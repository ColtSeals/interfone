#!/bin/bash

echo ">>> Atualizando sistema e instalando dependencias..."
apt update && apt install asterisk python3 -y

echo ">>> Backup das configs originais..."
mv /etc/asterisk/pjsip.conf /etc/asterisk/pjsip.conf.original
mv /etc/asterisk/extensions.conf /etc/asterisk/extensions.conf.original

echo ">>> Criando estrutura de arquivos limpa..."
touch /etc/asterisk/pjsip_users.conf
touch /etc/asterisk/extensions_users.conf

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
endpoint/allow=ulaw,alaw,gsm
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

# Ajustando permissoes para o script Python poder escrever
chown asterisk:asterisk /etc/asterisk/pjsip_users.conf
chown asterisk:asterisk /etc/asterisk/extensions_users.conf
chmod 666 /etc/asterisk/pjsip_users.conf
chmod 666 /etc/asterisk/extensions_users.conf

echo ">>> Reiniciando Asterisk..."
systemctl restart asterisk
systemctl enable asterisk

echo ">>> Instalação Concluída!"
