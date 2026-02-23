#!/bin/sh
set -eu

required_var() {
  name="$1"
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "ERROR: required environment variable $name is not set" >&2
    exit 1
  fi
}

required_var DATABASE_DSN
required_var PROMETHEUS_ADDR
required_var JAEGER_ADDR

DASHBOARD_LOG_LEVEL="${DASHBOARD_LOG_LEVEL:-warn}"
DASHBOARD_ACCESS_LOG="${DASHBOARD_ACCESS_LOG:-stdout}"
DASHBOARD_HTTP_DISABLE="${DASHBOARD_HTTP_DISABLE:-false}"
DASHBOARD_HTTP_HOST="${DASHBOARD_HTTP_HOST:-0.0.0.0}"
DASHBOARD_HTTP_PORT="${DASHBOARD_HTTP_PORT:-7080}"
DASHBOARD_TLS_DISABLE="${DASHBOARD_TLS_DISABLE:-false}"
DASHBOARD_TLS_HOST="${DASHBOARD_TLS_HOST:-0.0.0.0}"
DASHBOARD_TLS_PORT="${DASHBOARD_TLS_PORT:-7443}"

mkdir -p /usr/local/api7/conf

cat > /usr/local/api7/conf/conf.yaml <<EOF_CONFIG
server:
  listen:
    disable: ${DASHBOARD_HTTP_DISABLE}
    host: "${DASHBOARD_HTTP_HOST}"
    port: ${DASHBOARD_HTTP_PORT}
  tls:
    disable: ${DASHBOARD_TLS_DISABLE}
    host: "${DASHBOARD_TLS_HOST}"
    port: ${DASHBOARD_TLS_PORT}
    key_file: ""
    cert_file: ""
  status:
    disable: false
    host: "127.0.0.1"
    port: 7081
  pprof:
    enable: true
    host: "127.0.0.1"
    port: 6060

log:
  level: ${DASHBOARD_LOG_LEVEL}
  output: stderr
  access_log: ${DASHBOARD_ACCESS_LOG}

database:
  dsn: "${DATABASE_DSN}"
  max_open_conns: 30
  max_idle_time: 30s
  timeout: 5s

session_options_config:
  same_site: "lax"
  secure: false
  max_age: 86400

prometheus:
  addr: "${PROMETHEUS_ADDR}"
  query_path_prefix: ""
  whitelist:
    - "/api/v1/query_range"
    - "/api/v1/query"
    - "/api/v1/format_query"
    - "/api/v1/series"
    - "/api/v1/labels"
    - "/api/v1/labels/.*/values"

jaeger:
  addr: "${JAEGER_ADDR}"
  timeout: 30s

audit:
  retention_days: 60
consumer_proxy:
  enable: false
  cache_success_count: 512
  cache_success_ttl: 60
  cache_failure_count: 512
  cache_failure_ttl: 60
developer_proxy:
  cache_success_count: 256
  cache_success_ttl: 15
  cache_failure_count: 256
  cache_failure_ttl: 15

security:
  trusted_proxies: ["0.0.0.0/0", "::/0"]
  ip_restriction:
    allow_list: []
    deny_list: []
    message: "Access denied"
    response_code: 403
EOF_CONFIG

cd /usr/local/api7
node server.js &
exec /usr/local/api7/api7-ee-dashboard -c /usr/local/api7/conf/conf.yaml
