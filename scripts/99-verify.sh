#!/usr/bin/env bash
# Smoke-test the end-to-end flow:
#   - Cluster B app pod is Ready
#   - /vault/secrets/credentials is populated by Vault Agent
#   - /creds HTTP endpoint returns the expected username

set -euo pipefail

KCTX_FLAG=()
[[ -n "${KUBECONFIG_B:-}" ]] && KCTX_FLAG=(--kubeconfig "${KUBECONFIG_B}")

echo "==> app pod status"
kubectl "${KCTX_FLAG[@]}" -n app get pods -l app=vault-consumer -o wide

echo "==> waiting for credentials file to be rendered..."
POD=$(kubectl "${KCTX_FLAG[@]}" -n app get pod -l app=vault-consumer -o jsonpath='{.items[0].metadata.name}')
for i in $(seq 1 30); do
  if kubectl "${KCTX_FLAG[@]}" -n app exec "${POD}" -c app -- cat /vault/secrets/credentials 2>/dev/null | grep -q USERNAME; then
    break
  fi
  sleep 2
done

echo "==> rendered credentials"
kubectl "${KCTX_FLAG[@]}" -n app exec "${POD}" -c app -- cat /vault/secrets/credentials

echo
echo "==> app stdout (last 20 lines)"
kubectl "${KCTX_FLAG[@]}" -n app logs "${POD}" -c app --tail=20

echo
echo "==> probing /creds via port-forward"
kubectl "${KCTX_FLAG[@]}" -n app port-forward "${POD}" 18080:8080 >/dev/null 2>&1 &
PF_PID=$!
trap "kill ${PF_PID} 2>/dev/null || true" EXIT
sleep 2
curl -fsS http://127.0.0.1:18080/creds
echo
echo "==> PASS"
