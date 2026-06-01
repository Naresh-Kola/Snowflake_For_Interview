# Snowflake Query Optimization: 5 Billion Row SALES_HISTORY Table

**Scenario:** Marketing team filters by REGION and DATE, query is timing out
**Goal:** Fix performance WITHOUT increasing warehouse size

---

## Step 0: Diagnose the Problem

Before fixing anything, understand WHY it's slow.

```sql
-- Check the current clustering health of the table
SELECT SYSTEM$CLUSTERING_INFORMATION('SALES_DB.PUBLIC.SALES_HISTORY', '(REGION, SALE_DATE)');

-- Check clustering depth (lower = better, target < 5)
SELECT SYSTEM$CLUSTERING_DEPTH('SALES_DB.PUBLIC.SALES_HISTORY', '(REGION, SALE_DATE)');

-- Run the Marketing team's query, then inspect it:
SELECT *
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC'
  AND SALE_DATE BETWEEN '2025-01-01' AND '2025-01-31';
```

After running, go to **Query Profile** and look for:
- **"Percentage Scanned from Cache"** -- is caching being used?
- **"Partitions scanned" vs "Partitions total"** -- is pruning working?
- If partitions scanned ~ partitions total => **NO PRUNING = root cause**

---

## Fix #1: Clustering Key (Biggest Impact)

The #1 reason for timeout on a 5B row table with filter predicates. Without clustering, Snowflake scans ALL micro-partitions. With clustering on `(REGION, SALE_DATE)`, it prunes 95%+ of partitions.

- **Before:** 5B rows, ~10M micro-partitions, query scans ALL of them
- **After:** Same query scans only ~100K partitions (the ones matching REGION + DATE)

```sql
ALTER TABLE SALES_DB.PUBLIC.SALES_HISTORY
  CLUSTER BY (REGION, TO_DATE(SALE_DATE));
```

**Why this order?** REGION has LOW cardinality (e.g. 5-10 values) and goes FIRST. DATE has HIGH cardinality, so we use `TO_DATE()` to reduce granularity. Snowflake recommends: low cardinality -> high cardinality order.

Automatic Clustering kicks in and reorganizes micro-partitions in the background. Monitor progress:

```sql
SHOW TABLES LIKE 'SALES_HISTORY' IN SCHEMA SALES_DB.PUBLIC;
-- Check "automatic_clustering" = ON and monitor over time.

-- After reclustering completes, verify improvement:
SELECT SYSTEM$CLUSTERING_INFORMATION('SALES_DB.PUBLIC.SALES_HISTORY');
-- Look for: average_depth close to 1-2 (was probably 50+ before)
```

---

## Fix #2: Search Optimization Service (For Point Lookups)

If Marketing also does exact lookups like `WHERE REGION = 'EMEA'`:

```sql
ALTER TABLE SALES_DB.PUBLIC.SALES_HISTORY
  ADD SEARCH OPTIMIZATION ON EQUALITY(REGION);
```

This creates a "search access path" -- think of it like an index. Works best for equality predicates (`=`, `IN`) on high-cardinality columns. Complements clustering, doesn't replace it.

---

## Fix #3: Materialized View (Pre-computed Aggregation)

If the Marketing query always aggregates (SUM, COUNT) by REGION and DATE, pre-compute the result instead of scanning 5B rows every morning.

```sql
CREATE OR REPLACE MATERIALIZED VIEW SALES_DB.PUBLIC.MV_SALES_BY_REGION_DATE
AS
SELECT
    REGION,
    SALE_DATE,
    COUNT(*)          AS TOTAL_TRANSACTIONS,
    SUM(SALE_AMOUNT)  AS TOTAL_REVENUE,
    AVG(SALE_AMOUNT)  AS AVG_ORDER_VALUE
FROM SALES_DB.PUBLIC.SALES_HISTORY
GROUP BY REGION, SALE_DATE;
```

Now the Marketing query hits the MV (maybe ~1M rows) instead of 5B rows. Snowflake auto-maintains it when base table changes.

```sql
-- Marketing team now queries:
SELECT *
FROM SALES_DB.PUBLIC.MV_SALES_BY_REGION_DATE
WHERE REGION = 'APAC'
  AND SALE_DATE BETWEEN '2025-01-01' AND '2025-01-31';
-- Result: sub-second, no warehouse scaling needed.
```

---

## Fix #4: Result Caching

The Marketing team runs the SAME query every morning. Snowflake caches results for 24 hours automatically.

```sql
-- Ensure result caching is ON (it's ON by default):
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
```

