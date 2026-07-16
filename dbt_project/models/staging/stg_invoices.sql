{{
    config(
        materialized = 'table',
        cluster_by = ['issued_month']
    )
}}

/*
    Invoice lines: deduplicated, timezone-corrected, cast.

    The one staging model that is a table rather than a view, for two reasons:
    it is the only staging model doing real work (a window function over 511K
    rows), and every downstream model reads it. As a view that dedup would be
    re-executed on every reference — four times per `dbt build`, plus once per
    test. Materializing costs storage measured in megabytes and removes it from
    the critical path. Clustered on issued_month because every query downstream
    filters or groups by it (M4 quantifies what that clustering key buys).

    Two corrections happen here, and both are deliberately here rather than in
    RAW, where they would be invisible, or in the marts, where they would be
    too late.
*/

with source as (

    select * from {{ source('billing', 'invoices') }}

),

deduplicated as (

    /*
        The billing system replays batches: 10,011 lines are re-emitted verbatim
        except for a later ingested_at (data/raw/_manifest.json).

        SELECT DISTINCT does not remove these — ingested_at differs, so the rows
        are not identical. This is the trap the defect is built to catch, and
        it is why the dedup keys on (invoice_id, line_number) and takes the
        latest arrival rather than deduping on the whole row.

        Keeping max(ingested_at) rather than min: if a line is ever replayed
        with a *corrected* amount, the later version is the one the source means.
        Verified in tests: the duplicates carry identical business values today
        (tests/test_simulate.py::test_duplicates_differ_only_in_ingestion_metadata),
        so this choice is currently unobservable — which is exactly when to make
        it on principle rather than by accident.
    */
    select
        *,
        row_number() over (
            partition by invoice_id, line_number
            order by ingested_at desc, _loaded_at desc
        ) as _dedup_rank
    from source

),

renamed as (

    select
        -- Keys. The grain is (invoice_id, line_number); invoice_id alone is not unique.
        invoice_id,
        line_number,
        {{ dbt_utils.generate_surrogate_key(['invoice_id', 'line_number']) }} as invoice_line_key,
        customer_id,
        subscription_id,

        -- Attributes
        line_type,
        status as invoice_status,
        payment_method,
        source_system,
        upper(currency_code) as currency_code,

        -- Measures. amount_local is negative for discount and proration_credit;
        -- that is the source's convention and is preserved rather than abs()'d,
        -- so a naive SUM gives the net the invoice actually charged.
        amount_local,
        coalesce(line_type in ('discount', 'proration_credit'), false)
            as is_credit_line,
        -- Tax is a pass-through to a tax authority, never the company's revenue.
        -- Flagged here so no downstream model has to remember the list.
        coalesce(line_type = 'tax', false)
            as is_tax_line,

        -- Billing period. Anniversary-based, so it straddles calendar months:
        -- 14 Mar -> 13 Apr is one period across two months. The allocation is
        -- int_revenue_allocated_to_months' job, not this model's.
        period_start,
        period_end,
        datediff('day', period_start, period_end) + 1 as period_days,

        /*
            The timezone correction.

            The source contract documents issued_at as UTC. billing_sync_v2 does
            not honour that — it writes IST wall-clock (UTC+5:30) into the same
            column. 40,965 lines carry the shift. 9,352 land on the wrong day and
            434 land in the wrong calendar month, which is the only part that
            moves money between reporting periods.

            Subtracting the offset for that source and leaving the other alone
            recovers true UTC. The offset lives in dbt_project.yml vars so the
            correction is stated once; if a third source appears with its own
            lie, this becomes a mapping rather than a second copy of this
            expression.

            issued_at_raw is kept alongside precisely so this is auditable: when
            finance asks why last March moved, the query that answers it is
            `where issued_at_raw != issued_at_utc`.
        */
        issued_at as issued_at_raw,
        case
            when source_system = '{{ var("broken_tz_source") }}'
                then dateadd('minute', {{ (var('broken_tz_offset_hours') * 60) | int }}, issued_at)
            else issued_at
        end as issued_at_utc,
        case
            when source_system = '{{ var("broken_tz_source") }}'
                then true
            else false
        end as is_tz_corrected,

        paid_at,
        ingested_at,

        -- Lineage from the load. _loaded_at is when we landed it; ingested_at is
        -- when the source claims it arrived. The gap between them separates "the
        -- source was late" from "we were late" — different incidents, different owners.
        _source_file,
        _loaded_at

    from deduplicated
    where _dedup_rank = 1

),

final as (

    select
        *,
        -- Derived after the correction, never before. The whole point of fixing
        -- the timezone is that the month bucket lands right; deriving it from
        -- issued_at_raw would preserve the bug in a column with a trustworthy name.
        date_trunc('month', issued_at_utc)::date as issued_month,
        issued_at_utc::date as issued_date,

        -- Ingest lag, surfaced as a column so late arrivals are queryable rather
        -- than folklore. 7,569 lines exceed 3 days. Incremental models downstream
        -- use this to size their trailing reprocessing window.
        datediff('day', issued_at_utc, ingested_at) as ingest_lag_days

    from renamed

)

select * from final
