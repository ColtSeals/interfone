cat > menu.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

A_BIN=""

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo bash "$0" "$@"; }

pause(){ read -r -p "ENTER para continuar..." _; }

pick_asterisk(){
  if command -v asterisk >/dev/null 2>&1; then
    A_BIN="$(command -v asterisk)"
  elif [[ -x /usr/sbin/asterisk ]]; then
    A_BIN="/usr/sbin/asterisk"
  else
    A_BIN=""
  fi
}

require_asterisk(){
  pick_asterisk
  if [[ -z "$A_BIN" ]]; then
    echo "Asterisk NÃO está instalado."
    echo "Rode primeiro: sudo bash install.sh"
    return 1
  fi
  return 0
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

add_apartment(){
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

add_resident(){
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

remove_resident(){
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

apply_configs(){
  echo "Aplicando configs..."
  bash ./install.sh --apply-only
  echo "OK."
}

show_status(){
  require_asterisk || return
  echo "---- ENDPOINTS ----"
  "$A_BIN" -rx "pjsip show endpoints" || true
  echo
  echo "---- CONTACTS (ONLINE/OFFLINE) ----"
  "$A_BIN" -rx "pjsip show contacts" || true
  echo
  echo "---- CHANNELS (EM LIGAÇÃO) ----"
  "$A_BIN" -rx "core show channels concise" || true
}

show_secrets(){
  echo "Senhas SIP: $SECRETS"
  [[ -f "$SECRETS" ]] && (sed -n '1,200p' "$SECRETS" | head -n 120) || echo "Ainda não gerado."
  echo
  echo "AMI/ARI: $INTEG_TXT"
  [[ -f "$INTEG_TXT" ]] && cat "$INTEG_TXT" || true
}

main_menu(){
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
    echo "0) Sair"
    echo
    read -r -p "Escolha: " opt

    case "$opt" in
      1) show_status; pause ;;
      2) list_condo; pause ;;
      3) add_apartment; pause ;;
      4) add_resident; pause ;;
      5) remove_resident; pause ;;
      6) apply_configs; pause ;;
      7) show_secrets; pause ;;
      0) exit 0 ;;
      *) echo "Opção inválida"; pause ;;
    esac
  done
}

need_root "$@"
main_menu
EOF

chmod +x menu.sh
