/* ============================================================================
   MRR movement waterfall — new / expansion / contraction / churn, per month
   ----------------------------------------------------------------------------
   Run as:  REPORTER   (reads REVENUE_ANALYTICS.MARTS only)
   Reads:   FCT_REVENUE

   The one query a SaaS CFO actually asks for: "closing MRR moved from X to Y —
   show me the four numbers that explain the gap."

   The output is a waterfall that closes exactly:

       opening MRR
         + new                (customers who never paid before)
         + reactivation       (customers who paid, left, came back)
         + expansion          (existing customers paying more)
         - contraction        (existing customers paying less)
         - churn              (customers who stopped paying)
         = closing MRR

   If it does not close, the query is wrong. That is the value of writing it as
   an identity rather than five independent aggregates: five separate SUMs will
   each look plausible and quietly fail to reconcile, and nobody notices until
   someone adds them up in a slide.
   ============================================================================ */

-- ---------------------------------------------------------------------------
-- 1. The waterfall itself.
--
-- The per-customer classification already happened in fct_revenue (a LAG over
-- customer-months, classified into exactly one bucket). This query is therefore
-- a SUM, not a CASE — the definition lives in one model and every consumer
-- inherits it, rather than each report re-deriving "what counts as expansion".
-- ---------------------------------------------------------------------------

WITH monthly_movement AS (

    SELECT
        date_key                                                AS month_start,

        SUM(new_mrr_usd)                                        AS new_mrr,
        SUM(reactivation_mrr_usd)                               AS reactivation_mrr,
        SUM(expansion_mrr_usd)                                  AS expansion_mrr,
        SUM(contraction_mrr_usd)                                AS contraction_mrr,   -- already negative
        SUM(churned_mrr_usd)                                    AS churned_mrr,       -- already negative
        SUM(mrr_usd)                                            AS closing_mrr,

        COUNT_IF(movement_type = 'new')                         AS new_customers,
        COUNT_IF(movement_type = 'reactivation')                AS reactivated_customers,
        COUNT_IF(movement_type = 'expansion')                   AS expanded_customers,
        COUNT_IF(movement_type = 'contraction')                 AS contracted_customers,
        COUNT_IF(movement_type = 'churn')                       AS churned_customers,
        COUNT_IF(is_active)                                     AS active_customers

    FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE
    GROUP BY month_start

),

with_opening AS (

    SELECT
        *,

        -- Opening MRR is last month's closing MRR. Deriving it with LAG rather
        -- than summing prior_mrr_usd is deliberate: prior_mrr_usd is per-customer
        -- and NULL for a customer's first month, so SUM(prior_mrr_usd) silently
        -- omits exactly the customers who joined — which is to say, it omits the
        -- new business and the waterfall stops closing in every growth month.
        LAG(closing_mrr) OVER (ORDER BY month_start)            AS opening_mrr,

        -- Trailing 3-month average of net new MRR. A frame, not a self-join:
        -- the point of window functions is that "the last three rows" is a range
        -- expression, not a join condition.
        AVG(closing_mrr) OVER (
            ORDER BY month_start
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        )                                                       AS mrr_3mo_moving_avg,

        -- Rank each month by net growth without collapsing the rows. This is the
        -- thing a GROUP BY cannot do: keep the detail and add the aggregate.
        RANK() OVER (ORDER BY closing_mrr DESC)                 AS month_rank_by_mrr

    FROM monthly_movement

),

waterfall AS (

    SELECT
        month_start,
        TO_CHAR(month_start, 'YYYY-MM')                         AS month_label,

        COALESCE(opening_mrr, 0)                                AS opening_mrr,
        new_mrr,
        reactivation_mrr,
        expansion_mrr,
        contraction_mrr,
        churned_mrr,
        closing_mrr,

        -- The components, netted. Gross vs net churn is the distinction that
        -- separates a company that is growing from one that is treading water:
        -- gross churn counts only what left; net churn subtracts what expanded.
        -- Reporting only one of them is how a deck says "5% churn" and means
        -- whichever number was kinder.
        churned_mrr + contraction_mrr                           AS gross_churn_mrr,
        churned_mrr + contraction_mrr + expansion_mrr + reactivation_mrr
                                                                AS net_churn_mrr,
        new_mrr + reactivation_mrr + expansion_mrr + contraction_mrr + churned_mrr
                                                                AS net_new_mrr,

        new_customers,
        reactivated_customers,
        expanded_customers,
        contracted_customers,
        churned_customers,
        active_customers,

        mrr_3mo_moving_avg,
        month_rank_by_mrr

    FROM with_opening

)

