# databricks-lab

A medallion data platform on Databricks — landing → bronze → silver → gold — built with dbt,
Unity Catalog and Delta, on Databricks **Free Edition**.

A port of a local Docker lab (Iceberg + Polaris + MinIO + Spark + Trino) onto the managed stack,
keeping the patterns and replacing the tools.

## Status

**Phases 1–4 complete.** HR domain end to end, Unity Catalog governance enforced and proven per
principal, Delta file layout measured rather than assumed, and a governed semantic layer that Genie
and a dashboard both answer through.

| | |
|---|---|
| Landing | UC Volume, append-only, `.csv` + `.ctrl` sidecar per delivery |
| Bronze | 1:1 with the file, typed, seven provenance columns (silver keeps four), file-fingerprint watermark |
| Silver | one current row per key, materialized — **may never join** |
| Gold | named for the business question; the only layer allowed to join |
| Governance | role grants, column masks, a row filter, PII tags, a tag-driven ABAC policy, a stewardship register |
| Delta | layout and history measured per table; clustering decided with a number, retention's mechanism established and its measurement deferred |
| Semantic | a metric view holding **three** competing definitions of headcount, each named for its rule; a Genie space and an AI/BI dashboard built from code |

## Layout

```
infra/             delivery, SQL runner, grants, review environment, job specs
infra/governance/  principals, grants, tags, masks, row filters, ABAC, stewardship
infra/delta/       file-layout + history measurement, Delta design assertions
infra/semantic/    Genie space, AI/BI dashboard, semantic-layer assertions
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
./infra/delta/verify.sh                                # 11 Delta design assertions
python3 infra/semantic/10-genie-space.py               # the Genie space, from code
python3 infra/semantic/20-dashboard.py                 # the AI/BI dashboard, from code
./infra/semantic/verify.sh                             # 17 semantic-layer assertions
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
- **A view inherits the controls of the tables it *reads*** — measured, and evaluated as the caller, not
  the view's owner. The first metric view still leaked all 478 employees to a principal limited to 2 of
  16 departments, because it read `silver`, where no row filter exists; the filter is bound to the gold
  *table* it never touches. It read **around** the control rather than dropping one. Masks did carry
  through, and that partial inheritance is what made it look governed. So the question is never *"is
  this a new object?"* but **"which tables am I reading, and are the controls bound to those?"**
- **Three correct answers to "how many people work here", and the layer's job is to refuse to pick.**
  478 people, 447.0 FTE-weighted, 416 full-time. Asked against raw `silver`, Genie answered *"478
  employees"* — correct, and silent about the choice. Asked through the metric view with instructions,
  it returned all three, each labelled with the measure that produced it.
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

52 dbt nodes (10 models, 42 tests), plus 24 governance, 11 Delta design and 17 semantic-layer assertions. The ones that matter are
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

Semantic: the assertion that a restricted principal sees 70 people and not 478 was proven by
rebuilding the metric view without its access predicate and watching it go red — because that leak
is the one that phase actually shipped by accident. Independent review then drove five more of its
assertions red by construction, and found one that could not fail: an *empty* dashboard satisfied
"every dataset reads the semantic layer", because a check that only looks for counter-examples
passes when there is nothing to check.
