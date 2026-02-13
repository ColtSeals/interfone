#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# INTERFONE - SIP CORE (Debian 13)
# - Debian 13 não tem "apt install asterisk" (PBX) -> compila LTS do source
# - Config local: /opt/interfone/condo.json
# - Gera: /etc/asterisk/pjsip.conf e /etc/asterisk/extensions.conf
# - Deixa AMI/ARI prontos (127.0.0.1) para Laravel depois
# ==========================================================

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"
ASTERISK_DIR="/etc/asterisk"
SRC_DIR="/usr/src"

ASTERISK_SERIES="22"         # LTS atual (pode trocar para 20 se quiser)
PUBLIC_IP_OVERRIDE=""
NO_UFW="0"
APPLY_ONLY="0"

usage() {
  cat <<EOF
Uso:
  sudo bash install.sh
  sudo bash install.sh --ip 1.2.3.4
  sudo bash install.sh --apply-only        (não compila/reinstala, só regenera configs)
  sudo bash install.sh --no-ufw
  sudo bash install.sh --asterisk 22|20

EOF
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Execute como root: sudo bash install.sh"
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip) PUBLIC_IP_OVERRIDE="${2:-}"; shift 2 ;;
      --no-ufw) NO_UFW="1"; shift ;;
      --apply-only) APPLY_ONLY="1"; shift ;;
      --asterisk) ASTERISK_SERIES="${2:-22}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Argumento desconhecido: $1"; usage; exit 1 ;;
    esac
  done
}

detect_public_ip() {
  if [[ -n "$PUBLIC_IP_OVERRIDE" ]]; then
    echo "$PUBLIC_IP_OVERRIDE"; return
  fi

  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
  if [[ -z "${ip:-}" ]]; then
    ip="$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  fi
  echo "${ip:-}"
}

ensure_local_config() {
  install -d "$APP_DIR"
  chmod 700 "$APP_DIR"

  if [[ ! -f "$CFG" ]]; then
    cat > "$CFG" <<'JSON'
{
  "portaria": { "ramal": "1000", "nome": "PORTARIA", "senha": "" },
  "apartamentos": [
    {
      "numero": "101",
      "moradores": [
        { "ramal": "10101", "nome": "AP101-01", "senha": "" },
        { "ramal": "10102", "nome": "AP101-02", "senha": "" }
      ]
    }
  ]
}
JSON
    chmod 600 "$CFG"
    echo "Criado config inicial em: $CFG"
  fi
}

ensure_integration_creds() {
  if [[ -f "$INTEG_TXT" ]]; then
    return
  fi

  local AMI_USER="laravel"
  local ARI_USER="ari"
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
AMI:
  host: 127.0.0.1
  port: 5038
  user: $AMI_USER
  pass: $AMI_PASS

ARI:
  url: http://127.0.0.1:8088/ari/
  user: $ARI_USER
  pass: $ARI_PASS
EOF
  chmod 600 "$INTEG_TXT"
}

install_build_deps() {
  apt update -y
  apt install -y \
    ca-certificates curl wget git \
    build-essential pkg-config \
    libedit-dev libjansson-dev libxml2-dev uuid-dev libsqlite3-dev \
    libssl-dev libncurses5-dev libnewt-dev \
    subversion \
    ufw fail2ban python3

  systemctl enable --now fail2ban
}

create_asterisk_user() {
  # cria user/grupo se não existir
  if ! getent group asterisk >/dev/null; then
    addgroup --system asterisk
  fi
  if ! id asterisk >/dev/null 2>&1; then
    adduser --system --ingroup asterisk --home /var/lib/asterisk --no-create-home --disabled-login asterisk
  fi

  install -d -o asterisk -g asterisk /var/{lib,log,spool,run}/asterisk || true
  chown -R asterisk:asterisk /var/{lib,log,spool,run}/asterisk 2>/dev/null || true
}

download_and_build_asterisk() {
  # se já existe asterisk e APPLY_ONLY=0, não recompila
  if command -v asterisk >/dev/null 2>&1; then
    echo "Asterisk já existe no sistema. Pulando build."
    return
  fi

  local tar="asterisk-${ASTERISK_SERIES}-current.tar.gz"
  local url="https://downloads.asterisk.org/pub/telephony/asterisk/${tar}"
  local work="$SRC_DIR"

  mkdir -p "$work"
  cd "$work"

  echo "Baixando Asterisk ${ASTERISK_SERIES} LTS (source)..."
  rm -f "$tar"
  curl -fL "$url" -o "$tar"

  echo "Extraindo..."
  rm -rf asterisk-*
  tar xzf "$tar"

  local dir
  dir="$(find . -maxdepth 1 -type d -name "asterisk-*" | head -n1)"
  if [[ -z "${dir:-}" ]]; then
    echo "Falha ao localizar pasta extraída do Asterisk."
    exit 1
  fi

  cd "$dir"

  echo "Configurando..."
  ./configure

  echo "Compilando..."
  make -j"$(nproc)"

  echo "Instalando..."
  make install

  # Instala samples (vamos sobrescrever pjsip/extensions depois)
  make samples || true

  # Instala service
  make config || true
  ldconfig || true
}

