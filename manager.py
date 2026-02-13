import os, subprocess, json, time, random, string

# Cores Operacionais Premium
V, A, R, AZ, C, M = '\033[92m', '\033[93m', '\033[91m', '\033[94m', '\033[96m', '\033[95m'
RE, B = '\033[0m', '\033[1m'

P_USERS = "/etc/asterisk/pjsip_users.conf"
E_USERS = "/etc/asterisk/extensions_users.conf"
DB_FILE = "condominio.json"

def get_sys():
    upt = subprocess.getoutput("uptime -p").replace("up ", "")
    ram = subprocess.getoutput("free -h | grep Mem | awk '{print $3 \"/\" $2}'")
    ast = f"{V}ONLINE{RE}" if "active" in subprocess.getoutput("systemctl is-active asterisk") else f"{R}OFFLINE{RE}"
    return upt, ram, ast

def carregar_db():
    if not os.path.exists(DB_FILE): return []
    try:
        with open(DB_FILE, 'r') as f: return json.load(f)
    except: return []

def salvar_db(dados):
    with open(DB_FILE, 'w') as f: json.dump(dados, f, indent=4)
    os.chmod(DB_FILE, 0o777)

def sincronizar(dados):
    p, e = [], []
    for u in dados:
        r, s, n = u['ramal'], u['senha'], u['nome']
        bl, ap = u['bloco'], u['ap']
        
        # Identificação Premium (Aparece no visor do telefone)
        caller_id = f"\"{n} (Bl{bl}-Ap{ap})\" <{r}>"
        
        # Configuração PJSIP Unificada
        p.append(f"[{r}]\ntype=auth\nauth_type=userpass\nusername={r}\npassword={s}")
        p.append(f"[{r}]\ntype=aor\nmax_contacts=5\nremove_existing=yes\nqualify_frequency=30")
        p.append(f"[{r}]\ntype=endpoint\ncontext=interfone-ctx\ndisallow=all\nallow=ulaw,alaw,gsm,opus\nauth={r}\naors={r}\ncallerid={caller_id}\ntransport=transport-udp\nrtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\ndirect_media=no\n")
        
        # Dialplan com Log de Chamada
        e.append(f"exten => {r},1,NoOp(Chamada para {n})\n same => n,Dial(PJSIP/{r},30)\n same => n,Hangup()")
    
    with open(P_USERS, "w") as f: f.write("\n".join(p))
    with open(E_USERS, "w") as f: f.write("\n".join(e))
    subprocess.run(["asterisk", "-x", "core reload"], stdout=subprocess.DEVNULL)

def monitor_brutal():
    os.system('clear')
    print(f"{M}{B}--- MONITORAMENTO DE TRAFEGO EM TEMPO REAL ---{RE}\n")
    log = "/var/log/asterisk/messages"
    proc = subprocess.Popen(["tail", "-f", log], stdout=subprocess.PIPE, text=True)
    try:
        for l in proc.stdout:
            ts = time.strftime("%H:%M:%S")
            if "Registered" in l: print(f"[{ts}] {V}CONECTADO:{RE} Um morador acabou de entrar.")
            elif "Unauthorized" in l: print(f"[{ts}] {R}ALERTA:{RE} Tentativa com senha errada.")
            elif "Dial" in l: print(f"[{ts}] {AZ}CHAMADA:{RE} Existe uma ligação em curso.")
    except KeyboardInterrupt: proc.terminate()

def header():
    os.system('clear')
    upt, ram, ast = get_sys()
    print(f"{C}╔" + "═"*66 + "╗")
    print(f"║ {B}SISTEMA DE INTERFONIA INTELIGENTE v6.0{RE}{C} {" "*(25)} ║")
    print(f"╠" + "═"*66 + "╣")
    print(f"║ {RE}AST: {ast} | RAM: {ram:<11} | UPT: {upt:<16} {C}║")
    print(f"╚" + "═"*66 + "╝{RE}")

def menu():
    while True:
        header()
        print(f" 1. {B}Cadastrar Morador{RE} (Premium)")
        print(f" 2. {B}Lista de Unidades{RE} (Dashboard)")
        print(f" 3. {B}Remover Cadastro{RE}")
        print(f" 4. {B}Console Asterisk{RE}")
        print(f" 5. {M}Monitor Brutal{RE}")
        print(f" 6. Sair")
        
        op = input(f"\n{C}Seleção:{RE} ")
        
        if op == '1':
            header()
            nome = input("Nome do Morador: ")
            bloco = input("Bloco/Torre: ")
            ap = input("Apartamento: ")
            ramal = input("Ramal (Ex: 101): ")
            senha = input("Senha (Vazio p/ 'coltseals'): ") or "coltseals"
            
            db = carregar_db()
            db.append({"nome": nome, "bloco": bloco, "ap": ap, "ramal": ramal, "senha": senha})
            salvar_db(db); sincronizar(db)
            print(f"\n{V}✔ Morador Ativado!{RE}"); time.sleep(1)
            
        elif op == '2':
            header()
            db = carregar_db()
            print(f"{B}{'RAMAL':<7} | {'LOCAL':<12} | {'MORADOR':<20} | {'STATUS'}{RE}")
            print("-" * 64)
            for u in db:
                st_raw = subprocess.getoutput(f"asterisk -x 'pjsip show endpoint {u['ramal']}'")
                st = f"{V}ON{RE}" if "Not in use" in st_raw else f"{R}OFF{RE}"
                loc = f"Bl {u['bloco']} Ap {u['ap']}"
                print(f"{u['ramal']:<7} | {loc:<12} | {u['nome']:<20} | {st}")
            input(f"\n{A}[ Enter para Voltar ]{RE}")

        elif op == '3':
            r = input("Ramal para remover: ")
            db = [u for u in carregar_db() if u['ramal'] != r]
            salvar_db(db); sincronizar(db)
            
        elif op == '4': subprocess.run(["asterisk", "-rvvvvv"])
        elif op == '5': monitor_brutal()
        elif op == '6': break

if __name__ == "__main__": menu()
