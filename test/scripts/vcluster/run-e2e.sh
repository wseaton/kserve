#!/usr/bin/env bash
# Install KServe with LLMInferenceService into a vCluster created by up.sh and
# run LLMInferenceService e2e tests against it, following the steps of
# .github/workflows/e2e-test-llmisvc.yaml.
#
# Usage: KUBECONFIG=<vcluster kubeconfig> test/scripts/vcluster/run-e2e.sh [pytest marker expression]
# Env:   LLMISVC_CONTROLLER_IMAGE  controller image to run instead of kserve/llmisvc-controller:latest
#        SKIP_INSTALL=true         reuse an existing installation
#        SKIP_TESTS=true           install only
#        WITH_MODELEXPRESS=true    install a ModelExpress server, seed MODELEXPRESS_HF_MODEL into S3,
#                                  and export MODELEXPRESS_ADDRESS and MODELEXPRESS_MODEL_URI
#        PARALLELISM               pytest-xdist workers (default: 1)
set -euo pipefail

MARKERS="${1:-llminferenceservice and llmisvc_core and cluster_cpu}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${REPO_ROOT}"

: "${KUBECONFIG:?KUBECONFIG must point at the vCluster}"
mkdir -p "${REPO_ROOT}/bin"
export PATH="${REPO_ROOT}/bin:${PATH}"
export TAG="${TAG:-latest}"
export KO_DOCKER_REPO="${KO_DOCKER_REPO:-kserve}"
export ENABLE_LLMISVC=true

source ./kserve-images.sh
./hack/setup/cli/install-kustomize.sh
./hack/setup/cli/install-helm.sh
./test/scripts/gh-actions/setup-uv.sh

if [[ "${SKIP_INSTALL:-false}" != "true" ]]; then
  ./test/scripts/gh-actions/setup-deps.sh serverless envoy-gateway false true none none
  ./test/scripts/gh-actions/setup-kserve.sh
else
  (cd python/kserve && uv sync --group test)
fi

if [[ -n "${LLMISVC_CONTROLLER_IMAGE:-}" ]]; then
  kubectl -n kserve set image deployment/llmisvc-controller-manager "manager=${LLMISVC_CONTROLLER_IMAGE}"
  kubectl -n kserve rollout status deployment/llmisvc-controller-manager --timeout=5m
fi

if [[ "${WITH_MODELEXPRESS:-false}" == "true" ]]; then
  MODELEXPRESS_ADDRESS="$(./test/scripts/gh-actions/setup-modelexpress.sh)"
  export MODELEXPRESS_ADDRESS
  MODELEXPRESS_MODEL_URI="$(./test/scripts/gh-actions/seed-s3-model.sh "${MODELEXPRESS_HF_MODEL:-Qwen/Qwen2.5-0.5B-Instruct}")"
  export MODELEXPRESS_MODEL_URI
fi

if [[ "${SKIP_TESTS:-false}" != "true" ]]; then
  ./test/scripts/gh-actions/run-e2e-tests.sh "${MARKERS}" "${PARALLELISM:-1}" "envoy-gateway"
fi
