-- ============================================================
-- WAREHOUSE MONITORING & TUNING IN SNOWFLAKE
-- Production-Level Guide for Cost vs Performance Optimization
-- ============================================================

-- ============================================================
-- WHY WAREHOUSE TUNING MATTERS IN PRODUCTION
-- ============================================================
/*
In production environments:
- Over-sized warehouses waste money (paying for unused compute)
- Under-sized warehouses cause slow queries, timeouts, queueing
- Unmonitored warehouses can run 24/7 burning credits silently
- Poor auto-suspend settings leave warehouses idle but billing

Real cost impact:
  XS = 1 credit/hour   ≈ $3/hour
  S  = 2 credits/hour  ≈ $6/hour
  M  = 4 credits/hour  ≈ $12/hour
  L  = 8 credits/hour  ≈ $24/hour
  XL = 16 credits/hour ≈ $48/hour
  2XL = 32 credits/hour ≈ $96/hour
  3XL = 64 credits/hour ≈ $192/hour
  4XL = 128 credits/hour ≈ $384/hour

A medium warehouse left running 24/7 = ~$8,640/month
Same warehouse with proper auto-suspend = fraction of that
*/


-- ============================================================
-- SECTION 1: PRODUCTION WAREHOUSE ARCHITECTURE
-- ============================================================
-- In production, separate warehouses by workload type

-- ETL/ELT Warehouse: handles data loading pipelines
CREATE OR REPLACE WAREHOUSE ETL_WH
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 60            -- Suspend after 1 min idle (ETL is bursty)
    AUTO_RESUME = TRUE
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 3        -- Scale out for parallel loads
    SCALING_POLICY = 'STANDARD'
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'ETL pipeline processing - nightly and hourly loads';

-- Reporting/BI Warehouse: handles dashboards and reports
CREATE OR REPLACE WAREHOUSE REPORTING_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 300           -- 5 min (users may run back-to-back reports)
    AUTO_RESUME = TRUE
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 5        -- Scale for concurrent dashboard users
    SCALING_POLICY = 'STANDARD'
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'BI dashboards and scheduled reports';

-- Ad-hoc/Analyst Warehouse: data analysts exploring data
CREATE OR REPLACE WAREHOUSE ANALYST_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 120           -- 2 min (analysts pause between queries)
    AUTO_RESUME = TRUE
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 2
    SCALING_POLICY = 'ECONOMY'   -- Economy: wait longer before scaling out
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Ad-hoc analyst queries and exploration';

-- Data Science Warehouse: ML model training, heavy transforms
CREATE OR REPLACE WAREHOUSE DS_WH
    WAREHOUSE_SIZE = 'LARGE'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 1        -- No multi-cluster (single heavy jobs)
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Data science model training and feature engineering';

-- Application/API Warehouse: serving application queries
CREATE OR REPLACE WAREHOUSE APP_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 30            -- 30 sec (short transactional queries)
    AUTO_RESUME = TRUE
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 10       -- High concurrency for app traffic
    SCALING_POLICY = 'STANDARD'
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Application backend queries - low latency required';


-- ============================================================
-- SECTION 2: MONITORING WAREHOUSE CREDIT CONSUMPTION
-- ============================================================

-- 2A: Daily credit usage by warehouse (last 30 days)
SELECT
    warehouse_name,
    DATE_TRUNC('DAY', start_time) AS usage_date,
    SUM(credits_used) AS credits_consumed,
    SUM(credits_used) * 3 AS estimated_cost_usd,  -- Adjust rate per contract
    COUNT(DISTINCT query_id) AS query_count
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, usage_date
ORDER BY warehouse_name, usage_date DESC;


