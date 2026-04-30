# My Query is Running 30+ Minutes — Step-by-Step Optimization Playbook

> Explained as an Architect would in an Interview

---

## Scenario

You have a query that takes 30+ minutes. Your manager says "fix it." Here is the EXACT step-by-step process an Architect follows.

## Golden Rule (Say This in Every Interview)

> "I always optimize in this order:
> 1. UNDERSTAND the problem first (diagnose)
> 2. REDUCE data scanned (pruning, filters)
> 3. REDUCE compute needed (rewrite SQL)
> 4. RIGHT-SIZE infrastructure last (warehouse)
>
> Never throw a bigger warehouse at a bad query."

---

## Step 1: DIAGNOSE — Find Out WHY It's Slow (Don't Guess, MEASURE)

### Interview Answer

> "Before touching anything, I open the Query Profile in Snowsight. The Query Profile is like an X-ray of the query — it shows me EXACTLY where time is being spent. I never guess. I always measure first."

### What to Look For in Query Profile

1. Which operator node takes the most time? (the thickest bar)
2. How many partitions were scanned vs total? (pruning efficiency)
3. Is there spilling? (local or remote)
4. Is there a row explosion in JOINs? (output >> input rows)
5. Is the query queued? (waiting for resources)

### Diagnostic Query

```sql
SELECT
    query_id,
    SUBSTR(query_text, 1, 200) AS query_preview,
    warehouse_name,
    warehouse_size,
    total_elapsed_time / 1000 AS elapsed_sec,
    ROUND(total_elapsed_time / 60000, 1) AS elapsed_min,
    compilation_time / 1000 AS compile_sec,
    execution_time / 1000 AS exec_sec,
    queued_overload_time / 1000 AS queued_sec,
    bytes_scanned / (1024*1024*1024) AS scanned_gb,
    ROUND(bytes_spilled_to_local_storage / (1024*1024*1024), 2) AS local_spill_gb,
    ROUND(bytes_spilled_to_remote_storage / (1024*1024*1024), 2) AS remote_spill_gb,
    partitions_scanned,
    partitions_total,
    ROUND(partitions_scanned / NULLIF(partitions_total, 0) * 100, 1) AS pct_partitions_scanned,
    rows_produced
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE total_elapsed_time > 1800000    -- > 30 minutes (in milliseconds)
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 10;
```

### How to Read the Results

| Metric | What It Tells You | Next Step |
|--------|-------------------|-----------|
| queued_sec > 0 | Query WAITED for resources | → Step 7 (warehouse) |
| pct_partitions_scanned > 50% | Bad pruning | → Step 2 & 3 |
| local_spill_gb > 0 | Ran out of memory | → Step 5 or Step 7 |
| remote_spill_gb > 0 | CRITICAL memory issue | → Step 5 immediately, then Step 7 |
| rows_produced very high | Possible row explosion | → Step 4 |
| scanned_gb very large | Scanning too much data | → Step 2 & 3 |
| compile_sec > 10 | Query too complex | → Simplify SQL |

### Interview Tip

> "I start by running this diagnostic query against QUERY_HISTORY. It gives me the complete picture in one shot — am I spilling? scanning too much? queuing? This tells me which optimization lever to pull first."

---

## Step 2: CHECK PARTITION PRUNING — Are We Reading the Whole Table?

### Interview Answer

> "The #1 reason queries are slow in Snowflake is poor partition pruning. Snowflake stores data in micro-partitions (50-500 MB each). Each partition has metadata with MIN/MAX values. When you filter with WHERE, Snowflake checks this metadata and SKIPS partitions that can't contain your data. If pruning is bad, the query reads the ENTIRE table — even if you only need 1% of the data."

### How to Check

Open Query Profile → click on the TableScan node → look at:
```
Partitions scanned:  8,000
Partitions total:    10,000
→ You're scanning 80% of the table! That's terrible.
```

