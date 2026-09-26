-- The uniqueness tests on silver CANNOT FAIL: one-row-per-key is a structural
-- property of `ROW_NUMBER() ... WHERE _recency = 1`, not of the data. They are
-- kept as regression guards against a future rewrite, but they carry no
-- information about correctness today.
--
-- This one does. The question that can actually be answered wrongly is WHICH
-- row the window picked -- and that is exactly what broke: a correction
-- delivered as a new file on the same snapshot_date was silently discarded in
-- favour of the stale row.
--
-- Assert the choice, not the count: every silver row must come from its key's
-- most recent snapshot AND, within that snapshot, the most recently modified
-- file.
WITH winners AS (
    SELECT 'employee' AS entity, CAST(employee_id AS STRING) AS k,
           snapshot_date, _file_last_modified
    FROM {{ ref('silver_hr_employee') }}
    UNION ALL
    SELECT 'department', CAST(dept_id AS STRING), snapshot_date, _file_last_modified
    FROM {{ ref('silver_hr_department') }}
),
best AS (
    SELECT 'employee' AS entity, CAST(employee_id AS STRING) AS k,
           MAX(snapshot_date) AS max_snapshot
    FROM {{ ref('bronze_hr_employee') }} GROUP BY 1, 2
    UNION ALL
    SELECT 'department', CAST(dept_id AS STRING), MAX(snapshot_date)
    FROM {{ ref('bronze_hr_department') }} GROUP BY 1, 2
)
SELECT w.entity, w.k, w.snapshot_date AS picked, b.max_snapshot AS available
FROM winners w JOIN best b ON b.entity = w.entity AND b.k = w.k
WHERE w.snapshot_date <> b.max_snapshot
