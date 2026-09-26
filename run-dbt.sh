#!/usr/bin/env bash
# One entry point, so nobody has to remember the env dance.
#   ./run-dbt.sh build
#   ./run-dbt.sh test --select silver
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "${ROOT}/.envrc"; . "${ROOT}/.env.secret"; set +a
cd "${ROOT}/pipelines/dbt"
DBT_PROFILES_DIR=. exec "${ROOT}/.venv/bin/dbt" "$@"
