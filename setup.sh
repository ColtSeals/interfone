#!/usr/bin/env bash
set -euo pipefail

# ==============================
# SETUP TACTICAL - INTERFONE v7.0
# Debian 13 + Asterisk (PJSIP)
# ==============================

if [[ $EUID -ne 0 ]]; then
  echo "❌ Rode como root: sudo ./setup.sh"
  exit 1
fi

APP_DIR="/opt/interfone"
DATA_DIR="$APP_DIR/data"
LOG_DIR="/var/log/interfone"
DB_FILE="$DATA_DIR/condominio.json"

AST_ETC="/etc/asterisk"
PJSIP_MAIN="$AST_ETC/pjsip.conf"
EXT_MAIN="$AST_ETC/extensions.conf"
PJSIP_USERS="$AST_ETC/pjsip_users.conf"
EXT_USERS="$AST_ETC/extensions_users.conf"
CDR_CONF="$AST_ETC/cdr.conf"
CDRCSV_CONF="$AST_ETC/cdr_csv.conf"

# Detecta porta SSH pra não te trancar
SSH_PORT="$(awk '/^Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
if [[ -z "${SSH_PORT}" ]]; then SSH_PORT="22"; fi

echo "=============================="
echo "INTERFONE TACTICAL v7.0"
echo "=============================="
echo "SSH Port detectada: ${SSH_PORT}"
echo

echo ">>> [1/6] Instalando dependências (Asterisk + Python + UFW)..."
apt update -y
apt install -y asterisk python3 python3-venv python3-pip ufw

echo ">>> [2/6] Firewall UFW (sem te trancar)..."
ufw allow "${SSH_PORT}/tcp" >/dev/null
ufw allow 5060/udp >/dev/null
ufw allow 10000:20000/udp >/dev/null
ufw --force enable >/dev/null
ufw status

echo ">>> [3/6] Estruturando pastas do Interfone..."
mkdir -p "$APP_DIR" "$DATA_DIR" "$LOG_DIR"
chmod 750 "$APP_DIR" "$DATA_DIR"
chmod 750 "$LOG_DIR"

if [[ ! -f "$DB_FILE" ]]; then
  cat > "$DB_FILE" <<'JSON'
{
  "meta": {
    "name": "Condominio",
    "created_at": "init"
  },
  "users": []
}
JSON
  chmod 640 "$DB_FILE"
fi

echo ">>> [4/6] Config base do Asterisk (PJSIP + Dialplan + CDR)..."

# Include files
touch "$PJSIP_USERS" "$EXT_USERS"
chmod 640 "$PJSIP_USERS" "$EXT_USERS"

# pjsip.conf base com templates (bem mais limpo/maintainable)
cat > "$PJSIP_MAIN" <<'EOF'
[global]
type=global
user_agent=Interfone_Tactical_v7

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

; =========================
; Templates PJSIP (Premium)
; =========================
[auth-template](!)
type=auth
auth_type=userpass

[aor-template](!)
type=aor
max_contacts=1
remove_existing=yes
qualify_frequency=30

[endpoint-template](!)
type=endpoint
disallow=all
allow=ulaw,alaw,gsm,opus
transport=transport-udp
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
timers=yes
t38_udptl=no
trust_id_inbound=yes
send_pai=yes

#include pjsip_users.conf
EOF
chmod 640 "$PJSIP_MAIN"

# extensions.conf base
cat > "$EXT_MAIN" <<'EOF'
[interfone-common]
; Qualquer coisa não prevista cai fora
exten => _X.,1,Hangup()

[interfone-portaria]
; Ramal fixo da portaria (PJSIP/1000)
exten => 0,1,NoOp(Interfone: Chamando Portaria)
 same => n,Dial(PJSIP/1000,30)
 same => n,Hangup()

#include extensions_users.conf
EOF
chmod 640 "$EXT_MAIN"

# Habilita CDR CSV (histórico de chamadas)
# Obs: Alguns pacotes já vêm com isso, mas garantimos o básico.
if [[ -f "$CDR_CONF" ]]; then
  sed -i 's/^[; ]*enable *=.*/enable = yes/' "$CDR_CONF" || true
else
  cat > "$CDR_CONF" <<'EOF'
[general]
enable = yes
unanswered = yes
congestion = yes
batch = no
EOF
fi

if [[ -f "$CDRCSV_CONF" ]]; then
  sed -i 's/^[; ]*usegmtime *=.*/usegmtime = no/' "$CDRCSV_CONF" || true
  sed -i 's/^[; ]*loguniqueid *=.*/loguniqueid = yes/' "$CDRCSV_CONF" || true
else
  cat > "$CDRCSV_CONF" <<'EOF'
[general]
usegmtime = no
loguniqueid = yes
EOF
fi

echo ">>> [5/6] Python venv + dependências do painel (Textual)..."
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip >/dev/null
"$APP_DIR/venv/bin/pip" install textual psutil >/dev/null

echo ">>> [6/6] Reiniciando e habilitando Asterisk..."
systemctl restart asterisk
systemctl enable asterisk >/dev/null

echo
echo "✅ SETUP CONCLUÍDO!"
echo "----------------------------------------------------"
echo "1) Coloque o interfone.py em /opt/interfone/interfone.py"
echo "2) Rode o painel:"
echo "   sudo /opt/interfone/venv/bin/python /opt/interfone/interfone.py"
echo "----------------------------------------------------"
