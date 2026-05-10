-- ============================================================================
-- WORKLOAD ISOLATION IN SNOWFLAKE - COMPLETE GUIDE WITH EXAMPLES
-- ============================================================================
--
--
-- ############################################################################
-- PART 1: WHAT IS WORKLOAD ISOLATION & WHY DOES IT MATTER?
-- ############################################################################
--
-- Workload isolation means ensuring that different types of work
-- (loading, transforming, querying, ML) do NOT compete for the same
-- compute resources.
--
-- WITHOUT ISOLATION (the problem):
-- ┌─────────────────────────────────────────────────────────────────────┐
-- │                    SINGLE SHARED WAREHOUSE                         │
-- │                                                                    │
-- │   ETL Job (heavy)  ──┐                                            │
-- │   Dashboard User 1 ──┤                                            │
-- │   Dashboard User 2 ──┼──→  WH_SHARED (LARGE)  →  QUERY QUEUE!    │
-- │   Analyst Query    ──┤      All queries compete                   │
-- │   ML Training Job  ──┘      for the same pool                     │
-- │                                                                    │
-- │   RESULT: ETL slows dashboards. ML blocks analysts. Everyone waits.│
-- └─────────────────────────────────────────────────────────────────────┘
--
-- WITH ISOLATION (the solution):
-- ┌─────────────────────────────────────────────────────────────────────┐
-- │                   DEDICATED WAREHOUSES PER WORKLOAD                 │
-- │                                                                    │
-- │   ETL Job         ──→  WH_INGESTION   (MEDIUM)   → runs alone     │
-- │   dbt models      ──→  WH_TRANSFORM   (LARGE)    → runs alone     │
-- │   Dashboard Users ──→  WH_ANALYTICS   (MEDIUM x4) → scales out    │
-- │   Analyst Queries ──→  WH_ADHOC       (SMALL)     → runs alone    │
-- │   ML Training     ──→  WH_DATA_SCIENCE(LARGE)     → runs alone    │
-- │                                                                    │
-- │   RESULT: Each workload has guaranteed resources. Zero contention. │
-- └─────────────────────────────────────────────────────────────────────┘
--
-- WHY THIS WORKS IN SNOWFLAKE:
--   Snowflake separates STORAGE from COMPUTE. All warehouses read from
--   the SAME shared storage layer. Creating 5 warehouses does NOT copy
--   data 5 times — they all access the same data, just with independent
--   compute clusters.
--
--
-- ############################################################################
-- PART 2: THE 5 WORKLOAD CATEGORIES
-- ############################################################################
--
-- ┌──────────────┬────────────────────────┬───────────┬─────────────────────┐
-- │ WORKLOAD     │ CHARACTERISTICS        │ IDEAL SIZE│ KEY SETTINGS        │
-- ├──────────────┼────────────────────────┼───────────┼─────────────────────┤
-- │ INGESTION    │ Bulk COPY INTO, Snowpipe│ MEDIUM    │ AUTO_SUSPEND=60     │
-- │              │ High I/O, bursty       │           │ Single cluster      │
-- ├──────────────┼────────────────────────┼───────────┼─────────────────────┤
-- │ TRANSFORM    │ dbt, stored procs,     │ LARGE     │ AUTO_SUSPEND=120    │
-- │              │ MERGE, heavy SQL       │           │ Single cluster      │
-- ├──────────────┼────────────────────────┼───────────┼─────────────────────┤
-- │ ANALYTICS    │ BI dashboards, many    │ MEDIUM    │ AUTO_SUSPEND=300    │
-- │ (BI)         │ concurrent users       │           │ Multi-cluster (1-4) │
-- ├──────────────┼────────────────────────┼───────────┼─────────────────────┤
-- │ AD-HOC       │ Analyst exploration,   │ SMALL     │ AUTO_SUSPEND=300    │
-- │              │ unpredictable patterns │           │ Multi-cluster (1-2) │
-- ├──────────────┼────────────────────────┼───────────┼─────────────────────┤
-- │ DATA SCIENCE │ ML training, feature   │ LARGE/XL  │ AUTO_SUSPEND=120    │
-- │              │ engineering, batch     │           │ Single cluster      │
-- └──────────────┴────────────────────────┴───────────┴─────────────────────┘
--
--
-- ############################################################################
-- PART 3: IMPLEMENTATION — CREATING ISOLATED WAREHOUSES
-- ############################################################################


