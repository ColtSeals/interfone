#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# INTERFONE - SUPER MENU (SIP CORE)
#
# ✅ Dashboard rico ao abrir
# ✅ Tabela de ramais (🟢 online / 🔴 offline / 🟡 busy)
# ✅ Busca por ramal/nome/AP/bloco/prédio
# ✅ Wizard: criar AP + N moradores (com senha)
# ✅ Ao adicionar morador: ramal + senha na hora (manual ou auto)
# ✅ Apply/restart/logs/health-check
# ✅ Monitor LIVE de tentativas de LOGIN/REGISTER
#
# ✅ NOVO: Política dinâmica (quem pode falar com quem)
#   policy.mode:
#     - portaria_only
#     - apartment_only
#     - block_only
#     - building_only
#     - condo_all
#
# ✅ NOVO: Metadados por AP:
#   - bloco
#   - predio
# ==========================================

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"
INSTALL_LOG="/root/interfone-install.log"

ASTERISK_LOG="/var/log/asterisk/messages"
ASTERISK_SEC="/var/log/asterisk/security.log"

USE_COLOR="${USE_COLOR:-1}"
REFRESH_SLEEP="${REFRESH_SLEEP:-2}"

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo bash "$0" "$@"; }
pause(){ read -r -p "ENTER para continuar..." _; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- colors ----------
if [[ "$USE_COLOR" == "1" ]] && [[ -t 1 ]]; then
  B="$(tput bold || true)"; D="$(tput sgr0 || true)"
  R="$(tput setaf 1 || true)"; G="$(tput setaf 2 || true)"
  Y="$(tput setaf 3 || true)"; C="$(tput setaf 6 || true)"
  W="$(tput setaf 7 || true)"
else
  B=""; D=""; R=""; G=""; Y=""; C=""; W=""
fi

ok(){ echo -e "${G}✔${D} $*"; }
warn(){ echo -e "${Y}⚠${D} $*"; }
bad(){ echo -e "${R}✘${D} $*"; }

hr(){ printf "%s\n" "────────────────────────────────────────────────────────────────────────────"; }

title_box(){
  local line="INTERFONE • SIP CORE • PAINEL OPERACIONAL"
  printf "${B}${C}╔%s╗${D}\n" "$(printf '═%.0s' {1..76})"
  printf "${B}${C}║ %-76s ║${D}\n" "$line"
  printf "${B}${C}╚%s╝${D}\n" "$(printf '═%.0s' {1..76})"
}

asterisk_installed(){ have asterisk; }
asterisk_service_exists(){ systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "asterisk.service"; }
asterisk_active(){ systemctl is-active --quiet asterisk 2>/dev/null; }
asterisk_enabled(){ systemctl is-enabled --quiet asterisk 2>/dev/null; }

ufw_active(){ have ufw && ufw status 2>/dev/null | head -n1 | grep -qi "Status: active"; }
ufw_has_rule(){ local rule="$1"; have ufw || return 1; ufw status 2>/dev/null | grep -Fqi "$rule"; }

get_public_ip(){
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
  [[ -z "${ip:-}" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-N/A}"
}

ensure_cfg_exists(){
  if [[ ! -f "$CFG" ]]; then
    install -d "$APP_DIR"; chmod 700 "$APP_DIR"
    cat > "$CFG" <<'JSON'
{
  "policy": { "mode": "condo_all" },
  "portaria": { "ramal": "1000", "nome": "PORTARIA", "senha": "" },
  "apartamentos": [
    {
      "numero": "101",
      "bloco": "A",
      "predio": "1",
      "moradores": [
        { "ramal": "10101", "nome": "AP101-01", "senha": "" },
        { "ramal": "10102", "nome": "AP101-02", "senha": "" }
      ]
    }
  ]
}
JSON
    chmod 600 "$CFG"
  fi
}

safe_json_exists(){
  [[ -f "$CFG" ]] || return 1
  have python3 || return 1
  python3 - <<PY >/dev/null 2>&1
import json
json.load(open("${CFG}","r",encoding="utf-8"))
PY
}

ast_rx(){ asterisk -rx "$1" 2>/dev/null || true; }

# ---------- parsing robusto ----------
parse_objects_found(){ grep -oE 'Objects found: *[0-9]+' | tail -n1 | grep -oE '[0-9]+' || echo "0"; }

ast_endpoints_count(){ ast_rx "pjsip show endpoints" | tr -d '\r' | parse_objects_found; }

ast_contacts_online_count(){
  local out
  out="$(ast_rx "pjsip show contacts" | tr -d '\r')"
  if echo "$out" | grep -qi "No objects found"; then echo "0"; else echo "$out" | parse_objects_found; fi
}

ast_calls_summary(){
  local out calls ch
  out="$(ast_rx "core show channels count" | tr -d '\r')"
  ch="$(echo "$out" | awk '/active channels/{print $1}' | head -n1 | grep -E '^[0-9]+$' || echo "0")"
  calls="$(echo "$out" | awk '/active call/{print $1}' | head -n1 | grep -E '^[0-9]+$' || echo "0")"
  echo "$calls $ch"
}

ast_online_ramals(){
  ast_rx "pjsip show contacts" | awk '
    /^ *Contact:/{ x=$2; split(x,a,"/"); x=a[1]; sub(/-.*$/,"",x); gsub(/[^0-9]/,"",x); if(x!="") print x }
  ' | sort -u
}

ast_busy_ramals(){
  ast_rx "core show channels concise" | awk -F'!' '
    { c=$1; if (c ~ /^PJSIP\//) { sub(/^PJSIP\//,"",c); sub(/-.*/,"",c); gsub(/[^0-9]/,"",c); if(c!="") print c } }
  ' | sort -u
}

py(){ python3 - "$@"; }

# ---------- password ----------
validate_pass(){
  local p="$1"
  [[ ${#p} -ge 6 && ${#p} -le 64 ]] || return 1
  [[ "$p" =~ ^[A-Za-z0-9._@:+#=-]+$ ]] || return 1
  return 0
}

gen_password(){
  python3 - <<'PY'
import secrets,string
a=string.ascii_letters+string.digits+"._@:+#=-"
print(''.join(secrets.choice(a) for _ in range(20)))
PY
}

# =========================================================
# POLICY (NOVO)
# =========================================================

policy_label(){
  local m="$1"
  case "$m" in
    portaria_only)  echo "Somente Portaria (moradores não falam entre si)" ;;
    apartment_only) echo "Somente no AP (morador↔morador no mesmo AP) + Portaria" ;;
    block_only)     echo "Somente no Bloco (mesmo bloco) + Portaria" ;;
    building_only)  echo "Somente no Prédio (mesmo prédio) + Portaria" ;;
    condo_all)      echo "Livre (todo condomínio) + Portaria" ;;
    *)              echo "Desconhecido ($m)" ;;
  esac
}

get_policy_mode(){
  ensure_cfg_exists
  py <<PY
import json
d=json.load(open("${CFG}","r",encoding="utf-8"))
m=str(d.get("policy",{}).get("mode","condo_all")).strip().lower() or "condo_all"
print(m)
PY
}

set_policy_mode(){
  ensure_cfg_exists
  local cur newm
  cur="$(get_policy_mode)"
  echo "${B}POLÍTICA ATUAL:${D} $cur — $(policy_label "$cur")"
  echo
  echo "Escolha a nova política:"
  echo "1) portaria_only   — Somente Portaria"
  echo "2) apartment_only  — Somente dentro do AP"
  echo "3) block_only      — Somente dentro do Bloco"
  echo "4) building_only   — Somente dentro do Prédio"
  echo "5) condo_all       — Livre (condomínio todo)"
  echo
  read -r -p "Opção [1-5] (ENTER = cancelar): " opt
  [[ -z "${opt:-}" ]] && { warn "Cancelado."; return; }

  case "$opt" in
    1) newm="portaria_only" ;;
    2) newm="apartment_only" ;;
    3) newm="block_only" ;;
    4) newm="building_only" ;;
    5) newm="condo_all" ;;
    *) bad "Opção inválida."; return ;;
  esac

  py "$newm" <<PY
