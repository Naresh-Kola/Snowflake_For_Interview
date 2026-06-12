-- ============================================================
-- PRUNING STRATEGIES IN SNOWFLAKE
-- Complete Guide with Examples
-- ============================================================

-- ============================================================
-- WHAT IS PRUNING?
-- ============================================================
/*
Pruning is Snowflake's technique to SKIP reading micro-partitions
that cannot contain relevant data for your query.

How Snowflake stores data:
- Tables are divided into micro-partitions (50-500 MB compressed)
- Each micro-partition stores metadata:
    * MIN/MAX values for each column
    * Number of distinct values
    * NULL count

When you run a query with a filter (WHERE clause), Snowflake checks
the metadata FIRST. If a micro-partition's MIN/MAX range doesn't
overlap with your filter, that partition is SKIPPED entirely.

Example:
- Partition 1: dates from 2024-01-01 to 2024-01-15
- Partition 2: dates from 2024-01-16 to 2024-01-31
- Query: WHERE date = '2024-01-20'
- Result: Partition 1 is PRUNED (skipped), only Partition 2 is scanned

WHY IT MATTERS:
- Less data scanned = faster queries
- Less data scanned = lower compute cost
- Can turn a full table scan into reading 1% of data
*/


-- ============================================================
-- HOW TO CHECK PRUNING EFFECTIVENESS
-- ============================================================
-- Use the query profile or these system functions:

-- Check clustering information for a table
-- SELECT SYSTEM$CLUSTERING_INFORMATION('database.schema.table_name', '(column1, column2)');

-- Check partition info from query profile:
-- "Partitions scanned" vs "Partitions total" in the query profile
-- Goal: scanned << total


-- ============================================================
-- STRATEGY 1: FILTER ON NATURAL CLUSTERING COLUMNS
-- ============================================================
/*
Snowflake naturally clusters data by INSERT ORDER.
If you insert data chronologically, date/timestamp columns
will be naturally clustered.

GOOD: Filter on the column data was loaded by (usually date)
BAD:  Filter on a random column with no natural order
*/

-- Setup example table
CREATE OR REPLACE TABLE sales_data (
    sale_id INT AUTOINCREMENT,
    sale_date DATE,
    customer_id INT,
    product_id INT,
    region VARCHAR(20),
    amount NUMBER(12,2)
);

-- Insert data in chronological order (simulating daily loads)
INSERT INTO sales_data (sale_date, customer_id, product_id, region, amount)
SELECT
    DATEADD('DAY', SEQ4() % 365, '2024-01-01') AS sale_date,
    UNIFORM(1, 10000, RANDOM()) AS customer_id,
    UNIFORM(1, 500, RANDOM()) AS product_id,
    CASE UNIFORM(1, 4, RANDOM())
        WHEN 1 THEN 'NORTH'
        WHEN 2 THEN 'SOUTH'
        WHEN 3 THEN 'EAST'
        ELSE 'WEST'
    END AS region,
    ROUND(UNIFORM(10, 5000, RANDOM()), 2) AS amount
FROM TABLE(GENERATOR(ROWCOUNT => 10000000));

-- GOOD PRUNING: Filter on sale_date (naturally clustered)
SELECT COUNT(*), SUM(amount)
FROM sales_data
WHERE sale_date = '2024-06-15';
-- Snowflake prunes most partitions, scans only ~1/365th of data

-- BAD PRUNING: Filter on customer_id (random distribution)
SELECT COUNT(*), SUM(amount)
FROM sales_data
WHERE customer_id = 5000;
-- Snowflake must scan ALL partitions (customer_id is spread everywhere)


-- ============================================================
-- STRATEGY 2: CLUSTERING KEYS
-- ============================================================
/*
When natural clustering isn't enough, define CLUSTERING KEYS
to physically re-organize data within micro-partitions.

WHEN TO USE:
- Table is large (multi-TB)
- Queries frequently filter on columns that aren't naturally clustered
- You see high "partitions scanned / partitions total" ratio

WHEN NOT TO USE:
- Small tables (< few GB) -- pruning benefit is minimal
- Table is already well-clustered naturally
- Adds cost (automatic reclustering runs in background)
*/

