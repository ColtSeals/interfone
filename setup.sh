#!/bin/bash
# SETUP BLINDADO - INTERFONE OPERACIONAL

echo ">>> [1/3] Corrigindo Repositorios e Instalando Asterisk..."
CANDIDATO=$(apt-cache policy asterisk | grep Candidate | grep -v "(none)")
if [ -z "$CANDIDATO" ]; then
    echo "deb http://deb.debian.org/debian sid main" >> /etc/apt/sources.list
    apt update -y && apt install asterisk python3 python3-pip -y
    sed -i '/sid/d' /etc/apt/sources.list
    apt update -y
else
    apt update -y && apt install asterisk python3 -y
fi

echo ">>> [2/3] Criando Estrutura de Arquivos..."
mkdir -p /etc/asterisk
touch /etc/asterisk/pjsip_users.conf /etc/asterisk/extensions_users.conf
chmod 777 /etc/asterisk/pjsip_users.conf /etc/asterisk/extensions_users.conf

# PJSIP MASTER CONFIG
cat <<EOF > /etc/asterisk/pjsip.conf
[global]
type=global
user_agent=Interfone_Operacional_V2

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

#include pjsip_users.conf
EOF

# EXTENSIONS MASTER CONFIG
cat <<EOF > /etc/asterisk/extensions.conf
[interfone-ctx]
#include extensions_users.conf
exten => _X.,1,Hangup()
EOF

echo ">>> [3/3] Ajustando Firewall e Servico..."
# Abre a porta 5060 UDP e o range de audio RTP
apt install ufw -y
ufw allow 5060/udp
ufw allow 10000:20000/udp
ufw --force enable

systemctl restart asterisk
systemctl enable asterisk

echo "✅ AMBIENTE OPERACIONAL PRONTO!"