| Pruning Quality | Partitions Scanned |
|----------------|-------------------|
| GOOD | < 10% |
| OK | 10-30% |
| BAD (this is your problem) | > 50% |

### Common Causes of Bad Pruning

#### 1. No WHERE clause or very broad filters

```sql
-- BAD:
SELECT * FROM orders;

-- GOOD:
SELECT * FROM orders WHERE order_date >= '2025-01-01';
```

#### 2. Filtering on a column that's not clustered

The table is naturally ordered by insert time (e.g., created_at), but you filter on region. Snowflake can't prune because region values are scattered across ALL partitions.

#### 3. Using functions on filter columns (KILLS pruning!)

```sql
-- BAD: Snowflake can't use min/max metadata (evaluates EVERY row)
WHERE YEAR(order_date) = 2025

-- GOOD: Direct comparison on raw column (pruning works perfectly)
WHERE order_date >= '2025-01-01' AND order_date < '2026-01-01'
```

```sql
-- BAD:
WHERE UPPER(city) = 'MUMBAI'

-- GOOD: Store data consistently, avoid functions
WHERE city = 'Mumbai'
```

```sql
-- BAD:
WHERE TO_DATE(event_timestamp) = '2025-04-30'

-- GOOD:
WHERE event_timestamp >= '2025-04-30' AND event_timestamp < '2025-05-01'
```

### Interview Tip

> "I always check pruning first because it's the highest-impact fix. Going from 80% partitions scanned to 5% is a 16x improvement — no warehouse change needed, no extra cost. Just smarter filtering."

---

## Step 3: CHECK & FIX CLUSTERING — Is the Data Organized for Our Query?

### Interview Answer

> "If pruning is bad even with proper WHERE clauses, the data is not physically organized in a way that helps our filters. This is where clustering keys come in. A clustering key tells Snowflake to RE-ORGANIZE the data inside micro-partitions so that similar values are grouped together — making pruning dramatically more effective."

### Check Clustering Health

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('my_db.my_schema.my_table', '(date_column)');
```

**What the output means:**

| average_depth | Interpretation |
|--------------|----------------|
| 1-2 | EXCELLENT (each value spans 1-2 partitions) |
| 3-5 | OK (could be better) |
| 10+ | TERRIBLE (values scattered, no pruning) |

**Formula:** `total_constant_partition_count / total_partition_count` → closer to 1.0 = better. This ratio tells you what % of partitions are "pure" (contain only one value).

### When to Add a Clustering Key

- ✅ Table is large (> 1 GB, ideally > 10 GB)
- ✅ You always filter on the same 1-3 columns
- ✅ average_depth > 3 in SYSTEM$CLUSTERING_INFORMATION
- ✅ Partitions scanned > 50% in Query Profile

### How to Add

```sql
ALTER TABLE my_db.my_schema.orders CLUSTER BY (region, order_date);
```

### Key Rules

1. **LOW cardinality column FIRST** (region, status, country) → Creates large clean groups for Snowflake to skip
2. **HIGH cardinality column SECOND** (date, id) → Sorts within those groups
3. **Maximum 3-4 columns** (more = diminishing returns + higher cost)
4. **Choose columns from your WHERE and JOIN clauses**

### Example

Your slow query:
```sql
SELECT * FROM sales
WHERE region = 'APAC' AND sale_date BETWEEN '2025-01-01' AND '2025-03-31';
```

| Scenario | Partitions Scanned | Result |
|----------|-------------------|--------|
| Without clustering | 90% (region scattered) | 30 min |
| After `CLUSTER BY (region, sale_date)` | 3% (APAC + Q1 grouped) | 1 min |

### Cost Warning

Clustering is an ONGOING background service. Snowflake continuously re-organizes data as new rows are inserted. This costs serverless credits. Only cluster tables that truly need it.

### Monitor

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('my_db.my_schema.orders', '(region, order_date)');
```

### Interview Tip

