#!/usr/bin/env python3

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path

ESQUEMA_BANCO = "liga_facom"
FUSO_BRASILIA = timezone(timedelta(hours=-3))      
PRECO_FALLBACK = Decimal("1.00")                   # atleta so presente nos pontuados
SITUACAO_FALLBACK = "Nulo"                         
SIGLAS_ENUNCIADO = {"G", "A", "FT", "FD", "FF", "FS", "PS", "DS", "SG", "DE",
                    "DP", "GS", "FC", "I", "CA", "CV", "GC", "PC", "PP"}


class ErroDeCarga(Exception):
    """Erro de dados ou de pre-requisito, com mensagem para o aluno ler."""


# ---------------------------------------------------------------------------
# 1. LEITURA E PREPARO 
# ---------------------------------------------------------------------------
def ler_json(caminho):
    with open(caminho, encoding="utf-8") as f:
        return json.load(f, parse_float=Decimal)


def data_hora(texto):
    """'2026-08-29 18:30:00' (Brasilia, sem fuso) -> datetime com -03:00."""
    if not texto:
        return None
    return datetime.strptime(texto, "%Y-%m-%d %H:%M:%S").replace(tzinfo=FUSO_BRASILIA)


def preparar(pasta, siglas_validas, rodadas_consolidadas=frozenset()):
    """Le a pasta de JSON e devolve um dicionario com as linhas a gravar."""
    pasta = Path(pasta)
    exigidos = [pasta / "atletas_mercado.json", pasta / "esquemas.json"]
    faltando = [str(p) for p in exigidos if not p.exists()]
    if faltando:
        raise ErroDeCarga("Arquivos nao encontrados (rode coletar.py): " + ", ".join(faltando))

    mercado = ler_json(pasta / "atletas_mercado.json")
    esquemas_json = ler_json(pasta / "esquemas.json")
    avisos = []

    posicoes = [(p["id"], p["nome"], p["abreviacao"]) for p in mercado["posicoes"].values()]
    situacoes = [(s["id"], s["nome"]) for s in mercado["status"].values()]
    id_situacao_fallback = next((i for i, n in situacoes if n == SITUACAO_FALLBACK), None)
    if id_situacao_fallback is None:
        raise ErroDeCarga(f"Situacao '{SITUACAO_FALLBACK}' nao veio da fonte.")

    def por_rodada(subpasta, prefixo):
        achados = {}
        for arq in sorted((pasta / subpasta).glob(f"{prefixo}_*.json")):
            dados = ler_json(arq)
            achados[int(dados["rodada"])] = dados
        return achados

    partidas_rod = por_rodada("partidas", "partidas")
    pontuados_rod = por_rodada("atletas_pontuados", "pontuados")
    rodadas = sorted(set(partidas_rod) & set(pontuados_rod))
    for r in sorted(set(partidas_rod) ^ set(pontuados_rod)):
        avisos.append(f"Rodada {r}: falta partidas ou pontuados; ignorada.")
    puladas = [r for r in rodadas if r in rodadas_consolidadas]
    rodadas = [r for r in rodadas if r not in rodadas_consolidadas]
    if puladas:
        avisos.append(f"Rodadas ja consolidadas, puladas: {puladas}")
    if not rodadas:
        avisos.append("Nenhuma rodada nova para carregar (so clubes/atletas/esquemas).")

    # ---- clubes
    clubes = {}
    fontes = [mercado["clubes"]] + [d["clubes"] for d in partidas_rod.values()] \
             + [d["clubes"] for d in pontuados_rod.values()]
    for fonte in fontes:
        for c in fonte.values():
            clubes.setdefault(c["id"], (c["id"], c["apelido"], c["abreviacao"],
                                        c["escudos"]["60x60"]))
    clubes = list(clubes.values())

    # ---- esquemas taticos
    esquemas, exige = [], []
    for e in esquemas_json:
        if sum(e["posicoes"].values()) != 12:
            raise ErroDeCarga(f"Esquema {e['nome']} nao soma 12 posicoes.")
        esquemas.append((e["nome"],))
        for abrev, qtd in e["posicoes"].items():      
            exige.append((e["nome"], abrev, qtd))

    # ---- partidas 
    partidas, partida_do_clube = [], {}
    for r in rodadas:
        for p in partidas_rod[r]["partidas"]:
            partidas.append((p["partida_id"], r, p["clube_casa_id"], p["clube_visitante_id"],
                             p.get("local"), data_hora(p.get("partida_data")),
                             p["placar_oficial_mandante"], p["placar_oficial_visitante"],
                             bool(p["valida"])))
            for clube in (p["clube_casa_id"], p["clube_visitante_id"]):
                if (r, clube) in partida_do_clube:
                    avisos.append(f"Rodada {r}: clube {clube} aparece em mais de uma partida.")
                partida_do_clube[(r, clube)] = p["partida_id"]

    # ---- atletas
    atletas = {}
    for a in mercado["atletas"]:
        atletas[a["atleta_id"]] = (a["atleta_id"], a["nome"], a["apelido"], a["preco_num"],
                                   a["posicao_id"], a["status_id"], a["clube_id"])
    so_pontuados = {}
    for r in rodadas:                                 
        for id_txt, v in pontuados_rod[r]["atletas"].items():
            if int(id_txt) not in atletas:
                so_pontuados[int(id_txt)] = (int(id_txt), v["apelido"], v["apelido"],
                                             PRECO_FALLBACK, v["posicao_id"],
                                             id_situacao_fallback, v["clube_id"])
    atletas.update(so_pontuados)

    # ---- atleta_rodada, atua_em, registra -----------------------------------
    atleta_rodada, atua_em, registra = [], [], []
    ignorados = Counter()
    for r in rodadas:
        for id_txt, v in pontuados_rod[r]["atletas"].items():
            id_atleta = int(id_txt)
            atleta_rodada.append((id_atleta, r, v["clube_id"]))
            partida = partida_do_clube.get((r, v["clube_id"]))
            if partida is None:
                avisos.append(f"Rodada {r}: atleta {id_atleta} sem partida para o clube {v['clube_id']}.")
                continue
            atua_em.append((id_atleta, partida, bool(v["entrou_em_campo"])))
            for sigla, qtd in (v.get("scout") or {}).items():    # scout pode ser null
                if sigla not in siglas_validas:
                    ignorados[sigla] += 1                         # ex.: 'V' (so tecnicos)
                elif int(qtd) > 0:
                    registra.append((id_atleta, partida, sigla, int(qtd)))

    return {
        "rodadas": rodadas, "posicoes": posicoes, "situacoes": situacoes,
        "clubes": clubes, "esquemas": esquemas, "exige": exige,
        "atletas": list(atletas.values()), "n_so_pontuados": len(so_pontuados),
        "partidas": partidas, "atleta_rodada": atleta_rodada, "atua_em": atua_em,
        "registra": registra, "siglas_ignoradas": dict(ignorados), "avisos": avisos,
    }


