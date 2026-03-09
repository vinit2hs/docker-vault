# Policy: cosip-app
# Usada pelo AppRole cosip-laravel.
# Acesso completo aos secrets do COSIP (tenants, app, aws, microservice).

path "secret/data/cosip/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "secret/metadata/cosip/*" {
  capabilities = ["read", "delete", "list"]
}
