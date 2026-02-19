#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# INTERFONE • SUPER MENU (SIP CORE) — v2 (PRO) [ATUALIZADO]
# - Dashboard rico + data/hora (dd/mm/aaaa HH:MM:SS)
# - Tabela ramais (🟢 online / 🔴 offline / 🟡 busy) + filtros (ativos/vencidos)
# - Wizard AP + N moradores (com senha)
# - Ativar/Inativar ramal (bloco) + Validade (expires_at)
# - Política de chamadas (policy v2):
#     * policy.default_resident_can_call: ["PORTARIA", ...]
#     * policy.allow_resident_to_resident: true/false
#     * morador.can_call: ["RAMAL:1000", "AP:101", ...]
# - Apply/restart/logs/health-check
# - Monitor LIVE de tentativas LOGIN/REGISTER
# - Relatório de chamadas (CDR) — últimos registros
#
# Obs:
# 1) Este menu edita o condo.json e chama /usr/local/sbin/interfone-apply (preferencial)
# 2) Também suporta ./install.sh --apply-only se você rodar dentro do repo
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
  "policy": {
    "default_resident_can_call": ["PORTARIA"],
    "allow_resident_to_resident": false
  },
  "portaria": {
    "ramal": "1000",
    "nome": "PORTARIA",
    "senha": "",
    "active": true,
    "expires_at": null
  },
  "apartamentos": [
    {
      "numero": "101",
      "nome": "",
      "active": true,
      "expires_at": null,
      "moradores": [
        {
          "ramal": "10101",
          "nome": "AP101-01",
          "senha": "",
          "active": true,
          "expires_at": null,
          "can_call": []
        }
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
  # Upgrade automático:
  # - valid_until (antigo) -> expires_at (novo ISO)
  # - policy antiga booleana -> policy nova (default_resident_can_call / allow_resident_to_resident)
  # - garante can_call em moradores e flags em AP
  py <<PY
import json, re
from datetime import datetime

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))

def to_iso(vu):
    if vu is None: return None
    vu=str(vu).strip()
    if not vu: return None
    # aceita "YYYY-MM-DD HH:MM:SS" (antigo) -> "YYYY-MM-DDTHH:MM:SS"
    try:
        dt=datetime.strptime(vu, "%Y-%m-%d %H:%M:%S")
        return dt.strftime("%Y-%m-%dT%H:%M:%S")
    except Exception:
        # se já tiver T, tenta fromisoformat
        try:
            dt=datetime.fromisoformat(vu.replace("Z",""))
            return dt.strftime("%Y-%m-%dT%H:%M:%S")
        except Exception:
            return None

# policy nova
data.setdefault("policy", {})
pol=data["policy"]

# Se ainda existe policy antiga (resident_to_portaria etc.), converte para v2
legacy_keys={"resident_to_portaria","portaria_to_resident","resident_to_resident_same_ap","resident_to_resident_any"}
if any(k in pol for k in legacy_keys):
    r2p=bool(pol.get("resident_to_portaria", True))
    rr_any=bool(pol.get("resident_to_resident_any", False))
    # policy v2
    pol2={}
    pol2["default_resident_can_call"] = ["PORTARIA"] if r2p else []
    pol2["allow_resident_to_resident"] = True if rr_any else False
    data["policy"]=pol2
    pol=pol2
else:
    pol.setdefault("default_resident_can_call", ["PORTARIA"])
    pol.setdefault("allow_resident_to_resident", False)

# portaria
data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":""})
p=data["portaria"]
p.setdefault("active", True)
# migra valid_until -> expires_at (se existir)
if "expires_at" not in p:
    p["expires_at"]=to_iso(p.get("valid_until",""))
p.pop("valid_until", None)
# normalize null strings
if isinstance(p.get("expires_at"), str) and p["expires_at"].strip()=="":
    p["expires_at"]=None

# aps/moradores
for ap in data.get("apartamentos", []) or []:
    ap.setdefault("nome","")
    ap.setdefault("active", True)
    if "expires_at" not in ap:
        ap["expires_at"]=to_iso(ap.get("valid_until",""))
    ap.pop("valid_until", None)
    if isinstance(ap.get("expires_at"), str) and ap["expires_at"].strip()=="":
        ap["expires_at"]=None

    for m in ap.get("moradores", []) or []:
        m.setdefault("active", True)
        if "expires_at" not in m:
            m["expires_at"]=to_iso(m.get("valid_until",""))
        m.pop("valid_until", None)
        if isinstance(m.get("expires_at"), str) and m["expires_at"] and m["expires_at"].strip()=="":
            m["expires_at"]=None
        m.setdefault("can_call", [])

json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: condo.json atualizado/migrado para schema novo.")
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
    exp=obj.get("expires_at", None)
    return ("ATIVO" if act else "INATIVO") + (f" | expires_at:{exp}" if exp else "")

p=data.get("portaria",{})
print("PORTARIA:", p.get("ramal","1000"), "-", p.get("nome","PORTARIA"), "|", state(p))
print("")
for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","?")).strip()
    apnome=str(ap.get("nome","")).strip()
    head=f"AP {apn}" + (f" - {apnome}" if apnome else "")
    apst=state(ap)
    print(head, "|", apst)
    for m in ap.get("moradores",[]):
        pw = "SET" if str(m.get("senha","")).strip() else "AUTO"
        can = m.get("can_call",[]) or []
        can_s = ",".join(can) if can else "-"
        print("  -", m.get("ramal","?"), "|", m.get("nome",""), f"| senha:{pw} | {state(m)} | can_call:{can_s}")
PY
}

