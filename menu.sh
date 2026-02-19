#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# INTERFONE • SUPER MENU (SIP CORE) — v2 (PRO)
# - Dashboard rico + data/hora (dd/mm/aaaa HH:MM:SS)
# - Tabela ramais (🟢 online / 🔴 offline / 🟡 busy) + filtros (ativos/vencidos)
# - Wizard AP + N moradores (com senha)
# - Ativar/Inativar ramal (bloco) + Validade (expira)
# - Política de chamadas (quem fala com quem) — simples e segura
# - Apply/restart/logs/health-check
# - Monitor LIVE de tentativas LOGIN/REGISTER
# - Relatório de chamadas (CDR) — últimos registros
#
# Obs:
# 1) Este menu edita o condo.json e chama o install.sh (apply-only) para efetivar.
# 2) As regras (UFW) podem ser aplicadas via opção "Aplicar segurança de rede"
#    sem ficar exibindo detalhes técnicos no menu.
# ==============================================================================

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"
INSTALL_LOG="/root/interfone-install.log"

ASTERISK_LOG="/var/log/asterisk/messages"
ASTERISK_SEC="/var/log/asterisk/security.log"

# CDR (pode variar conforme build/config)
CDR_CSV1="/var/log/asterisk/cdr-csv/Master.csv"
CDR_CSV2="/var/log/asterisk/cdr-csv/custom/Master.csv"
CDR_CSV3="/var/log/asterisk/cdr-custom/Master.csv"

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

now_br(){ date "+%d/%m/%Y %H:%M:%S"; }
now_iso(){ date "+%Y-%m-%d %H:%M:%S"; }

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

