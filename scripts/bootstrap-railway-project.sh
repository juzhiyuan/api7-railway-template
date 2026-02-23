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
  - canonical service names are enforced:
    Postgres, dashboard, dp-manager, prometheus, jaeger
EOF
}

PROJECT_NAME=""
REPO_URL=""
REPO_SLUG=""
WORKSPACE=""
PROMETHEUS_VOLUME_MOUNT_PATH="/opt/bitnami/prometheus/data"

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

validate_repo_url

if ! railway whoami >/dev/null 2>&1; then
  fail "Not authenticated. Run: railway login"
fi

ensure_project() {
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
    log "Reusing existing Postgres service."
    return 0
  fi

  if railway add --database postgres --service Postgres >/dev/null 2>&1; then
    log "Created Postgres service."
  else
    warn "Could not create named Postgres service directly, retrying with default database add."
    railway add --database postgres >/dev/null
  fi

  if ! service_exists "Postgres"; then
    fail "Postgres service must be named exactly 'Postgres' for variable references. Rename it and rerun."
  fi
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
  ensure_project
  ensure_postgres

  ensure_service_from_repo "dashboard" "Dockerfile.dashboard"
  ensure_service_from_repo "dp-manager" "Dockerfile.dp-manager"
  ensure_service_from_repo "prometheus" "Dockerfile.prometheus"
  ensure_service_from_repo "jaeger" "Dockerfile.jaeger"

  ensure_variables "dashboard" \
    'DATABASE_DSN=${{Postgres.DATABASE_URL}}' \
    'PROMETHEUS_ADDR=http://prometheus.railway.internal:9090' \
    'JAEGER_ADDR=http://jaeger.railway.internal:16686'

  ensure_variables "dp-manager" \
    'DATABASE_DSN=${{Postgres.DATABASE_URL}}' \
    'PROMETHEUS_ADDR=http://prometheus.railway.internal:9090' \
    'JAEGER_COLLECTOR_ADDR=http://jaeger.railway.internal:4318'

  ensure_public_domain "dashboard" "7080"
  ensure_public_domain "dp-manager" "7943"
  ensure_prometheus_volume

  echo
  log "Bootstrap complete."
  log "Project: $PROJECT_NAME"
  log "Services: dashboard, dp-manager, prometheus, jaeger, Postgres"
}

main "$@"