import json, sys
newm=sys.argv[1].strip().lower()
allowed={"portaria_only","apartment_only","block_only","building_only","condo_all"}
if newm not in allowed:
  raise SystemExit("modo inválido")
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
pol=d.setdefault("policy",{})
pol["mode"]=newm
json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: policy.mode =", newm)
PY
  chmod 600 "$CFG" || true

  read -r -p "Aplicar agora (APPLY)? [S/n] " yn
  yn="${yn:-S}"
  if [[ "${yn,,}" == "s" ]]; then apply_configs; else warn "Ok. Faça APPLY depois."; fi
}

# =========================================================
# JSON ops
# =========================================================

list_aps_indexed(){
  ensure_cfg_exists
  py <<PY
import json
d=json.load(open("${CFG}","r",encoding="utf-8"))
aps=d.get("apartamentos",[])
if not aps:
  print("(Nenhum AP cadastrado)")
  raise SystemExit(0)
for i, ap in enumerate(aps, 1):
  n=str(ap.get("numero","?")).strip()
  nome=str(ap.get("nome","")).strip()
  bloco=str(ap.get("bloco","A")).strip() or "A"
  predio=str(ap.get("predio","1")).strip() or "1"
  q=len(ap.get("moradores",[]))
  label=f"AP {n}"
  if nome: label+=f" - {nome}"
  print(f"{i}) {label}  [bloco:{bloco}  prédio:{predio}]  ({q} morador(es))")
PY
}

resolve_ap_choice(){
  local choice="${1:-}"
  py "$choice" <<PY
import json, sys
choice=sys.argv[1].strip()
d=json.load(open("${CFG}","r",encoding="utf-8"))
aps=d.get("apartamentos",[])
if not aps:
  print(""); raise SystemExit(0)
if choice.isdigit():
  idx=int(choice)
  if 1 <= idx <= len(aps):
    print(str(aps[idx-1].get("numero","")).strip()); raise SystemExit(0)
for ap in aps:
  if str(ap.get("numero","")).strip() == choice:
    print(choice); raise SystemExit(0)
print("")
PY
}

list_condo(){
  ensure_cfg_exists
  py <<PY
import json
d=json.load(open("${CFG}","r",encoding="utf-8"))
mode=str(d.get("policy",{}).get("mode","condo_all")).strip()
print("POLICY:", mode)
print("")
p=d.get("portaria",{})
print("PORTARIA:", p.get("ramal","1000"), "-", p.get("nome","PORTARIA"))
print("")
for ap in d.get("apartamentos",[]):
  apn=str(ap.get("numero","?")).strip()
  apnome=str(ap.get("nome","")).strip()
  bloco=str(ap.get("bloco","A")).strip() or "A"
  predio=str(ap.get("predio","1")).strip() or "1"
  head=f"AP {apn} [bloco:{bloco} prédio:{predio}]"
  if apnome: head += f" - {apnome}"
  print(head)
  for m in ap.get("moradores",[]):
    pw = "SET" if str(m.get("senha","")).strip() else "AUTO"
    print("  -", m.get("ramal","?"), "|", m.get("nome",""), f"| senha:{pw}")
PY
}

