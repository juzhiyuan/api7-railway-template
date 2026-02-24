#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Bootstrap an API7 control-plane Railway project from one GitHub repo URL.

Usage:
  scripts/bootstrap-railway-project.sh --project <name> --repo-url <url> [--workspace <workspace>]

Examples:
  scripts/bootstrap-railway-project.sh \
    --project api7-control-plane \
    --repo-url https://github.com/your-org/api7-railway

  scripts/bootstrap-railway-project.sh \
    --project api7-control-plane \
    --repo-url https://github.com/your-org/api7-railway \
    --workspace <workspace-id-or-name>

Requirements:
  - railway CLI installed and authenticated (railway login)
  - canonical app service names are enforced:
    dashboard, dp-manager, prometheus, jaeger
  - Postgres service defaults to Postgres; script auto-detects if renamed
EOF
}

PROJECT_NAME=""
REPO_URL=""
REPO_SLUG=""
WORKSPACE=""
PROMETHEUS_VOLUME_MOUNT_PATH="/opt/bitnami/prometheus/data"
POSTGRES_SERVICE_NAME="Postgres"
DP_MANAGER_TLS_APP_PORT="7943"
RAILWAY_GRAPHQL_ENDPOINT="https://backboard.railway.app/graphql/v2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_NAME="${2:-}"
      shift 2
      ;;
    --repo-url)
      REPO_URL="${2:-}"
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$PROJECT_NAME" || -z "$REPO_URL" ]]; then
  echo "Both --project and --repo-url are required." >&2
  usage
  exit 1
fi

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

