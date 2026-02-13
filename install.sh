cd ~/interfone

cat > install.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"
ASTERISK_DIR="/etc/asterisk"
SRC_DIR="/usr/src"

ASTERISK_SERIES="22"   # 22 LTS (se quiser 20 LTS: mude para "20")
PUBLIC_IP_OVERRIDE=""
NO_UFW="0"
APPLY_ONLY="0"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Use: sudo bash install.sh"; exit 1; }; }

usage(){
  echo "Uso:"
  echo "  sudo bash install.sh"
  echo "  sudo bash install.sh --ip 1.2.3.4"
  echo "  sudo bash install.sh --apply-only"
  echo "  sudo bash install.sh --no-ufw"
  echo "  sudo bash install.sh --asterisk 22|20"
}

parse_args(){
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ip) PUBLIC_IP_OVERRIDE="${2:-}"; shift 2;;
      --no-ufw) NO_UFW="1"; shift;;
      --apply-only) APPLY_ONLY="1"; shift;;
      --asterisk) ASTERISK_SERIES="${2:-22}"; shift 2;;
      -h|--help) usage; exit 0;;
      *) echo "Arg desconhecido: $1"; usage; exit 1;;
    esac
  done
}

detect_public_ip(){
  [[ -n "$PUBLIC_IP_OVERRIDE" ]] && { echo "$PUBLIC_IP_OVERRIDE"; return; }
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
  [[ -z "${ip:-}" ]] && ip="$(ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-}"
}

ensure_local_config(){
  install -d "$APP_DIR"; chmod 700 "$APP_DIR"
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
    echo "Criado: $CFG"
  fi
}

ensure_integration_creds(){
  [[ -f "$INTEG_TXT" ]] && return
  local AMI_USER="laravel" ARI_USER="ari" AMI_PASS ARI_PASS
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
  cat > "$INTEG_TXT" <<EOF2
AMI:
  host: 127.0.0.1
  port: 5038
  user: $AMI_USER
  pass: $AMI_PASS

ARI:
  url: http://127.0.0.1:8088/ari/
  user: $ARI_USER
  pass: $ARI_PASS
EOF2
  chmod 600 "$INTEG_TXT"
}

install_build_deps(){
  apt update -y
  apt install -y ca-certificates curl wget git \
    build-essential pkg-config \
    libedit-dev libjansson-dev libxml2-dev uuid-dev libsqlite3-dev \
    libssl-dev libncurses5-dev libnewt-dev \
    subversion python3 ufw fail2ban
  systemctl enable --now fail2ban
}

create_asterisk_user(){
  getent group asterisk >/dev/null || addgroup --system asterisk
  id asterisk >/dev/null 2>&1 || adduser --system --ingroup asterisk --home /var/lib/asterisk --no-create-home --disabled-login asterisk
  install -d -o asterisk -g asterisk /var/{lib,log,spool,run}/asterisk || true
  chown -R asterisk:asterisk /var/{lib,log,spool,run}/asterisk 2>/dev/null || true
}

download_and_build_asterisk(){
  command -v asterisk >/dev/null 2>&1 && { echo "Asterisk já instalado. Pulando build."; return; }

  local tar="asterisk-${ASTERISK_SERIES}-current.tar.gz"
  local url="https://downloads.asterisk.org/pub/telephony/asterisk/${tar}"

  mkdir -p "$SRC_DIR"
  cd "$SRC_DIR"

  echo "Baixando Asterisk ${ASTERISK_SERIES} (source)..."
  rm -f "$tar"
  curl -fL "$url" -o "$tar"

  rm -rf asterisk-*
  tar xzf "$tar"
  local dir
  dir="$(find . -maxdepth 1 -type d -name "asterisk-*" | head -n1)"
  [[ -n "${dir:-}" ]] || { echo "Falha ao extrair Asterisk"; exit 1; }
  cd "$dir"

  # instala prereqs oficiais do Asterisk (evita faltar libs)
  yes | contrib/scripts/install_prereq install || true

  ./configure
  make -j"$(nproc)"
  make install
  make samples || true
  make config || true
  ldconfig || true
}