-- ============================================================================
-- 3A. INGESTION WAREHOUSE
-- ============================================================================
-- Purpose: Dedicated to bulk loading (COPY INTO), Snowpipe, external stages
-- Why MEDIUM: COPY INTO scales linearly with warehouse size for large files.
--   MEDIUM gives 2x throughput vs SMALL at 2x cost — good balance.
-- Why AUTO_SUSPEND=60: Loading is bursty. No need to keep it running.

CREATE WAREHOUSE IF NOT EXISTS WH_INGESTION
    WAREHOUSE_SIZE   = 'MEDIUM'
    AUTO_SUSPEND     = 60
    AUTO_RESUME      = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Isolated for ETL/ELT data loading — no contention with queries';

-- EXAMPLE: Load data using the ingestion warehouse
USE WAREHOUSE WH_INGESTION;

-- Bulk load from external stage
-- COPY INTO MY_DB.RAW.ORDERS
-- FROM @MY_DB.RAW.S3_STAGE/orders/
-- FILE_FORMAT = (TYPE = 'PARQUET')
-- MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;


-- ============================================================================
-- 3B. TRANSFORMATION WAREHOUSE
-- ============================================================================
-- Purpose: dbt runs, stored procedures, MERGE statements, heavy SQL transforms
-- Why LARGE: Transformations often involve multi-table JOINs, window functions,
--   and billions of rows. LARGE = 8 nodes = fast complex SQL.
-- Why AUTO_SUSPEND=120: dbt runs in bursts (e.g., every 30 min). Give 2 min
--   buffer for back-to-back model runs before suspending.

CREATE WAREHOUSE IF NOT EXISTS WH_TRANSFORM
    WAREHOUSE_SIZE   = 'LARGE'
    AUTO_SUSPEND     = 120
    AUTO_RESUME      = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Isolated for dbt, stored procs, MERGE — heavy transformations';

-- EXAMPLE: Run dbt using the transformation warehouse
-- In your dbt profiles.yml:
--   warehouse: WH_TRANSFORM
--
-- Or dynamically:
-- USE WAREHOUSE WH_TRANSFORM;
-- CALL MY_DB.TRANSFORMS.SP_BUILD_FACT_ORDERS();


-- ============================================================================
-- 3C. ANALYTICS WAREHOUSE (MULTI-CLUSTER)
-- ============================================================================
-- Purpose: BI dashboards (Tableau, PowerBI, Looker), scheduled reports
-- Why MULTI-CLUSTER: At 9 AM, 200 users open dashboards. A single cluster
--   queues queries. Multi-cluster spins up parallel clusters automatically.
-- Why MEDIUM: Dashboard queries are typically pre-aggregated and fast.
--   A MEDIUM cluster handles most dashboard queries in <5 seconds.
-- Why MAX=4: 4 MEDIUM clusters handle ~200 concurrent queries without queueing.
-- Why AUTO_SUSPEND=300: BI tools keep connections open. 5 min avoids
--   constant suspend/resume cycles that add cold-start latency.

CREATE WAREHOUSE IF NOT EXISTS WH_ANALYTICS
    WAREHOUSE_SIZE    = 'MEDIUM'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 4
    SCALING_POLICY    = 'STANDARD'
    AUTO_SUSPEND      = 300
    AUTO_RESUME       = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Multi-cluster for BI dashboards — auto-scales with user load';

