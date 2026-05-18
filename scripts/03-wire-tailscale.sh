#!/usr/bin/env bash
# Deploy the Tailscale egress proxy on Cluster A only. Cluster B's Tailscale
# runs as a SIDECAR inside the app pod (see app/k8s/deployment.yaml), so
# nothing to do on the B side here.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${TS_AUTHKEY:?set TS_AUTHKEY (reusable+ephemeral key)}"
: "${KUBECONFIG_A:?source .env first}"
export KUBECONFIG="${KUBECONFIG_A}"

echo "==> [A] tailscale namespace + auth secret"
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
kubectl -n tailscale create secret generic tailscale-auth \
  --from-literal=TS_AUTHKEY="${TS_AUTHKEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> [A] applying vault-tailscale-proxy"
kubectl apply -f "${ROOT}/tailscale/cluster-a-router.yaml"
kubectl -n tailscale rollout status deploy/vault-tailscale-proxy --timeout=180s

echo "==> [A] waiting for proxy to authenticate to tailnet..."
for i in $(seq 1 30); do
  state=$(kubectl -n tailscale exec deploy/vault-tailscale-proxy -c tailscale -- \
    tailscale status --json 2>/dev/null | jq -r '.BackendState' 2>/dev/null || echo "")
  [[ "$state" == "Running" ]] && break
  sleep 2
done

# DNSName is the actual MagicDNS name Tailscale assigned (handles auto-suffix
# like `-1` when a stale device still holds the requested name). HostName is
# only what we *requested*, which may not be what we got.
VAULT_TAILNET_HOST=$(kubectl -n tailscale exec deploy/vault-tailscale-proxy -c tailscale -- \
  tailscale status --json | jq -r '.Self.DNSName' | cut -d. -f1)

if [[ -z "$VAULT_TAILNET_HOST" || "$VAULT_TAILNET_HOST" == "null" ]]; then
  echo "ERROR: could not determine tailnet hostname" >&2
  exit 1
fi

echo "==> [A] proxy joined tailnet as: ${VAULT_TAILNET_HOST}"
if [[ "$VAULT_TAILNET_HOST" != "vault-cluster-a" ]]; then
  echo "    (Tailscale assigned a suffix because a previous device with that"
  echo "     name was still registered. The agent in Cluster B will use the"
  echo "     actual hostname above via VAULT_TAILNET_HOST in .env.)"
fi

# Persist into .env so 02 picks it up.
ENV_FILE="${ROOT}/.env"
grep -v '^VAULT_TAILNET_HOST=' "${ENV_FILE}" > "${ENV_FILE}.new" && \
  mv "${ENV_FILE}.new" "${ENV_FILE}"
echo "VAULT_TAILNET_HOST=${VAULT_TAILNET_HOST}" >> "${ENV_FILE}"

echo
echo "==> Done. Re-source .env before running script 02:"
echo "    set -a; source .env; set +a"
