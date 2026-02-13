#!/usr/bin/env python3
import os
import json
import time
import secrets
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple

from rich.console import Console
from rich.table import Table
from rich.live import Live
from rich.panel import Panel
from rich import box
import psutil

C = Console()

DB_PATH = "/opt/interfone/db.json"

P_USERS = "/etc/asterisk/pjsip_users.conf"
E_USERS = "/etc/asterisk/extensions_users.conf"

ASTERISK_BIN = "asterisk"

DEFAULT_RTP = "10000-20000"
DEFAULT_TRANSPORT = "transport-udp"

# -----------------------------
# Helpers
# -----------------------------
def sh(cmd: List[str], check: bool = False) -> Tuple[int, str, str]:
    p = subprocess.run(cmd, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"cmd failed: {' '.join(cmd)}\n{p.stderr}")
    return p.returncode, p.stdout, p.stderr

def asterisk_rx(command: str) -> str:
    rc, out, err = sh([ASTERISK_BIN, "-rx", command])
    return out if out else err

def systemctl_is_active(unit: str) -> bool:
    rc, out, _ = sh(["systemctl", "is-active", unit])
    return (rc == 0) and ("active" in out)

def uptime_pretty() -> str:
    try:
        return asterisk_rx("core show uptime").splitlines()[0].strip()
    except Exception:
        boot = psutil.boot_time()
        secs = int(time.time() - boot)
        h = secs // 3600
        m = (secs % 3600) // 60
        return f"up {h}h {m}m"

def ram_pretty() -> str:
    vm = psutil.virtual_memory()
    used = vm.used // (1024**2)
    total = vm.total // (1024**2)
    return f"{used}MB/{total}MB"

def ensure_root():
    if os.geteuid() != 0:
        C.print("[bold red]Rode como root:[/bold red] sudo interfone")
        raise SystemExit(1)

# -----------------------------
# Data model
# -----------------------------
@dataclass
class Resident:
    id: str
    name: str
    sip: str
    password: str
    priority: int = 10
    # WhatsApp (Evolution) - placeholder (não expomos pra portaria)
    wa_enabled: bool = False
    wa_number_enc: Optional[str] = None  # você pode criptografar depois

@dataclass
class Apartment:
    id: str                # "A-101" ou "101"
    label: str             # "Bloco A Ap 101"
    dial_ext: str          # "101" (o número que a portaria disca)
    strategy: str          # "sequential" | "parallel"
    ring_seconds: int
    residents: List[Resident]

def _default_db() -> Dict:
    return {"apartments": []}

def load_db() -> Dict:
    if not os.path.exists(DB_PATH):
        return _default_db()
    try:
        with open(DB_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return _default_db()

def save_db(db: Dict) -> None:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    tmp = DB_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2, ensure_ascii=False)
    os.replace(tmp, DB_PATH)
    os.chmod(DB_PATH, 0o640)

def list_apartments(db: Dict) -> List[Apartment]:
    out: List[Apartment] = []
    for a in db.get("apartments", []):
        rs = [Resident(**r) for r in a.get("residents", [])]
        out.append(Apartment(
            id=a["id"],
            label=a["label"],
            dial_ext=a["dial_ext"],
            strategy=a.get("strategy", "sequential"),
            ring_seconds=int(a.get("ring_seconds", 20)),
            residents=rs
        ))
    return out

def find_apartment(db: Dict, ap_id: str) -> Optional[Dict]:
    for a in db.get("apartments", []):
        if a.get("id") == ap_id or a.get("dial_ext") == ap_id:
            return a
    return None

def gen_pass() -> str:
    return secrets.token_urlsafe(10)

# -----------------------------
# Status (online / busy)
# -----------------------------
def get_contact_status_map() -> Dict[str, str]:
    """
    Returns: sip -> "Avail" | "NonQual" | "Unknown" | etc.
    """
    txt = asterisk_rx("pjsip show contacts")
    m: Dict[str, str] = {}
    for line in txt.splitlines():
        line = line.strip()
        if not line.startswith("Contact:"):
            continue
        # Example: Contact:  1011/sip:1011@1.2.3.4:5060;ob  Avail         23.123
        parts = line.split()
        if len(parts) < 4:
            continue
        # parts[1] is like "1011/sip:..."
        sip = parts[1].split("/")[0]
        status = parts[2]  # often Avail/NonQual/Unknown
        m[sip] = status
    return m

