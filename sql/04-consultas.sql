-- =====================================================================
-- 04-consultas.sql | visoes e consultas (item 5)
-- Ordem de execucao: 01-ddl, 02-dados, carga, 03-programacao, 04, 05.
-- =====================================================================
SET search_path TO liga_facom;

-- ---------------------------------------------------------------------
-- Visoes auxiliares (base das consultas 5(a)..5(k))
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW v_pontos_tecnico_real AS
SELECT DISTINCT ON (j.id_clube, j.numero_rodada)
       j.id_clube, j.numero_rodada,
       CASE WHEN j.gols_pro > j.gols_contra THEN 5
            WHEN j.gols_pro = j.gols_contra THEN 2
            ELSE 0 END AS pontos
  FROM (SELECT id_clube_mandante AS id_clube, numero_rodada, data_hora,
               placar_mandante AS gols_pro, placar_visitante AS gols_contra
          FROM partida WHERE valida AND placar_mandante IS NOT NULL
        UNION ALL
        SELECT id_clube_visitante, numero_rodada, data_hora,
               placar_visitante, placar_mandante
          FROM partida WHERE valida AND placar_mandante IS NOT NULL) j
 ORDER BY j.id_clube, j.numero_rodada, j.data_hora;

CREATE OR REPLACE VIEW v_pontuacao_atleta_rodada AS
SELECT ae.id_atleta, pa.numero_rodada,
       COALESCE(SUM(CASE WHEN vp.sigla IS NOT NULL THEN r.quantidade * ts.valor_pontos END), 0) AS pontuacao
  FROM atua_em ae
  JOIN partida pa ON pa.id_partida = ae.id_partida
  JOIN atleta a   ON a.id_atleta = ae.id_atleta
  JOIN posicao po ON po.id_posicao = a.id_posicao
  LEFT JOIN registra r    ON r.id_atleta = ae.id_atleta AND r.id_partida = ae.id_partida
  LEFT JOIN tipo_scout ts ON ts.sigla = r.sigla
  LEFT JOIN vale_para vp  ON vp.sigla = r.sigla AND vp.id_posicao = a.id_posicao
 WHERE ae.entrou_em_campo AND po.abreviacao <> 'tec'
 GROUP BY ae.id_atleta, pa.numero_rodada
UNION ALL
SELECT ae.id_atleta, pa.numero_rodada, COALESCE(MAX(tr.pontos), 0)
  FROM atua_em ae
  JOIN partida pa       ON pa.id_partida = ae.id_partida
  JOIN atleta a         ON a.id_atleta = ae.id_atleta
  JOIN posicao po       ON po.id_posicao = a.id_posicao
  LEFT JOIN atleta_rodada ar       ON ar.id_atleta = ae.id_atleta AND ar.numero_rodada = pa.numero_rodada
  LEFT JOIN v_pontos_tecnico_real tr ON tr.id_clube = ar.id_clube AND tr.numero_rodada = pa.numero_rodada
 WHERE ae.entrou_em_campo AND po.abreviacao = 'tec'
 GROUP BY ae.id_atleta, pa.numero_rodada;

CREATE OR REPLACE VIEW v_pontuacao_escalacao AS
SELECT es.id_tecnico, es.numero_rodada, es.data_confirmacao,
       round(SUM(CASE WHEN po.abreviacao = 'tec' THEN COALESCE(tr.pontos, 0)
                      ELSE COALESCE(v.pontuacao, 0) END
                 * CASE WHEN e.capitao THEN 1.5 ELSE 1 END), 2) AS pontuacao
  FROM escalacao es
  JOIN rodada rd ON rd.numero = es.numero_rodada AND rd.estado = 'consolidada'
  JOIN escala e  ON e.id_tecnico = es.id_tecnico AND e.numero_rodada = es.numero_rodada
  JOIN atleta a  ON a.id_atleta = e.id_atleta
  JOIN posicao po ON po.id_posicao = a.id_posicao
  JOIN atleta_rodada ar ON ar.id_atleta = e.id_atleta AND ar.numero_rodada = e.numero_rodada
  LEFT JOIN v_pontuacao_atleta_rodada v ON v.id_atleta = e.id_atleta AND v.numero_rodada = e.numero_rodada
  LEFT JOIN v_pontos_tecnico_real tr    ON tr.id_clube = ar.id_clube AND tr.numero_rodada = e.numero_rodada
 WHERE es.status = 'confirmada'
 GROUP BY es.id_tecnico, es.numero_rodada, es.data_confirmacao;

