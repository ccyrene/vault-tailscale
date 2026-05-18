#!/usr/bin/env bash
# Workaround for `labctl kube-proxy` racing on its internal SSH port when
# more than one playground is in play. Pulls each cluster's kubeconfig over
# `labctl ssh` (works reliably), patches the server URL, and starts a
# long-lived `labctl port-forward` for the API server on a unique local port.
#
# Requires PLAY_A and PLAY_B in .env. Writes KUBECONFIG_A/B to .env on success.
#
# Re-runnable: existing port-forward processes are not killed; if a port is
# already taken, this script logs that and continues.

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

: "${PLAY_A:?set PLAY_A in .env}"
: "${PLAY_B:?set PLAY_B in .env}"

LABCTL=${LABCTL:-$HOME/.iximiuz/labctl/bin/labctl}
PLAYS_DIR=${PLAYS_DIR:-$HOME/.iximiuz/labctl/plays}

setup_one() {
  local SIDE="$1" PLAY="$2" LOCAL_PORT="$3"
  local DIR="${PLAYS_DIR}/${PLAY}-k3s-01-laborant"
  local KC="${DIR}/kubeconfig"
  mkdir -p "${DIR}"

  echo "==> [${SIDE}] copying kubeconfig out of ${PLAY} via ssh"
  "${LABCTL}" ssh "${PLAY}" --machine k3s-01 -- 'sudo cat /etc/rancher/k3s/k3s.yaml' \
    | sed "s#server: https://127.0.0.1:6443#server: https://127.0.0.1:${LOCAL_PORT}#" \
    > "${KC}"
  chmod 600 "${KC}"
  [[ -s "${KC}" ]] || { echo "kubeconfig empty for ${PLAY}" >&2; exit 1; }

  if ss -tlnH "sport = :${LOCAL_PORT}" 2>/dev/null | grep -q .; then
    echo "    port ${LOCAL_PORT} already in use — skipping port-forward (assume already running)"
  else
    echo "==> [${SIDE}] starting labctl port-forward on 127.0.0.1:${LOCAL_PORT}"
    nohup "${LABCTL}" port-forward "${PLAY}" --machine k3s-01 \
      -L "127.0.0.1:${LOCAL_PORT}:127.0.0.1:6443" -q \
      >>"${DIR}/port-forward.log" 2>&1 &
    disown
    sleep 2
  fi

  echo "==> [${SIDE}] sanity check"
  KUBECONFIG="${KC}" kubectl get nodes --request-timeout=5s
  printf '%s\n' "${SIDE} kubeconfig: ${KC}"
}

setup_one A "${PLAY_A}" 6443
setup_one B "${PLAY_B}" 6444

# Persist into .env (replace previous KUBECONFIG_A/B lines)
ENV_FILE="${ROOT}/.env"
touch "${ENV_FILE}"
tmp=$(mktemp)
grep -v '^KUBECONFIG_A=\|^KUBECONFIG_B=' "${ENV_FILE}" > "${tmp}" || true
{
  cat "${tmp}"
  echo "KUBECONFIG_A=${PLAYS_DIR}/${PLAY_A}-k3s-01-laborant/kubeconfig"
  echo "KUBECONFIG_B=${PLAYS_DIR}/${PLAY_B}-k3s-01-laborant/kubeconfig"
} > "${ENV_FILE}"
rm -f "${tmp}"

echo
echo "==> Done. Re-source .env:"
echo "    set -a; source .env; set +a"