-- Add a clustering key on columns you frequently filter
ALTER TABLE sales_data CLUSTER BY (sale_date, region);

-- Check clustering depth (lower = better clustered)
SELECT SYSTEM$CLUSTERING_INFORMATION('sales_data', '(sale_date, region)');

-- Now this query benefits from pruning on BOTH columns:
SELECT COUNT(*), SUM(amount)
FROM sales_data
WHERE sale_date BETWEEN '2024-03-01' AND '2024-03-31'
  AND region = 'NORTH';

-- CLUSTERING KEY BEST PRACTICES:
/*
┌─────────────────────────────────────────────────────────────┐
│ RULE                          │ REASON                      │
├─────────────────────────────────────────────────────────────┤
│ Max 3-4 columns               │ More columns = less         │
│                               │ effective clustering         │
├─────────────────────────────────────────────────────────────┤
│ Low cardinality first         │ region (4 values) before    │
│                               │ customer_id (10000 values)  │
├─────────────────────────────────────────────────────────────┤
│ Most filtered columns         │ Only cluster on columns     │
│                               │ used in WHERE clauses       │
├─────────────────────────────────────────────────────────────┤
│ Date column is usually first  │ Time-based queries are      │
│ or second                     │ extremely common            │
├─────────────────────────────────────────────────────────────┤
│ Avoid high-cardinality alone  │ UUID, email = bad keys      │
│                               │ (too many distinct values)  │
└─────────────────────────────────────────────────────────────┘
*/

-- Example: Choosing column order
-- If queries mostly filter by region + date:
ALTER TABLE sales_data CLUSTER BY (region, sale_date);

-- If queries mostly filter by date + region:
ALTER TABLE sales_data CLUSTER BY (sale_date, region);

-- Drop clustering key if no longer needed (stops reclustering costs)
ALTER TABLE sales_data DROP CLUSTERING KEY;


-- ============================================================
-- STRATEGY 3: WRITE QUERIES THAT ENABLE PRUNING
-- ============================================================
/*
Even with good clustering, BAD query patterns defeat pruning.
*/

-- GOOD: Direct comparison on clustered column
SELECT * FROM sales_data WHERE sale_date = '2024-06-15';

-- GOOD: Range filter on clustered column
SELECT * FROM sales_data WHERE sale_date BETWEEN '2024-06-01' AND '2024-06-30';

-- GOOD: IN list on clustered column
SELECT * FROM sales_data WHERE region IN ('NORTH', 'SOUTH');

-- BAD: Function on clustered column (prevents pruning!)
SELECT * FROM sales_data WHERE YEAR(sale_date) = 2024;
-- Fix: Use range instead
SELECT * FROM sales_data WHERE sale_date >= '2024-01-01' AND sale_date < '2025-01-01';

-- BAD: CAST on clustered column
SELECT * FROM sales_data WHERE sale_date::VARCHAR = '2024-06-15';
-- Fix: Cast the literal, not the column
SELECT * FROM sales_data WHERE sale_date = '2024-06-15'::DATE;

-- BAD: Expression on clustered column
SELECT * FROM sales_data WHERE sale_date - 7 = '2024-06-08';
-- Fix: Move expression to the other side
SELECT * FROM sales_data WHERE sale_date = DATEADD('DAY', 7, '2024-06-08');

-- BAD: OR with non-clustered column (may defeat pruning)
SELECT * FROM sales_data WHERE sale_date = '2024-06-15' OR customer_id = 5000;
-- Fix: Use UNION ALL if both sides can prune independently
SELECT * FROM sales_data WHERE sale_date = '2024-06-15'
UNION ALL
SELECT * FROM sales_data WHERE customer_id = 5000 AND sale_date != '2024-06-15';


