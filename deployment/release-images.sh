#!/usr/bin/env bash
# AlgoCrack: publish and verify an immutable Docker Hub RC image set.
# Canonical implementation: <workspace>/scripts/deployment/release-images.sh
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/deployment/release-images.sh <vX.Y.Z-rc.N> [OPTIONS]

Default: build/push all seven AlgoCrack images, checking tags are absent first.

Options:
  --resume             Skip published images; build/push missing images. Preserve
                       original source SHAs for published images in the manifest.
  --skip-verification  Do not inspect digests after pushing (tag-existence checks
                       still run, to prevent overwriting published RC tags).
  --verify             Verification ONLY: check ALL seven remote image digests.
                       No builds, pushes, or tag-existence preflight.
  --dry-run            Print planned actions without network/build/push.
  --yes                Do not prompt before building and pushing.
  -h, --help           Show help.

Examples:
  ./scripts/deployment/release-images.sh v1.0.0-rc.2 --resume --skip-verification
  ./scripts/deployment/release-images.sh v1.0.0-rc.2 --verify
  ./scripts/deployment/release-images.sh v1.0.0-rc.3 --dry-run

Environment:
  DOCKER_HUB_NAMESPACE   Default: hrishabhjoshi
  RELEASE_PLATFORM       Default: linux/amd64
  RELEASE_OUTPUT_DIR     Default: <workspace>/release-manifests

Requires Docker/Buildx, Git, curl for publishing; Docker/Buildx for --verify.
Log in to Docker Hub before publishing. Published RC tags are never replaced.
No Git push/merge, Kubernetes deployment, or local service shutdown.
EOF
}

[[ $# -gt 0 ]] || { usage; exit 2; }
if [[ "$1" == --help || "$1" == -h ]]; then usage; exit 0; fi
TAG="$1"; shift
DRY_RUN=0
ASSUME_YES=0
RESUME=0
SKIP_VERIFICATION=0
VERIFY_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --resume) RESUME=1 ;;
    --skip-verification) SKIP_VERIFICATION=1 ;;
    --verify) VERIFY_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]] || {
  echo 'ERROR: Tag must look like v1.0.0-rc.2' >&2; exit 2;
}
if (( VERIFY_ONLY && (RESUME || SKIP_VERIFICATION || DRY_RUN) )); then
  echo 'ERROR: --verify is standalone (optionally with --yes).' >&2; exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