# ---------------------------------------------------------------------------
# 2. GRAVACAO NO BANCO
# ---------------------------------------------------------------------------
def gravar(cur, d):
    from psycopg2.extras import execute_values

    def lote(sql, linhas, template=None):
        if linhas:
            execute_values(cur, sql, linhas, template=template, page_size=1000)

    def conferir(descricao, esperado, sql, parametros):
        """Os JOIN descartam em silencio linhas cuja FK nao resolve; aqui paramos."""
        cur.execute(sql, parametros)
        encontrado = cur.fetchone()[0]
        if encontrado < esperado:
            raise ErroDeCarga(f"{descricao}: esperava {esperado} linhas, ha {encontrado} "
                              f"(alguma chave estrangeira nao foi resolvida).")

    lote("""INSERT INTO posicao (id_api, nome, abreviacao) VALUES %s
            ON CONFLICT (id_api) DO UPDATE
               SET nome = EXCLUDED.nome, abreviacao = EXCLUDED.abreviacao""", d["posicoes"])

    lote("""INSERT INTO situacao (id_api, nome) VALUES %s
            ON CONFLICT (id_api) DO UPDATE SET nome = EXCLUDED.nome""", d["situacoes"])

    lote("""INSERT INTO clube (id_api, nome, abreviacao, url_escudo) VALUES %s
            ON CONFLICT (id_api) DO UPDATE
               SET nome = EXCLUDED.nome, abreviacao = EXCLUDED.abreviacao,
                   url_escudo = EXCLUDED.url_escudo""", d["clubes"])

    lote("""INSERT INTO esquema_tatico (nome) VALUES %s
            ON CONFLICT (nome) DO NOTHING""", d["esquemas"])

    lote("""INSERT INTO exige (id_esquema, id_posicao, quantidade)
            SELECT e.id_esquema, p.id_posicao, v.qtd::smallint
              FROM (VALUES %s) AS v(nome, abrev, qtd)
              JOIN esquema_tatico e ON e.nome = v.nome::varchar
              JOIN posicao p        ON p.abreviacao = v.abrev::varchar
            ON CONFLICT (id_esquema, id_posicao) DO UPDATE SET quantidade = EXCLUDED.quantidade""",
         d["exige"])
    conferir("exige", len(d["exige"]), "SELECT count(*) FROM exige", ())


    lote("""INSERT INTO atleta (id_api, nome_completo, apelido, preco_inicial,
                                id_posicao, id_situacao, id_clube)
            SELECT v.id_api::integer, v.nome::varchar, v.apelido::varchar, v.preco::numeric(8,2),
                   p.id_posicao, s.id_situacao, c.id_clube
              FROM (VALUES %s) AS v(id_api, nome, apelido, preco, pos_api, sit_api, clube_api)
              JOIN posicao p  ON p.id_api = v.pos_api::integer
              JOIN situacao s ON s.id_api = v.sit_api::integer
              JOIN clube c    ON c.id_api = v.clube_api::integer
            ON CONFLICT (id_api) DO UPDATE
               SET nome_completo = EXCLUDED.nome_completo, apelido = EXCLUDED.apelido,
                   id_posicao = EXCLUDED.id_posicao, id_situacao = EXCLUDED.id_situacao,
                   id_clube = EXCLUDED.id_clube""", d["atletas"])
    conferir("atleta", len(d["atletas"]),
             "SELECT count(*) FROM atleta WHERE id_api = ANY(%s)",
             ([a[0] for a in d["atletas"]],))

    rodadas = d["rodadas"]
    if not rodadas:
        return

    lote("""INSERT INTO partida (id_api, numero_rodada, id_clube_mandante, id_clube_visitante,
                                local, data_hora, placar_mandante, placar_visitante, valida)
            SELECT v.id_api::integer, v.rodada::smallint, cm.id_clube, cv.id_clube,
                   v.loc::varchar, v.dh::timestamptz, v.pm::smallint, v.pv::smallint, v.valida::boolean
              FROM (VALUES %s) AS v(id_api, rodada, mand, vis, loc, dh, pm, pv, valida)
              JOIN clube cm ON cm.id_api = v.mand::integer
              JOIN clube cv ON cv.id_api = v.vis::integer
            ON CONFLICT (id_api) DO UPDATE
               SET local = EXCLUDED.local, data_hora = EXCLUDED.data_hora,
                   placar_mandante = EXCLUDED.placar_mandante,
                   placar_visitante = EXCLUDED.placar_visitante, valida = EXCLUDED.valida""",
         d["partidas"])
    conferir("partida", len(d["partidas"]),
             "SELECT count(*) FROM partida WHERE id_api = ANY(%s)",
             ([p[0] for p in d["partidas"]],))


    lote("""INSERT INTO atleta_rodada (id_atleta, numero_rodada, preco, id_clube, id_situacao)
            SELECT a.id_atleta, v.rodada::smallint, NULL::numeric(8,2), c.id_clube, a.id_situacao
              FROM (VALUES %s) AS v(atl_api, rodada, clube_api)
              JOIN atleta a ON a.id_api = v.atl_api::integer
              JOIN clube c  ON c.id_api = v.clube_api::integer
            ON CONFLICT (id_atleta, numero_rodada) DO UPDATE SET id_clube = EXCLUDED.id_clube""",
         d["atleta_rodada"])
    conferir("atleta_rodada", len(d["atleta_rodada"]),
             "SELECT count(*) FROM atleta_rodada WHERE numero_rodada = ANY(%s)", (rodadas,))

    lote("""INSERT INTO atua_em (id_atleta, id_partida, entrou_em_campo)
            SELECT a.id_atleta, pa.id_partida, v.entrou::boolean
              FROM (VALUES %s) AS v(atl_api, partida_api, entrou)
              JOIN atleta a   ON a.id_api = v.atl_api::integer
              JOIN partida pa ON pa.id_api = v.partida_api::integer
            ON CONFLICT (id_atleta, id_partida) DO UPDATE
               SET entrou_em_campo = EXCLUDED.entrou_em_campo""", d["atua_em"])
    conferir("atua_em", len(d["atua_em"]),
             """SELECT count(*) FROM atua_em ae JOIN partida p ON p.id_partida = ae.id_partida
                 WHERE p.numero_rodada = ANY(%s)""", (rodadas,))

    lote("""INSERT INTO registra (id_atleta, id_partida, sigla, quantidade)
            SELECT a.id_atleta, pa.id_partida, v.sigla::varchar, v.qtd::smallint
              FROM (VALUES %s) AS v(atl_api, partida_api, sigla, qtd)
              JOIN atleta a   ON a.id_api = v.atl_api::integer
              JOIN partida pa ON pa.id_api = v.partida_api::integer
            ON CONFLICT (id_atleta, id_partida, sigla) DO UPDATE
               SET quantidade = EXCLUDED.quantidade""", d["registra"])
    conferir("registra", len(d["registra"]),
             """SELECT count(*) FROM registra r JOIN partida p ON p.id_partida = r.id_partida
                 WHERE p.numero_rodada = ANY(%s)""", (rodadas,))


