#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# INTERFONE - SUPER MENU (SIP CORE)
# Painel operacional rico e bonito
# - Dashboard automático ao abrir (instalado/rodando/online/calls/UFW)
# - Overview por AP (online/offline/busy)
# - CRUD AP/Morador/Nomes + Reset senha (gera no apply)
# - Apply configs, restart, logs, monitor mode
# ==========================================

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"
INSTALL_LOG="/root/interfone-install.log"
ASTERISK_LOG="/var/log/asterisk/messages"

# UI
USE_COLOR="${USE_COLOR:-1}"
REFRESH_SLEEP="${REFRESH_SLEEP:-2}"

# ---------- helpers ----------
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo bash "$0" "$@"; }
pause(){ read -r -p "ENTER para continuar..." _; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- colors ----------
if [[ "$USE_COLOR" == "1" ]] && [[ -t 1 ]]; then
  B="$(tput bold || true)"
  D="$(tput sgr0 || true)"
  R="$(tput setaf 1 || true)"
  G="$(tput setaf 2 || true)"
  Y="$(tput setaf 3 || true)"
  C="$(tput setaf 6 || true)"
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

# ---------- state probes ----------
asterisk_installed(){
  have asterisk
}

asterisk_service_exists(){
  systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "asterisk.service"
}

asterisk_active(){
  systemctl is-active --quiet asterisk 2>/dev/null
}

asterisk_enabled(){
  systemctl is-enabled --quiet asterisk 2>/dev/null
}

ufw_active(){
  have ufw && ufw status 2>/dev/null | head -n1 | grep -qi "Status: active"
}

ufw_has_rule(){
  local rule="$1"
  have ufw || return 1
  ufw status 2>/dev/null | grep -Fqi "$rule"
}

get_public_ip(){
  local ip=""
  ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)"
  [[ -z "${ip:-}" ]] && ip="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)"
  echo "${ip:-N/A}"
}

safe_json_exists(){
  [[ -f "$CFG" ]] || return 1
  have python3 || return 1
  python3 - <<PY >/dev/null 2>&1
import json
json.load(open("${CFG}","r",encoding="utf-8"))
PY
}

ensure_cfg_exists(){
  if [[ ! -f "$CFG" ]]; then
    install -d "$APP_DIR"; chmod 700 "$APP_DIR"
    cat > "$CFG" <<'JSON'
{
  "portaria": { "ramal": "1000", "nome": "PORTARIA", "senha": "" },
  "apartamentos": [
    { "numero": "101", "moradores": [
      { "ramal": "10101", "nome": "AP101-01", "senha": "" },
      { "ramal": "10102", "nome": "AP101-02", "senha": "" }
    ] }
  ]
}
JSON
    chmod 600 "$CFG"
  fi
}

# ---------- Asterisk stats (only when active) ----------
ast_rx(){
  # safe wrapper
  asterisk -rx "$1" 2>/dev/null || true
}

ast_endpoints_count(){
  local out
  out="$(ast_rx "pjsip show endpoints")"
  echo "$out" | awk -F': ' '/Objects found:/{print $2}' | tail -n1 | tr -d '\r' | awk '{print $1}' | grep -E '^[0-9]+$' || echo "0"
}

ast_contacts_online_count(){
  local out
  out="$(ast_rx "pjsip show contacts")"
  if echo "$out" | grep -qi "No objects found"; then
    echo "0"
  else
    echo "$out" | awk -F': ' '/Objects found:/{print $2}' | tail -n1 | tr -d '\r' | awk '{print $1}' | grep -E '^[0-9]+$' || echo "0"
  fi
}

ast_calls_summary(){
  # returns "calls channels" numbers
  local out calls ch
  out="$(ast_rx "core show channels count")"
  # examples:
  # "2 active channels"
  # "1 active call"
  ch="$(echo "$out" | awk '/active channels/{print $1}' | head -n1 | grep -E '^[0-9]+$' || echo "0")"
  calls="$(echo "$out" | awk '/active call/{print $1}' | head -n1 | grep -E '^[0-9]+$' || echo "0")"
  echo "$calls $ch"
}

ast_online_ramals(){
  # prints ramais online, one per line
  local out
  out="$(ast_rx "pjsip show contacts")"
  echo "$out" | awk '
    /^ *Contact:/{
      x=$2
      sub(/-aor\/.*/,"",x)
      gsub(/[^0-9]/,"",x)
      if (x!="") print x
    }' | sort -u
}

