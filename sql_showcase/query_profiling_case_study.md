# Query profiling case study — clustering `fct_revenue`

> **Status: not yet measured.** This document is the experiment, not the result.
> Every runtime cell below is deliberately blank. This repo has no Snowflake account
> attached, so there is no profile to read and no before/after to report — and a
> performance case study with invented numbers is worse than no case study, because
> the numbers are the only part anyone checks.
>
> Everything needed to run it is here: the queries, the method, the hypothesis, and
> what would falsify it. Run the steps against a trial account and fill in the table.
> **If the results contradict the hypothesis, keep them** — a clustering key that
> didn't pay for itself is a more interesting finding than one that did, and the
> reason is in [When this is the wrong fix](#when-this-is-the-wrong-fix).

## The question

`fct_revenue` is ~170K rows (10K customers × their active months) and every consumer
filters it by month. The model declares `cluster_by = ['date_key']`. **Is that
clustering key earning its keep, or is it cargo cult?**

At this data volume the honest prior is: **probably not.** 170K rows is nothing — it
likely lands in a handful of micro-partitions that Snowflake scans in milliseconds
regardless. Clustering costs money continuously (automatic reclustering is a background
service billed in credits) and buys pruning that only matters when there is enough data
to prune. The interesting candidate is `stg_invoices` at 511K rows, or
`int_revenue_allocated_to_months`, which fans those out across months and is the largest
table in the project.

The experiment is designed to be able to say "no". That is the point of running it.

## Method

Run each step and record what it reports. Do not skip step 0.

### 0. Establish a baseline that isn't lying to you

```sql
-- Snowflake caches results for 24h. A second run of an identical query returns in
-- ~50ms without touching a warehouse, which looks exactly like a spectacular
-- optimisation and is in fact a cache hit. Every "we made it 100x faster" claim
-- that was never reproducible started here.
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Also suspend and resume the warehouse between runs. A warm warehouse has data in
-- local SSD cache; a cold one does not. Comparing a cold "before" to a warm "after"
-- measures the cache, not the change.
ALTER WAREHOUSE WH_REPORTING SUSPEND;
ALTER WAREHOUSE WH_REPORTING RESUME;
```

### 1. Find the genuinely slow query

Don't guess. Ask the account which query is actually slow:

```sql
SELECT
    query_id,
    LEFT(query_text, 120)                                    AS query_preview,
    warehouse_name,
    total_elapsed_time / 1000                                AS elapsed_sec,
    bytes_scanned / POWER(1024, 3)                           AS gb_scanned,
    partitions_scanned,
    partitions_total,
    ROUND(100.0 * partitions_scanned / NULLIF(partitions_total, 0), 1)
                                                            AS pct_partitions_scanned,
    bytes_spilled_to_local_storage / POWER(1024, 3)          AS gb_spilled_local,
    bytes_spilled_to_remote_storage / POWER(1024, 3)         AS gb_spilled_remote
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    END_TIME_RANGE_START => DATEADD('day', -7, CURRENT_TIMESTAMP()),
    RESULT_LIMIT => 500
))
WHERE query_type = 'SELECT'
  AND total_elapsed_time > 1000
ORDER BY total_elapsed_time DESC
LIMIT 20;
```

`pct_partitions_scanned` is the column that matters. **This is the whole diagnosis.**
If a query filtering on one month scans 100% of partitions, pruning is not happening and
a clustering key might fix it. If it already scans 4%, pruning is working and clustering
will change nothing — stop here and record that, because that *is* the finding.

`gb_spilled_remote` being non-zero means the query ran out of memory and spilled to S3.
That is a different problem with a different fix (a bigger warehouse, or less data in the
join), and no clustering key will touch it. Diagnosing a spill as a pruning problem is
the classic wasted afternoon.

### 2. Look at the pruning directly

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('REVENUE_ANALYTICS.MARTS.FCT_REVENUE', '(date_key)');
```

Read `average_overlaps` and `average_depth`. Depth ≈ 1 means partitions are cleanly
separated by `date_key` and a month filter reads only its own. High depth means every
partition contains rows from every month, so a month filter reads everything.

`partition_depth_histogram` is the one to screenshot — it shows the distribution, not
just the average, and a bimodal histogram (most partitions clean, a few catastrophic)
tells a story an average hides.

### 3. The query under test

The heaviest realistic read: the MRR waterfall's month aggregate, filtered to a quarter.

```sql
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

SELECT
    date_key,
    SUM(mrr_usd)            AS closing_mrr,
    SUM(new_mrr_usd)        AS new_mrr,
    SUM(churned_mrr_usd)    AS churned_mrr,
    COUNT_IF(is_active)     AS active_customers
FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE
WHERE date_key BETWEEN '2026-01-01' AND '2026-03-31'
GROUP BY date_key
ORDER BY date_key;
```

Then read the profile — **not `EXPLAIN`**:

```sql
EXPLAIN USING TEXT
SELECT ... ;                                        -- the estimated plan

SELECT * FROM TABLE(GET_QUERY_OPERATOR_STATS(LAST_QUERY_ID()));   -- what actually happened
```

`EXPLAIN` is the optimiser's *guess* before execution. `GET_QUERY_OPERATOR_STATS` and the
Query Profile tab report what really ran — actual partitions pruned, actual bytes, actual
spilling. A case study built on `EXPLAIN` alone is a case study about the planner's
opinion. Screenshot the **Query Profile** tab in Snowsight; that is the artifact worth
having.

### 4. Compare against no clustering

```sql
CREATE TABLE REVENUE_ANALYTICS.MARTS.FCT_REVENUE_UNCLUSTERED
    CLONE REVENUE_ANALYTICS.MARTS.FCT_REVENUE;

ALTER TABLE REVENUE_ANALYTICS.MARTS.FCT_REVENUE_UNCLUSTERED DROP CLUSTERING KEY;

-- Zero-copy clone: no storage duplicated, no load time. This is the cheapest honest
-- A/B in any warehouse. Note the clone inherits the *existing physical layout*, so it
-- starts already well-ordered — it only diverges as rows are rewritten. For a true
-- unclustered baseline, rebuild with CTAS and a shuffle:
--
--   CREATE TABLE ..._UNCLUSTERED AS
--   SELECT * FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE ORDER BY RANDOM();
--
-- Skipping this is the mistake that makes the "before" look identical to the "after"
-- and the whole experiment look like clustering does nothing.
```

Run the step-3 query against both, cold, three times each. Record the median, not the
best — the best run is the cache, and the mean is dragged by the cold start you already
tried to control for.

### 5. Cost

```sql
-- Reclustering is billed continuously and silently. A clustering key that saves 200ms
-- on a query run 40 times a day, while costing credits every hour to maintain, is a
-- net loss that no query-runtime chart will ever show you.
SELECT
    table_name,
    SUM(credits_used)   AS reclustering_credits,
    SUM(num_bytes_reclustered) / POWER(1024, 3)  AS gb_reclustered
FROM SNOWFLAKE.ACCOUNT_USAGE.AUTOMATIC_CLUSTERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY table_name
ORDER BY reclustering_credits DESC;
```

## Results

Fill these in from an actual run. Leave a cell blank rather than estimating it.

### Clustering health (step 2)

| Table | Clustering key | `average_depth` | `average_overlaps` | Total partitions |
|---|---|---|---|---|
| `FCT_REVENUE` | `(date_key)` | _TODO_ | _TODO_ | _TODO_ |
| `STG_INVOICES` | `(issued_month)` | _TODO_ | _TODO_ | _TODO_ |
| `INT_REVENUE_ALLOCATED_TO_MONTHS` | `(month_start)` | _TODO_ | _TODO_ | _TODO_ |

### Query under test (steps 3–4)

| | Unclustered | Clustered | Delta |
|---|---|---|---|
| Median elapsed (cold, n=3) | _TODO_ | _TODO_ | _TODO_ |
| Partitions scanned / total | _TODO_ | _TODO_ | _TODO_ |
| % partitions pruned | _TODO_ | _TODO_ | _TODO_ |
| Bytes scanned | _TODO_ | _TODO_ | _TODO_ |
| Spilled to local / remote | _TODO_ | _TODO_ | _TODO_ |

### Cost (step 5)

| Table | Reclustering credits / 30d | Queries/day benefiting | Verdict |
|---|---|---|---|
| `FCT_REVENUE` | _TODO_ | _TODO_ | _TODO_ |

### Screenshots to attach

- [ ] `SYSTEM$CLUSTERING_INFORMATION` output, both tables
- [ ] Query Profile tab — unclustered run (partitions scanned in the TableScan node)
- [ ] Query Profile tab — clustered run
- [ ] `AUTOMATIC_CLUSTERING_HISTORY` for the 30 days after

## The hypothesis, written before the measurement

Stated up front so it can be wrong:

1. **`FCT_REVENUE` clustering will show little or no benefit.** At ~170K rows the table
   is a handful of micro-partitions; there is not enough data to prune. Expect a
   single-digit-millisecond difference, inside the noise. **If so, the right action is to
   remove the clustering key**, and this document should record that.
2. **`INT_REVENUE_ALLOCATED_TO_MONTHS` is the real candidate.** It fans 511K invoice
   lines across every month each billing period covers — annual contracts explode into 13
   rows each — making it the largest table here. Every consumer filters it by
   `month_start`.
3. **Natural ordering may already do the job.** Rows are inserted in roughly
   chronological order, so `date_key` is already correlated with physical layout. If the
   unclustered clone prunes as well as the clustered table, clustering is paying for an
   ordering the insert pattern provides free. This is the most likely outcome and the
   most useful one to document.

## When this is the wrong fix

Reaching for a clustering key — or a bigger warehouse — is usually a way of avoiding
reading the profile. Before either:

- **Is it a cache hit?** (step 0). The most common "optimisation" in the wild.
- **Is it spilling?** `bytes_spilled_to_remote_storage > 0` is a memory problem. Clustering
  will not help. Either size up or reduce the join's working set.
- **Is the filter even prunable?** `WHERE DATE_TRUNC('month', date_key) = '2026-03-01'`
  wraps the column in a function and defeats pruning entirely — Snowflake cannot use
  min/max partition metadata through a function call. `WHERE date_key BETWEEN ... AND ...`
  prunes. **This one line is worth more than any clustering key**, and it is why the
  showcase queries filter on bare columns.
- **Is it exploding in a join?** A fan-out scans little and returns much. The profile
  shows it immediately: rows out ≫ rows in on a Join node.
- **Is the table big enough to care?** Below ~1GB, clustering is generally noise.
  `FCT_REVENUE` is far below that, which is exactly why hypothesis 1 expects a null result.

## Why this document exists in this shape

The PRD this repo was built from asked for a "45s → 3s" case study with EXPLAIN
screenshots. That number is not here because nothing was measured, and a fabricated
before/after would be the single most checkable lie in the repository — an interviewer
with a Snowflake account can reproduce it in ten minutes.

What is defensible without a warehouse is the reasoning: knowing that
`pct_partitions_scanned` is the diagnosis, that `EXPLAIN` is a guess and the Query Profile
is evidence, that the result cache invalidates a naive A/B, that a zero-copy clone needs a
shuffle to be a fair baseline, and that reclustering has a running cost that never appears
on a latency chart. That reasoning is the transferable part. The number is one run away.
