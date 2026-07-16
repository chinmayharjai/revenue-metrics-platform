{{
    config(
        materialized = 'table',
        cluster_by = ['date_key']
    )
}}

/*
    fct_revenue — grain: one row per customer per calendar month.

    The published contract. This is the table Power BI reads and the one the CFO's
    ARR comes from, and it is the reason REPORTER has no grant on staging: if
    there is exactly one place ARR can be computed, there is exactly one ARR.

    It carries two different kinds of money on purpose, and confusing them is the
    single most likely misuse of this table:

      mrr_usd / arr_usd        A snapshot of contracted run-rate at month end.
                               A commitment. Answers "what are we owed per month
                               if nothing changes?" Comes from subscriptions.

      recognized_revenue_usd   Revenue earned in this month, allocated pro-rata
                               across the calendar months each billing period
                               covers. Answers "what did we actually earn in
                               March?" Comes from invoices.

    They do not tie out, and should not. A customer on an annual contract commits
    12x their monthly MRR but is invoiced once; a customer who churns mid-month
    has zero closing MRR and a fortnight of recognized revenue. Reports that add
    them together, or use one to check the other, are wrong — hence the column
    comments and the tests below.

    Rows persist after churn with mrr_usd = 0, inherited from int_customer_months.
    That is what makes churn detectable at all.
*/

with customer_months as (

    select * from {{ ref('int_customer_months') }}

),

allocated_revenue as (

    select
        customer_id,
        month_start,

        sum(allocated_amount_usd) as recognized_revenue_usd,
        sum(case when line_type = 'subscription' then allocated_amount_usd else 0 end)
            as subscription_revenue_usd,
        sum(case when line_type in ('seats_addon', 'overage') then allocated_amount_usd else 0 end)
            as usage_revenue_usd,
        sum(case when line_type in ('platform_fee', 'support_plan') then allocated_amount_usd else 0 end)
            as fee_revenue_usd,
        -- Negative by convention; summed as-is so recognized_revenue_usd is already net.
        sum(case when line_type in ('discount', 'proration_credit') then allocated_amount_usd else 0 end)
            as credit_usd,
        count(distinct invoice_id) as invoice_count

    from {{ ref('int_revenue_allocated_to_months') }}
    group by 1, 2

),

-- Tax is aggregated separately and never folded into revenue. Reported because
-- someone always asks what was collected; kept out of every revenue column
-- because it is a liability owed to a tax authority.
tax_collected as (

    select
        customer_id,
        issued_month as month_start,
        sum(amount_usd) as tax_collected_usd
    from {{ ref('int_invoice_lines_usd') }}
    where
        is_tax_line
        and invoice_status != 'void'
    group by 1, 2

),

joined as (

    select
        customer_months.customer_id,
        customer_months.month_start,
        customer_months.subscription_id,
        customer_months.plan_id,
        customer_months.tier_rank,
        customer_months.spell_change_reason,
        customer_months.seats,
        customer_months.mrr_usd,
        customer_months.arr_usd,
        customer_months.is_active,

        coalesce(allocated_revenue.recognized_revenue_usd, 0) as recognized_revenue_usd,
        coalesce(allocated_revenue.subscription_revenue_usd, 0) as subscription_revenue_usd,
        coalesce(allocated_revenue.usage_revenue_usd, 0) as usage_revenue_usd,
        coalesce(allocated_revenue.fee_revenue_usd, 0) as fee_revenue_usd,
        coalesce(allocated_revenue.credit_usd, 0) as credit_usd,
        coalesce(allocated_revenue.invoice_count, 0) as invoice_count,
        coalesce(tax_collected.tax_collected_usd, 0) as tax_collected_usd

    from customer_months
    left join allocated_revenue
        on
            customer_months.customer_id = allocated_revenue.customer_id
            and customer_months.month_start = allocated_revenue.month_start
    left join tax_collected
        on
            customer_months.customer_id = tax_collected.customer_id
            and customer_months.month_start = tax_collected.month_start
-- left joins from the spine: a month with MRR but no invoice (annual contract
-- billed in a prior month) is a real and common row, and an inner join would
-- delete exactly the customers who pay the most.

),

