#!/bin/bash
# =============================================================================
# COSIP Vault — Inicialização Completa
# =============================================================================
# Compatível com macOS e Linux.
# Executa na PRIMEIRA instalação ou quando o Vault ainda não foi inicializado.
# Faz tudo: start do container, init, unseal, AppRole, policies,
# gera .env.laravel e SETUP-NOTES.md.
#
# USO:
#   bash scripts/init.sh
#   bash scripts/init.sh --vault-addr http://192.168.1.100:8200
# =============================================================================

set -euo pipefail

# ── Cores ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
ok()   { echo -e "${GREEN}[$(date '+%H:%M:%S')] ✓${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] ⚠${NC} $1"; }
err()  { echo -e "${RED}[$(date '+%H:%M:%S')] ✗${NC} $1"; exit 1; }

# ── Caminhos ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INIT_FILE="$ROOT_DIR/init-output.json"
ENV_LARAVEL="$ROOT_DIR/.env.laravel"
SETUP_NOTES="$ROOT_DIR/SETUP-NOTES.md"
CONTAINER="vault"

# ── Parâmetros ────────────────────────────────────────────────────────────────
VAULT_ADDR_EXTERNAL="http://127.0.0.1:8200"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-addr) VAULT_ADDR_EXTERNAL="$2"; shift 2 ;;
    *) err "Parâmetro desconhecido: $1" ;;
  esac
done

# ── Detectar OS ───────────────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macOS" ;;
    Linux)  OS="Linux"  ;;
    *)      OS="unknown" ;;
  esac
}

# ── Detectar docker compose ───────────────────────────────────────────────────
detect_docker_compose() {
  if docker compose version > /dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose > /dev/null 2>&1; then
    DC="docker-compose"
  else
    echo ""
    err "docker compose não encontrado. Instale:\n  macOS: Docker Desktop — https://www.docker.com/products/docker-desktop\n  Linux: sudo apt install docker-compose-plugin -y"
  fi
}

# ── Detectar ferramenta JSON (jq preferido, python3 como fallback) ────────────
detect_json_tool() {
  if command -v jq > /dev/null 2>&1; then
    JSON_TOOL="jq"
  elif command -v python3 > /dev/null 2>&1; then
    JSON_TOOL="python3"
  else
    echo ""
    err "jq ou python3 é necessário. Instale:\n  macOS: brew install jq\n  Linux:  sudo apt install jq -y"
  fi
}

# ── Helper: lê campo de arquivo JSON ─────────────────────────────────────────
# Uso: json_file FILE PY_EXPR JQ_EXPR
json_file() {
  local file="$1" py="$2" jq="$3"
  if [ "$JSON_TOOL" = "jq" ]; then
    command jq -r "$jq" "$file"
  else
    python3 -c "import json; d=json.load(open('$file')); print($py)" 2>/dev/null
  fi
}

# ── Helper: lê campo de JSON passado via stdin ────────────────────────────────
# Uso: echo "$JSON" | json_stdin PY_EXPR JQ_EXPR
json_stdin() {
  local py="$1" jq="$2"
  if [ "$JSON_TOOL" = "jq" ]; then
    command jq -r "$jq"
  else
    python3 -c "import json,sys; d=json.load(sys.stdin); print($py)" 2>/dev/null
  fi
}

# ── Helper: executa vault dentro do container com root token ─────────────────
vault_exec() {
  docker exec \
    -e VAULT_ADDR="http://127.0.0.1:8200" \
    -e VAULT_TOKEN="$ROOT_TOKEN" \
    "$CONTAINER" vault "$@"
}

# =============================================================================
detect_os
detect_docker_compose
detect_json_tool

echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║        COSIP Vault — Inicialização                          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo -e "  OS: ${OS}  |  compose: ${DC}  |  json: ${JSON_TOOL}"
echo ""

