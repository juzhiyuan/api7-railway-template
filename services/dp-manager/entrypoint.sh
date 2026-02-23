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
required_var JAEGER_COLLECTOR_ADDR

# API7 expects "postgres://", but Railway DATABASE_URL commonly uses "postgresql://".
case "${DATABASE_DSN}" in
  postgresql://*)
    DATABASE_DSN="postgres://${DATABASE_DSN#postgresql://}"
    ;;
esac

DP_MANAGER_LOG_LEVEL="${DP_MANAGER_LOG_LEVEL:-warn}"
DP_MANAGER_ACCESS_LOG="${DP_MANAGER_ACCESS_LOG:-stdout}"
DP_MANAGER_HTTP_HOST="${DP_MANAGER_HTTP_HOST:-0.0.0.0}"
DP_MANAGER_HTTP_PORT="${DP_MANAGER_HTTP_PORT:-7900}"
DP_MANAGER_TLS_HOST="${DP_MANAGER_TLS_HOST:-0.0.0.0}"
DP_MANAGER_TLS_PORT="${DP_MANAGER_TLS_PORT:-7943}"

CONFIG_DIR="/tmp/api7/conf"
CONFIG_FILE="$CONFIG_DIR/conf.yaml"
mkdir -p "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF_CONFIG
server:
  listen:
    host: "${DP_MANAGER_HTTP_HOST}"
    port: ${DP_MANAGER_HTTP_PORT}
  tls:
    host: "${DP_MANAGER_TLS_HOST}"
    port: ${DP_MANAGER_TLS_PORT}
  status:
    disable: false
    host: "127.0.0.1"
    port: 7901
  pprof:
    enable: true
    host: "127.0.0.1"
    port: 6060

log:
  level: ${DP_MANAGER_LOG_LEVEL}
  output: stderr
  access_log: ${DP_MANAGER_ACCESS_LOG}

database:
  dsn: "${DATABASE_DSN}"
  max_open_conns: 30
  max_idle_time: 30s
  timeout: 5s

prometheus:
  addr: "${PROMETHEUS_ADDR}"
  remote_write_path: "/api/v1/write"

jaeger:
  collector_addr: "${JAEGER_COLLECTOR_ADDR}"
  timeout: 30s

consumer_cache:
  size: 50000
  max_ttl: 2h
  evict_interval: 5s

developer_cache:
  size: 50000
  max_ttl: 2h
  evict_interval: 5s

rate_limit:
  enable: false
  time_window: 1
  count: 1000
EOF_CONFIG

exec /usr/local/api7/api7-ee-dp-manager -c "$CONFIG_FILE"