def get_busy_set() -> set:
    """
    Uses channel list to mark extensions currently in call.
    """
    txt = asterisk_rx("core show channels concise")
    busy = set()
    for line in txt.splitlines():
        # PJSIP/1011-0000000a!from-internal!101!...
        if line.startswith("PJSIP/"):
            ch = line.split("!")[0]  # PJSIP/1011-0000000a
            ext = ch.split("/")[1].split("-")[0]
            busy.add(ext)
    return busy

def asterisk_ok() -> bool:
    return systemctl_is_active("asterisk")

# -----------------------------
# Asterisk config generation
# -----------------------------
def sync_asterisk(db: Dict) -> None:
    aps = list_apartments(db)

    p_lines: List[str] = []
    e_lines: List[str] = []

    # Create one dialplan for each apartment dial_ext
    for ap in aps:
        # Order by priority
        residents = sorted(ap.residents, key=lambda r: (r.priority, r.name.lower()))

        # PJSIP entries for each resident (SIP unique per person)
        for r in residents:
            callerid = f"\"{r.name} ({ap.label})\" <{r.sip}>"

            p_lines.append(f"[{r.sip}]\n"
                           f"type=auth\n"
                           f"auth_type=userpass\n"
                           f"username={r.sip}\n"
                           f"password={r.password}\n")

            p_lines.append(f"[{r.sip}]\n"
                           f"type=aor\n"
                           f"max_contacts=5\n"
                           f"remove_existing=yes\n"
                           f"qualify_frequency=30\n")

            p_lines.append(f"[{r.sip}]\n"
                           f"type=endpoint\n"
                           f"context=interfone-ctx\n"
                           f"disallow=all\n"
                           f"allow=ulaw,alaw,gsm,opus\n"
                           f"auth={r.sip}\n"
                           f"aors={r.sip}\n"
                           f"callerid={callerid}\n"
                           f"transport={DEFAULT_TRANSPORT}\n"
                           f"rtp_symmetric=yes\n"
                           f"force_rport=yes\n"
                           f"rewrite_contact=yes\n"
                           f"direct_media=no\n")

            # Direct call to resident (optional)
            e_lines.append(
                f"exten => {r.sip},1,NoOp(Chamada direta para {r.name} | {ap.label})\n"
                f" same => n,Dial(PJSIP/{r.sip},30)\n"
                f" same => n,Hangup()\n"
            )

        # Apartment virtual extension (portaria calls ap.dial_ext)
        e_lines.append(f"; ===============================\n"
                       f"; AP: {ap.label} | EXT: {ap.dial_ext} | STRAT: {ap.strategy}\n"
                       f"; ===============================\n"
                       f"exten => {ap.dial_ext},1,NoOp(PORTARIA -> {ap.label})\n")

        if not residents:
            e_lines.append(" same => n,NoOp(SEM MORADORES CADASTRADOS)\n"
                           " same => n,Playback(vm-nobodyavail)\n"
                           " same => n,Hangup()\n")
            continue

        if ap.strategy == "parallel":
            targets = "&".join([f"PJSIP/{r.sip}" for r in residents])
            e_lines.append(f" same => n,Dial({targets},{ap.ring_seconds})\n"
                           f" same => n,GotoIf($[\"${{DIALSTATUS}}\"=\"ANSWER\"]?done)\n")
        else:
            # sequential default
            per = max(5, int(ap.ring_seconds / max(1, len(residents))))
            for r in residents:
                e_lines.append(f" same => n,Dial(PJSIP/{r.sip},{per})\n"
                               f" same => n,GotoIf($[\"${{DIALSTATUS}}\"=\"ANSWER\"]?done)\n")

        # WhatsApp fallback placeholder
        e_lines.append(" same => n,NoOp(FALLBACK_WHATSAPP: (placeholder) aqui entra Evolution API)\n"
                       " same => n,Playback(vm-nobodyavail)\n"
                       " same => n(done),Hangup()\n")

    # Write files
    os.makedirs(os.path.dirname(P_USERS), exist_ok=True)
    with open(P_USERS, "w", encoding="utf-8") as f:
        f.write("\n".join(p_lines).strip() + "\n")

    with open(E_USERS, "w", encoding="utf-8") as f:
        f.write("\n".join(e_lines).strip() + "\n")

    # Permissions
    try:
        sh(["chown", "root:asterisk", P_USERS, E_USERS])
        sh(["chmod", "640", P_USERS, E_USERS])
    except Exception:
        pass

    # Reload asterisk
    sh(["systemctl", "restart", "asterisk"])
    asterisk_rx("core reload")