# ── 1. Iniciar containers ─────────────────────────────────────────────────────
mkdir -p "$ROOT_DIR/runtime/data" "$ROOT_DIR/runtime/logs"
# No Linux, bind mounts preservam permissões do host; o usuário vault (UID 100)
# dentro do container precisa de escrita — chmod 777 garante compatibilidade.
chmod 777 "$ROOT_DIR/runtime/data" "$ROOT_DIR/runtime/logs"
log "Iniciando containers..."
$DC -f "$ROOT_DIR/docker-compose.yml" up -d
ok "Containers iniciados."
sleep 5  # aguarda o processo vault iniciar dentro do container

# ── 2. Aguardar Vault ─────────────────────────────────────────────────────────
# Verificar se o container está realmente rodando
if ! docker ps --filter "name=^${CONTAINER}$" --filter "status=running" --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  warn "Container '$CONTAINER' não está em execução. Logs:"
  docker logs "$CONTAINER" 2>&1 | tail -20 || true
  err "Container falhou ao iniciar. Verifique os logs acima."
fi

log "Aguardando Vault responder..."
for i in $(seq 1 45); do
  VAULT_SC=0
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault status > /dev/null 2>&1 || VAULT_SC=$?
  # exit 0 = unsealed, exit 2 = sealed (mas respondendo) — ambos OK
  if [ "$VAULT_SC" -eq 0 ] || [ "$VAULT_SC" -eq 2 ]; then
    break
  fi
  sleep 3
  # A cada 15 tentativas, mostrar status do container para diagnóstico
  if [ "$i" -eq 15 ] || [ "$i" -eq 30 ]; then
    warn "Ainda aguardando... (${i}/45)  status container: $(docker inspect --format='{{.State.Status}}' $CONTAINER 2>/dev/null || echo 'não encontrado')"
  fi
  if [ "$i" -eq 45 ]; then
    warn "Logs do container vault:"
    docker logs "$CONTAINER" 2>&1 | tail -30 || true
    err "Vault não respondeu após 135 segundos. Verifique os logs acima."
  fi
done
ok "Vault respondendo."

# ── 3. Inicializar (somente se necessário) ────────────────────────────────────
VAULT_STATUS_JSON=$(docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault status -format=json 2>/dev/null || true)
INITIALIZED=$(echo "$VAULT_STATUS_JSON" | json_stdin "str(d.get('initialized',False)).lower()" ".initialized | tostring | ascii_downcase" || echo "false")

if [ "$INITIALIZED" = "false" ]; then
  log "Inicializando Vault (primeira vez)..."
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json > "$INIT_FILE"
  ok "Vault inicializado. Arquivo salvo em: init-output.json"
else
  ok "Vault já estava inicializado."
  if [ ! -f "$INIT_FILE" ]; then
    err "init-output.json não encontrado. Você precisa desse arquivo para continuar."
  fi
fi

# ── 4. Extrair root token e unseal keys ───────────────────────────────────────
ROOT_TOKEN=$(json_file "$INIT_FILE"  "d['root_token']"       ".root_token")
UNSEAL_KEY_1=$(json_file "$INIT_FILE" "d['unseal_keys_b64'][0]" ".unseal_keys_b64[0]")
UNSEAL_KEY_2=$(json_file "$INIT_FILE" "d['unseal_keys_b64'][1]" ".unseal_keys_b64[1]")
UNSEAL_KEY_3=$(json_file "$INIT_FILE" "d['unseal_keys_b64'][2]" ".unseal_keys_b64[2]")

# ── 5. Unseal ─────────────────────────────────────────────────────────────────
VAULT_STATUS_JSON2=$(docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault status -format=json 2>/dev/null || true)
SEALED=$(echo "$VAULT_STATUS_JSON2" | json_stdin "str(d.get('sealed',True)).lower()" ".sealed | tostring | ascii_downcase" || echo "true")

