#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# INTERFONE - SIP CORE (Debian 13)
# - Instala Asterisk (source) + systemd
# - Gera PJSIP + Dialplan a partir do condo.json
# - AMI/ARI localhost-only (pronto p/ integrações)
# ==========================================

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

ASTERISK_ETC="/etc/asterisk"
SRC_BASE="/usr/src/interfone-asterisk"

ASTERISK_SERIES="${ASTERISK_SERIES:-22}"   # 22 LTS
JOBS="${JOBS:-1}"                          # VPS fraca? deixa 1.
NO_UFW=0
APPLY_ONLY=0
FORCE_REBUILD=0

die(){ echo -e "\n[ERRO] $*\n" >&2; exit 1; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "use: sudo bash install.sh"; }

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
      --apply-only) APPLY_ONLY=1; shift;;
      --force-rebuild) FORCE_REBUILD=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "arg inválido: $1";;
    esac
  done
}

detect_public_ip(){
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
  [[ -z "${ip:-}" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  [[ -n "${ip:-}" ]] || die "não consegui detectar IP. Verifique rede."
  echo "$ip"
}

ensure_seed_config(){
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
  fi
}

ensure_integrations(){
  [[ -f "$INTEG_TXT" ]] && return

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

install_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt install -y ca-certificates curl wget git \
    build-essential pkg-config \
    libedit-dev libjansson-dev libxml2-dev uuid-dev libsqlite3-dev \
    libssl-dev libncurses5-dev libnewt-dev \
    python3 ufw fail2ban
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
}

ensure_asterisk_user(){
  getent group asterisk >/dev/null || addgroup --system asterisk
  id asterisk >/dev/null 2>&1 || adduser --system --ingroup asterisk --home /var/lib/asterisk --no-create-home --disabled-login asterisk

  install -d -o asterisk -g asterisk /var/{lib,log,spool,run}/asterisk || true
  chown -R asterisk:asterisk /var/{lib,log,spool,run}/asterisk 2>/dev/null || true
}

build_asterisk(){
  if command -v asterisk >/dev/null 2>&1 && [[ "$FORCE_REBUILD" -eq 0 ]]; then
    echo "[OK] Asterisk já existe: $(command -v asterisk) (pulando build)"
    return
  fi

  echo "[..] Instalando Asterisk por source (serie ${ASTERISK_SERIES})"
  rm -rf "$SRC_BASE"
  mkdir -p "$SRC_BASE"
  cd "$SRC_BASE"

  local tar="asterisk-${ASTERISK_SERIES}-current.tar.gz"
  local url="https://downloads.asterisk.org/pub/telephony/asterisk/${tar}"

  echo "[..] Baixando: $url"
  curl -fL "$url" -o "$tar"

  tar xzf "$tar"
  local dir
  dir="$(find . -maxdepth 1 -type d -name "asterisk-*" | head -n1)"
  [[ -n "${dir:-}" ]] || die "não achei pasta asterisk-* após extrair"
  cd "$dir"

  # prereqs (se falhar, seguimos — já instalamos deps principais)
  yes | contrib/scripts/install_prereq install >/dev/null 2>&1 || true

  ./configure

  # evita binário com -march=native quebrar em VPS/CPU virtual
  menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts >/dev/null 2>&1 || true

  make -j"$JOBS"
  make install
  make samples >/dev/null 2>&1 || true
  make config  >/dev/null 2>&1 || true
  make install-logrotate >/dev/null 2>&1 || true

  # garante path comum
  if [[ -x /usr/local/sbin/asterisk && ! -x /usr/sbin/asterisk ]]; then
    ln -sf /usr/local/sbin/asterisk /usr/sbin/asterisk
  fi

  command -v asterisk >/dev/null 2>&1 || die "asterisk não apareceu no PATH após install"
}

write_systemd_unit(){
  local AST_BIN
  AST_BIN="$(command -v asterisk)"

  cat > /etc/systemd/system/asterisk.service <<EOF
[Unit]
Description=Asterisk PBX (Interfone)
After=network.target

[Service]
Type=simple
User=asterisk
Group=asterisk
ExecStart=${AST_BIN} -f -U asterisk -G asterisk
ExecReload=${AST_BIN} -rx 'core reload'
ExecStop=${AST_BIN} -rx 'core stop now'
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now asterisk
}

write_static_confs(){
  # RTP range
  cat > "$ASTERISK_ETC/rtp.conf" <<'C'
[general]
rtpstart=10000
rtpend=20000
C

  # desabilita chan_sip (legado)
  cat > "$ASTERISK_ETC/modules.conf" <<'C'
[modules]
autoload=yes
noload => chan_sip.so
C

  # logs
  cat > "$ASTERISK_ETC/logger.conf" <<'C'
[general]
dateformat=%F %T
[logfiles]
console => notice,warning,error,debug,verbose
messages => notice,warning,error
C

  # AMI/ARI localhost-only
  local AMI_USER AMI_PASS ARI_USER ARI_PASS
  AMI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | head -n1)"
  AMI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | head -n1)"
  ARI_USER="$(awk '/^  user: /{print $2}' "$INTEG_TXT" | tail -n1)"
  ARI_PASS="$(awk '/^  pass: /{print $2}' "$INTEG_TXT" | tail -n1)"

  cat > "$ASTERISK_ETC/manager.conf" <<EOF
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

  cat > "$ASTERISK_ETC/http.conf" <<'C'
[general]
enabled=yes
bindaddr=127.0.0.1
bindport=8088
C

  cat > "$ASTERISK_ETC/ari.conf" <<EOF
[general]
enabled=yes
pretty=yes

[$ARI_USER]
type=user
read_only=no
password=$ARI_PASS
EOF

  # permissões seguras
  chown -R root:asterisk "$ASTERISK_ETC" 2>/dev/null || true
  find "$ASTERISK_ETC" -type f -maxdepth 1 -exec chmod 640 {} \; 2>/dev/null || true
}

