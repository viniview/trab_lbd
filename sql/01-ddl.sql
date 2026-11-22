-- =====================================================================
-- 01-ddl.sql  |  Liga FACOM Fantasy  |  PostgreSQL 16+
-- Cria o esquema proprio da liga e todas as tabelas do mapeamento ER->relacional.
-- =====================================================================


DROP SCHEMA IF EXISTS liga_facom CASCADE;
CREATE SCHEMA liga_facom;

SET search_path TO liga_facom;

-- ---------------------------------------------------------------------
-- DECISOES GERAIS (valem para todo o script)
--
-- 1) Tipos monetarios e pontuacoes: NUMERIC(p,s), nunca REAL/DOUBLE PRECISION.
--    Float binario nao representa 0,1 ou 0,3 exatamente (0.1+0.2 <> 0.3), e a
--    liga soma e compara centenas de valores como 12,4 = 8,0+3,0+1,2+0,8-0,6.
--    O erro acumulado quebraria o teto do orcamento (C$ 100,00), o desempate
--    do ranking e a conferencia com os pontos da API. NUMERIC e exato.
--
-- 2) Chaves: tabelas vindas da API usam chave substituta (id_*) e guardam o
--    numero da fonte como chave CANDIDATA (id_api UNIQUE NOT NULL). Assim a
--    base nao depende da fonte e a carga usa ON CONFLICT (id_api).
--
-- 3) Valores derivados NAO sao armazenados: pontuacao do atleta na rodada,
--    pontuacao da escalacao, pontuacao acumulada do tecnico, media e preco
--    atual do atleta. Sao calculados por funcoes/visoes (03 e 04). Isso evita
--    inconsistencia; o gatilho 6(d) bloqueia alterar scouts de rodada
--    consolidada.
--
-- 4) Acoes referenciais:
--    ON UPDATE RESTRICT em todas as FKs: nenhuma chave referenciada muda
--    (ids substitutos, numero da rodada e sigla do scout sao imutaveis); se
--    alguem tentar mudar, o banco recusa em vez de propagar sem querer.
--    ON DELETE CASCADE somente quando o filho nao existe sem o pai
--    (dados DO tecnico, itens de uma escalacao, detalhe de scouts).
--    ON DELETE RESTRICT para dados de referencia e historico do futebol
--    (clube, atleta, rodada, partida, posicao...): apagar nao deve levar junto
--    pontuacoes ja consolidadas.
--
-- 5) Enumeracoes do enunciado ficam em CHECK: posicoes (secao 2.2), situacoes
--    (secao 2.2), estados da rodada (2.3), status da escalacao (2.5), esquemas
--    (2.5, formato do nome). Situacao e posicao guardam a grafia da fonte
--    (com acentos: 'Provável', 'Dúvida', 'Técnico') porque a carga faz ON CONFLICT (id_api).
--
-- 6) Preco: o enunciado manda usar como preco inicial o do /atletas/mercado, e
--    15 atletas do mercado custam menos de C$ 1,00 (min. 0,63). Por isso NAO ha
--    CHECK >= 1,00 nas colunas de preco (so > 0); o piso de C$ 1,00 vale para o
--    RESULTADO da valorizacao e e aplicado no procedimento 6(g).
--
-- 7) Ordem de execucao e dependencias circulares: posicao e situacao sao
--    enumeracoes fixas do enunciado e sao semeadas em 02-dados.sql (junto com
--    tipo_scout, vale_para e as 38 rodadas); a carga as atualiza por id_api.
--    Ordem: 01-ddl -> 02-dados -> carga -> 03-programacao -> 04 -> 05.
-- ---------------------------------------------------------------------


-- =====================================================================
-- 1. JOGO: TECNICO, TIME
-- =====================================================================