get_public_ip(){
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
  [[ -z "${ip:-}" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-N/A}"
}

ensure_cfg_exists(){
  install -d "$APP_DIR"
  chmod 700 "$APP_DIR"

  if [[ ! -f "$CFG" ]]; then
    cat > "$CFG" <<'JSON'
{
  "portaria": { "ramal": "1000", "nome": "PORTARIA", "senha": "", "active": true, "valid_until": "" },
  "policy": {
    "resident_to_portaria": true,
    "portaria_to_resident": true,
    "resident_to_resident_same_ap": false,
    "resident_to_resident_any": false
  },
  "apartamentos": [
    {
      "numero": "101",
      "nome": "",
      "moradores": [
        { "ramal": "10101", "nome": "AP101-01", "senha": "", "active": true, "valid_until": "" },
        { "ramal": "10102", "nome": "AP101-02", "senha": "", "active": true, "valid_until": "" }
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
    /^ *Contact:/{
      x=$2
      split(x,a,"/")
      x=a[1]
      sub(/-.*$/,"",x)
      gsub(/[^0-9]/,"",x)
      if (x!="") print x
    }' | sort -u
}

ast_busy_ramals(){
  ast_rx "core show channels concise" | awk -F'!' '
    {
      c=$1
      if (c ~ /^PJSIP\//) {
        sub(/^PJSIP\//,"",c)
        sub(/-.*/,"",c)
        gsub(/[^0-9]/,"",c)
        if (c!="") print c
      }
    }' | sort -u
}

# ---------- password ----------
validate_pass(){
  local p="$1"
  [[ ${#p} -ge 6 && ${#p} -le 64 ]] || return 1
  [[ "$p" =~ ^[A-Za-z0-9._@:+#=\-]+$ ]] || return 1
  return 0
}

gen_password(){
  python3 - <<'PY'
import secrets,string
a=string.ascii_letters+string.digits+"._@:+#=-"
print(''.join(secrets.choice(a) for _ in range(20)))
PY
}

# ---------- JSON helpers ----------
py(){ python3 - "$@"; }

json_defaults_upgrade(){
  # garante campos novos sem quebrar configs antigas
  py <<PY
import json
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))

data.setdefault("policy", {})
pol=data["policy"]
pol.setdefault("resident_to_portaria", True)
pol.setdefault("portaria_to_resident", True)
pol.setdefault("resident_to_resident_same_ap", False)
pol.setdefault("resident_to_resident_any", False)

data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":""})
p=data["portaria"]
p.setdefault("active", True)
p.setdefault("valid_until", "")

for ap in data.get("apartamentos", []) or []:
    ap.setdefault("nome","")
    for m in ap.get("moradores", []) or []:
        m.setdefault("active", True)
        m.setdefault("valid_until", "")

json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: condo.json atualizado com defaults.")
PY
  chmod 600 "$CFG" || true
}

list_aps_indexed(){
  ensure_cfg_exists
  py <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
aps=data.get("apartamentos",[])
if not aps:
    print("(Nenhum AP cadastrado)")
    raise SystemExit(0)
for i, ap in enumerate(aps, 1):
    n=str(ap.get("numero","?")).strip()
    nome=str(ap.get("nome","")).strip()
    q=len(ap.get("moradores",[]))
    label=f"AP {n}"
    if nome: label+=f" - {nome}"
    print(f"{i}) {label} ({q} morador(es))")
PY
}

resolve_ap_choice(){
  local choice="${1:-}"
  py "$choice" <<PY
import json, sys
choice=sys.argv[1].strip()
data=json.load(open("${CFG}","r",encoding="utf-8"))
aps=data.get("apartamentos",[])
if not aps:
    print(""); sys.exit(0)
if choice.isdigit():
    idx=int(choice)
    if 1 <= idx <= len(aps):
        print(str(aps[idx-1].get("numero","")).strip()); sys.exit(0)
for ap in aps:
    if str(ap.get("numero","")).strip() == choice:
        print(choice); sys.exit(0)
print("")
PY
}

list_condo(){
  ensure_cfg_exists
  py <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))

def state(obj):
    act=bool(obj.get("active", True))
    vu=str(obj.get("valid_until","")).strip()
    return ("ATIVO" if act else "INATIVO") + (f" | validade:{vu}" if vu else "")

p=data.get("portaria",{})
print("PORTARIA:", p.get("ramal","1000"), "-", p.get("nome","PORTARIA"), "|", state(p))
print("")
for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","?")).strip()
    apnome=str(ap.get("nome","")).strip()
    head=f"AP {apn}" + (f" - {apnome}" if apnome else "")
    print(head)
    for m in ap.get("moradores",[]):
        pw = "SET" if str(m.get("senha","")).strip() else "AUTO"
        print("  -", m.get("ramal","?"), "|", m.get("nome",""), f"| senha:{pw} | {state(m)}")
PY
}

policy_show(){
  ensure_cfg_exists
  py <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
p=data.get("policy",{})
print("POLÍTICA (quem pode ligar para quem):")
print(" - Morador → Portaria:", "SIM" if p.get("resident_to_portaria",True) else "NÃO")
print(" - Portaria → Morador:", "SIM" if p.get("portaria_to_resident",True) else "NÃO")
print(" - Morador → Morador (mesmo AP):", "SIM" if p.get("resident_to_resident_same_ap",False) else "NÃO")
print(" - Morador → Morador (qualquer):", "SIM" if p.get("resident_to_resident_any",False) else "NÃO")
PY
}

policy_set(){
  ensure_cfg_exists
  echo "Defina a política (responda S/N):"
  local a b c d

  read -r -p "Morador pode ligar para Portaria? [S/n] " a; a="${a:-S}"
  read -r -p "Portaria pode ligar para Morador? [S/n] " b; b="${b:-S}"
  read -r -p "Morador pode ligar para Morador do MESMO AP? [s/N] " c; c="${c:-N}"
  read -r -p "Morador pode ligar para Morador de QUALQUER AP? [s/N] " d; d="${d:-N}"

  py "${a,,}" "${b,,}" "${c,,}" "${d,,}" <<PY
import json, sys
def yn(x, default=False):
    x=(x or "").strip().lower()
    if x in ("s","sim","y","yes","1","true"): return True
    if x in ("n","nao","não","no","0","false"): return False
    return default

a=yn(sys.argv[1], True)
b=yn(sys.argv[2], True)
c=yn(sys.argv[3], False)
d=yn(sys.argv[4], False)

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
pol=data.setdefault("policy",{})
pol["resident_to_portaria"]=a
pol["portaria_to_resident"]=b
pol["resident_to_resident_same_ap"]=c
pol["resident_to_resident_any"]=d

# segurança: se any=true, força same_ap=true (faz sentido)
if pol["resident_to_resident_any"]:
    pol["resident_to_resident_same_ap"]=True

json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: política atualizada. Rode APPLY.")
PY
  chmod 600 "$CFG" || true
}

suggest_next_ramal(){
  local apnum="$1"
  py "$apnum" <<PY
import json, sys
apnum=sys.argv[1].strip()
data=json.load(open("${CFG}","r",encoding="utf-8"))
aps=data.get("apartamentos",[])
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

add_ap(){
  ensure_cfg_exists
  echo "APs atuais:"
  list_aps_indexed
  echo
  read -r -p "Número do AP (ex: 804): " apnum
  [[ -z "${apnum// }" ]] && { bad "AP inválido"; return; }
  read -r -p "Nome do AP (opcional): " apname

  py "$apnum" "$apname" <<PY
import json, sys
apnum=sys.argv[1].strip()
apname=sys.argv[2].strip()
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])
if any(str(a.get("numero","")).strip()==apnum for a in aps):
    print("Já existe.")
else:
    obj={"numero":apnum,"moradores":[],"nome":apname or ""}
    aps.append(obj)
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: AP criado.")
PY
  chmod 600 "$CFG" || true
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

  read -r -p "Nome do morador (ENTER = padrão): " nome
  [[ -z "${nome// }" ]] && nome="AP${apnum}-${ramal}"

  echo "Validade (opcional):"
  echo " - ENTER = sem validade"
  echo " - Formato: AAAA-MM-DD HH:MM:SS   (ex: 2026-12-31 23:59:59)"
  read -r -p "valid_until: " valid_until

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

  py "$apnum" "$ramal" "$nome" "$pass1" "$valid_until" <<PY
import json, sys, re
apnum=sys.argv[1].strip()
ramal=sys.argv[2].strip()
nome=sys.argv[3].strip()
senha=sys.argv[4]
valid_until=sys.argv[5].strip()

if not re.fullmatch(r"\d{2,10}", ramal):
    print("Ramal inválido (use só dígitos, 2..10)."); raise SystemExit(0)

if valid_until and not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", valid_until):
    print("valid_until inválido. Use AAAA-MM-DD HH:MM:SS"); raise SystemExit(0)

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])
ap=None
for a in aps:
    if str(a.get("numero","")).strip()==apnum:
        ap=a; break
if ap is None:
    print("AP não existe."); raise SystemExit(0)

port=str(data.get("portaria",{}).get("ramal","1000")).strip()
if ramal==port:
    print("Ramal conflita com PORTARIA."); raise SystemExit(0)

for a in aps:
    for m in a.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            print("Ramal já existe em outro AP."); raise SystemExit(0)

mor=ap.setdefault("moradores",[])
mor.append({"ramal":ramal,"nome":nome,"senha":senha,"active":True,"valid_until":valid_until})
json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: morador criado. Rode APPLY para entrar em produção.")
PY
  chmod 600 "$CFG" || true

  read -r -p "Aplicar agora (gerar configs + reiniciar Asterisk)? [S/n] " yn
  yn="${yn:-S}"
  if [[ "${yn,,}" == "s" ]]; then
    apply_configs
  else
    warn "Ok. Lembre: opção APPLY para efetivar no Asterisk."
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
    print("OK: removido. Rode APPLY.")
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
data=json.load(open(cfg,"r",encoding="utf-8"))
p=data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":"","active":True,"valid_until":""})
p["nome"]=newname
json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: nome da portaria atualizado. Rode APPLY.")
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
data=json.load(open(cfg,"r",encoding="utf-8"))
for ap in data.get("apartamentos",[]):
    if str(ap.get("numero","")).strip()==apnum:
        ap["nome"]=newname
        json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
        print("OK: AP renomeado. Rode APPLY.")
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
data=json.load(open(cfg,"r",encoding="utf-8"))
for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["nome"]=newname
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
            print("OK: morador renomeado. Rode APPLY.")
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
data=json.load(open(cfg,"r",encoding="utf-8"))

p=data.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
    p["senha"]=senha
    data["portaria"]=p
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: senha da PORTARIA definida. Rode APPLY.")
    raise SystemExit(0)

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["senha"]=senha
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
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
data=json.load(open(cfg,"r",encoding="utf-8"))

p=data.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
    p["senha"]=""
    data["portaria"]=p
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: senha da portaria será regenerada no APPLY.")
    raise SystemExit(0)

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["senha"]=""
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
            print("OK: senha do morador será regenerada no APPLY.")
            raise SystemExit(0)

print("Ramal não encontrado.")
PY
  chmod 600 "$CFG" || true
}

set_active(){
  ensure_cfg_exists
  read -r -p "Ramal (1000 ou morador): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  echo "1) Ativar"
  echo "2) Inativar (bloqueia no dialplan após APPLY)"
  read -r -p "Escolha: " o
  case "$o" in
    1) local act="true" ;;
    2) local act="false" ;;
    *) warn "Opção inválida"; return ;;
  esac

  py "$ramal" "$act" <<PY
import json, sys
ramal=sys.argv[1].strip()
act=sys.argv[2].strip().lower()=="true"
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))

