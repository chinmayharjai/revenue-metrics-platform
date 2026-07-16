# SaaS Revenue Metrics Platform

> A SaaS CFO gets three different ARR numbers from three teams. This is the single pipeline everyone trusts.

Snowflake · dbt · Airflow · SQL · Python · Power BI · GitHub Actions · Snowflake Cortex

**Status:** under construction — built milestone by milestone, one PR each. The full
architecture diagram, results table and how-to-run land in M8.

| # | Milestone | Status |
|---|-----------|--------|
| M1 | Data simulator | ✅ |
| M2 | Snowflake setup (RBAC, schemas, COPY INTO) | ✅ |
| M3 | dbt project (staging → intermediate → marts) | ✅ |
| M4 | Expert SQL showcase | ⬜ |
| M5 | Airflow orchestration | ⬜ |
| M6 | CI/CD | ⬜ |
| M7 | Snowflake Cortex AI summaries | ⬜ |
| M8 | Power BI handoff + final README | ⬜ |

---

## M1 — Data simulator

```bash
pip install -r requirements.txt
python data_generator/simulate.py          # ~6s, writes data/raw/
pytest tests/ -v                           # 20 tests
```

Generates a 24-month SaaS billing history (window `2024-07-01 → 2026-06-30`, seeded so
runs are byte-identical) shaped like what actually lands in a warehouse RAW schema —
a billing system, a CRM, and an FX feed, none of them clean.

### What it emits

| File | Rows | Grain |
|------|-----:|-------|
| `customers.csv` | 10,000 | one row per account |
| `employees.csv` | 123 | sales org, self-referencing `manager_id` |
| `plans.csv` | 8 | product catalogue, 4 tiers × monthly/annual |
| `subscriptions.csv` | 47,552 | one row per subscription **spell** |
| `invoices.csv` | 511,089 | one row per invoice **line item** (114,985 invoices) |
| `fx_rates.csv` | 5,840 | daily rate-to-USD per currency |

Row counts are from `data/raw/_manifest.json`, written by the generator on every run.

Two design choices carry most of the modelling weight downstream:

**Subscriptions are spells, not statuses.** A spell is a contiguous period on one plan
at one seat count. A plan change closes one spell and opens the next, which is what lets
the transform layer classify MRR movement — new, expansion, contraction, churn — by
diffing consecutive spells rather than trusting a status column.

**Billing is on the anniversary date, not the calendar month.** Real SaaS billing does
this, and it means a customer-month revenue grain *cannot* be reached with a `GROUP BY
date_trunc('month', ...)`. A period running 14 Mar → 13 Apr has to be allocated across
two calendar months. That allocation is the intermediate layer's job (M3).

Nine currencies (USD-heavy, ~42% US), eight plans across Starter/Growth/Pro/Enterprise,
~12% annual contracts. Invoice lines include `subscription`, `tax`, `seats_addon`,
`overage`, `discount`, `platform_fee`, `support_plan`, and `proration_credit` — credits
are negative, and an annual contract cut short by a plan change gets a prorated one back.

### Injected data problems

The data is dirty on purpose. Every defect is injected deliberately, counted on the
**emitted file**, and written to `_manifest.json` — so when a dbt test in M3 says it
caught something, the claim is anchored to a number anyone can reproduce by opening the
CSV and counting, rather than an anecdote.

| Problem | Count | What it breaks, and what has to handle it |
|---------|------:|-------------------------------------------|
| **Duplicate invoice lines** | 10,011 | Billing replays a batch; the line is re-emitted verbatim with a later `ingested_at`. `SELECT DISTINCT` will *not* remove these — the ingestion metadata differs. Dedup must key on `(invoice_id, line_number)` and keep `max(ingested_at)`. |
| **Timezone bug** | 40,965 rows shifted → **9,352** misdated days → **434** crossed a month close | `billing_sync_v2` writes IST wall-clock (UTC+5:30) into `issued_at`, a column its contract documents as UTC. Only the 434 month crossings actually move money between reporting periods — that's the number worth quoting; the other 40k are harmless. |
| **Late-arriving records** | 7,569 | `ingested_at` lands 3–30 days after `issued_at` — i.e. after that calendar month closed. An incremental model keyed on the current month silently loses them; it has to reprocess a trailing window. |
| **Orphan invoice lines** | 500 | `subscription_id` references a subscription absent from the extract. Caught by the dbt `relationships` test on `stg_invoices`. |
| **Null `payment_method`** | 25,822 | Missing on a slice of invoices; fans out to every line of those invoices. |
| **Null `employee_count`** | 1,277 | Optional CRM field left blank. Models must tolerate it; tests pin *which* columns may be null. |
| **Null `industry`** | 661 | As above. |