- **First run:** executes fully (say 8 seconds after clustering).
- **Second run (same query, same data):** 0 seconds -- served from cache.
- Cache invalidates only when underlying data changes.

**Important:** Cache is per-user and per-query-text. Standardize the Marketing team's query so everyone gets cache hits.

---

## Fix #5: Query Design Best Practices

Sometimes the query itself is the problem.

```sql
-- BAD: SELECT * (scans all columns across all micro-partitions)
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC' AND SALE_DATE = '2025-03-01';

-- GOOD: Select only needed columns (columnar storage skips unneeded columns)
SELECT SALE_DATE, REGION, SALE_AMOUNT, CUSTOMER_ID
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC' AND SALE_DATE = '2025-03-01';
```

```sql
-- BAD: Functions on filter columns kill partition pruning
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE YEAR(SALE_DATE) = 2025 AND MONTH(SALE_DATE) = 3;

-- GOOD: Use direct range predicates (enables pruning)
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE SALE_DATE BETWEEN '2025-03-01' AND '2025-03-31';
```

```sql
-- BAD: Casting the column prevents pruning
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE CAST(REGION AS VARCHAR) = 'APAC';

-- GOOD: Cast the literal, not the column
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC';
```

---

## Fix #6: Partition-Aware Table Design

If you're still migrating, load data sorted by the query pattern. When loading via COPY INTO, sort the source files by REGION, SALE_DATE. This gives you "natural clustering" for free -- no ongoing recluster cost.

```sql
CREATE OR REPLACE TABLE SALES_DB.PUBLIC.SALES_HISTORY_OPTIMIZED
  CLUSTER BY (REGION, TO_DATE(SALE_DATE))
AS
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
ORDER BY REGION, SALE_DATE;
```

---

## Performance Improvement Summary

| Technique | Impact | Cost | When to Use |
|---|---|---|---|
| Clustering Key | 10-100x | Auto-maint credits | Large tables with repeated filter patterns |
| Search Optimization | 5-10x | Storage + compute | Point lookups, equality filters on high-cardinality |
| Materialized View | 100-1000x | Storage + refresh | Repeated aggregation queries |
| Result Cache | Infinite | Free | Identical repeated queries |
| Query Rewrite | 2-10x | Free | Always -- first thing to check |
| Sorted Data Load | 10-50x | One-time | During migration / initial load |

**For this scenario, the winning combination is:**

1. Add `CLUSTER BY (REGION, TO_DATE(SALE_DATE))` -- fixes partition pruning
2. Create Materialized View for the daily report -- pre-computes the answer
3. Standardize the query text -- maximizes cache hits

**Expected result:** Query goes from TIMEOUT -> under 5 seconds. Warehouse stays at X-Small. Budget saved.

---

## Performance Test: Before vs After Clustering Key

Run this end-to-end to measure the real impact of clustering. Uses `QUERY_HISTORY` to capture exact execution metrics.

### Prep: Disable Result Cache

```sql
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
```

---

### Phase 1: Capture "Before" Baseline (No Clustering)

```sql
ALTER TABLE SALES_DB.PUBLIC.SALES_HISTORY DROP CLUSTERING KEY;

-- Record clustering state BEFORE
SELECT 'BEFORE_CLUSTERING' AS PHASE,
       PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION(
           'SALES_DB.PUBLIC.SALES_HISTORY', '(REGION, SALE_DATE)')) AS CLUSTER_INFO;
```