-- Regra de mapeamento: entidade forte.
CREATE TABLE tecnico (
    id_tecnico     integer GENERATED ALWAYS AS IDENTITY,
    nome           varchar(100) NOT NULL,
    email          varchar(150) NOT NULL,
    apelido        varchar(50)  NOT NULL,
    data_cadastro  date         NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_tecnico        PRIMARY KEY (id_tecnico),
    CONSTRAINT uq_tecnico_email  UNIQUE (email),
    CONSTRAINT ck_tecnico_email  CHECK (email ~ '^[^@[:space:]]+@[^@[:space:]]+$'),
    CONSTRAINT ck_tecnico_nome   CHECK (length(btrim(nome)) > 0),
    CONSTRAINT ck_tecnico_apelido CHECK (length(btrim(apelido)) > 0)
);

-- Regra de mapeamento: entidade forte; relacionamento 1:1 "possui" mapeado
-- como FK UNIQUE NOT NULL (participacao total do time).
CREATE TABLE time_fantasy (
    id_time          integer GENERATED ALWAYS AS IDENTITY,
    id_tecnico       integer       NOT NULL,
    nome             varchar(60)   NOT NULL,
    patrimonio_atual numeric(10,2) NOT NULL DEFAULT 100.00,   -- C$ 100,00 inicial
    CONSTRAINT pk_time            PRIMARY KEY (id_time),
    CONSTRAINT uq_time_tecnico    UNIQUE (id_tecnico),         -- 1:1
    CONSTRAINT ck_time_nome       CHECK (length(btrim(nome)) > 0),
    CONSTRAINT ck_time_patrimonio CHECK (patrimonio_atual >= 0),
    -- CASCADE: o time so existe para o seu tecnico.
    CONSTRAINT fk_time_tecnico FOREIGN KEY (id_tecnico)
        REFERENCES tecnico (id_tecnico) ON DELETE CASCADE ON UPDATE RESTRICT
);


-- =====================================================================
-- 2. FUTEBOL REAL: CLUBE, POSICAO, SITUACAO, ATLETA
-- =====================================================================

-- Entidade forte. id_api = candidata.
-- nome <- campo 'apelido' da fonte (o campo 'nome' da fonte e a sigla de 3 letras,
-- igual a abreviacao). 'Tricolor' repete (FLU e SAO), logo nome NAO e UNIQUE;
-- a abreviacao e que identifica o clube para o usuario. url_escudo <- escudos['60x60'].
CREATE TABLE clube (
    id_clube    integer GENERATED ALWAYS AS IDENTITY,
    id_api      integer      NOT NULL,
    nome        varchar(80)  NOT NULL,
    abreviacao  char(3)      NOT NULL,
    url_escudo  varchar(300),
    CONSTRAINT pk_clube       PRIMARY KEY (id_clube),
    CONSTRAINT uq_clube_api   UNIQUE (id_api),
    CONSTRAINT uq_clube_abrev UNIQUE (abreviacao),
    CONSTRAINT ck_clube_abrev CHECK (abreviacao ~ '^[A-Z]{3}$')
);

-- Entidade forte. As 6 posicoes do Cartola.
CREATE TABLE posicao (
    id_posicao  integer GENERATED ALWAYS AS IDENTITY,
    id_api      integer     NOT NULL,
    nome        varchar(30) NOT NULL,
    abreviacao  varchar(3)  NOT NULL,
    CONSTRAINT pk_posicao       PRIMARY KEY (id_posicao),
    CONSTRAINT uq_posicao_api   UNIQUE (id_api),
    CONSTRAINT uq_posicao_abrev UNIQUE (abreviacao),
    -- As 6 posicoes do enunciado, com abreviacao e nome coerentes entre si.
    CONSTRAINT ck_posicao_dominio CHECK ((abreviacao, nome) IN (
        ('gol','Goleiro'), ('lat','Lateral'), ('zag','Zagueiro'),
        ('mei','Meia'), ('ata','Atacante'), ('tec','Técnico')))
);

-- Entidade forte. provavel, duvida, suspenso, contundido, nulo.
CREATE TABLE situacao (
    id_situacao integer GENERATED ALWAYS AS IDENTITY,
    id_api      integer     NOT NULL,
    nome        varchar(30) NOT NULL,
    CONSTRAINT pk_situacao     PRIMARY KEY (id_situacao),
    CONSTRAINT uq_situacao_api UNIQUE (id_api),
    CONSTRAINT uq_situacao_nome UNIQUE (nome),
    -- As 5 situacoes do enunciado (grafia da fonte). Escalaveis: Provável e Dúvida
    -- (regra verificada no gatilho 6c, sobre atleta_rodada.id_situacao).
    CONSTRAINT ck_situacao_dominio CHECK (nome IN ('Provável','Dúvida','Suspenso','Contundido','Nulo'))
);

