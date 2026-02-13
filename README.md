# interfone


apt update -y && apt install git -y && rm -rf interfone && git clone https://github.com/ColtSeals/interfone.git && cd interfone && chmod +x setup.sh && ./setup.sh && python3 manager.py


apt update -y && apt install git -y
rm -rf interfone
git clone https://github.com/ColtSeals/interfone.git
cd interfone
chmod +x setup.sh
./setup.sh
interfone





# Interfone Tactical (SIP) — Gestor Inteligente de Interfonia para Condomínios

O **Interfone Tactical** é um gerenciador leve de chamadas SIP para condomínios usando **Asterisk + PJSIP**.  
Ele suporta **vários moradores por apartamento** (um **SIP por pessoa**), estratégias de chamada por unidade e um **painel tático ao vivo** mostrando: **Online / Ocupado / Atividade de chamadas**.

> **Privacidade em primeiro lugar:** o sistema acompanha apenas **presença SIP** (registro) e **estado de ligação**. Não captura áudio, não grava, não lê conteúdo.

---

## ✅ Recursos

- **Apartamento (unidade) → vários moradores (SIP por pessoa)**
- **Estratégia de chamada por AP:**
  - `sequential` (**cascata / hunt**): chama um morador por vez (ordem por prioridade + divisão do tempo)
  - `parallel` (**ringall**): chama todos os moradores ao mesmo tempo
- **Dashboard tático ao vivo**
  - **Online** = contato registrado (`Avail` no PJSIP)
  - **Ocupado (Busy)** = SIP em ligação (canal ativo)
- **Geração automática de configurações do Asterisk**
  - `/etc/asterisk/pjsip_users.conf`
  - `/etc/asterisk/extensions_users.conf`
- **Placeholder para fallback WhatsApp (Evolution API)**
  - A portaria vê apenas o **AP/EXT** — o número do WhatsApp do morador fica oculto no servidor (pode ser criptografado)

---

## 🧠 Como funciona (resumo)

### 1) Discagem por apartamento (EXT)
A **portaria disca o EXT do AP** (ex.: `101`).  
O Asterisk usa o dialplan gerado para chamar os moradores conforme a estratégia do AP.

### 2) Estratégias

#### `sequential` (cascata)
- Liga **um por vez** na ordem da **prioridade** (menor prioridade toca primeiro)
- O tempo total (`ring_seconds`) é dividido entre os moradores
- Se alguém atender → conecta e encerra o restante

**Quando usar:** quando você quer ordem e evitar que todos toquem ao mesmo tempo.

#### `parallel` (ringall)
- Liga **todos ao mesmo tempo** durante `ring_seconds`
- Se alguém atender → conecta e encerra os demais

**Quando usar:** quando você quer maior chance de resposta rápida.

### 3) Status do painel
- **Online:** vem do `pjsip show contacts` (status `Avail`)
- **Busy:** vem do `core show channels concise` (SIP aparece em canal ativo)

---

## 🚀 Instalação (Debian 13)

### Instalar a partir do GitHub
```bash
apt update -y && apt install git -y
rm -rf interfone
git clone https://github.com/ColtSeals/interfone.git
cd interfone
chmod +x setup.sh
./setup.sh
interfone
