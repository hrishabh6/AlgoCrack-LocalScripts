#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$ROOT/.dev-logs"
PID_DIR="$ROOT/.dev-pids"
OBS_DIR="${DEV_LOCAL_OBSERVABILITY_DIR:-$ROOT/.dev-observability}"

mkdir -p "$LOG_DIR" "$PID_DIR" "$OBS_DIR"

strip_optional_quotes() {
  local value="$1"
  value="${value%$'\r'}"

  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "$value"
}

load_env_file() {
  local env_file="$1"

  [[ -f "$env_file" ]] || return 0

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] && continue

    value="$(strip_optional_quotes "$value")"
    export "$key=$value"
  done < "$env_file"
}

load_env_file "$ROOT/.env"
load_env_file "$ROOT/AlgoCrack-AuthService/.env"

API_GATEWAY_PORT_FROM_ENV="${API_GATEWAY_PORT+x}"
NEXT_PUBLIC_API_BASE_URL_FROM_ENV="${NEXT_PUBLIC_API_BASE_URL+x}"
GOOGLE_REDIRECT_URI_FROM_ENV="${GOOGLE_REDIRECT_URI+x}"

java_major_version() {
  local java_bin="$1"

  "$java_bin" -version 2>&1 | awk -F'"' '/version/ { split($2, parts, "."); print parts[1]; exit }'
}

use_java_home_if_valid() {
  local candidate="$1"

  [[ -x "$candidate/bin/java" ]] || return 1
  [[ "$(java_major_version "$candidate/bin/java")" == "21" ]] || return 1

  export JAVA_HOME="$candidate"
  export PATH="$JAVA_HOME/bin:$PATH"
}

