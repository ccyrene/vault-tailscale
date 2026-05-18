#!/usr/bin/env bash
# Launch k9s with both clusters loaded as separate contexts.
#
# Usage:  bash scripts/monitor.sh [-c <context>]
#         scripts/monitor.sh -c cluster-a-vault   # start on Cluster A
#         scripts/monitor.sh -c cluster-b-app     # start on Cluster B
#
# Inside k9s:
#   :ctx          → list contexts, switch with arrow + Enter
#   :pod          → pods in current namespace
#   :ns           → pick namespace
#   l             → logs (live)
#   s             → shell into pod
#   ?             → keybindings
#   :q            → quit
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KC="${ROOT}/.kubeconfig"

[[ -f "${KC}" ]] || { echo "Run scripts/build-kubeconfig.sh first." >&2; exit 1; }
command -v k9s >/dev/null || command -v "$HOME/.local/bin/k9s" >/dev/null || {
  echo "k9s not on PATH. Install with: curl -sL https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz | tar -xz -C $HOME/.local/bin k9s" >&2
  exit 1
}

K9S=$(command -v k9s 2>/dev/null || echo "$HOME/.local/bin/k9s")
exec env KUBECONFIG="${KC}" "${K9S}" "$@"
