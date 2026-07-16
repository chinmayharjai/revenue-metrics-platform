"""Stub implementations of the dbt_utils macros this project uses.

sqlfluff's jinja templater cannot expand real dbt package macros — those live in
dbt_packages/ and are only installed by `dbt deps` against a live project. Without
stubs, every model calling dbt_utils.* fails to template and the lint job reports a
templating error instead of telling you whether your SQL is valid.

These stubs do not need to be correct dbt. They need to render SQL of the right
*shape*, so that what sqlfluff parses is structurally what Snowflake will run:
the surrogate key must be a scalar expression, the date spine must be a
subqueryable SELECT with the column name dbt_utils actually produces.

Exposed to jinja by module name via library_path in .sqlfluff, which is why the
file is called dbt_utils.py — that name is the namespace models reference.
"""


def generate_surrogate_key(field_list):
    """A scalar expression. Real dbt_utils hashes; the shape is what matters here."""
    parts = " || '-' || ".join(
        f"coalesce(cast({field} as varchar), '_dbt_utils_surrogate_key_null_')"
        for field in field_list
    )
    return f"md5(cast({parts} as varchar))"


def date_spine(datepart, start_date, end_date):
    """A SELECT producing one row per datepart, in a column named date_<datepart>.

    The column name matters: models select `date_month` / `date_day` from this by
    name, so a stub that emitted something else would template cleanly and then
    fail to parse for the wrong reason.
    """
    return (
        f"select dateadd({datepart}, seq4(), {start_date})::date as date_{datepart} "
        f"from table(generator(rowcount => 10000)) "
        f"qualify date_{datepart} < {end_date}"
    )


def star(from_, except_=None, relation_alias=None):
    return "*"


def surrogate_key(field_list):
    """Pre-1.0 alias. Kept so a model using the old name still lints."""
    return generate_surrogate_key(field_list)
