/* ============================================================================
   02_schema_design.sql — databases, schemas, raw tables, and object grants
   ----------------------------------------------------------------------------
   Run order: 01_rbac_roles.sql -> 02_schema_design.sql -> 03_copy_into.sql
   Run as:    SYSADMIN (object creation), SECURITYADMIN (grants — noted inline)

   Three databases, one per layer, rather than one database with three schemas.

   The trade is real and worth stating. One database is simpler and lets you
   join across layers without fully-qualifying everything. Three databases cost
   a little ceremony and buy two things this project needs:

     1. A blast radius. DROP DATABASE REVENUE_STAGING cannot take the marts with
        it. With one database, one bad `DROP SCHEMA` in the wrong session does.
     2. A grant boundary that is hard to fumble. REPORTER is granted usage on
        REVENUE_ANALYTICS and is simply not wired to the others — there is no
        schema-level exception to forget. Compare the one-database version,
        where every new schema starts life visible to a role holding a
        database-level grant unless someone remembers otherwise.

   The clone story also gets cheaper: CREATE DATABASE ... CLONE gives CI a
   zero-copy full-layer environment in seconds (used in M6).
   ============================================================================ */

USE ROLE SYSADMIN;

/* ---------------------------------------------------------------------------
   Databases
   --------------------------------------------------------------------------- */

CREATE DATABASE IF NOT EXISTS REVENUE_RAW
    DATA_RETENTION_TIME_IN_DAYS = 7
    COMMENT = 'Landing zone. Source fidelity preserved, defects included. Never edited in place.';

CREATE DATABASE IF NOT EXISTS REVENUE_STAGING
    DATA_RETENTION_TIME_IN_DAYS = 1
    COMMENT = 'dbt staging + intermediate. Fully rebuildable from RAW, so retention is minimal.';

CREATE DATABASE IF NOT EXISTS REVENUE_ANALYTICS
    DATA_RETENTION_TIME_IN_DAYS = 30
    COMMENT = 'Marts. The published contract. Longest retention — this is what people cite.';

/* Retention is set per layer on purpose, because Time Travel is billed storage
   and the layers differ in what a mistake costs:
     RAW       7d  — the CSVs can be re-extracted, but re-landing 24 months of
                     history is an afternoon. A week of undo is worth the storage.
     STAGING   1d  — a `dbt build` rebuilds it from RAW in minutes. Paying to
                     time-travel a derived table is paying twice for the same data.
     ANALYTICS 30d — someone will ask "what did the ARR dashboard say on the 3rd,
                     before the restatement?" and AT(TIMESTAMP => ...) answers it
                     directly. That question is why this platform exists. */

/* ---------------------------------------------------------------------------
   Schemas
   --------------------------------------------------------------------------- */

CREATE SCHEMA IF NOT EXISTS REVENUE_RAW.BILLING
    COMMENT = 'Billing system extracts: subscriptions, invoices, plans.';
CREATE SCHEMA IF NOT EXISTS REVENUE_RAW.CRM
    COMMENT = 'CRM extracts: customers, sales org.';
CREATE SCHEMA IF NOT EXISTS REVENUE_RAW.REFERENCE
    COMMENT = 'Reference feeds: FX rates.';

CREATE SCHEMA IF NOT EXISTS REVENUE_STAGING.STAGING
    COMMENT = 'dbt staging models — one per source table, cleaned and cast.';
CREATE SCHEMA IF NOT EXISTS REVENUE_STAGING.INTERMEDIATE
    COMMENT = 'dbt intermediate models — spells, proration, currency normalization.';

CREATE SCHEMA IF NOT EXISTS REVENUE_ANALYTICS.MARTS
    COMMENT = 'Star schema: fct_revenue, dim_customer, dim_product, dim_date.';
CREATE SCHEMA IF NOT EXISTS REVENUE_ANALYTICS.AI
    COMMENT = 'Cortex-generated executive summaries (M7).';

-- Source data is split across BILLING/CRM/REFERENCE rather than dumped in one
-- schema so that a source-level revocation is a single grant change. If the CRM
-- contract later says "PII may not leave the CRM schema", that is enforceable
-- here; it is not enforceable against a schema called RAW.PUBLIC.

/* ---------------------------------------------------------------------------
   Raw tables

   Landed with real types but permissive nullability, plus ingestion metadata.
   Constraints are deliberately absent: RAW's job is to accept what the source
   actually sent, defects and all, so the defect is visible in a query rather
   than as a COPY failure at 03:00. Rejecting bad rows at the door means the
   quarantine reason lives in a load log nobody reads. Landing them means the
   dbt tests in M3 can count them.
   --------------------------------------------------------------------------- */

USE SCHEMA REVENUE_RAW.CRM;

