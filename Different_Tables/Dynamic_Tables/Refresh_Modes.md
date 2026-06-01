# Dynamic Table Refresh Modes: Complete Hands-On Guide

All 3 modes explained with executable DML operations, side-by-side comparisons, monitoring, and real-world scenarios.

---

## Setup: Create Database, Schemas, and Source Tables

```sql
CREATE DATABASE IF NOT EXISTS DT_REFRESH_DB;
CREATE SCHEMA IF NOT EXISTS DT_REFRESH_DB.RAW;
CREATE SCHEMA IF NOT EXISTS DT_REFRESH_DB.STAGING;

CREATE OR REPLACE TABLE DT_REFRESH_DB.RAW.ORDERS (
    ORDER_ID        NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    CUSTOMER_ID     NUMBER,
    PRODUCT_NAME    VARCHAR(100),
    QUANTITY        NUMBER,
    UNIT_PRICE      NUMBER(10,2),
    ORDER_STATUS    VARCHAR(20),
    ORDER_DATE      TIMESTAMP_NTZ,
    UPDATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES
    (1,  'Laptop',          1,  999.99,  'COMPLETED', '2025-01-10 10:00:00'),
    (2,  'Mouse',           2,  29.99,   'COMPLETED', '2025-01-15 14:00:00'),
    (3,  'Keyboard',        1,  89.99,   'SHIPPED',   '2025-02-01 09:00:00'),
    (4,  'Monitor',         1,  399.99,  'PENDING',   '2025-02-10 11:00:00'),
    (5,  'Headphones',      1,  199.99,  'COMPLETED', '2025-03-01 08:00:00'),
    (1,  'USB Hub',         3,  59.99,   'SHIPPED',   '2025-03-15 13:00:00'),
    (2,  'Webcam',          1,  49.99,   'COMPLETED', '2025-04-01 10:00:00'),
    (3,  'Chair',           1,  249.99,  'PENDING',   '2025-04-10 12:00:00'),
    (4,  'Desk Lamp',       2,  34.99,   'COMPLETED', '2025-05-01 09:00:00'),
    (5,  'Laptop Stand',    1,  39.99,   'COMPLETED', '2025-05-10 16:00:00');

SELECT * FROM DT_REFRESH_DB.RAW.ORDERS ORDER BY ORDER_ID;
-- You should see 10 rows. This is our baseline.
```

---

## What Are Refresh Modes?

A dynamic table auto-updates itself from base tables. The REFRESH MODE decides **HOW** that update happens.

| Mode | What Happens During Refresh |
|------|---------------------------|
| **INCREMENTAL** | Figures out WHAT CHANGED since last refresh and merges ONLY the delta. Like updating a spreadsheet cell instead of reprinting the sheet. |
| **FULL** | Re-runs the ENTIRE SELECT query from scratch and REPLACES all data. Like reprinting the entire spreadsheet every time. |
| **AUTO** | Snowflake PICKS the best mode at creation time. The choice is made ONCE and does NOT change afterward. |

### When to Use Which:

| Mode | When to Use |
|------|------------|
| **INCREMENTAL** | <5% of data changes between refreshes. Query uses supported operators. Source tables have good data locality. |
| **FULL** | Large % of data changes. Query uses unsupported operators (PIVOT, subqueries, etc.). Data lacks locality. |
| **AUTO** | Prototyping and development ONLY. AVOID in production — behavior can change between SF releases. |

---

## Scenario 1: INCREMENTAL Refresh Mode

Processes ONLY the delta (changed rows) since the last refresh. Best for: high-volume tables where only a small % of rows change.

### Step 1: Create the INCREMENTAL dynamic table

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL
    TARGET_LAG = '5 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    INITIALIZE = ON_CREATE
    AS
        SELECT
            ORDER_ID, CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE,
            QUANTITY * UNIT_PRICE AS TOTAL_AMOUNT,
            ORDER_STATUS, ORDER_DATE
        FROM DT_REFRESH_DB.RAW.ORDERS;