-- ============================================================
-- STRATEGY 4: PARTITION ELIMINATION WITH SUBQUERIES
-- ============================================================
/*
When joining tables, structure queries so the driving table's
filter helps prune the joined table.
*/

-- Example: Orders and Order_Items tables
CREATE OR REPLACE TABLE orders (
    order_id INT,
    order_date DATE,
    customer_id INT,
    status VARCHAR(20)
);

CREATE OR REPLACE TABLE order_items (
    item_id INT,
    order_id INT,
    order_date DATE,  -- Denormalized for pruning!
    product_id INT,
    quantity INT,
    price NUMBER(10,2)
);

-- GOOD: Filter on order_date in BOTH tables (prunes both sides)
SELECT o.order_id, o.status, SUM(oi.quantity * oi.price) AS total
FROM orders o
JOIN order_items oi
    ON o.order_id = oi.order_id
    AND o.order_date = oi.order_date   -- Pruning-friendly join
WHERE o.order_date = '2024-06-15'
GROUP BY o.order_id, o.status;

-- BAD: Only filter on one side (other table does full scan)
SELECT o.order_id, o.status, SUM(oi.quantity * oi.price) AS total
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_date = '2024-06-15'
GROUP BY o.order_id, o.status;
-- order_items has no date filter, so Snowflake may scan all its partitions

/*
KEY INSIGHT: Denormalizing the partition/clustering column into
child tables allows pruning on BOTH sides of a join.
This is why star schemas in Snowflake often include the date
in fact tables rather than only in the dimension.
*/


-- ============================================================
-- STRATEGY 5: SEARCH OPTIMIZATION SERVICE (SOS)
-- ============================================================
/*
For point lookups on HIGH-CARDINALITY columns (UUID, email, etc.)
where clustering keys don't help.

SOS builds a search access path (like an index) that tells
Snowflake which micro-partitions contain a specific value.

WHEN TO USE:
- Equality filters (=) or IN on high-cardinality columns
- Columns with millions of distinct values
- Queries that look up specific records (needle in a haystack)

COST:
- Serverless compute for maintaining the search structure
- Storage for the access path metadata
*/

-- Enable search optimization on the table
ALTER TABLE sales_data ADD SEARCH OPTIMIZATION;

-- Enable for specific columns (more targeted, lower cost)
ALTER TABLE sales_data ADD SEARCH OPTIMIZATION
    ON EQUALITY(customer_id);

ALTER TABLE sales_data ADD SEARCH OPTIMIZATION
    ON EQUALITY(customer_id, product_id);

-- Also supports SUBSTRING and GEO searches
ALTER TABLE sales_data ADD SEARCH OPTIMIZATION
    ON SUBSTRING(region);

-- Check optimization status
SHOW TABLES LIKE 'sales_data';
-- Look at "search_optimization" and "search_optimization_progress" columns

-- Drop search optimization
ALTER TABLE sales_data DROP SEARCH OPTIMIZATION;

-- Drop for specific columns only
ALTER TABLE sales_data DROP SEARCH OPTIMIZATION
    ON EQUALITY(customer_id);


-- ============================================================
-- STRATEGY 6: TIME-BASED PARTITIONING PATTERNS
-- ============================================================
/*
Design your data loading to maximize natural pruning.
*/

-- PATTERN 1: Daily partition-style loading
-- Load each day's data in a batch → natural date clustering
-- Data for 2024-01-01 sits together in partitions

-- PATTERN 2: Use DATE_TRUNC for coarser pruning
-- If you don't need day-level, cluster by month
ALTER TABLE sales_data CLUSTER BY (DATE_TRUNC('MONTH', sale_date), region);

-- PATTERN 3: Separate hot/cold data
-- Recent data (hot): frequently queried, keep in main table
-- Old data (cold): rarely queried, move to archive table
CREATE OR REPLACE TABLE sales_data_archive AS
SELECT * FROM sales_data WHERE sale_date < '2023-01-01';