> "Clustering is one of the most powerful optimizations but also one of the most expensive ongoing costs. I only recommend it when the pruning ratio is consistently bad and the table is queried frequently with the same filter patterns. For small or infrequently queried tables, it's overkill."

---

## Step 4: CHECK FOR ROW EXPLOSION IN JOINS

### Interview Answer

> "Row explosion is a silent killer. It happens when a JOIN produces exponentially more rows than the input tables. This is usually caused by joining on a NON-UNIQUE key, creating a many-to-many relationship. The Query Profile will show a Join node where output rows are 100x or 1000x the input rows. That's the smoking gun."

### How to Detect

In Query Profile → click the Join node:
```
Input rows:  1,000,000 (left) + 500,000 (right)
Output rows: 500,000,000,000  ← 500 BILLION! Row explosion!
```

### Common Cause

Joining on a column that is NOT unique in EITHER table.

### Example of the Problem

```sql
-- BAD:
SELECT *
FROM orders o
JOIN payments p ON o.order_date = p.payment_date;

-- order_date '2025-01-15' appears in 10,000 orders.
-- payment_date '2025-01-15' appears in 8,000 payments.
-- Result: 10,000 × 8,000 = 80,000,000 rows for JUST ONE DATE!
-- Across 365 days → BILLIONS of rows → 30+ min query → spilling.
```

```sql
-- FIX:
SELECT *
FROM orders o
JOIN payments p ON o.order_id = p.order_id;

-- order_id is unique per order → 1:1 match → clean join, no explosion.
```

### Other Fixes

**1. Add more JOIN conditions to make the match more specific:**
```sql
ON o.order_date = p.payment_date AND o.customer_id = p.customer_id
```

**2. Pre-aggregate before joining:**
```sql
WITH daily_orders AS (
    SELECT order_date, COUNT(*) AS order_count, SUM(amount) AS total
    FROM orders GROUP BY order_date
)
SELECT * FROM daily_orders d JOIN payments p ON d.order_date = p.payment_date;
-- 365 rows JOIN instead of 10M rows JOIN
```

**3. Use QUALIFY or DISTINCT to eliminate duplicates before the JOIN.**

### Interview Tip

> "When I see a 30-minute query, the FIRST thing I check after pruning is whether there's a row explosion in the JOINs. I've seen queries go from 45 minutes to 10 seconds just by fixing the JOIN key from a date column to a proper foreign key."

---

## Step 5: CHECK FOR SPILLING — Is the Warehouse Running Out of Memory?

### Interview Answer

> "Spilling means the query needs more memory than the warehouse provides. When memory fills up, Snowflake writes overflow data to local SSD first (2-5x slower), then to remote cloud storage (10-50x slower). Remote spilling is a CRITICAL performance issue — it can turn a 2-minute query into a 30-minute query."

### How to Check

```sql
SELECT
    query_id,
    SUBSTR(query_text, 1, 100) AS query_preview,
    warehouse_size,
    ROUND(bytes_spilled_to_local_storage / (1024*1024*1024), 2) AS local_spill_gb,
    ROUND(bytes_spilled_to_remote_storage / (1024*1024*1024), 2) AS remote_spill_gb,
    total_elapsed_time / 1000 AS elapsed_sec
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE (bytes_spilled_to_local_storage > 0 OR bytes_spilled_to_remote_storage > 0)
  AND start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY bytes_spilled_to_remote_storage DESC
LIMIT 10;
```

### What Causes Spilling

1. Large JOINs between huge tables (billions × millions of rows)
2. GROUP BY on high-cardinality columns (millions of groups)
3. ORDER BY on massive result sets (sorts everything in memory)
4. Window functions over huge partitions
5. Too many concurrent queries sharing the warehouse memory
6. Warehouse size too small for the data volume

### How to Fix (In This Order)

#### FIX 1: Optimize the Query FIRST (Free, No Extra Cost)

- Remove SELECT * → select only columns you need
- Add WHERE filters to reduce data BEFORE joins/aggregations
- Break huge CTEs into temporary tables:

