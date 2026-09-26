-- "The path is the delivery's own statement about which day it represents.
--  When a column disagrees with it, that disagreement is a finding."
--
-- The documents said that; nothing checked it. These five comparisons are
-- cheap, all currently hold, and all can genuinely fail -- which is more than
-- can be said for the structural uniqueness tests.
SELECT 'employee: _file_date <> snapshot_date' AS check_name,
       _file_name, CAST(_file_date AS STRING) AS a, CAST(snapshot_date AS STRING) AS b
FROM {{ ref('bronze_hr_employee') }} WHERE _file_date <> snapshot_date
UNION ALL
SELECT 'department: _file_date <> snapshot_date',
       _file_name, CAST(_file_date AS STRING), CAST(snapshot_date AS STRING)
FROM {{ ref('bronze_hr_department') }} WHERE _file_date <> snapshot_date
UNION ALL
SELECT 'changes_ctrl: business_date <> _file_date',
       _file_name, CAST(business_date AS STRING), CAST(_file_date AS STRING)
FROM {{ ref('bronze_hr_employee_changes_ctrl') }} WHERE business_date <> _file_date
UNION ALL
-- The sidecar must name the data file it describes.
SELECT 'changes_ctrl: file_name does not match its sidecar',
       _file_name, file_name, REPLACE(_file_name, '.ctrl', '.csv')
FROM {{ ref('bronze_hr_employee_changes_ctrl') }}
WHERE file_name <> REPLACE(_file_name, '.ctrl', '.csv')
UNION ALL
-- A change cannot be received before it happened.
SELECT 'changes: event_date after received_date',
       _file_name, CAST(event_date AS STRING), CAST(received_date AS STRING)
FROM {{ ref('bronze_hr_employee_changes') }} WHERE event_date > received_date
