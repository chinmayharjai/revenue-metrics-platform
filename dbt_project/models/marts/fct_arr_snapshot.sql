{{
    config(
        materialized = 'incremental',
        on_schema_change = 'append_new_columns'
    )
}}

/*
    One row per (dbt run, month) recording total ARR as that run computed it.

    This exists so that "ARR moved more than it should have" is answerable at all.
    A tolerance test needs something to compare against, and the naive options are
    both wrong:

      - Compare this month to last month. Fails on legitimate growth: a book of
        business ramping from zero moves >10% month-over-month for real, so the
        test either cries wolf during the ramp or is set so loose it catches
        nothing.
      - Compare to a hardcoded expected number. Rots the first time the data
        legitimately changes, and someone updates the constant to make CI green
        without reading why it moved.

    What actually matters is different: *a historical month's ARR changed between
    two runs*. March 2025 was closed. Its ARR is a fact. If today's run says
    something different about it than yesterday's run did, a code change moved a
    closed month — which is the exact failure the platform exists to prevent, and
    it is invisible to any test that only looks at one run.

    Appending rather than merging: each run has a distinct invocation_id, so every
    run adds a fresh set of rows and history accumulates. `--full-refresh` wipes
    that history and the tolerance test goes quiet (vacuously passing on the first
    run afterwards) — so full-refresh on this model in prod is a deliberate act,
    not a routine one. Noted in runbooks/dag_failure_recovery.md.
*/

with revenue as (

    select * from {{ ref('fct_revenue') }}

),

snapshot_rows as (

    select
        '{{ invocation_id }}' as snapshot_run_id,
        '{{ run_started_at }}'::timestamp_ntz as snapshot_at,
        '{{ target.name }}' as snapshot_target,

        date_key,

        sum(arr_usd) as total_arr_usd,
        sum(mrr_usd) as total_mrr_usd,
        sum(recognized_revenue_usd) as total_recognized_revenue_usd,
        count_if(is_active) as active_customers,
        count(*) as customer_months

    from revenue
    group by 4

)

select * from snapshot_rows

{% if is_incremental() %}
-- No filter: this model appends a complete snapshot per run by design. The
-- is_incremental() guard is here only so that the first build creates the
-- table and subsequent builds add to it rather than replacing it.
{% endif %}
