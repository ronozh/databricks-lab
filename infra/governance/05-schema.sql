-- The governance schema: access-control functions, the department access map, and
-- the stewardship register. Separate from bronze/silver/gold because it is not
-- data about the business -- it is data about who may see the business.
CREATE SCHEMA IF NOT EXISTS ${CAT}.governance
  COMMENT 'Access-control functions, the department access map, and the stewardship register.';

-- The pipeline binds the masks and row filters (dbt reconciles them every run), and
-- binding requires USE SCHEMA here plus EXECUTE on each function. Reading through a
-- control requires neither -- definer rights -- so this grant is about the WRITE
-- path only. It was applied by hand during the build and existed in no script, which
-- meant a freshly created catalog could be granted access and then fail to protect
-- any of it.
GRANT USE SCHEMA ON SCHEMA ${CAT}.governance TO `${DBX_SP_APP_ID}`;
