#!/usr/bin/env bash
# Assert the Delta design rules recorded in .plan/phase-3-delta/ are in force.
#
#   ./infra/delta/verify.sh              # the catalog from .envrc
#   ./infra/delta/verify.sh hr_review
#
# Assertion numbers here are the ones used in .plan/phase-3-delta/validation.md.
#
# WHAT EACH ONE IS WORTH, stated honestly because the previous phase shipped four
# assertions that could not fail:
#   A1, A3, A4, A6, A7  -- can fail from a repo-side change. These earn their keep.
#   A2                  -- can fail from a repo-side change (see its note).
#   A5                  -- CANNOT fail from anything we control; it asserts a
#                          Databricks invariant. Kept as a platform-regression
#                          tripwire, NOT as a guard on our own work. Independent
#                          review called it a tautology by this project's standard
#                          and that is fair.
#
# An earlier header here claimed "several assertions would pass against an absent
# catalog". Measured: none do -- all of them fail against a nonexistent catalog.
# The claim overstated what A1 guards, so it is withdrawn.
#
# T1 and T2 in validation.md are NOT here: they need many Delta files, which needs
# real incremental builds. Deferred by P9.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a
CAT="${1:-${DBX_CATALOG}}"
pass=0; fail=0

# First cell of the first row, or "" on error. Degrades to "" for a NULL, an empty
# string, and a value containing a quote -- all safe directions (the check fails),
# but indistinguishable from each other, so the error text is kept for diagnosis.
LAST_ERR=""
val() {
  local out; out="$(python3 "${ROOT}/infra/dbsql.py" "$1" 2>&1)"
  LAST_ERR="$(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-160)"
  printf '%s' "${out}" | sed -n "s/^ *\['\([^']*\)'.*/\1/p" | head -1
}
# Refused for a SPECIFIC reason. Requires a NON-ZERO exit as well as the token:
# dbsql.py echoes the submitted SQL back inside parse errors, so a statement that
# merely MENTIONS the token -- or succeeds -- could otherwise satisfy this.
refused_with() {
  local out rc
  out="$(python3 "${ROOT}/infra/dbsql.py" "$1" 2>&1)"; rc=$?
  [[ ${rc} -ne 0 && "${out}" == *"$2"* ]]
}
check() {
  if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n          expected %s, got %s\n' "$1" "$3" "${2:-<empty>}"
    [[ -z "$2" && -n "${LAST_ERR}" ]] && printf '          last output: %s\n' "${LAST_ERR}"
    fail=$((fail+1))
  fi
}
yes_no() {
  if "${@:2}"; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "delta design assertions against ${CAT}"

# A1. The catalog is reachable and populated.
check "catalog reachable and bronze populated" \
  "$(val "SELECT CASE WHEN count(*) > 0 THEN 'yes' ELSE 'no' END FROM ${CAT}.bronze.bronze_hr_employee")" "yes"

# A2. Time travel WORKS where nothing is protected, and the oldest retained version
#     is a subset of today.
#
#     The first version compared v0's row count for EQUALITY with today's. Two
#     problems, both found by review: a DROP + CREATE resets versioning to 0, so the
#     rebuild IS v0 and the counts trivially match -- it could not catch the state
#     its comment claimed; and it would go RED as a false alarm the moment T1's real
#     incremental deliveries land, because then v0 legitimately holds fewer rows.
#
#     So: assert reachability, and assert the oldest version is no LARGER than today.
#     Anchored to the oldest RETAINED version rather than a hard-coded 0, which
#     survives log expiry.
#     VERSION AS OF takes a LITERAL -- a subquery is a parse error -- so the oldest
#     retained version is resolved first and interpolated.
MIN_V="$(val "SELECT min(version) FROM (DESCRIBE HISTORY ${CAT}.bronze.bronze_hr_employee)")"
check "bronze's oldest retained version is resolvable" "${MIN_V:+yes}" "yes"
yes_no "bronze time travel is reachable at version ${MIN_V:-?}" \
  bash -c "python3 '${ROOT}/infra/dbsql.py' \"SELECT 1 FROM ${CAT}.bronze.bronze_hr_employee VERSION AS OF ${MIN_V:--1} LIMIT 1\" >/dev/null 2>&1"
check "bronze at v${MIN_V:-?} holds no more rows than today" \
  "$(val "SELECT CASE WHEN (SELECT count(*) FROM ${CAT}.bronze.bronze_hr_employee VERSION AS OF ${MIN_V:--1})
                        <= (SELECT count(*) FROM ${CAT}.bronze.bronze_hr_employee)
               THEN 'yes' ELSE 'no' END")" "yes"

# A3-A4. Protection costs time travel, and the error class names WHICH protection.
#        Three classes exist; the two-protection one is not a superstring of either
#        single one (COLUMN_MASK singular vs COLUMN_MASKS plural), so matching the
#        wrong string here silently passes.
yes_no "silver.silver_hr_employee refuses time travel: column mask" \
  refused_with "SELECT 1 FROM ${CAT}.silver.silver_hr_employee VERSION AS OF 0" \
  "COLUMN_MASKS_FEATURE_NOT_SUPPORTED.TIME_TRAVEL"
yes_no "gold refuses time travel: mask AND row filter (combined class)" \
  refused_with "SELECT 1 FROM ${CAT}.gold.gold_hr_headcount_by_department VERSION AS OF 0" \
  "ROW_LEVEL_SECURITY_COLUMN_MASK_FEATURE_NOT_SUPPORTED.TIME_TRAVEL"

# A5. DESCRIBE HISTORY survives protection -- the log is intact, only reading an old
#     version is refused. PLATFORM INVARIANT: nothing in this repo can break it, so
#     it is a tripwire on Databricks, not a guard on us. See the header.
check "history is readable on a protected table" \
  "$(val "SELECT CASE WHEN count(*) > 0 THEN 'yes' ELSE 'no' END FROM (DESCRIBE HISTORY ${CAT}.silver.silver_hr_employee)")" "yes"

# A6. The materializations are what file counts depend on: bronze appends (so it CAN
#     accumulate files), silver is rewritten whole (so it never can). If bronze were
#     switched to `table`, T1 becomes unrunnable -- this is the early warning.
#
#     Asserted against dbt_project.yml, NOT against table history. Two earlier
#     versions were wrong:
#      1. `WRITE anywhere in history` -- history is retained ~30 days, so one stale
#         append made a rewrite-only table pass forever, and a single
#         failure-injection test on gold made a `table` model look incremental;
#      2. `the latest build commit is WRITE` -- catalog-dependent. It passes on `hr`
#         but FAILS on a freshly built `hr_review`, because review-env.sh only ever
#         full-refreshes, so no append has happened there yet. A correct observation
#         of the wrong thing.
#
#     The invariant T1 actually depends on is the DECLARED materialization, which is
#     a repo fact and identical for every catalog. The observed history is reported
#     by measure.py as information, not asserted here.
YML="${ROOT}/pipelines/dbt/dbt_project.yml"
declared() {  # declared <layer> -> the +materialized under that layer
  python3 - "$YML" "$1" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^    %s:\n(.*?)(?=^    \S|\Z)' % re.escape(sys.argv[2]),
              text, re.M | re.S)
if not m:
    print(""); raise SystemExit
mm = re.search(r'^\s*\+materialized:\s*(\S+)', m.group(1), re.M)
print(mm.group(1) if mm else "")
PY
}
check "bronze is declared incremental (T1 depends on it)" "$(declared bronze)" "incremental"
check "silver is declared table" "$(declared silver)" "table"
check "gold is declared table" "$(declared gold)" "table"

