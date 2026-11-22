-- =====================================================================
-- 03-programacao.sql | funcoes, gatilhos e procedimentos
-- Roda depois da carga (ordem: 01, 02, carga, 03, 04, 05).
-- =====================================================================
SET search_path TO liga_facom;

CREATE OR REPLACE FUNCTION fmt_cartoletas(v numeric) RETURNS text
LANGUAGE sql IMMUTABLE AS
$$ SELECT 'C$ ' || replace(to_char(v, 'FM999990.00'), '.', ',') $$;

CREATE OR REPLACE FUNCTION pontuacao_tecnico_real(p_id_clube integer, p_rodada integer)
RETURNS numeric LANGUAGE sql STABLE SET search_path = liga_facom AS $$
    SELECT COALESCE((
        SELECT CASE WHEN gp > gc THEN 5 WHEN gp = gc THEN 2 ELSE 0 END
          FROM (SELECT CASE WHEN id_clube_mandante = p_id_clube THEN placar_mandante ELSE placar_visitante END AS gp,
                       CASE WHEN id_clube_mandante = p_id_clube THEN placar_visitante ELSE placar_mandante END AS gc
                  FROM partida
                 WHERE numero_rodada = p_rodada AND valida
                   AND placar_mandante IS NOT NULL
                   AND p_id_clube IN (id_clube_mandante, id_clube_visitante)
                 ORDER BY data_hora
                 LIMIT 1) j
    ), 0)::numeric
$$;

CREATE OR REPLACE FUNCTION pontuacao_atleta(p_id_atleta integer, p_rodada integer)
RETURNS numeric LANGUAGE plpgsql STABLE SET search_path = liga_facom AS $$
DECLARE
    v_posicao integer;
    v_abrev   varchar;
    v_clube   integer;
BEGIN
    SELECT a.id_posicao, p.abreviacao INTO v_posicao, v_abrev
      FROM atleta a JOIN posicao p USING (id_posicao)
     WHERE a.id_atleta = p_id_atleta;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Atleta % não existe.', p_id_atleta;
    END IF;

    IF v_abrev = 'tec' THEN
        SELECT id_clube INTO v_clube FROM atleta_rodada
         WHERE id_atleta = p_id_atleta AND numero_rodada = p_rodada;
        RETURN CASE WHEN v_clube IS NULL THEN 0 ELSE pontuacao_tecnico_real(v_clube, p_rodada) END;
    END IF;

    RETURN COALESCE((
        SELECT SUM(r.quantidade * ts.valor_pontos)
          FROM atleta_partida ae
          JOIN partida pa     ON pa.id_partida = ae.id_partida AND pa.numero_rodada = p_rodada
          JOIN scout_partida r     ON r.id_atleta = ae.id_atleta AND r.id_partida = ae.id_partida
          JOIN tipo_scout ts  ON ts.sigla = r.sigla
          JOIN posicao_scout vp   ON vp.sigla = r.sigla AND vp.id_posicao = v_posicao
         WHERE ae.id_atleta = p_id_atleta AND ae.entrou_em_campo
    ), 0);
END $$;

CREATE OR REPLACE FUNCTION pontuacao_escalacao(p_id_tecnico integer, p_rodada integer)
RETURNS numeric LANGUAGE sql STABLE SET search_path = liga_facom AS $$
    SELECT round(COALESCE(SUM(pontuacao_atleta(e.id_atleta, p_rodada)
                        * CASE WHEN e.capitao THEN 1.5 ELSE 1 END), 0), 2)
      FROM escalacao es
      JOIN escala e ON e.id_tecnico = es.id_tecnico AND e.numero_rodada = es.numero_rodada
     WHERE es.id_tecnico = p_id_tecnico AND es.numero_rodada = p_rodada
       AND es.status = 'confirmada'
$$;