detect_java21() {
  local candidate

  if [[ -n "${JAVA_HOME:-}" ]] && use_java_home_if_valid "$JAVA_HOME"; then
    return 0
  fi

  if command -v java >/dev/null 2>&1 && [[ "$(java_major_version "$(command -v java)")" == "21" ]]; then
    return 0
  fi

  for candidate in \
    /usr/lib/jvm/java-21-* \
    /usr/lib/jvm/jdk-21* \
    "$HOME"/.jdks/*21* \
    "$HOME"/.sdkman/candidates/java/*21*; do
    use_java_home_if_valid "$candidate" && return 0
  done

  return 1
}

MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-change-me}"
MYSQL_DATABASE="${MYSQL_DATABASE:-leetcode}"
MYSQL_HOST="${MYSQL_HOST:-localhost}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
REDIS_HOST="${REDIS_HOST:-localhost}"
REDIS_PORT="${REDIS_PORT:-6379}"
SPRING_DATASOURCE_USERNAME="${SPRING_DATASOURCE_USERNAME:-root}"
SPRING_DATASOURCE_PASSWORD="${SPRING_DATASOURCE_PASSWORD:-$MYSQL_ROOT_PASSWORD}"
DEV_LOCAL_INFRA_WAIT_SECONDS="${DEV_LOCAL_INFRA_WAIT_SECONDS:-60}"
JWT_EXPIRY="${JWT_EXPIRY:-604800}"
COOKIE_EXPIRY="${COOKIE_EXPIRY:-604800}"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-local-google-client-id}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-local-google-client-secret}"
API_GATEWAY_PORT="${API_GATEWAY_PORT:-9090}"
GOOGLE_REDIRECT_URI="${GOOGLE_REDIRECT_URI:-http://localhost:$API_GATEWAY_PORT/api/v1/auth/login/oauth2/code/google}"
WORKER_COUNT="${WORKER_COUNT:-5}"
EXECUTION_WORKER_QUEUE_CAPACITY="${EXECUTION_WORKER_QUEUE_CAPACITY:-100}"
EXECUTION_TIMEOUT_SECONDS="${EXECUTION_TIMEOUT_SECONDS:-10}"
EXECUTION_POLL_TIMEOUT_SECONDS="${EXECUTION_POLL_TIMEOUT_SECONDS:-5}"
EXECUTION_MEMORY_SOFT_LIMIT_MB="${EXECUTION_MEMORY_SOFT_LIMIT_MB:-256}"
EXECUTION_COMPILATION_TIMEOUT_SECONDS="${EXECUTION_COMPILATION_TIMEOUT_SECONDS:-30}"
NEXT_PUBLIC_API_BASE_URL="${NEXT_PUBLIC_API_BASE_URL:-http://localhost:$API_GATEWAY_PORT}"
DEV_LOCAL_OBSERVABILITY="${DEV_LOCAL_OBSERVABILITY:-true}"
PROMETHEUS_PORT="${PROMETHEUS_PORT:-9091}"
LOKI_PORT="${LOKI_PORT:-3100}"
GRAFANA_PORT="${GRAFANA_PORT:-3001}"
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
# Playground is on for local dev by default (local-process sandbox — not hostile-code safe).
# Opt out: DEV_LOCAL_PLAYGROUND=false ./scripts/dev-local.sh up
# Production defaults in application.yml stay false; K8s verification gate unchanged.
DEV_LOCAL_PLAYGROUND="${DEV_LOCAL_PLAYGROUND:-true}"
# Complexity analysis is enabled locally as static analysis only. Dynamic profiling
# remains off because it requires the production-style benchmark/profile services.
DEV_LOCAL_COMPLEXITY="${DEV_LOCAL_COMPLEXITY:-true}"

if [[ "$DEV_LOCAL_PLAYGROUND" == "true" ]]; then
  PLAYGROUND_API_ENABLED=true
  PLAYGROUND_RUN_ENABLED=true
  EXECUTION_PLAYGROUND_ENABLED=true
  EXECUTION_PLAYGROUND_SANDBOX_BACKEND=local-process
  NEXT_PUBLIC_PLAYGROUND_ENABLED=true
else
  PLAYGROUND_API_ENABLED=false
  PLAYGROUND_RUN_ENABLED=false
  EXECUTION_PLAYGROUND_ENABLED=false
  NEXT_PUBLIC_PLAYGROUND_ENABLED=false
  EXECUTION_PLAYGROUND_SANDBOX_BACKEND="${EXECUTION_PLAYGROUND_SANDBOX_BACKEND:-local-process}"
fi

if [[ "$DEV_LOCAL_COMPLEXITY" == "true" ]]; then
  COMPLEXITY_API_ENABLED=true
  COMPLEXITY_STATIC_ANALYSIS_ENABLED=true
  COMPLEXITY_DYNAMIC_PROFILING_ENABLED=false
else
  COMPLEXITY_API_ENABLED=false
  COMPLEXITY_STATIC_ANALYSIS_ENABLED=false
  COMPLEXITY_DYNAMIC_PROFILING_ENABLED=false
fi

is_google_oauth_placeholder() {
  case "${1:-}" in
    ""|"local-google-client-id"|"local-google-client-secret"|"your-google-client-id"|"your-google-client-secret")
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

set_google_oauth_env_if_placeholder() {
  local key="$1"
  local value="$2"

  [[ -z "$value" ]] && return 0
  if is_google_oauth_placeholder "${!key:-}"; then
    export "$key=$value"
  fi
}

load_auth_local_oauth_secrets() {
  local secrets_file="$ROOT/AlgoCrack-AuthService/.local.secrets.properties"

  [[ -f "$secrets_file" ]] || return 0

  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="$(strip_optional_quotes "$value")"

    case "$key" in
      spring.security.oauth2.client.registration.google.client-id)
        set_google_oauth_env_if_placeholder GOOGLE_CLIENT_ID "$value"
        ;;
      spring.security.oauth2.client.registration.google.client-secret)
        set_google_oauth_env_if_placeholder GOOGLE_CLIENT_SECRET "$value"
        ;;
    esac
  done < "$secrets_file"
}

load_auth_local_oauth_secrets

export MYSQL_ROOT_PASSWORD MYSQL_DATABASE MYSQL_HOST MYSQL_PORT REDIS_HOST REDIS_PORT
export SPRING_DATASOURCE_USERNAME SPRING_DATASOURCE_PASSWORD
export JWT_EXPIRY COOKIE_EXPIRY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET GOOGLE_REDIRECT_URI
export WORKER_COUNT EXECUTION_WORKER_QUEUE_CAPACITY EXECUTION_TIMEOUT_SECONDS
export EXECUTION_POLL_TIMEOUT_SECONDS EXECUTION_MEMORY_SOFT_LIMIT_MB EXECUTION_COMPILATION_TIMEOUT_SECONDS
export API_GATEWAY_PORT NEXT_PUBLIC_API_BASE_URL DEV_LOCAL_OBSERVABILITY PROMETHEUS_PORT LOKI_PORT GRAFANA_PORT
export GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD
export DEV_LOCAL_PLAYGROUND PLAYGROUND_API_ENABLED PLAYGROUND_RUN_ENABLED
export EXECUTION_PLAYGROUND_ENABLED EXECUTION_PLAYGROUND_SANDBOX_BACKEND NEXT_PUBLIC_PLAYGROUND_ENABLED
export DEV_LOCAL_COMPLEXITY COMPLEXITY_API_ENABLED COMPLEXITY_STATIC_ANALYSIS_ENABLED
export COMPLEXITY_DYNAMIC_PROFILING_ENABLED

usage() {
  cat <<'EOF'
Usage:
  scripts/dev-local.sh up              Start local MySQL/Redis + live Java/Next dev servers
  scripts/dev-local.sh down            Stop local app processes
  scripts/dev-local.sh restart         Restart the full local dev stack
  scripts/dev-local.sh status          Show local dev process status
  scripts/dev-local.sh logs [service]  Tail all logs or one service log
  scripts/dev-local.sh seed            Seed problem_db from k8s/all_databases_dump.sql when empty
  scripts/dev-local.sh bootstrap-potd  Curate POTD metadata, grant ADMIN, publish today (UTC)

  scripts/dev-local.sh observability   Generate/start local Prometheus, Loki, Alloy, and Grafana

  Playground (local dev):
  - Enabled by default on `up` (local-process CXE backend; trusted dev only — not a hostile-code sandbox).
  - Sets PLAYGROUND_* / EXECUTION_PLAYGROUND_* / NEXT_PUBLIC_PLAYGROUND_ENABLED for the launcher.
  - Disable: DEV_LOCAL_PLAYGROUND=false ./scripts/dev-local.sh up
  - If playground-related env changed, `up` restarts submission-service, CXE, and frontend once.

This runs the app like a traditional IDE setup: local MySQL/Redis must already be
running, while each microservice and the Next.js app run as separate live dev
processes. No Docker containers are started or stopped by this script.

Environment:
  - Optional root .env: .env
  - Optional AuthService .env: AlgoCrack-AuthService/.env
  - Optional Google OAuth secrets: AlgoCrack-AuthService/.local.secrets.properties
  - Set DEV_LOCAL_SEED_PROBLEM_DATA=false to skip automatic Problem DB seeding.
  - Set DEV_LOCAL_OBSERVABILITY=false to skip local observability startup.
  - Playground is enabled by default (local-process CXE; not hostile-code safe).
    Set DEV_LOCAL_PLAYGROUND=false to disable API/run/UI for local processes.
  - Complexity analysis is enabled by default as static analysis only.
    Set DEV_LOCAL_COMPLEXITY=false to disable its API and worker locally.
EOF
}

wait_for_mysql() {
  local deadline=$((SECONDS + DEV_LOCAL_INFRA_WAIT_SECONDS))

  echo "Waiting for MySQL..."
  until mysqladmin ping \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    --silent >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      cat >&2 <<EOF
MySQL did not become reachable at $MYSQL_HOST:$MYSQL_PORT within ${DEV_LOCAL_INFRA_WAIT_SECONDS}s.
Start local MySQL, or start the project infra with:
  docker compose up -d mysql redis
EOF
      return 1
    fi
    sleep 2
  done

  if ! mysql_cli -N -B -e "SELECT 1" >/dev/null 2>&1; then
    cat >&2 <<EOF
MySQL is reachable at $MYSQL_HOST:$MYSQL_PORT, but authentication failed for user '$SPRING_DATASOURCE_USERNAME'.

Configure the credentials used by your local MySQL installation:
  cp .env.example .env
  # edit SPRING_DATASOURCE_USERNAME and SPRING_DATASOURCE_PASSWORD in .env

If you intended to use the project-managed MySQL instead of the host MySQL
currently listening on port $MYSQL_PORT, stop or move the host instance first,
then start the project infra with:
  docker compose up -d mysql redis

The script will not start application services with invalid database credentials.
EOF
    return 1
  fi
}

mysql_cli() {
  MYSQL_PWD="$SPRING_DATASOURCE_PASSWORD" mysql \
    -h "$MYSQL_HOST" \
    -P "$MYSQL_PORT" \
    -u "$SPRING_DATASOURCE_USERNAME" \
    "$@"
}

wait_for_redis() {
  echo "Waiting for Redis..."
  until redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; do
    sleep 1
  done
}

check_prerequisites() {
  local missing=0

  for command_name in mysql mysqladmin redis-cli npm ss; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "Missing required command: $command_name" >&2
      missing=1
    fi
  done

  if ! detect_java21; then
    cat >&2 <<'EOF'
Missing Java 21.
Install a JDK 21 distribution or set JAVA_HOME to a JDK 21 directory before running local services.
EOF
    missing=1
  fi

  [[ "$missing" -eq 0 ]]
}

is_managed_process_running() {
  local name="$1"
  local pid_file="$PID_DIR/$name.pid"

  [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1
}

is_port_listening() {
  local port="$1"

  ss -ltnH "sport = :$port" | grep -q .
}

select_api_gateway_port() {
  local candidate

  is_managed_process_running api-gateway && return 0

  if ! is_port_listening "$API_GATEWAY_PORT"; then
    return 0
  fi

  if [[ -n "$API_GATEWAY_PORT_FROM_ENV" ]]; then
    cat >&2 <<EOF
API Gateway port $API_GATEWAY_PORT is already in use.
Stop the process using that port or set API_GATEWAY_PORT to a free port.
EOF
    return 1
  fi

  for candidate in 9092 9093 19090; do
    if ! is_port_listening "$candidate"; then
      echo "API Gateway port $API_GATEWAY_PORT is busy (often Ubuntu Prometheus); using fallback port $candidate."
      echo "Frontend will call http://localhost:$candidate so it does not hit Prometheus 404s."
      API_GATEWAY_PORT="$candidate"

      if [[ -z "$NEXT_PUBLIC_API_BASE_URL_FROM_ENV" ]]; then
        NEXT_PUBLIC_API_BASE_URL="http://localhost:$API_GATEWAY_PORT"
      elif [[ "${NEXT_PUBLIC_API_BASE_URL}" == "http://localhost:9090" ]]; then
        NEXT_PUBLIC_API_BASE_URL="http://localhost:$API_GATEWAY_PORT"
        echo "Updated NEXT_PUBLIC_API_BASE_URL to match API Gateway fallback port."
      fi

      if [[ -z "$GOOGLE_REDIRECT_URI_FROM_ENV" ]]; then
        GOOGLE_REDIRECT_URI="http://localhost:$API_GATEWAY_PORT/api/v1/auth/login/oauth2/code/google"
      elif [[ "${GOOGLE_REDIRECT_URI}" == "http://localhost:9090/api/v1/auth/login/oauth2/code/google" ]]; then
        GOOGLE_REDIRECT_URI="http://localhost:$API_GATEWAY_PORT/api/v1/auth/login/oauth2/code/google"
      fi

      export API_GATEWAY_PORT NEXT_PUBLIC_API_BASE_URL GOOGLE_REDIRECT_URI
      return 0
    fi
  done

  echo "API Gateway port $API_GATEWAY_PORT is busy and no fallback port is free." >&2
  return 1
}

ensure_mysql_databases() {
  mysql_cli \
    -e "CREATE DATABASE IF NOT EXISTS auth_db; CREATE DATABASE IF NOT EXISTS problem_db; CREATE DATABASE IF NOT EXISTS submission_db;"
}

seed_problem_data_if_empty() {
  local dump_file="$ROOT/k8s/all_databases_dump.sql"
  local question_count

  [[ "${DEV_LOCAL_SEED_PROBLEM_DATA:-true}" == "false" ]] && return 0
  [[ -f "$dump_file" ]] || return 0

  question_count="$(
    mysql_cli -N -B \
      -e "SELECT COUNT(*) FROM problem_db.question;" 2>/dev/null || true
  )"

  if [[ "$question_count" =~ ^[0-9]+$ && "$question_count" -gt 0 ]]; then
    echo "Problem DB already has $question_count questions; skipping seed."
    return 0
  fi

  echo "Seeding problem_db from $dump_file..."
  {
    echo "SET FOREIGN_KEY_CHECKS=0;"
    awk '
      /^-- Current Database: `problem_db`/ { include = 1 }
      /^-- Current Database: `submission_db`/ { include = 0 }
      include { print }
    ' "$dump_file"
    echo "SET FOREIGN_KEY_CHECKS=1;"
  } | mysql_cli
}

google_oauth_status() {
  if is_google_oauth_placeholder "$GOOGLE_CLIENT_ID" || is_google_oauth_placeholder "$GOOGLE_CLIENT_SECRET"; then
    echo "Google OAuth: placeholder credentials (sign-in will fail until configured)"
  else
    echo "Google OAuth: custom credentials loaded"
  fi
}

generate_observability_config() {
  local grafana_provisioning="$OBS_DIR/grafana/provisioning"
  local grafana_dashboards="$OBS_DIR/grafana/dashboards"

  mkdir -p \
    "$OBS_DIR/prometheus-data" \
    "$OBS_DIR/loki-data/chunks" \
    "$OBS_DIR/loki-data/rules" \
    "$OBS_DIR/alloy-data" \
    "$grafana_provisioning/datasources" \
    "$grafana_provisioning/dashboards" \
    "$grafana_dashboards" \
    "$OBS_DIR/grafana-data" \
    "$OBS_DIR/grafana-logs" \
    "$OBS_DIR/grafana-plugins"

  rm -f "$grafana_provisioning/datasources"/*.yml
  rm -f "$grafana_provisioning/dashboards"/*.yml

  cat > "$OBS_DIR/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - $ROOT/docker/prometheus/alert-rules.yml

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - localhost:$PROMETHEUS_PORT

  - job_name: algocrack-backends
    metrics_path: /actuator/prometheus
    static_configs:
      - targets:
          - localhost:$API_GATEWAY_PORT
          - localhost:7483
          - localhost:8084
          - localhost:8080
          - localhost:8081
EOF

  cat > "$OBS_DIR/loki.yml" <<EOF
auth_enabled: false

server:
  http_listen_port: $LOKI_PORT

common:
  path_prefix: $OBS_DIR/loki-data
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

storage_config:
  filesystem:
    chunks_directory: $OBS_DIR/loki-data/chunks
    rules_directory: $OBS_DIR/loki-data/rules

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  allow_structured_metadata: true

ruler:
  storage:
    type: local
    local:
      directory: $OBS_DIR/loki-data/rules
EOF

  cat > "$OBS_DIR/alloy.alloy" <<EOF
local.file_match "dev_logs" {
  path_targets = [{
    __path__ = "$LOG_DIR/*.log",
    job      = "algocrack-local",
  }]
}

discovery.relabel "dev_logs" {
  targets = local.file_match.dev_logs.targets

  rule {
    source_labels = ["__path__"]
    regex         = ".*/([^/]+)\\.log"
    target_label  = "service"
  }
}

