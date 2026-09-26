#!/usr/bin/env bash
# Assert the semantic layer is real AND that it did not widen access.
#
#   ./infra/semantic/verify.sh              # the catalog from .envrc
#   ./infra/semantic/verify.sh hr_review
#
# The assertion that matters most is S5. A view inherits the controls of the securables
# it READS -- measured: a plain view over the row-filtered gold table passes the filter
# through, evaluated as the CALLER. The first mv_hr_workforce nonetheless handed
# biz-analyst all 478 employees, because it reads silver_hr_employee, which carries NO
# row filter; Phase 2 bound filter_dept to gold_hr_headcount_by_department, a different
# table. It read AROUND the control rather than dropping it. Masks did come through,
# which is what made it look governed. S5 is the regression test for that bypass.
#
# Every assertion below is written to be capable of failing, and the command that
# turns each one red is recorded in .plan/phase-4-semantic-genie/validation.md
# (CLAUDE.md: "seen failing" is not enough -- record the command).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a
CAT="${1:-${DBX_CATALOG}}"
MV="${CAT}.gold.mv_hr_workforce"
pass=0; fail=0

# The expected assertion count, declared HERE so the non-primary-catalog branch can lower
# it. It used to be set AFTER that branch, silently overwriting the lower value -- which
# made `verify.sh hr_review` fail with "ran 13, expected 17" even when every assertion it
# ran had passed. A guard that misfires is worse than none: it reported a problem that did
# not exist while the real skip count went unchecked.
EXPECTED=17

# val() is always called inside $( ), a SUBSHELL, so assigning a variable here can never
# reach the caller. The first version set LAST_ERR and printed it on failure -- that branch
# could never fire, and every empty-value FAIL was undiagnosable. A temp FILE survives.
ERRFILE="$(mktemp)"; trap 'rm -f "${ERRFILE}"' EXIT

val() {  # val <sql> [--as alias]  -> first cell of first row
  local out; out="$(python3 "${ROOT}/infra/dbsql.py" "${@:2}" "$1" 2>&1)"
  printf '%s' "${out}" | tr '\n' ' ' | cut -c1-200 > "${ERRFILE}"
  # Python repr quotes with ' normally but " when the value contains an apostrophe, so
  # accept both -- "O'Brien" used to read as empty and look like a broken query.
  # Two expressions, one per quote style. A single character class with \x27 in it does
  # NOT work under BSD sed (macOS) -- it silently matched nothing, so val() returned empty
  # for every value and would have turned every assertion red. Caught by testing the
  # parser on fixtures before trusting it.
  printf '%s' "${out}" |
    sed -n "s/^ *\['\([^']*\)'.*/\1/p; s/^ *\[\"\([^\"]*\)\".*/\1/p" | head -1
}
# A measure that returns NULL prints as [None], which val() cannot match -- so a
# masked value and a failed query would both read as "". Distinguish them.
# The row must be EXACTLY [None]. Matching ", None" anywhere passed for any row with a
# NULL in any column -- fine for today's single-column call, a trap the moment someone
# adds a column. The `ok*` guard is what stops a FAILED query reading as a successful mask.
is_null() {  # is_null <sql> [--as alias]
  local out; out="$(python3 "${ROOT}/infra/dbsql.py" "${@:2}" "$1" 2>&1)"
  [[ "${out}" == ok* ]] && printf '%s' "${out}" | grep -qE "^ *\[None\]$"
}
check() {
  if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else
    printf '  FAIL  %s\n          expected %s, got %s\n' "$1" "$3" "${2:-<empty>}"
    [[ -z "$2" && -s "${ERRFILE}" ]] && printf '          last output: %s\n' "$(cat "${ERRFILE}")"
    fail=$((fail+1))
  fi
}
yes_no() {
  if "${@:2}"; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); fi
}

echo "semantic layer assertions against ${CAT}"

# S1. The metric view exists AS A METRIC VIEW. Checking only that the name resolves
#     would pass for an ordinary view, which would silently lose measure().
check "mv_hr_workforce exists and is a METRIC_VIEW" \
  "$(val "SELECT table_type FROM ${CAT}.information_schema.tables
           WHERE table_schema='gold' AND table_name='mv_hr_workforce'")" "METRIC_VIEW"

# S2. The three competing definitions are live and DIFFERENT. Equality against the
#     documented numbers, not "it returned something": a view that lost its filter
#     would still answer, with a bigger number.
check "headcount_people = 478"    "$(val "SELECT measure(headcount_people) FROM ${MV}")"   "478"
check "headcount_fte = 447.0"     "$(val "SELECT measure(headcount_fte) FROM ${MV}")"      "447.0"
check "headcount_fulltime = 416"  "$(val "SELECT measure(headcount_fulltime) FROM ${MV}")" "416"

