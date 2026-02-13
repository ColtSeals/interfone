#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo bash "$0" "$@"; }
pause(){ read -r -p "ENTER para continuar..." _; }

has_asterisk(){ command -v asterisk >/dev/null 2>&1; }

show_status(){
  if ! has_asterisk; then
    echo "Asterisk NÃO está instalado. Use 9) Instalar Asterisk."
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

# ================
# Helpers de APs
# ================
list_aps_indexed(){
  python3 - <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
aps=data.get("apartamentos",[])
if not aps:
    print("(Nenhum AP cadastrado)")
    raise SystemExit(0)

for i, ap in enumerate(aps, 1):
    n=ap.get("numero","?")
    q=len(ap.get("moradores",[]))
    print(f"{i}) AP {n}  ({q} morador(es))")
PY
}

get_ap_numbers(){
  python3 - <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
aps=data.get("apartamentos",[])
print(" ".join([str(a.get("numero","")).strip() for a in aps if str(a.get("numero","")).strip()]))
PY
}

resolve_ap_choice(){
  # retorna AP number resolvido via stdout
  # aceita: "804" ou "2" (índice)
  local choice="$1"
  python3 - <<PY
import json, sys
choice=sys.argv[1].strip()
data=json.load(open("${CFG}","r",encoding="utf-8"))
aps=data.get("apartamentos",[])

if not aps:
    print("")
    sys.exit(0)

# se for índice
if choice.isdigit():
    idx=int(choice)
    if 1 <= idx <= len(aps):
        print(str(aps[idx-1].get("numero","")).strip())
        sys.exit(0)

# senão tenta por número do AP
for ap in aps:
    if str(ap.get("numero","")).strip() == choice:
        print(choice)
        sys.exit(0)

print("")
PY "$choice"
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
  echo "APs atuais:"
  list_aps_indexed
  echo
  read -r -p "Número do AP (ex: 804): " apnum
  [[ -z "${apnum// }" ]] && { echo "AP inválido"; return; }

  python3 - <<PY
import json
cfg="${CFG}"
apnum="${apnum}".strip()
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])
if any(str(a.get("numero","")).strip()==apnum for a in aps):
    print("Já existe.")
else:
    aps.append({"numero":apnum,"moradores":[]})
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: AP criado.")
PY
  chmod 600 "$CFG" || true
}

add_morador(){
  echo "Selecione o AP:"
  list_aps_indexed
  echo
  echo "Digite o NÚMERO do AP (ex: 804) ou o ÍNDICE (ex: 2)"
  read -r -p "AP: " choice

  local apnum
  apnum="$(resolve_ap_choice "${choice:-}")"
  if [[ -z "${apnum:-}" ]]; then
    echo "AP inválido ou não existe."
    return
  fi

  echo "AP escolhido: $apnum"
  read -r -p "Ramal SIP (ex: ${apnum}01): " ramal
  read -r -p "Nome (ex: AP${apnum}-01): " nome
  [[ -z "${ramal// }" ]] && { echo "Ramal inválido"; return; }
  [[ -z "${nome// }" ]] && nome="AP${apnum}-${ramal}"

  python3 - <<PY
import json
cfg="${CFG}"
apnum="${apnum}".strip()
ramal="${ramal}".strip()
nome="${nome}".strip()

data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])
ap=None
for a in aps:
    if str(a.get("numero","")).strip()==apnum:
        ap=a; break
if ap is None:
    print("AP não existe.")
    raise SystemExit(0)

mor=ap.setdefault("moradores",[])
if any(str(m.get("ramal","")).strip()==ramal for m in mor):
    print("Ramal já existe.")
else:
    mor.append({"ramal":ramal,"nome":nome,"senha":""})
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: morador adicionado (senha será gerada ao aplicar configs).")
PY
  chmod 600 "$CFG" || true
}

rm_morador(){
  read -r -p "Ramal a remover (ex: 80401): " ramal
  [[ -z "${ramal// }" ]] && { echo "Ramal inválido"; return; }

  python3 - <<PY
import json
cfg="${CFG}"
ramal="${ramal}".strip()
data=json.load(open(cfg,"r",encoding="utf-8"))
changed=False
for ap in data.get("apartamentos",[]):
    mor=ap.get("moradores",[])
    before=len(mor)
    ap["moradores"]=[m for m in mor if str(m.get("ramal","")).strip()!=ramal]
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
  [[ -f "$SECRETS" ]] && (sed -n '1,220p' "$SECRETS" | head -n 180) || echo "Ainda não gerado."
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
