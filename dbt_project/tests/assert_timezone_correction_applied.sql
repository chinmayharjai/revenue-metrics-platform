{{ config(severity = 'error', tags = ['data_quality', 'timezone']) }}

/*
    The timezone correction did what it claims.

    The generator injects a known, counted defect: billing_sync_v2 writes IST
    wall-clock into issued_at, a column documented as UTC. 40,965 lines carry the
    shift (data/raw/_manifest.json). stg_invoices subtracts 5h30m from exactly
    those rows.

    This test pins both halves of that claim, because a correction applied to the
    wrong set of rows is worse than no correction at all — it moves 460K *good*
    rows by five and a half hours and leaves the bad ones alone, which would be
    a far larger error than the bug being fixed and would look, on any summary
    query, like the fix had worked.

      1. Every billing_sync_v2 row is flagged corrected, and no other row is.
      2. Corrected rows moved by exactly -5h30m. Not approximately.
      3. Uncorrected rows did not move at all.
      4. issued_month is derived from the corrected timestamp, never the raw one.

    Check 4 is the one that matters for revenue: the entire reason for the
    correction is that 434 lines land in the wrong calendar month, and deriving
    the month bucket from issued_at_raw would preserve that bug in a column with
    a trustworthy name.
*/

with invoices as (

    select * from {{ ref('stg_invoices') }}

),

failures as (

    select
        invoice_line_key,
        source_system,
        issued_at_raw,
        issued_at_utc,
        'row from the broken source was not flagged as corrected' as failure_reason
    from invoices
    where
        source_system = '{{ var("broken_tz_source") }}'
        and not is_tz_corrected

    union all

    select
        invoice_line_key,
        source_system,
        issued_at_raw,
        issued_at_utc,
        'row from a clean source was flagged as corrected' as failure_reason
    from invoices
    where
        source_system != '{{ var("broken_tz_source") }}'
        and is_tz_corrected

    union all

    select
        invoice_line_key,
        source_system,
        issued_at_raw,
        issued_at_utc,
        'corrected row did not move by exactly -5h30m' as failure_reason
    from invoices
    where
        is_tz_corrected
        and datediff('minute', issued_at_utc, issued_at_raw) != {{ (var('broken_tz_offset_hours') * -60) | int }}

    union all

    select
        invoice_line_key,
        source_system,
        issued_at_raw,
        issued_at_utc,
        'uncorrected row was moved' as failure_reason
    from invoices
    where
        not is_tz_corrected
        and issued_at_raw != issued_at_utc

    union all

    select
        invoice_line_key,
        source_system,
        issued_at_raw,
        issued_at_utc,
        'issued_month was derived from the uncorrected timestamp' as failure_reason
    from invoices
    where issued_month != date_trunc('month', issued_at_utc)::date

)

select * from failures
