#!/usr/bin/env bash
# The same queries, run as every principal, printed side by side.
#
#   ./infra/governance/prove.sh
#
# verify.sh asserts; this one SHOWS. Governance is the one area where the evidence
# has to be a comparison -- a single principal's output, however correct, proves
# nothing about what anyone else can see.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a
CAT="${1:-${DBX_CATALOG}}"

run() {  # run <alias-or-'human'> <sql>
  local who="$1" sql="$2" out
  if [[ "${who}" == "human" ]]; then
    out="$(python3 "${ROOT}/infra/dbsql.py" "${sql}" 2>&1)"
  else
    out="$(python3 "${ROOT}/infra/dbsql.py" --as "${who}" "${sql}" 2>&1)"
  fi
  # Three outcomes, not two. Keying on the substring FAIL alone reported a missing
  # credential or an unreachable host as an empty row -- indistinguishable from "this
  # principal legitimately saw nothing", which is the worst possible reading for a
  # tool whose only job is comparing principals.
  if [[ "${out}" == *"INSUFFICIENT_PERMISSIONS"* || "${out}" == *"PERMISSION_DENIED"* ]]; then
    printf '  %-14s DENIED  %s\n' "${who}" \
      "$(printf '%s' "${out}" | grep -oE '\[[A-Z_]+\]' | head -1)"
  elif [[ "${out}" == *"FAIL"* || "${out}" == *"missing from .env.secret"* || "${out}" == *"cannot "* ]]; then
    printf '  %-14s ERROR   %s\n' "${who}" \
      "$(printf '%s' "${out}" | tr '\n' ' ' | cut -c1-90)"
  else
    printf '  %-14s %s\n' "${who}" "$(printf '%s' "${out}" | sed -n '2,3p' | tr -s ' ' | paste -sd' ' -)"
  fi
}

banner() { printf '\n%s\n%s\n' "$1" "$(printf '%.0s-' $(seq 1 ${#1}))"; }

banner "1. Row filter -- how many departments can you see?"
for p in human dbx hr-analyst biz-analyst; do
  run "$p" "SELECT count(*) AS departments, sum(headcount) AS people FROM ${CAT}.gold.gold_hr_headcount_by_department"
done

banner "2. Column mask -- one employee's email and salary"
for p in human dbx hr-analyst biz-analyst; do
  run "$p" "SELECT email, salary_annual FROM ${CAT}.silver.silver_hr_employee WHERE employee_id = 1"
done

banner "3. ABAC policy -- gender is masked by its TAG, not by a mask on the column"
for p in human hr-analyst; do
  run "$p" "SELECT gender FROM ${CAT}.silver.silver_hr_employee WHERE employee_id = 1"
done

banner "4. Visibility -- can you even see that silver exists?"
for p in hr-analyst biz-analyst; do
  run "$p" "SELECT count(*) AS tables FROM ${CAT}.information_schema.tables WHERE table_schema = 'silver'"
done

banner "5. Compensation aggregates in gold -- masked, though gold is not the roster"
for p in human hr-analyst biz-analyst; do
  run "$p" "SELECT sum(total_salary) AS payroll, max(avg_salary) AS highest_dept_avg FROM ${CAT}.gold.gold_hr_headcount_by_department"
done

banner "6. Lineage -- which column feeds gold.avg_salary"
run human "SELECT DISTINCT source_table_full_name, source_column_name FROM system.access.column_lineage WHERE target_table_full_name = '${CAT}.gold.gold_hr_headcount_by_department' AND target_column_name = 'avg_salary' AND source_table_full_name IS NOT NULL"
run hr-analyst "SELECT count(*) FROM system.access.column_lineage"

banner "7. Stewardship register -- generated from the metastore, not maintained"
python3 "${ROOT}/infra/dbsql.py" "SELECT table_schema, table_name, contains_pii, masked_columns, granted_readers, unapproved_readers, review_flag FROM ${CAT}.governance.stewardship_register ORDER BY table_schema, table_name" 2>&1 | tail -n +2
