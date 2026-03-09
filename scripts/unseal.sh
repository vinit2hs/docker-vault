#!/bin/bash
# =============================================================================
# COSIP Vault — Unseal + Reaplica Policies
# =============================================================================
# Compatível com macOS e Linux.
# Executar após restart do container Vault.
# Lê as chaves de unseal do init-output.json e reaplica todas as policies.
#
# USO:
#   bash scripts/unseal.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INIT_FILE="$ROOT_DIR/init-output.json"
CONTAINER="vault"

log() { echo "[$(date '+%H:%M:%S')] $1"; }
ok()  { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
err() { echo "[$(date '+%H:%M:%S')] ✗ $1"; exit 1; }

# ── Detectar ferramenta JSON ──────────────────────────────────────────────────
if command -v jq > /dev/null 2>&1; then
  JSON_TOOL="jq"
elif command -v python3 > /dev/null 2>&1; then
  JSON_TOOL="python3"
else
  err "jq ou python3 é necessário.\n  macOS: brew install jq\n  Linux: sudo apt install jq -y"
fi

# ── Helper: lê campo de arquivo JSON ─────────────────────────────────────────
json_file() {
  local file="$1" py="$2" jq="$3"
  if [ "$JSON_TOOL" = "jq" ]; then
    command jq -r "$jq" "$file"
  else
    python3 -c "import json; d=json.load(open('$file')); print($py)" 2>/dev/null
  fi
}

# ── Helper: lê campo de JSON via stdin ───────────────────────────────────────
json_stdin() {
  local py="$1" jq="$2"
  if [ "$JSON_TOOL" = "jq" ]; then
    command jq -r "$jq"
  else
    python3 -c "import json,sys; d=json.load(sys.stdin); print($py)" 2>/dev/null
  fi
}

# ── Validar init-output.json ──────────────────────────────────────────────────
if [ ! -f "$INIT_FILE" ]; then
  err "init-output.json não encontrado em $ROOT_DIR — execute scripts/init.sh primeiro."
fi

# ── Extrair credenciais ───────────────────────────────────────────────────────
ROOT_TOKEN=$(json_file "$INIT_FILE"  "d['root_token']"         ".root_token")
UNSEAL_KEY_1=$(json_file "$INIT_FILE" "d['unseal_keys_b64'][0]" ".unseal_keys_b64[0]")
UNSEAL_KEY_2=$(json_file "$INIT_FILE" "d['unseal_keys_b64'][1]" ".unseal_keys_b64[1]")
UNSEAL_KEY_3=$(json_file "$INIT_FILE" "d['unseal_keys_b64'][2]" ".unseal_keys_b64[2]")

log "Ferramenta JSON: ${JSON_TOOL}"

# ── Garantir permissões dos volumes (Linux bind mounts) ────────────────────────
if [ -d "$ROOT_DIR/runtime" ]; then
  chmod 777 "$ROOT_DIR/runtime/data" "$ROOT_DIR/runtime/logs" 2>/dev/null || true
fi

# ── Verificar se container está rodando ───────────────────────────────────────
if ! docker ps --filter "name=^${CONTAINER}$" --filter "status=running" --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  warn "Container '$CONTAINER' não está em execução. Tentando iniciar..."
  DC=""
  if docker compose version > /dev/null 2>&1; then DC="docker compose"
  elif command -v docker-compose > /dev/null 2>&1; then DC="docker-compose"; fi
  if [ -n "$DC" ]; then
    mkdir -p "$ROOT_DIR/runtime/data" "$ROOT_DIR/runtime/logs"
    chmod 777 "$ROOT_DIR/runtime/data" "$ROOT_DIR/runtime/logs"
    $DC -f "$ROOT_DIR/docker-compose.yml" up -d
    sleep 5
  fi
fi

# ── Aguardar container ────────────────────────────────────────────────────────
log "Aguardando container '$CONTAINER' iniciar..."
for i in $(seq 1 40); do
  VAULT_SC=0
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault status > /dev/null 2>&1 || VAULT_SC=$?
  if [ "$VAULT_SC" -eq 0 ] || [ "$VAULT_SC" -eq 2 ]; then break; fi
  sleep 3
  if [ "$i" -eq 20 ]; then
    warn "Ainda aguardando... (${i}/40)  status: $(docker inspect --format='{{.State.Status}}' $CONTAINER 2>/dev/null || echo 'não encontrado')"
  fi
  if [ "$i" -eq 40 ]; then
    warn "Logs do container vault:"
    docker logs "$CONTAINER" 2>&1 | tail -20 || true
    err "Container '$CONTAINER' não respondeu após 120 segundos."
  fi
done

# ── Unseal ────────────────────────────────────────────────────────────────────
VAULT_STATUS_JSON=$(docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault status -format=json 2>/dev/null || true)
SEALED=$(echo "$VAULT_STATUS_JSON" | json_stdin "str(d.get('sealed',True)).lower()" ".sealed | tostring | ascii_downcase" || echo "true")

if [ "$SEALED" = "true" ]; then
  log "Aplicando chaves de unseal (3 de 5)..."
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault operator unseal "$UNSEAL_KEY_1" > /dev/null
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault operator unseal "$UNSEAL_KEY_2" > /dev/null
  docker exec -e VAULT_ADDR="http://127.0.0.1:8200" "$CONTAINER" vault operator unseal "$UNSEAL_KEY_3" > /dev/null
  ok "Vault aberto (unsealed)."
else
  ok "Vault já estava aberto."
fi

# ── Reaplica policies ─────────────────────────────────────────────────────────
if [ -d "$ROOT_DIR/policies" ]; then
  log "Reaplicando policies..."
  for POLICY_FILE in "$ROOT_DIR/policies"/*.hcl; do
    POLICY_NAME=$(basename "$POLICY_FILE" .hcl)
    docker exec \
      -e VAULT_ADDR="http://127.0.0.1:8200" \
      -e VAULT_TOKEN="$ROOT_TOKEN" \
      "$CONTAINER" vault policy write "$POLICY_NAME" "/vault/policies/$(basename "$POLICY_FILE")" > /dev/null
    ok "  policy '$POLICY_NAME' reaplicada."
  done
fi

ok "Concluído."