```sql
-- BAD (everything in memory at once):
WITH huge_cte AS (SELECT ... FROM 10B_row_table ...)
SELECT * FROM huge_cte JOIN another_table ...

-- GOOD (materialized to disk, then joined):
CREATE TEMPORARY TABLE temp_filtered AS
SELECT ... FROM 10B_row_table WHERE date >= '2025-01-01';

SELECT * FROM temp_filtered JOIN another_table ...
-- The temp table is written to storage, freeing memory for the JOIN.
```

#### FIX 2: Reduce Concurrent Queries (Free)

- 4 queries sharing a MEDIUM warehouse = 4 GB each (instead of 16 GB)
- Schedule heavy queries at different times
- Use separate warehouses for different workloads

#### FIX 3: Scale UP the Warehouse (Costs More Credits)

```sql
ALTER WAREHOUSE my_wh SET WAREHOUSE_SIZE = 'XLARGE';
```

Each size doubles memory: XS(8GB) → S(16) → M(32) → L(64) → XL(128)

A query spilling 20 GB on MEDIUM → may run clean on LARGE.

### Interview Tip

> "I always try to eliminate spilling by optimizing the query first. Throwing a bigger warehouse at a bad query just costs more money. But if the query is already optimal and still spills, then scaling up is the right move — and I'd also check if concurrent queries are stealing memory from each other."

---

## Step 6: OPTIMIZE THE SQL ITSELF — Rewrite for Performance

### Interview Answer

> "Even with perfect pruning and no spilling, a poorly written query can still be slow. There are specific SQL anti-patterns that I check for and rewrite."

### Anti-Pattern 1: SELECT *

```sql
-- BAD: Reads ALL columns from BOTH tables (80 columns)
SELECT * FROM orders JOIN customers ON ...

-- GOOD: Reads only 3 columns. Columnar storage skips the other 77 entirely.
SELECT o.order_id, o.amount, c.name
FROM orders o JOIN customers c ON o.customer_id = c.customer_id;
```

### Anti-Pattern 2: ORDER BY Without LIMIT

```sql
-- BAD: Sorts 500 million rows in memory. Massive spilling.
SELECT * FROM events ORDER BY event_time DESC;

-- GOOD: Top-N optimization — only tracks top 1000 without full sort.
SELECT * FROM events ORDER BY event_time DESC LIMIT 1000;
```

### Anti-Pattern 3: Functions on Filter Columns (Kills Pruning)

```sql
-- BAD:
WHERE DATE_TRUNC('month', created_at) = '2025-01-01'
-- GOOD:
WHERE created_at >= '2025-01-01' AND created_at < '2025-02-01'

-- BAD:
WHERE CONCAT(first_name, ' ', last_name) = 'Rohit Sharma'
-- GOOD:
WHERE first_name = 'Rohit' AND last_name = 'Sharma'
```

### Anti-Pattern 4: Unnecessary DISTINCT or GROUP BY

```sql
-- BAD: If customer_id is already unique, DISTINCT wastes compute
SELECT DISTINCT customer_id FROM orders;

-- GOOD: Only use DISTINCT when you KNOW there are duplicates.
-- Check the data first.
```

### Anti-Pattern 5: Subquery in WHERE (Correlated Subquery)

```sql
-- BAD: Subquery may execute for EVERY row in orders
SELECT * FROM orders
WHERE customer_id IN (SELECT customer_id FROM customers WHERE region = 'APAC');

-- GOOD: Single join, much more efficient
SELECT o.*
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
WHERE c.region = 'APAC';

-- EVEN BETTER (if you only need orders columns):
SELECT o.*
FROM orders o
WHERE EXISTS (
    SELECT 1 FROM customers c
    WHERE c.customer_id = o.customer_id AND c.region = 'APAC'
);
```

### Anti-Pattern 6: Huge CTEs Referenced Multiple Times