-- 2B: Weekly credit trend by warehouse (spot increases)
SELECT
    warehouse_name,
    DATE_TRUNC('WEEK', start_time) AS week_start,
    SUM(credits_used) AS weekly_credits,
    LAG(SUM(credits_used)) OVER (
        PARTITION BY warehouse_name ORDER BY DATE_TRUNC('WEEK', start_time)
    ) AS prev_week_credits,
    ROUND(
        (SUM(credits_used) - LAG(SUM(credits_used)) OVER (
            PARTITION BY warehouse_name ORDER BY DATE_TRUNC('WEEK', start_time)
        )) / NULLIF(LAG(SUM(credits_used)) OVER (
            PARTITION BY warehouse_name ORDER BY DATE_TRUNC('WEEK', start_time)
        ), 0) * 100, 2
    ) AS week_over_week_pct_change
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('WEEK', -12, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, week_start
ORDER BY warehouse_name, week_start DESC;


-- 2C: Top 10 most expensive warehouses this month
SELECT
    warehouse_name,
    SUM(credits_used) AS total_credits,
    SUM(credits_used) * 3 AS estimated_cost_usd,
    ROUND(SUM(credits_used) / SUM(SUM(credits_used)) OVER () * 100, 2) AS pct_of_total
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC
LIMIT 10;


-- 2D: Hourly usage pattern (find peak hours for scheduling)
SELECT
    warehouse_name,
    HOUR(start_time) AS hour_of_day,
    ROUND(AVG(credits_used), 4) AS avg_hourly_credits,
    COUNT(*) AS data_points
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('DAY', -14, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, hour_of_day
ORDER BY warehouse_name, hour_of_day;


-- ============================================================
-- SECTION 3: QUERY PERFORMANCE ANALYSIS
-- ============================================================

-- 3A: Identify slow queries (candidates for warehouse upsizing)
SELECT
    query_id,
    warehouse_name,
    warehouse_size,
    user_name,
    query_type,
    total_elapsed_time / 1000 AS elapsed_seconds,
    execution_time / 1000 AS execution_seconds,
    queued_overload_time / 1000 AS queue_seconds,
    bytes_scanned / POWER(1024, 3) AS gb_scanned,
    bytes_spilled_to_local_storage / POWER(1024, 3) AS gb_spilled_local,
    bytes_spilled_to_remote_storage / POWER(1024, 3) AS gb_spilled_remote,
    partitions_scanned,
    partitions_total,
    ROUND((1 - partitions_scanned / NULLIF(partitions_total, 0)) * 100, 2) AS pruning_pct,
    query_text
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND total_elapsed_time > 60000  -- Queries taking > 60 seconds
    AND query_type IN ('SELECT', 'INSERT', 'CREATE_TABLE_AS_SELECT', 'MERGE')
    AND execution_status = 'SUCCESS'
ORDER BY total_elapsed_time DESC
LIMIT 50;


-- 3B: Queries that SPILL to storage (need bigger warehouse)
/*
SPILLING means the warehouse didn't have enough memory/SSD,
so data was written to slower storage. This is a strong signal
that the warehouse is TOO SMALL for that workload.
*/
SELECT
    warehouse_name,
    warehouse_size,
    COUNT(*) AS spill_count,
    SUM(bytes_spilled_to_local_storage) / POWER(1024, 3) AS total_gb_spilled_local,
    SUM(bytes_spilled_to_remote_storage) / POWER(1024, 3) AS total_gb_spilled_remote,
    AVG(total_elapsed_time) / 1000 AS avg_elapsed_seconds,
    AVG(bytes_scanned) / POWER(1024, 3) AS avg_gb_scanned
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND (bytes_spilled_to_local_storage > 0 OR bytes_spilled_to_remote_storage > 0)
    AND execution_status = 'SUCCESS'
GROUP BY warehouse_name, warehouse_size
ORDER BY total_gb_spilled_remote DESC;


-- 3C: Queue time analysis (warehouse is overloaded / needs multi-cluster)
/*
QUEUED_OVERLOAD_TIME > 0 means queries are WAITING because the
warehouse is busy. Solutions:
- Enable multi-cluster and increase MAX_CLUSTER_COUNT
- Or size up the warehouse
*/
SELECT
    warehouse_name,
    warehouse_size,
    COUNT(*) AS queued_query_count,
    AVG(queued_overload_time) / 1000 AS avg_queue_seconds,
    MAX(queued_overload_time) / 1000 AS max_queue_seconds,
    SUM(queued_overload_time) / 1000 / 60 AS total_queue_minutes,
    AVG(total_elapsed_time) / 1000 AS avg_total_elapsed_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND queued_overload_time > 0
    AND execution_status = 'SUCCESS'
GROUP BY warehouse_name, warehouse_size
ORDER BY total_queue_minutes DESC;


-- 3D: Query concurrency by hour (plan cluster scaling)
SELECT
    warehouse_name,
    DATE_TRUNC('HOUR', start_time) AS hour_bucket,
    COUNT(*) AS queries_in_hour,
    COUNT(DISTINCT user_name) AS unique_users,
    AVG(total_elapsed_time) / 1000 AS avg_elapsed_sec,
    MAX(total_elapsed_time) / 1000 AS max_elapsed_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
GROUP BY warehouse_name, hour_bucket
HAVING queries_in_hour > 10
ORDER BY warehouse_name, hour_bucket DESC;


-- ============================================================
-- SECTION 4: WAREHOUSE UTILIZATION & IDLE TIME ANALYSIS
-- ============================================================

-- 4A: Find warehouses that are OVER-PROVISIONED (paying for unused capacity)
/*
If a warehouse has very low average query load but is sized LARGE or XL,
it's wasting money.
*/
SELECT
    wh.warehouse_name,
    wh.warehouse_size,
    COUNT(qh.query_id) AS total_queries_7d,
    AVG(qh.total_elapsed_time) / 1000 AS avg_elapsed_sec,
    MAX(qh.total_elapsed_time) / 1000 AS max_elapsed_sec,
    AVG(qh.bytes_scanned) / POWER(1024, 3) AS avg_gb_scanned,
    MAX(qh.bytes_scanned) / POWER(1024, 3) AS max_gb_scanned,
    SUM(qh.bytes_spilled_to_remote_storage) AS total_remote_spill,
    CASE
        WHEN MAX(qh.total_elapsed_time) < 10000 AND wh.warehouse_size IN ('Large', 'X-Large', '2X-Large')
            THEN 'DOWNSIZE RECOMMENDED'
        WHEN SUM(qh.bytes_spilled_to_remote_storage) > 0
            THEN 'KEEP OR UPSIZE'
        WHEN AVG(qh.total_elapsed_time) < 5000 AND wh.warehouse_size NOT IN ('X-Small', 'Small')
            THEN 'CONSIDER DOWNSIZING'
        ELSE 'APPROPRIATE'
    END AS sizing_recommendation
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSES wh
LEFT JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY qh
    ON wh.warehouse_name = qh.warehouse_name
    AND qh.start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
WHERE wh.deleted_on IS NULL
GROUP BY wh.warehouse_name, wh.warehouse_size
ORDER BY total_queries_7d DESC;


-- 4B: Auto-suspend effectiveness (are warehouses suspending properly?)
SELECT
    warehouse_name,
    COUNT(*) AS resume_count_7d,
    SUM(credits_used) AS total_credits,
    AVG(credits_used) AS avg_credits_per_period,
    MIN(start_time) AS first_usage,
    MAX(end_time) AS last_usage
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
ORDER BY total_credits DESC;


-- 4C: Find warehouses running during off-hours (potential waste)
SELECT
    warehouse_name,
    DAYNAME(start_time) AS day_of_week,
    HOUR(start_time) AS hour_of_day,
    SUM(credits_used) AS credits_used,
    CASE
        WHEN DAYNAME(start_time) IN ('Sat', 'Sun') THEN 'WEEKEND'
        WHEN HOUR(start_time) NOT BETWEEN 6 AND 22 THEN 'OFF_HOURS'
        ELSE 'BUSINESS_HOURS'
    END AS time_category
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, day_of_week, hour_of_day
HAVING time_category != 'BUSINESS_HOURS' AND credits_used > 0
ORDER BY credits_used DESC
LIMIT 50;


-- ============================================================
-- SECTION 5: RESOURCE MONITORS (BUDGET GUARDRAILS)
-- ============================================================
/*
Resource monitors PREVENT runaway costs by setting credit limits.
In production, ALWAYS have resource monitors. They're your safety net.
*/

-- 5A: Account-level resource monitor (overall budget cap)
CREATE OR REPLACE RESOURCE MONITOR account_monthly_budget
    WITH CREDIT_QUOTA = 5000          -- 5000 credits/month max
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY        -- Alert at 75%
        ON 90 PERCENT DO NOTIFY        -- Alert at 90%
        ON 95 PERCENT DO SUSPEND       -- Suspend new queries at 95%
        ON 100 PERCENT DO SUSPEND_IMMEDIATE;  -- Kill running queries at 100%

-- Attach to account
ALTER ACCOUNT SET RESOURCE_MONITOR = account_monthly_budget;


-- 5B: Warehouse-level resource monitors (per-team budgets)
CREATE OR REPLACE RESOURCE MONITOR etl_budget
    WITH CREDIT_QUOTA = 2000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE ETL_WH SET RESOURCE_MONITOR = etl_budget;

CREATE OR REPLACE RESOURCE MONITOR reporting_budget
    WITH CREDIT_QUOTA = 500
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 80 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE REPORTING_WH SET RESOURCE_MONITOR = reporting_budget;

CREATE OR REPLACE RESOURCE MONITOR analyst_budget
    WITH CREDIT_QUOTA = 300
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE ANALYST_WH SET RESOURCE_MONITOR = analyst_budget;


-- 5C: Check resource monitor status
SHOW RESOURCE MONITORS;

-- Detailed usage against monitors
SELECT
    name,
    credit_quota,
    used_credits,
    remaining_credits,
    ROUND(used_credits / NULLIF(credit_quota, 0) * 100, 2) AS usage_pct,
    frequency,
    start_time,
    end_time
FROM TABLE(INFORMATION_SCHEMA.RESOURCE_MONITORS());


-- ============================================================
-- SECTION 6: AUTO-SUSPEND & AUTO-RESUME TUNING
-- ============================================================
/*
AUTO_SUSPEND: How many SECONDS idle before warehouse shuts down
AUTO_RESUME: Automatically start when a query arrives

PRODUCTION GUIDELINES:
┌──────────────────────┬─────────────────────┬──────────────────────────────┐
│ WORKLOAD TYPE        │ AUTO_SUSPEND        │ REASONING                    │
├──────────────────────┼─────────────────────┼──────────────────────────────┤
│ ETL/Batch            │ 60 seconds          │ Short gaps between jobs      │
│ Interactive/BI       │ 300 seconds (5 min) │ Users run queries in bursts  │
│ Application/API      │ 30 seconds          │ Fast queries, quick suspend  │
│ Ad-hoc Analysts      │ 120 seconds (2 min) │ Thinking time between runs   │
│ Data Science         │ 60 seconds          │ Long jobs then done          │
│ DevOps/CI-CD         │ 60 seconds          │ Automated, predictable       │
└──────────────────────┴─────────────────────┴──────────────────────────────┘

WARNING: Setting AUTO_SUSPEND = 0 means NEVER suspend (runs forever!)
MINIMUM: 60 seconds (cannot go lower)

COST OF RESUME: You pay for minimum 60 seconds each time warehouse resumes.
- If you set AUTO_SUSPEND = 60 and queries come every 90 seconds,
  you pay 60-sec resume cost each time → worse than keeping it running.
- Rule: If queries come more frequently than AUTO_SUSPEND interval,
  increase AUTO_SUSPEND to avoid repeated cold starts.
*/

-- Tune auto-suspend based on actual usage patterns
ALTER WAREHOUSE ETL_WH SET AUTO_SUSPEND = 60;
ALTER WAREHOUSE REPORTING_WH SET AUTO_SUSPEND = 300;
ALTER WAREHOUSE ANALYST_WH SET AUTO_SUSPEND = 120;
ALTER WAREHOUSE APP_WH SET AUTO_SUSPEND = 30;

-- Find the right auto-suspend by analyzing gaps between queries
SELECT
    warehouse_name,
    start_time,
    LAG(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time) AS prev_query_end,
    DATEDIFF('SECOND',
        LAG(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time),
        start_time
    ) AS gap_seconds
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND warehouse_name IS NOT NULL
    AND execution_status = 'SUCCESS'
QUALIFY gap_seconds IS NOT NULL;

-- Summarize gaps to find optimal auto-suspend
WITH query_gaps AS (
    SELECT
        warehouse_name,
        DATEDIFF('SECOND',
            LAG(end_time) OVER (PARTITION BY warehouse_name ORDER BY start_time),
            start_time
        ) AS gap_seconds
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
        AND warehouse_name IS NOT NULL
        AND execution_status = 'SUCCESS'
)
SELECT
    warehouse_name,
    COUNT(*) AS total_gaps,
    PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY gap_seconds) AS median_gap_sec,
    PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_seconds) AS p75_gap_sec,
    PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY gap_seconds) AS p90_gap_sec,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY gap_seconds) AS p95_gap_sec,
    CASE
        WHEN PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_seconds) < 60 THEN 'Set 300s (frequent queries)'
        WHEN PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap_seconds) < 300 THEN 'Set 120-180s'
        ELSE 'Set 60s (infrequent queries, suspend fast)'
    END AS suspend_recommendation
