#!/bin/sh
# Provision a throwaway PKI for the demo into $PKI_DIR (a Docker volume),
# using minica (https://github.com/jsha/minica).
#
# Layout, one directory per service so each can mount only its own subpath:
#   <service>/ca.crt     the demo CA certificate (trust anchor)
#   <service>/cert.pem   leaf certificate
#   <service>/key.pem    leaf private key
#
# The CA private key never touches the volume: minica runs in a temp dir and
# the CA key is discarded once the leaves are issued. To reissue, delete the
# volume (docker compose down -v).
#
# Idempotent: if a previous run completed, it does nothing.
#
# PRODUCTION: use your organisation's CA, with certificates renewed
# automatically (minica leaves last two years and are never rotated). Keep the
# CA key off the hosts that use the certificates.
set -eu

PKI_DIR=${PKI_DIR:-/pki}
# The seaweedfs image drops privileges to this uid, so its key must be readable by it.
SEAWEED_UID=${SEAWEED_UID:-1000}

if [ -f "$PKI_DIR/.complete" ]; then
  echo "PKI already provisioned in $PKI_DIR; nothing to do."
  exit 0
fi

# Clear out any partial earlier attempt.
find "$PKI_DIR" -mindepth 1 -delete

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# issue <service> <domains> <ip-addresses>
# minica creates minica.pem / minica-key.pem (the CA) on first use, and writes
# each leaf to a directory named after the first domain.
issue() {
  svc=$1 domains=$2 ips=$3
  echo "Issuing $svc: $domains $ips"
  minica -domains "$domains" -ip-addresses "$ips"
  first=${domains%%,*}
  mkdir -p "$PKI_DIR/$svc"
  cp "$first/cert.pem" "$first/key.pem" "$PKI_DIR/$svc/"
  cp minica.pem "$PKI_DIR/$svc/ca.crt"
  chmod 0644 "$PKI_DIR/$svc/cert.pem" "$PKI_DIR/$svc/ca.crt"
  chmod 0600 "$PKI_DIR/$svc/key.pem"
}

# With verify_server_hostname, Nomad checks for server.<region>.nomad and
# client.<region>.nomad. The other names cover HTTPS (API, UI, JWKS).
issue nomad-server "server.global.nomad,nomad-server,localhost" "127.0.0.1"
issue nomad-client "client.global.nomad,nomad-client,localhost" "127.0.0.1"
issue seaweed "seaweed,localhost" "127.0.0.1"

chown -R "$SEAWEED_UID:$SEAWEED_UID" "$PKI_DIR/seaweed"

touch "$PKI_DIR/.complete"
echo "PKI ready."