CREATE OR REPLACE VIEW v_pontuacao_acumulada AS
SELECT t.id_tecnico, COALESCE(SUM(v.pontuacao), 0) AS pontuacao
  FROM tecnico t
  LEFT JOIN v_pontuacao_escalacao v ON v.id_tecnico = t.id_tecnico
 GROUP BY t.id_tecnico;

-- 5(a) Visão do mercado: atletas escaláveis (Provável/Dúvida) da rodada aberta,
--      com preço atual, média e pontuação da última rodada consolidada.
CREATE OR REPLACE VIEW v_mercado AS
SELECT a.id_atleta, a.apelido, c.abreviacao AS clube, p.abreviacao AS posicao,
       s.nome AS situacao, ar.preco AS preco_atual,
       m.media, u.pontuacao AS pontuacao_ultima_rodada
  FROM rodada r
  JOIN atleta_rodada ar ON ar.numero_rodada = r.numero
  JOIN atleta a   ON a.id_atleta = ar.id_atleta
  JOIN clube c    ON c.id_clube = ar.id_clube
  JOIN posicao p  ON p.id_posicao = a.id_posicao
  JOIN situacao s ON s.id_situacao = ar.id_situacao
  LEFT JOIN LATERAL (
        SELECT round(avg(v.pontuacao), 2) AS media
          FROM v_pontuacao_atleta_rodada v
          JOIN rodada rc ON rc.numero = v.numero_rodada AND rc.estado = 'consolidada'
         WHERE v.id_atleta = a.id_atleta) m ON true
  LEFT JOIN LATERAL (
        SELECT v.pontuacao
          FROM v_pontuacao_atleta_rodada v
          JOIN rodada rc ON rc.numero = v.numero_rodada AND rc.estado = 'consolidada'
         WHERE v.id_atleta = a.id_atleta
         ORDER BY v.numero_rodada DESC
         LIMIT 1) u ON true
 WHERE r.estado = 'aberta'
   AND s.nome IN ('Provável', 'Dúvida');

SELECT * FROM v_mercado ORDER BY posicao, preco_atual DESC LIMIT 20;

-- 5(b) Visão do ranking da liga com empate na mesma posição (RANK) —
--      acumulada e por rodada consolidada.
CREATE OR REPLACE VIEW v_ranking AS
SELECT pa.id_liga, l.nome AS liga, pa.id_tecnico, t.apelido, tf.nome AS time,
       ac.pontuacao AS pontuacao_acumulada,
       RANK() OVER (PARTITION BY pa.id_liga ORDER BY ac.pontuacao DESC) AS posicao
  FROM participa pa
  JOIN liga l            ON l.id_liga = pa.id_liga
  JOIN tecnico t         ON t.id_tecnico = pa.id_tecnico
  JOIN time_fantasy tf   ON tf.id_tecnico = t.id_tecnico
  JOIN v_pontuacao_acumulada ac ON ac.id_tecnico = t.id_tecnico;

CREATE OR REPLACE VIEW v_ranking_rodada AS
SELECT pa.id_liga, l.nome AS liga, r.numero AS numero_rodada, pa.id_tecnico, t.apelido,
       COALESCE(v.pontuacao, 0) AS pontuacao,
       RANK() OVER (PARTITION BY pa.id_liga, r.numero ORDER BY COALESCE(v.pontuacao, 0) DESC) AS posicao
  FROM participa pa
  JOIN liga l    ON l.id_liga = pa.id_liga
  JOIN tecnico t ON t.id_tecnico = pa.id_tecnico
  CROSS JOIN rodada r
  LEFT JOIN v_pontuacao_escalacao v ON v.id_tecnico = pa.id_tecnico AND v.numero_rodada = r.numero
 WHERE r.estado = 'consolidada';

SELECT * FROM v_ranking ORDER BY id_liga, posicao, apelido;

