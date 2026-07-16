/* ============================================================================
   Cohort retention — multi-level aggregation with GROUPING SETS
   ----------------------------------------------------------------------------
   Run as:  REPORTER
   Reads:   FCT_REVENUE, DIM_CUSTOMER

   Two questions that look like one:

     "How much of each signup cohort is still paying, N months in?"
     "...and how does that break down by segment, by region, and overall?"

   The second is where GROUPING SETS earns its place. The naive answer is one
   query per breakdown UNION ALL'd together, which scans fct_revenue once per
   grain. GROUPING SETS asks the optimiser for several grains from a single scan.
   On this data that is a nice-to-have; on a fact table that does not fit in
   cache it is the difference between a report and a meeting about the report.
   ============================================================================ */

-- ---------------------------------------------------------------------------
-- 1. The retention grid: cohort x months-since-signup.
-- ---------------------------------------------------------------------------

WITH cohort_base AS (

    SELECT
        c.customer_key,
        c.customer_id,
        c.cohort_month,
        c.size_band,
        c.sales_region,
        c.industry,

        f.date_key                                              AS activity_month,

        -- Months since signup. The x-axis of the grid. DATEDIFF on month
        -- truncates to whole months, which is what makes month 0 mean "the month
        -- they signed up" regardless of the day.
        DATEDIFF('month', c.cohort_month, f.date_key)           AS months_since_signup,

        f.mrr_usd,
        f.is_active

    FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE        AS f
    INNER JOIN REVENUE_ANALYTICS.MARTS.DIM_CUSTOMER AS c
        ON f.customer_key = c.customer_key

),

cohort_sizes AS (

    /* The denominator, fixed at month 0.

       This is the part cohort analyses get wrong. The denominator must be the
       cohort's size *at signup* — not the customers still present in the month
       being measured, which would make retention 100% forever by only counting
       survivors. Computing it once here and joining it back is what keeps the
       denominator from silently shrinking underneath the numerator. */
    SELECT
        cohort_month,
        size_band,
        sales_region,
        COUNT(DISTINCT customer_key)                            AS cohort_size,
        SUM(mrr_usd)                                            AS cohort_starting_mrr
    FROM cohort_base
    WHERE months_since_signup = 0
    GROUP BY cohort_month, size_band, sales_region

),

-- ---------------------------------------------------------------------------
-- 2. Multi-level aggregation.
--
-- GROUPING SETS asks for four different grains in one pass:
--   (cohort, month, size_band, region)  the full detail
--   (cohort, month, size_band)          collapsed across regions
--   (cohort, month, region)             collapsed across segments
--   (cohort, month)                     the headline cohort curve
--
-- ROLLUP or CUBE would also work. ROLLUP gives a fixed hierarchy
-- (cohort > size > region) and cannot produce the region-without-size grain.
-- CUBE gives every combination — 2^4 = 16 grains here — of which most are
-- meaningless ("retention by region, ignoring which cohort" is not a cohort
-- analysis). GROUPING SETS names exactly the four that get looked at, which is
-- both cheaper and honest about intent.
-- ---------------------------------------------------------------------------

retention_multilevel AS (

    SELECT
        cohort_base.cohort_month,
        cohort_base.months_since_signup,
        cohort_base.size_band,
        cohort_base.sales_region,

        /* GROUPING() returns 1 when a column was rolled up in this row's grain
           and 0 when it is a real value. Without it, the subtotal row for "all
           regions" has NULL in sales_region and is indistinguishable from a row
           for customers whose region genuinely is NULL — so a report either
           double-counts the subtotals into the detail or drops real NULL-region
           customers. This is the single most common GROUPING SETS bug and it is
           silent. */
        GROUPING(cohort_base.size_band)                         AS is_size_rolled_up,
        GROUPING(cohort_base.sales_region)                      AS is_region_rolled_up,

        COUNT(DISTINCT CASE WHEN cohort_base.is_active THEN cohort_base.customer_key END)
                                                                AS retained_customers,
        SUM(cohort_base.mrr_usd)                                AS retained_mrr

    FROM cohort_base
    GROUP BY GROUPING SETS (
        (cohort_base.cohort_month, cohort_base.months_since_signup, cohort_base.size_band, cohort_base.sales_region),
        (cohort_base.cohort_month, cohort_base.months_since_signup, cohort_base.size_band),
        (cohort_base.cohort_month, cohort_base.months_since_signup, cohort_base.sales_region),
        (cohort_base.cohort_month, cohort_base.months_since_signup)
    )

),

