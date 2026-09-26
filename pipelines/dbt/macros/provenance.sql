{#
    Provenance and the incremental watermark.

    Every bronze row must be traceable to the file that produced it. That is what
    makes a delivery auditable rather than merely loaded, and it is the foundation
    the watermark is built on.
#}

{% macro provenance_columns() %}
    {#- FIVE columns. local-lab had six; there is no content hash here, because
        _metadata does not expose one -- see md5 reconciliation in the tests. -#}
    _metadata.file_path                     AS _file_path,
    _metadata.file_name                     AS _file_name,
    _metadata.file_size                     AS _file_size,
    _metadata.file_modification_time        AS _file_last_modified,
    {{ file_date_from_path() }}             AS _file_date,
    current_timestamp()                     AS _processed_timestamp
{% endmacro %}


{% macro file_date_from_path() %}
    {#- The business date is the directory name: .../<feed>/2025-01-31/<file>.csv
        Taken from the PATH rather than a column, because the path is the
        delivery's own statement about which day it represents. When a column
        disagrees with it, that disagreement is a finding -- and
        assert_path_and_column_dates_agree.sql is what turns "is a finding" into
        something that actually fires. -#}
    TRY_CAST(REGEXP_EXTRACT(_metadata.file_path, '/(\\d{4}-\\d{2}-\\d{2})/', 1) AS DATE)
{% endmacro %}


{% macro unloaded_files_only() %}
    {#- The watermark: a file is loaded once, identified by PATH and modification
        time together.

        _file_path, not _file_name. `_metadata.file_name` is the BASENAME, so a
        watermark on it is unique per basename rather than per object: the same
        file name delivered under two business dates would silently skip the
        second. Latent today (1,588 files, 1,588 distinct basenames) and free to
        prevent.

        NOT EXISTS, not NOT IN. `x NOT IN (SELECT ...)` evaluates to UNKNOWN if
        the subquery yields a single NULL, so ONE null provenance value would
        make this predicate false for every candidate row -- ingestion silently
        stops, dbt stays green, and nothing errors. Exactly the failure class
        this project cares most about.

        WHAT IT CANNOT SEE: a file whose bytes changed while path and mtime did
        not. No metadata-based watermark can. That is what the .ctrl md5 check
        is for -- and it is implemented, in
        assert_ctrl_md5_matches.sql, not merely promised. -#}
    {% if is_incremental() %}
        WHERE NOT EXISTS (
            SELECT 1 FROM {{ this }} t
            WHERE t._file_path          = src._file_path
              AND t._file_last_modified = src._file_last_modified
        )
    {% endif %}
{% endmacro %}


{% macro read_landing(feed, schema, glob='*.csv') %}
    {#- The landing layer is the Volume itself. read_files() is the batch reader;
        it exposes _metadata, which is what makes provenance possible.

        Not COPY INTO: it tracks loaded files for you -- convenient, and it hides
        the mechanism this lab exists to show. Not Auto Loader: measured at ~67s
        of DLT pipeline startup per table against a 76s whole build, so it is
        deferred to the PySpark phase where Trigger.AvailableNow costs nothing.

        The glob is not optional. Data files and .ctrl sidecars share a directory,
        so without it every control file is parsed as a data row.

        AN EXPLICIT SCHEMA, AND WHAT IT COSTS. Inference opens every file to read
        its header; this feed is 730 files of ~7 rows, which took 27 minutes and
        then failed. Declaring the schema takes 17 seconds.

        The trade is real and was not obvious: inference binds columns by HEADER
        NAME, an explicit schema binds them by POSITION. With a declared schema
        the header line is skipped, not checked -- so if the producer reorders two
        same-typed columns, every value lands in the wrong column with no error,
        correct row counts, and green tests.

        rescuedDataColumn is therefore not optional either: it captures anything
        that does not fit the declared shape, and
        assert_no_rescued_data.sql fails if it is ever non-empty. It
        catches an added or removed column. It does NOT catch a pure reorder of
        same-typed columns -- assert_landing_headers_match.sql does that,
        by reading line 1 as text and comparing it. -#}
    read_files(
        '{{ var("landing_volume") }}/{{ feed }}',
        format            => 'csv',
        header            => true,
        schema            => '{{ schema }}',
        rescuedDataColumn => '_rescued_data',
        pathGlobFilter    => '{{ glob }}'
    )
{% endmacro %}


{% macro landing_files(glob='*') %}
    {#- Every object in the landing Volume, as a table.

        binaryFile gives one row per file with its content, which is what makes
        both a presence check and an md5 comparison possible -- the two things
        that turn "794 files accounted for" from a manual count into an
        assertion. -#}
    read_files('{{ var("landing_volume") }}', format => 'binaryFile',
               pathGlobFilter => '{{ glob }}', recursiveFileLookup => true)
{% endmacro %}
