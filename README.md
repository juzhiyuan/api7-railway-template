# API7 Control Plane Railway Template (Single GitHub Link, No Gateway)

This repository is designed so **all Railway services use the same GitHub repo URL**.
You do not need per-service root directories.

Important Railway behavior:
- Pasting a plain GitHub repo URL into Railway creates one service by default.
- To provision the full stack in one operation, use either:
  - A published Railway Template link, or
  - The bootstrap script in this repo.

Included services:
- API7 Dashboard (`api7-ee-3-integrated:v3.9.5`)
- API7 DP Manager (`api7-ee-dp-manager:v3.9.5`)
- Prometheus (`api7/prometheus:2.48.1-debian-11-r0`)
- Jaeger (`jaeger:2.14.0`)
- Railway PostgreSQL plugin

Not included:
- API7 Gateway service (manual deployment after template instantiation)

## Single-link deployment model
For each Railway service, use the **same source repository URL** and set a different `RAILWAY_DOCKERFILE_PATH`:

| Railway service name | `RAILWAY_DOCKERFILE_PATH` |
| --- | --- |
| `dashboard` | `Dockerfile.dashboard` |
| `dp-manager` | `Dockerfile.dp-manager` |
| `prometheus` | `Dockerfile.prometheus` |
| `jaeger` | `Dockerfile.jaeger` |

Internal config/entrypoint assets are stored under:
- `services/dashboard`
- `services/dp-manager`

Detailed steps: `docs/railway-template-publish.md`

## One-command project bootstrap
If you want to avoid creating four services manually, use:

```bash
./scripts/bootstrap-railway-project.sh \
  --project api7-control-plane \
  --repo-url https://github.com/<you>/<repo>
```

Optional:

```bash
./scripts/bootstrap-railway-project.sh \
  --project api7-control-plane \
  --repo-url https://github.com/<you>/<repo> \
  --workspace <workspace-id-or-name>
```

What it does:
- Creates a new Railway project
- Adds Postgres plugin
- Adds `dashboard`, `dp-manager`, `prometheus`, `jaeger` from the same repo URL
- Sets required cross-service env vars
- Creates public domains for dashboard/dp-manager
- Attaches a Prometheus volume at `/opt/bitnami/prometheus/data`

## Required environment variables

### Dashboard service
- `DATABASE_DSN` (from Postgres plugin)
- `PROMETHEUS_ADDR` (recommended: `http://prometheus.railway.internal:9090`)
- `JAEGER_ADDR` (recommended: `http://jaeger.railway.internal:16686`)
When using Railway variable references, match the namespace to your PostgreSQL service name (example: `${{Postgres.DATABASE_URL}}`).

Optional Dashboard variables:
- `DASHBOARD_LOG_LEVEL` default: `warn`
- `DASHBOARD_ACCESS_LOG` default: `stdout`
- `DASHBOARD_HTTP_DISABLE` default: `false`
- `DASHBOARD_HTTP_HOST` default: `0.0.0.0`
- `DASHBOARD_HTTP_PORT` default: `7080`
- `DASHBOARD_TLS_DISABLE` default: `false`
- `DASHBOARD_TLS_HOST` default: `0.0.0.0`
- `DASHBOARD_TLS_PORT` default: `7443`

### DP Manager service
- `DATABASE_DSN` (from Postgres plugin)
- `PROMETHEUS_ADDR` (recommended: `http://prometheus.railway.internal:9090`)
- `JAEGER_COLLECTOR_ADDR` (recommended: `http://jaeger.railway.internal:4318`)

Optional DP Manager variables:
- `DP_MANAGER_LOG_LEVEL` default: `warn`
- `DP_MANAGER_ACCESS_LOG` default: `stdout`
- `DP_MANAGER_HTTP_HOST` default: `0.0.0.0`
- `DP_MANAGER_HTTP_PORT` default: `7900`
- `DP_MANAGER_TLS_HOST` default: `0.0.0.0`
- `DP_MANAGER_TLS_PORT` default: `7943`

## Public exposure contract
- Dashboard public endpoint: port `7080` (Railway TLS edge)
- DP Manager public endpoint: port `7943` (service-native TLS)
- Prometheus: private only
- Jaeger: private only

## Prometheus persistence
Attach a Railway volume to the Prometheus service mount path:
- `/opt/bitnami/prometheus/data`

## Default API7 temporary credentials
The API7 control plane starts with temporary credentials:
- username: `admin`
- password: `admin`

Rotate credentials immediately after first login.

## Manual gateway deployment
This template intentionally excludes the default gateway.

After Dashboard and DP Manager are healthy, deploy gateway manually via API7 Dashboard deployment workflow so each fresh project can choose its own gateway runtime settings.
