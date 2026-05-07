-- ============================================================================
-- SERVERLESS IN SNOWFLAKE & AVOIDING OVERPAYING FOR COMPUTE
-- What Serverless Means, Why You're Overpaying, and How to Fix It
-- ============================================================================


-- ============================================================================
-- SECTION 1: WHAT IS SERVERLESS IN SNOWFLAKE?
-- ============================================================================
/*
    In Snowflake, there are TWO types of compute:

    TYPE 1: YOUR WAREHOUSE (User-Managed Compute)
    ──────────────────────────────────────────────
    - YOU create it, YOU size it, YOU pay for it while it runs
    - You choose X-Small, Small, Medium, Large, etc.
    - You pay PER SECOND while it's running (even if idle!)
    - YOU manage auto-suspend and auto-resume settings
    
    Analogy: Hiring a full-time employee. You pay them whether they
    have work or not. If they sit idle for 2 hours, you still pay.

    TYPE 2: SERVERLESS (Snowflake-Managed Compute)
    ───────────────────────────────────────────────
    - SNOWFLAKE manages the compute behind the scenes
    - You DON'T create or size any warehouse
    - Snowflake spins up resources ONLY when needed, and stops automatically
    - You pay ONLY for what is actually consumed
    
    Analogy: Hiring a freelancer. They work only when you have a task,
    and you pay only for the hours they actually worked. No idle time.

    SERVERLESS FEATURES IN SNOWFLAKE:
    ┌──────────────────────────────┬────────────────────────────────────┐
    │ Feature                      │ What It Does                       │
    ├──────────────────────────────┼────────────────────────────────────┤
    │ Snowpipe                     │ Auto-loads files as they arrive    │
    │ Automatic Clustering         │ Maintains clustering keys on tables│
    │ Search Optimization Service  │ Builds search access paths         │
    │ Materialized View Refresh    │ Keeps MVs up to date               │
    │ Serverless Tasks             │ Runs scheduled SQL without a WH    │
    │ Database Replication         │ Syncs data across regions/accounts │
    │ Query Acceleration Service   │ Speeds up outlier queries          │
    │ Cortex AI Functions          │ AI/ML processing                   │
    │ Data Quality (DMFs)          │ Scheduled data quality checks      │
    └──────────────────────────────┴────────────────────────────────────┘

    KEY DIFFERENCE:
    Warehouse:   You pay for the TIME the warehouse is RUNNING
    Serverless:  You pay for the WORK actually DONE
*/


-- ============================================================================
-- SECTION 2: ADVANTAGES OF SERVERLESS
-- ============================================================================
/*
    1. NO IDLE COST
       ─────────────
       Warehouse: Running for 1 hour but only working for 5 minutes = you pay for 1 hour
       Serverless: Works for 5 minutes = you pay for 5 minutes
       
    2. NO SIZING DECISIONS
       ────────────────────
       Warehouse: You must choose X-Small, Small, Medium... guess wrong = waste or slow
       Serverless: Snowflake automatically picks the right size
       
    3. NO MANAGEMENT OVERHEAD
       ──────────────────────
       Warehouse: You configure auto-suspend, auto-resume, scaling policies, etc.
       Serverless: Zero configuration. It just works.
       
    4. AUTO-SCALES
       ───────────
       Warehouse: You must set up multi-cluster and scaling policies
       Serverless: Snowflake automatically scales up/down based on workload
       
    5. PER-SECOND BILLING ON ACTUAL WORK
       ──────────────────────────────────
       Warehouse: 60-second minimum billing every time it starts
       Serverless: Billed per second of actual compute used
*/


-- ============================================================================
-- SECTION 3: THE OVERPAYING PROBLEM — REAL SCENARIO
-- ============================================================================
/*
    SCENARIO: You're a data engineer at an e-commerce company.
    ─────────────────────────────────────────────────────────

    You have these SCHEDULED JOBS running on a Medium warehouse:

    JOB 1: Every HOUR  → Refresh a dashboard (takes 30 seconds)
    JOB 2: Every DAY   → Load new data from S3 (takes 3 minutes)
    JOB 3: Every DAY   → Run data quality checks (takes 1 minute)

    YOUR WAREHOUSE SETTINGS:
    - Size: Medium (4 credits/hour)
    - Auto-suspend: 5 minutes
    - Auto-resume: TRUE

    WHAT ACTUALLY HAPPENS EVERY HOUR:
    ┌────────────────────────────────────────────────────────────────┐
    │ 10:00:00  Warehouse RESUMES (cold start ~2 sec)               │
    │ 10:00:02  JOB 1 starts (dashboard refresh)                    │
    │ 10:00:32  JOB 1 finishes (30 seconds of ACTUAL work)          │
    │ 10:00:33  Warehouse sits IDLE...                              │
    │ 10:05:33  Warehouse SUSPENDS (after 5 min idle timeout)       │
    │                                                               │
    │ TOTAL TIME RUNNING:  5 min 33 sec                             │
    │ ACTUAL WORK DONE:    30 seconds                               │
    │ IDLE TIME PAID FOR:  5 min 3 sec  ← WASTED!                  │
    └────────────────────────────────────────────────────────────────┘

    DAILY COST CALCULATION:
    ─────────────────────────
    - Warehouse runs 24 times/day (hourly job)
    - Each run: ~5.5 minutes (30 sec work + 5 min idle before suspend)
    - Total daily runtime: 24 x 5.5 min = 132 minutes = 2.2 hours
    - Medium WH cost: 4 credits/hour
    - Daily cost: 2.2 x 4 = 8.8 credits/day
    - Monthly cost: 8.8 x 30 = 264 credits/month

    ACTUAL WORK DONE:
    - 24 x 30 seconds = 12 minutes/day of real work
    - You're paying for 132 minutes but using only 12 minutes
    - EFFICIENCY: 12/132 = 9% → 91% OF YOUR MONEY IS WASTED!
*/


