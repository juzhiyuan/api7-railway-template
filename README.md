# API7 Control Plane on Railway (Bootstrap-First)

This repo is the **single source** for all API7 control-plane services on Railway.

## Why bootstrap-first
A plain Railway "Deploy from GitHub repo" action creates one service and runs Railpack auto-detection. With this repo layout, that commonly fails with:

```text
⚠ Script start.sh not found
✖ Railpack could not determine how to build the app.
```

That is expected. Railway plain repo flow is single-service, while this stack needs multiple services.

Use this repo with the bootstrap script instead:
- one repo URL
- one command
- all required services created or reconciled idempotently

## What gets provisioned
- `dashboard` (public on `7080`)
- `dp-manager` (public on `7943`)
- `prometheus` (private)
- `jaeger` (private)
- `Postgres` (Railway PostgreSQL plugin, private)

Not included:
- API7 gateway service (manual post-deploy step)

## Dockerfile routing model (same GitHub link for all services)
Every Railway service points to the **same GitHub repository URL** and uses `RAILWAY_DOCKERFILE_PATH` to select its build target:

- `dashboard` -> `Dockerfile.dashboard`
- `dp-manager` -> `Dockerfile.dp-manager`
- `prometheus` -> `Dockerfile.prometheus`
- `jaeger` -> `Dockerfile.jaeger`

## Prerequisites
- `railway` CLI installed
- `jq` installed
- `railway login` completed
- repository pushed to GitHub

## Quickstart
```bash
./scripts/bootstrap-railway-project.sh \
  --project api7-control-plane \
  --repo-url https://github.com/<you>/<repo>
```

Optional workspace targeting:
```bash
./scripts/bootstrap-railway-project.sh \
  --project api7-control-plane \
  --repo-url https://github.com/<you>/<repo> \
  --workspace <workspace-id-or-name>
```

## Script contract
Path: `scripts/bootstrap-railway-project.sh`

Arguments:
- `--project <name>` required
- `--repo-url <url>` required (GitHub URL; `org/repo` also accepted)
- `--workspace <workspace>` optional

Idempotency behavior:
- creates or links project
- creates or reuses `Postgres`, `dashboard`, `dp-manager`, `prometheus`, `jaeger`
- reapplies required variables on rerun
- ensures dashboard/dp-manager public domains
- ensures Prometheus volume mount at `/opt/bitnami/prometheus/data`

## Required variable wiring
The script auto-resolves the PostgreSQL service reference. Default target is `Postgres`.

`dashboard`:
- `DATABASE_DSN=${{Postgres.DATABASE_URL}}`
- `PROMETHEUS_ADDR=http://prometheus.railway.internal:9090`
- `JAEGER_ADDR=http://jaeger.railway.internal:16686`

`dp-manager`:
- `DATABASE_DSN=${{Postgres.DATABASE_URL}}`
- `PROMETHEUS_ADDR=http://prometheus.railway.internal:9090`
- `JAEGER_COLLECTOR_ADDR=http://jaeger.railway.internal:4318`

## Troubleshooting
### `Railpack could not determine how to build the app`
Cause:
- you created a plain single-service project directly from repo URL, so Railway tried Railpack detection.

Fix:
1. Keep using the same GitHub repo URL.
2. Run the bootstrap command above.
3. Let the script create all services and set `RAILWAY_DOCKERFILE_PATH` per service.

### `Unauthorized. Please login with railway login`
Cause:
- Railway CLI is not authenticated.

Fix:
```bash
railway login
```
Then rerun bootstrap.

### `--repo-url must be a GitHub repository URL`
Cause:
- repo URL is malformed or not a GitHub repository path.

Fix:
- use `https://github.com/<org>/<repo>` (or `.git` suffix).

### `repo not found`
Cause:
- Railway can only link repos visible to its connected GitHub integration, and expects repository identity as `org/repo`.

Fix:
1. Confirm the repository exists and is pushed.
2. In Railway, connect/install GitHub integration for the workspace and grant access to this repo.
3. Rerun bootstrap with the same URL. The script normalizes it to `org/repo` automatically.

## Security note
API7 dashboard temporary credentials are `admin/admin` on first boot. Rotate immediately.

## Optional: publish as a real Railway template
Bootstrap is the primary supported workflow. If you also want a public template entry in Railway UI, follow:
- `docs/railway-template-publish.md`
