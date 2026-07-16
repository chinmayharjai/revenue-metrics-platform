<!--
  Two questions matter on a data PR, and reviewers reliably answer neither
  unless asked: what did the models change, and what proves it.

  A diff shows which files moved. It does not show that fct_revenue's grain is
  still one row per customer-month, or that the number on the CFO's dashboard
  means the same thing it meant yesterday. Only a test does that, and only the
  author knows which one.
-->

## What changed

<!-- One or two sentences. What does this do that main does not? -->

## What models changed, and what tests cover it

| Model | Change | Test that covers it |
|---|---|---|
| <!-- e.g. int_customer_months --> | <!-- e.g. added row_number() to break month-end ties --> | <!-- e.g. unique_combination_of_columns on (customer_id, month_start) --> |

<!--
  If a row here reads "none" — that is a fine answer, and it is the answer worth
  discussing. Some changes genuinely need no new test (a comment, a rename with
  no downstream reference). Say so explicitly rather than leaving the cell blank,
  so the reviewer knows it was considered rather than skipped.
-->

## Does this change a published number?

- [ ] **No** — no mart column's meaning or value changes.
- [ ] **Yes** — and I have said so below.

<!--
  If yes: which metric, by how much, and for which periods?

  This is the question the whole repo exists to answer. A model change that
  restates a closed month is not a bug by itself — sometimes the old number was
  wrong — but it must be a decision someone made on purpose, not a side effect
  that reaches the dashboard first and the conversation second.

  assert_arr_run_over_run_tolerance will fail the build if any month's ARR moves
  more than 10% between runs. If you expect it to fire, explain why here BEFORE
  merging, so the reviewer is agreeing to the restatement rather than to a green
  check.
-->

## Checks

- [ ] `sqlfluff lint` passes locally (CI runs it on models, `snowflake_setup/`, and `sql_showcase/`)
- [ ] `pytest tests/` passes
- [ ] If the simulator changed: manifest regenerated, committed, and the README numbers updated to match
- [ ] No credentials, keys, or account identifiers in the diff
- [ ] If a dbt test severity was lowered, the reasoning is in the PR body — not just the code

<!--
  That last one is deliberate. Downgrading a failing test to `warn` is the single
  easiest way to make CI green and the single easiest way to turn a test suite
  into decoration. It is sometimes correct. It should never be quiet.
-->

## Runbook impact

- [ ] No new failure mode.
- [ ] New failure mode — `runbooks/` updated.

<!--
  If this adds a task, a dependency, or a way for the pipeline to fail that did
  not exist before, the person on call at 03:00 needs to know what to do about
  it. They will not read this PR.
-->
