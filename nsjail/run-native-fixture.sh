#!/usr/bin/env bash
set -euo pipefail

fixture="${1:?fixture name required}"
shift

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=nsjail/lib/constants.sh
source "${ROOT}/nsjail/lib/constants.sh"

NSJAIL_BIN="${NSJAIL_BIN:-${SCRIPTS_ROOT}/.local/bin/nsjail}"
export LD_LIBRARY_PATH="${SCRIPTS_ROOT}/.local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
JAIL_ROOT="${NSJAIL_JAIL_ROOT:-${SCRIPTS_ROOT}/.local/jail-root}"
WORKSPACE="${NSJAIL_WORKSPACE:-${SCRIPTS_ROOT}/.local/nsjail-workspace}"
RUNNER_SECRET="${NSJAIL_RUNNER_SECRET:-${SCRIPTS_ROOT}/.local/runner-secret/value}"
FIXTURES="${NSJAIL_EXPERIMENT_DIR}/fixtures"

case "$fixture" in
  Hello.java|NetworkProbe.java|FileProbe.java|ForkBomb.java|Loop.java|AnnotationProcessor.java|Annotated.java)
    ;;
  *)
    echo "unsupported fixture: $fixture" >&2
    exit 64
    ;;
esac

mkdir -p "${WORKSPACE}" "${JAIL_ROOT}"/{usr,lib,lib64,bin,workspace,tmp,proc,opt/java} "$(dirname "${RUNNER_SECRET}")"
if [[ ! -f "${RUNNER_SECRET}" ]]; then
  printf 'not-visible-to-jail\n' >"${RUNNER_SECRET}"
  chmod 0444 "${RUNNER_SECRET}"
fi

rm -rf "${WORKSPACE:?}"/*
cp "${FIXTURES}/${fixture}" "${WORKSPACE}/"
if [[ "${fixture}" == "AnnotationProcessor.java" ]]; then
  cp "${FIXTURES}/Annotated.java" "${WORKSPACE}/"
fi

bind_java="${JAVA_HOME}"
if [[ ! -d "${bind_java}" ]]; then
  echo "JAVA_HOME ${bind_java} missing" >&2
  exit 1
fi

extra_ro=()
[[ -d /etc/java-21-openjdk ]] && extra_ro+=(--bindmount_ro /etc/java-21-openjdk)
[[ -d /etc/ssl ]] && extra_ro+=(--bindmount_ro /etc/ssl)

exec "${NSJAIL_BIN}" \
  --quiet \
  --mode o \
  --chroot "${JAIL_ROOT}" \
  --cwd /workspace \
  --time_limit 3 \
  --max_cpus 1 \
  --rlimit_as 2048 \
  --rlimit_cpu 2 \
  --rlimit_nproc 16 \
  --rlimit_nofile 64 \
  --disable_clone_newcgroup \
  --disable_proc \
  --bindmount_ro /usr \
  --bindmount_ro /lib \
  --bindmount_ro /lib64 \
  --bindmount_ro /bin \
  --bindmount_ro "${bind_java}:/opt/java" \
  "${extra_ro[@]}" \
  --bindmount "${WORKSPACE}:/workspace" \
  --tmpfsmount /tmp \
  -- /bin/bash -lc "export PATH=/opt/java/bin:\$PATH LD_LIBRARY_PATH=/opt/java/lib:\${LD_LIBRARY_PATH:-} JAVA_TOOL_OPTIONS='-Xmx256m -XX:MaxMetaspaceSize=128m -XX:CompressedClassSpaceSize=64m -XX:ReservedCodeCacheSize=32m'; $*"
