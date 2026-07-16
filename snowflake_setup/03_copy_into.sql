/* ============================================================================
   03_copy_into.sql — stage, file format, and the raw loads
   ----------------------------------------------------------------------------
   Run order: 01_rbac_roles.sql -> 02_schema_design.sql -> 03_copy_into.sql
   Run as:    LOADER (this is the role's entire job)

   Prerequisite: python data_generator/simulate.py  -> writes data/raw/*.csv
   ============================================================================ */

USE ROLE LOADER;
USE WAREHOUSE WH_LOADING;
USE DATABASE REVENUE_RAW;

/* ---------------------------------------------------------------------------
   File format

   EMPTY_FIELD_AS_NULL + NULL_IF: pandas writes an unquoted empty field for NaN.
   Both of the deliberate null injections (industry, employee_count) arrive this
   way, so getting this wrong turns 1,277 nulls into 1,277 empty strings and the
   not_null tests in M3 pass while meaning nothing.

   TRIM_SPACE is FALSE on purpose. Trimming is a transformation, and RAW does not
   transform — if a source pads a key with whitespace, that is a fact about the
   source and staging should be the layer that reveals it.
   --------------------------------------------------------------------------- */

CREATE FILE FORMAT IF NOT EXISTS REVENUE_RAW.BILLING.FF_CSV
    TYPE                         = CSV
    FIELD_DELIMITER              = ','
    SKIP_HEADER                  = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE                   = FALSE
    EMPTY_FIELD_AS_NULL          = TRUE
    NULL_IF                      = ('', 'NULL', 'null', 'NaN', 'nan')
    ESCAPE_UNENCLOSED_FIELD      = NONE
    ENCODING                     = 'UTF8'
    COMMENT = 'CSV as written by pandas.to_csv(index=False).';

/* ---------------------------------------------------------------------------
   Stage

   An internal named stage, not a user stage. Named stages are grantable objects
   — LOADER can be given exactly this stage — and they survive the user being
   dropped. A user stage (@~) is tied to whoever happened to upload, which makes
   the load path depend on an individual's account still existing.

   In a real deployment this is an external stage on S3/GCS with a storage
   integration, so no cloud credentials ever touch a SQL file. Internal is used
   here because the source is a local generator and adding a bucket would be
   ceremony without benefit. The COPY INTO statements below are identical either
   way — only the stage definition changes.
   --------------------------------------------------------------------------- */

CREATE STAGE IF NOT EXISTS REVENUE_RAW.BILLING.STG_LANDING
    FILE_FORMAT = REVENUE_RAW.BILLING.FF_CSV
    COMMENT = 'Landing stage for generator output.';

/* Upload from the client. PUT is SnowSQL/driver-side and cannot run in a
   worksheet, so this block is a shell step, not SQL:

     snowsql -a <account> -u SVC_AIRFLOW -r LOADER -w WH_LOADING \
       -q "PUT file://$(pwd)/data/raw/*.csv @REVENUE_RAW.BILLING.STG_LANDING
           AUTO_COMPRESS = TRUE OVERWRITE = TRUE;"

   AUTO_COMPRESS gzips client-side: 511K invoice rows go over the wire ~5x
   smaller, and Snowflake decompresses transparently. OVERWRITE makes re-running
   the load idempotent rather than accumulating _1, _2 copies of every file,
   which would silently double the row counts on the second run and break the
   reconciliation test for reasons that look like a dbt bug.

   Confirm before loading:
     LIST @REVENUE_RAW.BILLING.STG_LANDING;
   --------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   Loads

   TRUNCATE + COPY, i.e. full refresh. At 511K rows this takes seconds on an XS
   and it makes the load trivially idempotent: rerun it after a failure and the
   result is identical, with no partial-batch reasoning. Incremental loading here
   would be optimising the cheapest step in the pipeline while adding the one
   class of bug (did the watermark advance past a late arrival?) that this
   dataset is specifically built to expose — 7,569 invoice lines arrive 3-30 days
   after their event date. The trailing-window logic that handles them belongs in
   dbt, where it is testable, not in the load.

   ON_ERROR = ABORT_STATEMENT on every load. The temptation is CONTINUE ("don't
   let one bad row stop the pipeline"), but CONTINUE means a malformed file loads
   90% of its rows, the DAG goes green, and the row-count reconciliation test
   fails an hour later pointing at dbt. Failing loudly at the door is cheaper.
   Note this is not in tension with landing the injected defects: those are
   *well-formed CSV rows containing bad data*, which COPY has no opinion about.
   ABORT_STATEMENT catches malformed *files* — the wrong column count, a broken
   quote — which is a different failure and always operator error.

   FORCE = FALSE (the default) is left alone deliberately. Snowflake remembers
   loaded files for 64 days and skips them, which after the TRUNCATE above would
   be exactly wrong — it would leave the table empty. Hence OVERWRITE on the PUT:
   a re-uploaded file is a new file with a new checksum, so it loads again.
   --------------------------------------------------------------------------- */

