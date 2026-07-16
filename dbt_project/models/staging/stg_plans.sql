with source as (

    select * from {{ source('billing', 'plans') }}

),

renamed as (

    select
        plan_id,
        plan_name,
        tier,

        -- tier_rank orders the ladder (Starter=1 ... Enterprise=4). It is what
        -- makes an upgrade distinguishable from a downgrade downstream: comparing
        -- tier names alphabetically would rank Enterprise below Growth and invert
        -- half the MRR waterfall.
        tier_rank,

        billing_interval,

        -- The source quotes seat_price_usd per seat per *month* on every plan,
        -- including annual ones — an annual plan is a discounted monthly rate
        -- (Pro Annual $49 vs Pro Monthly $59), not a yearly total. Renaming it
        -- here rather than leaving it as seat_price_usd because the ambiguity is
        -- the whole risk: multiply an annual plan's price by 12 twice and the
        -- MRR is 12x too high, which is the shape of error that survives review.
        seat_price_usd as seat_price_monthly_usd,

        -- What an invoice for this plan covers. Annual plans bill once upfront
        -- for 12 months, so invoice amount / months_billed_per_invoice recovers
        -- the monthly figure. This is the factor the allocation in
        -- int_revenue_allocated_to_months divides by.
        case when billing_interval = 'annual' then 12 else 1 end
            as months_billed_per_invoice,

        _source_file,
        _loaded_at

    from source

)

select * from renamed