# -----------------------------
# UI
# -----------------------------
def header() -> Panel:
    ast = "[green]ONLINE[/green]" if asterisk_ok() else "[red]OFFLINE[/red]"
    info = f"[bold]ASTERISK:[/bold] {ast}    [bold]RAM:[/bold] {ram_pretty()}    [bold]UPTIME:[/bold] {uptime_pretty()}"
    return Panel(info, title="[bold cyan]INTERFONE TACTICAL[/bold cyan]", border_style="cyan")

def dashboard_table(db: Dict) -> Table:
    aps = list_apartments(db)
    contacts = get_contact_status_map() if asterisk_ok() else {}
    busy = get_busy_set() if asterisk_ok() else set()

    t = Table(box=box.SIMPLE_HEAVY)
    t.add_column("AP / EXT", style="bold")
    t.add_column("Estratégia")
    t.add_column("Moradores", justify="right")
    t.add_column("Online", justify="right")
    t.add_column("Busy", justify="right")
    t.add_column("Detalhe")

    for ap in aps:
        residents = sorted(ap.residents, key=lambda r: (r.priority, r.name.lower()))
        total = len(residents)
        online = 0
        busy_count = 0

        detail_bits = []
        for r in residents:
            st = contacts.get(r.sip, "—")
            is_on = (st.lower() == "avail")
            if is_on:
                online += 1
            is_busy = (r.sip in busy)
            if is_busy:
                busy_count += 1

            tag = "🟢" if is_on else "⚫"
            tag += "🔴" if is_busy else ""
            detail_bits.append(f"{tag}{r.name}:{r.sip}")

        det = " | ".join(detail_bits) if detail_bits else "—"
        t.add_row(f"{ap.label} / {ap.dial_ext}",
                  ap.strategy,
                  str(total),
                  f"[green]{online}[/green]" if online else "0",
                  f"[red]{busy_count}[/red]" if busy_count else "0",
                  det)
    return t

def prompt(msg: str) -> str:
    return C.input(f"[cyan]{msg}[/cyan] ").strip()

def add_apartment(db: Dict) -> None:
    C.print(header())
    dial_ext = prompt("Número do AP (EXT que a portaria disca) (ex: 101)")
    bloco = prompt("Bloco/Torre (ex: A)")
    apnum = prompt("Apartamento (ex: 101)")
    label = f"Bloco {bloco} Ap {apnum}"
    strategy = prompt("Estratégia [sequential/parallel] (padrão sequential)") or "sequential"
    ring = prompt("Ring total em segundos (padrão 20)") or "20"
    ap_id = f"{bloco}-{apnum}"

    db["apartments"].append({
        "id": ap_id,
        "label": label,
        "dial_ext": dial_ext,
        "strategy": "parallel" if strategy.lower().startswith("p") else "sequential",
        "ring_seconds": int(ring),
        "residents": []
    })
    save_db(db)
    C.print("[green]AP criado.[/green]")