-- Dry run first. VALIDATION_MODE parses without loading and returns the rows
-- that would fail. Cheap, and it turns "the 03:00 load exploded" into "the 03:00
-- load told us which file was malformed".
--   COPY INTO REVENUE_RAW.CRM.CUSTOMERS FROM @REVENUE_RAW.BILLING.STG_LANDING/customers.csv.gz
--       VALIDATION_MODE = 'RETURN_ERRORS';

TRUNCATE TABLE IF EXISTS REVENUE_RAW.CRM.CUSTOMERS;
COPY INTO REVENUE_RAW.CRM.CUSTOMERS
    (customer_id, company_name, country_code, currency_code, industry,
     employee_count, signup_date, account_manager_id, _source_file, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8,
           METADATA$FILENAME,
           CURRENT_TIMESTAMP()
    FROM @REVENUE_RAW.BILLING.STG_LANDING/customers.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = REVENUE_RAW.BILLING.FF_CSV)
ON_ERROR = ABORT_STATEMENT;

/* METADATA$FILENAME is carried on every table, not decoration. When the
   reconciliation test in M3 says staging is 40 rows short of raw, the first
   question is "which file?", and a lineage column answers it in one query
   instead of a re-load. _loaded_at is the load time, deliberately distinct from
   the source's own ingested_at — the gap between them is how you tell "the
   source was late" from "our pipeline was late", which are different incidents
   with different owners. */

TRUNCATE TABLE IF EXISTS REVENUE_RAW.CRM.EMPLOYEES;
COPY INTO REVENUE_RAW.CRM.EMPLOYEES
    (employee_id, manager_id, full_name, title, region, _source_file, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5, METADATA$FILENAME, CURRENT_TIMESTAMP()
    FROM @REVENUE_RAW.BILLING.STG_LANDING/employees.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = REVENUE_RAW.BILLING.FF_CSV)
ON_ERROR = ABORT_STATEMENT;

TRUNCATE TABLE IF EXISTS REVENUE_RAW.BILLING.PLANS;
COPY INTO REVENUE_RAW.BILLING.PLANS
    (plan_id, plan_name, tier, tier_rank, seat_price_usd, billing_interval,
     _source_file, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, METADATA$FILENAME, CURRENT_TIMESTAMP()
    FROM @REVENUE_RAW.BILLING.STG_LANDING/plans.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = REVENUE_RAW.BILLING.FF_CSV)
ON_ERROR = ABORT_STATEMENT;

TRUNCATE TABLE IF EXISTS REVENUE_RAW.BILLING.SUBSCRIPTIONS;
COPY INTO REVENUE_RAW.BILLING.SUBSCRIPTIONS
    (subscription_id, customer_id, plan_id, seats, started_at, ended_at,
     status, change_reason, _source_file, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, METADATA$FILENAME, CURRENT_TIMESTAMP()
    FROM @REVENUE_RAW.BILLING.STG_LANDING/subscriptions.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = REVENUE_RAW.BILLING.FF_CSV)