loki.source.file "dev_logs" {
  targets    = discovery.relabel.dev_logs.output
  forward_to = [loki.process.algocrack.receiver]
}

loki.process "algocrack" {
  stage.json {
    expressions = {
      level       = "level",
      app_service = "service",
      environment = "environment",
      kube_micro  = "kube_micro",
      event_type  = "event_type",
    }
  }

  stage.labels {
    values = {
      level       = "",
      app_service = "",
      environment = "",
      kube_micro  = "",
      event_type  = "",
    }
  }

  forward_to = [loki.write.local.receiver]
}

loki.write "local" {
  endpoint {
    url = "http://localhost:$LOKI_PORT/loki/api/v1/push"
  }
}
EOF

  cat > "$grafana_provisioning/datasources/datasources.yml" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    uid: Prometheus
    type: prometheus
    access: proxy
    url: http://localhost:$PROMETHEUS_PORT
    isDefault: true
    editable: true
  - name: Loki
    uid: Loki
    type: loki
    access: proxy
    url: http://localhost:$LOKI_PORT
    editable: true
EOF

  cat > "$grafana_provisioning/dashboards/dashboards.yml" <<EOF
apiVersion: 1

providers:
  - name: AlgoCrack
    orgId: 1
    folder: AlgoCrack
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: true
    options:
      path: $grafana_dashboards
