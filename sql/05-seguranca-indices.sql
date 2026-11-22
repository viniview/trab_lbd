-- =====================================================================
-- 05-seguranca-indices.sql | indices e camada de seguranca
-- Roda por ultimo (ordem: 01-ddl, 02-dados, carga, 03, 04, 05).
-- Script idempotente: pode ser executado duas vezes seguidas sem erro
-- (CREATE INDEX IF NOT EXISTS, DO ... IF NOT EXISTS para papeis,
-- GRANT/REVOKE repetidos nao falham).
-- =====================================================================
SET search_path TO liga_facom;

-- ---------------------------------------------------------------------
-- 1. INDICES
-- Justificativa geral: acelerar os joins e filtros das consultas de
-- 04-consultas.sql e da aplicacao de terminal. NENHUM indice abaixo
-- duplica uma PK ou UNIQUE ja existente em 01-ddl.sql — conferido:
--   * PKs de todas as tabelas (inclui os unicos compostos
--     atleta_rodada(id_atleta, numero_rodada),
--     atleta_rodada(id_atleta, numero_rodada, preco) [uq_atleta_rodada_preco],
--     escala(id_tecnico, numero_rodada, id_atleta),
--     escalacao(id_tecnico, numero_rodada),
--     participa(id_liga, id_tecnico),
--     historico_patrimonio(id_time, numero_rodada),
--     atleta_partida(id_atleta, id_partida), scout_partida(atleta, partida, sigla));
--   * UNIQUEs: uq_tecnico_email, uq_time_tecnico, uq_clube_api,
--     uq_clube_abrev, uq_posicao_api, uq_posicao_abrev, uq_situacao_api,
--     uq_situacao_nome, uq_atleta_api, uq_partida_api, uq_esquema_nome,
--     uq_liga_codigo;
--   * Unicos parciais: uq_rodada_unica_aberta, uq_escala_um_capitao.
-- Todos os indices criados aqui tem coluna(s) diferente(s) da coluna
-- inicial dessas chaves, logo nao sao redundantes.
-- ---------------------------------------------------------------------

-- Filtros por rodada sozinha (v_mercado, abrir_rodada/consolidar_rodada
-- procuram precos NULL da rodada). A PK composta (id_atleta, numero_rodada)
-- comeca por id_atleta e nao atende busca so por numero_rodada.
CREATE INDEX IF NOT EXISTS ix_atleta_rodada_numero_rodada
    ON atleta_rodada (numero_rodada);

-- "Clube do atleta na rodada": v_pontuacao_escalacao liga atleta_rodada
-- por (id_clube, numero_rodada) para achar o time do tecnico real, e a
-- carga localiza a partida do atleta por (rodada, clube).
CREATE INDEX IF NOT EXISTS ix_atleta_rodada_clube_rodada
    ON atleta_rodada (id_clube, numero_rodada);

-- Gatilhos trg_trava_* e as funcoes de pontuacao buscam a participacao
-- do atleta pela partida; a PK (id_atleta, id_partida) nao responde por
-- id_partida sozinho.
CREATE INDEX IF NOT EXISTS ix_atleta_partida_partida
    ON atleta_partida (id_partida);

-- pontuacao_tecnico_real, v_pontos_tecnico_real e abrir_rodada filtram
-- partidas por rodada; a PK e id_partida e o unico e id_api.
CREATE INDEX IF NOT EXISTS ix_partida_numero_rodada
    ON partida (numero_rodada);

-- Quais escalacoes contem um atleta (consulta de impacto do atleta e
-- verificacoes da aplicacao); a PK comeca por id_tecnico.
CREATE INDEX IF NOT EXISTS ix_escala_id_atleta
    ON escala (id_atleta);

-- Escalacoes de uma rodada (ranking, gatilhos, administrador); a PK
-- comeca por id_tecnico.
CREATE INDEX IF NOT EXISTS ix_escalacao_numero_rodada
    ON escalacao (numero_rodada);

-- "Ligas do tecnico" (menu do aplicativo: listar/entrar em liga e
-- consultar_ranking); a PK comeca por id_liga.
CREATE INDEX IF NOT EXISTS ix_participa_id_tecnico
    ON participa (id_tecnico);

-- Consulta 5(i): evolucao de patrimonio por rodada; a PK comeca por
-- id_time.
CREATE INDEX IF NOT EXISTS ix_historico_patrimonio_numero_rodada
    ON historico_patrimonio (numero_rodada);


-- ---------------------------------------------------------------------
-- 2. PAPEIS (idempotente)
-- app_liga  : camada minima para a aplicacao de terminal.
-- admin_liga: tudo do app_liga mais os procedimentos de administrador.
-- Ambos NOLOGIN: ninguem entra no banco com eles; quem conecta continua
-- sendo o dono (lbd). Sao seguranca documentada, nao obrigatorio.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_liga') THEN
        CREATE ROLE app_liga NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'admin_liga') THEN
        CREATE ROLE admin_liga NOLOGIN;
    END IF;