add_ap(){
  ensure_cfg_exists
  echo "APs atuais:"
  list_aps_indexed
  echo

  read -r -p "Número do AP (ex: 804): " apnum
  [[ -z "${apnum// }" ]] && { bad "AP inválido"; return; }
  read -r -p "Nome do AP (opcional): " apname
  read -r -p "Bloco (opcional, padrão=A): " bloco
  read -r -p "Prédio (opcional, padrão=1): " predio
  bloco="${bloco:-A}"
  predio="${predio:-1}"

  py "$apnum" "$apname" "$bloco" "$predio" <<PY
import json, sys, re
apnum=sys.argv[1].strip()
apname=sys.argv[2].strip()
bloco=sys.argv[3].strip() or "A"
predio=sys.argv[4].strip() or "1"
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
aps=d.setdefault("apartamentos",[])
if any(str(a.get("numero","")).strip()==apnum for a in aps):
  print("Já existe.")
else:
  obj={"numero":apnum,"moradores":[], "bloco": bloco, "predio": predio}
  if apname: obj["nome"]=apname
  aps.append(obj)
  json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
  print("OK: AP criado com bloco/prédio.")
PY
  chmod 600 "$CFG" || true
}

edit_ap_meta(){
  ensure_cfg_exists
  echo "Selecione o AP para editar bloco/prédio:"
  list_aps_indexed
  echo
  read -r -p "AP (número ou índice): " choice
  local apnum
  apnum="$(resolve_ap_choice "${choice:-}")"
  [[ -n "${apnum:-}" ]] || { bad "AP inválido."; return; }

  local cur
  cur="$(py "$apnum" <<PY
import json, sys
apnum=sys.argv[1].strip()
d=json.load(open("${CFG}","r",encoding="utf-8"))
for ap in d.get("apartamentos",[]):
  if str(ap.get("numero","")).strip()==apnum:
    b=str(ap.get("bloco","A")).strip() or "A"
    p=str(ap.get("predio","1")).strip() or "1"
    print(b, p)
    raise SystemExit(0)
print("A 1")
PY
)"
  local cur_bloco cur_predio
  cur_bloco="$(echo "$cur" | awk '{print $1}')"
  cur_predio="$(echo "$cur" | awk '{print $2}')"

  echo "AP escolhido: $apnum"
  echo "Atual: bloco=${B}${cur_bloco}${D}  prédio=${B}${cur_predio}${D}"
  read -r -p "Novo bloco (ENTER = manter): " nb
  read -r -p "Novo prédio (ENTER = manter): " np
  nb="${nb:-$cur_bloco}"
  np="${np:-$cur_predio}"

  py "$apnum" "$nb" "$np" <<PY
import json, sys
apnum=sys.argv[1].strip()
nb=sys.argv[2].strip() or "A"
np=sys.argv[3].strip() or "1"
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
for ap in d.get("apartamentos",[]):
  if str(ap.get("numero","")).strip()==apnum:
    ap["bloco"]=nb
    ap["predio"]=np
    json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: atualizado bloco/prédio do AP.")
    raise SystemExit(0)
print("AP não encontrado.")
PY
  chmod 600 "$CFG" || true

  read -r -p "Aplicar agora (APPLY)? [S/n] " yn
  yn="${yn:-S}"
  [[ "${yn,,}" == "s" ]] && apply_configs || warn "Ok. Faça APPLY depois."
}

suggest_next_ramal(){
  local apnum="$1"
  py "$apnum" <<PY
import json, sys
apnum=sys.argv[1].strip()
d=json.load(open("${CFG}","r",encoding="utf-8"))
aps=d.get("apartamentos",[])
ap=None
for a in aps:
  if str(a.get("numero","")).strip()==apnum:
    ap=a; break
if not ap:
  print(""); raise SystemExit(0)
used=set()
for m in ap.get("moradores",[]):
  r=str(m.get("ramal","")).strip()
  if r: used.add(r)
for i in range(1,100):
  cand=f"{apnum}{i:02d}"
  if cand not in used:
    print(cand); raise SystemExit(0)
print(f"{apnum}99")
PY
}

add_morador(){
  ensure_cfg_exists
  echo "Selecione o AP:"
  list_aps_indexed
  echo
  echo "Digite o NÚMERO do AP (ex: 804) ou o ÍNDICE (ex: 2)"
  read -r -p "AP: " choice

  local apnum
  apnum="$(resolve_ap_choice "${choice:-}")"
  [[ -n "${apnum:-}" ]] || { bad "AP inválido ou não existe."; return; }

  local suggested
  suggested="$(suggest_next_ramal "$apnum")"
  [[ -n "${suggested:-}" ]] || { bad "Falha ao sugerir ramal."; return; }

  echo "AP escolhido: $apnum"
  echo "Sugestão de ramal: ${B}${suggested}${D}"
  read -r -p "Ramal SIP (ENTER = usar sugestão): " ramal
  ramal="${ramal:-$suggested}"
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  read -r -p "Nome do morador (ex: João / Maria) (ENTER = padrão): " nome
  [[ -z "${nome// }" ]] && nome="AP${apnum}-${ramal}"

  echo "Senha (6-64 chars; permitido: A-Z a-z 0-9 . _ - @ : + = #)"
  echo "ENTER = gerar automaticamente e salvar no cadastro"
  local pass1 pass2
  read -r -s -p "Senha: " pass1; echo
  if [[ -z "${pass1:-}" ]]; then
    pass1="$(gen_password)"
    ok "Senha auto-gerada (não será mostrada aqui)."
  else
    read -r -s -p "Confirmar: " pass2; echo
    [[ "$pass1" == "$pass2" ]] || { bad "Confirmação não bate."; return; }
    validate_pass "$pass1" || { bad "Senha inválida (tamanho/caracteres)."; return; }
  fi

  py "$apnum" "$ramal" "$nome" "$pass1" <<PY
import json, sys, re
apnum=sys.argv[1].strip()
ramal=sys.argv[2].strip()
nome=sys.argv[3].strip()
senha=sys.argv[4]
cfg="${CFG}"

def clean_ext(x):
  x=str(x).strip()
  if not re.fullmatch(r"\d{2,10}", x):
    raise SystemExit("Ramal inválido (somente dígitos, 2..10).")
  return x

ramal=clean_ext(ramal)

d=json.load(open(cfg,"r",encoding="utf-8"))
aps=d.setdefault("apartamentos",[])
ap=None
for a in aps:
  if str(a.get("numero","")).strip()==apnum:
    ap=a; break
if ap is None:
  print("AP não existe."); raise SystemExit(0)

port=str(d.get("portaria",{}).get("ramal","1000")).strip()
if ramal==port:
  print("Ramal conflita com PORTARIA."); raise SystemExit(0)

for a in aps:
  for m in a.get("moradores",[]):
    if str(m.get("ramal","")).strip()==ramal:
      print("Ramal já existe em outro AP."); raise SystemExit(0)

mor=ap.setdefault("moradores",[])
mor.append({"ramal":ramal,"nome":nome,"senha":senha})
json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: morador criado com senha definida. Rode APPLY para entrar em produção.")
PY
  chmod 600 "$CFG" || true

  read -r -p "Aplicar agora (gerar configs + reiniciar Asterisk)? [S/n] " yn
  yn="${yn:-S}"
  if [[ "${yn,,}" == "s" ]]; then apply_configs
  else warn "Ok. Lembre: opção APPLY (no menu) para efetivar no Asterisk."
  fi
}

