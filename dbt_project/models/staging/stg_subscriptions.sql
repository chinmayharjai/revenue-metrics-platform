with source as (

    select * from {{ source('billing', 'subscriptions') }}

),

renamed as (

    select
        subscription_id,
        customer_id,
        plan_id,
        seats,

        started_at as spell_started_at,

        -- NULL ended_at means the spell is open, not missing. Coalescing it to the
        -- reporting end date would be convenient and wrong: an open spell and a
        -- spell that happened to end on the last day of the window are different
        -- facts, and only one of them contributes to closing ARR. The coalesce
        -- happens in int_subscription_spells, where it is scoped to the overlap
        -- arithmetic and cannot leak into a churn count.
        ended_at as spell_ended_at,
        ended_at is null as is_open_spell,

        status as spell_status,
        change_reason,

        _source_file,
        _loaded_at

    from source

)

select * from renamed
