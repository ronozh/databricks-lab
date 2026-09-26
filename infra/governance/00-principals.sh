#!/usr/bin/env bash
# Create the four governance groups and the two analyst service principals.
#
#   ./infra/governance/00-principals.sh
#
# Idempotent: everything is looked up by name before it is created, so re-running
# is a no-op. The one thing that CANNOT be idempotent is an OAuth secret -- the
# API returns it exactly once -- so a secret is minted only when the alias has no
# credentials in .env.secret yet.
#
# Why service principals and not invited humans: to prove a control works, some-
# thing must authenticate AS the restricted principal and run the query. A second
# human cannot, from a script. See .plan/phase-2-governance/mental-model.md §4.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a
P="${DBX_PROFILE:-free}"
SECRETS="${ROOT}/.env.secret"

dbx() { databricks "$@" --profile "${P}"; }
py() { python3 -c "$@"; }

# ---------------------------------------------------------------- groups
group_id() {
  dbx groups list -o json |
    py "import sys,json;print(next((g['id'] for g in json.load(sys.stdin)
        if g.get('displayName')=='$1'),''))"
}

ensure_group() {
  local name="$1" id
  id="$(group_id "${name}")"
  if [[ -z "${id}" ]]; then
    id="$(dbx groups create --json "{\"displayName\":\"${name}\"}" -o json |
          py "import sys,json;print(json.load(sys.stdin)['id'])")"
    echo "  created group ${name} (${id})" >&2
  else
    echo "  group ${name} exists (${id})" >&2
  fi
  printf '%s' "${id}"
}

# SCIM PATCH is itself idempotent for 'add members' -- adding an existing member
# is accepted and changes nothing -- so membership needs no existence check.
add_member() {
  local gid="$1" member_id="$2" label="$3"
  dbx groups patch "${gid}" --json "$(cat <<JSON
{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
 "Operations":[{"op":"add","path":"members","value":[{"value":"${member_id}"}]}]}
JSON
)" >/dev/null
  echo "  ${label} -> group ${gid}"
}

# ------------------------------------------------- service principals
sp_field() {  # sp_field <displayName> <field>
  dbx service-principals list -o json |
    py "import sys,json;print(next((s.get('$2','') for s in json.load(sys.stdin)
        if s.get('displayName')=='$1'),''))"
}

ensure_sp() {
  local name="$1" nid
  nid="$(sp_field "${name}" id)"
  if [[ -z "${nid}" ]]; then
    nid="$(dbx service-principals create --json "$(cat <<JSON
{"displayName":"${name}",
 "entitlements":[{"value":"databricks-sql-access"},{"value":"workspace-access"}]}
JSON
)" -o json | py "import sys,json;print(json.load(sys.stdin)['id'])")"
    echo "  created service principal ${name} (${nid})" >&2
  else
    echo "  service principal ${name} exists (${nid})" >&2
  fi
  # Entitlements are granted at create time above, but an SP created earlier by
  # hand may lack them, and without databricks-sql-access it authenticates fine
  # and then cannot reach a warehouse at all (Phase 1 gotcha #2).
  dbx api patch "/api/2.0/preview/scim/v2/ServicePrincipals/${nid}" --json "$(cat <<'JSON'
{"schemas":["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
 "Operations":[{"op":"add","path":"entitlements",
   "value":[{"value":"databricks-sql-access"},{"value":"workspace-access"}]}]}
JSON
)" >/dev/null
  printf '%s' "${nid}"
}

mint_secret() {  # mint_secret <alias> <numeric_id> <app_id>
  local alias="$1" nid="$2" app="$3"
  local key="SP_$(echo "${alias}" | tr 'a-z-' 'A-Z_')"
  touch "${SECRETS}"; chmod 600 "${SECRETS}"
  if grep -q "^${key}_CLIENT_ID=" "${SECRETS}" 2>/dev/null; then
    echo "  ${alias}: credentials already in .env.secret"
    return
  fi
  local sec
  sec="$(dbx service-principal-secrets-proxy create "${nid}" -o json |
         py "import sys,json;print(json.load(sys.stdin)['secret'])")"
  { echo ""; echo "# ${alias} -- created $(date +%F) by 00-principals.sh"
    echo "${key}_CLIENT_ID=${app}"
    echo "${key}_CLIENT_SECRET=${sec}"; } >> "${SECRETS}"
  echo "  ${alias}: secret minted -> .env.secret (shown once, never again)"
}

# ===================================================================
echo "groups"
G_PLATFORM="$(ensure_group hr_platform)"
G_STEWARDS="$(ensure_group hr_stewards)"
G_ANALYSTS="$(ensure_group hr_analysts)"
G_BIZ="$(ensure_group biz_users)"

echo "service principals"
DBT_NID="$(sp_field "${DBX_SP_NAME:-databricks-lab-dbt}" id)"
[[ -n "${DBT_NID}" ]] || { echo "the dbt service principal is missing" >&2; exit 1; }

for alias in hr-analyst biz-analyst; do
  nid="$(ensure_sp "${alias}")"
  app="$(sp_field "${alias}" applicationId)"
  mint_secret "${alias}" "${nid}" "${app}"
  eval "NID_${alias//-/_}=${nid}"
  eval "APP_${alias//-/_}=${app}"
done

echo "membership"
add_member "${G_PLATFORM}" "${DBT_NID}"  "dbt service principal"
add_member "${G_ANALYSTS}" "${NID_hr_analyst}"  "hr-analyst"
add_member "${G_BIZ}"      "${NID_biz_analyst}" "biz-analyst"

ME_ID="$(dbx current-user me -o json | py "import sys,json;print(json.load(sys.stdin)['id'])")"
add_member "${G_STEWARDS}" "${ME_ID}" "${DBX_HUMAN_PRINCIPAL}"

echo
echo "applicationIds (these are the grantees, not the numeric ids):"
echo "  hr-analyst   ${APP_hr_analyst}"
echo "  biz-analyst  ${APP_biz_analyst}"
