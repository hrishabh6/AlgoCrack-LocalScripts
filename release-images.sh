#!/usr/bin/env bash
# AlgoCrack: publish an immutable RC image set to Docker Hub.
# Place at: <workspace>/scripts/release-images.sh
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/release-images.sh <vX.Y.Z-rc.N> [--dry-run] [--yes]

Build and push the seven AlgoCrack images for linux/amd64.
By default the script requests confirmation before pushing.

Options:
  --dry-run    Validate sources and print build commands; don't build/push.
  --yes        Skip interactive push confirmation.
  -h, --help   Show help.

Optional environment:
  DOCKER_HUB_NAMESPACE  Default: hrishabhjoshi
  RELEASE_PLATFORM      Default: linux/amd64
  RELEASE_OUTPUT_DIR    Default: <workspace>/release-manifests

Requirements: Docker + Buildx, Git, curl; Docker Hub login done beforehand.
No Git pushes/merges, Kubernetes deployments, or local-service shutdowns.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ $# -gt 0 ]] || { usage; exit 2; }
TAG="$1"; shift
DRY_RUN=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
  esac
  shift
done

if ! [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
  echo 'ERROR: Tag must look like v1.0.0-rc.1' >&2
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
NAMESPACE="${DOCKER_HUB_NAMESPACE:-hrishabhjoshi}"
PLATFORM="${RELEASE_PLATFORM:-linux/amd64}"
OUTPUT_BASE="${RELEASE_OUTPUT_DIR:-$ROOT/release-manifests}"
[[ "$NAMESPACE" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo 'ERROR: Invalid Docker Hub namespace' >&2; exit 2; }
[[ "$PLATFORM" =~ ^linux/(amd64|arm64)$ ]] || { echo 'ERROR: Unsupported platform; use linux/amd64 or linux/arm64' >&2; exit 2; }

# image repo|Git repository|Docker build context relative to workspace|Dockerfile relative to workspace
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
require_cmd git
if [[ "$DRY_RUN" -eq 0 ]]; then
  require_cmd docker
  require_cmd curl
  docker info >/dev/null 2>&1 || fail 'Docker daemon is not available.'
  docker buildx version >/dev/null 2>&1 || fail 'Docker Buildx is not available.'
fi

echo "Workspace: $ROOT"
echo "Release:   $TAG"
echo "Namespace: $NAMESPACE"
echo "Platform:  $PLATFORM"
echo

declare -a IMAGES=() REPOS=() CONTEXTS=() DOCKERFILES=() SHAS=()
for entry in "${IMAGE_CONFIG[@]}"; do
  IFS='|' read -r image_name repo context dockerfile <<< "$entry"
  [[ -f "$ROOT/$dockerfile" ]] || fail "Missing Dockerfile: $dockerfile"
  [[ -d "$ROOT/$context" ]] || fail "Missing build context: $context"
  git -C "$ROOT/$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "Not a Git repo: $repo"
  branch="$(git -C "$ROOT/$repo" symbolic-ref --quiet --short HEAD || true)"
  [[ "$branch" == main ]] || fail "$repo is on '$branch', expected main."
  [[ -z "$(git -C "$ROOT/$repo" status --porcelain --untracked-files=normal)" ]] || fail "$repo has uncommitted or untracked files; refuse release."
  sha="$(git -C "$ROOT/$repo" rev-parse HEAD)"
  IMAGES+=("$image_name")
  REPOS+=("$repo")
  CONTEXTS+=("$ROOT/$context")
  DOCKERFILES+=("$ROOT/$dockerfile")
  SHAS+=("$sha")
  printf '%-22s %s:%s  (%s @ %.12s)\n' "$image_name" "$NAMESPACE/$image_name" "$TAG" "$repo" "$sha"
done

echo
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo 'DRY RUN: Planned build/push commands (nothing uploaded):'
  for i in "${!IMAGES[@]}"; do
    ref="${NAMESPACE}/${IMAGES[i]}:$TAG"
    printf '  '
    printf '%q ' docker buildx build --platform "$PLATFORM" --pull \
      --file "${DOCKERFILES[i]}" --tag "$ref" \
      --label "org.opencontainers.image.revision=${SHAS[i]}" \
      --label "org.opencontainers.image.version=$TAG" \
      --push "${CONTEXTS[i]}"
    printf '\n'
  done
  echo
  echo 'NOTE: Build contexts above are inferred from the Dockerfile parent folders.'
  echo 'Verify Dockerfile COPY paths and .dockerignore policies before live publish.'
  exit 0
fi

# Docker Hub's public tags endpoint: accept only a clear 404 as "not published".
# An unknown/network/auth/rate-limit response is fail-closed.
echo 'Checking Docker Hub for existing tags (abort rather than overwrite)...'
for i in "${!IMAGES[@]}"; do
  image_name="${IMAGES[i]}"
  url="https://hub.docker.com/v2/repositories/$NAMESPACE/$image_name/tags/$TAG/"
  status="$(curl --silent --show-error --location --max-time 20 --retry 2 \
    --output /dev/null --write-out '%{http_code}' "$url")" \
    || fail "Could not check remote tag for $image_name (network error)."
  case "$status" in
    404) printf '  %-22s tag not found (OK)\n' "$image_name" ;;
    200) fail "$NAMESPACE/$image_name:$TAG already exists; choose a NEW RC tag." ;;
    *) fail "Docker Hub returned HTTP $status for $image_name. Cannot verify tag uniqueness." ;;
  esac