EOF

  cp "$ROOT/docker/grafana/dashboards/algocrack-overview.json" \
    "$grafana_dashboards/algocrack-overview.json"
}

start_observability() {
  local grafana_home
  local loki_started=false
  local alloy_started=false

  [[ "$DEV_LOCAL_OBSERVABILITY" == "false" ]] && return 0

  generate_observability_config

  echo "Generated Grafana datasources:"
  echo "  Prometheus -> http://localhost:$PROMETHEUS_PORT"
  echo "  Loki       -> http://localhost:$LOKI_PORT"

  if command -v loki >/dev/null 2>&1; then
    start_bg loki "$ROOT" loki \
      -config.file="$OBS_DIR/loki.yml"
    loki_started=true
  else
    echo "Loki not found; Grafana's Loki datasource will fail until Loki is running on localhost:$LOKI_PORT."
    echo "Install loki locally, or run the Docker observability stack."
  fi

  if command -v alloy >/dev/null 2>&1; then
    start_bg alloy "$ROOT" alloy run "$OBS_DIR/alloy.alloy" \
      --storage.path="$OBS_DIR/alloy-data"
    alloy_started=true
  else
    echo "Grafana Alloy not found; .dev-logs will not be shipped into Loki until Alloy is installed."
  fi

  if command -v prometheus >/dev/null 2>&1; then
    start_bg prometheus "$ROOT" prometheus \
      --config.file="$OBS_DIR/prometheus.yml" \
      --web.listen-address=":$PROMETHEUS_PORT" \
      --storage.tsdb.path="$OBS_DIR/prometheus-data"
  else
    echo "Prometheus not found; install prometheus or set DEV_LOCAL_OBSERVABILITY=false to hide this warning."
  fi

  grafana_home="${GRAFANA_HOME:-/usr/share/grafana}"
  if command -v grafana-server >/dev/null 2>&1; then
    start_bg grafana "$ROOT" env \
      GF_PATHS_PROVISIONING="$OBS_DIR/grafana/provisioning" \
      GF_PATHS_DATA="$OBS_DIR/grafana-data" \
      GF_PATHS_LOGS="$OBS_DIR/grafana-logs" \
      GF_PATHS_PLUGINS="$OBS_DIR/grafana-plugins" \
      GF_SERVER_HTTP_PORT="$GRAFANA_PORT" \
      GF_SECURITY_ADMIN_USER="$GRAFANA_ADMIN_USER" \
      GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD" \
      GF_USERS_ALLOW_SIGN_UP=false \
      GF_ANALYTICS_CHECK_FOR_UPDATES=false \
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
      GF_PLUGINS_PREINSTALL_DISABLED=true \
      GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false \
      GF_PLUGINS_PLUGIN_ADMIN_ENABLED=false \
      grafana-server --homepath "$grafana_home"
  elif command -v grafana >/dev/null 2>&1; then
    start_bg grafana "$ROOT" env \
      GF_PATHS_PROVISIONING="$OBS_DIR/grafana/provisioning" \
      GF_PATHS_DATA="$OBS_DIR/grafana-data" \
      GF_PATHS_LOGS="$OBS_DIR/grafana-logs" \
      GF_PATHS_PLUGINS="$OBS_DIR/grafana-plugins" \
      GF_SERVER_HTTP_PORT="$GRAFANA_PORT" \
      GF_SECURITY_ADMIN_USER="$GRAFANA_ADMIN_USER" \
      GF_SECURITY_ADMIN_PASSWORD="$GRAFANA_ADMIN_PASSWORD" \
      GF_USERS_ALLOW_SIGN_UP=false \
      GF_ANALYTICS_CHECK_FOR_UPDATES=false \
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false \
      GF_PLUGINS_PREINSTALL_DISABLED=true \
      GF_PLUGINS_PREINSTALL_AUTO_UPDATE=false \
      GF_PLUGINS_PLUGIN_ADMIN_ENABLED=false \
      grafana server --homepath "$grafana_home"
  else
    echo "Grafana not found; install grafana or set DEV_LOCAL_OBSERVABILITY=false to hide this warning."
  fi

  if [[ "$loki_started" != "true" || "$alloy_started" != "true" ]]; then
    cat <<EOF

Local log search is not fully active.
Required for Grafana Explore logs:
  Loki:     $([[ "$loki_started" == "true" ]] && echo "started" || echo "missing")
  Alloy:    $([[ "$alloy_started" == "true" ]] && echo "started" || echo "missing")

Without Loki, selecting labels in Grafana returns a plugin 500 because
http://localhost:$LOKI_PORT is not listening.
EOF
  fi

  echo "If Grafana was already open, refresh the browser after it restarts so the data source picker reloads."
}

