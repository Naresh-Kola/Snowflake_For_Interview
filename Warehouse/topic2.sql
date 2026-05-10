-- ============================================================================
-- AUTO-SCALING & AUTO-SUSPEND IN SNOWFLAKE
-- HOW THEY IMPACT COST AND PERFORMANCE — COMPLETE GUIDE
-- ============================================================================
--
--
-- ############################################################################
-- PART 1: DEFINITIONS
-- ############################################################################
--
-- ─────────────────────────────────────────────────────────────────────────────
-- AUTO-SCALING (Multi-Cluster Warehouses)
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Auto-scaling is the ability of a multi-cluster warehouse to automatically
-- ADD or REMOVE compute clusters based on query load.
--
--   • When queries start queueing → Snowflake spins up another cluster
--   • When load drops             → Snowflake shuts down idle clusters
--   • You define MIN and MAX cluster counts; Snowflake manages the rest
--
-- AUTO-SCALING SOLVES: Query queueing from too many concurrent users/queries
-- AUTO-SCALING DOES NOT SOLVE: Slow individual queries (use warehouse resizing)
--
--
-- ─────────────────────────────────────────────────────────────────────────────
-- AUTO-SUSPEND
-- ─────────────────────────────────────────────────────────────────────────────
--
-- Auto-suspend automatically pauses a warehouse after N seconds of inactivity
-- (no running queries). When suspended, the warehouse consumes ZERO credits.
--
-- AUTO-RESUME (companion feature) automatically restarts the warehouse when
-- a new query arrives. There is a brief cold-start delay (1-2 seconds typical).
--
-- AUTO-SUSPEND SOLVES: Wasted credits from idle warehouses running 24/7
-- AUTO-SUSPEND TRADE-OFF: SSD cache is lost on suspend (first query after
--   resume is slower because data must be fetched from remote storage again)
--
--
-- ############################################################################
-- PART 2: HOW AUTO-SCALING WORKS INTERNALLY
-- ############################################################################
--
-- STEP-BY-STEP FLOW:
--
--   8:00 AM — Warehouse starts with MIN_CLUSTER_COUNT = 1
--   ┌──────────┐
--   │ Cluster 1│  ← handles all queries
--   └──────────┘
--
--   9:00 AM — 150 users open dashboards, queries start queueing
--   ┌──────────┐  ┌──────────┐
--   │ Cluster 1│  │ Cluster 2│  ← Snowflake detects queue → adds cluster
--   └──────────┘  └──────────┘
--
--   9:15 AM — Load keeps growing, still queueing
--   ┌──────────┐  ┌──────────┐  ┌──────────┐
--   │ Cluster 1│  │ Cluster 2│  │ Cluster 3│  ← another cluster added
--   └──────────┘  └──────────┘  └──────────┘
--
--   12:00 PM — Lunch break, load drops
--   ┌──────────┐  ┌──────────┐
--   │ Cluster 1│  │ Cluster 2│  ← Cluster 3 shut down (idle)
--   └──────────┘  └──────────┘
--
--   2:00 PM — Very light load
--   ┌──────────┐
--   │ Cluster 1│  ← back to minimum
--   └──────────┘
--
--   6:00 PM — No activity for AUTO_SUSPEND seconds
--   (suspended)   ← ALL clusters shut down, zero credits consumed
--
--
-- ############################################################################
-- PART 3: THE TWO SCALING POLICIES
-- ############################################################################
--
-- ┌──────────────┬─────────────────────────────────┬──────────────────────────┐
-- │ POLICY       │ STANDARD (default)               │ ECONOMY                  │
-- ├──────────────┼─────────────────────────────────┼──────────────────────────┤
-- │ Philosophy   │ Prevent queueing at all costs   │ Save money at all costs  │
-- ├──────────────┼─────────────────────────────────┼──────────────────────────┤
-- │ New cluster  │ Starts IMMEDIATELY when a query │ Starts only if system    │
-- │ spins up     │ is queued OR system estimates   │ estimates enough load    │
-- │ when...      │ the current clusters can't      │ to keep cluster busy     │
-- │              │ handle one more query            │ for at least 6 MINUTES   │
-- ├──────────────┼─────────────────────────────────┼──────────────────────────┤
-- │ Cluster      │ After sustained low load, shuts │ Shuts down when < 6 min  │
-- │ shuts down   │ down least-loaded clusters as   │ of estimated work left   │
-- │ when...      │ running queries finish          │ on the cluster           │
-- ├──────────────┼─────────────────────────────────┼──────────────────────────┤
-- │ Best for     │ BI dashboards, user-facing apps │ Batch/overnight jobs,    │
-- │              │ where queueing = poor UX        │ internal analytics where │
-- │              │                                 │ slight delays are OK     │
-- ├──────────────┼─────────────────────────────────┼──────────────────────────┤
-- │ Cost impact  │ HIGHER — more clusters running  │ LOWER — fewer clusters   │
-- │              │ more often (proactive scaling)   │ but queries may queue    │
-- ├──────────────┼─────────────────────────────────┼──────────────────────────┤
-- │ Performance  │ BETTER — near-zero queue time   │ WORSE — users may wait   │
-- │ impact       │                                 │ during ramp-up periods   │
-- └──────────────┴─────────────────────────────────┴──────────────────────────┘
--
--
-- ############################################################################
-- PART 4: HOW AUTO-SUSPEND WORKS INTERNALLY
-- ############################################################################
--
-- STEP-BY-STEP FLOW:
--
--   10:00:00 — Last query finishes executing
--              Timer starts counting: 0 seconds of idle
--
--   10:01:00 — Still idle (60 seconds)
--              If AUTO_SUSPEND = 60, warehouse suspends NOW
--              All compute nodes released. SSD cache DROPPED.
--              Credits = $0 from this point forward.
--
--   10:15:00 — New query arrives
--              AUTO_RESUME = TRUE → warehouse starts provisioning
--              ~1-2 second delay (cold start)
--              Minimum 60-second billing starts
--              SSD cache is EMPTY (first queries fetch from remote storage)
--
--
-- THE CACHE TRADE-OFF:
--
--   ┌─────────────────────────────────────────────────────────────┐
--   │ AUTO_SUSPEND = 60 seconds (aggressive)                      │
--   │                                                             │
--   │  ✓ Saves maximum credits (shuts down fast)                 │
--   │  ✗ SSD cache lost frequently                               │
--   │  ✗ Cold starts happen often                                │
--   │  ✗ If queries arrive every 2-3 min, constant suspend/resume│
--   │    → each resume = 60-second minimum charge                │
--   │    → may COST MORE than staying running!                   │
--   └─────────────────────────────────────────────────────────────┘
--
--   ┌─────────────────────────────────────────────────────────────┐
--   │ AUTO_SUSPEND = 300 seconds (5 minutes, balanced)            │
--   │                                                             │
--   │  ✓ Cache survives short gaps between queries               │
--   │  ✓ Fewer suspend/resume cycles                             │
--   │  ✗ Pays for 5 min idle after last query                    │
--   │  → BEST for BI/analytics with intermittent query patterns  │
--   └─────────────────────────────────────────────────────────────┘
--
--   ┌─────────────────────────────────────────────────────────────┐
--   │ AUTO_SUSPEND = NEVER (disabled)                             │
--   │                                                             │
--   │  ✓ Cache always warm, zero cold starts                     │
--   │  ✗ Pays credits 24/7 even when idle                        │
--   │  ✗ XL warehouse idle = 16 credits/hour wasted              │
--   │  → ONLY for heavy, continuous workloads with no gaps       │
--   └─────────────────────────────────────────────────────────────┘
--
--
-- ############################################################################
-- PART 5: COST IMPACT — THE MATH
-- ############################################################################
--
-- CREDIT RATES BY WAREHOUSE SIZE:
-- ┌───────────┬──────────────────┐
-- │ SIZE      │ CREDITS / HOUR   │
-- ├───────────┼──────────────────┤
-- │ X-Small   │ 1                │
-- │ Small     │ 2                │
-- │ Medium    │ 4                │
-- │ Large     │ 8                │
-- │ X-Large   │ 16               │
-- │ 2X-Large  │ 32               │
-- │ 3X-Large  │ 64               │
-- │ 4X-Large  │ 128              │
-- └───────────┴──────────────────┘
--
-- SCENARIO: MEDIUM warehouse, 3 max clusters, 8 working hours/day
--
-- WITHOUT auto-scaling (single cluster, no suspend):
--   1 cluster × 4 credits/hr × 24 hours = 96 credits/day
--
-- WITH auto-scaling + auto-suspend:
--   8 AM - 9 AM:   1 cluster × 1 hr =  4 credits
--   9 AM - 11 AM:  3 clusters × 2 hr = 24 credits (peak)
--   11 AM - 1 PM:  2 clusters × 2 hr = 16 credits
--   1 PM - 5 PM:   1 cluster × 4 hr  = 16 credits
--   5 PM - 8 AM:   SUSPENDED          =  0 credits
--                                 TOTAL: 60 credits/day
--
-- SAVINGS: 96 - 60 = 36 credits/day = 37.5% cost reduction
--          × 30 days = 1,080 credits/month saved
--
--
-- ############################################################################
-- PART 6: PERFORMANCE IMPACT
-- ############################################################################
--
-- ┌───────────────────────────┬──────────────────────┬───────────────────────┐
-- │ SCENARIO                  │ WITHOUT OPTIMIZATION │ WITH OPTIMIZATION      │
-- ├───────────────────────────┼──────────────────────┼───────────────────────┤
-- │ 200 users hit dashboard   │ Queries queue 5-10   │ Auto-scale adds       │
-- │ at 9 AM                   │ minutes. Users think │ clusters in seconds.  │
-- │                           │ dashboard is broken. │ Zero queue. Fast UX.  │
-- ├───────────────────────────┼──────────────────────┼───────────────────────┤
-- │ First query at 8 AM after │ Warehouse already    │ 1-2 second cold start │
-- │ overnight idle            │ running (wasted $$)  │ from auto-resume.     │
-- │                           │                      │ Cache rebuilds quickly.│
-- ├───────────────────────────┼──────────────────────┼───────────────────────┤
-- │ ETL job at 2 AM finishes, │ Warehouse runs idle  │ Auto-suspend kicks in │
-- │ next job at 6 AM          │ for 4 hours burning  │ after 2 min. Zero     │
-- │                           │ 32 credits (LARGE).  │ cost for 4 hours.     │
-- ├───────────────────────────┼──────────────────────┼───────────────────────┤
-- │ Repeated query on same    │ Cache warm, fast     │ If suspended + resumed│
-- │ data set                  │ (0.1 sec from cache) │ cache lost, slower    │
-- │                           │                      │ first run (5-10 sec). │
-- └───────────────────────────┴──────────────────────┴───────────────────────┘
--
--
-- ############################################################################
-- PART 7: IMPLEMENTATION EXAMPLES
-- ############################################################################


