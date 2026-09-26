-- Row filters. A filter is a UC function returning BOOLEAN, bound to a table;
-- rows for which it is false disappear. No error, no warning, no row count hint.
--
-- The allowlist lives in a TABLE rather than in the function body, so changing
-- who sees what is a DML statement and not a deployment.

CREATE TABLE IF NOT EXISTS ${CAT}.governance.dept_access (
  principal   STRING  COMMENT 'current_user(): an email for a human, an applicationId for a service principal',
  dept_id     BIGINT  COMMENT 'FK to silver_hr_department.dept_id',
  granted_by  STRING  COMMENT 'who authorised this row',
  granted_on  DATE    COMMENT 'when -- an access review needs a date'
) COMMENT 'Which principal may see which department. Read by filter_dept on every query.';

-- Idempotent reload: this is the whole access map, so it is replaced WHOLESALE. The
-- DELETE was scoped to one principal, which is not a reload at all -- a row for a
-- departed principal survived every re-apply forever, which is precisely the silent
-- leak this comment claimed to prevent.
DELETE FROM ${CAT}.governance.dept_access;
INSERT INTO ${CAT}.governance.dept_access VALUES
  ('${BIZ_ANALYST_APP_ID}', 1, '${DBX_HUMAN_PRINCIPAL}', current_date()),
  ('${BIZ_ANALYST_APP_ID}', 2, '${DBX_HUMAN_PRINCIPAL}', current_date());

-- Three exemptions and one lookup. The exemptions are group-based so they survive
-- people joining and leaving; the lookup is per-principal because department
-- ownership genuinely is per-person.
--
-- hr_platform is exempt for the same reason it is exempt from the masks: without
-- it the pipeline reads its own gold table as EMPTY -- measured, 0 of 16 rows --
-- and every downstream reconciliation test then compares silver against nothing.
--
-- The parameter is p_dept_id, NOT dept_id, and the prefix is load-bearing. Named
-- dept_id, the unqualified reference inside the correlated subquery resolves to
-- a.dept_id -- the predicate becomes a.dept_id = a.dept_id, every row passes, and
-- the filter permits EVERYTHING while looking correct. Measured: gotcha.md #4.
CREATE OR REPLACE FUNCTION ${CAT}.governance.filter_dept(p_dept_id BIGINT)
  RETURN is_member('hr_stewards')
      OR is_member('hr_platform')
      OR is_member('hr_analysts')
      OR exists (SELECT 1 FROM ${CAT}.governance.dept_access a
                  WHERE a.principal = current_user() AND a.dept_id = p_dept_id);

-- NO `SET ROW FILTER` here either -- see the note at the end of 30-masks.sql.
-- The binding is declared in pipelines/dbt/models/gold/hr/_gold_hr.yml.

-- EXECUTE for the pipeline, granted HERE and not in 10-roles.sh, because
-- CREATE OR REPLACE FUNCTION DISCARDS the function's grants -- measured: after
-- replacing filter_dept, SHOW GRANTS returned nothing. A grant in an earlier step
-- would be silently undone by this one. The pipeline needs EXECUTE not to READ
-- through the control (masks and filters evaluate with definer rights) but to
-- BIND it: dbt's ALTER ... SET ROW FILTER fails with PERMISSION_DENIED without it.
GRANT EXECUTE ON FUNCTION ${CAT}.governance.filter_dept TO `${DBX_SP_APP_ID}`;
