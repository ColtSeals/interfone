#!/usr/bin/env python3
import os
import json
import time
import secrets
import subprocess
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Set

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
        line = asterisk_rx("core show uptime").splitlines()
        return line[0].strip() if line else "—"
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


def prompt(msg: str) -> str:
    return C.input(f"[cyan]{msg}[/cyan] ").strip()


def gen_pass() -> str:
    return secrets.token_urlsafe(10)


def asterisk_ok() -> bool:
    return systemctl_is_active("asterisk")


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
    wa_enabled: bool = False
    wa_number_enc: Optional[str] = None


@dataclass
class Apartment:
    id: str
    label: str
    dial_ext: str
    strategy: str
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
        out.append(
            Apartment(
                id=a["id"],
                label=a["label"],
                dial_ext=str(a["dial_ext"]),
                strategy=a.get("strategy", "sequential"),
                ring_seconds=int(a.get("ring_seconds", 20)),
                residents=rs,
            )
        )
    return out


def apartments_sorted_dicts(db: Dict) -> List[Dict]:
    aps = db.get("apartments", [])
    def key(a: Dict):
        de = str(a.get("dial_ext", ""))
        return (0, int(de)) if de.isdigit() else (1, de)
    return sorted(aps, key=key)


def apartments_sorted_models(db: Dict) -> List[Apartment]:
    aps = list_apartments(db)
    def key(a: Apartment):
        de = str(a.dial_ext)
        return (0, int(de)) if de.isdigit() else (1, de)
    return sorted(aps, key=key)


def find_apartment(db: Dict, ap_id_or_ext: str) -> Optional[Dict]:
    for a in db.get("apartments", []):
        if a.get("id") == ap_id_or_ext or str(a.get("dial_ext")) == ap_id_or_ext:
            return a
    return None


def all_sips(db: Dict) -> Set[str]:
    s = set()
    for a in db.get("apartments", []):
        for r in a.get("residents", []):
            sip = str(r.get("sip", "")).strip()
            if sip:
                s.add(sip)
    return s


# -----------------------------
# Status (online / busy)
# -----------------------------
def get_contact_status_map() -> Dict[str, str]:
    txt = asterisk_rx("pjsip show contacts")
    m: Dict[str, str] = {}
    for line in txt.splitlines():
        line = line.strip()
        if not line.startswith("Contact:"):
            continue
        parts = line.split()
        if len(parts) < 3:
            continue
        sip = parts[1].split("/")[0]
        status = parts[2]  # Avail / NonQual / Unknown ...
        m[sip] = status
    return m


def get_busy_set() -> set:
    txt = asterisk_rx("core show channels concise")
    busy = set()
    for line in txt.splitlines():
        if line.startswith("PJSIP/"):
            ch = line.split("!")[0]
            ext = ch.split("/")[1].split("-")[0]
            busy.add(ext)
    return busy


# -----------------------------
# Asterisk config generation
# -----------------------------
def sync_asterisk(db: Dict) -> None:
    aps = apartments_sorted_models(db)

    p_lines: List[str] = []
    e_lines: List[str] = []

    for ap in aps:
        residents = sorted(ap.residents, key=lambda r: (r.priority, r.name.lower()))

        # SIP por pessoa
        for r in residents:
            callerid = f"\"{r.name} ({ap.label})\" <{r.sip}>"

            p_lines.append(
                f"[{r.sip}]\n"
                f"type=auth\n"
                f"auth_type=userpass\n"
                f"username={r.sip}\n"
                f"password={r.password}\n"
            )
            p_lines.append(
                f"[{r.sip}]\n"
                f"type=aor\n"
                f"max_contacts=5\n"
                f"remove_existing=yes\n"
                f"qualify_frequency=30\n"
            )
            p_lines.append(
                f"[{r.sip}]\n"
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
                f"direct_media=no\n"
            )

            # discagem direta opcional
            e_lines.append(
                f"exten => {r.sip},1,NoOp(Chamada direta para {r.name} | {ap.label})\n"
                f" same => n,Dial(PJSIP/{r.sip},30)\n"
                f" same => n,Hangup()\n"
            )

        # EXT do apartamento (portaria disca isso)
        e_lines.append(
            f"; ===============================\n"
            f"; AP: {ap.label} | EXT: {ap.dial_ext} | STRAT: {ap.strategy}\n"
            f"; ===============================\n"
            f"exten => {ap.dial_ext},1,NoOp(PORTARIA -> {ap.label})\n"
        )

        if not residents:
            e_lines.append(
                " same => n,NoOp(SEM MORADORES CADASTRADOS)\n"
                " same => n,Playback(vm-nobodyavail)\n"
                " same => n,Hangup()\n"
            )
            continue

        if ap.strategy == "parallel":
            targets = "&".join([f"PJSIP/{r.sip}" for r in residents])
            e_lines.append(
                f" same => n,Dial({targets},{ap.ring_seconds})\n"
                f" same => n,GotoIf($[\"${{DIALSTATUS}}\"=\"ANSWER\"]?done)\n"
            )
        else:
            per = max(5, int(ap.ring_seconds / max(1, len(residents))))
            for r in residents:
                e_lines.append(
                    f" same => n,Dial(PJSIP/{r.sip},{per})\n"
                    f" same => n,GotoIf($[\"${{DIALSTATUS}}\"=\"ANSWER\"]?done)\n"
                )

        # placeholder WhatsApp/Evolution
        e_lines.append(
            " same => n,NoOp(FALLBACK_WHATSAPP: placeholder - entra Evolution API aqui)\n"
            " same => n,Playback(vm-nobodyavail)\n"
            " same => n(done),Hangup()\n"
        )

    os.makedirs(os.path.dirname(P_USERS), exist_ok=True)
    with open(P_USERS, "w", encoding="utf-8") as f:
        f.write("\n".join(p_lines).strip() + "\n")

    with open(E_USERS, "w", encoding="utf-8") as f:
        f.write("\n".join(e_lines).strip() + "\n")

    try:
        sh(["chown", "root:asterisk", P_USERS, E_USERS])
        sh(["chmod", "640", P_USERS, E_USERS])
    except Exception:
        pass

    sh(["systemctl", "restart", "asterisk"])
    asterisk_rx("core reload")