if [ "$SEALED" = "true" ]; then
  log "Aplicando chaves de unseal (3 de 5)..."
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault operator unseal "$UNSEAL_KEY_1" > /dev/null
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault operator unseal "$UNSEAL_KEY_2" > /dev/null
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault operator unseal "$UNSEAL_KEY_3" > /dev/null
  ok "Vault aberto (unsealed)."
else
  ok "Vault já estava aberto."
fi

# ── 6. Habilitar AppRole auth ─────────────────────────────────────────────────
log "Verificando auth backend AppRole..."
APPROLE_JSON=$(vault_exec auth list -format=json 2>/dev/null || true)
APPROLE_ON=$(echo "$APPROLE_JSON" | json_stdin "'approle/' in d" ".\"approle/\" != null" || echo "False")

if [ "$APPROLE_ON" = "False" ] || [ "$APPROLE_ON" = "false" ]; then
  vault_exec auth enable approle > /dev/null
  ok "AppRole auth habilitado."
else
  ok "AppRole auth já habilitado."
fi

# ── 7. Habilitar KV v2 em secret/ ─────────────────────────────────────────────
log "Verificando secrets engine KV v2..."
SECRET_JSON=$(vault_exec secrets list -format=json 2>/dev/null || true)
SECRET_ON=$(echo "$SECRET_JSON" | json_stdin "'secret/' in d" ".\"secret/\" != null" || echo "False")

if [ "$SECRET_ON" = "False" ] || [ "$SECRET_ON" = "false" ]; then
  vault_exec secrets enable -path=secret kv-v2 > /dev/null
  ok "Secrets engine KV v2 habilitado em 'secret/'."
else
  ok "Secrets engine 'secret/' já habilitado."
fi