DELETE FROM sales_data WHERE sale_date < '2023-01-01';
-- Now queries on recent data scan a smaller table


-- ============================================================
-- STRATEGY 7: MATERIALIZED VIEWS FOR PRE-FILTERED DATA
-- ============================================================
/*
Materialized views can pre-filter and pre-aggregate data,
giving Snowflake a smaller dataset to prune against.
*/

-- Materialized view for a specific region (pre-filtered)
CREATE OR REPLACE MATERIALIZED VIEW mv_north_sales AS
SELECT sale_date, customer_id, product_id, amount
FROM sales_data
WHERE region = 'NORTH';

-- Queries filtered to NORTH region automatically use this MV
-- Snowflake picks the MV when it's more efficient
SELECT SUM(amount)
FROM sales_data
WHERE region = 'NORTH' AND sale_date = '2024-06-15';
-- May use mv_north_sales (smaller, already filtered)


-- ============================================================
-- STRATEGY 8: MONITORING AND MEASURING PRUNING
-- ============================================================

-- Method 1: Query Profile (in Snowsight UI)
-- Run your query, then check the query profile:
-- Look at TableScan operator → "Partitions scanned" vs "Partitions total"
-- Pruning % = (1 - scanned/total) * 100

-- Method 2: SYSTEM$CLUSTERING_INFORMATION
SELECT SYSTEM$CLUSTERING_INFORMATION('sales_data', '(sale_date)');
/*
Returns JSON with:
- cluster_by_keys: columns evaluated
- total_partition_count: total micro-partitions
- average_overlaps: avg overlap between partitions (lower = better)
- average_depth: avg partitions a value spans (lower = better, 1-2 is ideal)

INTERPRETING average_depth:
  1-2  = Excellent clustering
  3-5  = Good, may benefit from reclustering
  5-10 = Poor, consider adding clustering key
  10+  = Very poor, clustering key recommended
*/

-- Method 3: Query history for scan stats
SELECT
    query_id,
    query_text,
    partitions_scanned,
    partitions_total,
    ROUND((1 - partitions_scanned / NULLIF(partitions_total, 0)) * 100, 2) AS pruning_pct,
    bytes_scanned,
    total_elapsed_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE query_text ILIKE '%sales_data%'
  AND partitions_total > 0
ORDER BY start_time DESC
LIMIT 20;


-- ============================================================
-- STRATEGY 9: AVOIDING ANTI-PATTERNS
-- ============================================================

-- ANTI-PATTERN 1: SELECT * without filters
-- Scans entire table, no pruning possible
SELECT * FROM sales_data; -- BAD for large tables

-- ANTI-PATTERN 2: Functions on filter columns
SELECT * FROM sales_data WHERE UPPER(region) = 'NORTH'; -- BAD
SELECT * FROM sales_data WHERE region = 'NORTH';        -- GOOD

-- ANTI-PATTERN 3: Implicit type conversion
SELECT * FROM sales_data WHERE sale_date = '2024-06-15';       -- GOOD (auto-cast works)
SELECT * FROM sales_data WHERE sale_date = 20240615;           -- BAD (numeric comparison)

