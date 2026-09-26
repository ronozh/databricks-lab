-- Presence, not count.
--
-- A file declaring record_count = 0 -- 269 of 730 in the change feed -- is
-- indistinguishable by row count from one that never arrived. Counting cannot
-- tell "nothing changed" from "no delivery", and the docs single out exactly
-- that distinction as the interesting one.
--
-- So assert against the Volume listing instead. This also turns the README's
-- manual "794 files accounted for" into something executable.
--
-- NOTE ON THE JOIN KEY, which the first version of this test got wrong: a
-- sidecar's `file_name` column names the DATA FILE it describes (`....csv`),
-- not the sidecar itself (`....ctrl`). Comparing it to on-disk .ctrl basenames
-- matches nothing and fails on all 1,588 files. Compare declared names to the
-- .csv objects on disk.
WITH csv_on_disk AS (
    SELECT REGEXP_EXTRACT(path, '([^/]+)$', 1) AS file_name
    FROM {{ landing_files('*.csv') }}
),
declared AS (
    SELECT file_name FROM {{ ref('bronze_hr_employee_ctrl') }}
    UNION ALL SELECT file_name FROM {{ ref('bronze_hr_department_ctrl') }}
    UNION ALL SELECT file_name FROM {{ ref('bronze_hr_employee_changes_ctrl') }}
)
-- A data file arrived that no sidecar declares: an undeclared delivery.
SELECT o.file_name, 'delivered, but no .ctrl declares it' AS reason
FROM csv_on_disk o
LEFT JOIN declared d ON d.file_name = o.file_name
WHERE d.file_name IS NULL
UNION ALL
-- A sidecar declares a file that is not there: a lost or never-sent delivery.
SELECT d.file_name, 'declared by a .ctrl, but not on disk'
FROM declared d
LEFT JOIN csv_on_disk o ON o.file_name = d.file_name
WHERE o.file_name IS NULL
