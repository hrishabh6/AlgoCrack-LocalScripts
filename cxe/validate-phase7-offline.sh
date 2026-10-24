#!/usr/bin/env bash
# Offline Phase 7 preflight: Gradle gates, runner image optional, Helm lint/template for RC7 stages.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CXE="${ROOT}/CodeExecutionEngine"
HELM="${ROOT}/helm/algocrack"
STAGE1="${HELM}/overlays/releases/values.local-prod-sim-rc7-stage1-runner-warm.yaml"
STAGE2="${HELM}/overlays/releases/values.local-prod-sim-rc7-stage2-submission-cutover.yaml"

echo "== CXE JVM options + v2 recovery unit tests =="
(cd "${CXE}" && ./gradlew :nsjail-runner:test \
  --tests '*TaskExecutionPipelineJvmOptionsTest' \
  --tests '*ExecutionV2AtomicMoveRecoveryTest' \
  --no-daemon -q)

echo "== Gradle :nsjail-runner:installDist =="
(cd "${CXE}" && ./gradlew :nsjail-runner:installDist -x test --no-daemon)

if [[ "${SKIP_RUNNER_IMAGE_BUILD:-false}" != "true" ]]; then
  echo "== Docker build runner (packaged) =="
  CXE_RUNNER_IMAGE="${CXE_RUNNER_IMAGE:-hrishabhjoshi/cxe-nsjail-runner:phase7-2}" \
    "${ROOT}/scripts/cxe/build-runner-image.sh"
  docker run --rm --entrypoint /usr/local/bin/runner-probe.sh \
    "${CXE_RUNNER_IMAGE:-hrishabhjoshi/cxe-nsjail-runner:phase7-2}" startup
fi

echo "== helm lint =="
helm lint "${HELM}"

render_stage() {
  local name="$1" overlay="$2" outfile="$3"
  helm template "${name}" "${HELM}" \
    -f "${HELM}/values.yaml" \
    -f "${overlay}" \
    --namespace algocrack \
    --set secrets.useExisting=true \
    --set secrets.appSecretName=phase7-placeholder \
    --set secrets.jwtSecretName=phase7-placeholder \
    >"${outfile}"
}

echo "== helm template RC7 stage 1 (runner warm, routing off) =="
render_stage algocrack-rc7-s1 "${STAGE1}" /tmp/algocrack-rc7-stage1.yaml
grep -q 'name: cxe-nsjail-runner' /tmp/algocrack-rc7-stage1.yaml
grep -q 'EXECUTION_PERSISTENT_RUNNER_ENABLED: "false"' /tmp/algocrack-rc7-stage1.yaml

echo "== helm template RC7 stage 2 (must fail without ack) =="
if helm template algocrack-rc7-s2-fail "${HELM}" \
  -f "${HELM}/values.yaml" \
  -f "${STAGE2}" \
  --namespace algocrack \
  --set nsjailRunner.phase7LiveRoutingAcknowledged=false \
  --set secrets.useExisting=true \
  --set secrets.appSecretName=phase7-placeholder \
  --set secrets.jwtSecretName=phase7-placeholder \
  >/tmp/algocrack-rc7-stage2-fail.yaml 2>/tmp/algocrack-rc7-stage2-fail.err; then
  echo "expected helm template failure when ack=false" >&2
  exit 1
fi
grep -q 'phase7LiveRoutingAcknowledged' /tmp/algocrack-rc7-stage2-fail.err

render_stage algocrack-rc7-s2 "${STAGE2}" /tmp/algocrack-rc7-stage2.yaml
grep -q 'EXECUTION_PERSISTENT_RUNNER_ENABLED: "true"' /tmp/algocrack-rc7-stage2.yaml
grep -q 'EXECUTION_ROUTING_MODE_BACKENDS_SUBMISSION: "PERSISTENT_NSJAIL"' /tmp/algocrack-rc7-stage2.yaml
grep -q 'EXECUTION_ROUTING_MODE_BACKENDS_PLAYGROUND: "KUBERNETES_JOB"' /tmp/algocrack-rc7-stage2.yaml

echo "Phase 7 offline validation passed."
