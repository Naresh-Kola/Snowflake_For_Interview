# How Data Is Stored in Snowflake -- Complete Guide with Examples

## 1. Snowflake's 3-Layer Architecture

```
+---------------------------------------------------------------+
|                    LAYER 3: CLOUD SERVICES                     |
|  (Authentication, Metadata, Query Parsing, Optimization,       |
|   Access Control, Infrastructure Management)                   |
|                                                                |
|  Stores: metadata about every micro-partition                  |
|    - MIN/MAX values per column per partition                   |
|    - Row count, distinct count, NULL count                     |
|    - Byte size, compression info                               |
+---------------------------------------------------------------+
         |                                          |
         v                                          v
+-----------------------------+   +-----------------------------+
|   LAYER 2: QUERY           |   |   LAYER 2: QUERY           |
|   PROCESSING               |   |   PROCESSING               |
|   (Virtual Warehouses)     |   |   (Virtual Warehouses)     |
|                            |   |                            |
|   Compute nodes that       |   |   Each warehouse is        |
|   READ from storage,       |   |   independent, can scale   |
|   process, and return      |   |   up/down/out separately   |
+-----------------------------+   +-----------------------------+
         |                                          |
         +------------------+-----------------------+
                            |
                            v
+---------------------------------------------------------------+
|                   LAYER 1: STORAGE                             |
|              (Cloud Object Storage: S3 / Azure Blob / GCS)    |
|                                                                |
|   All data stored as MICRO-PARTITIONS (immutable files)       |
|   in COLUMNAR FORMAT, compressed and encrypted                |
+---------------------------------------------------------------+
```

**Key Insight:** Storage and compute are FULLY SEPARATED. You pay for storage ($/TB/month) and compute ($/credit/hour) independently.

---

## 2. Micro-Partitions: The Fundamental Storage Unit

Every table in Snowflake is automatically divided into micro-partitions. There is NO manual partitioning. Snowflake handles it transparently.

### Micro-Partition Properties

| Property | Value |
|---|---|
| Size | 50 MB - 500 MB (uncompressed) |
| Format | Columnar (like Parquet) |
| Immutable | Never modified in-place |
| Compressed | Automatic per-column |
| Encrypted | AES-256 at rest |

### Example: Inserting 12 rows into a table

```sql
CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.ORDERS (
    ORDER_ID    INT,
    CUSTOMER    VARCHAR,
    REGION      VARCHAR,
    AMOUNT      DECIMAL(10,2),
    ORDER_DATE  DATE
);

INSERT INTO DEMO_DB.PUBLIC.ORDERS VALUES
    (1,  'Alice',   'APAC',  150.00, '2025-01-05'),
    (2,  'Bob',     'EMEA',  230.00, '2025-01-10'),
    (3,  'Charlie', 'NA',    310.00, '2025-01-15'),
    (4,  'Diana',   'APAC',  175.00, '2025-01-20'),
    (5,  'Eve',     'EMEA',  420.00, '2025-02-01'),
    (6,  'Frank',   'NA',    290.00, '2025-02-05'),
    (7,  'Grace',   'APAC',   95.00, '2025-02-10'),
    (8,  'Hank',    'EMEA',  510.00, '2025-02-15'),
    (9,  'Ivy',     'NA',    180.00, '2025-03-01'),
    (10, 'Jack',    'APAC',  340.00, '2025-03-05'),
    (11, 'Karen',   'EMEA',  275.00, '2025-03-10'),
    (12, 'Leo',     'NA',    460.00, '2025-03-15');
```

Snowflake auto-creates micro-partitions based on insertion order:

```
+----------------------------------------------------------------------+
|                        TABLE: ORDERS (12 rows)                       |
+----------------------------------------------------------------------+

 Micro-Partition 1 (MP1)          Micro-Partition 2 (MP2)
 Rows 1-4 (insertion order)       Rows 5-8
 +---------------------------+    +---------------------------+
 | ORDER_ID: [1, 2, 3, 4]   |    | ORDER_ID: [5, 6, 7, 8]   |
 | CUSTOMER: [Alice...Diana] |    | CUSTOMER: [Eve...Hank]    |
 | REGION:   [APAC,EMEA,NA, |    | REGION:   [EMEA,NA,APAC,  |
 |            APAC]          |    |            EMEA]           |
 | AMOUNT:   [150..310]      |    | AMOUNT:   [95..510]       |
 | DATE:     [Jan05..Jan20]  |    | DATE:     [Feb01..Feb15]  |
 +---------------------------+    +---------------------------+

 Micro-Partition 3 (MP3)
 Rows 9-12
 +---------------------------+
 | ORDER_ID: [9, 10, 11, 12]|
 | CUSTOMER: [Ivy...Leo]    |
 | REGION:   [NA,APAC,EMEA, |
 |            NA]            |
 | AMOUNT:   [180..460]      |
 | DATE:     [Mar01..Mar15]  |
 +---------------------------+
```