NAMESPACE="${DOCKER_HUB_NAMESPACE:-hrishabhjoshi}"
PLATFORM="${RELEASE_PLATFORM:-linux/amd64}"
OUTPUT_BASE="${RELEASE_OUTPUT_DIR:-$ROOT/release-manifests}"
[[ "$NAMESPACE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'ERROR: Invalid Docker Hub namespace' >&2; exit 2; }
[[ "$PLATFORM" =~ ^linux/(amd64|arm64)$ ]] || { echo 'ERROR: Unsupported platform' >&2; exit 2; }

# Image repo | Git repository | Build context relative to workspace | Dockerfile
IMAGE_CONFIG=(
  'api-gateway|AlgoCrack-APIGateway|AlgoCrack-APIGateway|AlgoCrack-APIGateway/Dockerfile'
  'auth-service|AlgoCrack-AuthService|AlgoCrack-AuthService|AlgoCrack-AuthService/Dockerfile'
  'problem-service|AlgoCrack-ProblemService|AlgoCrack-ProblemService|AlgoCrack-ProblemService/Dockerfile'
  'submission-service|AlgoCrack-SubmissionService|AlgoCrack-SubmissionService|AlgoCrack-SubmissionService/Dockerfile'
  'code-execution-engine|CodeExecutionEngine|CodeExecutionEngine|CodeExecutionEngine/Dockerfile'
  'frontend|frontend|frontend|frontend/Dockerfile'
  'waf|docker|docker/waf|docker/waf/Dockerfile'
)

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
require_cmd docker
if (( ! VERIFY_ONLY )); then require_cmd git; fi
if (( ! VERIFY_ONLY && ! DRY_RUN )); then
  require_cmd curl
  docker info >/dev/null 2>&1 || fail 'Docker daemon is not available.'
fi
if (( ! DRY_RUN )); then
  docker buildx version >/dev/null 2>&1 || fail 'Docker Buildx is not available.'
fi

OUT="$OUTPUT_BASE/$TAG"
TSV="$OUT/images.tsv"
declare -a IMAGES=() REPOS=() CONTEXTS=() DOCKERFILES=() SHAS=() REMOTE_EXISTS=()
declare -A OLD_SHA=() OLD_DIGEST=() OLD_STATUS=() DIGESTS=() STATUSES=()

# A previous attempt may have left only a header (older script behavior).
# Read original digests and source revisions before modifying the manifest.
if [[ -f "$TSV" ]]; then
  while IFS=$'\t' read -r component image repo sha platform digest status _extra; do
    [[ "$component" == component || -z "$component" ]] && continue
    [[ "$component" =~ ^[a-z0-9-]+$ ]] || fail "Corrupt manifest row: $component"
    [[ -z "${OLD_SHA[$component]+x}" ]] || fail "Duplicate manifest entry: $component"
    OLD_SHA["$component"]="$sha"
    OLD_DIGEST["$component"]="$digest"
    OLD_STATUS["$component"]="${status:-UNKNOWN}"
  done < "$TSV"
fi

# --verify deliberately does not depend on the current Git checkout; its
# provenance comes from a previously recorded manifest, if there is one.
for entry in "${IMAGE_CONFIG[@]}"; do
  IFS='|' read -r name repo context dockerfile <<< "$entry"
  sha='UNKNOWN'
  if (( ! VERIFY_ONLY )); then
    [[ -f "$ROOT/$dockerfile" ]] || fail "Missing Dockerfile: $dockerfile"
    [[ -d "$ROOT/$context" ]] || fail "Missing build context: $context"
    git -C "$ROOT/$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Not a Git repo: $repo"
    branch="$(git -C "$ROOT/$repo" symbolic-ref --quiet --short HEAD || true)"
    [[ "$branch" == main ]] || fail "$repo is on '$branch', expected main."
    [[ -z "$(git -C "$ROOT/$repo" status --porcelain --untracked-files=normal)" ]] || fail "$repo has uncommitted/untracked files."
    sha="$(git -C "$ROOT/$repo" rev-parse HEAD)"
  elif [[ -n "${OLD_SHA[$name]:-}" ]]; then
    sha="${OLD_SHA[$name]}"
  fi
  IMAGES+=("$name") REPOS+=("$repo")
  CONTEXTS+=("$ROOT/$context") DOCKERFILES+=("$ROOT/$dockerfile") SHAS+=("$sha")
  DIGESTS["$name"]="${OLD_DIGEST[$name]:--}"
  STATUSES["$name"]="${OLD_STATUS[$name]:-PENDING}"
done

write_manifest() {
  mkdir -p -- "$OUT"
  local tmp="$OUT/.images.tsv.$$.tmp" i name
  {
    printf 'component\timage\tgit_repository\tgit_sha\tplatform\tmanifest_digest\tstatus\n'
    for i in "${!IMAGES[@]}"; do
      name="${IMAGES[i]}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$NAMESPACE/$name:$TAG" "${REPOS[i]}" "${SHAS[i]}" "$PLATFORM" \
        "${DIGESTS[$name]}" "${STATUSES[$name]}"
    done
  } > "$tmp"
  mv -- "$tmp" "$TSV"
}

# The Digest: line is the registry's top-level manifest/index digest (not a
# per-platform child digest). Inspect errors are retried, including 502s.
INSPECT_DIGEST=''
inspect_digest() {
  local ref="$1" attempt output value
  INSPECT_DIGEST=''
  for attempt in 1 2 3 4; do
    if output="$(docker buildx imagetools inspect "$ref" 2>&1)"; then
      value="$(printf '%s\n' "$output" | awk '$1=="Digest:" && $2~/^sha256:/ {print $2; exit}')"
      if [[ "$value" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        INSPECT_DIGEST="$value"
        return 0
      fi
      printf 'WARNING: Cannot parse remote digest for %s (attempt %d/4)\n' "$ref" "$attempt" >&2
    else
      printf 'WARNING: Remote inspect failed for %s (attempt %d/4): %s\n' \
        "$ref" "$attempt" "$(printf '%s' "$output" | tail -c 320)" >&2
    fi
    if (( attempt < 4 )); then sleep "$attempt"; fi
  done
  return 1
}

# Never silently accept a re-tagged image when a digest was recorded earlier.
record_verified() {
  local name="$1" digest="$2" previous="${DIGESTS[$1]}"
  if [[ "$previous" =~ ^sha256:[0-9a-f]{64}$ && "$previous" != "$digest" ]]; then
    STATUSES["$name"]='DIGEST_MISMATCH'
    write_manifest
    printf 'ERROR: %s digest CHANGED: recorded %s, remote %s\n' "$name" "$previous" "$digest" >&2
    return 1
  fi
  DIGESTS["$name"]="$digest"
  STATUSES["$name"]='VERIFIED'
  write_manifest
}

printf 'Workspace: %s\nRelease:   %s\nNamespace: %s\nPlatform:  %s\n\n' \
  "$ROOT" "$TAG" "$NAMESPACE" "$PLATFORM"
for i in "${!IMAGES[@]}"; do
  printf '%-22s %s:%s' "${IMAGES[i]}" "$NAMESPACE/${IMAGES[i]}" "$TAG"
  if (( ! VERIFY_ONLY )); then printf '  (%s @ %.12s)' "${REPOS[i]}" "${SHAS[i]}"; fi
  printf '\n'
done
printf '\n'

if (( VERIFY_ONLY )); then
  echo 'VERIFY ONLY: inspecting all seven published images (no builds/pushes).'
  failed=0
  for i in "${!IMAGES[@]}"; do
    name="${IMAGES[i]}"; ref="$NAMESPACE/$name:$TAG"
    printf '[%d/%d] %s ... ' "$((i+1))" "${#IMAGES[@]}" "$ref"
    if inspect_digest "$ref"; then
      if record_verified "$name" "$INSPECT_DIGEST"; then
        echo "VERIFIED $INSPECT_DIGEST"
      else
        (( failed+=1 ))
      fi
    else
      echo 'FAILED (missing image or registry/auth error)'
      STATUSES["$name"]='VERIFY_FAILED'
      write_manifest
      (( failed+=1 ))
    fi
  done
  echo "Manifest: $TSV"
  (( failed == 0 )) || fail "$failed of ${#IMAGES[@]} image(s) could not be verified."
  echo 'All seven remote image digests verified. No builds or pushes were performed.'
  exit 0
fi

if (( DRY_RUN )); then
  echo 'DRY RUN: no remote checks, builds, pushes, or manifest changes.'
  for i in "${!IMAGES[@]}"; do
    ref="$NAMESPACE/${IMAGES[i]}:$TAG"
    printf '  '
    printf '%q ' docker buildx build --platform "$PLATFORM" --pull \
      --file "${DOCKERFILES[i]}" --tag "$ref" \
      --label "org.opencontainers.image.revision=${SHAS[i]}" \
      --label "org.opencontainers.image.version=$TAG" \
      --push "${CONTEXTS[i]}"
    printf '\n'
  done
  (( RESUME )) && echo 'With --resume, existing remote tags will be skipped.'
  (( SKIP_VERIFICATION )) && echo 'With --skip-verification, post-push digest inspection is disabled.'
  exit 0
fi

# Preflight ALL seven before any push. Interpret only HTTP 404 as missing.
# Other responses fail closed; never treat a registry outage as a missing tag.
echo 'Checking Docker Hub tags (never overwrite an existing RC tag)...'
missing=0
for i in "${!IMAGES[@]}"; do
  name="${IMAGES[i]}"
  url="https://hub.docker.com/v2/repositories/$NAMESPACE/$name/tags/$TAG/"
  status="$(curl --silent --show-error --location --max-time 30 \
    --retry 3 --retry-delay 2 --output /dev/null --write-out '%{http_code}' "$url")" \
    || fail "Could not check tag for $name; network/registry problem."
  case "$status" in
    200)
      REMOTE_EXISTS[i]=1
      if (( ! RESUME )); then
        fail "$NAMESPACE/$name:$TAG already exists; use --resume to skip it (or a NEW RC tag)."
      fi
      printf '  %-22s EXISTS -> skip push\n' "$name"
      ;;
    404)
      REMOTE_EXISTS[i]=0
      (( missing+=1 ))
      printf '  %-22s not found -> build/push\n' "$name"
      ;;
    *) fail "Docker Hub returned HTTP $status for $name; refusing to guess tag state." ;;
  esac
done

# In resume mode, the registry decides which images are already published.
# Preserve provenance for published images; use current Git revisions ONLY for
# images that will actually be built. An old manifest may have captured SHAs
# for pending images before they were ever published.
if (( RESUME )); then
  echo 'Reconciling source revisions with remote image state...'
  for i in "${!IMAGES[@]}"; do
    name="${IMAGES[i]}"
    current_sha="${SHAS[i]}"
    previous_sha="${OLD_SHA[$name]:-}"
    if (( REMOTE_EXISTS[i] )); then
      if [[ -n "$previous_sha" && "$previous_sha" != UNKNOWN ]]; then
        SHAS[i]="$previous_sha"
        if [[ "$previous_sha" != "$current_sha" ]]; then
          printf '  %-22s published from %.12s; current checkout %.12s (not rebuilt)\n' \
            "$name" "$previous_sha" "$current_sha"
        fi
      else
        SHAS[i]='UNKNOWN'
        printf '  %-22s published; original source SHA unavailable (not rebuilt)\n' "$name"
      fi
    else
      # This tag does not exist: old manifest source data is only a plan.
      # Never preserve a digest or VERIFIED state for a missing remote image.
      if [[ -n "$previous_sha" && "$previous_sha" != UNKNOWN && "$previous_sha" != "$current_sha" ]]; then
        printf '  %-22s pending: updating planned SHA %.12s -> %.12s\n' \
          "$name" "$previous_sha" "$current_sha"
      fi
      DIGESTS["$name"]='-'
      STATUSES["$name"]='PENDING'
    fi
  done
fi

echo
if (( RESUME )); then
  printf 'Resuming %s: %d image(s) missing, %d already published.\n' \
    "$TAG" "$missing" "$((${#IMAGES[@]}-missing))"
else
  echo 'All seven tags are unused.'
fi
echo 'IMPORTANT: public tag checks may be inconclusive for PRIVATE repositories.'
echo 'Enable immutable Docker Hub tags when available; do not reuse RC tags.'
if (( ! SKIP_VERIFICATION )); then
  echo 'Remote digest verification enabled (with retries).'
else
  echo 'Post-push digest verification disabled. Run --verify separately afterward.'
fi
if (( ! ASSUME_YES && missing > 0 )); then
  [[ -t 0 ]] || fail 'Non-interactive use requires --yes.'
  read -r -p "Build and PUSH $missing missing image(s) tagged $TAG? Type PUBLISH: " answer
  [[ "$answer" == PUBLISH ]] || fail 'Cancelled; nothing pushed.'
fi

# New releases cannot accidentally replace a prior local manifest; resumes can
# update an interrupted manifest, including one created by the older script.
if (( ! RESUME )) && [[ -e "$OUT" ]]; then
  fail "Manifest output directory exists: $OUT (use --resume if this is an interrupted attempt)."
fi
write_manifest

for i in "${!IMAGES[@]}"; do
  name="${IMAGES[i]}"; ref="$NAMESPACE/$name:$TAG"
  echo
  if (( REMOTE_EXISTS[i] )); then
    if (( SKIP_VERIFICATION )); then
      if [[ "${DIGESTS[$name]}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "[ $((i+1))/${#IMAGES[@]} ] SKIPPED (previously recorded digest): $ref"
      else
        STATUSES["$name"]='SKIPPED_UNVERIFIED'
        write_manifest
        echo "[ $((i+1))/${#IMAGES[@]} ] SKIPPED (remote tag exists, digest not checked): $ref"
      fi
      continue
    fi
    echo "[$((i+1))/${#IMAGES[@]}] Existing image; verifying: $ref"
  else
    echo "[$((i+1))/${#IMAGES[@]}] Building and pushing: $ref"
    docker buildx build --platform "$PLATFORM" --pull \
      --file "${DOCKERFILES[i]}" --tag "$ref" \
      --label "org.opencontainers.image.revision=${SHAS[i]}" \
      --label "org.opencontainers.image.version=$TAG" \
      --push "${CONTEXTS[i]}" || fail "Build/push failed for $ref; use --resume to recover."
    STATUSES["$name"]='PUSHED_UNVERIFIED'
    DIGESTS["$name"]='-'
    write_manifest
    if (( SKIP_VERIFICATION )); then
      echo "PUSHED without verification: $ref"
      continue
    fi
  fi
  echo "Verifying remote digest: $ref"
  inspect_digest "$ref" || fail "Pushed/present but cannot inspect $ref. Rerun --resume or --verify later."
  record_verified "$name" "$INSPECT_DIGEST" || fail "Digest mismatch: $ref"
  echo "VERIFIED $ref@$INSPECT_DIGEST"
done

printf '\nRelease processing complete: %s\nManifest: %s\n' "$TAG" "$TSV"
if (( SKIP_VERIFICATION )); then
  echo 'Some images may be unverified. Run the same tag with --verify to verify ALL seven.'
else
  echo 'All seven images have verified remote digests.'
fi
echo 'No Kubernetes configuration or Git branches were modified.'
