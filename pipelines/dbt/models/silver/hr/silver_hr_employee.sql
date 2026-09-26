{#
    Current employee attributes -- one row per employee.

    Bronze holds 32 restatements of every employee across the two-year epoch.
    Joining that unfiltered multiplies every result by the number of snapshots
    loaded. Reducing it to the current version is this model's whole job.

    MATERIALIZED (D3), unlike local-lab's ephemeral silver: on Delta a table is
    cheap, inspectable, and visible in lineage.

    SILVER MAY NOT JOIN. It may select, filter and window -- this one windows --
    but integration is an opinion, and opinions belong in gold where a consumer
    can accept them or read bronze instead.

    ORDER BY: see silver_hr_department for why _file_last_modified must come
    before _processed_timestamp. The short version is that current_timestamp()
    is constant within a query, so _processed_timestamp cannot break a tie
    created during a single build.

    PROVENANCE IS CARRIED THROUGH on purpose. In a project whose thesis is that
    every row traces to its delivery, a silver row that cannot name its source
    file makes the dedup decision above unauditable from its own output.

    date_of_birth is DROPPED, deliberately: nothing downstream needs it, and it
    is the one column here with no analytical use and a real disclosure cost.
    email, gender and home_postcode are retained because gold and later phases
    use them -- they are handled by masking in Phase 2 rather than by omission.
#}
WITH ranked AS (
    SELECT
        employee_id, employee_number, first_name, last_name, email,
        job_grade, is_people_manager, job_title, salary_annual,
        hire_date, employment_type, is_employed, dept_id, manager_id,
        location_code, home_city, home_state, home_postcode, gender,
        snapshot_date,
        _file_path, _file_name, _file_last_modified, _processed_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY employee_id
            ORDER BY snapshot_date        DESC,
                     _file_last_modified  DESC,
                     _processed_timestamp DESC,
                     _file_path           DESC
        ) AS _recency
    FROM {{ ref('bronze_hr_employee') }}
)
SELECT * EXCEPT (_recency)
FROM ranked
WHERE _recency = 1