---

## 3. Columnar Storage: How Data is Physically Organized Inside a Partition

### Traditional Row Storage (MySQL, PostgreSQL)

Each ROW is stored together on disk:

```
Row 1: | 1 | Alice   | APAC | 150.00 | 2025-01-05 |
Row 2: | 2 | Bob     | EMEA | 230.00 | 2025-01-10 |
Row 3: | 3 | Charlie | NA   | 310.00 | 2025-01-15 |
Row 4: | 4 | Diana   | APAC | 175.00 | 2025-01-20 |
```

### Snowflake Columnar Storage

Each COLUMN is stored independently within the micro-partition:

```
+------- Micro-Partition 1 (on disk) --------+
|                                             |
|  Column "ORDER_ID" :  [1, 2, 3, 4]         |  <-- stored together, compressed
|  Column "CUSTOMER" :  [Alice,Bob,Charlie,   |  <-- stored together, compressed
|                        Diana]               |
|  Column "REGION"   :  [APAC,EMEA,NA,APAC]  |  <-- stored together, compressed
|  Column "AMOUNT"   :  [150,230,310,175]     |  <-- stored together, compressed
|  Column "ORDER_DATE": [Jan05,Jan10,Jan15,   |  <-- stored together, compressed
|                        Jan20]               |
+---------------------------------------------+
```

### Why This Matters

```sql
-- Query: SELECT SUM(AMOUNT) FROM ORDERS WHERE REGION = 'APAC';

-- ROW store:  Must read ALL 5 columns for every row     = 100% data read
-- COLUMNAR:   Only reads REGION + AMOUNT columns        = 40% data read

-- On a table with 50 columns, reading 2 columns = only 4% of the data!
```

Prove it -- compare scanning with `SELECT *` vs specific columns (check `BYTES_SCANNED` in Query Profile):

```sql
SELECT * FROM DEMO_DB.PUBLIC.ORDERS WHERE REGION = 'APAC';

SELECT REGION, SUM(AMOUNT) FROM DEMO_DB.PUBLIC.ORDERS
WHERE REGION = 'APAC' GROUP BY REGION;
```

---

## 4. Metadata Layer: The Secret to Snowflake's Speed

For EVERY micro-partition, Snowflake's Cloud Services layer stores:

```
+---------------------------------------------------------------+
|                  METADATA (per micro-partition)                |
+---------------------------------------------------------------+
| Column       | MIN        | MAX        | DISTINCT | NULLs     |
|--------------|------------|------------|----------|-----------|
| ORDER_ID     | 1          | 4          | 4        | 0         |
| CUSTOMER     | Alice      | Diana      | 4        | 0         |
| REGION       | APAC       | NA         | 3        | 0         |
| AMOUNT       | 150.00     | 310.00     | 4        | 0         |
| ORDER_DATE   | 2025-01-05 | 2025-01-20 | 4        | 0         |
+---------------------------------------------------------------+
| Row count:   4                                                |
| Size:        ~2 KB compressed                                 |
+---------------------------------------------------------------+
```

This metadata enables **partition pruning**: Snowflake reads ONLY the metadata (not the data!) to decide which micro-partitions to skip.

### Example: How Pruning Works

```
Query: SELECT * FROM ORDERS WHERE ORDER_DATE = '2025-03-10';

Step 1: Check metadata for each micro-partition:

MP1: ORDER_DATE range [2025-01-05 to 2025-01-20]
     -> 2025-03-10 NOT in range -> SKIP (pruned!)

MP2: ORDER_DATE range [2025-02-01 to 2025-02-15]
     -> 2025-03-10 NOT in range -> SKIP (pruned!)

MP3: ORDER_DATE range [2025-03-01 to 2025-03-15]
     -> 2025-03-10 IS in range  -> SCAN this partition

Result: Only 1 out of 3 partitions scanned = 67% pruned!
On a 5B row table with 10M partitions, this means scanning ~3M instead of 10M.
```

