import argparse
import json
import sys
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

BASE_URL = "https://api.cartola.globo.com"
CABECALHOS = {
    "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                   "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"),
    "Accept": "application/json",
}
PAUSA_SEGUNDOS = 1.1
TENTATIVAS = 3
RODADAS_MINIMAS = 10          # o enunciado pede scouts de pelo menos 10 rodadas


def baixar(endpoint):
    """GET no endpoint, com algumas tentativas; devolve o JSON ja convertido."""
    url = BASE_URL + endpoint
    ultimo_erro = None
    for tentativa in range(1, TENTATIVAS + 1):
        try:
            with urlopen(Request(url, headers=CABECALHOS), timeout=20) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"HTTP {resp.status}")
                return json.loads(resp.read().decode("utf-8"))
        except (HTTPError, URLError, RuntimeError, json.JSONDecodeError, TimeoutError) as erro:
            ultimo_erro = erro
            print(f"   tentativa {tentativa}/{TENTATIVAS} falhou em {endpoint}: {erro}")
            time.sleep(PAUSA_SEGUNDOS * tentativa)
    raise RuntimeError(f"Nao foi possivel baixar {url}: {ultimo_erro}")


def validar(dados, chaves, endpoint):
    """Evita salvar uma pagina de erro como se fosse dado."""
    if not isinstance(dados, dict) or not all(c in dados for c in chaves):
        raise RuntimeError(f"Resposta inesperada de {endpoint} (faltam chaves {chaves}).")


def coletar(endpoint, destino, chaves, forcar):
    if destino.exists() and not forcar:
        print(f"ja existe  {destino.name}")
        with destino.open(encoding="utf-8") as f:
            return json.load(f)
    dados = baixar(endpoint)
    if chaves:
        validar(dados, chaves, endpoint)
    destino.parent.mkdir(parents=True, exist_ok=True)
    with destino.open("w", encoding="utf-8") as f:
        json.dump(dados, f, ensure_ascii=False, indent=2)
    print(f"salvo      {destino.name}")
    time.sleep(PAUSA_SEGUNDOS)
    return dados


def main():
    ap = argparse.ArgumentParser(description="Coleta dados da API do Cartola e salva em JSON.")
    ap.add_argument("--pasta", default=str(Path(__file__).resolve().parent / "json"))
    ap.add_argument("--de", type=int, help="primeira rodada (padrao: ultima jogada - 9)")
    ap.add_argument("--ate", type=int, help="ultima rodada (padrao: rodada atual - 1)")
    ap.add_argument("--forcar", action="store_true", help="baixa de novo arquivos que ja existem")
    args = ap.parse_args()
    pasta = Path(args.pasta)

    falhas = []
    try:
        status = coletar("/mercado/status", pasta / "mercado_status.json", ["rodada_atual"], args.forcar)
        coletar("/atletas/mercado", pasta / "atletas_mercado.json",
                ["atletas", "clubes", "posicoes", "status"], args.forcar)
        coletar("/esquemas", pasta / "esquemas.json", None, args.forcar)
    except RuntimeError as erro:
        print(f"ERRO: {erro}\nSe a API estiver fora do ar por tempo indeterminado, "
              "o enunciado manda gerar dados sinteticos.", file=sys.stderr)
        return 1

    ultima = args.ate if args.ate else int(status["rodada_atual"]) - 1   # ultima rodada ja jogada
    primeira = args.de if args.de else max(1, ultima - RODADAS_MINIMAS + 1)
    print(f"Rodadas: {primeira} a {ultima}")

    for rodada in range(primeira, ultima + 1):
        try:
            coletar(f"/partidas/{rodada}", pasta / "partidas" / f"partidas_{rodada:02d}.json",
                    ["partidas", "rodada"], args.forcar)
            coletar(f"/atletas/pontuados/{rodada}",
                    pasta / "atletas_pontuados" / f"pontuados_{rodada:02d}.json",
                    ["atletas", "rodada"], args.forcar)
        except RuntimeError as erro:
            print(f"ERRO na rodada {rodada}: {erro}", file=sys.stderr)
            falhas.append(rodada)

    if falhas:
        print(f"Rodadas com falha: {falhas}. Rode de novo (os ja salvos sao pulados).", file=sys.stderr)
        return 1
    print("Coleta concluida.")
    return 0


if __name__ == "__main__":
    sys.exit(main())