END $$;


-- ---------------------------------------------------------------------
-- 3. PERMISSOES
-- ---------------------------------------------------------------------
-- Ninguem fora dos papeis enxerga o esquema (o PUBLIC nao tem nem
-- USAGE; por padrao o PostgreSQL concede USAGE+CREATE no schema novo
-- para PUBLIC, entao revogamos).
REVOKE ALL ON SCHEMA liga_facom FROM PUBLIC;
GRANT USAGE ON SCHEMA liga_facom TO app_liga, admin_liga;

-- Revogacao explicita e documental: precos, patrimonio e valores de
-- scout NUNCA sao alterados direto — so o dono executa consolidar_rodada.
-- (Nao ha grant de UPDATE nessas tabelas para os papeis; o REVOKE fica
-- como trava caso alguem venha a conceder no futuro.)
REVOKE UPDATE ON atleta_rodada FROM app_liga, admin_liga;
REVOKE UPDATE ON time_fantasy  FROM app_liga, admin_liga;   -- patrimonio_atual
REVOKE UPDATE ON tipo_scout    FROM app_liga, admin_liga;

-- app_liga: leitura de tudo (tabelas e visoes) ...
GRANT SELECT ON ALL TABLES IN SCHEMA liga_facom TO app_liga;

-- ... escrita apenas no que a aplicacao cadastra/edita ...
GRANT INSERT ON tecnico, time_fantasy, liga, escalacao, escala
    TO app_liga;
GRANT UPDATE ON escalacao TO app_liga;   -- confirmar_escalacao muda status
GRANT DELETE ON escala    TO app_liga;   -- remover atleta da escala

-- ... sequences/identities usadas pelos INSERTs acima
-- (escalacao e escala tem PK composta, sem identity).
GRANT USAGE ON SEQUENCE tecnico_id_tecnico_seq,
                      time_fantasy_id_time_seq,
                      liga_id_liga_seq
    TO app_liga;

-- ... e EXECUTE nos procedimentos que a aplicacao chama.
GRANT EXECUTE ON PROCEDURE entrar_na_liga,
                        definir_capitao,
                        confirmar_escalacao
    TO app_liga;

-- admin_liga herda TODOS os privilegios do app_liga (membro da funcao)
-- e ganha os tres procedimentos de administrador.
GRANT app_liga TO admin_liga;
GRANT EXECUTE ON PROCEDURE abrir_rodada,
                        fechar_mercado,
                        consolidar_rodada
    TO admin_liga;

-- Ninguem fora do dono executa funcoes/procedimentos por padrao
-- (o EXECUTE em funcoes/procedimentos vem concedido ao PUBLIC por
-- padrao no PostgreSQL). O dono (lbd) mantem tudo por propriedade.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA liga_facom FROM PUBLIC;
REVOKE EXECUTE ON PROCEDURE entrar_na_liga,
                         definir_capitao,
                         confirmar_escalacao,
                         abrir_rodada,
                         fechar_mercado,
                         consolidar_rodada
    FROM PUBLIC;

-- OBSERVACAO (nao alterar 03-programacao.sql): os procedimentos sao
-- SECURITY INVOKER. Se um dia a aplicacao ou o administrador passarem a
-- conectar como app_liga/admin_liga, estes precisariam de SECURITY
-- DEFINER (ou de grants extras) para funcionar:
--   * entrar_na_liga  -> faz INSERT em participa (app_liga nao tem);
--   * definir_capitao -> faz UPDATE em escala (app_liga so tem DELETE);
--   * abrir_rodada / fechar_mercado / consolidar_rodada -> fazem UPDATE em
--     rodada, atleta_rodada e time_fantasy e INSERT em historico_patrimonio
--     (admin_liga nao tem; por isso consolidacao roda pelo dono lbd).
-- Enquanto isso, os papeis sao apenas camada de seguranca documentada:
-- a aplicacao continua conectando com o dono do banco (lbd).


-- ---------------------------------------------------------------------
-- 4. TESTE: app_liga NAO consegue alterar preco diretamente.
-- Tenta UPDATE em atleta_rodada como app_liga; a excecao
-- insufficient_privilege e capturada e anunciada com NOTICE.
-- ---------------------------------------------------------------------
DO $$
BEGIN
    SET ROLE app_liga;
    BEGIN
        UPDATE liga_facom.atleta_rodada
           SET preco = preco
         WHERE id_atleta = 1 AND numero_rodada = 1;
        RAISE NOTICE 'TESTE FALHOU: app_liga conseguiu UPDATE em atleta_rodada.';
    EXCEPTION WHEN insufficient_privilege THEN
        RAISE NOTICE 'TESTE OK: UPDATE em atleta_rodada recusado para app_liga -> %',
                     SQLERRM;
    END;
    RESET ROLE;
END $$;
