{{ config(severity = 'error', tags = ['data_quality', 'metric_tolerance']) }}

/*
    Fail if any month's ARR moved by more than var('arr_tolerance_pct') between
    the previous run and this one.

    This is the test that is supposed to stand between a bad model change and the
    CFO's dashboard. A closed month's ARR is a fact; if a code change restates it,
    that is either a bug or a decision someone must make consciously — never a
    silent deploy.

    Returns the offending months. dbt fails the test if any rows come back.

    Vacuous on the first run (no prior snapshot to compare against) and after a
    --full-refresh of fct_arr_snapshot, which wipes the history. That is a real
    gap and it is why full-refresh of the snapshot is called out as a deliberate
    act in the runbook rather than something to try when a run looks stuck.

    Threshold is 10% by default (dbt_project.yml). Not a statistical bound — it
    is "no legitimate overnight change to a 24-month book is this big, so
    something upstream broke". Tighten it once the pipeline has a track record;
    a threshold nobody trusts gets --exclude'd within a month.
*/

with runs as (

    select distinct
        snapshot_run_id,
        snapshot_at
    from {{ ref('fct_arr_snapshot') }}

),

ranked_runs as (

    select
        snapshot_run_id,
        snapshot_at,
        row_number() over (order by snapshot_at desc, snapshot_run_id desc) as run_rank
    from runs

),

latest_run as (
    select snapshot_run_id from ranked_runs
    where run_rank = 1
),

previous_run as (
    select snapshot_run_id from ranked_runs
    where run_rank = 2
),

latest as (
    select date_key, total_arr_usd
    from {{ ref('fct_arr_snapshot') }}
    where snapshot_run_id = (select snapshot_run_id from latest_run)
),

previous as (
    select date_key, total_arr_usd
    from {{ ref('fct_arr_snapshot') }}
    where snapshot_run_id = (select snapshot_run_id from previous_run)
),

compared as (

    select
        previous.date_key,
        previous.total_arr_usd as previous_arr_usd,
        latest.total_arr_usd as latest_arr_usd,
        latest.total_arr_usd - previous.total_arr_usd as arr_delta_usd,
        round(
            100.0 * abs(latest.total_arr_usd - previous.total_arr_usd)
            / nullif(previous.total_arr_usd, 0),
            2
        ) as abs_pct_move

    from previous
    inner join latest
        on previous.date_key = latest.date_key
-- inner join: a month present in one run and not the other is a different
-- problem (the window changed), caught by the row-count reconciliation test
-- rather than misreported here as an infinite percentage move.

)

select *
from compared
where abs_pct_move > {{ var('arr_tolerance_pct') }}