ensure_asterisk_run_user(){
  local conf="$ASTERISK_DIR/asterisk.conf"
  [[ -f "$conf" ]] || return 0
  grep -qE '^\s*runuser\s*=' "$conf" && sed -i 's/^\s*runuser\s*=.*/runuser = asterisk/' "$conf" || echo "runuser = asterisk" >> "$conf"
  grep -qE '^\s*rungroup\s*=' "$conf" && sed -i 's/^\s*rungroup\s*=.*/rungroup = asterisk/' "$conf" || echo "rungroup = asterisk" >> "$conf"
}

write_static_asterisk_files(){
  # rtp
  cat > "$ASTERISK_DIR/rtp.conf" <<'C'
[general]
rtpstart=10000
rtpend=20000
C

  # modules
  cat > "$ASTERISK_DIR/modules.conf" <<'C'
[modules]
autoload=yes
noload => chan_sip.so
C

  # logger
  cat > "$ASTERISK_DIR/logger.conf" <<'C'
[general]
dateformat=%F %T
[logfiles]
console => notice,warning,error,debug,verbose
messages => notice,warning,error
C

  # AMI
  local AMI_USER AMI_PASS
  AMI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | head -n1)"
  AMI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | head -n1)"

  cat > "$ASTERISK_DIR/manager.conf" <<EOF2
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
EOF2

  # HTTP + ARI
  local ARI_USER ARI_PASS
  ARI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | tail -n1)"
  ARI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | tail -n1)"

  cat > "$ASTERISK_DIR/http.conf" <<'C'
[general]
enabled=yes
bindaddr=127.0.0.1
bindport=8088
C

  cat > "$ASTERISK_DIR/ari.conf" <<EOF2
[general]
enabled = yes
pretty = yes

[$ARI_USER]
type = user
read_only = no
password = $ARI_PASS
EOF2
}

