#!/usr/bin/env bash
# Apply the governance rules to a catalog. Idempotent by construction -- every
# statement is CREATE OR REPLACE, CREATE IF NOT EXISTS, GRANT (which is a set
# membership, not an append), or a DELETE+INSERT pair.
#
#   ./infra/governance/apply.sh                  # the catalog from .envrc
#   ./infra/governance/apply.sh hr_review        # a throwaway copy, catalog steps only
#   ./infra/governance/apply.sh hr 30-masks.sql  # one step
#   GLOBAL=1 ./infra/governance/apply.sh hr      # include the workspace-wide steps
#
# TWO OF THESE STEPS ARE NOT CATALOG-SCOPED. 00-principals.sh and 01-governed-tags.sh
# touch the WORKSPACE and the ACCOUNT: SCIM groups, service-principal entitlements,
# OAuth secrets, tag policies. Passing a catalog name does not sandbox them, and
# running them repeatedly against a "throwaway" catalog is not a throwaway operation.
# So they run only for the primary catalog, or with GLOBAL=1.
#
# The metastore is the source of truth at RUNTIME; these files are the source of
# truth for INTENT. Re-running is how you detect drift between the two.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "${ROOT}/.envrc"; set +a

export CAT="${1:-${DBX_CATALOG:?set DBX_CATALOG}}"
FILTER="${2:-}"

# Principal identifiers are looked up, never written down (D4).
sp_app() {
  databricks service-principals list --profile "${DBX_PROFILE:-free}" -o json |
    python3 -c "import sys,json;print(next((s.get('applicationId','') for s in json.load(sys.stdin)
                if s.get('displayName')=='$1'),''))"
}
export BIZ_ANALYST_APP_ID="$(sp_app biz-analyst)"
[[ -n "${BIZ_ANALYST_APP_ID}" ]] || {
  echo "biz-analyst service principal not found -- run 00-principals.sh first" >&2; exit 1; }
export DBX_HUMAN_PRINCIPAL="${DBX_HUMAN_PRINCIPAL:?set DBX_HUMAN_PRINCIPAL}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
rc=0
# Numeric prefixes order the steps; .sh steps exist only where SQL cannot express
# the work (expanding a group into the principals UC will actually accept).
GLOBAL_STEPS="00-principals.sh 01-governed-tags.sh"
for f in "${HERE}"/[0-9][0-9]-*; do
  base="$(basename "${f}")"
  [[ -z "${FILTER}" || "${base}" == "${FILTER}" ]] || continue
  if [[ " ${GLOBAL_STEPS} " == *" ${base} "* && -z "${FILTER}" ]]; then
    if [[ "${CAT}" != "${DBX_CATALOG}" && "${GLOBAL:-0}" != "1" ]]; then
      echo "-- ${base}  SKIPPED (workspace/account scope; GLOBAL=1 to include)"; continue
    fi
  fi
  echo "== ${base}  ->  ${CAT}"
  case "${base}" in
    *.sh)
      CAT="${CAT}" bash "${f}" || rc=1 ;;
    *.sql)
      # expandvars, not sed: one place that knows how ${VAR} is spelled.
      python3 -c "import os,sys;sys.stdout.write(os.path.expandvars(open(sys.argv[1]).read()))" \
        "${f}" > "${TMP}/${base}"
      python3 "${ROOT}/infra/dbsql.py" --file "${TMP}/${base}" || rc=1 ;;
  esac
done
exit "${rc}"
