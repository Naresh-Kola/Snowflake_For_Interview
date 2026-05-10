-- ============================================================================
-- SQL QUERY OPTIMIZATION GUIDE FOR SNOWFLAKE
-- 20 Ways to Optimize SQL Queries with Before/After Examples
-- ============================================================================


-- ============================================================================
-- 1. AVOID SELECT * — SELECT ONLY NEEDED COLUMNS
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT * FROM SALES.PUBLIC.ORDERS;

-- ✅ OPTIMIZED:
SELECT ORDER_ID, CUSTOMER_ID, ORDER_DATE, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS;

/*
WHY: Snowflake uses columnar storage. SELECT * reads ALL columns from
micro-partitions. Selecting only needed columns reduces I/O, network
transfer, and memory usage. If a table has 50 columns but you need 4,
you're reading 12.5x more data than necessary.
*/


-- ============================================================================
-- 2. USE FILTERS EARLY — PUSH PREDICATES DOWN
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT O.ORDER_ID, C.CUSTOMER_NAME, O.TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS O
JOIN SALES.PUBLIC.CUSTOMERS C ON O.CUSTOMER_ID = C.CUSTOMER_ID
WHERE O.ORDER_DATE >= '2024-01-01';

-- ✅ OPTIMIZED (filter before join using subquery/CTE):
WITH RECENT_ORDERS AS (
    SELECT ORDER_ID, CUSTOMER_ID, TOTAL_AMOUNT
    FROM SALES.PUBLIC.ORDERS
    WHERE ORDER_DATE >= '2024-01-01'
)
SELECT R.ORDER_ID, C.CUSTOMER_NAME, R.TOTAL_AMOUNT
FROM RECENT_ORDERS R
JOIN SALES.PUBLIC.CUSTOMERS C ON R.CUSTOMER_ID = C.CUSTOMER_ID;

/*
WHY: Filtering early reduces the number of rows BEFORE the join happens.
Fewer rows in the join = less memory, less shuffling between nodes,
faster execution. Snowflake's optimizer often does this automatically,
but explicit CTEs make intent clear and help in complex queries.
*/


-- ============================================================================
-- 3. AVOID FUNCTIONS ON FILTER COLUMNS — BREAKS PRUNING
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT ORDER_ID, ORDER_DATE, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
WHERE YEAR(ORDER_DATE) = 2024;

-- ✅ OPTIMIZED:
SELECT ORDER_ID, ORDER_DATE, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
WHERE ORDER_DATE >= '2024-01-01' AND ORDER_DATE < '2025-01-01';

/*
WHY: When you wrap a column in a function (YEAR, MONTH, TO_CHAR, etc.),
Snowflake cannot use partition pruning. It must scan ALL micro-partitions
and apply the function to every row. Using range predicates allows
Snowflake to skip entire micro-partitions that don't contain 2024 data.
This can reduce scan from 100% to <5% of the table.
*/


-- ============================================================================
-- 4. USE EXISTS INSTEAD OF IN FOR SUBQUERIES
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT CUSTOMER_ID, CUSTOMER_NAME
FROM SALES.PUBLIC.CUSTOMERS
WHERE CUSTOMER_ID IN (
    SELECT CUSTOMER_ID FROM SALES.PUBLIC.ORDERS WHERE TOTAL_AMOUNT > 1000
);

-- ✅ OPTIMIZED:
SELECT C.CUSTOMER_ID, C.CUSTOMER_NAME
FROM SALES.PUBLIC.CUSTOMERS C
WHERE EXISTS (
    SELECT 1 FROM SALES.PUBLIC.ORDERS O
    WHERE O.CUSTOMER_ID = C.CUSTOMER_ID AND O.TOTAL_AMOUNT > 1000
);

/*
WHY: IN builds a full result set from the subquery and then checks each
row against it. EXISTS stops searching as soon as it finds the FIRST match.
For large subquery results, EXISTS is significantly faster because it
short-circuits. The difference is dramatic when the subquery returns
millions of rows but most outer rows match early.
*/


