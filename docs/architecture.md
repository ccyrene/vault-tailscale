# Architecture

![overview](../images/overview.png)

## What runs where

| | Cluster A — **Vault** | Cluster B — **App** |
|---|---|---|
| Vault | `vault-0` (HA + Raft, single replica for the POC; bump on multi-node) | — |
| Tailscale | `vault-tailscale-proxy` Deployment (`tailscale` ns) — registers `vault-cluster-a` on the tailnet, `TS_DEST_IP` forwards to Vault ClusterIP | sidecar inside the app pod (registers `app-cluster-b`) |
| App | — | `vault-consumer` pod, 3 containers: `tailscale` + `vault-agent` + `app` |
| Trust | Trusts JWTs signed by Cluster B's API server (uploaded as PEM at `auth/jwt-cluster-b`) | Mints projected SA tokens with `audience=vault` |

The two Tailscale nodes form a WireGuard tunnel directly between each other.
Tailscale's coordination plane only brokers keys; no application traffic
traverses Tailscale's servers.

## Request flow

```
app container (Cluster B pod)
  │  reads /vault/secrets/credentials   (file written by sidecar)
  │
  ├──────── shared emptyDir tmpfs ────────┐
  │                                       │
vault-agent container (same pod)          │
  │  HTTP GET http://vault-cluster-a:8200/v1/secret/data/app/credentials
  │  ↑ MagicDNS resolved via Tailscale sidecar's DNS injection
  │
tailscale sidecar (same pod)
  │  WireGuard direct tunnel
  ↓
vault-tailscale-proxy pod (Cluster A `tailscale` ns)
  │  TS_DEST_IP → 10.43.x.y:8200
  ↓
Vault pod (Cluster A `vault` ns)
  │  validates JWT offline using Cluster B's PEM pubkeys
  │  bound_audiences=[vault], bound_subject=system:serviceaccount:app:vault-consumer
  │  returns kv-v2 secret
  └─────────────────────────────────────►
```

## Why these specific choices

- **Egress-proxy + sidecar over subnet routers.** Both k3s clusters default to
  the same Service CIDR (`10.43.0.0/16`), so kernel-mode subnet routing would
  collide; userspace routing doesn't actually deliver packets to other pods
  without per-port hints. Treating Vault as a tailnet-addressable service and
  letting each app pod join the tailnet directly sidesteps both problems.
- **Raft over Consul** for Vault storage — no external dep, smaller blast
  radius, easy to operate.
- **JWT auth, not native `kubernetes` auth.** Kubernetes auth would force
  Vault in Cluster A to call Cluster B's TokenReview API; that's a
  cross-cluster API hit needing more wiring. JWT only needs Cluster B's
  *public keys*, uploaded once at bootstrap.
- **Vault Agent sidecar over direct SDK calls.** The Go app stays small (it
  just reads a file). All the auth and renewal logic lives in a
  well-tested HashiCorp binary.
- **Static Go binary on hostPath** instead of a custom container image —
  the k3s-bare playground has no Docker, buildah, or registry, and shipping
  ~5 MB over `labctl ssh` is faster than spinning up a registry.
