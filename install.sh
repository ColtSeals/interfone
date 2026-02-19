#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# INTERFONE • INSTALL (Debian 13)
# Asterisk 22 LTS (source) + PJSIP + Dialplan gerado (condo.json)
#
# FOCO PROFISSIONAL:
#  - Política de chamadas (anti-trote) no dialplan (sempre valida)
#  - Ativo/Inativo + validade (expires_at) por ramal
#  - Guardião (systemd timer) revalida e regenera configs
#  - CDR (histórico) em CSV com permissões corretas
#  - Vídeo mais estável (ICE/AVPF/RTCP-MUX/NAT)
# ==========================================================

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

SRC_BASE="/usr/src/interfone-asterisk"
ASTERISK_SERIES="${ASTERISK_SERIES:-22}"     # 22 LTS
JOBS="${JOBS:-1}"

GEN_DIR="/etc/asterisk/interfone"
PJSIP_GEN="$GEN_DIR/pjsip.interfone.generated.conf"
EXT_GEN="$GEN_DIR/extensions.interfone.generated.conf"

GUARD_BIN="/usr/local/sbin/interfone-guard"
GUARD_PY="/usr/local/lib/interfone-guard.py"

NO_UFW=0
FORCE_REBUILD=0
ONLY_APPLY=0

log(){ echo -e "[INFO] $*"; }
warn(){ echo -e "[WARN] $*" >&2; }
die(){ echo -e "[ERRO] $*" >&2; exit 1; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Use: sudo bash install.sh"; }

usage(){
  cat <<'U'
Uso:
  sudo bash install.sh
  sudo bash install.sh --apply-only
  sudo bash install.sh --no-ufw
  sudo bash install.sh --force-rebuild

Env:
  ASTERISK_SERIES=22
  JOBS=1
U
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-ufw) NO_UFW=1; shift;;
      --force-rebuild) FORCE_REBUILD=1; shift;;
      --apply-only) ONLY_APPLY=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "Arg inválido: $1";;
    esac
  done
}

detect_public_ip(){
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [[ -z "$ip" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  if [[ -z "$ip" ]] && command -v curl >/dev/null 2>&1; then
    ip="$(curl -4fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -4fsS --max-time 2 https://ifconfig.me 2>/dev/null || true)"
  fi
  [[ -n "$ip" ]] || die "Não consegui detectar IP público/local da VPS."
  echo "$ip"
}

find_asterisk_bin(){
  if command -v asterisk >/dev/null 2>&1; then command -v asterisk; return 0; fi
  [[ -x /usr/sbin/asterisk ]] && { echo "/usr/sbin/asterisk"; return 0; }
  [[ -x /usr/local/sbin/asterisk ]] && { echo "/usr/local/sbin/asterisk"; return 0; }
  return 1
}

ensure_seed_config(){
  install -d "$APP_DIR"
  chmod 700 "$APP_DIR"

  if [[ ! -f "$CFG" ]]; then
    cat > "$CFG" <<'JSON'
{
  "policy": {
    "default_resident_can_call": ["PORTARIA"],
    "allow_resident_to_resident": false
  },
  "portaria": {
    "ramal": "1000",
    "nome": "PORTARIA",
    "senha": "",
    "active": true,
    "expires_at": null
  },
  "apartamentos": [
    {
      "numero": "101",
      "nome": "AP 101",
      "active": true,
      "expires_at": null,
      "moradores": [
        {
          "ramal": "10101",
          "nome": "AP101-01",
          "senha": "",
          "active": true,
          "expires_at": null,
          "can_call": []
        }
      ]
    }
  ]
}
JSON
    chmod 600 "$CFG"
  fi
}

ensure_integrations(){
  [[ -f "$INTEG_TXT" ]] && return 0

  local AMI_USER="laravel" ARI_USER="ari"
  local AMI_PASS ARI_PASS

  AMI_PASS="$(python3 - <<'PY'
import secrets,string
a=string.ascii_letters+string.digits
print(''.join(secrets.choice(a) for _ in range(28)))
PY
)"
  ARI_PASS="$(python3 - <<'PY'
import secrets,string
a=string.ascii_letters+string.digits
print(''.join(secrets.choice(a) for _ in range(28)))
PY
)"
  cat > "$INTEG_TXT" <<EOF
AMI (localhost-only):
  host: 127.0.0.1
  port: 5038
  user: $AMI_USER
  pass: $AMI_PASS

ARI (localhost-only):
  url: http://127.0.0.1:8088/ari/
  user: $ARI_USER
  pass: $ARI_PASS
EOF
  chmod 600 "$INTEG_TXT"
}

ensure_asterisk_user(){
  getent group asterisk >/dev/null || addgroup --system asterisk
  id asterisk >/dev/null 2>&1 || adduser --system --ingroup asterisk --home /var/lib/asterisk --no-create-home --disabled-login asterisk

  install -d -o asterisk -g asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk || true
  chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true
}

install_deps(){
  log "Instalando dependências..."
  apt update -y
  apt install -y \
    ca-certificates curl wget git \
    build-essential pkg-config \
    python3 python3-venv \
    libedit-dev libjansson-dev libxml2-dev uuid-dev libsqlite3-dev \
    libssl-dev libncurses-dev libnewt-dev \
    libcurl4-openssl-dev \
    ufw \
    iproute2 procps \
    logrotate \
    jq \
    tzdata
}