-- ============================================================================
-- 5. REPLACE UNION WITH UNION ALL (WHEN DUPLICATES ARE OK)
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT CUSTOMER_ID, ORDER_DATE FROM SALES.PUBLIC.ORDERS_2023
UNION
SELECT CUSTOMER_ID, ORDER_DATE FROM SALES.PUBLIC.ORDERS_2024;

-- ✅ OPTIMIZED:
SELECT CUSTOMER_ID, ORDER_DATE FROM SALES.PUBLIC.ORDERS_2023
UNION ALL
SELECT CUSTOMER_ID, ORDER_DATE FROM SALES.PUBLIC.ORDERS_2024;

/*
WHY: UNION removes duplicates by sorting/hashing ALL rows from both
result sets — this is expensive. UNION ALL simply concatenates results
with no deduplication overhead. If your data doesn't have duplicates
between the sets (e.g., partitioned by year), UNION ALL is always correct
and much faster.
*/


-- ============================================================================
-- 6. USE APPROXIMATE FUNCTIONS FOR LARGE DATASETS
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT COUNT(DISTINCT CUSTOMER_ID) AS UNIQUE_CUSTOMERS
FROM SALES.PUBLIC.ORDERS;

-- ✅ OPTIMIZED:
SELECT APPROX_COUNT_DISTINCT(CUSTOMER_ID) AS UNIQUE_CUSTOMERS
FROM SALES.PUBLIC.ORDERS;

/*
WHY: COUNT(DISTINCT) requires tracking every unique value in memory —
extremely expensive for billions of rows. APPROX_COUNT_DISTINCT uses
HyperLogLog algorithm giving ~2% error margin but runs 5-10x faster
with far less memory. Perfect for dashboards where exact counts aren't
critical.
*/


-- ============================================================================
-- 7. AVOID ORDER BY WITHOUT LIMIT
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT ORDER_ID, CUSTOMER_ID, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
ORDER BY TOTAL_AMOUNT DESC;

-- ✅ OPTIMIZED:
SELECT ORDER_ID, CUSTOMER_ID, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
ORDER BY TOTAL_AMOUNT DESC
LIMIT 100;

/*
WHY: ORDER BY without LIMIT sorts the ENTIRE result set (potentially
billions of rows) just to return them in order. This causes massive
memory usage and potential spilling to disk. Adding LIMIT allows Snowflake
to use a Top-N sort algorithm which only tracks the top N rows — far less
memory and compute.
*/


-- ============================================================================
-- 8. USE CLUSTERING KEYS FOR FREQUENTLY FILTERED COLUMNS
-- ============================================================================

-- ❌ NOT OPTIMIZED (table with no clustering, filters on ORDER_DATE):
SELECT ORDER_ID, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
WHERE ORDER_DATE BETWEEN '2024-06-01' AND '2024-06-30';
-- Scans 80% of micro-partitions

-- ✅ OPTIMIZED (add clustering key):
ALTER TABLE SALES.PUBLIC.ORDERS CLUSTER BY (ORDER_DATE);

-- Same query now scans only 2-5% of micro-partitions
SELECT ORDER_ID, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
WHERE ORDER_DATE BETWEEN '2024-06-01' AND '2024-06-30';

/*
WHY: Clustering keys physically organize data within micro-partitions.
When data is clustered by ORDER_DATE, all June 2024 data is stored
together. Snowflake's partition pruning can skip 95%+ of micro-partitions.
Without clustering, dates are scattered randomly across partitions,
forcing full table scans. Best for large tables (TB+) with consistent
filter patterns.
*/


-- ============================================================================
-- 9. AVOID CROSS JOINS (CARTESIAN PRODUCTS)
-- ============================================================================

