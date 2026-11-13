data_dir  = "/var/lib/nomad"
bind_addr = "0.0.0.0"

# PRODUCTION: enable ACLs (acl { enabled = true }). Anyone who can submit a job
# with a given namespace and job ID gets every role that trusts that job, so
# ACLs and namespaces are what actually guard the data.

server {
  enabled = true
  # PRODUCTION: 3 or 5 servers.
  bootstrap_expect = 1

  # Sets the `iss` claim on workload identity JWTs and enables
  # /.well-known/openid-configuration. SeaweedFS requires `iss` to match its
  # provider config exactly. The JWKS is always at /.well-known/jwks.json.
  # PRODUCTION: use a stable name (DNS or a load balancer in front of all
  # servers) that SeaweedFS can reach. It is baked into every token and into
  # SeaweedFS's config, so it is hard to change later.
  oidc_issuer = "https://nomad-server:4646"
}

tls {
  http = true
  rpc  = true

  # PRODUCTION: certificates from your own CA, renewed automatically.
  ca_file   = "/pki/ca.crt"
  cert_file = "/pki/cert.pem"
  key_file  = "/pki/key.pem"

  # RPC between agents is mutual TLS, and the server name must be
  # server.global.nomad.
  verify_server_hostname = true

  # The HTTP API does not require client certificates: SeaweedFS has no way to
  # present one when it fetches the JWKS.
  verify_https_client = false
}