ast_busy_ramals(){
  # prints ramais em chamada, one per line
  local out
  out="$(ast_rx "core show channels concise")"
  echo "$out" | awk -F'!' '
    {
      # field1 usually: PJSIP/10101-00000001
      c=$1
      if (c ~ /^PJSIP\//) {
        sub(/^PJSIP\//,"",c)
        sub(/-.*/,"",c)
        gsub(/[^0-9]/,"",c)
        if (c!="") print c
      }
    }' | sort -u
}

# ---------- JSON operations ----------
py(){
  python3 - "$@"
}

list_condo(){
  ensure_cfg_exists
  py <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
p=data.get("portaria",{})
print("PORTARIA:", p.get("ramal","1000"), "-", p.get("nome","PORTARIA"))
print("")
for ap in data.get("apartamentos",[]):
    apn=str(ap.get("numero","?")).strip()
    apnome=str(ap.get("nome","")).strip()
    head=f"AP {apn}"
    if apnome: head += f" - {apnome}"
    print(head)
    for m in ap.get("moradores",[]):
        print("  -", m.get("ramal","?"), "|", m.get("nome",""))
PY
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
    obj={"numero":apnum,"moradores":[]}
    if apname: obj["nome"]=apname
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

  echo "AP escolhido: $apnum"
  read -r -p "Ramal SIP (ex: ${apnum}01): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }
  read -r -p "Nome do morador (ex: João / Maria): " nome
  [[ -z "${nome// }" ]] && nome="AP${apnum}-${ramal}"

  py "$apnum" "$ramal" "$nome" <<PY
import json, sys
apnum=sys.argv[1].strip()
ramal=sys.argv[2].strip()
nome=sys.argv[3].strip()
cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))
aps=data.setdefault("apartamentos",[])
ap=None
for a in aps:
    if str(a.get("numero","")).strip()==apnum:
        ap=a; break
if ap is None:
    print("AP não existe."); raise SystemExit(0)
mor=ap.setdefault("moradores",[])
if any(str(m.get("ramal","")).strip()==ramal for m in mor):
    print("Ramal já existe.")
else:
    mor.append({"ramal":ramal,"nome":nome,"senha":""})
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: morador adicionado (senha será gerada ao aplicar).")
PY
  chmod 600 "$CFG" || true
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
data=json.load(open(cfg,"r",encoding="utf-8"))
p=data.setdefault("portaria", {"ramal":"1000","nome":"PORTARIA","senha":""})
p["nome"]=newname
json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
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
data=json.load(open(cfg,"r",encoding="utf-8"))
for ap in data.get("apartamentos",[]):
    if str(ap.get("numero","")).strip()==apnum:
        if newname:
            ap["nome"]=newname
        else:
            ap.pop("nome", None)
        json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
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
data=json.load(open(cfg,"r",encoding="utf-8"))
for ap in data.get("apartamentos",[]):
    for m in ap.get("moradores",[]):
        if str(m.get("ramal","")).strip()==ramal:
            m["nome"]=newname
            json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
            print("OK: morador renomeado.")
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

# portaria
p=data.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
    p["senha"]=""
    data["portaria"]=p
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: senha da portaria será regenerada no APPLY.")
    raise SystemExit(0)

# moradores
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

# ---------- operational actions ----------
apply_configs(){
  [[ -x ./install.sh ]] || { bad "install.sh não encontrado no diretório atual."; return; }
  ok "Aplicando configs + reiniciando Asterisk..."
  bash ./install.sh --apply-only
  ok "APPLY concluído."
}

restart_asterisk(){
  if ! asterisk_service_exists; then
    bad "asterisk.service não existe."
    return
  fi
  systemctl restart asterisk
  systemctl is-active --quiet asterisk && ok "Asterisk reiniciado e ATIVO." || bad "Asterisk não subiu."
}

service_status(){
  if ! asterisk_service_exists; then
    bad "asterisk.service não existe."
    return
  fi
  systemctl status asterisk --no-pager -l || true
}

tail_logs(){
  if [[ -f "$ASTERISK_LOG" ]]; then
    echo "Log: $ASTERISK_LOG"
    hr
    tail -n 200 "$ASTERISK_LOG" || true
  else
    warn "Arquivo de log não encontrado: $ASTERISK_LOG"
    echo "Dica: systemctl status asterisk -l"
  fi
}

install_now(){
  [[ -x ./install.sh ]] || { bad "install.sh não encontrado no diretório atual."; return; }
  ok "Instalando/atualizando Asterisk + Core..."
  bash ./install.sh |& tee "$INSTALL_LOG"
  echo "Log: $INSTALL_LOG"
}

pjsip_logger_toggle(){
  if ! asterisk_active; then
    bad "Asterisk não está ativo."
    return
  fi
  echo "1) ON  (pjsip set logger on)"
  echo "2) OFF (pjsip set logger off)"
  read -r -p "Escolha: " o
  case "$o" in
    1) ast_rx "pjsip set logger on"; ok "PJSIP logger ON.";;
    2) ast_rx "pjsip set logger off"; ok "PJSIP logger OFF.";;
    *) warn "Opção inválida";;
  esac
}

