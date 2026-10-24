#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/constants.sh
source "${ROOT}/lib/constants.sh"

fail() { echo "verify FAILED: $*" >&2; exit 1; }

command -v minikube >/dev/null || fail "minikube missing"
command -v kubectl >/dev/null || fail "kubectl missing"

minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running || fail "minikube not running"

remote_path="${NSJAIL_KUBELET_PROFILE_DIR}/${NSJAIL_KUBELET_PROFILE_NAME}"
remote_hash="$(minikube ssh -- "sudo test -f '${remote_path}' && sudo sha256sum '${remote_path}'" 2>/dev/null | awk '{print $1}')" \
  || fail "profile missing at ${remote_path} (run scripts/nsjail/install-minikube-seccomp.sh)"

[[ "${remote_hash}" == "${NSJAIL_OUTER_SECCOMP_SHA256}" ]] \
  || fail "hash ${remote_hash} != ${NSJAIL_OUTER_SECCOMP_SHA256}"

runner_sha="$(sha256sum "${NSJAIL_EXPERIMENT_DIR}/runner.sh" | awk '{print $1}')"
echo "Building spike image (runner.sha=${runner_sha})..."
docker build \
  --build-arg RUNNER_SCRIPT_SHA="${runner_sha}" \
  -t "${NSJAIL_SPIKE_IMAGE}" \
  "${NSJAIL_EXPERIMENT_DIR}"

echo "Loading ${NSJAIL_SPIKE_IMAGE} into minikube..."
minikube image load "${NSJAIL_SPIKE_IMAGE}"

# A Never-restart canary remains in a terminal state after an earlier run. Apply
# does not recreate that Pod, so replace only this disposable canary before its
# readiness check. The namespace and all application workloads are preserved.
kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" delete pod nsjail-spike \
  --ignore-not-found --wait=true

kubectl apply -f "${NSJAIL_CANARY_MANIFEST}"

kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" wait --for=condition=Ready pod/nsjail-spike --timeout=120s \
  || fail "canary pod not ready"

out="$(kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" exec nsjail-spike -- \
  run-nsjail Hello.java 'javac Hello.java && java Hello' 2>&1)" \
  || fail "canary Hello execution failed: ${out}"

[[ "${out}" == *"hello-from-jail"* ]] || fail "unexpected Hello output: ${out}"

echo "verify OK: profile hash + canary Hello"
echo "${out}"