-- 5(c) Os 5 atletas de cada posição com melhor custo-benefício (média / preço atual),
--      só atletas que entraram em campo em pelo menos 3 rodadas.
WITH base AS (
    SELECT a.id_atleta, a.apelido, a.id_posicao,
           avg(v.pontuacao) AS media,
           count(*)         AS rodadas_jogadas,
           COALESCE((SELECT x.preco FROM atleta_rodada x
                      WHERE x.id_atleta = a.id_atleta AND x.preco IS NOT NULL
                      ORDER BY x.numero_rodada DESC LIMIT 1), a.preco_inicial) AS preco_atual
      FROM atleta a
      JOIN v_pontuacao_atleta_rodada v ON v.id_atleta = a.id_atleta
     GROUP BY a.id_atleta, a.apelido, a.id_posicao, a.preco_inicial
    HAVING count(*) >= 3
), ranqueado AS (
    SELECT b.*, b.media / b.preco_atual AS custo_beneficio,
           ROW_NUMBER() OVER (PARTITION BY b.id_posicao
                              ORDER BY b.media / b.preco_atual DESC, b.apelido) AS ordem
      FROM base b
)
SELECT p.abreviacao AS posicao, r.ordem, r.apelido, round(r.media, 2) AS media,
       r.preco_atual, round(r.custo_beneficio, 3) AS custo_beneficio, r.rodadas_jogadas
  FROM ranqueado r
  JOIN posicao p ON p.id_posicao = r.id_posicao
 WHERE r.ordem <= 5
 ORDER BY array_position(ARRAY['gol','lat','zag','mei','ata','tec'], p.abreviacao::text), r.ordem;

-- 5(d) A escalação mais pontuada da rodada (top da rodada), com desempate
--      por quem confirmou a escalação primeiro.
-- parametro: rodada = 25
SELECT t.apelido AS tecnico, tf.nome AS time, v.pontuacao, cap.apelido AS capitao
  FROM v_pontuacao_escalacao v
  JOIN tecnico t       ON t.id_tecnico = v.id_tecnico
  JOIN time_fantasy tf ON tf.id_tecnico = t.id_tecnico
  JOIN escala e        ON e.id_tecnico = v.id_tecnico AND e.numero_rodada = v.numero_rodada AND e.capitao
  JOIN atleta cap      ON cap.id_atleta = e.id_atleta
 WHERE v.numero_rodada = 25
 ORDER BY v.pontuacao DESC, v.data_confirmacao
 LIMIT 1;

-- 5(e) O clube com mais jogos sem sofrer gol nas últimas 5 rodadas consolidadas.
WITH ultimas AS (
    SELECT numero FROM rodada WHERE estado = 'consolidada' ORDER BY numero DESC LIMIT 5
), jogos AS (
    SELECT id_clube_mandante AS id_clube, placar_visitante AS gols_sofridos
      FROM partida
     WHERE numero_rodada IN (SELECT numero FROM ultimas) AND valida AND placar_mandante IS NOT NULL
    UNION ALL
    SELECT id_clube_visitante, placar_mandante
      FROM partida
     WHERE numero_rodada IN (SELECT numero FROM ultimas) AND valida AND placar_mandante IS NOT NULL
)
SELECT c.abreviacao, c.nome, count(*) AS jogos_sem_sofrer_gol
  FROM jogos j JOIN clube c ON c.id_clube = j.id_clube
 WHERE j.gols_sofridos = 0
 GROUP BY c.id_clube, c.abreviacao, c.nome
 ORDER BY jogos_sem_sofrer_gol DESC
 FETCH FIRST 1 ROWS WITH TIES;

-- 5(f) O capitão mais escolhido na liga (entre escalações confirmadas).
-- parametro: id_liga = 1
SELECT a.apelido, count(*) AS vezes_capitao
  FROM participa pa
  JOIN escalacao es ON es.id_tecnico = pa.id_tecnico AND es.status = 'confirmada'
  JOIN escala e     ON e.id_tecnico = es.id_tecnico AND e.numero_rodada = es.numero_rodada AND e.capitao
  JOIN atleta a     ON a.id_atleta = e.id_atleta
 WHERE pa.id_liga = 1
 GROUP BY a.id_atleta, a.apelido
 ORDER BY vezes_capitao DESC
 FETCH FIRST 1 ROWS WITH TIES;

-- 5(g) Os técnicos que nunca escalaram nenhum atleta do clube indicado.
-- parametro: clube = 'FLA'
SELECT t.id_tecnico, t.apelido
  FROM tecnico t
 WHERE NOT EXISTS (
        SELECT 1
          FROM escalacao es
          JOIN escala e         ON e.id_tecnico = es.id_tecnico AND e.numero_rodada = es.numero_rodada
          JOIN atleta_rodada ar ON ar.id_atleta = e.id_atleta AND ar.numero_rodada = e.numero_rodada
          JOIN clube c          ON c.id_clube = ar.id_clube
         WHERE es.id_tecnico = t.id_tecnico AND es.status = 'confirmada'
           AND c.abreviacao = 'FLA')
 ORDER BY t.apelido;

