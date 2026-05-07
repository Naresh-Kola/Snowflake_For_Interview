-- ============================================================================
-- DESIGNING A SCALABLE DATA WAREHOUSE IN SNOWFLAKE - COMPLETE GUIDE
-- ============================================================================
--
-- ############################################################################
-- PART A: WHAT IS SCALABILITY & WHY DO WE NEED IT?
-- ############################################################################
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHAT DOES "SCALABLE" MEAN IN A DATA WAREHOUSE?
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Scalability = the ability of a system to handle GROWING amounts of:
--   • DATA VOLUME    → from GBs today to TBs/PBs tomorrow
--   • USER CONCURRENCY → from 5 analysts to 500 dashboard users
--   • WORKLOAD DIVERSITY → ingestion + transformation + analytics + ML simultaneously
--   • QUERY COMPLEXITY  → simple SELECTs today, multi-table JOINs with window functions tomorrow
--
-- WITHOUT degrading performance, breaking pipelines, or exploding costs.
--
-- In Snowflake, scalability has TWO dimensions:
--   1. VERTICAL SCALING  → increase warehouse size (XS → S → M → L → XL → ... 6XL)
--                          More nodes per cluster = more compute power per query
--   2. HORIZONTAL SCALING → increase number of clusters (multi-cluster warehouses)
--                           More clusters = more concurrent queries without queueing
--
--
-- ─────────────────────────────────────────────────────────────────────────────
-- WHY DO WE NEED TO SCALE? (THE BUSINESS REALITY)
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Year 1: Startup has 10GB data, 3 analysts, 1 dashboard → XS warehouse works fine
-- Year 2: Data grows to 500GB, 20 analysts, 15 dashboards → queries slow down
-- Year 3: Data hits 5TB, 100 users, real-time pipelines, ML models → everything breaks
--
-- Without a scalable design from Day 1, you face:
--   ✗ Query queueing     → users wait 10+ minutes for simple dashboards
--   ✗ Pipeline failures   → ETL jobs timeout because analysts hog the warehouse
--   ✗ Runaway costs       → one 4XL warehouse running 24/7 for all workloads
--   ✗ Security gaps       → everyone shares one role with full access
--   ✗ Data quality issues → no layered processing, raw data mixed with analytics
--
--
-- ############################################################################
-- PART B: REAL-WORLD DATA ENGINEER PROBLEMS → SNOWFLAKE SOLUTIONS
-- ############################################################################
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 1: RESOURCE CONTENTION                                         │
-- │ "My ETL pipeline fails every morning because analysts are running      │
-- │  heavy dashboards on the same warehouse at 9 AM."                      │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: Single warehouse shared across all workloads               │
-- │                                                                        │
-- │ SOLUTION: Workload isolation with dedicated warehouses                  │
-- │   → WH_INGESTION  (MEDIUM)  for data loading                          │
-- │   → WH_TRANSFORM  (LARGE)   for dbt/ELT jobs                          │
-- │   → WH_ANALYTICS  (MEDIUM, multi-cluster) for BI users                │
-- │   → WH_DATA_SCIENCE (LARGE) for ML workloads                          │
-- │                                                                        │
-- │ WHY IT WORKS: Snowflake decouples storage from compute. Each warehouse │
-- │ is an independent compute cluster. Your ETL never competes with BI.    │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 2: DASHBOARD QUEUEING AT PEAK HOURS                            │
-- │ "At 9 AM, 200 users open dashboards simultaneously. Queries queue      │
-- │  for 5-10 minutes. Users complain dashboards are broken."              │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: Single-cluster warehouse can't handle concurrency spike    │
-- │                                                                        │
-- │ SOLUTION: Multi-cluster warehouse with auto-scaling                    │
-- │   → MIN_CLUSTER_COUNT = 1 (save cost during off-hours)                │
-- │   → MAX_CLUSTER_COUNT = 4 (scale out during peak)                     │
-- │   → SCALING_POLICY = 'STANDARD' (spin up clusters as queue builds)    │
-- │                                                                        │
-- │ HOW IT WORKS: When query load increases, Snowflake automatically adds  │
-- │ clusters (up to MAX). Each cluster handles queries independently.      │
-- │ When load drops, clusters auto-suspend. You only pay for active time.  │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 3: SLOW QUERIES ON LARGE TABLES                                │
-- │ "Our FACT_ORDERS table has 2 billion rows. Queries filtering by date   │
-- │  and region take 45 seconds. Business wants sub-5-second response."    │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: Full table scans — Snowflake scans all micro-partitions    │
-- │                                                                        │
-- │ SOLUTION: Clustering keys + Search Optimization                        │
-- │   → CLUSTER BY (ORDER_DATE, REGION) on fact tables                    │
-- │     Snowflake reorganizes micro-partitions so date+region data is      │
-- │     co-located. Queries with WHERE ORDER_DATE = '2025-01-01' skip     │
-- │     99% of partitions (partition pruning).                             │
-- │                                                                        │
-- │   → SEARCH OPTIMIZATION for point lookups                              │
-- │     WHERE CUSTOMER_ID = 'C-12345' on a 500M row dimension table       │
-- │     goes from 8 sec → 0.2 sec with search optimization enabled.       │
-- │                                                                        │
-- │   → MATERIALIZED VIEWS for repeated heavy aggregations                 │
-- │     Pre-computed and auto-maintained. Snowflake rewrites queries to    │
-- │     use the MV automatically.                                          │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 4: MESSY DATA WITH NO QUALITY LAYERS                           │
-- │ "Raw JSON from APIs is loaded directly into analytics tables. Nulls,   │
-- │  duplicates, and schema changes break downstream dashboards weekly."   │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: No data quality layers — raw data served directly          │
-- │                                                                        │
-- │ SOLUTION: Medallion Architecture (Bronze → Silver → Gold)              │
-- │                                                                        │
-- │   BRONZE (DW_RAW):                                                     │
-- │     • Ingest raw JSON/CSV as-is into VARIANT columns                   │
-- │     • Append-only, never modify, keep full history                     │
-- │     • Use TRANSIENT tables to minimize storage cost                    │
-- │                                                                        │
-- │   SILVER (DW_STAGING):                                                 │
-- │     • Parse, clean, deduplicate, apply data types                      │
-- │     • Handle schema evolution gracefully                               │
-- │     • Streams + Tasks for incremental processing                       │
-- │                                                                        │
-- │   GOLD (DW_ANALYTICS):                                                 │
-- │     • Star schema with facts + dimensions                              │
-- │     • Business logic applied, KPIs calculated                          │
-- │     • Clustered for query performance                                  │
-- │                                                                        │
-- │   PRESENTATION (DW_PRESENTATION):                                      │
-- │     • Secure views per department (Finance, Marketing, Executive)       │
-- │     • RBAC ensures each team sees only their data                      │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 5: BRITTLE PIPELINES WITH COMPLEX TASK DEPENDENCIES            │
-- │ "We have 47 chained Tasks. When one fails midway, we spend hours       │
-- │  figuring out what to re-run. Adding a new step means editing 5 tasks."│
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: Imperative pipeline design with tightly coupled Tasks      │
-- │                                                                        │
-- │ SOLUTION: Dynamic Tables (declarative pipelines)                       │
-- │   → Define WHAT the result should look like, not HOW to build it      │
-- │   → Set TARGET_LAG = '30 MINUTES' and Snowflake handles scheduling    │
-- │   → Auto-detects upstream changes and refreshes incrementally          │
-- │   → No manual dependency management — Snowflake builds the DAG        │
-- │                                                                        │
-- │ WHEN TO USE DYNAMIC TABLES vs STREAMS+TASKS:                           │
-- │   Dynamic Tables → simple transformations, aggregations, joins         │
-- │   Streams+Tasks  → complex logic, conditional branching, MERGE/UPSERT │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 6: RUNAWAY CLOUD COSTS                                         │
-- │ "Our Snowflake bill went from $5K to $45K in one month. Nobody knows   │
-- │  which team or query caused it. Finance is blocking our budget."       │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: No cost guardrails, no per-team attribution                │
-- │                                                                        │
-- │ SOLUTION: Multi-layered cost control                                   │
-- │   1. RESOURCE MONITORS → set monthly credit quotas per warehouse       │
-- │      → 75% notify, 90% warn, 100% auto-suspend                       │
-- │   2. AUTO_SUSPEND → warehouses sleep after N seconds of idle           │
-- │      → Ingestion: 60s | Transform: 120s | Analytics: 300s             │
-- │   3. TRANSIENT TABLES → no fail-safe storage for staging data          │
-- │      → Saves ~25% storage cost on ephemeral data                      │
-- │   4. PER-TEAM WAREHOUSES → each team's cost is isolated and trackable │
-- │   5. QUERY TAGGING → tag queries to attribute cost to projects         │
-- │      → ALTER SESSION SET QUERY_TAG = 'project:marketing_campaign';    │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 7: SECURITY & ACCESS CHAOS                                     │
-- │ "A junior analyst accidentally dropped a production table. Interns     │
-- │  can see salary data. Nobody knows who has access to what."            │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: Flat role structure, excessive privileges                   │
-- │                                                                        │
-- │ SOLUTION: Hierarchical RBAC with least-privilege principle             │
-- │                                                                        │
-- │   ROLE_BI_VIEWER        → SELECT on presentation views only            │
-- │     ↑ inherited by                                                     │
-- │   ROLE_DATA_ANALYST     → + SELECT on analytics tables                 │
-- │     ↑ inherited by                                                     │
-- │   ROLE_DATA_ENGINEER    → + WRITE on raw/staging + warehouse access    │
-- │     ↑ inherited by                                                     │
-- │   SYSADMIN              → full admin                                   │
-- │                                                                        │
-- │   ADDITIONAL PROTECTIONS:                                              │
-- │   → FUTURE GRANTS for auto-granting on new objects                    │
-- │   → MASKING POLICIES to hide PII from non-privileged roles            │
-- │   → ROW ACCESS POLICIES to restrict row-level data per team           │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ PROBLEM 8: SHARING DATA ACROSS TEAMS/ACCOUNTS                          │
-- │ "Finance team in a different Snowflake account needs our revenue data. │
-- │  We currently export CSVs weekly. Data is always stale."              │
-- ├─────────────────────────────────────────────────────────────────────────┤
-- │ ROOT CAUSE: Manual data movement between accounts                      │
-- │                                                                        │
-- │ SOLUTION: Snowflake Secure Data Sharing                                │
-- │   → ZERO-COPY: no data movement, consumer reads from your storage     │
-- │   → REAL-TIME: consumer always sees the latest data                   │
-- │   → GOVERNED: share specific views, not raw tables                    │
-- │   → NO COST TO CONSUMER: they only pay for their own compute          │
-- └─────────────────────────────────────────────────────────────────────────┘
--
--
-- ############################################################################
-- PART C: SCALABILITY DECISION MATRIX
-- ############################################################################
--
-- ┌───────────────────────┬────────────────────┬────────────────────────────┐
-- │ SYMPTOM               │ SCALING TYPE       │ SNOWFLAKE SOLUTION         │
-- ├───────────────────────┼────────────────────┼────────────────────────────┤
-- │ Query too slow        │ Vertical (size up) │ Increase warehouse size    │
-- │ Too many queued       │ Horizontal (out)   │ Multi-cluster warehouse    │
-- │ Full table scans      │ Data optimization  │ Clustering keys            │
-- │ Point lookup slow     │ Data optimization  │ Search optimization        │
-- │ Repeated aggregations │ Pre-compute        │ Materialized views         │
-- │ Pipeline complexity   │ Architecture       │ Dynamic tables             │
-- │ Cost explosion        │ Governance         │ Resource monitors          │
-- │ Mixed workloads       │ Isolation          │ Dedicated warehouses       │
-- │ Data freshness        │ Automation         │ Streams + Tasks            │
-- │ Cross-team access     │ Collaboration      │ Secure data sharing        │
-- └───────────────────────┴────────────────────┴────────────────────────────┘
--
--
-- ############################################################################
-- PART D: IMPLEMENTATION (SQL BLUEPRINTS)
-- ############################################################################

