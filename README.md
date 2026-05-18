# vault-tailscale

> **Cross-cluster secret retrieval over a Tailscale mesh.**
> Cluster A runs HashiCorp Vault. Cluster B runs a Go service. They share
> no IP space and no API access — Vault is reached over a WireGuard tunnel,
> and the app authenticates with a short-lived Kubernetes JWT validated
> offline by Vault.

![architecture](images/overview.png)

---

## Contents

- [Quickstart](#quickstart)
- [Architecture](#architecture)
- [Repo layout](#repo-layout)
- [Testing](#testing)
- [Results](#results)
- [Known limitations](#known-limitations)
- [Production hardening](#production-hardening)
- [Further reading](#further-reading)

---

## Quickstart

> Prerequisites: `kubectl`, `helm`, `jq`, `curl`, `python3` (with `cryptography`),
> `go ≥ 1.22`, [`labctl`](https://labs.iximiuz.com/cli), and a
> [Tailscale](https://login.tailscale.com) auth key (reusable + ephemeral,
> tag `tag:k8s-router`).

### 1. Start two iximiuz playgrounds

```bash
labctl playground start k3s-bare   # → PLAY_A
labctl playground start k3s-bare   # → PLAY_B
```

### 2. Configure `.env`

```bash
cp .env.example .env
$EDITOR .env                       # fill TS_AUTHKEY, PLAY_A, PLAY_B
set -a; source .env; set +a
```

### 3. Pull kubeconfigs + bring up Vault

```bash
bash scripts/00-setup-kubeconfigs.sh
set -a; source .env; set +a        # picks up KUBECONFIG_A / KUBECONFIG_B
bash scripts/01-bootstrap-cluster-a.sh
```

### 4. Wire Tailscale + deploy the app

```bash
bash scripts/03-wire-tailscale.sh
set -a; source .env; set +a        # picks up VAULT_TAILNET_HOST
bash scripts/02-bootstrap-cluster-b.sh
```

### 5. Verify

```bash
bash scripts/99-verify.sh
```

You should land on **`==> PASS`** with the credentials printed. See
[Results](#results) for the full expected output.

> **Optional — multi-cluster TUI**
>
> ```bash
> bash scripts/build-kubeconfig.sh
> bash scripts/monitor.sh            # k9s; switch contexts with `:ctx`
> ```

---

## Architecture

| Cluster | Workload | Tailscale role |
|---|---|---|
| **A — Vault** | `vault-0` (Raft, single replica) in `vault` ns | `vault-tailscale-proxy` Deployment in `tailscale` ns — joins the tailnet, `TS_DEST_IP` forwards inbound to the Vault Service ClusterIP. |
| **B — App** | `vault-consumer` pod (3 containers: `tailscale` + `vault-agent` + `app`) in `app` ns | Sidecar inside the app pod — joins the tailnet, programs routes for the whole pod's network namespace, accepts DNS so MagicDNS resolves `vault-cluster-a`. |

### Request flow

```
app container (Cluster B)            reads /vault/secrets/credentials
                                              ▲
                                              │ (shared emptyDir tmpfs)
vault-agent container (same pod)              │
   GET http://$VAULT_TAILNET_HOST:8200/v1/secret/data/app/credentials
                                              ▼
tailscale sidecar (same pod)         WireGuard direct tunnel
                                              ▼
vault-tailscale-proxy pod (Cluster A)  TS_DEST_IP → Vault ClusterIP:8200
                                              ▼
vault-0 pod (Cluster A)              validates JWT offline (PEM pubkeys)
                                     bound_audiences=[vault]
                                     bound_subject=system:serviceaccount:app:vault-consumer
                                     returns kv-v2 secret
```

For deeper notes, see [`docs/architecture.md`](docs/architecture.md),
[`docs/tailscale-setup.md`](docs/tailscale-setup.md), and
[`docs/vault-jwt-auth.md`](docs/vault-jwt-auth.md).

---

## Repo layout

```
app/                  Go service + manifests (Cluster B)
  ├── main.go         Reads /vault/secrets/credentials, logs every 15 s
  ├── Dockerfile      For reference; this POC hostPath-mounts the binary instead
  └── k8s/            ServiceAccount, RBAC, ConfigMap, Deployment

vault/                Cluster A — Vault config
  ├── helm-values.yaml          HA + Raft, single replica
  ├── policies/app-read.hcl     Vault policy for the app role
  └── bootstrap/                init-unseal.sh, configure-auth.sh

tailscale/            Cluster A — egress proxy
  └── cluster-a-router.yaml     Deployment + RBAC

scripts/              Runbook + helpers (run from repo root)
docs/                 Deep-dives
images/overview.png   Architecture diagram
```

---

## Testing

### Smoke test (end-to-end)

```bash
bash scripts/99-verify.sh
```

What it checks: app pod is `3/3 Ready`, the agent rendered
`/vault/secrets/credentials`, the Go app prints them, and the HTTP `/creds`
endpoint returns them via `kubectl port-forward`.

### Cross-cluster auth status

```bash
set -a; source .env; set +a

# Vault healthy + role wired
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- vault status
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .vault-init.json) \
  vault read auth/jwt-cluster-b/role/app

# Both Tailscale peers can see each other
KUBECONFIG=$KUBECONFIG_A kubectl -n tailscale exec deploy/vault-tailscale-proxy -- tailscale status
POD=$(KUBECONFIG=$KUBECONFIG_B kubectl -n app get pod -l app=vault-consumer -o jsonpath='{.items[0].metadata.name}')
KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c tailscale -- tailscale status
```

### Live secret rotation

Prove updates flow through without a restart:

```bash
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .vault-init.json) \
  vault kv put secret/app/credentials \
    username=poc-user-v2 password=rotated-$(date +%s)
```

The agent re-renders within `static_secret_render_interval` (Vault Agent
default 5 min). To force immediate re-read, kill PID 1 in the agent
container — Kubernetes restarts only that container:

```bash
KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c vault-agent -- /bin/sh -c 'kill 1'
sleep 10
KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c app -- cat /vault/secrets/credentials
```

### Failure mode — Vault denies access

```bash
KUBECONFIG=$KUBECONFIG_A kubectl -n vault exec vault-0 -- \
  env VAULT_TOKEN=$(jq -r .root_token .vault-init.json) \
  vault write auth/jwt-cluster-b/role/app \
    role_type=jwt bound_audiences=vault user_claim=sub \
    bound_subject=system:serviceaccount:app:DOES-NOT-EXIST \
    token_policies=app-read token_ttl=1h

KUBECONFIG=$KUBECONFIG_B kubectl -n app exec $POD -c vault-agent -- /bin/sh -c 'kill 1'
KUBECONFIG=$KUBECONFIG_B kubectl -n app logs $POD -c vault-agent --tail=10
# Expect: "error authenticating: ... permission denied"
```

Restore by re-running the same command with
`bound_subject=system:serviceaccount:app:vault-consumer`.

### Failure mode — sever the tailnet

```bash
KUBECONFIG=$KUBECONFIG_A kubectl -n tailscale scale deploy/vault-tailscale-proxy --replicas=0
KUBECONFIG=$KUBECONFIG_B kubectl -n app logs $POD -c vault-agent -f
# Expect: lookup $VAULT_TAILNET_HOST on 10.43.0.10:53: no such host
```

Restore with `--replicas=1`.

---

## Results

### `99-verify.sh` happy path

```
==> app pod status
NAME                              READY   STATUS    RESTARTS   AGE
vault-consumer-647dcd889d-l9vr7   3/3     Running   0          48s

==> rendered credentials
USERNAME=poc-user
PASSWORD=s3cr3t-from-cluster-a
ROTATED_AT=2026-05-18T10:30:39Z

==> probing /creds via port-forward
USERNAME=poc-user
PASSWORD=s3cr3t-from-cluster-a
ROTATED_AT=2026-05-18T10:30:39Z

==> PASS
```

### Tailscale mesh — both peers visible

```
# From Cluster A's egress proxy:
100.81.216.16  vault-cluster-a  vault-cluster-a.tailXXXXX.ts.net  linux  -
100.65.156.29  app-cluster-b    tagged-devices                    linux  idle, tx 4460 rx 4372
```

```
# From the app pod's Tailscale sidecar in Cluster B:
100.65.156.29  app-cluster-b    app-cluster-b.tailXXXXX.ts.net    linux  -
100.81.216.16  vault-cluster-a  tagged-devices                    linux  idle, tx 4548 rx 4332
```

Non-zero `tx`/`rx` ⇒ real traffic has crossed the tunnel.

### Cross-cluster JWT handshake (Vault Agent logs)

```
agent.auth.handler: authenticating
agent.auth.handler: authentication successful, sending token to sinks
agent.auth.handler: starting renewal process
agent.sink.file:    token written: path=/home/vault/.vault-token
agent.auth.handler: renewed auth token
agent: (runner) rendered "(dynamic)" => "/vault/secrets/credentials"
```

That is the full handshake: read projected SA token → POST to the JWT
auth endpoint over the tunnel → receive a Vault token → template renders
the secret file.

---

## Known limitations

- **TLS disabled on Vault.** Fine over Tailscale; you still want mTLS for prod.
- **Single Vault replica, Shamir 1/1.** Trivial to unseal *and* to lose.
  Use Shamir 5/3 or KMS auto-unseal in real deployments.
- **Open Tailscale ACL** (`* → *:*`). Tighten to scoped tags + explicit ports.
- **Raw Tailscale containers**, not the operator — see
  [`docs/tailscale-setup.md`](docs/tailscale-setup.md) §6.
- **Static demo credential.** Use Vault's `database` secrets engine for
  real ephemeral, per-request credentials.
- **`labctl kube-proxy` races its internal SSH port** with two concurrent
  playgrounds. `scripts/00-setup-kubeconfigs.sh` works around it.
- **k3s-bare is single-node** — pod anti-affinity blocks `ha.replicas: 2+`,
  so the chart is pinned to 1.
- **Stale Tailscale ephemeral devices** can linger ~5 min after teardown,
  causing the new proxy to land on `vault-cluster-a-1`. Script 03 detects
  this and writes the *actual* hostname to `VAULT_TAILNET_HOST` in `.env`;
  the agent ConfigMap is templated to use it. Delete stale devices in the
  Tailscale admin console for a clean rerun.
- **No image registry in the playground.** The Go app builds locally and
  is hostPath-mounted under busybox.

---

## Production hardening

1. Enable TLS on Vault; mTLS end-to-end through the egress proxy.
2. Shamir 5/3 or KMS auto-unseal (`seal "awskms"`, `seal "gcpckms"`, ...).
3. Vault HA with ≥ 3 replicas on a multi-node cluster, anti-affinity by zone.
4. Tighten Tailscale ACLs to scoped tags and explicit ports.
5. Replace raw `tailscale/tailscale` containers with the
   [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator).
6. Use Vault's `database` secrets engine for ephemeral per-request creds.
7. Set `template_config { static_secret_render_interval = "10s" }` if you
   need sub-minute rotation pickup.
8. Move bootstrap from imperative shell to Terraform / Bank-Vaults.
9. Mount the projected SA token with `expirationSeconds: 600` and trust
   the kubelet's auto-rotation.

---

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — design rationale.
- [`docs/tailscale-setup.md`](docs/tailscale-setup.md) — Tailscale wiring,
  ACL examples, when to use the operator.
- [`docs/vault-jwt-auth.md`](docs/vault-jwt-auth.md) — offline JWT
  validation, JWKS → PEM, role binding.
- [`CLAUDE.md`](CLAUDE.md) — project notes auto-loaded by Claude Code.

## Credits

[HashiCorp Vault](https://www.vaultproject.io/) ·
[Tailscale](https://tailscale.com/) ·
[iximiuz Labs](https://labs.iximiuz.com/) ·
[k9s](https://k9scli.io/)
