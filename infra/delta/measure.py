"""
Record the Delta file layout and history of every table in a catalog.

    python3 infra/delta/measure.py                 # the catalog from .envrc
    python3 infra/delta/measure.py hr_review
    python3 infra/delta/measure.py --json          # machine-readable, for diffing

Two things make this more than a `DESCRIBE DETAIL` loop:

  * it reports whether each table is actually TIME-TRAVELLABLE, by attempting the
    read rather than inferring it from the presence of a mask. Phase 2 bound masks
    and a row filter, and each silently disables time travel -- so "has history"
    and "can read history" are different questions and only one of them is
    answerable by asking the metastore;
  * it reports the OPERATION MIX from the history, which is what distinguishes an
    incremental model (appends accumulating files) from a full-rebuild one (a single
    file, rewritten). That distinction is the whole reason file counts here are 1.

Emitting JSON is deliberate: Phase 5's observability dashboard needs a series, and a
series needs the same measurement taken twice. Printing only a table would make this
a one-shot report.
"""
import argparse, json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import dbsql  # noqa: E402

# DESCRIBE DETAIL is a statement, not a table-valued function, so `SELECT numFiles
# FROM (DESCRIBE DETAIL t)` is a parse error and the columns must be taken by
# position. Guessing these indices wrongly the first time produced a table of
# timestamps labelled numFiles -- a wrong answer that looked like a working query.
DETAIL = {"partitionColumns": 7, "clusteringColumns": 8, "numFiles": 9, "sizeInBytes": 10,
          "tableFeatures": 14, "clusterByAuto": 16}
# DESCRIBE HISTORY: version 0, timestamp 1, userId 2, userName 3, operation 4.
# Index 5 is operationParameters -- grouping by it produced one "operation" per
# distinct JSON blob, so every table looked like a full rebuild.
HIST_VERSION, HIST_OP = 0, 4

# Time travel is refused by THREE different error classes, one per protection
# combination, and the two-protection one is not a superstring of either single
# one: note COLUMN_MASK (singular) below versus COLUMN_MASKS in the mask-only
# class. Matching has to be explicit, most specific first.
TT_REFUSALS = [
    ("ROW_LEVEL_SECURITY_COLUMN_MASK_FEATURE_NOT_SUPPORTED", "no: mask + row filter"),
    ("COLUMN_MASKS_FEATURE_NOT_SUPPORTED", "no: column mask"),
    ("ROW_LEVEL_SECURITY_FEATURE_NOT_SUPPORTED", "no: row filter"),
    ("BEYOND_DELETED_FILE_RETENTION", "no: retention"),
]


def as_list(v):
    """DESCRIBE DETAIL returns array columns as a JSON STRING: '[]' or '["dept"]'.

    Splitting the string on commas leaves the quotes attached, so a clustered
    column printed as "dept" with literal quote marks.
    """
    if isinstance(v, list):
        return v
    s = (v or "").strip()
    if not s:
        return []
    try:
        parsed = json.loads(s)
        return parsed if isinstance(parsed, list) else [str(parsed)]
    except (ValueError, TypeError):
        return [x.strip().strip('"\'') for x in s.strip("[]").split(",") if x.strip()]


def q(fq):
    """Backtick each part of catalog.schema.table.

    Without this, any identifier needing quoting (a hyphen, a keyword) fails
    DESCRIBE DETAIL with INVALID_IDENTIFIER -- and the resulting record then has
    no clusteringColumns key, so a clustered table read as UNCLUSTERED to the
    caller. A per-table read failure must never look like a clean result.
    """
    return ".".join("`" + part.replace("`", "``") + "`" for part in fq)


def rows(stmt, profile, wh):
    ok, res = dbsql.run(stmt, profile=profile, wh=wh)
    if not ok:
        return None, str(res)
    return res.get("data_array") or [], None


