#!/bin/bash

# ==============================================================================
# SCRIPT DE INSTALAÇÃO AUTOMATIZADA - INTERFONE LUANQUE (Debian 13 Safe)
# ==============================================================================

echo ">>> [1/5] Verificando disponibilidade do Asterisk..."

# Verifica se o pacote existe no repositório atual
if ! apt-cache show asterisk > /dev/null 2>&1; then
    echo "⚠️  ALERTA: Asterisk ausente no repositório padrão (Bug comum do Debian 13/Trixie)."
    echo ">>> Solução automática: Buscando no repositório 'Sid' (Unstable)..."
    
    # Adiciona repositório Sid temporariamente
    echo "deb http://deb.debian.org/debian sid main" >> /etc/apt/sources.list
    apt update -y
    USOU_SID=1
else
    echo "✅ Asterisk encontrado normalmente."
    USOU_SID=0
fi

echo ">>> [2/5] Instalando Asterisk e Python..."
apt install asterisk python3 -y

# Se usou o Sid, remove agora para não quebrar o sistema no futuro
if [ "$USOU_SID" -eq "1" ]; then
    echo ">>> Limpando repositórios temporários..."
    sed -i '/sid/d' /etc/apt/sources.list
    apt update -y
fi

# Verifica se instalou mesmo
if ! command -v asterisk &> /dev/null; then
    echo "❌ ERRO CRÍTICO: A instalação falhou. Verifique sua conexão."
    exit 1
fi

echo ">>> [3/5] Criando estrutura de arquivos..."

# Backup se já existir
[ -f /etc/asterisk/pjsip.conf ] && mv /etc/asterisk/pjsip.conf /etc/asterisk/pjsip.conf.bkp
[ -f /etc/asterisk/extensions.conf ] && mv /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf.bkp

# Cria os arquivos que o Python vai usar (Vazios inicialmente)
touch /etc/asterisk/pjsip_users.conf
touch /etc/asterisk/extensions_users.conf

# PERMISSÃO TOTAL (777) para evitar qualquer erro de "Permission Denied" no Python
chmod 777 /etc/asterisk/pjsip_users.conf
chmod 777 /etc/asterisk/extensions_users.conf

echo ">>> [4/5] Configurando Asterisk (PJSIP e Dialplan)..."

# Cria o PJSIP.CONF mestre
cat <<EOF > /etc/asterisk/pjsip.conf
[global]
type=global
user_agent=InterfoneLuanque

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

; Template para ramais (Com correção de NAT para telefones fisicos)
[template-ramal](!)
type=wizard
accepts_auth=yes
accepts_registrations=yes
transport=transport-udp
endpoint/context=interfone-ctx
endpoint/disallow=all
endpoint/allow=ulaw,alaw,gsm,opus
endpoint/direct_media=no
endpoint/rewrite_contact=yes
endpoint/rtp_symmetric=yes
endpoint/force_rport=yes
aor/max_contacts=2

; Importa usuarios do script Python
#include pjsip_users.conf
EOF

# Cria o EXTENSIONS.CONF mestre
cat <<EOF > /etc/asterisk/extensions.conf
[interfone-ctx]
; Importa logica dos usuarios do script Python
#include extensions_users.conf

; Bloqueia chamadas externas nao autorizadas
exten => _X.,1,Hangup()
EOF

echo ">>> [5/5] Finalizando..."
systemctl restart asterisk
systemctl enable asterisk

echo "========================================================="
echo "✅ INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "Pode rodar o menu agora: python3 manager.py"
echo "========================================================="
