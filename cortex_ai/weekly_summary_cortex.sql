/* ============================================================================
   Weekly executive summary via Snowflake Cortex
   ----------------------------------------------------------------------------
   Run as:  TRANSFORMER (writes REVENUE_ANALYTICS.AI)
   Reads:   FCT_REVENUE
   Writes:  REVENUE_ANALYTICS.AI.AI_INSIGHTS

   > NOT EXECUTED. No Snowflake account is attached to this repo, so no output of
   > this query has ever been generated. Nothing below is a sample of real model
   > output, and there is deliberately no "example summary" — a hand-written
   > paragraph presented as an LLM's output would be the most misleading thing in
   > this repository.

   The idea: every Monday, turn the week's metric movements into a paragraph a CFO
   can read, and store it as a governed table row rather than a Slack message.

   The reason it is worth doing *in* the warehouse is not the LLM. It is that the
   output lands in a table with a foreign key to the data it describes, a model
   name, and a timestamp — so six months later, when someone asks why the summary
   said what it said, the answer is a query rather than an archaeology project.
   ============================================================================ */

USE ROLE TRANSFORMER;
USE WAREHOUSE WH_TRANSFORMING;
USE SCHEMA REVENUE_ANALYTICS.AI;

/* ---------------------------------------------------------------------------
   The output table.

   Structured on purpose. The temptation is one TEXT column holding the summary;
   the reason not to is that an LLM's output is a *derived artifact* and deserves
   the same treatment as any other model output — you need to know which inputs
   produced it, which model version, under which prompt, and what it cost.

   Without model_name and prompt_version, the day the model is upgraded every
   historical summary becomes unattributable, and the question "did the tone
   change or did the business change?" has no answer.
   --------------------------------------------------------------------------- */

CREATE TABLE IF NOT EXISTS AI_INSIGHTS (
    insight_id          VARCHAR(64)     NOT NULL,
    period_start        DATE            NOT NULL,
    period_end          DATE            NOT NULL,
    insight_type        VARCHAR(50)     NOT NULL,

    -- The generated text.
    summary_text        VARCHAR(16777216),

    -- Provenance. This is the half that makes it governed rather than generated.
    model_name          VARCHAR(100)    NOT NULL,
    prompt_version      VARCHAR(20)     NOT NULL,
    prompt_text         VARCHAR(16777216),
    input_context       VARCHAR(16777216),
    -- input_context stores the exact string the model saw. It is verbose and it is
    -- the single most useful column here: when a summary says something surprising,
    -- the first question is always "what was it actually looking at?" Without this,
    -- reproducing an answer means rebuilding the context from a mart that has since
    -- been rebuilt, and you cannot.

    -- The numbers the text is about, kept alongside it. If the prose and these
    -- disagree, the prose is wrong — and disagreement is detectable rather than a
    -- matter of opinion. This is what the validation query at the foot checks.
    context_metrics     VARIANT,

    generated_at        TIMESTAMP_NTZ   NOT NULL,
    generated_by_role   VARCHAR(50),
    input_tokens        NUMBER(10, 0),
    output_tokens       NUMBER(10, 0),

    -- Human review state. An LLM summary that goes to a CFO unreviewed is a
    -- generated claim about a company's finances with nobody's name on it.
    -- Defaulting to 'unreviewed' rather than NULL means "nobody has looked at
    -- this" is an explicit state, not an absence.
    review_status       VARCHAR(20)     DEFAULT 'unreviewed',
    reviewed_by         VARCHAR(100),
    reviewed_at         TIMESTAMP_NTZ,

    CONSTRAINT pk_ai_insights PRIMARY KEY (insight_id)
);

/* ---------------------------------------------------------------------------
   1. Aggregate the week's movements into a context string.

   The design decision that matters is here, not in the prompt: the model is given
   pre-computed numbers, never raw rows.

   Handing an LLM 500K invoice lines and asking it to total them is asking a text
   generator to do arithmetic it cannot do reliably, and it will produce a
   confident, plausible, wrong number. SQL computes the metrics; the model gets
   them as facts and is asked only to explain them. Every number in the output is
   therefore traceable to a query, and the LLM's job is reduced to the thing it is
   actually good at: prose.
   --------------------------------------------------------------------------- */