def measure(cat, profile, wh):
    tables, err = rows(
        "SELECT table_schema, table_name FROM "
        f"{cat}.information_schema.tables "
        # NOT LIKE '%VIEW%', not != 'VIEW'. A metric view's table_type is METRIC_VIEW, so
        # an equality test let it through -- and DESCRIBE DETAIL rejects it with
        # EXPECT_TABLE_NOT_VIEW.NO_ALTERNATIVE, which A7 correctly reported as an
        # unmeasurable table. Phase 4 added an object type this listing predated; A7
        # caught it because it treats "could not measure" as a failure rather than as
        # "not clustered". A view has no Delta files, so it belongs out of scope here.
        "WHERE table_schema <> 'information_schema' AND table_type NOT LIKE '%VIEW%' "
        "ORDER BY table_schema, table_name", profile, wh)
    if tables is None:
        sys.exit(f"cannot list tables in {cat}: {err}")

    if not tables:
        # A SUCCEEDING listing with zero rows is not an empty catalog -- UC filters
        # information_schema by privilege, so a principal with no grants sees this.
        # Returning [] made every "no table does X" check pass vacuously.
        sys.exit(f"{cat} lists no tables -- wrong catalog, or no privileges on it")

    out = []
    for schema, name in tables:
        fq = f"{cat}.{schema}.{name}"
        rec = {"schema": schema, "table": name}

        detail, err = rows(f"DESCRIBE DETAIL {q((cat, schema, name))}", profile, wh)
        if detail:
            d = detail[0]
            for k, i in DETAIL.items():
                v = d[i]
                if k in ("numFiles", "sizeInBytes"):
                    rec[k] = int(v) if v else 0
                else:
                    rec[k] = as_list(v)
        else:
            rec["error"] = err or "DESCRIBE DETAIL returned no rows"

        hist, err = rows(f"DESCRIBE HISTORY {q((cat, schema, name))}", profile, wh)
        if hist:
            ops = {}
            for h in hist:
                ops[h[HIST_OP]] = ops.get(h[HIST_OP], 0) + 1
            rec["versions"] = len(hist)
            rec["oldest_version"] = int(hist[-1][HIST_VERSION])
            rec["operations"] = ops
            # A WRITE (append) means the model is incremental, so its file count
            # rises with each build. A table whose history is only CREATE OR REPLACE
            # is rewritten whole and can never accumulate files -- which is why
            # OPTIMIZE has nothing to do here.
            #
            # Having BOTH is normal and still counts as accumulating: bronze shows
            # WRITE + CREATE OR REPLACE because `dbt build --full-refresh` rewrites
            # an incremental model. Requiring the absence of CREATE OR REPLACE
            # reported every table as a full rebuild.
            # NOT `"WRITE" in ops`. Retained history is up to 30 days, so a single
            # historical append -- a failure-injection test, a one-off backfill --
            # made a full-rebuild model report as accumulating forever. gold is
            # `materialized: table` and carries a WRITE from the emptied-gold test.
            # The current strategy is whatever the most recent commits do, so judge
            # on the latest write and ignore maintenance ops that either
            # materialization performs.
            MAINT = {"OPTIMIZE", "VACUUM START", "VACUUM END", "RESTORE",
                     "SET TBLPROPERTIES", "ADD COLUMNS", "CHANGE COLUMN"}
            builds = [h[HIST_OP] for h in hist if h[HIST_OP] not in MAINT]
            rec["last_build_op"] = builds[0] if builds else None
            rec["accumulates_files"] = rec["last_build_op"] == "WRITE"

        # Ask the engine, do not infer. A mask or row filter disables time travel,
        # and nothing in DESCRIBE DETAIL says so.
        else:
            rec["versions"] = None
            rec["history_error"] = err or "DESCRIBE HISTORY returned no rows"

        oldest = rec.get("oldest_version") or 0
        _, tt_err = rows(f"SELECT 1 FROM {q((cat, schema, name))} VERSION AS OF {oldest} LIMIT 1",
                         profile, wh)
        if tt_err is None:
            rec["time_travel"] = "yes"
        else:
            rec["time_travel"] = next(
                (label for token, label in TT_REFUSALS if token in tt_err),
                "no: " + " ".join(tt_err.split())[:70])

        out.append(rec)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog", nargs="?")
    ap.add_argument("--profile", default=os.environ.get("DBX_PROFILE", "free"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    cat = a.catalog or os.environ.get("DBX_CATALOG")
    if not cat:
        sys.exit("give a catalog or set DBX_CATALOG")
    wh = dbsql.warehouse_id(a.profile)
    recs = measure(cat, a.profile, wh)

    if a.json:
        print(json.dumps({"catalog": cat, "tables": recs}, indent=2))
        return

    print(f"\ndelta layout — {cat}\n")
    print(f"  {'table':<44}{'files':>6}{'bytes':>10}{'vers':>6}  "
          f"{'cluster':<10}{'grows':<7}time travel")
    print("  " + "-" * 104)
    tot_f = tot_b = 0
    errors = 0
    for r in recs:
        if r.get("error") or r.get("history_error"):
            errors += 1
            msg = " ".join(str(r.get("error") or r.get("history_error")).split())
            print(f"  {r['schema']+'.'+r['table']:<44}  ERROR {msg[:52]}")
            continue
        tot_f += r.get("numFiles") or 0
        tot_b += r.get("sizeInBytes") or 0
        cl = ",".join(r.get("clusteringColumns") or [])
        if not cl and str(r.get("clusterByAuto")).lower() == "true":
            cl = "AUTO"       # CLUSTER BY AUTO leaves clusteringColumns empty
        cl = cl or "—"
        print(f"  {r['schema']+'.'+r['table']:<44}{r.get('numFiles', 0):>6}"
              f"{r.get('sizeInBytes', 0):>10}{r.get('versions', 0):>6}  "
              f"{cl:<10}{('yes' if r.get('accumulates_files') else 'no'):<7}"
              f"{r.get('time_travel', '?')}")
    print("  " + "-" * 104)
    print(f"  {'total':<44}{tot_f:>6}{tot_b:>10}")
    if errors:
        print(f"\n  {errors} table(s) could not be measured -- counted in neither total.")
    print()
    print("  grows = the LATEST build commit is an append, so file count rises per build.")
    print("  A table whose history is only CREATE OR REPLACE is rewritten whole and")
    print("  cannot accumulate files -- which is why OPTIMIZE has nothing to compact")
    print("  here today. See T1 in .plan/phase-3-delta/validation.md\n")


if __name__ == "__main__":
    main()