# A7. THE ONE THAT GUARDS A DECISION OF OURS. Declaring clustering in dbt config also
#     makes the adapter run OPTIMIZE after every build of that model -- a real cost,
#     adopted by accident. The recorded decision is not to declare it while tables
#     are one file; this asserts the decision is still in force.
#
#     Three earlier versions of this check were defective, each found by review:
#      1. read information_schema.columns.partition_index -- NULL even for a
#         clustered column, so it could never fail;
#      2. read only clusteringColumns -- blind to CLUSTER BY AUTO (dbt's
#         `auto_liquid_cluster`), which leaves that empty, sets clusterByAuto=true,
#         and triggers the SAME per-build OPTIMIZE;
#      3. treated a per-table measurement FAILURE as "not clustered", so a table
#         whose DESCRIBE DETAIL errored read as clean.
#     It now fails on explicit keys, on AUTO, on the `clustering` table feature, and
#     on any table it could not measure. `zorder` is a dbt-side config with no
#     server-side trace, so it is covered by code review, not by this check.
check "no dbt table declares clustering (explicit, AUTO, or feature)" \
  "$(python3 "${ROOT}/infra/delta/measure.py" "${CAT}" --json 2>/dev/null |
     python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print('measure.py produced no usable output: %s' % e); raise SystemExit
ts = [t for t in d['tables'] if t['schema'] in ('bronze', 'silver', 'gold')]
if not ts:
    print('no bronze/silver/gold tables found'); raise SystemExit
bad = []
for t in ts:
    nm = t['schema'] + '.' + t['table']
    if t.get('error') or t.get('history_error'):
        bad.append(nm + '(unmeasurable)')
    elif (t.get('clusteringColumns')
          or str(t.get('clusterByAuto')).lower() == 'true'
          or 'clustering' in (t.get('tableFeatures') or [])):
        bad.append(nm)
print('yes' if not bad else 'clustered: ' + ','.join(bad))
")" "yes"

printf '\n  %d passed, %d failed\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]