CREATE OR REPLACE TEMPORARY TABLE _weekly_context AS
WITH latest_months AS (

    SELECT
        date_key,
        SUM(mrr_usd)                                            AS closing_mrr,
        SUM(arr_usd)                                            AS closing_arr,
        SUM(new_mrr_usd)                                        AS new_mrr,
        SUM(expansion_mrr_usd)                                  AS expansion_mrr,
        SUM(contraction_mrr_usd)                                AS contraction_mrr,
        SUM(churned_mrr_usd)                                    AS churned_mrr,
        SUM(reactivation_mrr_usd)                               AS reactivation_mrr,
        SUM(recognized_revenue_usd)                             AS recognized_revenue,
        COUNT_IF(is_active)                                     AS active_customers,
        COUNT_IF(movement_type = 'new')                         AS new_customers,
        COUNT_IF(movement_type = 'churn')                       AS churned_customers
    FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE
    GROUP BY date_key

),

with_deltas AS (

    SELECT
        *,
        LAG(closing_mrr) OVER (ORDER BY date_key)               AS prior_mrr,
        LAG(active_customers) OVER (ORDER BY date_key)          AS prior_active_customers,
        ROUND(100.0 * (closing_mrr - LAG(closing_mrr) OVER (ORDER BY date_key))
              / NULLIF(LAG(closing_mrr) OVER (ORDER BY date_key), 0), 1)
                                                                AS mrr_change_pct
    FROM latest_months

),

current_period AS (
    SELECT * FROM with_deltas
    QUALIFY ROW_NUMBER() OVER (ORDER BY date_key DESC) = 1
),

top_movers AS (

    SELECT
        LISTAGG(
            c.company_name || ' (' || f.movement_type || ', '
            || TO_CHAR(ROUND(f.mrr_delta_usd, 0)) || ' USD)',
            '; '
        ) WITHIN GROUP (ORDER BY ABS(f.mrr_delta_usd) DESC)     AS movers_text
    FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE        AS f
    INNER JOIN REVENUE_ANALYTICS.MARTS.DIM_CUSTOMER AS c
        ON f.customer_key = c.customer_key
    WHERE f.date_key = (SELECT date_key FROM current_period)
      AND f.movement_type IN ('expansion', 'contraction', 'churn', 'new')
    QUALIFY ROW_NUMBER() OVER (ORDER BY ABS(f.mrr_delta_usd) DESC) <= 5

),

segment_breakdown AS (

    SELECT
        LISTAGG(
            seg.size_band || ': ' || TO_CHAR(ROUND(seg.segment_mrr, 0)) || ' USD MRR ('
            || TO_CHAR(seg.segment_customers) || ' customers)',
            '; '
        ) WITHIN GROUP (ORDER BY seg.segment_mrr DESC)          AS segments_text
    FROM (
        SELECT
            c.size_band,
            SUM(f.mrr_usd)          AS segment_mrr,
            COUNT_IF(f.is_active)   AS segment_customers
        FROM REVENUE_ANALYTICS.MARTS.FCT_REVENUE        AS f
        INNER JOIN REVENUE_ANALYTICS.MARTS.DIM_CUSTOMER AS c
            ON f.customer_key = c.customer_key
        WHERE f.date_key = (SELECT date_key FROM current_period)
        GROUP BY c.size_band
    ) AS seg

)

