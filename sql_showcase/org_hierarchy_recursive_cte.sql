/* ============================================================================
   Sales org rollup — recursive CTE
   ----------------------------------------------------------------------------
   Run as:  REPORTER
   Reads:   DIM_CUSTOMER, FCT_REVENUE  (+ STG_EMPLOYEES for the raw tree)

   "Show me every VP's total ARR, including everyone beneath them."

   That question is unanswerable with a join, because the answer depends on how
   deep the tree is, and a join has to know its own depth at write time. Five
   levels means four self-joins; add a level and every query that flattened the
   hierarchy is quietly wrong — it does not error, it just stops including the
   new layer. dim_customer flattens to a fixed four columns precisely because
   Power BI cannot express recursion, and there is a dbt test
   (assert_org_hierarchy_is_traversable.sql) whose only job is to fail loudly if
   the org ever outgrows that flattening.

   This file is the general form: depth-independent, and it answers the rollup
   question in one pass.
   ============================================================================ */

-- ---------------------------------------------------------------------------
-- 1. Walk the tree, carrying the path down.
-- ---------------------------------------------------------------------------

WITH RECURSIVE org_tree AS (

    /* Anchor: the root. Exactly one row, which the dbt test guarantees — if there
       were two roots, this would produce two disconnected trees and each rollup
       would report a subtree as though it were the whole company. That failure
       returns a plausible number, which is why it is tested rather than trusted. */
    SELECT
        employee_id,
        manager_id,
        full_name,
        title,
        region,

        1                                                       AS depth,
        employee_id                                             AS root_id,

        -- The path is carried, not reconstructed. Materialising it here costs one
        -- string concat per row and buys the ability to answer "is X under Y?"
        -- with a LIKE instead of a second recursion.
        full_name                                               AS path,
        ARRAY_CONSTRUCT(employee_id)                            AS ancestor_ids

    FROM REVENUE_STAGING.STAGING.STG_EMPLOYEES
    WHERE manager_id IS NULL

    UNION ALL

    /* Recursive member: everyone reporting to someone already in the tree. */
    SELECT
        e.employee_id,
        e.manager_id,
        e.full_name,
        e.title,
        e.region,

        t.depth + 1                                             AS depth,
        t.root_id,
        t.path || ' > ' || e.full_name                          AS path,
        ARRAY_APPEND(t.ancestor_ids, e.employee_id)             AS ancestor_ids

    FROM REVENUE_STAGING.STAGING.STG_EMPLOYEES  AS e
    INNER JOIN org_tree                          AS t
        ON e.manager_id = t.employee_id

    /* The depth guard. Snowflake caps recursion and errors out, but a cycle in
       the data would hit that cap after burning warehouse time and report itself
       as a recursion-limit error rather than as "your org data has a loop".
       Bounding it here turns an infinite walk into a finite, diagnosable result.
       The dbt test asserts no cycle exists; this defends the query anyway,
       because a query that hangs at 03:00 is worse than one that returns
       something wrong at 03:00. */
    WHERE t.depth < 20

),

-- ---------------------------------------------------------------------------
-- 2. Every (manager, subordinate) pair, including the manager themselves.
--
-- This is the trick that makes the rollup a plain GROUP BY. Rather than
-- recursing again per manager, expand each employee into one row per ancestor.
-- An AE five levels deep produces five rows: one under themselves, one under
-- their manager, one under the director, and so on to the root. Joining revenue
-- to *that* and grouping by ancestor gives every level's rollup in a single
-- aggregate — no correlated subquery, no query-per-manager.
-- ---------------------------------------------------------------------------

manager_subordinate_pairs AS (

    SELECT
        f.value::VARCHAR                                        AS manager_employee_id,
        org_tree.employee_id                                    AS subordinate_employee_id,
        org_tree.depth                                          AS subordinate_depth
    FROM org_tree,
        LATERAL FLATTEN(input => org_tree.ancestor_ids)         AS f

),

-- ---------------------------------------------------------------------------
-- 3. Current ARR per account manager.
-- ---------------------------------------------------------------------------