-- SCALING_POLICY explained:
--   STANDARD: Start new cluster when a query is queued (reactive, cost-efficient)
--   ECONOMY:  Wait until load sustains for 6 min before adding cluster (cheaper,
--             but users may experience queueing during ramp-up)

-- EXAMPLE: How multi-cluster works in practice
--
--   8:00 AM  → 5 users   → 1 cluster active    (MIN_CLUSTER_COUNT=1)
--   9:00 AM  → 150 users → queries start queuing → cluster 2 spins up
--   9:05 AM  → 200 users → still queuing        → cluster 3 spins up
--   9:30 AM  → 250 users → near capacity        → cluster 4 spins up (MAX)
--   12:00 PM → 30 users  → clusters 4,3,2 shut down → back to 1 cluster
--   6:00 PM  → 0 users   → last cluster suspends after 5 min idle


-- ============================================================================
-- 3D. AD-HOC EXPLORATION WAREHOUSE
-- ============================================================================
-- Purpose: Analyst exploration, ad-hoc SQL, data discovery
-- Why SMALL: Ad-hoc queries vary wildly. SMALL is cheap for exploration.
--   If analysts need more power, they can temporarily resize (if granted).
-- Why multi-cluster (1-2): Prevents one analyst's heavy query from
--   blocking another's quick lookup.

CREATE WAREHOUSE IF NOT EXISTS WH_ADHOC
    WAREHOUSE_SIZE    = 'SMALL'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 2
    SCALING_POLICY    = 'STANDARD'
    AUTO_SUSPEND      = 300
    AUTO_RESUME       = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'For analyst ad-hoc queries and data exploration';


-- ============================================================================
-- 3E. DATA SCIENCE WAREHOUSE
-- ============================================================================
-- Purpose: ML feature engineering, model training, batch predictions
-- Why LARGE: ML training involves scanning entire tables, computing features
--   across billions of rows, and running expensive UDFs.
-- Why single cluster: ML jobs are typically sequential batch processes,
--   not concurrent interactive queries.

CREATE WAREHOUSE IF NOT EXISTS WH_DATA_SCIENCE
    WAREHOUSE_SIZE   = 'LARGE'
    AUTO_SUSPEND     = 120
    AUTO_RESUME      = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Isolated for ML training, feature engineering, batch scoring';


-- ============================================================================
-- 3F. DEV/TEST WAREHOUSE
-- ============================================================================
-- Purpose: Development, testing, CI/CD pipeline validation
-- Why XSMALL: Dev/test queries run on small datasets. Minimize cost.
-- Why AUTO_SUSPEND=60: Developers forget to suspend. Quick timeout saves money.

CREATE WAREHOUSE IF NOT EXISTS WH_DEV_TEST
    WAREHOUSE_SIZE   = 'XSMALL'
    AUTO_SUSPEND     = 60
    AUTO_RESUME      = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'For development and CI/CD testing — minimal cost';


-- ############################################################################
-- PART 4: RBAC — ENFORCING WAREHOUSE ISOLATION
-- ############################################################################
-- Creating warehouses is not enough. You must ENFORCE that teams use
-- the correct warehouse via role-based access control.

-- Create functional roles
CREATE ROLE IF NOT EXISTS ROLE_DATA_LOADER;
CREATE ROLE IF NOT EXISTS ROLE_DATA_ENGINEER;
CREATE ROLE IF NOT EXISTS ROLE_DATA_ANALYST;
CREATE ROLE IF NOT EXISTS ROLE_DATA_SCIENTIST;
CREATE ROLE IF NOT EXISTS ROLE_BI_SERVICE;
CREATE ROLE IF NOT EXISTS ROLE_DEVELOPER;