-- ============================================================================
-- 1. MULTI-CLUSTER ARCHITECTURE: SEPARATE WORKLOADS BY PURPOSE
-- ============================================================================
-- Snowflake decouples storage from compute. Use dedicated warehouses
-- for different workload types to avoid resource contention.

-- Ingestion warehouse: optimized for bulk loading
CREATE WAREHOUSE IF NOT EXISTS WH_INGESTION
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dedicated to ELT/ETL data loading';

-- Transformation warehouse: for dbt, stored procs, heavy SQL
CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM
    WAREHOUSE_SIZE = 'LARGE'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dedicated to data transformation workloads';

-- Analytics warehouse: multi-cluster for concurrent BI users
CREATE WAREHOUSE IF NOT EXISTS WH_ANALYTICS
    WAREHOUSE_SIZE = 'MEDIUM'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 4
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Multi-cluster for BI dashboards and ad-hoc queries';

-- Data science warehouse: for ML workloads
CREATE WAREHOUSE IF NOT EXISTS WH_DATA_SCIENCE
    WAREHOUSE_SIZE = 'LARGE'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Dedicated to ML training and feature engineering';


-- ============================================================================
-- 2. DATABASE & SCHEMA DESIGN: LAYERED MEDALLION ARCHITECTURE
-- ============================================================================
-- Use a layered approach (Bronze → Silver → Gold) for data quality progression.

