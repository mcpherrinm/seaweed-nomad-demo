data_dir  = "/var/lib/nomad"
bind_addr = "0.0.0.0"

client {
  enabled = true
  servers = ["nomad-server:4647"]

  # CPU fingerprinting doesn't work inside a container; without this every
  # placement fails with 'Dimension "cpu" exhausted'.
  cpu_total_compute = 4000
}

tls {
  http = true
  rpc  = true

  ca_file   = "/pki/ca.crt"
  cert_file = "/pki/cert.pem"
  key_file  = "/pki/key.pem"

  verify_server_hostname = true
  verify_https_client    = false
}

# raw_exec keeps the demo free of driver requirements (no Landlock on Docker
# Desktop for exec2, no nested container runtime). Workload identity works the
# same way for every driver.
# PRODUCTION: don't enable raw_exec. Its tasks run unisolated as root, so they
# can read every other task's secrets/ directory, including identity JWTs. Use
# exec2, docker or podman.
plugin "raw_exec" {
  config {
    enabled = true
  }
}
