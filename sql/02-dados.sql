-- =====================================================================
-- 02-dados.sql  |  Liga FACOM Fantasy  |  dados que NAO vem do fluxo da API

-- =====================================================================
SET search_path TO liga_facom;

-- ---------------------------------------------------------------------
-- 1. As 38 rodadas
-- ---------------------------------------------------------------------
INSERT INTO rodada (numero)
SELECT g FROM generate_series(1, 38) AS g
ON CONFLICT (numero) DO NOTHING;

-- ---------------------------------------------------------------------
-- 2. Enumeracoes fixas do enunciado. Os ids sao os da fonte; a
--    carga as atualiza por id_api. Semeadas aqui porque vale_para (abaixo)
--    depende de posicao e a carga depende de tipo_scout.
-- ---------------------------------------------------------------------
INSERT INTO posicao (id_api, nome, abreviacao) VALUES
    (1, 'Goleiro',  'gol'),
    (2, 'Lateral',  'lat'),
    (3, 'Zagueiro', 'zag'),
    (4, 'Meia',     'mei'),
    (5, 'Atacante', 'ata'),
    (6, 'Técnico',  'tec')
ON CONFLICT (id_api) DO NOTHING;

INSERT INTO situacao (id_api, nome) VALUES
    (2, 'Dúvida'),
    (3, 'Suspenso'),
    (5, 'Contundido'),
    (6, 'Nulo'),
    (7, 'Provável')
ON CONFLICT (id_api) DO NOTHING;

-- ---------------------------------------------------------------------
-- 3. Tipos de scout e valores 
-- ---------------------------------------------------------------------
INSERT INTO tipo_scout (sigla, descricao, valor_pontos) VALUES
    ('G',  'Gol',                               8.00),
    ('A',  'Assistência',                       5.00),
    ('FT', 'Finalização na trave',              3.00),
    ('FD', 'Finalização defendida pelo goleiro',1.20),
    ('FF', 'Finalização para fora',             0.80),
    ('FS', 'Falta sofrida',                     0.50),
    ('PS', 'Pênalti sofrido',                   1.00),
    ('DS', 'Desarme',                           1.50),
    ('SG', 'Jogo sem sofrer gol',               5.00),
    ('DE', 'Defesa',                            1.30),
    ('DP', 'Defesa de pênalti',                 7.00),
    ('GS', 'Gol sofrido',                      -1.00),
    ('FC', 'Falta cometida',                   -0.30),
    ('I',  'Impedimento',                      -0.10),
    ('CA', 'Cartão amarelo',                   -1.00),
    ('CV', 'Cartão vermelho',                  -3.00),
    ('GC', 'Gol contra',                       -3.00),
    ('PC', 'Pênalti cometido',                 -1.00),
    ('PP', 'Pênalti perdido',                  -4.00)
ON CONFLICT (sigla) DO NOTHING;

-- Posicoes em que cada scout pontua (coluna "Observacao" da tabela 2.7).
-- Tecnico real nao tem scouts: sua pontuacao sai do placar.
-- a) scouts sem restricao: goleiro, lateral, zagueiro, meia e atacante
INSERT INTO posicao_scout (sigla, id_posicao)
SELECT t.sigla, p.id_posicao
  FROM tipo_scout t
  JOIN posicao p ON p.abreviacao IN ('gol', 'lat', 'zag', 'mei', 'ata')
 WHERE t.sigla NOT IN ('SG', 'DE', 'DP', 'GS')
ON CONFLICT (sigla, id_posicao) DO NOTHING;
-- b) SG: so goleiro, lateral e zagueiro
INSERT INTO posicao_scout (sigla, id_posicao)
SELECT t.sigla, p.id_posicao
  FROM tipo_scout t
  JOIN posicao p ON p.abreviacao IN ('gol', 'lat', 'zag')
 WHERE t.sigla = 'SG'
ON CONFLICT (sigla, id_posicao) DO NOTHING;
-- c) DE, DP e GS: so goleiro
INSERT INTO posicao_scout (sigla, id_posicao)
SELECT t.sigla, p.id_posicao
  FROM tipo_scout t
  JOIN posicao p ON p.abreviacao = 'gol'
 WHERE t.sigla IN ('DE', 'DP', 'GS')
ON CONFLICT (sigla, id_posicao) DO NOTHING;

-- ---------------------------------------------------------------------
-- 4. Tecnicos (>= 8) e seus times. Dados ficticios: troque pelos do grupo.
--    O patrimonio comeca em C$ 100,00 (DEFAULT da coluna).
-- ---------------------------------------------------------------------
INSERT INTO tecnico (nome, email, apelido, data_cadastro) VALUES
    ('Ana Souza',      'ana.souza@exemplo.com',      'Aninha',   '2026-10-20'),
    ('Bruno Lima',     'bruno.lima@exemplo.com',     'Brunão',   '2026-10-20'),
    ('Carla Mendes',   'carla.mendes@exemplo.com',   'Carlota',  '2026-10-21'),
    ('Diego Ramos',    'diego.ramos@exemplo.com',    'Dié',      '2026-10-22'),
    ('Elisa Prado',    'elisa.prado@exemplo.com',    'Eli',      '2026-10-23'),
    ('Fábio Teixeira', 'fabio.teixeira@exemplo.com', 'Fabão',    '2026-10-24'),
    ('Gabriela Alves', 'gabriela.alves@exemplo.com', 'Gabi',     '2026-10-25'),
    ('Heitor Nunes',   'heitor.nunes@exemplo.com',   'Heitor',   '2026-10-26'),
    ('Iara Campos',    'iara.campos@exemplo.com',    'Iara',     '2026-10-27')