CREATE OR REPLACE FUNCTION tg_rodada_transicao() RETURNS trigger
LANGUAGE plpgsql SET search_path = liga_facom AS $$
BEGIN
    IF NEW.numero <> OLD.numero THEN
        RAISE EXCEPTION 'O número da rodada não pode ser alterado.';
    END IF;
    IF NEW.estado IS DISTINCT FROM OLD.estado
       AND NOT ((OLD.estado IS NULL AND NEW.estado = 'aberta')
             OR (OLD.estado = 'aberta' AND NEW.estado = 'fechada')
             OR (OLD.estado = 'fechada' AND NEW.estado = 'consolidada')) THEN
        RAISE EXCEPTION 'Mudança de estado inválida na rodada %: de % para %.',
            OLD.numero, COALESCE(OLD.estado, 'não aberta'), COALESCE(NEW.estado, 'não aberta');
    END IF;
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_rodada_transicao ON rodada;
CREATE TRIGGER trg_rodada_transicao BEFORE UPDATE ON rodada
    FOR EACH ROW EXECUTE FUNCTION tg_rodada_transicao();

CREATE OR REPLACE FUNCTION tg_escala_regras() RETURNS trigger
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE
    v_tec integer; v_rod integer;
    v_estado varchar; v_status varchar; v_esquema integer;
    v_preco numeric; v_sit varchar; v_apelido varchar; v_pos integer; v_pos_abrev varchar;
    v_patrimonio numeric; v_outros numeric; v_vagas smallint; v_ocupadas integer;
    v_antigo integer;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_tec := OLD.id_tecnico; v_rod := OLD.numero_rodada;
    ELSE
        v_tec := NEW.id_tecnico; v_rod := NEW.numero_rodada;
    END IF;

    SELECT estado INTO v_estado FROM rodada WHERE numero = v_rod;
    IF v_estado IS DISTINCT FROM 'aberta' THEN
        RAISE EXCEPTION 'A rodada % não está aberta: a escalação não pode ser alterada.', v_rod;
    END IF;

    SELECT status, id_esquema INTO v_status, v_esquema
      FROM escalacao WHERE id_tecnico = v_tec AND numero_rodada = v_rod FOR UPDATE;
    IF v_status = 'confirmada' THEN
        RAISE EXCEPTION 'A escalação já está confirmada e não pode mais ser alterada.';
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    v_antigo := CASE WHEN TG_OP = 'UPDATE' THEN OLD.id_atleta ELSE NEW.id_atleta END;

    SELECT ar.preco, s.nome, a.apelido, a.id_posicao, p.abreviacao
      INTO v_preco, v_sit, v_apelido, v_pos, v_pos_abrev
      FROM atleta_rodada ar
      JOIN atleta a   ON a.id_atleta = ar.id_atleta
      JOIN situacao s ON s.id_situacao = ar.id_situacao
      JOIN posicao p  ON p.id_posicao = a.id_posicao
     WHERE ar.id_atleta = NEW.id_atleta AND ar.numero_rodada = v_rod;
    IF NOT FOUND OR v_preco IS NULL THEN
        RAISE EXCEPTION 'O atleta % não tem preço definido para a rodada %.', NEW.id_atleta, v_rod;
    END IF;
    IF v_sit NOT IN ('Provável', 'Dúvida') THEN
        RAISE EXCEPTION '% está com a situação "%" e não pode ser escalado (só Provável ou Dúvida).',
            v_apelido, v_sit;
    END IF;
    NEW.preco_pago := v_preco;

    IF NEW.capitao AND v_pos_abrev = 'tec' THEN
        RAISE EXCEPTION 'O técnico real não pode ser capitão.';
    END IF;

    SELECT quantidade INTO v_vagas FROM esquema_posicao WHERE id_esquema = v_esquema AND id_posicao = v_pos;
    SELECT count(*) INTO v_ocupadas
      FROM escala e JOIN atleta a USING (id_atleta)
     WHERE e.id_tecnico = v_tec AND e.numero_rodada = v_rod
       AND a.id_posicao = v_pos AND e.id_atleta <> v_antigo;
    IF v_ocupadas >= COALESCE(v_vagas, 0) THEN
        RAISE EXCEPTION 'O esquema não tem mais vaga para a posição % (limite: %).',
            v_pos_abrev, COALESCE(v_vagas, 0);
    END IF;

    SELECT patrimonio_atual INTO v_patrimonio FROM time_fantasy WHERE id_tecnico = v_tec;
    SELECT COALESCE(SUM(preco_pago), 0) INTO v_outros
      FROM escala WHERE id_tecnico = v_tec AND numero_rodada = v_rod AND id_atleta <> v_antigo;
    IF v_outros + v_preco > v_patrimonio THEN
        RAISE EXCEPTION 'Orçamento estourado: a escalação custaria % e o patrimônio é %.',
            fmt_cartoletas(v_outros + v_preco), fmt_cartoletas(v_patrimonio);
    END IF;

    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_escala_regras ON escala;