-- RAW layer (Bronze): ingested data, append-only, minimal transformation
CREATE DATABASE IF NOT EXISTS DW_RAW;
CREATE SCHEMA IF NOT EXISTS DW_RAW.ERP;
CREATE SCHEMA IF NOT EXISTS DW_RAW.CRM;
CREATE SCHEMA IF NOT EXISTS DW_RAW.WEB_EVENTS;
CREATE SCHEMA IF NOT EXISTS DW_RAW.THIRD_PARTY;

-- STAGING layer (Silver): cleaned, deduplicated, conformed types
CREATE DATABASE IF NOT EXISTS DW_STAGING;
CREATE SCHEMA IF NOT EXISTS DW_STAGING.CLEANED;
CREATE SCHEMA IF NOT EXISTS DW_STAGING.CONFORMED;

-- ANALYTICS layer (Gold): business-ready dimensional models
CREATE DATABASE IF NOT EXISTS DW_ANALYTICS;
CREATE SCHEMA IF NOT EXISTS DW_ANALYTICS.DIMENSIONS;
CREATE SCHEMA IF NOT EXISTS DW_ANALYTICS.FACTS;
CREATE SCHEMA IF NOT EXISTS DW_ANALYTICS.AGGREGATES;
CREATE SCHEMA IF NOT EXISTS DW_ANALYTICS.DATA_VAULT;

