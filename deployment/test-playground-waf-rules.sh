#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RULES="$ROOT/helm/algocrack/files/waf/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf"
IMAGE="${WAF_TEST_IMAGE:-hrishabhjoshi/waf:v1.0.0-rc.2}"
CONTAINER="algocrack-playground-waf-test-$$"
STAGED_RULES="$(mktemp)"

command -v docker >/dev/null
command -v curl >/dev/null
command -v jq >/dev/null
[[ -f "$RULES" ]]

cleanup() {
  docker stop "$CONTAINER" >/dev/null 2>&1 || true
  rm -f "$STAGED_RULES"
}
trap cleanup EXIT

# The repository copy can be owner-readable only. Kubernetes projects the
# ConfigMap world-readably, so use the same effective permission in the
# isolated container rather than silently testing the image defaults.
cp "$RULES" "$STAGED_RULES"
chmod 0644 "$STAGED_RULES"

docker run --detach --rm --name "$CONTAINER" \
  --env BACKEND=http://127.0.0.1:9 \
  --env MODSEC_RULE_ENGINE=On \
  --volume "$STAGED_RULES:/opt/owasp-crs/rules/REQUEST-900-EXCLUSION-RULES-BEFORE-CRS.conf:ro" \
  --publish-all "$IMAGE" >/dev/null

port="$(docker port "$CONTAINER" 8080/tcp | head -n 1 | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p')"
[[ -n "$port" ]]
base_url="http://127.0.0.1:$port"

for _ in $(seq 1 30); do
  if curl --silent --max-time 1 -H 'Host: algocrack.test' "$base_url/" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

request_status() {
  local method="$1"
  local path="$2"
  local payload="$3"

  curl --silent --show-error --max-time 10 --output /dev/null --write-out '%{http_code}' \
    --request "$method" \
    --header 'Host: algocrack.test' \
    --header 'Content-Type: application/json' \
    --data "$payload" \
    "$base_url$path"
}

expect_status() {
  local name="$1"
  local expected="$2"
  local method="$3"
  local path="$4"
  local payload="$5"
  local actual

  actual="$(request_status "$method" "$path" "$payload")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL $name: expected HTTP $expected, got $actual" >&2
    exit 1
  fi
  echo "PASS $name: HTTP $actual"
}

playground_payload() {
  local source="$1"
  local stdin="${2:-}"
  local title="${3:-example}"
  local notes="${4:-safe notes}"
  jq -nc --arg sourceCode "$source" --arg stdin "$stdin" --arg title "$title" --arg notes "$notes" \
    '{sourceCode:$sourceCode, language:"java", stdin:$stdin, title:$title, notes:$notes}'
}

printf_source=$'import java.util.*;\npublic class Main {\n  public static void main(String[] args) {\n    int sum = 7;\n    int n = 3;\n    System.out.printf("Average: %.2f%n", (double) sum / n);\n  }\n}'
loop_source=$'public class Main { public static void main(String[] args) { while (true) {} } }'
runtime_source=$'public class Main { public static void main(String[] args) { throw new RuntimeException("boom"); } }'
compile_error_source=$'public class Main { public static void main(String[] args) { System.out.println("missing brace"); }'

# A 502 means ModSecurity admitted the request and the isolated test WAF then
# failed to reach its intentionally unavailable upstream.
expect_status 'printf run source' 502 POST /api/v1/playgrounds/run "$(playground_payload "$printf_source")"
expect_status 'printf create source' 502 POST /api/v1/playgrounds "$(playground_payload "$printf_source")"
expect_status 'printf numeric update source' 502 PUT /api/v1/playgrounds/42 "$(playground_payload "$printf_source")"
expect_status 'loop source' 502 POST /api/v1/playgrounds/run "$(playground_payload "$loop_source")"
expect_status 'runtime-error source' 502 POST /api/v1/playgrounds/run "$(playground_payload "$runtime_source")"
expect_status 'compile-error source' 502 POST /api/v1/playgrounds/run "$(playground_payload "$compile_error_source")"

expect_status 'stdin remains inspected' 403 POST /api/v1/playgrounds/run "$(playground_payload 'public class Main {}' '<script>alert(1)</script>')"
expect_status 'title remains inspected' 403 POST /api/v1/playgrounds "$(playground_payload 'public class Main {}' '' '<script>alert(1)</script>')"
expect_status 'notes remains inspected' 403 PUT /api/v1/playgrounds/42 "$(playground_payload 'public class Main {}' '' 'safe' '<script>alert(1)</script>')"
expect_status 'query sourceCode remains inspected' 403 POST '/api/v1/playgrounds/run?sourceCode=%3Cscript%3Ealert(1)%3C%2Fscript%3E' "$(playground_payload 'public class Main {}')"
expect_status 'other endpoint source remains inspected' 403 POST /api/v1/submissions/run "$(jq -nc --arg code "$printf_source" '{code:$code, language:"java"}')"
expect_status 'malformed JSON remains rejected' 400 POST /api/v1/playgrounds/run '{"sourceCode":'

echo 'PASS isolated Playground WAF compatibility regression matrix'