-- Verify initial data loaded (should be 10 rows)
SELECT 'INCREMENTAL - INITIAL' AS CHECK_POINT, COUNT(*) AS ROW_COUNT
FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL;

SELECT * FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL ORDER BY ORDER_ID;
```

### Scenario 1A: INSERT — Add new rows

```sql
INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES
    (6, 'Tablet',     1, 499.99, 'PENDING', CURRENT_TIMESTAMP()),
    (7, 'Charger',    2, 24.99,  'PENDING', CURRENT_TIMESTAMP());

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;

-- Verify: should now be 12 rows
SELECT 'INCREMENTAL - AFTER INSERT' AS CHECK_POINT, COUNT(*) AS ROW_COUNT
FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL;

-- Check refresh history: REFRESH_ACTION should be 'INCREMENTAL'
-- STATISTICS will show numInsertedRows = 2 (only 2 rows processed, not all 12!)
SELECT
    REFRESH_ACTION, REFRESH_TRIGGER, STATE,
    STATISTICS:numInsertedRows::INT AS ROWS_INSERTED,
    STATISTICS:numDeletedRows::INT AS ROWS_DELETED,
    STATISTICS:numCopiedRows::INT AS ROWS_COPIED,
    REFRESH_START_TIME, REFRESH_END_TIME
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_REFRESH_DB.STAGING.DT_INCREMENTAL'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 3;
```

### Scenario 1B: UPDATE — Modify existing rows

```sql
-- Change status of order 4 from PENDING to SHIPPED
UPDATE DT_REFRESH_DB.RAW.ORDERS
SET ORDER_STATUS = 'SHIPPED', UPDATED_AT = CURRENT_TIMESTAMP()
WHERE ORDER_ID = 4;

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;

-- Verify: ORDER_ID=4 should now show SHIPPED
SELECT * FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL WHERE ORDER_ID = 4;

-- Check stats: should show 1 inserted + 1 deleted (UPDATE = delete old + insert new)
SELECT
    REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INSERTED,
    STATISTICS:numDeletedRows::INT AS ROWS_DELETED,
    STATISTICS:numCopiedRows::INT AS ROWS_COPIED
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_REFRESH_DB.STAGING.DT_INCREMENTAL'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
-- ROWS_INSERTED=1, ROWS_DELETED=1 → only the changed row was processed!
```

### Scenario 1C: BULK UPDATE — Modify many rows at once

```sql
UPDATE DT_REFRESH_DB.RAW.ORDERS
SET ORDER_STATUS = 'COMPLETED', UPDATED_AT = CURRENT_TIMESTAMP()
WHERE ORDER_STATUS = 'PENDING';

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;

-- Verify: no more PENDING
SELECT ORDER_STATUS, COUNT(*) AS CNT
FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL GROUP BY ORDER_STATUS ORDER BY CNT DESC;

-- Check stats: only the changed rows were processed
SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INSERTED,
    STATISTICS:numDeletedRows::INT AS ROWS_DELETED
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_REFRESH_DB.STAGING.DT_INCREMENTAL'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
```

### Scenario 1D: DELETE — Remove rows

```sql
DELETE FROM DT_REFRESH_DB.RAW.ORDERS WHERE CUSTOMER_ID = 7;

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;

-- Verify: customer 7 rows gone
SELECT * FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL WHERE CUSTOMER_ID = 7;
-- Should return 0 rows

-- Check stats: should show deletions only
SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INSERTED,
    STATISTICS:numDeletedRows::INT AS ROWS_DELETED
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_REFRESH_DB.STAGING.DT_INCREMENTAL'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
```

### Scenario 1E: MIXED DML — INSERT + UPDATE + DELETE together

```sql
INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES (8, 'SSD Drive', 1, 129.99, 'PENDING', CURRENT_TIMESTAMP());

UPDATE DT_REFRESH_DB.RAW.ORDERS
SET QUANTITY = 5, UPDATED_AT = CURRENT_TIMESTAMP() WHERE ORDER_ID = 1;

