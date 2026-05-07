-- ============================================================================
-- SNOWFLAKE WAREHOUSES - COMPLETE GUIDE (Scratch to Architect Level)
-- ============================================================================
-- Author: Learning Guide
-- Topics: Types, Sizing, Configuration, Production Problems, Interview Q&A
-- ============================================================================

-- ============================================================================
-- SECTION 1: WHAT IS A SNOWFLAKE WAREHOUSE?
-- ============================================================================

/*
A Virtual Warehouse in Snowflake is a cluster of compute resources (CPU, memory,
temporary storage(SSD)) that executes:
  - SQL SELECT queries
  - DML operations (INSERT, UPDATE, DELETE, MERGE)
  - Data loading (COPY INTO <table>)
  - Data unloading (COPY INTO <location>)

Key Characteristics:
  - Warehouses do NOT store data (data is in storage layer)
  
  However, warehouses USE local cache (SSD + memory) for performance:
  ┌───────────────────┬─────────────────────────────────────────────────────────────┬──────────────────────────────────┐
  │ Cache Type        │ What It Does                                                │ Lifetime                         │
  ├───────────────────┼─────────────────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Local SSD Cache   │ Caches micro-partitions fetched from remote storage so      │ Lives while WH is RUNNING;       │
  │                   │ repeat scans avoid network I/O                              │ dropped on SUSPEND               │
  ├───────────────────┼─────────────────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Memory (RAM)      │ Holds intermediate query results (joins, sorts, aggs)       │ Freed after query completes      │
  │                   │ during execution. If insufficient, data "spills" to SSD     │                                  │
  │                   │ then to remote storage (slow!)                              │                                  │
  ├───────────────────┼─────────────────────────────────────────────────────────────┼──────────────────────────────────┤
  │ Result Cache      │ Stores final query results (lives in Cloud Services layer,  │ 24 hours; shared across users    │
  │                   │ NOT in the warehouse itself)                                │                                  │
  └───────────────────┴─────────────────────────────────────────────────────────────┴──────────────────────────────────┘

  Key Takeaway:
  - SSD cache = speeds up repeated reads (avoids fetching from remote storage again)
  - Memory = working space during execution (insufficient memory causes spilling)
  - Suspending a warehouse drops the SSD cache — next resume starts "cold"
  - Longer AUTO_SUSPEND keeps cache warm (faster queries) but costs more credits

  - They can be started/stopped at any time
  - They can be resized while running
  - Billing is per-second (with 60-second minimum on resume)
  - Multiple warehouses can access the same data simultaneously
*/

-- ============================================================================
-- SECTION 2: WAREHOUSE TYPES
-- ============================================================================

/*
Snowflake offers the following warehouse types:

┌─────────────────────────────┬────────────────────────────────────────────────┐
│ Type                        │ Purpose                                        │
├─────────────────────────────┼────────────────────────────────────────────────┤
│ 1. Standard (Gen1)          │ General-purpose analytics & ETL                │
│ 2. Standard (Gen2)          │ Improved hardware/software for better perf     │
│ 3. Snowpark-Optimized       │ High-memory workloads (ML training)            │
│ 4. Adaptive                 │ Auto-tuning, no sizing needed                  │
│ 5. Multi-Cluster            │ Concurrency scaling (any type above)           │
└─────────────────────────────┴────────────────────────────────────────────────┘
*/

-- ============================================================================
-- SECTION 2.1: STANDARD WAREHOUSE (Gen1)
-- ============================================================================

/*
The default warehouse type. Suitable for most analytics and ETL workloads.

Sizes: XS, S, M, L, XL, 2XL, 3XL, 4XL, 5XL, 6XL
Credits double with each size increase.

Credit Rates (Gen1 - same across all cloud providers):
  XS   = 1 credit/hour
  S    = 2 credits/hour
  M    = 4 credits/hour
  L    = 8 credits/hour
  XL   = 16 credits/hour
  2XL  = 32 credits/hour
  3XL  = 64 credits/hour
  4XL  = 128 credits/hour
  5XL  = 256 credits/hour
  6XL  = 512 credits/hour
*/

-- Create a standard warehouse (Gen1)
CREATE WAREHOUSE etl_warehouse
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

-- ============================================================================
-- SECTION 2.2: STANDARD WAREHOUSE (Gen2)
-- ============================================================================

/*
Gen2 is the SAME Standard type but with a different GENERATION.
It delivers better performance through:
  - Faster hardware (upgraded CPUs, memory, cache)
  - Software optimizations (DELETE, UPDATE, MERGE improvements)
  - Higher concurrency

Key Facts:
  - NOT a cost-saving feature — it's a PERFORMANCE feature
  - Sizes supported: XSMALL through X4LARGE only (no 5XL, 6XL)
  - NOT available for Snowpark-Optimized warehouses
  - Cannot be set via Snowsight UI (SQL only)
  - Live migration (no downtime) from Gen1 to Gen2

Gen2 Credit Rates (vary by cloud provider):
  AWS/GCP:  XS=1.35, S=2.7, M=5.4, L=10.8, XL=21.6, 2XL=43.2, 3XL=86.4, 4XL=172.8
  Azure:    XS=1.25, S=2.5, M=5, L=10, XL=20, 2XL=40, 3XL=80, 4XL=160
*/