arr_by_account_manager AS (

    SELECT
        c.account_manager_id,
        SUM(f.arr_usd)                                          AS arr_usd,
        SUM(f.mrr_usd)                                          AS mrr_usd,
        COUNT(DISTINCT CASE WHEN f.is_active THEN c.customer_id END)
                                                                AS active_customers
    FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE        AS f
    INNER JOIN REVENUE_ANALYTICS.MARTS.DIM_CUSTOMER AS c
        ON f.customer_key = c.customer_key
    -- Latest month only. A rollup of "current ARR" that summed every month would
    -- return 24 months of run-rate stacked on top of each other — a number ~20x
    -- too big that still looks like money.
    WHERE f.date_key = (SELECT MAX(date_key) FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE)
    GROUP BY c.account_manager_id

),

-- ---------------------------------------------------------------------------
-- 4. Roll it up the tree.
-- ---------------------------------------------------------------------------

rollup AS (

    SELECT
        pairs.manager_employee_id,

        SUM(COALESCE(arr.arr_usd, 0))                           AS total_arr_usd,
        SUM(COALESCE(arr.mrr_usd, 0))                           AS total_mrr_usd,
        SUM(COALESCE(arr.active_customers, 0))                  AS total_active_customers,
        COUNT(DISTINCT pairs.subordinate_employee_id) - 1       AS reports_beneath   -- exclude self

    FROM manager_subordinate_pairs                  AS pairs
    LEFT JOIN arr_by_account_manager                AS arr
        ON pairs.subordinate_employee_id = arr.account_manager_id
    -- LEFT: managers, directors and VPs own no accounts directly. An inner join
    -- would drop every non-AE and return a "hierarchy rollup" containing only the
    -- leaves — technically a correct sum of nothing.
    GROUP BY pairs.manager_employee_id

)

SELECT
    org_tree.depth,
    REPEAT('    ', org_tree.depth - 1) || org_tree.full_name     AS org_chart,
    org_tree.title,
    org_tree.region,
    org_tree.path,

    rollup.reports_beneath,
    rollup.total_active_customers,
    ROUND(rollup.total_arr_usd, 0)                              AS total_arr_usd,

    -- Each node's share of its parent's book. A window function over the
    -- recursion's output — the recursive CTE produced the tree, and this reads it
    -- like any other table.
    ROUND(
        100.0 * rollup.total_arr_usd
        / NULLIF(SUM(rollup.total_arr_usd) OVER (PARTITION BY org_tree.manager_id), 0),
    1)                                                        AS pct_of_managers_book,

    -- Rank siblings by book size.
    RANK() OVER (
        PARTITION BY org_tree.manager_id
        ORDER BY rollup.total_arr_usd DESC
    )                                                           AS rank_among_peers,

    ROUND(rollup.total_arr_usd / NULLIF(rollup.total_active_customers, 0), 0)
                                                                AS arr_per_customer

FROM org_tree
LEFT JOIN rollup
    ON org_tree.employee_id = rollup.manager_employee_id

ORDER BY org_tree.path;


/* ---------------------------------------------------------------------------
   Variant: the subtree beneath one VP.

   Because ancestor_ids is materialised, "everyone under EMP-00002" is a single
   ARRAY_CONTAINS — no second recursion, no LIKE on a path string that would
   match 'Dana Whitfield' inside 'Dana Whitfields'.

     SELECT full_name, title, depth
     FROM org_tree
     WHERE ARRAY_CONTAINS('EMP-00002'::VARIANT, ancestor_ids)
       AND employee_id != 'EMP-00002'
     ORDER BY path;

   ---------------------------------------------------------------------------
   Why not CONNECT BY?

   Snowflake supports CONNECT BY, and for a plain parent-child walk it is shorter:

     SELECT employee_id, full_name, LEVEL AS depth, SYS_CONNECT_BY_PATH(full_name, ' > ')
     FROM STG_EMPLOYEES
     START WITH manager_id IS NULL
     CONNECT BY PRIOR employee_id = manager_id;

   The recursive CTE is used here anyway, for two reasons. It is ANSI, so this
   query moves to BigQuery or Postgres unchanged — which matters in a portfolio
   spanning three clouds. And it composes: a CTE is a table expression, so the
   rollup can join to it, window over it, and flatten it, all in one statement.
   CONNECT BY is a clause on a single SELECT and stops being useful the moment the
   tree needs to be joined to something.
   --------------------------------------------------------------------------- */