-- Entidade forte. Relacionamentos N:1 (joga_como, tem_situacao, pertence)
-- mapeados como FKs NOT NULL (participacao total do atleta, conforme o DER).
-- O tecnico real tambem e um atleta, com posicao 'tec'.
-- preco_atual e media sao derivados (visao 5(a)), nao ficam aqui.
-- Atleta que so aparece em /atletas/pontuados (fora do mercado atual; 19 casos nas
-- rodadas 25-34) entra com: nome_completo = apelido, id_situacao = 'Nulo' (nao
-- escalavel), preco_inicial = 1.00 (a fonte nao informa preco) e id_clube/id_posicao
-- do proprio arquivo de pontuados. Assim a carga nao falha e os NOT NULL se mantem.
CREATE TABLE atleta (
    id_atleta      integer GENERATED ALWAYS AS IDENTITY,
    id_api         integer       NOT NULL,
    nome_completo  varchar(120)  NOT NULL,
    apelido        varchar(60)   NOT NULL,
    preco_inicial  numeric(8,2)  NOT NULL,     -- preco do mercado no momento da carga (pode ser < 1,00)
    id_posicao     integer       NOT NULL,
    id_situacao    integer       NOT NULL,     -- situacao ATUAL
    id_clube       integer       NOT NULL,     -- clube ATUAL (elenco)
    CONSTRAINT pk_atleta       PRIMARY KEY (id_atleta),
    CONSTRAINT uq_atleta_api   UNIQUE (id_api),
    CONSTRAINT ck_atleta_preco CHECK (preco_inicial > 0),
    CONSTRAINT fk_atleta_posicao  FOREIGN KEY (id_posicao)
        REFERENCES posicao (id_posicao)   ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_atleta_situacao FOREIGN KEY (id_situacao)
        REFERENCES situacao (id_situacao) ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_atleta_clube    FOREIGN KEY (id_clube)
        REFERENCES clube (id_clube)       ON DELETE RESTRICT ON UPDATE RESTRICT
);


-- =====================================================================
-- 3. RODADAS E PARTIDAS
-- =====================================================================

-- Entidade forte; chave natural (numero 1..38).
-- estado NULL = rodada ainda nao aberta pelo administrador.
-- A ordem aberta -> fechada -> consolidada e garantida por gatilho (03).
CREATE TABLE rodada (
    numero  smallint    NOT NULL,
    estado  varchar(12),
    CONSTRAINT pk_rodada        PRIMARY KEY (numero),
    CONSTRAINT ck_rodada_numero CHECK (numero BETWEEN 1 AND 38),
    CONSTRAINT ck_rodada_estado CHECK (estado IN ('aberta','fechada','consolidada'))
);
-- "Apenas uma rodada aberta por vez": indice unico parcial (declarativo).
CREATE UNIQUE INDEX uq_rodada_unica_aberta ON rodada ((estado)) WHERE estado = 'aberta';