p=data.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
    p["active"]=act
    data["portaria"]=p
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: portaria atualizada. Rode APPLY.")
    raise SystemExit(0)

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["active"]=act
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
            print("OK: morador atualizado. Rode APPLY.")
            raise SystemExit(0)

print("Ramal não encontrado.")
PY
  chmod 600 "$CFG" || true
}

set_valid_until(){
  ensure_cfg_exists
  read -r -p "Ramal (1000 ou morador): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  echo "valid_until:"
  echo " - ENTER = remover validade (nunca expira)"
  echo " - Formato: AAAA-MM-DD HH:MM:SS   (ex: 2026-12-31 23:59:59)"
  read -r -p "valid_until: " vu

  py "$ramal" "$vu" <<PY
import json, sys, re
ramal=sys.argv[1].strip()
vu=sys.argv[2].strip()
if vu and not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", vu):
    print("valid_until inválido. Use AAAA-MM-DD HH:MM:SS"); raise SystemExit(0)

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))

p=data.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
    p["valid_until"]=vu
    data["portaria"]=p
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: validade da portaria atualizada. Rode APPLY.")
    raise SystemExit(0)

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["valid_until"]=vu
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
            print("OK: validade do morador atualizada. Rode APPLY.")
            raise SystemExit(0)

print("Ramal não encontrado.")
PY
  chmod 600 "$CFG" || true
}

