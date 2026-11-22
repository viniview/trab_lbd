import os
import sys
import psycopg2
from psycopg2.extras import RealDictCursor


def conectar():
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ.get("PGDATABASE", "lbd"),
        user=os.environ.get("PGUSER", "lbd"),
        password=os.environ.get("PGPASSWORD", "lbd2026"),
        options="-c search_path=liga_facom",
    )


def executar(conn, acao):
    """Executa uma operação de escrita, faz commit ou rollback e exibe erros do banco."""
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            res = acao(cur)
        conn.commit()
        return True, res
    except psycopg2.Error as e:
        conn.rollback()
        msg = (e.diag.message_primary if e.diag and e.diag.message_primary else str(e)).strip()
        print(f"\n[RECUSADO PELO BANCO] {msg}")
        return False, None


def ler_int(prompt, permitir_vazio=False):
    while True:
        val = input(prompt).strip()
        if permitir_vazio and val == "":
            return None
        try:
            return int(val)
        except ValueError:
            print("Digite um número inteiro válido.")


def ler_float(prompt, permitir_vazio=False):
    while True:
        val = input(prompt).strip().replace(",", ".")
        if permitir_vazio and val == "":
            return None
        try:
            return float(val)
        except ValueError:
            print("Digite um valor numérico válido.")


def obter_rodada_aberta(conn):
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute("SELECT numero FROM rodada WHERE estado = 'aberta'")
        row = cur.fetchone()
        return row["numero"] if row else None


# =====================================================================
# (a) TÉCNICO: CADASTRO, SELEÇÃO E LIGAS
# =====================================================================
def cadastrar_tecnico(conn):
    print("\n--- Cadastrar Técnico ---")
    nome = input("Nome completo: ").strip()
    email = input("E-mail: ").strip()
    apelido = input("Apelido: ").strip()
    nome_time = input("Nome do Time Fantasy: ").strip()

    def acao(cur):
        cur.execute(
            """INSERT INTO tecnico (nome, email, apelido)
               VALUES (%s, %s, %s) RETURNING id_tecnico""",
            (nome, email, apelido),
        )
        id_tec = cur.fetchone()["id_tecnico"]
        cur.execute(
            """INSERT INTO time_fantasy (id_tecnico, nome)
               VALUES (%s, %s)""",
            (id_tec, nome_time),
        )
        return id_tec

    ok, id_tec = executar(conn, acao)
    if ok:
        print(f"Técnico cadastrado com sucesso! ID: {id_tec}")
        return id_tec
    return None


def selecionar_tecnico(conn):
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            """SELECT t.id_tecnico, t.apelido, t.nome, tf.nome AS time, tf.patrimonio_atual
                 FROM tecnico t
                 JOIN time_fantasy tf USING (id_tecnico)
                ORDER BY t.id_tecnico"""
        )
        lista = cur.fetchall()

    if not lista:
        print("\nNenhum técnico cadastrado.")
        return None

    print("\n--- Técnicos Cadastrados ---")
    for t in lista:
        print(
            f"[{t['id_tecnico']}] {t['apelido']} ({t['nome']}) | "
            f"Time: {t['time']} | Patrimônio: C$ {t['patrimonio_atual']:.2f}"
        )

    id_esc = ler_int("ID do técnico para usar o sistema (Enter para cancelar): ", permitir_vazio=True)
    if id_esc is None:
        return None
    if any(t["id_tecnico"] == id_esc for t in lista):
        return id_esc
    print("ID inválido.")
    return None



def criar_liga(conn, id_tecnico):
    print("\n--- Criar Liga ---")
    nome = input("Nome da liga: ").strip()
    descricao = input("Descrição (opcional): ").strip() or None
    codigo = input("Código de convite (mín. 4 caracteres): ").strip()
    limite = ler_int("Limite de participantes: ")
    pub_str = input("Liga pública? (s/n) [s]: ").strip().lower()
    publica = pub_str != "n"

    def acao(cur):
        cur.execute(
            """INSERT INTO liga
               (id_dono, nome, descricao, publica, codigo_convite, limite_participantes)
               VALUES (%s, %s, %s, %s, %s, %s)
               RETURNING id_liga""",
            (id_tecnico, nome, descricao, publica, codigo, limite)
        )
        return cur.fetchone()["id_liga"]

    ok, id_liga = executar(conn, acao)

    if ok:
        print(
            f"Liga criada com sucesso! ID: {id_liga} "
            "(você foi adicionado automaticamente)."
        )



