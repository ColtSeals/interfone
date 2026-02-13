#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/interfone"
CFG="$APP_DIR/condo.json"
SECRETS="/root/interfone-secrets.json"
INTEG_TXT="/root/interfone-integrations.txt"
INSTALL_LOG="/root/interfone-install.log"
ASTERISK_LOG="/var/log/asterisk/messages"

USE_COLOR="${USE_COLOR:-1}"
REFRESH_SLEEP="${REFRESH_SLEEP:-2}"

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

safe_json_exists(){
  [[ -f "$CFG" ]] || return 1
  have python3 || return 1
  python3 - <<PY >/dev/null 2>&1
import json
json.load(open("${CFG}","r",encoding="utf-8"))
PY
}

ast_rx(){ asterisk -rx "$1" 2>/dev/null || true; }

# parsers mais robustos (evita "Endpoints=0" bug)
parse_objects_found(){
  grep -oE 'Objects found: *[0-9]+' | tail -n1 | grep -oE '[0-9]+' || echo "0"
}

ast_endpoints_count(){
  ast_rx "pjsip show endpoints" | tr -d '\r' | parse_objects_found
}

ast_contacts_online_count(){
  local out
  out="$(ast_rx "pjsip show contacts" | tr -d '\r')"
  if echo "$out" | grep -qi "No objects found"; then
    echo "0"
  else
    echo "$out" | parse_objects_found
  fi
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
      sub(/-aor\/.*/,"",x)
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

py(){ python3 - "$@"; }

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
    print("OK: morador adicionado.")
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

# ✅ DEFINIR SENHA MANUALMENTE
# Recomendação: use só caracteres seguros (sem espaço/aspas):
# letras, números e . _ - @ : + = #
validate_pass(){
  local p="$1"
  [[ ${#p} -ge 6 && ${#p} -le 64 ]] || return 1
  [[ "$p" =~ ^[A-Za-z0-9._@:+#=\-]+$ ]] || return 1
  return 0
}

set_password(){
  ensure_cfg_exists
  read -r -p "Ramal (1000 portaria ou morador ex: 10101): " ramal
  [[ -z "${ramal// }" ]] && { bad "Ramal inválido"; return; }

  local p1 p2
  echo "Senha (6-64 chars; permitido: A-Z a-z 0-9 . _ - @ : + = #)"
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

# portaria
p=data.get("portaria",{})
if str(p.get("ramal","")).strip()==ramal:
    p["senha"]=senha
    data["portaria"]=p
    json.dump(data, open(cfg,"w",encoding="utf-8"), indent=2, ensure_ascii=False)
    print("OK: senha da PORTARIA definida. Rode APPLY.")
    raise SystemExit(0)

# moradores
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

apply_configs(){
  [[ -x ./install.sh ]] || { bad "install.sh não encontrado no diretório atual."; return; }
  ok "Aplicando configs + reiniciando Asterisk..."
  bash ./install.sh --apply-only
  ok "APPLY concluído. (Agora o $SECRETS deve existir)"
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
  asterisk_active || { bad "Asterisk não está ativo."; return; }
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
  have ufw || { warn "ufw não instalado."; return; }
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

explain_integrations(){
  echo "${B}AMI${D} (TCP 5038, localhost-only): eventos e comandos (melhor p/ status/online/busy)."
  echo "  - Laravel no mesmo servidor conecta em 127.0.0.1:5038"
  echo
  echo "${B}ARI${D} (HTTP 8088, localhost-only): API REST (controle/consulta)."
  echo "  - URL = endpoint HTTP do ARI:"
  echo "    http://127.0.0.1:8088/ari/"
  echo
  echo "Teste (na VPS):"
  echo "  curl -u ari:SENHA http://127.0.0.1:8088/ari/asterisk/info"
  echo
  warn "Dica: manter localhost-only é o mais seguro. Se quiser acesso externo depois, a gente faz via túnel SSH."
}

dashboard(){
  ensure_cfg_exists

  local ip srv_inst srv_act srv_en ufw on5060 onrtp
  ip="$(get_public_ip)"

  srv_inst="$(asterisk_installed && echo "INSTALADO" || echo "NÃO")"
  srv_act="$(asterisk_active && echo "ATIVO" || echo "OFF")"
  srv_en="$(asterisk_enabled && echo "ENABLED" || echo "DISABLED")"

  ufw="$(ufw_active && echo "ON" || echo "OFF")"
  on5060="$(ufw_has_rule "5060/udp" && echo "OK" || echo "X")"
  onrtp="$(ufw_has_rule "10000:20000/udp" && echo "OK" || echo "X")"

  local endpoints="—" online="—" calls="—" chans="—"
  if asterisk_active; then
    endpoints="$(ast_endpoints_count)"
    online="$(ast_contacts_online_count)"
    read -r calls chans <<<"$(ast_calls_summary)"
  fi

  local secrets_state
  secrets_state="$([[ -f "$SECRETS" ]] && echo "GERADO" || echo "NÃO")"

  clear
  title_box
  printf "${B}${W}IP:${D} %s\n" "$ip"
  echo "[ASTERISK: $srv_inst]  [SERVIÇO: $srv_act]  [BOOT: $srv_en]  [UFW: $ufw]  [PORTAS: 5060:$on5060 RTP:$onrtp]  [SECRETS: $secrets_state]"
  hr
  printf "${B}${C}Resumo:${D} Endpoints=%s  Online=%s  Calls=%s  Channels=%s\n" \
    "${B}${endpoints}${D}" "${B}${online}${D}" "${B}${calls}${D}" "${B}${chans}${D}"

  echo
  printf "${B}${C}Apartamentos (overview):${D}\n"

  if ! asterisk_active; then
    warn "Asterisk OFF — overview por AP exibirá apenas cadastro."
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
    local online_list busy_list
    online_list="$(ast_online_ramals || true)"
    busy_list="$(ast_busy_ramals || true)"

    python3 - <<PY
import json
data=json.load(open("${CFG}","r",encoding="utf-8"))
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
        st = "BUSY" if bz>0 else ("ONLINE" if on>0 else "OFFLINE")
        print(f"  - {label}: {on}/{total} online | {bz} busy | {st}")
PY
  fi

  hr
  echo "${B}${W}Atalhos rápidos:${D} [R]efresh  [M]onitor  [S]tatus  [L]ogs  [Q]uit"
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

menu(){
  while true; do
    dashboard
    echo "1) Ver status detalhado (endpoints/contacts/channels)"
    echo "2) Listar APs e moradores"
    echo "3) Adicionar AP"
    echo "4) Adicionar morador (ramal SIP)"
    echo "5) Remover morador (por ramal)"
    echo "6) Aplicar configs + reiniciar Asterisk (APPLY)"
    echo "7) Senhas/Integrações (explicação AMI/ARI + testes)"
    echo "8) Editar nome PORTARIA"
    echo "9) Editar nome AP"
    echo "10) Editar nome MORADOR (por ramal)"
    echo "11) Definir senha manualmente (por ramal)"
    echo "12) Resetar senha (regenera no APPLY)"
    echo "13) Exportar JSON (sem senhas) p/ integração"
    echo "14) Restart Asterisk"
    echo "15) Status do serviço (systemctl)"
    echo "16) Logs (tail asterisk/messages)"
    echo "17) PJSIP Logger (on/off)"
    echo "18) Firewall (UFW)"
    echo "19) MONITOR MODE (live)"
    echo "20) Instalar/Atualizar Asterisk (source) + Core"
    echo "0) Sair"
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
        if [[ -f "$SECRETS" ]]; then
          sed -n '1,240p' "$SECRETS" | head -n 220
        else
          warn "Ainda não gerado. Rode a opção 6 (APPLY) para gerar pjsip.conf/extensions.conf e salvar senhas."
        fi
        echo
        echo "${B}AMI/ARI:${D} $INTEG_TXT"
        [[ -f "$INTEG_TXT" ]] && cat "$INTEG_TXT" || warn "Ainda não gerado."
        echo
        explain_integrations
        pause
        ;;
      8) edit_portaria_name; pause ;;
      9) edit_ap_name; pause ;;
      10) edit_morador_name; pause ;;
      11) set_password; pause ;;
      12) reset_senha; pause ;;
      13) export_safe; pause ;;
      14) restart_asterisk; pause ;;
      15) service_status; pause ;;
      16) tail_logs; pause ;;
      17) pjsip_logger_toggle; pause ;;
      18) firewall_helper; pause ;;
      19|m) monitor_mode ;;
      20) install_now; pause ;;
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

  menu
}

main "$@"
