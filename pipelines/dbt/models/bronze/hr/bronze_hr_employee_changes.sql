{#
    The change log: what happened to an employee, and when we were told.

    `event_date` is when the change took effect; `received_date` is when it
    arrived. They differ by design -- the generator delays a share of changes by
    1-14 days. That gap is the reason the roster alone cannot date a change to
    the day it happened, and it is the seed of the as-of work in later phases.

    Many of these files are legitimately EMPTY (record_count 0). An empty
    delivery is still a delivery: it says "nothing changed", which is different
    from "no file arrived".
#}
WITH src AS (
    SELECT *, {{ provenance_columns() }}
    FROM {{ read_landing('employee_changes', schema='employee_id STRING, event_date STRING, attribute_name STRING, old_value STRING, new_value STRING, received_date STRING') }}
)
SELECT
    CAST(employee_id   AS BIGINT) AS employee_id,
    CAST(event_date    AS DATE)   AS event_date,
    attribute_name,
    old_value,
    new_value,
    CAST(received_date AS DATE)   AS received_date,
    _file_path, _file_name, _file_size, _file_last_modified, _file_date,
    _processed_timestamp,
    -- Anything that did not fit the declared schema. Must always be NULL;
    -- assert_no_rescued_data.sql fails if it is not.
    _rescued_data
FROM src
{{ unloaded_files_only() }}
