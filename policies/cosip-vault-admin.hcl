# Policy: cosip-vault-admin
# Usada pelo AppRole de admin do COSIP.
# Permite gerenciar AppRoles, policies e verificar capabilities via API.

# ── AppRole management (criar/ler/atualizar/deletar roles) ──────────────────
path "auth/approle/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "auth/approle/role/+/role-id" {
  capabilities = ["read"]
}
path "auth/approle/role/+/secret-id" {
  capabilities = ["list", "create", "update"]
}
path "auth/approle/role/+/secret-id-accessor/lookup" {
  capabilities = ["create", "update"]
}
path "auth/approle/role/+/secret-id-accessor/destroy" {
  capabilities = ["create", "update"]
}

# ── Token — lookup do próprio token ─────────────────────────────────────────
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

# ── Verificação de capabilities do próprio token ────────────────────────────
path "sys/capabilities-self" {
  capabilities = ["create", "update"]
}

# ── Gerenciamento de policies (permite auto-correção via UI do COSIP) ────────
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "list"]
}

# ── Health check ────────────────────────────────────────────────────────────
path "sys/health" {
  capabilities = ["read"]
}
