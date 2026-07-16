{{
    config(
        materialized = 'table',
        cluster_by = ['month_start']
    )
}}

/*
    The customer-month grain: one row per customer per calendar month from their
    signup month to the end of the reporting window, carrying the MRR in force at
    month end.

    Rows continue after churn, with mrr_usd = 0. That is the point of building
    this as a spine rather than aggregating what exists. Churn is not an event in
    this data — no source table has a "churned" row to count. Churn is the
    *absence* of MRR in a month that followed MRR, and you cannot detect an
    absence in a dataset that only contains presences. Give a churned customer no
    April row and April's churn is zero, forever, and every test passes.

    MRR is measured at month end, the standard SaaS convention. A customer who
    upgraded on the 3rd and downgraded on the 28th contributes the 28th's number.
    This is a real choice with a real cost: it ignores intra-month movement, so a
    customer who churned on the 2nd and a customer who churned on the 30th look
    identical. The alternative — time-weighting MRR across the month — measures
    activity rather than commitment, and makes every month's MRR a fraction of
    the run rate that was actually in force at any moment, which nobody can
    reconcile to a contract. Revenue *recognition* is time-weighted, and that is
    what int_revenue_allocated_to_months does; MRR is a snapshot. The two answer
    different questions and the marts carry both.
*/

with customers as (

    select * from {{ ref('stg_customers') }}

),

months as (

    select * from {{ ref('int_month_spine') }}

),

spells as (

    select * from {{ ref('int_subscription_spells') }}

),

-- Every customer x every month from their signup onward. Not from the window
-- start: a customer who signed up in month 18 has no meaningful month-3 row, and
-- inventing one would put 10,000 customers x 24 months = 240K rows in the mart,
-- most of them asserting that a customer who did not exist yet had zero MRR.
customer_month_spine as (

    select
        customers.customer_id,
        months.month_start,
        months.month_end,
        months.days_in_month,
        months.month_label
    from customers
    inner join months
        on months.month_end >= date_trunc('month', customers.signup_date)::date

),

-- The spell in force on the last day of each month.
spell_at_month_end as (

    select
        customer_month_spine.customer_id,
        customer_month_spine.month_start,
        spells.subscription_id,
        spells.plan_id,
        spells.seats,
        spells.tier,
        spells.tier_rank,
        spells.mrr_usd,
        spells.change_reason,
        spells.spell_started_at,

        -- A plan change on the final day of a month leaves two spells overlapping
        -- month_end for an instant. Ranking by spell_started_at desc takes the one
        -- the customer actually ended the month on. Without this the join fans out
        -- and the customer contributes MRR twice — a double-count that only appears
        -- on month boundaries and only for customers who changed plans that day,
        -- which is to say: in production, at quarter close, in front of the CFO.
        row_number() over (
            partition by customer_month_spine.customer_id, customer_month_spine.month_start
            order by spells.spell_started_at desc, spells.subscription_id desc
        ) as _spell_rank

    from customer_month_spine
    left join spells
        on
            customer_month_spine.customer_id = spells.customer_id
            and customer_month_spine.month_end >= spells.spell_started_at
            and customer_month_spine.month_end <= spells.spell_effective_end

),

final as (

    select
        customer_id,
        month_start,
        subscription_id,
        plan_id,
        tier,
        tier_rank,
        change_reason as spell_change_reason,
        spell_started_at,

        coalesce(seats, 0) as seats,

        -- coalesce to 0, not NULL. A churned customer's MRR is zero — a real,
        -- known quantity — not unknown. NULL here would drop the row from SUMs and
        -- from the lag() comparison in fct_revenue, and churn would silently stop
        -- being detected.
        coalesce(mrr_usd, 0) as mrr_usd,
        coalesce(mrr_usd, 0) * 12 as arr_usd,

        subscription_id is not null as is_active

    from spell_at_month_end
    where _spell_rank = 1

)

select * from final
