#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/context/phase1/host-state.txt}"
mkdir -p "$(dirname "${OUT}")"

{
  echo "# captured $(date -Is)"
  uname -a
  echo
  echo "## userns"
  cat /proc/sys/kernel/unprivileged_userns_clone 2>/dev/null || true
  unshare -Ur echo ok 2>&1 || true
  echo
  echo "## cgroup"
  stat -fc %T /sys/fs/cgroup 2>/dev/null || true
  cat /sys/fs/cgroup/cgroup.controllers 2>/dev/null || true
  cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
  echo
  echo "## delegation probe (current user cgroup)"
  if [[ -f /sys/fs/cgroup/cgroup.procs ]]; then
    cat /sys/fs/cgroup/cgroup.procs | wc -l
  fi
  echo
  echo "## java"
  /usr/lib/jvm/java-21-openjdk-amd64/bin/java -version 2>&1 || true
  echo
  echo "## minikube"
  minikube version 2>/dev/null || true
  kubectl version --short 2>/dev/null || kubectl version 2>/dev/null | head -3 || true
} >"${OUT}"

echo "Wrote ${OUT}"
