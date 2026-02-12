import os
import subprocess
import json
import random
import string
import urllib.request

# === CONFIGURAÇÕES ===
PJSIP_USERS = "/etc/asterisk/pjsip_users.conf"
EXT_USERS = "/etc/asterisk/extensions_users.conf"
JSON_DB = "usuarios.json"

# === FUNÇÕES AUXILIARES ===

def limpar_tela():
    os.system('cls' if os.name == 'nt' else 'clear')

def obter_ip_publico():
    try:
        return urllib.request.urlopen('https://api.ipify.org').read().decode('utf8')
    except:
        return "SEU_IP_VPS"

def gerar_senha(tamanho=12):
    chars = string.ascii_letters + string.digits
    return ''.join(random.choice(chars) for i in range(tamanho))

def carregar_banco():
    """Lê o JSON e retorna uma lista de dicionários. Se der erro, retorna lista vazia."""
    if not os.path.exists(JSON_DB):
        return []
    try:
        with open(JSON_DB, 'r') as f:
            return json.load(f)
    except:
        return []

def salvar_banco(dados):
    """Salva a lista no arquivo JSON."""
    with open(JSON_DB, 'w') as f:
        json.dump(dados, f, indent=4)

def recarregar_asterisk():
    print("\n>>> Aplicando configurações no Asterisk...")
    try:
        subprocess.run(["asterisk", "-x", "pjsip reload"], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["asterisk", "-x", "dialplan reload"], check=True, stdout=subprocess.DEVNULL)
        print("✅ Asterisk recarregado com sucesso!")
    except Exception as e:
        print(f"⚠️ Erro ao recarregar Asterisk (Ele está rodando?): {e}")

def sincronizar_arquivos(dados):
    """
    ESSA É A MÁGICA:
    Lê o banco de dados (JSON) e REESCREVE os arquivos .conf do zero.
    Isso garante que o Asterisk esteja sempre idêntico ao JSON.
    """
    print(">>> Sincronizando arquivos de configuração...")
    
    # 1. Reescreve PJSIP_USERS
    buffer_pjsip = ""
    buffer_ext = ""
    
    for u in dados:
        ramal = u['ramal']
        usuario = u['usuario']
        senha = u['senha']
        
        # Config do PJSIP
        buffer_pjsip += f"\n; Usuario: {usuario}\n"
        buffer_pjsip += f"[{ramal}](template-ramal)\n"
        buffer_pjsip += f"inbound_auth/username={ramal}\n"
        buffer_pjsip += f"inbound_auth/password={senha}\n"
        
        # Config do Dialplan (Extensions)
        buffer_ext += f"\n; Discagem para {usuario}\n"
        buffer_ext += f"exten => {ramal},1,Dial(PJSIP/{ramal},30)\n"
        buffer_ext += f" same => n,Hangup()\n"
    
    # Grava no disco (Modo 'w' sobrescreve tudo)
    try:
        with open(PJSIP_USERS, "w") as f:
            f.write(buffer_pjsip)
        
        with open(EXT_USERS, "w") as f:
            f.write(buffer_ext)
            
        recarregar_asterisk()
        
    except FileNotFoundError:
        print("❌ ERRO: Arquivos de config não encontrados em /etc/asterisk/")
        print("Execute o setup.sh novamente.")

# === FUNÇÕES DO MENU ===

def adicionar_usuario():
    limpar_tela()
    print("=== ADICIONAR NOVO USUÁRIO ===")
    dados = carregar_banco()
    
    nome = input("Nome do Usuário (ex: portaria): ").strip()
    if not nome:
        print("❌ Nome não pode ser vazio.")
        return

    ramal = input("Número do Ramal (ex: 1001): ").strip()
    if not ramal.isdigit():
        print("❌ Ramal deve conter apenas números.")
        return
        
    # Verifica duplicidade
    for u in dados:
        if u['ramal'] == ramal:
            print(f"❌ O ramal {ramal} já existe para o usuário '{u['usuario']}'.")
            return

    senha = input("Senha SIP (Enter para gerar automática): ").strip()
    if not senha:
        senha = gerar_senha()
    
    novo_user = {
        "ramal": ramal,
        "usuario": nome,
        "senha": senha,
        "host": obter_ip_publico()
    }
    
    dados.append(novo_user)
    salvar_banco(dados)
    sincronizar_arquivos(dados)
    
    print(f"\n✅ Usuário criado!")
    print(f"Ramal: {ramal} | Senha: {senha}")
    input("\nPressione Enter para voltar...")

def listar_usuarios():
    limpar_tela()
    dados = carregar_banco()
    ip = obter_ip_publico()
    
    print(f"=== LISTA DE USUÁRIOS (Host: {ip}) ===")
    print("-" * 65)
    print(f"{'RAMAL':<10} | {'USUÁRIO':<20} | {'SENHA SIP':<20}")
    print("-" * 65)
    
    if not dados:
        print(" Nenhum usuário cadastrado.")
    
    for u in dados:
        print(f"{u['ramal']:<10} | {u['usuario']:<20} | {u['senha']:<20}")
        
    print("-" * 65)
    input("\nPressione Enter para voltar...")

def remover_usuario():
    limpar_tela()
    print("=== REMOVER USUÁRIO ===")
    dados = carregar_banco()
    
    if not dados:
        print("Não há usuários para remover.")
        input("Enter para voltar...")
        return

    # Mostra lista rápida
    print(f"{'RAMAL':<10} | {'USUÁRIO'}")
    print("-" * 30)
    for u in dados:
        print(f"{u['ramal']:<10} | {u['usuario']}")
    print("-" * 30)
    
    ramal_alvo = input("\nDigite o RAMAL que deseja apagar: ").strip()
    
    # Filtra a lista, mantendo apenas quem NÃO for o alvo
    nova_lista = [u for u in dados if u['ramal'] != ramal_alvo]
    
    if len(nova_lista) == len(dados):
        print("❌ Ramal não encontrado.")
    else:
        salvar_banco(nova_lista)
        sincronizar_arquivos(nova_lista)
        print(f"✅ Usuário do ramal {ramal_alvo} removido e Asterisk atualizado.")
    
    input("\nPressione Enter para voltar...")

def menu():
    while True:
        limpar_tela()
        print("╔══════════════════════════════════╗")
        print("║   GERENCIADOR INTERFONE VOIP     ║")
        print("╠══════════════════════════════════╣")
        print("║ 1. Adicionar Usuário             ║")
        print("║ 2. Listar Usuários (Tabela)      ║")
        print("║ 3. Remover Usuário               ║")
        print("║ 4. Sair                          ║")
        print("╚══════════════════════════════════╝")
        
        opcao = input("Escolha: ")
        
        if opcao == '1':
            adicionar_usuario()
        elif opcao == '2':
            listar_usuarios()
        elif opcao == '3':
            remover_usuario()
        elif opcao == '4':
            print("Saindo...")
            break

if __name__ == "__main__":
    # Garante que os arquivos existem antes de começar
    if not os.path.exists(PJSIP_USERS):
        print("⚠️  AVISO: Rode o ./setup.sh primeiro para criar a estrutura!")
        exit()
        
    menu()
