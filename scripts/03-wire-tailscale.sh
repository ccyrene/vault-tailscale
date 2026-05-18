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

echo "==> [A] proxy joined tailnet as:"
kubectl -n tailscale exec deploy/vault-tailscale-proxy -- tailscale status 2>&1 \
  | grep -v 'Defaulted container' | head -5

cat <<EOF

==> Done. Cluster B's Tailscale is the sidecar in the app Deployment —
   it joins the tailnet on first apply (script 02) and discovers
   'vault-cluster-a' via MagicDNS automatically.
EOF