DELETE FROM DT_REFRESH_DB.RAW.ORDERS WHERE ORDER_ID = 2;

-- Single refresh handles ALL changes
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;

-- Verify
SELECT * FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL WHERE ORDER_ID = 1;
-- QUANTITY=5, TOTAL_AMOUNT=4999.95

SELECT * FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL WHERE ORDER_ID = 2;
-- 0 rows (deleted)

SELECT * FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL WHERE PRODUCT_NAME = 'SSD Drive';
-- New order

-- Check stats: all three DML types in one refresh
SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INSERTED,
    STATISTICS:numDeletedRows::INT AS ROWS_DELETED,
    STATISTICS:numCopiedRows::INT AS ROWS_COPIED
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_REFRESH_DB.STAGING.DT_INCREMENTAL'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
```

---

## How Incremental Refresh Works Behind the Scenes

| Step | What Happens |
|------|-------------|
| 1. Initialization | Enables CHANGE TRACKING. Runs full scan. Records checkpoint T1. |
| 2. Change tracking | Records delta: +INSERT(11), -DELETE(1 old)+INSERT(1 new), -DELETE(3) |
| 3. Incremental refresh | Reads ONLY the changelog, MERGEs delta into DT. Total: 4 ops, not full scan. |
| 4. No changes | Changelog empty → NO_DATA → zero compute. |

### Performance Comparison:

| Table Size | FULL Refresh | INCREMENTAL Refresh |
|-----------|-------------|-------------------|
| 10 rows, 1 changed | Scans 10 rows | Processes 1 row |
| 1M rows, 100 changed | Scans 1,000,000 rows | Processes ~100 rows |
| 1B rows, 500 changed | Scans 1,000,000,000 | Processes ~500 rows |
| Any size, 0 changed | Still scans everything | Skips entirely (NO_DATA) |

> **Analogy:** 500-page book with 3 edits. FULL = reprint entire book. INCREMENTAL = print 3 replacement pages.

---

## Scenario 2: FULL Refresh Mode

Re-runs the ENTIRE SELECT query and REPLACES all data every time. Best for: complex queries with unsupported operators, or when most data changes.

### Step 1: Create the FULL refresh dynamic table

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = FULL
    INITIALIZE = ON_CREATE
    AS
        SELECT
            ORDER_ID, CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE,
            QUANTITY * UNIT_PRICE AS TOTAL_AMOUNT,
            ORDER_STATUS, ORDER_DATE
        FROM DT_REFRESH_DB.RAW.ORDERS;

SELECT 'FULL - INITIAL' AS CHECK_POINT, COUNT(*) AS ROW_COUNT
FROM DT_REFRESH_DB.STAGING.DT_FULL;
```

### Scenario 2A: INSERT — Add new rows

```sql
INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES
    (9,  'Speaker',     1, 79.99,  'PENDING', CURRENT_TIMESTAMP()),
    (10, 'Mouse Pad',   3, 14.99,  'PENDING', CURRENT_TIMESTAMP());

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL REFRESH;

-- Check stats: ALL rows are reprocessed (not just the 2 new ones)
SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INSERTED,
    STATISTICS:numDeletedRows::INT AS ROWS_DELETED,
    STATISTICS:numCopiedRows::INT AS ROWS_COPIED,
    STATISTICS:numAddedPartitions::INT AS PARTITIONS_ADDED,
    STATISTICS:numRemovedPartitions::INT AS PARTITIONS_REMOVED
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_REFRESH_DB.STAGING.DT_FULL'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 3;
-- ROWS_INSERTED = ALL rows (entire table rebuilt), not just 2
```

### Scenario 2B: UPDATE — Modify existing rows

