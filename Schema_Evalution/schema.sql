-- ============================================================================
-- QUESTION: "HOW DO YOU HANDLE SCHEMA EVOLUTION IN DOWNSTREAM MODELS?"
-- ============================================================================
-- When source tables have SCHEMA EVOLUTION enabled (new columns auto-added),
-- how do you ensure downstream pipelines don't break?
-- ============================================================================


-- ============================================================================
-- 1. WHAT IS SCHEMA EVOLUTION IN SNOWFLAKE?
-- ============================================================================
--
-- Schema Evolution allows Snowflake to AUTOMATICALLY add new columns
-- when loading data (via COPY INTO or Snowpipe) without manual DDL.
--
-- ENABLED BY:
--   ALTER TABLE my_table SET ENABLE_SCHEMA_EVOLUTION = TRUE;
--
-- WHAT HAPPENS:
--   - Source sends a new field (e.g., "loyalty_tier") in the next file
--   - Snowflake auto-adds the column to the table
--   - Existing rows get NULL for the new column
--   - No manual ALTER TABLE needed
--
-- THE PROBLEM:
--   Your downstream views, models, and pipelines use SELECT * or
--   hardcoded column lists. When a new column appears:
--   - SELECT * picks it up (may break schema contracts)
--   - Hardcoded columns miss it (data loss)
--   - Downstream consumers may not expect it (dashboard errors)
--
-- ============================================================================


-- ============================================================================
-- 2. DEMO SETUP: Source Table with Schema Evolution
-- ============================================================================

CREATE OR REPLACE TABLE RAW_CUSTOMERS (
    customer_id INT,
    name VARCHAR(100),
    email VARCHAR(200),
    signup_date DATE
)
ENABLE_SCHEMA_EVOLUTION = TRUE;

INSERT INTO RAW_CUSTOMERS VALUES
(1, 'Alice', 'alice@example.com', '2024-01-15'),
(2, 'Bob', 'bob@example.com', '2024-02-20'),
(3, 'Charlie', 'charlie@example.com', '2024-03-10');

SELECT * FROM RAW_CUSTOMERS;

-- Simulate schema evolution: source now sends a new column
ALTER TABLE RAW_CUSTOMERS ADD COLUMN loyalty_tier VARCHAR(20);
ALTER TABLE RAW_CUSTOMERS ADD COLUMN phone_number VARCHAR(20);

UPDATE RAW_CUSTOMERS SET loyalty_tier = 'gold' WHERE customer_id = 1;
UPDATE RAW_CUSTOMERS SET loyalty_tier = 'silver' WHERE customer_id = 2;
UPDATE RAW_CUSTOMERS SET phone_number = '555-0101' WHERE customer_id = 1;

SELECT * FROM RAW_CUSTOMERS;
-- Now has 6 columns instead of original 4!


-- ============================================================================
-- 3. THE PROBLEM: WHY NOT USE SELECT * ?
-- ============================================================================
--
-- YES, SELECT * WILL pick up new columns automatically. That sounds great!
-- But here's WHY it causes serious problems in production:
--
-- ============================================================================
--
-- PROBLEM 1: INSERT INTO ... SELECT * BREAKS
-- ───────────────────────────────────────────
-- Your pipeline does:
--   INSERT INTO target_table SELECT * FROM source_table;
--
-- Source had 4 columns → target has 4 columns → WORKS.
-- Source evolves to 6 columns → target still has 4 → ERROR:
--   "Insert value list does not match column list expecting 4 but got 6"
--
-- PROBLEM 2: UNION ALL BREAKS
-- ────────────────────────────
-- Your model does:
--   SELECT * FROM table_a   -- 4 columns
--   UNION ALL
--   SELECT * FROM table_b   -- suddenly 6 columns → ERROR
--
-- PROBLEM 3: DOWNSTREAM COLUMN REFERENCES BREAK
-- ──────────────────────────────────────────────
-- A dashboard or API expects columns in a SPECIFIC ORDER:
--   Column 1 = customer_id, Column 2 = name, Column 3 = email...
--
-- With SELECT *, new columns might appear IN THE MIDDLE or change
-- ordinal position. Your BI tool that references "column 4" now
-- gets a different column → WRONG DATA displayed silently.
--
-- PROBLEM 4: PII/SENSITIVE DATA LEAKS
-- ────────────────────────────────────
-- Source team adds: phone_number, ssn, credit_card_last4
-- SELECT * automatically exposes them to ALL downstream consumers.
-- Your reporting view now shows PII to analysts who shouldn't see it.
-- COMPLIANCE VIOLATION (GDPR, HIPAA, PCI).
--
-- PROBLEM 5: COST EXPLOSION
-- ──────────────────────────
-- Source adds 20 new JSON/VARIANT columns (500MB each).
-- SELECT * now scans ALL of them even if downstream only needs 3.
-- Your query goes from scanning 1GB to 10GB → 10x more expensive.
--
-- PROBLEM 6: dbt CONTRACTS AND TESTS BREAK
-- ─────────────────────────────────────────
-- If your mart has a contract (enforced schema), and SELECT * brings
-- in new unexpected columns → dbt build FAILS because output doesn't
-- match the declared contract.
--
-- PROBLEM 7: SILENT DATA QUALITY ISSUES
-- ──────────────────────────────────────
-- New column "status" arrives with NULLs for all existing rows.
-- SELECT * passes it downstream. A dashboard shows a "status" filter
-- with all NULLs. Users think data is broken. No one reviewed if
-- the column is ready for consumption or still being backfilled.
--
-- ============================================================================
-- EXAMPLE: How SELECT * Breaks a Real Pipeline
-- ============================================================================