-- Create a Gen2 warehouse
CREATE WAREHOUSE analytics_gen2_wh
  GENERATION = '2'
  WAREHOUSE_SIZE = 'LARGE'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- Convert existing Gen1 to Gen2 (live migration, no downtime)
ALTER WAREHOUSE etl_warehouse SET GENERATION = '2';

-- Rollback to Gen1 if needed
ALTER WAREHOUSE etl_warehouse SET GENERATION = '1';

-- Verify warehouse generation
SHOW WAREHOUSES LIKE 'analytics_gen2_wh';
-- Check the "generation" column in the result

-- ============================================================================
-- SECTION 2.3: SNOWPARK-OPTIMIZED WAREHOUSE
-- ============================================================================

/*
Designed for workloads with large memory requirements:
  - ML model training via stored procedures
  - Large UDF/UDTF operations
  - Memory-intensive Snowpark workloads

Memory Configurations:
  MEMORY_1X     = 16GB   (min size: XSMALL)
  MEMORY_16X    = 256GB  (min size: MEDIUM)  [DEFAULT]
  MEMORY_64X    = 1TB    (min size: LARGE, AWS only, Preview)

Key Limitations:
  - Gen2 is NOT available for Snowpark-Optimized
  - Resume time may be longer than standard warehouses
  - Not beneficial for workloads that don't use Snowpark
*/

-- Create a Snowpark-Optimized warehouse for ML training
CREATE WAREHOUSE ml_training_wh
  WAREHOUSE_SIZE = 'MEDIUM'
  WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
  MAX_CONCURRENCY_LEVEL = 1;

-- Create with specific memory configuration
CREATE WAREHOUSE ml_heavy_wh
  WAREHOUSE_SIZE = 'LARGE'
  WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
  RESOURCE_CONSTRAINT = 'MEMORY_16X_X86';

-- ============================================================================
-- SECTION 2.4: ADAPTIVE WAREHOUSE
-- ============================================================================

/*
Adaptive Compute removes the need to choose warehouse sizes, configure 
concurrency, or manage QAS. The system decides how to allocate resources.

Key Characteristics:
  - New warehouse type (WAREHOUSE_TYPE = 'ADAPTIVE')
  - No sizing needed — Snowflake handles resource decisions
  - QAS is included (no separate charges)
  - All adaptive WHs in an account share a dedicated compute pool
  - NOT shared with other accounts or other warehouse types

Two Parameters:
  MAX_QUERY_PERFORMANCE_LEVEL: Max performance per query
    Values: XSMALL, SMALL, MEDIUM, LARGE, XLARGE, XXLARGE, XXXLARGE, X4LARGE
    Default: XLARGE

  QUERY_THROUGHPUT_MULTIPLIER: Peak concurrent capacity multiplier
    Values: Integer >= 2, or 0 (unlimited)
    Default: 2

Gen2 vs Adaptive:
  Gen2   = Better performance within the familiar size-based model
  Adaptive = Removes the sizing model entirely
*/

-- Create an Adaptive warehouse
CREATE ADAPTIVE WAREHOUSE adaptive_analytics_wh
  MAX_QUERY_PERFORMANCE_LEVEL = 'XLARGE'
  QUERY_THROUGHPUT_MULTIPLIER = 2;

-- ============================================================================
-- SECTION 2.5: MULTI-CLUSTER WAREHOUSE (Enterprise Edition+)
-- ============================================================================

/*
Multi-cluster warehouses scale OUT by adding clusters to handle concurrency.
Any warehouse type can be multi-cluster.

Two Modes:
  1. Maximized: All clusters run at all times (MIN = MAX > 1)
  2. Auto-scale: Clusters start/stop dynamically (MIN < MAX)

Scaling Policies:
  STANDARD (default): Favors starting clusters to prevent queuing
  ECONOMY: Conserves credits; only starts if 6+ minutes of work estimated

Max Clusters by Size:
  XSMALL-MEDIUM = 300 clusters max
  LARGE         = 160 clusters max
  XLARGE        = 80 clusters max
  2XLARGE       = 40 clusters max
  3XLARGE       = 20 clusters max
  4XL-6XL       = 10 clusters max

Credit Usage = (size credits/hour) x (number of running clusters)
*/

-- Create an Auto-scale multi-cluster warehouse
CREATE WAREHOUSE concurrency_wh
  WAREHOUSE_SIZE = 'MEDIUM'
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 5
  SCALING_POLICY = 'STANDARD'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE;