def add_resident(db: Dict) -> None:
    C.print(header())
    ap_key = prompt("Informe o AP (id 'A-101' ou EXT '101')")
    ap = find_apartment(db, ap_key)
    if not ap:
        C.print("[red]AP não encontrado.[/red]")
        return

    name = prompt("Nome do morador")
    sip = prompt("SIP do morador (único) (ex: 1011). Enter = auto") or ""
    if not sip:
        # auto: dial_ext + índice
        base = ap["dial_ext"]
        used = {r["sip"] for r in ap.get("residents", [])}
        for i in range(1, 100):
            cand = f"{base}{i}"
            if cand not in used:
                sip = cand
                break

    password = prompt("Senha SIP (Enter = gerar)") or gen_pass()
    pr = prompt("Prioridade (menor toca antes) (padrão 10)") or "10"

    ap.setdefault("residents", []).append({
        "id": secrets.token_hex(6),
        "name": name,
        "sip": sip,
        "password": password,
        "priority": int(pr),
        "wa_enabled": False,
        "wa_number_enc": None
    })

    save_db(db)
    C.print(f"[green]Morador criado:[/green] {name} | SIP={sip} | PASS={password}")

def remove_resident(db: Dict) -> None:
    C.print(header())
    ap_key = prompt("Informe o AP (id ou EXT)")
    ap = find_apartment(db, ap_key)
    if not ap:
        C.print("[red]AP não encontrado.[/red]")
        return

    sip = prompt("SIP do morador para remover (ex: 1011)")
    before = len(ap.get("residents", []))
    ap["residents"] = [r for r in ap.get("residents", []) if r.get("sip") != sip]
    after = len(ap.get("residents", []))
    save_db(db)
    C.print("[green]Removido.[/green]" if after < before else "[yellow]Nada removido.[/yellow]")

def remove_apartment(db: Dict) -> None:
    C.print(header())
    ap_id = prompt("Informe o AP id (ex: A-101) ou EXT (ex: 101)")
    before = len(db.get("apartments", []))
    db["apartments"] = [a for a in db.get("apartments", []) if not (a.get("id")==ap_id or a.get("dial_ext")==ap_id)]
    after = len(db.get("apartments", []))
    save_db(db)
    C.print("[green]AP removido.[/green]" if after < before else "[yellow]Nada removido.[/yellow]")

def live_dashboard(db: Dict) -> None:
    C.print("[bold]CTRL+C[/bold] para sair do modo tático.")
    with Live(refresh_per_second=1, console=C) as live:
        while True:
            db = load_db()
            layout = Table.grid(expand=True)
            layout.add_row(header())
            layout.add_row(dashboard_table(db))
            live.update(layout)
            time.sleep(1)

def tail_logs() -> None:
    C.print("[bold]CTRL+C[/bold] para sair do monitor.")
    p = subprocess.Popen(["tail", "-f", "/var/log/asterisk/messages"], text=True)
    try:
        p.wait()
    except KeyboardInterrupt:
        p.terminate()

def menu():
    ensure_root()
    while True:
        db = load_db()
        C.clear()
        C.print(header())
        C.print("\n[bold]1)[/bold] Dashboard tático (live)")
        C.print("[bold]2)[/bold] Criar AP (unidade)")
        C.print("[bold]3)[/bold] Criar morador (SIP por pessoa)")
        C.print("[bold]4)[/bold] Remover morador")
        C.print("[bold]5)[/bold] Remover AP")
        C.print("[bold]6)[/bold] Sincronizar Asterisk (gera configs + reload)")
        C.print("[bold]7)[/bold] Monitor logs Asterisk (tail -f)")
        C.print("[bold]8)[/bold] Console Asterisk (asterisk -rvvvvv)")
        C.print("[bold]0)[/bold] Sair\n")

        op = prompt("Seleção")
        if op == "1":
            try:
                live_dashboard(db)
            except KeyboardInterrupt:
                pass
        elif op == "2":
            add_apartment(db)
            time.sleep(1)
        elif op == "3":
            add_resident(db)
            time.sleep(2)
        elif op == "4":
            remove_resident(db)
            time.sleep(1)
        elif op == "5":
            remove_apartment(db)
            time.sleep(1)
        elif op == "6":
            sync_asterisk(db)
            C.print("[green]Sincronizado e Asterisk recarregado.[/green]")
            time.sleep(1)
        elif op == "7":
            tail_logs()
        elif op == "8":
            os.system("asterisk -rvvvvv")
        elif op == "0":
            break

if __name__ == "__main__":
    menu()