-- ============================================================================
-- EXAMPLE 1: BI Dashboard Warehouse (Performance Priority)
-- ============================================================================

CREATE OR REPLACE WAREHOUSE WH_BI_DASHBOARDS
    WAREHOUSE_SIZE    = 'MEDIUM'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 4
    SCALING_POLICY    = 'STANDARD'
    AUTO_SUSPEND      = 300
    AUTO_RESUME       = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'BI dashboards: fast scale-out, 5-min suspend to preserve cache';

-- WHY THESE SETTINGS:
--   MEDIUM:          Dashboard queries are typically fast (pre-aggregated)
--   MAX_CLUSTER = 4: Handles up to ~200 concurrent dashboard users
--   STANDARD:        Zero tolerance for queueing (user-facing)
--   SUSPEND = 300:   BI tools keep connections open; 5 min avoids
--                    constant suspend/resume cycles


-- ============================================================================
-- EXAMPLE 2: ETL/Transformation Warehouse (Cost Priority)
-- ============================================================================

CREATE OR REPLACE WAREHOUSE WH_ETL_TRANSFORM
    WAREHOUSE_SIZE    = 'LARGE'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 1
    AUTO_SUSPEND      = 60
    AUTO_RESUME       = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'ETL jobs: single cluster, aggressive suspend to save cost';

