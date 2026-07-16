{{ config(materialized = 'table') }}

/*
    Daily date dimension covering the reporting window.

    Daily rather than monthly even though fct_revenue is at month grain, because
    a date dimension that only contains month starts cannot answer a question
    about a day, and the next fact table (invoice-level, in any real extension of
    this) will need days. It costs ~730 rows.

    fct_revenue joins on the first day of its month, so date_key is a real date
    and not a smart integer like 20260701. Smart keys save nothing on a table
    this size and cost every analyst who has to remember the encoding.
*/

with spine as (

    {{ dbt_utils.date_spine(
        datepart = "day",
        start_date = "'" ~ var('reporting_start_date') ~ "'::date",
        end_date = "dateadd(day, 1, '" ~ var('reporting_end_date') ~ "'::date)"
    ) }}

),

final as (

    select
        date_day::date as date_key,
        date_day::date as calendar_date,

        year(date_day) as calendar_year,
        quarter(date_day) as calendar_quarter,
        month(date_day) as calendar_month,
        day(date_day) as day_of_month,
        dayofweek(date_day) as day_of_week,
        weekofyear(date_day) as week_of_year,

        to_char(date_day, 'YYYY-MM') as month_label,
        to_char(date_day, 'Mon') as month_name_short,
        to_char(date_day, 'YYYY"-Q"Q') as quarter_label,

        date_trunc('month', date_day)::date as month_start,
        last_day(date_day)::date as month_end,
        date_trunc('quarter', date_day)::date as quarter_start,
        date_trunc('year', date_day)::date as year_start,

        date_day = date_trunc('month', date_day)::date as is_month_start,
        date_day = last_day(date_day)::date as is_month_end,
        dayofweek(date_day) in (0, 6) as is_weekend,

        -- Fiscal calendar: FY starts 1 Feb, so FY2026 runs Feb-2026 -> Jan-2027.
        -- Hardcoding the offset in one place beats every analyst re-deriving it in
        -- a Power BI measure, which is how a company ends up with two Q3s.
        case
            when month(date_day) >= 2 then year(date_day)
            else year(date_day) - 1
        end as fiscal_year,
        case
            when month(date_day) >= 2 then month(date_day) - 1
            else 12
        end as fiscal_month

    from spine
    where date_day::date <= '{{ var("reporting_end_date") }}'::date

)

select * from final
