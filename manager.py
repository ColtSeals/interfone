import os
import subprocess
import json
import time
from datetime import datetime

# Cores para o Dashboard
VERDE = '\033[92m'
AMARELO = '\033[93m'
VERMELHO = '\033[91m'
AZUL = '\033[94m'
RESET = '\033[0m'
NEGRITO = '\033[1m'

PJSIP_USERS = "/etc/asterisk/pjsip_users.conf"
EXT_USERS = "/etc/asterisk/extensions_users.conf"
JSON_DB = "usuarios.json"

def get_sys_info():
    uptime = subprocess.getoutput("uptime -p")
    ram = subprocess.getoutput("free -h | grep Mem | awk '{print $3 \" / \" $2}'")
    cpu = subprocess.getoutput("top -bn1 | grep 'Cpu(s)' | awk '{print $2}'") + "%"
    status_ast = subprocess.getoutput("systemctl is-active asterisk")
    color_ast = VERDE if status_ast == "active" else VERMELHO
    return uptime, ram, cpu, f"{color_ast}{status_ast}{RESET}"

def sincronizar(dados):
    buffer_pjsip = ""
    buffer_ext = ""
    for u in dados:
        r, s, n = u['ramal'], u['senha'], u['usuario']
        buffer_pjsip += f"\n; --- USER: {n} ---\n[{r}-auth]\ntype=auth\nauth_type=userpass\nusername={r}\npassword={s}\n"
        buffer_pjsip += f"[{r}-aor]\ntype=aor\nmax_contacts=5\nremove_existing=yes\n"
        buffer_pjsip += f"[{r}]\ntype=endpoint\naors={r}-aor\nauth={r}-auth\ncontext=interfone-ctx\ndisallow=all\nallow=ulaw,alaw,gsm,opus\n"
        buffer_pjsip += f"rtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\ndirect_media=no\n"
        buffer_ext += f"exten => {r},1,Dial(PJSIP/{r},30)\n same => n,Hangup()\n"
    
    with open(PJSIP_USERS, "w") as f: f.write(buffer_pjsip)
    with open(EXT_USERS, "w") as f: f.write(buffer_ext)
    subprocess.run(["asterisk", "-x", "pjsip reload"], stdout=subprocess.DEVNULL)
    subprocess.run(["asterisk", "-x", "dialplan reload"], stdout=subprocess.DEVNULL)

def header():
    os.system('clear')
    uptime, ram, cpu, ast = get_sys_info()
    print(f"{AZUL}╔════════════════════════════════════════════════════════════════╗{RESET}")
    print(f"{AZUL}║{NEGRITO}          PAINEL OPERACIONAL - INTERFONE VOIP PRIVADO         {RESET}{AZUL}║{RESET}")
    print(f"{AZUL}╠════════════════════════════════════════════════════════════════╣{RESET}")
    print(f"{AZUL}║ {RESET}STATUS: {ast}   | RAM: {ram}   | CPU: {cpu}  {AZUL}║{RESET}")
    print(f"{AZUL}║ {RESET}UPTIME: {uptime:<47} {AZUL}║{RESET}")
    print(f"{AZUL}╚════════════════════════════════════════════════════════════════╝{RESET}")

def adicionar():
    header()
    print(f"{AMARELO}[+] NOVO CADASTRO{RESET}")
    nome = input("Identificação (ex: Luanque): ").strip()
    ramal = input("Ramal (4 dígitos sugerido): ").strip()
    senha = input("Senha (Enter para aleatória): ").strip() or "".join([str(time.time())[-4:]])
    
    dados = carregar_banco()
    dados.append({"ramal": ramal, "usuario": nome, "senha": senha})
    salvar_banco(dados)
    sincronizar(dados)
    print(f"\n{VERDE}✅ USUÁRIO ATIVADO!{RESET}")
    time.sleep(2)

def listar():
    header()
    dados = carregar_banco()
    print(f"{NEGRITO}{'RAMAL':<10} | {'USUÁRIO':<20} | {'STATUS ASTERISK'}{RESET}")
    print("-" * 64)
    for u in dados:
        # Verifica no Asterisk se o ramal está online
        check = subprocess.getoutput(f"asterisk -x 'pjsip show endpoint {u['ramal']}' | grep State")
        status = f"{VERDE}Online{RESET}" if "Not in use" in check else f"{VERMELHO}Offline{RESET}"
        print(f"{u['ramal']:<10} | {u['usuario']:<20} | {status}")
    print("-" * 64)
    input("\n[Pressione Enter para Voltar]")

def carregar_banco():
    try:
        with open(JSON_DB, 'r') as f: return json.load(f)
    except: return []

def salvar_banco(dados):
    with open(JSON_DB, 'w') as f: json.dump(dados, f, indent=4)

def ver_logs():
    header()
    print(f"{AMARELO}[!] LOGS DE CONEXÃO EM TEMPO REAL (Ctrl+C para sair){RESET}\n")
    try:
        subprocess.run(["asterisk", "-rvvvvv"])
    except KeyboardInterrupt:
        pass

def menu():
    while True:
        header()
        print(f" {NEGRITO}1.{RESET} Adicionar Usuário")
        print(f" {NEGRITO}2.{RESET} Dashboard de Ramais (Status)")
        print(f" {NEGRITO}3.{RESET} Remover Usuário")
        print(f" {NEGRITO}4.{RESET} Monitorar Console (Logs)")
        print(f" {NEGRITO}5.{RESET} Sair")
        print(f"\n{AZUL}Opção:{RESET} ", end="")
        op = input()
        
        if op == '1': adicionar()
        elif op == '2': listar()
        elif op == '3':
            header()
            r = input("Ramal para Deletar: ")
            dados = [u for u in carregar_banco() if u['ramal'] != r]
            salvar_banco(dados); sincronizar(dados)
        elif op == '4': ver_logs()
        elif op == '5': break

if __name__ == "__main__":
    menu()
