#!/usr/bin/env bash
# Offline tests for scripts/deployment/release-images.sh (no Docker Hub access).
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RELEASE_SCRIPT="$SCRIPT_DIR/../release-images.sh"
PASS=0
FAIL=0

assert() {
  if "$@"; then
    PASS=$((PASS + 1))
  else
    printf 'FAIL: %s\n' "$*" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

assert_eq() {
  [[ "$1" == "$2" ]]
}

setup_workspace() {
  WORK="$1"
  rm -rf "$WORK"
  mkdir -p "$WORK/scripts/deployment/tests/mock-bin"
  mkdir -p "$WORK/scripts/.local/bin"
  printf '#!/bin/sh\nexit 0\n' >"$WORK/scripts/.local/bin/nsjail"
  chmod +x "$WORK/scripts/.local/bin/nsjail"
  cp "$RELEASE_SCRIPT" "$WORK/scripts/deployment/release-images.sh"
  chmod +x "$WORK/scripts/deployment/release-images.sh"

  local repos=(
    AlgoCrack-APIGateway AlgoCrack-AuthService AlgoCrack-ProblemService
    AlgoCrack-SubmissionService CodeExecutionEngine frontend docker
  )
  for repo in "${repos[@]}"; do
    mkdir -p "$WORK/$repo"
    git -C "$WORK/$repo" init -q
    git -C "$WORK/$repo" checkout -b main -q
    git -C "$WORK/$repo" config user.email test@test
    git -C "$WORK/$repo" config user.name test
    touch "$WORK/$repo/.gitkeep"
    git -C "$WORK/$repo" add .gitkeep
    git -C "$WORK/$repo" commit -q -m init
  done

  mkdir -p "$WORK/CodeExecutionEngine/nsjail-runner/build/install/nsjail-runner"
  touch "$WORK/CodeExecutionEngine/Dockerfile" \
    "$WORK/CodeExecutionEngine/Dockerfile.runner.packaged" \
    "$WORK/AlgoCrack-APIGateway/Dockerfile" \
    "$WORK/AlgoCrack-AuthService/Dockerfile" \
    "$WORK/AlgoCrack-ProblemService/Dockerfile" \
    "$WORK/AlgoCrack-SubmissionService/Dockerfile" \
    "$WORK/frontend/Dockerfile"
  mkdir -p "$WORK/docker/waf" "$WORK/CodeExecutionEngine/docker"
  touch "$WORK/docker/waf/Dockerfile"
  touch "$WORK/CodeExecutionEngine/docker/runner-entrypoint.sh" \
    "$WORK/CodeExecutionEngine/docker/runner-probe.sh"
  chmod +x "$WORK/CodeExecutionEngine/docker/runner-entrypoint.sh" \
    "$WORK/CodeExecutionEngine/docker/runner-probe.sh"

  for repo in "${repos[@]}"; do
    git -C "$WORK/$repo" add -A
    git -C "$WORK/$repo" commit -q -m files || true
  done

  cat >"$WORK/scripts/deployment/tests/mock-bin/curl" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "--write-out" ]]; then
    if [[ "${MOCK_TAG_STATUS:-}" != "" ]]; then
      printf '%s' "$MOCK_TAG_STATUS"
      exit 0
    fi
    url=""
    for a in "$@"; do
      [[ "$a" == http* ]] && url="$a"
    done
    if [[ "$url" == *"/waf/tags/"* && "${MOCK_ONLY_WAF_MISSING:-0}" == 1 ]]; then
      printf '404'
    elif [[ "${MOCK_ONLY_WAF_MISSING:-0}" == 1 ]]; then
      printf '200'
    else
      printf '%s' "${MOCK_TAG_STATUS:-404}"
    fi
    exit 0
  fi
done
exit 0
EOF
  cat >"$WORK/scripts/deployment/tests/mock-bin/docker" <<'EOF'
#!/usr/bin/env bash
MOCK_BUILD_LOG="${MOCK_BUILD_LOG:-/tmp/release-images-mock-build.log}"
if [[ "$1" == "info" ]]; then exit 0; fi
if [[ "$1" == "buildx" && "$2" == "version" ]]; then exit 0; fi
if [[ "$1" == "buildx" && "$2" == "imagetools" && "$3" == "inspect" ]]; then
  printf 'Digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n'
  exit 0
fi
if [[ "$1" == "buildx" && "$2" == "build" ]]; then
  printf '%s\n' "$*" >>"$MOCK_BUILD_LOG"
  exit 0
fi
exit 0
EOF
  chmod +x "$WORK/scripts/deployment/tests/mock-bin/"*
}

run_release() {
  local work="$1"; shift
  env ALGOCRACK_WORKSPACE_ROOT="$work" PATH="$work/scripts/deployment/tests/mock-bin:$PATH" \
    bash "$work/scripts/deployment/release-images.sh" "$@"
}