list_expired(){
  ensure_cfg_exists
  py <<PY
import json
from datetime import datetime
data=json.load(open("${CFG}","r",encoding="utf-8"))

def is_expired(vu):
    vu=(vu or "").strip()
    if not vu: return False
    try:
        dt=datetime.strptime(vu, "%Y-%m-%d %H:%M:%S")
        return dt < datetime.now()
    except Exception:
        return True

rows=[]
p=data.get("portaria",{})
if is_expired(p.get("valid_until","")):
    rows.append(("PORTARIA", p.get("ramal","1000"), p.get("nome","PORTARIA"), p.get("valid_until","")))

for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","")).strip()
    for m in ap.get("moradores",[]):
        if is_expired(m.get("valid_until","")):
            rows.append((f"AP {apn}", m.get("ramal",""), m.get("nome",""), m.get("valid_until","")))

print("")
print("RAMAL(IS) VENCIDOS".center(76))
print("-"*76)
if not rows:
    print("Nenhum vencido.")
else:
    print(f"{'LOCAL':<14} {'RAMAL':<10} {'NOME':<28} {'VALID_UNTIL'}")
    print("-"*76)
    for loc, r, nm, vu in rows:
        print(f"{loc:<14} {str(r):<10} {str(nm)[:28]:<28} {vu}")
print("-"*76)
PY
}

# ---------- Apply/ops ----------
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
  [[ -f "$ASTERISK_LOG" ]] && tail -n 220 "$ASTERISK_LOG" || warn "Não achei $ASTERISK_LOG"
  echo
  echo "${B}LOG SEGURANÇA (LOGIN/REGISTER):${D} $ASTERISK_SEC"
  [[ -f "$ASTERISK_SEC" ]] && tail -n 220 "$ASTERISK_SEC" || warn "Não achei $ASTERISK_SEC"
}