def verificar_pre_requisitos(cur):
    """Confere o que o 02-dados.sql deveria ter criado; devolve (siglas, consolidadas)."""
    cur.execute("SELECT count(*) FROM rodada")
    if cur.fetchone()[0] != 38:
        raise ErroDeCarga("A tabela rodada nao tem as 38 rodadas. Rode sql/02-dados.sql antes da carga.")
    cur.execute("SELECT sigla FROM tipo_scout")
    siglas = {linha[0] for linha in cur.fetchall()}
    if not siglas:
        raise ErroDeCarga("A tabela tipo_scout esta vazia. Rode sql/02-dados.sql antes da carga.")
    cur.execute("SELECT numero FROM rodada WHERE estado = 'consolidada'")
    return siglas, {linha[0] for linha in cur.fetchall()}


# ---------------------------------------------------------------------------
# 3. PROGRAMA PRINCIPAL
# ---------------------------------------------------------------------------
def relatorio(d):
    print(f"  rodadas carregadas : {d['rodadas']}")
    for chave in ("posicoes", "situacoes", "clubes", "esquemas", "exige", "atletas",
                  "partidas", "atleta_rodada", "atua_em", "registra"):
        print(f"  {chave:<18} : {len(d[chave])}")
    print(f"  atletas so nos pontuados (fallback): {d['n_so_pontuados']}")
    if d["siglas_ignoradas"]:
        print(f"  siglas ignoradas (fora de tipo_scout): {d['siglas_ignoradas']}")
    for aviso in d["avisos"]:
        print(f"  AVISO: {aviso}")