-- PRESENTATION layer: curated views for specific consumers
CREATE DATABASE IF NOT EXISTS DW_PRESENTATION;
CREATE SCHEMA IF NOT EXISTS DW_PRESENTATION.FINANCE;
CREATE SCHEMA IF NOT EXISTS DW_PRESENTATION.MARKETING;
CREATE SCHEMA IF NOT EXISTS DW_PRESENTATION.EXECUTIVE;


-- ============================================================================
-- 3. TABLE DESIGN BEST PRACTICES
-- ============================================================================

-- 3a. Transient tables for staging (no Time Travel cost, no Fail-safe)
CREATE OR REPLACE TRANSIENT TABLE DW_RAW.ERP.ORDERS_RAW (
    RAW_DATA        VARIANT,
    SOURCE_FILE     VARCHAR,
    LOAD_TIMESTAMP  TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
DATA_RETENTION_TIME_IN_DAYS = 0
COMMENT = 'Raw ERP orders - transient to minimize storage cost';

-- 3b. Permanent tables for analytics with clustering
CREATE OR REPLACE TABLE DW_ANALYTICS.FACTS.FACT_ORDERS (
    ORDER_KEY           NUMBER AUTOINCREMENT,
    ORDER_ID            VARCHAR NOT NULL,
    CUSTOMER_KEY        NUMBER,
    PRODUCT_KEY         NUMBER,
    ORDER_DATE          DATE,
    SHIP_DATE           DATE,
    ORDER_AMOUNT        NUMBER(18,2),
    QUANTITY            NUMBER,
    DISCOUNT_AMOUNT     NUMBER(18,2),
    REGION              VARCHAR,
    ETL_LOADED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (ORDER_DATE, REGION)
DATA_RETENTION_TIME_IN_DAYS = 30
COMMENT = 'Clustered fact table - pruning on date and region';

-- 3c. Dimension table with search optimization
CREATE OR REPLACE TABLE DW_ANALYTICS.DIMENSIONS.DIM_CUSTOMER (
    CUSTOMER_KEY        NUMBER AUTOINCREMENT,
    CUSTOMER_ID         VARCHAR NOT NULL,
    CUSTOMER_NAME       VARCHAR,
    EMAIL               VARCHAR,
    SEGMENT             VARCHAR,
    REGION              VARCHAR,
    COUNTRY             VARCHAR,
    CREATED_DATE        DATE,
    IS_CURRENT          BOOLEAN DEFAULT TRUE,
    EFFECTIVE_FROM      TIMESTAMP_NTZ,
    EFFECTIVE_TO        TIMESTAMP_NTZ,
    ETL_LOADED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'SCD Type 2 customer dimension';

ALTER TABLE DW_ANALYTICS.DIMENSIONS.DIM_CUSTOMER
    ADD SEARCH OPTIMIZATION ON EQUALITY(CUSTOMER_ID, EMAIL);


-- ============================================================================
-- 4. AUTOMATED DATA PIPELINES WITH STREAMS & TASKS
-- ============================================================================
-- Streams capture CDC (change data capture). Tasks automate processing.

-- Stream on raw table to detect new inserts
CREATE OR REPLACE STREAM DW_RAW.ERP.ORDERS_RAW_STREAM
    ON TABLE DW_RAW.ERP.ORDERS_RAW
    APPEND_ONLY = TRUE
    COMMENT = 'CDC stream for incremental order processing';

-- Task to process new data every 10 minutes
CREATE OR REPLACE TASK DW_STAGING.CLEANED.TASK_PROCESS_ORDERS
    WAREHOUSE = WH_TRANSFORM
    SCHEDULE = '10 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('DW_RAW.ERP.ORDERS_RAW_STREAM')
AS
    INSERT INTO DW_STAGING.CLEANED.ORDERS_CLEANED
    SELECT
        RAW_DATA:order_id::VARCHAR       AS ORDER_ID,
        RAW_DATA:customer_id::VARCHAR    AS CUSTOMER_ID,
        RAW_DATA:order_date::DATE        AS ORDER_DATE,
        RAW_DATA:amount::NUMBER(18,2)    AS ORDER_AMOUNT,
        RAW_DATA:region::VARCHAR         AS REGION,
        CURRENT_TIMESTAMP()              AS ETL_LOADED_AT
    FROM DW_RAW.ERP.ORDERS_RAW_STREAM;


-- ============================================================================
-- 5. DYNAMIC TABLES FOR DECLARATIVE PIPELINES
-- ============================================================================
-- Dynamic tables auto-refresh with a target lag, replacing complex task chains.

CREATE OR REPLACE DYNAMIC TABLE DW_ANALYTICS.AGGREGATES.DAILY_SALES_SUMMARY
    TARGET_LAG = '30 MINUTES'
    WAREHOUSE = WH_TRANSFORM
AS
    SELECT
        f.ORDER_DATE,
        f.REGION,
        d.SEGMENT            AS CUSTOMER_SEGMENT,
        COUNT(*)             AS ORDER_COUNT,
        SUM(f.ORDER_AMOUNT)  AS TOTAL_REVENUE,
        AVG(f.ORDER_AMOUNT)  AS AVG_ORDER_VALUE,
        SUM(f.QUANTITY)      AS TOTAL_UNITS_SOLD
    FROM DW_ANALYTICS.FACTS.FACT_ORDERS f
    JOIN DW_ANALYTICS.DIMENSIONS.DIM_CUSTOMER d
        ON f.CUSTOMER_KEY = d.CUSTOMER_KEY
        AND d.IS_CURRENT = TRUE
    GROUP BY f.ORDER_DATE, f.REGION, d.SEGMENT;


-- ============================================================================
-- 6. PERFORMANCE OPTIMIZATION
-- ============================================================================

-- 6a. Clustering keys on large fact tables (billions of rows)
--     Choose columns used in WHERE/JOIN clauses with high cardinality
ALTER TABLE DW_ANALYTICS.FACTS.FACT_ORDERS
    CLUSTER BY (ORDER_DATE, REGION);

-- 6b. Search optimization for point lookups
ALTER TABLE DW_ANALYTICS.DIMENSIONS.DIM_CUSTOMER
    ADD SEARCH OPTIMIZATION ON EQUALITY(CUSTOMER_ID)
    ON SUBSTRING(CUSTOMER_NAME);

-- 6c. Materialized views for expensive repeated aggregations
CREATE OR REPLACE MATERIALIZED VIEW DW_ANALYTICS.AGGREGATES.MV_MONTHLY_REVENUE
AS
    SELECT
        DATE_TRUNC('MONTH', ORDER_DATE) AS MONTH,
        REGION,
        SUM(ORDER_AMOUNT)               AS MONTHLY_REVENUE,
        COUNT(DISTINCT ORDER_ID)        AS ORDER_COUNT
    FROM DW_ANALYTICS.FACTS.FACT_ORDERS
    GROUP BY 1, 2;

-- 6d. Result caching is automatic, but ensure queries are deterministic
-- Avoid CURRENT_TIMESTAMP() in queries when caching is desired


-- ============================================================================
-- 7. COST CONTROL & RESOURCE MONITORS
-- ============================================================================

-- Monitor credit usage per warehouse
CREATE OR REPLACE RESOURCE MONITOR RM_ANALYTICS
    WITH CREDIT_QUOTA = 500
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_ANALYTICS SET RESOURCE_MONITOR = RM_ANALYTICS;

-- Monitor for transformation workloads
CREATE OR REPLACE RESOURCE MONITOR RM_TRANSFORM
    WITH CREDIT_QUOTA = 300
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE WH_TRANSFORM SET RESOURCE_MONITOR = RM_TRANSFORM;


-- ============================================================================
-- 8. ROLE-BASED ACCESS CONTROL (RBAC)
-- ============================================================================
-- Implement least-privilege with functional roles

CREATE ROLE IF NOT EXISTS ROLE_DATA_ENGINEER;
CREATE ROLE IF NOT EXISTS ROLE_DATA_ANALYST;
CREATE ROLE IF NOT EXISTS ROLE_DATA_SCIENTIST;
CREATE ROLE IF NOT EXISTS ROLE_BI_VIEWER;

-- Data engineers: full access to raw + staging, read on analytics
GRANT USAGE ON DATABASE DW_RAW TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE DW_RAW TO ROLE ROLE_DATA_ENGINEER;
GRANT ALL PRIVILEGES ON ALL TABLES IN DATABASE DW_RAW TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_INGESTION TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE ON WAREHOUSE WH_TRANSFORM TO ROLE ROLE_DATA_ENGINEER;

-- Analysts: read-only on analytics + presentation
GRANT USAGE ON DATABASE DW_ANALYTICS TO ROLE ROLE_DATA_ANALYST;
GRANT USAGE ON ALL SCHEMAS IN DATABASE DW_ANALYTICS TO ROLE ROLE_DATA_ANALYST;
GRANT SELECT ON ALL TABLES IN DATABASE DW_ANALYTICS TO ROLE ROLE_DATA_ANALYST;
GRANT USAGE ON DATABASE DW_PRESENTATION TO ROLE ROLE_DATA_ANALYST;
GRANT USAGE ON ALL SCHEMAS IN DATABASE DW_PRESENTATION TO ROLE ROLE_DATA_ANALYST;
GRANT SELECT ON ALL VIEWS IN DATABASE DW_PRESENTATION TO ROLE ROLE_DATA_ANALYST;
GRANT USAGE ON WAREHOUSE WH_ANALYTICS TO ROLE ROLE_DATA_ANALYST;

-- BI viewers: presentation layer only
GRANT USAGE ON DATABASE DW_PRESENTATION TO ROLE ROLE_BI_VIEWER;
GRANT USAGE ON ALL SCHEMAS IN DATABASE DW_PRESENTATION TO ROLE ROLE_BI_VIEWER;
GRANT SELECT ON ALL VIEWS IN DATABASE DW_PRESENTATION TO ROLE ROLE_BI_VIEWER;
GRANT USAGE ON WAREHOUSE WH_ANALYTICS TO ROLE ROLE_BI_VIEWER;

-- Role hierarchy
GRANT ROLE ROLE_BI_VIEWER TO ROLE ROLE_DATA_ANALYST;
GRANT ROLE ROLE_DATA_ANALYST TO ROLE ROLE_DATA_ENGINEER;
GRANT ROLE ROLE_DATA_ENGINEER TO ROLE SYSADMIN;


-- ============================================================================
-- 9. DATA SHARING & COLLABORATION
-- ============================================================================
-- Zero-copy data sharing for cross-team or cross-account access

CREATE OR REPLACE SHARE SHARE_FINANCE_DATA;
GRANT USAGE ON DATABASE DW_PRESENTATION TO SHARE SHARE_FINANCE_DATA;
GRANT USAGE ON SCHEMA DW_PRESENTATION.FINANCE TO SHARE SHARE_FINANCE_DATA;
GRANT SELECT ON ALL VIEWS IN SCHEMA DW_PRESENTATION.FINANCE TO SHARE SHARE_FINANCE_DATA;


-- ============================================================================
-- 10. MONITORING & OBSERVABILITY
-- ============================================================================

-- Query to monitor warehouse performance and identify bottlenecks
SELECT
    WAREHOUSE_NAME,
    DATE_TRUNC('HOUR', START_TIME)          AS HOUR,
    COUNT(*)                                AS QUERY_COUNT,
    AVG(TOTAL_ELAPSED_TIME) / 1000          AS AVG_DURATION_SEC,
    MAX(TOTAL_ELAPSED_TIME) / 1000          AS MAX_DURATION_SEC,
    SUM(BYTES_SCANNED) / POWER(1024, 3)     AS TOTAL_TB_SCANNED,
    AVG(PARTITIONS_SCANNED /
        NULLIF(PARTITIONS_TOTAL, 0)) * 100  AS AVG_PARTITION_SCAN_PCT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND WAREHOUSE_NAME IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2 DESC;

-- Identify expensive queries for optimization
SELECT
    QUERY_ID,
    USER_NAME,
    WAREHOUSE_NAME,
    TOTAL_ELAPSED_TIME / 1000               AS DURATION_SEC,
    BYTES_SCANNED / POWER(1024, 3)          AS TB_SCANNED,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -1, CURRENT_TIMESTAMP())
    AND TOTAL_ELAPSED_TIME > 60000
ORDER BY TOTAL_ELAPSED_TIME DESC
LIMIT 20;


-- ============================================================================
-- SUMMARY OF KEY DESIGN PRINCIPLES
-- ============================================================================
--
-- 1. SEPARATE COMPUTE    → Dedicated warehouses per workload type
-- 2. LAYERED STORAGE     → Bronze/Silver/Gold (Raw → Staging → Analytics)
-- 3. AUTOMATE PIPELINES  → Streams, Tasks, Dynamic Tables
-- 4. CLUSTER WISELY      → Cluster large tables on filter/join columns
-- 5. CONTROL COSTS       → Resource monitors, auto-suspend, transient tables
-- 6. SECURE BY DEFAULT   → RBAC with least-privilege, role hierarchy
-- 7. SHARE, DON'T COPY   → Use Snowflake data sharing for collaboration
-- 8. MONITOR CONSTANTLY  → Track query performance, scan ratios, costs
-- 9. SCALE ELASTICALLY   → Multi-cluster warehouses for concurrency
-- 10. USE SEARCH OPT     → For point lookups on high-cardinality columns
-- ============================================================================
