#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=nsjail/lib/constants.sh
source "${ROOT}/nsjail/lib/constants.sh"

fail() { echo "verify FAILED: $*" >&2; exit 1; }

command -v minikube >/dev/null || fail "minikube missing"
command -v kubectl >/dev/null || fail "kubectl missing"

minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running || fail "minikube not running"

remote_path="${NSJAIL_KUBELET_PROFILE_DIR}/${NSJAIL_KUBELET_PROFILE_NAME}"
remote_hash="$(minikube ssh -- "sudo test -f '${remote_path}' && sudo sha256sum '${remote_path}'" 2>/dev/null | awk '{print $1}')" \
  || fail "profile missing at ${remote_path} (run install-minikube-nsjail-seccomp.sh)"

[[ "${remote_hash}" == "${NSJAIL_OUTER_SECCOMP_SHA256}" ]] \
  || fail "hash ${remote_hash} != ${NSJAIL_OUTER_SECCOMP_SHA256}"

runner_sha="$(sha256sum "${NSJAIL_EXPERIMENT_DIR}/runner.sh" | awk '{print $1}')"
echo "Building spike image (runner.sha=${runner_sha})..."
docker build \
  --build-arg RUNNER_SCRIPT_SHA="${runner_sha}" \
  -t "${NSJAIL_SPIKE_IMAGE}" \
  "${NSJAIL_EXPERIMENT_DIR}"

if ! minikube image ls 2>/dev/null | grep -q "nsjail-spike:3.6"; then
  echo "Loading ${NSJAIL_SPIKE_IMAGE} into minikube..."
  minikube image load "${NSJAIL_SPIKE_IMAGE}"
fi

kubectl apply -f "${NSJAIL_CANARY_MANIFEST}"

kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" wait --for=condition=Ready pod/nsjail-spike --timeout=120s \
  || fail "canary pod not ready"

out="$(kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" exec nsjail-spike -- \
  run-nsjail Hello.java 'javac Hello.java && java Hello' 2>&1)" \
  || fail "canary Hello execution failed: ${out}"

[[ "${out}" == *"hello-from-jail"* ]] || fail "unexpected Hello output: ${out}"

echo "verify OK: profile hash + canary Hello"
echo "${out}"