FROM query_gaps
WHERE gap_seconds > 0 AND gap_seconds < 3600  -- Ignore gaps > 1 hour
GROUP BY warehouse_name
ORDER BY warehouse_name;


-- ============================================================
-- SECTION 7: MULTI-CLUSTER WAREHOUSE TUNING
-- ============================================================
/*
Multi-cluster warehouses scale OUT (add more clusters) for concurrency.
They do NOT make individual queries faster — they handle MORE concurrent queries.

SCALING POLICIES:
- STANDARD: Starts new cluster immediately when queueing detected
            (best for latency-sensitive workloads)
- ECONOMY:  Waits 6 minutes before starting new cluster
            (best for cost-sensitive, can tolerate some queueing)
*/

-- Check if multi-cluster is being used effectively
SELECT
    warehouse_name,
    DATE_TRUNC('HOUR', start_time) AS hour_bucket,
    MAX(cluster_number) AS max_clusters_used,
    SUM(credits_used) AS credits_in_hour
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, hour_bucket
HAVING max_clusters_used > 1
ORDER BY max_clusters_used DESC
LIMIT 50;

-- If MAX_CLUSTER_COUNT is rarely reached, you may be paying too much
-- If it's ALWAYS at max, consider increasing it

-- Tune multi-cluster settings
-- High-concurrency reporting (many dashboard users)
ALTER WAREHOUSE REPORTING_WH SET
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 5
    SCALING_POLICY = 'STANDARD';

