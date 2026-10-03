#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# These are the active, deployable AlgoCrack repositories. Documentation,
# backups, runtime data, generated output, IDE state, and dependency caches are
# intentionally not project code and are not scanned.
ACTIVE_REPOS=(
  AlgoCrack-APIGateway
  AlgoCrack-AuthService
  AlgoCrack-ProblemService
  AlgoCrack-SubmissionService
  CodeExecutionEngine
  frontend
  docker
  k8s
  helm
  scripts
)

QUESTION_BANK_DUMP="k8s/all_databases_dump.sql"
DETAILS=false

usage() {
  cat <<'EOF'
Usage: scripts/cloc.sh [--details]

Reports these separate measurements:
  1. Production and operational code (no tests or question-bank content)
  2. Test and verification code
  3. Maintained engineering code (production + tests, no question code)
  4. Embedded question code (templates + reference solutions)
  5. Project code including the embedded question code

Only Git-tracked or non-ignored files in active repositories are considered.
Use --details to also print a maintained-code report for each repository.
EOF
}

while (($# > 0)); do
  case "$1" in
    --details)
      DETAILS=true
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

for command_name in cloc git awk; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
done

for repo in "${ACTIVE_REPOS[@]}"; do
  if [[ ! -d "$ROOT/$repo/.git" ]]; then
    echo "Expected active Git repository is missing: $ROOT/$repo" >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PRODUCTION_LIST="$TMP_DIR/production-files.txt"
TEST_LIST="$TMP_DIR/test-files.txt"
MAINTAINED_LIST="$TMP_DIR/maintained-files.txt"
: > "$PRODUCTION_LIST"
: > "$TEST_LIST"
: > "$MAINTAINED_LIST"

is_relevant_code_file() {
  local relative_path="$1"
  local base_name="${relative_path##*/}"

  case "$relative_path" in
    */gradle/wrapper/*|*/package-lock.json|*/yarn.lock|*/pnpm-lock.yaml)
      return 1
      ;;
  esac

  case "$base_name" in
    Dockerfile|dockerfile|Makefile)
      return 0
      ;;
  esac

  case "$relative_path" in
    *.java|*.kt|*.kts|*.scala|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.css|*.html|*.sh|*.bash|*.sql|*.yml|*.yaml|*.xml|*.properties|*.gradle|*.json|*.feature|*.tpl|*.alloy|*.hcl)
      return 0
      ;;
  esac

  return 1
}

