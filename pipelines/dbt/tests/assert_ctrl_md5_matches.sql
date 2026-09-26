-- The other half of the delivery contract, and the watermark's only backstop.
--
-- The watermark is (path, modification time). It cannot see a file whose BYTES
-- changed while both stayed the same -- and three documents previously claimed
-- the md5 covered that gap while no code computed one.
--
-- It does now. binaryFile gives the content; md5() over it is compared against
-- what the producer declared.
WITH on_disk AS (
    SELECT REGEXP_EXTRACT(path, '([^/]+)$', 1) AS file_name,
           LOWER(MD5(content))                 AS actual_md5
    FROM {{ landing_files('*.csv') }}
),
declared AS (
    SELECT file_name, LOWER(md5) AS declared_md5 FROM {{ ref('bronze_hr_employee_ctrl') }}
    UNION ALL SELECT file_name, LOWER(md5) FROM {{ ref('bronze_hr_department_ctrl') }}
    UNION ALL SELECT file_name, LOWER(md5) FROM {{ ref('bronze_hr_employee_changes_ctrl') }}
)
SELECT d.file_name, d.declared_md5, o.actual_md5
FROM declared d
JOIN on_disk o ON o.file_name = d.file_name
WHERE d.declared_md5 IS NULL OR d.declared_md5 <> o.actual_md5