CREATE TABLE IF NOT EXISTS CUSTOMERS (
    customer_id         VARCHAR(20),
    company_name        VARCHAR(200),
    country_code        VARCHAR(2),
    currency_code       VARCHAR(3),
    industry            VARCHAR(50),      -- nullable by contract; ~7% blank
    employee_count      NUMBER(10,0),     -- nullable by contract; ~12% blank
    signup_date         DATE,
    account_manager_id  VARCHAR(20),
    _source_file        VARCHAR(500),
    _loaded_at          TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS EMPLOYEES (
    employee_id   VARCHAR(20),
    manager_id    VARCHAR(20),            -- NULL only for the single org root
    full_name     VARCHAR(200),
    title         VARCHAR(100),
    region        VARCHAR(20),
    _source_file  VARCHAR(500),
    _loaded_at    TIMESTAMP_NTZ
);

USE SCHEMA REVENUE_RAW.BILLING;

CREATE TABLE IF NOT EXISTS PLANS (
    plan_id          VARCHAR(30),
    plan_name        VARCHAR(100),
    tier             VARCHAR(20),
    tier_rank        NUMBER(2,0),
    seat_price_usd   NUMBER(10,2),
    billing_interval VARCHAR(10),
    _source_file     VARCHAR(500),
    _loaded_at       TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS SUBSCRIPTIONS (
    subscription_id VARCHAR(20),
    customer_id     VARCHAR(20),
    plan_id         VARCHAR(30),
    seats           NUMBER(10,0),
    started_at      DATE,
    ended_at        DATE,                 -- NULL means the spell is still open
    status          VARCHAR(20),
    change_reason   VARCHAR(20),
    _source_file    VARCHAR(500),
    _loaded_at      TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS INVOICES (
    invoice_id      VARCHAR(30),
    line_number     NUMBER(4,0),
    customer_id     VARCHAR(20),
    subscription_id VARCHAR(20),
    line_type       VARCHAR(30),
    amount_local    NUMBER(18,2),         -- negative for discounts and credits
    currency_code   VARCHAR(3),
    period_start    DATE,
    period_end      DATE,
    issued_at       TIMESTAMP_NTZ,        -- see the type note below
    status          VARCHAR(20),
    paid_at         TIMESTAMP_NTZ,
    payment_method  VARCHAR(20),
    source_system   VARCHAR(50),
    ingested_at     TIMESTAMP_NTZ,
    _source_file    VARCHAR(500),
    _loaded_at      TIMESTAMP_NTZ
);

/* issued_at is TIMESTAMP_NTZ, not TIMESTAMP_TZ, and that is not laziness.

   The source contract *documents* issued_at as UTC. One source system —
   billing_sync_v2 — actually writes IST wall-clock into it. 40,965 rows carry
   the shift; 434 of them land in the wrong calendar month (see
   data/raw/_manifest.json).

   Typing the column as TIMESTAMP_TZ would force a zone at load time, which
   means either believing the contract (and silently baking the 5h30m error into
   RAW permanently, where it can never be distinguished from a real timestamp)
   or guessing per row. NTZ stores exactly the wall-clock the source sent and
   defers the question to a layer that can answer it: stg_invoices reads
   source_system and applies the correction, so the fix is a visible, testable,
   revertable line of SQL rather than an assumption frozen into a DDL. */

USE SCHEMA REVENUE_RAW.REFERENCE;

CREATE TABLE IF NOT EXISTS FX_RATES (
    rate_date     DATE,
    currency_code VARCHAR(3),
    rate_to_usd   NUMBER(18,6),
    _source_file  VARCHAR(500),
    _loaded_at    TIMESTAMP_NTZ
);

/* ---------------------------------------------------------------------------
   Object grants — attach privileges to the access roles from 01.

   Every schema gets both an ON ALL and an ON FUTURE grant. ON ALL covers what
   exists now; ON FUTURE covers what dbt creates tomorrow. Omit ON FUTURE and
   the pipeline works perfectly until someone adds a model, at which point a
   dashboard 404s at month-end and the fix looks like an outage.
   --------------------------------------------------------------------------- */

USE ROLE SECURITYADMIN;

-- RAW_READ: read everything in RAW, write nothing.
GRANT USAGE ON DATABASE REVENUE_RAW TO ROLE RAW_READ;
GRANT USAGE ON ALL SCHEMAS IN DATABASE REVENUE_RAW TO ROLE RAW_READ;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE REVENUE_RAW TO ROLE RAW_READ;
GRANT SELECT ON ALL TABLES IN DATABASE REVENUE_RAW TO ROLE RAW_READ;
GRANT SELECT ON FUTURE TABLES IN DATABASE REVENUE_RAW TO ROLE RAW_READ;

-- RAW_WRITE: land data, and nothing else.
-- INSERT + TRUNCATE, deliberately without DELETE or UPDATE. COPY INTO needs
-- INSERT; a full-refresh load needs TRUNCATE. Neither needs row-level surgery,
-- and a loader that cannot UPDATE cannot quietly "fix" a source value in the
-- landing zone — which would destroy RAW's only real guarantee, that it is what
-- the source sent.
GRANT USAGE ON DATABASE REVENUE_RAW TO ROLE RAW_WRITE;
GRANT USAGE ON ALL SCHEMAS IN DATABASE REVENUE_RAW TO ROLE RAW_WRITE;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE REVENUE_RAW TO ROLE RAW_WRITE;
GRANT INSERT, TRUNCATE ON ALL TABLES IN DATABASE REVENUE_RAW TO ROLE RAW_WRITE;
GRANT INSERT, TRUNCATE ON FUTURE TABLES IN DATABASE REVENUE_RAW TO ROLE RAW_WRITE;

-- STAGING_READ / STAGING_WRITE
GRANT USAGE ON DATABASE REVENUE_STAGING TO ROLE STAGING_READ;
GRANT USAGE ON ALL SCHEMAS IN DATABASE REVENUE_STAGING TO ROLE STAGING_READ;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE REVENUE_STAGING TO ROLE STAGING_READ;
GRANT SELECT ON ALL TABLES IN DATABASE REVENUE_STAGING TO ROLE STAGING_READ;
GRANT SELECT ON FUTURE TABLES IN DATABASE REVENUE_STAGING TO ROLE STAGING_READ;
GRANT SELECT ON ALL VIEWS IN DATABASE REVENUE_STAGING TO ROLE STAGING_READ;
GRANT SELECT ON FUTURE VIEWS IN DATABASE REVENUE_STAGING TO ROLE STAGING_READ;

GRANT USAGE ON DATABASE REVENUE_STAGING TO ROLE STAGING_WRITE;
GRANT USAGE, CREATE TABLE, CREATE VIEW ON ALL SCHEMAS IN DATABASE REVENUE_STAGING TO ROLE STAGING_WRITE;
GRANT USAGE, CREATE TABLE, CREATE VIEW ON FUTURE SCHEMAS IN DATABASE REVENUE_STAGING TO ROLE STAGING_WRITE;

-- ANALYTICS_READ / ANALYTICS_WRITE
GRANT USAGE ON DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_READ;
GRANT USAGE ON ALL SCHEMAS IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_READ;
GRANT USAGE ON FUTURE SCHEMAS IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_READ;
GRANT SELECT ON ALL TABLES IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_READ;
GRANT SELECT ON FUTURE TABLES IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_READ;
GRANT SELECT ON ALL VIEWS IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_READ;
GRANT SELECT ON FUTURE VIEWS IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_READ;

GRANT USAGE ON DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_WRITE;
GRANT USAGE, CREATE TABLE, CREATE VIEW ON ALL SCHEMAS IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_WRITE;
GRANT USAGE, CREATE TABLE, CREATE VIEW ON FUTURE SCHEMAS IN DATABASE REVENUE_ANALYTICS TO ROLE ANALYTICS_WRITE;

/* dbt creates objects owned by TRANSFORMER. Without the line below, a table dbt
   rebuilds tomorrow is owned by TRANSFORMER and invisible to REPORTER's ON
   FUTURE grant — the classic "dashboard broke after a deploy and nothing in the
   deploy touched the dashboard" failure. Managed access makes the schema owner,
   not the object creator, the grantor of record, so the ON FUTURE grants above
   survive every rebuild. */
USE ROLE SYSADMIN;
ALTER SCHEMA REVENUE_ANALYTICS.MARTS ENABLE MANAGED ACCESS;
ALTER SCHEMA REVENUE_ANALYTICS.AI    ENABLE MANAGED ACCESS;
ALTER SCHEMA REVENUE_STAGING.STAGING      ENABLE MANAGED ACCESS;
ALTER SCHEMA REVENUE_STAGING.INTERMEDIATE ENABLE MANAGED ACCESS;

/* ---------------------------------------------------------------------------
   Verification

     -- REPORTER must not be able to reach staging. Expect an error, not rows:
     USE ROLE REPORTER;
     SELECT * FROM REVENUE_STAGING.INTERMEDIATE.INT_SUBSCRIPTION_SPELLS LIMIT 1;
     -- SQL compilation error: Object does not exist or not authorized.

     -- TRANSFORMER must not be able to write RAW. Expect an error:
     USE ROLE TRANSFORMER;
     INSERT INTO REVENUE_RAW.BILLING.INVOICES (invoice_id) VALUES ('X');
     -- SQL access control error: Insufficient privileges to operate on table

   Both of these are meant to fail. A grant model is only proven by the queries
   it refuses.
   --------------------------------------------------------------------------- */
