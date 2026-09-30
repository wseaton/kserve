#!/usr/bin/env bash
# Run test/scripts/vcluster/run-e2e.sh from a Linux container against a vCluster
# reached through the port-forward that up.sh starts. The repository is copied
# into the container, so the scripts' in-place edits never touch this checkout.
#
# Usage: test/scripts/vcluster/run-e2e-in-container.sh <kubeconfig> [pytest marker expression]
# Env:   CONTAINER_TOOL (default: docker), and every variable run-e2e.sh reads.
set -euo pipefail

KUBECONFIG_IN="${1:?kubeconfig path required}"
MARKERS="${2:-}"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
IMAGE=kserve-e2e-runner:local
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

BUILD_ARGS=()
if [[ "${CONTAINER_TOOL}" == "docker" ]]; then
  BUILD_ARGS+=(--load)
fi
"${CONTAINER_TOOL}" build ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} -q -t "${IMAGE}" -f "${REPO_ROOT}/test/scripts/vcluster/runner.Dockerfile" "${REPO_ROOT}/test/scripts/vcluster" >&2

rsync -a --exclude .git --exclude bin/ --exclude .venv/ --exclude node_modules/ --exclude /install/ --exclude /docs/ "${REPO_ROOT}/" "${WORK}/src/"
git -C "${WORK}/src" init -q

cp "${KUBECONFIG_IN}" "${WORK}/kubeconfig"
CLUSTER="$(kubectl --kubeconfig "${WORK}/kubeconfig" config view -o jsonpath='{.clusters[0].name}')"
SERVER="$(kubectl --kubeconfig "${WORK}/kubeconfig" config view -o jsonpath='{.clusters[0].cluster.server}')"
kubectl --kubeconfig "${WORK}/kubeconfig" config set-cluster "${CLUSTER}" \
  --server "${SERVER/127.0.0.1/host.docker.internal}" --tls-server-name localhost >/dev/null

ENV_ARGS=()
for var in LLMISVC_CONTROLLER_IMAGE SKIP_INSTALL SKIP_TESTS WITH_MODELEXPRESS PARALLELISM OPT_125M_MODEL_URI \
  MODELEXPRESS_ADDRESS MODELEXPRESS_MODEL_URI MODELEXPRESS_MODEL_NAME MODELEXPRESS_HF_MODEL MODELEXPRESS_VLLM_CUDA_IMAGE MODELEXPRESS_RDMA_RESOURCE MODELEXPRESS_VERSION \
  PYTEST_ARGS PYTEST_MAXFAIL; do
  if [[ -n "${!var:-}" ]]; then
    ENV_ARGS+=(-e "${var}=${!var}")
  fi
done

"${CONTAINER_TOOL}" run --rm \
  -v "${WORK}/src:/workspace" \
  -v "${WORK}/kubeconfig:/kubeconfig:ro" \
  -e KUBECONFIG=/kubeconfig \
  ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
  "${IMAGE}" bash test/scripts/vcluster/run-e2e.sh ${MARKERS:+"${MARKERS}"}
