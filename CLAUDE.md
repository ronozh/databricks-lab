# databricks-lab — working agreements

## Responses

**Be concise.** Short answers, no preamble, no recap, no restating the question.

---

## Every phase ships three documents

**Non-negotiable. A phase is not finished until these exist in its `.plan/phase-N-*/` folder.**

| Document | Contents |
|---|---|
| **`gotcha.md`** | Every issue hit during the phase and how it was fixed. Include the exact error text — "not available" and "I called it wrong" look identical in a summary, and only the error distinguishes them. Mistakes I made myself go here too |
| **`cheatsheet.md`** | Every CLI command used, especially `databricks`, with what each one does. Copy-pasteable |
| **`mental-model.md`** | How the flow works: components, connections, data movement. Explain every Databricks product, feature, term or design decision the phase touched. This doc is for *understanding*, not instructions |

All markdown. **Concise.** Tables and diagrams over prose wherever they read better.

---

## Standing decisions

Set in Phase 1 after the Phase 0 probe. See `.plan/README.md`.

| # | Decision |
|---|---|
| **D1** | **dbt only** until Phase 8 (PySpark, targeted and optional) |
| **D2** | **HR only** until Phase 6 (Finance, the second and only other domain) |
| **D3** | **Silver is materialized.** The *"silver may not join"* rule still holds — that is a discipline about content, not materialization |
| **D4** | Workspace, catalog, warehouse and principal IDs are **variables**, never literals |

Also settled: **Free Edition only** (`--profile free`; the paid workspace cannot run SQL),
**catalog per domain**, **UC Volumes** for landing, **`read_files()`** for ingestion,
**file-arrival triggers** over schedules.

## Layer rules, carried from local-lab

| Layer | Rule |
|---|---|
| landing | The Volume itself. Append-only. A correction is a NEW file, never an overwrite |
| `bronze_` | 1:1 with the file, typed, provenance attached. **Must not** filter, derive or deduplicate |
| `silver_` | One current row per key. **Must not join.** May select, filter, window |
| `gold_` | Named for the business question, not the source tables. The only layer allowed to join |

## Verification

**Nothing is done because a document says so.** Every claim about the platform or the data is
proven by running something. Two of three findings in the first Phase 0 run were my own errors,
found only by re-testing.

Before claiming a phase complete: run it twice (idempotency), break it on purpose (the check must
be seen failing), and have an independent pass review it.

## Secrets

`.env.secret` is gitignored and holds the service-principal OAuth credentials. Never inline a
token, client secret or workspace ID into a model, profile or committed file.