-- Grant warehouse access per role (each role gets ONLY its warehouse)
GRANT USAGE, OPERATE ON WAREHOUSE WH_INGESTION    TO ROLE ROLE_DATA_LOADER;
GRANT USAGE, OPERATE ON WAREHOUSE WH_TRANSFORM    TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE, OPERATE ON WAREHOUSE WH_ANALYTICS    TO ROLE ROLE_BI_SERVICE;
GRANT USAGE, OPERATE ON WAREHOUSE WH_ADHOC        TO ROLE ROLE_DATA_ANALYST;
GRANT USAGE, OPERATE ON WAREHOUSE WH_DATA_SCIENCE TO ROLE ROLE_DATA_SCIENTIST;
GRANT USAGE, OPERATE ON WAREHOUSE WH_DEV_TEST     TO ROLE ROLE_DEVELOPER;

-- Data engineers also need ingestion + adhoc access
GRANT USAGE, OPERATE ON WAREHOUSE WH_INGESTION TO ROLE ROLE_DATA_ENGINEER;
GRANT USAGE, OPERATE ON WAREHOUSE WH_ADHOC     TO ROLE ROLE_DATA_ENGINEER;

-- Role hierarchy
GRANT ROLE ROLE_DATA_LOADER   TO ROLE ROLE_DATA_ENGINEER;
GRANT ROLE ROLE_BI_SERVICE    TO ROLE ROLE_DATA_ANALYST;
GRANT ROLE ROLE_DEVELOPER     TO ROLE ROLE_DATA_ENGINEER;
GRANT ROLE ROLE_DATA_ENGINEER TO ROLE SYSADMIN;
GRANT ROLE ROLE_DATA_SCIENTIST TO ROLE SYSADMIN;

-- Assign roles to users
-- GRANT ROLE ROLE_DATA_ENGINEER  TO USER JOHN_ETL;
-- GRANT ROLE ROLE_DATA_ANALYST   TO USER SARAH_ANALYST;
-- GRANT ROLE ROLE_BI_SERVICE     TO USER TABLEAU_SVC_ACCT;
-- GRANT ROLE ROLE_DATA_SCIENTIST TO USER ML_TEAM_LEAD;


-- ############################################################################
-- PART 5: COST CONTROL PER WORKLOAD
-- ############################################################################
-- Each isolated warehouse gets its own budget via resource monitors.
-- This gives per-team cost visibility and automatic spend limits.

CREATE OR REPLACE RESOURCE MONITOR RM_INGESTION
    WITH CREDIT_QUOTA = 200
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

CREATE OR REPLACE RESOURCE MONITOR RM_TRANSFORM
    WITH CREDIT_QUOTA = 400
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 95 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

CREATE OR REPLACE RESOURCE MONITOR RM_ANALYTICS
    WITH CREDIT_QUOTA = 600
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

CREATE OR REPLACE RESOURCE MONITOR RM_ADHOC
    WITH CREDIT_QUOTA = 150
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

CREATE OR REPLACE RESOURCE MONITOR RM_DATA_SCIENCE
    WITH CREDIT_QUOTA = 300
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

CREATE OR REPLACE RESOURCE MONITOR RM_DEV_TEST
    WITH CREDIT_QUOTA = 50
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND_IMMEDIATE;

-- Attach monitors to warehouses
ALTER WAREHOUSE WH_INGESTION    SET RESOURCE_MONITOR = RM_INGESTION;
ALTER WAREHOUSE WH_TRANSFORM    SET RESOURCE_MONITOR = RM_TRANSFORM;
ALTER WAREHOUSE WH_ANALYTICS    SET RESOURCE_MONITOR = RM_ANALYTICS;
ALTER WAREHOUSE WH_ADHOC        SET RESOURCE_MONITOR = RM_ADHOC;
ALTER WAREHOUSE WH_DATA_SCIENCE SET RESOURCE_MONITOR = RM_DATA_SCIENCE;
ALTER WAREHOUSE WH_DEV_TEST     SET RESOURCE_MONITOR = RM_DEV_TEST;