generate_pjsip_and_dialplan(){
  local VPS_IP="$1"
  python3 - <<PY
import json, secrets, string

CFG="${CFG}"
SECRETS="${SECRETS}"
VPS_IP="${VPS_IP}"

def gen_pass(n=20):
    a=string.ascii_letters+string.digits
    return ''.join(secrets.choice(a) for _ in range(n))

data=json.load(open(CFG,'r',encoding='utf-8'))
data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":""})
if not data["portaria"].get("senha"):
    data["portaria"]["senha"]=gen_pass()

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if not m.get("senha"):
            m["senha"]=gen_pass()

# pjsip.conf
p=[]
p.append("; INTERFONE - GERADO AUTOMATICAMENTE\\n\\n")
p.append("[global]\\n")
p.append("type=global\\n")
p.append("user_agent=InterfonePBX/1.0\\n\\n")

p.append("[transport-udp]\\n")
p.append("type=transport\\nprotocol=udp\\nbind=0.0.0.0:5060\\n")
p.append(f"external_signaling_address={VPS_IP}\\nexternal_media_address={VPS_IP}\\n")
p.append("local_net=10.0.0.0/8\\nlocal_net=172.16.0.0/12\\nlocal_net=192.168.0.0/16\\n\\n")

p.append("[endpoint-common](!)\\n")
p.append("type=endpoint\\ndisallow=all\\nallow=ulaw,alaw\\ndirect_media=no\\nrtp_symmetric=yes\\nforce_rport=yes\\nrewrite_contact=yes\\ntimers=yes\\nlanguage=pt_BR\\n\\n")
p.append("[aor-common](!)\\ntype=aor\\nmax_contacts=1\\nremove_existing=yes\\nqualify_frequency=30\\n\\n")
p.append("[auth-common](!)\\ntype=auth\\nauth_type=userpass\\n\\n")

def add_endpoint(ramal,nome,senha,context):
    aor=f"{ramal}-aor"
    auth=f"{ramal}-auth"
    p.append(f"[{aor}](aor-common)\\n\\n")
    p.append(f"[{auth}](auth-common)\\ntype=auth\\nusername={ramal}\\npassword={senha}\\n\\n")
    p.append(f"[{ramal}](endpoint-common)\\ntype=endpoint\\ncontext={context}\\nauth={auth}\\naors={aor}\\ncallerid=\\"{nome}\\" <{ramal}>\\n\\n")

add_endpoint(data["portaria"]["ramal"], data["portaria"].get("nome","PORTARIA"), data["portaria"]["senha"], "from-portaria")

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        add_endpoint(m["ramal"], m.get("nome", f"AP{ap.get('numero','')}"), m["senha"], "from-internal")

open("/etc/asterisk/pjsip.conf","w",encoding="utf-8").write("".join(p))

# extensions.conf
e=[]
e.append("; INTERFONE - GERADO AUTOMATICAMENTE\\n\\n")
e.append("[from-portaria]\\n")
e.append("exten => _X.,1,NoOp(PORTARIA chamando AP \\${EXTEN})\\n same => n,Goto(apartments,\\${EXTEN},1)\\n\\n")
e.append("[from-internal]\\n")
e.append("exten => 1000,1,NoOp(MORADOR chamando PORTARIA)\\n same => n,Dial(PJSIP/1000,30)\\n same => n,Hangup()\\n\\n")
e.append("exten => _X.,1,Goto(apartments,\\${EXTEN},1)\\n\\n")
e.append("[apartments]\\n")

for ap in data.get("apartamentos",[]):
    apnum=ap.get("numero","")
    targets=[f"PJSIP/{m['ramal']}" for m in ap.get("moradores",[]) if m.get("ramal")]
    dial="&".join(targets)
    e.append(f"exten => {apnum},1,NoOp(AP {apnum} - RingGroup)\\n same => n,Set(TIMEOUT(absolute)=60)\\n")
    e.append(f" same => n,Dial({dial},20,tT)\\n" if dial else " same => n,NoOp(AP sem moradores)\\n")
    e.append(" same => n,Hangup()\\n\\n")

open("/etc/asterisk/extensions.conf","w",encoding="utf-8").write("".join(e))

json.dump(data, open(SECRETS,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: configs geradas + senhas em", SECRETS)
PY
  chmod 600 "$SECRETS" || true
  chmod 600 "$CFG" || true
}

setup_firewall(){
  [[ "$NO_UFW" == "1" ]] && { echo "UFW ignorado (--no-ufw)."; return; }
  ufw allow OpenSSH
  ufw allow 5060/udp
  ufw allow 10000:20000/udp
  ufw --force enable
}

restart_asterisk(){
  systemctl enable --now asterisk 2>/dev/null || true
  systemctl restart asterisk || true
  # fallback caso service não exista
  command -v asterisk >/dev/null 2>&1 && asterisk -rx "core show version" >/dev/null 2>&1 || true
}

main(){
  need_root
  parse_args "$@"

  local VPS_IP
  VPS_IP="$(detect_public_ip)"
  [[ -n "$VPS_IP" ]] || { echo "Não detectei IP. Use: sudo bash install.sh --ip SEU_IP"; exit 1; }
  echo "IP da VPS: $VPS_IP"

  ensure_local_config
  ensure_integration_creds

  if [[ "$APPLY_ONLY" == "1" ]]; then
    command -v asterisk >/dev/null 2>&1 || { echo "Asterisk não instalado. Rode sem --apply-only."; exit 1; }
    write_static_asterisk_files
    generate_pjsip_and_dialplan "$VPS_IP"
    restart_asterisk
    echo "OK: aplicado (apply-only)."
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
  echo "INSTALADO ✅"
  echo "Config:  $CFG"
  echo "Senhas:  $SECRETS"
  echo "AMI/ARI: $INTEG_TXT"
  echo "Teste:   asterisk -rx \"pjsip show endpoints\""
}

main "$@"
EOF

chmod +x install.sh
