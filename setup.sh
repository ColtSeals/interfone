#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${APP_DIR}/venv"

AST_VER="22-current"
AST_TARBALL="asterisk-${AST_VER}.tar.gz"
AST_URL="https://downloads.asterisk.org/pub/telephony/asterisk/${AST_TARBALL}"

PJSIP_MAIN="/etc/asterisk/pjsip.conf"
EXT_MAIN="/etc/asterisk/extensions.conf"
P_USERS="/etc/asterisk/pjsip_users.conf"
E_USERS="/etc/asterisk/extensions_users.conf"

log(){ echo -e "\n\033[96m[interfone]\033[0m $*"; }
warn(){ echo -e "\n\033[93m[avis]\033[0m $*"; }
die(){ echo -e "\n\033[91m[erro]\033[0m $*"; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Rode como root: sudo ./setup.sh"
}

check_debian13() {
  [[ -f /etc/os-release ]] || die "/etc/os-release não encontrado"
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    die "Este setup é para Debian. Detectado: ${ID:-desconhecido}"
  fi
  if [[ "${VERSION_ID:-}" != "13" ]]; then
    die "Você pediu Debian 13. Detectado Debian ${VERSION_ID:-?} (${VERSION_CODENAME:-?}). Reinstale a VPS em Debian 13 (trixie)."
  fi
}

detect_ssh_port() {
  local p=""
  if [[ -f /etc/ssh/sshd_config ]]; then
    p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config || true)"
  fi
  [[ -n "${p}" ]] && echo "${p}" || echo "22"
}

install_base() {
  log "Instalando pacotes base..."
  apt update -y
  apt install -y \
    ca-certificates curl wget git rsync \
    build-essential pkg-config autoconf automake libtool \
    python3 python3-venv python3-pip \
    ufw
}

configure_firewall() {
  local SSH_PORT="$1"
  log "Configurando UFW (sem te trancar): SSH ${SSH_PORT}/tcp | SIP 5060/udp | RTP 10000-20000/udp"
  ufw allow "${SSH_PORT}/tcp" || true
  ufw allow 5060/udp || true
  ufw allow 10000:20000/udp || true
  ufw --force enable || true
}

install_asterisk_if_needed() {
  if command -v asterisk >/dev/null 2>&1; then
    local v
    v="$(asterisk -V 2>/dev/null || true)"
    warn "Asterisk já parece instalado: ${v}"
    return 0
  fi

  log "Asterisk não está instalado via apt no Debian 13 — compilando do fonte oficial (${AST_VER})..."

  mkdir -p /usr/src
  cd /usr/src

  rm -f "${AST_TARBALL}" 2>/dev/null || true
  wget -O "${AST_TARBALL}" "${AST_URL}"

  # Detecta o diretório real dentro do tar SEM quebrar por pipefail/SIGPIPE
  set +o pipefail
  AST_DIR="$(tar -tf "${AST_TARBALL}" | sed -n '1{s@/.*@@p;q}')"
  set -o pipefail

  [[ -n "${AST_DIR}" ]] || die "Não consegui detectar a pasta do tar do Asterisk."
  rm -rf "/usr/src/${AST_DIR}" 2>/dev/null || true
  tar -xzf "${AST_TARBALL}"
  cd "/usr/src/${AST_DIR}"

  log "Instalando pré-requisitos do Asterisk (install_prereq)..."
  yes | ./contrib/scripts/install_prereq install || true

  log "Configurando/compilando Asterisk..."
  ./configure
  make -j"$(nproc)"
  make install
  make samples
  make config
  ldconfig

  # usuário de execução
  if ! id asterisk >/dev/null 2>&1; then
    useradd -r -d /var/lib/asterisk -s /usr/sbin/nologin asterisk || true
  fi

  # rodar como usuário asterisk
  if [[ -f /etc/asterisk/asterisk.conf ]]; then
    sed -i 's/^[[:space:]]*;*[[:space:]]*runuser[[:space:]]*=.*$/runuser = asterisk/' /etc/asterisk/asterisk.conf || true
    sed -i 's/^[[:space:]]*;*[[:space:]]*rungroup[[:space:]]*=.*$/rungroup = asterisk/' /etc/asterisk/asterisk.conf || true
  fi

  chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true
  chown -R root:asterisk /etc/asterisk 2>/dev/null || true
  chmod -R 750 /etc/asterisk 2>/dev/null || true

  systemctl daemon-reload || true
  systemctl enable --now asterisk || true

  log "Asterisk instalado ✅"
  asterisk -rx "core show version" || true
}

write_base_asterisk_configs() {
  log "Criando base do PJSIP e dialplan..."

  mkdir -p /etc/asterisk
  touch "${P_USERS}" "${E_USERS}"
  chown root:asterisk "${P_USERS}" "${E_USERS}" || true
  chmod 640 "${P_USERS}" "${E_USERS}" || true

  cat > "${PJSIP_MAIN}" <<'EOF'
[global]
type=global
user_agent=Interfone_Tactical

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

#include pjsip_users.conf
EOF

  cat > "${EXT_MAIN}" <<'EOF'
[interfone-ctx]
; Discagem 0 -> Portaria (ramal SIP 1000)
exten => 0,1,NoOp(Chamando Portaria)
 same => n,Dial(PJSIP/1000,30)
 same => n,Hangup()

#include extensions_users.conf
EOF

  chown root:asterisk "${PJSIP_MAIN}" "${EXT_MAIN}" || true
  chmod 640 "${PJSIP_MAIN}" "${EXT_MAIN}" || true

  systemctl restart asterisk || true
  asterisk -rx "core reload" || true
}

install_panel() {
  log "Instalando painel em ${APP_DIR}..."

  mkdir -p "${APP_DIR}"
  rsync -a --delete "${REPO_DIR}/" "${APP_DIR}/"

  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools >/dev/null
  "${VENV_DIR}/bin/pip" install -r "${APP_DIR}/requirements.txt"

  chmod -R 750 "${APP_DIR}"

  # atalho
  ln -sf "${VENV_DIR}/bin/python" /usr/local/bin/interfone-py
  cat > /usr/local/bin/interfone <<EOF
#!/usr/bin/env bash
exec ${VENV_DIR}/bin/python ${APP_DIR}/interfone.py "\$@"
EOF
  chmod +x /usr/local/bin/interfone

  log "Painel instalado ✅ (comando: interfone)"
}

main() {
  require_root
  check_debian13

  local SSH_PORT
  SSH_PORT="$(detect_ssh_port)"

  log "=============================="
  log "INTERFONE TACTICAL (Debian 13)"
  log "=============================="
  log "SSH detectada: ${SSH_PORT}"

  install_base
  configure_firewall "${SSH_PORT}"
  install_asterisk_if_needed
  write_base_asterisk_configs
  install_panel

  log "Tudo pronto ✅"
  log "Teste Asterisk: asterisk -rx \"core show version\""
  log "Rodar painel:   interfone"
  log "Dica: crie primeiro o ramal 1000 (Portaria) no painel."
}

main "$@"