firewall_helper(){
  if ! have ufw; then
    warn "ufw não instalado."
    return
  fi
  echo "Status atual:"
  ufw status || true
  echo
  echo "Ações:"
  echo "1) Liberar SIP (5060/udp) + RTP (10000-20000/udp) + SSH e ativar"
  echo "2) Desativar UFW"
  echo "3) Mostrar regras"
  read -r -p "Escolha: " o
  case "$o" in
    1)
      ufw allow OpenSSH || true
      ufw allow 5060/udp || true
      ufw allow 10000:20000/udp || true
      ufw --force enable || true
      ok "UFW configurado."
      ;;
    2)
      ufw --force disable || true
      warn "UFW desativado."
      ;;
    3)
      ufw status verbose || true
      ;;
    *) warn "Opção inválida";;
  esac
}

# ---------- dashboard ----------
badge(){
  # badge "LABEL" "STATUS" "COLOR"
  local label="$1" status="$2" col="$3"
  printf "%b[%s: %s]%b" "${col}${B}" "$label" "$status" "${D}"
}

dashboard(){
  ensure_cfg_exists

  local ip srv_inst srv_act srv_en ufw on5060 onrtp
  ip="$(get_public_ip)"

  if asterisk_installed; then srv_inst="INSTALADO"; else srv_inst="NÃO"; fi
  if asterisk_active; then srv_act="ATIVO"; else srv_act="OFF"; fi
  if asterisk_enabled; then srv_en="ENABLED"; else srv_en="DISABLED"; fi

  if ufw_active; then ufw="ON"; else ufw="OFF"; fi
  if ufw_has_rule "5060/udp"; then on5060="OK"; else on5060="X"; fi
  if ufw_has_rule "10000:20000/udp"; then onrtp="OK"; else onrtp="X"; fi

  local endpoints="—" online="—" calls="—" chans="—"
  if asterisk_active; then
    endpoints="$(ast_endpoints_count)"
    online="$(ast_contacts_online_count)"
    read -r calls chans <<<"$(ast_calls_summary)"
  fi

  # header
  clear
  title_box
  printf "${B}${W}IP:${D} %s\n" "$ip"

  # status line (badges)
  local c_inst c_act c_ufw
  c_inst="$Y"; [[ "$srv_inst" == "INSTALADO" ]] && c_inst="$G"
  c_act="$R"; [[ "$srv_act" == "ATIVO" ]] && c_act="$G"
  c_ufw="$Y"; [[ "$ufw" == "ON" ]] && c_ufw="$G"

  printf "%s  %s  %s  %s  %s\n" \
    "$(badge "ASTERISK" "$srv_inst" "$c_inst")" \
    "$(badge "SERVIÇO" "$srv_act" "$c_act")" \
    "$(badge "BOOT" "$srv_en" "$Y")" \
    "$(badge "UFW" "$ufw" "$c_ufw")" \
    "$(badge "PORTAS" "5060:$on5060 RTP:$onrtp" "$Y")"

  hr

  # metrics
  printf "${B}${C}Resumo:${D} Endpoints=%s  Online=%s  Calls=%s  Channels=%s\n" \
    "${B}${endpoints}${D}" "${B}${online}${D}" "${B}${calls}${D}" "${B}${chans}${D}"

  # per-AP overview (online/offline/busy)
  echo
  printf "${B}${C}Apartamentos (overview):${D}\n"

  if ! asterisk_active; then
    warn "Asterisk OFF — overview por AP exibirá apenas contagem cadastrada."
    py <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
aps=data.get("apartamentos",[])
if not aps:
    print("  (Nenhum AP cadastrado)")
else:
    for ap in aps:
        apn=str(ap.get("numero","?")).strip()
        apnome=str(ap.get("nome","")).strip()
        mor=ap.get("moradores",[])
        label=f"AP {apn}"
        if apnome: label += f" - {apnome}"
        print(f"  - {label}: {len(mor)} morador(es)")
PY
  else
    # build overview using online/busy sets
    local online_list busy_list
    online_list="$(ast_online_ramals || true)"
    busy_list="$(ast_busy_ramals || true)"

    # pass to python via stdin blocks
    python3 - <<PY
import json, sys

cfg="${CFG}"
data=json.load(open(cfg,"r",encoding="utf-8"))

online=set([x.strip() for x in """${online_list}""".splitlines() if x.strip()])
busy=set([x.strip() for x in """${busy_list}""".splitlines() if x.strip()])

aps=data.get("apartamentos",[])
if not aps:
    print("  (Nenhum AP cadastrado)")
else:
    for ap in aps:
        apn=str(ap.get("numero","?")).strip()
        apnome=str(ap.get("nome","")).strip()
        mor=ap.get("moradores",[])
        total=len(mor)
        on=sum(1 for m in mor if str(m.get("ramal","")).strip() in online)
        bz=sum(1 for m in mor if str(m.get("ramal","")).strip() in busy)
        label=f"AP {apn}"
        if apnome: label += f" - {apnome}"

        # status simple
        if bz>0:
            st="BUSY"
        elif on>0:
            st="ONLINE"
        else:
            st="OFFLINE"

        print(f"  - {label}: {on}/{total} online | {bz} busy | {st}")
PY
  fi

  hr
  echo "${B}${W}Atalhos rápidos:${D} [R]efresh  [M]onitor  [S]tatus detalhado  [L]ogs  [Q]uit"
  echo
}

