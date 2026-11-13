# SeaweedFS S3 auth with Nomad workload identity

This demo lets a Nomad job use SeaweedFS's S3 API **without static access
keys**:

1. Nomad gives the task a signed JWT that says which job it is.
2. The task trades the JWT for short-lived S3 credentials with
   `sts:AssumeRoleWithWebIdentity`.
3. SeaweedFS decides what those credentials may do.

This is the same pattern AWS uses for Kubernetes and GitHub Actions. Here Nomad
is the identity provider and SeaweedFS plays the part of AWS.

It also shows how to serve one bucket to the public, read-only, through nginx.
A Nomad job publishes the content with the same identity flow.

```
./run-demo.sh            # build, start, run the demo jobs, print what happened
docker compose down -v   # tear down
```

Requires Docker with Compose. It uses Nomad 2.1.1 and SeaweedFS 4.40.

## How it works

```
 Nomad server ──signs JWT──▶ Nomad client ──writes──▶ task: secrets/nomad_seaweed.jwt
      ▲                                                     │
      │ (2) fetch public keys                               │ (1) AssumeRoleWithWebIdentity(JWT, role)
      │     /.well-known/jwks.json                          ▼
      └───────────────────────────────────────────── SeaweedFS S3 / STS
                                                            │ (3) temporary key, secret, session token
                                                            ▼
                                                     task uses S3 as that role
```

SeaweedFS never talks to the task's Nomad client and never needs a Nomad
token. It only needs the public keys Nomad publishes. With those it checks:

- the signature;
- the issuer (`iss`);
- the audience (`aud`);
- the role's **trust policy**, which matches claims such as the job ID.

If all pass, it issues credentials limited by the role's **permission policy**.

## Setting it up

### 1. Nomad: publish an issuer

`nomad/server.hcl`:

```hcl
server {
  oidc_issuer = "https://nomad-server:4646"
}
```

This value goes into the `iss` claim of every workload identity.
It also turns on `/.well-known/openid-configuration`. Nomad always serves its
public keys at `/.well-known/jwks.json`.

> **Pitfall:** without `oidc_issuer`, tokens have no `iss`, and SeaweedFS
> rejects them. The URL must match SeaweedFS's `issuer` setting exactly,
> including the scheme and any port or trailing slash.

### 2. The job: request an identity for SeaweedFS

`jobs/app.nomad.hcl`:

```hcl
identity {
  name = "seaweed"        # file is secrets/nomad_<name>.jwt
  aud  = ["seaweedfs"]    # must match the provider's clientId in SeaweedFS
  file = true             # write it to disk for the AWS SDK
  ttl  = "1h"             # Nomad re-signs and rewrites the file before expiry
}

env {
  AWS_ROLE_ARN                = "arn:aws:iam::role/DemoAppRole"
  AWS_WEB_IDENTITY_TOKEN_FILE = "${NOMAD_SECRETS_DIR}/nomad_seaweed.jwt"
  AWS_ENDPOINT_URL            = "https://seaweed:8333"   # STS and S3 share this port
}
```

The token's claims look like this (`run-demo.sh` prints a real one):

```json
{
  "iss": "https://nomad-server:4646",
  "aud": "seaweedfs",
  "sub": "global:default:s3-demo-app:app:app:seaweed",
  "nomad_namespace": "default",
  "nomad_job_id": "s3-demo-app",
  "nomad_task": "app",
  "nomad_allocation_id": "…"
}
```

Use a separate identity, with its own `aud`, for each service a task talks
to. A token meant for SeaweedFS should not be accepted anywhere else.

### 3. SeaweedFS: trust Nomad, define roles

Start the S3 gateway with `-s3.iam.config=/etc/seaweedfs/iam.json`. The file
has three parts.

**The provider**, under `sts.providers`:

```json
{
  "name": "nomad", "type": "oidc", "enabled": true,
  "config": {
    "issuer":    "https://nomad-server:4646",
    "clientId":  "seaweedfs",
    "jwksUri":   "https://nomad-server:4646/.well-known/jwks.json",
    "tlsCaCert": "/pki/ca.crt"
  }
}
```

**A role.** Its trust policy says *who* may assume it. Every top-level claim
is available as `oidc:<claim>`.

```json
"Principal": { "Federated": "nomad" },
"Action":    ["sts:AssumeRoleWithWebIdentity"],
"Condition": { "StringEquals": {
  "oidc:nomad_namespace": "default",
  "oidc:nomad_job_id":    "s3-demo-app"
}}
```

