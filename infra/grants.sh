#!/usr/bin/env bash
# Grants for the HR catalog.
#
# A shell script rather than a .sql file because the principals are identifiers,
# not content (D4) -- hardcoding a service-principal id and a personal email into
# a committed file is how a public repo leaks who runs it.
#
#   ./infra/grants.sh
#
# Principals come from .envrc (local, gitignored):
#   DBX_SP_APP_ID        the dbt service principal's applicationId
#   DBX_HUMAN_PRINCIPAL  the human account
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a
CAT="${1:-${DBX_CATALOG}}"
q() { python3 "${ROOT}/infra/dbsql.py" "$1"; }

SP="${DBX_SP_APP_ID:?set DBX_SP_APP_ID in .envrc}"
ME="${DBX_HUMAN_PRINCIPAL:?set DBX_HUMAN_PRINCIPAL in .envrc}"

# The service principal builds. dbt verifies (and will create) its target schemas
# on EVERY run, so CREATE SCHEMA on the catalog is required, not just on schemas.
q "GRANT USE CATALOG, CREATE SCHEMA ON CATALOG ${CAT} TO \`${SP}\`"
for s in bronze silver gold; do
  q "GRANT ALL PRIVILEGES ON SCHEMA ${CAT}.${s} TO \`${SP}\`"
done
q "GRANT USE SCHEMA, READ VOLUME ON SCHEMA ${CAT}.landing TO \`${SP}\`"
q "GRANT READ VOLUME ON VOLUME ${CAT}.landing.drop TO \`${SP}\`"

# Tables created by the service principal are OWNED by it, so the human account
# cannot read them by default. Unity Catalog behaving correctly, and the first
# concrete taste of Phase 2: ownership is not access, and neither is implied by
# having created the catalog.
for s in bronze silver gold; do
  q "GRANT SELECT, MODIFY ON SCHEMA ${CAT}.${s} TO \`${ME}\`"
done

q "SHOW GRANTS ON CATALOG ${CAT}"