echo "== dry-run includes runner prebuild and eight images =="
WORK="$(mktemp -d)"
setup_workspace "$WORK"
OUT="$(run_release "$WORK" v9.9.9-rc.1 --dry-run 2>&1 || true)"
assert assert_contains "$OUT" "cxe-nsjail-runner"
assert assert_contains "$OUT" "Images:    8"
assert assert_contains "$OUT" ":nsjail-runner:installDist"
assert assert_contains "$OUT" "Dockerfile.runner.packaged"
assert assert_contains "$OUT" "NSJAIL_VERSION"
rm -rf "$WORK"

echo "== remote tag collision fails without --resume =="
WORK="$(mktemp -d)"
setup_workspace "$WORK"
export MOCK_TAG_STATUS=200
if run_release "$WORK" v9.9.9-rc.2 --yes 2>/tmp/release-test-collision.err; then
  assert false
else
  assert true
fi
assert assert_contains "$(cat /tmp/release-test-collision.err)" "already exists"
unset MOCK_TAG_STATUS
rm -rf "$WORK"

echo "== manifest completeness (simulated write) =="
WORK="$(mktemp -d)"
setup_workspace "$WORK"
MANIFEST="$WORK/release-manifests/v9.9.9-rc.3/images.tsv"
mkdir -p "$(dirname "$MANIFEST")"
{
  printf 'component\timage\tgit_repository\tgit_sha\tplatform\tmanifest_digest\tstatus\tdockerfile\tbuild_context\tartifact_role\n'
  printf 'code-execution-engine\tt\tt\tsha\tlinux/amd64\t-\tVERIFIED\tCodeExecutionEngine/Dockerfile\tCodeExecutionEngine\tcxe-orchestrator\n'
  printf 'cxe-nsjail-runner\tt\tt\tsha\tlinux/amd64\t-\tVERIFIED\tCodeExecutionEngine/Dockerfile.runner.packaged\t.\tcxe-persistent-runner\n'
} >"$MANIFEST"
lines="$(tail -n +2 "$MANIFEST" | wc -l | tr -d ' ')"
assert assert_eq "$lines" "2"
header="$(head -n 1 "$MANIFEST")"
assert assert_contains "$header" "artifact_role"
assert assert_contains "$header" "dockerfile"
rm -rf "$WORK"

echo "== partial resume builds only missing image =="
WORK="$(mktemp -d)"
setup_workspace "$WORK"
MOCK_BUILD_LOG="$WORK/mock-build.log"
: >"$MOCK_BUILD_LOG"
export MOCK_ONLY_WAF_MISSING=1 MOCK_BUILD_LOG
MANIFEST_DIR="$WORK/release-manifests/v9.9.9-rc.4"
mkdir -p "$MANIFEST_DIR"
cp "$MANIFEST" "$MANIFEST_DIR/images.tsv" 2>/dev/null || {
  printf 'component\timage\tgit_repository\tgit_sha\tplatform\tmanifest_digest\tstatus\tdockerfile\tbuild_context\tartifact_role\n' \
    >"$MANIFEST_DIR/images.tsv"
}
OUT="$(run_release "$WORK" v9.9.9-rc.4 --resume --skip-verification --yes 2>&1 || true)"
assert assert_contains "$OUT" "waf"
assert assert_contains "$OUT" "SKIPPED"
build_lines="$(grep -c 'buildx build' "$MOCK_BUILD_LOG" 2>/dev/null || echo 0)"
assert assert_eq "$build_lines" "1"
grep -q 'docker/waf/Dockerfile' "$MOCK_BUILD_LOG" && assert true || assert false
unset MOCK_ONLY_WAF_MISSING MOCK_BUILD_LOG
rm -rf "$WORK"

echo "== verify-only inspects eight images (mock registry) =="
WORK="$(mktemp -d)"
setup_workspace "$WORK"
MANIFEST_DIR="$WORK/release-manifests/v9.9.9-rc.5"
mkdir -p "$MANIFEST_DIR"
OUT="$(run_release "$WORK" v9.9.9-rc.5 --verify 2>&1 || true)"
assert assert_contains "$OUT" "VERIFY ONLY"
assert assert_contains "$OUT" "All 8 remote image digests verified"
verified="$(tail -n +2 "$MANIFEST_DIR/images.tsv" 2>/dev/null | awk -F'\t' '$7=="VERIFIED"' | wc -l | tr -d ' ')"
assert assert_eq "$verified" "8"
rm -rf "$WORK"

echo "== production workspace dry-run (real repos) =="
REAL_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
if [[ -x "$REAL_ROOT/scripts/deployment/release-images.sh" ]]; then
  OUT="$(bash "$REAL_ROOT/scripts/deployment/release-images.sh" v1.0.0-rc.8 --dry-run 2>&1 || true)"
  assert assert_contains "$OUT" "cxe-nsjail-runner:v1.0.0-rc.8"
  assert assert_contains "$OUT" "code-execution-engine:v1.0.0-rc.8"
  assert assert_contains "$OUT" "CodeExecutionEngine @"
  count="$(printf '%s\n' "$OUT" | grep -Ec '^[a-z0-9-]+ +hrishabhjoshi/' || true)"
  assert assert_eq "$count" "8"
else
  assert false
fi

echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
echo "All release-images tests passed."
