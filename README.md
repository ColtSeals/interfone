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
git clone https://github.com/SEU_USUARIO/interfone.git
cd interfone
chmod +x setup.sh
sudo ./setup.sh
interfone