CREATE TRIGGER trg_escala_regras BEFORE INSERT OR UPDATE OR DELETE ON escala
    FOR EACH ROW EXECUTE FUNCTION tg_escala_regras();

CREATE OR REPLACE FUNCTION tg_escalacao_regras() RETURNS trigger
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE v_estado varchar; v_rod integer;
BEGIN
    v_rod := CASE WHEN TG_OP = 'DELETE' THEN OLD.numero_rodada ELSE NEW.numero_rodada END;
    SELECT estado INTO v_estado FROM rodada WHERE numero = v_rod;
    IF v_estado IS DISTINCT FROM 'aberta' THEN
        RAISE EXCEPTION 'A rodada % não está aberta: a escalação não pode ser criada, alterada ou removida.', v_rod;
    END IF;
    IF TG_OP <> 'INSERT' AND OLD.status = 'confirmada' THEN
        RAISE EXCEPTION 'A escalação já está confirmada e não pode mais ser alterada.';
    END IF;
    IF TG_OP <> 'DELETE' AND NEW.status = 'confirmada'
       AND COALESCE(current_setting('liga.confirmando', true), '') <> 'on' THEN
        RAISE EXCEPTION 'Para confirmar a escalação use o procedimento confirmar_escalacao.';
    END IF;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS trg_escalacao_regras ON escalacao;
CREATE TRIGGER trg_escalacao_regras BEFORE INSERT OR UPDATE OR DELETE ON escalacao
    FOR EACH ROW EXECUTE FUNCTION tg_escalacao_regras();

CREATE OR REPLACE FUNCTION tg_trava_rodada_consolidada() RETURNS trigger
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE
    v_linha jsonb; v_estado varchar;
BEGIN
    FOREACH v_linha IN ARRAY
        CASE TG_OP WHEN 'INSERT' THEN ARRAY[to_jsonb(NEW)]
                   WHEN 'DELETE' THEN ARRAY[to_jsonb(OLD)]
                   ELSE ARRAY[to_jsonb(OLD), to_jsonb(NEW)] END
    LOOP
        IF TG_TABLE_NAME = 'partida' THEN
            SELECT estado INTO v_estado FROM rodada WHERE numero = (v_linha->>'numero_rodada')::int;
        ELSE
            SELECT r.estado INTO v_estado
              FROM partida p JOIN rodada r ON r.numero = p.numero_rodada
             WHERE p.id_partida = (v_linha->>'id_partida')::int;
        END IF;
        IF v_estado = 'consolidada' THEN
            RAISE EXCEPTION 'A rodada já está consolidada: partidas, presenças e scouts não podem mais ser alterados.';
        END IF;
    END LOOP;
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

DROP TRIGGER IF EXISTS trg_trava_scout_partida ON scout_partida;
CREATE TRIGGER trg_trava_scout_partida BEFORE INSERT OR UPDATE OR DELETE ON scout_partida
    FOR EACH ROW EXECUTE FUNCTION tg_trava_rodada_consolidada();
DROP TRIGGER IF EXISTS trg_trava_atleta_partida ON atleta_partida;
CREATE TRIGGER trg_trava_atleta_partida BEFORE INSERT OR UPDATE OR DELETE ON atleta_partida
    FOR EACH ROW EXECUTE FUNCTION tg_trava_rodada_consolidada();
DROP TRIGGER IF EXISTS trg_trava_partida ON partida;
CREATE TRIGGER trg_trava_partida BEFORE INSERT OR UPDATE OR DELETE ON partida
    FOR EACH ROW EXECUTE FUNCTION tg_trava_rodada_consolidada();

CREATE OR REPLACE PROCEDURE definir_capitao(p_id_tecnico integer, p_rodada integer, p_id_atleta integer)
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE v_abrev varchar;
BEGIN
    SELECT p.abreviacao INTO v_abrev
      FROM escala e JOIN atleta a USING (id_atleta) JOIN posicao p USING (id_posicao)
     WHERE e.id_tecnico = p_id_tecnico AND e.numero_rodada = p_rodada AND e.id_atleta = p_id_atleta;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'O atleta % não está nessa escalação.', p_id_atleta;
    END IF;
    IF v_abrev = 'tec' THEN
        RAISE EXCEPTION 'O técnico real não pode ser capitão.';
    END IF;
    UPDATE escala SET capitao = false
     WHERE id_tecnico = p_id_tecnico AND numero_rodada = p_rodada AND capitao;
    UPDATE escala SET capitao = true
     WHERE id_tecnico = p_id_tecnico AND numero_rodada = p_rodada AND id_atleta = p_id_atleta;