-- ❌ NOT OPTIMIZED (accidental cross join):
SELECT O.ORDER_ID, P.PRODUCT_NAME
FROM SALES.PUBLIC.ORDERS O, SALES.PUBLIC.PRODUCTS P
WHERE O.TOTAL_AMOUNT > 500;

-- ✅ OPTIMIZED (proper join condition):
SELECT O.ORDER_ID, P.PRODUCT_NAME
FROM SALES.PUBLIC.ORDERS O
JOIN SALES.PUBLIC.ORDER_ITEMS OI ON O.ORDER_ID = OI.ORDER_ID
JOIN SALES.PUBLIC.PRODUCTS P ON OI.PRODUCT_ID = P.PRODUCT_ID
WHERE O.TOTAL_AMOUNT > 500;

/*
WHY: A cross join between tables with 1M and 10K rows produces 10 BILLION
rows. This explodes memory, causes spilling, and usually times out.
Always use explicit JOIN with ON conditions. The comma-separated FROM
syntax hides this problem — use explicit JOIN syntax always.
*/


-- ============================================================================
-- 10. USE COALESCE INSTEAD OF MULTIPLE OR/IS NULL CHECKS
-- ============================================================================

-- ❌ NOT OPTIMIZED:
SELECT ORDER_ID, CUSTOMER_ID, DISCOUNT
FROM SALES.PUBLIC.ORDERS
WHERE DISCOUNT IS NOT NULL AND DISCOUNT > 0
   OR (DISCOUNT IS NULL AND TOTAL_AMOUNT > 1000);

-- ✅ OPTIMIZED:
SELECT ORDER_ID, CUSTOMER_ID, DISCOUNT
FROM SALES.PUBLIC.ORDERS
WHERE COALESCE(DISCOUNT, 0) > 0
   OR TOTAL_AMOUNT > 1000;

/*
WHY: Complex OR conditions with IS NULL checks create complicated
execution plans. COALESCE simplifies the logic, makes it more readable,
and allows the optimizer to evaluate conditions more efficiently.
Simpler predicates = better optimization opportunities.
*/


-- ============================================================================
-- 11. USE TRANSIENT/TEMPORARY TABLES FOR INTERMEDIATE RESULTS
-- ============================================================================

-- ❌ NOT OPTIMIZED (repeating expensive subquery):
SELECT * FROM (
    SELECT CUSTOMER_ID, SUM(TOTAL_AMOUNT) AS TOTAL_SPEND
    FROM SALES.PUBLIC.ORDERS
    WHERE ORDER_DATE >= '2024-01-01'
    GROUP BY CUSTOMER_ID
) WHERE TOTAL_SPEND > 10000;

-- Later in same session, same subquery again:
SELECT * FROM (
    SELECT CUSTOMER_ID, SUM(TOTAL_AMOUNT) AS TOTAL_SPEND
    FROM SALES.PUBLIC.ORDERS
    WHERE ORDER_DATE >= '2024-01-01'
    GROUP BY CUSTOMER_ID
) WHERE TOTAL_SPEND > 50000;

-- ✅ OPTIMIZED (materialize once, reuse):
CREATE TEMPORARY TABLE TEMP_CUSTOMER_SPEND AS
SELECT CUSTOMER_ID, SUM(TOTAL_AMOUNT) AS TOTAL_SPEND
FROM SALES.PUBLIC.ORDERS
WHERE ORDER_DATE >= '2024-01-01'
GROUP BY CUSTOMER_ID;

SELECT * FROM TEMP_CUSTOMER_SPEND WHERE TOTAL_SPEND > 10000;
SELECT * FROM TEMP_CUSTOMER_SPEND WHERE TOTAL_SPEND > 50000;

/*
WHY: Without materializing, Snowflake recomputes the expensive aggregation
every time. Temporary tables store the result once and subsequent queries
read from the cached result (much smaller data). Also benefits from
Snowflake's result cache if the temp table doesn't change.
*/


