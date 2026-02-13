#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

APP_NAME="interfone"
APP_DIR="/opt/interfone"
DATA_DIR="/opt/interfone/data"
VENV_DIR="/opt/interfone/venv"
LOG="/var/log/interfone-setup.log"

AST_URL_DEFAULT="https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz"
AST_URL="${AST_URL:-$AST_URL_DEFAULT}"

PJSIP_USERS="/etc/asterisk/pjsip_users.conf"
EXT_USERS="/etc/asterisk/extensions_users.conf"

die() {
  echo
  echo "[ERRO] $1"
  echo "[LOG] Veja: $LOG"
  echo
  exit 1
}

msg() {
  echo "[interfone] $1"
  echo "[interfone] $1" >>"$LOG"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Execute como root: sudo ./setup.sh"
  fi
}

detect_ssh_port() {
  # tenta achar porta do sshd em runtime
  local p
  p="$(ss -tlpn 2>/dev/null | awk '/sshd/ {print $4}' | head -n1 | awk -F: '{print $NF}' || true)"
  if [[ -z "${p:-}" ]]; then
    echo "22"
  else
    echo "$p"
  fi
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >>"$LOG" 2>&1
}

ensure_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
      msg "Aviso: sistema não parece Debian (ID=${ID:-?}). Vou continuar mesmo assim."
    fi
  fi
}

ensure_user_group() {
  if ! getent group asterisk >/dev/null 2>&1; then
    msg "Criando grupo asterisk..."
    groupadd --system asterisk >>"$LOG" 2>&1 || true
  fi
  if ! id asterisk >/dev/null 2>&1; then
    msg "Criando usuário asterisk..."
    useradd --system --home /var/lib/asterisk --gid asterisk --shell /usr/sbin/nologin asterisk >>"$LOG" 2>&1 || true
  fi
}

write_systemd_service() {
  msg "Criando service nativo systemd do Asterisk..."
  cat >/etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX
After=network.target

[Service]
Type=simple
User=asterisk
Group=asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0755
ExecStart=/usr/sbin/asterisk -f -U asterisk -G asterisk
ExecReload=/usr/sbin/asterisk -rx "core reload"
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload >>"$LOG" 2>&1
  systemctl enable asterisk >>"$LOG" 2>&1 || true
}

wait_asterisk() {
  msg "Iniciando Asterisk e aguardando socket de controle..."
  systemctl restart asterisk >>"$LOG" 2>&1 || true

  local i
  for i in {1..40}; do
    if [[ -S /var/run/asterisk/asterisk.ctl ]]; then
      return 0
    fi
    sleep 0.5
  done
  die "Asterisk não subiu (não achei /var/run/asterisk/asterisk.ctl). Verifique: systemctl status asterisk"
}

install_asterisk_from_source() {
  if command -v asterisk >/dev/null 2>&1; then
    msg "Asterisk já existe no sistema. Pulando build."
    return 0
  fi

  msg "Instalando dependências de build (Debian 13)..."
  apt-get update -y >>"$LOG" 2>&1

  # Dependências suficientes para compilar Asterisk com PJSIP (sem install_prereq)
  apt_install \
    ca-certificates curl wget tar gzip bzip2 xz-utils \
    build-essential pkg-config autoconf automake libtool \
    subversion \
    libssl-dev libxml2-dev libsqlite3-dev uuid-dev \
    libjansson-dev libedit-dev libncurses-dev \
    libsrtp2-dev \
    ufw rsync \
    python3 python3-venv python3-pip

  ensure_user_group

  msg "Baixando Asterisk (22-current)..."
  mkdir -p /usr/local/src/asterisk-build >>"$LOG" 2>&1
  cd /usr/local/src/asterisk-build
  rm -rf asterisk-22* asterisk.tar.gz >>"$LOG" 2>&1 || true

  wget -O asterisk.tar.gz "$AST_URL" >>"$LOG" 2>&1

  msg "Extraindo Asterisk..."
  tar -xzf asterisk.tar.gz >>"$LOG" 2>&1

  local AST_DIR
  AST_DIR="$(find . -maxdepth 1 -type d -name "asterisk-22*" | head -n1 || true)"
  if [[ -z "${AST_DIR:-}" ]]; then
    die "Não consegui detectar a pasta do Asterisk após extrair. Veja o log: $LOG"
  fi

  cd "$AST_DIR"

  msg "Configurando build do Asterisk (PJSIP bundled)..."
  ./configure --with-pjproject-bundled >>"$LOG" 2>&1

  msg "Compilando Asterisk (isso pode demorar)..."
  make -j"$(nproc)" >>"$LOG" 2>&1

  msg "Instalando Asterisk..."
  make install >>"$LOG" 2>&1
  make samples >>"$LOG" 2>&1 || true

  ldconfig >>"$LOG" 2>&1 || true

  write_systemd_service

  # Ajusta permissões padrão
  mkdir -p /var/run/asterisk /var/log/asterisk /var/spool/asterisk /var/lib/asterisk >>"$LOG" 2>&1
  chown -R asterisk:asterisk /var/run/asterisk /var/log/asterisk /var/spool/asterisk /var/lib/asterisk >>"$LOG" 2>&1 || true
  chgrp -R asterisk /etc/asterisk >>"$LOG" 2>&1 || true

  wait_asterisk

  msg "Teste Asterisk: core show version"
  asterisk -rx "core show version" >>"$LOG" 2>&1 || die "Asterisk instalado, mas CLI não conectou."
}