```sql
-- BAD: big_cte computed TWICE (Snowflake doesn't cache CTEs)
WITH big_cte AS (SELECT ... complex query on 1B rows ...)
SELECT * FROM big_cte WHERE region = 'EAST'
UNION ALL
SELECT * FROM big_cte WHERE region = 'WEST';

-- GOOD: Computed once, stored on disk, read twice cheaply
CREATE TEMPORARY TABLE temp_result AS
SELECT ... complex query on 1B rows ...;

SELECT * FROM temp_result WHERE region = 'EAST'
UNION ALL
SELECT * FROM temp_result WHERE region = 'WEST';
```

### Interview Tip

> "I've seen queries go from 30 minutes to 30 seconds just by removing SELECT *, adding proper WHERE filters, and replacing a correlated subquery with a JOIN. SQL rewrites are free — they cost zero extra credits — so I always exhaust this step before touching infrastructure."

---

## Step 7: RIGHT-SIZE THE WAREHOUSE — Scale UP or Scale OUT

### Interview Answer

> "After I've optimized the query itself, if it's STILL slow, I look at the warehouse. There are two levers: Scale UP (bigger warehouse for heavy single queries) and Scale OUT (more clusters for many concurrent queries). They solve different problems."

### Decision Tree

```
Is the query SPILLING?
  YES → Scale UP (more memory)
  NO  ↓
Is the query QUEUING (waiting for resources)?
  YES → Scale OUT (more clusters)
  NO  ↓
Is the query scanning huge data and already well-pruned?
  YES → Scale UP (more compute power for parallelism)
  NO  → The problem is in the SQL, go back to Step 6.
```

### Scale UP (Make Each Server Bigger)

```sql
ALTER WAREHOUSE my_wh SET WAREHOUSE_SIZE = 'XLARGE';
```

| Size | Memory | Credits/sec |
|------|--------|-------------|
| XS | ~8 GB | 1x |
| S | ~16 GB | 2x |
| M | ~32 GB | 4x |
| L | ~64 GB | 8x |
| XL | ~128 GB | 16x |

**USE WHEN:** Single query is slow, spilling, or scanning huge data.
**DOES NOT HELP:** Many queries queuing.

### Scale OUT (Add More Warehouse Copies)

```sql
ALTER WAREHOUSE my_wh SET
  MIN_CLUSTER_COUNT = 1,
  MAX_CLUSTER_COUNT = 4;
```

**USE WHEN:** Many users/queries competing for the same warehouse.
**DOES NOT HELP:** Single slow query (it still runs on one cluster).

### Check If You Need to Scale

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

- If avg_queued > 0 consistently → **Scale OUT**
- If avg_queued = 0 but query is slow → **Scale UP** (if spilling) or optimize SQL

### Interview Tip

> "Scaling is always my LAST step because it costs money. A query optimized from scanning 80% of partitions to 5% will run fast on even an XS warehouse. But if I've exhausted all query-level optimizations and the query legitimately processes terabytes, then scaling up is the right call."

---

## Step 8: CONSIDER ADVANCED SERVICES — SOS, MV, QAS

### Interview Answer

> "After basic optimizations, I evaluate Snowflake's advanced services. Each one solves a SPECIFIC problem. Using the wrong one wastes money."

| Service | Use When | Example |
|---------|----------|---------|
| **Search Optimization Service (SOS)** | Point lookups on high cardinality columns | `WHERE email = '...'`, `WHERE user_id = 'X'`, `WHERE data:key = 'Y'` |
| **Materialized Views (MV)** | Same aggregation query runs repeatedly on a large table | `SUM(sales) GROUP BY region, date` — runs every hour |
| **Query Acceleration Service (QAS)** | Ad-hoc queries that scan huge data but are outliers in workload | Analyst scans 5TB but returns 1000 rows |

### Search Optimization — Needle-in-a-Haystack Lookups

```sql
ALTER TABLE my_db.my_schema.users
  ADD SEARCH OPTIMIZATION ON EQUALITY(email, user_id);
```

