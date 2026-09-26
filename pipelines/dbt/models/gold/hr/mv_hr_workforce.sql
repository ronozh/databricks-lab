{{ config(
    materialized='metric_view',
    post_hook=[
      "COMMENT ON VIEW {{ this }} IS 'The governed semantic layer for the workforce. Three competing definitions of headcount, each named for its rule. Consumers call measure(); Genie and the AI/BI dashboard both read this so they cannot compute the same word two ways.'",
      "COMMENT ON COLUMN {{ this }}.headcount_people IS 'Currently-employed people, one row per person. A part-timer counts as one.'",
      "COMMENT ON COLUMN {{ this }}.headcount_fte IS 'FTE-weighted: full_time counts 1, everything else 0.5. THERE IS NO FTE COLUMN IN THE DATA, so this weighting IS the definition -- it needs a business owner, not whoever wrote this file.'",
      "COMMENT ON COLUMN {{ this }}.headcount_fulltime IS 'Employees whose employment_type is full_time only.'",
      "COMMENT ON COLUMN {{ this }}.manager_count IS 'Currently-employed people flagged is_people_manager (job grade L5+).'",
      "COMMENT ON COLUMN {{ this }}.salary_total IS 'Restricted. Sum of annual gross salary, unweighted by employment_type. NULL outside hr_stewards/hr_platform is a permission outcome, not missing data.'",
      "COMMENT ON COLUMN {{ this }}.salary_avg IS 'Restricted, as salary_total. Mean annual gross across visible rows.'",
    ]
) }}
{#
    WHY THESE COMMENTS ARE POST-HOOKS AND NOT `description:` IN THE YML

    Both of the obvious routes are dead ends, measured:

      * `persist_docs` does NOT reach a metric view. It works on a `table` model -- the
        descriptions in _gold_hr.yml landed on gold_hr_headcount_by_department -- but the
        `metric_view` materialization never calls it, so every yml description here was
        SILENTLY INERT. Same shape as Phase 2's column masks, which are wired only into
        the alter path and so never apply to a `table` model.
      * A metric view's YAML has no `comment` field. The parser says so explicitly:
        "Unrecognized field \"comment\" ... (4 known properties: window, partition,
        name, expr)".

    `COMMENT ON COLUMN` and `COMMENT ON VIEW` both work on a metric view, so the
    descriptions are applied explicitly. They are duplicated in _gold_hr.yml for dbt docs;
    THE POST-HOOKS ARE WHAT REACHES UNITY CATALOG, and Phase 7's DataHub glossary reads
    the metastore, not dbt.
#}
{#
    The semantic layer for the workforce.

    ONE view, THREE competing definitions of headcount -- each named for what it
    counts, none of them called `headcount`. That naming is the whole point: a bare
    `headcount` would be this pipeline silently deciding, on the business's behalf,
    which of three correct answers is THE answer.

      headcount_people    478    a person is a person
      headcount_fte       447.0  non-full-time counts 0.5
      headcount_fulltime  416    only full-time counts

    All three are defensible and they disagree. There is no FTE column in the
    data, so the WEIGHTING IS THE DEFINITION -- which is why it belongs to a
    business owner rather than to whoever wrote this file. Recording that
    ownership is the CDE register's job, deferred to 99.6b; naming the measures
    honestly is enforceable here, today, and does not wait for it.

    This is a metric view, not a table: consumers call measure(), and the
    aggregation lives here instead of in each consumer's SQL. That is what stops
    Genie and a dashboard from computing "headcount" two different ways.

    It lives in gold because it JOINS (employee -> department for the name), and
    gold is the only layer allowed to join.

    GOVERNANCE IS INHERITED FROM WHAT A VIEW ACTUALLY READS -- and that is the whole
    lesson, because the first version of this view got it wrong in a way that leaked.

    MEASURED, so neither half is a guess:
      * A plain view over the row-filtered gold table DOES inherit the row filter, and
        it evaluates AS THE CALLER, not as the view's owner: biz-analyst reads 2
        departments / 70 people, hr-analyst reads 16 / 478, through a view owned by a
        filter-EXEMPT principal. Column masks behave identically.
      * So a view does NOT drop controls. What went wrong here was different and
        simpler: this view reads silver_hr_employee, which carries NO row filter --
        Phase 2 bound filter_dept to gold_hr_headcount_by_department, a DIFFERENT table
        this view never touches. The first version therefore READ AROUND the control by
        sourcing an ungoverned upstream table, and handed biz-analyst all 478 employees.

    Masks came through (salary_total was correctly NULL), which is exactly what made it
    look governed while the row-level control was simply not in the path.

    ALTER VIEW ... SET ROW FILTER does not parse -- row filters bind to tables only --
    so the predicate lives in this view's own `filter:` below, calling the SAME function
    the gold table binds. current_user() inside a view resolves to the CALLER (measured),
    which is what makes it work.

    THE RULE: a view inherits the controls of the securables it READS. So the question
    is never "is this a new object, must I re-declare everything" -- it is "WHICH tables
    am I reading, and are the controls I need bound to THOSE tables?" Reading silver to
    serve a gold-governed audience is the mistake; re-expressing the control, or reading
    the governed table instead, are both valid fixes.
#}
version: 0.1

source: {{ ref('silver_hr_employee') }}

filter: is_employed AND {{ target.database }}.governance.filter_dept(dept_id)

joins:
  - name: dept
    source: {{ ref('silver_hr_department') }}
    on: source.dept_id = dept.dept_id

dimensions:
  - name: Department
    expr: dept.dept_name
  - name: Cost centre
    expr: dept.cost_centre
  - name: Employment type
    expr: source.employment_type
  - name: Job grade
    expr: source.job_grade
  - name: Location
    expr: source.location_code
  - name: Department is active
    expr: dept.is_active
  - name: Is people manager
    expr: source.is_people_manager

measures:
  # -- the three competing definitions, each named for its rule --------------
  - name: headcount_people
    expr: count(1)
  - name: headcount_fte
    expr: sum(case when source.employment_type = 'full_time' then 1 else 0.5 end)
  - name: headcount_fulltime
    expr: count_if(source.employment_type = 'full_time')

  # -- compensation. Masked for anyone outside hr_stewards/hr_platform, so these
  #    return NULL rather than a wrong number -- see Phase 2's owner exemption.
  - name: salary_total
    expr: sum(source.salary_annual)
  - name: salary_avg
    expr: avg(source.salary_annual)

  - name: manager_count
    expr: count_if(source.is_people_manager)