build_asterisk_from_source(){
  if find_asterisk_bin >/dev/null 2>&1 && [[ "$FORCE_REBUILD" -eq 0 ]]; then
    log "Asterisk já instalado ($(find_asterisk_bin)). Pulando build."
    return 0
  fi

  log "Compilando Asterisk ${ASTERISK_SERIES} (source)..."
  rm -rf "$SRC_BASE"
  mkdir -p "$SRC_BASE"
  cd "$SRC_BASE"

  local tar="asterisk-${ASTERISK_SERIES}-current.tar.gz"
  local url="https://downloads.asterisk.org/pub/telephony/asterisk/${tar}"

  log "Baixando: $url"
  curl -fL "$url" -o "$tar"
  tar xzf "$tar"

  local dir
  dir="$(find . -maxdepth 1 -type d -name "asterisk-*" | head -n1)"
  [[ -n "${dir:-}" ]] || die "Não achei pasta asterisk-* após extrair."
  cd "$dir"

  yes | contrib/scripts/install_prereq install >/dev/null 2>&1 || warn "install_prereq falhou; seguindo com deps do apt."

  ./configure

  # evita BUILD_NATIVE (VPS virtual às vezes gera binário que não roda)
  if [[ -x menuselect/menuselect ]]; then
    menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts >/dev/null 2>&1 || true
  fi

  make -j"$JOBS"
  make install
  make samples || true
  make install-logrotate || true

  if [[ -x /usr/local/sbin/asterisk && ! -x /usr/sbin/asterisk ]]; then
    ln -sf /usr/local/sbin/asterisk /usr/sbin/asterisk
  fi

  find_asterisk_bin >/dev/null 2>&1 || die "Asterisk não apareceu após install."
}

write_systemd_unit(){
  local AST_BIN
  AST_BIN="$(find_asterisk_bin || true)"
  [[ -n "${AST_BIN:-}" ]] || die "Sem asterisk binário para criar service."

  log "Criando systemd unit..."
  cat > /etc/systemd/system/asterisk.service <<EOF
[Unit]
Description=Asterisk PBX (Interfone)
After=network.target

[Service]
Type=simple
User=asterisk
Group=asterisk

RuntimeDirectory=asterisk
RuntimeDirectoryMode=0755

ExecStart=${AST_BIN} -f -U asterisk -G asterisk -vvv
ExecReload=${AST_BIN} -rx "core reload"
ExecStop=${AST_BIN} -rx "core stop now"

Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable asterisk >/dev/null 2>&1 || true
}

write_logger_and_cdr(){
  local ETC="/etc/asterisk"
  install -d "$ETC"
  install -d /var/log/asterisk/cdr-csv

  # LOGS
  cat > "$ETC/logger.conf" <<'C'
[general]
dateformat=%F %T

[logfiles]
messages => notice,warning,error,verbose
security => security
console => notice,warning,error,verbose
C

  # CDR CSV (histórico de chamadas)
  cat > "$ETC/cdr.conf" <<'C'
[general]
enable=yes
unanswered=yes
congestion=yes
batch=no
endbeforehexten=no
C

  cat > "$ETC/cdr_csv.conf" <<'C'
[general]
usegmtime=no
loguniqueid=yes
accountlogs=yes
C

  # permissões corretas (evita Permission denied)
  chown -R asterisk:asterisk /var/log/asterisk
  chmod 750 /var/log/asterisk
  chmod 750 /var/log/asterisk/cdr-csv

  # logrotate (CDR cresce rápido)
  cat > /etc/logrotate.d/interfone-cdr <<'C'
/var/log/asterisk/cdr-csv/Master.csv {
  daily
  rotate 30
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
}
C
}

write_static_confs(){
  local ETC="/etc/asterisk"
  install -d "$ETC"
  install -d "$GEN_DIR"

  write_logger_and_cdr

  # RTP + NAT-friendly + ICE (lado Asterisk)
  cat > "$ETC/rtp.conf" <<'C'
[general]
rtpstart=10000
rtpend=20000
icesupport=yes
stunaddr=
C

  # módulos: sem chan_sip
  cat > "$ETC/modules.conf" <<'C'
[modules]
autoload=yes
noload => chan_sip.so
C

  [[ -f "$ETC/users.conf" ]] && mv -f "$ETC/users.conf" "$ETC/users.conf.bak" || true

  # AMI/ARI localhost-only
  local AMI_USER AMI_PASS ARI_USER ARI_PASS
  AMI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | head -n1)"
  AMI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | head -n1)"
  ARI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | tail -n1)"
  ARI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | tail -n1)"

  cat > "$ETC/manager.conf" <<EOF
[general]
enabled=yes
port=5038
bindaddr=127.0.0.1
displayconnects=no

[$AMI_USER]
secret=$AMI_PASS
deny=0.0.0.0/0.0.0.0
permit=127.0.0.1/255.255.255.255
read=system,call,log,verbose,command,agent,user,config,dtmf,reporting,cdr,dialplan
write=system,call,command,agent,user,config,reporting,originate
EOF

  cat > "$ETC/http.conf" <<'C'
[general]
enabled=yes
bindaddr=127.0.0.1
bindport=8088
C

  cat > "$ETC/ari.conf" <<EOF
[general]
enabled=yes
pretty=yes