-- ############################################################################
-- PART 6: QUERY TAGGING FOR COST ATTRIBUTION
-- ############################################################################
-- Even within a warehouse, tag queries to attribute cost to specific
-- projects, teams, or pipelines.

-- Tag a session (all queries in this session get tagged)
ALTER SESSION SET QUERY_TAG = 'team:data_engineering;project:order_pipeline';

-- Tag individual queries via comment convention
SELECT /* team:marketing, project:campaign_roi */
    CAMPAIGN_NAME,
    SUM(REVENUE)  AS TOTAL_REVENUE,
    SUM(SPEND)    AS TOTAL_SPEND
FROM DW_ANALYTICS.FACTS.FACT_CAMPAIGNS
GROUP BY 1;

-- Query cost attribution report
SELECT
    QUERY_TAG,
    WAREHOUSE_NAME,
    COUNT(*)                                    AS QUERY_COUNT,
    SUM(TOTAL_ELAPSED_TIME) / 1000 / 60         AS TOTAL_MINUTES,
    SUM(CREDITS_USED_CLOUD_SERVICES)             AS CLOUD_CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('MONTH', -1, CURRENT_TIMESTAMP())
    AND QUERY_TAG IS NOT NULL
    AND QUERY_TAG != ''
GROUP BY 1, 2
ORDER BY TOTAL_MINUTES DESC;


-- ############################################################################
-- PART 7: MONITORING WORKLOAD ISOLATION EFFECTIVENESS
-- ############################################################################

-- 7A. Check if warehouses are right-sized (are queries queueing?)
SELECT
    WAREHOUSE_NAME,
    COUNT(*)                                                  AS TOTAL_QUERIES,
    SUM(CASE WHEN QUEUED_OVERLOAD_TIME > 0 THEN 1 ELSE 0 END) AS QUEUED_QUERIES,
    ROUND(SUM(QUEUED_OVERLOAD_TIME) / 1000, 2)                AS TOTAL_QUEUE_SEC,
    ROUND(AVG(TOTAL_ELAPSED_TIME) / 1000, 2)                  AS AVG_DURATION_SEC,
    ROUND(MAX(TOTAL_ELAPSED_TIME) / 1000, 2)                  AS MAX_DURATION_SEC
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND WAREHOUSE_NAME IS NOT NULL
GROUP BY 1
ORDER BY QUEUED_QUERIES DESC;

-- INTERPRETATION:
--   QUEUED_QUERIES > 5% of TOTAL → warehouse is undersized or needs multi-cluster
--   AVG_DURATION > 30 sec        → consider sizing up the warehouse
--   MAX_DURATION > 300 sec       → investigate the specific slow queries

-- 7B. Check warehouse utilization (are we over-provisioned?)
SELECT
    WAREHOUSE_NAME,
    DATE_TRUNC('DAY', START_TIME)  AS DAY,
    COUNT(*)                       AS QUERY_COUNT,
    SUM(CREDITS_USED_CLOUD_SERVICES) AS CREDITS_USED,
    ROUND(AVG(TOTAL_ELAPSED_TIME) / 1000, 2) AS AVG_DURATION_SEC
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
    AND WAREHOUSE_NAME IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;

-- INTERPRETATION:
--   WH with < 10 queries/day and LARGE size → downsize to SMALL/MEDIUM
--   WH with 0 queries some days             → consider on-demand only

-- 7C. Identify queries running on the WRONG warehouse
-- (e.g., an analyst running on WH_INGESTION instead of WH_ADHOC)
SELECT
    QUERY_ID,
    USER_NAME,
    ROLE_NAME,
    WAREHOUSE_NAME,
    QUERY_TYPE,
    TOTAL_ELAPSED_TIME / 1000 AS DURATION_SEC,
    QUERY_TEXT
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND (
        (WAREHOUSE_NAME = 'WH_INGESTION' AND QUERY_TYPE = 'SELECT')
        OR (WAREHOUSE_NAME = 'WH_ANALYTICS' AND QUERY_TYPE IN ('INSERT', 'MERGE', 'CREATE_TABLE_AS_SELECT'))
        OR (WAREHOUSE_NAME = 'WH_TRANSFORM' AND ROLE_NAME LIKE '%ANALYST%')
    )