SELECT
    month_label,

    ROUND(opening_mrr, 0)                                       AS opening_mrr,
    ROUND(new_mrr, 0)                                           AS "+ new",
    ROUND(reactivation_mrr, 0)                                  AS "+ reactivation",
    ROUND(expansion_mrr, 0)                                     AS "+ expansion",
    ROUND(contraction_mrr, 0)                                   AS "- contraction",
    ROUND(churned_mrr, 0)                                       AS "- churn",
    ROUND(closing_mrr, 0)                                       AS closing_mrr,

    -- The proof. This column must be 0.00 on every row. It is kept in the output
    -- rather than asserted and hidden, because a waterfall you cannot check is a
    -- waterfall nobody believes — and the one time it is not zero, you want to
    -- see it in the same grid as the numbers, not in a test log.
    ROUND(
        opening_mrr + new_mrr + reactivation_mrr + expansion_mrr
        + contraction_mrr + churned_mrr - closing_mrr,
    2)                                                        AS reconciliation_check,

    ROUND(net_new_mrr, 0)                                       AS net_new_mrr,
    ROUND(100.0 * net_new_mrr / NULLIF(opening_mrr, 0), 1)      AS net_new_pct,

    -- Net revenue retention: what last month's cohort is worth this month,
    -- ignoring new business. >100% means existing customers grew enough to more
    -- than cover churn — the number investors ask for first.
    ROUND(
        100.0 * (opening_mrr + expansion_mrr + contraction_mrr + churned_mrr)
        / NULLIF(opening_mrr, 0),
    1)                                                        AS net_revenue_retention_pct,

    -- Gross revenue retention: same, but expansion cannot mask churn. Always
    -- <=100%. The gap between GRR and NRR is exactly how much of the growth story
    -- depends on upsell.
    ROUND(
        100.0 * (opening_mrr + contraction_mrr + churned_mrr)
        / NULLIF(opening_mrr, 0),
    1)                                                        AS gross_revenue_retention_pct,

    active_customers,
    new_customers,
    churned_customers,
    ROUND(100.0 * churned_customers / NULLIF(LAG(active_customers) OVER (ORDER BY month_start), 0), 1)
                                                                AS logo_churn_pct

FROM waterfall
WHERE opening_mrr IS NOT NULL   -- the first month has no prior to open from
ORDER BY month_start;


/* ---------------------------------------------------------------------------
   2. The same movement, per customer, for drill-through.

   When someone asks "why did expansion spike in March?", the answer is a list of
   customers, not a bigger aggregate. QUALIFY is the point here: it filters on a
   window function without the extra subquery SELECT/WHERE would need, which is
   the difference between a readable query and a nested one.
   --------------------------------------------------------------------------- */

SELECT
    TO_CHAR(f.date_key, 'YYYY-MM')                              AS month_label,
    c.company_name,
    c.size_band,
    c.sales_region,
    p.tier,
    f.movement_type,
    ROUND(f.prior_mrr_usd, 0)                                   AS prior_mrr,
    ROUND(f.mrr_usd, 0)                                         AS current_mrr,
    ROUND(f.mrr_delta_usd, 0)                                   AS mrr_delta,

    -- Each customer's share of that month's total movement of their own type.
    -- A window function partitioned two ways: the denominator is "all expansion
    -- in March", computed without a self-join or a second pass.
    ROUND(
        100.0 * f.mrr_delta_usd
        / NULLIF(SUM(f.mrr_delta_usd) OVER (PARTITION BY f.date_key, f.movement_type), 0),
    1)                                                        AS pct_of_month_movement,

    -- Running total of this customer's lifetime MRR change, so a drill-through
    -- shows trajectory rather than a single month out of context.
    ROUND(
        SUM(f.mrr_delta_usd) OVER (
            PARTITION BY f.customer_id
            ORDER BY f.date_key
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ),
    0)                                                        AS cumulative_mrr_change

FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE       AS f
INNER JOIN REVENUE_ANALYTICS.MARTS.DIM_CUSTOMER AS c
    ON f.customer_key = c.customer_key
LEFT JOIN REVENUE_ANALYTICS.MARTS.DIM_PRODUCT   AS p
    ON f.plan_key = p.plan_key
WHERE f.movement_type IN ('new', 'reactivation', 'expansion', 'contraction', 'churn')

-- Top 20 movers per month per type. Without QUALIFY this needs a wrapping
-- subquery purely to filter on the ROW_NUMBER.
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY f.date_key, f.movement_type
    ORDER BY ABS(f.mrr_delta_usd) DESC
) <= 20

ORDER BY f.date_key DESC, f.movement_type ASC, ABS(f.mrr_delta_usd) DESC;
