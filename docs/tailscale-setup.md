# Tailscale setup

## 1. Tailnet prerequisites

1. Sign up at https://login.tailscale.com (free tier is fine).
2. **Personal settings → Keys** → generate an **auth key**:
   - ✅ Reusable
   - ✅ Ephemeral (so playground tear-downs don't leave dead nodes)
   - Tag: `tag:k8s-router` (define it in ACLs first, see below)
3. **Access controls → ACLs** → paste at least this:

```jsonc
{
  "tagOwners": {
    "tag:k8s-router": ["autogroup:admin"]
  },
  "acls": [
    { "action": "accept", "src": ["*"], "dst": ["*:*"] }
  ]
}
```

Tighten the wildcard ACL in production: explicit `src=tag:k8s-cluster-b` →
`dst=tag:k8s-cluster-a:8200`.

## 2. The mesh in this POC

```
          Cluster A (vault ns)              Cluster B (app ns)
   ┌──────────────────────────────┐    ┌──────────────────────────────┐
   │  vault-0  (Service 10.43.x.y)│    │  vault-consumer pod          │
   │           ▲                  │    │   ┌──────────────────────┐   │
   │           │ TS_DEST_IP       │    │   │ app  (busybox+Go)    │   │
   │  ┌────────┴──────────────┐   │    │   │ vault-agent          │   │
   │  │ vault-tailscale-proxy │   │    │   │ tailscale (sidecar)  │◄─┐│
   │  │ TS_HOSTNAME=          │   │    │   └──────────┬───────────┘ ││
   │  │   vault-cluster-a     │   │    │              │ MagicDNS    ││
   │  └──────────┬────────────┘   │    │              ▼             ││
   └─────────────┼────────────────┘    └──────────────┼─────────────┘│
                 │ WireGuard direct                   │              │
                 └────────────────────────────────────┘              │
                                                                     │
        Tailscale control plane (DERP fallback)  ◄──────────────────┘
        (only key exchange + NAT-traversal; no app traffic)
```

## 3. Two ways Tailscale joins a Pod

**Egress proxy** (Cluster A) — Deployment in the `tailscale` namespace runs
`tailscale/tailscale:stable` with:

- `TS_HOSTNAME=vault-cluster-a`
- `TS_DEST_IP=<Vault ClusterIP>` (resolved by an init container)
- `TS_USERSPACE=false`, `NET_ADMIN`, hostPath `/dev/net/tun`

Result: a tailnet node whose inbound traffic gets forwarded to Vault's
ClusterIP on whatever port the caller used.

**Sidecar** (Cluster B) — the app Deployment includes a `tailscale`
container in the SAME pod as the Vault Agent and the Go app. Because they
share a network namespace, kernel-mode Tailscale's tun device + routes
benefit all of them. `TS_EXTRA_ARGS=--accept-dns=true` makes the sidecar
inject Tailscale's MagicDNS into the pod's resolver, so the Vault Agent
can dial `http://vault-cluster-a:8200` by short hostname.

## 4. RBAC the sidecar needs

The Tailscale image stores its state in a Kubernetes Secret named by
`TS_KUBE_SECRET`. The ServiceAccount running the sidecar needs:

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "update", "patch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "patch", "get"]
```

For the egress proxy this lives in the `tailscale` namespace SA
(`tailscale/cluster-a-router.yaml`); for the sidecar it lives in the `app`
namespace SA (`app/k8s/serviceaccount.yaml`).

## 5. Tear-down

Ephemeral auth keys → deleting the Deployments removes the nodes from the
tailnet within ~minutes. Manual cleanup if needed: the **Machines** tab in
the admin console.

## 6. When to graduate off the raw image

For real deployments, use the
[Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator).
It gives you:

- `tailscale.com/expose` annotations on Services for ingress.
- `ProxyClass` for egress with managed certs and rotation.
- A controller that handles RBAC, state secrets, and lifecycle automatically.
- Cleaner ACL story via stable per-Service tags.

The raw-container approach in this POC is fine for learning the moving
parts but is not what you want to run in prod.
