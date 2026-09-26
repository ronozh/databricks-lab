-- Stewardship: who is accountable for each table, and what protects it.
--
-- The register is a VIEW over information_schema, not a maintained document. That
-- is the whole point: a hand-written register drifts the moment someone runs an
-- ALTER, and a register that disagrees with the metastore is worse than none --
-- Phase 1's review found three documents asserting a defence that did not exist.
-- This one cannot drift, because it has nothing of its own to be stale about.

-- Approved exceptions. Bronze holds unmasked names, emails and salaries, and the
-- stewards can read it -- that is intended, not an oversight. But "intended" has to
-- be written down somewhere an auditor can read, or it is indistinguishable from a
-- misconfiguration nobody noticed. This table is that somewhere: a principal is
-- either masked, or has a row here with a reason and an approver.
CREATE TABLE IF NOT EXISTS ${CAT}.governance.unmasked_access (
  principal    STRING COMMENT 'current_user(): email for a human, applicationId for a service principal',
  scope        STRING COMMENT 'schema this exception covers, e.g. bronze',
  reason       STRING COMMENT 'why this principal needs unmasked access',
  approved_by  STRING,
  approved_on  DATE
) COMMENT 'Documented exceptions to masking. Read by the stewardship register to disposition findings.';

DELETE FROM ${CAT}.governance.unmasked_access;
INSERT INTO ${CAT}.governance.unmasked_access VALUES
  ('${DBX_HUMAN_PRINCIPAL}', 'bronze',
   'Data steward. Bronze is the unmasked audit copy; masking it would disable the time travel that makes it an audit copy.',
   '${DBX_HUMAN_PRINCIPAL}', current_date()),
  ('${DBX_SP_APP_ID}', 'bronze',
   'Pipeline. Owns and writes bronze; cannot compute on masked values.',
   '${DBX_HUMAN_PRINCIPAL}', current_date());

CREATE OR REPLACE VIEW ${CAT}.governance.stewardship_register
  COMMENT 'Ownership, classification and protection per table, read live from information_schema.'
