#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/interfone"
VENV_DIR="${APP_DIR}/venv"
DB_PATH="${APP_DIR}/db.json"

AST_VER="22-current"
AST_TARBALL="asterisk-${AST_VER}.tar.gz"
AST_URL="https://downloads.asterisk.org/pub/telephony/asterisk/${AST_TARBALL}"

PJSIP_MAIN="/etc/asterisk/pjsip.conf"
EXT_MAIN="/etc/asterisk/extensions.conf"
RTP_CONF="/etc/asterisk/rtp.conf"
P_USERS="/etc/asterisk/pjsip_users.conf"
E_USERS="/etc/asterisk/extensions_users.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/interfone-setup.log"

log(){ echo -e "\n\033[96m[interfone]\033[0m $*"; }
die(){ echo -e "\n\033[91m[ERRO]\033[0m $*"; exit 1; }

on_error() {
  local exit_code=$?
  echo -e "\n\033[91m[ERRO]\033[0m Falhou na linha ${BASH_LINENO[0]}: ${BASH_COMMAND}"
  echo -e "\033[91m[ERRO]\033[0m Exit code: ${exit_code}"
  echo -e "\n\033[93m[LOG]\033[0m Últimas linhas do log (${LOG_FILE}):"
  tail -n 200 "${LOG_FILE}" 2>/dev/null || true
  exit "${exit_code}"
}
trap on_error ERR

ensure_root() {
  [[ "${EUID}" -eq 0 ]] || die "Rode como root (ou sudo)."
}

detect_ssh_port() {
  local p=""
  if [[ -f /etc/ssh/sshd_config ]]; then
    p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  fi
  [[ -n "${p}" ]] && echo "${p}" || echo "22"
}

ensure_base_packages() {
  log "Instalando pacotes base (Debian 13)..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y

  apt install -y \
    ca-certificates curl wget git rsync \
    build-essential pkg-config autoconf automake libtool \
    python3 python3-venv python3-pip \
    ufw \
    libssl-dev libncurses-dev libxml2-dev uuid-dev \
    libsqlite3-dev libjansson-dev libedit-dev \
    libcurl4-gnutls-dev \
    libsrtp2-dev \
    subversion
}

configure_firewall() {
  local SSH_PORT="$1"
  log "Configurando UFW (SSH ${SSH_PORT}/tcp, SIP 5060/udp, RTP 10000-20000/udp)..."
  ufw allow "${SSH_PORT}/tcp" || true
  ufw allow 5060/udp || true
  ufw allow 10000:20000/udp || true
  ufw --force enable || true
}

ensure_asterisk_user() {
  if ! id asterisk >/dev/null 2>&1; then
    log "Criando usuário/grupo asterisk..."
    useradd -r -d /var/lib/asterisk -s /usr/sbin/nologin asterisk || true
  fi

  mkdir -p /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /run/asterisk /etc/asterisk
  chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /run/asterisk || true
  chown -R root:asterisk /etc/asterisk || true
  chmod -R 750 /etc/asterisk || true
}

write_systemd_unit_asterisk() {
  log "Instalando unit systemd nativa do Asterisk..."
  cat >/etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX (Interfone Tactical)
After=network.target

[Service]
Type=simple
User=asterisk
Group=asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0750
WorkingDirectory=/var/lib/asterisk
ExecStart=/usr/sbin/asterisk -f -U asterisk -G asterisk -vvvg
ExecReload=/usr/sbin/asterisk -rx "core reload"
Restart=on-failure
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable asterisk >/dev/null 2>&1 || true
}

