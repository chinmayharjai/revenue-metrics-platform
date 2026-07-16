{{ config(severity = 'error', tags = ['data_quality', 'reconciliation']) }}

/*
    Every invoice line's allocated slices must sum back to the line's own amount.

    This is the test that guards the proration logic, and it is the most valuable
    single test in the project, because allocation bugs are conservative-looking.
    Splitting a 14 Mar -> 13 Apr charge across two months either loses a day at
    the boundary (the classic off-by-one on an inclusive datediff), double-counts
    the boundary day, or silently drops a period whose month fell outside the
    spine. All three produce revenue that is *slightly* wrong in every month —
    small enough to look like rounding, systematic enough to be a real
    misstatement, and invisible to every not_null and unique test you would think
    to write.

    Stating the invariant directly is the only way to catch it:

        for each invoice line:  sum(allocated slices) == original amount

    Tolerance of 0.01 USD per line: each slice is round()ed to cents, so a period
    split across 13 months can accumulate a cent of rounding drift. Anything above
    that is a logic error, not floating point.
*/

with allocated as (

    select
        invoice_line_key,
        max(amount_usd) as original_amount_usd,
        sum(allocated_amount_usd) as summed_allocation_usd,
        sum(allocation_fraction) as summed_fraction,
        count(*) as months_spanned
    from {{ ref('int_revenue_allocated_to_months') }}
    group by 1

),

failures as (

    select
        invoice_line_key,
        original_amount_usd,
        summed_allocation_usd,
        round(summed_allocation_usd - original_amount_usd, 4) as difference_usd,
        summed_fraction,
        months_spanned
    from allocated
    where
        -- The amount must be conserved.
        abs(summed_allocation_usd - original_amount_usd) > 0.01

        -- And the fractions must sum to 1. This is the stronger half: a line
        -- whose slices sum to 95% of the amount fails the check above, but a line
        -- whose *period* was partly outside the month spine would allocate 95% of
        -- itself and still look internally consistent if only the amount were
        -- checked. Comparing fractions catches the missing month directly.
        or abs(summed_fraction - 1.0) > 0.0001

)

select * from failures
