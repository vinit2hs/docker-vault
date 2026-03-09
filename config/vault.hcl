ui            = true
disable_mlock = true

storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

api_addr = "http://127.0.0.1:8200"

default_lease_ttl = "768h"
max_lease_ttl     = "8760h"

log_level = "info"
