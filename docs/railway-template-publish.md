# Publish This Repository as a Public Railway Template

Before you start:
- A plain "paste GitHub repo URL" action in Railway creates one service.
- Multi-service one-click provisioning requires a published Railway Template, or automation via Railway CLI.

Fast automation option (no manual per-service setup):
```bash
./scripts/bootstrap-railway-project.sh \
  --project api7-control-plane \
  --repo-url https://github.com/<you>/<repo>
```

## 1. Push repository to GitHub
1. Create a GitHub repository.
2. Push this directory to the default branch.

## 2. Create Railway project from one GitHub link
1. In Railway, create a new project from the GitHub repository.
2. Add four services that all use the **same source repo URL**.
3. Name services exactly: `dashboard`, `dp-manager`, `prometheus`, `jaeger`.
4. For each service, set the matching Dockerfile path variable:
   - `dashboard`: `RAILWAY_DOCKERFILE_PATH=Dockerfile.dashboard`
   - `dp-manager`: `RAILWAY_DOCKERFILE_PATH=Dockerfile.dp-manager`
   - `prometheus`: `RAILWAY_DOCKERFILE_PATH=Dockerfile.prometheus`
   - `jaeger`: `RAILWAY_DOCKERFILE_PATH=Dockerfile.jaeger`
5. Do not set per-service root directories.
6. Add a PostgreSQL plugin service.

## 3. Configure service networking and variables
All services must be in the same Railway environment.

### 3.1 Dashboard variables
Set these in the Dashboard service:
- `DATABASE_DSN=${{Postgres.DATABASE_URL}}`
- `PROMETHEUS_ADDR=http://prometheus.railway.internal:9090`
- `JAEGER_ADDR=http://jaeger.railway.internal:16686`
If your PostgreSQL service is named differently, replace `Postgres` in the template reference namespace.

### 3.2 DP Manager variables
Set these in the DP Manager service:
- `DATABASE_DSN=${{Postgres.DATABASE_URL}}`
- `PROMETHEUS_ADDR=http://prometheus.railway.internal:9090`
- `JAEGER_COLLECTOR_ADDR=http://jaeger.railway.internal:4318`

### 3.3 Prometheus persistence
Attach a Railway volume to Prometheus:
- Mount path: `/opt/bitnami/prometheus/data`

## 4. Configure public exposure
1. Expose Dashboard publicly on port `7080`.
2. Expose DP Manager publicly on port `7943`.
3. Do not expose Prometheus or Jaeger publicly.

## 5. Verify deployment
Check all of the following:
1. All services reach Running/Healthy status.
2. Dashboard public URL loads and login works (`admin/admin` on first boot).
3. DP Manager public endpoint on `7943` is reachable.
4. Dashboard can query Prometheus and connect to PostgreSQL.
5. Restart Prometheus and confirm metrics data remains available (volume works).

## 6. Publish as public Railway template
1. Open `Project Settings` in Railway.
2. Select `Publish` then `New Template`.
3. Fill in template metadata (name, description, icon, tags).
4. Set visibility to Public.
5. Publish and verify you can create a brand-new project from the template.

## 7. Post-publish updates
When changing service images/configs:
1. Update this repository.
2. Redeploy and validate in Railway.
3. Republish the template snapshot if required by your workflow.

## Notes
- This template intentionally excludes an API7 gateway container.
- Gateway should be added manually after template instantiation via Dashboard.
- Keep API7 image tags pinned for reproducible project creation.
