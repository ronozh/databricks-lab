-- An INVARIANT: true for any input volume, not a fact about one dataset.
--
-- Every currently-employed person in silver must be counted exactly once in
-- gold. If the gold join fans out, or a department goes missing, the totals
-- diverge.
--
-- The NULL branch is not decoration. SUM() over an empty table returns NULL,
-- and `478 <> NULL` is UNKNOWN -- so the first version PASSED when gold was
-- entirely empty. Proven by deleting all 16 gold rows and watching it stay
-- green. A test that survives the total loss of the thing it checks is not a
-- test.
WITH expected AS (
    SELECT COUNT(*) AS n FROM {{ ref('silver_hr_employee') }} WHERE is_employed
),
actual AS (
    SELECT SUM(headcount_people) AS n, COUNT(*) AS rows_in_gold
    FROM {{ ref('gold_hr_headcount_by_department') }}
)
SELECT e.n AS expected, a.n AS actual, a.rows_in_gold
FROM expected e CROSS JOIN actual a
WHERE a.n IS NULL            -- gold empty, or headcount_people all NULL
   OR a.rows_in_gold = 0
   OR e.n <> a.n