done

echo
echo 'IMPORTANT: Docker Hub public-tag checks cannot prove absence in private repositories.'
echo 'Enable immutable image tags in Docker Hub if available; never republish the same RC.'
echo 'Ensure Docker Hub login is active and the Dockerfiles/.dockerignore do not copy secrets.'
if [[ "$ASSUME_YES" -eq 0 ]]; then
  [[ -t 0 ]] || fail 'Non-interactive use requires --yes.'
  read -r -p "Build and PUSH all 7 images tagged $TAG? Type PUBLISH to proceed: " answer
  [[ "$answer" == PUBLISH ]] || fail 'Cancelled; no images pushed.'
fi

mkdir -p -- "$OUTPUT_BASE"
OUT="$OUTPUT_BASE/$TAG"
[[ ! -e "$OUT" ]] || fail "Manifest output directory already exists: $OUT"
mkdir -- "$OUT"
TSV="$OUT/images.tsv"
printf 'component\timage\tgit_repository\tgit_sha\tplatform\tmanifest_digest\n' > "$TSV"

for i in "${!IMAGES[@]}"; do
  name="${IMAGES[i]}"
  ref="$NAMESPACE/$name:$TAG"
  echo
  printf '[%d/%d] Building and pushing %s\n' "$((i+1))" "${#IMAGES[@]}" "$ref"
  docker buildx build --platform "$PLATFORM" --pull \
    --file "${DOCKERFILES[i]}" --tag "$ref" \
    --label "org.opencontainers.image.revision=${SHAS[i]}" \
    --label "org.opencontainers.image.version=$TAG" \
    --push "${CONTEXTS[i]}" || fail "Build/push failed: $ref. Images already pushed must NOT be retagged; use a fresh RC for retry."

  echo "Verifying remote digest: $ref"
  inspect="$(docker buildx imagetools inspect "$ref")" || fail "Pushed but unable to inspect: $ref"
  digest="$(printf '%s\n' "$inspect" | awk '$1=="Digest:" && $2~/^sha256:/ {print $2; exit}')"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Pushed but could not extract SHA-256 digest: $ref"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$ref" "${REPOS[i]}" "${SHAS[i]}" "$PLATFORM" "$digest" >> "$TSV"
  echo "Verified $ref@$digest"
done

printf '\nAll %d images pushed and verified.\n' "${#IMAGES[@]}"
echo "Image manifest: $TSV"
echo 'No Kubernetes configuration or Git branches were modified.'
