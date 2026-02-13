#!/usr/bin/env python3
from __future__ import annotations

import os
import sqlite3
import subprocess
import time
import secrets
from dataclasses import dataclass
from typing import List, Optional, Dict, Tuple

import psutil
from rich.console import Console
from rich.table import Table
from rich.panel import Panel
from rich.prompt import Prompt, Confirm
from rich.live import Live

APP_DIR = "/opt/interfone"
DATA_DIR = "/opt/interfone/data"
DB_PATH = os.path.join(DATA_DIR, "interfone.db")

PJSIP_USERS = "/etc/asterisk/pjsip_users.conf"
EXT_USERS = "/etc/asterisk/extensions_users.conf"

DEFAULT_RING_SECONDS = 20

console = Console()


def sh(cmd: List[str], timeout: int = 10) -> Tuple[int, str]:
    """Run shell command and return (rc, output)."""
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip()
    except Exception as e:
        return 1, str(e)


def asterisk_rx(command: str, timeout: int = 10) -> Tuple[int, str]:
    return sh(["asterisk", "-rx", command], timeout=timeout)


def asterisk_online() -> bool:
    rc, _ = asterisk_rx("core show version", timeout=5)
    return rc == 0


def uptime_str() -> str:
    try:
        with open("/proc/uptime", "r", encoding="utf-8") as f:
            sec = float(f.read().split()[0])
        m, s = divmod(int(sec), 60)
        h, m = divmod(m, 60)
        d, h = divmod(h, 24)
        if d > 0:
            return f"{d}d {h}h {m}m"
        if h > 0:
            return f"{h}h {m}m {s}s"
        return f"{m}m {s}s"
    except Exception:
        return "N/A"


def ram_str() -> str:
    vm = psutil.virtual_memory()
    used = int(vm.used / (1024 * 1024))
    total = int(vm.total / (1024 * 1024))
    return f"{used}MB/{total}MB"


def ensure_db():
    os.makedirs(DATA_DIR, exist_ok=True)
    with sqlite3.connect(DB_PATH) as con:
        cur = con.cursor()
        cur.execute("""
        CREATE TABLE IF NOT EXISTS apartments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            ext TEXT NOT NULL UNIQUE,
            strategy TEXT NOT NULL DEFAULT 'sequential',
            ring_seconds INTEGER NOT NULL DEFAULT 20,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
        )
        """)
        cur.execute("""
        CREATE TABLE IF NOT EXISTS residents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ap_id INTEGER NOT NULL,
            name TEXT NOT NULL,
            ext TEXT NOT NULL UNIQUE,
            secret TEXT NOT NULL,
            created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
            FOREIGN KEY(ap_id) REFERENCES apartments(id) ON DELETE CASCADE
        )
        """)
        con.commit()


@dataclass
class Apartment:
    id: int
    name: str
    ext: str
    strategy: str
    ring_seconds: int


@dataclass
class Resident:
    id: int
    ap_id: int
    name: str
    ext: str
    secret: str


def db() -> sqlite3.Connection:
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


def list_apartments() -> List[Apartment]:
    with db() as con:
        rows = con.execute("SELECT * FROM apartments ORDER BY CAST(ext AS INTEGER) ASC, ext ASC").fetchall()
    return [Apartment(int(r["id"]), r["name"], r["ext"], r["strategy"], int(r["ring_seconds"])) for r in rows]


def count_residents_by_ap() -> Dict[int, int]:
    with db() as con:
        rows = con.execute("SELECT ap_id, COUNT(*) AS c FROM residents GROUP BY ap_id").fetchall()
    return {int(r["ap_id"]): int(r["c"]) for r in rows}


def list_residents(ap_id: int) -> List[Resident]:
    with db() as con:
        rows = con.execute("SELECT * FROM residents WHERE ap_id=? ORDER BY CAST(ext AS INTEGER) ASC, ext ASC", (ap_id,)).fetchall()
    return [Resident(int(r["id"]), int(r["ap_id"]), r["name"], r["ext"], r["secret"]) for r in rows]


