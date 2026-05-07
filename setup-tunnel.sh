#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  Cloudflare Tunnel Setup Script (Linux)
#  Cria tunnel + DNS via API (sem cloudflared login)
# ─────────────────────────────────────────────

FULL_DOMAIN="cliente1.seudominio.com.br"   # domínio fixo (ex: meusite.com)
CF_API_TOKEN=""  # API Token com permissões: Cloudflare Tunnel:Edit + DNS:Edit
CF_ACCOUNT_ID=""               # Account ID (painel CF → lado direito da tela inicial)
CF_ZONE_ID=""                  # Zone ID    (painel CF → domínio → lado direito)

# ─────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

trap 'echo -e "\n${RED}[ERRO]${NC} Script abortou na linha $LINENO. Comando: $BASH_COMMAND" >&2' ERR

echo ""
echo "══════════════════════════════════════════"
echo "   Cloudflare Tunnel Setup — Linux"
echo "══════════════════════════════════════════"
echo ""

# ── Validate config ──────────────────────────
step "Validando configurações..."
[[ -z "$FULL_DOMAIN" || "$FULL_DOMAIN" == "sub.albreis.com.br" ]] && error "Configure FULL_DOMAIN no script (ex: dev.meusite.com)."
[[ -z "$CF_API_TOKEN" ]]  && error "Configure CF_API_TOKEN no script."
[[ -z "$CF_ACCOUNT_ID" ]] && error "Configure CF_ACCOUNT_ID no script."
[[ -z "$CF_ZONE_ID" ]]    && error "Configure CF_ZONE_ID no script."
ok "Configurações OK."

# ── Extract subdomain part ────────────────────
SUBDOMAIN=$(echo "$FULL_DOMAIN" | cut -d'.' -f1)
ok "Domínio: ${FULL_DOMAIN} (subdomínio: ${SUBDOMAIN})"

# ── Ask for port ─────────────────────────────
echo ""
read -rp "  Qual porta local expor? (ex: 3000): " LOCAL_PORT
[[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] || error "Porta inválida: $LOCAL_PORT"
info "Rota: https://${FULL_DOMAIN} → http://localhost:${LOCAL_PORT}"
echo ""

# ── Check / install jq ───────────────────────
step "Verificando dependência: jq..."
if ! command -v jq &>/dev/null; then
  warn "jq não encontrado. Instalando..."
  sudo apt-get update -qq && sudo apt-get install -y jq
fi
ok "jq: $(jq --version)"

# ── Check / install Node.js ───────────────────
step "Verificando Node.js..."
if ! command -v node &>/dev/null; then
  warn "Node.js não encontrado. Instalando via NodeSource..."
  if command -v curl &>/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  elif command -v wget &>/dev/null; then
    wget -qO- https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  else
    error "curl e wget ausentes. Instale Node.js manualmente."
  fi
  sudo apt-get install -y nodejs
fi
ok "Node.js: $(node --version)"

# ── Check / install PM2 ───────────────────────
step "Verificando PM2..."
if ! command -v pm2 &>/dev/null; then
  warn "PM2 não encontrado. Instalando..."
  sudo npm install -g pm2
fi
ok "PM2: $(pm2 --version)"

# ── Check / install cloudflared ───────────────
step "Verificando cloudflared..."
if ! command -v cloudflared &>/dev/null; then
  warn "cloudflared não encontrado. Instalando..."
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  CF_ARCH="amd64" ;;
    aarch64) CF_ARCH="arm64" ;;
    armv7l)  CF_ARCH="arm"   ;;
    *)       error "Arquitetura não suportada: $ARCH" ;;
  esac
  CF_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
  info "Baixando de: $CF_URL"
  sudo curl -fsSL "$CF_URL" -o /usr/local/bin/cloudflared
  sudo chmod +x /usr/local/bin/cloudflared
fi
ok "cloudflared: $(cloudflared --version 2>&1 | head -1)"

# ── Create or reuse Cloudflare Tunnel via API ─
TUNNEL_NAME="tunnel-${SUBDOMAIN}"
step "Verificando tunnel '${TUNNEL_NAME}'..."

# Tenta criar o tunnel
CF_TUNNEL_RESPONSE=$(curl -s -X POST \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"name\":\"${TUNNEL_NAME}\",\"tunnel_secret\":\"$(openssl rand -base64 32)\"}")

CF_TUNNEL_SUCCESS=$(echo "$CF_TUNNEL_RESPONSE" | jq -r '.success')
CF_TUNNEL_ERR_CODE=$(echo "$CF_TUNNEL_RESPONSE" | jq -r '.errors[0].code // empty')

if [[ "$CF_TUNNEL_SUCCESS" == "true" ]]; then
  TUNNEL_ID=$(echo "$CF_TUNNEL_RESPONSE" | jq -r '.result.id')
  ok "Tunnel criado: ID=${TUNNEL_ID}"
elif [[ "$CF_TUNNEL_ERR_CODE" == "1013" ]]; then
  warn "Tunnel '${TUNNEL_NAME}' já existe. Reutilizando..."
  # Busca o tunnel existente pelo nome
  CF_LIST_RESPONSE=$(curl -s \
    "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" \
    -H "Authorization: Bearer ${CF_API_TOKEN}")
  info "Resposta da API (list tunnels): $(echo "$CF_LIST_RESPONSE" | jq -c '{success:.success, total:.result_info.count}')"
  TUNNEL_ID=$(echo "$CF_LIST_RESPONSE" | jq -r '.result[0].id')
  [[ -z "$TUNNEL_ID" || "$TUNNEL_ID" == "null" ]] && error "Não foi possível encontrar o tunnel existente."
  ok "Tunnel existente encontrado: ID=${TUNNEL_ID}"