-- Create a Maximized multi-cluster warehouse
CREATE WAREHOUSE peak_hours_wh
  WAREHOUSE_SIZE = 'LARGE'
  MIN_CLUSTER_COUNT = 3
  MAX_CLUSTER_COUNT = 3
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE;

-- Change scaling policy
ALTER WAREHOUSE concurrency_wh SET SCALING_POLICY = 'ECONOMY';

-- ============================================================================
-- SECTION 3: WAREHOUSE SIZING GUIDE - WHEN TO USE WHICH SIZE
-- ============================================================================

/*
┌────────────┬──────────────────────────────────────────────────────────────┐
│ Size       │ Best For                                                     │
├────────────┼──────────────────────────────────────────────────────────────┤
│ XS / S     │ Dev/test, Snowsight UI queries, simple lookups, light ETL    │
│ M          │ Moderate analytics, dashboard queries, standard ETL          │
│ L          │ Complex joins, large aggregations, production ETL            │
│ XL         │ Heavy analytics, large table scans, concurrent workloads     │
│ 2XL+       │ Very large data processing, complex ML, bulk operations      │
└────────────┴──────────────────────────────────────────────────────────────┘

Decision Framework:
  1. Start with size M or L for production workloads
  2. Monitor query spilling, queue time, execution time
  3. Scale UP if queries spill to disk or take too long
  4. Scale OUT (multi-cluster) if queries queue due to concurrency
  5. Use QAS for outlier queries instead of upsizing the whole warehouse
*/

-- ============================================================================
-- SECTION 4: KEY WAREHOUSE PROPERTIES & CONFIGURATION
-- ============================================================================

-- Full warehouse creation with all important properties
CREATE WAREHOUSE production_wh
  WAREHOUSE_SIZE = 'LARGE'
  WAREHOUSE_TYPE = 'STANDARD'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 3
  SCALING_POLICY = 'STANDARD'
  ENABLE_QUERY_ACCELERATION = TRUE
  QUERY_ACCELERATION_MAX_SCALE_FACTOR = 8
  STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 600
  STATEMENT_TIMEOUT_IN_SECONDS = 3600
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Production analytics warehouse';

-- ============================================================================
-- SECTION 5: QUERY ACCELERATION SERVICE (QAS)
-- ============================================================================

/*
QAS offloads portions of query processing to serverless compute.
Best for:
  - Ad-hoc analytics
  - Queries with large scans and selective filters
  - Outlier queries that use more resources than typical ones

Scale Factor:
  - Multiplier of warehouse credit consumption rate
  - Higher = more acceleration possible = more potential cost
  - 0 = unlimited (maximize performance)
*/

-- Enable QAS
ALTER WAREHOUSE production_wh SET
  ENABLE_QUERY_ACCELERATION = TRUE
  QUERY_ACCELERATION_MAX_SCALE_FACTOR = 8;

-- Check if a specific query benefits from QAS
SELECT PARSE_JSON(SYSTEM$ESTIMATE_QUERY_ACCELERATION('your-query-id-here'));

-- Find best QAS candidates in past 7 days
SELECT query_id, eligible_query_acceleration_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_ELIGIBLE
WHERE start_time > DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY eligible_query_acceleration_time DESC
LIMIT 20;

-- Find warehouses that benefit most from QAS
SELECT warehouse_name, SUM(eligible_query_acceleration_time) AS total_eligible_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_ELIGIBLE
WHERE start_time > DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_eligible_time DESC;

-- ============================================================================
-- SECTION 6: WAREHOUSE MANAGEMENT OPERATIONS
-- ============================================================================

-- Suspend a warehouse
ALTER WAREHOUSE production_wh SUSPEND;

-- Resume a warehouse
ALTER WAREHOUSE production_wh RESUME;

-- Resize a running warehouse (immediate for new queries)
ALTER WAREHOUSE production_wh SET WAREHOUSE_SIZE = 'XLARGE';

-- Change auto-suspend timeout
ALTER WAREHOUSE production_wh SET AUTO_SUSPEND = 60;

-- View all warehouses
SHOW WAREHOUSES;

-- View specific warehouse details
SHOW WAREHOUSES LIKE 'production_wh';

-- Drop a warehouse
DROP WAREHOUSE IF EXISTS temp_testing_wh;

-- ============================================================================
-- SECTION 7: PRODUCTION-LEVEL PROBLEMS AND SOLUTIONS
-- ============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 1: Queries are queuing during peak hours
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: Users report slow response times during business hours.
Root Cause: Single-cluster warehouse cannot handle concurrent load.

Solution: Convert to multi-cluster with auto-scale.
*/

ALTER WAREHOUSE reporting_wh SET
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 6
  SCALING_POLICY = 'STANDARD';

-- Monitor queue depth
SELECT
    warehouse_name,
    AVG(avg_running) AS avg_running_queries,
    AVG(avg_queued_load) AS avg_queued_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time > DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
