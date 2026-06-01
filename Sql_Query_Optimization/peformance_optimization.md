# Snowflake Performance Optimization — Complete Guide

> From Scratch to Architect Level

---

## Table of Contents

- [Section 1: What is Performance Optimization?](#section-1-what-is-performance-optimization)
- [Section 2: Snowflake Caching Layers](#section-2-snowflake-caching-layers)
- [Section 3: Micro-Partitions & Pruning](#section-3-micro-partitions--pruning)
- [Section 4: Clustering Keys](#section-4-clustering-keys)
- [Section 5: Query Profile & EXPLAIN](#section-5-query-profile--explain)
- [Section 6: Spilling (Local & Remote Storage)](#section-6-spilling-local--remote-storage)
- [Section 7: Warehouse Sizing & Scaling](#section-7-warehouse-sizing--scaling)
- [Section 8: Search Optimization Service](#section-8-search-optimization-service)
- [Section 9: Materialized Views](#section-9-materialized-views)
- [Section 10: Query Acceleration Service (QAS)](#section-10-query-acceleration-service-qas)
- [Section 11: Real-World Issues & Step-by-Step Solutions](#section-11-real-world-issues--step-by-step-solutions)
- [Section 12: Interview Questions — Beginner to Architect](#section-12-interview-questions--beginner-to-architect)
- [Bonus: Performance Optimization Cheat Sheet](#bonus-performance-optimization-cheat-sheet)

---

## Section 1: What is Performance Optimization?

### Simple Definition

Performance Optimization = Making queries run FASTER while using FEWER resources.

Think of it like driving a car:
- SLOW QUERY = traffic jam on a single-lane road
- OPTIMIZED QUERY = highway with multiple lanes, no traffic

### Why It Matters

1. Faster queries = happier users
2. Less compute time = lower costs (Snowflake charges per-second)
3. Better resource usage = more concurrent users supported

### The 3 Pillars of Snowflake Performance

```
┌──────────────────────────────────────────────────────────┐
│  1. REDUCE DATA SCANNED   → Pruning, Clustering, Caching│
│  2. REDUCE COMPUTE NEEDED → Query rewrite, Projections  │
│  3. RIGHT-SIZE RESOURCES  → Warehouse sizing, Scaling    │
└──────────────────────────────────────────────────────────┘
```

### Pillar 1: Reduce Data Scanned

**WHAT:** Make Snowflake read FEWER micro-partitions and columns.

**HOW:** Pruning (skip irrelevant partitions), Clustering (organize data so pruning works better), Caching (avoid reading storage at all).

```sql
-- BAD:  Scans entire table
SELECT * FROM sales;

-- GOOD: Scans ~1% of partitions
SELECT amount FROM sales WHERE date = '2024-01-01';
```

### Pillar 2: Reduce Compute Needed

**WHAT:** Make the QUERY ITSELF do less work (change your SQL, not the warehouse).

**HOW:** Project only needed columns, remove unnecessary ORDER BY, fix bad JOINs, replace heavy CTEs with temp tables.

```sql
-- BAD: SELECT * reads 100 columns, JOIN on date causes row explosion
SELECT * FROM orders JOIN items ON orders.date = items.date;

-- GOOD: 2 columns only, correct JOIN key, minimal compute
SELECT o.order_id, i.product_id
FROM orders o
JOIN items i ON o.order_id = i.order_id;
```

### Pillar 3: Right-Size Resources

**WHAT:** Give the query the RIGHT AMOUNT of warehouse power (change the warehouse, not the query).

**HOW:** Scale UP (bigger warehouse for heavy single queries), Scale OUT (multi-cluster for many concurrent queries).

**Example:**
- A perfectly optimized query still takes 10 min on XS warehouse → Same query takes 2 min on LARGE warehouse (more memory, no spilling)
- 50 users queuing on 1 cluster → add multi-cluster (1-5) to remove queues

### Analogy: Moving Furniture

```
┌─────────────────────────────────────────────────────────────────┐
│  REDUCE DATA SCANNED = Only move rooms you're renovating        │
│                        → You SKIPPED unnecessary work           │
│                                                                 │
│  REDUCE COMPUTE      = Pack fewer boxes (only take what u need) │
│                        → You made the JOB smaller               │
│                                                                 │
│  RIGHT-SIZE RESOURCES = Hire a bigger truck or more movers      │
│                        → You gave the job MORE POWER            │
│                                                                 │
│  ORDER: Always reduce data first, then optimize query,          │
│         then resize warehouse LAST (costs more credits).        │
└─────────────────────────────────────────────────────────────────┘
```

---

## Section 2: Snowflake Caching Layers

Snowflake has 3 layers of caching. Each layer avoids work at a different stage.

### Layer 1: Metadata Cache (Cloud Services Layer)

| Property | Value |
|----------|-------|
| **WHAT** | Stores min/max values, row counts, file references |
| **WHERE** | Cloud Services layer (always on, no warehouse needed) |
| **WHEN** | Queries like COUNT(*), MIN(), MAX() on full table |
| **COST** | FREE (no warehouse credits consumed) |
| **DURATION** | Always available as long as table exists |

```sql
-- This uses metadata cache - NO warehouse needed!
SELECT COUNT(*) FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS;
-- Result returns instantly because Snowflake already knows the row count.

SELECT MIN(O_ORDERDATE), MAX(O_ORDERDATE)
FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS;
-- MIN/MAX on full table = metadata cache hit.
```

### Layer 2: Result Cache (Cloud Services Layer)

| Property | Value |
|----------|-------|
| **WHAT** | Stores the EXACT result of previously run queries |
| **WHERE** | Cloud Services layer (persisted for 24 hours) |
| **WHEN** | Same query, same data (no changes), same role |
| **COST** | FREE (no warehouse credits consumed) |
| **DURATION** | 24 hours (resets each time the cache is hit) |

**Conditions for cache hit:**
- Exact same SQL text
- Underlying data has NOT changed
- Same role executing the query
- No functions like CURRENT_TIMESTAMP() that change

```sql
-- Run this query twice - second run is instant (result cache)
SELECT O_ORDERPRIORITY, COUNT(*) AS order_count
FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS
GROUP BY O_ORDERPRIORITY
ORDER BY order_count DESC;
```

**What BREAKS result cache:**
1. Any DML on the table (INSERT, UPDATE, DELETE, MERGE)
2. Different query text (even extra space or different case in some contexts)
3. Using volatile functions: CURRENT_TIMESTAMP(), RANDOM(), UUID_STRING()
4. Different role
5. Query has a WHERE clause with CURRENT_DATE (changes daily)

```sql
-- Disable result cache for testing:
ALTER SESSION SET USE_CACHED_RESULT = FALSE;

-- Re-enable result cache:
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
```

### Layer 3: Warehouse (Local Disk) Cache

| Property | Value |
|----------|-------|
| **WHAT** | Raw data cached on warehouse SSD after first read |
| **WHERE** | Local SSD of the virtual warehouse nodes |
| **WHEN** | Similar queries scan same micro-partitions |
| **COST** | Warehouse must be RUNNING (credits consumed) |
| **DURATION** | Until warehouse is suspended or resized |
| **BENEFIT** | Avoids reading from remote cloud storage (S3/Blob) |

```sql
-- First query loads data into warehouse cache
SELECT *
FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.LINEITEM
WHERE L_SHIPDATE BETWEEN '1995-01-01' AND '1995-01-31'
LIMIT 1000;

-- Second query on same data range benefits from warehouse cache
-- (data already on local SSD - no remote storage read needed)
SELECT L_RETURNFLAG, L_LINESTATUS, SUM(L_QUANTITY) AS total_qty
FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.LINEITEM
WHERE L_SHIPDATE BETWEEN '1995-01-01' AND '1995-01-31'
GROUP BY L_RETURNFLAG, L_LINESTATUS;
```

**IMPORTANT:** If you SUSPEND the warehouse, the local disk cache is LOST! This is why auto-suspend timeout matters for performance vs cost tradeoff.

### Cache Summary Diagram

```
Query Arrives
     │
     ▼
[Metadata Cache] → Hit? → Return instantly (FREE)
     │ Miss
     ▼
[Result Cache]   → Hit? → Return stored result (FREE)
     │ Miss
     ▼
[Warehouse Cache]→ Hit? → Read from local SSD (FAST)
     │ Miss
     ▼
[Remote Storage]  → Read from S3/Azure/GCS (SLOWEST)
```

---

## Section 3: Micro-Partitions & Pruning

### Simple Definition

- **Micro-Partition** = A small chunk of data (50-500 MB compressed). Snowflake automatically splits every table into micro-partitions.
- **Pruning** = Snowflake SKIPS micro-partitions it knows don't contain the data you're looking for (using min/max metadata).

### Analogy

Think of a library:
- Micro-Partitions = individual bookshelves
- Metadata (min/max) = labels on each shelf saying "Books A-D"
- Pruning = If you want book "M", you SKIP shelves labeled "A-D"
- Without pruning = You check EVERY shelf (full table scan)

### Examples

```sql
-- GOOD PRUNING: Table naturally clustered by O_ORDERDATE
SELECT COUNT(*)
FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS
WHERE O_ORDERDATE = '1995-03-15';
-- Only scans partitions where min_date <= 1995-03-15 AND max_date >= 1995-03-15

-- BAD PRUNING: Column with random distribution across partitions
SELECT COUNT(*)
FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS
WHERE O_COMMENT LIKE '%special%';
-- O_COMMENT values scattered across ALL partitions → full scan
```

### How to Check Pruning Efficiency

Use the **Query Profile** in Snowsight UI:
1. Run your query
2. Click on "Query Profile" tab
3. Look at the TableScan node:
   - "Partitions scanned" vs "Partitions total"
   - If scanned << total → GOOD pruning
   - If scanned ≈ total → BAD pruning (full scan)

### SYSTEM$CLUSTERING_INFORMATION

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION(
  'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS',
  '(O_ORDERDATE)'
);
```

#### Metric 1: average_overlaps

How many micro-partitions have OVERLAPPING value ranges for the column.

**Analogy — boxes of numbered balls:**

LOW OVERLAP (GOOD — close to 0):
```
Box 1: balls 1-20
Box 2: balls 21-40
Box 3: balls 41-60
→ Each box has a UNIQUE range. No overlap.
→ To find ball #35, you ONLY open Box 2. FAST!
```

HIGH OVERLAP (BAD — 4 or more):
```
Box 1: balls 1-50
Box 2: balls 10-55
Box 3: balls 5-60
→ All boxes contain values in the range 10-50. They OVERLAP.
→ To find ball #35, you must open ALL 3 boxes. SLOW!
```

| Value | Meaning |
|-------|---------|
| 0 | Perfect (no partitions overlap) |
| 1-2 | Good |
| 3-5 | Moderate (consider clustering) |
| 5+ | Bad (definitely needs clustering) |

#### Metric 2: average_depth

On average, how many micro-partitions does Snowflake need to scan to find ONE specific value?

**Analogy — looking for a book titled "Snowflake Guide":**
- Depth = 1 (PERFECT): Book on ONLY 1 shelf. Check 1, done!
- Depth = 2 (GOOD): Could be on 2 shelves. Still fast.
- Depth = 10 (BAD): Could be on 10 shelves. Very slow!
- Depth = 100 (TERRIBLE): Scattered across 100 shelves. Full scan!

| Value | Meaning |
|-------|---------|
| 1 | Perfect (each value in exactly 1 partition) |
| 1-2 | Excellent pruning |
| 2-5 | Acceptable |
| 5-10 | Poor (consider adding a clustering key) |
| 10+ | Very poor (clustering key strongly recommended) |

#### Reading the JSON Output — Good Example

```json
{
  "cluster_by_keys": "(O_ORDERDATE)",
  "total_partition_count": 50,
  "total_constant_partition_count": 40,
  "average_overlaps": 1.2,
  "average_depth": 1.5
}
```

**Interpretation:**
- `total_partition_count: 50` → table has 50 micro-partitions
- `total_constant_partition_count: 40` → 40 of 50 partitions contain ONLY one distinct date value (80% "pure" — GREAT!)
- `average_overlaps: 1.2` → minimal overlap between partitions (GOOD)
- `average_depth: 1.5` → a specific date spans ~1.5 partitions (EXCELLENT)

**Formula:** total_constant_partition_count / total_partition_count → closer to 1.0 = better

**VERDICT:** This table is WELL CLUSTERED on O_ORDERDATE. No action needed.

#### Reading the JSON Output — Bad Example

```json
{
  "average_overlaps": 12.5,
  "average_depth": 25.3,
  "total_constant_partition_count": 2
}
```

**Interpretation:**
- `average_overlaps: 12.5` → partitions heavily overlap (BAD)
- `average_depth: 25.3` → each value spans ~25 partitions (TERRIBLE)
- `total_constant_partition_count: 2` → only 2 partitions are "pure" (BAD)

**VERDICT:** This table NEEDS a clustering key on this column.

**ACTION:** `ALTER TABLE my_table CLUSTER BY (the_column);`

---

## Section 4: Clustering Keys

### Simple Definition

Clustering Key = tells Snowflake HOW to physically organize data within micro-partitions so similar values are stored together.

### When to Use

- Large tables (multi-TB) with poor pruning
- Queries consistently filter on specific columns
- SYSTEM$CLUSTERING_INFORMATION shows high overlap/depth

### When NOT to Use

- Small tables (< few GB) → already fast enough
- Tables with frequent full-table scans
- Tables where data is already well-clustered naturally

### Example

```sql
CREATE OR REPLACE TABLE my_db.my_schema.sales_data (
    sale_date    DATE,
    region       VARCHAR,
    product_id   NUMBER,
    amount       DECIMAL(12,2)
)
CLUSTER BY (sale_date, region);
```

**Why (sale_date, region)?** Because most queries filter on date range + region:
```sql
WHERE sale_date BETWEEN '2024-01-01' AND '2024-03-31'
  AND region = 'US-EAST'
```
With clustering, all US-EAST data for Q1 2024 is in the SAME partitions. Without clustering, it could be scattered across thousands of partitions.

### Best Practices

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Put LOW-CARDINALITY columns FIRST (e.g., region, status)     │
│ 2. Put HIGH-CARDINALITY columns SECOND (e.g., date, id)        │
│ 3. Maximum 3-4 columns in a clustering key                      │
│ 4. Choose columns that appear in WHERE and JOIN clauses          │
│ 5. Clustering is an ONGOING service (costs credits continuously)│
└──────────────────────────────────────────────────────────────────┘
```

### Cardinality Explained

Cardinality = the number of DISTINCT (unique) values a column has.

**LOW CARDINALITY → Few unique values:**
- REGION → 'EAST', 'WEST', 'NORTH', 'SOUTH' (4 values)
- STATUS → 'ACTIVE', 'INACTIVE', 'PENDING' (3 values)
- COUNTRY → ~200 values
- IS_DELETED → TRUE, FALSE (2 values)

**HIGH CARDINALITY → Many unique values:**
- ORDER_DATE → '2020-01-01' to '2025-12-31' (2000+ values)
- CUSTOMER_ID → 1 to 10,000,000 (millions of values)
- EMAIL → almost every row is unique (very high)
- TRANSACTION_ID → unique per row (highest possible)

### Why Put Low Cardinality First?

Snowflake clusters data left-to-right in the key. Low-cardinality columns FIRST creates large, clean groups. High-cardinality SECOND sorts within those groups.

**GOOD: `CLUSTER BY (REGION, ORDER_DATE)`**
```
Partition 1: REGION='EAST',  ORDER_DATE='2025-01-01' to '2025-01-15'
Partition 2: REGION='EAST',  ORDER_DATE='2025-01-16' to '2025-01-31'
Partition 3: REGION='WEST',  ORDER_DATE='2025-01-01' to '2025-01-15'
Partition 4: REGION='WEST',  ORDER_DATE='2025-01-16' to '2025-01-31'

Query: WHERE REGION = 'EAST' AND ORDER_DATE = '2025-01-10'
Result: Snowflake prunes to Partition 1 only → FAST!
```

**BAD: `CLUSTER BY (ORDER_DATE, REGION)` — high cardinality first**
```
Partition 1: ORDER_DATE='2025-01-01', REGION='EAST','WEST','NORTH','SOUTH'
Partition 2: ORDER_DATE='2025-01-02', REGION='EAST','WEST','NORTH','SOUTH'

Query: WHERE REGION = 'EAST' → must scan ALL partitions (every date has every region)
Result: No pruning benefit for REGION filter → SLOW!
```

### Managing Clustering

```sql
-- Monitor clustering:
SELECT SYSTEM$CLUSTERING_INFORMATION('my_table', '(col1, col2)');

-- Drop clustering key if not needed:
ALTER TABLE my_table DROP CLUSTERING KEY;
```

---

## Section 5: Query Profile & EXPLAIN

### Simple Definition

Query Profile = A visual breakdown of HOW Snowflake executed your query. It shows each step, time spent, data scanned, and bottlenecks.

### How to Access

1. Run a query in Snowsight
2. Click the "Query Profile" button in the results pane
3. Each node represents an operation (TableScan, Join, Sort, etc.)

### Using EXPLAIN Plan

```sql
EXPLAIN
SELECT O_ORDERPRIORITY, COUNT(*) AS cnt
FROM SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS
WHERE O_ORDERDATE >= '1995-01-01'
GROUP BY O_ORDERPRIORITY;
```

### What to Look For in Query Profile

| Issue | Where to Find |
|-------|--------------|
| Full table scan | TableScan: scanned ≈ total partitions |
| Spilling to disk | Any node: "Bytes spilled to local" |
| Spilling to remote | Any node: "Bytes spilled to remote" |
| Row explosion in joins | Join node: output rows >> input rows |
| Slow sorting | Sort node taking majority of time |
| Cartesian product | Join without proper ON condition |
| Network transfer | Data transferred between nodes |

### Finding Slow Queries from History

```sql
SELECT
    query_id,
    SUBSTR(query_text, 1, 80) AS short_query,
    warehouse_name,
    execution_status,
    total_elapsed_time / 1000 AS elapsed_sec,
    bytes_scanned / (1024*1024*1024) AS gb_scanned,
    rows_produced,
    partitions_scanned,
    partitions_total,
    ROUND(partitions_scanned / NULLIF(partitions_total, 0) * 100, 2) AS pct_scanned,
    bytes_spilled_to_local_storage,
    bytes_spilled_to_remote_storage
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND total_elapsed_time > 60000  -- queries taking > 60 seconds
ORDER BY total_elapsed_time DESC
LIMIT 20;
```

---

## Section 6: Spilling (Local & Remote Storage)

### Simple Definition

Spilling = When a query needs MORE memory than the warehouse has, it "spills" data to disk (local SSD first, then remote cloud storage).

### Analogy

Your desk (memory) is full of papers (data):
- **Local Spill** = putting papers on the floor next to your desk (slower)
- **Remote Spill** = putting papers in a storage unit across town (VERY slow)

### Spilling Example

You have an ORDERS table (10 billion rows) and CUSTOMERS (50 million rows). Query on SMALL warehouse (8 GB memory):

```sql
SELECT c.name, SUM(o.amount)
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
GROUP BY c.name
ORDER BY SUM(o.amount) DESC;
```

**What Happens:**
1. Snowflake starts JOIN, loads chunks into 8 GB memory. But JOIN produces 10 billion rows — way more than 8 GB.
2. **LOCAL SPILL:** Writes overflow to local SSD → 2-5x SLOWER
3. **REMOTE SPILL:** If SSD fills up, writes to cloud storage → 10-50x SLOWER

### Severity

| Spill Type | Performance Impact |
|-----------|-------------------|
| No spill | BEST performance |
| Local spill | 2-5x slower |
| Remote spill | 10-50x slower (CRITICAL) |

### Fix 1: Scale Up the Warehouse

```sql
ALTER WAREHOUSE my_wh SET WAREHOUSE_SIZE = 'XLARGE';  -- 32 GB memory
-- Same query now fits in memory. No spilling. 4x faster.
```

### Fix 2: Optimize the Query

```sql
-- Pre-aggregate to reduce rows BEFORE the JOIN
WITH top_customers AS (
    SELECT customer_id, SUM(amount) AS total
    FROM orders
    WHERE order_date >= '2025-01-01'   -- filter early → fewer rows
    GROUP BY customer_id
)
SELECT c.name, t.total
FROM top_customers t
JOIN customers c ON t.customer_id = c.customer_id
ORDER BY t.total DESC;
-- Reduces 10B rows to maybe 50M rows BEFORE the JOIN. No spill needed.
```

### Find Queries That Spill

```sql
SELECT
    query_id,
    SUBSTR(query_text, 1, 80) AS short_query,
    user_name,
    warehouse_name,
    warehouse_size,
    ROUND(bytes_spilled_to_local_storage / (1024*1024*1024), 2) AS local_spill_gb,
    ROUND(bytes_spilled_to_remote_storage / (1024*1024*1024), 2) AS remote_spill_gb,
    total_elapsed_time / 1000 AS elapsed_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE (bytes_spilled_to_local_storage > 0
    OR bytes_spilled_to_remote_storage > 0)
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY bytes_spilled_to_remote_storage DESC, bytes_spilled_to_local_storage DESC
LIMIT 10;
```

### How to Fix Spilling

| Solution | When to Use |
|----------|------------|
| 1. Optimize the query (remove columns, add filters, break CTEs) | Always try FIRST |
| 2. Use a larger warehouse (XS → S → M → L → XL) | When query is already optimal |
| 3. Reduce concurrent queries | Multiple queries share memory |
| 4. Process data in batches | For very large data volumes |

### "Reduce Concurrent Queries" Explained

A warehouse has FIXED memory. Multiple queries running simultaneously SHARE it equally.

**Example — MEDIUM warehouse with 16 GB memory:**

| Scenario | Memory Per Query | Result |
|----------|-----------------|--------|
| 1 query running alone | 16 GB | NO SPILLING |
| 4 queries at same time | 4 GB each | ALL 4 SPILL to disk |
| 8 queries at same time | 2 GB each | Even worse spilling |

**Solutions:**
1. Stagger queries — don't run all reports at the same time
2. Use separate warehouses for different workloads:
   - WH_ETL (XLARGE) → heavy data loading
   - WH_ANALYSTS (MEDIUM) → analyst queries
   - WH_DASHBOARDS (SMALL) → lightweight dashboards
3. Limit concurrency:
   ```sql
   ALTER WAREHOUSE my_wh SET MAX_CONCURRENCY_LEVEL = 2;
   -- Only 2 queries run at once, rest wait in queue
   ```
4. Multi-cluster warehouse:
   ```sql
   ALTER WAREHOUSE my_wh SET
     MIN_CLUSTER_COUNT = 1
     MAX_CLUSTER_COUNT = 4;
   -- Each cluster has its own full memory → no sharing
   ```

---

## Section 7: Warehouse Sizing & Scaling

### Size Reference

| SIZE | SERVERS | CREDITS/HR | BEST FOR |
|------|---------|-----------|----------|
| X-Small | 1 | 1 | Simple queries, dev/test |
| Small | 2 | 2 | Light dashboards |
| Medium | 4 | 4 | Moderate BI workloads |
| Large | 8 | 8 | Complex queries, ETL |
| X-Large | 16 | 16 | Heavy analytics |
| 2XL | 32 | 32 | Large data processing |
| 3XL | 64 | 64 | Very large ETL |
| 4XL | 128 | 128 | Massive workloads |
| 5XL | 256 | 256 | Enterprise-scale |
| 6XL | 512 | 512 | Maximum compute |

**IMPORTANT RULE:** Bigger warehouse ≠ faster for ALL queries.
- Bigger helps: Large scans, complex joins, GROUP BY on big data
- Bigger does NOT help: Simple lookups, LIMIT queries, cached results

### Scale UP vs Scale OUT

```
┌──────────────────────────────────────────────────────────────────┐
│  Scale UP   = Use a bigger warehouse size (more power per query)│
│  Scale OUT  = Add more clusters (more concurrent queries)       │
│                                                                 │
│  WHEN TO SCALE UP:   Single query is slow                       │
│  WHEN TO SCALE OUT:  Many queries are queuing                   │
└──────────────────────────────────────────────────────────────────┘
```

### Scale UP (Increase SIZE) — Detailed

Each size DOUBLES the CPU, memory, and SSD:
- XS = bicycle (~8 GB) | S = scooter (~16 GB) | M = car (~32 GB) | L = van (~64 GB) | XL = truck (~128 GB) | 2XL = big truck (~256 GB)

```sql
-- Single complex query spills on SMALL → no spilling on XLARGE
ALTER WAREHOUSE my_wh SET WAREHOUSE_SIZE = 'XLARGE';
```

**USE WHEN:** One query is slow, spilling, or needs more compute power.

### Scale OUT (Increase CLUSTERS) — Detailed

Snowflake creates IDENTICAL copies of the warehouse. Each cluster handles different queries independently.

Think of it like adding checkout lanes at a supermarket:
- 1 cluster = 1 lane → 10 customers in 1 line
- 3 clusters = 3 lanes → customers split across 3 lines

```sql
ALTER WAREHOUSE my_wh SET
  MIN_CLUSTER_COUNT = 1
  MAX_CLUSTER_COUNT = 4;
```

**USE WHEN:** Many users/queries compete for the same warehouse.

### Key Difference Table

| Aspect | Scale UP (Size) | Scale OUT (Clusters) |
|--------|----------------|---------------------|
| What changes | Power of EACH server | NUMBER of servers |
| Helps with | 1 slow/heavy query | Many concurrent queries |
| Fixes | Spilling, complex joins | Queuing, wait times |
| Cost impact | 2x size = 2x cost/hour | 2 clusters = 2x cost/hour |
| Example | XS → XL = 16x power | 1 → 4 clusters = 4x lanes |
| Does NOT help | 20 users queuing | 1 query that needs memory |

**IMPORTANT:** Scaling OUT does NOT make a single query faster! A slow query on 1 MEDIUM cluster is still slow on 4 MEDIUM clusters.

### Multi-Cluster Warehouse Example

```sql
CREATE OR REPLACE WAREHOUSE analytics_wh
    WAREHOUSE_SIZE = 'MEDIUM'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 5
    SCALING_POLICY = 'STANDARD'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE;
```

### Scaling Policies

#### STANDARD Policy (aggressive, fast response)

**Rule:** Start a new cluster the MOMENT any query has to wait.

```
9:00 AM — 8 queries arrive. Cluster 1 handles them all.
9:01 AM — 4 more arrive. Cluster 1 busy → 1 query waits.
          Snowflake IMMEDIATELY starts Cluster 2 (within seconds).
9:02 AM — 10 more arrive. Clusters 1 & 2 busy.
          Snowflake IMMEDIATELY starts Clusters 3 and 4.
9:15 AM — Load drops. Clusters 3 & 4 idle 2-3 min → shut down.
```

**BEST FOR:** User-facing dashboards, real-time analytics, interactive queries where SPEED matters more than cost.

#### ECONOMY Policy (conservative, cost-saving)

**Rule:** Start a new cluster ONLY when there's enough queued work to keep it busy for at least 6 minutes.

```
9:00 AM — 8 queries arrive. Cluster 1 handles them all.
9:01 AM — 4 more arrive. Cluster 1 busy → queries WAIT.
          Snowflake checks: "Enough work for 6 min?" No → keep waiting.
9:03 AM — 20 more pile up. NOW there's enough work.
          Snowflake starts Cluster 2.
```

**BEST FOR:** Batch ETL jobs, scheduled reports, background processing where COST matters more than a few minutes of waiting.

### Scaling Policy Comparison

| Aspect | STANDARD | ECONOMY |
|--------|----------|---------|
| New cluster starts | Instantly (seconds) | After ~6 min backlog |
| User wait time | Almost zero | Could be minutes |
| Cost | Higher (more uptime) | Lower (less uptime) |
| Best for | Interactive queries | Batch/ETL workloads |
| Cluster shutdown | After 2-3 min idle | After 5-6 min idle |

```sql
ALTER WAREHOUSE my_wh SET SCALING_POLICY = 'STANDARD';  -- fast, costly
ALTER WAREHOUSE my_wh SET SCALING_POLICY = 'ECONOMY';   -- slow, cheaper
```

### Check if Warehouse is Right-Sized

```sql
SELECT
    warehouse_name,
    warehouse_size,
    AVG(avg_running) AS avg_running_queries,
    AVG(avg_queued_load) AS avg_queued_queries,
    AVG(avg_blocked) AS avg_blocked_queries
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY warehouse_name, warehouse_size
HAVING AVG(avg_queued_load) > 0
ORDER BY avg_queued_queries DESC;
```

If avg_queued > 0 frequently → Scale OUT (more clusters) or Scale UP.

---

## Section 8: Search Optimization Service

### Simple Definition

Search Optimization Service (SOS) builds a hidden data structure (like an INDEX) that helps Snowflake skip micro-partitions even more aggressively for point-lookup queries.

- **Without SOS:** For high-cardinality lookups (find 1 email out of 100M), may still scan thousands of partitions.
- **With SOS:** Knows EXACTLY which micro-partitions contain the value → jumps directly.

### Analogy

Library with 10,000 shelves:
- Without SOS = You know "Science" section (clustering), but check 500 shelves
- With SOS = Exact catalog card: "Book XYZ is on Shelf #3847" → go directly

### Best For

- `WHERE column = 'specific_value'` (equality)
- `WHERE column IN ('val1', 'val2', 'val3')` (IN list)
- High-cardinality columns (user_id, email, UUID)
- VARIANT/semi-structured data queries
- GEOGRAPHY/GEOMETRY functions
- Substring: `WHERE column LIKE '%search_term%'`

### NOT Helpful For

- Full table scans
- Range queries (BETWEEN) → clustering is better
- Queries already well-pruned by clustering
- Small tables

### Examples

```sql
-- Enable on specific lookup columns
ALTER TABLE my_db.my_schema.users
  ADD SEARCH OPTIMIZATION ON EQUALITY(email, user_id);
-- WITHOUT SOS: Scans 2,000/10,000 partitions → 5 seconds
-- WITH SOS:    Scans 2 partitions directly    → 0.1 seconds

-- Enable on VARIANT data
ALTER TABLE my_db.my_schema.events
  ADD SEARCH OPTIMIZATION ON EQUALITY(event_data:user_id::STRING);

-- Enable on substring searches
ALTER TABLE my_db.my_schema.logs
  ADD SEARCH OPTIMIZATION ON SUBSTRING(error_message);

-- Enable on GEOGRAPHY functions
ALTER TABLE my_db.my_schema.stores
  ADD SEARCH OPTIMIZATION ON GEO(location);
```

### Managing Search Optimization

```sql
-- Check status:
DESCRIBE SEARCH OPTIMIZATION ON my_db.my_schema.users;

-- Estimate costs before enabling:
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS('my_db.my_schema.users');

-- Remove from specific columns:
ALTER TABLE my_db.my_schema.users
  DROP SEARCH OPTIMIZATION ON EQUALITY(email);

-- Remove all:
ALTER TABLE my_db.my_schema.users DROP SEARCH OPTIMIZATION;
```

### Cost

SOS uses SERVERLESS compute (no warehouse needed). Two ongoing costs:
1. **Storage cost** → for the search access path data structure
2. **Compute cost** → serverless credits to keep it updated as data changes

### Search Optimization vs Clustering

| Query Type | Use |
|-----------|-----|
| `WHERE date BETWEEN x AND y` | CLUSTERING (range scans) |
| `WHERE email = 'abc@xyz.com'` | SEARCH OPTIMIZATION (lookup) |
| `WHERE status = 'ACTIVE'` | CLUSTERING (low cardinality) |
| `WHERE user_id = 'U-999999'` | SEARCH OPTIMIZATION (lookup) |
| `WHERE msg LIKE '%error%'` | SEARCH OPTIMIZATION (substr) |
| Both range + point lookups | USE BOTH together |

---

## Section 9: Materialized Views

### Simple Definition

Materialized View = A pre-computed result set stored as a table. Snowflake automatically refreshes it when base data changes.

**Analogy:**
- Regular View = Recipe (instructions to make the dish every time)
- Materialized View = Pre-made dish in the fridge (just reheat)

### When to Use

- Same aggregation query runs repeatedly
- Base table is large but the aggregated result is small
- Query involves expensive operations (GROUP BY, DISTINCT, etc.)

### Limitations

- Cannot include JOINs (single table only)
- Cannot include UDFs
- Cannot include HAVING, ORDER BY, LIMIT
- Cannot include window functions
- Enterprise Edition required
- Has maintenance cost (background refresh)

### Example

```sql
CREATE OR REPLACE MATERIALIZED VIEW my_db.my_schema.mv_daily_sales AS
SELECT
    sale_date,
    region,
    SUM(amount) AS total_sales,
    COUNT(*) AS transaction_count
FROM my_db.my_schema.sales
GROUP BY sale_date, region;

-- Now this automatically uses the materialized view:
SELECT * FROM my_db.my_schema.mv_daily_sales WHERE region = 'US-EAST';
-- Instead of scanning millions of rows → reads pre-computed results
```

---

## Section 10: Query Acceleration Service (QAS)

### Simple Definition

QAS = Offloads portions of a query to shared serverless compute resources, accelerating queries that scan a lot of data.

### Best For

- Ad-hoc/exploratory analytics
- Queries with large scans but selective filters
- Outlier queries that are slower than typical workload

### Enable QAS

```sql
ALTER WAREHOUSE my_wh SET
  ENABLE_QUERY_ACCELERATION = TRUE
  QUERY_ACCELERATION_MAX_SCALE_FACTOR = 8;
  -- 0 = unlimited, 8 = max 8x the warehouse compute added
```

### Check Eligible Queries

```sql
SELECT
    query_id,
    eligible_query_acceleration_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_ELIGIBLE
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND eligible_query_acceleration_time > 0
ORDER BY eligible_query_acceleration_time DESC
LIMIT 10;
```

---

## Section 11: Real-World Issues & Step-by-Step Solutions

### Issue 1: "My query takes 10 minutes but it used to take 30 seconds"

**ROOT CAUSE:** Data growth + no clustering = poor pruning

**Diagnosis Steps:**

1. Check Query Profile → "Partitions scanned" vs "Partitions total". If 90%+ → pruning broken.

2. Check clustering:
```sql
SELECT SYSTEM$CLUSTERING_INFORMATION(
  'SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS', '(O_ORDERDATE)'
);
```

**Understanding the Partition Depth Histogram:**

The histogram shows HOW MANY partitions have a given "depth":
- Depth = how many overlapping partitions a specific value spans
- Keys ("00001", "00002") = the DEPTH
- Values = how many partitions at that depth

**POORLY CLUSTERED (all at depth 10):**
```json
"partition_depth_histogram": {
  "00001": 0,
  "00010": 10    // ALL 10 partitions at depth 10
}
```
Every partition overlaps with ALL others. Must scan ALL for any date value.

**WELL CLUSTERED (most at depth 1):**
```json
"partition_depth_histogram": {
  "00001": 8,    // 8 partitions have depth 1 (GREAT!)
  "00002": 2     // 2 with slight overlap
}
```
Searching for a specific date scans only 1-2 partitions.

**Quick Read:** Numbers bunched at LOW depths → WELL CLUSTERED. Numbers at HIGH depths → POORLY CLUSTERED. GOAL: Push all toward "00001".

3. Add clustering key:
```sql
ALTER TABLE my_table CLUSTER BY (date_column, region);
```

4. Monitor:
```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('my_table');
```

**How to Explain:** "Imagine a library where new books are placed randomly on any shelf. To find all books by Author X, you'd check every shelf. Clustering is like reorganizing alphabetically by author. Now just 1-2 shelves."

---

### Issue 2: "Queries are queuing and users are waiting"

**ROOT CAUSE:** Too many concurrent queries for the warehouse.

```sql
SELECT warehouse_name,
       AVG(avg_running) AS avg_running,
       AVG(avg_queued_load) AS avg_queued,
       AVG(avg_blocked) AS avg_blocked
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -3, CURRENT_TIMESTAMP())
GROUP BY warehouse_name
HAVING AVG(avg_queued_load) > 1
ORDER BY avg_queued DESC;
```

**Solutions:**
- A) Multi-cluster: `ALTER WAREHOUSE my_wh SET MIN_CLUSTER_COUNT=1, MAX_CLUSTER_COUNT=5;`
- B) Separate workloads:
  - ETL → etl_wh (LARGE, auto-suspend 60s)
  - BI → bi_wh (MEDIUM, auto-suspend 300s)
  - Ad-hoc → adhoc_wh (SMALL, auto-suspend 120s)

**How to Explain:** "Restaurant with 1 chef. Rush hour → orders pile up. Solution: Add more chefs (multi-cluster) or separate kitchens for different meals (workload separation)."

---

### Issue 3: "Query spilling to remote storage — extremely slow"

**ROOT CAUSE:** Query data > warehouse memory + local SSD.

```sql
SELECT query_id,
       SUBSTR(query_text, 1, 100) AS query_preview,
       warehouse_size,
       ROUND(bytes_spilled_to_local_storage/1e9, 2) AS local_spill_gb,
       ROUND(bytes_spilled_to_remote_storage/1e9, 2) AS remote_spill_gb
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE bytes_spilled_to_remote_storage > 0
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY bytes_spilled_to_remote_storage DESC
LIMIT 5;
```

**Analyze:** SELECT * ? → Project needed columns. Bad join keys? → Fix conditions. Huge CTEs? → Use temp tables. Unnecessary ORDER BY? → Remove.

**If already optimal:** `ALTER WAREHOUSE my_wh SET WAREHOUSE_SIZE = 'XLARGE';`

**How to Explain:** "Your desk is too small. Papers fall on the floor (local spill), then across town in a storage locker (remote spill). Fix: Bigger desk or fewer papers."

---

### Issue 4: "Row explosion in joins"

**ROOT CAUSE:** Many-to-many join or wrong join condition.

```sql
-- WRONG! order_date is not unique → massive row multiplication
SELECT * FROM orders o
JOIN order_items oi ON o.order_date = oi.order_date;

-- CORRECT! order_id is unique per order
SELECT * FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id;
```

**How to Explain:** "Merging class lists by 'first name' instead of 'student ID'. 3 Johns x 4 Johns = 12 rows instead of expected 3-4."

---

### Issue 5: "High cloud services cost (>10% of compute)"

**ROOT CAUSE:** Too many small queries, excessive metadata ops, frequent suspend/resume.

```sql
SELECT
    DATE_TRUNC('day', start_time) AS day,
    SUM(credits_used_cloud_services) AS cloud_services_credits,
    SUM(credits_used_compute) AS compute_credits,
    ROUND(cloud_services_credits / NULLIF(compute_credits, 0) * 100, 2) AS cs_pct
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY day
HAVING cs_pct > 10
ORDER BY day DESC;
```

**Fix:** Batch small queries, increase auto-suspend timeout, use result caching, reduce SHOW/DESCRIBE commands.

---

## Section 12: Interview Questions — Beginner to Architect

### Level 1: Beginner (Fresher / Junior)

**Q1: What are the 3 caching layers in Snowflake?**
> 1. **Metadata Cache** (Cloud Services) — table stats (row counts, min/max). For COUNT(*), MIN(), MAX(). FREE.
> 2. **Result Cache** (Cloud Services) — exact query results for 24hrs. Same query + data + role = instant. FREE.
> 3. **Warehouse Cache** (Local Disk) — raw data on SSD. Lost on suspend. Speeds repeated scans.

**Q2: What is a micro-partition?**
> A small, immutable, compressed chunk of data (50-500 MB compressed, ~16 MB uncompressed per column). Auto-created during loading. Stores min/max metadata enabling pruning.

**Q3: What is pruning and why is it important?**
> Snowflake's ability to SKIP micro-partitions that don't contain needed data. Uses min/max metadata. Good pruning = fewer partitions scanned = faster + cheaper.

**Q4: What happens when you suspend a warehouse?**
> Running queries complete first. Local disk cache is CLEARED. No credits consumed. Result/metadata cache unaffected (they're in cloud services).

**Q5: Difference between scaling UP and scaling OUT?**
> Scale UP: Bigger size → more power per query (helps slow queries). Scale OUT: More clusters → more concurrent capacity (helps queuing).

---

### Level 2: Intermediate (2-4 years)

**Q6: What is spilling and how do you fix it?**
> When a query needs more memory than the warehouse has. Spills to local SSD (2-5x slower), then remote storage (10-50x slower). Fixes: 1) Optimize query (reduce columns, add filters, break CTEs). 2) Reduce concurrency. 3) Upsize warehouse. 4) Batch processing.

**Q7: When should you use clustering key vs Search Optimization?**
> **Clustering:** RANGE queries (BETWEEN, >=), low-to-medium cardinality, date ranges + categories. Reorganizes data physically.
> **Search Optimization:** POINT LOOKUPS (=, IN), high cardinality (user_id, email), VARIANT data, substring searches. Creates access path without reorganizing.

**Q8: Query was fast yesterday (5s), slow today (2min). Data unchanged. Why?**
> Possible: 1) Result cache expired (24hr TTL). 2) Warehouse suspended → disk cache cleared. 3) Warehouse under heavy load. 4) Warehouse resized down. 5) Cloud services latency.

**Q9: How to decide the right warehouse size?**
> Start XS for dev. Monitor spilling: local spill → try next size. Remote spill → definitely upsize. Rule: double size ≈ 2x faster for scan-heavy queries. Check WAREHOUSE_LOAD_HISTORY for queuing, QUERY_HISTORY for spilling.

**Q10: Materialized View vs regular View?**
> **Regular View:** Stored SQL, executes every time. No cost.
> **Materialized View:** Pre-computed table, auto-refreshed. Faster reads. Has storage + maintenance cost. No JOINs, no window functions. Enterprise Edition only.

---

### Level 3: Senior (5-8 years)

**Q11: Design warehouse strategy for 50 BI users + nightly ETL + data science team.**
> 1. **BI_WH** (MEDIUM, multi-cluster 1-5, STANDARD) — dashboards, 5 min suspend
> 2. **ETL_WH** (LARGE, single cluster) — batch jobs, 60s suspend, suspended during day
> 3. **DS_WH** (X-LARGE, single) — ad-hoc, 10 min suspend, QAS for outliers
> 4. **ADMIN_WH** (X-SMALL) — monitoring

**Q12: 80% result cache hit but costs still high. Investigate.**
> 1. The 20% non-cached may be very expensive (90% of credits?)
> 2. Warehouses idle but running (auto-suspend too long)
> 3. Cloud services >10% (small queries, metadata ops)
> 4. Background services: clustering, MV, SOS maintenance
> 5. Snowpipe or Streams/Tasks running continuously

**Q13: Query already optimized but still slow?**
> Decision tree: 1) Pruning bad → clustering key. 2) Spilling → upsize. 3) Point lookup → SOS. 4) Repeated aggregation → MV. 5) Large scan → QAS. 6) Complex join → temp tables. 7) Pre-aggregate with summary table. 8) LAST RESORT: redesign data model.