validate_repo_url() {
  if [[ "$REPO_URL" =~ ^https?://github\.com/([^/]+)/([^/]+)(\.git)?/?$ ]]; then
    local org="${BASH_REMATCH[1]}"
    local repo="${BASH_REMATCH[2]}"
    repo="${repo%.git}"
    REPO_SLUG="${org}/${repo}"
    return 0
  fi

  if [[ "$REPO_URL" =~ ^[^/]+/[^/]+$ ]]; then
    REPO_SLUG="$REPO_URL"
    warn "--repo-url received repository slug '$REPO_SLUG'. Prefer https://github.com/<org>/<repo>."
    return 0
  fi

  fail "--repo-url must be a GitHub repository URL (https://github.com/<org>/<repo>) or <org>/<repo>."
}

if ! command -v railway >/dev/null 2>&1; then
  fail "railway CLI is required. Install it first."
fi

if ! command -v jq >/dev/null 2>&1; then
  fail "jq is required. Install it first."
fi

if ! command -v curl >/dev/null 2>&1; then
  fail "curl is required. Install it first."
fi

validate_repo_url

if ! railway whoami >/dev/null 2>&1; then
  fail "Not authenticated. Run: railway login"
fi

ensure_project() {
  local current_project_name=""
  if current_project_name="$(railway status --json 2>/dev/null | jq -r '.name // empty' 2>/dev/null)" \
    && [[ -n "$current_project_name" ]] \
    && [[ "$current_project_name" == "$PROJECT_NAME" ]]; then
    log "Using currently linked Railway project: $PROJECT_NAME"
    return 0
  fi

  local link_args=("--project" "$PROJECT_NAME")
  if [[ -n "$WORKSPACE" ]]; then
    link_args+=("--workspace" "$WORKSPACE")
  fi

  local output

  if output="$(railway link "${link_args[@]}" 2>&1)"; then
    log "Linked existing Railway project: $PROJECT_NAME"
    return 0
  fi

  local init_args=("--name" "$PROJECT_NAME")
  if [[ -n "$WORKSPACE" ]]; then
    init_args+=("--workspace" "$WORKSPACE")
  fi

  if output="$(railway init "${init_args[@]}" 2>&1)"; then
    log "Created and linked Railway project: $PROJECT_NAME"
    return 0
  fi

  fail "Could not link or create Railway project '$PROJECT_NAME'. Last error: $output"
}

service_exists() {
  local service_name="$1"
  railway variables --service "$service_name" --json >/dev/null 2>&1
}

ensure_postgres() {
  if service_exists "Postgres"; then
    POSTGRES_SERVICE_NAME="Postgres"
    log "Reusing existing Postgres service."
    return 0
  fi

  if railway add --database postgres --service Postgres >/dev/null 2>&1; then
    log "Created Postgres service."
  else
    warn "Could not create named Postgres service directly, retrying with default database add."
    railway add --database postgres >/dev/null
  fi

  local attempts=0
  while [[ $attempts -lt 10 ]]; do
    if service_exists "Postgres"; then
      POSTGRES_SERVICE_NAME="Postgres"
      log "Detected Postgres service after create."
      return 0
    fi
    sleep 1
    attempts=$((attempts + 1))
  done

  local postgres_candidates
  postgres_candidates="$(
    railway status --json \
      | jq -r '.services.edges[].node
          | .name as $name
          | (.serviceInstances.edges[0].node.source.image // "") as $image
          | select(($name | test("postgres"; "i")) or ($image | test("postgres"; "i")))
          | $name' \
      | sort -u
  )"

  local candidate_count
  candidate_count="$(printf '%s\n' "$postgres_candidates" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [[ "$candidate_count" -eq 1 ]]; then
    POSTGRES_SERVICE_NAME="$(printf '%s\n' "$postgres_candidates" | sed '/^$/d')"
    warn "Using detected PostgreSQL service name '$POSTGRES_SERVICE_NAME' (default is 'Postgres')."
    return 0
  fi

  if [[ "$candidate_count" -gt 1 ]]; then
    fail "Multiple PostgreSQL-like services detected (${postgres_candidates//$'\n'/, }). Keep one database service or rename to 'Postgres', then rerun."
  fi

  fail "Could not detect PostgreSQL service after creation. Check Railway services and rerun."
}

ensure_service_from_repo() {
  local service_name="$1"
  local dockerfile_path="$2"
  local output

  if service_exists "$service_name"; then
    log "Reusing existing service: $service_name"
  else
    if output="$(railway add \
      --service "$service_name" \
      --repo "$REPO_SLUG" \
      --variables "RAILWAY_DOCKERFILE_PATH=$dockerfile_path" 2>&1)"; then
      log "Created service: $service_name"
    else
      if printf '%s' "$output" | grep -qi 'repo not found'; then
        fail "Railway cannot access GitHub repo '$REPO_SLUG'. Connect GitHub to Railway and grant repository access, then rerun."
      fi
      fail "Failed to create service '$service_name' from repo '$REPO_SLUG': $output"
    fi
  fi

  railway variables --service "$service_name" --skip-deploys \
    --set "RAILWAY_DOCKERFILE_PATH=$dockerfile_path" >/dev/null
}

ensure_variables() {
  local service_name="$1"
  shift

  local args=("--service" "$service_name" "--skip-deploys")
  local kv
  for kv in "$@"; do
    args+=("--set" "$kv")
  done
  railway variables "${args[@]}" >/dev/null
  log "Applied variables for service: $service_name"
}

service_id_by_name() {
  local service_name="$1"
  railway status --json \
    | jq -r --arg service_name "$service_name" \
      '.services.edges[] | select(.node.name == $service_name) | .node.id' \
    | head -n 1
}

environment_id() {
  railway status --json | jq -r '.environments.edges[0].node.id'
}

service_deploy_status() {
  local service_name="$1"
  railway status --json \
    | jq -r --arg service_name "$service_name" \
      '.services.edges[]
       | select(.node.name == $service_name)
       | .node.serviceInstances.edges[0].node.latestDeployment.status // empty' \
    | head -n 1
}

service_deploy_status_is_terminal() {
  local status="$1"
  case "$status" in
    SUCCESS|CRASHED|FAILED|CANCELED|REMOVED)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

wait_for_service_success() {
  local service_name="$1"
  local timeout_seconds="${2:-900}"
  local poll_interval_seconds=5
  local start_ts now_ts elapsed status

  start_ts="$(date +%s)"

  while true; do
    status="$(service_deploy_status "$service_name")"

    if [[ -z "$status" ]]; then
      fail "Could not determine deployment status for service '$service_name'."
    fi

    case "$status" in
      SUCCESS)
        log "Service '$service_name' deployment is SUCCESS."
        return 0
        ;;
      CRASHED|FAILED|CANCELED|REMOVED)
        fail "Service '$service_name' deployment ended with status '$status'. Check: railway logs --service $service_name"
        ;;
      *)
        ;;
    esac

    now_ts="$(date +%s)"
    elapsed="$((now_ts - start_ts))"
    if (( elapsed >= timeout_seconds )); then
      fail "Timed out waiting for service '$service_name' to reach SUCCESS (last status: $status)."
    fi

    sleep "$poll_interval_seconds"
  done
}

wait_for_service_terminal_status() {
  local service_name="$1"
  local timeout_seconds="${2:-900}"
  local poll_interval_seconds=5
  local start_ts now_ts elapsed status

  start_ts="$(date +%s)"

  while true; do
    status="$(service_deploy_status "$service_name")"
    if [[ -z "$status" ]]; then
      fail "Could not determine deployment status for service '$service_name'."
    fi

    if service_deploy_status_is_terminal "$status"; then
      printf '%s' "$status"
      return 0
    fi

    now_ts="$(date +%s)"
    elapsed="$((now_ts - start_ts))"
    if (( elapsed >= timeout_seconds )); then
      fail "Timed out waiting for service '$service_name' terminal status (last status: $status)."
    fi

    sleep "$poll_interval_seconds"
  done
}

