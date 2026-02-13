#!/usr/bin/env python3
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, List, Optional, Tuple

import psutil
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, Container
from textual.reactive import reactive
from textual.screen import ModalScreen
from textual.widgets import (
    Header, Footer, Static, DataTable, Button, Input, Label, RichLog
)

# =========================
# Paths (Debian padrão)
# =========================
APP_DIR = "/opt/interfone"
DATA_DIR = f"{APP_DIR}/data"
DB_FILE = f"{DATA_DIR}/condominio.json"

AST_PJSIP_USERS = "/etc/asterisk/pjsip_users.conf"
AST_EXT_USERS = "/etc/asterisk/extensions_users.conf"

AST_LOG_MESSAGES = "/var/log/asterisk/messages"
AST_LOG_FULL = "/var/log/asterisk/full"
AST_CDR_MASTER = "/var/log/asterisk/cdr-csv/Master.csv"

PORTARIA_ENDPOINT = "1000"   # PJSIP/1000 (portaria)
PORTARIA_SHORT_EXT = "0"     # discagem rápida 0

# =========================
# Model
# =========================
@dataclass
class User:
    ramal: str
    senha: str
    nome: str
    bloco: str
    ap: str
    allowed: List[str]

    def callerid(self) -> str:
        # Ex: "Luanque (BlA-Ap101)" <101>
        safe_name = self.nome.replace('"', "").strip()
        safe_bl = self.bloco.replace(" ", "").strip()
        safe_ap = self.ap.replace(" ", "").strip()
        return f"\"{safe_name} (Bl{safe_bl}-Ap{safe_ap})\" <{self.ramal}>"


