#!/usr/bin/env bash
# Curate POTD metadata, grant a local admin role, and publish today's UTC challenge.
# Requires: MySQL with problem_db + auth_db, Flyway V3 (ProblemService) and V2 (Auth) applied.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

strip_optional_quotes() {
  local v="$1"
  v="${v%$'\r'}"
  if [[ "$v" == \"*\" && "$v" == *\" ]]; then v="${v:1:${#v}-2}"; fi
  printf '%s' "$v"
}

if [[ -f "$ROOT/.env" ]]; then
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] && continue
    export "$key=$(strip_optional_quotes "$value")"
  done < "$ROOT/.env"
fi

MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
SPRING_DATASOURCE_USERNAME="${SPRING_DATASOURCE_USERNAME:-root}"
SPRING_DATASOURCE_PASSWORD="${SPRING_DATASOURCE_PASSWORD:-change-me}"
POTD_ADMIN_EMAIL="${POTD_ADMIN_EMAIL:-}"

mysql_exec() {
  mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$SPRING_DATASOURCE_USERNAME" -p"$SPRING_DATASOURCE_PASSWORD" "$@"
}

echo "==> POTD local bootstrap (UTC date for challenge)"

mysql_exec -N -B -e "SELECT 1 FROM information_schema.tables WHERE table_schema='problem_db' AND table_name='daily_challenge'" | grep -q 1 || {
  echo "ERROR: problem_db.daily_challenge missing. Start ProblemService once so Flyway V3 runs." >&2
  exit 1
}

mysql_exec -N -B -e "SELECT 1 FROM information_schema.columns WHERE table_schema='auth_db' AND table_name='user' AND column_name='role'" | grep -q 1 || {
  echo "ERROR: auth_db.user.role missing. Start AuthService once so Flyway V2 runs." >&2
  exit 1
}

echo "==> Curating potd_problem_metadata for structurally complete questions"
mysql_exec problem_db <<'SQL'
INSERT INTO potd_problem_metadata (
  question_id, eligible, curation_status, quality_score, primary_tag_id,
  validation_status, validated_at, reviewed_at, reviewed_by
)
SELECT
  q.id,
  1,
  'APPROVED',
  85,
  (SELECT qt.tag_id FROM question_tag qt WHERE qt.question_id = q.id ORDER BY qt.tag_id LIMIT 1),
  'VALID',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  'bootstrap-potd-local'
FROM question q
WHERE EXISTS (SELECT 1 FROM reference_solution rs WHERE rs.question_id = q.id)
  AND EXISTS (SELECT 1 FROM test_case tc WHERE tc.question_id = q.id)
  AND NOT EXISTS (SELECT 1 FROM potd_problem_metadata m WHERE m.question_id = q.id);
SQL

mysql_exec problem_db <<'SQL'
UPDATE potd_problem_metadata m
INNER JOIN question q ON q.id = m.question_id
SET
  m.eligible = 1,
  m.curation_status = 'APPROVED',
  m.validation_status = 'VALID',
  m.quality_score = GREATEST(m.quality_score, 80),
  m.primary_tag_id = COALESCE(
    m.primary_tag_id,
    (SELECT qt.tag_id FROM question_tag qt WHERE qt.question_id = q.id ORDER BY qt.tag_id LIMIT 1)
  ),
  m.validated_at = COALESCE(m.validated_at, CURRENT_TIMESTAMP),
  m.reviewed_at = CURRENT_TIMESTAMP,
  m.reviewed_by = 'bootstrap-potd-local'
WHERE EXISTS (SELECT 1 FROM reference_solution rs WHERE rs.question_id = q.id)
  AND EXISTS (SELECT 1 FROM test_case tc WHERE tc.question_id = q.id);
SQL

echo "==> Granting ADMIN role"
if [[ -n "$POTD_ADMIN_EMAIL" ]]; then
  mysql_exec auth_db -e "UPDATE user SET role = 'ADMIN' WHERE email = '${POTD_ADMIN_EMAIL}' LIMIT 1;"
else
  mysql_exec auth_db -e "UPDATE user SET role = 'ADMIN' ORDER BY id ASC LIMIT 1;"
fi

TODAY_UTC="$(date -u +%F)"
QUESTION_ID="$(mysql_exec problem_db -N -B -e "
SELECT q.id
FROM question q
INNER JOIN potd_problem_metadata m ON m.question_id = q.id
WHERE m.eligible = 1
  AND m.curation_status = 'APPROVED'
  AND m.validation_status = 'VALID'
  AND m.primary_tag_id IS NOT NULL
  AND q.status = 'PUBLISHED'
ORDER BY q.id ASC
LIMIT 1;
")"

if [[ -z "$QUESTION_ID" ]]; then
  echo "ERROR: No eligible question after curation. Check catalogue seed data." >&2
  exit 1
fi

echo "==> Publishing daily challenge for UTC ${TODAY_UTC} (question ${QUESTION_ID})"
mysql_exec problem_db <<SQL
INSERT INTO daily_challenge (
  challenge_date, question_id, status, selection_type, locked,
  scheduler_version, configuration_hash, deterministic_seed,
  published_at, published_by, created_by, updated_by, version
)
SELECT
  '${TODAY_UTC}',
  ${QUESTION_ID},
  'PUBLISHED',
  'MANUAL',
  0,
  'potd-planner-v1',
  'bootstrap-local',
  CONCAT('bootstrap-', '${TODAY_UTC}', '-', ${QUESTION_ID}),
  CURRENT_TIMESTAMP,
  'bootstrap-potd-local',
  'bootstrap-potd-local',
  'bootstrap-potd-local',
  0
FROM DUAL
WHERE NOT EXISTS (
  SELECT 1 FROM daily_challenge dc
  WHERE dc.challenge_date = '${TODAY_UTC}' AND dc.status = 'PUBLISHED'
);
SQL

echo "==> Done. Verify: curl -s http://localhost:${API_GATEWAY_PORT:-9090}/api/v1/daily-challenges/today | head"