rm_morador(){
  ensure_cfg_exists
  read -r -p "Ramal a remover (ex: 80401): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  py "$ramal" <<PY
import json, sys
ramal=sys.argv[1].strip()
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
changed=False
for ap in d.get("apartamentos",[]):
  mor=ap.get("moradores",[])
  before=len(mor)
  ap["moradores"]=[m for m in mor if str(m.get("ramal","")).strip()!=ramal]
  if len(ap["moradores"])!=before:
    changed=True
if changed:
  json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
  print("OK: removido.")
else:
  print("Não achei esse ramal.")
PY
  chmod 600 "$CFG" || true
}

edit_portaria_name(){
  ensure_cfg_exists
  read -r -p "Novo nome da PORTARIA: " newname
  [[ -z "${newname// }" ]] && { bad "Nome inválido"; return; }

  py "$newname" <<PY
import json, sys
newname=sys.argv[1].strip()
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
p=d.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":""})
p["nome"]=newname
json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: nome da portaria atualizado.")
PY
  chmod 600 "$CFG" || true
}

edit_ap_name(){
  ensure_cfg_exists
  echo "Selecione o AP para renomear:"
  list_aps_indexed
  echo
  read -r -p "AP (número ou índice): " choice
  local apnum
  apnum="$(resolve_ap_choice "${choice:-}")"
  [[ -n "${apnum:-}" ]] || { bad "AP inválido."; return; }

  read -r -p "Novo nome do AP $apnum (vazio para remover nome): " newname

  py "$apnum" "$newname" <<PY
import json, sys
apnum=sys.argv[1].strip()
newname=sys.argv[2].strip()
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
for ap in d.get("apartamentos",[]):
  if str(ap.get("numero","")).strip()==apnum:
    if newname: ap["nome"]=newname
    else: ap.pop("nome", None)
    json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: AP renomeado.")
    raise SystemExit(0)
print("AP não encontrado.")
PY
  chmod 600 "$CFG" || true
}

edit_morador_name(){
  ensure_cfg_exists
  read -r -p "Ramal do morador (ex: 80401): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }
  read -r -p "Novo nome desse morador: " newname
  [[ -z "${newname// }" ]] && { bad "Nome inválido"; return; }

  py "$ramal" "$newname" <<PY
import json, sys
ramal=sys.argv[1].strip()
newname=sys.argv[2].strip()
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
for ap in d.get("apartamentos",[]):
  for m in ap.get("moradores",[]):
    if str(m.get("ramal","")).strip()==ramal:
      m["nome"]=newname
      json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
      print("OK: morador renomeado.")
      raise SystemExit(0)
print("Ramal não encontrado.")
PY
  chmod 600 "$CFG" || true
}

set_password(){
  ensure_cfg_exists
  read -r -p "Ramal (1000 portaria ou morador ex: 10101): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  echo "Senha (6-64 chars; permitido: A-Z a-z 0-9 . _ - @ : + = #)"
  local p1 p2
  read -r -s -p "Nova senha: " p1; echo
  read -r -s -p "Confirmar: " p2; echo
  [[ "$p1" == "$p2" ]] || { bad "Confirmação não bate."; return; }
  validate_pass "$p1" || { bad "Senha inválida (tamanho ou caracteres)."; return; }

  py "$ramal" "$p1" <<PY
import json, sys
ramal=sys.argv[1].strip()
senha=sys.argv[2]
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))

p=d.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
  p["senha"]=senha
  d["portaria"]=p
  json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
  print("OK: senha da PORTARIA definida. Rode APPLY.")
  raise SystemExit(0)

for ap in d.get("apartamentos",[]):
  for m in ap.get("moradores",[]):
    if str(m.get("ramal","")).strip()==ramal:
      m["senha"]=senha
      json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
      print("OK: senha do morador definida. Rode APPLY.")
      raise SystemExit(0)

print("Ramal não encontrado.")
PY
  chmod 600 "$CFG" || true
}

reset_senha(){
  ensure_cfg_exists
  read -r -p "Ramal para RESETAR senha (ex: 10101 ou 1000): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  py "$ramal" <<PY
import json, sys
ramal=sys.argv[1].strip()
cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))

p=d.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
  p["senha"]=""
  d["portaria"]=p
  json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
  print("OK: senha da portaria será regenerada no APPLY.")
  raise SystemExit(0)

for ap in d.get("apartamentos",[]):
  for m in ap.get("moradores",[]):
    if str(m.get("ramal","")).strip()==ramal:
      m["senha"]=""
      json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
      print("OK: senha do morador será regenerada no APPLY.")
      raise SystemExit(0)