else
  error "Falha ao criar tunnel: $(echo "$CF_TUNNEL_RESPONSE" | jq -r '.errors')"
fi

# ── Get tunnel token ──────────────────────────
step "Obtendo token do tunnel..."
CF_TOKEN_RESPONSE=$(curl -s \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
  -H "Authorization: Bearer ${CF_API_TOKEN}")

info "Resposta da API (token): $(echo "$CF_TOKEN_RESPONSE" | jq -c '{success:.success, errors:.errors}')"

TUNNEL_TOKEN=$(echo "$CF_TOKEN_RESPONSE" | jq -r '.result')
[[ -z "$TUNNEL_TOKEN" || "$TUNNEL_TOKEN" == "null" ]] && error "Falha ao obter token do tunnel."
ok "Token do tunnel obtido."

# ── Configure tunnel ingress rules via API ────
step "Configurando regras de ingress do tunnel..."
CF_CONFIG_RESPONSE=$(curl -s -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{
    \"config\": {
      \"ingress\": [
        {\"hostname\": \"${FULL_DOMAIN}\", \"service\": \"http://localhost:${LOCAL_PORT}\"},
        {\"service\": \"http_status:404\"}
      ]
    }
  }")

info "Resposta da API (config): $(echo "$CF_CONFIG_RESPONSE" | jq -c '{success:.success, errors:.errors}')"
CF_CONFIG_SUCCESS=$(echo "$CF_CONFIG_RESPONSE" | jq -r '.success')
[[ "$CF_CONFIG_SUCCESS" != "true" ]] && error "Falha ao configurar ingress: $(echo "$CF_CONFIG_RESPONSE" | jq -r '.errors')"
ok "Ingress configurado."

# ── Create or update DNS CNAME record ────────
step "Configurando DNS CNAME: ${FULL_DOMAIN} → ${TUNNEL_ID}.cfargotunnel.com ..."

# Verifica se o registro já existe
CF_DNS_LIST=$(curl -s \
  "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${FULL_DOMAIN}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}")
EXISTING_DNS_ID=$(echo "$CF_DNS_LIST" | jq -r '.result[0].id // empty')

if [[ -n "$EXISTING_DNS_ID" ]]; then
  warn "Registro DNS já existe (ID: ${EXISTING_DNS_ID}). Atualizando..."
  CF_DNS_RESPONSE=$(curl -s -X PATCH \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${EXISTING_DNS_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
      \"proxied\": true
    }")
else
  CF_DNS_RESPONSE=$(curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\": \"CNAME\",
      \"name\": \"${SUBDOMAIN}\",
      \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
      \"proxied\": true,
      \"comment\": \"auto-criado por setup-tunnel.sh\"
    }")
fi

info "Resposta da API (DNS): $(echo "$CF_DNS_RESPONSE" | jq -c '{success:.success, errors:.errors}')"
CF_DNS_SUCCESS=$(echo "$CF_DNS_RESPONSE" | jq -r '.success')
[[ "$CF_DNS_SUCCESS" != "true" ]] && error "Falha ao configurar DNS: $(echo "$CF_DNS_RESPONSE" | jq -r '.errors')"
ok "DNS configurado: ${FULL_DOMAIN}"

# ── Write PM2 ecosystem file ──────────────────
step "Criando arquivo de configuração PM2..."
ECOSYSTEM_FILE="$HOME/.cf-tunnel-${SUBDOMAIN}.config.js"
CLOUDFLARED_BIN=$(command -v cloudflared)

cat > "$ECOSYSTEM_FILE" <<EOF
module.exports = {
  apps: [{
    name: 'cf-tunnel-${SUBDOMAIN}',
    script: '${CLOUDFLARED_BIN}',
    args: ['tunnel', '--no-autoupdate', 'run', '--token', '${TUNNEL_TOKEN}'],
    autorestart: true,
    watch: false,
    max_restarts: 10,
    restart_delay: 3000,
    env: {}
  }]
};
EOF
ok "Config PM2 escrita em: ${ECOSYSTEM_FILE}"

# ── Start tunnel via PM2 ──────────────────────
step "Iniciando tunnel via PM2..."
PM2_APP_NAME="cf-tunnel-${SUBDOMAIN}"
pm2 delete "$PM2_APP_NAME" 2>/dev/null && info "Instância anterior removida." || true
pm2 start "$ECOSYSTEM_FILE"
pm2 save
ok "Tunnel iniciado no PM2."

# ── Enable PM2 startup ────────────────────────
step "Configurando PM2 para iniciar no boot..."
PM2_STARTUP=$(pm2 startup 2>&1 | grep "sudo" || true)
if [[ -n "$PM2_STARTUP" ]]; then
  warn "Execute o comando abaixo para finalizar a configuração de boot:"
  echo ""
  echo -e "  ${YELLOW}${PM2_STARTUP}${NC}"
  echo ""
else
  ok "PM2 startup já configurado."
fi

# ── Summary ───────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
echo -e "  ${GREEN}✓ Tunnel ativo!${NC}"
echo "══════════════════════════════════════════"
echo ""
info "  URL pública  : https://${FULL_DOMAIN}"
info "  Porta local  : ${LOCAL_PORT}"
info "  Tunnel ID    : ${TUNNEL_ID}"
info "  PM2 app      : ${PM2_APP_NAME}"
echo ""
info "Comandos úteis:"
echo "  pm2 logs ${PM2_APP_NAME}      # ver logs em tempo real"
echo "  pm2 status                    # status de todos os processos"
echo "  pm2 stop ${PM2_APP_NAME}      # parar tunnel"
echo "  pm2 restart ${PM2_APP_NAME}   # reiniciar tunnel"
echo "  pm2 delete ${PM2_APP_NAME}    # remover tunnel"
echo ""