with_movement as (

    select
        *,

        lag(mrr_usd) over (
            partition by customer_id
            order by month_start
        ) as prior_mrr_usd,

        -- Whether this customer ever had MRR before this month. Distinguishes a
        -- genuine new customer from a reactivation — both look like 0 -> positive
        -- if you only compare to last month, and counting a returning customer as
        -- new inflates new-business ARR while hiding that retention is working.
        max(case when mrr_usd > 0 then 1 else 0 end) over (
            partition by customer_id
            order by month_start
            rows between unbounded preceding and 1 preceding
        ) as had_prior_mrr

    from joined

),

classified as (

    select
        *,

        coalesce(mrr_usd, 0) - coalesce(prior_mrr_usd, 0) as mrr_delta_usd,

        /*
            MRR movement classification — the input to the waterfall in M4.

            Order matters: the first matching branch wins, so the exclusive cases
            (new, reactivation, churn) are tested before the directional ones
            (expansion, contraction). Reordering this silently reclassifies
            reactivations as expansion.
        */
        case
            when coalesce(prior_mrr_usd, 0) = 0 and mrr_usd > 0 and coalesce(had_prior_mrr, 0) = 0
                then 'new'
            when coalesce(prior_mrr_usd, 0) = 0 and mrr_usd > 0 and had_prior_mrr = 1
                then 'reactivation'
            when prior_mrr_usd > 0 and coalesce(mrr_usd, 0) = 0
                then 'churn'
            when mrr_usd > coalesce(prior_mrr_usd, 0) and coalesce(prior_mrr_usd, 0) > 0
                then 'expansion'
            when mrr_usd < prior_mrr_usd and mrr_usd > 0
                then 'contraction'
            when mrr_usd = coalesce(prior_mrr_usd, 0) and mrr_usd > 0
                then 'unchanged'
            else 'inactive'
            -- 'inactive': zero MRR this month and zero last month. Post-churn
            -- months, mostly. Kept as rows rather than filtered out so a customer's
            -- timeline is continuous and a later reactivation has something to
            -- follow.
        end as movement_type

    from with_movement

),

final as (

    select
        -- Keys
        {{ dbt_utils.generate_surrogate_key(['classified.customer_id', 'classified.month_start']) }}
            as revenue_key,
        classified.month_start as date_key,
        dim_customer.customer_key,
        dim_product.plan_key,

        -- Degenerate dimensions, kept for drill-through without a join
        classified.customer_id,
        classified.plan_id,
        classified.subscription_id,

        -- Contracted run-rate (a snapshot at month end)
        classified.mrr_usd,
        classified.arr_usd,
        classified.prior_mrr_usd,
        classified.mrr_delta_usd,
        classified.movement_type,
        classified.seats,

        -- Movement components, pre-split so the waterfall is a SUM rather than a
        -- CASE every consumer rewrites. Churn and contraction are negative here:
        -- summing all five columns plus the prior month's closing MRR gives this
        -- month's closing MRR, which is the identity
        -- tests/assert_mrr_waterfall_reconciles.sql asserts.
        case when classified.movement_type = 'new' then classified.mrr_delta_usd else 0 end
            as new_mrr_usd,
        case when classified.movement_type = 'reactivation' then classified.mrr_delta_usd else 0 end
            as reactivation_mrr_usd,
        case when classified.movement_type = 'expansion' then classified.mrr_delta_usd else 0 end
            as expansion_mrr_usd,
        case when classified.movement_type = 'contraction' then classified.mrr_delta_usd else 0 end
            as contraction_mrr_usd,
        case when classified.movement_type = 'churn' then classified.mrr_delta_usd else 0 end
            as churned_mrr_usd,

        -- Earned revenue (allocated across the months each period covers)
        classified.recognized_revenue_usd,
        classified.subscription_revenue_usd,
        classified.usage_revenue_usd,
        classified.fee_revenue_usd,
        classified.credit_usd,
        classified.invoice_count,

        -- Collected on behalf of a tax authority. Never revenue.
        classified.tax_collected_usd,

        classified.is_active,
        classified.spell_change_reason

    from classified
    left join {{ ref('dim_customer') }} as dim_customer
        on classified.customer_id = dim_customer.customer_id
    left join {{ ref('dim_product') }} as dim_product
        on classified.plan_id = dim_product.plan_id
-- dim_product is left-joined because plan_id is NULL on inactive months. An
-- inner join here would delete every post-churn row and take churn detection
-- with it.

)

select * from final