-- Cost-sensitive analyst workload (can wait a bit)
ALTER WAREHOUSE ANALYST_WH SET
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 2
    SCALING_POLICY = 'ECONOMY';


-- ============================================================
-- SECTION 8: WAREHOUSE SIZING EXPERIMENTS
-- ============================================================
/*
To find the right size, run the SAME query on different sizes and compare.
Snowflake's query result cache makes this tricky — use unique filters.

DOUBLING RULE:
Each size up doubles compute power AND cost:
- XS → S: 2x faster, 2x cost → same total credits per query
- S → M:  2x faster, 2x cost → same total credits per query
- Benefit: Faster wall-clock time (users wait less)
- Caveat: Only helps if query is compute-bound, not I/O or pruning bound
*/

-- Step 1: Create test warehouses (temporary, for benchmarking)
CREATE OR REPLACE WAREHOUSE BENCHMARK_XS WAREHOUSE_SIZE = 'XSMALL' AUTO_SUSPEND = 60 INITIALLY_SUSPENDED = TRUE;
CREATE OR REPLACE WAREHOUSE BENCHMARK_S  WAREHOUSE_SIZE = 'SMALL'  AUTO_SUSPEND = 60 INITIALLY_SUSPENDED = TRUE;
CREATE OR REPLACE WAREHOUSE BENCHMARK_M  WAREHOUSE_SIZE = 'MEDIUM' AUTO_SUSPEND = 60 INITIALLY_SUSPENDED = TRUE;

