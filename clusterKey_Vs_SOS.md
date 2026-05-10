# Clustering Key vs Search Optimization Service — Complete Guide

When to Use Which, Side-by-Side Comparison with Examples

---

## Section 1: Overview — What Each Does

### Clustering Key

- Physically **SORTS and ORGANIZES** data in micro-partitions by chosen columns
- Improves **RANGE-based queries** (`>`, `<`, `BETWEEN`, date ranges)
- Snowflake's Automatic Clustering maintains it in the background
- **Best for:** Large tables with range scans, date-based queries, GROUP BY

### Search Optimization Service (SOS)

- Builds a behind-the-scenes **ACCESS PATH** (search structure) for specific columns
- Improves **POINT LOOKUP queries** (`=`, `IN`, `LIKE`, `CONTAINS`, etc.)
- Requires **Enterprise Edition or higher**
- **Best for:** Finding a needle in a haystack — specific value lookups

### Analogy

| Feature | Analogy |
|---------|---------|
| Clustering Key | Organizing a library by genre/author (easy to find a RANGE of books) |
| Search Optimization | Building an INDEX at the back of each book (find EXACT page instantly) |

---

## Section 2: When to Use Clustering Key

### USE Clustering Key When:

1. Table is **VERY LARGE** (multiple TBs of data)
2. Queries filter on **DATE/TIME ranges**
   - `WHERE order_date BETWEEN '2025-01-01' AND '2025-06-30'`
3. Queries use **range predicates** (`>`, `<`, `>=`, `<=`, `BETWEEN`)
4. Queries **GROUP BY** or **ORDER BY** specific columns frequently
5. Table is queried frequently but updated **INFREQUENTLY**
6. Pruning is poor (most partitions scanned for filtered queries)

### DO NOT Use Clustering Key When:

- Table is small (< 1 TB)
- Table has heavy, frequent DML (high reclustering cost)
- Queries are point lookups (`=` single value)
- You'd need more than 3-4 columns in the key

### Column Selection Rules

- Max **3-4 columns** per key
- Order: **LOW cardinality → HIGH cardinality**
- Prefer columns used in WHERE and JOIN clauses
- For high cardinality columns, use expressions:

```sql
CLUSTER BY (TO_DATE(timestamp_col))    -- not the raw timestamp
CLUSTER BY (TRUNC(amount, -3))         -- reduce cardinality
```

---

## Section 3: When to Use Search Optimization Service

### USE Search Optimization When:

1. Queries do **POINT LOOKUPS** (`=` exact value, `IN` list)
   - `WHERE customer_id = 12345`
   - `WHERE email IN ('a@b.com', 'c@d.com')`
2. Queries search for **SUBSTRINGS** (`LIKE`, `CONTAINS`, `STARTSWITH`)
   - `WHERE name LIKE '%Smith%'`
   - `WHERE log_message CONTAINS 'ERROR'`
3. Queries filter on **SEMI-STRUCTURED data** (VARIANT, OBJECT, ARRAY)
   - `WHERE payload:user.email = 'john@example.com'`
4. Queries use **GEOGRAPHY functions** (GEO search)
5. Table is large but you need to find **SPECIFIC rows** quickly
6. Clustering alone doesn't help because queries aren't range-based

### DO NOT Use Search Optimization When:

- Queries are range-based (use clustering instead)
- Table is small (overhead isn't justified)
- Full table scans are acceptable for your workload
- Budget is tight (SOS has storage + serverless compute costs)

> **REQUIRES: Enterprise Edition or higher!**

---

## Section 4: Side-by-Side Comparison

| Feature | Clustering Key | Search Optimization |
|---------|---------------|-------------------|
| What it does | Sorts data physically | Builds search index |
| Best for | Range queries (BETWEEN, >, <) | Point lookups (=, IN, LIKE, CONTAINS) |
| Query patterns | Date ranges, ranges | Exact match, substring |
| Works on | Regular columns | Regular + VARIANT + OBJECT + ARRAY + GEO |
| Edition required | Standard+ | Enterprise+ |
| Cost type | Serverless compute | Serverless compute + storage for access paths |
| Maintenance | Automatic Clustering | Automatic (background) |
| Max columns | 3-4 recommended | As many as needed |
| Table size requirement | Multi-TB recommended | Any large table |
| Can use together? | **YES — they complement each other!** | **YES — they complement each other!** |

---

## Section 5: Practical Examples — Setup

```sql
CREATE OR REPLACE DATABASE OPTIMIZATION_DEMO;
USE DATABASE OPTIMIZATION_DEMO;
USE SCHEMA PUBLIC;

CREATE OR REPLACE TABLE EVENTS (
    EVENT_ID        INT,
    USER_ID         INT,
    EVENT_TYPE      VARCHAR(50),
    EVENT_DATE      TIMESTAMP,
    REGION          VARCHAR(20),
    DEVICE          VARCHAR(30),
    SESSION_ID      VARCHAR(100),
    PAYLOAD         VARIANT
);

INSERT INTO EVENTS
SELECT 
    SEQ4()                                                      AS EVENT_ID,
    MOD(SEQ4(), 500000)                                         AS USER_ID,
    CASE MOD(SEQ4(), 6)
        WHEN 0 THEN 'PAGE_VIEW'
        WHEN 1 THEN 'CLICK'
        WHEN 2 THEN 'PURCHASE'
        WHEN 3 THEN 'SIGNUP'
        WHEN 4 THEN 'LOGOUT'
        ELSE 'ERROR'
    END                                                         AS EVENT_TYPE,
    DATEADD(SECOND, -SEQ4(), CURRENT_TIMESTAMP())               AS EVENT_DATE,
    CASE MOD(SEQ4(), 4)
        WHEN 0 THEN 'US-EAST'
        WHEN 1 THEN 'US-WEST'
        WHEN 2 THEN 'EU-WEST'
        ELSE 'APAC'
    END                                                         AS REGION,
    CASE MOD(SEQ4(), 3)
        WHEN 0 THEN 'MOBILE'
        WHEN 1 THEN 'DESKTOP'
        ELSE 'TABLET'
    END                                                         AS DEVICE,
    UUID_STRING()                                               AS SESSION_ID,
    PARSE_JSON('{"browser":"Chrome","os":"Windows","version":"' 
        || SEQ4()::VARCHAR || '"}')                             AS PAYLOAD
FROM TABLE(GENERATOR(ROWCOUNT => 5000000));
```

---

## Section 6: Example — Clustering Key in Action

### Check Current Clustering on EVENT_DATE

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('EVENTS', '(EVENT_DATE)');
```

### Query 1: Range Query WITHOUT Clustering Key

Run this and check Query Profile → TableScan → Partitions scanned vs total:

```sql
SELECT EVENT_TYPE, COUNT(*) AS EVENT_COUNT, SUM(USER_ID) AS TOTAL
FROM EVENTS
WHERE EVENT_DATE BETWEEN '2026-04-01' AND '2026-04-15'
GROUP BY EVENT_TYPE;
```

### Add Clustering Key on EVENT_DATE

```sql
ALTER TABLE EVENTS CLUSTER BY (TO_DATE(EVENT_DATE));
```

> Note: Automatic Clustering will reorganize data in the background. Over time, partition pruning will dramatically improve.

### Check Clustering Health After Setting the Key

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('EVENTS', '(TO_DATE(EVENT_DATE))');
SELECT SYSTEM$CLUSTERING_DEPTH('EVENTS', '(TO_DATE(EVENT_DATE))');
```

### Query 2: Same Range Query — After Clustering, Pruning Improves

```sql
SELECT EVENT_TYPE, COUNT(*) AS EVENT_COUNT
FROM EVENTS
WHERE EVENT_DATE BETWEEN '2026-04-01' AND '2026-04-15'
GROUP BY EVENT_TYPE;
```

> Compare Query Profile: Partitions scanned should be much lower!

### Multi-Column Clustering: Low Cardinality First → High Cardinality Second

```sql
ALTER TABLE EVENTS CLUSTER BY (REGION, TO_DATE(EVENT_DATE));
-- REGION has 4 values (low) → EVENT_DATE has many (high)
```

---

## Section 7: Example — Search Optimization in Action

### Point Lookup Without SOS (Scans Many/All Partitions)

```sql
SELECT * FROM EVENTS WHERE USER_ID = 42 LIMIT 10;
```

### Enable Search Optimization on Specific Columns

```sql
ALTER TABLE EVENTS ADD SEARCH OPTIMIZATION ON EQUALITY(USER_ID);
ALTER TABLE EVENTS ADD SEARCH OPTIMIZATION ON EQUALITY(SESSION_ID);
ALTER TABLE EVENTS ADD SEARCH OPTIMIZATION ON EQUALITY(EVENT_TYPE);
```

### Check Search Optimization Status

```sql
SHOW TABLES LIKE 'EVENTS';
-- Look at "search_optimization" and "search_optimization_progress" columns

DESCRIBE SEARCH OPTIMIZATION ON EVENTS;
```

### Point Lookup Queries (Now Optimized by SOS)

```sql
-- Query 1: Exact match on USER_ID
SELECT * FROM EVENTS WHERE USER_ID = 42 LIMIT 10;

-- Query 2: IN list lookup
SELECT * FROM EVENTS WHERE USER_ID IN (42, 100, 9999, 250000);

-- Query 3: Find specific session
SELECT * FROM EVENTS WHERE SESSION_ID = 'some-uuid-value';
```

### Substring Search: Enable for Text Columns

```sql
ALTER TABLE EVENTS ADD SEARCH OPTIMIZATION ON SUBSTRING(SESSION_ID);

-- Now LIKE queries are optimized too:
SELECT * FROM EVENTS WHERE SESSION_ID LIKE '%abc123%';
```

### Semi-Structured Data: Search Inside VARIANT Column

```sql
ALTER TABLE EVENTS ADD SEARCH OPTIMIZATION ON EQUALITY(PAYLOAD);

-- Query inside JSON:
SELECT * FROM EVENTS 
WHERE PAYLOAD:browser::VARCHAR = 'Chrome' 
  AND PAYLOAD:os::VARCHAR = 'Windows'
LIMIT 10;
```

---

## Section 8: Using Both Together — The Best Approach

You **CAN and SHOULD** use both together when your workload has:
- **Range queries** (dates, amounts) → Clustering Key
- **Point lookups** (IDs, emails, UUIDs) → Search Optimization

### Example Scenario: E-commerce ORDERS Table

| Query Pattern | Type | Solution |
|--------------|------|----------|
| "Get all orders from last month" | RANGE | Clustering Key on ORDER_DATE |
| "Find order #12345" | POINT | Search Optimization on ORDER_ID |
| "Find orders by customer email" | POINT | Search Optimization on EMAIL |
| "Search order notes for 'refund'" | SUBSTRING | Search Optimization on NOTES |

### Setup Combined Optimization

```sql
CREATE OR REPLACE TABLE ORDERS_DEMO (
    ORDER_ID        INT,
    CUSTOMER_EMAIL  VARCHAR(200),
    ORDER_DATE      DATE,
    AMOUNT          DECIMAL(12,2),
    STATUS          VARCHAR(20),
    NOTES           VARCHAR(500)
);

INSERT INTO ORDERS_DEMO
SELECT 
    SEQ4()                                                          AS ORDER_ID,
    'user' || MOD(SEQ4(), 100000) || '@example.com'                 AS CUSTOMER_EMAIL,
    DATEADD(DAY, -MOD(SEQ4(), 730), CURRENT_DATE())                 AS ORDER_DATE,
    ROUND(UNIFORM(10, 5000, RANDOM())::DECIMAL(12,2), 2)            AS AMOUNT,
    CASE MOD(SEQ4(), 4)
        WHEN 0 THEN 'SHIPPED'
        WHEN 1 THEN 'DELIVERED'
        WHEN 2 THEN 'PENDING'
        ELSE 'RETURNED'
    END                                                             AS STATUS,
    CASE MOD(SEQ4(), 5)
        WHEN 0 THEN 'Customer requested refund'
        WHEN 1 THEN 'Express shipping applied'
        WHEN 2 THEN 'Gift wrapping included'
        WHEN 3 THEN 'Damaged in transit - replacement sent'
        ELSE 'Standard delivery'
    END                                                             AS NOTES
FROM TABLE(GENERATOR(ROWCOUNT => 5000000));

-- CLUSTERING KEY: For date range queries
ALTER TABLE ORDERS_DEMO CLUSTER BY (ORDER_DATE);

-- SEARCH OPTIMIZATION: For point lookups and substring searches
ALTER TABLE ORDERS_DEMO ADD SEARCH OPTIMIZATION ON EQUALITY(ORDER_ID);
ALTER TABLE ORDERS_DEMO ADD SEARCH OPTIMIZATION ON EQUALITY(CUSTOMER_EMAIL);
ALTER TABLE ORDERS_DEMO ADD SEARCH OPTIMIZATION ON SUBSTRING(NOTES);
```

### All These Query Types Are Now Fast

```sql
-- Range query → Uses clustering
SELECT STATUS, COUNT(*), SUM(AMOUNT) 
FROM ORDERS_DEMO 
WHERE ORDER_DATE BETWEEN '2026-01-01' AND '2026-03-31'
GROUP BY STATUS;

-- Point lookup → Uses search optimization
SELECT * FROM ORDERS_DEMO WHERE ORDER_ID = 999999;

-- Email lookup → Uses search optimization
SELECT * FROM ORDERS_DEMO WHERE CUSTOMER_EMAIL = 'user42@example.com';

-- Substring search → Uses search optimization
SELECT * FROM ORDERS_DEMO WHERE NOTES LIKE '%refund%';
```

---

## Section 9: Monitoring Costs & Status

### Check Clustering Health

```sql
SELECT SYSTEM$CLUSTERING_INFORMATION('ORDERS_DEMO', '(ORDER_DATE)');
```

### Check Search Optimization Status and Progress

```sql
DESCRIBE SEARCH OPTIMIZATION ON ORDERS_DEMO;
```

### Check Search Optimization Cost (Serverless Credit Usage)

```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.SEARCH_OPTIMIZATION_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END   => CURRENT_TIMESTAMP(),
    TABLE_NAME       => 'ORDERS_DEMO'
));
```

### Check Automatic Clustering Cost

```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.AUTOMATIC_CLUSTERING_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END   => CURRENT_TIMESTAMP(),
    TABLE_NAME       => 'ORDERS_DEMO'
));
```

---

## Section 10: Managing Search Optimization

### Remove Search Optimization from a Specific Column

```sql
ALTER TABLE ORDERS_DEMO DROP SEARCH OPTIMIZATION ON EQUALITY(ORDER_ID);
```

### Remove ALL Search Optimization from a Table

```sql
ALTER TABLE ORDERS_DEMO DROP SEARCH OPTIMIZATION;
```

### Remove Clustering Key

```sql
ALTER TABLE ORDERS_DEMO DROP CLUSTERING KEY;
```

---

## Section 11: Decision Flowchart

```
YOUR QUERY IS SLOW --> What kind of filter are you using?

+-------------------------------------------------------------+
| Q: What type of query?                                      |
|                                                             |
| RANGE (BETWEEN, >, <, date range)                           |
|   --> Table > 1 TB?                                         |
|       YES --> USE CLUSTERING KEY                            |
|       NO  --> Check pruning first, may not need clustering  |
|                                                             |
| POINT LOOKUP (=, IN)                                        |
|   --> Enterprise Edition?                                   |
|       YES --> USE SEARCH OPTIMIZATION                       |
|       NO  --> Use clustering on that column as workaround   |
|                                                             |
| SUBSTRING (LIKE, CONTAINS, STARTSWITH)                      |
|   --> Enterprise Edition?                                   |
|       YES --> USE SEARCH OPTIMIZATION ON SUBSTRING          |
|       NO  --> No good alternative, consider upgrading       |
|                                                             |
| SEMI-STRUCTURED (VARIANT:path = value)                      |
|   --> Enterprise Edition?                                   |
|       YES --> USE SEARCH OPTIMIZATION ON EQUALITY/SUBSTRING |
|       NO  --> Flatten data into regular columns + cluster   |
|                                                             |
| MIXED (range + point lookups)                               |
|   --> USE BOTH! They work together perfectly.               |
+-------------------------------------------------------------+
```

---

## Cleanup

```sql
DROP TABLE EVENTS;
DROP TABLE ORDERS_DEMO;
DROP DATABASE OPTIMIZATION_DEMO;
```