**Run 1:** Filter by single REGION + DATE range (Marketing's daily query)

```sql
SELECT /*+ LABEL='PERF_TEST_BEFORE_CLUSTER_RUN1' */
    REGION,
    SALE_DATE,
    SUM(SALE_AMOUNT)  AS TOTAL_REVENUE,
    COUNT(*)          AS TOTAL_TRANSACTIONS
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC'
  AND SALE_DATE BETWEEN '2025-01-01' AND '2025-01-31'
GROUP BY REGION, SALE_DATE
ORDER BY SALE_DATE;
```

**Run 2:** Multi-region comparison (common follow-up query)

```sql
SELECT /*+ LABEL='PERF_TEST_BEFORE_CLUSTER_RUN2' */
    REGION,
    SUM(SALE_AMOUNT)  AS TOTAL_REVENUE,
    COUNT(*)          AS TOTAL_TRANSACTIONS,
    AVG(SALE_AMOUNT)  AS AVG_ORDER_VALUE
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION IN ('APAC', 'EMEA', 'NA')
  AND SALE_DATE BETWEEN '2025-01-01' AND '2025-03-31'
GROUP BY REGION
ORDER BY TOTAL_REVENUE DESC;
```

**Run 3:** Single-day drill-down (point lookup pattern)

```sql
SELECT /*+ LABEL='PERF_TEST_BEFORE_CLUSTER_RUN3' */
    REGION,
    SALE_DATE,
    CUSTOMER_ID,
    SALE_AMOUNT
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'EMEA'
  AND SALE_DATE = '2025-02-15'
ORDER BY SALE_AMOUNT DESC
LIMIT 100;
```

**Capture BEFORE metrics from QUERY_HISTORY:**

```sql
SELECT
    QUERY_TAG,
    QUERY_TEXT,
    TOTAL_ELAPSED_TIME / 1000                       AS ELAPSED_SECONDS,
    BYTES_SCANNED / POWER(1024, 3)                  AS GB_SCANNED,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(PARTITIONS_SCANNED / PARTITIONS_TOTAL * 100, 2) AS PCT_PARTITIONS_SCANNED,
    BYTES_SPILLED_TO_LOCAL_STORAGE / POWER(1024, 2) AS MB_SPILLED_LOCAL,
    BYTES_SPILLED_TO_REMOTE_STORAGE / POWER(1024, 2) AS MB_SPILLED_REMOTE,
    ROWS_PRODUCED,
    COMPILATION_TIME / 1000                         AS COMPILE_SECONDS,
    EXECUTION_TIME / 1000                           AS EXEC_SECONDS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TAG LIKE 'PERF_TEST_BEFORE_CLUSTER%'
  AND START_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
ORDER BY START_TIME;
```

---

### Phase 2: Add Clustering Key

```sql
ALTER TABLE SALES_DB.PUBLIC.SALES_HISTORY
  CLUSTER BY (REGION, TO_DATE(SALE_DATE));

-- Wait for Automatic Clustering to finish.
-- Poll until recluster_state = 'COMPLETE' or clustering depth stabilizes.
-- In production, this may take hours for 5B rows. Check periodically:
SELECT SYSTEM$CLUSTERING_INFORMATION(
    'SALES_DB.PUBLIC.SALES_HISTORY', '(REGION, SALE_DATE)');

-- Record clustering state AFTER
SELECT 'AFTER_CLUSTERING' AS PHASE,
       PARSE_JSON(SYSTEM$CLUSTERING_INFORMATION(
           'SALES_DB.PUBLIC.SALES_HISTORY', '(REGION, SALE_DATE)')) AS CLUSTER_INFO;
```

---

### Phase 3: Capture "After" Metrics (With Clustering)

**Run 1** (same query, now with clustering):

```sql
SELECT /*+ LABEL='PERF_TEST_AFTER_CLUSTER_RUN1' */
    REGION,
    SALE_DATE,
    SUM(SALE_AMOUNT)  AS TOTAL_REVENUE,
    COUNT(*)          AS TOTAL_TRANSACTIONS
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC'
  AND SALE_DATE BETWEEN '2025-01-01' AND '2025-01-31'
GROUP BY REGION, SALE_DATE
ORDER BY SALE_DATE;
```

**Run 2** (same query, now with clustering):

```sql
SELECT /*+ LABEL='PERF_TEST_AFTER_CLUSTER_RUN2' */
    REGION,
    SUM(SALE_AMOUNT)  AS TOTAL_REVENUE,
    COUNT(*)          AS TOTAL_TRANSACTIONS,
    AVG(SALE_AMOUNT)  AS AVG_ORDER_VALUE
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION IN ('APAC', 'EMEA', 'NA')
  AND SALE_DATE BETWEEN '2025-01-01' AND '2025-03-31'
GROUP BY REGION
ORDER BY TOTAL_REVENUE DESC;
```

**Run 3** (same query, now with clustering):

```sql
SELECT /*+ LABEL='PERF_TEST_AFTER_CLUSTER_RUN3' */
    REGION,
    SALE_DATE,
    CUSTOMER_ID,
    SALE_AMOUNT
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'EMEA'
  AND SALE_DATE = '2025-02-15'
ORDER BY SALE_AMOUNT DESC
LIMIT 100;
```

**Capture AFTER metrics from QUERY_HISTORY:**

```sql
SELECT
    QUERY_TAG,
    QUERY_TEXT,
    TOTAL_ELAPSED_TIME / 1000                       AS ELAPSED_SECONDS,
    BYTES_SCANNED / POWER(1024, 3)                  AS GB_SCANNED,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(PARTITIONS_SCANNED / PARTITIONS_TOTAL * 100, 2) AS PCT_PARTITIONS_SCANNED,
    BYTES_SPILLED_TO_LOCAL_STORAGE / POWER(1024, 2) AS MB_SPILLED_LOCAL,
    BYTES_SPILLED_TO_REMOTE_STORAGE / POWER(1024, 2) AS MB_SPILLED_REMOTE,
    ROWS_PRODUCED,
    COMPILATION_TIME / 1000                         AS COMPILE_SECONDS,
    EXECUTION_TIME / 1000                           AS EXEC_SECONDS
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE QUERY_TAG LIKE 'PERF_TEST_AFTER_CLUSTER%'
  AND START_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
ORDER BY START_TIME;
```

---

### Phase 4: Side-by-Side Comparison Report

```sql
WITH before_runs AS (
    SELECT
        REPLACE(QUERY_TAG, 'PERF_TEST_BEFORE_CLUSTER_', '') AS RUN_ID,
        TOTAL_ELAPSED_TIME / 1000                            AS ELAPSED_SEC,
        BYTES_SCANNED / POWER(1024, 3)                       AS GB_SCANNED,
        PARTITIONS_SCANNED,
        PARTITIONS_TOTAL,
        ROWS_PRODUCED
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE QUERY_TAG LIKE 'PERF_TEST_BEFORE_CLUSTER_RUN%'
      AND START_TIME >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
),
after_runs AS (
    SELECT
        REPLACE(QUERY_TAG, 'PERF_TEST_AFTER_CLUSTER_', '') AS RUN_ID,
        TOTAL_ELAPSED_TIME / 1000                           AS ELAPSED_SEC,
        BYTES_SCANNED / POWER(1024, 3)                      AS GB_SCANNED,
        PARTITIONS_SCANNED,
        PARTITIONS_TOTAL,
        ROWS_PRODUCED
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
    WHERE QUERY_TAG LIKE 'PERF_TEST_AFTER_CLUSTER_RUN%'
      AND START_TIME >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
)
SELECT
    b.RUN_ID,
    b.ELAPSED_SEC                                              AS BEFORE_SECONDS,
    a.ELAPSED_SEC                                              AS AFTER_SECONDS,
    ROUND((b.ELAPSED_SEC - a.ELAPSED_SEC) / b.ELAPSED_SEC * 100, 1) AS PCT_IMPROVEMENT,
    ROUND(b.ELAPSED_SEC / NULLIF(a.ELAPSED_SEC, 0), 1)        AS SPEEDUP_FACTOR,
    b.GB_SCANNED                                               AS BEFORE_GB_SCANNED,
    a.GB_SCANNED                                               AS AFTER_GB_SCANNED,
    b.PARTITIONS_SCANNED                                       AS BEFORE_PARTITIONS,
    a.PARTITIONS_SCANNED                                       AS AFTER_PARTITIONS,
    b.PARTITIONS_TOTAL                                         AS TOTAL_PARTITIONS,
    ROUND(b.PARTITIONS_SCANNED / b.PARTITIONS_TOTAL * 100, 1) AS BEFORE_PCT_SCANNED,
    ROUND(a.PARTITIONS_SCANNED / a.PARTITIONS_TOTAL * 100, 1) AS AFTER_PCT_SCANNED
FROM before_runs b
JOIN after_runs a ON b.RUN_ID = a.RUN_ID
ORDER BY b.RUN_ID;
```

### Expected Output (approximate for 5B row table)

| RUN_ID | BEFORE_SEC | AFTER_SEC | PCT_IMPROVEMENT | SPEEDUP | BEFORE_GB | AFTER_GB | BEFORE_PARTS | AFTER_PARTS | BEFORE_%_SCANNED | AFTER_%_SCANNED |
|--------|------------|-----------|-----------------|---------|-----------|----------|--------------|-------------|------------------|-----------------|
| RUN1   | 120.0      | 3.2       | 97.3%           | 37.5x   | 450.0     | 8.5      | 9,800,000    | 185,000     | 100.0%           | 1.9%            |
| RUN2   | 180.0      | 8.1       | 95.5%           | 22.2x   | 450.0     | 25.0     | 9,800,000    | 560,000     | 100.0%           | 5.7%            |
| RUN3   | 95.0       | 1.5       | 98.4%           | 63.3x   | 450.0     | 2.1      | 9,800,000    | 48,000      | 100.0%           | 0.5%            |

**Key takeaway:** Partition pruning drops from 100% scanned to <6% scanned. That's the entire optimization -- fewer partitions = less I/O = faster query.

### Cleanup

```sql
-- Re-enable result cache for normal operations
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
```
