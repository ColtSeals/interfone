import os
import subprocess
import json
import random
import string

# Caminhos dos arquivos
PJSIP_USERS = "/etc/asterisk/pjsip_users.conf"
EXT_USERS = "/etc/asterisk/extensions_users.conf"
JSON_DB = "usuarios.json"

def gerar_senha(tamanho=12):
    chars = string.ascii_letters + string.digits
    return ''.join(random.choice(chars) for i in range(tamanho))

def recarregar_asterisk():
    print("\n>>> Recarregando Asterisk...")
    try:
        subprocess.run(["asterisk", "-x", "pjsip reload"], check=True)
        subprocess.run(["asterisk", "-x", "dialplan reload"], check=True)
        print(">>> Sucesso! Configurações aplicadas.")
    except Exception as e:
        print(f"Erro ao recarregar: {e}")

def salvar_json(usuario, senha, ramal):
    dados = []
    # Lê dados existentes se houver
    if os.path.exists(JSON_DB):
        try:
            with open(JSON_DB, 'r') as f:
                dados = json.load(f)
        except:
            dados = []
    
    # Adiciona novo
    dados.append({
        "ramal": ramal,
        "usuario": usuario,
        "senha": senha,
        "host": "IP_DA_VPS" 
    })
    
    with open(JSON_DB, 'w') as f:
        json.dump(dados, f, indent=4)
    print(f">>> Dados salvos em {JSON_DB}")

def adicionar_usuario():
    print("\n--- Adicionar Novo Usuário ---")
    nome = input("Nome do Usuário (sem espaços, ex: portaria): ").strip()
    ramal = input("Número do Ramal (ex: 1001): ").strip()
    
    # === AQUI ESTÁ A MUDANÇA PARA SENHA MANUAL ===
    senha_input = input("Digite a Senha SIP (Deixe vazio para gerar automática): ").strip()
    
    if senha_input:
        senha = senha_input
    else:
        senha = gerar_senha()
        print(f"(Senha gerada automaticamente: {senha})")
    
    # 1. Adiciona no PJSIP (Credenciais)
    config_pjsip = f"\n; Usuario: {nome}\n[{ramal}](template-ramal)\ninbound_auth/username={ramal}\ninbound_auth/password={senha}\n"
    
    try:
        with open(PJSIP_USERS, "a") as f:
            f.write(config_pjsip)
            
        # 2. Adiciona no Extensions (Lógica de discagem)
        config_ext = f"\n; Discagem para {nome}\nexten => {ramal},1,Dial(PJSIP/{ramal},30)\n same => n,Hangup()\n"
        
        with open(EXT_USERS, "a") as f:
            f.write(config_ext)
            
        print(f"\n[SUCESSO] Usuário '{nome}' criado.")
        print(f"Ramal: {ramal}")
        print(f"Senha: {senha}")
        
        salvar_json(nome, senha, ramal)
        recarregar_asterisk()
        
    except FileNotFoundError:
        print("\n[ERRO CRÍTICO] Arquivos de configuração não encontrados.")
        print("Rode o ./setup.sh primeiro!")

def listar_usuarios():
    if os.path.exists(JSON_DB):
        with open(JSON_DB, 'r') as f:
            print(f.read())
    else:
        print("Nenhum usuário no banco JSON ainda.")

def menu():
    while True:
        print("\n=== SISTEMA DE INTERFONE LUANQUE ===")
        print("1. Adicionar Usuário")
        print("2. Listar Usuários (JSON)")
        print("3. Sair")
        opcao = input("Escolha: ")
        
        if opcao == '1':
            adicionar_usuario()
        elif opcao == '2':
            listar_usuarios()
        elif opcao == '3':
            break
        else:
            print("Opção inválida")

if __name__ == "__main__":
    menu()