-- ============================================================================
-- SECTION 4: HOW TO FIX IT — 5 STRATEGIES
-- ============================================================================


-- =========================================================================
-- FIX 1: USE SERVERLESS TASKS (Instead of Warehouse-Based Tasks)
-- =========================================================================
/*
    WHAT CHANGES:
    - Instead of: Task runs on YOUR warehouse (you pay idle time)
    - Use: Serverless task (Snowflake provides compute, you pay only for work)
    
    HOW: Simply don't specify a warehouse when creating the task!
*/

-- BAD: Warehouse-based task (you pay for idle time)
/*
CREATE OR REPLACE TASK REFRESH_DASHBOARD_BAD
    WAREHOUSE = MY_MEDIUM_WH
    SCHEDULE = 'USING CRON 0 * * * * America/New_York'
AS
    INSERT OVERWRITE INTO DASHBOARD_SUMMARY
    SELECT REGION, SUM(AMOUNT), COUNT(*)
    FROM SALES
    WHERE SALE_DATE >= DATEADD(DAY, -7, CURRENT_DATE())
    GROUP BY REGION;
*/

-- GOOD: Serverless task (pay only for the 30 seconds of actual work!)
/*
CREATE OR REPLACE TASK REFRESH_DASHBOARD_GOOD
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE = 'USING CRON 0 * * * * America/New_York'
AS
    INSERT OVERWRITE INTO DASHBOARD_SUMMARY
    SELECT REGION, SUM(AMOUNT), COUNT(*)
    FROM SALES
    WHERE SALE_DATE >= DATEADD(DAY, -7, CURRENT_DATE())
    GROUP BY REGION;
*/
/*
    COST COMPARISON:
    ┌─────────────────────────────┬──────────────┬───────────────┐
    │                             │ Warehouse    │ Serverless    │
    │                             │ Task         │ Task          │
    ├─────────────────────────────┼──────────────┼───────────────┤
    │ Compute used per run        │ 5.5 minutes  │ 30 seconds    │
    │ Daily compute               │ 132 minutes  │ 12 minutes    │
    │ Monthly credits (approx)    │ 264          │ ~30           │
    │ Savings                     │ —            │ ~88%!         │
    └─────────────────────────────┴──────────────┴───────────────┘

    NOTE: Serverless tasks have a HIGHER credit rate per second
    (about 1.5x), but because there's ZERO idle time, they're
    still much cheaper for short-running scheduled jobs.
*/


-- =========================================================================
-- FIX 2: REDUCE AUTO-SUSPEND TIMEOUT
-- =========================================================================
/*
    If you MUST use a warehouse, reduce the idle timeout!
    
    Default auto-suspend is often 10 minutes.
    If your job runs for 30 seconds, the warehouse sits idle for 9.5 minutes.
    
    Reduce to 1 minute (60 seconds) — the minimum practical value.
    
    WHY NOT 0?
    - 0 or NULL = NEVER suspend (warehouse runs forever = VERY expensive!)
    - 60 seconds is the minimum billing unit anyway
    
    TRADE-OFF:
    - Lower suspend = save credits but lose warehouse cache
    - Higher suspend = spend more credits but keep cache warm
    - For scheduled jobs: LOW suspend is almost always better
*/

-- Set auto-suspend to 60 seconds
-- ALTER WAREHOUSE MY_MEDIUM_WH SET AUTO_SUSPEND = 60;

/*
    SAVINGS:
    Before (5 min auto-suspend): 5.5 min per run = 132 min/day
    After  (1 min auto-suspend): 1.5 min per run = 36 min/day
    Savings: ~73% reduction in idle time!
*/


