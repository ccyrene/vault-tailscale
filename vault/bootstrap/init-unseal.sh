#!/usr/bin/env bash
# Initialize Vault, capture root token + unseal key, unseal vault-0.
# Single-node version (matches helm-values.yaml ha.replicas=1).
#
# Outputs ./.vault-init.json — keep safe, gitignored by default.
# Idempotent-ish: refuses to overwrite an existing .vault-init.json.

set -euo pipefail

NS="${VAULT_NAMESPACE:-vault}"
LEADER="vault-0"
SECRETS_FILE="${SECRETS_FILE:-./.vault-init.json}"
KUBECONFIG="${KUBECONFIG_A:-${KUBECONFIG:-}}"
[[ -n "$KUBECONFIG" ]] && export KUBECONFIG

require() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
require kubectl
require jq

if [[ -f "$SECRETS_FILE" ]]; then
  echo "==> ${SECRETS_FILE} already exists; skipping init (delete the file to force re-init)."
  exit 0
fi

echo "==> Waiting for ${LEADER} container to be Running..."
for i in $(seq 1 60); do
  state=$(kubectl -n "${NS}" get pod "${LEADER}" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null || true)
  [[ "$state" == *running* ]] && break
  sleep 2
done

echo "==> Initializing Vault..."
kubectl -n "${NS}" exec -i "${LEADER}" -- \
  vault operator init -key-shares=1 -key-threshold=1 -format=json > "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"

UNSEAL=$(jq -r '.unseal_keys_b64[0]' "${SECRETS_FILE}")
ROOT=$(jq -r '.root_token' "${SECRETS_FILE}")

echo "==> Unsealing..."
kubectl -n "${NS}" exec -i "${LEADER}" -- vault operator unseal "${UNSEAL}" >/dev/null

echo
echo "==> Done. Root token written to ${SECRETS_FILE}"
echo "    Export with:  export VAULT_TOKEN=\$(jq -r .root_token ${SECRETS_FILE})"