SELECT
    current_period.date_key                                     AS period_start,
    LAST_DAY(current_period.date_key)                           AS period_end,

    /* The context string. Deliberately terse, labelled, and numeric.

       Not prose, and not JSON. Prose invites the model to re-narrate what it was
       told rather than analyse it. JSON works but spends tokens on syntax the
       model must parse before it can read a number. Labelled key-value lines are
       what these models handle most reliably, and every line is a fact the model
       is told to treat as given. */
    'PERIOD: ' || TO_CHAR(current_period.date_key, 'YYYY-MM') || CHR(10)
    || 'CLOSING MRR: ' || TO_CHAR(ROUND(current_period.closing_mrr, 0)) || ' USD' || CHR(10)
    || 'PRIOR MRR: ' || TO_CHAR(ROUND(COALESCE(current_period.prior_mrr, 0), 0)) || ' USD' || CHR(10)
    || 'MRR CHANGE: ' || TO_CHAR(COALESCE(current_period.mrr_change_pct, 0)) || '%' || CHR(10)
    || 'CLOSING ARR: ' || TO_CHAR(ROUND(current_period.closing_arr, 0)) || ' USD' || CHR(10)
    || 'NEW MRR: ' || TO_CHAR(ROUND(current_period.new_mrr, 0)) || ' USD from '
                   || TO_CHAR(current_period.new_customers) || ' new customers' || CHR(10)
    || 'EXPANSION MRR: ' || TO_CHAR(ROUND(current_period.expansion_mrr, 0)) || ' USD' || CHR(10)
    || 'REACTIVATION MRR: ' || TO_CHAR(ROUND(current_period.reactivation_mrr, 0)) || ' USD' || CHR(10)
    || 'CONTRACTION MRR: ' || TO_CHAR(ROUND(current_period.contraction_mrr, 0)) || ' USD' || CHR(10)
    || 'CHURNED MRR: ' || TO_CHAR(ROUND(current_period.churned_mrr, 0)) || ' USD from '
                       || TO_CHAR(current_period.churned_customers) || ' customers' || CHR(10)
    || 'ACTIVE CUSTOMERS: ' || TO_CHAR(current_period.active_customers)
                            || ' (prior: ' || TO_CHAR(COALESCE(current_period.prior_active_customers, 0)) || ')' || CHR(10)
    || 'RECOGNIZED REVENUE: ' || TO_CHAR(ROUND(current_period.recognized_revenue, 0)) || ' USD' || CHR(10)
    || 'NET REVENUE RETENTION: ' || TO_CHAR(ROUND(
           100.0 * (COALESCE(current_period.prior_mrr, 0) + current_period.expansion_mrr
                    + current_period.contraction_mrr + current_period.churned_mrr)
           / NULLIF(current_period.prior_mrr, 0), 1)) || '%' || CHR(10)
    || 'TOP MOVERS: ' || COALESCE(top_movers.movers_text, 'none') || CHR(10)
    || 'BY SEGMENT: ' || COALESCE(segment_breakdown.segments_text, 'none')
                                                                AS context_text,

    /* The same numbers as structured data, stored beside the prose. This is what
       makes the summary checkable: the validation query at the foot of this file
       compares what the model wrote against these, and a mismatch is a fact, not
       a debate. */
    OBJECT_CONSTRUCT(
        'closing_mrr', ROUND(current_period.closing_mrr, 0),
        'prior_mrr', ROUND(COALESCE(current_period.prior_mrr, 0), 0),
        'mrr_change_pct', COALESCE(current_period.mrr_change_pct, 0),
        'closing_arr', ROUND(current_period.closing_arr, 0),
        'new_mrr', ROUND(current_period.new_mrr, 0),
        'expansion_mrr', ROUND(current_period.expansion_mrr, 0),
        'contraction_mrr', ROUND(current_period.contraction_mrr, 0),
        'churned_mrr', ROUND(current_period.churned_mrr, 0),
        'active_customers', current_period.active_customers,
        'new_customers', current_period.new_customers,
        'churned_customers', current_period.churned_customers
    )                                                           AS context_metrics

FROM current_period
CROSS JOIN top_movers
CROSS JOIN segment_breakdown;


/* ---------------------------------------------------------------------------
   2. Call the model and insert the result.

   COMPLETE() takes (model, prompt). The prompt below is versioned as a literal in
   this file rather than built dynamically, because a prompt is code: it changes
   behaviour, it belongs in review, and it needs a diff. prompt_version is bumped
   by hand when the text changes, and the old version stays attached to the rows
   it produced.
   --------------------------------------------------------------------------- */