```sql
UPDATE DT_REFRESH_DB.RAW.ORDERS
SET UNIT_PRICE = 899.99, UPDATED_AT = CURRENT_TIMESTAMP()
WHERE ORDER_ID = 1;

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL REFRESH;

-- Verify price changed
SELECT ORDER_ID, PRODUCT_NAME, UNIT_PRICE, QUANTITY * UNIT_PRICE AS TOTAL_AMOUNT
FROM DT_REFRESH_DB.STAGING.DT_FULL WHERE ORDER_ID = 1;

-- Stats: entire table rebuilt for 1 row change
SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INSERTED,
    STATISTICS:numDeletedRows::INT AS ROWS_DELETED
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_REFRESH_DB.STAGING.DT_FULL'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
```

### Scenario 2D: TRUNCATE + RELOAD — Full table replacement

```sql
TRUNCATE TABLE DT_REFRESH_DB.RAW.ORDERS;

INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES
    (100, 'Server Rack',    1, 2999.99, 'COMPLETED', '2025-06-01 08:00:00'),
    (101, 'Network Switch', 2, 499.99,  'SHIPPED',   '2025-06-05 10:00:00'),
    (102, 'Fiber Cable',   10, 19.99,   'COMPLETED', '2025-06-10 14:00:00');

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL REFRESH;

-- DT now has completely different data
SELECT * FROM DT_REFRESH_DB.STAGING.DT_FULL ORDER BY ORDER_ID;
-- Should show only the 3 new rows
```

---

## How Full Refresh Works Behind the Scenes

| Step | What Happens |
|------|-------------|
| 1. Any refresh | Runs ENTIRE SELECT. Scans ALL rows. Writes into NEW partitions. |
| 2. SWAP | Old DT partitions dropped. New partitions become DT content. |
| 3. No changes? | Still runs full query. Has no changelog to check. Wastes compute. |
| 4. TRUNCATE+RELOAD | Handles perfectly — just a clean swap. |

### The Full Refresh Cycle:

```
Run full SELECT → Build new micro-partitions → SWAP old with new → Drop old
       ↑                                                              │
       └──────────────── repeats every refresh cycle ─────────────────┘
```

### When FULL is Actually Better:

| Scenario | Why FULL Wins |
|----------|--------------|
| 80-100% of rows change | Changelog is huge, row-by-row merge is slower than full swap |
| Unsupported operators (PIVOT, subqueries, recursive CTEs) | INCREMENTAL can't handle them |
| Source data has poor locality | Changed rows spread across all partitions |
| TRUNCATE + RELOAD is your ETL pattern | Clean swap is simpler and more efficient |

> **Analogy:** Whiteboard with today's schedule. FULL = erase and rewrite everything. INCREMENTAL = fix the 2 meetings that changed.

---

## Scenario 3: AUTO Refresh Mode

Snowflake picks the best mode at creation time. The choice is made ONCE.

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AUTO
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = AUTO
    INITIALIZE = ON_CREATE
    AS
        SELECT
            ORDER_ID, CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE,
            QUANTITY * UNIT_PRICE AS TOTAL_AMOUNT,
            ORDER_STATUS, ORDER_DATE
        FROM DT_REFRESH_DB.RAW.ORDERS;

-- Check which mode Snowflake chose
SHOW DYNAMIC TABLES LIKE 'DT_AUTO' IN SCHEMA DT_REFRESH_DB.STAGING;
-- Look at "refresh_mode" column → likely INCREMENTAL for this simple query
```

### AUTO with a complex query (may force FULL)

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AUTO_COMPLEX
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = AUTO
    AS
        SELECT
            ORDER_STATUS,
            COUNT(*) AS ORDER_COUNT,
            SUM(QUANTITY * UNIT_PRICE) AS TOTAL_REVENUE,
            AVG(QUANTITY * UNIT_PRICE) AS AVG_ORDER_VALUE,
            MIN(ORDER_DATE) AS FIRST_ORDER,
            MAX(ORDER_DATE) AS LAST_ORDER
        FROM DT_REFRESH_DB.RAW.ORDERS
        GROUP BY ORDER_STATUS;

SHOW DYNAMIC TABLES LIKE 'DT_AUTO_COMPLEX' IN SCHEMA DT_REFRESH_DB.STAGING;
```

