# Cortex AI — governed LLM summaries

> **Not executed.** No Snowflake account is attached to this repo, so
> `weekly_summary_cortex.sql` has never run and no model output exists. There is
> deliberately **no example summary** below: a paragraph I wrote by hand, presented
> as an LLM's output, would be the most misleading thing in this repository — it
> would look like evidence and be fiction. Run it against a trial account and the
> output lands in `AI_INSIGHTS` with its provenance attached.
>
> Cost figures below are marked as unmeasured. Snowflake publishes credit rates per
> model; the actual bill depends on token counts this workload has never generated.

## What it does

Every period, turn the metric movements into a paragraph a CFO can read, and store
it as a **table row with provenance** rather than a Slack message that scrolls away.

```
fct_revenue → SQL aggregates the numbers → context string → CORTEX.COMPLETE()
            → AI_INSIGHTS (text + model + prompt version + input context + metrics)
```

## The design decision that matters

**The model never sees a row of data. It only sees numbers SQL already computed.**

Handing an LLM 511K invoice lines and asking it to total them is asking a text
generator to do arithmetic. It will produce a confident, plausible, wrong number,
and the wrongness will be invisible because the sentence around it reads perfectly.
So: SQL computes every metric; the model is told to treat them as authoritative and
is asked only to write prose.

This reduces the LLM's job to the one thing it is reliably good at, and it means
every number in the output is traceable to a query. The prompt says so explicitly —
*"Use ONLY the numbers provided. Do not compute, estimate, or infer any figure that
is not listed below."*

## Why it's a table, not a message

`AI_INSIGHTS` stores the summary alongside `model_name`, `prompt_version`,
`input_context` (the exact string the model saw), and `context_metrics` (the same
numbers as structured data).

That last pair is what makes the output checkable. If the prose and
`context_metrics` disagree, **the prose is wrong** — and disagreement is detectable
rather than a matter of opinion. The validation query at the foot of the file
asserts the headline MRR figure it was given actually appears in the text it wrote.

`input_context` looks verbose and is the most useful column there: when a summary
says something surprising, the first question is always "what was it looking at?"
Without it, reproducing an answer means rebuilding the context from a mart that has
since been rebuilt — which you cannot do.

`review_status` defaults to `'unreviewed'` rather than NULL, because "nobody has
looked at this" should be an explicit state. An LLM summary that reaches a CFO
unreviewed is a generated claim about a company's finances with nobody's name on it.

## Idempotency matters more here than anywhere else in the pipeline

The insert is guarded by `NOT EXISTS` on `MD5(period | type | prompt_version)`.

Every other task in the DAG is free to retry — re-running a dbt model costs
warehouse seconds and produces the identical table. Re-running this costs a token
bill **and produces a different paragraph**, because the model is non-deterministic.
A retried task would silently leave two different official summaries of the same
week, with no way to know which one the CFO read.

The key includes `prompt_version`, so changing the prompt *intentionally* writes a
new row rather than being suppressed as a duplicate. The two then sit side by side
and can be compared — the only honest way to evaluate a prompt change.

## Cortex vs. an external LLM API

The comparison the PRD asks for. Cortex is the right call **for this specific
workload**, and the reasons are mostly not about the model.

### Governance — the actual argument

| | Cortex | External API (OpenAI/Anthropic/etc.) |
|---|---|---|
| Data leaves the account | **No** | Yes — over the internet, to a third party |
| Access control | Existing Snowflake RBAC (`TRANSFORMER` runs it, `REPORTER` reads the output) | A separate API key, a separate permission model, its own rotation story |
| Audit trail | `CORTEX_FUNCTIONS_USAGE_HISTORY` + `ACCESS_HISTORY`, same as any query | Whatever you build |
| New vendor review | None — already an approved processor | A DPA, a security review, a procurement cycle |
| Egress | None | Customer names and revenue figures crossing a network boundary |

The egress row is the one that decides it. This context string contains **customer
company names next to their MRR**. Sending that to a third party is a data-processing
decision that needs a contract and a review — not something a data engineer enables
by adding a secret. Cortex keeps it inside the compliance boundary that already
exists, which turns a months-long approval into a `GRANT`.

### Latency

Cortex runs next to the data — no network hop, no context assembly round trip. But
this is a **weekly batch job**. If it took thirty seconds it would not matter. Anyone
citing latency as the reason to choose Cortex here is reaching for a benefit the
workload cannot use; the honest version is that latency is irrelevant to this
decision and would only matter if the summary were generated on dashboard load.

### Cost

_Unmeasured._ Cortex bills credits per token by model, on the existing Snowflake
contract — one bill, one budget, and the resource monitor from
`01_rbac_roles.sql` applies. An external API is a separate invoice with a separate
card and no relationship to the warehouse budget.

Whether Cortex is *cheaper per token* than a comparable external model is not claimed
here, because it was not measured. What is structurally true is that it is cheaper
*to govern*: no second budget to reconcile, no second key to rotate.

To measure, run the file for a month and then:

```sql
SELECT model_name, SUM(token_credits) AS credits, SUM(tokens) AS tokens, COUNT(*) AS calls
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY model_name;
```

| Metric | Value |
|---|---|
| Credits / 30d | _TODO — run the query above_ |
| Cost per summary | _TODO_ |
| Median latency | _TODO_ |

### Where Cortex loses

Stated because a comparison that only lists advantages is marketing:

- **Model choice is Snowflake's.** You get the models Cortex hosts in your region,
  at the versions Snowflake ships. If the best model for a task is not on that list,
  it is not available — and you cannot pin a version the way you can against an API.
- **No streaming.** Fine for batch; wrong for anything user-facing.
- **Region availability varies**, so a multi-region deployment can find the function
  missing in one of them.
- **Weaker tooling.** No function calling, no structured-output mode — which is why
  the prompt here specifies a text template and the validation query greps for
  section headers. An external API with a JSON schema would make that check exact
  instead of `ILIKE '%RISKS%'`.

**If this workload were an interactive assistant** — streaming, tool use, strict JSON
— the balance would flip and an external API would win despite the governance cost.
It is a weekly batch summary of numbers that never leave the warehouse. That is the
case Cortex is actually built for.

### Model choice

`llama3.1-70b`. The task is constrained summarisation of ~15 pre-computed numbers
into three fixed sections — it does not need frontier reasoning, and a larger model
would cost several times as much to write the same paragraph. `mistral-large2` is the
upgrade if quality disappoints; `llama3.1-8b` is the downgrade if this proves
over-specified. **That is an experiment to run against real output, not a decision to
make from a README.**

## How to run it

```sql
-- 1. Confirm Cortex is available in your region
SELECT SNOWFLAKE.CORTEX.COMPLETE('llama3.1-70b', 'Reply with the single word: ok');

-- 2. Grant usage (Cortex functions need an explicit grant)
USE ROLE ACCOUNTADMIN;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE TRANSFORMER;

-- 3. Run it
USE ROLE TRANSFORMER;
-- ...then execute cortex_ai/weekly_summary_cortex.sql
```

Then read the validation query's output **before** reading the summary. If
`quotes_closing_mrr` is false, the model wrote a number it was not given, and the
paragraph is fiction regardless of how well it reads.