ON CONFLICT (email) DO NOTHING;

INSERT INTO time_fantasy (id_tecnico, nome)
SELECT t.id_tecnico, v.nome_time
  FROM (VALUES
        ('ana.souza@exemplo.com',      'Bits Futebol Clube'),
        ('bruno.lima@exemplo.com',     'Atlético de Joins'),
        ('carla.mendes@exemplo.com',   'Primary Key United'),
        ('diego.ramos@exemplo.com',    'Select Esporte Clube'),
        ('elisa.prado@exemplo.com',    'Foreign Key FC'),
        ('fabio.teixeira@exemplo.com', 'Commit Atlético'),
        ('gabriela.alves@exemplo.com', 'Trigger Sports'),
        ('heitor.nunes@exemplo.com',   'Rollback Rovers'),
        ('iara.campos@exemplo.com',    'Index Scan FC')
       ) AS v(email, nome_time)
  JOIN tecnico t ON t.email = v.email
ON CONFLICT (id_tecnico) DO NOTHING;

-- ---------------------------------------------------------------------
-- 5. Ligas (3: duas publicas e uma privada) e participacoes.
--    O dono participa da propria liga. Varios tecnicos estao em mais de uma
--    liga (ex.: Ana, Bruno e Carla participam das tres).
-- ---------------------------------------------------------------------
INSERT INTO liga (id_dono, nome, descricao, codigo_convite, limite_participantes, publica)
SELECT t.id_tecnico, v.nome, v.descricao, v.codigo, v.limite, v.publica
  FROM (VALUES
        ('ana.souza@exemplo.com',    'Liga FACOM Geral', 'Liga aberta a toda a turma.',           'FACOM2026', 20, true),
        ('bruno.lima@exemplo.com',   'Turma de LBD',     'Liga fechada da disciplina de LBD.',    'LBD-8472',   8, false),
        ('carla.mendes@exemplo.com', 'Amigos do Código', 'Liga pública para quem quer treinar.',  'CODE-0001',  5, true)
       ) AS v(email, nome, descricao, codigo, limite, publica)
  JOIN tecnico t ON t.email = v.email
ON CONFLICT (codigo_convite) DO NOTHING;

INSERT INTO participa (id_liga, id_tecnico, data_entrada)
SELECT l.id_liga, t.id_tecnico, v.entrada::date
  FROM (VALUES
        -- Liga FACOM Geral: todos os 9 tecnicos
        ('FACOM2026', 'ana.souza@exemplo.com',      '2026-10-20'),
        ('FACOM2026', 'bruno.lima@exemplo.com',     '2026-10-20'),
        ('FACOM2026', 'carla.mendes@exemplo.com',   '2026-10-21'),
        ('FACOM2026', 'diego.ramos@exemplo.com',    '2026-10-22'),
        ('FACOM2026', 'elisa.prado@exemplo.com',    '2026-10-23'),
        ('FACOM2026', 'fabio.teixeira@exemplo.com', '2026-10-24'),
        ('FACOM2026', 'gabriela.alves@exemplo.com', '2026-10-25'),
        ('FACOM2026', 'heitor.nunes@exemplo.com',   '2026-10-26'),
        ('FACOM2026', 'iara.campos@exemplo.com',    '2026-10-27'),
        -- Turma de LBD (privada): 5 tecnicos
        ('LBD-8472',  'bruno.lima@exemplo.com',     '2026-10-21'),
        ('LBD-8472',  'ana.souza@exemplo.com',      '2026-10-22'),
        ('LBD-8472',  'carla.mendes@exemplo.com',   '2026-10-22'),
        ('LBD-8472',  'diego.ramos@exemplo.com',    '2026-10-23'),
        ('LBD-8472',  'elisa.prado@exemplo.com',    '2026-10-24'),
        -- Amigos do Codigo: 3 tecnicos
        ('CODE-0001', 'carla.mendes@exemplo.com',   '2026-10-23'),
        ('CODE-0001', 'ana.souza@exemplo.com',      '2026-10-24'),
        ('CODE-0001', 'bruno.lima@exemplo.com',     '2026-10-25')
       ) AS v(codigo, email, entrada)
  JOIN liga l    ON l.codigo_convite = v.codigo
  JOIN tecnico t ON t.email = v.email
ON CONFLICT (id_liga, id_tecnico) DO NOTHING;

