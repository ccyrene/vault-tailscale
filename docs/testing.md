# Testing scenarios

Always source `.env` first:

```bash
set -a; source .env; set +a
POD=$(KUBECONFIG=$KUBECONFIG_B kubectl -n app get pod -l app=vault-consumer -o jsonpath='{.items[0].metadata.name}')
```

## Smoke test

```bash
bash scripts/99-verify.sh
```

What it checks: app pod is `3/3 Ready`, agent rendered
`/vault/secrets/credentials`, the Go app prints them, and `/creds` returns
them through `kubectl port-forward`. Last line is `==> PASS`.

## Cross-cluster auth status

```bash
# Vault healthy + role wired
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- vault status
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .vault-init.json) \
  vault read auth/jwt-cluster-b/role/app

# Both Tailscale peers visible from each side
KUBECONFIG=$KUBECONFIG_A kubectl -n tailscale exec deploy/vault-tailscale-proxy -- tailscale status
KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c tailscale -- tailscale status
```

Non-zero `tx`/`rx` in the `tailscale status` output ⇒ real traffic has
crossed the tunnel.

## Live secret rotation

Prove updates flow through without a restart:

```bash
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .vault-init.json) \
  vault kv put secret/app/credentials \
    username=poc-user-v2 password=rotated-$(date +%s)
```

The agent re-renders within `static_secret_render_interval` (Vault Agent
default 5 min). To force an immediate re-read, restart only the agent
container:

```bash
KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c vault-agent -- /bin/sh -c 'kill 1'
sleep 10
KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c app -- cat /vault/secrets/credentials
```

`restartCount` will tick up only on `vault-agent` — `app` and `tailscale`
stay untouched.

## Failure mode — Vault denies access

```bash
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .vault-init.json) \
  vault write auth/jwt-cluster-b/role/app \
    role_type=jwt bound_audiences=vault user_claim=sub \
    bound_subject=system:serviceaccount:app:DOES-NOT-EXIST \
    token_policies=app-read token_ttl=1h

KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c vault-agent -- /bin/sh -c 'kill 1'
KUBECONFIG=$KUBECONFIG_B kubectl -n app logs $POD -c vault-agent --tail=10
```

Expect: `error authenticating: ... permission denied`.

Restore by re-running with
`bound_subject=system:serviceaccount:app:vault-consumer`.

## Failure mode — sever the tailnet

```bash
KUBECONFIG=$KUBECONFIG_A kubectl -n tailscale scale deploy/vault-tailscale-proxy --replicas=0
KUBECONFIG=$KUBECONFIG_B kubectl -n app logs $POD -c vault-agent -f
```

Expect: `lookup $VAULT_TAILNET_HOST on 10.43.0.10:53: no such host`.

Restore with `--replicas=1`.