-- Day 1: Everything works fine
-- Source: customer_id, name, email, signup_date (4 columns)
-- Pipeline: INSERT INTO warehouse_table SELECT * FROM source → OK

-- Day 5: Source team adds "loyalty_tier" (now 5 columns)
-- Pipeline: INSERT INTO warehouse_table SELECT * FROM source → FAILS!
-- Error: "Insert value list does not match column list"
-- Your entire pipeline is DOWN at 3 AM. On-call gets paged.

-- With explicit columns:
-- INSERT INTO warehouse_table (customer_id, name, email, signup_date)
-- SELECT customer_id, name, email, signup_date FROM source → STILL WORKS!
-- New column is ignored until you deliberately add it.

-- ============================================================================
-- THE CORRECT APPROACH:
-- ============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │                                                                         │
-- │  SELECT * is OK for:                                                   │
-- │    - Ad-hoc exploration (one-time queries in Snowsight)                │
-- │    - Development/debugging                                             │
-- │    - Raw → staging ONLY IF using dbt with on_schema_change='fail'      │
-- │                                                                         │
-- │  SELECT * is DANGEROUS for:                                            │
-- │    - Production pipelines                                              │
-- │    - INSERT INTO ... SELECT *                                          │
-- │    - Views consumed by dashboards                                      │
-- │    - Models with data contracts                                        │
-- │    - Any query where column order/count matters                        │
-- │    - Tables with potential PII columns                                 │
-- │                                                                         │
-- │  EXPLICIT COLUMNS give you:                                            │
-- │    ✅ Pipeline stability (won't break when source evolves)             │
-- │    ✅ Security (PII columns excluded deliberately)                     │
-- │    ✅ Performance (only scan needed columns)                           │
-- │    ✅ Documentation (code shows exactly what data flows through)       │
-- │    ✅ Control (new columns require deliberate, reviewed changes)       │
-- │                                                                         │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- SUMMARY: "Will SELECT * pick up new columns?" → YES.
--          "Is that a good thing?" → NO. Because:
--          1. It breaks INSERT/UNION operations
--          2. It leaks PII without review
--          3. It increases cost (scans unneeded data)
--          4. It causes silent failures in dashboards
--          5. It removes your ability to CONTROL what goes downstream
--
--          The whole point of a data pipeline is CONTROLLED data flow.
--          SELECT * gives you UNCONTROLLED data flow.
--
-- ============================================================================


-- ============================================================================
-- 4. STRATEGY 1: EXPLICIT COLUMN LIST + CONTROLLED PROMOTION
-- ============================================================================
--
-- BEST PRACTICE: Never use SELECT * in production models.
-- Explicitly list columns and ADD new ones deliberately after validation.
--
C
--
-- ============================================================================

-- Staging model: explicit columns (new ones are deliberately excluded until reviewed)
CREATE OR REPLACE VIEW DEMO_DB.PUBLIC.STG_CUSTOMERS AS
SELECT
    customer_id,
    name AS customer_name,
    email AS customer_email,
    signup_date,
    loyalty_tier  -- Added after review and validation
    -- phone_number deliberately excluded (PII, not needed downstream)
FROM DEMO_DB.PUBLIC.RAW_CUSTOMERS;

SELECT * FROM DEMO_DB.PUBLIC.STG_CUSTOMERS;


-- ============================================================================
-- 5. STRATEGY 2: DETECT SCHEMA CHANGES AUTOMATICALLY
-- ============================================================================
--
-- Monitor the source table for new columns and alert the team.
--
-- ============================================================================

-- Query: Find columns added recently
SELECT
    TABLE_NAME,
    COLUMN_NAME,
    DATA_TYPE,
    ORDINAL_POSITION,
    COMMENT
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'PUBLIC'
    AND TABLE_NAME = 'RAW_CUSTOMERS'
ORDER BY ORDINAL_POSITION;

-- Query: Compare current schema vs expected schema
WITH expected_columns AS (
    SELECT column_value AS col_name
    FROM TABLE(FLATTEN(INPUT => ARRAY_CONSTRUCT(
        'CUSTOMER_ID', 'NAME', 'EMAIL', 'SIGNUP_DATE'
    )))
),
actual_columns AS (
    SELECT COLUMN_NAME AS col_name
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'PUBLIC'
        AND TABLE_NAME = 'RAW_CUSTOMERS'
)
SELECT a.col_name AS new_column_detected
FROM actual_columns a
LEFT JOIN expected_columns e ON a.col_name = e.col_name
WHERE e.col_name IS NULL;

-- RESULT: Shows LOYALTY_TIER and PHONE_NUMBER as new columns.
-- Use this in a Snowflake TASK to alert via email/Slack.


-- ============================================================================
-- 6. STRATEGY 3: SCHEMA CHANGE ALERTING WITH TASKS
-- ============================================================================

-- Create a table to track known schema
CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.SCHEMA_REGISTRY (
    table_name VARCHAR,
    column_name VARCHAR,
    data_type VARCHAR,
    first_seen_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    approved BOOLEAN DEFAULT FALSE
);

-- Procedure to detect and log new columns
CREATE OR REPLACE PROCEDURE DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    INSERT INTO DEMO_DB.PUBLIC.SCHEMA_REGISTRY (table_name, column_name, data_type)
    SELECT
        c.TABLE_NAME,
        c.COLUMN_NAME,
        c.DATA_TYPE
    FROM INFORMATION_SCHEMA.COLUMNS c
    LEFT JOIN DEMO_DB.PUBLIC.SCHEMA_REGISTRY r
        ON c.TABLE_NAME = r.table_name
        AND c.COLUMN_NAME = r.column_name
    WHERE c.TABLE_SCHEMA = 'PUBLIC'
        AND c.TABLE_NAME = 'RAW_CUSTOMERS'
        AND r.column_name IS NULL;

    RETURN 'Schema check complete';
END;
$$;

CALL DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION();
SELECT * FROM DEMO_DB.PUBLIC.SCHEMA_REGISTRY;


-- ============================================================================
-- 7. STRATEGY 4: VARIANT COLUMN FOR FLEXIBLE SCHEMA
-- ============================================================================
--
-- Store evolving fields in a VARIANT column so the table schema is FIXED
-- but new fields are captured in a semi-structured column.
--
-- ============================================================================

CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.RAW_CUSTOMERS_FLEX (
    customer_id INT,
    name VARCHAR(100),
    email VARCHAR(200),
    signup_date DATE,
    extra_fields VARIANT        -- All new/evolving fields go here
);

INSERT INTO DEMO_DB.PUBLIC.RAW_CUSTOMERS_FLEX VALUES
(1, 'Alice', 'alice@example.com', '2024-01-15',
    PARSE_JSON('{"loyalty_tier": "gold", "phone": "555-0101"}')),
(2, 'Bob', 'bob@example.com', '2024-02-20',
    PARSE_JSON('{"loyalty_tier": "silver"}')),
(3, 'Charlie', 'charlie@example.com', '2024-03-10',
    PARSE_JSON('{}'));

-- Downstream extracts specific fields from VARIANT as needed:
SELECT
    customer_id,
    name,
    email,
    signup_date,
    extra_fields:loyalty_tier::VARCHAR AS loyalty_tier,
    extra_fields:phone::VARCHAR AS phone_number
FROM DEMO_DB.PUBLIC.RAW_CUSTOMERS_FLEX;

-- BENEFIT: Table schema NEVER changes. New fields appear in extra_fields.
-- Downstream chooses which fields to extract explicitly.


-- ============================================================================
-- 8. STRATEGY 5: dbt on_schema_change CONFIG
-- ============================================================================
--
-- If using dbt incremental models, configure how schema changes are handled:
--
-- ============================================================================

-- dbt model config options:
-- {{
--   config(
--     materialized='incremental',
--     on_schema_change='sync_all_columns'  -- or 'ignore', 'fail', 'append_new_columns'
--   )
-- }}
--
-- OPTIONS:
-- ┌─────────────────────┬────────────────────────────────────────────────────┐
-- │ OPTION              │ BEHAVIOR                                           │
-- ├─────────────────────┼────────────────────────────────────────────────────┤
-- │ ignore (default)    │ New columns silently dropped. Target unchanged.    │
-- │ fail                │ Build FAILS if schema changes. Forces review.      │
-- │ append_new_columns  │ New columns added to target. Old rows get NULL.    │
-- │ sync_all_columns    │ Add new columns AND remove dropped ones.           │
-- └─────────────────────┴────────────────────────────────────────────────────┘
--
-- EXAMPLE: Staging model that auto-adapts
-- {{
--   config(
--     materialized='incremental',
--     unique_key='customer_id',
--     on_schema_change='append_new_columns'
--   )
-- }}
--
-- SELECT * FROM {{ source('raw', 'customers') }}
-- {% if is_incremental() %}
--     WHERE loaded_at > (SELECT MAX(loaded_at) FROM {{ this }})
-- {% endif %}
--
-- RECOMMENDED PER LAYER:
--   Staging:      on_schema_change='append_new_columns' (capture everything)
--   Intermediate: on_schema_change='fail' (force deliberate changes)
--   Marts:        on_schema_change='fail' (contracts protect consumers)


-- ============================================================================
-- 9. STRATEGY 6: DYNAMIC SQL FOR AUTO-ADAPTING VIEWS
-- ============================================================================
--
-- Create a view that automatically includes all current columns with
-- safe defaults for NULLs.
--
-- ============================================================================

-- Procedure to recreate a downstream view whenever schema evolves:
CREATE OR REPLACE PROCEDURE DEMO_DB.PUBLIC.REBUILD_STG_CUSTOMERS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    col_list VARCHAR;
BEGIN
    SELECT LISTAGG(
        CASE
            WHEN COLUMN_NAME IN ('CUSTOMER_ID', 'NAME', 'EMAIL', 'SIGNUP_DATE')
                THEN COLUMN_NAME
            ELSE 'COALESCE(' || COLUMN_NAME || ', ''unknown'') AS ' || COLUMN_NAME
        END,
        ', '
    ) WITHIN GROUP (ORDER BY ORDINAL_POSITION)
    INTO col_list
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = 'PUBLIC'
        AND TABLE_NAME = 'RAW_CUSTOMERS';

    EXECUTE IMMEDIATE
        'CREATE OR REPLACE VIEW DEMO_DB.PUBLIC.STG_CUSTOMERS_AUTO AS SELECT '
        || col_list
        || ' FROM DEMO_DB.PUBLIC.RAW_CUSTOMERS';

    RETURN 'View rebuilt with columns: ' || col_list;
END;
$$;

CALL DEMO_DB.PUBLIC.REBUILD_STG_CUSTOMERS();
SELECT * FROM DEMO_DB.PUBLIC.STG_CUSTOMERS_AUTO;


-- ============================================================================
-- 10. STRATEGY 7: STREAM + TASK FOR REAL-TIME SCHEMA MONITORING
-- ============================================================================

-- Create a task that checks for schema changes every hour:
CREATE OR REPLACE TASK DEMO_DB.PUBLIC.MONITOR_SCHEMA_EVOLUTION
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '60 MINUTE'
AS
    CALL DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION();

-- Enable the task:
ALTER TASK DEMO_DB.PUBLIC.MONITOR_SCHEMA_EVOLUTION RESUME;

-- Check unapproved new columns:
SELECT *
FROM DEMO_DB.PUBLIC.SCHEMA_REGISTRY
WHERE approved = FALSE
ORDER BY first_seen_at DESC;


-- ============================================================================
-- 11. COMPLETE PATTERN: Production-Ready Schema Evolution Handling
-- ============================================================================
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │                                                                         │
-- │  RAW TABLE (schema evolution = TRUE)                                   │
-- │  New columns auto-added by Snowpipe/COPY INTO                          │
-- │       │                                                                 │
-- │       ▼                                                                 │
-- │  SCHEMA MONITOR (Task, runs hourly)                                    │
-- │  Detects new columns → logs to SCHEMA_REGISTRY → alerts team           │
-- │       │                                                                 │
-- │       ▼                                                                 │
-- │  STAGING MODEL (explicit column list)                                  │
-- │  Only includes APPROVED columns. New columns excluded until reviewed.  │
-- │       │                                                                 │
-- │       ▼                                                                 │
-- │  INTERMEDIATE / MARTS (stable schema)                                  │
-- │  Protected by dbt contracts. on_schema_change='fail'.                  │
-- │  Downstream consumers see STABLE, predictable schema.                  │
-- │                                                                         │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- WORKFLOW:
--   1. Source sends new field → auto-added to RAW table
--   2. Hourly task detects it → logs to registry → sends alert
--   3. Engineer reviews: Is it needed? Is it PII? What type?
--   4. If approved → adds to staging model with proper casting/renaming
--   5. Staging change triggers dbt CI → tests run → PR merged
--   6. Downstream marts pick up new column via ref()
--
-- ============================================================================


-- ============================================================================
-- 12. HANDLING IN dbt: FULL EXAMPLE
-- ============================================================================
--
-- FILE: models/staging/stg_customers.sql
-- ──────────────────────────────────────
-- {{
--   config(
--     materialized='view'
--   )
-- }}
--
-- SELECT
--     customer_id,
--     name AS customer_name,
--     email AS customer_email,
--     signup_date,
--     -- New columns added after schema evolution review:
--     loyalty_tier,
--     -- phone_number excluded (PII, handled separately)
--     CURRENT_TIMESTAMP() AS _loaded_at
-- FROM {{ source('raw', 'customers') }}
--
-- ─────────────────────────────────────
-- FILE: models/staging/_sources.yml
-- ─────────────────────────────────────
-- version: 2
-- sources:
--   - name: raw
--     database: DEMO_DB
--     schema: PUBLIC
--     tables:
--       - name: customers
--         columns:
--           - name: customer_id
--             tests: [unique, not_null]
--           - name: name
--             tests: [not_null]
--           - name: email
--             tests: [not_null]
--           - name: loyalty_tier
--             tests:
--               - accepted_values:
--                   values: ['gold', 'silver', 'bronze']
--                   config:
--                     where: "loyalty_tier IS NOT NULL"
--
-- ─────────────────────────────────────
-- FILE: models/marts/dim_customers.sql
-- ─────────────────────────────────────
-- {{
--   config(
--     materialized='table',
--     contract: {enforced: true}
--   )
-- }}
--
-- SELECT
--     customer_id,
--     customer_name,
--     customer_email,
--     signup_date,
--     COALESCE(loyalty_tier, 'none') AS loyalty_tier
-- FROM {{ ref('stg_customers') }}
--
-- The CONTRACT ensures if someone removes loyalty_tier from staging,
-- the mart build FAILS instead of silently losing the column.


-- ============================================================================
-- 13. INTERVIEW ANSWER
-- ============================================================================
--
-- "When source tables have schema evolution enabled, new columns appear
-- automatically. The challenge is preventing downstream breakage while
-- still capturing new data.
--
-- My approach has four layers:
--
-- FIRST: NEVER use SELECT * in production models. Staging models have
-- explicit column lists. New source columns are invisible downstream
-- until deliberately added.
--
-- SECOND: I set up schema monitoring — a Snowflake Task runs hourly,
-- compares current columns against a registry table, and alerts the
-- team when new columns appear. This gives us visibility without
-- surprise breakage.
--
-- THIRD: In dbt, I use on_schema_change='fail' for marts so any
-- unexpected schema change blocks the build and forces a review.
-- For staging incrementals, I use 'append_new_columns' to capture
-- data while protecting downstream.
--
-- FOURTH: For highly dynamic schemas (IoT, event data), I use a
-- VARIANT column to store evolving fields. The table schema stays
-- fixed, but new fields are captured in the semi-structured column
-- and extracted explicitly when needed.
--
-- The key principle: schema evolution at the source is fine for
-- ingestion flexibility, but downstream models should have CONTROLLED,
-- DELIBERATE schema changes that go through review and testing."
--
-- ============================================================================


-- ============================================================================
-- 14. QUICK REFERENCE
-- ============================================================================
--
-- ┌────────────────────────────────────────────────────────────────────────┐
-- │ STRATEGY                     │ WHEN TO USE                            │
-- ├──────────────────────────────┼────────────────────────────────────────┤
-- │ Explicit column list         │ Always (default best practice)         │
-- │ Schema monitoring + alerts   │ Any table with evolution enabled       │
-- │ VARIANT column               │ Highly dynamic schemas (IoT, events)  │
-- │ on_schema_change='fail'      │ Marts / contracts / critical models   │
-- │ on_schema_change='append'    │ Staging incrementals (capture all)    │
-- │ Dynamic view rebuild         │ Auto-adapting reporting layers         │
-- │ Schema registry table        │ Audit trail + approval workflow        │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ============================================================================
-- END
-- ============================================================================
