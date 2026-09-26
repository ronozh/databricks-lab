# databricks-lab

A medallion data platform on Databricks — landing → bronze → silver → gold — built with dbt,
Unity Catalog and Delta, on Databricks **Free Edition**.

A port of a local Docker lab (Iceberg + Polaris + MinIO + Spark + Trino) onto the managed stack,
keeping the patterns and replacing the tools.

## Status

**Phases 1–3 complete.** HR domain end to end, 51 dbt nodes green, Unity Catalog governance
enforced and proven per principal, and Delta file layout measured rather than assumed.

| | |
|---|---|
| Landing | UC Volume, append-only, `.csv` + `.ctrl` sidecar per delivery |
| Bronze | 1:1 with the file, typed, five provenance columns, file-fingerprint watermark |
| Silver | one current row per key, materialized — **may never join** |
| Gold | named for the business question; the only layer allowed to join |
| Governance | role grants, column masks, a row filter, PII tags, a tag-driven ABAC policy, a stewardship register |
| Delta | layout and history measured per table; clustering decided with a number, retention's mechanism established and its measurement deferred |

## Layout

```
infra/             delivery, SQL runner, grants, review environment, job specs
infra/governance/  principals, grants, tags, masks, row filters, ABAC, stewardship
infra/delta/       file-layout + history measurement, Delta design assertions
pipelines/dbt/     the models, macros and tests
run-dbt.sh         one entry point — sources config, runs dbt
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
./infra/grants.sh                                      # the pipeline principal
python3 infra/deliver.py --all                         # files -> landing volume
./run-dbt.sh build                                     # bronze -> silver -> gold
./infra/governance/apply.sh                            # roles, tags, masks, filters, policies
./infra/governance/verify.sh                           # 24 assertions
./infra/governance/prove.sh                            # same query, every principal
python3 infra/delta/measure.py                         # file layout + history per table
./infra/delta/verify.sh                                # 8 Delta design assertions
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
- **Governance is split by lifecycle, not by tool.** Mask and filter *functions*, grants, tags and
  the access map live in `infra/governance/`; the mask and row-filter *bindings* live in dbt model
  config — because `dbt-databricks` reconciles them on every run and drops any binding it did not
  configure. A control applied out of band survives exactly until the next green build.
- **Masks and row filters apply to the table's owner, the pipeline included.** Left unexempted, the
  pipeline read `NULL` for every salary and wrote `total_salary = 0.00` into gold while dbt reported
  `PASS=1`. Nothing errored.
- **A mask on silver is worth nothing if bronze is readable.** Bronze stays unmasked so it keeps
  time travel (a column mask disables it), so "nobody outside the steward role reads bronze" is an
  asserted invariant rather than a note.
- **The small-file problem never reaches Delta here, and that is a finding.** The 794 small files are
  landing CSVs; `read_files()` writes one Parquet file, and silver and gold are rewritten whole every
  build, so they are permanently one file. `OPTIMIZE` has nothing to compact — measured, not assumed,
  after the plan had twice asserted the opposite.
- **Liquid clustering is not declared**, because at one file of 85 KB there is nothing to skip and
  setting `liquid_clustered_by` also runs an `OPTIMIZE` after every build of that model. The
  threshold at which it would pay is written down instead.
- **Retention is a property, not a command.** Setting `delta.deletedFileRetentionDuration` blocks
  time travel immediately, with every file still on disk. `VACUUM` only collects what the property
  already abandoned — the opposite of the intuitive causality. Established on a throwaway table; no
  retention policy is set on any `hr` table, and the measurement on the real pipeline is deferred.

## Tests

51 dbt nodes, plus 24 governance assertions and 8 Delta design assertions. The ones that matter are
the ones that have been **seen failing**.

dbt: a truncated delivery, a NULL declared count, a delivery with no sidecar, a tampered md5, and
an emptied gold table each fail the build.

Governance: dropping the row filter, granting an unapproved reader on bronze PII, and removing a
classification tag each fail `verify.sh`. Because a control that nobody has watched fail is
indistinguishable from one that does nothing — masks and row filters do not raise errors, they
quietly return less.

Delta: the clustering assertion was first written against `information_schema`, where a clustered
column is invisible, so it could not fail. Creating a clustered table proved the rewritten version
catches it.
