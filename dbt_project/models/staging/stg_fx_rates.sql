with source as (

    select * from {{ source('reference', 'fx_rates') }}

),

renamed as (

    select
        rate_date,
        upper(currency_code) as currency_code,
        rate_to_usd,

        _source_file,
        _loaded_at

    from source

)

select * from renamed
