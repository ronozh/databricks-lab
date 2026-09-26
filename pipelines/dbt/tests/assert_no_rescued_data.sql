-- Schema drift detector.
--
-- The explicit read schema binds by POSITION, not by header name -- that is the
-- cost of the 96x speedup. rescuedDataColumn captures anything that does not fit
-- the declared shape, so an added or removed upstream column shows up here
-- instead of silently shifting every value one place.
--
-- It does NOT catch a pure reorder of two same-typed columns; that is what
-- assert_landing_headers_match.sql is for.
{% set models = [
    'bronze_hr_employee', 'bronze_hr_department', 'bronze_hr_employee_changes',
    'bronze_hr_employee_ctrl', 'bronze_hr_department_ctrl', 'bronze_hr_employee_changes_ctrl',
] %}
{% for m in models %}
{% if not loop.first %}UNION ALL{% endif %}
SELECT '{{ m }}' AS model, _file_name, _rescued_data
FROM {{ ref(m) }} WHERE _rescued_data IS NOT NULL
{% endfor %}
