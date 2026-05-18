#!/usr/bin/env bash
# Merge KUBECONFIG_A + KUBECONFIG_B into ./.kubeconfig with sane context
# names: `cluster-a-vault` and `cluster-b-app`.
#
# Run AFTER 00-setup-kubeconfigs.sh (which produces the two per-cluster
# kubeconfigs). Safe to re-run — overwrites .kubeconfig.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"

: "${KUBECONFIG_A:?source .env first}"
: "${KUBECONFIG_B:?source .env first}"

require() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 1; }; }
require kubectl
require python3

tmpA=$(mktemp); tmpB=$(mktemp)
cp "${KUBECONFIG_A}" "${tmpA}"
cp "${KUBECONFIG_B}" "${tmpB}"

rename_all () {
  local file="$1" cluster="$2" user="$3" ctx="$4" old_ctx="${5:-default}"
  KUBECONFIG="${file}" kubectl config rename-context "${old_ctx}" "${ctx}" >/dev/null
  python3 - "${file}" "${cluster}" "${user}" <<'PY'
import sys, yaml
path, cluster, user = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(path))
for c in d['clusters']: c['name'] = cluster
for u in d['users']:    u['name'] = user
for ctx in d['contexts']:
    ctx['context']['cluster'] = cluster
    ctx['context']['user']    = user
open(path, 'w').write(yaml.safe_dump(d))
PY
}

rename_all "${tmpA}" cluster-a cluster-a-admin cluster-a-vault
rename_all "${tmpB}" cluster-b cluster-b-admin cluster-b-app

KUBECONFIG="${tmpA}:${tmpB}" kubectl config view --flatten > "${ROOT}/.kubeconfig"
chmod 600 "${ROOT}/.kubeconfig"
rm -f "${tmpA}" "${tmpB}"

echo "==> wrote ${ROOT}/.kubeconfig"
KUBECONFIG="${ROOT}/.kubeconfig" kubectl config get-contexts