policy_show(){
  ensure_cfg_exists
  py <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
p=data.get("policy",{})
d=p.get("default_resident_can_call", ["PORTARIA"])
rr=bool(p.get("allow_resident_to_resident", False))
print("POLÍTICA (schema novo):")
print(" - default_resident_can_call:", d)
print(" - allow_resident_to_resident:", "SIM" if rr else "NÃO")
print("")
print("Dica:")
print(" - Para permitir morador -> AP específico: adicione em can_call do morador: AP:101")
print(" - Para permitir morador -> ramal específico: RAMAL:1000 (PORTARIA) ou RAMAL:10102 etc.")
PY
}

policy_set(){
  ensure_cfg_exists
  echo "Defina a política (schema novo):"
  echo
  echo "1) Morador só liga para PORTARIA (recomendado)"
  echo "2) Morador liga para PORTARIA + libera morador->morador (todos)"
  echo "3) Morador NÃO liga para ninguém por padrão (tudo por can_call)"
  echo
  read -r -p "Escolha: " o

  case "$o" in
    1) local d='["PORTARIA"]'; local rr="false" ;;
    2) local d='["PORTARIA"]'; local rr="true" ;;
    3) local d='[]'; local rr="false" ;;
    *) warn "Opção inválida"; return ;;
  esac

  py "$d" "$rr" <<PY
import json, sys
import ast as _ast
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
pol=data.setdefault("policy", {})
pol["default_resident_can_call"]=_ast.literal_eval(sys.argv[1])
pol["allow_resident_to_resident"]=(sys.argv[2].lower()=="true")
json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
print("OK: política atualizada. Rode APPLY.")
PY
  chmod 600 "$CFG" || true
}

# can_call por morador
set_can_call(){
  ensure_cfg_exists
  read -r -p "Ramal do morador (ex: 10101): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  echo
  echo "Configurar can_call desse morador:"
  echo " - ENTER vazio = limpar lista"
  echo " - Exemplos:"
  echo "   AP:101"
  echo "   RAMAL:1000"
  echo "   RAMAL:10102"
  echo
  read -r -p "can_call (separe por vírgula): " raw

  py "$ramal" "$raw" <<PY
import json, sys, re
ramal=sys.argv[1].strip()
raw=sys.argv[2].strip()

items=[]
if raw:
    for part in raw.split(","):
        x=part.strip()
        if not x: continue
        if not (x.startswith("AP:") or x.startswith("RAMAL:") or x=="PORTARIA" or x=="RESIDENTS"):
            print("Item inválido:", x); raise SystemExit(0)
        items.append(x)

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["can_call"]=items
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
            print("OK: can_call atualizado. Rode APPLY.")
            raise SystemExit(0)

print("Ramal não encontrado (apenas moradores têm can_call).")
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
    obj={"numero":apnum,"moradores":[],"nome":apname or "","active":True,"expires_at":None}
    aps.append(obj)
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: AP criado.")
PY
  chmod 600 "$CFG" || true
}