redeploy_and_wait() {
  local service_name="$1"
  railway redeploy --service "$service_name" --yes >/dev/null
  log "Triggered redeploy for service '$service_name'."
  wait_for_service_success "$service_name"
}

railway_api_token() {
  jq -r '.user.token // empty' "$HOME/.railway/config.json" 2>/dev/null
}

railway_graphql() {
  local query="$1"
  local variables_json="$2"
  local token payload

  token="$(railway_api_token)"
  [[ -n "$token" ]] || fail "Could not read Railway API token from ~/.railway/config.json. Run: railway login"

  payload="$(jq -n --arg query "$query" --argjson variables "$variables_json" '{query: $query, variables: $variables}')"

  curl -sS "$RAILWAY_GRAPHQL_ENDPOINT" \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    --data "$payload"
}

ensure_tcp_proxy() {
  local service_name="$1"
  local app_port="$2"
  local service_id env_id
  local query mutation query_vars mutation_vars response
  local proxy_id proxy_domain proxy_port proxy_status
  local attempts=0

  service_id="$(service_id_by_name "$service_name")"
  [[ -n "$service_id" ]] || fail "Could not find service ID for '$service_name'."

  env_id="$(environment_id)"
  [[ -n "$env_id" ]] || fail "Could not determine Railway environment ID."

  query='query($sid:String!,$eid:String!){ tcpProxies(serviceId:$sid, environmentId:$eid){ id domain proxyPort applicationPort syncStatus } }'
  query_vars="$(jq -n --arg sid "$service_id" --arg eid "$env_id" '{sid: $sid, eid: $eid}')"

  response="$(railway_graphql "$query" "$query_vars")"
  if [[ "$(printf '%s' "$response" | jq '.errors | length // 0')" != "0" ]]; then
    fail "Failed to query Railway TCP proxy state for '$service_name'. Response: $response"
  fi

  proxy_id="$(
    printf '%s' "$response" \
      | jq -r --argjson app_port "$app_port" '.data.tcpProxies[]? | select(.applicationPort == $app_port) | .id' \
      | head -n 1
  )"

  if [[ -z "$proxy_id" ]]; then
    mutation='mutation($input:TCPProxyCreateInput!){ tcpProxyCreate(input:$input){ id domain proxyPort applicationPort syncStatus } }'
    mutation_vars="$(
      jq -n \
        --arg service_id "$service_id" \
        --arg env_id "$env_id" \
        --argjson app_port "$app_port" \
        '{input: {serviceId: $service_id, environmentId: $env_id, applicationPort: $app_port}}'
    )"
    response="$(railway_graphql "$mutation" "$mutation_vars")"

    if [[ "$(printf '%s' "$response" | jq '.errors | length // 0')" != "0" ]]; then
      if printf '%s' "$response" | grep -Eqi 'already|exists'; then
        warn "TCP proxy likely already exists for '$service_name' on app port $app_port. Reusing existing proxy."
      else
        fail "Failed to create Railway TCP proxy for '$service_name' on app port $app_port. Response: $response"
      fi
    else
      log "Requested Railway TCP proxy for '$service_name' on app port $app_port."
    fi
  else
    log "Found existing Railway TCP proxy for '$service_name' on app port $app_port."
  fi

  while (( attempts < 30 )); do
    attempts=$((attempts + 1))
    response="$(railway_graphql "$query" "$query_vars")"
    proxy_id="$(
      printf '%s' "$response" \
        | jq -r --argjson app_port "$app_port" '.data.tcpProxies[]? | select(.applicationPort == $app_port) | .id' \
        | head -n 1
    )"
    proxy_domain="$(
      printf '%s' "$response" \
        | jq -r --argjson app_port "$app_port" '.data.tcpProxies[]? | select(.applicationPort == $app_port) | .domain' \
        | head -n 1
    )"
    proxy_port="$(
      printf '%s' "$response" \
        | jq -r --argjson app_port "$app_port" '.data.tcpProxies[]? | select(.applicationPort == $app_port) | .proxyPort' \
        | head -n 1
    )"
    proxy_status="$(
      printf '%s' "$response" \
        | jq -r --argjson app_port "$app_port" '.data.tcpProxies[]? | select(.applicationPort == $app_port) | .syncStatus' \
        | head -n 1
    )"

    if [[ -n "$proxy_id" && "$proxy_status" == "ACTIVE" ]]; then
      log "TCP proxy active for '$service_name': ${proxy_domain}:${proxy_port} -> ${app_port}"
      return 0
    fi

    sleep 2
  done

  fail "TCP proxy for '$service_name' on app port $app_port did not reach ACTIVE in time."
}

