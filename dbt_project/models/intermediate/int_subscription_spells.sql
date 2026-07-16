/*
    Subscription spells enriched with contracted MRR.

    MRR is defined here as seats x plan list price per seat per month. That is a
    definition, not a calculation, and it is worth being explicit about because
    it is exactly where the "three teams, three numbers" problem starts:

      - Overage and seats_addon are excluded. They are usage, and usage is not
        recurring by definition — a customer who overran their quota once has not
        expanded their contract. Including them makes MRR jump and fall with
        consumption and stops it predicting anything.
      - Discounts are excluded. This is *list* MRR. A discount is a commercial
        term on an invoice, not a change to the subscription.
      - Tax is excluded everywhere, always.

    Reasonable people define this differently — plenty of companies report MRR net
    of discount. The point is that it is written down in one place and every
    number downstream inherits it, rather than three teams each picking one.

    Prices are already USD (stg_plans.seat_price_monthly_usd), so no FX join is
    needed here. Only invoiced amounts are denominated in local currency; that
    conversion lives in int_invoice_lines_usd. Keeping the two apart is deliberate
    — MRR is a contract fact and should not move because a rate moved.
*/

with subscriptions as (

    select * from {{ ref('stg_subscriptions') }}

),

plans as (

    select * from {{ ref('stg_plans') }}

),

joined as (

    select
        subscriptions.subscription_id,
        subscriptions.customer_id,
        subscriptions.plan_id,
        subscriptions.seats,
        subscriptions.change_reason,
        subscriptions.spell_status,
        subscriptions.is_open_spell,

        plans.plan_name,
        plans.tier,
        plans.tier_rank,
        plans.billing_interval,
        plans.seat_price_monthly_usd,

        subscriptions.spell_started_at,
        subscriptions.spell_ended_at,

        -- Coalesced only for the overlap arithmetic below. Scoped to this column
        -- so it cannot leak into a churn count: is_open_spell stays the load-
        -- bearing flag, and an open spell is never mistaken for one that ended on
        -- the window's last day.
        coalesce(subscriptions.spell_ended_at, '{{ var("reporting_end_date") }}'::date)
            as spell_effective_end,

        round(subscriptions.seats * plans.seat_price_monthly_usd, 2)
            as mrr_usd,
        round(subscriptions.seats * plans.seat_price_monthly_usd * 12, 2)
            as arr_usd

    from subscriptions
    inner join plans
        on subscriptions.plan_id = plans.plan_id
        -- inner, not left. A subscription on an unknown plan has no price, so its
        -- MRR would be NULL and would vanish from every SUM silently. The
        -- relationships test on stg_subscriptions.plan_id already fails the build
        -- in that case; this join simply refuses to invent a fallback.

),

final as (

    select
        *,
        datediff('day', spell_started_at, spell_effective_end) + 1
            as spell_days,
        date_trunc('month', spell_started_at)::date as spell_start_month,
        date_trunc('month', spell_effective_end)::date as spell_end_month
    from joined

)

select * from final
