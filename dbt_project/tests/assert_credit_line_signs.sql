{{ config(severity = 'error', tags = ['data_quality']) }}

/*
    Credits are negative, charges are not.

    A generic positivity test on amount_local would be wrong (credits are
    legitimately negative) and a generic not_null says nothing about sign. So the
    invariant has to be stated per line_type, which is what this does.

    The failure it guards: a sign flip on a discount turns a credit into a charge.
    Nothing else notices — the row count is right, the type is valid, the value is
    a plausible number — and revenue goes up by twice the discount. Sign errors are
    the cheapest bug to introduce and among the most expensive to find, because
    the result is a number that is wrong in the direction nobody questions.
*/

with lines as (

    select
        invoice_line_key,
        invoice_id,
        line_number,
        line_type,
        amount_local,
        amount_usd
    from {{ ref('int_invoice_lines_usd') }}

),

failures as (

    select *, 'credit line is not negative' as failure_reason
    from lines
    where
        line_type in ('discount', 'proration_credit')
        and amount_local > 0

    union all

    select *, 'charge line is negative' as failure_reason
    from lines
    where
        line_type in ('subscription', 'tax', 'platform_fee', 'support_plan', 'seats_addon', 'overage')
        and amount_local < 0

    union all

    -- Conversion must preserve sign. A negative rate would flip it, which the
    -- accepted_range on rate_to_usd already prevents — this catches the case where
    -- the conversion itself is wrong rather than the rate.
    select *, 'usd conversion flipped the sign of the local amount' as failure_reason
    from lines
    where
        sign(amount_local) != sign(amount_usd)
        and amount_local != 0

)

select * from failures