def find_ap_by_ext(ext: str) -> Optional[Apartment]:
    with db() as con:
        r = con.execute("SELECT * FROM apartments WHERE ext=?", (ext,)).fetchone()
    if not r:
        return None
    return Apartment(int(r["id"]), r["name"], r["ext"], r["strategy"], int(r["ring_seconds"]))


def create_ap(name: str, ext: str, strategy: str, ring_seconds: int) -> None:
    with db() as con:
        con.execute(
            "INSERT INTO apartments (name, ext, strategy, ring_seconds) VALUES (?,?,?,?)",
            (name, ext, strategy, ring_seconds),
        )
        con.commit()


def remove_ap(ap_id: int) -> None:
    with db() as con:
        con.execute("DELETE FROM apartments WHERE id=?", (ap_id,))
        con.commit()


def create_resident(ap_id: int, name: str, ext: str, secret: str) -> None:
    with db() as con:
        con.execute(
            "INSERT INTO residents (ap_id, name, ext, secret) VALUES (?,?,?,?)",
            (ap_id, name, ext, secret),
        )
        con.commit()


def remove_resident(resident_id: int) -> None:
    with db() as con:
        con.execute("DELETE FROM residents WHERE id=?", (resident_id,))
        con.commit()


def random_secret(length: int = 14) -> str:
    alphabet = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def parse_contacts() -> Dict[str, str]:
    """
    Return map ext -> status string (Avail/Unavail/Unknown)
    Based on `pjsip show contacts`.
    """
    rc, out = asterisk_rx("pjsip show contacts", timeout=10)
    if rc != 0 or not out:
        return {}
    status = {}
    for line in out.splitlines():
        # Common format contains:  <AOR/contact> ... Avail/Unavail
        # Example:  1011/sip:1011@1.2.3.4:5060  Avail  32.123
        parts = line.strip().split()
        if not parts:
            continue
        head = parts[0]
        if "/" not in head:
            continue
        aor = head.split("/")[0]
        # find 'Avail' or 'Unavail' token
        st = None
        for tok in parts:
            if tok in ("Avail", "Unavail", "Unknown"):
                st = tok
                break
        if st:
            status[aor] = st
    return status


def parse_busy_channels() -> Dict[str, int]:
    """
    Return map ext -> number of active channels involving PJSIP/ext-
    """
    rc, out = asterisk_rx("core show channels concise", timeout=10)
    if rc != 0 or not out:
        return {}
    busy = {}
    for line in out.splitlines():
        # concise format contains channel name like: PJSIP/1011-0000000a!...
        if "PJSIP/" not in line:
            continue
        ch = line.split("!")[0]
        if ch.startswith("PJSIP/"):
            rest = ch[len("PJSIP/"):]
            ext = rest.split("-")[0]
            busy[ext] = busy.get(ext, 0) + 1
    return busy


def header_panel() -> Panel:
    ast = "ONLINE" if asterisk_online() else "OFFLINE"
    title = "INTERFONE TACTICAL"
    body = f"ASTERISK: {ast}    RAM: {ram_str()}    UPTIME: {uptime_str()}"
    return Panel(body, title=title, expand=True)


