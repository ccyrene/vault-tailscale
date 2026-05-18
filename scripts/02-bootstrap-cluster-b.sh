#!/usr/bin/env bash
# Cluster B: build static Go binary locally, ship to the k3s node via labctl
# ssh (no docker available in the playground), apply manifests. The app pod
# has a Tailscale sidecar + Vault Agent sidecar + the Go binary (hostPath-
# mounted into a busybox container).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${TS_AUTHKEY:?set TS_AUTHKEY}"
: "${KUBECONFIG_B:?source .env first}"
: "${PLAY_B:?set PLAY_B}"

LABCTL=${LABCTL:-$HOME/.iximiuz/labctl/bin/labctl}
export KUBECONFIG="${KUBECONFIG_B}"

echo "==> [B] building static Go binary"
( cd "${ROOT}/app" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -ldflags="-s -w" -o /tmp/vault-consumer . )
ls -la /tmp/vault-consumer

echo "==> [B] shipping binary to playground at /opt/vault-consumer/app (base64 over ssh)"
base64 -w0 /tmp/vault-consumer | "${LABCTL}" ssh "${PLAY_B}" --machine k3s-01 -- \
  'sudo mkdir -p /opt/vault-consumer && sudo bash -c "base64 -d > /opt/vault-consumer/app && chmod +x /opt/vault-consumer/app" && ls -la /opt/vault-consumer/app'

echo "==> [B] applying app manifests"
kubectl apply -f "${ROOT}/app/k8s/serviceaccount.yaml"
kubectl -n app create secret generic tailscale-auth \
  --from-literal=TS_AUTHKEY="${TS_AUTHKEY}" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${ROOT}/app/k8s/configmap-agent.yaml"
kubectl apply -f "${ROOT}/app/k8s/deployment.yaml"

echo "==> [B] waiting for all 3 containers Ready (tailscale + vault-agent + app)"
until kubectl -n app get pod -l app=vault-consumer \
  -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null \
  | grep -q 'true true true'; do
  sleep 3
done

echo
echo "==> [B] done."
kubectl -n app get pod -l app=vault-consumer