configure_firewall() {
  local SSH_PORT
  SSH_PORT="$(detect_ssh_port)"

  msg "Configurando UFW (SSH ${SSH_PORT}/tcp, SIP 5060/udp, RTP 10000-20000/udp)..."
  ufw --force enable >>"$LOG" 2>&1 || true
  ufw allow "${SSH_PORT}/tcp" >>"$LOG" 2>&1 || true
  ufw allow 5060/udp >>"$LOG" 2>&1 || true
  ufw allow 10000:20000/udp >>"$LOG" 2>&1 || true
}

write_asterisk_base_configs() {
  msg "Escrevendo configs base do PJSIP e Dialplan..."

  # RTP range
  cat >/etc/asterisk/rtp.conf <<'RTP'
[general]
rtpstart=10000
rtpend=20000
RTP

  # pjsip.conf (base) + include dos usuários gerados
  cat >/etc/asterisk/pjsip.conf <<'PJSIP'
; ================================
; Interfone Tactical - PJSIP Base
; ================================

[global]
type=global
user_agent=Interfone-Tactical

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
allow_reload=yes

; NAT friendly defaults (ok para VPS)
; (mantenha direct_media=no nos endpoints gerados)
; Os endpoints gerados vão usar:
;   rtp_symmetric=yes, force_rport=yes, rewrite_contact=yes

; Usuários gerados automaticamente:
#include pjsip_users.conf
PJSIP

  # extensions.conf (base) + include do dialplan gerado
  cat >/etc/asterisk/extensions.conf <<'EXT'
; ======================================
; Interfone Tactical - Dialplan Base
; ======================================

[interfone-ctx]
; aqui entram as chamadas dos ramais (endpoints)
; e os ramais "AP" (ex: 101, 102 etc) que disparam a estratégia
#include extensions_users.conf

; fallback padrão
exten => i,1,Playback(pbx-invalid)
 same => n,Hangup()
exten => t,1,Hangup()
EXT

  # Arquivos gerados (vazios inicialmente)
  if [[ ! -f "$PJSIP_USERS" ]]; then
    cat >"$PJSIP_USERS" <<'EOF'
; Arquivo gerado pelo Interfone Tactical
; NÃO EDITE MANUALMENTE (use o painel "interfone" e sincronize)
EOF
  fi

  if [[ ! -f "$EXT_USERS" ]]; then
    cat >"$EXT_USERS" <<'EOF'
; Arquivo gerado pelo Interfone Tactical
; NÃO EDITE MANUALMENTE (use o painel "interfone" e sincronize)
EOF
  fi

  chgrp asterisk /etc/asterisk/pjsip.conf /etc/asterisk/extensions.conf "$PJSIP_USERS" "$EXT_USERS" >>"$LOG" 2>&1 || true
  chmod 640 /etc/asterisk/pjsip.conf /etc/asterisk/extensions.conf "$PJSIP_USERS" "$EXT_USERS" >>"$LOG" 2>&1 || true

  msg "Recarregando Asterisk..."
  asterisk -rx "core reload" >>"$LOG" 2>&1 || true
  asterisk -rx "pjsip reload" >>"$LOG" 2>&1 || true
}

install_panel() {
  msg "Instalando painel em $APP_DIR..."

  mkdir -p "$APP_DIR" "$DATA_DIR" >>"$LOG" 2>&1

  # Copia arquivos do repo para /opt/interfone
  rsync -a --delete --exclude ".git" --exclude ".github" ./ "$APP_DIR/" >>"$LOG" 2>&1

  msg "Criando venv Python..."
  python3 -m venv "$VENV_DIR" >>"$LOG" 2>&1
  "$VENV_DIR/bin/pip" install --upgrade pip >>"$LOG" 2>&1
  "$VENV_DIR/bin/pip" install -r "$APP_DIR/requirements.txt" >>"$LOG" 2>&1

  msg "Instalando comando /usr/local/bin/interfone..."
  cat >/usr/local/bin/interfone <<'BIN'
#!/usr/bin/env bash
exec /opt/interfone/venv/bin/python /opt/interfone/interfone.py "$@"
BIN
  chmod +x /usr/local/bin/interfone >>"$LOG" 2>&1
}

main() {
  : >"$LOG"
  need_root
  ensure_os

  msg "=============================="
  msg "INTERFONE TACTICAL (Debian 13)"
  msg "=============================="

  configure_firewall
  install_asterisk_from_source
  write_asterisk_base_configs
  install_panel

  msg "Tudo pronto ✅"
  echo
  echo "[interfone] Teste Asterisk: asterisk -rx \"core show version\""
  echo "[interfone] Rodar painel:   interfone"
  echo
  echo "[interfone] Dica: crie primeiro o AP 1000 (Portaria) e adicione o SIP do porteiro."
  echo
}

main "$@"