ensure_asterisk_run_user() {
  local conf="$ASTERISK_DIR/asterisk.conf"
  [[ -f "$conf" ]] || return 0

  # força rodar como asterisk
  if grep -qE '^\s*runuser\s*=' "$conf"; then
    sed -i 's/^\s*runuser\s*=.*/runuser = asterisk/' "$conf"
  else
    echo "runuser = asterisk" >> "$conf"
  fi

  if grep -qE '^\s*rungroup\s*=' "$conf"; then
    sed -i 's/^\s*rungroup\s*=.*/rungroup = asterisk/' "$conf"
  else
    echo "rungroup = asterisk" >> "$conf"
  fi
}

write_static_asterisk_files() {
  # RTP
  cat > "$ASTERISK_DIR/rtp.conf" <<'EOF'
[general]
rtpstart=10000
rtpend=20000
EOF

  # Modules (garante PJSIP)
  cat > "$ASTERISK_DIR/modules.conf" <<'EOF'
[modules]
autoload=yes
noload => chan_sip.so
EOF

  # Logger
  cat > "$ASTERISK_DIR/logger.conf" <<'EOF'
[general]
dateformat=%F %T

[logfiles]
console => notice,warning,error,debug,verbose
messages => notice,warning,error
EOF

  # AMI
  local AMI_USER AMI_PASS
  AMI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | head -n1)"
  AMI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | head -n1)"

  cat > "$ASTERISK_DIR/manager.conf" <<EOF
[general]
enabled = yes
port = 5038
bindaddr = 127.0.0.1
displayconnects = no

[$AMI_USER]
secret = $AMI_PASS
deny=0.0.0.0/0.0.0.0
permit=127.0.0.1/255.255.255.255
read = system,call,log,verbose,command,agent,user,config,dtmf,reporting,cdr,dialplan
write = system,call,command,agent,user,config,reporting,originate
EOF

  # HTTP + ARI
  local ARI_USER ARI_PASS
  ARI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | tail -n1)"
  ARI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | tail -n1)"

  cat > "$ASTERISK_DIR/http.conf" <<'EOF'
[general]
enabled=yes
bindaddr=127.0.0.1
bindport=8088
EOF

  cat > "$ASTERISK_DIR/ari.conf" <<EOF
[general]
enabled = yes
pretty = yes

[$ARI_USER]
type = user
read_only = no
password = $ARI_PASS
EOF

  chmod 644 "$ASTERISK_DIR/"{rtp.conf,modules.conf,logger.conf,manager.conf,http.conf,ari.conf} || true
}

