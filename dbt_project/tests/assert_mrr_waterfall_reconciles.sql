{{ config(severity = 'error', tags = ['data_quality', 'reconciliation']) }}

/*
    The MRR waterfall identity, asserted per customer per month:

        prior_mrr + new + reactivation + expansion + contraction + churn == mrr

    (contraction and churn are already negative, so this is a sum, not a mix of
    signs.)

    This is the test that catches a double-count.

    The failure it exists for: a fan-out in the spell join gives one customer two
    rows in one month, or a movement gets classified into two buckets at once. In
    both cases every column still looks reasonable — MRR is positive, the
    categories are valid, nothing is null — and the ARR total is simply too big.
    There is no test of a single column that finds this. Only the identity does,
    because a double-count breaks the arithmetic even when it does not break any
    individual value.

    The classification in fct_revenue is a CASE, so exactly one branch fires per
    row by construction and this identity holds trivially — today. That is the
    argument for the test, not against it: it is trivially true right up until
    someone adds a branch, reorders them, or introduces a join that fans out, and
    then it is the only thing that notices.
*/

with revenue as (

    select
        revenue_key,
        customer_id,
        date_key,
        coalesce(prior_mrr_usd, 0) as prior_mrr_usd,
        new_mrr_usd,
        reactivation_mrr_usd,
        expansion_mrr_usd,
        contraction_mrr_usd,
        churned_mrr_usd,
        mrr_usd,
        movement_type
    from {{ ref('fct_revenue') }}

),

reconciled as (

    select
        *,
        prior_mrr_usd
        + new_mrr_usd
        + reactivation_mrr_usd
        + expansion_mrr_usd
        + contraction_mrr_usd
        + churned_mrr_usd as rebuilt_mrr_usd
    from revenue

)

select
    *,
    round(rebuilt_mrr_usd - mrr_usd, 4) as difference_usd
from reconciled
where abs(rebuilt_mrr_usd - mrr_usd) > 0.01
