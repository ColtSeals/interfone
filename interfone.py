#!/usr/bin/env python3
import os
import json
import time
import secrets
import subprocess
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Any

from rich.console import Console
from rich.table import Table
from rich.live import Live
from rich.panel import Panel
from rich import box
import psutil

C = Console()

APP_DIR = "/opt/interfone"
DB_PATH = f"{APP_DIR}/db.json"

P_USERS = "/etc/asterisk/pjsip_users.conf"
E_USERS = "/etc/asterisk/extensions_users.conf"

ASTERISK_BIN = "/usr/sbin/asterisk" if os.path.exists("/usr/sbin/asterisk") else "asterisk"
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

def asterisk_ok() -> bool:
    if systemctl_is_active("asterisk"):
        return True
    # fallback: tenta rx
    try:
        out = asterisk_rx("core show uptime")
        return "System uptime" in out or "up" in out.lower()
    except Exception:
        return False

def uptime_pretty() -> str:
    try:
        txt = asterisk_rx("core show uptime").splitlines()
        return txt[0].strip() if txt else "—"
    except Exception:
        boot = psutil.boot_time()
        secs = int(time.time() - boot)
        h = secs // 3600
        m = (secs % 3600) // 60
        s = secs % 60
        return f"System uptime: {h}h {m}m {s}s"

def ram_pretty() -> str:
    vm = psutil.virtual_memory()
    used = vm.used // (1024**2)
    total = vm.total // (1024**2)
    return f"{used}MB/{total}MB"

def ensure_root():
    if os.geteuid() != 0:
        C.print("[bold red]Rode como root:[/bold red] sudo interfone")
        raise SystemExit(1)

def gen_pass() -> str:
    return secrets.token_urlsafe(10)

def norm(s: str) -> str:
    return (s or "").strip()

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

def _default_db() -> Dict[str, Any]:
    return {
        "portaria": {"sip": "1000", "name": "Portaria", "password": gen_pass()},
        "apartments": []
    }

def load_db() -> Dict[str, Any]:
    if not os.path.exists(DB_PATH):
        return _default_db()
    try:
        with open(DB_PATH, "r", encoding="utf-8") as f:
            db = json.load(f)
            if "portaria" not in db:
                db["portaria"] = {"sip": "1000", "name": "Portaria", "password": gen_pass()}
            if "apartments" not in db:
                db["apartments"] = []
            return db
    except Exception:
        return _default_db()

def save_db(db: Dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    tmp = DB_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2, ensure_ascii=False)
    os.replace(tmp, DB_PATH)
    os.chmod(DB_PATH, 0o640)

def list_apartments(db: Dict[str, Any]) -> List[Apartment]:
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

def find_apartment(db: Dict[str, Any], ap_key: str) -> Optional[Dict[str, Any]]:
    ap_key = norm(ap_key)
    for a in db.get("apartments", []):
        if a.get("id") == ap_key or a.get("dial_ext") == ap_key:
            return a
    return None

def dial_ext_in_use(db: Dict[str, Any], dial_ext: str) -> bool:
    dial_ext = norm(dial_ext)
    return any(a.get("dial_ext") == dial_ext for a in db.get("apartments", []))

def ap_id_in_use(db: Dict[str, Any], ap_id: str) -> bool:
    ap_id = norm(ap_id)
    return any(a.get("id") == ap_id for a in db.get("apartments", []))

# -----------------------------
# Status (Online / Busy)
# -----------------------------
CONTACT_RE = re.compile(r"^Contact:\s+(?P<name>[^/\s]+)/.*?\s+(?P<status>Avail|NonQual|Unknown|Unavail|Reachable|Lagged)\b", re.I)

def get_contact_status_map() -> Dict[str, str]:
    txt = asterisk_rx("pjsip show contacts")
    m: Dict[str, str] = {}
    for line in txt.splitlines():
        line = line.strip()
        if not line.startswith("Contact:"):
            continue
        mm = CONTACT_RE.match(line)
        if not mm:
            # fallback simples
            parts = line.split()
            if len(parts) >= 3:
                sip = parts[1].split("/")[0]
                st = parts[2]
                m[sip] = st
            continue
        sip = mm.group("name")
        st = mm.group("status")
        m[sip] = st
    return m

def get_busy_set() -> set:
    txt = asterisk_rx("core show channels concise")
    busy = set()
    for line in txt.splitlines():
        if line.startswith("PJSIP/"):
            ch = line.split("!")[0]  # PJSIP/1011-0000000a
            ext = ch.split("/")[1].split("-")[0]
            busy.add(ext)
    return busy

