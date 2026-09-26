#!/usr/bin/env bash
# An isolated catalog for review, reading the SAME landing Volume.
#
# The Volume is expensive to fill (1,588 files, ~9 min) and cheap to share; the
# catalog is cheap to recreate. Separating them makes the review loop ~80s.
#
#   ./infra/review-env.sh create|build|drop
#
# SAFETY. The first version of this script did the opposite of what it claimed:
# run-dbt.sh sourced .envrc, which unconditionally exported DBX_CATALOG=hr and
# clobbered the caller, so `review-env.sh build` full-refreshed PRODUCTION.
# Three guards now, because one was evidently not enough:
#   1. .envrc assigns conditionally, so a caller's value survives
#   2. this script refuses to operate on the primary catalog
#   3. build asserts current_catalog() before it writes
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; . "${ROOT}/.envrc"; set +a

PRIMARY="hr"
CAT="${REVIEW_CATALOG:-hr_review}"
if [[ "${CAT}" == "${PRIMARY}" ]]; then
  echo "refusing: REVIEW_CATALOG must not be the primary catalog '${PRIMARY}'" >&2
  exit 1
fi

q() { python3 "${ROOT}/infra/dbsql.py" "$1"; }

case "${1:-}" in
  create)
    q "CREATE CATALOG IF NOT EXISTS ${CAT} COMMENT 'Isolated review copy. Reads ${DBX_LANDING_VOLUME}.'"
    for s in bronze silver gold; do q "CREATE SCHEMA IF NOT EXISTS ${CAT}.${s}"; done
    q "GRANT USE CATALOG, CREATE SCHEMA ON CATALOG ${CAT} TO \`${DBX_SP_APP_ID}\`"
    for s in bronze silver gold; do
      q "GRANT ALL PRIVILEGES ON SCHEMA ${CAT}.${s} TO \`${DBX_SP_APP_ID}\`"
      q "GRANT SELECT, MODIFY ON SCHEMA ${CAT}.${s} TO \`${DBX_HUMAN_PRINCIPAL}\`"
    done
    echo "ready: ./infra/review-env.sh build"
    ;;
  build)
    # Guard 3: prove where we are about to write before writing.
    actual="$(DBX_CATALOG="${CAT}" python3 - <<'PY'
import os, sys
sys.path.insert(0, os.path.join(os.environ["PWD"], "infra"))
from dbsql import run, warehouse_id
ok, d = run(f"SELECT current_catalog()", profile="free", wh=warehouse_id("free"),
            catalog=os.environ["DBX_CATALOG"])
print(d["data_array"][0][0] if ok else "UNKNOWN")
PY
)"
    if [[ "${actual}" != "${CAT}" ]]; then
      echo "refusing: session resolved to catalog '${actual}', expected '${CAT}'" >&2
      exit 1
    fi
    echo "verified target catalog: ${actual}"
    DBX_CATALOG="${CAT}" "${ROOT}/run-dbt.sh" build --full-refresh
    ;;
  drop) q "DROP CATALOG IF EXISTS ${CAT} CASCADE" ;;
  *) echo "usage: review-env.sh create|build|drop"; exit 1 ;;
esac