-- 5(h) Os atletas que ficaram sempre acima da média da posição em todas as
--      rodadas consolidadas em que jogaram.
WITH pts AS (
    SELECT v.id_atleta, v.numero_rodada, v.pontuacao, a.id_posicao,
           avg(v.pontuacao) OVER (PARTITION BY v.numero_rodada, a.id_posicao) AS media_posicao
      FROM v_pontuacao_atleta_rodada v
      JOIN atleta a ON a.id_atleta = v.id_atleta
      JOIN rodada r ON r.numero = v.numero_rodada AND r.estado = 'consolidada'
)
SELECT a.apelido, p.abreviacao AS posicao, count(*) AS rodadas_jogadas
  FROM pts
  JOIN atleta a  ON a.id_atleta = pts.id_atleta
  JOIN posicao p ON p.id_posicao = pts.id_posicao
 GROUP BY a.id_atleta, a.apelido, p.abreviacao
HAVING bool_and(pts.pontuacao > pts.media_posicao)
 ORDER BY rodadas_jogadas DESC, a.apelido;

-- 5(i) A evolução do patrimônio do técnico rodada a rodada, com a variação
--      em relação à rodada anterior.
-- parametro: id_tecnico = 1
SELECT h.numero_rodada, h.patrimonio_final,
       h.patrimonio_final - LAG(h.patrimonio_final, 1, 100.00)
                            OVER (ORDER BY h.numero_rodada) AS variacao
  FROM historico_patrimonio h
  JOIN time_fantasy tf ON tf.id_time = h.id_time
 WHERE tf.id_tecnico = 1
 ORDER BY h.numero_rodada;

-- 5(j) As ligas com pelo menos 3 participantes cuja pontuação média por
--      técnico (não acumulada, média das pontuações por rodada consolidada)
--      seja maior que a média geral de todos os técnicos do sistema.
WITH scores AS (
    -- uma linha por técnico por rodada consolidada (pontuação da escalação)
    SELECT v.id_tecnico, v.pontuacao
      FROM v_pontuacao_escalacao v
), geral AS (
    SELECT avg(pontuacao) AS valor FROM scores
)
SELECT l.id_liga,
       l.nome,
       count(DISTINCT pa.id_tecnico) AS participantes,
       round(avg(s.pontuacao), 2)    AS media_da_liga,
       round(g.valor, 2)             AS media_geral
  FROM liga l
  JOIN participa pa     ON pa.id_liga = l.id_liga
  LEFT JOIN scores s    ON s.id_tecnico = pa.id_tecnico
  CROSS JOIN geral g
 GROUP BY l.id_liga, l.nome, g.valor
HAVING count(DISTINCT pa.id_tecnico) >= 3
   AND avg(s.pontuacao) > g.valor
 ORDER BY media_da_liga DESC, l.nome;

-- 5(k) A seleção da rodada: o melhor atleta de cada posição com preço até
--      C$ 12,00 e o custo total da seleção.
-- parametro: rodada = 25
WITH candidatos AS (
    SELECT a.apelido, a.id_posicao, ar.preco, v.pontuacao,
           ROW_NUMBER() OVER (PARTITION BY a.id_posicao
                              ORDER BY v.pontuacao DESC, ar.preco, a.apelido) AS ordem
      FROM v_pontuacao_atleta_rodada v
      JOIN rodada r         ON r.numero = v.numero_rodada AND r.estado = 'consolidada'
      JOIN atleta a         ON a.id_atleta = v.id_atleta
      JOIN atleta_rodada ar ON ar.id_atleta = v.id_atleta AND ar.numero_rodada = v.numero_rodada
     WHERE v.numero_rodada = 25 AND ar.preco <= 12.00
)
SELECT p.abreviacao AS posicao, c.apelido, c.pontuacao, c.preco,
       SUM(c.preco) OVER () AS custo_total
  FROM candidatos c
  JOIN posicao p ON p.id_posicao = c.id_posicao
 WHERE c.ordem = 1
 ORDER BY array_position(ARRAY['gol','lat','zag','mei','ata','tec'], p.abreviacao::text);