# -----------------------------
# Asterisk config generation
# -----------------------------
def _pjsip_block_auth(sip: str, password: str) -> str:
    return (
        f"[{sip}]\n"
        f"type=auth\n"
        f"auth_type=userpass\n"
        f"username={sip}\n"
        f"password={password}\n"
    )

def _pjsip_block_aor(sip: str) -> str:
    return (
        f"[{sip}]\n"
        f"type=aor\n"
        f"max_contacts=5\n"
        f"remove_existing=yes\n"
        f"qualify_frequency=30\n"
    )

def _pjsip_block_endpoint(sip: str, callerid: str) -> str:
    return (
        f"[{sip}]\n"
        f"type=endpoint\n"
        f"context=interfone-ctx\n"
        f"disallow=all\n"
        f"allow=ulaw,alaw,gsm,opus\n"
        f"auth={sip}\n"
        f"aors={sip}\n"
        f"callerid={callerid}\n"
        f"transport={DEFAULT_TRANSPORT}\n"
        f"rtp_symmetric=yes\n"
        f"force_rport=yes\n"
        f"rewrite_contact=yes\n"
        f"direct_media=no\n"
    )

def sync_asterisk(db: Dict[str, Any]) -> None:
    aps = list_apartments(db)
    portaria = db.get("portaria", {"sip": "1000", "name": "Portaria", "password": gen_pass()})
    p_sip = str(portaria.get("sip", "1000")).strip() or "1000"
    p_name = str(portaria.get("name", "Portaria")).strip() or "Portaria"
    p_pass = str(portaria.get("password", gen_pass())).strip() or gen_pass()

    p_lines: List[str] = []
    e_lines: List[str] = []

    # -------- Portaria 1000 --------
    portaria_callerid = f"\"{p_name}\" <{p_sip}>"
    p_lines.append(_pjsip_block_auth(p_sip, p_pass))
    p_lines.append(_pjsip_block_aor(p_sip))
    p_lines.append(_pjsip_block_endpoint(p_sip, portaria_callerid))

    e_lines.append(
        f"; ===============================\n"
        f"; PORTARIA ({p_sip})\n"
        f"; ===============================\n"
        f"exten => {p_sip},1,NoOp(Chamada direta para Portaria)\n"
        f" same => n,Dial(PJSIP/{p_sip},30)\n"
        f" same => n,Hangup()\n"
    )

    # -------- Apartamentos --------
    for ap in aps:
        residents = sorted(ap.residents, key=lambda r: (r.priority, r.name.lower()))

        # PJSIP para cada morador
        for r in residents:
            callerid = f"\"{r.name} ({ap.label})\" <{r.sip}>"
            p_lines.append(_pjsip_block_auth(r.sip, r.password))
            p_lines.append(_pjsip_block_aor(r.sip))
            p_lines.append(_pjsip_block_endpoint(r.sip, callerid))

            # chamada direta pro morador (opcional)
            e_lines.append(
                f"exten => {r.sip},1,NoOp(Chamada direta para {r.name} | {ap.label})\n"
                f" same => n,Dial(PJSIP/{r.sip},30)\n"
                f" same => n,Hangup()\n"
            )

        # ramal do AP (portaria disca ap.dial_ext)
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

        e_lines.append(
            " same => n,NoOp(FALLBACK_WHATSAPP: placeholder Evolution API)\n"
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

    # reload asterisk (se falhar, restart)
    rc, _, _ = sh([ASTERISK_BIN, "-rx", "core reload"])
    if rc != 0:
        sh(["systemctl", "restart", "asterisk"])

# -----------------------------
# UI
# -----------------------------
def header(db: Dict[str, Any]) -> Panel:
    ast = "[green]ONLINE[/green]" if asterisk_ok() else "[red]OFFLINE[/red]"
    portaria = db.get("portaria", {})
    info = (
        f"[bold]ASTERISK:[/bold] {ast}    "
        f"[bold]RAM:[/bold] {ram_pretty()}    "
        f"[bold]UPTIME:[/bold] {uptime_pretty()}    "
        f"[bold]PORTARIA:[/bold] {portaria.get('sip','1000')}"
    )
    return Panel(info, title="[bold cyan]INTERFONE TACTICAL[/bold cyan]", border_style="cyan")

def dashboard_table(db: Dict[str, Any]) -> Table:
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
            is_on = (str(st).lower() == "avail")
            if is_on:
                online += 1
            is_busy = (r.sip in busy)
            if is_busy:
                busy_count += 1

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
            det
        )
    return t

def prompt(msg: str) -> str:
    return C.input(f"[cyan]{msg}[/cyan] ").strip()

