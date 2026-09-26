{#
    The nightly roster, as delivered. One row per employee per snapshot date.

    Bronze does not filter, derive or deduplicate. If a row is in the file it is
    here. Losing a row at this layer makes the delivery unauditable -- and the
    roster is a SCD source, so "duplicates" across snapshot dates are the point,
    not a defect.
#}
WITH src AS (
    SELECT *, {{ provenance_columns() }}
    FROM {{ read_landing('employee', schema='employee_id STRING, employee_number STRING, first_name STRING, last_name STRING, email STRING, job_grade STRING, is_people_manager STRING, job_title STRING, salary_annual STRING, hire_date STRING, employment_type STRING, is_employed STRING, dept_id STRING, manager_id STRING, location_code STRING, home_city STRING, home_state STRING, home_postcode STRING, date_of_birth STRING, gender STRING, snapshot_date STRING') }}
)
SELECT
    CAST(employee_id       AS BIGINT)  AS employee_id,
    employee_number,
    first_name,
    last_name,
    email,
    job_grade,
    CAST(is_people_manager AS BOOLEAN) AS is_people_manager,
    job_title,
    CAST(salary_annual     AS DECIMAL(12,2)) AS salary_annual,
    CAST(hire_date         AS DATE)    AS hire_date,
    employment_type,
    CAST(is_employed       AS BOOLEAN) AS is_employed,
    CAST(dept_id           AS BIGINT)  AS dept_id,
    CAST(manager_id        AS BIGINT)  AS manager_id,
    location_code,
    home_city,
    home_state,
    home_postcode,
    CAST(date_of_birth     AS DATE)    AS date_of_birth,
    gender,
    CAST(snapshot_date     AS DATE)    AS snapshot_date,
    _file_path, _file_name, _file_size, _file_last_modified, _file_date,
    _processed_timestamp,
    -- Anything that did not fit the declared schema. Must always be NULL;
    -- assert_no_rescued_data.sql fails if it is not.
    _rescued_data
FROM src
{{ unloaded_files_only() }}