print("Ramal não encontrado.")
PY
  chmod 600 "$CFG" || true
}

export_safe(){
  ensure_cfg_exists
  local out="/root/interfone-export.json"
  py "$out" <<PY
import json, sys
out=sys.argv[1]
d=json.load(open("${CFG}","r",encoding="utf-8"))

def strip_pw(obj):
  if isinstance(obj, dict):
    obj=dict(obj)
    obj.pop("senha", None)
    for k,v in list(obj.items()):
      obj[k]=strip_pw(v)
    return obj
  if isinstance(obj, list):
    return [strip_pw(x) for x in obj]
  return obj

clean=strip_pw(d)
json.dump(clean, open(out,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK:", out)
PY
  chmod 600 "/root/interfone-export.json" || true
}

# ---------- operational actions ----------
apply_configs(){
  [[ -x ./install.sh ]] || { bad "install.sh não encontrado no diretório atual."; return; }
  ok "Aplicando configs + reiniciando Asterisk..."
  bash ./install.sh --apply-only
  ok "APPLY concluído."
}

restart_asterisk(){
  asterisk_service_exists || { bad "asterisk.service não existe."; return; }
  systemctl restart asterisk
  asterisk_active && ok "Asterisk reiniciado e ATIVO." || bad "Asterisk não subiu."
}

service_status(){
  asterisk_service_exists || { bad "asterisk.service não existe."; return; }
  systemctl status asterisk --no-pager -l || true
}

tail_logs(){
  echo "${B}LOG PRINCIPAL:${D} $ASTERISK_LOG"
  [[ -f "$ASTERISK_LOG" ]] && tail -n 200 "$ASTERISK_LOG" || warn "Não achei $ASTERISK_LOG"
  echo
  echo "${B}LOG SEGURANÇA (LOGIN/REGISTER):${D} $ASTERISK_SEC"
  [[ -f "$ASTERISK_SEC" ]] && tail -n 200 "$ASTERISK_SEC" || warn "Não achei $ASTERISK_SEC"
}

monitor_logins_live(){
  echo
  echo "${B}${C}MONITOR LIVE - TENTATIVAS DE LOGIN/REGISTER${D}"
  echo "Arquivos:"
  echo "  - $ASTERISK_SEC  (auth failures / scanners / REGISTER issues)"
  echo "  - $ASTERISK_LOG  (geral)"
  echo
  echo "${Y}Dica:${D} tente logar no Linphone/Zoiper agora e observe as linhas."
  echo "${Y}Ctrl+C${D} para sair."
  echo
  if [[ -f "$ASTERISK_SEC" ]]; then
    tail -n 0 -F "$ASTERISK_SEC" | sed -u 's/^/[SEC] /'
  else
    warn "security.log não existe ainda. Rode APPLY/restart para o logger gerar."
    pause
  fi
}

pjsip_logger_toggle(){
  asterisk_active || { bad "Asterisk não está ativo."; return; }
  echo "1) ON  (pjsip set logger on)  [mostra pacotes SIP no console/CLI]"
  echo "2) OFF (pjsip set logger off)"
  read -r -p "Escolha: " o
  case "$o" in
    1) ast_rx "pjsip set logger on"; ok "PJSIP logger ON.";;
    2) ast_rx "pjsip set logger off"; ok "PJSIP logger OFF.";;
    *) warn "Opção inválida";;
  esac
}

firewall_helper(){
  have ufw || { warn "ufw não instalado."; return; }
  echo "Status atual:"
  ufw status || true
  echo
  echo "Ações:"
  echo "1) Liberar SIP (5060/udp + 5060/tcp) + RTP (10000-20000/udp) + SSH e ativar"
  echo "2) Desativar UFW"
  echo "3) Mostrar regras"
  read -r -p "Escolha: " o
  case "$o" in
    1) ufw allow OpenSSH || true
       ufw allow 5060/udp || true
       ufw allow 5060/tcp || true
       ufw allow 10000:20000/udp || true
       ufw --force enable || true
       ok "UFW configurado." ;;
    2) ufw --force disable || true
       warn "UFW desativado." ;;
    3) ufw status verbose || true ;;
    *) warn "Opção inválida";;
  esac
}

explain_integrations(){
  echo "${B}AMI${D} (127.0.0.1:5038) = canal TCP de eventos/comandos (status online/busy etc)."
  echo "${B}ARI${D} (http://127.0.0.1:8088/ari/) = API REST do Asterisk (controle/consulta)."
  echo
  echo "Teste ARI (na VPS):"
  echo "  curl -u ari:SENHA http://127.0.0.1:8088/ari/asterisk/info"
  echo
  warn "Manter localhost-only é o mais seguro. Se precisar acesso externo depois: túnel SSH."
}