# -----------------------------
# UI
# -----------------------------
def header() -> Panel:
    ast = "[green]ONLINE[/green]" if asterisk_ok() else "[red]OFFLINE[/red]"
    info = (
        f"[bold]ASTERISK:[/bold] {ast}    "
        f"[bold]RAM:[/bold] {ram_pretty()}    "
        f"[bold]UPTIME:[/bold] {uptime_pretty()}"
    )
    return Panel(info, title="[bold cyan]INTERFONE TACTICAL[/bold cyan]", border_style="cyan")


def dashboard_table(db: Dict) -> Table:
    aps = apartments_sorted_models(db)
    contacts = get_contact_status_map() if asterisk_ok() else {}
    busy = get_busy_set() if asterisk_ok() else set()

    total_aps = len(aps)
    total_res = sum(len(a.residents) for a in aps)
    total_online = 0
    total_busy = 0

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
            is_on = (str(st).lower() == "avail")
            if is_on:
                online += 1
                total_online += 1

            is_busy = (r.sip in busy)
            if is_busy:
                busy_count += 1
                total_busy += 1

            tag = "🟢" if is_on else "⚫"
            tag += "🔴" if is_busy else ""
            detail_bits.append(f"{tag}{r.name}:{r.sip}")

        det = " | ".join(detail_bits) if detail_bits else "—"
        t.add_row(
            f"{ap.label} / {ap.dial_ext}",
            ap.strategy,
            str(total),
            f"[green]{online}[/green]" if online else "0",
            f"[red]{busy_count}[/red]" if busy_count else "0",
            det,
        )

    t.caption = f"APs: {total_aps} | SIPs: {total_res} | Online: {total_online} | Busy: {total_busy}"
    return t


def select_apartment_ui(db: Dict, title: str) -> Optional[Dict]:
    aps = apartments_sorted_dicts(db)
    if not aps:
        C.print("[yellow]Nenhum AP cadastrado.[/yellow]")
        return None

    contacts = get_contact_status_map() if asterisk_ok() else {}
    busy = get_busy_set() if asterisk_ok() else set()

    t = Table(title=title, box=box.SIMPLE_HEAVY)
    t.add_column("#", style="bold")
    t.add_column("AP / EXT", style="bold")
    t.add_column("Estratégia")
    t.add_column("Moradores", justify="right")
    t.add_column("Online", justify="right")
    t.add_column("Busy", justify="right")

    for idx, ap in enumerate(aps, start=1):
        residents = ap.get("residents", [])
        total = len(residents)
        online = 0
        busy_count = 0

        for r in residents:
            sip = str(r.get("sip", "")).strip()
            st = contacts.get(sip, "—")
            if str(st).lower() == "avail":
                online += 1
            if sip in busy:
                busy_count += 1

        t.add_row(
            str(idx),
            f"{ap.get('label','—')} / {ap.get('dial_ext','—')}",
            ap.get("strategy", "sequential"),
            str(total),
            f"[green]{online}[/green]" if online else "0",
            f"[red]{busy_count}[/red]" if busy_count else "0",
        )

    C.print(t)
    choice = prompt("Digite o número (#) ou EXT (ex: 101). Enter cancela")
    if not choice:
        return None

    if choice.isdigit():
        n = int(choice)
        if 1 <= n <= len(aps):
            return aps[n - 1]
        # fallback: talvez seja EXT
        ap = find_apartment(db, choice)
        return ap

    return find_apartment(db, choice.strip())