-- WHY THESE SETTINGS:
--   LARGE:           Heavy transforms need compute power (vertical scale)
--   MAX_CLUSTER = 1: ETL is sequential, not concurrent (no need to scale out)
--   SUSPEND = 60:    ETL runs in bursts. No humans waiting. Suspend fast.


-- ============================================================================
-- EXAMPLE 3: Ad-hoc Analytics Warehouse (Balanced)
-- ============================================================================

CREATE OR REPLACE WAREHOUSE WH_ADHOC_ANALYTICS
    WAREHOUSE_SIZE    = 'SMALL'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 2
    SCALING_POLICY    = 'ECONOMY'
    AUTO_SUSPEND      = 300
    AUTO_RESUME       = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Ad-hoc queries: economy scaling, moderate suspend';

-- WHY THESE SETTINGS:
--   SMALL:           Ad-hoc queries vary; start small, resize if needed
--   MAX_CLUSTER = 2: Prevents one analyst's heavy query from blocking another
--   ECONOMY:         Analysts can tolerate brief queues; save money
--   SUSPEND = 300:   Analysts query intermittently; keep cache warm


-- ============================================================================
-- EXAMPLE 4: Real-time Ingestion Warehouse (Always-on)
-- ============================================================================

CREATE OR REPLACE WAREHOUSE WH_REALTIME_INGEST
    WAREHOUSE_SIZE    = 'SMALL'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 1
    AUTO_SUSPEND      = 0
    AUTO_RESUME       = TRUE
    COMMENT = 'Real-time ingestion: never suspend, continuous streaming';

