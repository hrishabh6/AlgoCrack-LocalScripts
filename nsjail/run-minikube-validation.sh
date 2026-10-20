#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/constants.sh
source "${SCRIPT_DIR}/lib/constants.sh"

OUT="${NSJAIL_MINIKUBE_VALIDATION_OUT:-${SCRIPTS_ROOT}/../context/phase1/minikube-validation.jsonl}"
mkdir -p "$(dirname "${OUT}")"
: >"${OUT}"

"${SCRIPT_DIR}/verify-minikube-seccomp.sh"

record() {
  printf '{"case":%s,"status":%s,"detail":%s}\n' \
    "$(jq -Rn --arg v "$1" '$v')" \
    "$(jq -Rn --arg v "$2" '$v')" \
    "$(jq -Rn --arg v "$3" '$v')" >>"${OUT}"
}

exec_fixture() {
  local name="$1" fixture="$2" cmd="$3" expect="$4"
  local out rc=0
  set +e
  out="$(kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" exec nsjail-spike -- \
    run-nsjail "${fixture}" "${cmd}" 2>&1)"
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 && "${out}" == *"${expect}"* ]]; then
    record "${name}" "pass" "${out}"
    echo "PASS ${name}"
  else
    record "${name}" "fail" "rc=${rc} out=${out}"
    echo "FAIL ${name}" >&2
    return 1
  fi
}

failures=0
exec_fixture hello Hello.java 'javac Hello.java && java Hello' "hello-from-jail" || failures=$((failures + 1))
exec_fixture network NetworkProbe.java 'javac NetworkProbe.java && java NetworkProbe' "NETWORK_DENIED" || failures=$((failures + 1))
exec_fixture files FileProbe.java 'javac FileProbe.java && java FileProbe' "/runner-secret/value:false" || failures=$((failures + 1))
exec_fixture annotation AnnotationProcessor.java \
  'javac AnnotationProcessor.java && javac -processor AnnotationProcessor -processorpath . Annotated.java && java Annotated' \
  "processor-ok" || failures=$((failures + 1))

# Loop should be killed by nsjail time limit
set +e
loop_out="$(kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" exec nsjail-spike -- \
  run-nsjail Loop.java 'javac Loop.java && java Loop' 2>&1)"
loop_rc=$?
set -e
if [[ "${loop_rc}" -ne 0 ]]; then
  record "loop_timeout" "pass" "${loop_out}"
  echo "PASS loop_timeout"
else
  record "loop_timeout" "fail" "${loop_out}"
  failures=$((failures + 1))
fi

# Service account token must not exist in pod (automount false)
token_out="$(kubectl -n "${NSJAIL_SPIKE_NAMESPACE}" exec nsjail-spike -- \
  test ! -f /var/run/secrets/kubernetes.io/serviceaccount/token && echo NO_TOKEN || echo HAS_TOKEN)"
if [[ "${token_out}" == *"NO_TOKEN"* ]]; then
  record "no_service_account_token" "pass" "${token_out}"
else
  record "no_service_account_token" "fail" "${token_out}"
  failures=$((failures + 1))
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "Minikube validation FAILED (${failures})"
  exit 1
fi
echo "Minikube validation passed. Log: ${OUT}"
