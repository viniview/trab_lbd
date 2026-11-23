# trab_lbd
Trabalho de Laboratório de Banco de Dados

João Vitor Terres - 202519060465

Saulo Emanuel Borba - 202519060015
# Liga FACOM Fantasy


## Pré-requisitos

- Docker instalado
- Python 3.10 ou superior (programa de carga e aplicação)

## 1. Subir o banco

O banco roda num container com a imagem oficial `postgres:18`, usuário `lbd`, senha `lbd2026` e banco `lbd`.

```
docker run -d --name lbd-postgres -e POSTGRES_USER=lbd -e POSTGRES_PASSWORD=lbd2026 -e POSTGRES_DB=lbd -p 5432:5432 -v pgdata:/var/lib/postgresql postgres:18
```

Para abrir o `psql` dentro do container:

```
docker exec -it lbd-postgres psql -U lbd -d lbd
```

## 2. Criar o esquema e os dados

Os scripts SQL rodam **nesta ordem**, cada um sem erros num banco vazio. O `-v ON_ERROR_STOP=1` faz o `psql` parar no primeiro erro, em vez de seguir executando o resto.

| Ordem | Arquivo | O que faz |
|---|---|---|
| 1 | `sql/01-ddl.sql` | Cria o esquema `liga_facom` e todas as tabelas |
| 2 | `sql/02-dados.sql` | Rodadas, posições, situações, tipos de scout, técnicos, ligas e participações |
| 3 | **carga da API** (seção 3) | Clubes, atletas, esquemas, partidas e scouts |
| 4 | `sql/03-programacao.sql` | Funções, gatilhos e procedimentos |
| 5 | `sql/04-consultas.sql` | Visões e consultas |


```
docker exec -i lbd-postgres psql -U lbd -d lbd -v ON_ERROR_STOP=1 < sql/01-ddl.sql
docker exec -i lbd-postgres psql -U lbd -d lbd -v ON_ERROR_STOP=1 < sql/02-dados.sql
```

Pare aqui e faça a carga da seção 3. Depois, continue:

```
docker exec -i lbd-postgres psql -U lbd -d lbd -v ON_ERROR_STOP=1 < sql/03-programacao.sql
docker exec -i lbd-postgres psql -U lbd -d lbd -v ON_ERROR_STOP=1 < sql/04-consultas.sql
docker exec -i lbd-postgres psql -U lbd -d lbd -v ON_ERROR_STOP=1 < sql/05-seguranca-indices.sql
```

## 3. Carga dos dados da API

Os dados do Brasileirão 2026 vêm da API pública do Cartola (`https://api.cartola.globo.com`). Eles já estão salvos em `carga/json/`, e **o programa de carga lê somente esses arquivos**, então a API não precisa estar no ar.

Instale a dependência (uma vez) e informe a conexão com o banco por variáveis de ambiente:

```
python3 -m venv .venv
source .venv/bin/activate.fish
pip install -r carga/requirements.txt

export PGHOST=localhost PGPORT=5432 PGDATABASE=lbd PGUSER=lbd PGPASSWORD=lbd2026
```

## Rodar a aplicacao
´´´
source .venv/bin/activate
export PGHOST=localhost PGPORT=5432 PGDATABASE=lbd PGUSER=lbd PGPASSWORD=lbd2026
python3 app/main.py
´´´
## Documentação

- `docs/der.drawio.png`: diagrama entidade-relacionamento.
- `docs/mao_rel.jpeg`: mapeamento relacional