AS
WITH tbl AS (
  SELECT table_schema, table_name, table_owner, table_type
  FROM ${CAT}.information_schema.tables
  WHERE table_schema IN ('bronze', 'silver', 'gold')
),
tags AS (
  SELECT schema_name, table_name,
         max(CASE WHEN tag_name = 'domain' THEN tag_value END)       AS domain,
         max(CASE WHEN tag_name = 'layer' THEN tag_value END)        AS layer,
         max(CASE WHEN tag_name = 'contains_pii' THEN tag_value END) AS contains_pii
  FROM ${CAT}.information_schema.table_tags
  GROUP BY schema_name, table_name
),
classified AS (
  SELECT schema_name, table_name,
         count(DISTINCT column_name) AS classified_columns
  FROM ${CAT}.information_schema.column_tags
  WHERE tag_name = 'pii_class'
  GROUP BY schema_name, table_name
),
-- The columns that actually have to be protected: data_sensitivity=restricted.
-- Counting "classified" columns instead was the earlier mistake -- 9 classified
-- columns and 2 masks read as under-protection when most of those 9 (name, city,
-- postcode) are deliberately readable.
restricted AS (
  SELECT schema_name, table_name, column_name
  FROM ${CAT}.information_schema.column_tags
  WHERE tag_name = 'data_sensitivity' AND lower(tag_value) = 'restricted'
),
-- A restricted column counts as protected if a column mask is bound to it OR its
-- pii_class is covered by an ABAC policy (which information_schema cannot show).
protected AS (
  SELECT r.schema_name, r.table_name, r.column_name
  FROM restricted r
  LEFT JOIN ${CAT}.information_schema.column_masks m
         ON m.table_schema = r.schema_name AND m.table_name = r.table_name
        AND m.column_name  = r.column_name
  LEFT JOIN ${CAT}.information_schema.column_tags pc
         ON pc.schema_name = r.schema_name AND pc.table_name = r.table_name
        AND pc.column_name = r.column_name AND pc.tag_name = 'pii_class'
  LEFT JOIN ${CAT}.governance.abac_coverage a
         ON a.pii_class = pc.tag_value AND a.scope = r.schema_name
  WHERE m.column_name IS NOT NULL OR a.pii_class IS NOT NULL
),
exposure AS (
  SELECT r.schema_name, r.table_name,
         count(*) AS restricted_columns,
         count(p.column_name) AS protected_columns
  FROM restricted r
  LEFT JOIN protected p
         ON p.schema_name = r.schema_name AND p.table_name = r.table_name
        AND p.column_name = r.column_name
  GROUP BY r.schema_name, r.table_name
),
masked AS (
  SELECT table_schema, table_name, count(*) AS masked_columns
  FROM ${CAT}.information_schema.column_masks
  GROUP BY table_schema, table_name
),
filtered AS (
  SELECT table_schema, table_name, filter_name
  FROM ${CAT}.information_schema.row_filters
),
-- Grants only. OWNERSHIP does not appear in table_privileges, so a table whose
-- readers count is 0 is still readable by its owner -- which is why table_owner is
-- a column of this register and not a footnote.
readers AS (
  -- ALL_PRIVILEGES is stored as its own value and is NEVER expanded into SELECT, so
  -- filtering on = 'SELECT' alone made every ALL PRIVILEGES grantee invisible here.
  -- A principal granted ALL PRIVILEGES on bronze read 17,725 unmasked salaries while
  -- this register reported "ok" and the assertion built on it passed.
  SELECT p.table_schema, p.table_name,
         count(DISTINCT p.grantee) AS granted_readers,
         -- Readers with no approved exception for this schema. This is the number
         -- that matters: not "who can read it" but "who can read it unaccounted
         -- for". A LEFT JOIN + IS NULL, so a reader with no row here counts.
         count(DISTINCT CASE WHEN x.principal IS NULL THEN p.grantee END) AS unapproved_readers
  FROM ${CAT}.information_schema.table_privileges p
  LEFT JOIN ${CAT}.governance.unmasked_access x
         ON x.principal = p.grantee AND x.scope = p.table_schema
  WHERE p.privilege_type IN ('SELECT', 'ALL_PRIVILEGES')
  GROUP BY p.table_schema, p.table_name
)
SELECT
  t.table_schema,
  t.table_name,
  t.table_owner,
  g.domain,
  g.layer,
  g.contains_pii,
  coalesce(c.classified_columns, 0) AS classified_columns,
  coalesce(e.restricted_columns, 0) AS restricted_columns,
  coalesce(e.protected_columns, 0)  AS protected_columns,
  coalesce(m.masked_columns, 0)     AS masked_columns,
  f.filter_name                     AS row_filter,
  coalesce(r.granted_readers, 0)    AS granted_readers,
  coalesce(r.unapproved_readers, 0) AS unapproved_readers,
  -- What an access review actually asks. Unmasked PII is not automatically a
  -- finding -- bronze is deliberately unmasked -- so the flag fires only when
  -- unmasked PII is also REACHABLE by someone other than its owner.
  -- Driven by RESTRICTED COLUMNS and REACHABILITY, not by one tag's spelling.
  -- The earlier version asked only `contains_pii = 'true'` and then `masked_columns
  -- > 0`, which produced three separate false passes: gold was tagged
  -- contains_pii='false' while carrying two restricted salary columns and so was
  -- skipped entirely; one mask out of many restricted columns read as "masked"; and
  -- re-tagging a table 'True' turned a real exposure into 'ok'.
  --
  -- The NULL branch stays first and explicit: written as `<> 'true'` alone, an
  -- untagged table yields NULL, the CASE falls to the ELSE, and every unclassified
  -- table is reported as a breach. Unclassified is its own finding.
  CASE
    WHEN g.contains_pii IS NULL AND coalesce(e.restricted_columns, 0) = 0
                                                   THEN 'REVIEW: unclassified'
    WHEN coalesce(e.restricted_columns, 0) > 0
     AND coalesce(e.protected_columns, 0) < coalesce(e.restricted_columns, 0)
     AND coalesce(r.unapproved_readers, 0) > 0      THEN 'REVIEW: unprotected restricted columns, reader without an approved exception'
    WHEN lower(coalesce(g.contains_pii, 'false')) = 'true'
     AND coalesce(m.masked_columns, 0) = 0
     AND coalesce(r.unapproved_readers, 0) > 0      THEN 'REVIEW: unmasked PII, reader without an approved exception'
    WHEN coalesce(r.granted_readers, 0) = 0        THEN 'ok — owner only'
    WHEN coalesce(e.restricted_columns, 0) > 0
     AND coalesce(e.protected_columns, 0) >= coalesce(e.restricted_columns, 0)
                                                   THEN 'ok — restricted columns protected'
    WHEN coalesce(r.unapproved_readers, 0) = 0     THEN 'ok — approved exception'
    ELSE 'ok'
  END AS review_flag
FROM tbl t
LEFT JOIN tags g       ON g.schema_name  = t.table_schema AND g.table_name = t.table_name
LEFT JOIN classified c ON c.schema_name  = t.table_schema AND c.table_name = t.table_name
LEFT JOIN masked m     ON m.table_schema = t.table_schema AND m.table_name = t.table_name
LEFT JOIN filtered f   ON f.table_schema = t.table_schema AND f.table_name = t.table_name
LEFT JOIN readers r    ON r.table_schema = t.table_schema AND r.table_name = t.table_name
LEFT JOIN exposure e   ON e.schema_name  = t.table_schema AND e.table_name = t.table_name;

GRANT SELECT ON VIEW ${CAT}.governance.stewardship_register TO `${DBX_HUMAN_PRINCIPAL}`;