ON_ERROR = ABORT_STATEMENT;

-- The big one: 511,089 rows. Column order matches the generator's output.
TRUNCATE TABLE IF EXISTS REVENUE_RAW.BILLING.INVOICES;
COPY INTO REVENUE_RAW.BILLING.INVOICES
    (invoice_id, customer_id, subscription_id, period_start, period_end,
     issued_at, status, paid_at, payment_method, currency_code, source_system,
     ingested_at, line_type, amount_local, line_number, _source_file, _loaded_at)
FROM (
    SELECT $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15,
           METADATA$FILENAME, CURRENT_TIMESTAMP()
    FROM @REVENUE_RAW.BILLING.STG_LANDING/invoices.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = REVENUE_RAW.BILLING.FF_CSV)
ON_ERROR = ABORT_STATEMENT;

TRUNCATE TABLE IF EXISTS REVENUE_RAW.REFERENCE.FX_RATES;
COPY INTO REVENUE_RAW.REFERENCE.FX_RATES
    (rate_date, currency_code, rate_to_usd, _source_file, _loaded_at)
FROM (
    SELECT $1, $2, $3, METADATA$FILENAME, CURRENT_TIMESTAMP()
    FROM @REVENUE_RAW.BILLING.STG_LANDING/fx_rates.csv.gz
)
FILE_FORMAT = (FORMAT_NAME = REVENUE_RAW.BILLING.FF_CSV)
ON_ERROR = ABORT_STATEMENT;

/* ---------------------------------------------------------------------------
   Post-load verification

   Expected counts come from data/raw/_manifest.json (seed 42). This query is the
   raw side of the row-count reconciliation that becomes an automated dbt test in
   M3 — same numbers, same intent, run here by hand once so the load can be
   trusted before anything is built on it.
   --------------------------------------------------------------------------- */

SELECT 'customers'     AS table_name, COUNT(*) AS actual, 10000  AS expected FROM REVENUE_RAW.CRM.CUSTOMERS
UNION ALL SELECT 'employees',     COUNT(*), 123    FROM REVENUE_RAW.CRM.EMPLOYEES
UNION ALL SELECT 'plans',         COUNT(*), 8      FROM REVENUE_RAW.BILLING.PLANS
UNION ALL SELECT 'subscriptions', COUNT(*), 47552  FROM REVENUE_RAW.BILLING.SUBSCRIPTIONS
UNION ALL SELECT 'invoices',      COUNT(*), 511089 FROM REVENUE_RAW.BILLING.INVOICES
UNION ALL SELECT 'fx_rates',      COUNT(*), 5840   FROM REVENUE_RAW.REFERENCE.FX_RATES
ORDER BY table_name;

-- Load history, including rows COPY rejected. Empty error columns here plus
-- matching counts above is what "the load is good" actually means.
SELECT file_name, status, row_count, row_parsed, first_error_message
FROM   TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
           TABLE_NAME  => 'REVENUE_RAW.BILLING.INVOICES',
           START_TIME  => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
       ))
ORDER BY last_load_time DESC;

-- Confirm the injected defects survived the load. If these come back zero, the
-- load flattened the very problems the platform is built to catch, and every
-- test downstream would pass for the wrong reason.
SELECT
    COUNT(*)                                                   AS total_lines,
    COUNT(*) - COUNT(DISTINCT invoice_id || '-' || line_number) AS duplicate_lines,  -- expect 10011
    COUNT_IF(payment_method IS NULL)                            AS null_payment_method, -- expect 25822
    COUNT_IF(source_system = 'billing_sync_v2')                 AS tz_suspect_rows      -- expect 40965
FROM REVENUE_RAW.BILLING.INVOICES;