-- ANTI-PATTERN 4: LIKE with leading wildcard
SELECT * FROM sales_data WHERE region LIKE '%ORTH';   -- BAD (can't prune)
SELECT * FROM sales_data WHERE region LIKE 'NOR%';    -- BETTER (prefix can prune)
-- For substring searches, use SEARCH OPTIMIZATION instead

-- ANTI-PATTERN 5: NOT IN / NOT EXISTS on clustered columns
-- These often require scanning all partitions to find exclusions
SELECT * FROM sales_data WHERE region NOT IN ('NORTH', 'SOUTH'); -- Less pruning-friendly
SELECT * FROM sales_data WHERE region IN ('EAST', 'WEST');       -- Better pruning

-- ANTI-PATTERN 6: Overly broad date ranges
SELECT * FROM sales_data WHERE sale_date >= '2020-01-01'; -- Scans years of data
SELECT * FROM sales_data WHERE sale_date >= '2024-06-01'  -- Much narrower
  AND sale_date < '2024-07-01';


-- ============================================================
-- STRATEGY 10: CLUSTERING KEY SELECTION FRAMEWORK
-- ============================================================
/*
Step-by-step process to choose the right clustering key:

STEP 1: Identify your most common/expensive queries
    → Look at query history for top resource consumers

STEP 2: Find columns in WHERE/JOIN that appear most often
    → These are clustering key candidates

STEP 3: Check cardinality of candidate columns
    → Low cardinality (< 1000 distinct) = good first column
    → Medium cardinality (1000-100000) = good second column
    → High cardinality (100000+) = use SEARCH OPTIMIZATION instead

STEP 4: Order columns by:
    1st: Lowest cardinality, most frequently filtered
    2nd: Next lowest cardinality, frequently filtered
    3rd: Date/timestamp (if not already included)

STEP 5: Test and measure
    → Apply clustering key
    → Wait for reclustering to complete
    → Compare query performance before/after

STEP 6: Monitor ongoing costs
    → Automatic reclustering has serverless compute cost
    → Check: SELECT * FROM TABLE(INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY(...))
*/

-- Example: Choosing clustering keys based on query patterns
-- If most queries filter by: region + sale_date + product_id

-- Check cardinality
SELECT
    COUNT(DISTINCT region) AS region_cardinality,       -- ~4 (LOW)
    COUNT(DISTINCT sale_date) AS date_cardinality,      -- ~365 (MEDIUM)
    COUNT(DISTINCT product_id) AS product_cardinality   -- ~500 (MEDIUM)
FROM sales_data;

-- Best clustering key order: region (4) → sale_date (365) → product_id (500)
ALTER TABLE sales_data CLUSTER BY (region, sale_date, product_id);

-- Monitor reclustering cost
SELECT *
FROM TABLE(INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END => CURRENT_TIMESTAMP(),
    TABLE_NAME => 'sales_data'
));


-- ============================================================
-- SUMMARY: PRUNING STRATEGIES QUICK REFERENCE
-- ============================================================
/*
┌─────────────────────────────────────────────────────────────────────┐
│ STRATEGY              │ BEST FOR                  │ COST            │
├─────────────────────────────────────────────────────────────────────┤
│ Natural clustering    │ Date/time filters         │ Free            │
│ (insert order)        │                           │                 │
├─────────────────────────────────────────────────────────────────────┤
│ Clustering keys       │ Low-medium cardinality    │ Auto-recluster  │
│                       │ columns in WHERE          │ compute cost    │
├─────────────────────────────────────────────────────────────────────┤
│ Search Optimization   │ High cardinality          │ Serverless      │
│ Service (SOS)         │ point lookups (=, IN)     │ compute + store │
├─────────────────────────────────────────────────────────────────────┤
│ Query patterns        │ All queries               │ Free            │
│ (avoid anti-patterns) │                           │                 │
├─────────────────────────────────────────────────────────────────────┤
│ Denormalization       │ Join pruning              │ Storage         │
│ (date in fact table)  │                           │                 │
├─────────────────────────────────────────────────────────────────────┤
│ Materialized views    │ Repeated filtered queries │ Storage +       │
│                       │                           │ refresh compute │
├─────────────────────────────────────────────────────────────────────┤
│ Hot/cold separation   │ Time-decaying access      │ Management      │
│                       │ patterns                  │ overhead        │
└─────────────────────────────────────────────────────────────────────┘

GOLDEN RULES:
1. Always filter on clustered/date columns
2. Never apply functions to filter columns
3. Low cardinality columns first in clustering key
4. Use SEARCH OPTIMIZATION for high-cardinality point lookups
5. Measure with SYSTEM$CLUSTERING_INFORMATION and query profile
6. Don't cluster small tables (< few GB) — overhead exceeds benefit
*/