---

## 5. Immutability: How Updates and Deletes Work

Micro-partitions are **immutable** -- they are NEVER modified in place. Every INSERT, UPDATE, DELETE creates NEW micro-partitions.

### Example: UPDATE a single row

```sql
UPDATE ORDERS SET AMOUNT = 999.99 WHERE ORDER_ID = 2;
```

```
BEFORE:
MP1: [Row1, Row2, Row3, Row4]   <-- Row2 has AMOUNT=230.00

AFTER:
MP1: [Row1, Row2, Row3, Row4]   <-- marked as DELETED (kept for Time Travel)
MP1': [Row1, Row2', Row3, Row4] <-- NEW partition, Row2 has AMOUNT=999.99

+------------------+       +-------------------+
| MP1 (old)        |       | MP1' (new)        |
| Row2: AMT=230.00 | ----> | Row2: AMT=999.99  |
| STATUS: DELETED  |       | STATUS: ACTIVE     |
| (Time Travel)    |       |                    |
+------------------+       +-------------------+
```

The old partition stays for Time Travel (default 1 day) then moves to Fail-safe (7 days) before being permanently deleted.

```sql
-- See this in action:
UPDATE DEMO_DB.PUBLIC.ORDERS SET AMOUNT = 999.99 WHERE ORDER_ID = 2;

-- You can query the PREVIOUS version using Time Travel:
SELECT * FROM DEMO_DB.PUBLIC.ORDERS AT(OFFSET => -60)
WHERE ORDER_ID = 2;
```

---

## 6. Data Lifecycle: Active -> Time Travel -> Fail-safe

```
+============+     +--------------+     +-------------+     +---------+
|   ACTIVE   | --> | TIME TRAVEL  | --> |  FAIL-SAFE  | --> | PURGED  |
| (queryable)|     | (1-90 days)  |     | (7 days)    |     | (gone)  |
|            |     | UNDROP works |     | SF support  |     |         |
+============+     +--------------+     +-------------+     +---------+
```

| Phase | Description |
|---|---|
| **Active** | Current data you can query. Billed as storage. |
| **Time Travel** | Deleted/changed data retained for recovery. You can query historical data or UNDROP tables. Configurable: 0-1 day (Standard), 0-90 days (Enterprise). |
| **Fail-safe** | After Time Travel expires. Only Snowflake support can recover. Always 7 days. NOT configurable. Permanent tables only. |
| **Purged** | Data permanently deleted. No recovery possible. |

### Check storage breakdown for a table

```sql
SELECT
    TABLE_NAME,
    ACTIVE_BYTES / POWER(1024,2)       AS ACTIVE_MB,
    TIME_TRAVEL_BYTES / POWER(1024,2)  AS TIME_TRAVEL_MB,
    FAILSAFE_BYTES / POWER(1024,2)     AS FAILSAFE_MB,
    RETAINED_FOR_CLONE_BYTES / POWER(1024,2) AS CLONE_MB
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME = 'ORDERS'
  AND TABLE_CATALOG = 'DEMO_DB'
ORDER BY ACTIVE_BYTES DESC;
```

---

## 7. Clustering: Natural vs Explicit

### Natural Clustering

Data is clustered by insertion order automatically. If you load data sorted by DATE, it's naturally clustered by DATE.

```
Load order: Jan -> Feb -> Mar

MP1: [Jan 01-10]  MP2: [Jan 11-20]  MP3: [Jan 21-31]
MP4: [Feb 01-10]  MP5: [Feb 11-20]  MP6: [Feb 21-28]
MP7: [Mar 01-10]  MP8: [Mar 11-20]  MP9: [Mar 21-31]

Query: WHERE DATE BETWEEN 'Feb-01' AND 'Feb-28'
Pruned: MP1,2,3,7,8,9 -> Only scans MP4,5,6 (3 out of 9 = 67% pruned)
```

### Problem: Random load order

```
MP1: [Jan,Mar,Feb]  MP2: [Feb,Jan,Mar]  MP3: [Mar,Jan,Feb]

Query: WHERE DATE BETWEEN 'Feb-01' AND 'Feb-28'
ALL micro-partitions have Feb data -> 0% pruned -> FULL TABLE SCAN!
```

