Atalhos rápidos

R: atualiza o painel (refresh)

M: entra no Monitor Mode ao vivo

P: abre o Painel de ramais (tabela 🟢/🔴/🟡)

B: busca por ramal/nome/AP

H: health check (diagnóstico)

Q: sai

1) Ver status detalhado (endpoints/contacts/channels)

Mostra três visões do Asterisk:

Endpoints: ramais existentes no Asterisk

Contacts: ramais registrados (online/offline)

Channels: chamadas em andamento (busy)

Use quando: quer ver “o que o Asterisk está enxergando” de verdade.

2) Listar APs e moradores

Mostra o cadastro do condomínio (o condo.json):

Portaria (1000)

APs

Moradores por AP (ramal/nome)

Use quando: conferir cadastro e organização.

3) Painel de ramais (tabela 🟢/🔴/🟡)

Mostra uma tabela única com:

status 🟢/🔴/🟡

tipo (PORTARIA/MORADOR)

AP

ramal

nome

Use quando: “visão operacional rápida” do prédio inteiro.

4) Buscar (ramal/nome/ap)

Busca texto no cadastro:

“101”

“João”

“ap rodrigues”

“10101”

E mostra resultado com status do ramal.

Use quando: você tem muitos APs e quer achar rápido.

5) Adicionar AP

Cria um apartamento (unidade) novo no cadastro.

Use quando: entrou um AP novo no sistema.

6) Wizard AP + N moradores (com senha)

Cria:

AP

N moradores automaticamente (ramais 01..N)

senha única pra todos ou senha diferente por morador

Use quando: quer cadastrar um AP inteiro de uma vez.

7) Adicionar morador (ramal + senha na hora)

Cadastro individual do morador com:

sugestão automática do próximo ramal

nome do morador

senha definida na hora (ou auto-gerar)

pergunta se quer APPLY logo após

Use quando: chega novo morador / novo usuário.

8) Remover morador (por ramal)

Remove um ramal específico do cadastro.

Use quando: morador saiu / ramal foi desativado.

9) Editar nome PORTARIA

Troca o nome exibido da portaria (CallerID).

Use quando: quer aparecer “Portaria Torre A” etc.

10) Editar nome AP

Define/alterar o nome descritivo do AP:
ex.: “Cobertura”, “Família Rodrigues”.

Use quando: quer organização no painel/busca.

11) Editar nome MORADOR (por ramal)

Renomeia o morador sem mexer no ramal.

Use quando: quer deixar padronizado.

12) Definir senha manualmente (por ramal)

Define senha de qualquer ramal:

portaria (1000)

morador (10101 etc)

Use quando: quer controlar senha sem auto-geração.

13) Resetar senha (regenera no APPLY)

Apaga a senha daquele ramal no cadastro e deixa para o APPLY gerar uma nova automaticamente.

Use quando: “esqueci a senha” ou quer forçar troca.

14) APPLY (gerar configs + reiniciar Asterisk)

É o botão mais importante:

gera configs do Asterisk (pjsip + dialplan)

reinicia o serviço

atualiza secrets

Use quando: sempre que cadastrar/editar/remover algo.

15) Senhas/Integrações (AMI/ARI + testes)

Mostra:

arquivo de secrets (server-only)

credenciais AMI/ARI (server-only)

explicação e comando de teste ARI

Use quando: vai integrar com Laravel depois ou auditar acesso.

16) Restart Asterisk

Reinicia o serviço.

Use quando: travou, ou após ajustes manuais.

17) Status do serviço (systemctl)

Mostra status detalhado do systemd.

Use quando: quer ver erro de boot, permissões, crash etc.

18) Logs (tail asterisk/messages)

Mostra logs recentes do Asterisk.

Use quando: ramal não registra, áudio falha, etc.

19) PJSIP Logger (on/off)

Liga/desliga debug de SIP (muito verboso).

Use quando: depurar registro SIP, autenticação, NAT.

20) Firewall (UFW)

Ativa/desativa UFW e cria regras:

OpenSSH

5060/udp

10000–20000/udp

Use quando: quer “fechar” e liberar só o necessário.

21) Health Check

Resumo de saúde:

asterisk instalado?

service ativo?

portas ok?

configs existem?

contagens

Use quando: “não sei o que tá faltando”.

22) MONITOR MODE (live)

Tela ao vivo atualizando:

contacts (online/offline)

channels (ligações)

Use quando: operação “ao vivo” na portaria.

23) Instalar/Atualizar Asterisk (source) + Core

Compila/instala/atualiza o core novamente.

Use quando: primeira instalação ou upgrade.

Sobre “discar o AP e chamar todos”

✅ Sim, e você ainda pode ter dois modos, se você quiser:

RingAll (todos ao mesmo tempo) — o padrão

Cascata (um por vez) — se você preferir

Se você me disser qual modo você quer como padrão (ringall ou cascata), eu ajusto o dialplan no install.sh pra isso ficar configurável por AP depois.










# Interfone Tactical (SIP) — Gerenciador de Chamadas de Condomínio

O **Interfone Tactical** é um gerenciador leve de chamadas SIP para condomínios usando **Asterisk + PJSIP**.
Ele permite **vários moradores por AP** (um SIP por pessoa), define **estratégia de chamada por AP**,
e oferece um **dashboard tático ao vivo** (Online / Busy).

> Privacidade: acompanha apenas presença SIP e estado de chamada (não grava conteúdo).

---

## Recursos

- **AP (unidade) → vários moradores (SIP por pessoa)**
- Estratégia por AP:
  - `sequential` (cascata / hunt): chama um por um (prioridade por ordem)
  - `parallel` (ringall): chama todos ao mesmo tempo
- **Dashboard tático ao vivo**
  - Online = SIP registrado (`Avail` em `pjsip show contacts`)
  - Busy = ramal com canal ativo (em ligação)
- Gera configs automaticamente:
  - `/etc/asterisk/pjsip_users.conf`
  - `/etc/asterisk/extensions_users.conf`
- Base pronta (criada pelo setup):
  - `/etc/asterisk/pjsip.conf` (inclui `pjsip_users.conf`)
  - `/etc/asterisk/extensions.conf` (inclui `extensions_users.conf` no contexto `interfone-ctx`)

---

## Como funciona a Estratégia

### `sequential` (cascata)
Ao ligar para o **ramal do AP** (ex.: `101`), ele chama os moradores **um por um**, na ordem cadastrada.
O tempo total (ex.: 20s) é dividido entre eles.

### `parallel` (ringall)
Ao ligar para o **ramal do AP** (ex.: `101`), ele chama **todos ao mesmo tempo**.
Quem atender primeiro assume a ligação.

---

## Instalação (Debian 13)

```bash
apt update -y && apt install -y git
rm -rf interfone
git clone https://github.com/ColtSeals/interfone.git interfone
cd interfone
chmod +x install.sh menu.sh
sudo bash install.sh
sudo bash menu.sh
