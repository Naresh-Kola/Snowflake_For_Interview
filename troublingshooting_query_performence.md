# Troubleshooting Long-Running Queries in Snowflake — Complete Guide

Step-by-Step with Executable Examples & Query Profile Analysis

---

## Section 1: The Troubleshooting Framework

When a query is slow, check these 5 things **IN ORDER**:

1. **IS IT QUEUED?** → Warehouse is too busy / too small
2. **IS IT SPILLING?** → Not enough memory → data written to disk
3. **IS PRUNING EFFICIENT?** → Too many partitions scanned
4. **IS THERE ROW EXPLOSION?** → JOINs producing way more rows than input
5. **IS RESULT CACHE USED?** → Same query could return instantly from cache

**TOOLS:**
- Query Profile in Snowsight (Monitoring → Query History → Select Query → Query Profile)
- `GET_QUERY_OPERATOR_STATS()` function (programmatic access to same data)

---

## Section 2: Setup — Create Demo Tables

```sql
CREATE OR REPLACE DATABASE QUERY_TROUBLESHOOT_DEMO;
USE DATABASE QUERY_TROUBLESHOOT_DEMO;
USE SCHEMA PUBLIC;

CREATE OR REPLACE TABLE CUSTOMERS (
    CUSTOMER_ID     INT,
    CUSTOMER_NAME   VARCHAR(100),
    REGION          VARCHAR(50),
    SIGNUP_DATE     DATE,
    STATUS          VARCHAR(20)
);

INSERT INTO CUSTOMERS
SELECT 
    SEQ4()                                                          AS CUSTOMER_ID,
    'CUSTOMER_' || SEQ4()                                           AS CUSTOMER_NAME,
    CASE MOD(SEQ4(), 5)
        WHEN 0 THEN 'NORTH'
        WHEN 1 THEN 'SOUTH'
        WHEN 2 THEN 'EAST'
        WHEN 3 THEN 'WEST'
        ELSE 'CENTRAL'
    END                                                             AS REGION,
    DATEADD(DAY, -MOD(SEQ4(), 1000), CURRENT_DATE())                AS SIGNUP_DATE,
    CASE MOD(SEQ4(), 3)
        WHEN 0 THEN 'ACTIVE'
        WHEN 1 THEN 'INACTIVE'
        ELSE 'SUSPENDED'
    END                                                             AS STATUS
FROM TABLE(GENERATOR(ROWCOUNT => 5000000));

CREATE OR REPLACE TABLE ORDERS (
    ORDER_ID        INT,
    CUSTOMER_ID     INT,
    ORDER_DATE      DATE,
    AMOUNT          DECIMAL(12,2),
    PRODUCT_CATEGORY VARCHAR(50)
);

INSERT INTO ORDERS
SELECT 
    SEQ4()                                                          AS ORDER_ID,
    MOD(SEQ4(), 5000000)                                            AS CUSTOMER_ID,
    DATEADD(DAY, -MOD(SEQ4(), 365), CURRENT_DATE())                 AS ORDER_DATE,
    ROUND(UNIFORM(10, 5000, RANDOM())::DECIMAL(12,2), 2)            AS AMOUNT,
    CASE MOD(SEQ4(), 4)
        WHEN 0 THEN 'ELECTRONICS'
        WHEN 1 THEN 'CLOTHING'
        WHEN 2 THEN 'GROCERIES'
        ELSE 'FURNITURE'
    END                                                             AS PRODUCT_CATEGORY
FROM TABLE(GENERATOR(ROWCOUNT => 10000000));

CREATE OR REPLACE TABLE PRODUCTS (
    PRODUCT_ID      INT,
    PRODUCT_NAME    VARCHAR(100),
    CATEGORY        VARCHAR(50),
    PRICE           DECIMAL(10,2)
);

INSERT INTO PRODUCTS
SELECT 
    SEQ4()                                                          AS PRODUCT_ID,
    'PRODUCT_' || SEQ4()                                            AS PRODUCT_NAME,
    CASE MOD(SEQ4(), 4)
        WHEN 0 THEN 'ELECTRONICS'
        WHEN 1 THEN 'CLOTHING'
        WHEN 2 THEN 'GROCERIES'
        ELSE 'FURNITURE'
    END                                                             AS CATEGORY,
    ROUND(UNIFORM(5, 2000, RANDOM())::DECIMAL(10,2), 2)             AS PRICE
FROM TABLE(GENERATOR(ROWCOUNT => 1000000));

SELECT * FROM CUSTOMERS;
```

