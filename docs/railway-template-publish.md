# Optional Appendix: Publish This Project as a Public Railway Template

This document is optional. The primary workflow for this repository is bootstrap-first provisioning via:
- `scripts/bootstrap-railway-project.sh`

Use this appendix only if you also want a public template in Railway UI.

## Preconditions
- repository is pushed to GitHub
- bootstrap flow has already been validated at least once
- all services healthy in Railway project (`dashboard`, `dp-manager`, `prometheus`, `jaeger`, `Postgres`)

## Publish steps
1. Open Railway project that already runs this stack.
2. Go to `Project Settings -> Publish -> New Template`.
3. Enter template metadata (name, description, icon, tags).
4. Set visibility to `Public`.
5. Publish and verify new-project creation from the template link.

## Template scope
- Included: `dashboard`, `dp-manager`, `prometheus`, `jaeger`, `Postgres` plugin
- Excluded: gateway service

## Post-publish verification
1. Create a fresh project from the template.
2. Confirm all services deploy without manual edits.
3. Confirm public exposure policy:
   - `dashboard` on `7080`
   - `dp-manager` on `7943`
   - `prometheus` and `jaeger` private only
4. Confirm Prometheus volume remains mounted at `/opt/bitnami/prometheus/data`.

## Notes
- Plain "deploy from repo URL" is single-service and can trigger Railpack detection failure.
- Bootstrap-first remains the official reproducible path for this repo.
