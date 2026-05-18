# Operations

## Known limitations (POC scope)

- **TLS disabled on Vault.** Fine over Tailscale; you still want mTLS in prod.
- **Single Vault replica, Shamir 1/1.** Trivial to unseal *and* to lose.
- **Open Tailscale ACL** (`* → *:*`). Tighten to scoped tags + explicit ports.
- **Raw Tailscale containers**, not the Kubernetes Operator — see
  [`tailscale-setup.md`](tailscale-setup.md) §6.
- **Static demo credential.** No automatic rotation upstream.
- **`labctl kube-proxy` races its internal SSH port** with two playgrounds
  in parallel. `scripts/00-setup-kubeconfigs.sh` works around it.
- **k3s-bare is single-node** — pod anti-affinity blocks `ha.replicas: 2+`,
  so the chart is pinned to 1.
- **Stale Tailscale ephemeral devices** can linger ~5 min after teardown,
  causing the new proxy to land on `vault-cluster-a-1` instead of the
  canonical name. Script 03 detects this and writes the actual hostname
  to `VAULT_TAILNET_HOST` in `.env`; the agent ConfigMap is templated.
- **No image registry in the playground.** The Go app builds locally and
  is hostPath-mounted under busybox.

## Production-hardening checklist

1. Enable TLS on Vault; mTLS end-to-end through the egress proxy.
2. Shamir 5/3 or KMS auto-unseal (`seal "awskms"`, `seal "gcpckms"`, …).
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

## Tear-down

```bash
labctl playground stop $PLAY_A $PLAY_B
rm -f .env .vault-init.json .kubeconfig
rm -rf .logs/ ~/.iximiuz/labctl/plays/*
```

Stale Tailscale devices age out automatically (ephemeral keys); delete
them manually from the admin console if you redeploy within ~5 min.