---

## Section 3: Check 1 — Is the Query Queued?

### What to Look For in Query Profile

- Go to Snowsight → Monitoring → Query History
- Check the STATUS column: "Queued" means waiting for warehouse resources

### Why It Happens

- Warehouse is too small for concurrent load
- Too many queries running at the same time
- Warehouse is suspended and needs to resume (cold start)

### How to Fix

- **Scale UP:** Use a larger warehouse
- **Scale OUT:** Use multi-cluster warehouse (auto-scaling)
- **Move queries** to a separate warehouse

### Check Warehouse Load and Queuing History

```sql
SELECT 
    TO_DATE(START_TIME)     AS QUERY_DATE,
    WAREHOUSE_NAME,
    COUNT(*)                AS TOTAL_QUERIES,
    AVG(QUEUED_OVERLOAD_TIME) / 1000    AS AVG_QUEUE_TIME_SEC,
    MAX(QUEUED_OVERLOAD_TIME) / 1000    AS MAX_QUEUE_TIME_SEC,
    AVG(TOTAL_ELAPSED_TIME) / 1000      AS AVG_ELAPSED_TIME_SEC
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATEADD('HOURS', -24, CURRENT_TIMESTAMP()),
    CURRENT_TIMESTAMP()
))
WHERE WAREHOUSE_NAME IS NOT NULL
GROUP BY 1, 2
ORDER BY AVG_QUEUE_TIME_SEC DESC;
```

> If `AVG_QUEUE_TIME_SEC` is high → warehouse is overloaded!

---

## Section 4: Check 2 — Is the Query Spilling to Disk?

### What to Look For in Query Profile

- Click on any operator node (especially Sort, Aggregate, Join)
- Under STATISTICS → Spilling section:
  - **"Bytes spilled to local storage"** → Spilled to warehouse SSD (slow)
  - **"Bytes spilled to remote storage"** → Spilled to cloud storage (VERY slow)

### Why It Happens

- Data too large to fit in warehouse memory
- Complex operations (GROUP BY, ORDER BY, large JOINs)

### Impact

- Local spilling: **2-5x slower**
- Remote spilling: **10-50x slower**

### How to Fix

- Use a **LARGER** warehouse (more memory + local disk)
- **Reduce data** processed (add filters, limit columns)
- **Break query** into smaller steps using temp tables
- **Reduce concurrent queries** on the warehouse

### Example: Query Likely to Spill on Small Warehouse

```sql
SELECT 
    C.REGION,
    O.PRODUCT_CATEGORY,
    COUNT(DISTINCT C.CUSTOMER_ID)       AS UNIQUE_CUSTOMERS,
    SUM(O.AMOUNT)                       AS TOTAL_REVENUE,
    AVG(O.AMOUNT)                       AS AVG_ORDER_VALUE,
    COUNT(O.ORDER_ID)                   AS TOTAL_ORDERS
FROM ORDERS O
JOIN CUSTOMERS C ON O.CUSTOMER_ID = C.CUSTOMER_ID
GROUP BY C.REGION, O.PRODUCT_CATEGORY
ORDER BY TOTAL_REVENUE DESC;
```

After running, check Query Profile:
1. Click on the Aggregate node
2. Look at Statistics → Spilling section
3. If "Bytes spilled to local/remote storage" > 0, it's spilling!

### Programmatic Check: Find Spilling Queries from History

```sql
SELECT 
    QUERY_ID,
    SUBSTR(QUERY_TEXT, 1, 80)                               AS QUERY_PREVIEW,
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    TOTAL_ELAPSED_TIME / 1000                               AS DURATION_SEC,
    BYTES_SPILLED_TO_LOCAL_STORAGE / (1024*1024)             AS SPILLED_LOCAL_MB,
    BYTES_SPILLED_TO_REMOTE_STORAGE / (1024*1024)            AS SPILLED_REMOTE_MB
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATEADD('HOURS', -24, CURRENT_TIMESTAMP()),
    CURRENT_TIMESTAMP()
))
WHERE BYTES_SPILLED_TO_LOCAL_STORAGE > 0
   OR BYTES_SPILLED_TO_REMOTE_STORAGE > 0
ORDER BY BYTES_SPILLED_TO_REMOTE_STORAGE DESC
LIMIT 10;
```

