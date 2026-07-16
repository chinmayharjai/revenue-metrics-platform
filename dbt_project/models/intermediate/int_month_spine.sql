/*
    Every calendar month in the reporting window, as a first/last day pair.

    A spine, not a derived set of the months that happen to appear in the data.
    That distinction is the whole reason this model exists: if the months come
    from `select distinct date_trunc('month', issued_at)`, then a month in which
    nothing was invoiced simply does not exist, and a customer who churned in
    March has no April row to be zero in. Churn would then be invisible — not
    wrong, *absent* — which is the failure mode that survives every test you
    would think to write.

    Bounds are pinned to vars rather than min/max of the data so the marts do not
    change shape when the generator is re-run with different parameters.
*/

{% set start_date = var('reporting_start_date') %}
{% set end_date = var('reporting_end_date') %}

with spine as (

    {{ dbt_utils.date_spine(
        datepart = "month",
        start_date = "'" ~ start_date ~ "'::date",
        end_date = "dateadd(month, 1, '" ~ end_date ~ "'::date)"
    ) }}

),

final as (

    select
        date_month::date as month_start,
        last_day(date_month)::date as month_end,
        year(date_month) as calendar_year,
        month(date_month) as calendar_month,
        day(last_day(date_month)) as days_in_month,
        to_char(date_month, 'YYYY-MM') as month_label
    from spine
    where date_month::date <= '{{ end_date }}'::date

)

select * from final