# =========================
# Backend (Asterisk + DB)
# =========================
class InterfoneBackend:
    def __init__(self) -> None:
        self.sip_logger_on = False
        self._last_log_pos = 0
        self._log_cache: List[str] = []

    # ---------- Helpers ----------
    @staticmethod
    def _run(cmd: List[str], timeout: int = 6) -> Tuple[int, str]:
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            out = (p.stdout or "") + (p.stderr or "")
            return p.returncode, out.strip()
        except Exception as e:
            return 1, str(e)

    @staticmethod
    def asterisk_rx(command: str) -> str:
        code, out = InterfoneBackend._run(["asterisk", "-rx", command])
        return out if code == 0 else ""

    @staticmethod
    def systemctl_is_active(service: str) -> bool:
        code, out = InterfoneBackend._run(["systemctl", "is-active", service])
        return code == 0 and "active" in out

    # ---------- DB ----------
    def load_db(self) -> Tuple[Dict, List[User]]:
        if not os.path.exists(DB_FILE):
            return {"meta": {"name": "Condominio"}, "users": []}, []

        try:
            with open(DB_FILE, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except Exception:
            raw = {"meta": {"name": "Condominio"}, "users": []}

        users: List[User] = []
        for u in raw.get("users", []):
            users.append(User(
                ramal=str(u.get("ramal", "")).strip(),
                senha=str(u.get("senha", "")).strip(),
                nome=str(u.get("nome", "")).strip(),
                bloco=str(u.get("bloco", "")).strip(),
                ap=str(u.get("ap", "")).strip(),
                allowed=list(u.get("allowed", ["0"]))  # por padrão, liga pra portaria
            ))
        return raw, users

    def save_db(self, meta: Dict, users: List[User]) -> None:
        os.makedirs(DATA_DIR, exist_ok=True)
        payload = {
            "meta": meta.get("meta", {"name": "Condominio", "updated_at": "now"}),
            "users": [
                {
                    "ramal": u.ramal,
                    "senha": u.senha,
                    "nome": u.nome,
                    "bloco": u.bloco,
                    "ap": u.ap,
                    "allowed": u.allowed,
                } for u in users
            ]
        }
        payload["meta"]["updated_at"] = datetime.now().isoformat(timespec="seconds")

        tmp = DB_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2, ensure_ascii=False)
        os.replace(tmp, DB_FILE)

        try:
            os.chmod(DB_FILE, 0o640)
        except Exception:
            pass

    # ---------- Sync configs ----------
    def sync_to_asterisk(self, users: List[User]) -> None:
        # Gera PJSIP users + dialplan por usuário (contexto individual com ACL de discagem)
        pjsip_lines: List[str] = []
        ext_lines: List[str] = []

        for u in users:
            r = u.ramal
            s = u.senha
            cid = u.callerid()

            # PJSIP (usando templates)
            pjsip_lines += [
                f"; ===== USER {r} =====",
                f"[{r}](auth-template)",
                f"username={r}",
                f"password={s}",
                "",
                f"[{r}](aor-template)",
                "",
                f"[{r}](endpoint-template)",
                f"auth={r}",
                f"aors={r}",
                f"callerid={cid}",
                f"context=interfone-{r}",
                "",
            ]

            # Dialplan por contexto (Allowed destinations)
            allowed = [x.strip() for x in (u.allowed or []) if x.strip()]
            if PORTARIA_SHORT_EXT not in allowed:
                allowed.insert(0, PORTARIA_SHORT_EXT)

            ext_lines += [
                f"; ===== CONTEXT {r} ({u.nome}) =====",
                f"[interfone-{r}]",
                f"exten => {r},1,NoOp(Chamada interna p/ {u.nome})",
                f" same => n,Dial(PJSIP/{r},30)",
                f" same => n,Hangup()",
                "",
                f"; Discagens permitidas (ACL)",
            ]

            for dest in allowed:
                if dest == PORTARIA_SHORT_EXT:
                    ext_lines += [
                        f"exten => {PORTARIA_SHORT_EXT},1,NoOp({u.nome} chamando Portaria)",
                        f" same => n,Dial(PJSIP/{PORTARIA_ENDPOINT},30)",
                        f" same => n,Hangup()",
                        "",
                    ]
                else:
                    # permite discar ramais específicos
                    ext_lines += [
                        f"exten => {dest},1,NoOp({u.nome} chamando {dest})",
                        f" same => n,Dial(PJSIP/{dest},30)",
                        f" same => n,Hangup()",
                        "",
                    ]

            # fallback (nega tudo)
            ext_lines += [
                f"exten => _X.,1,NoOp(NEGADO: {u.nome} tentou discar ${{EXTEN}})",
                f" same => n,Hangup()",
                "",
            ]

        self._safe_write(AST_PJSIP_USERS, "\n".join(pjsip_lines).strip() + "\n")
        self._safe_write(AST_EXT_USERS, "\n".join(ext_lines).strip() + "\n")

        # reload
        self.asterisk_reload()

    @staticmethod
    def _safe_write(path: str, content: str) -> None:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o640)
        except Exception:
            pass

    # ---------- Controls ----------
    def asterisk_reload(self) -> None:
        self.asterisk_rx("core reload")

    def toggle_sip_logger(self) -> bool:
        self.sip_logger_on = not self.sip_logger_on
        self.asterisk_rx("pjsip set logger " + ("on" if self.sip_logger_on else "off"))
        return self.sip_logger_on

    # ---------- State collectors ----------
    def collect_system(self) -> Dict:
        vm = psutil.virtual_memory()
        du = psutil.disk_usage("/")
        cpu = psutil.cpu_percent(interval=None)
        boot = datetime.fromtimestamp(psutil.boot_time())
        uptime = datetime.now() - boot

        return {
            "cpu": cpu,
            "ram_used_gb": vm.used / (1024**3),
            "ram_total_gb": vm.total / (1024**3),
            "disk_used_gb": du.used / (1024**3),
            "disk_total_gb": du.total / (1024**3),
            "uptime": str(uptime).split(".")[0],
        }

    def collect_endpoints(self) -> Dict[str, Dict]:
        """
        Retorna status por ramal usando:
        - pjsip show contacts  (online/offline + RTT)
        """
        out = self.asterisk_rx("pjsip show contacts")
        status: Dict[str, Dict] = {}

        # Exemplo de linha (varia):
        #  101/sip:101@1.2.3.4:5060;...  Avail  23.456ms
        for line in out.splitlines():
            line = line.strip()
            if not line or line.lower().startswith("contact:") or line.lower().startswith("=== "):
                continue
            if "/" not in line:
                continue

            parts = re.split(r"\s+", line)
            if len(parts) < 2:
                continue

            aor_uri = parts[0]
            aor = aor_uri.split("/")[0]
            st = parts[1]
            rtt = parts[2] if len(parts) >= 3 else ""
            online = st.lower().startswith("avail")

            status[aor] = {
                "online": online,
                "status": st,
                "rtt": rtt,
                "contact": aor_uri.split("/", 1)[1] if "/" in aor_uri else "",
            }

        return status

    def collect_active_calls(self) -> List[Dict]:
        out = self.asterisk_rx("core show channels concise")
        calls: List[Dict] = []
        for line in out.splitlines():
            if "!" not in line:
                continue
            parts = line.split("!")
            if len(parts) < 8:
                continue
            channel, context, exten, _, state, app, data, callerid = parts[:8]
            calls.append({
                "channel": channel,
                "context": context,
                "exten": exten,
                "state": state,
                "app": app,
                "callerid": callerid,
                "data": data,
            })
        return calls

    def collect_recent_cdr(self, limit: int = 25) -> List[Dict]:
        if not os.path.exists(AST_CDR_MASTER):
            return []
        try:
            with open(AST_CDR_MASTER, "r", encoding="utf-8", errors="ignore") as f:
                lines = f.read().splitlines()
        except Exception:
            return []

        # Pega últimas linhas úteis
        tail = [l for l in lines[-(limit * 2):] if l.strip()][-limit:]
        items: List[Dict] = []

        # Master.csv formato Asterisk (padrão):
        # accountcode,src,dst,dcontext,clid,channel,dstchannel,lastapp,lastdata,start,answer,end,duration,billsec,disposition,amaflags,uniqueid,userfield
        for l in reversed(tail):
            cols = self._csv_split(l)
            if len(cols) < 15:
                continue
            items.append({
                "src": cols[1],
                "dst": cols[2],
                "clid": cols[4],
                "start": cols[9],
                "duration": cols[12],
                "billsec": cols[13],
                "disp": cols[14],
            })
        return items

    @staticmethod
    def _csv_split(line: str) -> List[str]:
        # split CSV simples preservando aspas
        out = []
        cur = ""
        inq = False
        for ch in line:
            if ch == '"':
                inq = not inq
                cur += ch
            elif ch == "," and not inq:
                out.append(cur.strip().strip('"'))
                cur = ""
            else:
                cur += ch
        out.append(cur.strip().strip('"'))
        return out

    def tail_tactical_logs(self, max_lines: int = 120) -> List[str]:
        """
        Tail incremental com filtro tático (register/auth/dial/hangup).
        """
        path = AST_LOG_MESSAGES if os.path.exists(AST_LOG_MESSAGES) else AST_LOG_FULL
        if not os.path.exists(path):
            return ["(log do Asterisk não encontrado em /var/log/asterisk)"]

        # Leitura incremental (mantém ponteiro simples)
        try:
            size = os.path.getsize(path)
            if self._last_log_pos > size:
                self._last_log_pos = 0

            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                f.seek(self._last_log_pos)
                chunk = f.read()
                self._last_log_pos = f.tell()
        except Exception as e:
            return [f"(erro lendo log: {e})"]

        if chunk:
            for raw in chunk.splitlines():
                line = raw.strip()
                if not line:
                    continue

                key = line.lower()
                if (
                    "registered" in key or
                    "unregistered" in key or
                    "unauthorized" in key or
                    "failed" in key and "auth" in key or
                    "dial" in key or
                    "hangup" in key or
                    "call" in key and "answered" in key
                ):
                    self._log_cache.append(line)

            # limita cache
            self._log_cache = self._log_cache[-1000:]

        return self._log_cache[-max_lines:]