HAVING AVG(avg_queued_load) > 0
ORDER BY avg_queued_queries DESC;

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 2: Queries spilling to local/remote storage
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: Queries run slowly, QUERY_HISTORY shows bytes_spilled_to_local_storage
           or bytes_spilled_to_remote_storage > 0.
Root Cause: Warehouse does not have enough memory for the operation.

Solutions:
  1. Increase warehouse size (more memory per node)
  2. Optimize the query (reduce data scanned)
  3. For Snowpark workloads, use Snowpark-Optimized warehouse
*/

-- Find queries with spilling
SELECT
    query_id,
    warehouse_name,
    warehouse_size,
    execution_time / 1000 AS exec_seconds,
    bytes_spilled_to_local_storage / (1024*1024*1024) AS gb_spilled_local,
    bytes_spilled_to_remote_storage / (1024*1024*1024) AS gb_spilled_remote
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time > DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND (bytes_spilled_to_local_storage > 0 OR bytes_spilled_to_remote_storage > 0)
ORDER BY bytes_spilled_to_remote_storage DESC
LIMIT 20;

-- Solution: Resize the warehouse
ALTER WAREHOUSE analytics_wh SET WAREHOUSE_SIZE = 'XLARGE';

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 3: Warehouse costs are too high
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: Monthly credit consumption much higher than expected.
Root Causes:
  - Warehouses running when idle (auto-suspend too high or disabled)
  - Warehouse oversized for the workload
  - Multi-cluster scaling too aggressively

Solutions:
*/

