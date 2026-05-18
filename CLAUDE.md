# vault-tailscale — Claude Code notes

POC of **cross-cluster secret retrieval**:
- **Cluster A** runs HashiCorp Vault (Raft, single replica) and a Tailscale
  egress-proxy Deployment that exposes Vault on the tailnet.
- **Cluster B** runs a Go service. Its pod has a `tailscale` sidecar +
  `vault-agent` sidecar + `app` (busybox running a hostPath-mounted Go
  binary). Vault Agent authenticates with a projected SA token (audience
  `vault`); Vault validates it **offline** against Cluster B's JWKS
  converted to PEM.

No shared IP space, no cross-cluster API access, no long-lived tokens
in the app.

---

## Where things live

| Path | Purpose |
|---|---|
| `app/` | Go source, Dockerfile (reference only), K8s manifests for Cluster B |
| `vault/` | Helm values, init/configure scripts for Cluster A |
| `tailscale/` | Egress-proxy Deployment for Cluster A |
| `scripts/` | Runbook (`00`→`01`→`03`→`02`→`99`) + helpers |
| `docs/` | Deep dives on architecture / Tailscale / Vault JWT |
| `.env.example` | User-provided: `TS_AUTHKEY`, `PLAY_A`, `PLAY_B` (everything else is auto-derived) |

---

## Most common tasks

| Goal | How |
|---|---|
| Set up from scratch | Follow `README.md` Quickstart (`00 → 01 → 03 → re-source → 02 → 99`) |
| Verify it's still working | `bash scripts/99-verify.sh` |
| Rotate the demo credential | See `README.md` § Testing → Live secret rotation |
| Monitor in a TUI | `bash scripts/monitor.sh` (k9s, both contexts loaded) |
| Tear down | `labctl playground stop $PLAY_A $PLAY_B` then `rm -f .env .vault-init.json .kubeconfig` |
| Re-establish API tunnels after they die | `bash scripts/00-setup-kubeconfigs.sh` |

Always `set -a; source .env; set +a` before running scripts. Scripts 00
and 03 write values back to `.env`, so re-source after each.

---

## State expectations

The repo is gitignored against runtime artifacts:

- `.env` — your `TS_AUTHKEY` + the auto-derived `KUBECONFIG_A/B` /
  `VAULT_TAILNET_HOST` / `PLAY_A/B`.
- `.vault-init.json` — Vault root token + unseal key from
  `vault/bootstrap/init-unseal.sh`. **Treat as a secret.**
- `.kubeconfig` — merged kubeconfig used by `scripts/monitor.sh`.
- `.logs/` — port-forward logs.

Never commit these. The `.gitignore` already protects them; double-check
before `git add -A`.

---

## Gotchas (real ones, caught by replay)

- **Tailscale hostname collision.** Stale ephemeral devices from a
  previous run linger ~5 min, causing the new proxy to land on
  `vault-cluster-a-1` instead of `vault-cluster-a`. Script 03 reads the
  *actual* assigned name from `tailscale status --json | jq -r .Self.DNSName`
  and writes it to `VAULT_TAILNET_HOST` in `.env`. The agent ConfigMap
  has `VAULT_TAILNET_HOST_PLACEHOLDER` which script 02 substitutes at
  apply time.
- **k3s-bare is single-node** → Vault Helm chart's pod anti-affinity
  blocks `ha.replicas: 2+`. Pinned to 1 in `vault/helm-values.yaml`.
- **`labctl kube-proxy` races its internal SSH port** with two
  concurrent playgrounds. Script 00 uses `labctl ssh -- 'cat'` to pull
  the kubeconfig and `labctl port-forward -L` for the API server.
- **No image registry in the playground.** The Go app is built locally
  with `CGO_ENABLED=0`, shipped to the k3s node over base64-over-SSH,
  and hostPath-mounted under busybox. See `scripts/02-bootstrap-cluster-b.sh`.
- **Vault has no `jwks_pairs` parameter.** `configure-auth.sh` converts
  Cluster B's JWKS to PEM via Python `cryptography` and uses
  `jwt_validation_pubkeys` instead.
- **ConfigMap YAML literal blocks** don't tolerate unindented heredoc
  bodies. The agent template is inlined as a single quoted string in
  `app/k8s/configmap-agent.yaml`.
- **Tailscale sidecar needs RBAC** for the `tailscale-state-app-b`
  Secret. Granted in `app/k8s/serviceaccount.yaml`.

---

## Debugging cheatsheet

```bash
set -a; source .env; set +a

# Pod state
KUBECONFIG=$KUBECONFIG_B kubectl -n app get pod -l app=vault-consumer

# Per-container logs (replace <ctr> with: tailscale | vault-agent | app)
POD=$(KUBECONFIG=$KUBECONFIG_B kubectl -n app get pod -l app=vault-consumer -o jsonpath='{.items[0].metadata.name}')
KUBECONFIG=$KUBECONFIG_B kubectl -n app logs $POD -c <ctr> --tail=30

# Tailscale visibility on each side
KUBECONFIG=$KUBECONFIG_A kubectl -n tailscale exec deploy/vault-tailscale-proxy -c tailscale -- tailscale status
KUBECONFIG=$KUBECONFIG_B kubectl -n app          exec $POD                       -c tailscale -- tailscale status

# Vault state + role
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- vault status
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .vault-init.json) \
  vault read auth/jwt-cluster-b/role/app
```

### Common symptoms

| Symptom | Likely cause |
|---|---|
| `vault-agent` logs: `dial tcp ...: i/o timeout` | Tailscale not yet authenticated, or `VAULT_TAILNET_HOST` points to a stale offline device. Verify with `tailscale status` from inside the sidecar. |
| `vault-agent` logs: `lookup <host> on 10.43.0.10:53: no such host` | The Tailscale proxy in Cluster A is down, OR `VAULT_TAILNET_HOST` not substituted into the ConfigMap. |
| `tailscale` sidecar in CrashLoopBackOff with `missing get permission on secret` | RBAC missing — confirm `vault-consumer-tailscale` Role exists in `app` ns. |
| `vault-1` / `vault-2` Pending forever | Multi-replica + single-node — `helm-values.yaml` should already pin `ha.replicas: 1`. |
| `vault-agent` logs: `error authenticating: ... permission denied` | Vault role's `bound_subject` doesn't match Cluster B's SA, OR JWKS PEM out of date. |

---

## What not to do

- Don't push `.env`, `.vault-init.json`, `.kubeconfig`, or `.logs/`. Gitignore
  already protects them, but verify with `git status` before any add.
- Don't hard-code `vault-cluster-a` anywhere new — always use
  `${VAULT_TAILNET_HOST}`.
- Don't enable Vault HA replicas > 1 on k3s-bare (single node, anti-affinity).
- Don't add fallbacks for `kubectl` failures inside scripts — let them
  exit non-zero so problems surface, don't hide them.
- Don't graduate the raw `tailscale/tailscale` containers in production —
  switch to the Tailscale Kubernetes Operator.

---

## Useful repo URLs

- GitHub: <https://github.com/ccyrene/vault-tailscale>
- HashiCorp Vault docs: <https://developer.hashicorp.com/vault/docs>
- Tailscale Kubernetes guide: <https://tailscale.com/kb/1185/kubernetes>
- iximiuz Labs `labctl`: <https://labs.iximiuz.com/cli>
