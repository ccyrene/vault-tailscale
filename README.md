# vault-tailscale

Cluster B's app pulls credentials from Cluster A's Vault over a Tailscale
tunnel. No shared network, no long-lived tokens in the app.

![architecture](images/overview.png)

## Setup

**Need:** `kubectl`, `helm`, `jq`, `python3` (`cryptography`), `go` ≥ 1.22,
[`labctl`](https://labs.iximiuz.com/cli), and a
[Tailscale auth key](https://login.tailscale.com/admin/settings/keys)
(reusable + ephemeral, tag `tag:k8s-router`).

**1. Start two playgrounds**

```bash
labctl playground start k3s-bare   # → PLAY_A
labctl playground start k3s-bare   # → PLAY_B
```

**2. Fill `.env`** (only `TS_AUTHKEY`, `PLAY_A`, `PLAY_B` — the rest is auto)

```bash
cp .env.example .env && $EDITOR .env
set -a; source .env; set +a
```

**3. Run the scripts** in order. Re-source `.env` between `00→01` and `03→02`
— each writes derived values back.

```bash
bash scripts/00-setup-kubeconfigs.sh    && set -a; source .env; set +a
bash scripts/01-bootstrap-cluster-a.sh
bash scripts/03-wire-tailscale.sh       && set -a; source .env; set +a
bash scripts/02-bootstrap-cluster-b.sh
```

**4. Verify**

```bash
bash scripts/99-verify.sh
```

Expected tail:

```
==== vault credentials ====
USERNAME=poc-user
PASSWORD=s3cr3t-from-cluster-a
ROTATED_AT=2026-05-18T10:30:39Z
===========================
==> PASS
```

## How it works

The app pod runs three containers sharing one network namespace:

- **`tailscale`** sidecar joins the tailnet → the whole pod sees MagicDNS.
- **`vault-agent`** does JWT login at `http://$VAULT_TAILNET_HOST:8200`
  using a projected ServiceAccount token (audience `vault`) and renders
  `/vault/secrets/credentials`.
- **`app`** (Go) reads that file every 15 s and prints it; also serves
  `/healthz` and `/creds`.

On the Vault side, a single `vault-tailscale-proxy` Deployment registers
on the tailnet and forwards inbound traffic to Vault's Service ClusterIP.
Vault validates Cluster B's tokens **offline** using its JWKS (converted
to PEM at bootstrap) — no cross-cluster API access needed.

Deeper notes: [`docs/architecture.md`](docs/architecture.md) ·
[`docs/tailscale-setup.md`](docs/tailscale-setup.md) ·
[`docs/vault-jwt-auth.md`](docs/vault-jwt-auth.md).

## Repository

| Path | What's there |
|---|---|
| `app/` | Go source + manifests (Cluster B) |
| `vault/` | Helm values + bootstrap scripts (Cluster A) |
| `tailscale/` | Egress-proxy Deployment (Cluster A) |
| `scripts/` | Runbook + helpers |
| `docs/` | Architecture, Tailscale, Vault JWT, testing, operations |

## Test it harder

- [`docs/testing.md`](docs/testing.md) — live rotation, denial test, severed-tunnel test.
- `bash scripts/monitor.sh` — multi-cluster TUI via k9s.

## Operations

POC scope: TLS off, single Vault replica, open Tailscale ACL, static demo
credential. The full known-limitations list and a production-hardening
checklist live in [`docs/operations.md`](docs/operations.md).

For Claude Code users picking this up: [`CLAUDE.md`](CLAUDE.md).

## Credits

[HashiCorp Vault](https://www.vaultproject.io/) ·
[Tailscale](https://tailscale.com/) ·
[iximiuz Labs](https://labs.iximiuz.com/) ·
[k9s](https://k9scli.io/)
