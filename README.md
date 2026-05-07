# Cloudflare Tunnel Setup

Scripts para criar e manter um tunnel Cloudflare via API, sem precisar fazer login no CLI.

## Vídeo

Tutorial: https://www.youtube.com/watch?v=8pmNHplZkzQ

---

## Configuração

Antes de executar, preencha as 4 variáveis no topo do script (`setup-tunnel.sh` ou `setup-tunnel.bat`):

```
FULL_DOMAIN="dev.seudominio.com"
CF_API_TOKEN=""
CF_ACCOUNT_ID=""
CF_ZONE_ID=""
```

---

## Onde encontrar cada variável no painel Cloudflare

### `FULL_DOMAIN`
O domínio completo com subdomínio que será criado. Deve usar um domínio que você já tem na Cloudflare.

Exemplo: `dev.meusite.com`, `cliente1.meusite.com`

---

### `CF_API_TOKEN`

1. Acesse [https://dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
2. Clique em **"Create Token"**
3. Use o modelo **"Edit Cloudflare Tunnel"** (ou crie customizado)
4. Adicione as permissões:
   - `Account` → `Cloudflare Tunnel` → **Edit**
   - `Zone` → `DNS` → **Edit**
5. Em **"Account Resources"**, selecione sua conta
6. Em **"Zone Resources"**, selecione o domínio ou "All zones"
7. Clique em **"Continue to summary"** → **"Create Token"**
8. Copie o token gerado (só aparece uma vez)

> **Atenção:** este é um **API Token**, diferente do token de run do tunnel (`cfat_...`).

---

### `CF_ACCOUNT_ID`

1. Acesse [https://dash.cloudflare.com](https://dash.cloudflare.com)
2. Clique em qualquer domínio seu
3. No painel direito, role até a seção **"API"**
4. Copie o valor de **"Account ID"**

---

### `CF_ZONE_ID`

1. Acesse [https://dash.cloudflare.com](https://dash.cloudflare.com)
2. Clique no domínio que será usado (ex: `meusite.com`)
3. No painel direito, role até a seção **"API"**
4. Copie o valor de **"Zone ID"**

> `CF_ZONE_ID` é por domínio. Se usar `meusite.com`, copie o Zone ID de `meusite.com`.

---

## Executando

**Linux:**
```bash
chmod +x setup-tunnel.sh
./setup-tunnel.sh
```

**Windows** (como Administrador):
```
setup-tunnel.bat
```

O script irá:
1. Verificar/instalar Node.js, PM2 e cloudflared
2. Criar o tunnel na Cloudflare via API (ou reutilizar se já existir)
3. Configurar as regras de ingress (hostname → porta local)
4. Criar/atualizar o registro DNS CNAME automaticamente
5. Iniciar o tunnel via PM2 com restart automático
6. Configurar o PM2 para inicializar no boot

---

## Comandos úteis após instalação

```bash
pm2 logs cf-tunnel-<subdomain>     # ver logs em tempo real
pm2 status                         # status de todos os processos
pm2 stop cf-tunnel-<subdomain>     # parar tunnel
pm2 restart cf-tunnel-<subdomain>  # reiniciar tunnel
pm2 delete cf-tunnel-<subdomain>   # remover tunnel
```