{{
    config(
        materialized = 'table',
        cluster_by = ['month_start']
    )
}}

/*
    Allocate each invoice line across the calendar months its billing period
    covers, pro-rata by days.

    This is the model the whole layer exists for.

    Subscriptions bill on their anniversary, so a period runs 14 Mar -> 13 Apr —
    one invoice, two calendar months. An annual contract spans thirteen. Finance
    reports by calendar month. So the invoice amount cannot be attributed to the
    month it was issued in; it has to be spread across the months it actually
    pays for. `date_trunc('month', issued_at)` would put the entire 14 Mar -> 13
    Apr charge in March, overstating March and leaving a hole in April, and it
    would do so consistently enough to look like a seasonality pattern rather
    than a bug.

    Materialized as a table, not ephemeral: it fans 511K lines out across months
    (annual lines land in 13 rows each), it is the input to fct_revenue and to
    several tests, and re-deriving that fan-out per reference is the most
    expensive thing in the project. Clustered on month_start because every
    consumer filters on it.

    Tax is excluded here rather than downstream. Tax collected is a liability
    owed to a tax authority, never the company's revenue — including it would
    inflate ARR by roughly the blended tax rate, and it is the single easiest
    way to produce a revenue number that is confidently, defensibly wrong.
*/

with invoice_lines as (

    select * from {{ ref('int_invoice_lines_usd') }}
    where
        not is_tax_line
        and invoice_status != 'void'
-- Voided invoices were cancelled and never collected. They stay in staging
-- (raw fidelity) but must not reach revenue. 'open' lines are kept: unpaid
-- is a collections problem, not a revenue-recognition one — the money is
-- earned whether or not it has arrived.

),

months as (

    select * from {{ ref('int_month_spine') }}

),

overlaps as (

    select
        invoice_lines.invoice_line_key,
        invoice_lines.invoice_id,
        invoice_lines.line_number,
        invoice_lines.customer_id,
        invoice_lines.subscription_id,
        invoice_lines.line_type,
        invoice_lines.currency_code,
        invoice_lines.issued_month,
        invoice_lines.invoice_status,
        invoice_lines.amount_usd,
        invoice_lines.amount_local,
        invoice_lines.period_start,
        invoice_lines.period_end,
        invoice_lines.period_days,

        months.month_start,
        months.month_end,

        -- Days of this billing period that fall inside this calendar month.
        -- +1 because both bounds are inclusive: a period of 1 Mar -> 1 Mar is one
        -- day, not zero. Dropping the +1 loses a day of revenue per period per
        -- month — about 3%, which is small enough to be mistaken for rounding and
        -- large enough to matter at board level.
        datediff(
            'day',
            greatest(months.month_start, invoice_lines.period_start),
            least(months.month_end, invoice_lines.period_end)
        ) + 1 as overlap_days

    from invoice_lines
    inner join months
    -- The overlap condition. Inclusive on both sides: a period touching a
        -- month by a single day still owes that month a slice.
        on
            invoice_lines.period_end >= months.month_start
            and invoice_lines.period_start <= months.month_end

),

allocated as (

    select
        *,

        overlap_days / nullif(period_days, 0) as allocation_fraction,

        -- The allocation itself. nullif guards a zero-length period: division by
        -- zero would abort the run, which is a worse outcome than a NULL the
        -- not_null test below catches with the offending rows attached.
        round(amount_usd * (overlap_days / nullif(period_days, 0)), 2)
            as allocated_amount_usd,
        round(amount_local * (overlap_days / nullif(period_days, 0)), 2)
            as allocated_amount_local

    from overlaps

)

select * from allocated