| Scenario | Partitions Scanned | Time |
|----------|-------------------|------|
| Before SOS | 2,000 | 5 sec |
| After SOS | 2 | 0.1 sec |

Estimate cost first:
```sql
SELECT SYSTEM$ESTIMATE_SEARCH_OPTIMIZATION_COSTS('my_db.my_schema.users');
```

### Materialized Views — Repeated Expensive Aggregations

```sql
CREATE MATERIALIZED VIEW my_db.my_schema.mv_daily_sales AS
SELECT sale_date, region, SUM(amount) AS total, COUNT(*) AS cnt
FROM my_db.my_schema.sales
GROUP BY sale_date, region;

-- Reads pre-computed results instead of scanning millions of rows
SELECT * FROM mv_daily_sales WHERE region = 'APAC';
```

**Limitation:** Single table only, no JOINs, no window functions.

### Query Acceleration — Outlier Heavy Queries

```sql
ALTER WAREHOUSE my_wh SET
  ENABLE_QUERY_ACCELERATION = TRUE,
  QUERY_ACCELERATION_MAX_SCALE_FACTOR = 8;
```

Check eligible queries:
```sql
SELECT query_id, eligible_query_acceleration_time
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_ACCELERATION_ELIGIBLE
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
  AND eligible_query_acceleration_time > 0
ORDER BY eligible_query_acceleration_time DESC
LIMIT 10;
```

### Interview Tip

> "I think of these as specialized tools in a toolbox. You don't use a hammer for every problem. SOS for lookups, MVs for repeated aggregations, QAS for heavy ad-hoc scans. I always estimate cost before enabling because they all have ongoing serverless compute charges."

---

## Step 9: CHECK CACHING — Are We Re-doing Work Snowflake Already Did?

### Interview Answer

> "Snowflake has three caching layers. If I can make my query hit a cache, the result is essentially free and instant."

### Cache Layers

#### 1. Result Cache (Cloud Services Layer)

- Stores exact query results for 24 hours
- Same query + same data + same role = instant result (0 credits)
- Invalidated if underlying data changes (any DML)
- KILLED BY: CURRENT_TIMESTAMP(), RANDOM(), non-deterministic functions

```sql
-- BAD: CURRENT_TIMESTAMP() changes every second → cache NEVER hits
SELECT *, CURRENT_TIMESTAMP() AS run_time FROM sales WHERE ...

-- GOOD: If data hasn't changed, returns cached result in milliseconds
SELECT * FROM sales WHERE ...
```

#### 2. Metadata Cache (Cloud Services Layer)

- Stores table stats: row count, min/max per column, file references
- Answers COUNT(*), MIN(), MAX() on full table WITHOUT a warehouse
- FREE — no warehouse credits consumed

#### 3. Warehouse Cache (Local SSD on Compute Nodes)

- Raw data cached on warehouse's local disk
- Lost when warehouse SUSPENDS
- Trade-off: longer auto-suspend = better cache, higher cost

```sql
-- For frequently queried warehouses:
ALTER WAREHOUSE bi_wh SET AUTO_SUSPEND = 300;  -- 5 minutes
-- Keeps cache warm between queries
```

### Interview Tip

> "Caching is the cheapest optimization. I make sure result caching is enabled (USE_CACHED_RESULT = TRUE), I avoid non-deterministic functions in queries that don't need them, and I set auto-suspend thoughtfully — too aggressive suspension kills the warehouse cache."

---

## Step 10: LONG-TERM — Set Up Monitoring to PREVENT Future Slow Queries

### Interview Answer

> "Fixing one slow query is a band-aid. As an architect, I set up monitoring so we catch performance regressions BEFORE users complain."

### Monitoring Query 1: Weekly Slow Query Report