A note on why the counts don't equal `rate × rows`: invoice defects are injected at
**header** grain and fan out across that invoice's line items. The 5% `payment_method`
knob touches ~5% of 114,985 invoices, which surfaces as 25,822 of 511,089 lines. The
manifest records the grain of each injection for exactly this reason.

> This was a bug before it was a feature. The manifest originally counted defects at
> injection time, at header grain, and under-reported the timezone bug by 4.5× — it
> claimed 378 affected rows where the file had 1,708. `tests/test_simulate.py` caught it
> by counting the emitted CSV instead of trusting the generator's own bookkeeping. The
> tests now exist to hold the manifest to account, which is the only reason the numbers
> in this README are worth anything.

### Tests

`pytest tests/` runs 20 checks in ~6s. They assert the manifest is truthful (declared
count == count in file, for every defect), that the org hierarchy has exactly one root
and no cycles (a cycle would hang the recursive CTE in M4), that subscription spells
don't overlap per customer (overlap would double-count MRR), that every movement type
and churn actually occur, that FX covers every currency in the book, and that generation
is deterministic for a given seed — without which the measured numbers above rot.

---

## M2 — Snowflake setup

> **Not yet executed.** These scripts are written against Snowflake but have not been
> run — this repo has no Snowflake account attached. Nothing in this section is
> presented as a measured result. To verify: open a trial, run the three files in
> order, and the verification queries at the foot of each will tell you whether the
> claims hold. Where a number appears below it comes from `_manifest.json`, which is
> measured locally.

```
snowflake_setup/
├── 01_rbac_roles.sql      # roles, grants between them, warehouses, resource monitor
├── 02_schema_design.sql   # databases, schemas, raw DDL, object grants
└── 03_copy_into.sql       # file format, stage, loads, verification
```
Run in numeric order. `01` needs `USERADMIN`/`SYSADMIN`/`ACCOUNTADMIN`, `02` needs
`SYSADMIN`/`SECURITYADMIN`, `03` runs as `LOADER`.

### RBAC: two tiers, not three roles

Access roles hold privileges on objects (`RAW_READ` can `SELECT` from raw). Functional
roles hold job descriptions (`TRANSFORMER` is what dbt runs as). Functional roles are
granted access roles; users are granted functional roles.

The tiers exist because the privilege set and the job description change for different
reasons. Adding a database touches access roles only; hiring an analyst touches
functional roles only. Collapse them and every new database re-opens "who should see
this?" in three places at once.

| Role | Has | Deliberately does **not** have | Why |
|---|---|---|---|
| `LOADER` | `RAW_WRITE` (`INSERT`, `TRUNCATE`) | `RAW_READ`, `UPDATE`, `DELETE` | A loader that can't read back what it wrote isn't an exfiltration path if its key leaks. No `UPDATE` means it can't quietly "fix" a source value — which would destroy raw's only guarantee: that it is what the source sent. |
| `TRANSFORMER` | `RAW_READ`, staging + analytics read/write | `RAW_WRITE` | dbt must never alter its own source of truth. If a model could write back to raw, the raw-vs-staging reconciliation test in M3 would be checking dbt against itself and be worth nothing. |
| `REPORTER` | `ANALYTICS_READ`, `USAGE` on `WH_REPORTING` | `STAGING_READ`, `RAW_READ`, `OPERATE` | **This grant is the product.** If analysts can reach staging, someone builds a dashboard on an intermediate model, and there are three ARR numbers again — the exact problem this platform exists to solve. No `OPERATE` means nobody can `ALTER` the warehouse to a 4XL to make their query faster; cost control belongs in the grant, not a Slack reminder. |

Three XS warehouses, one per function — per-function cost attribution, and a backfill
can't queue behind a dashboard refresh. All XS deliberately: this is 500K rows, and
resizing to fix a slow query is the expensive way to avoid reading the query profile
(M4 makes that argument with an actual profile).

### Three databases, not one with three schemas

Costs some ceremony, buys a blast radius (`DROP DATABASE REVENUE_STAGING` can't take
the marts with it) and a grant boundary that's hard to fumble — `REPORTER` simply isn't
wired to the other two, so there's no per-schema exception to forget. Time Travel
retention is set per layer by what a mistake costs: raw 7d (re-landing 24 months is an
afternoon), staging 1d (a `dbt build` rebuilds it — paying to time-travel a derived
table is paying twice), analytics 30d (someone *will* ask what the dashboard said on
the 3rd, before the restatement).