---

## Scenario 4: Side-by-Side Comparison (Same DML, All 3 Modes)

```sql
-- Make sure all 3 DTs are refreshed to same baseline
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL REFRESH;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AUTO REFRESH;

-- Confirm same row count
SELECT 'INCREMENTAL' AS MODE, COUNT(*) AS ROWS FROM DT_REFRESH_DB.STAGING.DT_INCREMENTAL
UNION ALL
SELECT 'FULL' AS MODE, COUNT(*) AS ROWS FROM DT_REFRESH_DB.STAGING.DT_FULL
UNION ALL
SELECT 'AUTO' AS MODE, COUNT(*) AS ROWS FROM DT_REFRESH_DB.STAGING.DT_AUTO;
```

### Test 1: Single INSERT

```sql
INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES (12, 'Ethernet Cable', 5, 9.99, 'PENDING', CURRENT_TIMESTAMP());

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL REFRESH;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AUTO REFRESH;
```

**Key Observation:**
- INCREMENTAL → INS=1, DEL=0 (processed 1 row)
- FULL → INS=ALL, DEL=ALL (rebuilt entire table)
- AUTO → depends on Snowflake's choice

### Test 2: Bulk UPDATE (50% of rows)

```sql
UPDATE DT_REFRESH_DB.RAW.ORDERS
SET ORDER_STATUS = 'ARCHIVED', UPDATED_AT = CURRENT_TIMESTAMP()
WHERE ORDER_STATUS = 'COMPLETED';

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL REFRESH;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AUTO REFRESH;
```

**Key Observation:** When 50% of rows change, FULL might actually be more efficient at large volumes!

### Test 3: No changes

```sql
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL REFRESH;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL REFRESH;
```

**Key Observation:**
- INCREMENTAL → REFRESH_ACTION = 'NO_DATA' (detects no changes, skips!)
- FULL → May still rebuild everything even with no changes

---

## Scenario 5: Incremental with Aggregations

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AGG_INCREMENTAL
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            ORDER_STATUS,
            COUNT(*) AS ORDER_COUNT,
            SUM(QUANTITY * UNIT_PRICE) AS TOTAL_REVENUE,
            AVG(QUANTITY * UNIT_PRICE) AS AVG_ORDER_VALUE
        FROM DT_REFRESH_DB.RAW.ORDERS
        GROUP BY ORDER_STATUS;

-- Add a new PENDING order
INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES (13, 'Graphics Card', 1, 699.99, 'PENDING', CURRENT_TIMESTAMP());

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AGG_INCREMENTAL REFRESH;

-- PENDING count should increase by 1
SELECT * FROM DT_REFRESH_DB.STAGING.DT_AGG_INCREMENTAL ORDER BY ORDER_COUNT DESC;
```

---

## Scenario 6: Incremental with JOINs

```sql
CREATE OR REPLACE TABLE DT_REFRESH_DB.RAW.CUSTOMERS (
    CUSTOMER_ID NUMBER, CUSTOMER_NAME VARCHAR(100), SEGMENT VARCHAR(20)
);

INSERT INTO DT_REFRESH_DB.RAW.CUSTOMERS VALUES
    (1, 'Rohit Sharma', 'Premium'), (2, 'Priya Patel', 'Standard'),
    (3, 'James Wilson', 'Premium'), (4, 'Emily Brown', 'Standard'),
    (5, 'Amit Kumar', 'Enterprise'), (6, 'Sarah Johnson', 'Premium'),
    (9, 'Alex Taylor', 'Standard'), (11, 'Mike Chen', 'Enterprise'),
    (12, 'Lisa Wang', 'Standard'), (13, 'Tom Harris', 'Premium');

CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_JOIN_INCREMENTAL
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            o.ORDER_ID, c.CUSTOMER_NAME, c.SEGMENT,
            o.PRODUCT_NAME, o.QUANTITY * o.UNIT_PRICE AS TOTAL_AMOUNT,
            o.ORDER_STATUS, o.ORDER_DATE
        FROM DT_REFRESH_DB.RAW.ORDERS o
        INNER JOIN DT_REFRESH_DB.RAW.CUSTOMERS c
            ON o.CUSTOMER_ID = c.CUSTOMER_ID;

-- Insert a new order for existing customer
INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES (1, 'Docking Station', 1, 179.99, 'PENDING', CURRENT_TIMESTAMP());

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_JOIN_INCREMENTAL REFRESH;

-- New order should appear with customer name 'Rohit Sharma'
SELECT * FROM DT_REFRESH_DB.STAGING.DT_JOIN_INCREMENTAL
WHERE PRODUCT_NAME = 'Docking Station';
```

---

## Scenario 7: Incremental with Window Functions

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_WINDOW_INCREMENTAL
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            ORDER_ID, CUSTOMER_ID, PRODUCT_NAME,
            QUANTITY * UNIT_PRICE AS TOTAL_AMOUNT, ORDER_DATE,
            ROW_NUMBER() OVER (
                PARTITION BY CUSTOMER_ID ORDER BY ORDER_DATE DESC
            ) AS RECENCY_RANK,
            SUM(QUANTITY * UNIT_PRICE) OVER (
                PARTITION BY CUSTOMER_ID ORDER BY ORDER_DATE
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS CUMULATIVE_SPEND
        FROM DT_REFRESH_DB.RAW.ORDERS;

-- Add another order for customer 1
INSERT INTO DT_REFRESH_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES (1, 'Thunderbolt Cable', 2, 49.99, 'PENDING', CURRENT_TIMESTAMP());

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_WINDOW_INCREMENTAL REFRESH;

-- Customer 1's rankings and cumulative spend should be recalculated
SELECT * FROM DT_REFRESH_DB.STAGING.DT_WINDOW_INCREMENTAL
WHERE CUSTOMER_ID = 1 ORDER BY ORDER_DATE;
```

---

## Scenario 8: Full Refresh with Unsupported Operators

```sql
CREATE OR REPLACE TABLE DT_REFRESH_DB.RAW.ORDER_TAGS (
    ORDER_ID NUMBER, TAGS VARIANT
);

INSERT INTO DT_REFRESH_DB.RAW.ORDER_TAGS SELECT 1, PARSE_JSON('["electronics", "premium", "warranty"]');
INSERT INTO DT_REFRESH_DB.RAW.ORDER_TAGS SELECT 2, PARSE_JSON('["electronics", "basic"]');
INSERT INTO DT_REFRESH_DB.RAW.ORDER_TAGS SELECT 3, PARSE_JSON('["peripherals"]');

CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FLATTEN_FULL
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = FULL
    AS
        SELECT t.ORDER_ID, f.VALUE::VARCHAR AS TAG
        FROM DT_REFRESH_DB.RAW.ORDER_TAGS t,
        LATERAL FLATTEN(INPUT => t.TAGS) f;

SELECT * FROM DT_REFRESH_DB.STAGING.DT_FLATTEN_FULL ORDER BY ORDER_ID;

-- Add new tagged order
INSERT INTO DT_REFRESH_DB.RAW.ORDER_TAGS
SELECT 4, PARSE_JSON('["furniture", "office", "ergonomic"]');

ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FLATTEN_FULL REFRESH;

SELECT * FROM DT_REFRESH_DB.STAGING.DT_FLATTEN_FULL ORDER BY ORDER_ID;
```

---

## Scenario 9: Monitoring — Complete Refresh History Analysis