monitor_mode(){
  if ! asterisk_active; then
    bad "Asterisk não está ativo. Saindo do monitor."
    return
  fi
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

# ---------- menu ----------
menu(){
  while true; do
    dashboard
    echo "${B}1${D}) Ver status detalhado (endpoints/contacts/channels)"
    echo "${B}2${D}) Listar APs e moradores"
    echo "${B}3${D}) Adicionar AP"
    echo "${B}4${D}) Adicionar morador (ramal SIP)"
    echo "${B}5${D}) Remover morador (por ramal)"
    echo "${B}6${D}) Aplicar configs + reiniciar Asterisk (APPLY)"
    echo "${B}7${D}) Mostrar senhas/integrações (server-only)"
    echo "${B}8${D}) Editar nome PORTARIA"
    echo "${B}9${D}) Editar nome AP"
    echo "${B}10${D}) Editar nome MORADOR (por ramal)"
    echo "${B}11${D}) Resetar senha (gera nova no APPLY)"
    echo "${B}12${D}) Exportar JSON (sem senhas) p/ integração"
    echo "${B}13${D}) Restart Asterisk"
    echo "${B}14${D}) Status do serviço (systemctl)"
    echo "${B}15${D}) Logs (tail asterisk/messages)"
    echo "${B}16${D}) PJSIP Logger (on/off)"
    echo "${B}17${D}) Firewall (UFW)"
    echo "${B}18${D}) MONITOR MODE (live)"
    echo "${B}19${D}) Instalar/Atualizar Asterisk (source) + Core"
    echo "${B}0${D}) Sair"
    echo
    read -r -p "Escolha: " opt

    case "${opt,,}" in
      1|s)
        if ! asterisk_active; then bad "Asterisk não está ativo."; pause; continue; fi
        echo "---- ENDPOINTS ----"; ast_rx "pjsip show endpoints"; echo
        echo "---- CONTACTS ----";  ast_rx "pjsip show contacts"; echo
        echo "---- CHANNELS ----";  ast_rx "core show channels concise"; echo
        pause
        ;;
      2) list_condo; pause ;;
      3) add_ap; pause ;;
      4) add_morador; pause ;;
      5) rm_morador; pause ;;
      6) apply_configs; pause ;;
      7)
        echo "${B}Senhas SIP:${D} $SECRETS"
        [[ -f "$SECRETS" ]] && (sed -n '1,220p' "$SECRETS" | head -n 180) || warn "Ainda não gerado."
        echo
        echo "${B}AMI/ARI:${D} $INTEG_TXT"
        [[ -f "$INTEG_TXT" ]] && cat "$INTEG_TXT" || warn "Ainda não gerado."
        pause
        ;;
      8) edit_portaria_name; pause ;;
      9) edit_ap_name; pause ;;
      10) edit_morador_name; pause ;;
      11) reset_senha; pause ;;
      12) export_safe; pause ;;
      13) restart_asterisk; pause ;;
      14) service_status; pause ;;
      15) tail_logs; pause ;;
      16) pjsip_logger_toggle; pause ;;
      17) firewall_helper; pause ;;
      18|m) monitor_mode ;;
      19) install_now; pause ;;
      r) : ;; # refresh (loop redraw)
      q|0) exit 0 ;;
      *) warn "Opção inválida"; pause ;;
    esac
  done
}

main(){
  need_root "$@"

  # pré-checks úteis
  if ! have python3; then
    warn "python3 não encontrado. Instale com: apt install -y python3"
    pause
  fi

  ensure_cfg_exists

  # se JSON quebrado, avisar
  if ! safe_json_exists; then
    bad "Seu $CFG está inválido (JSON quebrado). Corrija antes de continuar."
    echo "Arquivo: $CFG"
    exit 1
  fi

  menu
}

main "$@"
