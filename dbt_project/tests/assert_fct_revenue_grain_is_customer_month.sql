{{ config(severity = 'error', tags = ['data_quality', 'grain']) }}

/*
    The grain claim, asserted: one row per customer per month, no exceptions.

    A grain test is the cheapest insurance in a dimensional model. Every fan-out
    bug — a dimension join that matched twice, a spell that overlapped a month
    boundary, a duplicate that survived staging — surfaces here first, and
    surfaces as an obviously wrong row count rather than as an ARR number that is
    merely too large.

    unique_combination_of_columns in the yml covers this too. This exists as a
    separate singular test because it returns the offending customer-months with
    their duplicate count attached, and store_failures writes them to a table. At
    03:00 the difference between "the grain test failed" and "these 4 customers
    have 2 rows in 2026-03" is the difference between an investigation and a fix.
*/

with duplicates as (

    select
        customer_id,
        date_key,
        count(*) as row_count,
        listagg(distinct subscription_id, ', ') as subscription_ids,
        sum(mrr_usd) as summed_mrr_usd
    from {{ ref('fct_revenue') }}
    group by 1, 2
    having count(*) > 1

)

select * from duplicates