def choose_ap_interactive() -> Optional[Apartment]:
    aps = list_apartments()
    if not aps:
        console.print("[yellow]Nenhum AP cadastrado. Crie um AP primeiro.[/yellow]")
        return None

    counts = count_residents_by_ap()
    contacts = parse_contacts()
    busy = parse_busy_channels()

    table = Table(title="Selecionar AP para adicionar morador", show_lines=False)
    table.add_column("#", justify="right")
    table.add_column("AP / EXT", justify="left")
    table.add_column("Estratégia", justify="left")
    table.add_column("Moradores", justify="right")
    table.add_column("Online", justify="right")
    table.add_column("Busy", justify="right")

    for i, ap in enumerate(aps, start=1):
        res = list_residents(ap.id)
        online_count = sum(1 for r in res if contacts.get(r.ext) == "Avail")
        busy_count = sum(1 for r in res if busy.get(r.ext, 0) > 0)
        table.add_row(
            str(i),
            f"{ap.name} / {ap.ext}",
            ap.strategy,
            str(counts.get(ap.id, 0)),
            str(online_count),
            str(busy_count),
        )

    console.print(table)
    console.print("Digite o número (#) ou EXT (ex: 101). Enter cancela")

    ans = Prompt.ask("AP", default="")
    ans = ans.strip()
    if ans == "":
        return None

    # number index
    if ans.isdigit():
        idx = int(ans)
        if 1 <= idx <= len(aps):
            return aps[idx - 1]

    # ext
    ap = find_ap_by_ext(ans)
    if ap:
        return ap

    console.print("[red]AP inválido.[/red]")
    return None


def generate_pjsip_users() -> str:
    aps = list_apartments()
    lines = []
    lines.append("; =====================================")
    lines.append("; GERADO PELO INTERFONE TACTICAL")
    lines.append("; Arquivo: pjsip_users.conf")
    lines.append("; NÃO EDITE MANUALMENTE")
    lines.append("; =====================================")
    lines.append("")

    for ap in aps:
        residents = list_residents(ap.id)
        for r in residents:
            # Repetir [ext] com type diferentes é padrão em pjsip.conf.sample
            lines += [
                f"; --- {ap.ext} / {ap.name} :: {r.ext} / {r.name}",
                f"[{r.ext}]",
                "type=auth",
                "auth_type=userpass",
                f"username={r.ext}",
                f"password={r.secret}",
                "",
                f"[{r.ext}]",
                "type=aor",
                "max_contacts=1",
                "remove_existing=yes",
                "qualify_frequency=30",
                "",
                f"[{r.ext}]",
                "type=endpoint",
                "transport=transport-udp",
                "context=interfone-ctx",
                "disallow=all",
                "allow=ulaw,alaw,opus",
                "direct_media=no",
                "rtp_symmetric=yes",
                "force_rport=yes",
                "rewrite_contact=yes",
                f"aors={r.ext}",
                f"auth={r.ext}",
                f'callerid="{r.name}" <{r.ext}>',
                "",
            ]
    return "\n".join(lines).strip() + "\n"