---

### Level 4: Architect (8+ years)

**Q14: Design performance monitoring for 500-user, 20-warehouse deployment.**
> **Layer 1 — Real-time Dashboard:** Warehouse load, active queries > threshold, spilling metrics.
> **Layer 2 — Daily Health Check:** Top 20 slow queries, spill trends, cache hit rates, utilization.
> **Layer 3 — Weekly Optimization:** Tables needing clustering, SOS/MV/QAS candidates, right-sizing recommendations.
> **Layer 4 — Alerting:** Credit thresholds, queries > 30 min, remote spilling, queuing > 5 min average.

**Q15: Customer spending $50K/month (60% compute). Reduce costs by 30%.**
> **Phase 1 — Quick Wins (10-15%):** Audit auto-suspend settings, right-size oversized warehouses, enable result caching awareness.
> **Phase 2 — Query Optimization (10%):** Fix top 20 expensive queries, add clustering keys, replace repeated subqueries with temp tables, enable QAS.
> **Phase 3 — Architecture (5-10%):** Workload isolation, materialized views for dashboards, pre-aggregated summary tables, Resource Monitors, schedule ETL off-peak.

**Q16: Compare trade-offs of ALL optimization features.**

| FEATURE | BEST FOR | ONGOING COST | LIMITATION |
|---------|----------|-------------|-----------|
| Clustering Key | Range filters | Yes (reorg) | 3-4 cols max |
| Search Optimization | Point lookup | Yes (maintain) | Equality only |
| Materialized View | Aggregations | Yes (refresh) | No JOINs |
| Query Acceleration | Large scans | Per-query | Not all queries |
| Result Cache | Repeat query | Free | 24hr, no DML |
| Warehouse Sizing | All queries | Per-second | Not all benefit |
| Multi-Cluster WH | Concurrency | Per-cluster | Enterprise Ed. |