END $$;

CREATE OR REPLACE PROCEDURE confirmar_escalacao(p_id_tecnico integer, p_rodada integer)
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE
    v_status varchar; v_esquema integer; v_estado varchar;
    r record; v_capitaes integer; v_total numeric; v_patrimonio numeric;
BEGIN
    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada;
    IF v_estado IS DISTINCT FROM 'aberta' THEN
        RAISE EXCEPTION 'A rodada % não está aberta.', p_rodada;
    END IF;
    SELECT status, id_esquema INTO v_status, v_esquema
      FROM escalacao WHERE id_tecnico = p_id_tecnico AND numero_rodada = p_rodada FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'O técnico % não tem escalação na rodada %.', p_id_tecnico, p_rodada;
    END IF;
    IF v_status = 'confirmada' THEN
        RAISE EXCEPTION 'A escalação já está confirmada.';
    END IF;

    FOR r IN
        SELECT p.abreviacao, x.quantidade AS exigida,
               (SELECT count(*) FROM escala e JOIN atleta a USING (id_atleta)
                 WHERE e.id_tecnico = p_id_tecnico AND e.numero_rodada = p_rodada
                   AND a.id_posicao = x.id_posicao) AS escolhida
          FROM esquema_posicao x JOIN posicao p USING (id_posicao)
         WHERE x.id_esquema = v_esquema
    LOOP
        IF r.escolhida <> r.exigida THEN
            RAISE EXCEPTION 'Escalação incompleta: posição % tem % atleta(s) e o esquema exige %.',
                r.abreviacao, r.escolhida, r.exigida;
        END IF;
    END LOOP;

    SELECT count(*) INTO v_capitaes
      FROM escala e JOIN atleta a USING (id_atleta) JOIN posicao p USING (id_posicao)
     WHERE e.id_tecnico = p_id_tecnico AND e.numero_rodada = p_rodada
       AND e.capitao AND p.abreviacao <> 'tec';
    IF v_capitaes <> 1 THEN
        RAISE EXCEPTION 'A escalação precisa de exatamente um capitão entre os 11 atletas (há %).', v_capitaes;
    END IF;

    SELECT COALESCE(SUM(preco_pago), 0) INTO v_total
      FROM escala WHERE id_tecnico = p_id_tecnico AND numero_rodada = p_rodada;
    SELECT patrimonio_atual INTO v_patrimonio FROM time_fantasy WHERE id_tecnico = p_id_tecnico;
    IF v_total > v_patrimonio THEN
        RAISE EXCEPTION 'Orçamento estourado: a escalação custa % e o patrimônio é %.',
            fmt_cartoletas(v_total), fmt_cartoletas(v_patrimonio);
    END IF;

    PERFORM set_config('liga.confirmando', 'on', true);
    UPDATE escalacao SET status = 'confirmada', data_confirmacao = clock_timestamp()
     WHERE id_tecnico = p_id_tecnico AND numero_rodada = p_rodada;
    PERFORM set_config('liga.confirmando', 'off', true);
END $$;

CREATE OR REPLACE PROCEDURE entrar_na_liga(p_id_tecnico integer, p_id_liga integer, p_codigo text DEFAULT NULL)
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE v_liga liga%ROWTYPE; v_qtd integer;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tecnico WHERE id_tecnico = p_id_tecnico) THEN
        RAISE EXCEPTION 'Técnico % não existe.', p_id_tecnico;
    END IF;
    SELECT * INTO v_liga FROM liga WHERE id_liga = p_id_liga FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Liga % não existe.', p_id_liga;
    END IF;
    IF EXISTS (SELECT 1 FROM participa WHERE id_liga = p_id_liga AND id_tecnico = p_id_tecnico) THEN
        RAISE EXCEPTION 'Você já participa da liga "%".', v_liga.nome;
    END IF;
    IF NOT v_liga.publica AND p_codigo IS DISTINCT FROM v_liga.codigo_convite THEN
        RAISE EXCEPTION 'Código de convite inválido para a liga privada "%".', v_liga.nome;
    END IF;
    SELECT count(*) INTO v_qtd FROM participa WHERE id_liga = p_id_liga;
    IF v_qtd >= v_liga.limite_participantes THEN
        RAISE EXCEPTION 'A liga "%" já atingiu o limite de % participantes.', v_liga.nome, v_liga.limite_participantes;
    END IF;
    INSERT INTO participa (id_liga, id_tecnico) VALUES (p_id_liga, p_id_tecnico);
