cd ~/interfone

cat > setup.sh <<'BASH'
#!/usr/bin/env bash
set -u

APP_DIR="/opt/interfone"
VENV_DIR="/opt/interfone/venv"
AST_VER="20-current"
AST_TARBALL="asterisk-${AST_VER}.tar.gz"
AST_URL="https://downloads.asterisk.org/pub/telephony/asterisk/${AST_TARBALL}"
AST_SRC="/usr/src/asterisk-${AST_VER}"

PJSIP_MAIN="/etc/asterisk/pjsip.conf"
EXT_MAIN="/etc/asterisk/extensions.conf"
P_USERS="/etc/asterisk/pjsip_users.conf"
E_USERS="/etc/asterisk/extensions_users.conf"

log(){ echo -e "\n\033[96m[interfone]\033[0m $*"; }
die(){ echo -e "\n\033[91m[ERRO]\033[0m $*"; exit 1; }

detect_ssh_port() {
  # Tenta extrair a porta real do SSHD; fallback para 22
  local p
  p="$(ss -tnlp 2>/dev/null | awk '/sshd/ {print $4}' | head -n1 | sed -E 's/.*:([0-9]+)$/\1/')"
  [[ -n "${p}" ]] && echo "${p}" || echo "22"
}

ensure_base_packages() {
  log "Instalando pacotes base..."
  apt update -y
  apt install -y \
    ca-certificates curl wget git \
    build-essential pkg-config \
    python3 python3-venv python3-pip \
    ufw
}

configure_firewall() {
  local SSH_PORT="$1"
  log "Configurando UFW (SSH ${SSH_PORT}/tcp, SIP 5060/udp, RTP 10000-20000/udp)..."
  ufw allow "${SSH_PORT}/tcp" || true
  ufw allow 5060/udp || true
  ufw allow 10000:20000/udp || true
  ufw --force enable || true
}

install_asterisk_via_apt_or_source() {
  log "Tentando instalar Asterisk via apt..."
  set +e
  apt install -y asterisk
  local ok=$?
  set -e
  if [[ $ok -eq 0 ]]; then
    log "Asterisk instalado via apt ✅"
    return 0
  fi

  log "Pacote 'asterisk' não disponível no apt — compilando do fonte oficial (${AST_VER})..."
  rm -rf "${AST_SRC}" /usr/src/"${AST_TARBALL}" 2>/dev/null || true
  mkdir -p /usr/src
  cd /usr/src

  wget -O "${AST_TARBALL}" "${AST_URL}" || die "Falha ao baixar ${AST_URL}"
  tar -xzf "${AST_TARBALL}"
  cd "${AST_SRC}"

  # Pré-requisitos (recomendado pelo README do Asterisk)
  log "Instalando pré-requisitos do Asterisk (install_prereq)..."
  set +e
  yes | ./contrib/scripts/install_prereq install
  set -e

  log "Configurando e compilando Asterisk..."
  ./configure
  make -j"$(nproc)"
  make install
  make samples
  make config
  ldconfig

  # Usuário/grupo de execução
  if ! id asterisk >/dev/null 2>&1; then
    useradd -r -d /var/lib/asterisk -s /usr/sbin/nologin asterisk
  fi

  # Rodar como usuário asterisk
  if [[ -f /etc/asterisk/asterisk.conf ]]; then
    sed -i 's/^\s*;*\s*runuser\s*=.*$/runuser = asterisk/' /etc/asterisk/asterisk.conf || true
    sed -i 's/^\s*;*\s*rungroup\s*=.*$/rungroup = asterisk/' /etc/asterisk/asterisk.conf || true
  fi

  chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true
  chown -R root:asterisk /etc/asterisk 2>/dev/null || true
  chmod -R 750 /etc/asterisk 2>/dev/null || true

  systemctl daemon-reload || true
  systemctl enable --now asterisk || true
  log "Asterisk compilado e instalado ✅"
}

write_interfone_base_configs() {
  log "Aplicando configs base do Interfone (PJSIP + dialplan)..."

  mkdir -p /etc/asterisk
  touch "${P_USERS}" "${E_USERS}"
  chown root:asterisk "${P_USERS}" "${E_USERS}" || true
  chmod 640 "${P_USERS}" "${E_USERS}" || true

  cat > "${PJSIP_MAIN}" <<EOF
[global]
type=global
user_agent=Interfone_Tactical

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

#include pjsip_users.conf
EOF

  cat > "${EXT_MAIN}" <<EOF
[interfone-ctx]
; Ramal de Emergência/Portaria (0)
exten => 0,1,Dial(PJSIP/1000,30)
 same => n,Hangup()

#include extensions_users.conf
EOF

  chown root:asterisk "${PJSIP_MAIN}" "${EXT_MAIN}" || true
  chmod 640 "${PJSIP_MAIN}" "${EXT_MAIN}" || true

  systemctl restart asterisk || true
  asterisk -rx "core reload" >/dev/null 2>&1 || true
}

prepare_python_env() {
  log "Preparando ambiente Python em ${VENV_DIR}..."
  mkdir -p "${APP_DIR}"
  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools >/dev/null

  # Se o repo tiver requirements.txt, instala
  if [[ -f "$(pwd)/requirements.txt" ]]; then
    "${VENV_DIR}/bin/pip" install -r "$(pwd)/requirements.txt"
  fi

  # Copia o app para /opt/interfone (ajusta nomes conforme teu repo)
  rsync -a --delete "$(pwd)/" "${APP_DIR}/"
  chmod -R 750 "${APP_DIR}"
}

main() {
  local SSH_PORT
  SSH_PORT="$(detect_ssh_port)"

  log "=============================="
  log "INTERFONE TACTICAL (Debian 13 fix)"
  log "=============================="
  log "SSH detectada: ${SSH_PORT}"

  ensure_base_packages
  configure_firewall "${SSH_PORT}"
  install_asterisk_via_apt_or_source
  write_interfone_base_configs
  prepare_python_env

  log "Tudo pronto ✅"
  log "Teste rápido:"
  log "  systemctl status asterisk --no-pager"
  log "  asterisk -rx \"core show version\""
  log "Rodar o painel:"
  log "  ${VENV_DIR}/bin/python ${APP_DIR}/interfone.py"
}

set -e
main "$@"
BASH

chmod +x setup.sh
./setup.sh
