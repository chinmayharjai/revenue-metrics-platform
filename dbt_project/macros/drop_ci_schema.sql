{% macro drop_ci_schema(schema_suffix) %}
    {#
        Drop the schema a CI run built into.

        Called from .github/workflows/ci.yml with `if: always()`, so it runs even
        when the build failed — which is precisely when a schema is most likely to
        be orphaned. Without it, every failed PR leaks a CI_<run_id> schema and the
        account slowly fills with them, each holding a full copy of the marts.

        Three guards, because a run-operation that takes a name and drops it is one
        typo away from being a very efficient way to delete production:

          1. The suffix must be non-empty.
          2. The resulting name must start with CI_.
          3. The target must be `ci`, so pointing this at prod is a compile error
             rather than an outage.

        They cost a few lines and remove the whole class of accident.
    #}

    {% set target_schema = 'CI_' ~ schema_suffix %}

    {% if not schema_suffix or schema_suffix | length < 1 %}
        {{ exceptions.raise_compiler_error(
            "drop_ci_schema requires a non-empty schema_suffix"
        ) }}
    {% endif %}

    {% if not target_schema.startswith('CI_') %}
        {{ exceptions.raise_compiler_error(
            "Refusing to drop " ~ target_schema ~ " — only CI_* schemas may be dropped by this macro"
        ) }}
    {% endif %}

    {% if target.name != 'ci' %}
        {{ exceptions.raise_compiler_error(
            "drop_ci_schema may only run against the ci target, not " ~ target.name
        ) }}
    {% endif %}

    {% set drop_sql %}
        drop schema if exists {{ target.database }}.{{ target_schema }} cascade
    {% endset %}

    {% do log("Dropping " ~ target.database ~ "." ~ target_schema, info=True) %}
    {% do run_query(drop_sql) %}
    {% do log("Dropped " ~ target_schema, info=True) %}

{% endmacro %}
