#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE="/var/log/interfone-setup.log"

exec > >(tee -a "$LOG_FILE") 2>&1

trap 'echo -e "\n[ERRO] Falhou na linha ${LINENO}: ${BASH_COMMAND}\nVeja o log: ${LOG_FILE}\n" >&2' ERR

# -----------------------------
# Helpers
# -----------------------------
say() { echo -e "[interfone] $*"; }
die() { echo -e "[interfone][ERRO] $*\n" >&2; exit 1; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Rode como root: sudo ./setup.sh"
  fi
}

detect_ssh_port() {
  local port="22"
  if command -v ss >/dev/null 2>&1; then
    port="$(ss -lntp 2>/dev/null | awk '$4 ~ /:22$/ {print "22"}' | head -n1 || true)"
  fi
  echo "${port:-22}"
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends "$@"
}

ensure_ufw() {
  local ssh_port="$1"
  if ! command -v ufw >/dev/null 2>&1; then
    apt_install ufw
  fi

  say "Configurando UFW (SSH ${ssh_port}/tcp, SIP 5060/udp, RTP 10000-20000/udp)..."
  ufw --force reset >/dev/null 2>&1 || true
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow "${ssh_port}/tcp"
  ufw allow 5060/udp
  ufw allow 10000:20000/udp
  ufw --force enable
}

ensure_asterisk_user() {
  if ! getent group asterisk >/dev/null; then
    say "Criando grupo asterisk..."
    groupadd --system asterisk
  fi
  if ! id -u asterisk >/dev/null 2>&1; then
    say "Criando usuário asterisk..."
    useradd --system --gid asterisk --home-dir /var/lib/asterisk --shell /usr/sbin/nologin asterisk
  fi
}

make_jobs() {
  local nproc_mem jobs
  nproc_mem="$(nproc || echo 1)"
  jobs="$nproc_mem"

  # Se VPS fraca, não explodir RAM
  local mem_mb
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)"
  if (( mem_mb < 2000 )); then
    jobs=1
  elif (( mem_mb < 3500 )); then
    jobs=2
  fi

  echo "$jobs"
}

install_asterisk_from_source() {
  if command -v asterisk >/dev/null 2>&1; then
    say "Asterisk já existe no sistema. Pulando build."
    return 0
  fi

  say "Instalando dependências de build (Debian 13)..."
  apt_install \
    ca-certificates curl wget gnupg rsync \
    build-essential autoconf automake libtool pkg-config \
    libedit-dev libjansson-dev libxml2-dev uuid-dev \
    libsqlite3-dev libssl-dev \
    libncurses5-dev libncursesw5-dev \
    libsrtp2-dev libcurl4-gnutls-dev \
    subversion

  ensure_asterisk_user

  local build_dir="/usr/src/interfone-build"
  mkdir -p "$build_dir"
  cd "$build_dir"

  say "Baixando Asterisk (22-current)..."
  rm -f asterisk-22-current.tar.gz
  wget -O asterisk-22-current.tar.gz "https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-22-current.tar.gz"

  say "Extraindo Asterisk..."
  rm -rf asterisk-22* || true
  tar -xzf asterisk-22-current.tar.gz

  local src
  src="$(find . -maxdepth 1 -type d -name "asterisk-22*" | head -n1 || true)"
  [[ -n "$src" ]] || die "Não consegui detectar a pasta extraída do Asterisk."

  cd "$src"

  say "Configurando build do Asterisk (PJSIP bundled)..."
  ./configure --with-pjproject-bundled --with-jansson-bundled

  local jobs
  jobs="$(make_jobs)"
  say "Compilando Asterisk (jobs=${jobs})..."
  make -j"$jobs"

  say "Instalando Asterisk..."
  make install
  make samples || true
  make config  || true
  ldconfig

  # diretórios e permissões
  install -d -o asterisk -g asterisk -m 0755 /var/lib/asterisk /var/log/asterisk /var/spool/asterisk
  install -d -o asterisk -g asterisk -m 0755 /var/run/asterisk /run/asterisk || true

  chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk || true
}

install_systemd_service() {
  # Se já existe unit custom, mantém.
  if [[ -f /etc/systemd/system/asterisk.service ]]; then
    say "Service systemd do Asterisk já existe. Mantendo."
    return 0
  fi

  say "Criando service nativo systemd do Asterisk..."
  cat >/etc/systemd/system/asterisk.service <<'UNIT'
[Unit]
Description=Asterisk PBX (Interfone Tactical)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=asterisk
Group=asterisk
WorkingDirectory=/var/lib/asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0755
ExecStart=/usr/sbin/asterisk -f -U asterisk -G asterisk -vvvg
ExecStop=/usr/sbin/asterisk -rx "core stop now"
Restart=on-failure
RestartSec=2
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
UNIT

  systemctl daemon-reload
  systemctl enable --now asterisk
}