def entrar_liga(conn, id_tecnico):
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            """SELECT l.id_liga, l.nome, l.publica, l.limite_participantes,
                      (SELECT count(*) FROM participa p WHERE p.id_liga = l.id_liga) AS inscritos,
                      EXISTS(SELECT 1 FROM participa p WHERE p.id_liga = l.id_liga AND p.id_tecnico = %s) AS ja_participa
                 FROM liga l
                ORDER BY l.id_liga""",
            (id_tecnico,),
        )
        ligas = cur.fetchall()

    print("\n--- Ligas Disponíveis ---")
    for l in ligas:
        tipo = "Pública" if l["publica"] else "Privada"
        status = " [JÁ PARTICIPA]" if l["ja_participa"] else ""
        print(
            f"[{l['id_liga']}] {l['nome']} ({tipo}) - "
            f"{l['inscritos']}/{l['limite_participantes']} participantes{status}"
        )

    id_liga = ler_int("ID da liga para entrar (Enter para voltar): ", permitir_vazio=True)
    if id_liga is None:
        return
    codigo = input("Código de convite (Enter se pública): ").strip() or None

    ok, _ = executar(conn, lambda cur: cur.execute("CALL entrar_na_liga(%s, %s, %s)", (id_tecnico, id_liga, codigo)))
    if ok:
        print("Entrada na liga realizada com sucesso!")


# =====================================================================
# (b) MERCADO E ESCALAÇÃO
# =====================================================================
def consultar_mercado(conn):
    rodada = obter_rodada_aberta(conn)
    if rodada is None:
        print("\nNão há nenhuma rodada aberta no momento.")
        return

    print(f"\n--- Mercado (Rodada {rodada}) | Deixe em branco para ignorar o filtro ---")
    pos = input("Posição (gol, lat, zag, mei, ata, tec): ").strip().lower() or None
    clube = input("Sigla do clube (ex: FLA, PAL, COR): ").strip().upper() or None
    preco_max = ler_float("Preço máximo (C$): ", permitir_vazio=True)

    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            """SELECT id_atleta, apelido, clube, posicao, situacao,
                      preco_atual, media, pontuacao_ultima_rodada
                 FROM v_mercado
                WHERE (%s IS NULL OR posicao = %s)
                  AND (%s IS NULL OR clube = %s)
                  AND (%s IS NULL OR preco_atual <= %s)
                ORDER BY preco_atual DESC, apelido
                LIMIT 40""",
            (pos, pos, clube, clube, preco_max, preco_max),
        )
        atletas = cur.fetchall()

    if not atletas:
        print("Nenhum atleta encontrado com esses filtros.")
        return

    print(f"\n{'ID':<6} {'Apelido':<20} {'Clube':<5} {'Pos':<4} {'Situação':<10} {'Preço':>8} {'Média':>7} {'Últ.':>7}")
    print("-" * 74)
    for a in atletas:
        media = f"{a['media']:.2f}" if a["media"] is not None else "-"
        ult = f"{a['pontuacao_ultima_rodada']:.2f}" if a["pontuacao_ultima_rodada"] is not None else "-"
        print(
            f"{a['id_atleta']:<6} {a['apelido']:<20} {a['clube']:<5} {a['posicao']:<4} "
            f"{a['situacao']:<10} {a['preco_atual']:>8.2f} {media:>7} {ult:>7}"
        )


