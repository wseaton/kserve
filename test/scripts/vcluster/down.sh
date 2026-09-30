#!/usr/bin/env bash
# Delete a vCluster created by up.sh, its host namespace, and the port-forward.
#
# Usage: test/scripts/vcluster/down.sh [name] [host-namespace]
set -euo pipefail

NAME="${1:-kserve-e2e}"
HOST_NS="${2:-${NAME}}"
STATE_DIR="${VCLUSTER_STATE_DIR:-${TMPDIR:-/tmp}/vcluster-${NAME}}"
HOST_KUBECTL=(kubectl ${HOST_CONTEXT:+--context "${HOST_CONTEXT}"})
HOST_HELM=(helm ${HOST_CONTEXT:+--kube-context "${HOST_CONTEXT}"})

"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stop-port-forward.sh" "${STATE_DIR}" "$(cat "${STATE_DIR}/port-forward.port" 2>/dev/null || echo 18443)"

"${HOST_HELM[@]}" uninstall "${NAME}" --namespace "${HOST_NS}" --wait --timeout 10m || true

PVS=$("${HOST_KUBECTL[@]}" get pv -o jsonpath="{range .items[?(@.spec.claimRef.namespace==\"${HOST_NS}\")]}{.metadata.name}{\"\\n\"}{end}")
"${HOST_KUBECTL[@]}" delete namespace "${HOST_NS}" --wait --timeout 10m || true
for pv in ${PVS}; do
  "${HOST_KUBECTL[@]}" delete pv "${pv}" --ignore-not-found
done
rm -rf "${STATE_DIR}"