# ── 8. Aplicar policies ───────────────────────────────────────────────────────
log "Aplicando policies..."
for POLICY_FILE in "$ROOT_DIR/policies"/*.hcl; do
  POLICY_NAME=$(basename "$POLICY_FILE" .hcl)
  vault_exec policy write "$POLICY_NAME" "/vault/policies/$(basename "$POLICY_FILE")" > /dev/null
  ok "  Policy '$POLICY_NAME' aplicada."
done

# ── 9. Criar / atualizar AppRole admin ────────────────────────────────────────
log "Configurando AppRole admin..."
vault_exec write auth/approle/role/cosip-vault-admin \
  policies="cosip-vault-admin" \
  token_type=service \
  token_ttl="2h" \
  token_max_ttl="8h" > /dev/null
ok "  AppRole 'cosip-vault-admin' → policy: cosip-vault-admin  (ttl: 2h / max: 8h)"

# ── 10. Ler Role ID ───────────────────────────────────────────────────────────
log "Obtendo Role ID..."
ADMIN_ROLE_ID=$(vault_exec read -field=role_id auth/approle/role/cosip-vault-admin/role-id)
ok "Role ID obtido."

# ── 11. Gerar Secret ID ───────────────────────────────────────────────────────
log "Gerando Secret ID..."
ADMIN_SECRET_ID=$(vault_exec write -field=secret_id -f auth/approle/role/cosip-vault-admin/secret-id)
ok "Secret ID gerado."

# ── 12. Gerar .env.laravel ────────────────────────────────────────────────────
log "Gerando .env.laravel..."
cat > "$ENV_LARAVEL" << ENVEOF
# =============================================================================
# Vault — variáveis para o projeto Laravel COSIP
# Gerado automaticamente por scripts/init.sh em $(date '+%Y-%m-%d %H:%M:%S')
# Copie este conteúdo para o arquivo .env do projeto.
# =============================================================================

VAULT_ADDR=${VAULT_ADDR_EXTERNAL}
VAULT_MOUNT=secret
VAULT_TENANT_PATH=cosip/tenants
VAULT_ADMIN_POLICY_NAME=cosip-vault-admin

# AppRole Admin (gerenciar AppRoles e policies via painel COSIP)
VAULT_ADMIN_ROLE_ID=${ADMIN_ROLE_ID}
VAULT_ADMIN_SECRET_ID=${ADMIN_SECRET_ID}

# Os demais AppRoles (Laravel, microserviços) devem ser criados
# pelo painel administrativo do COSIP (Configurações > Vault / Microserviços)
# e seus credentials adicionados manualmente ao .env.
ENVEOF
ok ".env.laravel gerado."

# ── 13. Gerar SETUP-NOTES.md ──────────────────────────────────────────────────
log "Gerando SETUP-NOTES.md..."
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
cat > "$SETUP_NOTES" << NOTESEOF
# COSIP Vault — Setup Notes

> Gerado automaticamente em: ${INSTALL_DATE}
> OS: ${OS} | compose: ${DC} | json: ${JSON_TOOL}

---

## Acesso

| | |
|---|---|
| **UI** | ${VAULT_ADDR_EXTERNAL}/ui |
| **Root Token** | \`${ROOT_TOKEN}\` |

> ⚠️ **ATENÇÃO:** Guarde \`init-output.json\` em local seguro (cofre de senhas, etc.).
> Contém o root token e as 5 unseal keys. **Nunca commitar.**

---

## AppRole Configurado

| AppRole | Policy | TTL / Max TTL |
|---|---|---|
| \`cosip-vault-admin\` | \`cosip-vault-admin\` | 2h / 8h |

### Credenciais do Admin

\`\`\`
VAULT_ADMIN_ROLE_ID=${ADMIN_ROLE_ID}
VAULT_ADMIN_SECRET_ID=${ADMIN_SECRET_ID}
\`\`\`

---

## Policies Criadas

| Policy | Permissões |
|---|---|
| \`cosip-vault-admin\` | Gerencia AppRoles, policies, token lookup |
| \`cosip-app\` | CRUD em \`secret/data/cosip/*\` |
| \`cosip-microservice\` | Leitura em \`secret/data/cosip/*\` |

---

## Próximos Passos

1. Copie \`.env.laravel\` para o \`.env\` do projeto COSIP
2. Execute no projeto:
   \`\`\`bash
   php artisan config:clear && php artisan cache:clear
   \`\`\`
3. Acesse o painel → **Configurações → Vault / Microserviços**
4. Crie os AppRoles necessários (ex: \`cosip-laravel\`)
5. Adicione os credentials gerados ao \`.env\`

---

## Após Restart do Container

\`\`\`bash
bash scripts/unseal.sh
\`\`\`

---

## Comandos Úteis

\`\`\`bash
# Status do Vault
docker exec vault vault status

# Listar AppRoles
docker exec -e VAULT_TOKEN="${ROOT_TOKEN}" vault vault list auth/approle/role

# Listar policies
docker exec -e VAULT_TOKEN="${ROOT_TOKEN}" vault vault policy list
\`\`\`
NOTESEOF
ok "SETUP-NOTES.md gerado."

# ── 14. Resumo ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Vault COSIP — Inicialização Concluída ✓                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BLUE}UI:${NC}          ${VAULT_ADDR_EXTERNAL}/ui"
echo -e "  ${BLUE}Root token:${NC}  ${ROOT_TOKEN}"
echo ""
echo -e "  ${YELLOW}AppRole:${NC}     cosip-vault-admin  (admin, 2h/8h)"
echo ""
echo -e "  ${YELLOW}Arquivos gerados:${NC}"
echo -e "    .env.laravel    — variáveis para o .env do Laravel"
echo -e "    SETUP-NOTES.md  — documentação desta instalação"
echo ""
echo -e "  ${YELLOW}Próximos passos:${NC}"
echo -e "    1. Copie .env.laravel para o .env do projeto COSIP"
echo -e "    2. Execute: php artisan config:clear && php artisan cache:clear"
echo -e "    3. Acesse: ${VAULT_ADDR_EXTERNAL}/ui"
echo ""
echo -e "  ${RED}⚠  GUARDE init-output.json EM LOCAL SEGURO — contém root token e unseal keys!${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════════════${NC}"
echo ""