panel_ramais(){
  ensure_cfg_exists

  local online_list busy_list
  if asterisk_active; then
    online_list="$(ast_online_ramals || true)"
    busy_list="$(ast_busy_ramals || true)"
  else
    online_list=""; busy_list=""
  fi

  python3 - <<PY
import json
d=json.load(open("${CFG}","r",encoding="utf-8"))
mode=str(d.get("policy",{}).get("mode","condo_all")).strip().lower() or "condo_all"

online=set([x.strip() for x in """${online_list}""".splitlines() if x.strip()])
busy=set([x.strip() for x in """${busy_list}""".splitlines() if x.strip()])

rows=[]
p=d.get("portaria",{})
pr=str(p.get("ramal","1000")).strip()
pn=str(p.get("nome","PORTARIA")).strip()
rows.append(("PORTARIA","—","—","—",pr,pn))

for ap in d.get("apartamentos",[]):
  apn=str(ap.get("numero","")).strip()
  apnome=str(ap.get("nome","")).strip()
  bloco=str(ap.get("bloco","A")).strip() or "A"
  predio=str(ap.get("predio","1")).strip() or "1"
  apLabel=apn + (f" ({apnome})" if apnome else "")
  for m in ap.get("moradores",[]):
    r=str(m.get("ramal","")).strip()
    nm=str(m.get("nome","")).strip()
    rows.append(("MORADOR",apLabel,bloco,predio,r,nm))

def st_icon(r):
  if r in busy: return "🟡 BUSY"
  if r in online: return "🟢 ONLINE"
  return "🔴 OFFLINE"

print("")
print(("TABELA DE RAMAIS  |  POLICY: " + mode).center(76))
print("-"*76)
print(f"{'STATUS':<12} {'TIPO':<9} {'AP':<18} {'BLOCO':<6} {'PRÉD':<5} {'RAMAL':<8} {'NOME'}")
print("-"*76)
for typ, ap, bl, prd, r, nm in rows:
  status=st_icon(r)
  print(f"{status:<12} {typ:<9} {ap:<18} {bl:<6} {prd:<5} {r:<8} {nm}")
print("-"*76)
PY
}

buscar(){
  ensure_cfg_exists
  read -r -p "Buscar (ramal/nome/ap/bloco/prédio): " q
  [[ -z "${q// }" ]] && { warn "Busca vazia."; return; }

  local online_list busy_list
  if asterisk_active; then
    online_list="$(ast_online_ramals || true)"
    busy_list="$(ast_busy_ramals || true)"
  else
    online_list=""; busy_list=""
  fi

  python3 - <<PY
import json
q="${q}".strip().lower()
d=json.load(open("${CFG}","r",encoding="utf-8"))
mode=str(d.get("policy",{}).get("mode","condo_all")).strip().lower() or "condo_all"

online=set([x.strip() for x in """${online_list}""".splitlines() if x.strip()])
busy=set([x.strip() for x in """${busy_list}""".splitlines() if x.strip()])

def st(r):
  if r in busy: return "🟡 BUSY"
  if r in online: return "🟢 ONLINE"
  return "🔴 OFFLINE"

hits=[]
p=d.get("portaria",{})
pr=str(p.get("ramal","1000")).strip()
pn=str(p.get("nome","PORTARIA")).strip()
blob=f"portaria {pr} {pn}".lower()
if q in blob:
  hits.append((st(pr),"PORTARIA","—","—","—",pr,pn))

for ap in d.get("apartamentos",[]):
  apn=str(ap.get("numero","")).strip()
  apnome=str(ap.get("nome","")).strip()
  bloco=str(ap.get("bloco","A")).strip() or "A"
  predio=str(ap.get("predio","1")).strip() or "1"
  apLabel=apn + (f" ({apnome})" if apnome else "")
  apBlob=(f"{apn} {apnome} {apLabel} bloco {bloco} predio {predio} prédio {predio}").lower()
  for m in ap.get("moradores",[]):
    r=str(m.get("ramal","")).strip()
    nm=str(m.get("nome","")).strip()
    blob=f"{apBlob} {r} {nm}".lower()
    if q in blob:
      hits.append((st(r),"MORADOR",apLabel,bloco,predio,r,nm))

print("")
print((f"RESULTADOS PARA: {q}  |  POLICY: {mode}").center(76))
print("-"*76)
if not hits:
  print("Nenhum resultado.")
else:
  print(f"{'STATUS':<12} {'TIPO':<9} {'AP':<18} {'BLOCO':<6} {'PRÉD':<5} {'RAMAL':<8} {'NOME'}")
  print("-"*76)
  for s,t,ap,bl,prd,r,nm in hits:
    print(f"{s:<12} {t:<9} {ap:<18} {bl:<6} {prd:<5} {r:<8} {nm}")
  print("-"*76)
PY
}

