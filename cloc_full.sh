#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INCLUDE_GENERATED=false
DETAILS=false

# These directories are project-local but reproducible or machine-local. They
# are excluded from the default full-project report so dependency/build output
# does not drown out the actual files maintained in the workspace. Use
# --include-generated when you want a literal scan of every non-Git file.
EXCLUDED_DIRS=(
  .git
  .gradle
  build
  target
  node_modules
  .next
  dist
  coverage
  .dev-logs
  .dev-pids
  .dev-observability
)

usage() {
  cat <<'EOF'
Usage: scripts/cloc_full.sh [--details] [--include-generated]

Measures every readable project file under the workspace, including:
  source code, tests, documentation, prompts, configuration, scripts,
  migrations, fixtures, and files in nested repositories.

Default exclusions:
  Git metadata and reproducible dependency/build/runtime directories.

Options:
  --details             Print a report for each top-level project directory.
  --include-generated   Include dependency caches, build output, and local
                        runtime directories in the scan.
  -h, --help            Show this help text.
EOF
}

while (($# > 0)); do
  case "$1" in
    --details)
      DETAILS=true
      ;;
    --include-generated)
      INCLUDE_GENERATED=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

for command_name in cloc find sort awk wc; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ALL_FILES="$TMP_DIR/all-files.txt"
: > "$ALL_FILES"

find_args=("$ROOT" -type f -readable)
if [[ "$INCLUDE_GENERATED" != "true" ]]; then
  for directory in "${EXCLUDED_DIRS[@]}"; do
    find_args+=( -not -path "*/$directory" -not -path "*/$directory/*" )
  done
fi

# -P prevents following a symlink out of the workspace. This also avoids
# counting the same external file twice when a local link is present.
find -P "${find_args[@]}" -print0 \
  | while IFS= read -r -d '' file_path; do
      printf '%s\n' "$file_path"
    done \
  | sort -u > "$ALL_FILES"

run_cloc_report() {
  local title="$1"
  local file_list="$2"
  local output
  local timeout_args=()

  # Generated/minified bundles can exceed cloc's default filter timeout. In
  # literal-scan mode, completeness is preferred over silently omitting those
  # files; the trade-off is a potentially much longer run.
  if [[ "$INCLUDE_GENERATED" == "true" ]]; then
    timeout_args+=(--timeout=0)
  fi

  echo
  echo "================================================================"
  echo "$title"
  echo "================================================================"

  if [[ ! -s "$file_list" ]]; then
    echo "No readable files found."
    return 0
  fi

  cloc \
    --list-file="$file_list" \
    "${timeout_args[@]}" \
    --skip-uniqueness \
    --quiet
}

echo "================================================================"
echo "AlgoCrack Full Project Size"
echo "================================================================"
echo "Root:  $ROOT"
echo "Files: $(wc -l < "$ALL_FILES" | awk '{print $1}') readable regular files"

if [[ "$INCLUDE_GENERATED" == "true" ]]; then
  echo "Scope: every readable non-Git file, including generated/cached output"
  echo "Note: generated files are scanned without cloc's per-file timeout"
else
  echo "Scope: every readable project file except reproducible/generated caches"
  echo "Excluded directories: ${EXCLUDED_DIRS[*]}"
fi

run_cloc_report "Full project (all recognized languages and file types)" "$ALL_FILES"

if [[ "$DETAILS" == "true" ]]; then
  while IFS= read -r top_level; do
    detail_list="$TMP_DIR/detail-${top_level//[^[:alnum:]_.-]/_}.txt"
    if [[ "$top_level" == "." ]]; then
      awk -v root="$ROOT" '
        index($0, root "/") == 1 {
          relative = substr($0, length(root) + 2)
          if (index(relative, "/") == 0) print
        }
      ' "$ALL_FILES" > "$detail_list"
    else
      awk -v root="$ROOT" -v prefix="$top_level/" \
        'index($0, root "/" prefix) == 1 { print }' "$ALL_FILES" > "$detail_list"
    fi
    run_cloc_report "Full project: $top_level" "$detail_list"
  done < <(
    awk -v root="$ROOT" '
      index($0, root "/") == 1 {
        relative = substr($0, length(root) + 2)
        split(relative, parts, "/")
        if (index(relative, "/") == 0) print "."
        else print parts[1]
      }
    ' "$ALL_FILES" | sort -u
  )
fi