def exibir_escalacao(conn, id_tecnico, rodada):
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute("SELECT patrimonio_atual FROM time_fantasy WHERE id_tecnico = %s", (id_tecnico,))
        patrimonio = cur.fetchone()["patrimonio_atual"]

        cur.execute(
            """SELECT es.status, eq.id_esquema, eq.nome AS esquema
                 FROM escalacao es
                 JOIN esquema_tatico eq USING (id_esquema)
                WHERE es.id_tecnico = %s AND es.numero_rodada = %s""",
            (id_tecnico, rodada),
        )
        esc = cur.fetchone()

        print(f"\n=== Escalação - Rodada {rodada} | Patrimônio: C$ {patrimonio:.2f} ===")
        if not esc:
            print("Nenhuma escalação iniciada para esta rodada.")
            return

        cur.execute(
            """SELECT p.abreviacao AS pos, x.quantidade AS exigida,
                      (SELECT count(*) FROM escala e JOIN atleta a USING (id_atleta)
                        WHERE e.id_tecnico = %s AND e.numero_rodada = %s
                          AND a.id_posicao = p.id_posicao) AS atual
                 FROM esquema_posicao x
                 JOIN posicao p USING (id_posicao)
                WHERE x.id_esquema = %s
                ORDER BY array_position(ARRAY['gol','lat','zag','mei','ata','tec'], p.abreviacao::text)""",
            (id_tecnico, rodada, esc["id_esquema"]),
        )
        vagas = " | ".join(f"{r['pos'].upper()}: {r['atual']}/{r['exigida']}" for r in cur.fetchall())
        print(f"Esquema: {esc['esquema']} | Status: {esc['status'].upper()} | Vagas -> {vagas}")

        cur.execute(
            """SELECT e.id_atleta, a.apelido, p.abreviacao AS pos, c.abreviacao AS clube,
                      e.preco_pago, e.capitao
                 FROM escala e
                 JOIN atleta a USING (id_atleta)
                 JOIN posicao p USING (id_posicao)
                 JOIN atleta_rodada ar ON ar.id_atleta = e.id_atleta AND ar.numero_rodada = e.numero_rodada
                 JOIN clube c ON c.id_clube = ar.id_clube
                WHERE e.id_tecnico = %s AND e.numero_rodada = %s
                ORDER BY array_position(ARRAY['gol','lat','zag','mei','ata','tec'], p.abreviacao::text), a.apelido""",
            (id_tecnico, rodada),
        )
        itens = cur.fetchall()
        total = sum(i["preco_pago"] for i in itens)
        print(f"Custo atual: C$ {total:.2f} | Saldo restante: C$ {patrimonio - total:.2f}")
        for i in itens:
            cap = " [CAPITÃO]" if i["capitao"] else ""
            print(f"  [{i['id_atleta']}] {i['pos'].upper():<3} | {i['apelido']:<20} ({i['clube']}) - C$ {i['preco_pago']:.2f}{cap}")


