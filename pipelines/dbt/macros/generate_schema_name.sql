{#
    dbt's default prepends the profile's schema to any custom +schema, giving
    `bronze_bronze`, `bronze_silver`, `bronze_gold`. That default exists so
    several developers can share one warehouse without colliding.

    This lab has one target and names its layers deliberately, so the custom
    schema is used verbatim. If multi-developer isolation is ever needed, it
    belongs in the catalog name (a bundle variable), not smuggled into the
    schema.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
