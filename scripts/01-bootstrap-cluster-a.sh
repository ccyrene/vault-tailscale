#!/usr/bin/env bash
# Cluster A: install Vault (HA chart, single-replica for k3s), init, unseal,
# enable kv-v2, store demo credential, enable jwt-cluster-b auth method
# trusting Cluster B's SA tokens offline (JWKS converted to PEM).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${KUBECONFIG_A:?source .env first}"
export KUBECONFIG="${KUBECONFIG_A}"

echo "==> [A] adding HashiCorp Helm repo"
helm repo add hashicorp https://helm.releases.hashicorp.com >/dev/null 2>&1 || true
helm repo update hashicorp >/dev/null

echo "==> [A] installing Vault"
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install vault hashicorp/vault \
  -n vault \
  -f "${ROOT}/vault/helm-values.yaml" \
  --wait --timeout 5m || true   # Vault pod is unsealable-but-not-Ready; helm --wait gives up, fine.

echo "==> [A] init + unseal"
bash "${ROOT}/vault/bootstrap/init-unseal.sh"
export VAULT_TOKEN=$(jq -r .root_token "${ROOT}/.vault-init.json")

echo "==> [A] configuring kv-v2, demo secret, JWT auth for Cluster B"
bash "${ROOT}/vault/bootstrap/configure-auth.sh"

echo
echo "==> [A] done. Vault service:"
kubectl -n vault get svc vault