# S3. They must actually disagree. If a future edit made two measures identical the
#     numbers above could all still pass while the LESSON evaporated.
check "the three definitions are mutually distinct" \
  "$(val "SELECT CASE WHEN measure(headcount_people) <> measure(headcount_fte)
                       AND measure(headcount_fte) <> measure(headcount_fulltime)
                       AND measure(headcount_people) <> measure(headcount_fulltime)
                      THEN 'yes' ELSE 'no' END FROM ${MV}")" "yes"

# S4. No measure is named so vaguely that using it constitutes a silent decision.
#     A bare `headcount` is the data team choosing on the business's behalf.
#
#     SCOPED TO THE WHOLE `gold` SCHEMA, not just the metric view. The first version
#     checked only mv_hr_workforce -- while gold_hr_headcount_by_department had a column
#     literally named `headcount`, and this very script read `sum(headcount)` from it.
#     The rule was asserted only where it already held. Column renamed; assertion widened.
check "no gold column is an ambiguous metric name" \
  "$(val "SELECT CASE WHEN count(*) = 0 THEN 'yes'
                      ELSE concat_ws(',', collect_list(concat(table_name,'.',column_name))) END
            FROM ${CAT}.information_schema.columns
           WHERE table_schema='gold'
             AND lower(column_name) IN ('headcount','people','staff','employees','count','fte')")" "yes"

# S5. *** THE BYPASS TEST *** The semantic layer must not widen access.
#     biz-analyst is denied silver entirely and sees 2 of 16 departments on the gold
#     table. Through the metric view they must see the SAME 70 people -- not 478.
check "biz-analyst sees only its permitted departments through the layer" \
  "$(val "SELECT measure(headcount_people) FROM ${MV}" --as biz-analyst)" "70"
# coalesce both sides: a principal with NO department mapping gets 0 from the metric view
# but NULL from sum() over zero visible rows, and 0 = NULL is NULL, not false -- so a
# correctly locked-out caller would have failed this. It conflated "wrong" with "sees nothing".
check "biz-analyst's layer total equals its gold-table total" \
  "$(val "SELECT CASE WHEN coalesce((SELECT measure(headcount_people) FROM ${MV}), 0)
                         = coalesce((SELECT sum(headcount_people) FROM ${CAT}.gold.gold_hr_headcount_by_department), 0)
                      THEN 'yes' ELSE 'no' END" --as biz-analyst)" "yes"

# S6. Column masks DO carry through a view, and must keep doing so. A restricted
#     caller gets NULL, not a number -- and NULL is the correct answer here, so this
#     asserts nullness explicitly rather than treating "" as success.
yes_no "salary is masked to NULL for hr-analyst through the layer" \
  is_null "SELECT measure(salary_total) FROM ${MV}" --as hr-analyst
check "salary is NOT masked for the owner role" \
  "$(val "SELECT CASE WHEN measure(salary_total) > 0 THEN 'yes' ELSE 'no' END FROM ${MV}")" "yes"

# S9. Every measure carries a description IN UNITY CATALOG. This was claimed as delivered
#     and did not exist -- all comments were NULL -- so it is asserted rather than trusted.
#     Two of the three ways to document a metric view fail SILENTLY: `persist_docs` is not
#     called by the metric_view materialization, and the YAML has no `comment` field. Only
#     an explicit COMMENT ON works, so only reading information_schema proves it.
#     Phase 7's DataHub glossary is generated from these.
check "every gold measure has a description in Unity Catalog" \
  "$(val "SELECT CASE WHEN count(*) = 0 THEN 'yes'
                      ELSE concat_ws(',', collect_list(concat(table_name,'.',column_name))) END
            FROM ${CAT}.information_schema.columns
           WHERE table_schema='gold'
             AND (column_name LIKE 'headcount%' OR column_name LIKE 'salary%'
                  OR column_name LIKE '%count')
             AND (comment IS NULL OR length(trim(comment)) < 10)")" "yes"

# S7-S8 are WORKSPACE-SCOPED, not per-catalog. There is one Genie space and one
# dashboard per workspace, and they point at the PRIMARY catalog. Asserting them while
# verifying a review catalog asserts the wrong thing -- it failed exactly that way
# first, which is the same mistake Phase 3's A6 made (a catalog-dependent check on a
# decision that is not catalog-dependent). Skipped unless this IS the primary catalog.
# Only the DATA-SOURCE and dashboard checks are catalog-dependent. The instruction-text
# check is not -- and it guards the one piece of configuration the headline experiment
# depends on, so skipping it left that unverified on every review run.
PRIMARY_ONLY=0
if [[ "${CAT}" != "${DBX_CATALOG}" ]]; then
  PRIMARY_ONLY=1
  EXPECTED=13   # 17 minus the four catalog-specific Genie/dashboard checks
  echo "  --    catalog-specific Genie/dashboard assertions SKIPPED"
  echo "        (workspace singletons bound to ${DBX_CATALOG}; the instruction check still runs)"
fi