generate_pjsip_and_dialplan(){
  local VPS_IP="$1"

  python3 - <<PY
import json, secrets, string

CFG="${CFG}"
SECRETS="${SECRETS}"
VPS_IP="${VPS_IP}"
ASTERISK_ETC="${ASTERISK_ETC}"

def gen_pass(n=20):
    a=string.ascii_letters+string.digits
    return ''.join(secrets.choice(a) for _ in range(n))

data=json.load(open(CFG,'r',encoding='utf-8'))

data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":""})
if not data["portaria"].get("senha"):
    data["portaria"]["senha"]=gen_pass()

# garante lista
data.setdefault("apartamentos", [])

# senhas moradores
for ap in data.get("apartamentos",[]):
    ap.setdefault("moradores", [])
    for m in ap.get("moradores",[]):
        if not m.get("senha"):
            m["senha"]=gen_pass()

# -------- pjsip.conf --------
p=[]
p.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

p.append("[global]\n")
p.append("type=global\n")
p.append("user_agent=InterfonePBX/1.0\n")
p.append("endpoint_identifier_order=auth_username,username,ip\n")
p.append("allow_anonymous=no\n\n")

p.append("[transport-udp]\n")
p.append("type=transport\nprotocol=udp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

p.append("[endpoint-common](!)\n")
p.append("type=endpoint\n")
p.append("disallow=all\n")
p.append("allow=ulaw,alaw,g722\n")
p.append("direct_media=no\n")
p.append("rtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\n")
p.append("timers=yes\nlanguage=pt_BR\n")
p.append("dtmf_mode=rfc4733\n\n")

p.append("[aor-common](!)\n")
p.append("type=aor\n")
p.append("max_contacts=5\n")
p.append("remove_existing=no\n")
p.append("qualify_frequency=30\n\n")

p.append("[auth-common](!)\n")
p.append("type=auth\n")
p.append("auth_type=userpass\n\n")

def add_endpoint(ramal,nome,senha,context):
    aor=f"{ramal}-aor"
    auth=f"{ramal}-auth"
    p.append(f"[{aor}](aor-common)\n\n")
    p.append(f"[{auth}](auth-common)\nusername={ramal}\npassword={senha}\n\n")
    p.append(f"[{ramal}](endpoint-common)\ncontext={context}\nauth={auth}\naors={aor}\ncallerid=\"{nome}\" <{ramal}>\n\n")

# portaria
add_endpoint(data["portaria"]["ramal"], data["portaria"].get("nome","PORTARIA"), data["portaria"]["senha"], "from-portaria")

# moradores
all_residents=[]
for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        all_residents.append(m["ramal"])
        add_endpoint(m["ramal"], m.get("nome", f"AP{ap.get('numero','')}"), m["senha"], "from-internal")

open(f"{ASTERISK_ETC}/pjsip.conf","w",encoding="utf-8").write("".join(p))

# -------- extensions.conf --------
e=[]
e.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

e.append("[from-portaria]\n")
# portaria pode discar AP (ex: 101) ou ramal direto (ex: 10101)
e.append("exten => _X.,1,NoOp(PORTARIA discou ${EXTEN})\n")
e.append(" same => n,Goto(apartments,${EXTEN},1)\n\n")

e.append("[from-internal]\n")
e.append("exten => 1000,1,NoOp(MORADOR chamando PORTARIA)\n")
e.append(" same => n,Dial(PJSIP/1000,30)\n")
e.append(" same => n,Hangup()\n\n")
# morador também pode discar AP ou ramal direto
e.append("exten => _X.,1,Goto(apartments,${EXTEN},1)\n\n")

e.append("[apartments]\n")

# ramal direto (para portaria ou morador chamar um ramal específico)
for r in all_residents:
    e.append(f"exten => {r},1,NoOp(Chamando ramal {r})\n")
    e.append(f" same => n,Dial(PJSIP/{r},20,tT)\n")
    e.append(" same => n,Hangup()\n\n")

# ring group por AP
for ap in data.get("apartamentos",[]):
    apnum=str(ap.get("numero","")).strip()
    targets=[f"PJSIP/{m['ramal']}" for m in ap.get("moradores",[]) if m.get("ramal")]
    dial="&".join(targets)
    e.append(f"exten => {apnum},1,NoOp(AP {apnum} - RingGroup)\n")
    if dial:
        e.append(f" same => n,Dial({dial},20,tT)\n")
    else:
        e.append(" same => n,NoOp(AP sem moradores)\n")
    e.append(" same => n,Hangup()\n\n")

open(f"{ASTERISK_ETC}/extensions.conf","w",encoding="utf-8").write("".join(e))

json.dump(data, open(SECRETS,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: gerado pjsip.conf + extensions.conf | senhas em:", SECRETS)
PY

  chmod 600 "$CFG" || true
  chmod 600 "$SECRETS" || true
}

firewall(){
  [[ "$NO_UFW" -eq 1 ]] && { echo "[..] UFW ignorado (--no-ufw)"; return; }

  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 5060/udp  >/dev/null 2>&1 || true
  ufw allow 10000:20000/udp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
}

restart_asterisk(){
  systemctl restart asterisk
  asterisk -rx "core show version" >/dev/null
}

main(){
  need_root
  parse_args "$@"

  local VPS_IP
  VPS_IP="$(detect_public_ip)"
  echo "[OK] IP da VPS: $VPS_IP"

  ensure_seed_config
  ensure_integrations

  if [[ "$APPLY_ONLY" -eq 1 ]]; then
    command -v asterisk >/dev/null 2>&1 || die "Asterisk não instalado. Rode sem --apply-only."
    write_static_confs
    generate_pjsip_and_dialplan "$VPS_IP"
    restart_asterisk
    echo "[OK] apply-only finalizado."
    exit 0
  fi

  install_deps
  ensure_asterisk_user
  build_asterisk
  write_systemd_unit
  write_static_confs
  generate_pjsip_and_dialplan "$VPS_IP"
  firewall
  restart_asterisk

  echo
  echo "==============================="
  echo "  INSTALADO / ATIVO ✅"
  echo "==============================="
  echo "Config:   $CFG"
  echo "Senhas:   $SECRETS"
  echo "AMI/ARI:  $INTEG_TXT"
  echo
  echo "Testes:"
  echo "  asterisk -rx \"pjsip show endpoints\""
  echo "  asterisk -rx \"pjsip show contacts\""
}

main "$@"