wizard_ap(){
  ensure_cfg_exists
  echo "WIZARD - Criar AP + N moradores"
  read -r -p "Número do AP (ex: 804): " apnum
  [[ -z "${apnum// }" ]] && { bad "AP inválido"; return; }
  read -r -p "Nome do AP (opcional): " apname
  read -r -p "Bloco (opcional, padrão=A): " bloco
  read -r -p "Prédio (opcional, padrão=1): " predio
  bloco="${bloco:-A}"
  predio="${predio:-1}"

  read -r -p "Quantos moradores criar? (ex: 2): " n
  [[ "$n" =~ ^[0-9]+$ ]] || { bad "Número inválido."; return; }
  (( n >= 1 && n <= 20 )) || { bad "Use 1..20"; return; }

  echo "Senha padrão para todos? (ENTER = gerar uma diferente pra cada)"
  local p1 p2
  read -r -s -p "Senha padrão: " p1; echo
  if [[ -n "${p1:-}" ]]; then
    read -r -s -p "Confirmar: " p2; echo
    [[ "$p1" == "$p2" ]] || { bad "Confirmação não bate."; return; }
    validate_pass "$p1" || { bad "Senha inválida."; return; }
  fi

  py "$apnum" "$apname" "$bloco" "$predio" "$n" "$p1" <<PY
import json, sys, secrets, string
apnum=sys.argv[1].strip()
apname=sys.argv[2].strip()
bloco=sys.argv[3].strip() or "A"
predio=sys.argv[4].strip() or "1"
n=int(sys.argv[5].strip())
shared=sys.argv[6] if len(sys.argv)>6 else ""

def gen():
  a=string.ascii_letters+string.digits+"._@:+#=-"
  return ''.join(secrets.choice(a) for _ in range(20))

cfg="${CFG}"
d=json.load(open(cfg,"r",encoding="utf-8"))
aps=d.setdefault("apartamentos",[])

if any(str(a.get("numero","")).strip()==apnum for a in aps):
  print("AP já existe."); raise SystemExit(0)

ap={"numero":apnum,"moradores":[], "bloco": bloco, "predio": predio}
if apname: ap["nome"]=apname

port=str(d.get("portaria",{}).get("ramal","1000")).strip()
used=set([port])
for a in aps:
  for m in a.get("moradores",[]):
    r=str(m.get("ramal","")).strip()
    if r: used.add(r)

for i in range(1,n+1):
  ramal=f"{apnum}{i:02d}"
  if ramal in used:
    print("Conflito de ramal:", ramal); raise SystemExit(0)
  senha=shared if shared else gen()
  ap["moradores"].append({"ramal":ramal,"nome":f"AP{apnum}-{i:02d}","senha":senha})

aps.append(ap)
json.dump(d, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: AP criado com moradores + senhas definidas. Rode APPLY.")
PY

  chmod 600 "$CFG" || true
  read -r -p "Aplicar agora (APPLY)? [S/n] " yn
  yn="${yn:-S}"
  [[ "${yn,,}" == "s" ]] && apply_configs || warn "Ok. Faça APPLY depois."
}

health_check(){
  echo
  echo "HEALTH CHECK (SIP CORE)"
  hr

  if asterisk_installed; then ok "Asterisk instalado: $(command -v asterisk)"; else bad "Asterisk NÃO instalado"; fi
  if asterisk_service_exists; then ok "Service existe: asterisk.service"; else warn "Service não encontrado"; fi
  if asterisk_active; then ok "Service ATIVO"; else warn "Service OFF"; fi

  if have ss; then
    ss -lunp 2>/dev/null | grep -qE '(:5060)\s' && ok "UDP 5060 escutando (SIP)" || warn "UDP 5060 NÃO parece escutar"
    ss -lntp 2>/dev/null | grep -qE '(:5060)\s' && ok "TCP 5060 escutando (SIP)" || warn "TCP 5060 NÃO parece escutar"
  else
    warn "ss não encontrado (iproute2)."
  fi

  if have ufw; then
    ufw_active && ok "UFW ativo" || warn "UFW off"
    ufw_has_rule "5060/udp" && ok "Regra 5060/udp OK" || warn "Regra 5060/udp ausente"
    ufw_has_rule "5060/tcp" && ok "Regra 5060/tcp OK" || warn "Regra 5060/tcp ausente"
    ufw_has_rule "10000:20000/udp" && ok "Regra RTP 10000:20000 OK" || warn "Regra RTP ausente"
  else
    warn "ufw não instalado."
  fi

  [[ -f "$CFG" ]] && ok "CFG: $CFG" || bad "CFG ausente: $CFG"
  [[ -f "/etc/asterisk/pjsip.conf" ]] && ok "pjsip.conf existe" || warn "pjsip.conf ausente (rode APPLY)"
  [[ -f "/etc/asterisk/extensions.conf" ]] && ok "extensions.conf existe" || warn "extensions.conf ausente (rode APPLY)"
  [[ -f "$ASTERISK_SEC" ]] && ok "security.log existe (login/register)" || warn "security.log não existe ainda"

  local mode
  mode="$(get_policy_mode)"
  ok "Policy.mode: $mode — $(policy_label "$mode")"

  if asterisk_active; then
    local ep on calls chans
    ep="$(ast_endpoints_count)"
    on="$(ast_contacts_online_count)"
    read -r calls chans <<<"$(ast_calls_summary)"
    echo "Resumo Asterisk: endpoints=$ep | online=$on | calls=$calls | channels=$chans"
  else
    warn "Sem contagem (Asterisk off)."
  fi

  hr
}

dashboard(){
  ensure_cfg_exists

  local ip srv_inst srv_act srv_en ufw on5060u on5060t onrtp
  ip="$(get_public_ip)"

  srv_inst="$(asterisk_installed && echo "INSTALADO" || echo "NÃO")"
  srv_act="$(asterisk_active && echo "ATIVO" || echo "OFF")"
  srv_en="$(asterisk_enabled && echo "ENABLED" || echo "DISABLED")"

  ufw="$(ufw_active && echo "ON" || echo "OFF")"
  on5060u="$(ufw_has_rule "5060/udp" && echo "OK" || echo "X")"
  on5060t="$(ufw_has_rule "5060/tcp" && echo "OK" || echo "X")"
  onrtp="$(ufw_has_rule "10000:20000/udp" && echo "OK" || echo "X")"

  local endpoints="—" online="—" calls="—" chans="—"
  if asterisk_active; then
    endpoints="$(ast_endpoints_count)"
    online="$(ast_contacts_online_count)"
    read -r calls chans <<<"$(ast_calls_summary)"
  fi

  local secrets_state
  secrets_state="$([[ -f "$SECRETS" ]] && echo "GERADO" || echo "NÃO")"

  local mode label
  mode="$(get_policy_mode)"
  label="$(policy_label "$mode")"

  clear
  title_box
  printf "${B}${W}IP:${D} %s\n" "$ip"
  echo "[ASTERISK: $srv_inst]  [SERVIÇO: $srv_act]  [BOOT: $srv_en]  [UFW: $ufw]  [PORTAS: 5060/udp:$on5060u 5060/tcp:$on5060t RTP:$onrtp]  [SECRETS: $secrets_state]"
  hr
  printf "${B}${C}Policy:${D} %s  —  %s\n" "${B}${mode}${D}" "$label"
  printf "${B}${C}Resumo:${D} Endpoints=%s  Online=%s  Calls=%s  Channels=%s\n" \
    "${B}${endpoints}${D}" "${B}${online}${D}" "${B}${calls}${D}" "${B}${chans}${D}"

  hr
  echo "${B}${W}Atalhos rápidos:${D} [R]efresh  [P]ainel  [B]uscar  [H]ealth  [M]odoPolicy  [L]oginsLive  [Q]uit"
  echo
}

monitor_mode(){
  asterisk_active || { bad "Asterisk não está ativo."; return; }
  while true; do
    dashboard
    echo "${B}${Y}MONITOR MODE${D} — atualizando a cada ${REFRESH_SLEEP}s (Ctrl+C para sair)"
    echo
    echo "${B}${C}Contacts (online/offline):${D}"
    ast_rx "pjsip show contacts" | sed -n '1,120p'
    echo
    echo "${B}${C}Channels (em ligação):${D}"
    ast_rx "core show channels concise" | sed -n '1,40p'
    sleep "$REFRESH_SLEEP"
  done
}

install_now(){
  [[ -x ./install.sh ]] || { bad "install.sh não encontrado no diretório atual."; return; }
  ok "Instalando/atualizando Asterisk + Core..."
  bash ./install.sh |& tee "$INSTALL_LOG"
  echo "Log: $INSTALL_LOG"
}

policy_panel(){
  ensure_cfg_exists
  local mode
  mode="$(get_policy_mode)"
  echo
  echo "${B}${C}PAINEL • POLICY${D}"
  hr
  echo "${B}policy.mode:${D} ${B}${mode}${D}"
  echo "Descrição: $(policy_label "$mode")"
  echo
  echo "Regras importantes:"
  echo " - Portaria sempre pode ligar pra todos."
  echo " - Moradores sempre podem ligar para a portaria."
  echo " - Outras ligações obedecem ao policy.mode."
  hr
}

menu(){
  while true; do
    dashboard

    echo "1) Status detalhado (endpoints/contacts/channels)"
    echo "2) Listar APs e moradores (inclui bloco/prédio)"
    echo "3) Painel de ramais (tabela 🟢/🔴/🟡 + bloco/prédio)"
    echo "4) Buscar (ramal/nome/ap/bloco/prédio)"
    echo "5) Adicionar AP (com bloco/prédio)"
    echo "6) Wizard AP + N moradores (com senha + bloco/prédio)"
    echo "7) Adicionar morador (ramal + senha na hora)"
    echo "8) Remover morador (por ramal)"
    echo "9) Editar nome PORTARIA"
    echo "10) Editar nome AP"
    echo "11) Editar nome MORADOR (por ramal)"
    echo "12) Definir senha manualmente (por ramal)"
    echo "13) Resetar senha (regenera no APPLY)"
    echo "14) APPLY (gerar configs + reiniciar Asterisk)"
    echo "15) Senhas/Integrações (AMI/ARI + testes)"
    echo "16) Restart Asterisk"
    echo "17) Status do serviço (systemctl)"
    echo "18) Logs (messages + security)"
    echo "19) PJSIP Logger (on/off)"
    echo "20) Firewall (UFW)"
    echo "21) Health Check"
    echo "22) MONITOR MODE (live)"
    echo "23) Monitor LIVE tentativas LOGIN/REGISTER (security.log)"
    echo "24) Exportar condo.json sem senhas (safe export)"
    echo "25) Instalar/Atualizar Asterisk (source) + Core"
    echo
    echo "${B}${C}— NOVO: CONTROLE DINÂMICO —${D}"
    echo "26) Policy: ver painel"
    echo "27) Policy: alterar mode (portaria/AP/bloco/prédio/condomínio)"
    echo "28) AP: editar bloco/prédio"
    echo
    echo "0) Sair"
    echo

    read -r -p "Escolha: " opt

    case "${opt,,}" in
      1)
        if ! asterisk_active; then bad "Asterisk não está ativo."; pause; continue; fi
        echo "---- ENDPOINTS ----"; ast_rx "pjsip show endpoints"; echo
        echo "---- CONTACTS ----";  ast_rx "pjsip show contacts"; echo
        echo "---- CHANNELS ----";  ast_rx "core show channels concise"; echo
        pause
        ;;
      2) list_condo; pause ;;
      3|p) panel_ramais; pause ;;
      4|b) buscar; pause ;;
      5) add_ap; pause ;;
      6) wizard_ap; pause ;;
      7) add_morador; pause ;;
      8) rm_morador; pause ;;
      9) edit_portaria_name; pause ;;
      10) edit_ap_name; pause ;;
      11) edit_morador_name; pause ;;
      12) set_password; pause ;;
      13) reset_senha; pause ;;
      14) apply_configs; pause ;;
      15)
        echo "${B}Senhas SIP:${D} $SECRETS"
        if [[ -f "$SECRETS" ]]; then
          sed -n '1,260p' "$SECRETS" | head -n 240
        else
          warn "Ainda não gerado. Rode APPLY para gerar e salvar senhas."
        fi
        echo
        echo "${B}AMI/ARI:${D} $INTEG_TXT"
        [[ -f "$INTEG_TXT" ]] && cat "$INTEG_TXT" || warn "Ainda não gerado."
        echo
        explain_integrations
        pause
        ;;
      16) restart_asterisk; pause ;;
      17) service_status; pause ;;
      18) tail_logs; pause ;;
      19) pjsip_logger_toggle; pause ;;
      20) firewall_helper; pause ;;
      21|h) health_check; pause ;;
      22) monitor_mode ;;
      23|l) monitor_logins_live ;;
      24) export_safe; pause ;;
      25) install_now; pause ;;

      26) policy_panel; pause ;;
      27|m) set_policy_mode; pause ;;
      28) edit_ap_meta; pause ;;

      r) : ;;        # refresh
      q|0) exit 0 ;;
      *) warn "Opção inválida"; pause ;;
    esac
  done
}

main(){
  need_root "$@"
  have python3 || { bad "python3 não encontrado. Instale: apt install -y python3"; exit 1; }
  ensure_cfg_exists
  safe_json_exists || { bad "Seu $CFG está inválido (JSON quebrado). Corrija e tente novamente."; exit 1; }
  menu
}

main "$@"
