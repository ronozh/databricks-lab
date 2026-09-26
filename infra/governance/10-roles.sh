#!/usr/bin/env bash
# Role grants.
#
# A shell script, not a .sql file, for a reason worth stating: on this workspace
# Unity Catalog will NOT accept a workspace-local group as a grantee --
#
#   GRANT USE SCHEMA ON SCHEMA hr.silver TO `hr_analysts`
#   -> PRINCIPAL_DOES_NOT_EXIST: Could not find principal with name hr_analysts
#
# UC grants resolve ACCOUNT-level principals only, and Free Edition has no
# account-group API. So the group stays the unit of intent -- membership is still
# the only thing an operator edits -- and this script expands it to the individual
# principals UC does accept. Change the roster, re-run, done.
#
# Measured: `account users` (the built-in account group) IS accepted; any other
# group name is not. See gotcha.md #2.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a
CAT="${CAT:-${DBX_CATALOG}}"
P="${DBX_PROFILE:-free}"
# dbsql.py writes its errors to STDOUT. Redirecting that to /dev/null and relying on
# `set -e` produced an abort with no message at all -- the single least helpful failure
# mode a deployment script can have. Capture, and print on failure.
q() {
  local out; out="$(python3 "${ROOT}/infra/dbsql.py" "$1" 2>&1)" || {
    printf '  FAILED: %s\n    %s\n' "$1" "${out}" >&2; return 1; }
}

USERS_JSON="$(databricks users list --profile "${P}" -o json)"
SPS_JSON="$(databricks service-principals list --profile "${P}" -o json)"
GROUPS_JSON="$(databricks groups list --profile "${P}" -o json)"
export USERS_JSON SPS_JSON GROUPS_JSON

# `groups list` omits the members attribute entirely -- every group comes back
# looking empty and the grant loop then silently does nothing. Members appear only
# on `groups get <id>`, so resolve the id from the list, then fetch the group.
group_id() {
  python3 -c "import json,os,sys;print(next((g['id'] for g in json.loads(os.environ['GROUPS_JSON']) if g.get('displayName')==sys.argv[1]),''))" "$1"
}

# A SCIM member is a numeric id. UC wants an email for a human and an
# applicationId for a service principal -- two namespaces, so resolve, not assume.
# NOTE ON THE MISSING-GROUP PATH: this function is called in a command substitution,
# so an `exit` here kills only the subshell -- the caller would carry on and print
# "no members, nothing to grant", which is exactly the silent no-op of gotcha #3. It
# returns a sentinel instead, and the caller aborts.
members_of() {
  local gid; gid="$(group_id "$1")"
  [[ -n "${gid}" ]] || { echo "__MISSING_GROUP__"; return 0; }
  databricks groups get "${gid}" --profile "${P}" -o json | python3 -c "
import json, os, sys
users = {u['id']: u.get('userName') for u in json.loads(os.environ['USERS_JSON'])}
sps   = {s['id']: s.get('applicationId') for s in json.loads(os.environ['SPS_JSON'])}
for m in json.load(sys.stdin).get('members') or []:
    who = users.get(m['value']) or sps.get(m['value'])
    if who:
        print(who)
"
}

# role | privileges | securable type | securable
#
# The interesting lines are the ones that are ABSENT: no role below is granted
# anything on hr.bronze. The masks live on silver, and a reader of bronze would
# see straight past them -- so bronze stays reachable by its owner alone.
GRANTS=(
  # hr_stewards -- accountable for the data. Read everything, masked columns
  # included: they are the exemption every mask in 30-masks.sql is written against.
  "hr_stewards|USE CATALOG|CATALOG|${CAT}"
  "hr_stewards|USE SCHEMA, SELECT|SCHEMA|${CAT}.silver"
  "hr_stewards|USE SCHEMA, SELECT|SCHEMA|${CAT}.gold"
  "hr_stewards|USE SCHEMA, SELECT|SCHEMA|${CAT}.governance"

  # hr_analysts -- inside HR: every department, but salary and email masked.
  # Granted on the SCHEMA, so a silver table added next month is covered.
  "hr_analysts|USE CATALOG|CATALOG|${CAT}"
  "hr_analysts|USE SCHEMA, SELECT|SCHEMA|${CAT}.silver"
  "hr_analysts|USE SCHEMA, SELECT|SCHEMA|${CAT}.gold"

  # biz_users -- outside HR: the published answer, not the roster, and row-filtered
  # to the departments they own. No USE SCHEMA on silver, which makes silver
  # INVISIBLE rather than forbidden: a different experience, a different ticket.
  #
  # Neither analyst role is granted anything on hr.governance, deliberately. Masks
  # and row filters evaluate with DEFINER rights: the function reads dept_access on
  # every query, yet the caller needs neither EXECUTE on the function nor SELECT on
  # the table. Measured -- biz-analyst has no EXECUTE on filter_dept and the
  # filtered query still works. The allowlist is therefore not readable by the
  # people it constrains, which is the property you want.
  "biz_users|USE CATALOG|CATALOG|${CAT}"
  "biz_users|USE SCHEMA, SELECT|SCHEMA|${CAT}.gold"
)

# Plain string cache, not an associative array: macOS ships bash 3.2, where
# `declare -A` is a syntax error.
CACHED_ROLE=""; CACHED_MEMBERS=""
for row in "${GRANTS[@]}"; do
  IFS='|' read -r role privs stype securable <<< "${row}"
  if [[ "${role}" != "${CACHED_ROLE}" ]]; then
    CACHED_ROLE="${role}"; CACHED_MEMBERS="$(members_of "${role}")"
    if [[ "${CACHED_MEMBERS}" == "__MISSING_GROUP__" ]]; then
      echo "group ${role} does not exist -- run 00-principals.sh first" >&2; exit 1
    fi
  fi
  [[ -n "${CACHED_MEMBERS}" ]] || { echo "  ${role}: no members, nothing to grant"; continue; }
  while read -r principal; do
    [[ -n "${principal}" ]] || continue
    q "GRANT ${privs} ON ${stype} ${securable} TO \`${principal}\`"
    echo "  ${role}: ${privs} ON ${stype} ${securable} -> ${principal:0:14}…"
  done <<< "${CACHED_MEMBERS}"
done
echo "grants applied to ${CAT}"
