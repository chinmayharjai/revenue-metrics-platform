/* ============================================================================
   01_rbac_roles.sql — role hierarchy and warehouses
   ----------------------------------------------------------------------------
   Run order: 01_rbac_roles.sql -> 02_schema_design.sql -> 03_copy_into.sql
   Run as:    USERADMIN for role creation, SYSADMIN for warehouses (noted inline)

   This file builds the *skeleton*: roles, the grants between them, and the
   warehouses. It deliberately does not grant anything on databases — those
   objects do not exist yet, and object grants live next to the objects they
   describe in 02_schema_design.sql. Splitting it this way means you can read
   "who can exist" separately from "who can touch what".

   ---------------------------------------------------------------------------
   The design: two tiers, access roles and functional roles.

   Access roles own privileges on objects  (RAW_READ can SELECT from RAW).
   Functional roles own job descriptions   (TRANSFORMER is what dbt runs as).
   Functional roles are granted access roles; users are granted functional roles.

   Why bother, when three roles could hold the grants directly? Because the
   privilege set and the job description change for different reasons and at
   different times. Adding a database means touching access roles only. Hiring
   an analyst means touching functional roles only. Collapse the tiers and every
   new database re-opens the question of who should see it, in three places at
   once. This is the standard Snowflake pattern and it is the one thing here
   that stops being optional the moment a second person joins.
   ============================================================================ */

USE ROLE USERADMIN;

/* ---------------------------------------------------------------------------
   Access roles — one per (database, access level).
   Named <DB>_<LEVEL> so a grant audit reads like English.
   --------------------------------------------------------------------------- */

CREATE ROLE IF NOT EXISTS RAW_READ
    COMMENT = 'SELECT on REVENUE_RAW. Held by TRANSFORMER.';
CREATE ROLE IF NOT EXISTS RAW_WRITE
    COMMENT = 'Load into REVENUE_RAW. Held by LOADER only.';

CREATE ROLE IF NOT EXISTS STAGING_READ
    COMMENT = 'SELECT on REVENUE_STAGING. Held by TRANSFORMER.';
CREATE ROLE IF NOT EXISTS STAGING_WRITE
    COMMENT = 'Create/modify in REVENUE_STAGING. Held by TRANSFORMER.';

CREATE ROLE IF NOT EXISTS ANALYTICS_READ
    COMMENT = 'SELECT on REVENUE_ANALYTICS marts. Held by REPORTER and TRANSFORMER.';
CREATE ROLE IF NOT EXISTS ANALYTICS_WRITE
    COMMENT = 'Create/modify marts in REVENUE_ANALYTICS. Held by TRANSFORMER.';

/* ---------------------------------------------------------------------------
   Functional roles — the three jobs this platform actually has.
   --------------------------------------------------------------------------- */

CREATE ROLE IF NOT EXISTS LOADER
    COMMENT = 'Ingestion only. Airflow extract/load tasks authenticate as this.';
CREATE ROLE IF NOT EXISTS TRANSFORMER
    COMMENT = 'dbt runs as this, in both prod and CI.';
CREATE ROLE IF NOT EXISTS REPORTER
    COMMENT = 'Power BI service principal and human analysts.';

/* ---------------------------------------------------------------------------
   Wire access roles into functional roles.

   Each grant below is a decision, so each gets a reason.
   --------------------------------------------------------------------------- */

-- LOADER writes RAW and nothing else.
-- Explicitly NOT granted RAW_READ: a loader that cannot read back what it wrote
-- cannot be repurposed into an exfiltration path if its key leaks, and nothing
-- in the load path needs to read — COPY INTO reports its own results.
GRANT ROLE RAW_WRITE TO ROLE LOADER;

-- TRANSFORMER reads RAW and owns everything downstream of it.
-- Explicitly NOT granted RAW_WRITE: dbt must never be able to alter its own
-- source of truth. If a model could write back to RAW, the reconciliation test
-- in M3 (raw row count vs staging row count) would be checking dbt against
-- itself and would be worth nothing.
GRANT ROLE RAW_READ       TO ROLE TRANSFORMER;
GRANT ROLE STAGING_READ   TO ROLE TRANSFORMER;
GRANT ROLE STAGING_WRITE  TO ROLE TRANSFORMER;
GRANT ROLE ANALYTICS_READ TO ROLE TRANSFORMER;
GRANT ROLE ANALYTICS_WRITE TO ROLE TRANSFORMER;

-- REPORTER reads the marts. That is the entire grant.
-- Explicitly NOT granted STAGING_READ or RAW_READ. This is the grant that makes
-- the "single source of truth" claim real rather than aspirational: if analysts
-- can reach staging, someone eventually builds a dashboard on an intermediate
-- model, and then there are two ARR numbers again — which is the exact problem
-- this platform exists to solve. The restriction is the product.
GRANT ROLE ANALYTICS_READ TO ROLE REPORTER;

-- Roll functional roles up to SYSADMIN so it retains visibility of everything
-- built beneath it. Without this, SYSADMIN cannot manage objects these roles
-- create, and you end up doing routine admin as ACCOUNTADMIN — which is how
-- accounts drift into having ten ACCOUNTADMIN users.
GRANT ROLE LOADER      TO ROLE SYSADMIN;
GRANT ROLE TRANSFORMER TO ROLE SYSADMIN;
GRANT ROLE REPORTER    TO ROLE SYSADMIN;

