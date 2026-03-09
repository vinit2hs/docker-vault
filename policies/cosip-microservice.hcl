# Policy: cosip-microservice
# Usada pelos AppRoles de microserviços gerenciados pelo COSIP.
# Apenas leitura dos secrets — microserviços não gravam no Vault diretamente.

path "secret/data/cosip/*" {
  capabilities = ["read"]
}