# ---------- expires_at helpers ----------
read_expires_input(){
  echo "Validade (opcional):"
  echo " - ENTER = sem validade"
  echo " - Formato 1 (recomendado): AAAA-MM-DD            (vira 23:59:59)"
  echo " - Formato 2: AAAA-MM-DD HH:MM:SS"
  echo " - Formato 3: AAAA-MM-DDTHH:MM:SS"
  read -r -p "expires_at: " exp
  echo "$exp"
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

  local exp; exp="$(read_expires_input)"

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

  py "$apnum" "$ramal" "$nome" "$pass1" "$exp" <<PY
import json, sys, re, datetime
apnum=sys.argv[1].strip()
ramal=sys.argv[2].strip()
nome=sys.argv[3].strip()
senha=sys.argv[4]
exp=sys.argv[5].strip()

def norm_exp(s):
    s=(s or "").strip()
    if not s: return None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}$", s):
        return s+"T23:59:59"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", s):
        return s.replace(" ","T")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$", s):
        return s
    print("expires_at inválido. Use AAAA-MM-DD ou AAAA-MM-DD HH:MM:SS ou AAAA-MM-DDTHH:MM:SS"); raise SystemExit(0)

if not re.fullmatch(r"\d{2,10}", ramal):
    print("Ramal inválido (use só dígitos, 2..10)."); raise SystemExit(0)

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
mor.append({"ramal":ramal,"nome":nome,"senha":senha,"active":True,"expires_at":norm_exp(exp),"can_call":[]})
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
p=data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":"","active":True,"expires_at":None})
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

set_expires_at(){
  ensure_cfg_exists
  read -r -p "Ramal (1000 ou morador): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  local exp; exp="$(read_expires_input)"

  py "$ramal" "$exp" <<PY
import json, sys, re
ramal=sys.argv[1].strip()
exp=sys.argv[2].strip()

def norm(s):
    s=(s or "").strip()
    if not s: return None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}$", s):
        return s+"T23:59:59"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", s):
        return s.replace(" ","T")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$", s):
        return s
    print("expires_at inválido. Use AAAA-MM-DD ou AAAA-MM-DD HH:MM:SS ou AAAA-MM-DDTHH:MM:SS"); raise SystemExit(0)

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
val=norm(exp)

p=data.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
    p["expires_at"]=val
    data["portaria"]=p
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: expires_at da portaria atualizado. Rode APPLY.")
    raise SystemExit(0)

for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["expires_at"]=val
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
            print("OK: expires_at do morador atualizado. Rode APPLY.")
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

def parse_iso(s):
    if not s: return None
    s=str(s).strip()
    if not s: return None
    try:
        return datetime.fromisoformat(s.replace("Z",""))
    except Exception:
        return None

def expired(exp):
    dt=parse_iso(exp)
    if not dt: return False
    return dt < datetime.now()

rows=[]
p=data.get("portaria",{})
if expired(p.get("expires_at")):
    rows.append(("PORTARIA", p.get("ramal","1000"), p.get("nome","PORTARIA"), p.get("expires_at","")))

for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","")).strip()
    for m in ap.get("moradores",[]):
        if expired(m.get("expires_at")):
            rows.append((f"AP {apn}", m.get("ramal",""), m.get("nome",""), m.get("expires_at","")))

print("")
print("RAMAIS VENCIDOS (expires_at)".center(76))
print("-"*76)
if not rows:
    print("Nenhum vencido.")
else:
    print(f"{'LOCAL':<14} {'RAMAL':<10} {'NOME':<28} {'EXPIRES_AT'}")
    print("-"*76)
    for loc, r, nm, exp in rows:
        print(f"{loc:<14} {str(r):<10} {str(nm)[:28]:<28} {exp}")
