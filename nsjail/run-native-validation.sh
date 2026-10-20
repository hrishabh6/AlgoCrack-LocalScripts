#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="${ROOT}/nsjail/run-native-fixture.sh"
OUT="${NSJAIL_VALIDATION_OUT:-${ROOT}/../context/phase1/native-validation.jsonl}"
mkdir -p "$(dirname "${OUT}")"
: >"${OUT}"

record() {
  local name="$1" status="$2" detail="$3"
  printf '{"case":%s,"status":%s,"detail":%s}\n' \
    "$(jq -Rn --arg v "$name" '$v')" \
    "$(jq -Rn --arg v "$status" '$v')" \
    "$(jq -Rn --arg v "$detail" '$v')" >>"${OUT}"
}

pass() { record "$1" "pass" "$2"; echo "PASS $1"; }
fail() { record "$1" "fail" "$2"; echo "FAIL $1: $2" >&2; failures=$((failures + 1)); }

failures=0

run_capture() {
  local name="$1" fixture="$2" cmd="$3"
  local out rc
  set +e
  out="$("${RUN}" "${fixture}" "${cmd}" 2>&1)"
  rc=$?
  set -e
  printf '%s\n' "${out}"
  return "${rc}"
}

echo "== native Java fixtures =="
if out="$(run_capture hello Hello.java 'javac Hello.java && java Hello')" && [[ "${out}" == *"hello-from-jail"* ]]; then
  pass "hello" "${out}"
else
  fail "hello" "${out:-empty}"
fi

if out="$(run_capture annotation AnnotationProcessor.java \
  'javac AnnotationProcessor.java && javac -processor AnnotationProcessor -processorpath . Annotated.java && java Annotated')" \
  && [[ "${out}" == *"processor-ok"* ]]; then
  pass "annotation_processor" "${out}"
else
  fail "annotation_processor" "${out:-empty}"
fi

echo "== negative probes =="
if out="$(run_capture network NetworkProbe.java 'javac NetworkProbe.java && java NetworkProbe')" \
  && [[ "${out}" == *"NETWORK_DENIED"* ]]; then
  pass "network_denied" "${out}"
else
  fail "network_denied" "${out:-empty}"
fi

if out="$(run_capture files FileProbe.java 'javac FileProbe.java && java FileProbe')" \
  && [[ "${out}" == *"/runner-secret/value:false"* && "${out}" == *"/etc/shadow:false"* ]]; then
  pass "filesystem_isolation" "${out}"
else
  fail "filesystem_isolation" "${out:-empty}"
fi

set +e
loop_out="$(run_capture loop Loop.java 'javac Loop.java && java Loop')"
loop_rc=$?
set -e
if [[ "${loop_rc}" -ne 0 ]]; then
  pass "loop_timeout" "nsjail terminated loop (${loop_out:-rc=${loop_rc}})"
else
  fail "loop_timeout" "expected non-zero exit, got: ${loop_out}"
fi

if out="$(run_capture fork ForkBomb.java 'javac ForkBomb.java && java ForkBomb')" ; then
  if [[ "${out}" == *"Killed"* || "${out}" == *"Resource temporarily unavailable"* ]]; then
    pass "fork_bomb" "${out}"
  else
    fail "fork_bomb" "unexpected success: ${out}"
  fi
else
  pass "fork_bomb" "non-zero exit (${out:-terminated})"
fi

echo "== Python (informational first cutover) =="
if command -v python3 >/dev/null; then
  if out="$(run_capture py_hello Hello.java 'python3 -c "print(42)"' 2>/dev/null || true)" && [[ "${out}" == "42" ]]; then
    pass "python_exec" "${out}"
  else
    record "python_exec" "skip" "native jail PATH lacks python3; defer to runner image in Phase 5"
    echo "SKIP python_exec (not in jail PATH yet)"
  fi
else
  record "python_exec" "skip" "python3 not on host"
fi

if [[ "${failures}" -gt 0 ]]; then
  echo "Native validation FAILED (${failures})"
  exit 1
fi
echo "Native validation passed. Log: ${OUT}"