-- ============================================================================
-- 12. LEVERAGE RESULT CACHE — AVOID UNNECESSARY CHANGES
-- ============================================================================

-- ❌ NOT OPTIMIZED (breaks cache with CURRENT_TIMESTAMP):
SELECT ORDER_ID, TOTAL_AMOUNT, CURRENT_TIMESTAMP() AS QUERY_TIME
FROM SALES.PUBLIC.ORDERS
WHERE ORDER_DATE = '2024-06-15';

-- ✅ OPTIMIZED (remove non-deterministic function):
SELECT ORDER_ID, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
WHERE ORDER_DATE = '2024-06-15';

/*
WHY: Snowflake caches query results for 24 hours. If the same query runs
again and data hasn't changed, results return instantly (0 credits used).
But non-deterministic functions (CURRENT_TIMESTAMP, RANDOM, UUID) make
every execution unique, bypassing the cache completely. Remove them
unless actually needed.
*/


-- ============================================================================
-- 13. USE QUALIFY INSTEAD OF SUBQUERY FOR WINDOW FUNCTIONS
-- ============================================================================

-- ❌ NOT OPTIMIZED (nested subquery for window filter):
SELECT * FROM (
    SELECT
        ORDER_ID,
        CUSTOMER_ID,
        TOTAL_AMOUNT,
        ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY ORDER_DATE DESC) AS RN
    FROM SALES.PUBLIC.ORDERS
) WHERE RN = 1;

-- ✅ OPTIMIZED (QUALIFY clause):
SELECT ORDER_ID, CUSTOMER_ID, TOTAL_AMOUNT
FROM SALES.PUBLIC.ORDERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY ORDER_DATE DESC) = 1;

/*
WHY: QUALIFY filters window function results directly without a subquery
wrapper. This eliminates an extra execution step, reduces complexity for
the optimizer, and is cleaner SQL. Snowflake-native syntax that avoids
materializing the intermediate result set.
*/


-- ============================================================================
-- 14. JOIN ON INTEGERS INSTEAD OF STRINGS
-- ============================================================================

-- ❌ NOT OPTIMIZED (joining on string columns):
SELECT O.ORDER_ID, C.CUSTOMER_NAME
FROM SALES.PUBLIC.ORDERS O
JOIN SALES.PUBLIC.CUSTOMERS C ON O.CUSTOMER_CODE = C.CUSTOMER_CODE;
-- CUSTOMER_CODE is VARCHAR(50)

-- ✅ OPTIMIZED (join on integer surrogate key):
SELECT O.ORDER_ID, C.CUSTOMER_NAME
FROM SALES.PUBLIC.ORDERS O
JOIN SALES.PUBLIC.CUSTOMERS C ON O.CUSTOMER_ID = C.CUSTOMER_ID;
-- CUSTOMER_ID is NUMBER/INTEGER

/*
WHY: Integer comparisons are 2-5x faster than string comparisons.
Strings require byte-by-byte comparison, are variable length, and use
more memory for hash tables during joins. Integer keys are fixed 8 bytes,
compared in a single CPU operation. Design your schema with integer
surrogate keys for join columns.
*/


-- ============================================================================
-- 15. AVOID CORRELATED SUBQUERIES — USE JOINS INSTEAD
-- ============================================================================

-- ❌ NOT OPTIMIZED (correlated subquery runs per row):
SELECT
    C.CUSTOMER_ID,
    C.CUSTOMER_NAME,
    (SELECT MAX(ORDER_DATE)
     FROM SALES.PUBLIC.ORDERS O
     WHERE O.CUSTOMER_ID = C.CUSTOMER_ID) AS LAST_ORDER_DATE
FROM SALES.PUBLIC.CUSTOMERS C;

-- ✅ OPTIMIZED (single join):
SELECT
    C.CUSTOMER_ID,
    C.CUSTOMER_NAME,
    O.LAST_ORDER_DATE
