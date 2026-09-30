#!/usr/bin/env bash
# Create a vCluster on the current host cluster and write a kubeconfig for it.
#
# Usage: test/scripts/vcluster/up.sh [name] [host-namespace]
# Env:   HOST_CONTEXT     kube context of the host cluster (default: current)
#        VCLUSTER_VERSION chart version (default: 0.37.2)
#        VCLUSTER_PORT    local port for the API port-forward (default: 18443)
#
# Prints the kubeconfig path. The API server is reached through a background
# kubectl port-forward, restarted whenever it exits, whose PID is written next
# to the kubeconfig. kubeconfig-in-host, next to it, reaches the API server from
# pods on the host cluster.
set -euo pipefail

NAME="${1:-kserve-e2e}"
HOST_NS="${2:-${NAME}}"
VCLUSTER_VERSION="${VCLUSTER_VERSION:-0.37.2}"
VCLUSTER_PORT="${VCLUSTER_PORT:-18443}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${VCLUSTER_STATE_DIR:-${TMPDIR:-/tmp}/vcluster-${NAME}}"
HOST_KUBECTL=(kubectl ${HOST_CONTEXT:+--context "${HOST_CONTEXT}"})
HOST_HELM=(helm ${HOST_CONTEXT:+--kube-context "${HOST_CONTEXT}"})

mkdir -p "${STATE_DIR}"

"${HOST_HELM[@]}" repo add loft https://charts.loft.sh >/dev/null 2>&1 || true
"${HOST_HELM[@]}" repo update loft >/dev/null
"${HOST_HELM[@]}" upgrade --install "${NAME}" loft/vcluster \
  --version "${VCLUSTER_VERSION}" \
  --namespace "${HOST_NS}" --create-namespace \
  --values "${SCRIPT_DIR}/values.yaml" \
  --wait --timeout 10m >&2

if "${HOST_KUBECTL[@]}" -n "${HOST_NS}" get "statefulset/${NAME}" >/dev/null 2>&1; then
  "${HOST_KUBECTL[@]}" -n "${HOST_NS}" rollout status "statefulset/${NAME}" --timeout=10m >&2
else
  "${HOST_KUBECTL[@]}" -n "${HOST_NS}" rollout status "deployment/${NAME}" --timeout=10m >&2
fi

KUBECONFIG_OUT="${STATE_DIR}/kubeconfig"
for _ in $(seq 1 60); do
  "${HOST_KUBECTL[@]}" -n "${HOST_NS}" get secret "vc-${NAME}" >/dev/null 2>&1 && break
  sleep 5
done
"${HOST_KUBECTL[@]}" -n "${HOST_NS}" get secret "vc-${NAME}" -o jsonpath='{.data.config}' | base64 -d > "${KUBECONFIG_OUT}"
kubectl --kubeconfig "${KUBECONFIG_OUT}" config set-cluster "$(kubectl --kubeconfig "${KUBECONFIG_OUT}" config view -o jsonpath='{.clusters[0].name}')" \
  --server "https://127.0.0.1:${VCLUSTER_PORT}" >/dev/null

KUBECONFIG_IN_HOST="${STATE_DIR}/kubeconfig-in-host"
cp "${KUBECONFIG_OUT}" "${KUBECONFIG_IN_HOST}"
kubectl --kubeconfig "${KUBECONFIG_IN_HOST}" config set-cluster "$(kubectl --kubeconfig "${KUBECONFIG_IN_HOST}" config view -o jsonpath='{.clusters[0].name}')" \
  --server "https://${NAME}.${HOST_NS}:443" >/dev/null

"${SCRIPT_DIR}/stop-port-forward.sh" "${STATE_DIR}" "${VCLUSTER_PORT}"
nohup bash -c 'while true; do "$@"; sleep 1; done' port-forward \
  "${HOST_KUBECTL[@]}" -n "${HOST_NS}" port-forward "svc/${NAME}" "${VCLUSTER_PORT}:443" \
  > "${STATE_DIR}/port-forward.log" 2>&1 &
echo $! > "${STATE_DIR}/port-forward.pid"
echo "${VCLUSTER_PORT}" > "${STATE_DIR}/port-forward.port"

for _ in $(seq 1 30); do
  if kubectl --kubeconfig "${KUBECONFIG_OUT}" get --raw /readyz >/dev/null 2>&1; then
    echo "${KUBECONFIG_OUT}"
    exit 0
  fi
  sleep 2
done
echo "vCluster API did not become reachable; see ${STATE_DIR}/port-forward.log" >&2
exit 1
