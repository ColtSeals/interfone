import os
import subprocess
import json
import random
import string

PJSIP_USERS = "/etc/asterisk/pjsip_users.conf"
EXT_USERS = "/etc/asterisk/extensions_users.conf"
JSON_DB = "usuarios.json"

def limpar_tela():
    os.system('clear')

def gerar_senha(tamanho=12):
    return ''.join(random.choice(string.ascii_letters + string.digits) for i in range(tamanho))

def carregar_banco():
    if not os.path.exists(JSON_DB): return []
    try:
        with open(JSON_DB, 'r') as f: return json.load(f)
    except: return []

def salvar_banco(dados):
    with open(JSON_DB, 'w') as f: json.dump(dados, f, indent=4)

def recarregar_asterisk():
    print("\n>>> Sincronizando com Asterisk...")
    subprocess.run(["asterisk", "-x", "pjsip reload"], stdout=subprocess.DEVNULL)
    subprocess.run(["asterisk", "-x", "dialplan reload"], stdout=subprocess.DEVNULL)
    print("✅ Configurações aplicadas!")

def sincronizar(dados):
    buffer_pjsip = ""
    buffer_ext = ""
    for u in dados:
        r = u['ramal']
        s = u['senha']
        n = u['usuario']
        
        # Formato Nativo PJSIP
        buffer_pjsip += f"\n; --- {n} ---\n[{r}-auth]\ntype=auth\nauth_type=userpass\nusername={r}\npassword={s}\n"
        buffer_pjsip += f"[{r}-aor]\ntype=aor\nmax_contacts=2\nremove_existing=yes\n"
        buffer_pjsip += f"[{r}]\ntype=endpoint\naors={r}-aor\nauth={r}-auth\ncontext=interfone-ctx\ndisallow=all\nallow=ulaw,alaw,gsm,opus\n"
        buffer_pjsip += f"rtp_symmetric=yes\nforce_rport=yes\nrewrite_contact=yes\ndirect_media=no\n"
        
        # Dialplan
        buffer_ext += f"\nexten => {r},1,Dial(PJSIP/{r},30)\n same => n,Hangup()\n"
    
    with open(PJSIP_USERS, "w") as f: f.write(buffer_pjsip)
    with open(EXT_USERS, "w") as f: f.write(buffer_ext)
    recarregar_asterisk()

def adicionar():
    limpar_tela()
    print("=== NOVO USUÁRIO ===")
    dados = carregar_banco()
    nome = input("Nome (ex: portaria): ").strip()
    ramal = input("Ramal (ex: 1001): ").strip()
    if not ramal: return
    for u in dados:
        if u['ramal'] == ramal:
            print("❌ Ramal já existe!"); input(); return
    
    senha_in = input("Senha (Vazio para auto): ").strip()
    senha = senha_in if senha_in else gerar_senha()
    
    dados.append({"ramal": ramal, "usuario": nome, "senha": senha})
    salvar_banco(dados); sincronizar(dados)
    print(f"\n✅ Criado: Ramal {ramal} | Senha {senha}")
    input("\nEnter para voltar...")

def listar():
    limpar_tela()
    dados = carregar_banco()
    print(f"{'RAMAL':<10} | {'NOME':<20} | {'SENHA'}")
    print("-" * 50)
    for u in dados: print(f"{u['ramal']:<10} | {u['usuario']:<20} | {u['senha']}")
    input("\nEnter para voltar...")

def remover():
    limpar_tela()
    dados = carregar_banco()
    ramal = input("Ramal para DELETAR: ").strip()
    nova = [u for u in dados if u['ramal'] != ramal]
    if len(nova) != len(dados):
        salvar_banco(nova); sincronizar(nova)
        print("✅ Removido!")
    else: print("❌ Não encontrado.")
    input("\nEnter para voltar...")

def menu():
    while True:
        limpar_tela()
        print("=== INTERFONE LUANQUE (V2) ===")
        print("1. Adicionar / 2. Listar / 3. Remover / 4. Sair")
        op = input("Escolha: ")
        if op == '1': adicionar()
        elif op == '2': listar()
        elif op == '3': remover()
        elif op == '4': break

if __name__ == "__main__":
    menu()
