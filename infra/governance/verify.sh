#!/usr/bin/env bash
# Assert the governance controls are in force. Exit non-zero if any is not.
#
#   ./infra/governance/verify.sh              # the catalog from .envrc
#   ./infra/governance/verify.sh hr_review    # a throwaway copy
#
# Every assertion here is written so that it CAN fail, and each has been seen failing
# -- see .plan/phase-2-governance/validation.md §C. An assertion nobody has watched go
# red is decoration; Phase 1's review found three of those, and Phase 2's review found
# four more of mine: assertions that counted rows instead of checking identity, that
# passed on an empty table, that passed when a filter denied EVERYTHING, and one that
# passed when the catalog did not exist.
#
# The difference between this and a dbt test: these run as SEVERAL principals. A
# control is not "SELECT works", it is "SELECT returns different things to different
# people", and a single-identity test cannot express that.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a
CAT="${1:-${DBX_CATALOG}}"
P="${DBX_PROFILE:-free}"
pass=0; fail=0

val() {  # val <sql> [--as alias]   -> first cell of first row, or "" on error
  python3 "${ROOT}/infra/dbsql.py" "${@:2}" "$1" 2>/dev/null |
    sed -n "s/^ *\['\([^']*\)'.*/\1/p" | head -1
}

# Whether a statement was refused FOR LACK OF PRIVILEGE -- not merely "failed".
# Keying on the substring FAIL made this pass for a stopped warehouse, a typo'd
# table, or a catalog that does not exist: `verify.sh hr_does_not_exist` reported
# "biz-analyst denied on silver" as PASS. The error class has to be the right one.
denied() {
  local out; out="$(python3 "${ROOT}/infra/dbsql.py" "${@:2}" "$1" 2>&1)"
  [[ "${out}" == *"INSUFFICIENT_PERMISSIONS"* || "${out}" == *"PERMISSION_DENIED"* ]]
}
check() {  # check <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then printf '  PASS  %s\n' "$1"; pass=$((pass+1))
  else printf '  FAIL  %s\n          expected %s, got %s\n' "$1" "$3" "${2:-<empty>}"; fail=$((fail+1)); fi
}

echo "governance assertions against ${CAT}"

# 0. The catalog exists and holds the data. Everything below is meaningless otherwise,
#    and several assertions below would pass against an empty or absent catalog.
check "catalog reachable and silver populated" \
  "$(val "SELECT CASE WHEN count(*) > 0 THEN 'yes' ELSE 'no' END FROM ${CAT}.silver.silver_hr_employee")" "yes"

# 1-2. The bindings exist, BY IDENTITY. Counting rows let a mask on the wrong column,
#      or bound through the wrong function, satisfy the assertion.
check "mask on silver.salary_annual is mask_salary" \
  "$(val "SELECT mask_name FROM ${CAT}.information_schema.column_masks WHERE table_schema='silver' AND table_name='silver_hr_employee' AND column_name='salary_annual'")" \
  "${CAT}.governance.mask_salary"
check "mask on silver.email is mask_email" \
  "$(val "SELECT mask_name FROM ${CAT}.information_schema.column_masks WHERE table_schema='silver' AND table_name='silver_hr_employee' AND column_name='email'")" \
  "${CAT}.governance.mask_email"
check "mask on gold.total_salary is mask_salary_total" \
  "$(val "SELECT mask_name FROM ${CAT}.information_schema.column_masks WHERE table_schema='gold' AND column_name='total_salary'")" \
  "${CAT}.governance.mask_salary_total"
check "mask on gold.avg_salary is mask_salary_avg" \
  "$(val "SELECT mask_name FROM ${CAT}.information_schema.column_masks WHERE table_schema='gold' AND column_name='avg_salary'")" \
  "${CAT}.governance.mask_salary_avg"