-- WHY THESE SETTINGS:
--   AUTO_SUSPEND = 0: Data arrives every few seconds (Snowpipe Streaming).
--                     Suspending would cause constant resume cycles.
--                     Each resume = 60-second minimum charge.
--                     Staying on is CHEAPER than suspend/resume churn.


-- ============================================================================
-- EXAMPLE 5: Dynamic Resizing for Scheduled Heavy Jobs
-- ============================================================================

-- Scale UP before nightly heavy ETL
ALTER WAREHOUSE WH_ETL_TRANSFORM SET WAREHOUSE_SIZE = 'XLARGE';

-- (run heavy ETL here)

-- Scale DOWN after job completes
ALTER WAREHOUSE WH_ETL_TRANSFORM SET WAREHOUSE_SIZE = 'LARGE';

-- The warehouse auto-suspends 60 seconds after the last query finishes.


-- ############################################################################
-- PART 8: RECOMMENDED SETTINGS BY WORKLOAD
-- ############################################################################
--
-- ┌──────────────────┬──────────┬───────┬───────┬──────────┬────────────────┐
-- │ WORKLOAD         │ SIZE     │ MIN   │ MAX   │ SUSPEND  │ SCALING POLICY │
-- ├──────────────────┼──────────┼───────┼───────┼──────────┼────────────────┤
-- │ BI Dashboards    │ Medium   │ 1     │ 3-6   │ 300 sec  │ STANDARD       │
-- │ ETL / dbt        │ Large    │ 1     │ 1     │ 60 sec   │ N/A (single)   │
-- │ Ad-hoc Analysts  │ Small    │ 1     │ 2     │ 300 sec  │ ECONOMY        │
-- │ Data Science/ML  │ Large-XL │ 1     │ 1     │ 120 sec  │ N/A (single)   │
-- │ Real-time Ingest │ Small    │ 1     │ 1     │ NEVER    │ N/A (single)   │
-- │ Dev/Test         │ X-Small  │ 1     │ 1     │ 60 sec   │ N/A (single)   │
-- │ Scheduled Reports│ Medium   │ 1     │ 2     │ 120 sec  │ ECONOMY        │
-- └──────────────────┴──────────┴───────┴───────┴──────────┴────────────────┘
--
--
-- ############################################################################
-- PART 9: MONITORING — IS YOUR CONFIG WORKING?
-- ############################################################################