FROM SALES.PUBLIC.CUSTOMERS C
LEFT JOIN (
    SELECT CUSTOMER_ID, MAX(ORDER_DATE) AS LAST_ORDER_DATE
    FROM SALES.PUBLIC.ORDERS
    GROUP BY CUSTOMER_ID
) O ON C.CUSTOMER_ID = O.CUSTOMER_ID;

/*
WHY: A correlated subquery conceptually executes ONCE PER ROW in the
outer query. For 1M customers, that's 1M subquery executions. A JOIN
with pre-aggregation executes the aggregation ONCE and then joins the
result. Snowflake's optimizer sometimes decorrelates automatically, but
explicit rewrite guarantees it.
*/


-- ============================================================================
-- 16. USE APPROPRIATE DATA TYPES — AVOID OVERSIZED COLUMNS
-- ============================================================================

-- ❌ NOT OPTIMIZED (oversized types):
CREATE TABLE SALES.PUBLIC.ORDERS_BAD (
    ORDER_ID VARCHAR(500),          -- only needs 20 chars
    STATUS VARCHAR(1000),           -- only 10 possible values
    QUANTITY NUMBER(38, 18),        -- never exceeds 9999
    ORDER_DATE VARCHAR(50)          -- should be DATE type
);

-- ✅ OPTIMIZED (right-sized types):
CREATE TABLE SALES.PUBLIC.ORDERS_GOOD (
    ORDER_ID NUMBER(10),
    STATUS VARCHAR(20),
    QUANTITY NUMBER(5),
    ORDER_DATE DATE
);

/*
WHY: Snowflake stores data in compressed micro-partitions. Proper data
types compress better (DATE compresses 5-10x better than VARCHAR date
strings). NUMBER(5) uses less storage than NUMBER(38,18). Better
compression = fewer micro-partitions = faster scans = less I/O.
Also enables proper partition pruning on DATE/NUMBER types.
*/


-- ============================================================================
-- 17. USE LATERAL FLATTEN EFFICIENTLY FOR SEMI-STRUCTURED DATA
-- ============================================================================

-- ❌ NOT OPTIMIZED (multiple separate parse operations):
SELECT
    RAW:order_id::NUMBER AS ORDER_ID,
    RAW:customer.name::VARCHAR AS CUSTOMER_NAME,
    RAW:customer.email::VARCHAR AS CUSTOMER_EMAIL,
    RAW:items[0].product::VARCHAR AS FIRST_PRODUCT,
    RAW:items[0].price::NUMBER AS FIRST_PRICE,
    RAW:items[1].product::VARCHAR AS SECOND_PRODUCT,
    RAW:items[1].price::NUMBER AS SECOND_PRICE,
    RAW:items[2].product::VARCHAR AS THIRD_PRODUCT,
    RAW:items[2].price::NUMBER AS THIRD_PRICE
FROM SALES.PUBLIC.RAW_ORDERS;

-- ✅ OPTIMIZED (use FLATTEN for arrays):
SELECT
    RAW:order_id::NUMBER AS ORDER_ID,
    RAW:customer.name::VARCHAR AS CUSTOMER_NAME,
    RAW:customer.email::VARCHAR AS CUSTOMER_EMAIL,
    F.VALUE:product::VARCHAR AS PRODUCT_NAME,
    F.VALUE:price::NUMBER AS PRICE
FROM SALES.PUBLIC.RAW_ORDERS,
LATERAL FLATTEN(INPUT => RAW:items) F;

/*
WHY: Hardcoding array indices (items[0], items[1]) is brittle and misses
data when arrays have variable lengths. FLATTEN handles any array size,
produces proper relational rows, and allows Snowflake to parallelize
the expansion. Also avoids repeating NULL columns for short arrays.
*/


-- ============================================================================
-- 18. PARTITION LARGE DELETES/UPDATES INTO BATCHES
-- ============================================================================

