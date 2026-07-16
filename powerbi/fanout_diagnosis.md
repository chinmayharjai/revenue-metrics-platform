# The fan-out join that doubled one AE's revenue

> **Reproduced, not recalled.** Every number here comes from
> [`fanout_repro.py`](fanout_repro.py), which runs against the real generated data:
> `python powerbi/fanout_repro.py`. No Snowflake or Power BI needed — the bug is
> neither a Snowflake nor a Power BI bug. It is a cardinality bug, and cardinality
> is arithmetic.

## The headline is not 2× revenue

The brief for this writeup was "report showed 2× revenue → traced to a missing join
key". Reproducing it properly gives a more uncomfortable result:

| | Value |
|---|---|
| Total revenue, correct | `$5,930,051,653.30` |
| Total revenue, fanned out | `$5,964,292,211.86` |
| Inflation | `$34,240,558.56` — **+0.58%** |
| Customers affected | 117 of 10,000 (1.2% of the book) |
| Those 117 customers, reported | `$68,481,117.12` |
| Those 117 customers, actually | `$34,240,558.56` |
| **Their inflation factor** | **exactly 2.0×** |

**The company number moved 0.58%.** Nobody blinks at 0.58%. It looks like FX, or a
late invoice, or rounding. The dashboard is not obviously broken — it is quietly,
locally, exactly wrong.

That is the finding worth keeping. A report that shows 2× revenue gets fixed on
Monday morning, because it is absurd on sight. A report that shows +0.58% company-wide
and 2× for one account executive gets found *by that account executive, checking their
commission* — weeks later, after the number has been in a board pack.

## What broke

`dim_customer` flattens the sales org onto each account by joining customers to
employees:

```sql
from customers
left join employees as ae on customers.account_manager_id = ae.employee_id
```

That join is correct **if and only if `employee_id` is unique in the employees
extract.** The repro breaks exactly that, in the most boring way available:

```
INJECTED: employee_id EMP-00037 (AE AMER 1) duplicated
          — 1 extra row in a 123-row table
```

One duplicated row. Not corruption, not a schema change. This is what a re-hire, a
merged CRM record, or an extract that forgot `WHERE is_current = true` actually
produces.

The consequence:

```
dim_customer rows    10,000  ->  10,117   (+117)
```

`dim_customer` is supposed to have exactly one row per customer. Now 117 customers —
everyone managed by that AE — have two. Every measure sliced by that dimension
double-counts them.

## Why Power BI makes it worse

In a star schema, `dim_customer[customer_key]` is the *one* side of a
one-to-many relationship to `fct_revenue`. Power BI validates that at
relationship-creation time.

But when the dimension has duplicate keys, Power BI does not fail. It **silently
downgrades the relationship to many-to-many** and carries on. There is a small icon
change on the relationship line in the model view. That is the entire warning.

`SUM(fct_revenue[mrr_usd])` then fans across both dimension rows, and:

- The measure still returns a number.
- The number is still positive and plausibly sized.
- No error, no warning, no red cell.
- Every visual not sliced by that AE looks perfect.

So the failure is invisible in exactly the place people look (the total) and only
visible in the place nobody looks (one AE's row).

## The diagnosis path

What actually finds it, in order of how quickly it gets there:

**1. Compare the dimension's row count to its grain.** Ten seconds, catches it
immediately:
```sql
select count(*) as rows, count(distinct customer_id) as customers
from dim_customer;
-- 10,117 vs 10,000  -> the dimension is not at the grain it claims
```

**2. Find the duplicate key.**
```sql
select employee_id, count(*)
from stg_employees
group by employee_id
having count(*) > 1;
-- EMP-00037, 2
```

**3. Confirm the blast radius before fixing anything.**
```sql
select count(*) from dim_customer where account_manager_id = 'EMP-00037';
-- 234 rows for 117 customers
```

**Do not start from the measure.** The instinct is to rewrite the DAX — wrap it in
`DISTINCT`, or `SUMX` over a filtered table, or add `TREATAS`. All of those can be
made to return the right number, and all of them are the wrong fix: they patch one
visual while the dimension stays broken for every other measure, every future
report, and every other developer. The measure is not lying. The model is.

## The fix, and the test that should have caught it

The fix is upstream, in the extract: deduplicate employees, or add the
`WHERE is_current` the extract forgot.

The test already exists in this project, and has since M3:

```yaml
# dbt_project/models/staging/_staging__models.yml
- name: stg_employees
  columns:
    - name: employee_id
      tests: [not_null, unique]      # <- this one
```

The repro confirms both guards fire:

```
unique(stg_employees.employee_id)              -> FAILS, 2 rows share EMP-00037
unique_combination(customer_id) on the report  -> FAILS, 117 customers appear twice
```

**A one-line `unique` test on a 123-row dimension nobody thinks is interesting is
what stands between this bug and a board pack.** It costs nothing to run and it is
the single cheapest thing in the entire repository, which is the actual lesson: the
tests that earn their keep are almost never the clever ones.

`dim_customer`'s 5-level org chain is also flattened with joins rather than a
recursive CTE (see [`../sql_showcase/org_hierarchy_recursive_cte.sql`](../sql_showcase/org_hierarchy_recursive_cte.sql)),
and `assert_org_hierarchy_is_traversable.sql` guards the other half of the same
risk — an org that grows a sixth level would silently truncate rather than fan out,
which is the same class of bug pointing the other way.

## The Power BI page

> **No screenshot.** Power BI Desktop is Windows-only, requires a Microsoft account,
> and the marts it would read do not exist — nothing here has been deployed to a
> Snowflake account. A mocked-up screenshot presented as a live dashboard would be
> the same category of fiction this repo avoids everywhere else.

What it would contain, and the two decisions that matter:

**Connection: Import, not DirectQuery.** The marts are ~170K rows and refresh nightly.
DirectQuery would fire a Snowflake query per visual per interaction, resuming
`WH_REPORTING` constantly and turning a slider drag into a credit line item. Import
loads once after the DAG finishes. DirectQuery earns its place when the data is too
large to import or must be real-time; neither is true here, and choosing it anyway is
how a BI tool becomes the largest line on a warehouse bill.

**Reads `REVENUE_ANALYTICS.MARTS` only, as `REPORTER`.** That role has no grant on
staging (M2), which is what makes "one number" structural rather than a convention.
If a report author could reach `int_customer_months`, someone would eventually build a
visual on it, and the CFO would have three ARR numbers again — the exact problem the
platform exists to end.

| Visual | Source |
|---|---|
| ARR trend | `fct_revenue.arr_usd` by `dim_date.month_start` |
| MRR waterfall | the five pre-split movement columns — a `SUM`, not a `CASE` per report |
| NRR / GRR by segment | `dim_customer.size_band` |
| Cohort retention grid | `dim_customer.cohort_month` × months-since-signup |
| Org rollup | `dim_customer`'s flattened AE → manager → director → VP chain |

The movement columns (`new_mrr_usd`, `expansion_mrr_usd`, …) are pre-split in the mart
precisely so the waterfall visual is a `SUM` over a column rather than a DAX
re-implementation of "what counts as expansion". Every definition that lives in a
measure is a definition that eventually differs between two reports.

## Reproduce it

```bash
python data_generator/simulate.py     # if data/raw/ is empty
python powerbi/fanout_repro.py
```
