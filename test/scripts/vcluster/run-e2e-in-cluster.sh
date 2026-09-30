#!/usr/bin/env bash
# Run test/scripts/vcluster/run-e2e.sh from a pod, so tests reach gateway and
# service addresses that are only routable inside the cluster network.
#
# The pod runs in the cluster kubectl points at. By default it tests that same
# cluster through a ServiceAccount bound to cluster-admin, so use a disposable
# cluster. With TARGET_KUBECONFIG it tests the cluster that kubeconfig names
# instead, e.g. a vCluster reached from its host (up.sh writes kubeconfig-in-host),
# and needs no permissions on the cluster it runs in.
#
# Usage: test/scripts/vcluster/run-e2e-in-cluster.sh [pytest marker expression]
# Env:   RUNNER_NAMESPACE (default: kserve-e2e-runner)
#        TARGET_KUBECONFIG kubeconfig for the cluster under test, as seen from the pod
#        and every variable run-e2e.sh reads.
set -euo pipefail

MARKERS="${1:-}"
NS="${RUNNER_NAMESPACE:-kserve-e2e-runner}"
POD=runner
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

k() {
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if kubectl "$@"; then
      return 0
    fi
    sleep 3
  done
  return 1
}

cat > "${WORK}/namespace.yaml" <<YAML
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: runner
  namespace: ${NS}
YAML
k apply -f "${WORK}/namespace.yaml"

if [[ -n "${TARGET_KUBECONFIG:-}" ]]; then
  k -n "${NS}" create secret generic runner-kubeconfig --from-file=kubeconfig="${TARGET_KUBECONFIG}" \
    --dry-run=client -o yaml > "${WORK}/secret.yaml"
  k apply -f "${WORK}/secret.yaml"
  KUBECONFIG_VOLUME='
    volumeMounts:
    - {name: target-kubeconfig, mountPath: /target, readOnly: true}
  volumes:
  - name: target-kubeconfig
    secret: {secretName: runner-kubeconfig}'
else
  cat > "${WORK}/rbac.yaml" <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NS}-runner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: runner
  namespace: ${NS}
YAML
  k apply -f "${WORK}/rbac.yaml"
  KUBECONFIG_VOLUME=""
fi

if ! k -n "${NS}" get pod "${POD}" >/dev/null 2>&1; then
  cat > "${WORK}/pod.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
spec:
  serviceAccountName: runner
  restartPolicy: Never
  containers:
  - name: runner
    image: python:3.12-bookworm
    command: ["bash", "-c"]
    args:
    - |
      set -e
      ARCH="\$(dpkg --print-architecture)"
      curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.35.0/bin/linux/\${ARCH}/kubectl"
      chmod +x /usr/local/bin/kubectl
      apt-get update -qq && apt-get install -y -qq --no-install-recommends jq rsync >/dev/null
      touch /tmp/ready
      exec sleep infinity
    resources:
      requests: {cpu: "2", memory: 4Gi}${KUBECONFIG_VOLUME}
YAML
  k apply -f "${WORK}/pod.yaml"
fi
k -n "${NS}" wait --for=condition=Ready "pod/${POD}" --timeout=10m
until kubectl -n "${NS}" exec "${POD}" -- test -f /tmp/ready 2>/dev/null; do sleep 2; done

STATE="$(k -n "${NS}" exec "${POD}" -- sh -c 'if pgrep -f "[r]un-e2e.sh" >/dev/null; then echo running; else echo idle; fi')"
if [[ "${STATE}" == "running" ]]; then
  echo "A run is already in progress in ${NS}/${POD}; follow it with: kubectl -n ${NS} exec ${POD} -- tail -f /tmp/e2e.log" >&2
  exit 1
fi

rsync -a --exclude .git --exclude bin/ --exclude .venv/ --exclude node_modules/ --exclude /install/ --exclude /docs/ \
  "${REPO_ROOT}/" "${WORK}/src/"
tar -C "${WORK}/src" -czf "${WORK}/src.tgz" .
k -n "${NS}" exec "${POD}" -- rm -rf /workspace /tmp/e2e.log /tmp/e2e.exit
k -n "${NS}" exec "${POD}" -- mkdir -p /workspace
k -n "${NS}" cp "${WORK}/src.tgz" "${POD}:/tmp/src.tgz"
k -n "${NS}" exec "${POD}" -- tar -C /workspace -xzf /tmp/src.tgz

ENV_ARGS=()
for var in LLMISVC_CONTROLLER_IMAGE SKIP_INSTALL SKIP_TESTS WITH_MODELEXPRESS PARALLELISM OPT_125M_MODEL_URI \
  MODELEXPRESS_ADDRESS MODELEXPRESS_MODEL_URI MODELEXPRESS_MODEL_NAME MODELEXPRESS_HF_MODEL MODELEXPRESS_VLLM_CUDA_IMAGE \
  MODELEXPRESS_RDMA_RESOURCE MODELEXPRESS_VERSION PYTEST_ARGS PYTEST_MAXFAIL; do
  if [[ -n "${!var:-}" ]]; then
    ENV_ARGS+=("${var}=${!var}")
  fi
done

k -n "${NS}" exec "${POD}" -- env ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} bash -c '
  if [[ -f /target/kubeconfig ]]; then
    export KUBECONFIG=/target/kubeconfig
  else
    SA=/var/run/secrets/kubernetes.io/serviceaccount
    export KUBECONFIG=/tmp/kubeconfig
    cat > "${KUBECONFIG}" <<KUBECONFIG
apiVersion: v1
kind: Config
clusters:
- name: in-cluster
  cluster:
    server: https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}
    certificate-authority: ${SA}/ca.crt
users:
- name: runner
  user:
    tokenFile: ${SA}/token
contexts:
- name: in-cluster
  context: {cluster: in-cluster, user: runner}
current-context: in-cluster
KUBECONFIG
  fi
  cd /workspace && git init -q
  nohup bash -c "bash test/scripts/vcluster/run-e2e.sh \"\$@\" > /tmp/e2e.log 2>&1; echo \$? > /tmp/e2e.exit" run-e2e "$@" >/dev/null 2>&1 &
' run-e2e ${MARKERS:+"${MARKERS}"}

echo "Tests are running in ${NS}/${POD}; follow with: kubectl -n ${NS} exec ${POD} -- tail -f /tmp/e2e.log" >&2
until kubectl -n "${NS}" exec "${POD}" -- test -f /tmp/e2e.exit 2>/dev/null; do
  sleep 30
done
k -n "${NS}" exec "${POD}" -- cat /tmp/e2e.log
exit "$(k -n "${NS}" exec "${POD}" -- cat /tmp/e2e.exit)"
