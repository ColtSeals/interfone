#!/usr/bin/env bash
set -euo pipefail

# =========================
# Interfone Tactical - Debian 13 (Trixie)
# Instala: Asterisk (source) + Painel Python + Configs base + wrapper "interfone"
# =========================

APP_DIR="/opt/interfone"
VENV_DIR="${APP_DIR}/venv"
DB_PATH="${APP_DIR}/db.json"

# Asterisk: use "22-current" (sempre pega a última 22.x) para não quebrar com versões
AST_VER="22-current"
AST_TARBALL="asterisk-${AST_VER}.tar.gz"
AST_URL="https://downloads.asterisk.org/pub/telephony/asterisk/${AST_TARBALL}"

PJSIP_MAIN="/etc/asterisk/pjsip.conf"
EXT_MAIN="/etc/asterisk/extensions.conf"
RTP_CONF="/etc/asterisk/rtp.conf"
P_USERS="/etc/asterisk/pjsip_users.conf"
E_USERS="/etc/asterisk/extensions_users.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log(){ echo -e "\n\033[96m[interfone]\033[0m $*"; }
warn(){ echo -e "\n\033[93m[warn]\033[0m $*"; }
die(){ echo -e "\n\033[91m[ERRO]\033[0m $*"; exit 1; }

detect_ssh_port() {
  local p=""
  if [[ -f /etc/ssh/sshd_config ]]; then
    p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  fi
  if [[ -z "${p}" ]]; then
    p="$(ss -tnlp 2>/dev/null | awk '/sshd/ {print $4}' | head -n1 | sed -E 's/.*:([0-9]+)$/\1/' || true)"
  fi
  [[ -n "${p}" ]] && echo "${p}" || echo "22"
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Rode como root (ou sudo)."
  fi
}

ensure_base_packages() {
  log "Instalando pacotes base (Debian 13)..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y

  # Base + build + libs comuns do Asterisk
  apt install -y \
    ca-certificates curl wget git rsync \
    build-essential pkg-config autoconf automake libtool \
    python3 python3-venv python3-pip \
    ufw \
    libssl-dev libncurses-dev libxml2-dev uuid-dev \
    libsqlite3-dev libjansson-dev libedit-dev \
    libcurl4-gnutls-dev \
    libsrtp2-dev \
    subversion || true
}

configure_firewall() {
  local SSH_PORT="$1"
  log "Configurando UFW (SSH ${SSH_PORT}/tcp, SIP 5060/udp, RTP 10000-20000/udp)..."

  # se ufw já está ativo, só garante regras
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
  log "Instalando unit systemd nativo do Asterisk..."
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

# -f foreground; -U/-G garante user/group; -c console off via systemd; -vvv logs
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
  # espera o socket de controle aparecer
  local i
  for i in $(seq 1 30); do
    if [[ -S /run/asterisk/asterisk.ctl || -S /var/run/asterisk/asterisk.ctl ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

install_asterisk_from_source() {
  if command -v /usr/sbin/asterisk >/dev/null 2>&1; then
    log "Asterisk já existe em /usr/sbin/asterisk ✅"
    write_systemd_unit_asterisk
    systemctl restart asterisk || true
    return 0
  fi

  log "Debian 13 não tem pacote 'asterisk' no apt → compilando via fonte oficial (${AST_VER})..."
  mkdir -p /usr/src
  cd /usr/src

  rm -f "${AST_TARBALL}" || true
  wget -O "${AST_TARBALL}" "${AST_URL}" || die "Falha ao baixar ${AST_URL}"

  # Descobre pasta real no tar (ex: asterisk-22.8.2/)
  local AST_DIR
  AST_DIR="$(tar -tf "${AST_TARBALL}" | head -1 | cut -d/ -f1)"
  [[ -n "${AST_DIR}" ]] || die "Não consegui detectar a pasta do tar."

  rm -rf "/usr/src/${AST_DIR}" || true
  tar -xzf "${AST_TARBALL}"
  cd "/usr/src/${AST_DIR}"

  log "Pré-requisitos do Asterisk (install_prereq)..."
  set +e
  yes | ./contrib/scripts/install_prereq install
  set -e

  log "Configurando build..."
  ./configure --with-pjproject-bundled --with-jansson-bundled

  # tenta habilitar opus se disponível (não quebra se não existir)
  if [[ -f menuselect/menuselect && -f menuselect.makeopts ]]; then
    menuselect/menuselect --enable codec_opus menuselect.makeopts >/dev/null 2>&1 || true
  fi

  log "Compilando Asterisk... (pode demorar)"
  make -j"$(nproc)"
  make install
  ldconfig

  ensure_asterisk_user
  write_systemd_unit_asterisk

  log "Iniciando Asterisk..."
  systemctl restart asterisk || true

  if ! wait_asterisk_ctl; then
    systemctl status asterisk --no-pager || true
    die "Asterisk não subiu (socket asterisk.ctl não apareceu). Veja: journalctl -u asterisk -n 200"
  fi

  log "Asterisk instalado ✅"
}

write_asterisk_base_configs() {
  log "Criando base do PJSIP e dialplan..."

  mkdir -p /etc/asterisk
  touch "${P_USERS}" "${E_USERS}"
  chown root:asterisk "${P_USERS}" "${E_USERS}" || true
  chmod 640 "${P_USERS}" "${E_USERS}" || true

  # RTP range fixo (bom para firewall)
  cat >"${RTP_CONF}" <<'EOF'
[general]
rtpstart=10000
rtpend=20000
EOF

  # pjsip.conf principal (inclui users gerados pelo painel)
  cat >"${PJSIP_MAIN}" <<'EOF'
[global]
type=global
user_agent=Interfone_Tactical

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

; endpoints gerados pelo painel
#include pjsip_users.conf
EOF

  # extensions.conf principal (inclui dialplan gerado)
  cat >"${EXT_MAIN}" <<'EOF'
[interfone-ctx]
; Portaria (ramal 1000) - também atende discando "0"
exten => 0,1,NoOp(Chamando Portaria)
 same => n,Dial(PJSIP/1000,30)
 same => n,Hangup()

; dialplan gerado pelo painel
#include extensions_users.conf
EOF

  chown root:asterisk "${PJSIP_MAIN}" "${EXT_MAIN}" "${RTP_CONF}" || true
  chmod 640 "${PJSIP_MAIN}" "${EXT_MAIN}" "${RTP_CONF}" || true

  systemctl restart asterisk || true

  # teste simples
  /usr/sbin/asterisk -rx "core show version" >/dev/null 2>&1 || true
}

install_panel() {
  log "Instalando painel em ${APP_DIR}..."
  mkdir -p "${APP_DIR}"

  # copia repo para /opt/interfone (sem .git)
  rsync -a --delete \
    --exclude ".git" \
    --exclude "__pycache__" \
    --exclude "*.pyc" \
    "${SCRIPT_DIR}/" "${APP_DIR}/"

  # cria venv
  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools >/dev/null

  if [[ -f "${APP_DIR}/requirements.txt" ]]; then
    "${VENV_DIR}/bin/pip" install -r "${APP_DIR}/requirements.txt"
  else
    "${VENV_DIR}/bin/pip" install rich psutil
  fi

  chmod -R 750 "${APP_DIR}"
  chown -R root:root "${APP_DIR}" || true

  # DB inicial (cria portaria 1000 se não existir)
  if [[ ! -f "${DB_PATH}" ]]; then
    local PASS
    PASS="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(10))
PY
)"
    cat >"${DB_PATH}" <<EOF
{
  "portaria": {
    "sip": "1000",
    "name": "Portaria",
    "password": "${PASS}"
  },
  "apartments": []
}
EOF
    chmod 640 "${DB_PATH}" || true
    log "Portaria criada: SIP=1000 | SENHA=${PASS}"
  fi

  # comando global
  log "Criando comando global: /usr/local/bin/interfone"
  cat >/usr/local/bin/interfone <<'SH'
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="/opt/interfone"
exec "${APP_DIR}/venv/bin/python" "${APP_DIR}/interfone.py" "$@"
SH
  chmod +x /usr/local/bin/interfone

  log "Painel instalado ✅ (comando: interfone)"
}

main() {
  ensure_root

  local SSH_PORT
  SSH_PORT="$(detect_ssh_port)"

  log "=============================="
  log "INTERFONE TACTICAL (Debian 13)"
  log "=============================="
  log "SSH detectada: ${SSH_PORT}"

  ensure_base_packages
  configure_firewall "${SSH_PORT}"

  ensure_asterisk_user
  install_asterisk_from_source
  write_asterisk_base_configs
  install_panel

  log "Tudo pronto ✅"
  log "Teste Asterisk: /usr/sbin/asterisk -rx \"core show version\""
  log "Rodar painel:   interfone"
  log "Dica: no painel, vá em 'Portaria (1000)' se quiser trocar a senha."
}

main "$@"
