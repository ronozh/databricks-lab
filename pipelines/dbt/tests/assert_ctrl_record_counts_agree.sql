-- The delivery contract, enforced -- in BOTH directions.
--
-- Every data file ships with a .ctrl sidecar declaring how many rows it should
-- contain. This compares declared against loaded, per file. Zero rows = pass.
--
-- The first version had three independent ways to pass on wrong data:
--
--   1. A NULL declared count. `COALESCE(loaded,0) <> NULL` is UNKNOWN, so the
--      row was discarded and the test passed. Proven: 299 of 500 rows loaded,
--      record_count set to NULL, test green. A blank field in a .ctrl parses to
--      NULL, so this was reachable from real producer output.
--
--   2. No sidecar at all. The query was ctrl LEFT JOIN bronze, so bronze rows
--      from a file with no .ctrl were invisible. Proven: 50 phantom rows
--      inserted, test green. Reachable whenever a producer writes the .csv and
--      dies before the .ctrl -- they are two separate objects.
--
--   3. A declared count of zero. 269 of the 730 change files declare 0, where
--      "empty as intended" and "never arrived" are indistinguishable by count.
--      Presence is asserted separately, in assert_ctrl_files_present.sql.
--
-- A FULL OUTER JOIN closes 1 and 2; the explicit NULL branch closes the rest.
{% set feeds = [
    ('bronze_hr_employee',         'bronze_hr_employee_ctrl'),
    ('bronze_hr_department',       'bronze_hr_department_ctrl'),
    ('bronze_hr_employee_changes', 'bronze_hr_employee_changes_ctrl'),
] %}

{% for data_model, ctrl_model in feeds %}
{% if not loop.first %}UNION ALL{% endif %}
SELECT
    '{{ data_model }}'                                   AS model,
    COALESCE(c.file_name, d.file_name)                   AS file_name,
    c.record_count                                       AS declared,
    d.loaded                                             AS loaded,
    CASE WHEN c.file_name IS NULL      THEN 'bronze rows with no .ctrl'
         WHEN c.record_count IS NULL   THEN 'declared count is NULL'
         WHEN COALESCE(d.loaded,0) <> c.record_count
                                       THEN 'declared <> loaded'
    END                                                  AS reason
FROM {{ ref(ctrl_model) }} c
FULL OUTER JOIN (
    SELECT _file_name AS file_name, COUNT(*) AS loaded
    FROM {{ ref(data_model) }}
    GROUP BY _file_name
) d ON d.file_name = c.file_name
WHERE c.file_name IS NULL                      -- loaded but never declared
   OR c.record_count IS NULL                   -- declared, but declared nothing
   OR COALESCE(d.loaded, 0) <> c.record_count  -- declared <> loaded
{% endfor %}
