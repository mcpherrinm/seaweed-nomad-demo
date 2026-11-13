#!/usr/bin/env bash
# Bring up the stack, run the trusted, untrusted and publisher jobs, then check
# what the public nginx front end does and doesn't serve.
# Exits non-zero if anything doesn't behave as the demo expects.
set -euo pipefail
cd "$(dirname "$0")"

dc() { docker compose "$@"; }
nomad() { dc exec -T -w /jobs nomad-server nomad "$@"; }
# (stdin is passed through, so "nomad job run -" works)

echo "==> Starting stack (pki runs first and exits)"
dc build
dc up -d --wait nomad-server
dc up -d nomad-client seaweed nginx
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

# run_job <jobfile> <task> <job id> [expect]
# Submits the job (renamed to <job id>), waits for it to finish, prints its
# output, and succeeds if the task printed "RESULT: PASS".
run_job() {
  local file=$1 task=$2 name=$3 expect=${4:-}
  echo
  echo "################ job ${name}${expect:+ (expect ${expect})} ################"
  local vars=()
  [[ -n "${expect}" ]] && vars=(-var "expect=${expect}")
  sed -E "s/^job \"[^\"]+\"/job \"${name}\"/" "jobs/${file}" |
    nomad job run -detach ${vars[@]+"${vars[@]}"} - >/dev/null
  local status=""
  for _ in $(seq 120); do
    status=$(nomad job status -short "${name}" 2>/dev/null | awk '/^Status/ {print $3}')
    [[ "${status}" == "dead" ]] && break
    sleep 1
  done
  local alloc
  alloc=$(nomad job allocs -t '{{range .}}{{.ID}}{{end}}' "${name}")
  nomad alloc logs "${alloc}" "${task}" || true
  nomad alloc logs -stderr "${alloc}" "${task}" || true
  nomad alloc logs "${alloc}" "${task}" | grep -q '^RESULT: PASS'
}

# check <description> <expected HTTP status> <curl args...>
# Runs curl inside the client container (it has the demo CA) and compares the status.
check() {
  local desc=$1 want=$2
  shift 2
  local got
  got=$(dc exec -T nomad-client curl -s -o /dev/null -w '%{http_code}' --cacert /pki/ca.crt "$@")
  if [[ "${got}" == "${want}" ]]; then
    printf '  ok    %-58s %s\n' "${desc}" "${got}"
  else
    printf '  FAIL  %-58s %s (want %s)\n' "${desc}" "${got}" "${want}"
    rc=1
  fi
}

rc=0
run_job app.nomad.hcl app s3-demo-app allow || rc=1
run_job app.nomad.hcl app intruder deny || rc=1
run_job publisher.nomad.hcl publish s3-publisher || rc=1

NGINX=https://nginx:8443
S3=https://seaweed:8333
echo
echo "################ public bucket via nginx ################"
dc exec -T nomad-client curl -s --cacert /pki/ca.crt "${NGINX}/"
check "GET  /                (index.html)"                 200 "${NGINX}/"
check "GET  /hello.txt"                                     200 "${NGINX}/hello.txt"
check "HEAD /hello.txt"                                     200 -I "${NGINX}/hello.txt"
check "PUT  /hello.txt       (writes blocked by nginx)"     403 -X PUT --data x "${NGINX}/hello.txt"
check "GET  /?list-type=2    (S3 subresources blocked)"     400 "${NGINX}/?list-type=2"
check "GET  /missing.txt"                                   404 "${NGINX}/missing.txt"
check "GET  /../demo-app/secret.txt (can't leave bucket)"   400 --path-as-is "${NGINX}/../demo-app/secret.txt"
check "GET  /..%2fdemo-app/secret.txt (encoded, same)"     400 --path-as-is "${NGINX}/..%2fdemo-app/secret.txt"
echo "direct anonymous S3, showing the bucket policy is what grants access:"
check "GET  s3/public/hello.txt"                            200 "${S3}/public/hello.txt"
check "GET  s3/public/       (listing not granted)"         403 "${S3}/public/"
check "PUT  s3/public/x.txt  (writes not granted)"          403 -X PUT --data x "${S3}/public/x.txt"
check "GET  s3/demo-app/secret.txt (other bucket private)"  403 "${S3}/demo-app/secret.txt"

echo
if [[ ${rc} -eq 0 ]]; then echo "DEMO PASSED"; else echo "DEMO FAILED"; fi
echo "Public site: https://localhost:8443/ (demo CA; see README)"
echo "Tear down with: docker compose -f $(pwd)/docker-compose.yml down -v"
exit ${rc}