```sql
SELECT
    DATE_TRUNC('day', start_time) AS query_date,
    COUNT(*) AS slow_query_count,
    AVG(total_elapsed_time) / 1000 AS avg_elapsed_sec,
    SUM(CASE WHEN bytes_spilled_to_remote_storage > 0 THEN 1 ELSE 0 END) AS remote_spill_count
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE total_elapsed_time > 300000    -- > 5 minutes
  AND start_time >= DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY query_date
ORDER BY query_date DESC;
```

### Monitoring Query 2: Tables That Need Clustering

```sql
-- Run for your top 10 most-queried large tables:
SELECT SYSTEM$CLUSTERING_INFORMATION('db.schema.table', '(filter_column)');
-- If average_depth > 5 → clustering key needed.
```

### Monitoring Query 3: Warehouse Queuing Trends

```sql
SELECT
    DATE_TRUNC('hour', start_time) AS hour,
    warehouse_name,
    AVG(avg_queued_load) AS avg_queued
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_LOAD_HISTORY
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
GROUP BY hour, warehouse_name
HAVING avg_queued > 1
ORDER BY hour DESC;
```

### Set Up Alerts

```sql
CREATE ALERT slow_query_alert
  WAREHOUSE = admin_wh
  SCHEDULE = 'USING CRON 0 * * * * UTC'  -- every hour
  IF (EXISTS (
      SELECT 1 FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
      WHERE total_elapsed_time > 1800000
        AND start_time >= DATEADD('hour', -1, CURRENT_TIMESTAMP())
  ))
  THEN
    CALL SYSTEM$SEND_EMAIL('my_notification', 'team@company.com',
      'ALERT: Query running > 30 min', 'Check QUERY_HISTORY for details.');
```

### Resource Monitors (Budget Guardrails)

```sql
CREATE RESOURCE MONITOR monthly_limit
  WITH CREDIT_QUOTA = 5000
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 90 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE my_wh SET RESOURCE_MONITOR = monthly_limit;
```

### Interview Tip

> "An architect doesn't just fix problems — they build systems that prevent problems. I set up 4 layers of monitoring: real-time dashboards, daily health checks, weekly optimization reports, and automated alerts. Combined with resource monitors, this ensures we catch regressions early and never get a surprise $50K bill."

---

## Complete Optimization Flowchart

```
Query running 30+ minutes
       │
       ▼
┌─ STEP 1: DIAGNOSE (Query Profile + QUERY_HISTORY) ─────────────────────┐
│   What's the bottleneck? Pruning? Spilling? Joins? Queuing?            │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 2: CHECK PRUNING ────────────────────────────────────────────────┐
│   Partitions scanned > 50%? → Fix WHERE clauses, remove functions      │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 3: CHECK CLUSTERING ─────────────────────────────────────────────┐
│   average_depth > 3? → ADD clustering key (low cardinality first)      │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 4: CHECK JOINS ─────────────────────────────────────────────────┐
│   Output rows >> Input rows? → Fix JOIN key, pre-aggregate             │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 5: CHECK SPILLING ──────────────────────────────────────────────┐
│   Spilling to disk? → Optimize SQL first, then scale UP warehouse      │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 6: REWRITE SQL ─────────────────────────────────────────────────┐
│   SELECT *? Functions in WHERE? Correlated subqueries? Fix them.       │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 7: RIGHT-SIZE WAREHOUSE ────────────────────────────────────────┐
│   Still slow after SQL is optimal? → Scale UP or Scale OUT             │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 8: ADVANCED SERVICES ───────────────────────────────────────────┐
│   Point lookups → SOS | Repeated aggs → MV | Heavy scans → QAS        │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 9: CACHING ─────────────────────────────────────────────────────┐
│   Can result cache help? Remove non-deterministic functions.            │
└────────────────────────────────────────────────────────────────────────┘
       │
       ▼
┌─ STEP 10: MONITORING ─────────────────────────────────────────────────┐
│   Set up alerts, resource monitors, weekly reports. Prevent recurrence. │
└────────────────────────────────────────────────────────────────────────┘
```

---

*End of Query Optimization Playbook*