def main():
    ap = argparse.ArgumentParser(description="Carga dos JSON da API do Cartola no PostgreSQL.")
    ap.add_argument("--pasta", default=str(Path(__file__).resolve().parent / "json"))
    ap.add_argument("--host", default=os.environ.get("PGHOST", "localhost"))
    ap.add_argument("--porta", default=os.environ.get("PGPORT", "5432"))
    ap.add_argument("--banco", default=os.environ.get("PGDATABASE", "postgres"))
    ap.add_argument("--usuario", default=os.environ.get("PGUSER", "postgres"))
    ap.add_argument("--senha", default=os.environ.get("PGPASSWORD", ""))
    ap.add_argument("--dry-run", action="store_true", help="le e valida os JSON sem acessar o banco")
    args = ap.parse_args()

    try:
        if args.dry_run:
            print("Dry-run: lendo JSON, sem acessar o banco.")
            relatorio(preparar(args.pasta, SIGLAS_ENUNCIADO))
            return 0

        import psycopg2
        conn = psycopg2.connect(host=args.host, port=args.porta, dbname=args.banco,
                                user=args.usuario, password=args.senha,
                                options=f"-c search_path={ESQUEMA_BANCO}")
        try:
            with conn.cursor() as cur:
                siglas, consolidadas = verificar_pre_requisitos(cur)
                dados = preparar(args.pasta, siglas, consolidadas)
                gravar(cur, dados)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
        print("Carga concluida (transacao confirmada).")
        relatorio(dados)
        return 0
    except ErroDeCarga as e:
        print(f"ERRO: {e}", file=sys.stderr)
        return 1
    except Exception as e:                                  
        print(f"ERRO inesperado ({type(e).__name__}): {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())