### Fix: Break the Large Query into Steps Using Temp Tables

```sql
CREATE OR REPLACE TEMPORARY TABLE TEMP_ORDER_SUMMARY AS
SELECT 
    CUSTOMER_ID,
    PRODUCT_CATEGORY,
    SUM(AMOUNT)     AS TOTAL_AMOUNT,
    COUNT(ORDER_ID) AS ORDER_COUNT
FROM ORDERS
GROUP BY CUSTOMER_ID, PRODUCT_CATEGORY;

SELECT 
    C.REGION,
    T.PRODUCT_CATEGORY,
    COUNT(DISTINCT C.CUSTOMER_ID)   AS UNIQUE_CUSTOMERS,
    SUM(T.TOTAL_AMOUNT)             AS TOTAL_REVENUE,
    SUM(T.TOTAL_AMOUNT) / SUM(T.ORDER_COUNT) AS AVG_ORDER_VALUE,
    SUM(T.ORDER_COUNT)              AS TOTAL_ORDERS
FROM TEMP_ORDER_SUMMARY T
JOIN CUSTOMERS C ON T.CUSTOMER_ID = C.CUSTOMER_ID
GROUP BY C.REGION, T.PRODUCT_CATEGORY
ORDER BY TOTAL_REVENUE DESC;
```

---

## Section 5: Check 3 — Is Partition Pruning Efficient?

### What to Look For in Query Profile

- Click on the TableScan node
- Under STATISTICS → Pruning section:
  - **"Partitions total"** → Total micro-partitions in table
  - **"Partitions scanned"** → How many Snowflake actually read

| Scenario | Meaning |
|----------|---------|
| Partitions scanned << Partitions total | GOOD (e.g., 5 out of 500) |
| Partitions scanned ≈ Partitions total | BAD (full table scan!) |

### Why It Happens

- No filter (WHERE clause) in the query
- Filter on a column that doesn't align with data's natural ordering
- Using functions on filter columns: `WHERE YEAR(date_col) = 2025`
- Using OR conditions that prevent pruning

### How to Fix

- Add/improve WHERE clauses
- Use clustering keys on frequently filtered columns
- Avoid wrapping filter columns in functions

### BAD Query: Full Table Scan — No Filter

```sql
SELECT COUNT(*), AVG(AMOUNT) FROM ORDERS;
```

After running, check: Partitions scanned = Partitions total (FULL SCAN — expected for no filter)

### BETTER Query: With Date Filter — Enables Pruning

```sql
SELECT COUNT(*), AVG(AMOUNT)
FROM ORDERS
WHERE ORDER_DATE >= '2026-01-01';
```

After running, check: Partitions scanned < Partitions total (PRUNING WORKED!)

### BAD Practice: Function on Filter Column Prevents Pruning

```sql
SELECT COUNT(*) FROM ORDERS
WHERE YEAR(ORDER_DATE) = 2026 AND MONTH(ORDER_DATE) = 1;
```

### GOOD Practice: Direct Date Range Comparison Enables Pruning

```sql
SELECT COUNT(*) FROM ORDERS
WHERE ORDER_DATE >= '2026-01-01' AND ORDER_DATE < '2026-02-01';
```

> Compare the two queries above in Query Profile! The function-based query will scan more partitions.

### Check Clustering Health

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('ORDERS', '(ORDER_DATE)');
```

### Add Clustering Key if Pruning is Poor

```sql
ALTER TABLE ORDERS CLUSTER BY (ORDER_DATE);
```

---

## Section 6: Check 4 — Row Explosion in Joins

### What to Look For in Query Profile

- Click on the Join node
- Under STATISTICS:
  - **"Input rows"** → Rows going INTO the join
  - **"Output rows"** → Rows coming OUT of the join

**RED FLAG:** Output rows >> Input rows (e.g., 1M input → 100M output)
This is called **"ROW EXPLOSION"** or **"EXPLODING JOIN"**

### Why It Happens

- Missing join condition (Cartesian product)
- Join key is not unique (many-to-many relationship)
- Wrong join column chosen

### How to Fix

- Verify join conditions are correct
- Add missing join predicates
- Pre-aggregate before joining
- Use DISTINCT or GROUP BY to reduce duplicates

### Example: Intentional Cartesian Join (VERY BAD — Row Explosion!)

> WARNING: This creates a massive result set! We limit it for safety.

```sql
SELECT *
FROM CUSTOMERS C
CROSS JOIN PRODUCTS P
WHERE C.REGION = 'NORTH'
  AND P.CATEGORY = 'ELECTRONICS';