END $$;

CREATE OR REPLACE FUNCTION tg_liga_dono_participa() RETURNS trigger
LANGUAGE plpgsql SET search_path = liga_facom AS $$
BEGIN
    INSERT INTO participa (id_liga, id_tecnico) VALUES (NEW.id_liga, NEW.id_dono)
    ON CONFLICT DO NOTHING;
    RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_liga_dono_participa ON liga;
CREATE TRIGGER trg_liga_dono_participa AFTER INSERT ON liga
    FOR EACH ROW EXECUTE FUNCTION tg_liga_dono_participa();

CREATE OR REPLACE PROCEDURE abrir_rodada(p_rodada integer)
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE v_estado varchar; v_ult integer; v_prim integer; v_sem_preco integer;
BEGIN
    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'A rodada % não existe.', p_rodada;
    END IF;
    IF v_estado IS NOT NULL THEN
        RAISE EXCEPTION 'A rodada % não pode ser aberta: ela já está %.', p_rodada, v_estado;
    END IF;
    IF EXISTS (SELECT 1 FROM rodada WHERE estado IN ('aberta', 'fechada')) THEN
        RAISE EXCEPTION 'Já existe uma rodada aberta ou fechada; consolide-a antes de abrir outra.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM partida WHERE numero_rodada = p_rodada) THEN
        RAISE EXCEPTION 'A rodada % não tem partidas carregadas.', p_rodada;
    END IF;

    SELECT max(numero) INTO v_ult FROM rodada WHERE estado = 'consolidada';
    IF v_ult IS NULL THEN
        SELECT min(numero_rodada) INTO v_prim FROM partida;
        IF p_rodada <> v_prim THEN
            RAISE EXCEPTION 'A primeira rodada a abrir é a %.', v_prim;
        END IF;
    ELSIF p_rodada <> v_ult + 1 THEN
        RAISE EXCEPTION 'A próxima rodada a abrir é a %.', v_ult + 1;
    END IF;

    INSERT INTO atleta_rodada (id_atleta, numero_rodada, preco, id_clube, id_situacao)
    SELECT id_atleta, p_rodada, NULL, id_clube, id_situacao FROM atleta
    ON CONFLICT (id_atleta, numero_rodada) DO NOTHING;

    UPDATE atleta_rodada ar
       SET preco = COALESCE(
             (SELECT x.preco FROM atleta_rodada x
               WHERE x.id_atleta = ar.id_atleta AND x.numero_rodada < ar.numero_rodada
                 AND x.preco IS NOT NULL
               ORDER BY x.numero_rodada DESC LIMIT 1),
             a.preco_inicial)
      FROM atleta a
     WHERE a.id_atleta = ar.id_atleta AND ar.numero_rodada = p_rodada AND ar.preco IS NULL;

    SELECT count(*) INTO v_sem_preco FROM atleta_rodada WHERE numero_rodada = p_rodada AND preco IS NULL;
    IF v_sem_preco > 0 THEN
        RAISE EXCEPTION 'Ainda há % atletas sem preço na rodada %.', v_sem_preco, p_rodada;
    END IF;

    UPDATE rodada SET estado = 'aberta' WHERE numero = p_rodada;
END $$;

CREATE OR REPLACE PROCEDURE fechar_mercado(p_rodada integer)
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE v_estado varchar;
BEGIN
    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'A rodada % não existe.', p_rodada;
    END IF;
    IF v_estado IS DISTINCT FROM 'aberta' THEN
        RAISE EXCEPTION 'Só é possível fechar o mercado de uma rodada aberta (a rodada % está %).',
            p_rodada, COALESCE(v_estado, 'não aberta');
    END IF;
    UPDATE rodada SET estado = 'fechada' WHERE numero = p_rodada;
