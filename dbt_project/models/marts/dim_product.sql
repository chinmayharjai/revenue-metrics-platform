{{ config(materialized = 'table') }}

/*
    Product (plan) dimension. Eight rows.

    Small enough that its size is the point: it exists so that reports join to a
    named tier and an ordered rank instead of parsing plan_id strings. Every
    "Enterprise sorts below Growth" bug comes from a report that had the name but
    not the rank.
*/

with plans as (

    select * from {{ ref('stg_plans') }}

),

final as (

    select
        {{ dbt_utils.generate_surrogate_key(['plan_id']) }} as plan_key,
        plan_id,

        plan_name,
        tier,
        -- The sort order for every tier axis in Power BI. Without a numeric rank on
        -- the dimension, BI tools sort tiers alphabetically: Enterprise, Growth,
        -- Pro, Starter — which reads as a ladder and is not one.
        tier_rank,

        billing_interval,
        billing_interval = 'annual' as is_annual,
        seat_price_monthly_usd,
        months_billed_per_invoice,

        -- What an annual contract charges upfront, per seat. Derived here rather
        -- than in a measure so that "annual contract value per seat" means one
        -- thing everywhere.
        round(seat_price_monthly_usd * months_billed_per_invoice, 2)
            as invoice_price_per_seat_usd,

        -- The annual discount, as the commercial team would quote it. Compares each
        -- annual plan to the monthly plan on the same tier.
        case
            when billing_interval = 'annual' then
                round(
                    1 - (
                        seat_price_monthly_usd
                        / nullif(max(case when billing_interval = 'monthly' then seat_price_monthly_usd end)
                            over (partition by tier), 0)
                    ), 4
                )
        end as annual_discount_pct

    from plans

)

select * from final