```

```sql
SELECT count(*)
FROM CUSTOMERS c
WHERE c.REGION = 'NORTH'; --1M

SELECT count(*)
FROM PRODUCTS P
WHERE P.CATEGORY = 'ELECTRONICS'; --0.25M
```

After running, check Query Profile: Join node output rows will be dramatically larger than input rows!

### GOOD Join: Proper Join Condition, Controlled Output

```sql
SELECT 
    C.CUSTOMER_NAME,
    O.ORDER_ID,
    O.AMOUNT
FROM CUSTOMERS C
JOIN ORDERS O ON C.CUSTOMER_ID = O.CUSTOMER_ID
WHERE C.REGION = 'NORTH'
  AND O.ORDER_DATE >= '2026-01-01';
```

After running, check Query Profile: Join node output rows should be reasonable relative to input rows.

### Programmatic Check: Find Exploding Joins

```sql
SET LAST_QID = LAST_QUERY_ID();

SELECT 
    OPERATOR_ID,
    OPERATOR_TYPE,
    OPERATOR_STATISTICS:input_rows::INT      AS INPUT_ROWS,
    OPERATOR_STATISTICS:output_rows::INT     AS OUTPUT_ROWS,
    ROUND(
        OPERATOR_STATISTICS:output_rows / 
        NULLIF(OPERATOR_STATISTICS:input_rows, 0), 2
    )                                        AS ROW_MULTIPLIER
FROM TABLE(GET_QUERY_OPERATOR_STATS($LAST_QID))
WHERE OPERATOR_TYPE = 'Join'
ORDER BY ROW_MULTIPLIER DESC;
```

> If `ROW_MULTIPLIER >> 1`, you have a row explosion problem!

---

## Section 7: Check 5 — Is Result Caching Being Used?

### What to Look For in Query Profile

- If result is cached, Query Profile shows: **"Query Result Reuse"**
- Only 1 node (no TableScan, no Join, nothing)
- Query returns INSTANTLY (0 seconds)

### Result Cache Conditions

- Same query text (exact match)
- Same role
- Underlying data hasn't changed
- Cache is valid for 24 hours
- `USE_CACHED_RESULT = TRUE` (default)

### When Cache is NOT Used

- Query uses non-deterministic functions (`CURRENT_TIMESTAMP`, `RANDOM`, etc.)
- Underlying table data has changed
- Different role running the query
- `USE_CACHED_RESULT = FALSE`

### Example: Run This Query TWICE

```sql
SELECT REGION, COUNT(*) AS CUSTOMER_COUNT
FROM CUSTOMERS
GROUP BY REGION
ORDER BY CUSTOMER_COUNT DESC;
```

- **First run:** Full execution (TableScan, Aggregate, Sort in Query Profile)
- **Second run:** Query Profile shows "Query Result Reuse" — instant!

### Check if Result Caching is Enabled

```sql
SHOW PARAMETERS LIKE 'USE_CACHED_RESULT' IN SESSION;
```

### Force Disable Caching to Test True Query Performance

```sql
ALTER SESSION SET USE_CACHED_RESULT = FALSE;
```

### Re-enable Caching

```sql
ALTER SESSION SET USE_CACHED_RESULT = TRUE;
```

---

## Section 8: Reading the Query Profile — Complete Reference

### Execution Time Breakdown (Overview Panel — Top Right, No Node Selected)

| Category | What It Means |
|----------|---------------|
| Processing | CPU time doing actual work |
| Local Disk IO | Waiting for local SSD reads/writes |
| Remote Disk IO | Waiting for cloud storage reads/writes |
| Network Communication | Data transfer between nodes |
| Synchronization | Coordination between parallel processes |
| Initialization | Setup time for query processing |

**IDEAL:** Processing should be the largest portion.

**RED FLAGS:**
- High Remote Disk IO = spilling or cold cache
- High Synchronization = too much parallelism overhead

### Operator Nodes (The Boxes in the Tree)

| Operator | What It Does |
|----------|--------------|
| TableScan | Reads data from a table |
| Filter | Applies WHERE conditions |
| Join | Combines two tables (INNER, LEFT, etc.) |
| JoinFilter | Pre-filters rows before they reach the Join |
| Aggregate | GROUP BY, COUNT, SUM, AVG etc. |
| Sort | ORDER BY |
| SortWithLimit | ORDER BY ... LIMIT ... OFFSET |
| WindowFunction | ROW_NUMBER, RANK, LAG, LEAD etc. |
| Result | Final output returned to client |
| Flatten | Processes VARIANT/ARRAY/OBJECT data |
| UnionAll | Combines results from UNION ALL |

### Statistics Per Node (Click on a Node to See)

**IO Section:**
- `Scan progress` → % of table data read
- `Bytes scanned` → How much data was read
- `% scanned from cache` → Data served from warehouse cache (higher = better)

**Pruning Section (TableScan only):**
- `Partitions total` → Total micro-partitions in the table
- `Partitions scanned` → Partitions actually read

**Spilling Section:**
- `Bytes spilled to local` → Data overflowed to local SSD
- `Bytes spilled to remote` → Data overflowed to cloud storage (VERY BAD)

**Row Counts:**
- `Input rows` → Rows received by this operator
- `Output rows` → Rows produced by this operator

### Most Expensive Nodes (Bottom Right Panel)

Lists nodes consuming >= 1% of total execution time. This is your **STARTING POINT** for optimization!

---

## Section 9: Full Troubleshooting Workflow — Put It All Together

### Step 1: Run a Complex Query

```sql
SELECT 
    C.REGION,
    C.STATUS,
    O.PRODUCT_CATEGORY,
    DATE_TRUNC('MONTH', O.ORDER_DATE)   AS ORDER_MONTH,
    COUNT(DISTINCT C.CUSTOMER_ID)       AS UNIQUE_CUSTOMERS,
    COUNT(O.ORDER_ID)                   AS TOTAL_ORDERS,
    SUM(O.AMOUNT)                       AS TOTAL_REVENUE,
    AVG(O.AMOUNT)                       AS AVG_ORDER_VALUE,
    MAX(O.AMOUNT)                       AS MAX_ORDER_VALUE