def choose_ap(db: Dict[str, Any], title: str) -> Optional[Dict[str, Any]]:
    aps = list_apartments(db)
    if not aps:
        C.print("[yellow]Nenhum AP cadastrado ainda.[/yellow]")
        return None

    contacts = get_contact_status_map() if asterisk_ok() else {}
    busy = get_busy_set() if asterisk_ok() else set()

    C.print(f"\n[bold]{title}[/bold]\n")
    t = Table(box=box.SIMPLE_HEAVY)
    t.add_column("#", justify="right", style="bold")
    t.add_column("AP / EXT", style="bold")
    t.add_column("Estratégia")
    t.add_column("Moradores", justify="right")
    t.add_column("Online", justify="right")
    t.add_column("Busy", justify="right")

    for i, ap in enumerate(aps, start=1):
        residents = sorted(ap.residents, key=lambda r: (r.priority, r.name.lower()))
        total = len(residents)
        online = sum(1 for r in residents if str(contacts.get(r.sip, "")).lower() == "avail")
        busy_count = sum(1 for r in residents if r.sip in busy)
        t.add_row(
            str(i),
            f"{ap.label} / {ap.dial_ext}",
            ap.strategy,
            str(total),
            str(online),
            str(busy_count),
        )

    C.print(t)
    ans = prompt("Digite o número (#) ou EXT (ex: 101). Enter cancela")
    if not ans:
        return None

    if ans.isdigit():
        idx = int(ans)
        if 1 <= idx <= len(aps):
            return find_apartment(db, aps[idx-1].dial_ext)
        # se digitou EXT (ex: 101) e também é número, tenta buscar
        ap = find_apartment(db, ans)
        return ap

    return find_apartment(db, ans)

def add_apartment(db: Dict[str, Any]) -> None:
    C.print(header(db))
    dial_ext = norm(prompt("EXT do AP (número que a portaria disca) (ex: 101)"))
    if not dial_ext:
        C.print("[red]EXT inválida.[/red]")
        return
    if dial_ext_in_use(db, dial_ext):
        C.print("[red]Essa EXT já está em uso.[/red]")
        return

    bloco = norm(prompt("Bloco/Torre (ex: A)")) or "A"
    apnum = norm(prompt("Apartamento (ex: 101)")) or dial_ext

    label = f"Bloco {bloco.upper()} Ap {apnum}"
    strategy = (norm(prompt("Estratégia [sequential/parallel] (padrão sequential)")) or "sequential").lower()
    ring = norm(prompt("Ring total em segundos (padrão 20)")) or "20"

    ap_id = f"{bloco.upper()}-{apnum}"
    if ap_id_in_use(db, ap_id):
        C.print("[red]Esse ID de AP já existe.[/red]")
        return

    db["apartments"].append({
        "id": ap_id,
        "label": label,
        "dial_ext": dial_ext,
        "strategy": "parallel" if strategy.startswith("p") else "sequential",
        "ring_seconds": int(ring),
        "residents": []
    })
    save_db(db)
    C.print("[green]AP criado.[/green]")

def add_resident(db: Dict[str, Any]) -> None:
    C.print(header(db))
    ap = choose_ap(db, "Selecionar AP para adicionar morador")
    if not ap:
        return

    name = norm(prompt("Nome do morador"))
    if not name:
        C.print("[red]Nome inválido.[/red]")
        return

    sip = norm(prompt("SIP do morador (único) (ex: 1011). Enter = auto"))
    if not sip:
        base = str(ap["dial_ext"])
        used = {r["sip"] for r in ap.get("residents", [])}
        for i in range(1, 100):
            cand = f"{base}{i}"
            if cand not in used:
                sip = cand
                break

    used_global = set()
    for a in db.get("apartments", []):
        for r in a.get("residents", []):
            used_global.add(r.get("sip"))
    if sip in used_global or sip == str(db.get("portaria", {}).get("sip", "1000")):
        C.print("[red]SIP já em uso. Escolha outro.[/red]")
        return

    password = norm(prompt("Senha SIP (Enter = gerar)")) or gen_pass()
    pr = norm(prompt("Prioridade (menor toca antes) (padrão 10)")) or "10"

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