# =========================
# UI (Textual) - Modal Add
# =========================
class AddUserModal(ModalScreen[Optional[User]]):
    def compose(self) -> ComposeResult:
        yield Container(
            Vertical(
                Label("Cadastrar Morador (Tactical)", id="title"),
                Input(placeholder="Nome do morador", id="nome"),
                Horizontal(
                    Input(placeholder="Bloco/Torre (ex: A)", id="bloco"),
                    Input(placeholder="Apartamento (ex: 101)", id="ap"),
                ),
                Horizontal(
                    Input(placeholder="Ramal (ex: 101)", id="ramal"),
                    Input(placeholder="Senha SIP (vazio => coltseals)", id="senha", password=True),
                ),
                Input(placeholder="Permitidos (ex: 0,101,102) | vazio => só portaria (0)", id="allowed"),
                Horizontal(
                    Button("Salvar + Sync", variant="success", id="save"),
                    Button("Cancelar", variant="error", id="cancel"),
                ),
                id="modal",
            ),
            id="modal_wrap"
        )

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "cancel":
            self.dismiss(None)
            return

        nome = self.query_one("#nome", Input).value.strip()
        bloco = self.query_one("#bloco", Input).value.strip()
        ap = self.query_one("#ap", Input).value.strip()
        ramal = self.query_one("#ramal", Input).value.strip()
        senha = self.query_one("#senha", Input).value.strip() or "coltseals"
        allowed_raw = self.query_one("#allowed", Input).value.strip()

        if not (nome and bloco and ap and ramal):
            # mantém modal aberto
            return

        allowed = [x.strip() for x in allowed_raw.split(",") if x.strip()] if allowed_raw else ["0"]

        self.dismiss(User(
            ramal=ramal,
            senha=senha,
            nome=nome,
            bloco=bloco,
            ap=ap,
            allowed=allowed
        ))


