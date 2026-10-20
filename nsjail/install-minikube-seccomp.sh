#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/constants.sh
source "${ROOT}/lib/constants.sh"

if ! command -v minikube >/dev/null; then
  echo "minikube not found" >&2
  exit 1
fi

if ! minikube status --format='{{.Host}}' 2>/dev/null | grep -q Running; then
  echo "minikube profile is not running" >&2
  exit 1
fi

profile="$(minikube profile 2>/dev/null || echo minikube)"
node_name="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
echo "Minikube profile=${profile} node=${node_name:-unknown}"

if [[ ! -f "${NSJAIL_OUTER_SECCOMP_SOURCE}" ]]; then
  echo "missing profile source ${NSJAIL_OUTER_SECCOMP_SOURCE}" >&2
  exit 1
fi

local_hash="$(sha256sum "${NSJAIL_OUTER_SECCOMP_SOURCE}" | awk '{print $1}')"
if [[ "${local_hash}" != "${NSJAIL_OUTER_SECCOMP_SHA256}" ]]; then
  echo "refusing to install: hash ${local_hash} != pin ${NSJAIL_OUTER_SECCOMP_SHA256}" >&2
  exit 1
fi

remote_dir="${NSJAIL_KUBELET_PROFILE_DIR}"
remote_path="${remote_dir}/${NSJAIL_KUBELET_PROFILE_NAME}"

minikube ssh -- "sudo mkdir -p '${remote_dir}' && sudo chmod 755 '${remote_dir}'"
minikube cp "${NSJAIL_OUTER_SECCOMP_SOURCE}" "/tmp/${NSJAIL_KUBELET_PROFILE_NAME}"
minikube ssh -- "sudo install -m 0644 '/tmp/${NSJAIL_KUBELET_PROFILE_NAME}' '${remote_path}' && sudo rm -f '/tmp/${NSJAIL_KUBELET_PROFILE_NAME}'"

remote_hash="$(minikube ssh -- "sudo sha256sum '${remote_path}'" | awk '{print $1}')"
if [[ "${remote_hash}" != "${NSJAIL_OUTER_SECCOMP_SHA256}" ]]; then
  echo "post-install hash mismatch on node: ${remote_hash}" >&2
  exit 1
fi

echo "Installed Localhost seccomp profile:"
echo "  path=${remote_path}"
echo "  sha256=${remote_hash}"