generate_pjsip_and_dialplan() {
  local VPS_IP="$1"

  python3 - <<PY
import json, secrets, string

CFG="${CFG}"
SECRETS="${SECRETS}"
VPS_IP="${VPS_IP}"

def gen_pass(n=20):
    a = string.ascii_letters + string.digits
    return ''.join(secrets.choice(a) for _ in range(n))

data = json.load(open(CFG, 'r', encoding='utf-8'))

if not data.get("portaria"):
    data["portaria"]={"ramal":"1000","nome":"PORTARIA","senha":""}

if not data["portaria"].get("senha"):
    data["portaria"]["senha"]=gen_pass()

for ap in data.get("apartamentos", []):
    for m in ap.get("moradores", []):
        if not m.get("senha"):
            m["senha"]=gen_pass()

# --- pjsip.conf ---
p=[]
p.append("; INTERFONE - GERADO AUTOMATICAMENTE\\n\\n")
p.append("[global]\\n")
p.append("type=global\\n")
p.append("user_agent=InterfonePBX/1.0\\n\\n")

p.append("[transport-udp]\\n")
p.append("type=transport\\n")
p.append("protocol=udp\\n")
p.append("bind=0.0.0.0:5060\\n")
p.append(f"external_signaling_address={VPS_IP}\\n")
p.append(f"external_media_address={VPS_IP}\\n")
p.append("local_net=10.0.0.0/8\\n")
p.append("local_net=172.16.0.0/12\\n")
p.append("local_net=192.168.0.0/16\\n\\n")

p.append("[endpoint-common](!)\\n")
p.append("type=endpoint\\n")
p.append("disallow=all\\n")
p.append("allow=ulaw,alaw\\n")
p.append("direct_media=no\\n")
p.append("rtp_symmetric=yes\\n")
p.append("force_rport=yes\\n")
p.append("rewrite_contact=yes\\n")
p.append("timers=yes\\n")
p.append("language=pt_BR\\n\\n")

p.append("[aor-common](!)\\n")
p.append("type=aor\\n")
p.append("max_contacts=1\\n")
p.append("remove_existing=yes\\n")
p.append("qualify_frequency=30\\n\\n")

p.append("[auth-common](!)\\n")
p.append("type=auth\\n")
p.append("auth_type=userpass\\n\\n")

def add_endpoint(ramal,nome,senha,context):
    aor=f"{ramal}-aor"
    auth=f"{ramal}-auth"
    p.append(f"[{aor}](aor-common)\\n")
    p.append("type=aor\\n\\n")
    p.append(f"[{auth}](auth-common)\\n")
    p.append("type=auth\\n")
    p.append(f"username={ramal}\\n")
    p.append(f"password={senha}\\n\\n")
    p.append(f"[{ramal}](endpoint-common)\\n")
    p.append("type=endpoint\\n")
    p.append(f"context={context}\\n")
    p.append(f"auth={auth}\\n")
    p.append(f"aors={aor}\\n")
    p.append(f'callerid="{nome}" <{ramal}>\\n\\n')

add_endpoint(data["portaria"]["ramal"], data["portaria"].get("nome","PORTARIA"), data["portaria"]["senha"], "from-portaria")
for ap in data.get("apartamentos", []):
    for m in ap.get("moradores", []):
        add_endpoint(m["ramal"], m.get("nome", f"AP{ap.get('numero','')}"), m["senha"], "from-internal")

open("/etc/asterisk/pjsip.conf","w",encoding="utf-8").write("".join(p))

# --- extensions.conf ---
e=[]
e.append("; INTERFONE - GERADO AUTOMATICAMENTE\\n\\n")

e.append("[from-portaria]\\n")
e.append("exten => _X.,1,NoOp(PORTARIA chamando AP \\${EXTEN})\\n")
e.append(" same => n,Goto(apartments,\\${EXTEN},1)\\n\\n")

e.append("[from-internal]\\n")
e.append("exten => 1000,1,NoOp(MORADOR chamando PORTARIA)\\n")
e.append(" same => n,Dial(PJSIP/1000,30)\\n")
e.append(" same => n,Hangup()\\n\\n")
e.append("exten => _X.,1,Goto(apartments,\\${EXTEN},1)\\n\\n")

e.append("[apartments]\\n")
for ap in data.get("apartamentos", []):
    apnum = ap.get("numero","")
    targets=[f"PJSIP/{m['ramal']}" for m in ap.get("moradores", []) if m.get("ramal")]
    dial="&".join(targets)
    e.append(f"exten => {apnum},1,NoOp(AP {apnum} - RingGroup)\\n")
    e.append(" same => n,Set(TIMEOUT(absolute)=60)\\n")
    if dial:
        e.append(f" same => n,Dial({dial},20,tT)\\n")
    else:
        e.append(" same => n,NoOp(AP sem moradores)\\n")
    e.append(" same => n,Hangup()\\n\\n")

open("/etc/asterisk/extensions.conf","w",encoding="utf-8").write("".join(e))

json.dump(data, open(SECRETS,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: /etc/asterisk/pjsip.conf e /etc/asterisk/extensions.conf gerados")
print("OK: senhas SIP em:", SECRETS)
PY

  chmod 600 "$SECRETS" || true
  chmod 600 "$CFG" || true
}

setup_firewall() {
  if [[ "$NO_UFW" == "1" ]]; then
    echo "UFW ignorado (--no-ufw)."
    return
  fi

  ufw allow OpenSSH
  ufw allow 5060/udp
  ufw allow 10000:20000/udp
  ufw --force enable
}

restart_asterisk() {
  systemctl enable --now asterisk 2>/dev/null || true
  systemctl restart asterisk
  sleep 1
}

main() {
  need_root
  parse_args "$@"

  local VPS_IP
  VPS_IP="$(detect_public_ip)"
  if [[ -z "$VPS_IP" ]]; then
    echo "Não consegui detectar o IP da VPS. Rode: ip -4 addr"
    echo "E use: sudo bash install.sh --ip SEU_IP"
    exit 1
  fi
  echo "IP da VPS: $VPS_IP"

  ensure_local_config
  ensure_integration_creds

  if [[ "$APPLY_ONLY" == "1" ]]; then
    if ! command -v asterisk >/dev/null 2>&1; then
      echo "Asterisk não está instalado. Rode: sudo bash install.sh (sem --apply-only)"
      exit 1
    fi
    write_static_asterisk_files
    generate_pjsip_and_dialplan "$VPS_IP"
    restart_asterisk
    echo "OK: configs aplicadas (apply-only)."
    exit 0
  fi

  install_build_deps
  create_asterisk_user
  download_and_build_asterisk
  ensure_asterisk_run_user

  write_static_asterisk_files
  generate_pjsip_and_dialplan "$VPS_IP"
  setup_firewall
  restart_asterisk

  echo
  echo "=============================="
  echo "INSTALADO ✅ (Asterisk via source)"
  echo "Config local: $CFG"
  echo "Senhas SIP:   $SECRETS"
  echo "AMI/ARI:      $INTEG_TXT"
  echo
  echo "Menu:"
  echo "  sudo bash menu.sh"
  echo
  echo "Console:"
  echo "  asterisk -rvvv"
  echo "  pjsip show endpoints"
  echo "  pjsip show contacts"
  echo "=============================="
}

main "$@"