END $$;

CREATE OR REPLACE PROCEDURE consolidar_rodada(p_rodada integer)
LANGUAGE plpgsql SET search_path = liga_facom AS $$
DECLARE v_estado varchar; v_sem_preco integer;
BEGIN
    SELECT estado INTO v_estado FROM rodada WHERE numero = p_rodada FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'A rodada % não existe.', p_rodada;
    END IF;
    IF v_estado = 'consolidada' THEN
        RAISE EXCEPTION 'A rodada % já foi consolidada.', p_rodada;
    END IF;
    IF v_estado IS DISTINCT FROM 'fechada' THEN
        RAISE EXCEPTION 'Só é possível consolidar uma rodada fechada (a rodada % está %).',
            p_rodada, COALESCE(v_estado, 'não aberta');
    END IF;
    SELECT count(*) INTO v_sem_preco FROM atleta_rodada WHERE numero_rodada = p_rodada AND preco IS NULL;
    IF v_sem_preco > 0 THEN
        RAISE EXCEPTION 'A rodada % tem % atletas sem preço.', p_rodada, v_sem_preco;
    END IF;

    DROP TABLE IF EXISTS tmp_valorizacao;
    CREATE TEMP TABLE tmp_valorizacao ON COMMIT DROP AS
    WITH jogou AS (
        SELECT DISTINCT ae.id_atleta
          FROM atleta_partida ae JOIN partida p ON p.id_partida = ae.id_partida
         WHERE p.numero_rodada = p_rodada AND ae.entrou_em_campo
    ), historico AS (
        SELECT DISTINCT ae.id_atleta, p.numero_rodada
          FROM atleta_partida ae
          JOIN partida p ON p.id_partida = ae.id_partida
          JOIN rodada r  ON r.numero = p.numero_rodada AND r.estado = 'consolidada'
         WHERE ae.entrou_em_campo AND ae.id_atleta IN (SELECT id_atleta FROM jogou)
    ), medias AS (
        SELECT id_atleta, avg(pontuacao_atleta(id_atleta, numero_rodada)) AS media
          FROM historico GROUP BY id_atleta
    ), var AS (
        SELECT j.id_atleta,
               CASE WHEN m.media IS NULL THEN 0
                    ELSE round(LEAST(1.50, GREATEST(-1.50,
                         0.10 * (pontuacao_atleta(j.id_atleta, p_rodada) - m.media))), 2)
               END AS variacao
          FROM jogou j LEFT JOIN medias m USING (id_atleta)
    )
    SELECT ar.id_atleta, ar.preco AS preco_antigo, ar.id_clube, ar.id_situacao,
           CASE WHEN v.id_atleta IS NULL THEN ar.preco
                ELSE GREATEST(1.00, ar.preco + v.variacao) END AS preco_novo
      FROM atleta_rodada ar LEFT JOIN var v USING (id_atleta)
     WHERE ar.numero_rodada = p_rodada;

    UPDATE time_fantasy t
       SET patrimonio_atual = t.patrimonio_atual + d.delta
      FROM (SELECT es.id_tecnico, SUM(v.preco_novo - e.preco_pago) AS delta
              FROM escalacao es
              JOIN escala e ON e.id_tecnico = es.id_tecnico AND e.numero_rodada = es.numero_rodada
              JOIN tmp_valorizacao v ON v.id_atleta = e.id_atleta
             WHERE es.numero_rodada = p_rodada AND es.status = 'confirmada'
             GROUP BY es.id_tecnico) d
     WHERE t.id_tecnico = d.id_tecnico;

    INSERT INTO historico_patrimonio (id_time, numero_rodada, patrimonio_final)
    SELECT id_time, p_rodada, patrimonio_atual FROM time_fantasy;

    IF p_rodada < 38 THEN
        INSERT INTO atleta_rodada (id_atleta, numero_rodada, preco, id_clube, id_situacao)
        SELECT id_atleta, p_rodada + 1, preco_novo, id_clube, id_situacao FROM tmp_valorizacao
        ON CONFLICT (id_atleta, numero_rodada) DO UPDATE SET preco = EXCLUDED.preco;
    END IF;

    UPDATE rodada SET estado = 'consolidada' WHERE numero = p_rodada;
END $$;