INSERT INTO AI_INSIGHTS (
    insight_id, period_start, period_end, insight_type,
    summary_text, model_name, prompt_version, prompt_text,
    input_context, context_metrics,
    generated_at, generated_by_role, review_status
)
SELECT
    MD5(TO_CHAR(period_start) || '|weekly_exec_summary|v1.2.0')  AS insight_id,
    period_start,
    period_end,
    'weekly_exec_summary'                                       AS insight_type,

    SNOWFLAKE.CORTEX.COMPLETE(
        'llama3.1-70b',
        /* Model choice is a cost decision as much as a quality one. This task is
           constrained summarisation of ~15 pre-computed numbers into three fixed
           sections — it does not need frontier reasoning. A larger model would
           cost several times as much per call to write the same paragraph.
           mistral-large2 is the upgrade if output quality disappoints; llama3.1-8b
           is the downgrade if this proves over-specified. That is an experiment to
           run against real output, not a decision to make from a README. */

        'You are a financial analyst writing for a SaaS CFO.

Below are this period''s revenue metrics, already computed from the governed
warehouse. Treat every number as authoritative and final.

RULES:
- Use ONLY the numbers provided. Do not compute, estimate, or infer any figure
  that is not listed below.
- If something is not in the data, do not mention it. Do not speculate about
  causes, market conditions, or competitors — you cannot see any of that.
- Do not soften or dramatise. State what moved and by how much.
- Every number you write must appear verbatim in the data below.
- If the data does not support a Risk or an Action, write "None identified."
  An empty section is correct and expected; inventing one to fill the template
  is not.

Respond in EXACTLY this structure, nothing before or after:

HIGHLIGHTS
- (2-3 bullets: what moved most, with the figures)

RISKS
- (1-3 bullets: concerning movements, with the figures. "None identified." if none.)

ACTIONS
- (1-3 bullets: what a CFO should ask about next. "None identified." if none.)

DATA:
' || context_text
    )                                                           AS summary_text,

    'llama3.1-70b'                                              AS model_name,
    'v1.2.0'                                                    AS prompt_version,
    'weekly_exec_summary/v1.2.0 — see cortex_ai/weekly_summary_cortex.sql'
                                                                AS prompt_text,
    context_text                                                AS input_context,
    context_metrics,
    CURRENT_TIMESTAMP()                                         AS generated_at,
    CURRENT_ROLE()                                              AS generated_by_role,
    'unreviewed'                                                AS review_status

FROM _weekly_context

WHERE NOT EXISTS (
    SELECT 1 FROM AI_INSIGHTS AS existing
    WHERE existing.insight_id = MD5(TO_CHAR(_weekly_context.period_start) || '|weekly_exec_summary|v1.2.0')
);

/* The NOT EXISTS makes this idempotent, and idempotency matters more here than
   almost anywhere else in the pipeline. Every other task in the DAG is free to
   retry — re-running a dbt model costs warehouse seconds. Re-running this costs a
   token bill *and* produces a different paragraph, because the model is
   non-deterministic. A retried task would silently give you two different official
   summaries of the same week, with no way to tell which one the CFO read.

   The key includes prompt_version, so changing the prompt intentionally generates
   a new row rather than being suppressed as a duplicate — the two summaries then
   sit side by side and can be compared, which is the only honest way to evaluate a
   prompt change. */


/* ---------------------------------------------------------------------------
   3. Validate the output before anyone reads it.

   An LLM summary is untrusted input until checked, and it is untrusted in a
   specific way: the failure mode is not gibberish, it is a fluent paragraph
   containing a number that was never in the data. Nobody reading it would notice.

   These checks are cheap and mechanical. They do not verify the *analysis* — no
   automated check can — which is why review_status exists and defaults to
   'unreviewed'.
   --------------------------------------------------------------------------- */

SELECT
    insight_id,
    period_start,
    model_name,
    prompt_version,

    -- Structure: did it follow the template? A missing section means the model
    -- ignored the format, and anything downstream that parses sections will
    -- silently get nothing.
    summary_text ILIKE '%HIGHLIGHTS%'                           AS has_highlights,
    summary_text ILIKE '%RISKS%'                                AS has_risks,
    summary_text ILIKE '%ACTIONS%'                              AS has_actions,

    -- Grounding: does the headline figure it was given actually appear in the
    -- prose? This is the check that catches the dangerous failure — a confident
    -- paragraph quoting an MRR that does not exist. It is necessary, not
    -- sufficient: it cannot catch a number that is wrong in a sentence that also
    -- happens to contain the right one.
    summary_text LIKE '%' || context_metrics:closing_mrr::VARCHAR || '%'
                                                                AS quotes_closing_mrr,

    -- Length: a 50-character summary means the call failed or returned a refusal;
    -- a 4,000-character one means it ignored the structure and wrote an essay.
    LENGTH(summary_text)                                        AS summary_length,

    review_status,
    generated_at

FROM AI_INSIGHTS
WHERE insight_type = 'weekly_exec_summary'
ORDER BY period_start DESC
LIMIT 10;


/* ---------------------------------------------------------------------------
   4. Cost.

   Run before turning this on weekly, not after the first invoice.
   --------------------------------------------------------------------------- */

SELECT
    function_name,
    model_name,
    SUM(token_credits)                                          AS total_credits,
    SUM(tokens)                                                 AS total_tokens,
    COUNT(*)                                                    AS calls
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_USAGE_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY function_name, model_name
ORDER BY total_credits DESC;
