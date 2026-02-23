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
  - fresh/unlinked directory recommended
EOF
}

PROJECT_NAME=""
REPO_URL=""
WORKSPACE=""

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

if ! command -v railway >/dev/null 2>&1; then
  echo "railway CLI is required. Install it first." >&2
  exit 1
fi

if ! railway whoami >/dev/null 2>&1; then
  echo "Not authenticated. Run: railway login" >&2
  exit 1
fi

init_project() {
  if [[ -n "$WORKSPACE" ]]; then
    railway init --name "$PROJECT_NAME" --workspace "$WORKSPACE"
  else
    railway init --name "$PROJECT_NAME"
  fi
}

add_repo_service() {
  local service_name="$1"
  local dockerfile_path="$2"

  railway add \
    --service "$service_name" \
    --repo "$REPO_URL" \
    --variables "RAILWAY_DOCKERFILE_PATH=$dockerfile_path"
}

echo "Creating Railway project: $PROJECT_NAME"
init_project

echo "Adding PostgreSQL plugin service"
railway add --database postgres

echo "Adding application services from one repo URL"
add_repo_service dashboard Dockerfile.dashboard
add_repo_service dp-manager Dockerfile.dp-manager
add_repo_service prometheus Dockerfile.prometheus
add_repo_service jaeger Dockerfile.jaeger

echo "Configuring service variables"
railway variables --service dashboard --skip-deploys \
  --set 'DATABASE_DSN=${{Postgres.DATABASE_URL}}' \
  --set 'PROMETHEUS_ADDR=http://prometheus.railway.internal:9090' \
  --set 'JAEGER_ADDR=http://jaeger.railway.internal:16686'

railway variables --service dp-manager --skip-deploys \
  --set 'DATABASE_DSN=${{Postgres.DATABASE_URL}}' \
  --set 'PROMETHEUS_ADDR=http://prometheus.railway.internal:9090' \
  --set 'JAEGER_COLLECTOR_ADDR=http://jaeger.railway.internal:4318'

echo "Generating public domains"
railway domain --service dashboard --port 7080
railway domain --service dp-manager --port 7943

echo "Attaching Prometheus persistent volume"
railway service prometheus
railway volume add --mount-path /opt/bitnami/prometheus/data

echo
echo "Bootstrap complete."
echo "Project: $PROJECT_NAME"
echo "Services: dashboard, dp-manager, prometheus, jaeger, Postgres"
echo "Next: open Railway dashboard and verify deployments/health."