def gerenciar_escalacao(conn, id_tecnico):
    rodada = obter_rodada_aberta(conn)
    if rodada is None:
        print("\nNão há nenhuma rodada aberta para escalar.")
        return

    while True:
        exibir_escalacao(conn, id_tecnico, rodada)
        print("\n1. Definir/Alterar esquema tático")
        print("2. Consultar mercado (com filtros)")
        print("3. Incluir atleta")
        print("4. Remover atleta")
        print("5. Definir capitão")
        print("6. Confirmar escalação")
        print("0. Voltar")
        op = input("Opção: ").strip()

        if op == "0":
            break
        elif op == "1":
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                cur.execute("SELECT id_esquema, nome FROM esquema_tatico ORDER BY nome")
                esquemas = cur.fetchall()
            for eq in esquemas:
                print(f"  [{eq['id_esquema']}] {eq['nome']}")
            id_esq = ler_int("ID do esquema: ")

            def acao_esq(cur):
                cur.execute(
                    """INSERT INTO escalacao (id_tecnico, numero_rodada, id_esquema)
                       VALUES (%s, %s, %s)
                       ON CONFLICT (id_tecnico, numero_rodada)
                       DO UPDATE SET id_esquema = EXCLUDED.id_esquema""",
                    (id_tecnico, rodada, id_esq),
                )

            ok, _ = executar(conn, acao_esq)
            if ok:
                print("Esquema atualizado.")
        elif op == "2":
            consultar_mercado(conn)
        
        elif op == "3":
            id_atl = ler_int("ID do atleta para incluir: ")

            def acao_inc(cur):
                cur.execute(
                    """INSERT INTO escala
                       (id_tecnico, numero_rodada, id_atleta, preco_pago)
                       SELECT %s, %s, %s, ar.preco
                         FROM atleta_rodada ar
                        WHERE ar.id_atleta = %s
                          AND ar.numero_rodada = %s
                          AND ar.preco IS NOT NULL""",
                    (id_tecnico, rodada, id_atl, id_atl, rodada)
                )
                return cur.rowcount > 0

            ok, inseriu = executar(conn, acao_inc)

            if ok and inseriu:
                print("Atleta incluído.")
            elif ok:
                print("Atleta não encontrado ou sem preço definido nesta rodada.")

        elif op == "4":
            id_atl = ler_int("ID do atleta para remover: ")

            def acao_rem(cur):
                cur.execute(
                    """DELETE FROM escala
                       WHERE id_tecnico = %s
                         AND numero_rodada = %s
                         AND id_atleta = %s""",
                    (id_tecnico, rodada, id_atl)
                )
                return cur.rowcount > 0

            ok, removeu = executar(conn, acao_rem)

            if ok and removeu:
                print("Atleta removido.")
            elif ok:
                print("Atleta não encontrado na escalação.")


        elif op == "5":
            id_atl = ler_int("ID do atleta para ser capitão: ")
            ok, _ = executar(conn, lambda cur: cur.execute("CALL definir_capitao(%s, %s, %s)", (id_tecnico, rodada, id_atl)))
            if ok:
                print("Capitão definido.")
        elif op == "6":
            ok, _ = executar(conn, lambda cur: cur.execute("CALL confirmar_escalacao(%s, %s)", (id_tecnico, rodada)))
            if ok:
                print("Escalação confirmada com sucesso!")


# =====================================================================
# (c) RANKING DA LIGA
# =====================================================================
def consultar_ranking(conn, id_tecnico):
    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            """SELECT l.id_liga, l.nome
                 FROM participa p
                 JOIN liga l USING (id_liga)
                WHERE p.id_tecnico = %s
                ORDER BY l.id_liga""",
            (id_tecnico,),
        )
        ligas = cur.fetchall()

    if not ligas:
        print("\nVocê ainda não participa de nenhuma liga.")
        return

    print("\n--- Suas Ligas ---")
    for l in ligas:
        print(f"[{l['id_liga']}] {l['nome']}")

    id_liga = ler_int("ID da liga: ")
    tipo = input("Ranking [1] Acumulado ou [2] Por Rodada? ").strip()

    with conn.cursor(cursor_factory=RealDictCursor) as cur:
        if tipo == "2":
            rod = ler_int("Número da rodada consolidada: ")
            cur.execute(
                """SELECT posicao, apelido, pontuacao
                     FROM v_ranking_rodada
                    WHERE id_liga = %s AND numero_rodada = %s
                    ORDER BY posicao, apelido""",
                (id_liga, rod),
            )
            rows = cur.fetchall()
            if not rows:
                print("Sem dados para esta rodada (verifique se ela já foi consolidada).")
                return
            print(f"\n--- Ranking Rodada {rod} ---")
            for r in rows:
                print(f"{r['posicao']}º | {r['apelido']:<20} | {r['pontuacao']:.2f} pts")
        else:
            cur.execute(
                """SELECT posicao, apelido, time, pontuacao_acumulada
                     FROM v_ranking
                    WHERE id_liga = %s
                    ORDER BY posicao, apelido""",
                (id_liga,),
            )
            rows = cur.fetchall()
            print("\n--- Ranking Acumulado ---")
            for r in rows:
                print(f"{r['posicao']}º | {r['apelido']:<20} ({r['time']}) | {r['pontuacao_acumulada']:.2f} pts")


