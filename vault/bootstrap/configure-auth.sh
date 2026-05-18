#!/usr/bin/env bash
# Configure Vault for the POC:
#   - kv-v2 at secret/
#   - demo credential at secret/app/credentials
#   - app-read policy
#   - jwt auth at jwt-cluster-b, validating Cluster B SA tokens offline
#     using Cluster B's JWKS converted to PEM
#   - role 'app' bound to system:serviceaccount:app:vault-consumer
#
# Requires:
#   VAULT_TOKEN          root token
#   KUBECONFIG_A         cluster A
#   KUBECONFIG_B         cluster B (needed to read its JWKS once)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="${VAULT_NAMESPACE:-vault}"
LEADER="vault-0"

: "${VAULT_TOKEN:?set VAULT_TOKEN to the Vault root token}"
: "${KUBECONFIG_A:?set KUBECONFIG_A}"
: "${KUBECONFIG_B:?set KUBECONFIG_B}"

require() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
require kubectl
require jq
require python3

KCA() { KUBECONFIG="${KUBECONFIG_A}" "$@"; }
KCB() { KUBECONFIG="${KUBECONFIG_B}" "$@"; }
vex() { KCA kubectl -n "${NS}" exec -i "${LEADER}" -- env VAULT_TOKEN="${VAULT_TOKEN}" "$@"; }

echo "==> Reading Cluster B issuer + JWKS"
CLUSTER_B_ISSUER=$(KCB kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
KCB kubectl get --raw /openid/v1/jwks > /tmp/cluster-b-jwks.json
echo "    issuer: ${CLUSTER_B_ISSUER}"

echo "==> Converting JWKS -> PEM (jwt_validation_pubkeys is what Vault accepts)"
python3 - /tmp/cluster-b-jwks.json > /tmp/cluster-b-pubkeys.pem <<'PY'
import json, sys, base64
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers
from cryptography.hazmat.primitives import serialization
def b64u(s): return base64.urlsafe_b64decode(s + '=' * (-len(s) % 4))
jwks = json.load(open(sys.argv[1]))
for k in jwks['keys']:
    n = int.from_bytes(b64u(k['n']), 'big')
    e = int.from_bytes(b64u(k['e']), 'big')
    pem = RSAPublicNumbers(e, n).public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
    print(pem.decode(), end='')
PY
[[ -s /tmp/cluster-b-pubkeys.pem ]] || { echo "PEM empty; check JWKS" >&2; exit 1; }

echo "==> Enabling kv-v2 at secret/"
vex vault secrets enable -path=secret kv-v2 2>&1 | grep -v 'already in use' || true

echo "==> Writing demo credential"
vex vault kv put secret/app/credentials \
  username=poc-user \
  password=s3cr3t-from-cluster-a

echo "==> Uploading app-read policy"
KCA kubectl -n "${NS}" exec -i "${LEADER}" -- env VAULT_TOKEN="${VAULT_TOKEN}" \
  vault policy write app-read - < "${ROOT}/vault/policies/app-read.hcl"

echo "==> Enabling JWT auth at auth/jwt-cluster-b"
vex vault auth enable -path=jwt-cluster-b jwt 2>&1 | grep -v 'already' || true

echo "==> Copying PEM into Vault pod and configuring JWT auth"
KCA kubectl -n "${NS}" cp /tmp/cluster-b-pubkeys.pem "${NS}/${LEADER}:/tmp/cluster-b-pubkeys.pem"
vex sh -c "vault write auth/jwt-cluster-b/config \
  jwt_validation_pubkeys=@/tmp/cluster-b-pubkeys.pem \
  bound_issuer=\"${CLUSTER_B_ISSUER}\" \
  default_role=app"

echo "==> Creating role 'app'"
vex vault write auth/jwt-cluster-b/role/app \
  role_type=jwt \
  bound_audiences=vault \
  user_claim=sub \
  bound_subject=system:serviceaccount:app:vault-consumer \
  token_policies=app-read \
  token_ttl=1h

echo "==> Verify"
vex vault read auth/jwt-cluster-b/role/app 2>&1 | grep -E 'bound_audiences|bound_subject|token_policies'