```sql
-- Full refresh history for all DTs with timing breakdown
SELECT
    NAME, REFRESH_ACTION, REFRESH_TRIGGER, STATE,
    STATISTICS:numInsertedRows::INT AS ROWS_INS,
    STATISTICS:numDeletedRows::INT AS ROWS_DEL,
    STATISTICS:numCopiedRows::INT AS ROWS_COPIED,
    STATISTICS:numAddedPartitions::INT AS PARTS_ADDED,
    STATISTICS:numRemovedPartitions::INT AS PARTS_REMOVED,
    STATISTICS:queuedTimeMs::INT AS QUEUE_MS,
    STATISTICS:compilationTimeMs::INT AS COMPILE_MS,
    STATISTICS:executionTimeMs::INT AS EXEC_MS,
    REFRESH_START_TIME, REFRESH_END_TIME,
    DATEDIFF('SECOND', REFRESH_START_TIME, REFRESH_END_TIME) AS DURATION_SEC
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME_PREFIX => 'DT_REFRESH_DB.STAGING'
))
WHERE STATE = 'SUCCEEDED'
ORDER BY REFRESH_START_TIME DESC LIMIT 30;

-- Summary: average refresh time per mode
SELECT
    NAME, REFRESH_ACTION AS MODE_USED, COUNT(*) AS REFRESH_COUNT,
    AVG(STATISTICS:executionTimeMs::INT) AS AVG_EXEC_MS,
    MAX(STATISTICS:executionTimeMs::INT) AS MAX_EXEC_MS,
    AVG(STATISTICS:numInsertedRows::INT) AS AVG_ROWS_INS
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME_PREFIX => 'DT_REFRESH_DB.STAGING'
))
WHERE STATE = 'SUCCEEDED' AND REFRESH_ACTION IN ('INCREMENTAL', 'FULL')
GROUP BY NAME, REFRESH_ACTION
ORDER BY NAME, REFRESH_ACTION;
```

---

## Scenario 10: Switching Between Modes

You **CANNOT** alter the refresh mode. You must **recreate** the dynamic table.

```sql
-- Check current mode
SHOW DYNAMIC TABLES LIKE 'DT_INCREMENTAL' IN SCHEMA DT_REFRESH_DB.STAGING;

-- To switch to FULL, you must CREATE OR REPLACE
CREATE OR REPLACE DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = FULL
    AS
        SELECT ORDER_ID, CUSTOMER_ID, PRODUCT_NAME, QUANTITY, UNIT_PRICE,
               QUANTITY * UNIT_PRICE AS TOTAL_AMOUNT, ORDER_STATUS, ORDER_DATE
        FROM DT_REFRESH_DB.RAW.ORDERS;

-- Verify mode changed
SHOW DYNAMIC TABLES LIKE 'DT_INCREMENTAL' IN SCHEMA DT_REFRESH_DB.STAGING;
-- refresh_mode = FULL now
```

---

## Summary: Key Takeaways

| Observation | What You Should Remember |
|------------|------------------------|
| 1 row INSERT | INCREMENTAL processes 1 row; FULL rebuilds entire table |
| Bulk UPDATE (50%) | INCREMENTAL processes changed rows; FULL rebuilds everything |
| No changes | INCREMENTAL = NO_DATA (skips!); FULL may still rebuild |
| TRUNCATE + RELOAD | Both modes handle it; FULL is more natural for this pattern |
| JOINs | Both support JOINs; INCREMENTAL only processes delta |
| Window Functions | Both support them; INCREMENTAL recalculates affected partitions |
| Aggregations | Both support GROUP BY; INCREMENTAL updates affected groups |
| Cannot ALTER mode | Must CREATE OR REPLACE to change refresh mode |
| AUTO | Snowflake decides ONCE at creation; avoid in production |
| Cost at scale | INCREMENTAL saves massive compute on large tables |

---

## Cleanup

```sql
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_INCREMENTAL SUSPEND;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FULL SUSPEND;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AUTO SUSPEND;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AUTO_COMPLEX SUSPEND;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_AGG_INCREMENTAL SUSPEND;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_JOIN_INCREMENTAL SUSPEND;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_WINDOW_INCREMENTAL SUSPEND;
ALTER DYNAMIC TABLE DT_REFRESH_DB.STAGING.DT_FLATTEN_FULL SUSPEND;

-- Or drop everything when done:
-- DROP DATABASE DT_REFRESH_DB;
```
