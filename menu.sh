#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo bash "$0" "$@"; }
pause(){ read -r -p "ENTER para continuar..." _; }

has_asterisk(){
  command -v asterisk >/dev/null 2>&1
}

show_status(){
  if ! has_asterisk; then
    echo "Asterisk NÃO está instalado."
    echo "Use a opção 9) Instalar Asterisk"
    return
  fi
  echo "---- ENDPOINTS ----"
  asterisk -rx "pjsip show endpoints" || true
  echo
  echo "---- CONTACTS (ONLINE/OFFLINE) ----"
  asterisk -rx "pjsip show contacts" || true
  echo
  echo "---- CHANNELS (EM LIGAÇÃO) ----"
  asterisk -rx "core show channels concise" || true
}

list_condo(){
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

add_ap(){
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
  chmod 600 "$CFG" || true
}

add_morador(){
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
    print("OK: morador adicionado (senha será gerada ao aplicar).")
PY
  chmod 600 "$CFG" || true
}

rm_morador(){
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
  chmod 600 "$CFG" || true
}

apply(){
  echo "Aplicando configs + restart..."
  bash ./install.sh --apply-only
  echo "OK."
}

show_secrets(){
  echo "Senhas SIP: $SECRETS"
  [[ -f "$SECRETS" ]] && (sed -n '1,200p' "$SECRETS" | head -n 150) || echo "Ainda não gerado."
  echo
  echo "AMI/ARI: $INTEG_TXT"
  [[ -f "$INTEG_TXT" ]] && cat "$INTEG_TXT" || true
}

install_now(){
  echo "Instalando Asterisk + Core..."
  bash ./install.sh |& tee /root/interfone-install.log
  echo "Log: /root/interfone-install.log"
}

main(){
  need_root "$@"
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
    echo "6) Aplicar configs + reiniciar Asterisk"
    echo "7) Mostrar senhas/integrações (server-only)"
    echo "9) Instalar Asterisk (source) + Core"
    echo "0) Sair"
    echo
    read -r -p "Escolha: " opt
    case "$opt" in
      1) show_status; pause;;
      2) list_condo; pause;;
      3) add_ap; pause;;
      4) add_morador; pause;;
      5) rm_morador; pause;;
      6) apply; pause;;
      7) show_secrets; pause;;
      9) install_now; pause;;
      0) exit 0;;
      *) echo "Opção inválida"; pause;;
    esac
  done
}

main "$@"