-- =========================================================================
-- FIX 3: RIGHT-SIZE YOUR WAREHOUSE
-- =========================================================================
/*
    PROBLEM: Using a MEDIUM warehouse for a 30-second query.
    A Medium WH costs 4 credits/hour. An X-Small costs 1 credit/hour.
    
    If the query runs in 30 seconds on BOTH sizes, why use Medium?
    
    RULE: Start with X-Small. Only scale up if the query is SLOW.
    
    Test approach:
    1. Run your query on X-Small → note execution time
    2. Run on Small → note execution time
    3. Run on Medium → note execution time
    4. If X-Small finishes in similar time → use X-Small!
*/

-- Create a right-sized warehouse
/*
CREATE OR REPLACE WAREHOUSE ETL_SCHEDULER
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE;
*/

/*
    COST COMPARISON:
    ┌──────────────────┬──────────────┬────────────────┐
    │ Warehouse Size   │ Credits/Hour │ Monthly Cost*  │
    ├──────────────────┼──────────────┼────────────────┤
    │ X-Small          │ 1            │ ~$90           │
    │ Small            │ 2            │ ~$180          │
    │ Medium           │ 4            │ ~$360          │
    │ Large            │ 8            │ ~$720          │
    │ X-Large          │ 16           │ ~$1,440        │
    └──────────────────┴──────────────┴────────────────┘
    * Assuming 2.2 hours/day usage, $3/credit
    
    Going from Medium → X-Small saves 75% of warehouse credits!
*/


-- =========================================================================
-- FIX 4: BATCH MULTIPLE JOBS INTO ONE WINDOW
-- =========================================================================
/*
    PROBLEM: 3 separate jobs trigger the warehouse 3 times.
    Each time = cold start + idle time.
    
    INSTEAD: Run all 3 jobs back-to-back in ONE window.
    Warehouse starts ONCE, does all work, suspends ONCE.
    
    BEFORE (3 separate triggers):
    ┌──────────────────────────────────────────────┐
    │ 10:00 → WH starts → Job1 (30s) → idle 5m    │
    │ 10:15 → WH starts → Job2 (3m)  → idle 5m    │
    │ 10:30 → WH starts → Job3 (1m)  → idle 5m    │
    │ Total runtime: 3 starts + 3 idles = ~19.5 min│
    └──────────────────────────────────────────────┘
    
    AFTER (batched into 1 window):
    ┌──────────────────────────────────────────────┐
    │ 10:00 → WH starts → Job1 → Job2 → Job3 → idle 1m │
    │ Total runtime: 1 start + 4.5m work + 1m idle = ~5.5 min │
    └──────────────────────────────────────────────┘
    
    Savings: 19.5 min → 5.5 min = ~72% reduction!
*/

-- Use task dependencies to chain jobs
/*
CREATE OR REPLACE TASK JOB1_LOAD_DATA
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    SCHEDULE = 'USING CRON 0 2 * * * America/New_York'
AS
    COPY INTO SALES FROM @MY_STAGE FILE_FORMAT = (FORMAT_NAME = 'CSV_OPT');

CREATE OR REPLACE TASK JOB2_QUALITY_CHECK
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    AFTER JOB1_LOAD_DATA
AS
    INSERT INTO DQ_RESULTS
    SELECT 'SALES', COUNT(*), MIN(SALE_DATE), MAX(SALE_DATE)
    FROM SALES;

CREATE OR REPLACE TASK JOB3_REFRESH_DASHBOARD
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
    AFTER JOB2_QUALITY_CHECK
AS
    INSERT OVERWRITE INTO DASHBOARD_SUMMARY
    SELECT REGION, SUM(AMOUNT), COUNT(*)
    FROM SALES
    GROUP BY REGION;

-- All 3 run as a chain: Job1 → Job2 → Job3 → done!
-- ALTER TASK JOB1_LOAD_DATA RESUME;
*/


-- =========================================================================
-- FIX 5: USE SNOWPIPE INSTEAD OF SCHEDULED COPY INTO
-- =========================================================================
/*
    PROBLEM: You have a scheduled task that runs COPY INTO every hour.
    Most hours, there are NO new files — but the warehouse still starts,
    checks, finds nothing, and shuts down. You paid for nothing!
    
    BEFORE (Scheduled COPY INTO):
    ┌──────────────────────────────────────────────────────────┐
    │ Every hour:                                              │
    │ - Warehouse resumes (even if no new files)               │
    │ - Runs COPY INTO → finds 0 files → does nothing         │
    │ - Warehouse idles for 5 min → suspends                  │
    │ - You paid 5+ min of Medium WH for ZERO work!           │
    │ - This happens 24 times/day = 120 min wasted daily      │
    └──────────────────────────────────────────────────────────┘
    
    AFTER (Snowpipe — serverless):
    ┌──────────────────────────────────────────────────────────┐
    │ File arrives in S3:                                      │
    │ - S3 sends notification to Snowpipe                      │
    │ - Snowpipe loads the file (serverless compute)           │
    │ - Done! No warehouse needed.                             │
    │                                                          │
    │ No files arrive:                                         │
    │ - Nothing happens. ZERO cost.                            │
    └──────────────────────────────────────────────────────────┘
*/