wait_asterisk_ctl() {
  say "Iniciando Asterisk e aguardando socket de controle..."
  systemctl restart asterisk

  local i
  for i in {1..30}; do
    if [[ -S /var/run/asterisk/asterisk.ctl || -S /run/asterisk/asterisk.ctl ]]; then
      say "Socket OK."
      return 0
    fi
    sleep 1
  done
  die "Asterisk não criou o socket de controle (asterisk.ctl). Verifique: systemctl status asterisk"
}

write_asterisk_base_configs() {
  say "Escrevendo configs base do PJSIP e Dialplan..."

  # backup se existirem
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"

  if [[ -f /etc/asterisk/pjsip.conf ]]; then
    cp -a /etc/asterisk/pjsip.conf "/etc/asterisk/pjsip.conf.bak.${ts}" || true
  fi
  if [[ -f /etc/asterisk/extensions.conf ]]; then
    cp -a /etc/asterisk/extensions.conf "/etc/asterisk/extensions.conf.bak.${ts}" || true
  fi

  cat >/etc/asterisk/pjsip.conf <<'PJSIP'
; ===============================
; Interfone Tactical - PJSIP Base
; ===============================

[global]
type=global
user_agent=InterfoneTactical

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

; Template básico de endpoint (o painel gera endpoints em pjsip_users.conf)
[endpoint-template](!)
type=endpoint
context=interfone-ctx
disallow=all
allow=ulaw,alaw,gsm,opus
transport=transport-udp
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes

#include pjsip_users.conf
PJSIP

  cat >/etc/asterisk/extensions.conf <<'DPL'
; ===============================
; Interfone Tactical - Dialplan Base
; ===============================

[interfone-ctx]
; Tudo do interfone fica aqui
#include extensions_users.conf
DPL

  touch /etc/asterisk/pjsip_users.conf /etc/asterisk/extensions_users.conf
  chown root:asterisk /etc/asterisk/pjsip_users.conf /etc/asterisk/extensions_users.conf || true
  chmod 0640 /etc/asterisk/pjsip_users.conf /etc/asterisk/extensions_users.conf || true

  say "Recarregando Asterisk..."
  asterisk -rx "core reload" >/dev/null 2>&1 || true
  asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
}

install_panel() {
  say "Instalando painel em /opt/interfone..."

  # deps do python SEMPRE (mesmo se Asterisk já existia)
  apt_install python3 python3-venv python3-pip

  install -d -m 0755 /opt/interfone
  install -d -m 0755 /opt/interfone/bin
  install -d -m 0755 /opt/interfone/venv

  # copia arquivos do repo (sem apagar db.json se existir)
  local here
  here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

  install -m 0644 "$here/requirements.txt" /opt/interfone/requirements.txt
  install -m 0755 "$here/interfone.py" /opt/interfone/interfone.py

  if [[ ! -f /opt/interfone/db.json ]]; then
    cat >/opt/interfone/db.json <<'JSON'
{ "apartments": [] }
JSON
    chmod 0640 /opt/interfone/db.json
    chown root:asterisk /opt/interfone/db.json || true
  fi

  say "Criando venv Python..."
  rm -rf /opt/interfone/venv 2>/dev/null || true
  python3 -m venv /opt/interfone/venv

  say "Instalando dependências Python..."
  /opt/interfone/venv/bin/pip install --upgrade pip
  /opt/interfone/venv/bin/pip install -r /opt/interfone/requirements.txt

  say "Criando comando /usr/local/bin/interfone..."
  cat >/usr/local/bin/interfone <<'BIN'
#!/usr/bin/env bash
exec /opt/interfone/venv/bin/python /opt/interfone/interfone.py "$@"
BIN
  chmod +x /usr/local/bin/interfone

  say "Painel instalado ✅ (comando: interfone)"
}

main() {
  need_root

  say "=============================="
  say "INTERFONE TACTICAL (Debian 13)"
  say "=============================="

  local ssh_port
  ssh_port="$(detect_ssh_port)"
  ensure_ufw "$ssh_port"

  install_asterisk_from_source
  install_systemd_service
  wait_asterisk_ctl
  say "Teste Asterisk: $(asterisk -rx 'core show version' 2>/dev/null | head -n1 || true)"

  write_asterisk_base_configs
  install_panel

  say "Tudo pronto ✅"
  echo
  say "Rodar painel: interfone"
  say "Dica: crie primeiro o ramal 1000 (Portaria) no painel."
  echo
  say "Log: ${LOG_FILE}"
}

main "$@"
