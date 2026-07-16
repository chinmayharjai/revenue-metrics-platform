with source as (

    select * from {{ source('crm', 'customers') }}

),

renamed as (

    select
        customer_id,
        company_name,
        upper(country_code) as country_code,
        upper(currency_code) as currency_code,

        -- industry is nullable by contract (661 blanks). Coalescing to 'Unknown'
        -- here rather than leaving NULL is a reporting decision made once: a
        -- GROUP BY industry in Power BI silently drops NULL rows, so the segment
        -- totals would not sum to the company total and someone would spend an
        -- afternoon finding out why. is_industry_known preserves the distinction
        -- between "we know it is unknown" and "it is a category called Unknown".
        coalesce(industry, 'Unknown') as industry,
        industry is not null as is_industry_known,

        -- employee_count stays NULL (1,277 blanks). Unlike industry, this is a
        -- measure, and defaulting a measure to 0 would drag every average toward
        -- zero. NULL is arithmetically honest — AVG ignores it.
        employee_count,

        signup_date,
        account_manager_id,

        _source_file,
        _loaded_at

    from source

)

select * from renamed
