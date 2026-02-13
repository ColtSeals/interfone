#!/bin/bash
# SETUP PREMIUM - INTERFONE INTELIGENTE v6.0

echo ">>> [1/4] Instalando Dependências..."
apt update -y && apt install asterisk python3 python3-pip ufw -y

echo ">>> [2/4] Configurando Segurança e Firewall..."
ufw allow 22/tcp
ufw allow 5060/udp
ufw allow 10000:20000/udp
ufw --force enable

echo ">>> [3/4] Estruturando Asterisk..."
mkdir -p /etc/asterisk
touch /etc/asterisk/pjsip_users.conf /etc/asterisk/extensions_users.conf
chmod -R 777 /etc/asterisk/
chmod -R 777 /var/log/asterisk/

# Criando PJSIP Base
cat <<EOF > /etc/asterisk/pjsip.conf
[global]
type=global
user_agent=Interfone_Premium_v6

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

#include pjsip_users.conf
EOF

# Criando Dialplan Base
cat <<EOF > /etc/asterisk/extensions.conf
[interfone-ctx]
; Ramal de Emergência/Portaria (0)
exten => 0,1,Dial(PJSIP/1000,30)
 same => n,Hangup()

#include extensions_users.conf
EOF

echo ">>> [4/4] Reiniciando Serviços..."
systemctl restart asterisk
systemctl enable asterisk
echo "✅ AMBIENTE PREMIUM PRONTO!"
