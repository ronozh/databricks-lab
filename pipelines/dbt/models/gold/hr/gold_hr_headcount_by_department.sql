{#
    "How many people work in each department, and what does it cost?"

    Named for the question, not for the tables. Gold is the only layer allowed
    to join, because joining is integration and integration is an opinion -- and
    this model holds several worth stating out loud:

      * Headcount counts CURRENT employees only (is_employed). A leaver is not
        headcount, but their history is still in bronze.
      * A department with nobody in it still appears, with zero. Absence is an
        answer; an inner join would hide it.
      * Salary is annual gross, unweighted by employment_type. A part-timer
        counts as one person. Finance would disagree -- and that disagreement
        is exactly the conformance problem Phase 8 exists to solve.
#}
WITH staff AS (
    SELECT dept_id, employee_id, salary_annual, is_people_manager, employment_type
    FROM {{ ref('silver_hr_employee') }}
    WHERE is_employed
),
by_dept AS (
    SELECT
        dept_id,
        COUNT(*)                                                     AS headcount,
        SUM(CASE WHEN is_people_manager THEN 1 ELSE 0 END)           AS managers,
        SUM(CASE WHEN employment_type = 'full_time' THEN 1 ELSE 0 END) AS full_time,
        ROUND(SUM(salary_annual), 2)                                 AS total_salary,
        ROUND(AVG(salary_annual), 2)                                 AS avg_salary
    FROM staff
    GROUP BY dept_id
)
SELECT
    d.dept_id,
    d.dept_code,
    d.dept_name,
    d.cost_centre,
    d.is_active                             AS department_active,
    COALESCE(b.headcount, 0)                AS headcount,
    COALESCE(b.managers, 0)                 AS managers,
    COALESCE(b.full_time, 0)                AS full_time,
    COALESCE(b.total_salary, 0)             AS total_salary,
    b.avg_salary
FROM {{ ref('silver_hr_department') }} d
LEFT JOIN by_dept b ON b.dept_id = d.dept_id