-- ❌ NOT OPTIMIZED (single massive delete):
DELETE FROM SALES.PUBLIC.ORDERS
WHERE ORDER_DATE < '2020-01-01';
-- Locks table, massive transaction log, potential timeout

-- ✅ OPTIMIZED (batch delete by partition):
DELETE FROM SALES.PUBLIC.ORDERS WHERE ORDER_DATE BETWEEN '2018-01-01' AND '2018-12-31';
DELETE FROM SALES.PUBLIC.ORDERS WHERE ORDER_DATE BETWEEN '2019-01-01' AND '2019-12-31';

-- Or use COPY + SWAP pattern for very large deletes:
CREATE TABLE SALES.PUBLIC.ORDERS_KEEP AS
SELECT * FROM SALES.PUBLIC.ORDERS WHERE ORDER_DATE >= '2020-01-01';

ALTER TABLE SALES.PUBLIC.ORDERS SWAP WITH SALES.PUBLIC.ORDERS_KEEP;

/*
WHY: Massive single DML operations create huge transaction logs, consume
excessive memory, and can time out or fail. Batching by date range
processes manageable chunks. For removing >50% of data, the COPY+SWAP
pattern is fastest — it only writes the data you WANT TO KEEP rather
than deleting what you don't.
*/


-- ============================================================================
-- 19. USE SEARCH OPTIMIZATION SERVICE FOR POINT LOOKUPS
-- ============================================================================

-- ❌ NOT OPTIMIZED (point lookup on large table without SOS):
SELECT * FROM SALES.PUBLIC.ORDERS
WHERE ORDER_ID = 'ORD-2024-789456';
-- Full table scan or inefficient pruning on non-clustered column

-- ✅ OPTIMIZED (enable Search Optimization):
ALTER TABLE SALES.PUBLIC.ORDERS ADD SEARCH OPTIMIZATION ON EQUALITY(ORDER_ID);

-- Same query now uses search access path:
SELECT * FROM SALES.PUBLIC.ORDERS
WHERE ORDER_ID = 'ORD-2024-789456';

/*
WHY: Search Optimization Service (SOS) creates a persistent data
structure (like an index) that enables near-instant point lookups.
Without SOS, Snowflake must scan or prune micro-partitions. With SOS,
it directly locates the exact micro-partition containing the row.
Best for: equality filters, IN lists, SUBSTR, GEO functions on large tables.
Cost: background maintenance uses serverless compute credits.
*/


-- ============================================================================
-- 20. USE MATERIALIZED VIEWS FOR REPEATED EXPENSIVE AGGREGATIONS
-- ============================================================================

-- ❌ NOT OPTIMIZED (expensive aggregation computed every time):
SELECT
    PRODUCT_CATEGORY,
    DATE_TRUNC('MONTH', ORDER_DATE) AS ORDER_MONTH,
    SUM(TOTAL_AMOUNT) AS MONTHLY_REVENUE,
    COUNT(DISTINCT CUSTOMER_ID) AS UNIQUE_CUSTOMERS
FROM SALES.PUBLIC.ORDERS O
JOIN SALES.PUBLIC.ORDER_ITEMS OI ON O.ORDER_ID = OI.ORDER_ID
JOIN SALES.PUBLIC.PRODUCTS P ON OI.PRODUCT_ID = P.PRODUCT_ID
GROUP BY 1, 2;

-- ✅ OPTIMIZED (create materialized view):
CREATE MATERIALIZED VIEW SALES.PUBLIC.MV_MONTHLY_REVENUE AS
SELECT
    PRODUCT_CATEGORY,
    DATE_TRUNC('MONTH', ORDER_DATE) AS ORDER_MONTH,
    SUM(TOTAL_AMOUNT) AS MONTHLY_REVENUE,
    COUNT(DISTINCT CUSTOMER_ID) AS UNIQUE_CUSTOMERS
