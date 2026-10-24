#!/usr/bin/env bash
# Offline Phase 5 checks: Gradle runner dist, optional image inspect, Helm lint/template.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CXE="${ROOT}/CodeExecutionEngine"
HELM="${ROOT}/helm/algocrack"
OVERLAY="${ROOT}/helm/algocrack/overlays/releases/values.local-prod-sim-rc5-nsjail-runner-disposable.yaml"

echo "== Gradle :nsjail-runner:installDist =="
(cd "${CXE}" && ./gradlew :nsjail-runner:installDist -x test --no-daemon)

if [[ "${SKIP_RUNNER_IMAGE_BUILD:-false}" != "true" ]]; then
  echo "== Docker build Dockerfile.runner =="
  "${ROOT}/scripts/cxe/build-runner-image.sh"
  IMAGE="${CXE_RUNNER_IMAGE:-hrishabhjoshi/cxe-nsjail-runner:local}"
  docker run --rm --entrypoint /usr/local/bin/runner-probe.sh "${IMAGE}" startup
fi

echo "== helm lint (default, runner disabled) =="
helm lint "${HELM}"

echo "== helm template disposable RC5 overlay =="
helm template algocrack-phase5-test "${HELM}" \
  -f "${HELM}/values.yaml" \
  -f "${OVERLAY}" \
  --namespace algocrack-phase5-disposable \
  --set secrets.useExisting=true \
  --set secrets.appSecretName=phase5-placeholder \
  --set secrets.jwtSecretName=phase5-placeholder \
  >/tmp/algocrack-phase5-disposable.yaml

grep -q 'kind: Deployment' /tmp/algocrack-phase5-disposable.yaml
grep -q 'cxe-nsjail-runner' /tmp/algocrack-phase5-disposable.yaml
grep -q 'runAsNonRoot: true' /tmp/algocrack-phase5-disposable.yaml

echo "Phase 5 offline validation passed."
