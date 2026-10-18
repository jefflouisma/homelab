# Analytics operations

The `analytics` Argo application renders [apps/analytics/kustomization.yaml](apps/analytics/kustomization.yaml). Airflow, DataHub, and DataHub prerequisites have dedicated Helm Applications in [apps/analytics-helm-apps.yaml](apps/analytics-helm-apps.yaml). Their existing persistent storage is retained.

| Service | Entry point |
| --- | --- |
| Airflow | `http://airflow.barleta.local` |
| DataHub | `http://datahub.barleta.local` |
| Grafana | `http://grafana.barleta.local` |
| Metabase | `http://metabase.barleta.local` |
| Superset | `http://superset.barleta.local` |

Loki/Alloy collect logs. PostgreSQL lives in `identity`, with analytics schemas in the existing `midpoint` database.

## Database setup and UCI ingestion

Database setup and ingestion are **suspended CronJobs**. Create a Job explicitly to run either operation. This prevents Argo self-heal from repeatedly recreating TTL-deleted Jobs.

```sh
kubectl create job --from=cronjob/analytics-db-setup analytics-db-setup-manual -n identity
kubectl wait --for=condition=complete job/analytics-db-setup-manual -n identity --timeout=600s
kubectl logs job/analytics-db-setup-manual -n identity

kubectl create job --from=cronjob/uci-data-loader uci-data-loader-manual -n analytics
kubectl wait --for=condition=complete job/uci-data-loader-manual -n analytics --timeout=1800s
kubectl logs job/uci-data-loader-manual -n analytics
```

Use a fresh Job name for another run. Database setup reads the existing PostgreSQL Secret and stops on SQL errors. The loader image bundles pinned Python dependencies; Jobs do not install packages on startup.

The UCI loader validates the Online Retail workbook columns, removes rows without customer IDs, and loads `raw_uci.transactions` transactionally. The production load contains **406,829** rows. A PostgreSQL advisory lock prevents concurrent writes. A subsequent run preserves an existing nonempty table and reports that ingestion was skipped. Loading errors roll back instead of dropping the table.

Airflow migration and user setup jobs use ordered Argo Sync hooks with cleanup. Chart updates can replace their immutable Job templates without turning TTL expiry into a self-heal loop.

## Loader integration test

Use an isolated PostgreSQL database. Put the Python environment under the required temporary root:

```sh
export TMPDIR=/Volumes/4TB_Drive/tmp/
python3 -m venv /Volumes/4TB_Drive/tmp/loader-tests/venv
. /Volumes/4TB_Drive/tmp/loader-tests/venv/bin/activate
pip install -r barleta/apps/analytics/uci-loader/requirements.txt
export PGHOST=localhost PGUSER=postgres PGDATABASE=loader_test
# Set PGPASSWORD for the isolated test database.
make test-loader
```

Tests cover initial ingestion, retry, schema validation, and rollback against PostgreSQL. GitHub Actions provides an isolated PostgreSQL service and requires these tests before publishing the image.

Earlier design sketches are available at Git commit `5a22b7a`. Planned dbt models and extra datasets described there are not deployed components of this repository.