### Two decisions worth calling out

**`issued_at` is `TIMESTAMP_NTZ`, not `TIMESTAMP_TZ`.** The source contract documents it
as UTC; `billing_sync_v2` actually writes IST wall-clock into it. Typing it `TZ` forces a
zone at load time — either believing the contract and baking the 5h30m error into raw
permanently where it can't be told apart from a real timestamp, or guessing per row.
`NTZ` stores exactly the wall-clock the source sent and defers the question to
`stg_invoices`, where the correction is a visible, testable, revertable line of SQL
rather than an assumption frozen into DDL.

**Raw has no constraints and `ON_ERROR = ABORT_STATEMENT`.** Not a contradiction: the
injected defects are *well-formed CSV rows containing bad data*, which `COPY` has no
opinion about, so they land and M3's tests can count them. `ABORT_STATEMENT` catches
malformed *files* — wrong column count, broken quote — which is a different failure and
always operator error. `ON_ERROR = CONTINUE` would load 90% of a broken file, go green,
and surface an hour later as a reconciliation failure pointing at dbt.

Loads are `TRUNCATE` + `COPY` (full refresh). At 511K rows that's seconds on an XS and
trivially idempotent. Incremental loading here would optimise the cheapest step in the
pipeline while introducing the one bug class this dataset is built to expose — did the
watermark advance past a late arrival? The 7,569 late-arriving lines get handled in dbt
with a trailing window, where it's testable.

---

## M3 — dbt project

> **Not yet executed against Snowflake** (no account attached), so no row counts or
> runtimes from the warehouse are claimed here. What *has* been verified locally, and
> runs in CI from M6: every model and test templates and parses cleanly against the
> Snowflake dialect via `sqlfluff lint` (0 parse errors, 0 rule violations). That
> catches syntax, not semantics — `dbt build` is what proves the logic, and it needs a
> warehouse.

```
dbt_project/models/
├── staging/          6 models — clean, rename, cast, dedup, correct
├── intermediate/     5 models — spells, currency, allocation, customer-months
└── marts/            5 models — fct_revenue, fct_arr_snapshot, dim_customer/product/date
```

```bash
cd dbt_project
cp profiles.yml.example ~/.dbt/profiles.yml   # every value reads from env vars
dbt deps && dbt build && dbt docs generate
```

### The star schema

`fct_revenue` is the published contract — grain: **one row per customer per calendar
month**, from signup to the window end. It carries two different kinds of money, and
conflating them is the single most likely misuse of the table:

| | `mrr_usd` / `arr_usd` | `recognized_revenue_usd` |
|---|---|---|
| **Is** | Contracted run-rate at month end | Revenue earned in the month |
| **Answers** | "What are we owed per month if nothing changes?" | "What did we actually earn in March?" |
| **From** | subscriptions | invoices, allocated pro-rata |
| **Kind** | a commitment (snapshot) | an earning (time-weighted) |

**They do not tie out, and shouldn't.** An annual customer commits 12× their MRR but is
invoiced once; a customer who churns mid-month has zero closing MRR and a fortnight of
recognized revenue. Reports that add them together, or use one to check the other, are
wrong — so both the model and the schema docs say so out loud.

### The three decisions that carry the project

**Allocation, not `date_trunc`.** Anniversary billing means a period runs 14 Mar → 13
Apr: one invoice, two calendar months (an annual contract spans thirteen).
`int_revenue_allocated_to_months` spreads each line across the months it actually pays
for, pro-rata by days. `date_trunc('month', issued_at)` would dump the whole charge into
March, overstate it, leave a hole in April — and do it consistently enough to look like
seasonality rather than a bug. `assert_allocation_conserves_revenue.sql` pins the
invariant: for every line, the slices must sum back to the amount **and** the fractions
must sum to exactly 1.0. The second half is the stronger one — a period partly outside
the month spine would allocate 95% of itself and still look internally consistent if
only the amount were checked.

**A spine, not an aggregation.** `int_month_spine` and `int_customer_months` enumerate
every customer-month and let MRR be zero, rather than aggregating the months that happen
to appear in the data. Churn is not an event here — no source table has a "churned" row
to count. Churn is the *absence* of MRR in a month that followed MRR, and you cannot
detect an absence in a dataset containing only presences. Give a churned customer no
April row and April's churn is zero forever, and every test still passes.