/* ---------------------------------------------------------------------------
   Warehouses — one per function, not one per team.

   Separate warehouses are how you get per-function cost attribution and stop a
   backfill from queueing behind a dashboard refresh. All XS: this workload is
   500K rows, and reaching for a bigger warehouse to fix a slow query is the
   expensive way to avoid reading the query profile. The clustering work in M4
   makes that argument concretely.

   AUTO_SUSPEND is aggressive (60s) because Snowflake bills per second with a
   60s minimum per resume — for a spiky ELT workload, idle time is pure waste.
   The reporting warehouse suspends slower (300s): BI users fire bursts of small
   queries, and resuming per click both feels bad and bills a fresh minimum each
   time.
   --------------------------------------------------------------------------- */

USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS WH_LOADING WITH
    WAREHOUSE_SIZE       = 'XSMALL'
    AUTO_SUSPEND         = 60
    AUTO_RESUME          = TRUE
    INITIALLY_SUSPENDED  = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 1800
    COMMENT = 'COPY INTO only. Sized XS: loading 500K rows is I/O-bound, not compute-bound.';

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORMING WITH
    WAREHOUSE_SIZE       = 'XSMALL'
    AUTO_SUSPEND         = 60
    AUTO_RESUME          = TRUE
    INITIALLY_SUSPENDED  = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 3600
    COMMENT = 'dbt run/test. Longer timeout than loading: a full refresh legitimately takes minutes.';

CREATE WAREHOUSE IF NOT EXISTS WH_REPORTING WITH
    WAREHOUSE_SIZE       = 'XSMALL'
    AUTO_SUSPEND         = 300
    AUTO_RESUME          = TRUE
    INITIALLY_SUSPENDED  = TRUE
    STATEMENT_TIMEOUT_IN_SECONDS = 600
    COMMENT = 'Power BI + ad hoc. Short timeout: a 10-minute dashboard query is a bug, not a wait.';

-- USAGE lets a role run queries on the warehouse. OPERATE additionally lets it
-- resume/suspend. LOADER and TRANSFORMER get OPERATE because they run from
-- Airflow, which needs to resume a suspended warehouse at 03:00 unattended.
GRANT USAGE, OPERATE ON WAREHOUSE WH_LOADING      TO ROLE LOADER;
GRANT USAGE, OPERATE ON WAREHOUSE WH_TRANSFORMING TO ROLE TRANSFORMER;

-- REPORTER gets USAGE but NOT OPERATE. AUTO_RESUME already covers the only
-- legitimate need (a dashboard waking a suspended warehouse). Withholding
-- OPERATE means no analyst can suspend the warehouse other people are using,
-- and — more to the point — nobody can ALTER it to a 4XL to make their query
-- faster. Cost control belongs in the grant, not in a Slack reminder.
GRANT USAGE ON WAREHOUSE WH_REPORTING TO ROLE REPORTER;

/* ---------------------------------------------------------------------------
   Resource monitor — a hard credit ceiling.

   Requires ACCOUNTADMIN. Set first, not last: the trial account has a fixed
   credit budget and an accidental cross join on a 500K-row table at 4XL will
   find the end of it. NOTIFY at 75/90 gives warning; SUSPEND at 100 stops new
   queries; SUSPEND_IMMEDIATE at 110 kills running ones. The 10% gap between the
   last two is deliberate — it lets an in-flight dbt run finish and leave the
   warehouse consistent rather than half-built.
   --------------------------------------------------------------------------- */

USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS RM_REVENUE_PLATFORM WITH
    CREDIT_QUOTA = 50
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75  PERCENT DO NOTIFY
        ON 90  PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND
        ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE WH_LOADING      SET RESOURCE_MONITOR = RM_REVENUE_PLATFORM;
ALTER WAREHOUSE WH_TRANSFORMING SET RESOURCE_MONITOR = RM_REVENUE_PLATFORM;
ALTER WAREHOUSE WH_REPORTING    SET RESOURCE_MONITOR = RM_REVENUE_PLATFORM;

/* ---------------------------------------------------------------------------
   Users. Passwords/keys are NOT in this file and must not be.

   Create these by hand or via Terraform with secrets from a manager, then grant
   the functional role. Key-pair auth is used rather than passwords because both
   are unattended service accounts — a password on a service account is a
   password that gets pasted into a CI log eventually.

     CREATE USER SVC_AIRFLOW  DEFAULT_ROLE = LOADER      DEFAULT_WAREHOUSE = WH_LOADING
         RSA_PUBLIC_KEY = '<from secrets manager>';
     CREATE USER SVC_DBT      DEFAULT_ROLE = TRANSFORMER DEFAULT_WAREHOUSE = WH_TRANSFORMING
         RSA_PUBLIC_KEY = '<from secrets manager>';
     CREATE USER SVC_POWERBI  DEFAULT_ROLE = REPORTER    DEFAULT_WAREHOUSE = WH_REPORTING
         RSA_PUBLIC_KEY = '<from secrets manager>';

     GRANT ROLE LOADER      TO USER SVC_AIRFLOW;
     GRANT ROLE TRANSFORMER TO USER SVC_DBT;
     GRANT ROLE REPORTER    TO USER SVC_POWERBI;
   --------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
   Verification — run these and read the output; do not assume the grants landed.

     SHOW GRANTS TO ROLE REPORTER;     -- expect ANALYTICS_READ + WH_REPORTING usage, nothing more
     SHOW GRANTS TO ROLE LOADER;       -- expect RAW_WRITE only; no RAW_READ
     SHOW GRANTS TO ROLE TRANSFORMER;  -- expect RAW_READ but NOT RAW_WRITE

   The negative expectations are the point. A role having what it needs is easy;
   proving it lacks what it should not have is the part an auditor asks for.
   --------------------------------------------------------------------------- */
