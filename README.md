# databricks-lab

A medallion data platform on Databricks — landing → bronze → silver → gold — built with dbt,
Unity Catalog and Delta, on Databricks **Free Edition**.

A port of a local Docker lab (Iceberg + Polaris + MinIO + Spark + Trino) onto the managed stack,
keeping the patterns and replacing the tools.

## Status

**Phase 1 complete.** HR domain, end to end, 51 dbt nodes green.

| | |
|---|---|
| Landing | UC Volume, append-only, `.csv` + `.ctrl` sidecar per delivery |
| Bronze | 1:1 with the file, typed, five provenance columns, file-fingerprint watermark |
| Silver | one current row per key, materialized — **may never join** |
| Gold | named for the business question; the only layer allowed to join |

## Layout

```
infra/          delivery, SQL runner, grants, review environment, job specs
pipelines/dbt/  the models, macros and tests
run-dbt.sh      one entry point — sources config, runs dbt
```

Planning, analysis and phase write-ups live outside this repo, in local-only `.` directories.

## Running it

Requires the Databricks CLI authenticated to a workspace, and a local `.envrc` +
`.env.secret` (neither is committed):

```bash
# .envrc
export DBX_HOST=...                 # workspace hostname
export DBX_HTTP_PATH=/sql/1.0/warehouses/<id>
export DBX_CATALOG=hr
export DBX_LANDING_VOLUME=/Volumes/hr/landing/drop
export DBX_SP_APP_ID=...            # dbt service principal applicationId
export DBX_HUMAN_PRINCIPAL=...      # your account

# .env.secret  (chmod 600)
export DBX_CLIENT_ID=...
export DBX_CLIENT_SECRET=...
```

```bash
python3 infra/dbsql.py --file infra/sql/00-setup.sql   # catalog, schemas, volume
./infra/grants.sh                                      # principals
python3 infra/deliver.py --all                         # files -> landing volume
./run-dbt.sh build                                     # bronze -> silver -> gold
```

An isolated catalog for review or experiments, reading the same landing Volume:

```bash
./infra/review-env.sh create && ./infra/review-env.sh build
```

## Design notes

- **Ingestion is `read_files()`**, not `COPY INTO` or Auto Loader. `COPY INTO` tracks loaded
  files for you and hides the mechanism; Auto Loader via streaming tables measured ~67s of
  pipeline startup per table against a ~76s whole build. The watermark here is explicit and
  visible, including the case it is blind to.
- **The declared read schema binds by position**, not header name — 96× faster than inference
  (1,631s → 17s on a 730-file feed) and it makes the header decorative, so
  `rescuedDataColumn` and a header check guard against upstream drift.
- **The `.ctrl` sidecar is the delivery contract**: declared row count *and* md5 are both
  verified, and file presence is asserted against the Volume listing.

## Tests

51 nodes. The ones that matter are the ones that have been **seen failing**: a truncated
delivery, a NULL declared count, a delivery with no sidecar, a tampered md5, and an emptied gold
table each fail the build.
