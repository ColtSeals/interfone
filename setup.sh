#!/bin/bash

# === CORREÇÃO AUTOMÁTICA DE REPOSITÓRIO (DEBIAN 13/TRIXIE) ===
echo ">>> Verificando disponibilidade do Asterisk..."
if ! apt-cache show asterisk > /dev/null 2>&1; then
    echo "[AVISO] Asterisk não encontrado no repositório padrão (Bug do Debian Trixie)."
    echo ">>> Adicionando repositório 'Sid' temporariamente..."
    echo "deb http://deb.debian.org/debian sid main" >> /etc/apt/sources.list
    apt update
    INSTALOU_VIA_SID=1
else
    echo ">>> Asterisk encontrado nos repositórios padrão."
    INSTALOU_VIA_SID=0
fi

echo ">>> Instalando Asterisk e Python..."
apt install asterisk python3 -y

if [ "$INSTALOU_VIA_SID" -eq "1" ]; then
    echo ">>> Removendo repositório 'Sid' para manter o sistema estável..."
    sed -i '/sid/d' /etc/apt/sources.list
    apt update
fi

# === CONFIGURAÇÃO DOS ARQUIVOS ===
echo ">>> Backup das configs originais..."
[ -f /etc/asterisk/pjsip.conf ] && mv /etc/asterisk/pjsip.conf /etc/asterisk/pjsip.conf.bak
[ -f /etc/asterisk/extensions.conf ] && mv /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf.bak

echo ">>> Criando estrutura de arquivos..."
# Garante que os arquivos existam e tenham permissão total para evitar erro no Python
touch /etc/asterisk/pjsip_users.conf
touch /etc/asterisk/extensions_users.conf
chmod 777 /etc/asterisk/pjsip_users.conf
chmod 777 /etc/asterisk/extensions_users.conf

# Criando pjsip.conf base
cat <<EOF > /etc/asterisk/pjsip.conf
[global]
type=global
user_agent=InterfoneLuanque

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

; Template base para usuarios
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
aor/max_contacts=2

; Inclui os usuarios gerados pelo Python
#include pjsip_users.conf
EOF

# Criando extensions.conf base
cat <<EOF > /etc/asterisk/extensions.conf
[interfone-ctx]
; Inclui o plano de discagem dos usuarios
#include extensions_users.conf

; Rejeita o resto
exten => _X.,1,Hangup()
EOF

echo ">>> Reiniciando Asterisk..."
systemctl restart asterisk
systemctl enable asterisk

echo ">>> Instalação Concluída! Pode rodar 'python3 manager.py'"
