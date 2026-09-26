{#
    The control sidecar for the employee_changes feed, loaded as a first-class table.

    The producer writes one .ctrl beside every data file declaring how many rows
    it should contain and the md5 of its bytes. That sidecar is the delivery
    CONTRACT, and checking it is what makes a truncated file fail loudly instead
    of quietly under-reporting.

    It is loaded rather than merely read because the check must be auditable
    later: "we verified this" is a claim that needs evidence with a timestamp.
#}
WITH src AS (
    SELECT *, {{ provenance_columns() }}
    FROM {{ read_landing('employee_changes', schema='file_name STRING, record_count STRING, md5 STRING, business_date STRING, feed STRING, domain STRING', glob='*.ctrl') }}
)
SELECT
    file_name,
    CAST(record_count  AS BIGINT) AS record_count,
    md5,
    CAST(business_date AS DATE)   AS business_date,
    feed,
    domain,
    _file_path, _file_name, _file_size, _file_last_modified, _file_date,
    _processed_timestamp,
    -- Anything that did not fit the declared schema. Must always be NULL;
    -- assert_no_rescued_data.sql fails if it is not.
    _rescued_data
FROM src
{{ unloaded_files_only() }}