-- 9A. Check which warehouses are running and their cluster counts
SHOW WAREHOUSES;

-- 9B. Find warehouses that are WASTING credits (running but idle)
SELECT
    WAREHOUSE_NAME,
    SUM(CREDITS_USED)                        AS TOTAL_CREDITS,
    COUNT(*)                                 AS TOTAL_QUERIES,
    ROUND(SUM(CREDITS_USED) / NULLIF(COUNT(*), 0), 4) AS CREDITS_PER_QUERY
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY TOTAL_CREDITS DESC;

-- 9C. Find warehouses with excessive QUEUEING (need more clusters)
SELECT
    WAREHOUSE_NAME,
    COUNT(*)                                                    AS TOTAL_QUERIES,
    SUM(CASE WHEN QUEUED_OVERLOAD_TIME > 0 THEN 1 ELSE 0 END) AS QUEUED_QUERIES,
    ROUND(100.0 * SUM(CASE WHEN QUEUED_OVERLOAD_TIME > 0 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                        AS QUEUE_PCT,
    ROUND(AVG(QUEUED_OVERLOAD_TIME) / 1000, 2)                 AS AVG_QUEUE_SEC
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
    AND WAREHOUSE_NAME IS NOT NULL
GROUP BY 1
HAVING QUEUED_QUERIES > 0
ORDER BY QUEUE_PCT DESC;

-- INTERPRETATION:
--   QUEUE_PCT > 5%   → increase MAX_CLUSTER_COUNT or switch to STANDARD policy
--   QUEUE_PCT = 0%   → scaling is working well, or warehouse is over-provisioned
--   AVG_QUEUE_SEC > 5 → users are noticeably waiting; consider STANDARD policy

-- 9D. Count suspend/resume cycles (too many = raise AUTO_SUSPEND)
SELECT
    WAREHOUSE_NAME,
    DATE_TRUNC('DAY', START_TIME) AS DAY,
    COUNT(*)                       AS RESUME_COUNT
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY RESUME_COUNT DESC;

-- INTERPRETATION:
--   RESUME_COUNT > 50/day → AUTO_SUSPEND is too aggressive
--     Each resume = 60-second minimum billing
--     50 resumes × 60 sec = 50 minutes of minimum charges
--     Consider raising AUTO_SUSPEND to 300 seconds


-- ############################################################################
-- SUMMARY: DECISION CHEAT SHEET
-- ############################################################################
--
-- QUESTION 1: "Are users complaining about slow dashboards / queueing?"
--   YES → Enable auto-scaling (increase MAX_CLUSTER_COUNT)
--         Use STANDARD scaling policy
--   NO  → Single cluster is fine
--
-- QUESTION 2: "Is our Snowflake bill too high?"
--   YES → Enable auto-suspend (start with 60-300 seconds)
--         Switch to ECONOMY scaling policy
--         Check for warehouses running 24/7 with low query counts
--   NO  → Current settings are fine
--
-- QUESTION 3: "Should I scale UP (bigger) or OUT (more clusters)?"
--   Individual queries are slow      → Scale UP (larger warehouse size)
--   Many queries queue simultaneously → Scale OUT (more clusters)
--   Both                              → Scale UP first, then OUT
--
-- QUESTION 4: "What AUTO_SUSPEND value should I use?"
--   Continuous queries (< 2 min gaps)  → 60 seconds or NEVER
--   Intermittent queries (2-10 min gaps)→ 300 seconds
--   Sparse queries (> 30 min gaps)     → 60 seconds
--   Key: AUTO_SUSPEND > typical gap between queries
-- ============================================================================
