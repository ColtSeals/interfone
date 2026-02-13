#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
VENV_DIR="${APP_DIR}/venv"

# Asterisk
AST_VER="22-current"
AST_TARBALL="asterisk-${AST_VER}.tar.gz"
AST_URL="https://downloads.asterisk.org/pub/telephony/asterisk/${AST_TARBALL}"

# Asterisk files
PJSIP_MAIN="/etc/asterisk/pjsip.conf"
EXT_MAIN="/etc/asterisk/extensions.conf"
P_USERS="/etc/asterisk/pjsip_users.conf"
E_USERS="/etc/asterisk/extensions_users.conf"

log(){ echo -e "\n\033[96m[interfone]\033[0m $*"; }
die(){ echo -e "\n\033[91m[ERRO]\033[0m $*"; exit 1; }

detect_ssh_port() {
  local p=""
  if [[ -f /etc/ssh/sshd_config ]]; then
    p="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/ {print $2; exit}' /etc/ssh/sshd_config || true)"
  fi
  [[ -n "${p}" ]] && echo "${p}" || echo "22"
}

ensure_base_packages() {
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
  log "Configurando UFW (SSH ${SSH_PORT}/tcp, SIP 5060/udp, RTP 10000-20000/udp)..."
  ufw allow "${SSH_PORT}/tcp" || true
  ufw allow 5060/udp || true
  ufw allow 10000:20000/udp || true
  ufw --force enable || true
}

install_asterisk() {
  log "Tentando instalar Asterisk via apt..."
  set +e
  apt install -y asterisk
  local ok=$?
  set -e

  if [[ $ok -eq 0 ]]; then
    log "Asterisk instalado via apt ✅"
    return
  fi

  log "Sem pacote 'asterisk' no apt — compilando do fonte oficial (${AST_VER})..."
  mkdir -p /usr/src
  cd /usr/src

  rm -f "${AST_TARBALL}" 2>/dev/null || true
  wget -O "${AST_TARBALL}" "${AST_URL}" || die "Falha ao baixar ${AST_URL}"

  # Detecta o nome real da pasta dentro do tar (evita erro de cd)
  AST_DIR="$(tar -tf "${AST_TARBALL}" | head -1 | cut -d/ -f1)"
  [[ -n "${AST_DIR}" ]] || die "Não consegui detectar a pasta do tar."
  rm -rf "/usr/src/${AST_DIR}" 2>/dev/null || true
  tar -xzf "${AST_TARBALL}"

  cd "/usr/src/${AST_DIR}"

  log "Pré-requisitos do Asterisk (install_prereq)..."
  yes | ./contrib/scripts/install_prereq install || true

  log "Compilando Asterisk..."
  ./configure
  make -j"$(nproc)"
  make install
  make samples
  make config
  ldconfig

  if ! id asterisk >/dev/null 2>&1; then
    useradd -r -d /var/lib/asterisk -s /usr/sbin/nologin asterisk || true
  fi

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
; Portaria (ramal 1000)
exten => 0,1,NoOp(Chamando Portaria)
 same => n,Dial(PJSIP/1000,30)
 same => n,Hangup()

#include extensions_users.conf
EOF

  chown root:asterisk "${PJSIP_MAIN}" "${EXT_MAIN}" || true
  chmod 640 "${PJSIP_MAIN}" "${EXT_MAIN}" || true

  systemctl restart asterisk || true

  # só tenta -rx depois que o ctl existir
  for i in {1..20}; do
    [[ -S /run/asterisk/asterisk.ctl || -S /var/run/asterisk/asterisk.ctl ]] && break
    sleep 0.3
  done

  asterisk -rx "core reload" >/dev/null 2>&1 || true
}

install_panel() {
  log "Instalando painel em ${APP_DIR}..."
  mkdir -p "${APP_DIR}"
  rsync -a --delete "$(pwd)/" "${APP_DIR}/"

  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools >/dev/null
  "${VENV_DIR}/bin/pip" install -r "${APP_DIR}/requirements.txt" >/dev/null

  chmod +x "${APP_DIR}/interfone.py"

  # comando global
  cat > /usr/local/bin/interfone <<EOF
#!/usr/bin/env bash
exec ${VENV_DIR}/bin/python ${APP_DIR}/interfone.py "\$@"
EOF
  chmod +x /usr/local/bin/interfone

  log "Painel instalado ✅ (comando: interfone)"
}

main() {
  local SSH_PORT
  SSH_PORT="$(detect_ssh_port)"

  log "=============================="
  log "INTERFONE TACTICAL (Debian 13)"
  log "=============================="
  log "SSH detectada: ${SSH_PORT}"

  ensure_base_packages
  configure_firewall "${SSH_PORT}"
  install_asterisk
  write_base_asterisk_configs
  install_panel

  log "Tudo pronto ✅"
  log "Teste Asterisk: asterisk -rx \"core show version\""
  log "Rodar painel:   interfone"
  log "Dica: crie primeiro o ramal 1000 (Portaria) no painel."
}

main "$@"