# =====================================================================
# (d) ADMINISTRADOR
# =====================================================================
def menu_admin(conn):
    while True:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                """SELECT numero, estado FROM rodada
                    WHERE estado IS NOT NULL
                    ORDER BY numero"""
            )
            ativas = cur.fetchall()

        print("\n=== Painel do Administrador ===")
        if ativas:
            resumo = ", ".join(f"R{r['numero']}:{r['estado']}" for r in ativas[-5:])
            print(f"Últimas rodadas com estado: {resumo}")
        else:
            print("Nenhuma rodada aberta ou consolidada ainda.")

        print("1. Abrir rodada")
        print("2. Fechar mercado da rodada")
        print("3. Consolidar rodada")
        print("0. Voltar")
        op = input("Opção: ").strip()

        if op == "0":
            break
        elif op == "1":
            rod = ler_int("Número da rodada a abrir: ")
            ok, _ = executar(conn, lambda cur: cur.execute("CALL abrir_rodada(%s)", (rod,)))
            if ok:
                print(f"Rodada {rod} aberta com sucesso!")
        elif op == "2":
            rod = ler_int("Número da rodada para fechar o mercado: ")
            ok, _ = executar(conn, lambda cur: cur.execute("CALL fechar_mercado(%s)", (rod,)))
            if ok:
                print(f"Mercado da rodada {rod} fechado!")
        elif op == "3":
            rod = ler_int("Número da rodada para consolidar: ")
            ok, _ = executar(conn, lambda cur: cur.execute("CALL consolidar_rodada(%s)", (rod,)))
            if ok:
                print(f"Rodada {rod} consolidada! Pontuações e patrimônios atualizados.")


# =====================================================================
# MENU PRINCIPAL
# =====================================================================
def main():
    try:
        conn = conectar()
    except psycopg2.Error as e:
        print(f"Erro ao conectar ao banco: {e}", file=sys.stderr)
        sys.exit(1)

    id_tecnico = None
    try:
        while True:
            with conn.cursor(cursor_factory=RealDictCursor) as cur:
                if id_tecnico is not None:
                    cur.execute(
                        """SELECT t.apelido, tf.nome AS time, tf.patrimonio_atual
                             FROM tecnico t JOIN time_fantasy tf USING (id_tecnico)
                            WHERE t.id_tecnico = %s""",
                        (id_tecnico,),
                    )
                    tec_atual = cur.fetchone()
                else:
                    tec_atual = None

            rod_aberta = obter_rodada_aberta(conn)
            print("\n==========================================")
            print("          LIGA FACOM FANTASY")
            print("==========================================")
            print(f"Rodada aberta: {rod_aberta if rod_aberta else 'Nenhuma'}")
            if tec_atual:
                print(
                    f"Técnico ativo: {tec_atual['apelido']} | "
                    f"Time: {tec_atual['time']} | C$ {tec_atual['patrimonio_atual']:.2f}"
                )
            else:
                print("Técnico ativo: Nenhum selecionado")

            print("\n1. Cadastrar novo técnico")
            print("2. Escolher técnico ativo")
            print("3. Criar liga")
            print("4. Entrar em liga")
            print("5. Consultar mercado (rodada aberta)")
            print("6. Montar / Confirmar escalação")
            print("7. Ver ranking de liga (rodada / acumulado)")
            print("8. Modo Administrador (abrir / fechar / consolidar rodada)")
            print("0. Sair")

            op = input("Escolha uma opção: ").strip()
            if op == "0":
                break
            elif op == "1":
                novo_id = cadastrar_tecnico(conn)
                if novo_id:
                    id_tecnico = novo_id
            elif op == "2":
                escolhido = selecionar_tecnico(conn)
                if escolhido is not None:
                    id_tecnico = escolhido
            elif op in {"3", "4", "6", "7"} and id_tecnico is None:
                print("\nSelecione ou cadastre um técnico primeiro (opções 1 ou 2).")
            elif op == "3":
                criar_liga(conn, id_tecnico)
            elif op == "4":
                entrar_liga(conn, id_tecnico)
            elif op == "5":
                consultar_mercado(conn)
            elif op == "6":
                gerenciar_escalacao(conn, id_tecnico)
            elif op == "7":
                consultar_ranking(conn, id_tecnico)
            elif op == "8":
                menu_admin(conn)
            else:
                print("Opção inválida.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()