FROM ORDERS O
JOIN CUSTOMERS C ON O.CUSTOMER_ID = C.CUSTOMER_ID
WHERE O.ORDER_DATE >= '2025-06-01'
GROUP BY C.REGION, C.STATUS, O.PRODUCT_CATEGORY, ORDER_MONTH
ORDER BY TOTAL_REVENUE DESC;
```

### Step 2: Capture the Query ID

```sql
SET QID = LAST_QUERY_ID();
```

### Step 3: Analyze with GET_QUERY_OPERATOR_STATS

```sql
SELECT 
    OPERATOR_ID,
    OPERATOR_TYPE,
    OPERATOR_STATISTICS,
    EXECUTION_TIME_BREAKDOWN,
    OPERATOR_ATTRIBUTES
FROM TABLE(GET_QUERY_OPERATOR_STATS($QID))
ORDER BY OPERATOR_ID;
```

### Step 4: Check for Expensive Operators (Time Breakdown)

```sql
SELECT 
    OPERATOR_ID,
    OPERATOR_TYPE,
    EXECUTION_TIME_BREAKDOWN:overall_percentage::FLOAT   AS PCT_OF_TOTAL_TIME,
    EXECUTION_TIME_BREAKDOWN:processing::FLOAT           AS PCT_PROCESSING,
    EXECUTION_TIME_BREAKDOWN:local_disk_io::FLOAT        AS PCT_LOCAL_IO,
    EXECUTION_TIME_BREAKDOWN:remote_disk_io::FLOAT       AS PCT_REMOTE_IO,
    EXECUTION_TIME_BREAKDOWN:network_communication::FLOAT AS PCT_NETWORK,
    EXECUTION_TIME_BREAKDOWN:synchronization::FLOAT      AS PCT_SYNC
