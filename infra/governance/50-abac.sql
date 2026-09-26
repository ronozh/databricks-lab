-- ABAC: bind a mask to a TAG instead of to a column.
--
-- This is the difference between classification that decorates and classification
-- that enforces. Under 20-classification.sql, tagging a column pii_class=email is
-- a sticky note. Under the policy below, the tag IS the control: tag a new column
-- in a new table tomorrow and it is masked, with no DDL on that table and no
-- deployment. Classification becomes the interface.
--
-- THREE PREREQUISITES, each of which cost an error to discover (gotcha.md #10, #11, #12):
--
--  1. The tag key must be a GOVERNED tag -- registered through the Tag Policies
--     API, not merely used in ALTER ... SET TAGS. Otherwise:
--       'Unknown tag policy key `pii_class`'
--     Registered by 01-governed-tags.sh; the values are a closed list, which is the
--     point: a governed tag cannot be misspelled into existence.
--
--  2. `DROP POLICY IF EXISTS` DOES NOT PARSE. It is `DROP POLICY <name> ON ...`,
--     so this file cannot be made idempotent the usual way. CREATE OR REPLACE
--     works, which is why it is used here.
--
--  3. The mask function's parameter type must match EVERY column the tag matches.
--     A DECIMAL mask over a tag that also matches a STRING column does not fail at
--     CREATE time and does not fail for the restricted role -- it returns NULL.
--     It fails only for the EXEMPT role, at read time:
--       CAST_INVALID_INPUT: The value 'M' ... cannot be cast to "DECIMAL(10,0)"
--     A control that breaks for privileged users and looks fine to everyone else
--     is the worst possible failure shape. Scope policies by TYPE, not by severity.

CREATE OR REPLACE FUNCTION ${CAT}.governance.mask_redact_string(v STRING)
  RETURN CASE WHEN is_member('hr_stewards') OR is_member('hr_platform')
              THEN v ELSE 'REDACTED' END;

GRANT EXECUTE ON FUNCTION ${CAT}.governance.mask_redact_string TO `${DBX_SP_APP_ID}`;

-- Applies to every STRING column in hr.silver tagged pii_class=special_category.
-- Today that is `gender` alone, and nothing in this statement names it.
CREATE OR REPLACE POLICY mask_special_category_by_tag
  ON SCHEMA ${CAT}.silver
  COMMENT 'Special-category personal data is redacted outside hr_stewards. Tag-driven: see 20-classification.sql.'
  COLUMN MASK ${CAT}.governance.mask_redact_string
  TO `account users`
  FOR TABLES
  MATCH COLUMNS hasTagValue('pii_class', 'special_category') AS special_col
  ON COLUMN special_col;

-- ABAC coverage, declared. An ABAC-derived mask does NOT appear in
-- information_schema.column_masks, so the stewardship register cannot see it and
-- would report a column protected by the policy above as unprotected. Rather than
-- have the register guess, the policy states what it covers, in a table the register
-- joins. If this file and the register ever disagree, the register is wrong -- which
-- is the right direction for a governance artifact to fail.
CREATE TABLE IF NOT EXISTS ${CAT}.governance.abac_coverage (
  pii_class     STRING COMMENT 'the tag value the policy matches on',
  scope         STRING COMMENT 'schema the policy is attached to',
  policy_name   STRING,
  mask_function STRING
) COMMENT 'Which pii_class values are protected by an ABAC policy rather than a column-bound mask.';

DELETE FROM ${CAT}.governance.abac_coverage;
INSERT INTO ${CAT}.governance.abac_coverage VALUES
  ('special_category', 'silver', 'mask_special_category_by_tag',
   '${CAT}.governance.mask_redact_string');