monitor_logins_live(){
  echo
  echo "${B}${C}MONITOR LIVE - TENTATIVAS DE LOGIN/REGISTER${D}"
  echo "Agora tente logar no Linphone/Zoiper e observe."
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
  echo "1) ON  (captura SIP no console/CLI)"
  echo "2) OFF"
  read -r -p "Escolha: " o
  case "$o" in
    1) ast_rx "pjsip set logger on"; ok "PJSIP logger ON.";;
    2) ast_rx "pjsip set logger off"; ok "PJSIP logger OFF.";;
    *) warn "Opção inválida";;
  esac
}

# ---------- Segurança de rede (sem “pontas soltas” no menu) ----------
apply_network_hardening(){
  # Mantém o menu “limpo”: não fica exibindo portas/regras.
  if ! have ufw; then
    warn "ufw não instalado. Sugestão: apt install -y ufw"
    return
  fi
  ok "Aplicando segurança de rede recomendada (modo silencioso)..."
  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw allow 5060/udp >/dev/null 2>&1 || true
  ufw allow 5060/tcp >/dev/null 2>&1 || true
  ufw allow 10000:20000/udp >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
  ok "Segurança aplicada."
}

network_status(){
  if ! have ufw; then warn "ufw não instalado."; return; fi
  ufw status verbose || true
}

# ---------- CDR / Histórico de chamadas ----------
pick_cdr_file(){
  if [[ -f "$CDR_CSV1" ]]; then echo "$CDR_CSV1"; return; fi
  if [[ -f "$CDR_CSV2" ]]; then echo "$CDR_CSV2"; return; fi
  if [[ -f "$CDR_CSV3" ]]; then echo "$CDR_CSV3"; return; fi
  echo ""
}

cdr_tail(){
  local f; f="$(pick_cdr_file)"
  if [[ -z "$f" ]]; then
    warn "CDR CSV não encontrado. (Pode precisar habilitar cdr_csv no Asterisk.)"
    echo "Caminhos tentados:"
    echo " - $CDR_CSV1"
    echo " - $CDR_CSV2"
    echo " - $CDR_CSV3"
    return
  fi

  local n="${1:-50}"
  echo "${B}CDR:${D} $f"
  echo "(Mostrando últimos $n registros)"
  tail -n "$n" "$f" || true
}

cdr_by_ramal(){
  local f; f="$(pick_cdr_file)"
  if [[ -z "$f" ]]; then warn "CDR CSV não encontrado."; return; fi

  read -r -p "Ramal para filtrar (ex: 10101): " r
  [[ -z "${r// }" ]] && { warn "Vazio."; return; }

  echo "${B}CDR:${D} $f"
  echo "(Últimos 80 que contenham o ramal no src/dst)"
  # Master.csv é CSV padrão do Asterisk: não vamos fazer parser “perfeito”, mas funciona bem na prática.
  grep -F "\"$r\"" "$f" | tail -n 80 || true
}

# ---------- Painel / Busca ----------
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
from datetime import datetime
data=json.load(open("${CFG}","r",encoding="utf-8"))

online=set([x.strip() for x in """${online_list}""".splitlines() if x.strip()])
busy=set([x.strip() for x in """${busy_list}""".splitlines() if x.strip()])

def expired(vu):
    vu=(vu or "").strip()
    if not vu: return False
    try:
        return datetime.strptime(vu, "%Y-%m-%d %H:%M:%S") < datetime.now()
    except Exception:
        return True

rows=[]
p=data.get("portaria",{})
rows.append(("PORTARIA","—",str(p.get("ramal","1000")).strip(),str(p.get("nome","PORTARIA")).strip(),p.get("active",True),p.get("valid_until","")))

for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","")).strip()
    apnome=str(ap.get("nome","")).strip()
    apLabel=apn + (f" ({apnome})" if apnome else "")
    for m in ap.get("moradores",[]):
        rows.append(("MORADOR",apLabel,str(m.get("ramal","")).strip(),str(m.get("nome","")).strip(),m.get("active",True),m.get("valid_until","")))

def st_icon(r, active, vu):
    if not active: return "⛔ INATIVO"
    if expired(vu): return "⌛ VENCIDO"
    if r in busy: return "🟡 BUSY"
    if r in online: return "🟢 ONLINE"
    return "🔴 OFFLINE"

