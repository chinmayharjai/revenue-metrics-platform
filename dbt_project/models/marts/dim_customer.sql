{{ config(materialized = 'table') }}

/*
    Customer dimension, one row per account, with the sales org rolled up onto it.

    Type 1 (current state only) — deliberately, and this is the biggest modelling
    limitation in the project, so it is written down rather than discovered.

    A customer's industry or account manager can change, and this dimension keeps
    only today's value. Slice historical ARR by region and you get today's region
    applied to every past month, so a territory reshuffle silently rewrites last
    year. Type 2 would fix it, and the honest reason it is not here is that the
    generator emits no change history to build it from — there is no
    valid_from/valid_to to derive, and inventing one would be modelling a fact
    that does not exist. What is here instead: the grain is documented, the flaw
    is stated, and fct_revenue carries plan_key at the month it applied, so
    revenue-by-plan is correct over time even though revenue-by-region is not.

    The manager chain is flattened to four columns rather than joined recursively
    at query time. Power BI cannot express a recursive CTE, so leaving the
    hierarchy in a self-join means every report either flattens it again or gets
    it wrong. sql_showcase/org_hierarchy_recursive_cte.sql shows the recursive
    form for the general-depth case; this is the fixed-depth version the BI layer
    can actually consume.
*/

with customers as (

    select * from {{ ref('stg_customers') }}

),

employees as (

    select * from {{ ref('stg_employees') }}

),

-- The org is five levels and fixed, so the chain is walked with joins rather than
-- recursion. If the org ever gained a level, this would silently truncate — which
-- is why tests/assert_org_depth_within_flattened_bounds.sql exists to fail loudly
-- instead.
org_chain as (

    select
        ae.employee_id as account_manager_id,
        ae.full_name as account_manager_name,
        ae.region as sales_region,

        mgr.employee_id as sales_manager_id,
        mgr.full_name as sales_manager_name,

        dir.employee_id as sales_director_id,
        dir.full_name as sales_director_name,

        vp.employee_id as sales_vp_id,
        vp.full_name as sales_vp_name

    from employees as ae
    left join employees as mgr on ae.manager_id = mgr.employee_id
    left join employees as dir on mgr.manager_id = dir.employee_id
    left join employees as vp on dir.manager_id = vp.employee_id

),

-- First and last observed activity, so the dimension can answer "is this customer
-- still with us" without every consumer re-deriving it from the fact table.
activity as (

    select
        customer_id,
        min(spell_started_at) as first_subscription_date,
        max(case when is_open_spell then 1 else 0 end) as has_open_spell,
        max(spell_effective_end) as last_active_date,
        count(*) as lifetime_spell_count,
        count_if(change_reason = 'upgrade') as lifetime_upgrades,
        count_if(change_reason = 'downgrade') as lifetime_downgrades,
        count_if(change_reason = 'reactivation') as lifetime_reactivations
    from {{ ref('int_subscription_spells') }}
    group by 1

),

final as (

    select
        -- Surrogate key. The natural key is stable and readable here, but the
        -- surrogate is what fct_revenue joins on, so a future Type 2 rebuild can
        -- add versions without every fact row needing a new join column.
        {{ dbt_utils.generate_surrogate_key(['customers.customer_id']) }}
            as customer_key,
        customers.customer_id,

        customers.company_name,
        customers.country_code,
        customers.currency_code,
        customers.industry,
        customers.is_industry_known,
        customers.employee_count,

        -- Banded for reporting. The bands are on the dimension, not in a Power BI
        -- measure, so every report agrees on what "Mid-Market" means. NULL
        -- employee_count (1,277 customers) becomes 'Unknown' rather than falling
        -- into the smallest band, which is what a naive `< 50` would do.
        case
            when customers.employee_count is null then 'Unknown'
            when customers.employee_count < 50 then 'SMB'
            when customers.employee_count < 250 then 'Mid-Market'
            when customers.employee_count < 1000 then 'Enterprise'
            else 'Strategic'
        end as size_band,

        customers.signup_date,
        date_trunc('month', customers.signup_date)::date as signup_month,
        -- The cohort a customer belongs to, fixed at signup and never revised.
        -- Cohort retention (M4) is meaningless if this can move.
        date_trunc('month', customers.signup_date)::date as cohort_month,

        org_chain.account_manager_id,
        org_chain.account_manager_name,
        org_chain.sales_manager_id,
        org_chain.sales_manager_name,
        org_chain.sales_director_id,
        org_chain.sales_director_name,
        org_chain.sales_vp_id,
        org_chain.sales_vp_name,
        org_chain.sales_region,

        activity.first_subscription_date,
        activity.last_active_date,
        coalesce(activity.has_open_spell, 0) = 1 as is_currently_active,
        coalesce(activity.lifetime_spell_count, 0) as lifetime_spell_count,
        coalesce(activity.lifetime_upgrades, 0) as lifetime_upgrades,
        coalesce(activity.lifetime_downgrades, 0) as lifetime_downgrades,
        coalesce(activity.lifetime_reactivations, 0) as lifetime_reactivations

    from customers
    left join org_chain
        on customers.account_manager_id = org_chain.account_manager_id
    left join activity
        on customers.customer_id = activity.customer_id
-- Both left joins. A customer with no subscription yet is still a customer,
-- and dropping them would make the dimension disagree with the CRM on how many
-- accounts exist — the kind of discrepancy that costs a day to explain.

)

select * from final
