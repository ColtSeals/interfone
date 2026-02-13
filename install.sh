cat > install.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

SRC_BASE="/usr/src/interfone-asterisk"
ASTERISK_SERIES="${ASTERISK_SERIES:-22}"   # 22 LTS
JOBS="${JOBS:-1}"                          # VPS fraca? use 1

NO_UFW=0
APPLY_ONLY=0
FORCE_REBUILD=0

die(){ echo "ERRO: $*" >&2; exit 1; }
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
  local ip
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
  [[ -z "${ip:-}" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  [[ -n "${ip:-}" ]] || die "não consegui detectar IP. Verifique rede."
  echo "$ip"
}

detect_asterisk_etc(){
  if [[ -d /etc/asterisk ]]; then
    echo "/etc/asterisk"
  elif [[ -d /usr/local/etc/asterisk ]]; then
    echo "/usr/local/etc/asterisk"
  else
    echo "/etc/asterisk"
  fi
}

ensure_seed_config(){
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
  apt update -y
  apt install -y ca-certificates curl wget git \
    build-essential pkg-config \
    libedit-dev libjansson-dev libxml2-dev uuid-dev libsqlite3-dev \
    libssl-dev libncurses-dev libnewt-dev \
    python3 ufw
}

ensure_asterisk_user(){
  getent group asterisk >/dev/null || addgroup --system asterisk
  id asterisk >/dev/null 2>&1 || adduser --system --ingroup asterisk --home /var/lib/asterisk --no-create-home --disabled-login asterisk
  install -d -o asterisk -g asterisk /var/{lib,log,spool,run}/asterisk || true
  chown -R asterisk:asterisk /var/{lib,log,spool,run}/asterisk 2>/dev/null || true
}

build_asterisk(){
  if command -v asterisk >/dev/null 2>&1 && [[ "$FORCE_REBUILD" -eq 0 ]]; then
    echo "Asterisk já existe ($(command -v asterisk)). Pulando build."
    return
  fi

  rm -rf "$SRC_BASE"
  mkdir -p "$SRC_BASE"
  cd "$SRC_BASE"

  local tar="asterisk-${ASTERISK_SERIES}-current.tar.gz"
  local url="https://downloads.asterisk.org/pub/telephony/asterisk/${tar}"

  echo "Baixando: $url"
  curl -fL "$url" -o "$tar"

  tar xzf "$tar"
  local dir
  dir="$(find . -maxdepth 1 -type d -name "asterisk-*" | head -n1)"
  [[ -n "${dir:-}" ]] || die "não achei pasta asterisk-* após extrair"
  cd "$dir"

  yes | contrib/scripts/install_prereq install || true

  ./configure

  if [[ -x menuselect/menuselect ]]; then
    menuselect/menuselect --disable BUILD_NATIVE menuselect.makeopts >/dev/null 2>&1 || true
  fi

  make -j"$JOBS"
  make install
  make samples || true
  make config || true
  make install-logrotate || true

  # garante path conhecido
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
  local ASTERISK_ETC
  ASTERISK_ETC="$(detect_asterisk_etc)"
  install -d "$ASTERISK_ETC"

  # RTP range
  cat > "$ASTERISK_ETC/rtp.conf" <<'C'
[general]
rtpstart=10000
rtpend=20000
C

  # modules: desliga legacy e módulos inúteis que só poluem log
  cat > "$ASTERISK_ETC/modules.conf" <<'C'
[modules]
autoload=yes

; legacy
noload => chan_sip.so

; CDR/CEL extras (não necessários no Interfone)
noload => cdr_radius.so
noload => cel_radius.so
noload => cdr_pgsql.so
noload => cdr_tds.so
noload => cel_tds.so
noload => cdr_sqlite3_custom.so

; HEP capture (não usamos)
noload => res_hep_rtcp.so
noload => res_hep_pjsip.so
C

  # remove users.conf (deprecated)
  [[ -f "$ASTERISK_ETC/users.conf" ]] && mv -f "$ASTERISK_ETC/users.conf" "$ASTERISK_ETC/users.conf.bak" || true

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
}

generate_pjsip_and_dialplan(){
  local VPS_IP="$1"
  local ASTERISK_ETC
  ASTERISK_ETC="$(detect_asterisk_etc)"

  # IMPORTANTÍSSIMO: heredoc QUOTED pra bash NÃO expandir ${EXTEN}
  python3 - "$CFG" "$SECRETS" "$VPS_IP" "$ASTERISK_ETC" <<'PY'
import json, secrets, string, sys, os

CFG=sys.argv[1]
SECRETS=sys.argv[2]
VPS_IP=sys.argv[3]
ASTERISK_ETC=sys.argv[4]

def gen_pass(n=20):
    a=string.ascii_letters+string.digits+"._@:+#=-"
    return ''.join(secrets.choice(a) for _ in range(n))

data=json.load(open(CFG,'r',encoding='utf-8'))

data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":""})
if not str(data["portaria"].get("senha","")).strip():
    data["portaria"]["senha"]=gen_pass()

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if not str(m.get("senha","")).strip():
            m["senha"]=gen_pass()

# --- pjsip.conf ---
p=[]
p.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

p.append("[global]\n")
p.append("type=global\n")
p.append("user_agent=InterfonePBX/1.0\n\n")

p.append("[transport-udp]\n")
p.append("type=transport\nprotocol=udp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

p.append("[endpoint-common](!)\n")
p.append("type=endpoint\n")
p.append("disallow=all\nallow=ulaw,alaw\n")
p.append("direct_media=no\nrtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\n")
p.append("timers=yes\nlanguage=pt_BR\n\n")

p.append("[aor-common](!)\n")
p.append("type=aor\nmax_contacts=5\nremove_existing=no\nqualify_frequency=30\n\n")

p.append("[auth-common](!)\n")
p.append("type=auth\nauth_type=userpass\n\n")

def add_endpoint(ramal,nome,senha,context):
    aor=f"{ramal}-aor"
    auth=f"{ramal}-auth"
    p.append(f"[{aor}](aor-common)\n\n")
    p.append(f"[{auth}](auth-common)\nusername={ramal}\npassword={senha}\n\n")
    p.append(f"[{ramal}](endpoint-common)\ncontext={context}\nauth={auth}\naors={aor}\ncallerid=\"{nome}\" <{ramal}>\n\n")

add_endpoint(data["portaria"]["ramal"], data["portaria"].get("nome","PORTARIA"), data["portaria"]["senha"], "from-portaria")

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        add_endpoint(m["ramal"], m.get("nome", f"AP{ap.get('numero','')}"), m["senha"], "from-internal")

open(os.path.join(ASTERISK_ETC,"pjsip.conf"),"w",encoding="utf-8").write("".join(p))

# --- extensions.conf ---
e=[]
e.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

e.append("[from-portaria]\n")
e.append("exten => 1000,1,NoOp(PORTARIA auto-call PORTARIA?)\n")
e.append(" same => n,Hangup()\n\n")
e.append("exten => _X.,1,NoOp(PORTARIA chamando ${EXTEN})\n")
e.append(" same => n,Goto(apartments,${EXTEN},1)\n\n")

e.append("[from-internal]\n")
e.append("exten => 1000,1,NoOp(MORADOR chamando PORTARIA)\n")
e.append(" same => n,Dial(PJSIP/1000,30)\n")
e.append(" same => n,Hangup()\n\n")
e.append("exten => _X.,1,Goto(apartments,${EXTEN},1)\n\n")

e.append("[apartments]\n")
for ap in data.get("apartamentos",[]):
    apnum=str(ap.get("numero","")).strip()
    targets=[f"PJSIP/{m['ramal']}" for m in ap.get("moradores",[]) if str(m.get("ramal","")).strip()]
    dial="&".join(targets)
    e.append(f"exten => {apnum},1,NoOp(AP {apnum} - RingGroup)\n")
    if dial:
        e.append(f" same => n,Dial({dial},20,tT)\n")
    else:
        e.append(" same => n,NoOp(AP sem moradores)\n")
    e.append(" same => n,Hangup()\n\n")

open(os.path.join(ASTERISK_ETC,"extensions.conf"),"w",encoding="utf-8").write("".join(e))

# salva secrets e atualiza CFG (com senhas preenchidas quando faltavam)
json.dump(data, open(SECRETS,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
json.dump(data, open(CFG,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: gerado pjsip.conf + extensions.conf; secrets em", SECRETS)
PY

  chmod 600 "$CFG" || true
  chmod 600 "$SECRETS" || true
}

firewall(){
  [[ "$NO_UFW" -eq 1 ]] && { echo "UFW ignorado (--no-ufw)."; return; }
  ufw allow OpenSSH || true
  ufw allow 5060/udp || true
  ufw allow 10000:20000/udp || true
  ufw --force enable || true
}

restart_asterisk(){
  systemctl restart asterisk
  asterisk -rx "core show version" >/dev/null 2>&1 || die "Asterisk não respondeu após restart"
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
    echo "OK: apply-only."
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
  echo "INSTALADO ✅"
  echo "Senhas SIP:  $SECRETS"
  echo "AMI/ARI:     $INTEG_TXT"
  echo "Testes:"
  echo "  asterisk -rx \"pjsip show endpoints\""
  echo "  asterisk -rx \"pjsip show contacts\""
}

main "$@"
SH

chmod +x install.sh