print("")
print("TABELA DE RAMAIS".center(76))
print("-"*76)
print(f"{'STATUS':<11} {'TIPO':<8} {'AP':<18} {'RAMAL':<8} {'NOME':<20} {'VALID'}")
print("-"*76)
for typ, ap, r, nm, act, vu in rows:
    status=st_icon(r, bool(act), vu)
    v=vu if vu else "-"
    print(f"{status:<11} {typ:<8} {ap:<18} {r:<8} {nm[:20]:<20} {v}")
print("-"*76)
PY
}

buscar(){
  ensure_cfg_exists
  read -r -p "Buscar (ramal/nome/ap): " q
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
from datetime import datetime
q="${q}".strip().lower()
data=json.load(open("${CFG}","r",encoding="utf-8"))

online=set([x.strip() for x in """${online_list}""".splitlines() if x.strip()])
busy=set([x.strip() for x in """${busy_list}""".splitlines() if x.strip()])

def expired(vu):
    vu=(vu or "").strip()
    if not vu: return False
    try:
        return datetime.strptime(vu, "%Y-%m-%d %H:%M:%S") < datetime.now()
    except Exception:
        return True

def st(r, active, vu):
    if not active: return "⛔ INATIVO"
    if expired(vu): return "⌛ VENCIDO"
    if r in busy: return "🟡 BUSY"
    if r in online: return "🟢 ONLINE"
    return "🔴 OFFLINE"

hits=[]
p=data.get("portaria",{})
pr=str(p.get("ramal","1000")).strip()
pn=str(p.get("nome","PORTARIA")).strip()
pact=bool(p.get("active",True))
pvu=str(p.get("valid_until","")).strip()
blob=f"portaria {pr} {pn}".lower()
if q in blob:
    hits.append((st(pr,pact,pvu),"PORTARIA","—",pr,pn,pvu or "-"))

for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","")).strip()
    apnome=str(ap.get("nome","")).strip()
    apLabel=apn + (f" ({apnome})" if apnome else "")
    apBlob=(f"{apn} {apnome}").lower()
    for m in ap.get("moradores",[]):
        r=str(m.get("ramal","")).strip()
        nm=str(m.get("nome","")).strip()
        act=bool(m.get("active",True))
        vu=str(m.get("valid_until","")).strip()
        blob=f"{apBlob} {apLabel} {r} {nm}".lower()
        if q in blob:
            hits.append((st(r,act,vu),"MORADOR",apLabel,r,nm,vu or "-"))

print("")
print(f"RESULTADOS PARA: {q}".center(76))
print("-"*76)
if not hits:
    print("Nenhum resultado.")
else:
    print(f"{'STATUS':<11} {'TIPO':<8} {'AP':<18} {'RAMAL':<8} {'NOME':<20} {'VALID'}")
    print("-"*76)
    for s,t,ap,r,nm,vu in hits:
        print(f"{s:<11} {t:<8} {ap:<18} {r:<8} {nm[:20]:<20} {vu}")
print("-"*76)
PY
}

wizard_ap(){
  ensure_cfg_exists
  echo "WIZARD — Criar AP + N moradores"
  read -r -p "Número do AP (ex: 804): " apnum
  [[ -z "${apnum// }" ]] && { bad "AP inválido"; return; }
  read -r -p "Nome do AP (opcional): " apname
  read -r -p "Quantos moradores criar? (1..20): " n
  [[ "$n" =~ ^[0-9]+$ ]] || { bad "Número inválido."; return; }
  (( n >= 1 && n <= 20 )) || { bad "Use 1..20"; return; }

  echo "Validade (opcional) para TODOS os moradores do wizard:"
  echo " - ENTER = sem validade"
  echo " - Formato: AAAA-MM-DD HH:MM:SS"
  read -r -p "valid_until: " vu

  echo "Senha padrão para todos? (ENTER = gerar diferente para cada)"
  local p1 p2
  read -r -s -p "Senha padrão: " p1; echo
  if [[ -n "${p1:-}" ]]; then
    read -r -s -p "Confirmar: " p2; echo
    [[ "$p1" == "$p2" ]] || { bad "Confirmação não bate."; return; }
    validate_pass "$p1" || { bad "Senha inválida."; return; }
  fi

  py "$apnum" "$apname" "$n" "$p1" "$vu" <<PY
import json, sys, secrets, string, re
apnum=sys.argv[1].strip()
apname=sys.argv[2].strip()
n=int(sys.argv[3].strip())
shared=sys.argv[4] if len(sys.argv)>4 else ""
vu=sys.argv[5].strip() if len(sys.argv)>5 else ""

if vu and not re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}", vu):
    print("valid_until inválido. Use AAAA-MM-DD HH:MM:SS"); raise SystemExit(0)