wait_asterisk_ctl() {
  for _ in $(seq 1 30); do
    if [[ -S /run/asterisk/asterisk.ctl || -S /var/run/asterisk/asterisk.ctl ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

install_asterisk_from_source() {
  if [[ -x /usr/sbin/asterisk ]]; then
    log "Asterisk já existe em /usr/sbin/asterisk ✅"
    write_systemd_unit_asterisk
    systemctl restart asterisk || true
    return 0
  fi

  log "Debian 13 sem pacote 'asterisk' no apt → compilando via fonte oficial (${AST_VER})..."
  mkdir -p /usr/src
  cd /usr/src

  rm -f "${AST_TARBALL}" || true
  wget -O "${AST_TARBALL}" "${AST_URL}"

  log "Extraindo tar e detectando pasta..."
  # ✅ FIX: evitar SIGPIPE matar o script com pipefail (tar | head)
  AST_DIR="$(tar -tf "${AST_TARBALL}" | head -n 1 | cut -d/ -f1 || true)"
  [[ -n "${AST_DIR}" ]] || die "Não consegui detectar a pasta do tar. Arquivo: ${AST_TARBALL}"
  log "Pasta detectada: ${AST_DIR}"

  rm -rf "/usr/src/${AST_DIR}" || true
  tar -xzf "${AST_TARBALL}"
  cd "/usr/src/${AST_DIR}"

  log "Pré-requisitos do Asterisk (install_prereq)..."
  set +e
  yes | ./contrib/scripts/install_prereq install
  set -e

  log "Configurando build..."
  ./configure --with-pjproject-bundled --with-jansson-bundled

  if [[ -f menuselect/menuselect && -f menuselect.makeopts ]]; then
    menuselect/menuselect --enable codec_opus menuselect.makeopts >/dev/null 2>&1 || true
  fi

  log "Compilando..."
  make -j"$(nproc)"

  log "Instalando..."
  make install

  log "Instalando samples..."
  make samples
  ldconfig

  ensure_asterisk_user
  write_systemd_unit_asterisk

  log "Ajustando asterisk.conf (runuser/rungroup)..."
  if [[ -f /etc/asterisk/asterisk.conf ]]; then
    sed -i 's/^[[:space:]]*;*[[:space:]]*runuser[[:space:]]*=.*$/runuser = asterisk/' /etc/asterisk/asterisk.conf || true
    sed -i 's/^[[:space:]]*;*[[:space:]]*rungroup[[:space:]]*=.*$/rungroup = asterisk/' /etc/asterisk/asterisk.conf || true
  fi

  log "Iniciando Asterisk..."
  systemctl restart asterisk

  if ! wait_asterisk_ctl; then
    systemctl status asterisk --no-pager || true
    die "Asterisk não subiu. Rode: journalctl -u asterisk -n 200 --no-pager"
  fi

  log "Asterisk instalado ✅"
}

write_asterisk_base_configs() {
  log "Criando configs base (PJSIP + Dialplan + RTP)..."

  touch "${P_USERS}" "${E_USERS}"
  chown root:asterisk "${P_USERS}" "${E_USERS}" || true
  chmod 640 "${P_USERS}" "${E_USERS}" || true

  cat >"${RTP_CONF}" <<'EOF'
[general]
rtpstart=10000
rtpend=20000
EOF

  cat >"${PJSIP_MAIN}" <<'EOF'
[global]
type=global
user_agent=Interfone_Tactical

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

#include pjsip_users.conf
EOF

  cat >"${EXT_MAIN}" <<'EOF'
[residente-ctx]
exten => 0,1,NoOp(RESIDENTE -> PORTARIA)
 same => n,Dial(PJSIP/1000,30)
 same => n,Hangup()

[portaria-ctx]
#include extensions_users.conf
EOF

  chown root:asterisk "${PJSIP_MAIN}" "${EXT_MAIN}" "${RTP_CONF}" || true
  chmod 640 "${PJSIP_MAIN}" "${EXT_MAIN}" "${RTP_CONF}" || true

  systemctl restart asterisk
  /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1 || true
}

install_panel() {
  log "Instalando painel em ${APP_DIR}..."
  mkdir -p "${APP_DIR}"

  rsync -a --delete \
    --exclude ".git" \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "${SCRIPT_DIR}/" "${APP_DIR}/"

  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools >/dev/null
  "${VENV_DIR}/bin/pip" install -r "${APP_DIR}/requirements.txt"

  chmod -R 750 "${APP_DIR}"

  if [[ ! -f "${DB_PATH}" ]]; then
    local PASS
    PASS="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(10))
PY
)"
    cat >"${DB_PATH}" <<EOF
{
  "portaria": { "sip": "1000", "name": "Portaria", "password": "${PASS}" },
  "apartments": []
}
EOF
    chmod 640 "${DB_PATH}" || true
    log "Portaria criada: SIP=1000 | SENHA=${PASS}"
  fi

  log "Criando comando global: /usr/local/bin/interfone"
  cat >/usr/local/bin/interfone <<'SH'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="/opt/interfone"
exec "${APP_DIR}/venv/bin/python" "${APP_DIR}/interfone.py" "$@"
SH
  chmod +x /usr/local/bin/interfone
}

main() {
  ensure_root

  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}"
  chmod 600 "${LOG_FILE}" || true
  exec > >(tee -a "${LOG_FILE}") 2>&1

  local SSH_PORT
  SSH_PORT="$(detect_ssh_port)"

  log "=============================="
  log "INTERFONE TACTICAL (Debian 13)"
  log "=============================="
  log "SSH detectada: ${SSH_PORT}"
  log "Log: ${LOG_FILE}"

  ensure_base_packages
  configure_firewall "${SSH_PORT}"

  ensure_asterisk_user
  install_asterisk_from_source
  write_asterisk_base_configs
  install_panel

  log "Tudo pronto ✅"
  log "Teste: /usr/sbin/asterisk -rx \"core show version\""
  log "Rodar painel: interfone"
}

main "$@"
