# Interfone Tactical (SIP) — Gerenciador de Chamadas para Condomínio

**Interfone Tactical** é um gerenciador leve para “interfone” usando **Asterisk + PJSIP**.
Você cadastra **APs** e **moradores (1 SIP por pessoa)**, escolhe a estratégia de toque por AP e o sistema
gera automaticamente os arquivos do Asterisk.

> **Privacidade:** o sistema só acompanha **presença SIP** (Online) e **estado de ligação** (Busy). Não grava áudio.

---

## Recursos

- **AP (unidade) → vários moradores (SIP por pessoa)**
- Estratégia por AP:
  - **`sequential` (cascata / hunt):** chama um por vez (prioridade + divisão de tempo)
  - **`parallel` (ringall):** chama todos ao mesmo tempo
- **Dashboard tático ao vivo**:
  - **Online** = SIP registrado (`Avail`)
  - **Busy** = em ligação (canal ativo)
- Gera configs do Asterisk:
  - `/etc/asterisk/pjsip_users.conf`
  - `/etc/asterisk/extensions_users.conf`
- **Portaria (ramal 1000)** gerada automaticamente (você pode trocar a senha no painel)

---

## O que significa a “Estratégia”?

### sequential (cascata / hunt)
O ramal do AP toca **um morador por vez**, na ordem da **prioridade** (menor = toca antes).
O tempo total do toque (`ring_seconds`) é dividido entre os moradores.

Exemplo:
- 3 moradores
- ring_seconds = 21
- cada um toca ~7s (até alguém atender)

✅ Bom quando você quer evitar tocar todo mundo ao mesmo tempo.

### parallel (ringall)
O ramal do AP toca **todos os moradores ao mesmo tempo** por `ring_seconds`.
Quem atender primeiro assume a chamada.

✅ Bom quando o objetivo é alguém atender rápido.

---

## Instalação (Debian 13)

> Recomendado usar VPS limpa/formatada.

```bash
apt update -y && apt install -y git
git clone https://github.com/ColtSeals/interfone.git
cd interfone
chmod +x setup.sh
./setup.sh

# roda o painel
interfone