-- Step 2: Run your representative query on each (disable cache)
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

USE WAREHOUSE BENCHMARK_XS;
-- <run your query here, note the query_id>

USE WAREHOUSE BENCHMARK_S;
-- <run the same query, note the query_id>

USE WAREHOUSE BENCHMARK_M;
-- <run the same query, note the query_id>

-- Step 3: Compare results
SELECT
    query_id,
    warehouse_name,
    warehouse_size,
    total_elapsed_time / 1000 AS elapsed_sec,
    execution_time / 1000 AS exec_sec,
    bytes_spilled_to_local_storage / POWER(1024, 2) AS mb_spilled_local,
    bytes_spilled_to_remote_storage / POWER(1024, 2) AS mb_spilled_remote,
    credits_used_cloud_services
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE query_id IN ('<xs_query_id>', '<s_query_id>', '<m_query_id>')
ORDER BY warehouse_size;

/*
DECISION FRAMEWORK:
- If no spilling on XS → stay XS (cheapest)
- If spilling on XS but not S → use S
- If queries take > 30s on S and users need faster → use M
- If spilling on M → something else is wrong (bad query, no pruning)
*/

-- Cleanup
DROP WAREHOUSE IF EXISTS BENCHMARK_XS;
DROP WAREHOUSE IF EXISTS BENCHMARK_S;
DROP WAREHOUSE IF EXISTS BENCHMARK_M;