# S7. The Genie space exists, is wired to the METRIC VIEW rather than to raw tables,
#     and carries the instruction that forbids a silent pick. Without that
#     instruction the headline experiment is not reproducible.
SPACE="$(python3 "${ROOT}/infra/semantic/10-genie-space.py" --show 2>/dev/null)"
check "a Genie space named 'HR Workforce' exists" "${SPACE:+yes}" "yes"
if [[ -n "${SPACE}" ]]; then
  SS="$(databricks api get "/api/2.0/genie/spaces/${SPACE}?include_serialized_space=true" \
        --profile "${DBX_PROFILE:-free}" 2>/dev/null)"
  if [[ ${PRIMARY_ONLY} -eq 0 ]]; then
  check "the space's data source is the metric view, not a raw table" \
    "$(printf '%s' "${SS}" | python3 -c "
import sys, json
try:
    ss = json.loads(json.load(sys.stdin)['serialized_space'])
except Exception:
    print('unreadable'); raise SystemExit
ids = [t.get('identifier','') for t in ss.get('data_sources',{}).get('tables',[])]
print('yes' if ids == ['${CAT}.gold.mv_hr_workforce'] else ','.join(ids) or 'none')")" "yes"
  fi
  check "the space instructs Genie not to choose a headcount silently" \
    "$(printf '%s' "${SS}" | python3 -c "
import sys, json
try:
    ss = json.loads(json.load(sys.stdin)['serialized_space'])
except Exception:
    print('unreadable'); raise SystemExit
txt = ' '.join(c for b in ss.get('instructions',{}).get('text_instructions',[])
                 for c in b.get('content',[])).lower()
need = ['headcount_people', 'headcount_fte', 'headcount_fulltime']
print('yes' if all(n in txt for n in need) and 'must not silently choose' in txt else 'no')")" "yes"
fi

# S8. The dashboard exists and every dataset reads the METRIC VIEW. A tile computing
#     its own COUNT would be the semantic layer failing at its only job -- it could
#     then disagree with Genie about the same word.
if [[ ${PRIMARY_ONLY} -eq 0 ]]; then
DASH="$(python3 "${ROOT}/infra/semantic/20-dashboard.py" --show 2>/dev/null)"
check "an AI/BI dashboard named 'HR Workforce' exists" "${DASH:+yes}" "yes"
if [[ -n "${DASH}" ]]; then
  check "every dashboard dataset reads the metric view" \
    "$(databricks api get "/api/2.0/lakeview/dashboards/${DASH}" \
         --profile "${DBX_PROFILE:-free}" 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.loads(json.load(sys.stdin)['serialized_dashboard'])
except Exception:
    print('unreadable'); raise SystemExit
ds = d.get('datasets') or []
# An EMPTY dataset list used to satisfy this check, because an all-clear is vacuous
# when there is nothing to check -- a dashboard with no tiles at all passed. Require
# the expected shape, not merely the absence of a counter-example.
# NOTE: no quotes or backticks in these comments. This block is inside a bash
# double-quoted command substitution, so both would break out of the string.
if len(ds) < 3:
    print('only %d dataset(s); expected 3' % len(ds)); raise SystemExit
tiles = sum(len(p.get('layout') or []) for p in (d.get('pages') or []))
if tiles < 5:
    print('only %d tile(s); expected 5' % tiles); raise SystemExit
bad = [x.get('name', '?') for x in ds
       if 'mv_hr_workforce' not in ' '.join(x.get('queryLines', []))
       or 'measure(' not in ' '.join(x.get('queryLines', []))]
print('yes' if not bad else 'not via the layer: ' + ','.join(bad))")" "yes"

  # F16: an unpublished draft nobody else can open, or one published with the API's
  # DEFAULT embed_credentials=true, silently defeats per-viewer governance -- every
  # viewer's tiles would run as the publisher, reinstating the S5 bypass one click later.
  check "the dashboard is published WITHOUT embedded credentials" \
    "$(databricks api get "/api/2.0/lakeview/dashboards/${DASH}/published" \
         --profile "${DBX_PROFILE:-free}" 2>/dev/null | python3 -c "
import sys, json
try:
    p = json.load(sys.stdin)
except Exception:
    print('not published'); raise SystemExit
print('yes' if p.get('embed_credentials') is False else 'embed_credentials=%r' % p.get('embed_credentials'))")" "yes"
fi
fi

# Gated sub-assertions (behind a non-empty SPACE / DASH) used to silently DISAPPEAR if a
# --show returned empty, and the run just looked shorter. Pin the total so a missing
# assertion is itself a failure. EXPECTED is set at the top and lowered by the skip branch.
total=$((pass+fail))
if [[ ${total} -ne ${EXPECTED} ]]; then
  printf '  FAIL  ran %d assertions, expected %d -- some were skipped silently\n' \
    "${total}" "${EXPECTED}"
  fail=$((fail+1))
fi

printf '\n  %d passed, %d failed\n' "${pass}" "${fail}"
[[ ${fail} -eq 0 ]]