denominators AS (

    /* The cohort sizes, aggregated to match each grain above. */
    SELECT
        cohort_month,
        size_band,
        sales_region,
        GROUPING(size_band)                                     AS is_size_rolled_up,
        GROUPING(sales_region)                                  AS is_region_rolled_up,
        SUM(cohort_size)                                        AS cohort_size,
        SUM(cohort_starting_mrr)                                AS cohort_starting_mrr
    FROM cohort_sizes
    GROUP BY GROUPING SETS (
        (cohort_month, size_band, sales_region),
        (cohort_month, size_band),
        (cohort_month, sales_region),
        (cohort_month)
    )

)

SELECT
    TO_CHAR(r.cohort_month, 'YYYY-MM')                          AS cohort,

    -- Label the rolled-up rows explicitly. A human reading a grid needs to see
    -- "All regions", not an empty cell they will read as missing data.
    CASE WHEN r.is_size_rolled_up = 1   THEN 'All segments' ELSE r.size_band END
                                                                AS segment,
    CASE WHEN r.is_region_rolled_up = 1 THEN 'All regions'  ELSE r.sales_region END
                                                                AS region,

    r.months_since_signup                                       AS month_n,

    d.cohort_size,
    r.retained_customers,

    -- Logo retention: what fraction of the cohort is still paying.
    ROUND(100.0 * r.retained_customers / NULLIF(d.cohort_size, 0), 1)
                                                                AS logo_retention_pct,

    -- Net revenue retention: what the cohort is worth now vs at signup. Can
    -- exceed 100% — that is the point. A cohort can lose half its customers and
    -- still be worth more, if the survivors expanded. Reporting only logo
    -- retention hides exactly that, and it is usually the more important half.
    ROUND(100.0 * r.retained_mrr / NULLIF(d.cohort_starting_mrr, 0), 1)
                                                                AS net_revenue_retention_pct,

    ROUND(r.retained_mrr, 0)                                    AS retained_mrr,

    -- Month-on-month change within the cohort's own curve. The PARTITION BY has
    -- to include the grain flags, or the LAG would step across from the detail
    -- rows into the subtotal rows and compare a segment to a company total.
    ROUND(
        100.0 * r.retained_customers / NULLIF(d.cohort_size, 0)
        - LAG(100.0 * r.retained_customers / NULLIF(d.cohort_size, 0)) OVER (
            PARTITION BY r.cohort_month, r.is_size_rolled_up, r.is_region_rolled_up,
                         r.size_band, r.sales_region
            ORDER BY r.months_since_signup
        ),
    1)                                                        AS retention_change_pts

FROM retention_multilevel AS r
INNER JOIN denominators   AS d
    ON  r.cohort_month          = d.cohort_month
    AND r.is_size_rolled_up     = d.is_size_rolled_up
    AND r.is_region_rolled_up   = d.is_region_rolled_up
    AND COALESCE(r.size_band, '~')    = COALESCE(d.size_band, '~')
    AND COALESCE(r.sales_region, '~') = COALESCE(d.sales_region, '~')
    -- COALESCE on the join keys because rolled-up columns are NULL on both sides
    -- and NULL = NULL is never true. Omit this and every subtotal row silently
    -- vanishes from the result — the query returns the detail only, looks
    -- complete, and the totals are simply absent.

WHERE r.months_since_signup BETWEEN 0 AND 12
ORDER BY r.cohort_month, segment, region, r.months_since_signup;


/* ---------------------------------------------------------------------------
   The classic triangle grid, for a screenshot.

   PIVOT turns months-since-signup into columns. Fixed to 0-6 because PIVOT needs
   its column list at compile time — one of the real limits of SQL pivoting, and
   the reason BI tools do this client-side.

   The subquery selects exactly three columns, and that is load-bearing. PIVOT
   implicitly groups by every column that is neither the aggregate's input nor the
   pivot column, so any extra column silently becomes part of the grain. Carrying
   is_active through here (even though the WHERE already fixes it to TRUE) would
   add it to the implicit GROUP BY and split each cohort's row in two. Whatever
   the subquery does not need, it must not select.
   --------------------------------------------------------------------------- */

SELECT *
FROM (
    SELECT
        TO_CHAR(c.cohort_month, 'YYYY-MM')                      AS cohort,
        DATEDIFF('month', c.cohort_month, f.date_key)           AS month_n,
        f.customer_key
    FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE        AS f
    INNER JOIN REVENUE_ANALYTICS.MARTS.DIM_CUSTOMER AS c
        ON f.customer_key = c.customer_key
    WHERE DATEDIFF('month', c.cohort_month, f.date_key) BETWEEN 0 AND 6
      AND f.is_active
) AS cohort_activity
PIVOT (
    COUNT(customer_key) FOR month_n IN (0, 1, 2, 3, 4, 5, 6)
) AS p (cohort, m0, m1, m2, m3, m4, m5, m6)
ORDER BY cohort;
