#!/bin/bash

echo ">>> [1/4] Verificando disponibilidade do Asterisk..."
CANDIDATO=$(apt-cache policy asterisk | grep Candidate | grep -v "(none)")

if [ -z "$CANDIDATO" ]; then
    echo "⚠️ Ativando repositório Sid temporariamente para instalar Asterisk..."
    echo "deb http://deb.debian.org/debian sid main" >> /etc/apt/sources.list
    apt update -y
    apt install asterisk python3 -y
    sed -i '/sid/d' /etc/apt/sources.list
    apt update -y
else
    echo "✅ Instalando Asterisk via repositório padrão..."
    apt update -y && apt install asterisk python3 -y
fi

echo ">>> [2/4] Criando estrutura de diretórios e arquivos..."
mkdir -p /etc/asterisk
touch /etc/asterisk/pjsip_users.conf
touch /etc/asterisk/extensions_users.conf
chmod 777 /etc/asterisk/pjsip_users.conf
chmod 777 /etc/asterisk/extensions_users.conf

echo ">>> [3/4] Configurando Arquivos Mestres..."

# PJSIP.CONF (Modo Nativo)
cat <<EOF > /etc/asterisk/pjsip.conf
[global]
type=global
user_agent=InterfoneLuanque

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060

#include pjsip_users.conf
EOF

# EXTENSIONS.CONF
cat <<EOF > /etc/asterisk/extensions.conf
[interfone-ctx]
#include extensions_users.conf

exten => _X.,1,Hangup()
EOF

echo ">>> [4/4] Reiniciando serviços..."
systemctl restart asterisk
systemctl enable asterisk

echo "✅ AMBIENTE PRONTO! Agora use o manager.py para criar usuários."