# =========================
# Tactical App
# =========================
class InterfoneTactical(App):
    CSS = """
    #root { height: 100%; }
    #main { height: 1fr; }
    #left { width: 40%; min-width: 48; }
    #right { width: 60%; }
    #stats { height: auto; padding: 1; }
    #hint { height: auto; padding: 1; }
    #tables { height: 1fr; }
    #users_table { height: 1fr; }
    #calls_table { height: 1fr; }
    #log { height: 1fr; }
    #modal_wrap { align: center middle; height: 100%; }
    #modal { width: 78; padding: 1; border: round $accent; background: $panel; }
    #title { text-style: bold; padding-bottom: 1; }
    """

    BINDINGS = [
        ("a", "add_user", "Add"),
        ("d", "delete_user", "Delete"),
        ("s", "sync", "Sync"),
        ("r", "reload_ast", "Reload"),
        ("l", "toggle_logger", "Logger"),
        ("q", "quit", "Quit"),
    ]

    backend = InterfoneBackend()

    # reactive state
    ast_online = reactive(False)
    last_sync = reactive("—")
    condo_name = reactive("Condominio")

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)
        with Horizontal(id="main"):
            with Vertical(id="left"):
                yield Static("", id="stats")
                yield Static("", id="hint")
                yield DataTable(id="users_table")
                yield DataTable(id="calls_table")
            with Vertical(id="right"):
                yield RichLog(id="log", wrap=True, markup=False)
        yield Footer()

    def on_mount(self) -> None:
        if os.geteuid() != 0:
            self.exit(message="Rode como root: sudo python interfone.py")

        # Setup tables
        users = self.query_one("#users_table", DataTable)
        users.add_columns("Ramal", "Local", "Morador", "Status", "RTT")
        users.zebra_stripes = True

        calls = self.query_one("#calls_table", DataTable)
        calls.add_columns("Tipo", "SRC", "DST", "Estado", "Info")
        calls.zebra_stripes = True

        log = self.query_one("#log", RichLog)
        log.write("[Tactical] Painel iniciado. Aguardando telemetria...")

        self.set_interval(1.0, self.refresh_all)

    # ---------- Actions ----------
    def action_add_user(self) -> None:
        self.push_screen(AddUserModal(), self._on_add_user_done)

    def _on_add_user_done(self, user: Optional[User]) -> None:
        if not user:
            return
        meta, users = self.backend.load_db()

        # evita duplicados
        users = [u for u in users if u.ramal != user.ramal]
        users.append(user)

        self.backend.save_db(meta, users)
        self.backend.sync_to_asterisk(users)
        self.last_sync = datetime.now().strftime("%H:%M:%S")

        self.query_one("#log", RichLog).write(f"[DB] Morador {user.nome} (ramal {user.ramal}) salvo + sync.")

    def action_delete_user(self) -> None:
        table = self.query_one("#users_table", DataTable)
        if table.row_count == 0 or table.cursor_row is None:
            return

        ramal = str(table.get_cell_at(table.cursor_row, 0))
        if not ramal:
            return

        meta, users = self.backend.load_db()
        users2 = [u for u in users if u.ramal != ramal]
        self.backend.save_db(meta, users2)
        self.backend.sync_to_asterisk(users2)
        self.last_sync = datetime.now().strftime("%H:%M:%S")
        self.query_one("#log", RichLog).write(f"[DB] Removido ramal {ramal} + sync.")

    def action_sync(self) -> None:
        meta, users = self.backend.load_db()
        self.backend.sync_to_asterisk(users)
        self.last_sync = datetime.now().strftime("%H:%M:%S")
        self.query_one("#log", RichLog).write("[AST] Sync manual executado (PJSIP + Dialplan + reload).")

    def action_reload_ast(self) -> None:
        self.backend.asterisk_reload()
        self.query_one("#log", RichLog).write("[AST] core reload executado.")

    def action_toggle_logger(self) -> None:
        state = self.backend.toggle_sip_logger()
        self.query_one("#log", RichLog).write(f"[AST] PJSIP logger: {'ON' if state else 'OFF'}")

    # ---------- Refresh ----------
    def refresh_all(self) -> None:
        # System + Asterisk status
        sysinfo = self.backend.collect_system()
        self.ast_online = self.backend.systemctl_is_active("asterisk")

        meta, users = self.backend.load_db()
        self.condo_name = meta.get("meta", {}).get("name", "Condominio")

        endpoint_status = self.backend.collect_endpoints()
        active_calls = self.backend.collect_active_calls()
        recent_cdr = self.backend.collect_recent_cdr(limit=12)
        logs = self.backend.tail_tactical_logs(max_lines=120)

        # Render stats
        ast = "ONLINE" if self.ast_online else "OFFLINE"
        stats = (
            f"🏢 {self.condo_name}\n"
            f"🛰️  ASTERISK: {ast}   |   Last Sync: {self.last_sync}\n"
            f"⚙️  CPU: {sysinfo['cpu']:.1f}%   "
            f"🧠 RAM: {sysinfo['ram_used_gb']:.2f}/{sysinfo['ram_total_gb']:.2f} GB   "
            f"💾 DISK: {sysinfo['disk_used_gb']:.1f}/{sysinfo['disk_total_gb']:.1f} GB\n"
            f"⏱️  Uptime: {sysinfo['uptime']}\n"
        )
        self.query_one("#stats", Static).update(stats)

        # Hints
        hint = (
            "Hotkeys: [A] Add  [D] Delete  [S] Sync  [R] Reload  [L] Logger  [Q] Quit\n"
            "Dica: ramal 0 chama a Portaria (PJSIP/1000)."
        )
        self.query_one("#hint", Static).update(hint)

        # Render users table
        ut = self.query_one("#users_table", DataTable)
        ut.clear()
        for u in sorted(users, key=lambda x: x.ramal):
            st = endpoint_status.get(u.ramal, {})
            online = st.get("online", False)
            status_txt = "ON" if online else "OFF"
            rtt = st.get("rtt", "")
            loc = f"Bl {u.bloco} Ap {u.ap}"
            ut.add_row(u.ramal, loc, u.nome, status_txt, rtt)

        # Render calls table
        ct = self.query_one("#calls_table", DataTable)
        ct.clear()

        # Ativas
        if active_calls:
            for c in active_calls[:12]:
                ct.add_row("ATIVA", c.get("callerid", ""), c.get("exten", ""), c.get("state", ""), c.get("app", ""))
        else:
            ct.add_row("ATIVA", "-", "-", "-", "-")

        # Últimas do CDR
        if recent_cdr:
            for c in recent_cdr[:8]:
                ct.add_row("CDR", c.get("src", ""), c.get("dst", ""), c.get("disp", ""), f"{c.get('billsec','0')}s")
        else:
            ct.add_row("CDR", "-", "-", "-", "-")

        # Logs
        logw = self.query_one("#log", RichLog)
        logw.clear()
        for l in logs:
            logw.write(l)


if __name__ == "__main__":
    InterfoneTactical().run()
