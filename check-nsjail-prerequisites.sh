#!/usr/bin/env bash
set -euo pipefail

# Read-only prerequisite gate for native NsJail development.
# Never enables local-process or other unsandboxed fallbacks.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=nsjail/lib/constants.sh
source "${ROOT}/nsjail/lib/constants.sh"

failures=0
note() { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [warn] %s\n' "$*" >&2; }
fail() { printf '  [fail] %s\n' "$*" >&2; failures=$((failures + 1)); }

echo "== kernel / user namespaces =="
if [[ "$(uname -s)" != "Linux" ]]; then
  fail "Linux required (found $(uname -s))"
else
  note "Linux $(uname -r) $(uname -m)"
fi

if [[ -r /proc/sys/kernel/unprivileged_userns_clone ]]; then
  if [[ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" == "1" ]]; then
    note "unprivileged_userns_clone=1"
  else
    fail "unprivileged_userns_clone is not 1"
  fi
else
  warn "unprivileged_userns_clone sysctl not readable"
fi

if unshare -Ur true 2>/dev/null; then
  note "unshare -Ur succeeds"
else
  fail "unshare -Ur failed (user namespaces blocked?)"
fi

echo "== cgroup =="
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
  note "cgroup v2 unified hierarchy"
  note "controllers: $(tr '\n' ' ' </sys/fs/cgroup/cgroup.controllers)"
else
  warn "cgroup v2 controllers file missing (hybrid or cgroup v1?)"
fi

echo "== JDK / Python =="
java_bin="${JAVA_HOME:-}/bin/java"
if [[ -z "${JAVA_HOME:-}" || ! -x "${java_bin}" ]]; then
  for candidate in /usr/lib/jvm/java-21-openjdk-amd64 /usr/lib/jvm/java-21-openjdk; do
    if [[ -x "${candidate}/bin/java" ]]; then
      JAVA_HOME="${candidate}"
      java_bin="${JAVA_HOME}/bin/java"
      break
    fi
  done
fi
if [[ -x "${java_bin}" ]]; then
  ver="$("${java_bin}" -version 2>&1 | head -1)"
  if [[ "${ver}" == *"21."* ]]; then
    note "JDK 21: ${JAVA_HOME:-${java_bin%/*/*}}"
  else
    fail "JDK 21 required (${ver})"
  fi
  if [[ -x "${JAVA_HOME}/bin/javac" ]]; then
    note "javac present"
  else
    fail "javac missing under JAVA_HOME"
  fi
else
  fail "JDK 21 not found (set JAVA_HOME to a JDK 21 install)"
fi

if command -v python3 >/dev/null; then
  note "python3 $(python3 --version 2>&1)"
else
  warn "python3 not found (optional unless Python is in first cutover)"
fi

echo "== Redis reachability (optional local dev) =="
if command -v redis-cli >/dev/null; then
  note "redis-cli present"
else
  warn "redis-cli not installed (required later for dev-local runner gate)"
fi

echo "== NsJail binary =="
NSJAIL_BIN="${NSJAIL_BIN:-${SCRIPTS_ROOT}/.local/bin/nsjail}"
export LD_LIBRARY_PATH="${SCRIPTS_ROOT}/.local/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
if [[ -x "${NSJAIL_BIN}" ]]; then
  if nsj_ver="$("${NSJAIL_BIN}" --help 2>&1 | head -1 || true)" && [[ "${nsj_ver}" == *"nsjail"* ]]; then
    note "nsjail at ${NSJAIL_BIN} (${NSJAIL_VERSION}): ${nsj_ver}"
  else
    fail "nsjail at ${NSJAIL_BIN} not runnable (${nsj_ver:-missing runtime libs})"
  fi
else
  fail "nsjail not executable at ${NSJAIL_BIN} (build via scripts/nsjail/build-nsjail-from-docker.sh)"
fi

echo "== pinned outer seccomp artifact =="
if [[ -f "${NSJAIL_OUTER_SECCOMP_SOURCE}" ]]; then
  actual="$(sha256sum "${NSJAIL_OUTER_SECCOMP_SOURCE}" | awk '{print $1}')"
  if [[ "${actual}" == "${NSJAIL_OUTER_SECCOMP_SHA256}" ]]; then
    note "outer profile hash matches pin (${NSJAIL_OUTER_SECCOMP_SHA256})"
  else
    fail "outer profile hash mismatch (got ${actual}, expected ${NSJAIL_OUTER_SECCOMP_SHA256})"
  fi
else
  fail "missing ${NSJAIL_OUTER_SECCOMP_SOURCE}"
fi

echo "== build toolchain (informational) =="
for pkg in bison flex protobuf-compiler libprotobuf-dev libnl-route-3-dev; do
  if dpkg -s "${pkg}" >/dev/null 2>&1; then
    note "deb ${pkg} installed"
  else
    warn "deb ${pkg} not installed (use scripts/nsjail/build-nsjail-from-docker.sh if sudo apt is unavailable)"
  fi
done

echo "== runtime libraries for extracted nsjail =="
for lib in libnl-route-3.so.200 libprotobuf.so.32 libprotobuf.so.23; do
  if ldconfig -p 2>/dev/null | grep -q "${lib}"; then
    note "found ${lib}"
  fi
done

if [[ "${failures}" -gt 0 ]]; then
  echo
  echo "Prerequisite check FAILED (${failures} blocking item(s))."
  echo "Do not enable unsandboxed local-process execution when NsJail is absent."
  exit 1
fi

echo
echo "Prerequisite check passed."