FROM SALES.PUBLIC.ORDERS O
JOIN SALES.PUBLIC.ORDER_ITEMS OI ON O.ORDER_ID = OI.ORDER_ID
JOIN SALES.PUBLIC.PRODUCTS P ON OI.PRODUCT_ID = P.PRODUCT_ID
GROUP BY 1, 2;

-- Query the materialized view (reads pre-computed results):
SELECT * FROM SALES.PUBLIC.MV_MONTHLY_REVENUE
WHERE ORDER_MONTH >= '2024-01-01';

/*
WHY: Materialized views store pre-computed results. Snowflake auto-
maintains them when base data changes (serverless background process).
Queries against MVs read pre-aggregated data instead of scanning
billions of rows. Best for: dashboards with repeated aggregations,
frequently joined tables. Cost: storage + maintenance credits.
*/


-- ============================================================================
-- BONUS TIPS: QUERY PROFILE ANALYSIS
-- ============================================================================

/*
HOW TO FIND SLOW QUERIES AND WHAT TO LOOK FOR:

1. Check Query Profile in Snowsight (after running a query):
   - Look for "Bytes Scanned" vs "Bytes Sent" ratio
   - High scan, low sent = poor filtering
   - Look for "Spillage to Local/Remote Storage" = needs more memory/warehouse size
   - Look for "Partition Pruning" = high total vs scanned = bad pruning

2. Key metrics to check:
*/

-- Find your slowest queries:
SELECT
    QUERY_ID,
    QUERY_TEXT,
    TOTAL_ELAPSED_TIME / 1000 AS SECONDS,
    BYTES_SCANNED / 1024 / 1024 / 1024 AS GB_SCANNED,
    PARTITIONS_SCANNED,
    PARTITIONS_TOTAL,
    ROUND(PARTITIONS_SCANNED / NULLIF(PARTITIONS_TOTAL, 0) * 100, 2) AS PCT_SCANNED,
    BYTES_SPILLED_TO_LOCAL_STORAGE / 1024 / 1024 AS MB_SPILLED_LOCAL,
    BYTES_SPILLED_TO_REMOTE_STORAGE / 1024 / 1024 AS MB_SPILLED_REMOTE
FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE EXECUTION_STATUS = 'SUCCESS'
    AND TOTAL_ELAPSED_TIME > 30000  -- queries > 30 seconds
    AND START_TIME >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
ORDER BY TOTAL_ELAPSED_TIME DESC
LIMIT 20;

/*
INTERPRETATION:
- PCT_SCANNED > 80% on filtered queries = need clustering key or SOS
- MB_SPILLED > 0 = warehouse too small OR query needs optimization
- GB_SCANNED very high = missing filters or SELECT *
- SECONDS > 300 = candidate for materialized view or query rewrite
*/


-- ============================================================================
-- OPTIMIZATION DECISION MATRIX
-- ============================================================================

/*
| Problem                          | Solution                              |
|----------------------------------|---------------------------------------|
| Full table scans                 | Clustering keys, filters, SOS         |
| Slow joins                       | Integer keys, filter before join       |
| Repeated expensive queries       | Materialized views, temp tables       |
| Memory spilling                  | Larger warehouse, reduce data early   |
| Slow COUNT DISTINCT              | APPROX_COUNT_DISTINCT                 |
| Complex subqueries               | CTEs, EXISTS, QUALIFY                 |
| Large result sorting             | Add LIMIT, remove ORDER BY            |
| Semi-structured parsing          | FLATTEN, pre-extract to columns       |
| Same query re-runs               | Result cache (remove non-determinism) |
| Point lookups on large tables    | Search Optimization Service           |
| Dashboard aggregations           | Materialized views                    |
| Massive DML operations           | Batch by range, COPY+SWAP             |
*/


-- ============================================================================
-- END OF GUIDE
-- ============================================================================
