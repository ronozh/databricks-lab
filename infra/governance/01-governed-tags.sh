#!/usr/bin/env bash
# Register the governed tag keys that the ABAC policies in 50-abac.sql match on.
#
# A tag used only in `ALTER ... SET TAGS` is free-text: anyone may invent a key or
# misspell a value, and no policy can match it --
#
#   CREATE POLICY ... hasTagValue('pii_class','special_category')
#   -> Unknown tag policy key `pii_class`
#
# Registering the key through the Tag Policies API makes it GOVERNED: the allowed
# values become a closed list, and the key becomes usable in a policy condition.
# That closed list is the real deliverable -- a classification scheme nobody can
# extend by typo.
#
# Idempotent AND convergent: an existing key whose value list differs is UPDATED.
# Get-then-skip is not enough -- a key created before a value was added stays stale,
# and the next classification statement then fails with
# UC_TAG_POLICY_VALUE_NOT_ALLOWED on a value this file claims to allow.
set -euo pipefail
P="${DBX_PROFILE:-free}"

ensure_tag_policy() {  # ensure_tag_policy <key> <description> <value,value,...>
  local key="$1" desc="$2" values="$3" existing json
  # The CLI rejects a positional TAG_KEY when --json is given, and the body is FLAT
  # -- a {"tag_policy": {...}} wrapper is refused as an unknown field even though the
  # error for omitting it names 'tag_policy.tag_key' as required.
  json="$(python3 -c "
import json, sys
print(json.dumps({'tag_key': sys.argv[1], 'description': sys.argv[2],
                  'values': [{'name': v} for v in sys.argv[3].split(',')]}))
" "${key}" "${desc}" "${values}")"

  existing="$(databricks tag-policies get-tag-policy "${key}" --profile "${P}" -o json 2>/dev/null || true)"
  if [[ -z "${existing}" ]]; then
    databricks tag-policies create-tag-policy --json "${json}" --profile "${P}" -o json >/dev/null
    echo "  governed tag ${key} created"
    return
  fi
  local have want
  have="$(printf '%s' "${existing}" | python3 -c "import sys,json;print(','.join(sorted(v['name'] for v in json.load(sys.stdin).get('values') or [])))")"
  want="$(printf '%s' "${values}" | tr ',' '\n' | sort | paste -sd, -)"
  if [[ "${have}" == "${want}" ]]; then
    echo "  governed tag ${key} up to date"
  else
    # UPDATE_MASK is POSITIONAL here (unlike create, which refuses positionals
    # alongside --json): update-tag-policy TAG_KEY UPDATE_MASK --json '{...}'
    databricks tag-policies update-tag-policy "${key}" 'values,description' \
      --json "${json}" --profile "${P}" -o json >/dev/null
    echo "  governed tag ${key} updated: ${have} -> ${want}"
  fi
}

ensure_tag_policy pii_class \
  "What kind of personal data a column holds." \
  "name,email,internal_id,compensation,compensation_aggregate,special_category,quasi_identifier"

ensure_tag_policy data_sensitivity \
  "How much this column matters, independent of whether it is PII." \
  "public,internal,confidential,restricted"

# contains_pii drives the stewardship register's review flag, so its VALUES must be a
# closed list too. Ungoverned, it was free text: re-tagging a bronze table
# contains_pii='True' (capital T) made the register compare 'True' <> 'true', report
# 'ok', and hide a reader of 17,725 unmasked salaries. Governing the key is the fix;
# the register also lower()s, so both halves have to fail before that hole reopens.
ensure_tag_policy contains_pii \
  "Whether a table holds personal data. Drives the stewardship register." \
  "true,false"