is_test_file() {
  local relative_path="$1"

  case "$relative_path" in
    */src/test/*|*/src/tests/*|*/test/*|*/tests/*|*/__tests__/*|*.test.ts|*.test.tsx|*.test.js|*.test.jsx|*.spec.ts|*.spec.tsx|*.spec.js|*.spec.jsx)
      return 0
      ;;
  esac

  return 1
}

for repo in "${ACTIVE_REPOS[@]}"; do
  while IFS= read -r -d '' repo_path; do
    project_path="$repo/$repo_path"

    is_relevant_code_file "$project_path" || continue

    # The dump is generated catalogue data. Its embedded templates and
    # reference solutions are measured separately below, so the serialized SQL
    # must not inflate the maintained engineering-code totals.
    [[ "$project_path" == "$QUESTION_BANK_DUMP" ]] && continue

    absolute_path="$ROOT/$project_path"
    [[ -f "$absolute_path" ]] || continue

    printf '%s\n' "$absolute_path" >> "$MAINTAINED_LIST"
    if is_test_file "$project_path"; then
      printf '%s\n' "$absolute_path" >> "$TEST_LIST"
    else
      printf '%s\n' "$absolute_path" >> "$PRODUCTION_LIST"
    fi
  done < <(git -C "$ROOT/$repo" ls-files --cached --others --exclude-standard -z)
done

sort -u -o "$PRODUCTION_LIST" "$PRODUCTION_LIST"
sort -u -o "$TEST_LIST" "$TEST_LIST"
sort -u -o "$MAINTAINED_LIST" "$MAINTAINED_LIST"

run_cloc_report() {
  local title="$1"
  local file_list="$2"
  local result_variable="$3"
  local output
  local code_lines

  echo
  echo "================================================================"
  echo "$title"
  echo "================================================================"

  if [[ ! -s "$file_list" ]]; then
    echo "No matching files."
    printf -v "$result_variable" '%s' 0
    return 0
  fi

  output="$(
    cloc \
      --list-file="$file_list" \
      --force-lang=YAML,tpl \
      --force-lang=HCL,alloy \
      --skip-uniqueness \
      --quiet
  )"
  printf '%s\n' "$output"

  code_lines="$(printf '%s\n' "$output" | awk '$1 == "SUM:" { print $NF }')"
  if [[ ! "$code_lines" =~ ^[0-9]+$ ]]; then
    echo "Could not read the CLOC total for: $title" >&2
    exit 1
  fi
  printf -v "$result_variable" '%s' "$code_lines"
}

measure_embedded_question_code() {
  local dump_path="$ROOT/$QUESTION_BANK_DUMP"

  if [[ ! -f "$dump_path" ]]; then
    printf '0 0 0\n'
    return 0
  fi

  # The dump serializes every source-code newline as a literal \n. The two
  # selected INSERT statements contain code templates and reference solutions;
  # question prose and testcase data are deliberately excluded. Each source
  # blob contributes one initial line in addition to its encoded newlines.
  awk '
    /^INSERT INTO `(question_metadata|reference_solution)` VALUES / {
      scan = $0
      newline_count += gsub(/\\n/, "", scan)

      scan = $0
      java_blobs += gsub(/,\047JAVA\047,/, "", scan)

      scan = $0
      python_blobs += gsub(/,\047PYTHON\047,/, "", scan)
    }
    END {
      blob_count = java_blobs + python_blobs
      print newline_count + blob_count, blob_count, newline_count
    }
  ' "$dump_path"
}

echo "================================================================"
echo "AlgoCrack Project Size"
echo "================================================================"
echo "Scope: Git-tracked and non-ignored code/config in active repositories"
echo "Root:  $ROOT"
echo
echo "Excluded: generated builds, dependencies, Git history, IDE/runtime data,"
echo "          backups, documentation, binary assets, keys, and lock files."
echo "Question statements and test vectors are data, not source code."

run_cloc_report \
  "1. Production and operational code (tests and question code excluded)" \
  "$PRODUCTION_LIST" \
  PRODUCTION_CODE_LINES

run_cloc_report \
  "2. Test and verification code only" \
  "$TEST_LIST" \
  TEST_CODE_LINES

run_cloc_report \
  "3. Maintained engineering code (tests included; question code excluded)" \
  "$MAINTAINED_LIST" \
  MAINTAINED_CODE_LINES

read -r QUESTION_CODE_LINES QUESTION_CODE_BLOBS QUESTION_CODE_NEWLINES < <(measure_embedded_question_code)
TOTAL_WITH_QUESTION_CODE=$((MAINTAINED_CODE_LINES + QUESTION_CODE_LINES))

echo
echo "================================================================"
echo "Question-code contribution"
echo "================================================================"
echo "Source: $QUESTION_BANK_DUMP"
echo "Embedded templates/reference solutions: $QUESTION_CODE_BLOBS"
echo "Embedded logical code lines:           $QUESTION_CODE_LINES"
echo "Encoded newline markers inspected:     $QUESTION_CODE_NEWLINES"
echo
echo "The embedded total is newline-based because the SQL dump stores source"
echo "inside string values. Problem statements and testcase values are omitted."

if [[ "$DETAILS" == "true" ]]; then
  for repo in "${ACTIVE_REPOS[@]}"; do
    repo_list="$TMP_DIR/${repo//\//_}-files.txt"
    awk -v prefix="$ROOT/$repo/" 'index($0, prefix) == 1' "$MAINTAINED_LIST" > "$repo_list"
    run_cloc_report "Maintained code by repository: $repo" "$repo_list" REPO_CODE_LINES
  done
fi

echo
echo "================================================================"
echo "Final project-size summary"
echo "================================================================"
printf '%-58s %12d\n' "Production/operational code:" "$PRODUCTION_CODE_LINES"
printf '%-58s %12d\n' "Test/verification code:" "$TEST_CODE_LINES"
printf '%-58s %12d\n' "Project code excluding embedded question code:" "$MAINTAINED_CODE_LINES"
printf '%-58s %12d\n' "Embedded question templates/reference solutions:" "$QUESTION_CODE_LINES"
printf '%-58s %12d\n' "Project code including embedded question code:" "$TOTAL_WITH_QUESTION_CODE"
echo "================================================================"
