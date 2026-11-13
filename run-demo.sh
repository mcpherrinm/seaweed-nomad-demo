#!/usr/bin/env bash
# Bring up the stack, run the trusted and untrusted jobs, print their output.
# Exits non-zero if either job's result is not what the demo expects.
set -euo pipefail
cd "$(dirname "$0")"

dc() { docker compose "$@"; }
nomad() { dc exec -T -w /jobs nomad-server nomad "$@"; }
# (stdin is passed through, so "nomad job run -" works)

echo "==> Starting stack (pki runs first and exits)"
dc build
dc up -d --wait nomad-server
dc up -d nomad-client seaweed
dc logs pki

echo "==> Waiting for the Nomad client to register"
for _ in $(seq 60); do
  nomad node status 2>/dev/null | grep -q ' ready ' && break
  sleep 1
done
nomad node status

# curl from inside the client container, which has the demo CA at /pki/ca.crt.
s3curl() { dc exec -T nomad-client curl -s -o /dev/null "$@" https://seaweed:8333/; }

echo "==> Waiting for SeaweedFS S3 (HTTPS) on :8333"
for _ in $(seq 60); do
  s3curl --cacert /pki/ca.crt && break
  sleep 1
done
echo "anonymous ListBuckets returns HTTP $(s3curl --cacert /pki/ca.crt -w '%{http_code}') (expect 403)"
if s3curl; then
  echo "S3 certificate verified WITHOUT the demo CA; that should not happen"
  exit 1
else
  echo "without the demo CA, curl rejects the S3 certificate (expected)"
fi

run_job() {
  local name=$1 expect=$2
  echo
  echo "################ job ${name} (expect ${expect}) ################"
  sed "s/^job \"s3-demo-app\"/job \"${name}\"/" jobs/app.nomad.hcl |
    nomad job run -detach -var "expect=${expect}" - >/dev/null
  local status=""
  for _ in $(seq 120); do
    status=$(nomad job status -short "${name}" 2>/dev/null | awk '/^Status/ {print $3}')
    [[ "${status}" == "dead" ]] && break
    sleep 1
  done
  local alloc
  alloc=$(nomad job allocs -t '{{range .}}{{.ID}}{{end}}' "${name}")
  nomad alloc logs "${alloc}" app || true
  nomad alloc logs -stderr "${alloc}" app || true
  nomad alloc logs "${alloc}" app | grep -q '^RESULT: PASS'
}

rc=0
run_job s3-demo-app allow || rc=1
run_job intruder deny || rc=1

echo
if [[ ${rc} -eq 0 ]]; then echo "DEMO PASSED"; else echo "DEMO FAILED"; fi
echo "Tear down with: docker compose -f $(pwd)/docker-compose.yml down -v"
exit ${rc}