### Explicit Clustering Key

Reorganizes micro-partitions by chosen columns:

```sql
ALTER TABLE ORDERS CLUSTER BY (REGION, ORDER_DATE);
```

```
BEFORE (random):
+--------+--------+--------+--------+--------+--------+
| MP1    | MP2    | MP3    | MP4    | MP5    | MP6    |
| APAC   | EMEA   | APAC   | NA     | EMEA   | NA     |
| Jan    | Jan    | Feb    | Jan    | Feb    | Mar    |
| EMEA   | NA     | NA     | APAC   | APAC   | EMEA   |
| Mar    | Feb    | Mar    | Mar    | Jan    | Feb    |
+--------+--------+--------+--------+--------+--------+
REGION ranges overlap across ALL partitions -> no pruning on REGION

AFTER (clustered):
+--------+--------+--------+--------+--------+--------+
| MP1    | MP2    | MP3    | MP4    | MP5    | MP6    |
| APAC   | APAC   | EMEA   | EMEA   | NA     | NA     |
| Jan    | Feb-   | Jan    | Feb-   | Jan    | Feb-   |
| APAC   | Mar    | EMEA   | Mar    | NA     | Mar    |
| Jan    | APAC   | Jan    | EMEA   | Jan    | NA     |
+--------+--------+--------+--------+--------+--------+
REGION='APAC' -> only scans MP1,MP2 (2 out of 6 = 67% pruned!)
```

```sql
-- Check natural clustering of a table:
SELECT SYSTEM$CLUSTERING_INFORMATION('DEMO_DB.PUBLIC.ORDERS', '(REGION, ORDER_DATE)');
```

---

## 8. Compression: How Snowflake Shrinks Your Data

Each column in each micro-partition is compressed independently. Snowflake auto-selects the best algorithm per column type:

| Column Type | Likely Algorithm | Typical Ratio |
|---|---|---|
| INTEGER | Delta / Run-Length | 5-10x |
| VARCHAR (low cardinality) | Dictionary Encoding | 10-50x |
| VARCHAR (high cardinality) | LZ4 / ZSTD | 3-5x |
| DATE/TIMESTAMP | Delta Encoding | 5-10x |
| BOOLEAN | Bitmap | 20-50x |
| FLOAT/DOUBLE | Byte-Dict / ZSTD | 2-4x |

### Example: REGION column (only 3 distinct values: APAC, EMEA, NA)

```
Raw:        APAC, EMEA, NA, APAC, EMEA, NA, APAC, ... (5B rows)
Dictionary: {0=APAC, 1=EMEA, 2=NA} + [0,1,2,0,1,2,0,...] (2 bits/row)

5B rows x 4 chars avg = 20 GB raw
5B rows x 2 bits      = 1.25 GB compressed  = 16x compression!
```

### Check actual vs compressed sizes

```sql
SELECT
    TABLE_NAME,
    ROW_COUNT,
    BYTES / POWER(1024,2) AS COMPRESSED_MB,
    (BYTES * 3) / POWER(1024,2) AS ESTIMATED_RAW_MB
FROM INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'PUBLIC'
  AND TABLE_NAME = 'ORDERS';
```

---

## 9. Zero-Copy Cloning: Storage Efficiency

Cloning a table does NOT duplicate data -- it shares micro-partitions.

```
ORIGINAL TABLE                    CLONED TABLE
+--------+--------+--------+     +--------+--------+--------+
|  MP1   |  MP2   |  MP3   |     |  MP1   |  MP2   |  MP3   |
+--------+--------+--------+     +--------+--------+--------+
     |        |        |              |        |        |
     +--------+--------+--------------+--------+--------+
                       |
               SAME physical storage
               (no extra bytes used!)
```

Only when you MODIFY one side do the micro-partitions diverge:

```sql
UPDATE CLONE SET AMOUNT = 0 WHERE ORDER_ID = 1;
```

```
ORIGINAL                          CLONE (after update)
+--------+--------+--------+     +--------'+--------+--------+
|  MP1   |  MP2   |  MP3   |     |  MP1'  |  MP2   |  MP3   |
+--------+--------+--------+     +--------'+--------+--------+
     |        |        |              |         |        |
     |        +--------+--------------+---------+--------+
     |                                |
 MP1 (original)                  MP1' (new, diverged)
```