-- Entidade forte. Relacionamentos tem_partida, mandante e visitante mapeados
-- como FKs NOT NULL (participacao total da partida).
-- ATENCAO (dados reais): partida com valida = false (adiada / jogada fora da janela
-- da rodada) JA VEM com placar preenchido (5 das 100 partidas carregadas). Ela nao
-- conta para o tecnico real (clube "nao jogou na rodada" = 0 ponto); a funcao de
-- pontuacao deve filtrar valida = true, nao apenas placar IS NOT NULL.
-- Em dados reais cada clube aparece em exatamente 1 partida por rodada (valida ou
-- nao); a carga usa (rodada, clube do atleta) para achar a partida do atleta.
-- data_hora: a fonte traz horario de Brasilia sem fuso; carregar como -03:00.
CREATE TABLE partida (
    id_partida          integer GENERATED ALWAYS AS IDENTITY,
    id_api              integer      NOT NULL,
    numero_rodada       smallint     NOT NULL,
    id_clube_mandante   integer      NOT NULL,
    id_clube_visitante  integer      NOT NULL,
    local               varchar(120),
    data_hora           timestamptz,                 -- pode faltar em partida adiada
    placar_mandante     smallint,                    -- NULL ate ser jogada
    placar_visitante    smallint,
    valida              boolean      NOT NULL DEFAULT true,   -- false = adiada
    CONSTRAINT pk_partida     PRIMARY KEY (id_partida),
    CONSTRAINT uq_partida_api UNIQUE (id_api),
    CONSTRAINT ck_partida_clubes_distintos CHECK (id_clube_mandante <> id_clube_visitante),
    CONSTRAINT ck_partida_placar_pos CHECK (
        (placar_mandante IS NULL OR placar_mandante >= 0)
        AND (placar_visitante IS NULL OR placar_visitante >= 0)),
    CONSTRAINT ck_partida_placar_par CHECK ((placar_mandante IS NULL) = (placar_visitante IS NULL)),
    CONSTRAINT fk_partida_rodada FOREIGN KEY (numero_rodada)
        REFERENCES rodada (numero)    ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_partida_mandante FOREIGN KEY (id_clube_mandante)
        REFERENCES clube (id_clube)   ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_partida_visitante FOREIGN KEY (id_clube_visitante)
        REFERENCES clube (id_clube)   ON DELETE RESTRICT ON UPDATE RESTRICT
);


-- =====================================================================
-- 4. HISTORICO POR RODADA (associativa ATLETA x RODADA)
-- =====================================================================

-- Mapeamento da entidade (fraca/associativa) Atleta_rodada: PK composta
-- (atleta, rodada). Guarda o preco do atleta NA rodada (historico de precos),
-- o clube em que estava (transferencias) e a situacao informada.
-- preco = preco em vigor com o mercado aberto; o preco recalculado na
-- consolidacao da rodada r vira o preco da rodada r+1 (procedimento 6g).
-- CICLO DE VIDA (por que preco aceita NULL): a carga insere as linhas das rodadas
-- ja jogadas com o CLUBE REAL daquela rodada (vem de /atletas/pontuados; ha
-- transferencias, ex.: atleta 86757 FLA->SAN, e tecnico que mudou de clube) e
-- NUNCA escreve preco. O preco de uma rodada so existe depois que a anterior e
-- consolidada: o procedimento 6(g) grava o preco novo na linha r+1, e o
-- procedimento de abrir rodada preenche o que faltar (copia o ultimo preco ou usa
-- atleta.preco_inicial na primeira rodada reproduzida), cria as linhas dos atletas
-- sem pontuacao na rodada (clube/situacao atuais do atleta) e recusa abrir se
-- restar preco NULL ou se a rodada anterior nao estiver consolidada.
-- id_situacao: a fonte so informa a situacao do momento (mercado atual); nas
-- rodadas reproduzidas ela e a situacao do snapshot, uma aproximacao a documentar.
CREATE TABLE atleta_rodada (
    id_atleta      integer      NOT NULL,
    numero_rodada  smallint     NOT NULL,
    preco          numeric(8,2),              -- NULL = ainda nao definido (ver abaixo)
    id_clube       integer      NOT NULL,     -- estava_em
    id_situacao    integer      NOT NULL,     -- teve_situacao
    CONSTRAINT pk_atleta_rodada PRIMARY KEY (id_atleta, numero_rodada),
    -- Superchave extra: permite que a escalacao referencie (atleta, rodada, preco)
    -- e assim garanta, sem gatilho, que preco_pago = preco do atleta na rodada.
    CONSTRAINT uq_atleta_rodada_preco UNIQUE (id_atleta, numero_rodada, preco),
    CONSTRAINT ck_atleta_rodada_preco CHECK (preco IS NULL OR preco > 0),
    -- CASCADE: o historico nao existe sem o atleta.
    CONSTRAINT fk_ar_atleta FOREIGN KEY (id_atleta)
        REFERENCES atleta (id_atleta)     ON DELETE CASCADE  ON UPDATE RESTRICT,
    CONSTRAINT fk_ar_rodada FOREIGN KEY (numero_rodada)
        REFERENCES rodada (numero)        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_ar_clube FOREIGN KEY (id_clube)
        REFERENCES clube (id_clube)       ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_ar_situacao FOREIGN KEY (id_situacao)
        REFERENCES situacao (id_situacao) ON DELETE RESTRICT ON UPDATE RESTRICT
);