start_bg() {
  local name="$1"
  local cwd="$2"
  shift 2

  local pid_file="$PID_DIR/$name.pid"
  local log_file="$LOG_DIR/$name.log"

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
    echo "$name already running"
    return 0
  fi

  rm -f "$pid_file"

  (
    cd "$cwd"
    setsid nohup "$@" </dev/null >"$log_file" 2>&1 &
    echo $! >"$pid_file"
  )

  echo "Started $name -> $log_file"
}

stop_unmanaged_frontend() {
  if is_managed_process_running frontend; then
    return 0
  fi

  if is_port_listening 3000; then
    echo "Stopping the existing Next.js process on port 3000 so frontend can start with the current API Gateway URL."
    fuser -k 3000/tcp >/dev/null 2>&1 || true
    sleep 1
  fi
}

playground_local_env_stamp() {
  printf 'dev_local_playground=%s api=%s run=%s cxe=%s next=%s backend=%s complexity=%s complexity_api=%s complexity_static=%s complexity_dynamic=%s' \
    "$DEV_LOCAL_PLAYGROUND" \
    "$PLAYGROUND_API_ENABLED" \
    "$PLAYGROUND_RUN_ENABLED" \
    "$EXECUTION_PLAYGROUND_ENABLED" \
    "$NEXT_PUBLIC_PLAYGROUND_ENABLED" \
    "$EXECUTION_PLAYGROUND_SANDBOX_BACKEND" \
    "$DEV_LOCAL_COMPLEXITY" \
    "$COMPLEXITY_API_ENABLED" \
    "$COMPLEXITY_STATIC_ANALYSIS_ENABLED" \
    "$COMPLEXITY_DYNAMIC_PROFILING_ENABLED"
}

