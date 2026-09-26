-- Classification. Tags are metadata: they enforce NOTHING on their own.
-- Their job is to be the thing a policy matches on, so that adding a column to
-- a class is a tagging decision rather than a code change (see 50-abac.sql).
--
-- Two keys, deliberately separate:
--   pii_class          what KIND of personal data this is
--   data_sensitivity   how much it matters, independent of whether it is PII

ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN first_name
  SET TAGS ('pii_class' = 'name', 'data_sensitivity' = 'confidential');
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN last_name
  SET TAGS ('pii_class' = 'name', 'data_sensitivity' = 'confidential');
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN email
  SET TAGS ('pii_class' = 'email', 'data_sensitivity' = 'confidential');
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN employee_number
  SET TAGS ('pii_class' = 'internal_id', 'data_sensitivity' = 'internal');
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN salary_annual
  SET TAGS ('pii_class' = 'compensation', 'data_sensitivity' = 'restricted');
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN gender
  SET TAGS ('pii_class' = 'special_category', 'data_sensitivity' = 'restricted');

-- Quasi-identifiers: harmless alone, re-identifying in combination. Tagged so
-- the register shows them, not masked -- location drives legitimate analysis.
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN home_city
  SET TAGS ('pii_class' = 'quasi_identifier', 'data_sensitivity' = 'internal');
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN home_state
  SET TAGS ('pii_class' = 'quasi_identifier', 'data_sensitivity' = 'internal');
ALTER TABLE ${CAT}.silver.silver_hr_employee ALTER COLUMN home_postcode
  SET TAGS ('pii_class' = 'quasi_identifier', 'data_sensitivity' = 'internal');

-- Gold carries no names, but it carries salary in aggregate. An average over a
-- one-person department IS that person's salary, so the class is inherited even
-- though the column is derived.
ALTER TABLE ${CAT}.gold.gold_hr_headcount_by_department ALTER COLUMN total_salary
  SET TAGS ('pii_class' = 'compensation_aggregate', 'data_sensitivity' = 'restricted');
ALTER TABLE ${CAT}.gold.gold_hr_headcount_by_department ALTER COLUMN avg_salary
  SET TAGS ('pii_class' = 'compensation_aggregate', 'data_sensitivity' = 'restricted');

-- Table-level tags: what the table IS, for discovery.
ALTER TABLE ${CAT}.silver.silver_hr_employee
  SET TAGS ('contains_pii' = 'true', 'domain' = 'hr', 'layer' = 'silver');
ALTER TABLE ${CAT}.silver.silver_hr_department
  SET TAGS ('contains_pii' = 'false', 'domain' = 'hr', 'layer' = 'silver');
ALTER TABLE ${CAT}.gold.gold_hr_headcount_by_department
  SET TAGS ('contains_pii' = 'false', 'domain' = 'hr', 'layer' = 'gold');

-- The Phase 4 semantic layer. A metric view is a securable like any other, so it needs
-- classifying like any other -- and the stewardship register is what said so: it reported
--   mv_hr_workforce | layer NULL | REVIEW: unclassified
-- the moment Phase 4 created it. An untagged table is a register FINDING by design, which
-- is exactly why an unclassified new object could not slip through quietly.
--
-- contains_pii = 'false': it exposes aggregates, and its salary measures are masked at
-- source. It is nonetheless row-filtered per caller, because it reads silver directly --
-- see the phase-4 gotcha on reading around a control.
ALTER VIEW ${CAT}.gold.mv_hr_workforce
  SET TAGS ('contains_pii' = 'false', 'domain' = 'hr', 'layer' = 'gold');

-- Bronze is tagged truthfully, which means tagged as PII. It holds the same names,
-- emails and salaries as silver and it is NOT masked -- masking it would cost the
-- time travel that makes bronze the audit copy. Its only protection is that nobody
-- outside hr_stewards is granted SELECT on it, and that is an invariant worth
-- asserting rather than assuming: see verify.sh, the bronze assertions (#8).
ALTER TABLE ${CAT}.bronze.bronze_hr_employee
  SET TAGS ('contains_pii' = 'true', 'domain' = 'hr', 'layer' = 'bronze',
            'protection' = 'grants_only');
ALTER TABLE ${CAT}.bronze.bronze_hr_employee_changes
  SET TAGS ('contains_pii' = 'true', 'domain' = 'hr', 'layer' = 'bronze',
            'protection' = 'grants_only');
ALTER TABLE ${CAT}.bronze.bronze_hr_department
  SET TAGS ('contains_pii' = 'false', 'domain' = 'hr', 'layer' = 'bronze');

-- The .ctrl sidecars hold delivery metadata -- file name, row count, md5 -- and no
-- personal data. Tagged anyway: an UNTAGGED table is a finding in the register, so
-- "no PII here" has to be said out loud rather than left blank.
ALTER TABLE ${CAT}.bronze.bronze_hr_employee_ctrl
  SET TAGS ('contains_pii' = 'false', 'domain' = 'hr', 'layer' = 'bronze');
ALTER TABLE ${CAT}.bronze.bronze_hr_employee_changes_ctrl
  SET TAGS ('contains_pii' = 'false', 'domain' = 'hr', 'layer' = 'bronze');
ALTER TABLE ${CAT}.bronze.bronze_hr_department_ctrl
  SET TAGS ('contains_pii' = 'false', 'domain' = 'hr', 'layer' = 'bronze');
