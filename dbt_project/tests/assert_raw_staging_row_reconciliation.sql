{{ config(severity = 'error', tags = ['data_quality', 'reconciliation']) }}

/*
    Reconcile raw row counts against staging, accounting for exactly the rows
    staging is supposed to remove.

    The naive version of this test — `count(raw) = count(staging)` — is useless
    here, because staging legitimately drops 10,011 duplicate lines. It would fail
    every run, get marked severity: warn, and then never be read again.

    The useful version states the arithmetic that must hold:

        raw_lines - duplicates_removed = staging_lines

    which turns the test into a claim about *what* staging removed rather than
    *how many* rows survived. If the dedup ever removes a row that is not a
    replay — a real invoice line lost to a window-function mistake — this fails
    even though the count looks plausible.

    This test is why TRANSFORMER is not granted RAW_WRITE. If dbt could write to
    raw, this would be checking dbt against itself.
*/

with raw_invoices as (

    select
        count(*) as raw_line_count,
        count(distinct invoice_id || '~' || line_number) as raw_distinct_grain
    from {{ source('billing', 'invoices') }}

),

staged_invoices as (

    select count(*) as staged_line_count
    from {{ ref('stg_invoices') }}

),

reconciliation as (

    select
        raw_invoices.raw_line_count,
        raw_invoices.raw_distinct_grain,
        staged_invoices.staged_line_count,

        raw_invoices.raw_line_count - raw_invoices.raw_distinct_grain
            as expected_duplicates_removed,
        raw_invoices.raw_line_count - staged_invoices.staged_line_count
            as actual_rows_removed

    from raw_invoices
    cross join staged_invoices

)

select
    *,
    'staging removed ' || actual_rows_removed::varchar
    || ' rows but only ' || expected_duplicates_removed::varchar
    || ' were duplicates' as failure_reason
from reconciliation
where actual_rows_removed != expected_duplicates_removed
-- Staging must remove the duplicates and nothing else. Both directions are
-- failures: removing too many means real revenue was dropped, removing too few
-- means the dedup did not work and the double-count is downstream already.
or staged_line_count != raw_distinct_grain
