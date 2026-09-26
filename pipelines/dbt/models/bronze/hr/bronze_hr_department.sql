{#
    The org chart, as delivered. parent_dept_id points at another row of this
    same table -- the hierarchy Phase 6 and the gold layer both rely on.
#}
WITH src AS (
    SELECT *, {{ provenance_columns() }}
    FROM {{ read_landing('department', schema='dept_id STRING, dept_code STRING, dept_name STRING, parent_dept_id STRING, is_active STRING, cost_centre STRING, location_code STRING, snapshot_date STRING') }}
)
SELECT
    CAST(dept_id        AS BIGINT)  AS dept_id,
    dept_code,
    dept_name,
    CAST(parent_dept_id AS BIGINT)  AS parent_dept_id,
    CAST(is_active      AS BOOLEAN) AS is_active,
    cost_centre,
    location_code,
    CAST(snapshot_date  AS DATE)    AS snapshot_date,
    _file_path, _file_name, _file_size, _file_last_modified, _file_date,
    _processed_timestamp,
    -- Anything that did not fit the declared schema. Must always be NULL;
    -- assert_no_rescued_data.sql fails if it is not.
    _rescued_data
FROM src
{{ unloaded_files_only() }}