print("-"*76)
PY
}

# ---------- Apply/ops ----------
apply_configs(){
  # Preferencial: interfone-apply (independente de onde você roda)
  if [[ -x /usr/local/sbin/interfone-apply ]]; then
    ok "Aplicando configs (interfone-apply) + reload/restart conforme guard..."
    /usr/local/sbin/interfone-apply
    # reinicia asterisk pra garantir (padrão do teu menu)
    systemctl restart asterisk >/dev/null 2>&1 || true
    ok "APPLY concluído."
    return
  fi

  # fallback: dentro do repo
  if [[ -x ./install.sh ]]; then
    ok "Aplicando configs via ./install.sh --apply-only ..."
    bash ./install.sh --apply-only
    ok "APPLY concluído."
    return
  fi

  bad "Nem /usr/local/sbin/interfone-apply nem ./install.sh foram encontrados."
  warn "Dica: rode o install.sh uma vez para instalar o interfone-apply."
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

# ---------- Segurança de rede ----------
apply_network_hardening(){
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

# ---------- CDR ----------
pick_cdr_file(){
  if [[ -f "$CDR_CSV1" ]]; then echo "$CDR_CSV1"; return; fi
  if [[ -f "$CDR_CSV2" ]]; then echo "$CDR_CSV2"; return; fi
  if [[ -f "$CDR_CSV3" ]]; then echo "$CDR_CSV3"; return; fi
  echo ""
}

cdr_tail(){
  local f; f="$(pick_cdr_file)"
  if [[ -z "$f" ]]; then
    warn "CDR CSV não encontrado."
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

def parse_iso(s):
    if not s: return None
    s=str(s).strip()
    if not s: return None
    try:
        return datetime.fromisoformat(s.replace("Z",""))
    except Exception:
        return None

def expired(exp):
    dt=parse_iso(exp)
    if not dt: return False
    return dt < datetime.now()

rows=[]
p=data.get("portaria",{})
rows.append(("PORTARIA","—",str(p.get("ramal","1000")).strip(),str(p.get("nome","PORTARIA")).strip(),p.get("active",True),p.get("expires_at",None)))

for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","")).strip()
    apnome=str(ap.get("nome","")).strip()
    apLabel=apn + (f" ({apnome})" if apnome else "")
    for m in ap.get("moradores",[]):
        rows.append(("MORADOR",apLabel,str(m.get("ramal","")).strip(),str(m.get("nome","")).strip(),m.get("active",True),m.get("expires_at",None)))

def st_icon(r, active, exp):
    if not active: return "⛔ INATIVO"
    if expired(exp): return "⌛ VENCIDO"
    if r in busy: return "🟡 BUSY"
    if r in online: return "🟢 ONLINE"
    return "🔴 OFFLINE"

print("")
print("TABELA DE RAMAIS".center(76))
print("-"*76)
print(f"{'STATUS':<11} {'TIPO':<8} {'AP':<18} {'RAMAL':<8} {'NOME':<20} {'EXPIRES'}")
print("-"*76)
for typ, ap, r, nm, act, exp in rows:
    status=st_icon(r, bool(act), exp)
    v=str(exp) if exp else "-"
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

def parse_iso(s):
    if not s: return None
    s=str(s).strip()
    if not s: return None
    try:
        return datetime.fromisoformat(s.replace("Z",""))
    except Exception:
        return None

def expired(exp):
    dt=parse_iso(exp)
    if not dt: return False
    return dt < datetime.now()

def st(r, active, exp):
    if not active: return "⛔ INATIVO"
    if expired(exp): return "⌛ VENCIDO"
    if r in busy: return "🟡 BUSY"
    if r in online: return "🟢 ONLINE"
    return "🔴 OFFLINE"

hits=[]
p=data.get("portaria",{})
pr=str(p.get("ramal","1000")).strip()
pn=str(p.get("nome","PORTARIA")).strip()
pact=bool(p.get("active",True))
pexp=p.get("expires_at",None)
blob=f"portaria {pr} {pn}".lower()
if q in blob:
    hits.append((st(pr,pact,pexp),"PORTARIA","—",pr,pn,str(pexp) if pexp else "-"))

for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","")).strip()
    apnome=str(ap.get("nome","")).strip()
    apLabel=apn + (f" ({apnome})" if apnome else "")
    apBlob=(f"{apn} {apnome}").lower()
    for m in ap.get("moradores",[]):
        r=str(m.get("ramal","")).strip()
        nm=str(m.get("nome","")).strip()
        act=bool(m.get("active",True))
        exp=m.get("expires_at",None)
        blob=f"{apBlob} {apLabel} {r} {nm}".lower()
        if q in blob:
            hits.append((st(r,act,exp),"MORADOR",apLabel,r,nm,str(exp) if exp else "-"))

print("")
print(f"RESULTADOS PARA: {q}".center(76))
print("-"*76)
if not hits:
    print("Nenhum resultado.")
else:
    print(f"{'STATUS':<11} {'TIPO':<8} {'AP':<18} {'RAMAL':<8} {'NOME':<20} {'EXPIRES'}")
    print("-"*76)
    for s,t,ap,r,nm,exp in hits:
        print(f"{s:<11} {t:<8} {ap:<18} {r:<8} {nm[:20]:<20} {exp}")
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

  echo "Expires_at (opcional) para TODOS os moradores do wizard:"
  local exp; exp="$(read_expires_input)"

  echo "Senha padrão para todos? (ENTER = gerar diferente para cada)"
  local p1 p2
  read -r -s -p "Senha padrão: " p1; echo
  if [[ -n "${p1:-}" ]]; then
    read -r -s -p "Confirmar: " p2; echo
    [[ "$p1" == "$p2" ]] || { bad "Confirmação não bate."; return; }
    validate_pass "$p1" || { bad "Senha inválida."; return; }
  fi

  py "$apnum" "$apname" "$n" "$p1" "$exp" <<PY
import json, sys, secrets, string, re
apnum=sys.argv[1].strip()
apname=sys.argv[2].strip()
n=int(sys.argv[3].strip())
shared=sys.argv[4] if len(sys.argv)>4 else ""
exp=sys.argv[5].strip() if len(sys.argv)>5 else ""

def norm(s):
    s=(s or "").strip()
    if not s: return None
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}$", s):
        return s+"T23:59:59"
    if re.fullmatch(r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$", s):
        return s.replace(" ","T")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$", s):
        return s
    print("expires_at inválido."); raise SystemExit(0)

def gen():
    a=string.ascii_letters+string.digits+"._@:+#=-"
    return ''.join(secrets.choice(a) for _ in range(20))

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])

if any(str(a.get("numero","")).strip()==apnum for a in aps):
    print("AP já existe."); raise SystemExit(0)

ap={"numero":apnum,"moradores":[],"nome":apname or "","active":True,"expires_at":None}

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
    ap["moradores"].append({"ramal":ramal,"nome":f"AP{apnum}-{i:02d}","senha":senha,"active":True,"expires_at":norm(exp),"can_call":[]})

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
    echo "2) Listar APs e moradores (com ativo/expires_at)"
    echo "3) Painel de ramais (🟢/🔴/🟡 + vencidos/inativos)"
    echo "4) Buscar (ramal/nome/ap)"
    echo "5) Política: ver / alterar (schema novo)"
    echo "6) Adicionar AP"
    echo "7) Wizard AP + N moradores (com senha)"
    echo "8) Adicionar morador (ramal + senha + expires_at)"
    echo "9) Remover morador (por ramal)"
    echo "10) Editar nome PORTARIA"
    echo "11) Editar nome AP"
    echo "12) Editar nome MORADOR (por ramal)"
    echo "13) Definir senha manualmente (por ramal)"
    echo "14) Resetar senha (regenera no APPLY)"
    echo "15) Ativar/Inativar ramal (bloco)"
    echo "16) Definir/Remover expires_at do ramal"
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
    echo "33) Definir can_call do morador (AP:xxx / RAMAL:yyy)"
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
      16) set_expires_at; pause ;;
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
      33) set_can_call; pause ;;
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
