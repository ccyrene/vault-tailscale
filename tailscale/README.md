# Tailscale manifests

This POC uses the **egress-proxy + sidecar** pattern, not the subnet-router
pattern shown in the architecture image. See `../docs/tailscale-setup.md`
for the full rationale.

## What's here

- **`cluster-a-router.yaml`** — Deployment in the `tailscale` namespace on
  Cluster A. Joins the tailnet as `vault-cluster-a`. An init container
  resolves Vault's ClusterIP via `nslookup` and writes it to a shared
  emptyDir; the main container reads it and sets `TS_DEST_IP` so all
  inbound tailnet traffic forwards to Vault:8200.

- **`cluster-b-router.yaml`** — intentionally empty (a comment file). The
  Cluster B side of the tailnet is the `tailscale` sidecar inside the app
  Deployment in `../app/k8s/deployment.yaml`. Keeping the file lets anyone
  exploring this dir find an explanation.

## Apply (Cluster A only)

`scripts/03-wire-tailscale.sh` does this for you. Manually:

```bash
kubectl --kubeconfig $KUBECONFIG_A create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
kubectl --kubeconfig $KUBECONFIG_A -n tailscale create secret generic tailscale-auth \
  --from-literal=TS_AUTHKEY="$TS_AUTHKEY"
kubectl --kubeconfig $KUBECONFIG_A apply -f cluster-a-router.yaml
```
