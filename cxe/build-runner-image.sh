#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CXE="${ROOT}/CodeExecutionEngine"
IMAGE="${CXE_RUNNER_IMAGE:-hrishabhjoshi/cxe-nsjail-runner:local}"
NSJAIL_VERSION="${NSJAIL_VERSION:-3.6}"
VCS_REF="$(git -C "${CXE}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "Building ${IMAGE} (nsjail ${NSJAIL_VERSION}, ref ${VCS_REF})"
docker build \
  -f "${CXE}/Dockerfile.runner" \
  --build-arg "NSJAIL_VERSION=${NSJAIL_VERSION}" \
  --build-arg "VCS_REF=${VCS_REF}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  -t "${IMAGE}" \
  "${CXE}"

docker inspect "${IMAGE}" --format 'User={{.Config.User}} Entrypoint={{json .Config.Entrypoint}}'
