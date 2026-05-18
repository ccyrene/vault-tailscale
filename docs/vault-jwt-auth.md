# Vault JWT auth across clusters

The challenge: Vault lives in Cluster A but the workload it trusts lives in
Cluster B. Cluster A has no API access to Cluster B, so Vault cannot use the
native `kubernetes` auth method (which calls Cluster B's `TokenReview` API).
We use the **`jwt`** auth method instead — Vault validates SA tokens
**offline**, using Cluster B's public JWKS keys.

## How a Kubernetes SA token is structured

A projected token requested with `audience=vault` looks like:

```json
{
  "iss": "https://kubernetes.default.svc.cluster.local",
  "sub": "system:serviceaccount:app:vault-consumer",
  "aud": ["vault"],
  "exp": 1730000000,
  "kubernetes.io": { "namespace": "app", "serviceaccount": {"name": "vault-consumer"}}
}
```

The token is signed by Cluster B's API server with its service-account signing
key. Vault verifies that signature using the matching public key, available at
Cluster B's `/openid/v1/jwks` endpoint.

## Two configuration paths

### A. Live OIDC discovery (cleanest, needs network reachability)

Vault is configured with `oidc_discovery_url=https://<cluster-b-api>/openid/v1`
and fetches `jwks_uri` on every key rotation. Because the path goes through
the Tailscale mesh, Vault in Cluster A *can* reach Cluster B's API server —
but only if you also expose it as a tailnet device or proxy. Adds wiring.

### B. Static public keys (what this POC uses)

Vault's `jwt` auth backend accepts `jwt_validation_pubkeys` as a list of
PEM-encoded RSA/ECDSA public keys. Kubernetes exposes its signing keys as a
**JWKS** at `/openid/v1/jwks` — JSON, base64url-encoded modulus/exponent
pairs. We convert JWKS → PEM once and feed Vault.

`scripts/01-bootstrap-cluster-a.sh` does this end-to-end:

```bash
kubectl --kubeconfig "$KUBECONFIG_B" get --raw /openid/v1/jwks > /tmp/cluster-b-jwks.json

python3 - /tmp/cluster-b-jwks.json > /tmp/cluster-b-pubkeys.pem <<'PY'
import json, sys, base64
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers
from cryptography.hazmat.primitives import serialization
def b64u(s): return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
jwks = json.load(open(sys.argv[1]))
for k in jwks['keys']:
    n = int.from_bytes(b64u(k['n']), 'big')
    e = int.from_bytes(b64u(k['e']), 'big')
    print(RSAPublicNumbers(e, n).public_key().public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo).decode(), end='')
PY

vault write auth/jwt-cluster-b/config \
  jwt_validation_pubkeys=@/tmp/cluster-b-pubkeys.pem \
  bound_issuer="https://kubernetes.default.svc.cluster.local"
```

When Cluster B rotates its signing keys (rare; only on `kube-apiserver`
restart with new flags) you re-upload. For a POC playground, the key never
rotates.

## The Vault role

```hcl
auth/jwt-cluster-b/role/app = {
  role_type        = "jwt"
  bound_audiences  = ["vault"]
  user_claim       = "sub"
  bound_subject    = "system:serviceaccount:app:vault-consumer"
  token_policies   = ["app-read"]
  token_ttl        = "1h"
}
```

- **`bound_audiences=["vault"]`** ⇒ the projected token's `aud` claim must
  include `"vault"`. The Pod spec asks for exactly that.
- **`bound_subject=...`** ⇒ pins the role to one specific Namespace+SA. A
  different workload presenting a Cluster B token gets rejected.
- **`token_policies=["app-read"]`** ⇒ what the resulting Vault token can do.

## Vault Agent's auth dance

The Vault Agent sidecar (in Cluster B) does:

1. Read `/var/run/secrets/tokens/vault-jwt` (the projected SA token).
2. `POST` it to `vault/v1/auth/jwt-cluster-b/login` with `role=app`.
3. Receive a Vault token, cached in the agent.
4. Use the Vault token to `GET secret/data/app/credentials`.
5. Render to `/vault/secrets/credentials` via the template stanza.
6. On token expiry / rotation, repeat steps 1–4 transparently.

The Go app never touches Vault.

## Failure modes worth knowing

| Symptom | Likely cause |
|---|---|
| `permission denied` at login | `bound_subject` or `bound_audiences` mismatch |
| `failed to verify signature` | JWKS not uploaded / wrong cluster's JWKS |
| `unable to fetch jwks` | OIDC discovery URL unreachable from Vault pod |
| `expired token` | `expirationSeconds` on projected token too short for agent's renew loop (default agent re-reads it; should self-heal) |
| Agent loops on `dial tcp ... i/o timeout` | Tailscale routes not yet approved, or router pod not Running |