ORDER BY DURATION_SEC DESC
LIMIT 50;


-- ############################################################################
-- PART 8: ADVANCED — DYNAMIC WAREHOUSE SIZING
-- ############################################################################
-- For workloads with variable compute needs, you can resize warehouses
-- programmatically before heavy jobs and resize back after.

-- EXAMPLE: Scale up before nightly ETL, scale back after
-- (Run this in a stored procedure or Task)

-- Before heavy load
ALTER WAREHOUSE WH_TRANSFORM SET WAREHOUSE_SIZE = 'XLARGE';

-- Run the heavy transformation
-- CALL MY_DB.TRANSFORMS.SP_REBUILD_ALL_FACTS();

-- After heavy load, scale back down
ALTER WAREHOUSE WH_TRANSFORM SET WAREHOUSE_SIZE = 'LARGE';

-- EXAMPLE: Stored procedure that auto-scales based on data volume
-- CREATE OR REPLACE PROCEDURE MY_DB.ADMIN.SP_ADAPTIVE_WAREHOUSE_SIZE(
--     WH_NAME VARCHAR, ROW_THRESHOLD NUMBER, LARGE_SIZE VARCHAR, SMALL_SIZE VARCHAR
-- )
-- RETURNS VARCHAR
-- LANGUAGE SQL
-- AS
-- $$
-- DECLARE
--     ROW_COUNT NUMBER;
--     NEW_SIZE VARCHAR;
-- BEGIN
--     SELECT COUNT(*) INTO :ROW_COUNT FROM MY_DB.RAW.INCOMING_DATA;
--     IF (ROW_COUNT > ROW_THRESHOLD) THEN
--         NEW_SIZE := LARGE_SIZE;
--     ELSE
--         NEW_SIZE := SMALL_SIZE;
--     END IF;
--     EXECUTE IMMEDIATE 'ALTER WAREHOUSE ' || WH_NAME || ' SET WAREHOUSE_SIZE = ''' || NEW_SIZE || '''';
--     RETURN 'Warehouse ' || WH_NAME || ' resized to ' || NEW_SIZE || ' (rows: ' || ROW_COUNT || ')';
-- END;
-- $$;


-- ############################################################################
-- SUMMARY: WORKLOAD ISOLATION CHECKLIST
-- ############################################################################
--
--  [1] CREATE separate warehouses per workload type
--      → Ingestion, Transform, Analytics, Ad-hoc, Data Science, Dev/Test
--
--  [2] CONFIGURE each warehouse appropriately
--      → Size based on workload weight
--      → Multi-cluster for high concurrency (BI, ad-hoc)
--      → Single cluster for sequential batch jobs (ETL, ML)
--      → AUTO_SUSPEND tuned per usage pattern
--
--  [3] ENFORCE isolation via RBAC
--      → Each role gets USAGE only on its designated warehouse(s)
--      → Users cannot accidentally use the wrong warehouse
--
--  [4] CONTROL costs per workload
--      → Resource monitor on every warehouse
--      → Tiered alerts: notify → warn → suspend
--      → Query tagging for granular cost attribution
--
--  [5] MONITOR continuously
--      → Track queue times (undersized?)
--      → Track utilization (oversized?)
--      → Detect misrouted queries (wrong warehouse usage)
--
--  [6] ADAPT dynamically
--      → Resize warehouses before/after heavy jobs
--      → Adjust cluster counts seasonally
--      → Review sizing monthly based on monitoring data
-- ============================================================================
