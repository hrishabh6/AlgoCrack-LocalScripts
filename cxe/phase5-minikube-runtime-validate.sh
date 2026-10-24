#!/usr/bin/env bash
# Phase 5 disposable Minikube runtime validation (does not upgrade algocrack Helm release).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="${ROOT}/context/phase5/k8s/disposable-runner-test.yaml"
NS="algocrack-phase5-disposable"
IMAGE="${CXE_RUNNER_IMAGE:-hrishabhjoshi/cxe-nsjail-runner:local}"

echo "== Build & load runner image =="
"${ROOT}/scripts/cxe/build-runner-image.sh"
minikube image load "${IMAGE}"

echo "== Apply disposable stack =="
kubectl apply -f "${MANIFEST}"
kubectl -n "${NS}" rollout status deployment/redis --timeout=120s
kubectl -n "${NS}" rollout status deployment/cxe-nsjail-runner --timeout=300s

echo "== Probe checks =="
kubectl -n "${NS}" exec deploy/cxe-nsjail-runner -- /usr/local/bin/runner-probe.sh startup
kubectl -n "${NS}" exec deploy/cxe-nsjail-runner -- /usr/local/bin/nsjail --version

echo "== Enqueue v2 fixture via disposable Redis =="
# Minimal add-task JSON; runner consumes from execution:v2:phase5-disposable:ready
kubectl -n "${NS}" run redis-enqueue --rm -i --restart=Never --image=redis:7-alpine -- \
  redis-cli -h redis LPUSH 'execution:v2:phase5-disposable:ready' 'phase5-exec-1' \
  && kubectl -n "${NS}" run redis-set --rm -i --restart=Never --image=redis:7-alpine -- \
  sh -c 'redis-cli -h redis SET execution:v2:phase5-disposable:task:phase5-exec-1 "{\"contractVersion\":\"cxe.runner.v2\",\"taskId\":\"phase5-exec-1\",\"attemptId\":\"0\",\"submissionId\":\"sub-p5\",\"executionId\":\"phase5-exec-1\",\"mode\":\"RUN\",\"language\":\"java\",\"payloadBase64\":\"PLACEHOLDER\",\"expiresAt\":\"2099-01-01T00:00:00Z\",\"limitsProfileId\":\"default\"}" EX 3600'

echo "NOTE: Replace PLACEHOLDER with encoded payload for full Java run; basic startup/probes validated."
echo "Phase 5 disposable runtime validation steps completed."