**A policy** attached to the role says *what* it may do. Here that is
everything, but only on bucket `demo-app`.

The `sts` block also sets `issuer` and `signingKey`. SeaweedFS uses these to
sign the session credentials it issues. They are unrelated to Nomad's keys.

### 4. The app: use any AWS SDK

The standard variables from step 2 are enough. The SDK reads the token file,
calls STS, and refreshes the credentials before they expire. `jobs/app.py`
shows both an explicit STS call and the automatic path. Use path-style S3
addressing, because SeaweedFS doesn't serve bucket subdomains by default.

### 5. Optional: serve a bucket publicly through nginx

The `s3-publisher` job (`jobs/publisher.nomad.hcl`) assumes `PublisherRole`
in the same way. It creates bucket `public`, uploads a small site, and attaches
a **bucket policy** that lets anyone read objects:

```json
{ "Effect": "Allow", "Principal": "*",
  "Action": ["s3:GetObject"], "Resource": ["arn:aws:s3:::public/*"] }
```

Only object reads are granted: anonymous listing, writes and reading the
policy all stay denied. nginx (`nginx/nginx.conf`) then proxies
`https://localhost:8443/<key>` to `public/<key>`. **It sends no credentials**,
so it can never do more than an anonymous S3 client could. Its job is to
narrow the S3 API down to a static file server:

- only `GET` and `HEAD`;
- requests with a query string are refused, since `?acl`, `?policy`,
  `?list-type` and presigned `?X-Amz-*` parameters select other S3 operations;
- the client's `Authorization` header is dropped;
- the path is pinned to the one bucket, so `../` can't escape it.

> **Pitfall:** the bucket policy is the real access control. A mistake in
> nginx can at worst expose what the policy already makes public. A mistake in
> the policy, such as `s3:*` or `Resource: "*"`, exposes data however nginx is
> configured.

> **Pitfall (SeaweedFS 4.40):** creating a bucket is authorised as `s3:*` on
> the bucket ARN, not as `s3:CreateBucket`. `PublisherRole` therefore gets
> `s3:*` on `arn:aws:s3:::public`, but only read, write and delete on the
> objects.

### What the demo checks

- `s3-demo-app` gets credentials, then writes and reads in `demo-app`.
  Creating another bucket is denied.
- The `intruder` job holds a perfectly valid Nomad token, but STS refuses it
  because its `nomad_job_id` doesn't match the trust policy.
- Anonymous S3 requests get a 403, and a client that doesn't trust the CA
  can't connect.
- `s3-publisher` publishes to `public`, and nginx serves it. nginx refuses
  writes, query strings and path escapes, both plain `../` and encoded. Direct
  anonymous S3 can read `public` objects but can't list or write `public`, and
  gets nothing from `demo-app`.

## Key ideas and pitfalls

- **Whoever can run job X can use job X's role.** The trust policy can only
  check what Nomad put in the token. Anyone who can submit a job named
  `s3-demo-app` in `default` gets `DemoAppRole`. Nomad ACLs and namespaces
  are what actually protect your data.
- **Signing algorithm.** Nomad signs with RS256. SeaweedFS 4.40 accepts RSA and
  ECDSA keys, but not EdDSA.
- **Audience.** `aud` must match the provider's `clientId`, or one of its
  `clientIds`.
- **SeaweedFS must reach Nomad's HTTPS API to fetch the public keys.** It
  can't present a client certificate, so Nomad must not require one on HTTP
  (`tls.verify_https_client = false`). SeaweedFS caches the keys and
  re-fetches when it sees an unknown `kid`, so Nomad's key rotation just
  works.
- **Two kinds of TTL.** The Nomad JWT (`identity.ttl`) must be valid whenever
  the SDK refreshes. Nomad rewrites the file before it expires, so that holds.
  The S3 session lifetime comes from SeaweedFS's `sts.tokenDuration`.
- **Token replay.** SeaweedFS 4.50+ accepts each token only once by default
  (`jtiReplayProtectionEnabled`). An SDK that refreshes credentials before
  Nomad has rotated the file then sends the same token twice. Set a short
  `identity.ttl`, or turn replay protection off for this provider.
- **Static users live elsewhere.** `iam.json` can't define static access-key
  users. If you also need those, put them in `-s3.config`.

## What a production deployment would do differently

The code comments mark these places with `PRODUCTION:`.