def gen():
    a=string.ascii_letters+string.digits+"._@:+#=-"
    return ''.join(secrets.choice(a) for _ in range(20))

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])

if any(str(a.get("numero","")).strip()==apnum for a in aps):
    print("AP já existe."); raise SystemExit(0)

ap={"numero":apnum,"moradores":[],"nome":apname or ""}

port=str(data.get("portaria",{}).get("ramal","1000")).strip()
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
    ap["moradores"].append({"ramal":ramal,"nome":f"AP{apnum}-{i:02d}","senha":senha,"active":True,"valid_until":vu})

aps.append(ap)
json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: AP criado com moradores. Rode APPLY.")
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
    ss -lunp 2>/dev/null | grep -qE '(:5060)\s' && ok "SIP UDP escutando" || warn "SIP UDP não parece escutar"
    ss -lntp 2>/dev/null | grep -qE '(:5060)\s' && ok "SIP TCP escutando" || warn "SIP TCP não parece escutar"
  else
    warn "ss não encontrado (iproute2)."
  fi

  [[ -f "$CFG" ]] && ok "CFG: $CFG" || bad "CFG ausente: $CFG"
  [[ -f "/etc/asterisk/pjsip.conf" ]] && ok "pjsip.conf existe" || warn "pjsip.conf ausente (rode APPLY)"
  [[ -f "/etc/asterisk/extensions.conf" ]] && ok "extensions.conf existe" || warn "extensions.conf ausente (rode APPLY)"
  [[ -f "$ASTERISK_SEC" ]] && ok "security.log existe" || warn "security.log não existe ainda"

  if asterisk_active; then
    local ep on calls chans
    ep="$(ast_endpoints_count)"
    on="$(ast_contacts_online_count)"
    read -r calls chans <<<"$(ast_calls_summary)"
    echo "Resumo: endpoints=$ep | online=$on | calls=$calls | channels=$chans"
  else
    warn "Sem contagem (Asterisk off)."
  fi

  local cdr; cdr="$(pick_cdr_file)"
  [[ -n "$cdr" ]] && ok "CDR encontrado: $cdr" || warn "CDR não encontrado (histórico pode não estar habilitado)"

  hr
}

dashboard(){
  ensure_cfg_exists

  local ip srv_inst srv_act srv_en
  ip="$(get_public_ip)"
  srv_inst="$(asterisk_installed && echo "INSTALADO" || echo "NÃO")"
  srv_act="$(asterisk_active && echo "ATIVO" || echo "OFF")"
  srv_en="$(asterisk_enabled && echo "ENABLED" || echo "DISABLED")"

  local endpoints="—" online="—" calls="—" chans="—"
  if asterisk_active; then
    endpoints="$(ast_endpoints_count)"
    online="$(ast_contacts_online_count)"
    read -r calls chans <<<"$(ast_calls_summary)"
  fi

  clear
  title_box
  printf "${B}${W}%s${D}\n" "$(now_br)"
  printf "${B}${W}IP:${D} %s\n" "$ip"
  echo "[ASTERISK: $srv_inst]  [SERVIÇO: $srv_act]  [BOOT: $srv_en]"
  hr
  printf "${B}${C}Resumo:${D} Endpoints=%s  Online=%s  Calls=%s  Channels=%s\n" \
    "${B}${endpoints}${D}" "${B}${online}${D}" "${B}${calls}${D}" "${B}${chans}${D}"
  hr
  echo "${B}${W}Atalhos:${D} [R]efresh  [P]ainel  [B]uscar  [H]ealth  [L]oginsLive  [Q]uit"
  echo
}

