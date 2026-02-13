#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo bash "$0" "$@"
  fi
}

pause() { read -r -p "ENTER para continuar..." _; }

detect_public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1
}

regen() {
  local ip
  ip="$(detect_public_ip)"
  if [[ -z "${ip:-}" ]]; then
    echo "Não detectei IP. Ajuste no install.sh com --ip."
    return 1
  fi
  echo "Regenerando configs com IP: $ip"
  bash ./install.sh --ip "$ip" >/dev/null
  echo "OK: configs regenerados."
}

list_condo() {
  python3 - <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
print("PORTARIA:", data["portaria"]["ramal"], "-", data["portaria"].get("nome",""))
print("")
for ap in data.get("apartamentos",[]):
    print("AP", ap.get("numero","?"))
    for m in ap.get("moradores",[]):
        print("  -", m.get("ramal","?"), "|", m.get("nome",""))
PY
}

add_apartment() {
  read -r -p "Número do AP (ex: 804): " apnum
  [[ -z "${apnum// }" ]] && { echo "AP inválido"; return; }

  python3 - <<PY
import json
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])
if any(a.get("numero")== "${apnum}" for a in aps):
    print("Já existe.")
else:
    aps.append({"numero":"${apnum}","moradores":[]})
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: AP criado.")
PY
  chmod 600 "$CFG"
}

add_resident() {
  read -r -p "AP (ex: 804): " apnum
  read -r -p "Ramal SIP (ex: 80401): " ramal
  read -r -p "Nome (ex: AP804-01): " nome
  [[ -z "${apnum// }" || -z "${ramal// }" ]] && { echo "Dados inválidos"; return; }

  python3 - <<PY
import json
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])
ap=None
for a in aps:
    if a.get("numero")== "${apnum}":
        ap=a; break
if ap is None:
    print("AP não existe. Crie primeiro.")
    raise SystemExit(0)
mor=ap.setdefault("moradores",[])
if any(m.get("ramal")== "${ramal}" for m in mor):
    print("Ramal já existe.")
else:
    mor.append({"ramal":"${ramal}","nome":"${nome}","senha":""})
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: morador adicionado (senha será gerada ao regenerar).")
PY
  chmod 600 "$CFG"
}

remove_resident() {
  read -r -p "Ramal a remover (ex: 80401): " ramal
  [[ -z "${ramal// }" ]] && { echo "Ramal inválido"; return; }

  python3 - <<PY
import json
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
changed=False
for ap in data.get("apartamentos",[]):
    mor=ap.get("moradores",[])
    before=len(mor)
    ap["moradores"]=[m for m in mor if m.get("ramal")!="${ramal}"]
    if len(ap["moradores"])!=before:
        changed=True
if changed:
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: removido.")
else:
    print("Não achei esse ramal.")
PY
  chmod 600 "$CFG"
}

show_status() {
  echo "---- ENDPOINTS ----"
  asterisk -rx "pjsip show endpoints" || true
  echo
  echo "---- CONTACTS (ONLINE/OFFLINE) ----"
  asterisk -rx "pjsip show contacts" || true
  echo
  echo "---- CHANNELS (EM LIGAÇÃO) ----"
  asterisk -rx "core show channels concise" || true
}

show_secrets() {
  echo "Senhas SIP: $SECRETS"
  [[ -f "$SECRETS" ]] && (sed -n '1,200p' "$SECRETS" | head -n 120) || echo "Ainda não gerado. Rode install.sh."
  echo
  echo "AMI/ARI: $INTEG_TXT"
  [[ -f "$INTEG_TXT" ]] && cat "$INTEG_TXT" || true
}

firewall_menu() {
  echo "UFW status:"
  ufw status || true
  echo
  echo "Portas necessárias:"
  echo " - 5060/udp (SIP)"
  echo " - 10000-20000/udp (RTP áudio)"
  echo
  read -r -p "Reaplicar regras básicas e habilitar UFW? (s/n): " yn
  if [[ "${yn,,}" == "s" ]]; then
    ufw allow OpenSSH
    ufw allow 5060/udp
    ufw allow 10000:20000/udp
    ufw --force enable
    ufw status
  fi
}

main_menu() {
  while true; do
    clear
    echo "===================================="
    echo " INTERFONE - MENU (SIP CORE)"
    echo "===================================="
    echo "1) Ver status (online/offline/busy)"
    echo "2) Listar APs e moradores"
    echo "3) Adicionar AP"
    echo "4) Adicionar morador (ramal SIP)"
    echo "5) Remover morador (por ramal)"
    echo "6) Regenerar configs + reiniciar Asterisk"
    echo "7) Mostrar senhas/integrações (server-only)"
    echo "8) Firewall (UFW)"
    echo "0) Sair"
    echo
    read -r -p "Escolha: " opt

    case "$opt" in
      1) show_status; pause ;;
      2) list_condo; pause ;;
      3) add_apartment; pause ;;
      4) add_resident; pause ;;
      5) remove_resident; pause ;;
      6) regen; pause ;;
      7) show_secrets; pause ;;
      8) firewall_menu; pause ;;
      0) exit 0 ;;
      *) echo "Opção inválida"; pause ;;
    esac
  done
}

need_root "$@"

if [[ ! -f "./install.sh" ]]; then
  echo "Rode o menu dentro da pasta do repo (onde existe install.sh)."
  exit 1
fi

main_menu
