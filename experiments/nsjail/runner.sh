#!/usr/bin/env bash
set -euo pipefail

fixture="${1:?fixture name required}"
shift

case "$fixture" in
  Hello.java|NetworkProbe.java|FileProbe.java|ForkBomb.java|Loop.java|AnnotationProcessor.java|Annotated.java)
    ;;
  *)
    echo "unsupported fixture: $fixture" >&2
    exit 64
    ;;
esac

rm -rf /workspace/*
cp "/opt/nsjail-fixtures/$fixture" /workspace/
if [ "$fixture" = "AnnotationProcessor.java" ]; then
  cp "/opt/nsjail-fixtures/Annotated.java" /workspace/
fi

# A fresh nsjail invocation creates user, PID, mount, IPC, UTS, and network
# namespaces. The jail root intentionally contains only the Java runtime and
# dynamic-loader dependencies needed for these feasibility checks. Java reserves
# substantial virtual address space even with a small heap, so the 512 MiB Pod
# memory limit is the physical-memory backstop while rlimit_as is 2 GiB.
exec /usr/local/bin/nsjail \
  --quiet \
  --mode o \
  --chroot /opt/jail-root \
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
  --bindmount_ro /opt/java:/opt/java \
  --bindmount /workspace \
  --tmpfsmount /tmp \
  -- /bin/bash -lc "export PATH=/opt/java/openjdk/bin:\$PATH LD_LIBRARY_PATH=/opt/java/openjdk/lib JAVA_TOOL_OPTIONS='-Xmx256m -XX:MaxMetaspaceSize=128m -XX:CompressedClassSpaceSize=64m -XX:ReservedCodeCacheSize=32m'; $*"