ALTER SESSION SET USE_CACHED_RESULT = TRUE;


-- ============================================================
-- SECTION 9: PRODUCTION MONITORING DASHBOARD QUERIES
-- ============================================================

-- 9A: Daily health summary (run this every morning)
SELECT
    CURRENT_DATE() AS report_date,
    warehouse_name,
    SUM(credits_used) AS credits_today,
    (SELECT SUM(credits_used)
     FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
     WHERE warehouse_name = wmh.warehouse_name
       AND DATE_TRUNC('DAY', start_time) = DATEADD('DAY', -1, CURRENT_DATE())
    ) AS credits_yesterday,
    ROUND(
        (SUM(credits_used) -
            (SELECT SUM(credits_used)
             FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
             WHERE warehouse_name = wmh.warehouse_name
               AND DATE_TRUNC('DAY', start_time) = DATEADD('DAY', -1, CURRENT_DATE()))
        ) / NULLIF(
            (SELECT SUM(credits_used)
             FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
             WHERE warehouse_name = wmh.warehouse_name
               AND DATE_TRUNC('DAY', start_time) = DATEADD('DAY', -1, CURRENT_DATE()))
        , 0) * 100, 2
    ) AS day_over_day_pct_change
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY wmh
WHERE DATE_TRUNC('DAY', start_time) = CURRENT_DATE()
GROUP BY warehouse_name
ORDER BY credits_today DESC;


-- 9B: Failed queries by warehouse (detect broken pipelines)
SELECT
    warehouse_name,
    error_code,
    error_message,
    COUNT(*) AS failure_count,
    MIN(start_time) AS first_failure,
    MAX(start_time) AS last_failure
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -1, CURRENT_TIMESTAMP())
    AND execution_status = 'FAIL'
    AND warehouse_name IS NOT NULL
GROUP BY warehouse_name, error_code, error_message
ORDER BY failure_count DESC
LIMIT 20;