[$ARI_USER]
type=user
read_only=no
password=$ARI_PASS
EOF

  # include gerados
  grep -q "interfone.generated" "$ETC/pjsip.conf" 2>/dev/null || {
    [[ -f "$ETC/pjsip.conf" ]] || echo "; base pjsip" > "$ETC/pjsip.conf"
    cat >> "$ETC/pjsip.conf" <<EOF

; ====== INTERFONE (AUTO) ======
#include ${PJSIP_GEN}
EOF
  }

  grep -q "extensions.interfone.generated" "$ETC/extensions.conf" 2>/dev/null || {
    [[ -f "$ETC/extensions.conf" ]] || echo "; base extensions" > "$ETC/extensions.conf"
    cat >> "$ETC/extensions.conf" <<EOF

; ====== INTERFONE (AUTO) ======
#include ${EXT_GEN}
EOF
  }
}

generate_all(){
  local VPS_IP="$1"
  python3 - "$CFG" "$SECRETS" "$VPS_IP" "$GEN_DIR" <<'PY'
import json, secrets, string, sys, os, re, datetime

CFG, SECRETS, VPS_IP, GEN_DIR = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def gen_pass(n=20):
    a = string.ascii_letters + string.digits + "._-@:+#="
    return "".join(secrets.choice(a) for _ in range(n))

def clean_ext(x):
    x = str(x).strip()
    if not re.fullmatch(r"\d{2,10}", x):
        raise SystemExit(f"Ramal inválido: {x} (use só dígitos, 2..10)")
    return x

def parse_dt(s):
    if s is None: return None
    s = str(s).strip()
    if not s or s.lower() in ("null","none"): return None
    if "T" in s:
        return datetime.datetime.fromisoformat(s)
    return datetime.datetime.fromisoformat(s + "T23:59:59")

def is_active(obj):
    if obj is None: return True
    if obj.get("active", True) is False:
        return False
    exp = parse_dt(obj.get("expires_at"))
    if exp and datetime.datetime.now() > exp:
        return False
    return True

data = json.load(open(CFG, "r", encoding="utf-8"))

data.setdefault("policy", {})
policy = data["policy"]
policy.setdefault("default_resident_can_call", ["PORTARIA"])
policy.setdefault("allow_resident_to_resident", False)

data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":"","active":True,"expires_at":None})
data["portaria"]["ramal"] = clean_ext(data["portaria"].get("ramal","1000") or "1000")
if not str(data["portaria"].get("senha","")).strip():
    data["portaria"]["senha"] = gen_pass()

ramais = {}
PORT_R = data["portaria"]["ramal"]

for ap in data.get("apartamentos", []):
    ap.setdefault("active", True)
    ap.setdefault("expires_at", None)
    apnum = str(ap.get("numero","")).strip()
    if not apnum or not re.fullmatch(r"\d{1,6}", apnum):
        raise SystemExit(f"Apartamento inválido: {apnum}")
    ap.setdefault("moradores", [])
    for m in ap["moradores"]:
        m["ramal"] = clean_ext(m.get("ramal",""))
        m.setdefault("nome", f"AP{apnum}")
        m.setdefault("active", True)
        m.setdefault("expires_at", None)
        m.setdefault("can_call", [])
        if not str(m.get("senha","")).strip():
            m["senha"] = gen_pass()
        if m["ramal"] in ramais or m["ramal"] == PORT_R:
            raise SystemExit(f"Ramal duplicado: {m['ramal']}")
        ramais[m["ramal"]] = {"ap": apnum, "nome": m["nome"], "obj": m}

# ---------------- PJSIP ----------------
p=[]
p.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

p.append("[global]\n")
p.append("type=global\n")
p.append("user_agent=InterfonePBX/2.0\n")
p.append("endpoint_identifier_order=auth_username,username,ip\n\n")

# UDP
p.append("[transport-udp]\n")
p.append("type=transport\nprotocol=udp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

# TCP
p.append("[transport-tcp]\n")
p.append("type=transport\nprotocol=tcp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

# Template robusto (NAT + vídeo)
p.append("[endpoint-common](!)\n")
p.append("type=endpoint\n")
p.append("transport=transport-udp\n")
p.append("disallow=all\n")
p.append("allow=ulaw,alaw,opus,vp8\n")
p.append("direct_media=no\n")
p.append("rtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\n")
p.append("media_use_received_transport=yes\n")
p.append("ice_support=yes\n")
p.append("use_avpf=yes\n")
p.append("rtcp_mux=yes\n")
p.append("timers=yes\n")
p.append("language=pt_BR\n")
p.append("allow_unauthenticated_options=no\n")
p.append("send_rpid=yes\ntrust_id_outbound=yes\ntrust_id_inbound=yes\n")
p.append("dtmf_mode=rfc4733\n")
p.append("t38_udptl=no\n\n")

p.append("[aor-common](!)\n")
p.append("type=aor\nmax_contacts=3\nremove_existing=yes\nqualify_frequency=30\n\n")

p.append("[auth-common](!)\n")
p.append("type=auth\nauth_type=userpass\n\n")

def add_user(ramal, nome, senha, context):
    p.append(f"[{ramal}](aor-common)\n\n")
    p.append(f"[{ramal}](auth-common)\nusername={ramal}\npassword={senha}\n\n")
    p.append(f"[{ramal}](endpoint-common)\n")
    p.append(f"context={context}\n")
    p.append(f"auth={ramal}\n")
    p.append(f"aors={ramal}\n")
    p.append(f"callerid=\"{nome}\" <{ramal}>\n")
    p.append("identify_by=auth_username,username\n\n")

# Portaria
add_user(PORT_R, data["portaria"].get("nome","PORTARIA"), data["portaria"]["senha"], "from-interfone")

# Moradores
for r, meta in sorted(ramais.items(), key=lambda x: x[0]):
    add_user(r, meta["nome"], meta["obj"]["senha"], "from-interfone")

open(os.path.join(GEN_DIR, "pjsip.interfone.generated.conf"), "w", encoding="utf-8").write("".join(p))

# ---------------- DIALPLAN ----------------
e=[]
e.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

e.append("[from-interfone]\n")
e.append("exten => _X.,1,NoOp(INTERFONE IN ${CALLERID(num)} -> ${EXTEN})\n")
e.append(" same => n,Set(CDR(userfield)=INTERFONE caller=${CALLERID(num)} dest=${EXTEN})\n")
e.append(" same => n,Goto(interfone-route,${EXTEN},1)\n\n")

e.append("[interfone-route]\n")
e.append("exten => _X.,1,NoOp(ROUTE ${CALLERID(num)} -> ${EXTEN})\n")

e.append(" same => n,Set(__IF_CALLER_OK=0)\n")
e.append(" same => n,Set(__IF_CALLER_NAME=UNKNOWN)\n")
e.append(" same => n,Set(__IF_CALLER_TYPE=UNKNOWN)\n")

# portaria?
e.append(f' same => n,GotoIf($["{PORT_R}"="${{CALLERID(num)}}"]?is_portaria:chk_res)\n')
e.append(" same => n(is_portaria),Set(__IF_CALLER_TYPE=PORTARIA)\n")
e.append(f" same => n,Set(__IF_CALLER_NAME={data['portaria'].get('nome','PORTARIA')})\n")
e.append(f" same => n,Set(__IF_CALLER_OK={'1' if is_active(data['portaria']) else '0'})\n")
e.append(" same => n,Goto(chk_ok)\n")

# residents
e.append(" same => n(chk_res),NoOp(CALLER resident check)\n")
for r in sorted(ramais.keys()):
    meta = ramais[r]
    apnum = meta["ap"]
    ap_obj = next((a for a in data.get("apartamentos",[]) if str(a.get("numero","")).strip()==apnum), {})
    ok = is_active(meta["obj"]) and is_active(ap_obj)

    e.append(f' same => n,GotoIf($["{r}"="${{CALLERID(num)}}"]?caller_{r}:nextcaller_{r})\n')
    e.append(f" same => n(caller_{r}),Set(__IF_CALLER_TYPE=RESIDENT)\n")
    e.append(f" same => n,Set(__IF_CALLER_NAME={meta['nome']})\n")
    e.append(f" same => n,Set(__IF_CALLER_OK={'1' if ok else '0'})\n")
    e.append(" same => n,Goto(chk_ok)\n")
    e.append(f" same => n(nextcaller_{r}),NoOp(.)\n")

e.append(" same => n,NoOp(CALLER not found)\n")
e.append(" same => n,Set(__IF_CALLER_OK=0)\n")

e.append(" same => n(chk_ok),GotoIf($[${IF_CALLER_OK}=1]?route_dest:reject)\n")
e.append(" same => n(reject),NoOp(REJECT caller=${CALLERID(num)} inactive/expired/unknown)\n")
e.append(" same => n,Playback(ss-noservice)\n")
e.append(" same => n,Hangup(403)\n\n")

# route destination
e.append("[route_dest]\n")
e.append("exten => _X.,1,NoOp(DEST ${EXTEN})\n")

dest_ramais = set([PORT_R] + list(ramais.keys()))
dest_aps = set(str(a.get("numero","")).strip() for a in data.get("apartamentos",[]) if str(a.get("numero","")).strip())

# can_call por ramal
allow_rr = bool(policy.get("allow_resident_to_resident", False))
caller_can_call = {}
for r, meta in ramais.items():
    allowed=[]
    for d in policy.get("default_resident_can_call", ["PORTARIA"]):
        allowed.append(str(d))
    if allow_rr:
        allowed.append("RESIDENTS")
    for d in meta["obj"].get("can_call", []) or []:
        allowed.append(str(d))
    caller_can_call[r] = allowed

# destino apartamento (AP): portaria sempre; morador só se explicitamente "AP:xxx"
for ap in sorted(dest_aps, key=lambda x: int(x)):
    e.append(f"exten => {ap},1,NoOp(AP {ap} ringgroup)\n")
    e.append(f" same => n,GotoIf($[\"${{IF_CALLER_TYPE}}\"=\"PORTARIA\"]?do_ap_{ap}:chk_ap_policy_{ap})\n")
    e.append(f" same => n(chk_ap_policy_{ap}),NoOp(Check policy for AP)\n")
    e.append(f" same => n,Set(__IF_ALLOWED=0)\n")

    for r in sorted(ramais.keys()):
        allowed = caller_can_call[r]
        if ("AP:"+ap) in allowed:
            e.append(f' same => n,GotoIf($["{r}"="${{CALLERID(num)}}"]?allow_ap_{ap}:next_allow_ap_{ap}_{r})\n')
            e.append(f" same => n(allow_ap_{ap}),Set(__IF_ALLOWED=1)\n")
            e.append(f" same => n,Goto(do_ap_{ap})\n")
            e.append(f" same => n(next_allow_ap_{ap}_{r}),NoOp(.)\n")

    e.append(f" same => n,GotoIf($[${{IF_ALLOWED}}=1]?do_ap_{ap}:deny_ap_{ap})\n")
    e.append(f" same => n(deny_ap_{ap}),Playback(permission-denied)\n")
    e.append(" same => n,Hangup(403)\n")

    targets=[]
    for rr, meta in ramais.items():
        if meta["ap"] == ap:
            targets.append(f"PJSIP/{rr}")
    dial="&".join(targets)

    e.append(f" same => n(do_ap_{ap}),Set(CDR(userfield)=${{CDR(userfield)}}|ap={ap})\n")
    if dial:
        e.append(f" same => n,Dial({dial},20,tT)\n")
    else:
        e.append(" same => n,Playback(vm-nobodyavail)\n")
    e.append(" same => n,Hangup()\n\n")

# destino ramal
for ext in sorted(dest_ramais, key=lambda x: int(x)):
    e.append(f"exten => {ext},1,NoOp(CALL RAMAL {ext})\n")
    e.append(f" same => n,GotoIf($[\"${{IF_CALLER_TYPE}}\"=\"PORTARIA\"]?do_call_{ext}:chk_policy_{ext})\n")
    e.append(f" same => n(chk_policy_{ext}),NoOp(Policy for resident caller)\n")

    if ext == PORT_R:
        e.append(" same => n,Set(__IF_ALLOWED=1)\n")
        e.append(f" same => n,Goto(do_call_{ext})\n")
    else:
        if allow_rr:
            e.append(" same => n,Set(__IF_ALLOWED=1)\n")
        else:
            e.append(" same => n,Set(__IF_ALLOWED=0)\n")
            for r in sorted(ramais.keys()):
                allowed = caller_can_call[r]
                if ("RAMAL:"+ext) in allowed:
                    e.append(f' same => n,GotoIf($["{r}"="${{CALLERID(num)}}"]?allow_ramal_{ext}:next_allow_ramal_{ext}_{r})\n')
                    e.append(f" same => n(allow_ramal_{ext}),Set(__IF_ALLOWED=1)\n")
                    e.append(f" same => n,Goto(do_call_{ext})\n")
                    e.append(f" same => n(next_allow_ramal_{ext}_{r}),NoOp(.)\n")

        e.append(f" same => n,GotoIf($[${{IF_ALLOWED}}=1]?do_call_{ext}:deny_{ext})\n")
        e.append(f" same => n(deny_{ext}),Playback(permission-denied)\n")
        e.append(" same => n,Hangup(403)\n")

    e.append(f" same => n(do_call_{ext}),Set(CDR(userfield)=${{CDR(userfield)}}|to={ext})\n")
    e.append(f" same => n,Dial(PJSIP/{ext},30,tT)\n")
    e.append(" same => n,Hangup()\n\n")

# fallback
e.append("exten => _X.,1,NoOp(DEST inválido)\n")
e.append(" same => n,Playback(invalid)\n")
e.append(" same => n,Hangup()\n\n")

open(os.path.join(GEN_DIR, "extensions.interfone.generated.conf"), "w", encoding="utf-8").write("".join(e))

# salva secrets (inclui senhas geradas) e normaliza CFG
json.dump(data, open(SECRETS, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
json.dump(data, open(CFG, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: gerado", os.path.join(GEN_DIR,"pjsip.interfone.generated.conf"), "e", os.path.join(GEN_DIR,"extensions.interfone.generated.conf"))
PY

  chmod 600 "$CFG" || true
  chmod 600 "$SECRETS" || true
  chmod 700 "$GEN_DIR" || true
  chown -R root:root "$GEN_DIR" || true
}

install_guard(){
  log "Instalando guardião (timer) para expiração/ativação..."

  cat > "$GUARD_PY" <<'PY'
#!/usr/bin/env python3
import os, sys, subprocess, hashlib, datetime

CFG="/opt/interfone/condo.json"
GEN_DIR="/etc/asterisk/interfone"
PJSIP_GEN=os.path.join(GEN_DIR,"pjsip.interfone.generated.conf")
EXT_GEN=os.path.join(GEN_DIR,"extensions.interfone.generated.conf")

def sha256(p):
    try:
        with open(p,"rb") as f: return hashlib.sha256(f.read()).hexdigest()
    except FileNotFoundError:
        return ""

def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def main():
    before = (sha256(PJSIP_GEN), sha256(EXT_GEN))
    r = run(["/usr/local/sbin/interfone-apply"])
    after = (sha256(PJSIP_GEN), sha256(EXT_GEN))

    if r.returncode != 0:
        print("apply failed:", r.stderr.strip(), file=sys.stderr)
        sys.exit(1)

    if before != after:
        run(["/usr/sbin/asterisk","-rx","pjsip reload"])
        run(["/usr/sbin/asterisk","-rx","dialplan reload"])
        try:
            with open("/var/log/asterisk/security.log","a",encoding="utf-8") as f:
                f.write(f"{datetime.datetime.now().strftime('%F %T')} [INTERFONE] guard reload due to config change\n")
        except Exception:
            pass

    sys.exit(0)

if __name__=="__main__":
    main()
PY
  chmod 755 "$GUARD_PY"

  # wrapper apply
  cat > /usr/local/sbin/interfone-apply <<'B'
#!/usr/bin/env bash
set -euo pipefail
CFG="/opt/interfone/condo.json"
SECRETS="/root/interfone-secrets.json"
GEN_DIR="/etc/asterisk/interfone"

detect_ip(){
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [[ -z "$ip" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  if [[ -z "$ip" ]] && command -v curl >/dev/null 2>&1; then
    ip="$(curl -4fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -4fsS --max-time 2 https://ifconfig.me 2>/dev/null || true)"
  fi
  [[ -n "$ip" ]] || { echo "no ip"; exit 1; }
  echo "$ip"
}

VPS_IP="$(detect_ip)"
mkdir -p "$GEN_DIR"
chmod 700 "$GEN_DIR"

python3 - "$CFG" "$SECRETS" "$VPS_IP" "$GEN_DIR" <<'PY'
import json, secrets, string, sys, os, re, datetime

CFG, SECRETS, VPS_IP, GEN_DIR = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def gen_pass(n=20):
    a = string.ascii_letters + string.digits + "._-@:+#="
    return "".join(secrets.choice(a) for _ in range(n))

def clean_ext(x):
    x = str(x).strip()
    if not re.fullmatch(r"\d{2,10}", x):
        raise SystemExit(f"Ramal inválido: {x}")
    return x

def parse_dt(s):
    if s is None: return None
    s=str(s).strip()
    if not s or s.lower() in ("null","none"): return None
    if "T" in s: return datetime.datetime.fromisoformat(s)
    return datetime.datetime.fromisoformat(s+"T23:59:59")

def is_active(obj):
    if obj is None: return True
    if obj.get("active", True) is False: return False
    exp=parse_dt(obj.get("expires_at"))
    if exp and datetime.datetime.now() > exp: return False
    return True

data=json.load(open(CFG,"r",encoding="utf-8"))
data.setdefault("policy", {})
policy=data["policy"]
policy.setdefault("default_resident_can_call", ["PORTARIA"])
policy.setdefault("allow_resident_to_resident", False)

data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":"","active":True,"expires_at":None})
data["portaria"]["ramal"]=clean_ext(data["portaria"].get("ramal","1000") or "1000")
if not str(data["portaria"].get("senha","")).strip():
    data["portaria"]["senha"]=gen_pass()

ramais={}
PORT_R=data["portaria"]["ramal"]

for ap in data.get("apartamentos", []):
    ap.setdefault("active", True)
    ap.setdefault("expires_at", None)
    apnum=str(ap.get("numero","")).strip()
    if not apnum or not re.fullmatch(r"\d{1,6}", apnum):
        raise SystemExit(f"Apartamento inválido: {apnum}")
    ap.setdefault("moradores", [])
    for m in ap["moradores"]:
        m["ramal"]=clean_ext(m.get("ramal",""))
        m.setdefault("nome", f"AP{apnum}")
        m.setdefault("active", True)
        m.setdefault("expires_at", None)
        m.setdefault("can_call", [])
        if not str(m.get("senha","")).strip():
            m["senha"]=gen_pass()
        if m["ramal"] in ramais or m["ramal"]==PORT_R:
            raise SystemExit(f"Ramal duplicado: {m['ramal']}")
        ramais[m["ramal"]]={"ap":apnum,"nome":m["nome"],"obj":m}

# PJSIP
p=[]
p.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")
p.append("[global]\n")
p.append("type=global\n")
p.append("user_agent=InterfonePBX/2.0\n")
p.append("endpoint_identifier_order=auth_username,username,ip\n\n")

p.append("[transport-udp]\n")
p.append("type=transport\nprotocol=udp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

p.append("[transport-tcp]\n")
p.append("type=transport\nprotocol=tcp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

p.append("[endpoint-common](!)\n")
p.append("type=endpoint\ntransport=transport-udp\n")
p.append("disallow=all\nallow=ulaw,alaw,opus,vp8\n")
p.append("direct_media=no\nrtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\n")
p.append("media_use_received_transport=yes\nice_support=yes\nuse_avpf=yes\nrtcp_mux=yes\n")
p.append("timers=yes\nlanguage=pt_BR\nallow_unauthenticated_options=no\n")
p.append("send_rpid=yes\ntrust_id_outbound=yes\ntrust_id_inbound=yes\n")
p.append("dtmf_mode=rfc4733\n\n")

p.append("[aor-common](!)\n")
p.append("type=aor\nmax_contacts=3\nremove_existing=yes\nqualify_frequency=30\n\n")

p.append("[auth-common](!)\n")
p.append("type=auth\nauth_type=userpass\n\n")

def add_user(ramal, nome, senha, context):
    p.append(f"[{ramal}](aor-common)\n\n")
    p.append(f"[{ramal}](auth-common)\nusername={ramal}\npassword={senha}\n\n")
    p.append(f"[{ramal}](endpoint-common)\ncontext={context}\nauth={ramal}\naors={ramal}\n")
    p.append(f"callerid=\"{nome}\" <{ramal}>\nidentify_by=auth_username,username\n\n")

add_user(PORT_R, data["portaria"].get("nome","PORTARIA"), data["portaria"]["senha"], "from-interfone")
for r, meta in sorted(ramais.items(), key=lambda x: x[0]):
    add_user(r, meta["nome"], meta["obj"]["senha"], "from-interfone")

open(os.path.join(GEN_DIR,"pjsip.interfone.generated.conf"),"w",encoding="utf-8").write("".join(p))

# DIALPLAN
e=[]
e.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")
e.append("[from-interfone]\n")
e.append("exten => _X.,1,NoOp(INTERFONE IN ${CALLERID(num)} -> ${EXTEN})\n")
e.append(" same => n,Set(CDR(userfield)=INTERFONE caller=${CALLERID(num)} dest=${EXTEN})\n")
e.append(" same => n,Goto(interfone-route,${EXTEN},1)\n\n")

e.append("[interfone-route]\n")
e.append("exten => _X.,1,NoOp(ROUTE ${CALLERID(num)} -> ${EXTEN})\n")
e.append(" same => n,Set(__IF_CALLER_OK=0)\n")
e.append(" same => n,Set(__IF_CALLER_TYPE=UNKNOWN)\n")
e.append(f' same => n,GotoIf($["{PORT_R}"="${{CALLERID(num)}}"]?is_portaria:chk_res)\n')
e.append(" same => n(is_portaria),Set(__IF_CALLER_TYPE=PORTARIA)\n")
e.append(f" same => n,Set(__IF_CALLER_OK={'1' if is_active(data['portaria']) else '0'})\n")
e.append(" same => n,Goto(chk_ok)\n")

e.append(" same => n(chk_res),NoOp(CALLER resident check)\n")
for r, meta in sorted(ramais.items(), key=lambda x: x[0]):
    apnum = meta["ap"]
    ap_obj = next((a for a in data.get("apartamentos",[]) if str(a.get("numero","")).strip()==apnum), {})
    ok = is_active(meta["obj"]) and is_active(ap_obj)

    e.append(f' same => n,GotoIf($["{r}"="${{CALLERID(num)}}"]?caller_{r}:nextcaller_{r})\n')
    e.append(f" same => n(caller_{r}),Set(__IF_CALLER_TYPE=RESIDENT)\n")
    e.append(f" same => n,Set(__IF_CALLER_OK={'1' if ok else '0'})\n")
    e.append(" same => n,Goto(chk_ok)\n")
    e.append(f" same => n(nextcaller_{r}),NoOp(.)\n")

e.append(" same => n,Set(__IF_CALLER_OK=0)\n")
e.append(" same => n(chk_ok),GotoIf($[${IF_CALLER_OK}=1]?route_dest:reject)\n")
e.append(" same => n(reject),Playback(ss-noservice)\n")
e.append(" same => n,Hangup(403)\n\n")

e.append("[route_dest]\n")
e.append("exten => _X.,1,NoOp(DEST ${EXTEN})\n")

dest_ramais=set([PORT_R]+list(ramais.keys()))
dest_aps=set(str(a.get("numero","")).strip() for a in data.get("apartamentos",[]) if str(a.get("numero","")).strip())

# AP calls: só portaria por default
for ap in sorted(dest_aps, key=lambda x: int(x)):
    e.append(f"exten => {ap},1,NoOp(AP {ap} ringgroup)\n")
    e.append(f" same => n,GotoIf($[\"${{IF_CALLER_TYPE}}\"=\"PORTARIA\"]?do_ap_{ap}:deny_ap_{ap})\n")
    targets=[]
    for rr, meta in ramais.items():
        if meta["ap"]==ap:
            targets.append(f"PJSIP/{rr}")
    dial="&".join(targets)
    e.append(f" same => n(do_ap_{ap}),Set(CDR(userfield)=${{CDR(userfield)}}|ap={ap})\n")
    if dial:
        e.append(f" same => n,Dial({dial},20,tT)\n")
    else:
        e.append(" same => n,Playback(vm-nobodyavail)\n")
    e.append(" same => n,Hangup()\n")
    e.append(f" same => n(deny_ap_{ap}),Playback(permission-denied)\n")
    e.append(" same => n,Hangup(403)\n\n")

# Ramal calls
allow_rr = bool(policy.get("allow_resident_to_resident", False))

caller_can = {}
for r, meta in ramais.items():
    allowed=[]
    for d in policy.get("default_resident_can_call", ["PORTARIA"]):
        allowed.append(str(d))
    if allow_rr:
        allowed.append("RESIDENTS")
    for d in meta["obj"].get("can_call", []) or []:
        allowed.append(str(d))
    caller_can[r]=set(allowed)

for ext in sorted(dest_ramais, key=lambda x: int(x)):
    e.append(f"exten => {ext},1,NoOp(CALL RAMAL {ext})\n")
    e.append(f" same => n,GotoIf($[\"${{IF_CALLER_TYPE}}\"=\"PORTARIA\"]?do_{ext}:chk_{ext})\n")
    e.append(f" same => n(chk_{ext}),Set(__IF_ALLOWED=0)\n")

    if ext == PORT_R:
        e.append(" same => n,Set(__IF_ALLOWED=1)\n")
    else:
        if allow_rr:
            e.append(" same => n,Set(__IF_ALLOWED=1)\n")
        else:
            for r in sorted(ramais.keys(), key=lambda x: int(x)):
                if f"RAMAL:{ext}" in caller_can.get(r,set()):
                    e.append(f' same => n,GotoIf($["{r}"="${{CALLERID(num)}}"]?allow_{ext}:next_{ext}_{r})\n')
                    e.append(f" same => n(allow_{ext}),Set(__IF_ALLOWED=1)\n")
                    e.append(f" same => n,Goto(go_{ext})\n")
                    e.append(f" same => n(next_{ext}_{r}),NoOp(.)\n")

    e.append(f" same => n,GotoIf($[${{IF_ALLOWED}}=1]?go_{ext}:deny_{ext})\n")
    e.append(f" same => n(deny_{ext}),Playback(permission-denied)\n")
    e.append(" same => n,Hangup(403)\n")
    e.append(f" same => n(go_{ext}),Set(CDR(userfield)=${{CDR(userfield)}}|to={ext})\n")
    e.append(f" same => n(do_{ext}),Dial(PJSIP/{ext},30,tT)\n")
    e.append(" same => n,Hangup()\n\n")

e.append("exten => _X.,1,Playback(invalid)\n same => n,Hangup()\n")
open(os.path.join(GEN_DIR,"extensions.interfone.generated.conf"),"w",encoding="utf-8").write("".join(e))

json.dump(data, open(SECRETS,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
json.dump(data, open(CFG,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK apply")
PY

chmod 600 "$CFG" "$SECRETS" 2>/dev/null || true
exit 0
B
  chmod 755 /usr/local/sbin/interfone-apply

  cat > "$GUARD_BIN" <<EOF
#!/usr/bin/env bash
exec ${GUARD_PY} "\$@"
EOF
  chmod 755 "$GUARD_BIN"

  cat > /etc/systemd/system/interfone-guard.service <<'S'
[Unit]
Description=Interfone Guard (regen + reload on changes)
After=network.target asterisk.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/interfone-guard
S

  cat > /etc/systemd/system/interfone-guard.timer <<'T'
[Unit]
Description=Interfone Guard Timer (every 2 minutes)

[Timer]
OnBootSec=45s
OnUnitActiveSec=120s
Persistent=true

[Install]
WantedBy=timers.target
T

  systemctl daemon-reload
  systemctl enable --now interfone-guard.timer >/dev/null 2>&1 || true
}

enable_firewall(){
  [[ "$NO_UFW" -eq 1 ]] && { warn "UFW ignorado (--no-ufw)."; return 0; }
  command -v ufw >/dev/null 2>&1 || { warn "ufw não instalado; pulando firewall."; return 0; }

  log "Configurando UFW (SSH + SIP 5060 UDP/TCP + RTP 10000-20000/UDP)..."
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 5060/udp >/dev/null 2>&1 || true
  ufw allow 5060/tcp >/dev/null 2>&1 || true
  ufw allow 10000:20000/udp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

dump_failure(){
  echo
  echo "==================== DIAGNÓSTICO (FALHA START) ===================="
  systemctl status asterisk --no-pager -l || true
  echo "-------------------------------------------------------------------"
  journalctl -u asterisk -n 220 --no-pager || true
  echo "-------------------------------------------------------------------"
  echo "Últimas linhas /var/log/asterisk/security.log:"
  tail -n 120 /var/log/asterisk/security.log 2>/dev/null || true
  echo "==================================================================="
  echo
}

restart_and_wait(){
  local AST_BIN
  AST_BIN="$(find_asterisk_bin || true)"
  [[ -n "${AST_BIN:-}" ]] || die "Asterisk binário não encontrado."

  log "Reiniciando Asterisk (systemd)..."
  systemctl reset-failed asterisk >/dev/null 2>&1 || true
  systemctl restart asterisk || { dump_failure; die "systemctl restart asterisk falhou"; }

  for i in {1..40}; do
    systemctl is-active --quiet asterisk && break
    sleep 0.35
  done

  systemctl is-active --quiet asterisk || { dump_failure; die "Asterisk não ficou ACTIVE."; }

  for i in {1..40}; do
    "${AST_BIN}" -rx "core show version" >/dev/null 2>&1 && { log "Asterisk OK e respondendo."; return 0; }
    sudo -u asterisk "${AST_BIN}" -rx "core show version" >/dev/null 2>&1 && { log "Asterisk OK (como asterisk)."; return 0; }
    sleep 0.35
  done

  dump_failure
  die "Asterisk não respondeu via CLI após restart."
}

main(){
  need_root
  parse_args "$@"

  local VPS_IP
  VPS_IP="$(detect_public_ip)"
  log "IP detectado: $VPS_IP"

  ensure_seed_config
  ensure_integrations

  if [[ "$ONLY_APPLY" -eq 1 ]]; then
    if find_asterisk_bin >/dev/null 2>&1; then
      log "Asterisk encontrado — aplicando configs..."
      write_static_confs
      generate_all "$VPS_IP"
      restart_and_wait
      systemctl restart interfone-guard.timer >/dev/null 2>&1 || true
      log "APPLY finalizado ✅"
      exit 0
    else
      warn "Asterisk não encontrado — vou instalar e depois aplicar."
    fi
  fi

  install_deps
  ensure_asterisk_user
  build_asterisk_from_source
  write_systemd_unit

  write_static_confs
  generate_all "$VPS_IP"
  install_guard
  enable_firewall
  restart_and_wait

  echo
  echo "=========================== INSTALADO ✅ ==========================="
  echo "Asterisk: $(find_asterisk_bin)"
  echo "Service:  systemctl status asterisk"
  echo "Guard:    systemctl status interfone-guard.timer"
  echo "Senhas:   $SECRETS"
  echo "AMI/ARI:  $INTEG_TXT"
  echo "GERADOS:"
  echo "  $PJSIP_GEN"
  echo "  $EXT_GEN"
  echo "LOGS:"
  echo "  /var/log/asterisk/messages"
  echo "  /var/log/asterisk/security.log"
  echo "  /var/log/asterisk/cdr-csv/Master.csv   (histórico)"
  echo "Testes:"
  echo "  asterisk -rx \"pjsip show endpoints\""
  echo "  asterisk -rx \"pjsip show contacts\""
  echo "  journalctl -u interfone-guard.service -n 50 --no-pager"
  echo "==================================================================="
}

main "$@"
