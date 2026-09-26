-- Column masks. A mask is a UC function bound to a column; it rewrites the value
-- per caller at read time. The stored bytes never change, which is what makes it
-- reversible -- and what makes it useless against someone who reads the file.
--
-- COST, decided deliberately: a column mask DISABLES TIME TRAVEL on the table it
-- is bound to (COLUMN_MASKS_FEATURE_NOT_SUPPORTED.TIME_TRAVEL). So masks go on
-- SILVER, and bronze stays unmasked and time-travellable as the audit copy --
-- which is only safe because no role is granted anything on bronze.
--
-- THE PIPELINE MUST BE EXEMPT, and this is not a convenience. A mask applies to
-- the table's OWNER too -- measured, and contrary to what is often assumed: the
-- dbt service principal owns silver_hr_employee and still read 0 of 613 salaries.
-- Without hr_platform below, the next `dbt run` computes SUM(NULL) and writes
-- total_salary = 0.00 into gold. dbt reports PASS=1. Nothing errors. Gold is
-- simply wrong. Measured: gotcha.md #5.

CREATE OR REPLACE FUNCTION ${CAT}.governance.mask_salary(salary DECIMAL(12,2))
  RETURN CASE WHEN is_member('hr_stewards') OR is_member('hr_platform')
              THEN salary ELSE NULL END;

-- Not every mask is a NULL. Redaction keeps the shape of the value, so an
-- analyst can still tell two people apart and still see the domain.
--
-- element_at, NOT split(...)[1]. Under ANSI semantics the [1] subscript on a
-- one-element array RAISES -- INVALID_ARRAY_INDEX -- so a single address with no
-- '@' in a landed file would make every hr_analysts SELECT on this table fail while
-- the steward, who takes the first CASE arm, saw nothing wrong. element_at returns
-- NULL out of range. (0 offenders in the current 613 rows; the point is that it is
-- an upstream data value, not a code path we control.)
CREATE OR REPLACE FUNCTION ${CAT}.governance.mask_email(email STRING)
  RETURN CASE WHEN is_member('hr_stewards') OR is_member('hr_platform') THEN email
              WHEN email IS NULL THEN NULL
              ELSE concat('***@', coalesce(element_at(split(email, '@'), 2), 'redacted')) END;

-- Bindings live HERE, and this is the opposite of the gold row filter, which must
-- live in dbt config. The adapter is asymmetric, measured both ways:
--
--   row filter   dbt reconciles it every run. A filter it did not configure is
--                DROPPED -- so an out-of-band binding survives one build.
--   column mask  dbt never applies one on a `table` model, in either yml spelling.
--                `apply_column_masks` is only wired into the alter path (materialized
--                views, streaming tables). The config is silently inert.
--
-- An ALTER-bound mask is stable because CREATE OR REPLACE TABLE PRESERVES masks
-- (measured on a probe table, and by silver surviving a dozen rebuilds). So:
--
--   function + grant + tag + access map + MASK binding  ->  infra/governance
--   ROW FILTER binding                                  ->  dbt model config
--
-- The rule underneath, which is what survives an adapter upgrade: find out which
-- properties your declarative tool reconciles, and put exactly those in its config.
-- Assume nothing -- the two properties either side of this line look identical in the
-- documentation and behave in opposite ways.

-- EXECUTE for the pipeline, granted HERE and not in 10-roles.sh, because
-- CREATE OR REPLACE FUNCTION DISCARDS the function's grants -- measured: after
-- replacing filter_dept, SHOW GRANTS returned nothing. A grant in an earlier step
-- would be silently undone by this one. The pipeline needs EXECUTE not to READ
-- through the control (masks and filters evaluate with definer rights) but to
-- BIND it: dbt's ALTER ... SET ROW FILTER fails with PERMISSION_DENIED without it.
GRANT EXECUTE ON FUNCTION ${CAT}.governance.mask_salary TO `${DBX_SP_APP_ID}`;
GRANT EXECUTE ON FUNCTION ${CAT}.governance.mask_email  TO `${DBX_SP_APP_ID}`;

-- Gold's compensation aggregates. These are tagged data_sensitivity=restricted in
-- 20-classification.sql, and until now nothing enforced that: hr_analysts is exempt
-- from the row filter and gold carried no mask, so the role the masks exist to
-- restrict could read all 16 departments' payroll totals.
--
-- Masking gold used to look expensive because it would cost gold's time travel. It
-- does not: the ROW FILTER already costs it. Bronze is the only time-travellable
-- layer, so the trade this was avoiding does not exist.
--
-- With both controls bound, gold now reports a THIRD error class --
-- ROW_LEVEL_SECURITY_COLUMN_MASK_FEATURE_NOT_SUPPORTED.TIME_TRAVEL, note
-- COLUMN_MASK singular -- so it is not a superstring of either single-protection
-- class. Anything matching on those two strings misses this case.
--
-- Two functions, because a mask's parameter type must match the column EXACTLY and
-- these differ: SUM widens to decimal(23,2), AVG to decimal(13,2).
CREATE OR REPLACE FUNCTION ${CAT}.governance.mask_salary_total(v DECIMAL(23,2))
  RETURN CASE WHEN is_member('hr_stewards') OR is_member('hr_platform')
              THEN v ELSE NULL END;

CREATE OR REPLACE FUNCTION ${CAT}.governance.mask_salary_avg(v DECIMAL(13,2))
  RETURN CASE WHEN is_member('hr_stewards') OR is_member('hr_platform')
              THEN v ELSE NULL END;

GRANT EXECUTE ON FUNCTION ${CAT}.governance.mask_salary_total TO `${DBX_SP_APP_ID}`;
GRANT EXECUTE ON FUNCTION ${CAT}.governance.mask_salary_avg   TO `${DBX_SP_APP_ID}`;

ALTER TABLE ${CAT}.silver.silver_hr_employee
  ALTER COLUMN salary_annual SET MASK ${CAT}.governance.mask_salary;
ALTER TABLE ${CAT}.silver.silver_hr_employee
  ALTER COLUMN email SET MASK ${CAT}.governance.mask_email;
ALTER TABLE ${CAT}.gold.gold_hr_headcount_by_department
  ALTER COLUMN total_salary SET MASK ${CAT}.governance.mask_salary_total;
ALTER TABLE ${CAT}.gold.gold_hr_headcount_by_department
  ALTER COLUMN avg_salary SET MASK ${CAT}.governance.mask_salary_avg;