-- 9C: Query execution time percentiles by warehouse
SELECT
    warehouse_name,
    warehouse_size,
    COUNT(*) AS query_count,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p50_sec,
    ROUND(PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p75_sec,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p90_sec,
    ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p95_sec,
    ROUND(PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY total_elapsed_time) / 1000, 2) AS p99_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND execution_status = 'SUCCESS'
    AND warehouse_name IS NOT NULL
GROUP BY warehouse_name, warehouse_size
ORDER BY query_count DESC;


-- 9D: Credit consumption forecast (simple linear projection)
WITH daily_usage AS (
    SELECT
        DATE_TRUNC('DAY', start_time) AS usage_date,
        SUM(credits_used) AS daily_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
    WHERE start_time >= DATE_TRUNC('MONTH', CURRENT_TIMESTAMP())
    GROUP BY usage_date
)
SELECT
    SUM(daily_credits) AS month_to_date_credits,
    AVG(daily_credits) AS avg_daily_credits,
    AVG(daily_credits) * DAY(LAST_DAY(CURRENT_DATE())) AS projected_monthly_credits,
    AVG(daily_credits) * DAY(LAST_DAY(CURRENT_DATE())) * 3 AS projected_monthly_cost_usd
FROM daily_usage;


-- ============================================================
-- SECTION 10: AUTOMATED WAREHOUSE MANAGEMENT WITH TASKS
-- ============================================================

-- 10A: Auto-resize warehouse based on time of day
-- Scale up during business hours, scale down off-hours
CREATE OR REPLACE TASK scale_up_reporting_wh
    WAREHOUSE = ETL_WH
    SCHEDULE = 'USING CRON 0 8 * * MON-FRI America/New_York'
AS
    ALTER WAREHOUSE REPORTING_WH SET WAREHOUSE_SIZE = 'MEDIUM';

CREATE OR REPLACE TASK scale_down_reporting_wh
    WAREHOUSE = ETL_WH
    SCHEDULE = 'USING CRON 0 20 * * MON-FRI America/New_York'
AS
    ALTER WAREHOUSE REPORTING_WH SET WAREHOUSE_SIZE = 'SMALL';

-- Enable the tasks
ALTER TASK scale_up_reporting_wh RESUME;
ALTER TASK scale_down_reporting_wh RESUME;


-- 10B: Suspend idle warehouses that shouldn't be running on weekends
CREATE OR REPLACE TASK weekend_suspend_analyst_wh
    WAREHOUSE = ETL_WH
    SCHEDULE = 'USING CRON 0 22 * * FRI America/New_York'
AS
    ALTER WAREHOUSE ANALYST_WH SUSPEND;

ALTER TASK weekend_suspend_analyst_wh RESUME;


-- 10C: Alert on long-running queries (create a monitoring task)
CREATE OR REPLACE TABLE long_running_query_alerts (
    alert_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    query_id VARCHAR,
    warehouse_name VARCHAR,
    user_name VARCHAR,
    elapsed_seconds NUMBER,
    query_text VARCHAR(1000)
);

CREATE OR REPLACE TASK monitor_long_queries
    WAREHOUSE = ETL_WH
    SCHEDULE = '5 MINUTE'
AS
    INSERT INTO long_running_query_alerts (query_id, warehouse_name, user_name, elapsed_seconds, query_text)
    SELECT
        query_id,
        warehouse_name,
        user_name,
        total_elapsed_time / 1000,
        LEFT(query_text, 1000)
    FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
        RESULT_LIMIT => 100,
        END_TIME_RANGE_START => DATEADD('MINUTE', -5, CURRENT_TIMESTAMP())
    ))
    WHERE total_elapsed_time > 300000  -- > 5 minutes
        AND execution_status = 'SUCCESS';

ALTER TASK monitor_long_queries RESUME;