write_playground_local_env_stamp() {
  playground_local_env_stamp >"$PID_DIR/playground-local-env.stamp"
}

# Playground flags are read at process start (Spring @ConditionalOnProperty, Next.js env).
restart_playground_dependent_services_if_needed() {
  local stamp_file="$PID_DIR/playground-local-env.stamp"
  local current
  current="$(playground_local_env_stamp)"

  if [[ -f "$stamp_file" ]] && [[ "$(cat "$stamp_file")" == "$current" ]]; then
    return 0
  fi

  local name
  for name in submission-service code-execution-engine frontend; do
    if is_managed_process_running "$name"; then
      if [[ "$DEV_LOCAL_PLAYGROUND" == "true" ]]; then
        echo "Restarting $name for playground local config (local-process; not production sandbox)..."
      else
        echo "Restarting $name (playground disabled: DEV_LOCAL_PLAYGROUND=false)..."
      fi
      stop_bg "$name"
    fi
  done
}

stop_bg() {
  local name="$1"
  local pid_file="$PID_DIR/$name.pid"

  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file"
  fi
}

up() {
  check_prerequisites
  select_api_gateway_port

  echo "Checking local infra..."
  wait_for_mysql
  ensure_mysql_databases
  wait_for_redis
  seed_problem_data_if_empty
  restart_playground_dependent_services_if_needed

  # A reused Gradle daemon retains its original environment. Use a fresh process so
  # each bootRun receives the current local service and feature-flag configuration.
  start_bg auth-service "$ROOT/AlgoCrack-AuthService" env \
    SERVER_PORT=7483 \
    SPRING_DATASOURCE_URL=jdbc:mysql://"$MYSQL_HOST":"$MYSQL_PORT"/auth_db \
    SPRING_DATASOURCE_USERNAME="$SPRING_DATASOURCE_USERNAME" \
    SPRING_DATASOURCE_PASSWORD="$SPRING_DATASOURCE_PASSWORD" \
    SPRING_DATASOURCE_HIKARI_INITIALIZATION_FAIL_TIMEOUT=0 \
    SPRING_FLYWAY_CONNECT_RETRIES=10 \
    JWT_EXPIRY="$JWT_EXPIRY" \
    COOKIE_EXPIRY="$COOKIE_EXPIRY" \
    GOOGLE_CLIENT_ID="$GOOGLE_CLIENT_ID" \
    GOOGLE_CLIENT_SECRET="$GOOGLE_CLIENT_SECRET" \
    GOOGLE_REDIRECT_URI="$GOOGLE_REDIRECT_URI" \
    ./gradlew --no-daemon bootRun

  start_bg problem-service "$ROOT/AlgoCrack-ProblemService" env \
    SERVER_PORT=8084 \
    SPRING_DATASOURCE_URL=jdbc:mysql://"$MYSQL_HOST":"$MYSQL_PORT"/problem_db \
    SPRING_DATASOURCE_USERNAME="$SPRING_DATASOURCE_USERNAME" \
    SPRING_DATASOURCE_PASSWORD="$SPRING_DATASOURCE_PASSWORD" \
    SPRING_DATASOURCE_HIKARI_INITIALIZATION_FAIL_TIMEOUT=0 \
    SPRING_FLYWAY_CONNECT_RETRIES=10 \
    AUTH_SERVICE_BASE_URL=http://localhost:7483 \
    SUBMISSION_SERVICE_URL=http://localhost:8080 \
    ./gradlew --no-daemon bootRun

  start_bg code-execution-engine "$ROOT/CodeExecutionEngine" env \
    SERVER_PORT=8081 \
    SPRING_DATA_REDIS_HOST="$REDIS_HOST" \
    SPRING_DATA_REDIS_PORT="$REDIS_PORT" \
    SPRING_DATA_REDIS_TIMEOUT=5000ms \
    PROBLEM_SERVICE_URL=http://localhost:8084 \
    EXECUTION_BACKEND=local-process \
    EXECUTION_MODE=worker \
    WORKER_COUNT="$WORKER_COUNT" \
    EXECUTION_WORKER_QUEUE_CAPACITY="$EXECUTION_WORKER_QUEUE_CAPACITY" \
    EXECUTION_TIMEOUT_SECONDS="$EXECUTION_TIMEOUT_SECONDS" \
    EXECUTION_POLL_TIMEOUT_SECONDS="$EXECUTION_POLL_TIMEOUT_SECONDS" \
    EXECUTION_MEMORY_SOFT_LIMIT_MB="$EXECUTION_MEMORY_SOFT_LIMIT_MB" \
    EXECUTION_COMPILATION_TIMEOUT_SECONDS="$EXECUTION_COMPILATION_TIMEOUT_SECONDS" \
    EXECUTION_PLAYGROUND_ENABLED="$EXECUTION_PLAYGROUND_ENABLED" \
    EXECUTION_PLAYGROUND_SANDBOX_BACKEND="$EXECUTION_PLAYGROUND_SANDBOX_BACKEND" \
    ./gradlew --no-daemon bootRun

  start_bg submission-service "$ROOT/AlgoCrack-SubmissionService" env \
    SERVER_PORT=8080 \
    SPRING_DATASOURCE_URL=jdbc:mysql://"$MYSQL_HOST":"$MYSQL_PORT"/submission_db \
    SPRING_DATASOURCE_USERNAME="$SPRING_DATASOURCE_USERNAME" \
    SPRING_DATASOURCE_PASSWORD="$SPRING_DATASOURCE_PASSWORD" \
    SPRING_DATASOURCE_HIKARI_INITIALIZATION_FAIL_TIMEOUT=0 \
    SPRING_FLYWAY_CONNECT_RETRIES=10 \
    PROBLEM_SERVICE_URL=http://localhost:8084 \
    CXE_SERVICE_URL=http://localhost:8081 \
    PLAYGROUND_API_ENABLED="$PLAYGROUND_API_ENABLED" \
    PLAYGROUND_RUN_ENABLED="$PLAYGROUND_RUN_ENABLED" \
    COMPLEXITY_API_ENABLED="$COMPLEXITY_API_ENABLED" \
    COMPLEXITY_STATIC_ANALYSIS_ENABLED="$COMPLEXITY_STATIC_ANALYSIS_ENABLED" \
    COMPLEXITY_DYNAMIC_PROFILING_ENABLED="$COMPLEXITY_DYNAMIC_PROFILING_ENABLED" \
    ./gradlew --no-daemon bootRun

  start_bg api-gateway "$ROOT/AlgoCrack-APIGateway" env \
    SERVER_PORT="$API_GATEWAY_PORT" \
    AUTH_SERVICE_BASE_URL=http://localhost:7483 \
    PROBLEM_SERVICE_URL=http://localhost:8084 \
    SUBMISSION_SERVICE_URL=http://localhost:8080 \
    JWT_PUBLIC_KEY_PATH=classpath:keys/public.pem \
    ./gradlew --no-daemon bootRun

  stop_unmanaged_frontend

  start_bg frontend "$ROOT/frontend" env \
    NEXT_PUBLIC_API_BASE_URL="$NEXT_PUBLIC_API_BASE_URL" \
    NEXT_PUBLIC_PLAYGROUND_ENABLED="$NEXT_PUBLIC_PLAYGROUND_ENABLED" \
    PORT=3000 \
    npm run dev

  start_observability
  write_playground_local_env_stamp

  cat <<EOF

Local dev is up.
$( [[ "$DEV_LOCAL_PLAYGROUND" == "true" ]] && printf '\nPlayground: ON (local-process; trusted dev only — not hostile-code safe).\n  http://localhost:3000/playground after sign-in.\n  Opt out: DEV_LOCAL_PLAYGROUND=false ./scripts/dev-local.sh up\n' )
$( [[ "$DEV_LOCAL_PLAYGROUND" != "true" ]] && printf '\nPlayground: OFF (DEV_LOCAL_PLAYGROUND=false).\n' )
$( [[ "$DEV_LOCAL_COMPLEXITY" == "true" ]] && printf '\nComplexity analysis: ON (static analysis only; dynamic profiling is disabled locally).\n' )
$( [[ "$DEV_LOCAL_COMPLEXITY" != "true" ]] && printf '\nComplexity analysis: OFF (DEV_LOCAL_COMPLEXITY=false).\n' )

Open:
  Frontend:      http://localhost:3000
  API Gateway:   http://localhost:$API_GATEWAY_PORT
  Auth Service:  http://localhost:7483
  Problem API:   http://localhost:8084/api/v1/questions
  Prometheus:    http://localhost:$PROMETHEUS_PORT
  Loki:          http://localhost:$LOKI_PORT
  Grafana:       http://localhost:$GRAFANA_PORT

Logs:
  scripts/dev-local.sh logs
  scripts/dev-local.sh logs problem-service
  scripts/dev-local.sh logs prometheus
  scripts/dev-local.sh logs loki
  scripts/dev-local.sh logs alloy
  scripts/dev-local.sh logs grafana

$(google_oauth_status)

Stop:
  scripts/dev-local.sh down
EOF
}