# -----------------------------
# Actions
# -----------------------------
def add_apartment(db: Dict) -> None:
    C.print(header())
    dial_ext = prompt("Número do AP (EXT que a portaria disca) (ex: 101)")
    bloco = prompt("Bloco/Torre (ex: A)")
    apnum = prompt("Apartamento (ex: 101)")
    label = f"Bloco {bloco} Ap {apnum}"

    strategy = (prompt("Estratégia [sequential/parallel] (padrão sequential)") or "sequential").lower()
    ring = prompt("Ring total em segundos (padrão 20)") or "20"

    if find_apartment(db, str(dial_ext)) is not None:
        C.print("[red]Já existe um AP com esse EXT.[/red]")
        return

    ap_id = f"{bloco}-{apnum}"
    db["apartments"].append(
        {
            "id": ap_id,
            "label": label,
            "dial_ext": str(dial_ext),
            "strategy": "parallel" if strategy.startswith("p") else "sequential",
            "ring_seconds": int(ring),
            "residents": [],
        }
    )
    save_db(db)
    C.print("[green]AP criado.[/green]")


def add_resident(db: Dict) -> None:
    C.print(header())
    ap = select_apartment_ui(db, "Selecionar AP para adicionar morador")
    if not ap:
        return

    name = prompt("Nome do morador")
    sip = prompt("SIP do morador (único) (ex: 1011). Enter = auto") or ""

    used_global = all_sips(db)

    if not sip:
        base = str(ap["dial_ext"])
        used_local = {str(r.get("sip")) for r in ap.get("residents", [])}
        for i in range(1, 100):
            cand = f"{base}{i}"
            if cand not in used_local and cand not in used_global:
                sip = cand
                break

    sip = sip.strip()
    if not sip:
        C.print("[red]Falha ao gerar SIP automático.[/red]")
        return

    if sip in used_global:
        C.print("[red]Esse SIP já existe em outro AP.[/red]")
        return

    password = prompt("Senha SIP (Enter = gerar)") or gen_pass()
    pr = prompt("Prioridade (menor toca antes) (padrão 10)") or "10"

    ap.setdefault("residents", []).append(
        {
            "id": secrets.token_hex(6),
            "name": name,
            "sip": sip,
            "password": password,
            "priority": int(pr),
            "wa_enabled": False,
            "wa_number_enc": None,
        }
    )

    save_db(db)
    C.print(f"[green]Morador criado:[/green] {name} | SIP={sip} | PASS={password}")


def remove_resident(db: Dict) -> None:
    C.print(header())
    ap = select_apartment_ui(db, "Selecionar AP para remover morador")
    if not ap:
        return

    residents = ap.get("residents", [])
    if not residents:
        C.print("[yellow]Este AP não tem moradores.[/yellow]")
        return

    t = Table(title="Moradores", box=box.SIMPLE_HEAVY)
    t.add_column("#", style="bold")
    t.add_column("Nome")
    t.add_column("SIP", style="bold")
    t.add_column("Prioridade", justify="right")

    residents_sorted = sorted(residents, key=lambda r: (r.get("priority", 10), r.get("name", "").lower()))
    for idx, r in enumerate(residents_sorted, start=1):
        t.add_row(str(idx), r.get("name", "—"), r.get("sip", "—"), str(r.get("priority", 10)))

    C.print(t)
    choice = prompt("Digite o número (#) ou SIP (ex: 1011). Enter cancela")
    if not choice:
        return

    sip = None
    if choice.isdigit():
        n = int(choice)
        if 1 <= n <= len(residents_sorted):
            sip = residents_sorted[n - 1].get("sip")
        else:
            sip = choice
    else:
        sip = choice.strip()

    before = len(ap.get("residents", []))
    ap["residents"] = [r for r in ap.get("residents", []) if r.get("sip") != sip]
    after = len(ap.get("residents", []))
    save_db(db)
    C.print("[green]Removido.[/green]" if after < before else "[yellow]Nada removido.[/yellow]")


def remove_apartment(db: Dict) -> None:
    C.print(header())
    ap = select_apartment_ui(db, "Selecionar AP para remover")
    if not ap:
        return

    confirm = prompt(f"CONFIRMAR remoção de '{ap.get('label')}' (digite SIM)")
    if confirm.strip().upper() != "SIM":
        C.print("[yellow]Cancelado.[/yellow]")
        return

    before = len(db.get("apartments", []))
    db["apartments"] = [a for a in db.get("apartments", []) if a.get("id") != ap.get("id")]
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