-- ============================================================
-- SECTION 11: WAREHOUSE TUNING DECISION TREE
-- ============================================================
/*
SYMPTOM → DIAGNOSIS → ACTION

┌─────────────────────────────────────────────────────────────────┐
│ SYMPTOM: Queries are slow                                       │
├─────────────────────────────────────────────────────────────────┤
│ Check: Is there SPILLING?                                       │
│   YES → Upsize warehouse (need more memory)                     │
│   NO  → Check: Is there QUEUEING?                              │
│          YES → Add clusters (MAX_CLUSTER_COUNT)                 │
│          NO  → Check: Is PRUNING bad?                           │
│                 YES → Add clustering key / fix query filters    │
│                 NO  → Query itself needs optimization           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ SYMPTOM: Credits too high                                       │
├─────────────────────────────────────────────────────────────────┤
│ Check: Is warehouse running during idle periods?                │
│   YES → Reduce AUTO_SUSPEND                                     │
│   NO  → Check: Is warehouse oversized?                          │
│          YES → Downsize (no spilling = safe to reduce)          │
│          NO  → Check: Are there unnecessary queries?            │
│                 YES → Optimize/eliminate wasteful queries        │
│                 NO  → This is legitimate workload cost           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ SYMPTOM: Users complaining about wait times                     │
├─────────────────────────────────────────────────────────────────┤
│ Check: Is QUEUED_OVERLOAD_TIME high?                            │
│   YES → Increase MAX_CLUSTER_COUNT                              │
│         Change SCALING_POLICY to STANDARD                       │
│   NO  → Check: Is warehouse resuming too often?                 │
│          YES → Increase AUTO_SUSPEND (avoid cold start penalty) │
│          NO  → Individual query optimization needed             │
└─────────────────────────────────────────────────────────────────┘

SIZING CHEAT SHEET:
┌──────────────────────────────────────────────────────────────┐
│ DATA SCANNED      │ RECOMMENDED SIZE   │ NOTES              │
├──────────────────────────────────────────────────────────────┤
│ < 100 MB          │ X-Small            │ Simple lookups     │
│ 100 MB - 1 GB     │ Small              │ Standard reports   │
│ 1 GB - 10 GB      │ Medium             │ Complex analytics  │
│ 10 GB - 100 GB    │ Large              │ Heavy transforms   │
│ 100 GB - 1 TB     │ X-Large            │ Large aggregations │
│ > 1 TB            │ 2XL+               │ Massive processing │
└──────────────────────────────────────────────────────────────┘
Note: These are starting points. Always benchmark with real queries.
*/


-- ============================================================
-- SECTION 12: PRODUCTION CHECKLIST
-- ============================================================
/*
□ Separate warehouses by workload (ETL, BI, Analyst, App)
□ Set appropriate AUTO_SUSPEND for each workload type
□ Enable AUTO_RESUME on all warehouses
□ Set resource monitors on every warehouse (no exceptions)
□ Set account-level resource monitor as safety net
□ Configure multi-cluster for concurrent workloads
□ Schedule warehouse resizing for peak/off-peak hours
□ Monitor spilling weekly — upsize if persistent
□ Monitor queueing — add clusters if growing
□ Review credit consumption weekly
□ Benchmark new queries before production deployment
□ Set query timeout (STATEMENT_TIMEOUT_IN_SECONDS) per warehouse
□ Tag warehouses for chargeback reporting
□ Document warehouse ownership and purpose
*/

-- Set query timeout to prevent runaway queries
ALTER WAREHOUSE ETL_WH SET STATEMENT_TIMEOUT_IN_SECONDS = 3600;       -- 1 hour max for ETL
ALTER WAREHOUSE REPORTING_WH SET STATEMENT_TIMEOUT_IN_SECONDS = 600;  -- 10 min max for reports
ALTER WAREHOUSE ANALYST_WH SET STATEMENT_TIMEOUT_IN_SECONDS = 1800;   -- 30 min max for analysts
ALTER WAREHOUSE APP_WH SET STATEMENT_TIMEOUT_IN_SECONDS = 30;         -- 30 sec max for app queries