def remove_resident(db: Dict[str, Any]) -> None:
    C.print(header(db))
    ap = choose_ap(db, "Selecionar AP para remover morador")
    if not ap:
        return

    if not ap.get("residents"):
        C.print("[yellow]Esse AP não tem moradores.[/yellow]")
        return

    t = Table(box=box.SIMPLE_HEAVY)
    t.add_column("#", justify="right", style="bold")
    t.add_column("Nome", style="bold")
    t.add_column("SIP", style="bold")
    t.add_column("Prioridade", justify="right")
    residents = sorted(ap.get("residents", []), key=lambda r: (int(r.get("priority", 10)), str(r.get("name", "")).lower()))
    for i, r in enumerate(residents, start=1):
        t.add_row(str(i), str(r.get("name")), str(r.get("sip")), str(r.get("priority", 10)))
    C.print(t)

    ans = prompt("Digite o número (#) ou SIP para remover. Enter cancela")
    if not ans:
        return

    target_sip = None
    if ans.isdigit():
        idx = int(ans)
        if 1 <= idx <= len(residents):
            target_sip = str(residents[idx-1].get("sip"))
        else:
            target_sip = ans
    else:
        target_sip = ans

    before = len(ap.get("residents", []))
    ap["residents"] = [r for r in ap.get("residents", []) if str(r.get("sip")) != str(target_sip)]
    after = len(ap.get("residents", []))
    save_db(db)
    C.print("[green]Removido.[/green]" if after < before else "[yellow]Nada removido.[/yellow]")

def remove_apartment(db: Dict[str, Any]) -> None:
    C.print(header(db))
    ap = choose_ap(db, "Selecionar AP para remover")
    if not ap:
        return

    conf = prompt(f"Confirma remover {ap.get('label')} / {ap.get('dial_ext')} ? (digite SIM)")
    if conf.strip().upper() != "SIM":
        C.print("[yellow]Cancelado.[/yellow]")
        return

    ap_id = ap.get("id")
    before = len(db.get("apartments", []))
    db["apartments"] = [a for a in db.get("apartments", []) if a.get("id") != ap_id]
    after = len(db.get("apartments", []))
    save_db(db)
    C.print("[green]AP removido.[/green]" if after < before else "[yellow]Nada removido.[/yellow]")

def portaria_settings(db: Dict[str, Any]) -> None:
    C.print(header(db))
    p = db.get("portaria", {"sip": "1000", "name": "Portaria", "password": gen_pass()})

    C.print("\n[bold]Portaria (ramal 1000)[/bold]")
    C.print(f"SIP atual: [bold]{p.get('sip','1000')}[/bold] (recomendado manter 1000)")
    C.print(f"Nome atual: [bold]{p.get('name','Portaria')}[/bold]")

    name = norm(prompt("Novo nome (Enter mantém)"))
    if name:
        p["name"] = name

    passwd = norm(prompt("Nova senha SIP (Enter = gerar nova / vazio mantém?) [G=gerar / Enter mantém]"))
    # comportamento:
    # - se usuário digitar "G": gera
    # - se usuário deixar vazio: mantém
    # - se digitar algo: usa
    if passwd.upper() == "G":
        p["password"] = gen_pass()
    elif passwd:
        p["password"] = passwd

    p["sip"] = str(p.get("sip", "1000")).strip() or "1000"
    db["portaria"] = p
    save_db(db)

    C.print(f"[green]Portaria atualizada.[/green] SIP={p['sip']} | SENHA={p['password']}")

def live_dashboard() -> None:
    C.print("[bold]CTRL+C[/bold] para sair do modo tático.")
    with Live(refresh_per_second=1, console=C) as live:
        while True:
            db = load_db()
            layout = Table.grid(expand=True)
            layout.add_row(header(db))
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
        C.print(header(db))
        C.print("\n[bold]1)[/bold] Dashboard tático (live)")
        C.print("[bold]2)[/bold] Criar AP (unidade)")
        C.print("[bold]3)[/bold] Criar morador (SIP por pessoa)")
        C.print("[bold]4)[/bold] Remover morador")
        C.print("[bold]5)[/bold] Remover AP")
        C.print("[bold]6)[/bold] Sincronizar Asterisk (gera configs + reload)")
        C.print("[bold]7)[/bold] Monitor logs Asterisk (tail -f)")
        C.print("[bold]8)[/bold] Console Asterisk (asterisk -rvvvvv)")
        C.print("[bold]9)[/bold] Portaria (ramal 1000) - alterar senha")
        C.print("[bold]0)[/bold] Sair\n")

        op = prompt("Seleção")
        if op == "1":
            try:
                live_dashboard()
            except KeyboardInterrupt:
                pass
        elif op == "2":
            add_apartment(db); time.sleep(1)
        elif op == "3":
            add_resident(db); time.sleep(2)
        elif op == "4":
            remove_resident(db); time.sleep(1)
        elif op == "5":
            remove_apartment(db); time.sleep(1)
        elif op == "6":
            sync_asterisk(db)
            C.print("[green]Sincronizado e Asterisk recarregado.[/green]")
            time.sleep(1)
        elif op == "7":
            tail_logs()
        elif op == "8":
            os.system("asterisk -rvvvvv")
        elif op == "9":
            portaria_settings(db)
            time.sleep(2)
        elif op == "0":
            break

if __name__ == "__main__":
    menu()