-- ============================================================================
-- SECTION 5: DETECT IF YOU'RE OVERPAYING — RUN THESE QUERIES
-- ============================================================================

-- QUERY 1: Find warehouses with low utilization (high idle time)
/*
SELECT 
    WAREHOUSE_NAME,
    SUM(CREDITS_USED)                       AS TOTAL_CREDITS,
    COUNT(DISTINCT TO_DATE(START_TIME))      AS ACTIVE_DAYS,
    SUM(CREDITS_USED) / ACTIVE_DAYS         AS AVG_CREDITS_PER_DAY
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY TOTAL_CREDITS DESC;
*/

-- QUERY 2: Find short-running queries on large warehouses (overpaying!)
/*
SELECT 
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    COUNT(*)                                         AS QUERY_COUNT,
    AVG(EXECUTION_TIME) / 1000                       AS AVG_EXEC_SEC,
    MEDIAN(EXECUTION_TIME) / 1000                    AS MEDIAN_EXEC_SEC,
    MAX(EXECUTION_TIME) / 1000                       AS MAX_EXEC_SEC
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
  AND WAREHOUSE_NAME IS NOT NULL
  AND EXECUTION_TIME > 0
GROUP BY 1, 2
HAVING AVG_EXEC_SEC < 10
ORDER BY QUERY_COUNT DESC;
*/
-- If AVG_EXEC_SEC < 10 on a MEDIUM or LARGE warehouse → you're overpaying!

-- QUERY 3: Find tasks that could be serverless
/*
SELECT 
    NAME                    AS TASK_NAME,
    DATABASE_NAME,
    SCHEMA_NAME,
    WAREHOUSE               AS WAREHOUSE_NAME,
    SCHEDULE,
    STATE
FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY
WHERE WAREHOUSE IS NOT NULL
  AND COMPLETED_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY TASK_NAME;
*/
-- Any task with a WAREHOUSE assigned could potentially be converted to serverless

-- QUERY 4: Compare serverless task cost vs warehouse task cost
/*
SELECT 
    TO_DATE(START_TIME) AS DATE,
    SUM(CREDITS_USED) AS SERVERLESS_TASK_CREDITS
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY 1;
*/


-- ============================================================================
-- SECTION 6: DECISION FLOWCHART — WHEN TO USE WHAT
-- ============================================================================
/*
    YOUR JOB RUNS ON A SCHEDULE → Ask yourself:

    ┌─────────────────────────────────────────────────────────────────┐
    │ How long does the job take?                                     │
    │                                                                 │
    │ LESS THAN 1 MINUTE                                              │
    │   └─→ USE SERVERLESS TASK (zero idle cost)                      │
    │                                                                 │
    │ 1-10 MINUTES                                                    │
    │   └─→ USE SERVERLESS TASK or X-Small WH with 60s auto-suspend  │
    │                                                                 │
    │ 10-60 MINUTES                                                   │
    │   └─→ USE RIGHT-SIZED WAREHOUSE with 60s auto-suspend           │
    │                                                                 │
    │ HOURS (heavy ETL)                                               │
    │   └─→ USE DEDICATED WAREHOUSE, size it properly                 │
    │                                                                 │
    │ CONTINUOUS FILE LOADING                                         │
    │   └─→ USE SNOWPIPE (serverless) instead of scheduled COPY INTO  │
    │                                                                 │
    │ TABLE MAINTENANCE (clustering, search optimization)             │
    │   └─→ ALREADY SERVERLESS! Just monitor costs.                   │
    └─────────────────────────────────────────────────────────────────┘


    SUMMARY — WAYS TO STOP OVERPAYING:
    ====================================
    ┌────────────────────────────────┬────────────────────────────────┐
    │ Problem                        │ Fix                            │
    ├────────────────────────────────┼────────────────────────────────┤
    │ Short jobs on big warehouses   │ Right-size to X-Small          │
    │ Long idle before suspend       │ Reduce auto-suspend to 60 sec  │
    │ Scheduled tasks with warehouse │ Convert to serverless tasks    │
    │ Hourly COPY INTO with no data  │ Switch to Snowpipe             │
    │ Multiple jobs at different     │ Batch into one window using    │
    │ times                          │ task dependencies (AFTER)      │
    │ Warehouse runs 24/7 with       │ Enable auto-suspend!           │
    │ gaps in usage                  │                                │
    └────────────────────────────────┴────────────────────────────────┘
*/
