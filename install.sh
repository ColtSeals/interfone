#!/usr/bin/env bash
set -euo pipefail

# =========================
# INTERFONE • INSTALL (Debian 13)
# Asterisk (source) + PJSIP + Dialplan gerado do condo.json
#
# PRINCÍPIOS DE ESTABILIDADE (REGISTER):
#  - endpoint_identifier_order=auth_username,username,ip
#  - endpoint == ramal (simples e robusto)
#  - transport UDP + TCP em 5060
#  - logs de auth em /var/log/asterisk/security.log
# =========================

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

SRC_BASE="/usr/src/interfone-asterisk"
ASTERISK_SERIES="${ASTERISK_SERIES:-22}"   # 22 LTS
JOBS="${JOBS:-1}"

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
  # 1) rota default (pega IP de saída)
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  # 2) primeira interface global
  [[ -z "$ip" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"

  # 3) tentativas via internet (quando VPS tem NAT/CGNAT ou rota estranha)
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
  "portaria": { "ramal": "1000", "nome": "PORTARIA", "senha": "" },
  "apartamentos": [
    {
      "numero": "101",
      "nome": "",
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
    python3 \
    libedit-dev libjansson-dev libxml2-dev uuid-dev libsqlite3-dev \
    libssl-dev libncurses-dev libnewt-dev \
    libcurl4-openssl-dev \
    ufw \
    iproute2 \
    procps \
    logrotate
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

# -f = foreground
# -U/-G = usuário/grupo
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

write_logger_conf(){
  local ETC="/etc/asterisk"
  install -d "$ETC"

  # Garante log de segurança (falhas auth/register etc.)
  cat > "$ETC/logger.conf" <<'C'
[general]
dateformat=%F %T

[logfiles]
; log principal (verbose+notice+warning+error)
messages => notice,warning,error,verbose

; log de segurança: tentativas de REGISTER, auth failures, scanners
security => security

; console (quando roda no foreground)
console => notice,warning,error,verbose
C
}

write_static_confs(){
  local ETC="/etc/asterisk"
  install -d "$ETC"

  write_logger_conf

  cat > "$ETC/rtp.conf" <<'C'
[general]
rtpstart=10000
rtpend=20000
C

  cat > "$ETC/modules.conf" <<'C'
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
}

generate_pjsip_and_dialplan(){
  local VPS_IP="$1"
  local ETC="/etc/asterisk"

  python3 - "$CFG" "$SECRETS" "$VPS_IP" "$ETC" <<'PY'
import json, secrets, string, sys, os, re

CFG, SECRETS, VPS_IP, ETC = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def gen_pass(n=18):
    a = string.ascii_letters + string.digits + "._-@:+#="
    return "".join(secrets.choice(a) for _ in range(n))

def clean_ext(x):
    x = str(x).strip()
    if not x:
        return ""
    # aceita só dígitos para ramal (interfone)
    if not re.fullmatch(r"\d{2,10}", x):
        raise SystemExit(f"Ramal inválido: {x} (use só dígitos, 2..10 chars)")
    return x

data = json.load(open(CFG, "r", encoding="utf-8"))

data.setdefault("portaria", {"ramal": "1000", "nome": "PORTARIA", "senha": ""})
data["portaria"]["ramal"] = clean_ext(data["portaria"].get("ramal", "1000") or "1000")
if not str(data["portaria"].get("senha","")).strip():
    data["portaria"]["senha"] = gen_pass()

# garante senhas para moradores
ramais_global=set([data["portaria"]["ramal"]])

for ap in data.get("apartamentos", []):
    apnum=str(ap.get("numero","")).strip()
    for m in ap.get("moradores", []):
        m["ramal"]=clean_ext(m.get("ramal",""))
        if not m["ramal"]:
            raise SystemExit(f"Morador sem ramal no AP {apnum}")
        if m["ramal"] in ramais_global:
            raise SystemExit(f"Ramal duplicado detectado: {m['ramal']}")
        ramais_global.add(m["ramal"])
        if not str(m.get("senha","")).strip():
            m["senha"] = gen_pass()

# =========================
# PJSIP (robusto)
# - endpoint == ramal
# - aor == ramal
# - auth == ramal
# - endpoint_identifier_order=auth_username,username,ip
# - transport UDP + TCP em 5060
# =========================
p=[]
p.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

p.append("[global]\n")
p.append("type=global\n")
p.append("user_agent=InterfonePBX/1.0\n")
p.append("endpoint_identifier_order=auth_username,username,ip\n\n")

# UDP
p.append("[transport-udp]\n")
p.append("type=transport\nprotocol=udp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

# TCP (mesma porta 5060)
p.append("[transport-tcp]\n")
p.append("type=transport\nprotocol=tcp\nbind=0.0.0.0:5060\n")
p.append(f"external_signaling_address={VPS_IP}\nexternal_media_address={VPS_IP}\n")
p.append("local_net=10.0.0.0/8\nlocal_net=172.16.0.0/12\nlocal_net=192.168.0.0/16\n\n")

# template
p.append("[endpoint-common](!)\n")
p.append("type=endpoint\n")
# IMPORTANTE: se teu cliente usar UDP, funciona com transport-udp
# Se usar TCP, você pode mudar aqui pra transport-tcp OU criar endpoint específico.
p.append("transport=transport-udp\n")
p.append("disallow=all\nallow=ulaw,alaw\n")
p.append("direct_media=no\n")
p.append("rtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\n")
p.append("timers=yes\nlanguage=pt_BR\n")
p.append("allow_unauthenticated_options=no\n")
p.append("mwi_subscribe_replaces_unsolicited=yes\n")
p.append("send_rpid=yes\n")
p.append("trust_id_outbound=yes\n")
p.append("trust_id_inbound=yes\n\n")

p.append("[aor-common](!)\n")
p.append("type=aor\n")
p.append("max_contacts=5\nremove_existing=yes\nqualify_frequency=30\n\n")

p.append("[auth-common](!)\n")
p.append("type=auth\nauth_type=userpass\n\n")

def add_user(ramal, nome, senha, context):
    ramal = str(ramal).strip()
    if not ramal:
        return
    endpoint = ramal
    aor = ramal
    auth = ramal

    p.append(f"[{aor}](aor-common)\n\n")
    p.append(f"[{auth}](auth-common)\nusername={ramal}\npassword={senha}\n\n")
    p.append(f"[{endpoint}](endpoint-common)\n")
    p.append(f"context={context}\n")
    p.append(f"auth={auth}\n")
    p.append(f"aors={aor}\n")
    p.append(f"callerid=\"{nome}\" <{ramal}>\n\n")

# Portaria + Moradores
add_user(data["portaria"]["ramal"], data["portaria"].get("nome","PORTARIA"), data["portaria"]["senha"], "from-portaria")
for ap in data.get("apartamentos", []):
    for m in ap.get("moradores", []):
        add_user(m.get("ramal",""), m.get("nome", f"AP{ap.get('numero','')}"), m.get("senha",""), "from-internal")

open(os.path.join(ETC, "pjsip.conf"), "w", encoding="utf-8").write("".join(p))

# =========================
# DIALPLAN
# - Discar AP (101/804) toca todos moradores do AP
# - Discar ramal direto (10101/80401...)
# - Morador disca 1000 para portaria
# =========================
e=[]
e.append("; INTERFONE - GERADO AUTOMATICAMENTE\n\n")

e.append("[from-portaria]\n")
e.append("exten => _X.,1,Goto(route,${EXTEN},1)\n\n")

e.append("[from-internal]\n")
e.append("exten => _X.,1,Goto(route,${EXTEN},1)\n\n")

e.append("[route]\n")
e.append("exten => _X.,1,NoOp(ROUTE ${EXTEN})\n")
e.append(" same => n,GotoIf($[${DIALPLAN_EXISTS(apartments,${EXTEN},1)}]?apartments,${EXTEN},1)\n")
e.append(" same => n,GotoIf($[${DIALPLAN_EXISTS(extens,${EXTEN},1)}]?extens,${EXTEN},1)\n")
e.append(" same => n,Playback(invalid)\n")
e.append(" same => n,Hangup()\n\n")

e.append("[extens]\n")
port_r = str(data.get("portaria", {}).get("ramal", "1000")).strip() or "1000"
e.append(f"exten => {port_r},1,NoOp(CHAMANDO PORTARIA)\n")
e.append(f" same => n,Dial(PJSIP/{port_r},30)\n")
e.append(" same => n,Hangup()\n\n")

ramais=set()
for ap in data.get("apartamentos", []):
    for m in ap.get("moradores", []):
        r=str(m.get("ramal","")).strip()
        if r:
            ramais.add(r)

for r in sorted(ramais):
    e.append(f"exten => {r},1,NoOp(CHAMANDO RAMAL {r})\n")
    e.append(f" same => n,Dial(PJSIP/{r},30)\n")
    e.append(" same => n,Hangup()\n\n")

e.append("[apartments]\n")
for ap in data.get("apartamentos", []):
    apnum=str(ap.get("numero","")).strip()
    targets=[f"PJSIP/{str(m.get('ramal','')).strip()}" for m in ap.get("moradores", []) if str(m.get("ramal","")).strip()]
    dial="&".join(targets)
    e.append(f"exten => {apnum},1,NoOp(AP {apnum} - RingGroup)\n")
    if dial:
        e.append(f" same => n,Dial({dial},20,tT)\n")
    else:
        e.append(" same => n,NoOp(AP sem moradores)\n")
    e.append(" same => n,Hangup()\n\n")

open(os.path.join(ETC, "extensions.conf"), "w", encoding="utf-8").write("".join(e))

json.dump(data, open(SECRETS, "w", encoding="utf-8"), indent=2, ensure_ascii=False)
json.dump(data, open(CFG, "w", encoding="utf-8"), indent=2, ensure_ascii=False)

print("OK: gerado pjsip.conf + extensions.conf; secrets em", SECRETS)
PY

  chmod 600 "$CFG" || true
  chmod 600 "$SECRETS" || true
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

  local i
  for i in {1..35}; do
    systemctl is-active --quiet asterisk && break
    sleep 0.4
  done

  systemctl is-active --quiet asterisk || { dump_failure; die "Asterisk não ficou ACTIVE."; }

  for i in {1..35}; do
    "${AST_BIN}" -rx "core show version" >/dev/null 2>&1 && { log "Asterisk OK e respondendo."; return 0; }
    sudo -u asterisk "${AST_BIN}" -rx "core show version" >/dev/null 2>&1 && { log "Asterisk OK e respondendo (como usuário asterisk)."; return 0; }
    sleep 0.4
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
      generate_pjsip_and_dialplan "$VPS_IP"
      restart_and_wait
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
  generate_pjsip_and_dialplan "$VPS_IP"
  enable_firewall
  restart_and_wait

  echo
  echo "=========================== INSTALADO ✅ ==========================="
  echo "Asterisk: $(find_asterisk_bin)"
  echo "Service:  systemctl status asterisk"
  echo "Senhas:   $SECRETS"
  echo "AMI/ARI:  $INTEG_TXT"
  echo "LOGS:"
  echo "  /var/log/asterisk/messages"
  echo "  /var/log/asterisk/security.log   (LOGIN/REGISTER failures)"
  echo "Testes:"
  echo "  asterisk -rx \"pjsip show endpoints\""
  echo "  asterisk -rx \"pjsip show contacts\""
  echo "==================================================================="
}

main "$@"
