-- Silver's entire purpose is the reduction to one current row per key.
-- If this fails, every gold number built on it is multiplied and nothing
-- downstream will say so.
SELECT 'silver_hr_employee' AS model, CAST(employee_id AS STRING) AS k, COUNT(*) AS n
FROM {{ ref('silver_hr_employee') }} GROUP BY 1, 2 HAVING COUNT(*) > 1
UNION ALL
SELECT 'silver_hr_department', CAST(dept_id AS STRING), COUNT(*)
FROM {{ ref('silver_hr_department') }} GROUP BY 1, 2 HAVING COUNT(*) > 1