| Area | Demo | Production |
|---|---|---|
| Nomad servers | One server, no ACLs | 3 or 5 servers, ACLs on. Namespaces and ACL policies control who can submit which job IDs. |
| `oidc_issuer` | A container hostname | A stable DNS name or load balancer in front of all servers. It is baked into every token and into SeaweedFS's config, so it is hard to change later. |
| Task driver | `raw_exec` | `exec2`, `docker` or `podman`. `raw_exec` tasks run as root on the host and can read *other* tasks' identity files. |
| SeaweedFS | All-in-one `weed server`, data lost on restart | Separate master, volume, filer and S3 processes with persistent storage. All S3 gateways share the same `sts.issuer` and `sts.signingKey`. Internal gRPC protected with `security.toml`. |
| Secrets | `signingKey` committed in `iam.json` | `signingKey` kept in a secret store (Vault or Nomad Variables) and rendered into the config at deploy time. |
| PKI | minica: throwaway CA, no rotation | Your organisation's CA. Certificates renewed automatically, CA key never on the hosts. |
| Roles | One hand-written role | One role per app, or per namespace, managed as code. Narrow bucket and prefix permissions. |
| SeaweedFS version | 4.40 | Pin a version and test token refresh against it. See the replay note above. |
| Public nginx | One container with the demo certificate, no caching | A real certificate, `proxy_cache` or a CDN in front, rate limits and access logs. SeaweedFS's S3 port is reachable only from nginx and your apps, never from the internet. |

## Files

| Path | Purpose |
|---|---|
| `docker-compose.yml` | The five services: `pki`, `nomad-server`, `nomad-client`, `seaweed`, `nginx` |
| `pki/` | One-shot container that runs [minica](https://github.com/jsha/minica) to create a demo CA and per-service certificates in a volume. Everything else waits for it. |
| `nomad/server.hcl`, `nomad/client.hcl` | Nomad agent config, including `oidc_issuer` and TLS |
| `seaweed/iam.json` | SeaweedFS STS, the Nomad provider, roles and policies |
| `jobs/app.nomad.hcl`, `jobs/app.py` | The demo job and the boto3 app |
| `jobs/publisher.nomad.hcl`, `jobs/publisher.py` | Publishes the `public` bucket and sets its bucket policy |
| `nginx/nginx.conf` | Public, read-only HTTPS front end for the `public` bucket |
| `run-demo.sh` | Runs the trusted, `intruder` and publisher jobs, then checks S3 and nginx |

The Nomad UI is at https://127.0.0.1:4646, and the public site at
https://localhost:8443/. To trust the demo CA from the host, run
`docker compose exec nomad-server cat /pki/ca.crt > ca.crt`.

## References

- Nomad: [Workload identity](https://developer.hashicorp.com/nomad/docs/concepts/workload-identity)
  · [`identity` block](https://developer.hashicorp.com/nomad/docs/job-specification/identity)
  · [`server.oidc_issuer`](https://developer.hashicorp.com/nomad/docs/configuration/server)
  · [Key management](https://developer.hashicorp.com/nomad/docs/operations/key-management)
  · [TLS](https://developer.hashicorp.com/nomad/docs/configuration/tls)
  · [ACLs](https://developer.hashicorp.com/nomad/docs/secure/acl)
  · [`raw_exec` driver](https://developer.hashicorp.com/nomad/docs/drivers/raw_exec)
- SeaweedFS: [OIDC integration](https://github.com/seaweedfs/seaweedfs/wiki/OIDC-Integration)
  · [Kubernetes ServiceAccount authentication](https://github.com/seaweedfs/seaweedfs/wiki/Kubernetes-ServiceAccount-Authentication) (the same flow, with a different issuer)
  · [Security configuration](https://github.com/seaweedfs/seaweedfs/wiki/Security-Configuration)
- AWS: [AssumeRoleWithWebIdentity API](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html)
  · [SDK web identity settings](https://docs.aws.amazon.com/sdkref/latest/guide/feature-assume-role-credentials.html)
  · [Service-specific endpoints (`AWS_ENDPOINT_URL`)](https://docs.aws.amazon.com/sdkref/latest/guide/feature-ss-endpoints.html)
  · [S3 bucket policies](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-policies.html)
  · [Bucket policy examples](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-bucket-policies.html)
- nginx: [`ngx_http_proxy_module`](https://nginx.org/en/docs/http/ngx_http_proxy_module.html)
- [minica](https://github.com/jsha/minica)