def generate_extensions_users() -> str:
    aps = list_apartments()
    lines = []
    lines.append("; =====================================")
    lines.append("; GERADO PELO INTERFONE TACTICAL")
    lines.append("; Arquivo: extensions_users.conf")
    lines.append("; NÃO EDITE MANUALMENTE")
    lines.append("; =====================================")
    lines.append("")

    # Para cada AP: ramal do AP chama a estratégia
    for ap in aps:
        residents = list_residents(ap.id)

        lines.append(f"; ===== AP {ap.ext} - {ap.name} (strategy={ap.strategy}) =====")
        lines.append(f"exten => {ap.ext},1,NoOp(INTERFONE AP {ap.ext} strategy={ap.strategy})")

        if not residents:
            lines.append(" same => n,Playback(vm-nobodyavail)")
            lines.append(" same => n,Hangup()")
            lines.append("")
            continue

        ring_total = max(5, int(ap.ring_seconds or DEFAULT_RING_SECONDS))

        if ap.strategy == "parallel":
            targets = "&".join([f"PJSIP/{r.ext}" for r in residents])
            lines.append(f" same => n,Dial({targets},{ring_total})")
            lines.append(" same => n,Hangup()")
            lines.append("")
        else:
            # sequential (divide tempo)
            per = max(5, ring_total // max(1, len(residents)))
            for idx, r in enumerate(residents, start=1):
                lines.append(f" same => n,NoOp(Tentativa {idx}/{len(residents)} -> {r.ext} {r.name})")
                lines.append(f" same => n,Dial(PJSIP/{r.ext},{per})")
                lines.append(' same => n,GotoIf($["${DIALSTATUS}"="ANSWER"]?done)')
            lines.append(" same => n,Playback(vm-nobodyavail)")
            lines.append(" same => n,Hangup()")
            lines.append(" same => n(done),Hangup()")
            lines.append("")

    # Ramal direto por morador (opcional, útil)
    lines.append("; ===== RAMAIS DIRETOS (por morador) =====")
    for ap in aps:
        residents = list_residents(ap.id)
        for r in residents:
            lines.append(f"exten => {r.ext},1,NoOp(INTERFONE MORADOR {r.ext} ({r.name}) AP {ap.ext})")
            lines.append(f" same => n,Dial(PJSIP/{r.ext},{max(5, int(ap.ring_seconds or DEFAULT_RING_SECONDS))})")
            lines.append(" same => n,Hangup()")
            lines.append("")
    return "\n".join(lines).strip() + "\n"


def sync_asterisk() -> None:
    pjsip = generate_pjsip_users()
    ext = generate_extensions_users()

    # escreve arquivos
    with open(PJSIP_USERS, "w", encoding="utf-8") as f:
        f.write(pjsip)
    with open(EXT_USERS, "w", encoding="utf-8") as f:
        f.write(ext)

    # reload
    asterisk_rx("pjsip reload", timeout=15)
    asterisk_rx("dialplan reload", timeout=15)
    asterisk_rx("core reload", timeout=15)


def dashboard_table() -> Table:
    aps = list_apartments()
    counts = count_residents_by_ap()
    contacts = parse_contacts()
    busy = parse_busy_channels()

    t = Table(title="Dashboard tático (live)")
    t.add_column("AP / EXT", justify="left")
    t.add_column("Estratégia", justify="left")
    t.add_column("Moradores", justify="right")
    t.add_column("Online", justify="right")
    t.add_column("Busy", justify="right")

    for ap in aps:
        res = list_residents(ap.id)
        online_count = sum(1 for r in res if contacts.get(r.ext) == "Avail")
        busy_count = sum(1 for r in res if busy.get(r.ext, 0) > 0)
        t.add_row(
            f"{ap.name} / {ap.ext}",
            ap.strategy,
            str(counts.get(ap.id, 0)),
            str(online_count),
            str(busy_count),
        )
    return t


def dashboard_live():
    if not asterisk_online():
        console.print("[red]Asterisk OFFLINE. Verifique: systemctl status asterisk[/red]")
        return

    console.print("[cyan]Pressione CTRL+C para sair do live.[/cyan]")
    try:
        with Live(console=console, refresh_per_second=1) as live:
            while True:
                live.update(Panel(dashboard_table(), title="INTERFONE TACTICAL", expand=True))
                time.sleep(1)
    except KeyboardInterrupt:
        return


def create_ap_flow():
    console.print(Panel(
        "Estratégias:\n"
        "- [bold]sequential[/bold]: chama um por um (cascata)\n"
        "- [bold]parallel[/bold]: chama todos ao mesmo tempo (ringall)\n",
        title="Criar AP (unidade)"
    ))
    name = Prompt.ask("Nome do AP (ex: Bloco A Ap 101)")
    ext = Prompt.ask("Ramal do AP (ex: 101)").strip()
    strategy = Prompt.ask("Estratégia", choices=["sequential", "parallel"], default="sequential")
    ring = int(Prompt.ask("Tempo total de toque (segundos)", default=str(DEFAULT_RING_SECONDS)))

    if find_ap_by_ext(ext):
        console.print("[red]Já existe um AP com esse ramal.[/red]")
        return
    create_ap(name=name, ext=ext, strategy=strategy, ring_seconds=ring)
    console.print("[green]AP criado![/green]")


def create_resident_flow():
    ap = choose_ap_interactive()
    if not ap:
        return

    console.print(Panel(
        f"AP selecionado: [bold]{ap.name}[/bold] (ramal {ap.ext})\n"
        "Dica: use ramais por pessoa (ex: 1011, 1012...).",
        title="Criar morador"
    ))

    name = Prompt.ask("Nome do morador")
    ext = Prompt.ask("Ramal SIP do morador (ex: 1011)").strip()

    with db() as con:
        exists = con.execute("SELECT 1 FROM residents WHERE ext=?", (ext,)).fetchone()
    if exists:
        console.print("[red]Esse ramal SIP já existe.[/red]")
        return

    secret = Prompt.ask("Senha SIP (Enter para gerar)", default="")
    secret = secret.strip() or random_secret()

    create_resident(ap_id=ap.id, name=name, ext=ext, secret=secret)
    console.print("[green]Morador criado![/green]")
    console.print(f"[bold]SIP:[/bold] usuário={ext}  senha={secret}")


def remove_resident_flow():
    ap = choose_ap_interactive()
    if not ap:
        return
    res = list_residents(ap.id)
    if not res:
        console.print("[yellow]Nenhum morador neste AP.[/yellow]")
        return

    t = Table(title=f"Moradores do AP {ap.ext} - {ap.name}")
    t.add_column("#", justify="right")
    t.add_column("Ramal", justify="left")
    t.add_column("Nome", justify="left")
    for i, r in enumerate(res, start=1):
        t.add_row(str(i), r.ext, r.name)
    console.print(t)

    ans = Prompt.ask("Remover qual? (# ou ramal). Enter cancela", default="").strip()
    if not ans:
        return

    target: Optional[Resident] = None
    if ans.isdigit():
        idx = int(ans)
        if 1 <= idx <= len(res):
            target = res[idx - 1]
    else:
        for r in res:
            if r.ext == ans:
                target = r
                break

    if not target:
        console.print("[red]Seleção inválida.[/red]")
        return

    if Confirm.ask(f"Confirmar remoção de {target.ext} / {target.name}?"):
        remove_resident(target.id)
        console.print("[green]Removido![/green]")


def remove_ap_flow():
    ap = choose_ap_interactive()
    if not ap:
        return
    if Confirm.ask(f"Remover AP {ap.ext} / {ap.name} (isso remove todos moradores)?"):
        remove_ap(ap.id)
        console.print("[green]AP removido![/green]")


def monitor_logs():
    console.print("[cyan]Saindo: CTRL+C[/cyan]")
    try:
        os.execvp("bash", ["bash", "-lc", "tail -f /var/log/asterisk/full"])
    except Exception as e:
        console.print(f"[red]Falha ao abrir tail: {e}[/red]")


def asterisk_console():
    try:
        os.execvp("asterisk", ["asterisk", "-rvvvvv"])
    except Exception as e:
        console.print(f"[red]Falha ao abrir console: {e}[/red]")


def menu():
    ensure_db()

    while True:
        console.print(header_panel())
        console.print("""
1) Dashboard tático (live)
2) Criar AP (unidade)
3) Criar morador (SIP por pessoa)
4) Remover morador
5) Remover AP
6) Sincronizar Asterisk (gera configs + reload)
7) Monitor logs Asterisk (tail -f)
8) Console Asterisk (asterisk -rvvvvv)
0) Sair
""".strip())

        choice = Prompt.ask("Seleção", choices=[str(i) for i in range(0, 9)], default="1")

        if choice == "0":
            return
        if choice == "1":
            dashboard_live()
        elif choice == "2":
            create_ap_flow()
        elif choice == "3":
            create_resident_flow()
        elif choice == "4":
            remove_resident_flow()
        elif choice == "5":
            remove_ap_flow()
        elif choice == "6":
            if not asterisk_online():
                console.print("[red]Asterisk OFFLINE. Verifique: systemctl status asterisk[/red]")
            else:
                sync_asterisk()
                console.print("[green]Sincronizado e recarregado![/green]")
        elif choice == "7":
            monitor_logs()
        elif choice == "8":
            asterisk_console()


if __name__ == "__main__":
    menu()