**MRR is defined once.** `seats × plan list price`. Overage and add-ons excluded (usage
isn't recurring — a customer who overran quota once hasn't expanded their contract),
discounts excluded (this is *list* MRR), tax excluded everywhere always. Reasonable
companies define it differently; the point is that it's written down in one model and
everything inherits it, rather than three teams each picking one — which is the premise
of the whole repo.

### Tests — 163 of them

| Kind | Count |
|---|---:|
| `not_null` | 37 |
| `dbt_utils.accepted_range` | 19 |
| `relationships` (referential integrity) | 13 |
| `accepted_values` | 13 |
| `unique` / `unique_combination_of_columns` (grain) | 5 + inline |
| Custom singular tests | 9 |
| **Total** | **163** |

Counted from the YAML and `tests/`, not estimated. The nine custom ones are where the
real thinking is:

- **`assert_raw_staging_row_reconciliation`** — the naive `count(raw) = count(staging)`
  would fail every run (staging legitimately drops 10,011 replays), get marked
  `severity: warn`, and never be read again. This asserts the arithmetic instead:
  `raw − duplicates_removed = staging`. If dedup ever drops a *real* line, this fails
  even though the count looks plausible.
- **`assert_mrr_waterfall_reconciles`** — `prior + new + reactivation + expansion +
  contraction + churn == mrr`, per customer-month. **This is the test that catches a
  double-count.** A fan-out gives one customer two rows and every column still looks
  reasonable — MRR positive, categories valid, nothing null — the total is just too big.
  No single-column test finds that. Only the identity does.
- **`assert_allocation_conserves_revenue`** — described above.
- **`assert_timezone_correction_applied`** — pins that the fix hit *exactly* the 40,965
  broken rows and no others. A correction applied to the wrong set would move 460K good
  rows by 5h30m and look, on any summary query, like it had worked.
- **`assert_usd_conversion_is_correct`** — three checks whose combination matters: USD
  converts to itself (a control — if the divide were a multiply, USD still passes and
  every US spot-check looks clean while JPY is off by 151×), no conversion produced
  NULL, and non-USD amounts actually changed.
- **`assert_arr_run_over_run_tolerance`** — see below.
- Plus grain, org-hierarchy traversability (one root, no cycles, depth within what
  `dim_customer` flattens), and credit-line signs.

### The ARR tolerance test is not month-over-month

The PRD asked for a day-over-day ARR tolerance. Implemented as **run-over-run** instead,
backed by `fct_arr_snapshot` (append-only, one row per dbt run per month), because the
obvious readings are both broken:

- *This month vs last month* fails on legitimate growth — a book ramping from zero moves
  >10% month-over-month for real, so the test either cries wolf or is set so loose it
  catches nothing.
- *Versus a hardcoded expected number* rots the first time the data legitimately changes,
  and someone edits the constant to make CI green without reading why it moved.

What actually matters is different: **a closed month's ARR changed between two runs.**
March 2025 is a fact. If today's run disagrees with yesterday's about it, a code change
moved a closed month — the exact failure this platform exists to prevent, and invisible
to any test that only looks at one run. The threshold (10%, in `dbt_project.yml`) isn't
statistical; it's "no legitimate overnight change to a 24-month book is this big".

Honest gap: the test passes vacuously on the first run and after a `--full-refresh` of
the snapshot, which wipes the history. That's why full-refreshing that model is called
out as a deliberate act in the runbook rather than something to try when a run looks
stuck.

### Materialization, and where the severity calls are

Staging is views (thin work, rebuilt free) except `stg_invoices`, which is a table — it's
the only staging model doing real work (a window function over 511K rows) and every
downstream model reads it, so as a view the dedup would re-execute on every reference.
Intermediate is **ephemeral by default**, so the layer names steps without becoming
tables people build dashboards on — the same failure `REPORTER`'s missing `STAGING_READ`
grant prevents from the other direction. Two intermediate models override that where the
fan-out is expensive enough to persist. Marts are tables.

`store_failures: true` globally: when a test fails at 03:00 the useful question is
"which rows?", and re-running a failing test by hand to find out wastes the one thing an
on-call has none of.

The most arguable line in the project is the `relationships` severity on
`stg_invoices.subscription_id`. The 500 orphans are late-arriving parents, not
corruption — the invoice is real, its subscription just hasn't landed. Erroring would
mean a source-side timing quirk stops ARR from publishing; dropping them silently would
understate revenue with no trace. So: `warn`, with `error_if: ">550"` — above that it
stops being lateness and becomes a broken extract.