-- =====================================================================
-- 5. ESTATISTICAS: ATLETA_PARTIDA, TIPO_SCOUT, POSICAO_SCOUT, SCOUT_PARTIDA
-- =====================================================================

-- Regra de mapeamento: relacionamento N:M com atributo -> tabela propria.
-- Se a linha existe, o atleta consta na partida; entrou_em_campo diz se jogou.
-- A pontuacao e derivada (funcao 6a), nao armazenada.
CREATE TABLE atleta_partida (
    id_atleta        integer NOT NULL,
    id_partida       integer NOT NULL,
    entrou_em_campo  boolean NOT NULL,
    CONSTRAINT pk_atleta_partida PRIMARY KEY (id_atleta, id_partida),
    CONSTRAINT fk_atleta_partida_atleta FOREIGN KEY (id_atleta)
        REFERENCES atleta (id_atleta)   ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_atleta_partida_partida FOREIGN KEY (id_partida)
        REFERENCES partida (id_partida) ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- Entidade forte; chave natural = sigla (G, A, FT, ...).
-- Valores em NUMERIC (ver decisao 1). Pode ser negativo.
CREATE TABLE tipo_scout (
    sigla         varchar(2)   NOT NULL,
    descricao     varchar(60)  NOT NULL,
    valor_pontos  numeric(5,2) NOT NULL,
    CONSTRAINT pk_tipo_scout PRIMARY KEY (sigla),
    CONSTRAINT ck_tipo_scout_sigla CHECK (sigla ~ '^[A-Z]{1,2}$'),
    CONSTRAINT ck_tipo_scout_valor CHECK (valor_pontos <> 0)
);

-- N:M tipo_scout x posicao: em quais posicoes cada scout pontua
-- (SG: gol/lat/zag; DE, DP, GS: gol; os demais: gol/lat/zag/mei/ata).
-- Todo scout deve ter ao menos uma linha aqui (populado em 02-dados.sql).
CREATE TABLE posicao_scout (
    sigla       varchar(2) NOT NULL,
    id_posicao  integer    NOT NULL,
    CONSTRAINT pk_posicao_scout PRIMARY KEY (sigla, id_posicao),
    CONSTRAINT fk_posicao_scout_scout FOREIGN KEY (sigla)
        REFERENCES tipo_scout (sigla)     ON DELETE CASCADE  ON UPDATE RESTRICT,
    CONSTRAINT fk_posicao_scout_posicao FOREIGN KEY (id_posicao)
        REFERENCES posicao (id_posicao)   ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- Regra de mapeamento: relacionamento ternario -> tabela com PK composta
-- pelas tres chaves. Referencia atleta_partida: so ha scout de atleta que consta
-- na partida. quantidade > 0 (quantidade zero nao e registrada).
-- A carga IGNORA siglas fora de tipo_scout: a fonte traz 'V' (vitoria) so para
-- tecnicos (74 ocorrencias), mas na liga a pontuacao do tecnico sai do placar.
-- Scout vindo como null na fonte (9 linhas) = nenhuma linha aqui; o atleta
-- continua em atleta_partida. Scouts de quem nao entrou em campo sao guardados (10
-- linhas, so cartoes) mas a funcao 6(a) devolve 0 para eles (secao 2.7).
CREATE TABLE scout_partida (
    id_atleta   integer  NOT NULL,
    id_partida  integer  NOT NULL,
    sigla       varchar(2) NOT NULL,
    quantidade  smallint NOT NULL,
    CONSTRAINT pk_scout_partida PRIMARY KEY (id_atleta, id_partida, sigla),
    CONSTRAINT ck_scout_partida_qtd CHECK (quantidade > 0),
    -- CASCADE: o scout e detalhe da participacao do atleta na partida.
    CONSTRAINT fk_scout_partida_atleta_partida FOREIGN KEY (id_atleta, id_partida)
        REFERENCES atleta_partida (id_atleta, id_partida) ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_scout_partida_scout FOREIGN KEY (sigla)
        REFERENCES tipo_scout (sigla)     ON DELETE RESTRICT ON UPDATE RESTRICT
);


-- =====================================================================
-- 6. ESQUEMAS TATICOS
-- =====================================================================

CREATE TABLE esquema_tatico (
    id_esquema  integer GENERATED ALWAYS AS IDENTITY,
    nome        varchar(7) NOT NULL,                      -- ex.: '4-3-3'
    CONSTRAINT pk_esquema      PRIMARY KEY (id_esquema),
    CONSTRAINT uq_esquema_nome UNIQUE (nome),
    CONSTRAINT ck_esquema_nome CHECK (nome ~ '^[0-9]-[0-9]-[0-9]$')
);

-- N:M esquema x posicao com atributo quantidade.
-- O DER nao exige linha para posicao ausente; para 3-4-3, lateral = 0.
CREATE TABLE esquema_posicao (
    id_esquema  integer  NOT NULL,
    id_posicao  integer  NOT NULL,
    quantidade  smallint NOT NULL,
    CONSTRAINT pk_esquema_posicao PRIMARY KEY (id_esquema, id_posicao),
    CONSTRAINT ck_esquema_posicao_qtd CHECK (quantidade BETWEEN 0 AND 5),
    CONSTRAINT fk_esquema_posicao_esquema FOREIGN KEY (id_esquema)
        REFERENCES esquema_tatico (id_esquema) ON DELETE CASCADE  ON UPDATE RESTRICT,
    CONSTRAINT fk_esquema_posicao_posicao FOREIGN KEY (id_posicao)
        REFERENCES posicao (id_posicao)        ON DELETE RESTRICT ON UPDATE RESTRICT
);


-- =====================================================================
-- 7. ESCALACAO (entidade fraca de TECNICO e RODADA) E ITENS
-- =====================================================================

-- Regra de mapeamento: entidade fraca. PK = (tecnico, rodada) vinda dos dois
-- relacionamentos identificadores => no maximo uma escalacao por tecnico por
-- rodada. Pontuacao e derivada (funcao 6b), nao armazenada.
CREATE TABLE escalacao (
    id_tecnico        integer     NOT NULL,
    numero_rodada     smallint    NOT NULL,
    id_esquema        integer     NOT NULL,
    status            varchar(10) NOT NULL DEFAULT 'edicao',
    data_confirmacao  timestamptz,
    CONSTRAINT pk_escalacao PRIMARY KEY (id_tecnico, numero_rodada),
    CONSTRAINT ck_escalacao_status CHECK (status IN ('edicao','confirmada')),
    -- confirmada <=> tem data de confirmacao
    CONSTRAINT ck_escalacao_confirmacao CHECK ((status = 'confirmada') = (data_confirmacao IS NOT NULL)),
    -- CASCADE: a escalacao pertence ao tecnico.
    CONSTRAINT fk_escalacao_tecnico FOREIGN KEY (id_tecnico)
        REFERENCES tecnico (id_tecnico)  ON DELETE CASCADE  ON UPDATE RESTRICT,
    CONSTRAINT fk_escalacao_rodada FOREIGN KEY (numero_rodada)
        REFERENCES rodada (numero)       ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_escalacao_esquema FOREIGN KEY (id_esquema)
        REFERENCES esquema_tatico (id_esquema) ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- Regra de mapeamento: N:M "escala" com atributos preco_pago e capitao.
-- * PK impede o mesmo atleta duas vezes na mesma escalacao.
-- * A FK composta (atleta, rodada, preco_pago) -> atleta_rodada garante, sem
--   gatilho, que o preco pago e o preco do atleta naquela rodada e que o
--   atleta tem historico nela.
-- * capitao: boolean; "no maximo um" por indice unico parcial abaixo;
--   "exatamente um entre os 11 e nao ser o tecnico real" -> procedimento 6e.
CREATE TABLE escala (
    id_tecnico     integer      NOT NULL,
    numero_rodada  smallint     NOT NULL,
    id_atleta      integer      NOT NULL,
    preco_pago     numeric(8,2) NOT NULL,
    capitao        boolean      NOT NULL DEFAULT false,
    CONSTRAINT pk_escala PRIMARY KEY (id_tecnico, numero_rodada, id_atleta),
    -- CASCADE: os itens somem com a escalacao.
    CONSTRAINT fk_escala_escalacao FOREIGN KEY (id_tecnico, numero_rodada)
        REFERENCES escalacao (id_tecnico, numero_rodada) ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_escala_atleta_rodada FOREIGN KEY (id_atleta, numero_rodada, preco_pago)
        REFERENCES atleta_rodada (id_atleta, numero_rodada, preco) ON DELETE RESTRICT ON UPDATE RESTRICT
);
CREATE UNIQUE INDEX uq_escala_um_capitao ON escala (id_tecnico, numero_rodada) WHERE capitao;


-- =====================================================================
-- 8. HISTORICO DE PATRIMONIO (entidade fraca de TIME e RODADA)
-- =====================================================================

-- patrimonio_final = patrimonio do time ao fim da consolidacao da rodada.
-- Alimenta a consulta 5(i). Gravado pelo procedimento 6g.
CREATE TABLE historico_patrimonio (
    id_time          integer       NOT NULL,
    numero_rodada    smallint      NOT NULL,
    patrimonio_final numeric(10,2) NOT NULL,
    CONSTRAINT pk_hist_patrimonio PRIMARY KEY (id_time, numero_rodada),
    CONSTRAINT ck_hist_patrimonio CHECK (patrimonio_final >= 0),
    CONSTRAINT fk_hp_time FOREIGN KEY (id_time)
        REFERENCES time_fantasy (id_time) ON DELETE CASCADE  ON UPDATE RESTRICT,
    CONSTRAINT fk_hp_rodada FOREIGN KEY (numero_rodada)
        REFERENCES rodada (numero)        ON DELETE RESTRICT ON UPDATE RESTRICT
);


-- =====================================================================
-- 9. LIGAS
-- =====================================================================

-- Entidade forte; dono_de (1:N) mapeado como FK NOT NULL na liga.
CREATE TABLE liga (
    id_liga              integer GENERATED ALWAYS AS IDENTITY,
    id_dono              integer      NOT NULL,
    nome                 varchar(80)  NOT NULL,
    descricao            varchar(300),                    -- opcional
    codigo_convite       varchar(20)  NOT NULL,
    limite_participantes smallint     NOT NULL,
    publica              boolean      NOT NULL DEFAULT true,
    CONSTRAINT pk_liga PRIMARY KEY (id_liga),
    CONSTRAINT uq_liga_codigo UNIQUE (codigo_convite),
    CONSTRAINT ck_liga_nome   CHECK (length(btrim(nome)) > 0),
    CONSTRAINT ck_liga_limite CHECK (limite_participantes >= 1),
    CONSTRAINT ck_liga_codigo CHECK (length(codigo_convite) >= 4),
    -- RESTRICT: nao se apaga um tecnico que ainda e dono de liga.
    CONSTRAINT fk_liga_dono FOREIGN KEY (id_dono)
        REFERENCES tecnico (id_tecnico) ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- N:M participa com atributo data_entrada.
-- O dono entra automaticamente; o limite e a regra de convite estao no 6(f).
CREATE TABLE participa (
    id_liga       integer NOT NULL,
    id_tecnico    integer NOT NULL,
    data_entrada  date    NOT NULL DEFAULT CURRENT_DATE,
    CONSTRAINT pk_participa PRIMARY KEY (id_liga, id_tecnico),   -- nao entra duas vezes
    CONSTRAINT fk_participa_liga FOREIGN KEY (id_liga)
        REFERENCES liga (id_liga)       ON DELETE CASCADE ON UPDATE RESTRICT,
    CONSTRAINT fk_participa_tecnico FOREIGN KEY (id_tecnico)
        REFERENCES tecnico (id_tecnico) ON DELETE CASCADE ON UPDATE RESTRICT
);

