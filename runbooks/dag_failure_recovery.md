# Runbook — `revenue_elt` DAG failure

**Alert source:** Slack `#data-alerts`, posted by the `on_failure_callback` on any task.
**DAG:** `revenue_elt` · **Schedule:** 03:00 UTC daily · **Owner:** data-platform

> The whole DAG is a full refresh from a seeded extract, and every task is
> idempotent. **In almost every case the correct action is: clear the failed task and
> let it re-run.** There is no partial state to unwind, no watermark to reset, no
> half-loaded table to truncate. If you find yourself hand-editing a table to recover
> this pipeline, stop — that is not a step in this runbook and it will break the
> raw-vs-staging reconciliation test tomorrow.
>
> The exceptions are listed under [Do not do these](#do-not-do-these).

## 0. First 60 seconds

```
Which task failed?   -> the Slack alert names it and links the log
Did tests pass?      -> if dbt_test is green, the marts are fine; nothing is published wrong
Is anything stale?   -> check the marts' latest date_key (query below)
```

```sql
-- Are the marts current? Run as REPORTER.
SELECT MAX(date_key) AS latest_month, COUNT(*) AS rows
FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE;
```

**The key fact for triage: nothing publishes unless `dbt_test` passed.** `publish_gate` sits
downstream of it with `trigger_rule="all_success"`. If the failure is anywhere at or before
`dbt_test`, the marts are simply yesterday's — stale, not wrong. Stale is an inconvenience;
wrong is an incident. Do not treat them the same, and do not rush a fix that risks turning
the first into the second.

## 1. Triage by task

### `extract.generate_source_extracts`

The simulator failed. Almost always disk or a Python environment problem.

```bash
docker compose exec airflow-scheduler bash -c "df -h /opt/airflow/data"
docker compose exec airflow-scheduler python /opt/airflow/data_generator/simulate.py --out /tmp/probe --customers 100
```

**Fix:** clear the task and re-run. The extract is seeded (`--seed 42`), so it regenerates
byte-identical files. There is no "partially generated" state to clean up — it writes whole
files or fails.

### `load_to_snowflake.put_files_to_stage`

Network, credentials, or Snowflake reachability. Not a data problem.

```sql
-- Did anything land?
LIST @REVENUE_RAW.BILLING.STG_LANDING;
```

**Fix:** clear and re-run. Safe because the `PUT` uses `OVERWRITE = TRUE` — a re-upload
replaces rather than accumulating `customers_1.csv.gz` next to `customers.csv.gz`.

> **If someone has removed `OVERWRITE`, stop and check the stage.** Duplicate staged files
> get globbed by the `COPY`, every row loads twice, and the failure surfaces three tasks
> later looking like a dbt bug. `LIST` the stage before re-running.

If the credentials are the problem, check the key hasn't rotated:
```bash
docker compose exec airflow-scheduler bash -c 'snowsql -a $SNOWFLAKE_ACCOUNT -u $SNOWFLAKE_USER -r LOADER -q "SELECT CURRENT_ROLE(), CURRENT_WAREHOUSE();"'
```

### `load_to_snowflake.copy_into_raw`

A data or schema problem — `ON_ERROR = ABORT_STATEMENT` means one malformed file stops the
statement.

```sql
-- What did COPY object to? This is the first query to run, always.
SELECT file_name, status, row_count, row_parsed, first_error_message, first_error_line_number
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'REVENUE_RAW.BILLING.INVOICES',
    START_TIME => DATEADD(HOUR, -3, CURRENT_TIMESTAMP())
))
ORDER BY last_load_time DESC;
```

`first_error_message` names the file, the line and the column. Three usual causes:

| Symptom | Cause | Fix |
|---|---|---|
| "Number of columns in file does not match" | Generator schema changed, `COPY` column list didn't | Update `snowflake_setup/03_copy_into.sql`; the column order is asserted against the CSV header |
| "Field delimiter ',' found while expecting record delimiter" | An unescaped quote in `company_name` | File format issue — check `FIELD_OPTIONALLY_ENCLOSED_BY` |
| Loads 0 rows, no error | Snowflake skipped the files as already-loaded (64-day load history) | The `PUT` didn't `OVERWRITE`, so the checksum matched. Re-`PUT`, then re-run |

That last row is the nasty one: it is a *success* that loaded nothing, and the
`TRUNCATE` before it means the table is now empty. The row-count verification at the foot
of `03_copy_into.sql` catches it.

**Fix:** correct the cause, then clear and re-run. `TRUNCATE` + `COPY` means re-running is
always safe — there is no double-load risk from the `COPY` itself.

### `transform.dbt_run`

A model failed to build. Marts are stale but correct; the gate never opened.

```bash
docker compose exec airflow-scheduler bash -c "cd /opt/airflow/dbt_project && dbt run --target prod --select <failed_model>"
```

**SLA miss on this task (>30 min)** is not a failure — the task may still be running and will
probably succeed. It is a signal: `dbt_run` duration tracks data volume, so a creeping SLA
miss means the book grew. Cold-warehouse variance is noise. Do not react to one miss; react
to a trend.

**Fix:** fix the model, clear, re-run. dbt models here are `table`/`view` materializations
rebuilt from scratch, so a half-built model is impossible — dbt builds into a temp relation
and swaps.

### `transform.dbt_test` ← **the one that matters**

**This is the good outcome.** A failed test means the framework did its job: bad data was
caught *before* `publish_gate`, and nothing downstream was republished. The marts still hold
the last known-good build. Resist the urge to make it green quickly.

`retries: 0` on this task is deliberate — a test failure is a fact about the data, not a
transient blip, and re-running it three times just delays the alert by 35 minutes.

Every test writes its failing rows to a table (`store_failures: true`). **Read the rows
before theorising:**

```sql
SHOW TABLES IN SCHEMA REVENUE_STAGING.TEST_FAILURES;

-- e.g. the grain test
SELECT * FROM REVENUE_STAGING.TEST_FAILURES.ASSERT_FCT_REVENUE_GRAIN_IS_CUSTOMER_MONTH LIMIT 50;
```

| Failed test | What it means | Where to look |
|---|---|---|
| `assert_raw_staging_row_reconciliation` | Staging removed rows that were not duplicates, or failed to remove ones that were | The dedup window in `stg_invoices`. Check the `PUT` didn't double-stage first — that presents identically |
| `assert_mrr_waterfall_reconciles` | **A double-count.** The components no longer sum to MRR | A fan-out. Check `int_customer_months` — a customer with two spells overlapping `month_end` |
| `assert_allocation_conserves_revenue` | Proration is leaking or inventing revenue | `int_revenue_allocated_to_months`. If `summed_fraction != 1.0`, a billing period fell partly outside `int_month_spine` |
| `assert_timezone_correction_applied` | The IST fix hit the wrong rows | `stg_invoices`. Worse than no fix — check `is_tz_corrected` vs `source_system` |
| `assert_arr_run_over_run_tolerance` | **A closed month's ARR moved.** See below | Compare the last two snapshots |
| `relationships` on `subscription_id` (warn) | Orphan invoices >550 | Expected up to ~500 (late-arriving parents). Above that, the subscriptions extract is broken |

#### If `assert_arr_run_over_run_tolerance` failed

A historical month's ARR changed between runs. **Do not clear and re-run — it will fail
again, and that is correct.** Find out what moved:

```sql
WITH ranked AS (
    SELECT snapshot_run_id, snapshot_at,
           ROW_NUMBER() OVER (ORDER BY snapshot_at DESC) AS rn
    FROM (SELECT DISTINCT snapshot_run_id, snapshot_at FROM REVENUE_ANALYTICS.MARTS.FCT_ARR_SNAPSHOT)
)
SELECT
    prev.date_key,
    prev.total_arr_usd AS before_arr,
    curr.total_arr_usd AS after_arr,
    ROUND(100.0 * (curr.total_arr_usd - prev.total_arr_usd) / NULLIF(prev.total_arr_usd, 0), 2) AS pct_move
FROM REVENUE_ANALYTICS.MARTS.FCT_ARR_SNAPSHOT AS prev
INNER JOIN REVENUE_ANALYTICS.MARTS.FCT_ARR_SNAPSHOT AS curr USING (date_key)
WHERE prev.snapshot_run_id = (SELECT snapshot_run_id FROM ranked WHERE rn = 2)
  AND curr.snapshot_run_id = (SELECT snapshot_run_id FROM ranked WHERE rn = 1)
ORDER BY ABS(pct_move) DESC;
```

Then: was there a model change deployed since the last run? `git log` the dbt project. If
yes, that change restated history — decide deliberately whether that is intended, and if it
is, say so out loud to whoever reads the ARR dashboard. If there was no model change, the
*source data* changed underneath a closed month, which is a conversation with the billing
system's owner, not a pipeline fix.

### `source_freshness`

A source hasn't been updated recently enough. **The marts published anyway** — this task runs
parallel to the transform and does not gate it, because a stale upstream is a message about
someone else's system, not a reason to stop republishing correct marts.

```sql
SELECT MAX(_loaded_at) AS last_load, DATEDIFF('hour', MAX(_loaded_at), CURRENT_TIMESTAMP()) AS hours_stale
FROM REVENUE_RAW.BILLING.INVOICES;
```

Thresholds: billing errors at 26h (not 24h — a daily load must be allowed to be two hours
late without paging anyone), CRM at 48h, FX at 72h. If billing is stale, the load failed
silently or the upstream stopped sending. Check `COPY_HISTORY` first.

## 2. Do not do these

- **Do not `--full-refresh` `fct_arr_snapshot`.** It is append-only and holds the run
  history that `assert_arr_run_over_run_tolerance` compares against. Full-refreshing it wipes
  that history and the test then passes *vacuously* — no prior run to compare to. You will
  have silenced the alarm rather than fixed the fault, and the next real restatement will go
  unnoticed. If you must, say so in the incident channel so people know the guard is down
  until the run after next.
- **Do not edit rows in `REVENUE_RAW`.** `LOADER` has no `UPDATE` grant precisely so this is
  not possible; if you find yourself reaching for `ACCOUNTADMIN` to do it, that is the signal
  to stop. Raw's only guarantee is that it is what the source sent.
- **Do not set a failing test to `severity: warn` to unblock a release.** If the test is
  wrong, fix the test in a PR with the reasoning. Downgrading it at 03:00 is how a test suite
  becomes decoration, and this one is the only thing standing between a bad model and the
  CFO's dashboard.
- **Do not re-run with `catchup=True`** to "fill a gap". The pipeline full-refreshes a fixed
  24-month window; there is no gap to fill, and it would run the identical job N times.

## 3. Escalation

| Situation | Action |
|---|---|
| Marts stale <24h, tests green | No escalation. Fix in hours. |
| Marts stale >24h | Notify `#finance-data` — someone is looking at a stale dashboard and does not know it |
| `assert_arr_run_over_run_tolerance` failed | Notify `#finance-data` **before** fixing. A restated closed month is their decision, not the pipeline's |
| Any test failed and marts published anyway | **Incident.** This should be impossible — `publish_gate` is `all_success`. If it happened, the gate is broken, and that is a bigger problem than the data |

## 4. Why recovery is this boring

Three properties, each a deliberate design choice, and each one paying for itself here:

1. **The extract is seeded.** Re-running produces identical files, so a retry cannot load
   different data than the attempt before it.
2. **The load is `TRUNCATE` + `COPY` with `OVERWRITE` on the `PUT`.** No watermark, no
   partial batch, no "did it get halfway".
3. **`max_active_runs=1`.** Two runs can never race to write the same models.

Together they mean the recovery procedure for nearly every failure is one sentence. That is
the return on the idempotency work — not elegance, but the fact that this document is short
and can be followed at 03:00 by someone who did not write the pipeline.