```sql
CREATE TABLE DEMO_DB.PUBLIC.ORDERS_CLONE CLONE DEMO_DB.PUBLIC.ORDERS;
```

---

## 10. Complete Picture: End-to-End Data Flow

### When a User Inserts Data

```
USER INSERTS DATA
     |
     v
+------------------+
| Cloud Services   |  1. Parse SQL, optimize query plan
| Layer            |  2. Determine which warehouse to use
+------------------+
     |
     v
+------------------+
| Virtual          |  3. Warehouse processes the INSERT
| Warehouse        |  4. Organizes rows into micro-partitions
|                  |  5. Compresses each column independently
|                  |  6. Encrypts the micro-partition
+------------------+
     |
     v
+------------------+
| Cloud Storage    |  7. Writes immutable micro-partition file
| (S3/Azure/GCS)  |     (50-500 MB compressed)
+------------------+
     |
     v
+------------------+
| Cloud Services   |  8. Records metadata:
| (Metadata)       |     - MIN/MAX per column
+------------------+     - Row count, distinct values
                         - File location, size, compression
```

### When a User Queries Data

```
USER QUERIES DATA
     |
     v
+------------------+
| Cloud Services   |  1. Parse SQL
|                  |  2. Check RESULT CACHE -> if hit, return immediately
|                  |  3. Read METADATA to identify relevant partitions
|                  |  4. PRUNE partitions that don't match WHERE clause
+------------------+
     |
     v
+------------------+
| Virtual          |  5. Read ONLY the needed micro-partitions
| Warehouse        |  6. Read ONLY the needed columns (columnar scan)
|  - SSD Cache     |  7. Check LOCAL DISK CACHE first
|  - Compute       |  8. If not cached, fetch from cloud storage
+------------------+  9. Process (filter, aggregate, join, sort)
     |
     v
+------------------+
| Cloud Services   |  10. Store result in RESULT CACHE (24 hours)
|                  |  11. Return results to user
+------------------+
```

### Summary Table

| Concept | What It Means |
|---|---|
| Micro-partition | 50-500 MB immutable compressed columnar file |
| Columnar storage | Each column stored separately for fast scans |
| Metadata | MIN/MAX/count per column per partition |
| Partition pruning | Skip partitions whose metadata doesn't match |
| Immutability | Never modify files; create new ones instead |
| Time Travel | Old partitions kept for N days for recovery |
| Fail-safe | 7 more days after Time Travel, SF-only |
| Clustering key | Reorganize partitions for better pruning |
| Compression | Auto per-column (dictionary, delta, LZ4) |
| Zero-copy clone | Share partitions until data diverges |

---

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

-- Run the Marketing team's query, then inspect the Query Profile:
SELECT *
FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC'
  AND SALE_DATE BETWEEN '2025-01-01' AND '2025-01-31';

-- After running, go to Query Profile and look for:
--   * "Percentage Scanned from Cache" (is caching being used?)
--   * "Partitions scanned" vs "Partitions total" (is pruning working?)
--   * If partitions scanned ~ partitions total => NO PRUNING = root cause
```

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

-- BAD: Functions on filter columns kill partition pruning
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE YEAR(SALE_DATE) = 2025 AND MONTH(SALE_DATE) = 3;

-- GOOD: Use direct range predicates (enables pruning)
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE SALE_DATE BETWEEN '2025-03-01' AND '2025-03-31';

-- BAD: Casting the column prevents pruning
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE CAST(REGION AS VARCHAR) = 'APAC';

-- GOOD: Cast the literal, not the column
SELECT * FROM SALES_DB.PUBLIC.SALES_HISTORY
WHERE REGION = 'APAC';
```

---

## Fix #6: Partition-Aware Table Design

If you're still migrating, load data sorted by the query pattern. This gives you "natural clustering" for free -- no ongoing recluster cost.

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

### Prep: Disable result cache

```sql
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
```

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

**Capture BEFORE metrics:**

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

### Phase 3: Capture "After" Metrics (With Clustering)

**Run 1 (same query, now with clustering):**

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

**Run 2 (same query, now with clustering):**

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

**Run 3 (same query, now with clustering):**

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

**Capture AFTER metrics:**

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

```sql
-- CLEANUP: Re-enable result cache for normal operations
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
```
