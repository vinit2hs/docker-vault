# COSIP — HashiCorp Vault Docker Setup

Setup completo do Vault para o projeto COSIP. Inclui todas as roles, policies e scripts de inicialização.

---

## Estrutura

```
docker-vault/
├── docker-compose.yml
├── .env                      # Porta (VAULT_PORT=8200)
├── config/
│   └── vault.hcl             # Configuração do servidor Vault
├── policies/
│   ├── cosip-vault-admin.hcl # Admin — gerencia AppRoles e policies
│   ├── cosip-app.hcl         # Laravel — leitura/escrita de secrets
│   └── cosip-microservice.hcl# Microserviços — somente leitura
├── scripts/
│   ├── init.sh               # Inicialização completa (1ª instalação)
│   └── unseal.sh             # Unseal + reaplica policies (após restart)
├── data/                     # Dados do Vault (gerado em runtime, gitignored)
└── logs/                     # Logs (gitignored)
```

---

## Roles e Policies

| AppRole | Policy | TTL | Uso |
|---|---|---|---|
| `cosip-vault-admin` | `cosip-vault-admin` | 2h / 8h | Gerencia AppRoles via painel COSIP |
| `cosip-laravel` | `cosip-app` | 1h / 4h | Laravel — lê/grava secrets de tenants |
| `cosip-golang` | `cosip-microservice` | 1h / 4h | Microserviços — apenas leitura |

### Caminhos KV

| Path | Acesso |
|---|---|
| `secret/data/cosip/tenants/{uuid}` | Secrets por tenant (db_password, redis_password, etc.) |
| `secret/data/cosip/*` | Secrets gerais do sistema |

---

## Primeira Instalação

```bash
# 1. Clonar / copiar este diretório para o servidor
cd docker-vault

# 2. (Opcional) Ajustar a porta no .env
echo "VAULT_PORT=8200" > .env

# 3. Dar permissão de execução aos scripts
chmod +x scripts/init.sh scripts/unseal.sh

# 4. Executar inicialização completa
bash scripts/init.sh

# Em ambiente com IP diferente de localhost:
bash scripts/init.sh --vault-addr http://192.168.1.100:8200
```

O script fará:
1. `docker compose up -d`
2. `vault operator init` (5 chaves, threshold 3)
3. Unseal com 3 chaves
4. Habilitar `auth/approle` e `secrets/kv-v2`
5. Criar as 3 policies
6. Criar os 3 AppRoles
7. Gerar `.env.laravel` com todas as variáveis

---

## Configurar o Laravel

Após `init.sh`, copie o conteúdo de `.env.laravel` para o `.env` do projeto:

```bash
cat .env.laravel
```

Variáveis geradas:

```dotenv
VAULT_ADDR=http://127.0.0.1:8200
VAULT_MOUNT=secret
VAULT_TENANT_PATH=cosip/tenants
VAULT_ADMIN_POLICY_NAME=cosip-vault-admin

VAULT_ROLE_ID=<role_id do cosip-laravel>
VAULT_SECRET_ID=<secret_id do cosip-laravel>

VAULT_ADMIN_ROLE_ID=<role_id do cosip-vault-admin>
VAULT_ADMIN_SECRET_ID=<secret_id do cosip-vault-admin>
```

Depois:

```bash
php artisan config:clear && php artisan cache:clear
```

---

## Após Restart do Container

```bash
bash scripts/unseal.sh
```

O script lê as chaves de `init-output.json` e reabre o Vault automaticamente.
As policies são reaplicadas a cada unseal.

---

## Adicionar Novo Microserviço

Microserviços são gerenciados pelo painel admin do COSIP (aba Vault / Microserviços).
O painel cria o AppRole automaticamente ao cadastrar o microserviço.

**Manualmente via CLI:**

```bash
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('init-output.json'))['root_token'])")

docker exec -e VAULT_TOKEN="$ROOT_TOKEN" vault vault write \
  auth/approle/role/nome-do-servico \
  policies="cosip-microservice" \
  token_type=service \
  token_ttl=1h \
  token_max_ttl=4h
```

Se precisar de uma policy customizada, crie o arquivo em `policies/` e rode `unseal.sh`.

---

## Comandos Úteis

```bash
# Status
docker exec vault vault status

# Listar AppRoles
docker exec -e VAULT_TOKEN="$ROOT_TOKEN" vault vault list auth/approle/role

# Listar policies
docker exec -e VAULT_TOKEN="$ROOT_TOKEN" vault vault policy list

# Ler policy
docker exec -e VAULT_TOKEN="$ROOT_TOKEN" vault vault policy read cosip-vault-admin

# Listar secrets de um tenant
docker exec -e VAULT_TOKEN="$ROOT_TOKEN" vault vault kv list secret/cosip/tenants

# UI (browser)
open http://127.0.0.1:8200/ui
```

---

## Segurança

- `init-output.json` contém o **root token** e as **unseal keys** — guarde em local seguro (cofre de senha, etc.)
- `.env.laravel` contém os Secret IDs — não commitar
- Ambos estão no `.gitignore`
- Em produção, considere **Vault Auto-Unseal** (AWS KMS, GCP KMS, etc.) para eliminar a necessidade de unseal manual