down() {
  stop_bg grafana
  stop_bg prometheus
  stop_bg alloy
  stop_bg loki
  stop_bg frontend
  stop_bg api-gateway
  stop_bg submission-service
  stop_bg code-execution-engine
  stop_bg problem-service
  stop_bg auth-service

  echo "Stopped local app processes. MySQL and Redis were left running."
}

status() {
  google_oauth_status

  for name in auth-service problem-service code-execution-engine submission-service api-gateway frontend prometheus loki alloy grafana; do
    local pid_file="$PID_DIR/$name.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
      echo "$name: running (pid $(cat "$pid_file"))"
    else
      echo "$name: stopped"
    fi
  done
}

logs() {
  local service="${1:-}"

  if [[ -n "$service" ]]; then
    tail -f "$LOG_DIR/$service.log"
  else
    tail -f "$LOG_DIR"/*.log
  fi
}

command="${1:-up}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$command" in
  up) up ;;
  down) down ;;
  restart) down && up ;;
  status) status ;;
  logs) logs "$@" ;;
  observability) start_observability ;;
  seed)
    wait_for_mysql
    ensure_mysql_databases
    seed_problem_data_if_empty
    ;;
  bootstrap-potd)
    wait_for_mysql
    ensure_mysql_databases
    bash "$ROOT/scripts/bootstrap-potd-local.sh"
    ;;
  *) usage ;;
esac