-- Check warehouse usage patterns
SELECT
    warehouse_name,
    SUM(credits_used) AS total_credits,
    COUNT(DISTINCT DATE_TRUNC('day', start_time)) AS active_days,
    SUM(credits_used) / COUNT(DISTINCT DATE_TRUNC('day', start_time)) AS avg_daily_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time > DATEADD('month', -1, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- Reduce auto-suspend to 60 seconds for intermittent workloads
ALTER WAREHOUSE dev_wh SET AUTO_SUSPEND = 60;

-- Use ECONOMY scaling policy to reduce multi-cluster costs
ALTER WAREHOUSE reporting_wh SET SCALING_POLICY = 'ECONOMY';

-- Set resource monitors
CREATE RESOURCE MONITOR monthly_monitor
  WITH CREDIT_QUOTA = 1000
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 90 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE production_wh SET RESOURCE_MONITOR = monthly_monitor;

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 4: ETL jobs running too slowly
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: Nightly ETL batch doesn't complete within the SLA window.
Root Cause: Warehouse undersized OR poor query optimization.

Solutions:
  1. Increase warehouse size for the ETL window
  2. Convert to Gen2 for DML improvements (DELETE, UPDATE, MERGE)
  3. Break ETL into parallel tasks using multiple warehouses
*/

-- Temporarily upsize for ETL window
ALTER WAREHOUSE etl_wh SET WAREHOUSE_SIZE = '2XLARGE';

-- After ETL completes, resize back
ALTER WAREHOUSE etl_wh SET WAREHOUSE_SIZE = 'MEDIUM';

-- Better: Use Gen2 for DML-heavy ETL
ALTER WAREHOUSE etl_wh SET GENERATION = '2';

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 5: One bad query affecting all users
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: A single complex ad-hoc query consumes all warehouse resources,
           causing other queries to queue.

Solutions:
  1. Set statement timeouts
  2. Enable QAS to offload heavy queries
  3. Use separate warehouses for ad-hoc vs production
  4. Use resource monitors
*/

-- Set query timeout (kill queries running > 30 minutes)
ALTER WAREHOUSE shared_wh SET STATEMENT_TIMEOUT_IN_SECONDS = 1800;

-- Set queue timeout (don't wait more than 5 minutes)
ALTER WAREHOUSE shared_wh SET STATEMENT_QUEUED_TIMEOUT_IN_SECONDS = 300;

-- Create separate warehouse for ad-hoc queries
CREATE WAREHOUSE adhoc_wh
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 600;

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 6: Data loading is slow
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: COPY INTO takes very long despite using a large warehouse.
Root Cause: Data loading performance depends more on FILE COUNT and FILE SIZE
             than warehouse size.

Best Practices:
  - Use files sized 100-250 MB (compressed)
  - Use multiple files for parallel loading
  - Small/Medium warehouse is usually sufficient
  - Larger warehouse helps ONLY with many concurrent files

  DETAILED EXPLANATION - Loading Performance:
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │ HOW SNOWFLAKE LOADS DATA INTERNALLY                                         │
  │                                                                             │
  │ Warehouse nodes pick up files one-by-one from the stage.                    │
  │ More nodes (bigger WH) = more files processed in parallel.                  │
  │ But a SINGLE large file is processed by ONE node — it can't be split.       │
  └─────────────────────────────────────────────────────────────────────────────┘

  ┌────────────────────────────────┬──────────────────┬──────────────────────────┐
  │ Scenario                       │ What Helps        │ Why                      │
  ├────────────────────────────────┼──────────────────┼──────────────────────────┤
  │ 1000 files × 100MB each        │ Larger warehouse │ More nodes pick up more  │
  │                                │                  │ files in parallel        │
  ├────────────────────────────────┼──────────────────┼──────────────────────────┤
  │ 5 files × 10GB each            │ Split into       │ One huge file = one node │
  │                                │ smaller files    │ can't parallelize it     │
  ├────────────────────────────────┼──────────────────┼──────────────────────────┤
  │ Multiple COPY commands from    │ Multi-cluster    │ Each COPY statement gets │
  │ different users/jobs running   │ warehouse        │ its own cluster          │
  │ at the same time               │                  │                          │
  └────────────────────────────────┴──────────────────┴──────────────────────────┘

  KEY INSIGHT:
  - Larger warehouse  = more NODES  = more FILES loaded simultaneously
  - Multi-cluster WH  = more CLUSTERS = more COPY COMMANDS run concurrently
  - Neither helps with ONE big file → you must SPLIT it first (100-250 MB each)

  Example:
    Bad:  1 file × 50GB on XL warehouse → 1 node works, others idle
    Good: 500 files × 100MB on Medium warehouse → all nodes busy in parallel
*/

-- Optimal loading configuration
CREATE WAREHOUSE loading_wh
  WAREHOUSE_SIZE = 'SMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 7: Warehouse takes long to resume
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: Queries delayed because warehouse takes time to provision.
Root Cause: Cold start after suspension.

Solutions:
  1. Keep warehouse running if queries are frequent (increase auto-suspend)
  2. Use multi-cluster with MIN_CLUSTER_COUNT > 0
  3. Gen2 uses warmed cache of servers (may help)
  4. For critical workloads, set AUTO_SUSPEND high enough to bridge gaps
*/

-- Keep at least one cluster always running
ALTER WAREHOUSE critical_wh SET
  MIN_CLUSTER_COUNT = 1
  AUTO_SUSPEND = 0;  -- Never suspend (use cautiously!)

-- ─────────────────────────────────────────────────────────────────────────────
-- PROBLEM 8: Isolating workloads for cost attribution
-- ─────────────────────────────────────────────────────────────────────────────

/*
Symptoms: Cannot determine which team/project is consuming credits.
Solution: Create dedicated warehouses per team/project.
*/

CREATE WAREHOUSE team_data_eng_wh
  WAREHOUSE_SIZE = 'LARGE'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  COMMENT = 'Data Engineering team warehouse';

CREATE WAREHOUSE team_analytics_wh
  WAREHOUSE_SIZE = 'MEDIUM'
  AUTO_SUSPEND = 120
  AUTO_RESUME = TRUE
  COMMENT = 'Analytics team warehouse';

CREATE WAREHOUSE team_datascience_wh
  WAREHOUSE_SIZE = 'MEDIUM'
  WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE
  COMMENT = 'Data Science team ML warehouse';

-- Query credit usage per warehouse (team)
SELECT
    warehouse_name,
    DATE_TRUNC('week', start_time) AS week,
    SUM(credits_used) AS weekly_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time > DATEADD('month', -3, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, week
ORDER BY warehouse_name, week;

-- ============================================================================
-- SECTION 8: MONITORING AND OPTIMIZATION QUERIES
-- ============================================================================

-- Credit usage by warehouse (last 30 days)
SELECT
    warehouse_name,
    SUM(credits_used) AS total_credits,
    SUM(credits_used_compute) AS compute_credits,
    SUM(credits_used_cloud_services) AS cloud_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time > DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;

-- Warehouse utilization (are warehouses running idle?)
SELECT
    warehouse_name,
    SUM(credits_used) AS credits,
    COUNT(*) AS metering_intervals,
    AVG(credits_used) AS avg_credits_per_interval
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time > DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY credits DESC;

-- Find long-running queries
SELECT
    query_id,
    user_name,
    warehouse_name,
    execution_time / 1000 AS exec_seconds,
    query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time > DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND execution_time > 300000  -- > 5 minutes
ORDER BY execution_time DESC
LIMIT 20;

-- Identify warehouses with high queue times
SELECT
    warehouse_name,
    AVG(queued_overload_time) / 1000 AS avg_queue_seconds,
    MAX(queued_overload_time) / 1000 AS max_queue_seconds,
    COUNT(*) AS query_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time > DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND queued_overload_time > 0
GROUP BY warehouse_name
ORDER BY avg_queue_seconds DESC;

-- ============================================================================
-- SECTION 9: WAREHOUSE STRATEGY PATTERNS
-- ============================================================================

/*
PATTERN 1: T-Shirt Sizing Strategy
  - XS: Development, testing, Snowsight UI
  - S/M: Reporting dashboards, light analytics
  - L/XL: Production ETL, heavy analytics
  - 2XL+: Bulk historical loads, complex transformations

PATTERN 2: Workload Isolation
  - Separate warehouses for: ETL, Reporting, Ad-hoc, Data Science
  - Prevents resource contention between workloads
  - Enables per-team cost attribution

PATTERN 3: Time-Based Scaling
  - Small warehouse during off-hours
  - Large warehouse during business hours / ETL windows
  - Automate with Snowflake Tasks or external orchestration

PATTERN 4: Multi-Cluster for BI Tools
  - BI tools (Tableau, PowerBI) create many concurrent sessions
  - Multi-cluster with auto-scale handles burst concurrency
  - Standard scaling policy prevents query queuing
*/

-- ============================================================================
-- SECTION 10: INTERVIEW QUESTIONS - BEGINNER TO ARCHITECT
-- ============================================================================

/*
═══════════════════════════════════════════════════════════════════════════════
BEGINNER LEVEL
═══════════════════════════════════════════════════════════════════════════════

Q1: What is a Virtual Warehouse in Snowflake?
A: A virtual warehouse is a cluster of compute resources (CPU, memory, temp 
   storage) used to execute queries and DML operations. It does NOT store data.

Q2: Does a warehouse store data?
A: No. Warehouses provide compute only. Data is stored in Snowflake's 
   centralized storage layer, separate from compute.

Q3: What happens when a warehouse is suspended?
A: All compute resources are released, no credits are consumed, and the 
   local cache is dropped. Running queries will complete first.

Q4: What is auto-suspend and auto-resume?
A: Auto-suspend automatically stops the warehouse after a period of 
   inactivity. Auto-resume automatically starts it when a new query arrives.

Q5: What is the minimum billing time when a warehouse starts?
A: 60 seconds. After the first 60 seconds, billing is per-second.

Q6: What are the warehouse sizes available?
A: XS, S, M, L, XL, 2XL, 3XL, 4XL, 5XL, 6XL. Each size doubles 
   the compute resources and credits of the previous size.

Q7: Can you resize a running warehouse?
A: Yes. New resources are used for new/queued queries; currently running 
   queries continue on existing resources.

═══════════════════════════════════════════════════════════════════════════════
INTERMEDIATE LEVEL
═══════════════════════════════════════════════════════════════════════════════

Q8: What is the difference between scaling UP and scaling OUT?
A: Scale UP = increase warehouse size (more resources per node, better for 
   complex queries). Scale OUT = add clusters via multi-cluster warehouse 
   (better for concurrency).

Q9: What is a multi-cluster warehouse?
A: A warehouse with multiple clusters that can scale out to handle more 
   concurrent queries. Available in Enterprise Edition and above.

Q10: Explain Auto-scale vs Maximized mode in multi-cluster warehouses.
A: Auto-scale: Clusters start/stop dynamically based on load (MIN < MAX).
   Maximized: All clusters run at all times (MIN = MAX > 1).

Q11: What are the scaling policies? When would you use each?
A: STANDARD: Starts clusters aggressively to prevent queuing (default).
   ECONOMY: Only starts clusters if 6+ minutes of work exists (saves credits).
   Use STANDARD for latency-sensitive BI; ECONOMY for batch/background work.

Q12: What is Query Acceleration Service (QAS)?
A: QAS offloads portions of query processing to serverless compute resources.
   Best for outlier queries with large scans and selective filters.

Q13: What is a Snowpark-Optimized warehouse?
A: A warehouse type with up to 16x more memory per node than standard.
   Designed for ML training, large UDFs, and memory-intensive Snowpark workloads.

Q14: How does warehouse caching work?
A: Running warehouses cache table data. This improves performance for 
   repeated queries. The cache is dropped when the warehouse is suspended.

Q15: What is the difference between Gen1 and Gen2 warehouses?
A: Gen2 has upgraded hardware and software optimizations delivering better 
   performance (especially DML operations). Gen2 is a performance feature, 
   not a cost-saving feature. Sizes limited to XS through 4XL.

Q16: Can you convert a Gen1 warehouse to Gen2 without downtime?
A: Yes. ALTER WAREHOUSE my_wh SET GENERATION = '2'; performs a live migration.

Q17: What is RESOURCE_MONITOR?
A: A governance object that tracks credit consumption and can notify or 
   suspend warehouses when thresholds are reached.

═══════════════════════════════════════════════════════════════════════════════
ADVANCED LEVEL
═══════════════════════════════════════════════════════════════════════════════

Q18: How would you design a warehouse strategy for a company with ETL, 
     reporting, ad-hoc analytics, and data science teams?
A: Create separate warehouses per workload:
   - ETL: Large/XL Gen2, auto-suspend=300 (long-running transforms)
   - Reporting: Medium multi-cluster auto-scale (concurrency for BI tools)
   - Ad-hoc: Small with timeout limits (prevent runaway queries)
   - Data Science: Snowpark-Optimized Medium (ML training memory needs)
   This enables workload isolation, cost attribution, and independent scaling.

Q19: A dashboard refreshes slowly during peak hours. How do you troubleshoot?
A: 1. Check WAREHOUSE_LOAD_HISTORY for queue depth
   2. Check QUERY_HISTORY for query execution times
   3. If queuing: add clusters (multi-cluster) or separate workloads
   4. If slow execution: check spilling, consider upsizing or Gen2
   5. If cache misses: check auto-suspend isn't too aggressive
   6. Enable QAS for outlier queries

Q20: What factors determine the credit cost of a query?
A: Credits depend on: warehouse size, number of clusters running, and time 
   the warehouse runs (per-second billing). NOT on data scanned or rows 
   returned. A query on an XL warehouse for 10 seconds costs the same 
   whether it scans 1 row or 1 billion rows.

Q21: When would you choose Snowpark-Optimized over Standard?
A: When workloads need large memory (ML training, complex UDFs).
   Standard: 16GB memory per node (MEMORY_1X equivalent).
   Snowpark-Optimized: Up to 256GB (MEMORY_16X) or 1TB (MEMORY_64X).

Q22: Explain the billing during a Gen1 to Gen2 conversion on a running WH.
A: During conversion, existing queries continue on Gen1 resources and new 
   queries use Gen2 resources. Both are billed simultaneously during the 
   overlap period until Gen1 queries finish.

Q23: How does statement timeout differ from queued timeout?
A: STATEMENT_TIMEOUT_IN_SECONDS: Max time a query can EXECUTE.
   STATEMENT_QUEUED_TIMEOUT_IN_SECONDS: Max time a query can WAIT in queue.
   Both help prevent resource hogging and improve user experience.

Q24: What is the relationship between warehouse size and data loading?
A: Larger warehouses do NOT always load data faster. Loading performance 
   depends on file count and file sizes. Use 100-250 MB compressed files 
   and a Small/Medium warehouse for most loads.

═══════════════════════════════════════════════════════════════════════════════
ARCHITECT / EXPERT LEVEL
═══════════════════════════════════════════════════════════════════════════════

Q25: Design a complete warehouse strategy for a global enterprise with:
     - 500 analysts across 3 time zones
     - Nightly ETL of 10TB
     - Real-time dashboards
     - ML/AI workloads
     - Strict cost governance

A: Architecture:
   1. ETL Tier:
      - 2XL Gen2 warehouse (DML improvements for MERGE/UPDATE)
      - Auto-suspend=300, runs during ETL window
      - Task-based orchestration to resize dynamically
   
   2. Reporting Tier:
      - Medium multi-cluster, MAX_CLUSTER=10, STANDARD scaling
      - Handles 500 concurrent BI users across time zones
      - Auto-scale naturally adjusts to peak per timezone
   
   3. Ad-Hoc Analytics:
      - Small/Medium per-region warehouses
      - STATEMENT_TIMEOUT=600, QUEUED_TIMEOUT=120
      - QAS enabled (scale_factor=5) for outlier queries
   
   4. Data Science:
      - Snowpark-Optimized Medium (MEMORY_16X) for training
      - Standard Small for inference/scoring
      - MAX_CONCURRENCY_LEVEL=1 during training
   
   5. Governance:
      - Resource monitors per warehouse (monthly quotas)
      - Separate warehouses per cost center for chargeback
      - Auto-suspend=60 for all non-critical warehouses
      - Tagging warehouses for cost attribution

Q26: What is Adaptive Compute and when would you recommend it over Gen2?
A: Adaptive Compute is a new warehouse type where Snowflake automatically 
   determines resource allocation per query. No sizing, no multi-cluster 
   config, no QAS management needed.
   
   Recommend Adaptive when:
   - Workloads are unpredictable or highly variable
   - Team lacks expertise to tune warehouse sizes
   - You want zero operational overhead for compute management
   
   Recommend Gen2 when:
   - You need precise control over compute resources
   - Workloads are well-understood and predictable
   - You want to benchmark against specific sizes

Q27: How would you handle a scenario where Gen2 warehouse resume is slower 
     than expected?
A: Gen2 uses a warmed cache of pre-warmed servers. The system monitors usage 
   patterns to determine pool size. If resume is degraded:
   1. Understand it's a characteristic of Gen2 architecture
   2. Check if usage patterns changed (less predictable = smaller warm pool)
   3. For critical latency needs: increase auto-suspend time to avoid 
      frequent resume cycles
   4. If persistent: contact Snowflake Support for pool tuning

Q28: Explain the trade-offs between warehouse cache and cost savings.
A: Suspending saves credits but drops cache. Resuming may have slower initial 
   queries (cold cache). The trade-off:
   - High auto-suspend (or never): Higher cost, warm cache, fast queries
   - Low auto-suspend: Lower cost, cold cache, slower first queries
   
   Strategy: Match auto-suspend to query gaps. If queries arrive every 
   2-3 min, set auto-suspend > 3 min to maintain cache between queries.

Q29: How would you migrate 50 warehouses from Gen1 to Gen2?
A: 1. Run SELECT CURRENT_REGION() to verify Gen2 availability
   2. Identify candidates via Snowsight Gen2 recommendations
   3. Filter out: Snowpark-Optimized, 5XL/6XL, Interactive types
   4. Start with non-critical warehouses for validation
   5. ALTER WAREHOUSE <name> SET GENERATION = '2' (live, no downtime)
   6. Monitor execution times, spilling, and credits for 1-2 weeks
   7. Rollback any that don't show improvement
   8. Document credit rate changes (Gen2 rates are higher per-hour but 
      queries finish faster)

Q30: Design a cost-optimization strategy for 100 warehouses consuming 
     50,000 credits/month.
A: 1. ANALYZE: Query WAREHOUSE_METERING_HISTORY to identify top consumers
   2. IDLE DETECTION: Find warehouses with high running time but low query 
      count — reduce auto-suspend
   3. RIGHT-SIZE: Check spilling (need bigger) vs low utilization (need smaller)
   4. CONSOLIDATE: Merge similar workloads into multi-cluster warehouses
   5. SCHEDULE: Use tasks to resize warehouses for peak/off-peak
   6. QAS: Enable for warehouses with outlier queries (cheaper than upsizing)
   7. GOVERNANCE: Resource monitors with alerts at 75%/90%/100%
   8. Gen2: Convert eligible warehouses — faster execution = fewer total credits
   9. POLICY: Implement tagging and chargeback to create cost accountability
  10. REVIEW: Monthly review cycle with stakeholders

Q31: What are the limitations of multi-cluster warehouses?
A: - Enterprise Edition or higher required
   - Auto-suspend applies to the entire warehouse, not individual clusters
   - Auto-resume only works when ALL clusters are suspended
   - Resizing applies to ALL clusters simultaneously
   - Max cluster count varies by size (XS-M=300, L=160, XL=80, etc.)
   - Not designed for improving individual query performance (that's sizing)
   - Economy policy may still allow some queuing

Q32: Compare all warehouse types. When would each be the WRONG choice?
A: Standard Gen1:
   WRONG when: DML-heavy workloads, Gen2 is available in your region
   
   Standard Gen2:
   WRONG when: Need 5XL/6XL sizes, Snowpark-Optimized needed, 
               region doesn't support Gen2
   
   Snowpark-Optimized:
   WRONG when: Standard analytics/ETL workloads (doesn't benefit), 
               need Gen2 (not compatible)
   
   Adaptive:
   WRONG when: Need precise control over resources, 
               predictable fixed-cost budgeting needed
   
   Multi-Cluster:
   WRONG when: Trying to speed up individual slow queries (use sizing instead),
               Standard Edition account (not available)

Q33: How does per-second billing affect warehouse design decisions?
A: Per-second billing (with 60s minimum) means:
   - No penalty for using large warehouses briefly
   - Auto-suspend can be aggressive (60s is fine for most workloads)
   - "Burst" strategy is viable: upsize, run query, downsize
   - Don't fear large warehouses — a 4XL running 30 seconds costs less 
     than a Medium running 10 minutes
   - Design for performance first, then optimize cost

Q34: How do you implement warehouse-level security and access control?
A: Warehouse privileges:
   - USAGE: Can use the warehouse to run queries
   - OPERATE: Can start/stop/resize the warehouse
   - MONITOR: Can view warehouse activity and history
   - MODIFY: Can change warehouse properties
   - OWNERSHIP: Full control
   
   Strategy:
   - Grant USAGE to functional roles (ANALYST, ENGINEER)
   - Grant OPERATE to team leads
   - Grant MONITOR to FinOps/Admins
   - Use OWNERSHIP for warehouse administrators only

Q35: Explain the architecture of Snowflake's compute layer and how 
     warehouses fit into the overall system.
A: Snowflake's 3-layer architecture:
   1. Storage Layer: Centralized, columnar, compressed micro-partitions
   2. Compute Layer: Virtual warehouses (independent, scalable clusters)
   3. Cloud Services: Metadata, optimization, security, transactions
   
   Warehouses in compute layer:
   - Completely independent of storage (shared-nothing compute)
   - Multiple warehouses can query same data simultaneously
   - No contention between warehouses (isolation)
   - Each warehouse has its own local SSD cache
   - Cloud services coordinates metadata and query planning
   - This separation enables instant elasticity and concurrency
*/

-- ============================================================================
-- END OF GUIDE
-- ============================================================================