monitor_mode(){
  asterisk_active || { bad "Asterisk não está ativo."; return; }
  while true; do
    dashboard
    echo "${B}${Y}MONITOR MODE${D} — atualizando a cada ${REFRESH_SLEEP}s (Ctrl+C para sair)"
    echo
    echo "${B}${C}Contacts:${D}"
    ast_rx "pjsip show contacts" | sed -n '1,120p'
    echo
    echo "${B}${C}Channels:${D}"
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

export_safe(){
  ensure_cfg_exists
  local out="/root/interfone-export.json"
  py "$out" <<PY
import json, sys
out=sys.argv[1]
data=json.load(open("${CFG}","r",encoding="utf-8"))

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

clean=strip_pw(data)
json.dump(clean, open(out,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK:", out)
PY
  chmod 600 "/root/interfone-export.json" || true
}

show_integrations(){
  echo "${B}Senhas SIP:${D} $SECRETS"
  if [[ -f "$SECRETS" ]]; then
    warn "Arquivo contém senhas. Não cole em chat/grupo."
    sed -n '1,220p' "$SECRETS" | head -n 200
  else
    warn "Ainda não gerado. Rode APPLY."
  fi
  echo
  echo "${B}AMI/ARI:${D} $INTEG_TXT"
  [[ -f "$INTEG_TXT" ]] && cat "$INTEG_TXT" || warn "Ainda não gerado."
  pause
}

menu(){
  while true; do
    dashboard
    echo "1) Status detalhado (endpoints/contacts/channels)"
    echo "2) Listar APs e moradores (com ativo/validade)"
    echo "3) Painel de ramais (🟢/🔴/🟡 + vencidos/inativos)"
    echo "4) Buscar (ramal/nome/ap)"
    echo "5) Política: ver / alterar (quem fala com quem)"
    echo "6) Adicionar AP"
    echo "7) Wizard AP + N moradores (com senha)"
    echo "8) Adicionar morador (ramal + senha + validade)"
    echo "9) Remover morador (por ramal)"
    echo "10) Editar nome PORTARIA"
    echo "11) Editar nome AP"
    echo "12) Editar nome MORADOR (por ramal)"
    echo "13) Definir senha manualmente (por ramal)"
    echo "14) Resetar senha (regenera no APPLY)"
    echo "15) Ativar/Inativar ramal (bloco)"
    echo "16) Definir/Remover validade do ramal"
    echo "17) Listar ramais vencidos"
    echo "18) APPLY (gerar configs + reiniciar Asterisk)"
    echo "19) Restart Asterisk"
    echo "20) Status do serviço (systemctl)"
    echo "21) Logs (messages + security)"
    echo "22) Monitor LIVE LOGIN/REGISTER (security.log)"
    echo "23) PJSIP Logger (on/off)"
    echo "24) Health Check"
    echo "25) MONITOR MODE (live)"
    echo "26) Histórico de chamadas (CDR) — últimos 50"
    echo "27) Histórico de chamadas (CDR) — por ramal"
    echo "28) Aplicar segurança de rede (silencioso)"
    echo "29) Status da segurança de rede"
    echo "30) Exportar condo.json sem senhas (safe export)"
    echo "31) Mostrar Integrações (AMI/ARI) + arquivo de senhas"
    echo "32) Instalar/Atualizar Core (install.sh completo)"
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
      5)
        policy_show
        echo
        read -r -p "Alterar política agora? [s/N] " yn; yn="${yn:-N}"
        [[ "${yn,,}" == "s" ]] && policy_set
        pause
        ;;
      6) add_ap; pause ;;
      7) wizard_ap; pause ;;
      8) add_morador; pause ;;
      9) rm_morador; pause ;;
      10) edit_portaria_name; pause ;;
      11) edit_ap_name; pause ;;
      12) edit_morador_name; pause ;;
      13) set_password; pause ;;
      14) reset_senha; pause ;;
      15) set_active; pause ;;
      16) set_valid_until; pause ;;
      17) list_expired; pause ;;
      18) apply_configs; pause ;;
      19) restart_asterisk; pause ;;
      20) service_status; pause ;;
      21) tail_logs; pause ;;
      22|l) monitor_logins_live ;;
      23) pjsip_logger_toggle; pause ;;
      24|h) health_check; pause ;;
      25) monitor_mode ;;
      26) cdr_tail 50; pause ;;
      27) cdr_by_ramal; pause ;;
      28) apply_network_hardening; pause ;;
      29) network_status; pause ;;
      30) export_safe; pause ;;
      31) show_integrations ;;
      32) install_now; pause ;;
      r) : ;;
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
  json_defaults_upgrade >/dev/null 2>&1 || true
  menu
}

main "$@"