check "row filter on gold is filter_dept(dept_id)" \
  "$(val "SELECT concat(filter_name,' ON ',target_columns) FROM ${CAT}.information_schema.row_filters WHERE table_schema='gold' AND table_name='gold_hr_headcount_by_department'")" \
  "${CAT}.governance.filter_dept ON dept_id"

# 3. The row filter shows EXACTLY the departments the access map grants. Asserting
#    only "fewer than the steward" passed when the filter denied everything -- an
#    empty access map, or an SP re-created with a new applicationId, gives 0 < 16.
EXPECTED_DEPTS="$(val "SELECT count(DISTINCT dept_id) FROM ${CAT}.governance.dept_access")"
check "biz-analyst sees exactly its ${EXPECTED_DEPTS} mapped departments" \
  "$(val "SELECT count(*) FROM ${CAT}.gold.gold_hr_headcount_by_department" --as biz-analyst)" "${EXPECTED_DEPTS}"
# The two sides are read by DIFFERENT identities and compared here, because
# biz-analyst cannot read the access map -- definer rights apply inside the filter
# function, not to a query the caller writes. Asking biz-analyst to join against
# governance.dept_access returned an error, and the assertion read that as a pass.
MAPPED_IDS="$(val "SELECT array_join(array_sort(array_agg(DISTINCT cast(dept_id AS STRING))), ',') FROM ${CAT}.governance.dept_access")"
VISIBLE_IDS="$(val "SELECT array_join(array_sort(array_agg(DISTINCT cast(dept_id AS STRING))), ',') FROM ${CAT}.gold.gold_hr_headcount_by_department" --as biz-analyst)"
check "biz-analyst sees exactly the mapped dept_ids (${MAPPED_IDS})" "${VISIBLE_IDS}" "${MAPPED_IDS}"
check "steward sees more departments than biz-analyst" \
  "$(val "SELECT CASE WHEN count(*) > ${EXPECTED_DEPTS:-0} THEN 'yes' ELSE 'no' END FROM ${CAT}.gold.gold_hr_headcount_by_department")" "yes"

# 4. The masks mask. Each paired with a positive control, because "0 non-null" is also
#    what an empty table returns -- assertion 0 guards the table, these guard the
#    direction: the same column must be readable by somebody.
check "silver salary is NULL for hr-analyst" \
  "$(val "SELECT count(salary_annual) FROM ${CAT}.silver.silver_hr_employee" --as hr-analyst)" "0"
check "silver salary is visible to the steward" \
  "$(val "SELECT CASE WHEN count(salary_annual) > 0 THEN 'yes' ELSE 'no' END FROM ${CAT}.silver.silver_hr_employee")" "yes"
check "silver salary is visible to the pipeline (or gold silently zeroes)" \
  "$(val "SELECT CASE WHEN count(salary_annual) > 0 THEN 'yes' ELSE 'no' END FROM ${CAT}.silver.silver_hr_employee" --as dbx)" "yes"
check "silver email is redacted for hr-analyst" \
  "$(val "SELECT DISTINCT split(email,'@')[0] FROM ${CAT}.silver.silver_hr_employee WHERE email IS NOT NULL" --as hr-analyst)" "***"

# 5. Gold's compensation aggregates. hr_analysts is exempt from the ROW filter, so
#    without these masks the role the masks exist to restrict read every department's
#    payroll -- which it did, while this file certified "salary is NULL for hr-analyst".
check "gold total_salary is NULL for hr-analyst" \
  "$(val "SELECT count(total_salary) FROM ${CAT}.gold.gold_hr_headcount_by_department" --as hr-analyst)" "0"
check "gold total_salary is visible to the steward" \
  "$(val "SELECT CASE WHEN count(total_salary) > 0 THEN 'yes' ELSE 'no' END FROM ${CAT}.gold.gold_hr_headcount_by_department")" "yes"
check "gold avg_salary is NULL for biz-analyst" \
  "$(val "SELECT count(avg_salary) FROM ${CAT}.gold.gold_hr_headcount_by_department" --as biz-analyst)" "0"