FROM TABLE(GET_QUERY_OPERATOR_STATS($QID))
ORDER BY PCT_OF_TOTAL_TIME DESC;
```

### Step 5: Check Pruning Efficiency for TableScan Nodes

```sql
SELECT 
    OPERATOR_ID,
    OPERATOR_TYPE,
    OPERATOR_ATTRIBUTES:table_name::VARCHAR                          AS TABLE_NAME,
    OPERATOR_STATISTICS:pruning:partitions_total::INT                AS PARTITIONS_TOTAL,
    OPERATOR_STATISTICS:pruning:partitions_scanned::INT              AS PARTITIONS_SCANNED,
    ROUND(
        OPERATOR_STATISTICS:pruning:partitions_scanned / 
        NULLIF(OPERATOR_STATISTICS:pruning:partitions_total, 0) * 100, 2
    )                                                                AS PCT_SCANNED,
    OPERATOR_STATISTICS:io:percentage_scanned_from_cache::FLOAT      AS PCT_FROM_CACHE,
    OPERATOR_STATISTICS:output_rows::INT                             AS ROWS_OUTPUT
FROM TABLE(GET_QUERY_OPERATOR_STATS($QID))
WHERE OPERATOR_TYPE = 'TableScan'
ORDER BY PCT_SCANNED DESC;
```

### Step 6: Check for Spilling

```sql
SELECT 
    OPERATOR_ID,
    OPERATOR_TYPE,
    OPERATOR_STATISTICS:spilling:bytes_spilled_local_storage::INT    AS SPILLED_LOCAL_BYTES,
    OPERATOR_STATISTICS:spilling:bytes_spilled_remote_storage::INT   AS SPILLED_REMOTE_BYTES
FROM TABLE(GET_QUERY_OPERATOR_STATS($QID))
WHERE OPERATOR_STATISTICS:spilling IS NOT NULL;
```

### Step 7: Check for Row Explosion in Joins

```sql
SELECT 
    OPERATOR_ID,
    OPERATOR_TYPE,
    OPERATOR_ATTRIBUTES:join_type::VARCHAR                           AS JOIN_TYPE,
    OPERATOR_ATTRIBUTES:equality_join_condition::VARCHAR             AS JOIN_CONDITION,
    OPERATOR_STATISTICS:input_rows::INT                              AS INPUT_ROWS,
    OPERATOR_STATISTICS:output_rows::INT                             AS OUTPUT_ROWS,
    ROUND(
        OPERATOR_STATISTICS:output_rows / 
        NULLIF(OPERATOR_STATISTICS:input_rows, 0), 2
    )                                                                AS ROW_MULTIPLIER
FROM TABLE(GET_QUERY_OPERATOR_STATS($QID))
WHERE OPERATOR_TYPE IN ('Join', 'CartesianJoin')
ORDER BY ROW_MULTIPLIER DESC;
```

---

## Section 10: Find Top Slow Queries in Your Account

### Top 20 Slowest Queries in Last 24 Hours

```sql
SELECT 
    QUERY_ID,
    SUBSTR(QUERY_TEXT, 1, 100)                              AS QUERY_PREVIEW,
    USER_NAME,
    WAREHOUSE_NAME,
    WAREHOUSE_SIZE,
    TOTAL_ELAPSED_TIME / 1000                               AS TOTAL_SEC,
    COMPILATION_TIME / 1000                                 AS COMPILE_SEC,
    QUEUED_OVERLOAD_TIME / 1000                             AS QUEUE_SEC,
    EXECUTION_TIME / 1000                                   AS EXEC_SEC,
    BYTES_SCANNED / (1024*1024)                             AS SCANNED_MB,
    BYTES_SPILLED_TO_LOCAL_STORAGE / (1024*1024)             AS SPILL_LOCAL_MB,
    BYTES_SPILLED_TO_REMOTE_STORAGE / (1024*1024)            AS SPILL_REMOTE_MB,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROWS_PRODUCED
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY(
    DATEADD('HOURS', -24, CURRENT_TIMESTAMP()),
    CURRENT_TIMESTAMP()
))
WHERE TOTAL_ELAPSED_TIME > 0
  AND ERROR_CODE IS NULL
  AND QUERY_TYPE = 'SELECT'
ORDER BY TOTAL_ELAPSED_TIME DESC
LIMIT 20;
```

---

## Section 11: Quick Reference — Troubleshooting Decision Tree

```
QUERY IS SLOW --> Go to Query Profile and ask:

+-----------------------------------------------------------------------+
| 1. Is it QUEUED?                                                      |
|    YES --> Scale up warehouse OR use multi-cluster OR separate WH      |
|    NO  --> Go to step 2                                               |
+-----------------------------------------------------------------------+
| 2. Is it SPILLING to disk?                                            |
|    LOCAL  --> Use larger warehouse OR reduce data                      |
|    REMOTE --> URGENT: Use bigger warehouse + optimize query            |
|    NO  --> Go to step 3                                               |
+-----------------------------------------------------------------------+
| 3. Is PRUNING efficient?                                              |
|    Scanned ~ Total  --> Add filters, use clustering keys              |
|    Scanned << Total --> Pruning is fine, go to step 4                 |
+-----------------------------------------------------------------------+
| 4. Is there ROW EXPLOSION?                                            |
|    Output >> Input --> Fix join condition, pre-aggregate               |
|    Output ~ Input  --> Joins are fine, go to step 5                   |
+-----------------------------------------------------------------------+
| 5. Is CACHE being used?                                               |
|    Check USE_CACHED_RESULT = TRUE                                     |
|    Ensure no non-deterministic functions                              |
+-----------------------------------------------------------------------+
| 6. Check MOST EXPENSIVE NODES in Query Profile                        |
|    Optimize the node consuming the highest % of time                  |
+-----------------------------------------------------------------------+
```

### Key Query Profile Stats to Always Check

- Partitions scanned vs total (pruning efficiency)
- % scanned from cache (cache hit rate — higher is better)
- Bytes spilled local/remote (memory pressure)
- Input rows vs output rows (row explosion on joins)
- Execution time breakdown (where time is spent)
- Most expensive nodes (which operator to optimize first)

---

## Section 12: Real Query Profile Statistics — Line by Line Explanation

### Example Query Profile Output

**Scan progress: 50.00%**
- Snowflake scanned 50% of the table's total data.
- Only HALF the table was read — the other half was PRUNED (skipped).
- This is GOOD — your WHERE filter eliminated half the partitions.
- 100% = full table scan (no pruning). Lower = better pruning.

**Bytes scanned: 13.62 MB**
- The actual amount of raw data Snowflake read from storage.
- 13.62 MB is VERY small — this query processed minimal data.
- If this number is in GBs or TBs, consider adding filters or clustering keys.

**Percentage scanned from cache: 100.00%**
- 100% of the 13.62 MB was served from the WAREHOUSE LOCAL CACHE (SSD/RAM).
- ZERO bytes were fetched from remote cloud storage (S3/Azure Blob).
- This is the BEST possible scenario — no remote IO wait time.
- Cache is populated when you run queries; subsequent queries on the same data hit the cache as long as the warehouse is running.
- If this drops to 0% → cold warehouse or first-time query on that data.

**Bytes written to result: 358.96 GB**
- This is the SIZE OF THE RESULT SET returned to the client.
- 358.96 GB is EXTREMELY LARGE — this is a **RED FLAG!**
- Possible causes:
  - `SELECT *` on a large table without LIMIT
  - Cartesian join / row explosion creating billions of rows
  - CROSS JOIN or missing join condition
- **FIX:** Add LIMIT, add WHERE filters, fix JOIN conditions, or use aggregation (GROUP BY) to reduce output size.
- Network transfer of 358 GB to the client will be very slow!

**Partitions scanned: 1**
- Only 1 micro-partition was actually read by the query.
- This is excellent — minimal IO work.

**Partitions total: 2**
- The table has 2 micro-partitions in total.
- Since only 1 of 2 was scanned, pruning efficiency = 50%.
- Snowflake skipped 1 partition entirely based on your filter.

### Overall Assessment

**GOOD:**
- Pruning is working (1 of 2 partitions scanned)
- 100% cache hit (no remote storage reads)
- Small data scanned (13.62 MB)
- No spilling (not shown = no spill)

**CONCERN:**
- Bytes written to result = 358.96 GB — this is unusually large compared to only 13.62 MB scanned. The query is producing a HUGE result set. Check if:
  - There is a CROSS JOIN or missing join condition
  - You need to add GROUP BY or LIMIT
  - The query has a row explosion in a join

---

## Cleanup

```sql
DROP TABLE CUSTOMERS;
DROP TABLE ORDERS;
DROP TABLE PRODUCTS;
DROP TABLE TEMP_ORDER_SUMMARY;
DROP DATABASE QUERY_TROUBLESHOOT_DEMO;
```
