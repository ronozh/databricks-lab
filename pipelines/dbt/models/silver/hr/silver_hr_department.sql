{#
    Current department attributes -- one row per department.

    Same reduction as silver_hr_employee, and the same prohibition: this model
    does NOT resolve parent_dept_id into a name, because that is a self-join and
    self-joins are still joins. The hierarchy is assembled in gold.

    THE ORDER BY NEEDS THREE KEYS, AND THE MIDDLE ONE IS NOT WHAT IT LOOKS LIKE.

    `current_timestamp()` is evaluated ONCE PER QUERY, so _processed_timestamp is
    identical across every row written by a single build -- measured: 1 distinct
    value across 17,725 rows and 32 files. It orders rows ACROSS runs and
    resolves nothing WITHIN one.

    This model previously ordered by (snapshot_date, _processed_timestamp) only,
    which on a first load is effectively snapshot_date alone. The landing rule
    says "a correction is a NEW file, never an overwrite" -- so a correction and
    the row it corrects arrive on the SAME snapshot_date, and the model returned
    the stale one. Silently.

    _file_last_modified breaks that tie the way the landing design intends: the
    later delivery wins. _file_path is the final deterministic fallback so the
    answer cannot change between runs.
#}
WITH ranked AS (
    SELECT
        dept_id, dept_code, dept_name, parent_dept_id, is_active,
        cost_centre, location_code, snapshot_date,
        _file_path, _file_name, _file_last_modified, _processed_timestamp,
        ROW_NUMBER() OVER (
            PARTITION BY dept_id
            ORDER BY snapshot_date        DESC,
                     _file_last_modified  DESC,
                     _processed_timestamp DESC,
                     _file_path           DESC
        ) AS _recency
    FROM {{ ref('bronze_hr_department') }}
)
SELECT * EXCEPT (_recency)
FROM ranked
WHERE _recency = 1