reconcile_startup_order() {
  local dp_status

  # Mirror API7 quickstart order at service level:
  # dashboard must be healthy first, then dp-manager.
  wait_for_service_success "dashboard"

  dp_status="$(wait_for_service_terminal_status "dp-manager")"
  if [[ "$dp_status" == "SUCCESS" ]]; then
    log "Service 'dp-manager' deployment is already SUCCESS."
    return 0
  fi

  warn "Service 'dp-manager' is '$dp_status'. Triggering one recovery redeploy after dashboard readiness."
  redeploy_and_wait "dp-manager"
}

ensure_public_domain() {
  local service_name="$1"
  local port="$2"
  local existing
  local output

  if existing="$(railway domain --service "$service_name" --json 2>/dev/null)"; then
    if printf '%s' "$existing" | grep -Eq "\"port\"[[:space:]]*:[[:space:]]*$port"; then
      log "Public domain already exists for $service_name on port $port."
      return 0
    fi
  fi

  if output="$(railway domain --service "$service_name" --port "$port" --json 2>&1)"; then
    log "Ensured public domain for $service_name on port $port."
    return 0
  fi

  if printf '%s' "$output" | grep -Eqi 'already|maximum|exists|one railway provided domain'; then
    warn "Domain already exists for $service_name. Reusing existing domain."
    return 0
  fi

  fail "Failed to ensure domain for $service_name: $output"
}

ensure_prometheus_volume() {
  local output

  railway service prometheus >/dev/null

  if output="$(railway volume list 2>&1)"; then
    if printf '%s' "$output" | grep -Fq "$PROMETHEUS_VOLUME_MOUNT_PATH"; then
      log "Prometheus volume already mounted at $PROMETHEUS_VOLUME_MOUNT_PATH."
      return 0
    fi
  fi

  if output="$(railway volume add --mount-path "$PROMETHEUS_VOLUME_MOUNT_PATH" 2>&1)"; then
    log "Attached Prometheus volume at $PROMETHEUS_VOLUME_MOUNT_PATH."
    return 0
  fi

  if printf '%s' "$output" | grep -Eqi 'already|exists|attached|mount path'; then
    warn "Prometheus volume appears to already exist/attach. Treating as success."
    return 0
  fi

  fail "Failed to ensure Prometheus volume: $output"
}

main() {
  # Phase 1: project + service inventory
  ensure_project
  ensure_postgres

  ensure_service_from_repo "dashboard" "Dockerfile.dashboard"
  ensure_service_from_repo "dp-manager" "Dockerfile.dp-manager"
  ensure_service_from_repo "prometheus" "Dockerfile.prometheus"
  ensure_service_from_repo "jaeger" "Dockerfile.jaeger"

  # Phase 2: cross-service wiring
  local database_ref
  printf -v database_ref \
    'DATABASE_DSN=postgres://${{%s.PGUSER}}:${{%s.PGPASSWORD}}@${{%s.PGHOST}}:${{%s.PGPORT}}/${{%s.PGDATABASE}}' \
    "$POSTGRES_SERVICE_NAME" "$POSTGRES_SERVICE_NAME" "$POSTGRES_SERVICE_NAME" "$POSTGRES_SERVICE_NAME" "$POSTGRES_SERVICE_NAME"

  ensure_variables "dashboard" \
    "$database_ref" \
    'PROMETHEUS_ADDR=http://prometheus.railway.internal:9090' \
    'JAEGER_ADDR=http://jaeger.railway.internal:16686' \
    'PORT=7080' \
    'DASHBOARD_TLS_DISABLE=true'

  ensure_variables "dp-manager" \
    "$database_ref" \
    'PROMETHEUS_ADDR=http://prometheus.railway.internal:9090' \
    'JAEGER_COLLECTOR_ADDR=http://jaeger.railway.internal:4318' \
    'PORT=7900'

  # Phase 3: exposure + runtime reconciliation
  ensure_public_domain "dashboard" "7080"
  ensure_tcp_proxy "dp-manager" "$DP_MANAGER_TLS_APP_PORT"

  # Dashboard applies DB migrations needed by dp-manager.
  # Railway does not support docker-compose-style depends_on between services,
  # so we enforce startup readiness explicitly.
  reconcile_startup_order

  ensure_prometheus_volume

  echo
  log "Bootstrap complete."
  log "Project: $PROJECT_NAME"
  log "Services: dashboard, dp-manager, prometheus, jaeger, $POSTGRES_SERVICE_NAME"
}

main "$@"