# 6. Tag-driven enforcement, not column-bound: gender has no mask of its own.
check "gender redacted for hr-analyst by ABAC policy" \
  "$(val "SELECT DISTINCT gender FROM ${CAT}.silver.silver_hr_employee WHERE gender IS NOT NULL" --as hr-analyst)" "REDACTED"

# 7. Silver is INVISIBLE to biz_users, not merely filtered.
check "biz-analyst denied on silver" \
  "$( denied "SELECT count(*) FROM ${CAT}.silver.silver_hr_employee" --as biz-analyst && echo yes || echo no )" "yes"

# 8. THE MASK BYPASS. Bronze holds the same PII unmasked; a mask on silver is worth
#    nothing if anyone can read bronze instead. Asserted against the register, which
#    now counts ALL_PRIVILEGES -- filtering on SELECT alone made an ALL PRIVILEGES
#    grantee invisible and let a principal read 17,725 unmasked salaries silently.
check "no unapproved reader on bronze PII" \
  "$(val "SELECT count(*) FROM ${CAT}.governance.stewardship_register WHERE table_schema='bronze' AND contains_pii='true' AND unapproved_readers > 0")" "0"
check "bronze is directly unreadable by hr-analyst" \
  "$( denied "SELECT count(*) FROM ${CAT}.bronze.bronze_hr_employee" --as hr-analyst && echo yes || echo no )" "yes"

# 9. THE OTHER BYPASS, and the one the phase's own documents forgot: the landing
#    Volume holds the same PII as plain CSV. local-lab's governance.md R5 --
#    "any claim about protecting a column is only as strong as the answer to
#    'who can read landing/'".
# There is exactly ONE landing zone, and it belongs to the primary catalog -- a review
# catalog reads the same Volume rather than getting a copy. So this is deliberately NOT
# parameterised by ${CAT}: doing that made both assertions fail against hr_review with
# SCHEMA_NOT_FOUND, which is a broken assertion, not a finding.
LANDING="${DBX_LANDING_VOLUME:-/Volumes/${DBX_CATALOG}/landing/drop}"
check "landing volume (${LANDING}) unreadable by hr-analyst" \
  "$( denied "SELECT count(*) FROM read_files('${LANDING}', format => 'csv')" --as hr-analyst && echo yes || echo no )" "yes"
check "landing volume unreadable by biz-analyst" \
  "$( denied "LIST '${LANDING}'" --as biz-analyst && echo yes || echo no )" "yes"

# 10. No grant outlives its principal. A deleted service principal left SELECT and
#     USE SCHEMA on gold behind -- REVOKE is per-securable and does not cascade from
#     the catalog, so nothing removed it and nothing noticed.
LIVE="$( { databricks users list --profile "${P}" -o json | python3 -c "import sys,json;[print(u['userName']) for u in json.load(sys.stdin)]"
           databricks service-principals list --profile "${P}" -o json | python3 -c "import sys,json;[print(s['applicationId']) for s in json.load(sys.stdin)]"; } | sort -u)"
STALE=0
while read -r g; do
  [[ -z "${g}" || "${g}" == "account users" ]] && continue
  grep -qxF "${g}" <<< "${LIVE}" || { echo "          stale grantee: ${g}"; STALE=$((STALE+1)); }
done <<< "$(python3 "${ROOT}/infra/dbsql.py" "SELECT DISTINCT grantee FROM ${CAT}.information_schema.schema_privileges WHERE schema_name <> 'information_schema'" 2>/dev/null | sed -n "s/^ *\['\([^']*\)'.*/\1/p")"
check "no grant belongs to a principal that no longer exists" "${STALE}" "0"

# 11. Nothing unclassified, nothing unaccounted for, anywhere.
check "stewardship register has no findings" \
  "$(val "SELECT count(*) FROM ${CAT}.governance.stewardship_register WHERE review_flag LIKE 'REVIEW%'")" "0"

echo "  ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