**Q17: 10TB fact table JOIN 50MB dimension takes 20 min. Optimize.**
> 1. Check Query Profile — row explosion? Fix join key. Full scan? Add filters.
> 2. Cluster fact table on most common filter columns (date + category). Target < 10% partitions.
> 3. Filter early — push WHERE before the join.
> 4. Project only needed columns (5-10, not SELECT *).
> 5. Query rewrite — filter fact into temp table, then join with dimension.
> 6. Warehouse sizing — 10TB scan needs L or XL to avoid spilling.

**Q18: When recommend AGAINST using a clustering key?**
> 1. Small tables (< 1 GB) — already fast, overhead not worth it
> 2. Full-table scan workloads — clustering helps pruning but full scans read everything
> 3. Highly volatile tables — reclustering cost exceeds savings
> 4. Tables queried on many different columns — can't optimize all; use SOS
> 5. Natural insertion order already clusters well (timestamp-ordered event tables)

---

## Bonus: Performance Optimization Cheat Sheet

### Troubleshooting Flowchart

```
Query is slow
     │
     ├─ Is it queuing? ──────→ Scale OUT (multi-cluster) or
     │                         separate workloads
     │
     ├─ Is it spilling? ─────→ Optimize query OR scale UP
     │
     ├─ Full table scan? ────→ Add WHERE filters, clustering key
     │
     ├─ Row explosion? ──────→ Fix JOIN conditions
     │
     ├─ Point lookup slow? ──→ Search Optimization Service
     │
     ├─ Same agg repeated? ──→ Materialized View
     │
     └─ Large scan, outlier? → Query Acceleration Service
```

### Key Diagnostic Queries

| Purpose | Source |
|---------|--------|
| Slow queries | QUERY_HISTORY (filter by elapsed_time) |
| Spilling | QUERY_HISTORY (bytes_spilled columns) |
| Queuing | WAREHOUSE_LOAD_HISTORY (avg_queued_load) |
| Pruning | Query Profile → TableScan node |
| Clustering health | SYSTEM$CLUSTERING_INFORMATION() |
| Warehouse cost | WAREHOUSE_METERING_HISTORY |
| QAS candidates | QUERY_ACCELERATION_ELIGIBLE |

### Golden Rules

1. Always optimize the QUERY first, then the INFRASTRUCTURE
2. SELECT only columns you need (never SELECT *)
3. Filter early, join late
4. Use clustering for range filters, search optimization for point lookups
5. Monitor continuously — performance degrades as data grows
6. Separate workloads into dedicated warehouses
7. Set appropriate auto-suspend (cost vs cache tradeoff)
8. Use Resource Monitors to prevent runaway costs

---

*End of Snowflake Performance Optimization Complete Guide*
