# Snowflake Dynamic Tables: Complete Guide (Scratch to Advanced)

**Features, Advantages, Disadvantages, Practical Code & Interview Preparation**

---

## Table of Contents

1. [What Are Dynamic Tables?](#1-what-are-dynamic-tables)
2. [Why Dynamic Tables? The Problem They Solve](#2-why-dynamic-tables-the-problem-they-solve)
3. [Key Features](#3-key-features)
4. [Advantages](#4-advantages)
5. [Disadvantages](#5-disadvantages)
6. [Dynamic Tables vs Streams+Tasks vs Materialized Views](#6-dynamic-tables-vs-streamstasks-vs-materialized-views)
7. [Setup: Create Source Tables](#7-setup-create-source-tables)
8. [Basic Dynamic Table Creation](#8-basic-dynamic-table-creation)
9. [Target Lag Explained](#9-target-lag-explained)
10. [Refresh Modes: Incremental vs Full vs Auto](#10-refresh-modes-incremental-vs-full-vs-auto)
11. [Chaining Dynamic Tables (Multi-Layer Pipeline)](#11-chaining-dynamic-tables-multi-layer-pipeline)
12. [Dynamic Tables with Joins](#12-dynamic-tables-with-joins)
13. [Dynamic Tables with Window Functions](#13-dynamic-tables-with-window-functions)
14. [Dynamic Tables with Aggregations](#14-dynamic-tables-with-aggregations)
15. [Controller Dynamic Table Pattern](#15-controller-dynamic-table-pattern)
16. [Transient Dynamic Tables](#16-transient-dynamic-tables)
17. [Managing Dynamic Tables (ALTER, SUSPEND, RESUME, DROP)](#17-managing-dynamic-tables)
18. [Monitoring & Debugging](#18-monitoring--debugging)
19. [Dynamic Tables with Cortex AI Functions](#19-dynamic-tables-with-cortex-ai-functions)
20. [Limitations](#20-limitations)
21. [Best Practices](#21-best-practices)
22. [Interview Questions: Basic](#22-interview-questions-basic)
23. [Interview Questions: Intermediate](#23-interview-questions-intermediate)
24. [Interview Questions: Advanced](#24-interview-questions-advanced)
25. [Interview Questions: Scenario-Based](#25-interview-questions-scenario-based)

---

## 1. What Are Dynamic Tables?

Dynamic tables are tables that **automatically refresh** based on a defined SQL query and a **target freshness** (called target lag). You define WHAT result you want using a SELECT statement, and Snowflake handles HOW and WHEN to refresh the data.

**In simple terms:** You write a SELECT query. Snowflake materializes the results into a table and keeps it updated automatically.

```
Traditional Approach:
  Source Table → Stream → Task (with MERGE logic) → Target Table
  (You manage everything)

Dynamic Table Approach:
  Source Table → Dynamic Table (just a SELECT query)
  (Snowflake manages everything)
```

---

## 2. Why Dynamic Tables? The Problem They Solve

### Without Dynamic Tables (Streams + Tasks):
1. Create a stream on the source table
2. Create a target table
3. Write a task with complex MERGE/INSERT logic
4. Handle error cases, retries, scheduling
5. Manage dependencies between multiple tasks
6. Monitor each component separately

### With Dynamic Tables:
1. Write a SELECT query
2. Set target lag
3. Done. Snowflake handles the rest.

---

## 3. Key Features

| Feature | Description |
|---------|-------------|
| **Declarative** | Define WHAT you want, not HOW to get it |
| **Auto-Refresh** | Snowflake automatically refreshes based on target lag |
| **Incremental Processing** | Only processes changed data when possible |
| **Chaining** | Dynamic tables can read from other dynamic tables |
| **Target Lag** | Control data freshness (e.g., "1 minute", "1 hour", or DOWNSTREAM) |
| **Snapshot Isolation** | Consistent data across the pipeline during refresh |
| **Change Tracking** | Automatically enabled on base tables |
| **Cortex AI Support** | Can use LLM/AI functions in the SELECT clause |
| **Immutability Constraints** | Mark historical data as static to skip during refresh |
| **Primary Keys** | System-derived keys enable incremental refresh downstream |
| **Initialization Control** | ON_CREATE (immediate) or ON_SCHEDULE (delayed) |

---

## 4. Advantages

| Advantage | Explanation |
|-----------|-------------|
| **Simplicity** | No streams, no tasks, no MERGE logic. Just a SELECT. |
| **Less Code** | 5 lines vs 50+ lines for streams+tasks approach |
| **Auto-Orchestration** | Snowflake manages refresh scheduling and dependency ordering |
| **Incremental Refresh** | Processes only changed data, reducing compute costs |
| **Declarative Pipeline** | Define the end state; Snowflake figures out the transformation steps |
| **Chaining** | Build multi-layer pipelines (bronze → silver → gold) |
| **Snapshot Isolation** | All tables in a chain refresh consistently |
| **Easy Debugging** | View refresh history, lag, and errors in Snowsight |
| **Batch-to-Streaming** | Change target lag from hours to minutes with a single ALTER command |
| **No Manual Scheduling** | No CRON expressions, no task graphs to manage |

---

## 5. Disadvantages

| Disadvantage | Explanation |
|-------------|-------------|
| **No Procedural Logic** | Cannot call stored procedures, no IF/ELSE, no MERGE |
| **No External Functions** | External functions not supported in the query |
| **No Temporary DTs** | Cannot create temporary dynamic tables |
| **Query Restrictions** | PIVOT, UNPIVOT, SAMPLE, sequences, recursive CTEs not supported in incremental mode |
| **Staleness Risk** | Can become stale if not refreshed within MAX_DATA_EXTENSION_TIME_IN_DAYS |
| **No Fine-Grained Scheduling** | Cannot specify exact refresh times (e.g., "every day at 2 AM") without using a task |
| **Limited DML** | Cannot INSERT/UPDATE/DELETE/TRUNCATE dynamic table data directly |
| **Storage Cost** | Materialized data consumes storage |
| **Compute Cost** | Refresh process uses warehouse credits |
| **50K Limit** | Maximum 50,000 dynamic tables per account |
| **No Shared DT Consumption** | Cannot query shared dynamic tables or shared secure views referencing upstream DTs |

---

## 6. Dynamic Tables vs Streams+Tasks vs Materialized Views

| Feature | Dynamic Tables | Streams + Tasks | Materialized Views |
|---------|---------------|-----------------|-------------------|
| **Approach** | Declarative (SELECT) | Imperative (procedural code) | Declarative (SELECT) |
| **Scheduling** | Auto (target lag) | Manual (CRON/interval) | Auto (always current) |
| **Joins** | Supported | Supported | NOT supported |
| **Complex Queries** | Supported | Supported | Single table only |
| **Stored Procedures** | NOT supported | Supported | NOT supported |
| **Data Freshness** | Configurable lag | Depends on schedule | Always current |
| **Orchestration** | Automatic | Manual task graphs | Automatic |
| **Cost Control** | Target lag + warehouse | Task schedule + warehouse | Automatic (less control) |
| **Use Case** | Data pipelines | Complex ETL with logic | Query acceleration |
| **Incremental** | Yes (when supported) | Yes (via streams) | Yes (automatic) |
| **Multi-Table** | Yes (chaining) | Yes (task dependencies) | No |

---

## 7. Setup: Create Source Tables

```sql
-- Create database and schemas
CREATE DATABASE IF NOT EXISTS DT_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS DT_DEMO_DB.RAW;
CREATE SCHEMA IF NOT EXISTS DT_DEMO_DB.STAGING;
CREATE SCHEMA IF NOT EXISTS DT_DEMO_DB.ANALYTICS;

-- Create warehouse for dynamic table refreshes
CREATE WAREHOUSE IF NOT EXISTS DT_WH
    WAREHOUSE_SIZE = 'XSMALL'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE;

-- Raw orders table
CREATE OR REPLACE TABLE DT_DEMO_DB.RAW.ORDERS (
    ORDER_ID        NUMBER AUTOINCREMENT,
    CUSTOMER_ID     NUMBER,
    PRODUCT_ID      NUMBER,
    QUANTITY        NUMBER,
    UNIT_PRICE      NUMBER(10,2),
    ORDER_STATUS    VARCHAR(20),
    ORDER_DATE      TIMESTAMP_NTZ,
    UPDATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Raw customers table
CREATE OR REPLACE TABLE DT_DEMO_DB.RAW.CUSTOMERS (
    CUSTOMER_ID     NUMBER,
    FIRST_NAME      VARCHAR(50),
    LAST_NAME       VARCHAR(50),
    EMAIL           VARCHAR(100),
    COUNTRY         VARCHAR(50),
    SEGMENT         VARCHAR(20),
    CREATED_AT      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Raw products table
CREATE OR REPLACE TABLE DT_DEMO_DB.RAW.PRODUCTS (
    PRODUCT_ID      NUMBER,
    PRODUCT_NAME    VARCHAR(100),
    CATEGORY        VARCHAR(50),
    BRAND           VARCHAR(50),
    COST_PRICE      NUMBER(10,2),
    LIST_PRICE      NUMBER(10,2)
);

-- Insert sample data
INSERT INTO DT_DEMO_DB.RAW.CUSTOMERS VALUES
    (1, 'Rohit',   'Sharma',   'rohit@example.com',    'India',          'Premium',  '2024-01-15'),
    (2, 'Priya',   'Patel',    'priya@example.com',    'India',          'Standard', '2024-02-20'),
    (3, 'James',   'Wilson',   'james@example.com',    'United States',  'Premium',  '2024-03-10'),
    (4, 'Emily',   'Brown',    'emily@example.com',    'United Kingdom', 'Standard', '2024-04-05'),
    (5, 'Amit',    'Kumar',    'amit@example.com',     'India',          'Premium',  '2024-05-15'),
    (6, 'Sarah',   'Johnson',  'sarah@example.com',    'United States',  'Enterprise','2024-06-01'),
    (7, 'Michael', 'Davis',    'michael@example.com',  'Canada',         'Standard', '2024-07-20'),
    (8, 'Ananya',  'Reddy',    'ananya@example.com',   'India',          'Enterprise','2024-08-10');

INSERT INTO DT_DEMO_DB.RAW.PRODUCTS VALUES
    (101, 'Laptop Pro 15',       'Electronics',  'TechCorp',  600.00,  999.99),
    (102, 'Wireless Mouse',      'Electronics',  'TechCorp',  15.00,   29.99),
    (103, 'Office Chair',        'Furniture',    'ComfortCo', 120.00,  249.99),
    (104, 'Standing Desk',       'Furniture',    'ComfortCo', 280.00,  549.99),
    (105, 'Headphones NC',       'Electronics',  'AudioMax',  80.00,   199.99),
    (106, 'USB-C Hub',           'Accessories',  'TechCorp',  25.00,   59.99),
    (107, 'Mechanical Keyboard', 'Accessories',  'KeyMaster', 40.00,   89.99),
    (108, 'Monitor 27"',         'Electronics',  'ViewPro',   200.00,  399.99);

INSERT INTO DT_DEMO_DB.RAW.ORDERS
    (CUSTOMER_ID, PRODUCT_ID, QUANTITY, UNIT_PRICE, ORDER_STATUS, ORDER_DATE)
VALUES
    (1, 101, 1, 999.99,  'COMPLETED', '2025-01-15 10:30:00'),
    (2, 102, 2, 29.99,   'COMPLETED', '2025-01-20 14:15:00'),
    (3, 103, 1, 249.99,  'SHIPPED',   '2025-02-01 09:00:00'),
    (1, 105, 1, 199.99,  'COMPLETED', '2025-02-10 16:45:00'),
    (4, 104, 1, 549.99,  'PENDING',   '2025-02-15 11:30:00'),
    (5, 101, 2, 999.99,  'COMPLETED', '2025-03-01 08:00:00'),
    (6, 108, 3, 399.99,  'SHIPPED',   '2025-03-10 13:20:00'),
    (2, 107, 1, 89.99,   'COMPLETED', '2025-03-15 15:00:00'),
    (7, 106, 4, 59.99,   'COMPLETED', '2025-04-01 10:00:00'),
    (8, 101, 1, 999.99,  'PENDING',   '2025-04-10 12:00:00'),
    (3, 102, 3, 29.99,   'COMPLETED', '2025-04-15 14:30:00'),
    (5, 103, 2, 249.99,  'SHIPPED',   '2025-05-01 09:15:00'),
    (1, 107, 1, 89.99,   'COMPLETED', '2025-05-10 16:00:00'),
    (6, 105, 2, 199.99,  'COMPLETED', '2025-05-20 11:45:00'),
    (4, 108, 1, 399.99,  'COMPLETED', '2025-06-01 08:30:00');
```

---

## 8. Basic Dynamic Table Creation

### Syntax

```sql
CREATE [ OR REPLACE ] [ TRANSIENT ] DYNAMIC TABLE <name>
    TARGET_LAG = { '<num> { seconds | minutes | hours | days }' | DOWNSTREAM }
    WAREHOUSE = <warehouse_name>
    [ REFRESH_MODE = { AUTO | FULL | INCREMENTAL } ]
    [ INITIALIZE = { ON_CREATE | ON_SCHEDULE } ]
    AS
        <SELECT_query>;
```

### Example 1: Simple Staging Dynamic Table

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS
    TARGET_LAG = '5 minutes'
    WAREHOUSE = DT_WH
    REFRESH_MODE = AUTO
    INITIALIZE = ON_CREATE
    AS
        SELECT
            ORDER_ID,
            CUSTOMER_ID,
            PRODUCT_ID,
            QUANTITY,
            UNIT_PRICE,
            QUANTITY * UNIT_PRICE AS TOTAL_AMOUNT,
            ORDER_STATUS,
            ORDER_DATE,
            UPDATED_AT
        FROM DT_DEMO_DB.RAW.ORDERS;
```

### Example 2: Staging Customers

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_CUSTOMERS
    TARGET_LAG = '10 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT
            CUSTOMER_ID,
            FIRST_NAME || ' ' || LAST_NAME AS FULL_NAME,
            EMAIL,
            COUNTRY,
            SEGMENT,
            CREATED_AT
        FROM DT_DEMO_DB.RAW.CUSTOMERS;
```

### Example 3: Staging Products

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_PRODUCTS
    TARGET_LAG = '1 hour'
    WAREHOUSE = DT_WH
    AS
        SELECT
            PRODUCT_ID,
            PRODUCT_NAME,
            CATEGORY,
            BRAND,
            COST_PRICE,
            LIST_PRICE,
            LIST_PRICE - COST_PRICE AS PROFIT_MARGIN,
            ROUND((LIST_PRICE - COST_PRICE) / COST_PRICE * 100, 2) AS MARGIN_PERCENT
        FROM DT_DEMO_DB.RAW.PRODUCTS;
```

---

## 9. Target Lag Explained

Target lag controls how fresh your data is. It is the **maximum allowed delay** between base table updates and dynamic table content.

### Types of Target Lag

| Type | Syntax | Behavior |
|------|--------|----------|
| **Time-Based** | `TARGET_LAG = '5 minutes'` | Refresh to keep data within 5 min of base table |
| **Downstream** | `TARGET_LAG = DOWNSTREAM` | Only refresh when a downstream DT needs it |

### How Scheduling Works

- Snowflake schedules refreshes **slightly earlier** than the target lag
- If target lag = 5 min, refresh may happen every ~4 min to allow time for processing
- Target lag is a **target, not a guarantee** — actual lag may exceed target under heavy load

### Target Lag in Chains

```
DT1 (TARGET_LAG = DOWNSTREAM)  →  DT2 (TARGET_LAG = DOWNSTREAM)  →  DT3 (TARGET_LAG = '10 minutes')
```

DT3 drives the schedule. DT1 and DT2 refresh only when DT3 needs them.

### Changing Target Lag

```sql
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS SET TARGET_LAG = '1 hour';

ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS SET TARGET_LAG = DOWNSTREAM;
```

---

## 10. Refresh Modes: Incremental vs Full vs Auto

| Mode | How It Works | Best For |
|------|-------------|----------|
| **INCREMENTAL** | Analyzes changes since last refresh, merges only the delta | Small % of data changes (<5%), supported operators |
| **FULL** | Re-runs the entire SELECT query, replaces all data | Large % changes, unsupported operators, poor locality |
| **AUTO** | Snowflake picks the best mode at creation time | Development/prototyping (avoid in production) |

### When Incremental Refresh Works Best

- Less than 5% of data changes between refreshes
- Source tables clustered by join/group keys
- Query uses supported operators (joins, group by, window functions, etc.)

### When Full Refresh Is Better

- Large percentage of data changes
- Query uses unsupported operators (PIVOT, subqueries outside FROM, etc.)
- Data lacks locality (keys spread across many micro-partitions)

### Specifying Refresh Mode

```sql
-- Explicit incremental
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS_INC
    TARGET_LAG = '5 minutes'
    WAREHOUSE = DT_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT * FROM DT_DEMO_DB.RAW.ORDERS;

-- Explicit full
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS_FULL
    TARGET_LAG = '5 minutes'
    WAREHOUSE = DT_WH
    REFRESH_MODE = FULL
    AS
        SELECT * FROM DT_DEMO_DB.RAW.ORDERS;
```

---

## 11. Chaining Dynamic Tables (Multi-Layer Pipeline)

Build a bronze → silver → gold pipeline entirely with dynamic tables.

```
RAW Tables (Bronze)
    ↓
STAGING Dynamic Tables (Silver) — clean, type, rename
    ↓
ANALYTICS Dynamic Tables (Gold) — join, aggregate, business logic
```

### Gold Layer: Order Summary (reads from staging DTs)

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.ORDER_SUMMARY
    TARGET_LAG = '15 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT
            o.ORDER_ID,
            c.FULL_NAME AS CUSTOMER_NAME,
            c.COUNTRY,
            c.SEGMENT AS CUSTOMER_SEGMENT,
            p.PRODUCT_NAME,
            p.CATEGORY AS PRODUCT_CATEGORY,
            p.BRAND,
            o.QUANTITY,
            o.UNIT_PRICE,
            o.TOTAL_AMOUNT,
            p.COST_PRICE * o.QUANTITY AS TOTAL_COST,
            o.TOTAL_AMOUNT - (p.COST_PRICE * o.QUANTITY) AS PROFIT,
            o.ORDER_STATUS,
            o.ORDER_DATE
        FROM DT_DEMO_DB.STAGING.STG_ORDERS o
        JOIN DT_DEMO_DB.STAGING.STG_CUSTOMERS c ON o.CUSTOMER_ID = c.CUSTOMER_ID
        JOIN DT_DEMO_DB.STAGING.STG_PRODUCTS p ON o.PRODUCT_ID = p.PRODUCT_ID;
```

---

## 12. Dynamic Tables with Joins

```sql
-- INNER JOIN (supported in both incremental and full)
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.CUSTOMER_ORDERS
    TARGET_LAG = '10 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT
            c.FULL_NAME,
            c.COUNTRY,
            COUNT(o.ORDER_ID) AS TOTAL_ORDERS,
            SUM(o.TOTAL_AMOUNT) AS TOTAL_SPEND,
            AVG(o.TOTAL_AMOUNT) AS AVG_ORDER_VALUE,
            MAX(o.ORDER_DATE) AS LAST_ORDER_DATE
        FROM DT_DEMO_DB.STAGING.STG_CUSTOMERS c
        INNER JOIN DT_DEMO_DB.STAGING.STG_ORDERS o
            ON c.CUSTOMER_ID = o.CUSTOMER_ID
        GROUP BY c.FULL_NAME, c.COUNTRY;

-- LEFT OUTER JOIN (supported with equality predicates)
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.ALL_CUSTOMERS_WITH_ORDERS
    TARGET_LAG = '10 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT
            c.FULL_NAME,
            c.SEGMENT,
            COALESCE(COUNT(o.ORDER_ID), 0) AS ORDER_COUNT,
            COALESCE(SUM(o.TOTAL_AMOUNT), 0) AS TOTAL_SPEND
        FROM DT_DEMO_DB.STAGING.STG_CUSTOMERS c
        LEFT JOIN DT_DEMO_DB.STAGING.STG_ORDERS o
            ON c.CUSTOMER_ID = o.CUSTOMER_ID
        GROUP BY c.FULL_NAME, c.SEGMENT;
```

---

## 13. Dynamic Tables with Window Functions

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.ORDER_RANKINGS
    TARGET_LAG = '15 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT
            o.ORDER_ID,
            c.FULL_NAME,
            p.PRODUCT_NAME,
            o.TOTAL_AMOUNT,
            o.ORDER_DATE,
            ROW_NUMBER() OVER (
                PARTITION BY o.CUSTOMER_ID
                ORDER BY o.ORDER_DATE DESC
            ) AS ORDER_RECENCY_RANK,
            SUM(o.TOTAL_AMOUNT) OVER (
                PARTITION BY o.CUSTOMER_ID
                ORDER BY o.ORDER_DATE
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
            ) AS CUMULATIVE_SPEND,
            FIRST_VALUE(o.TOTAL_AMOUNT) OVER (
                PARTITION BY o.CUSTOMER_ID
                ORDER BY o.ORDER_DATE
            ) AS FIRST_ORDER_AMOUNT,
            LAST_VALUE(o.TOTAL_AMOUNT) OVER (
                PARTITION BY o.CUSTOMER_ID
                ORDER BY o.ORDER_DATE
                ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
            ) AS LATEST_ORDER_AMOUNT
        FROM DT_DEMO_DB.STAGING.STG_ORDERS o
        JOIN DT_DEMO_DB.STAGING.STG_CUSTOMERS c ON o.CUSTOMER_ID = c.CUSTOMER_ID
        JOIN DT_DEMO_DB.STAGING.STG_PRODUCTS p ON o.PRODUCT_ID = p.PRODUCT_ID;
```

---

## 14. Dynamic Tables with Aggregations

```sql
-- Daily sales summary
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.DAILY_SALES
    TARGET_LAG = '30 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT
            DATE_TRUNC('DAY', o.ORDER_DATE)::DATE AS SALE_DATE,
            p.CATEGORY,
            COUNT(DISTINCT o.ORDER_ID) AS NUM_ORDERS,
            COUNT(DISTINCT o.CUSTOMER_ID) AS UNIQUE_CUSTOMERS,
            SUM(o.TOTAL_AMOUNT) AS TOTAL_REVENUE,
            SUM(o.TOTAL_AMOUNT - (p.COST_PRICE * o.QUANTITY)) AS TOTAL_PROFIT,
            AVG(o.TOTAL_AMOUNT) AS AVG_ORDER_VALUE,
            MAX(o.TOTAL_AMOUNT) AS MAX_ORDER_VALUE
        FROM DT_DEMO_DB.STAGING.STG_ORDERS o
        JOIN DT_DEMO_DB.STAGING.STG_PRODUCTS p ON o.PRODUCT_ID = p.PRODUCT_ID
        GROUP BY DATE_TRUNC('DAY', o.ORDER_DATE)::DATE, p.CATEGORY;

-- Customer segment analysis
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.SEGMENT_ANALYSIS
    TARGET_LAG = '1 hour'
    WAREHOUSE = DT_WH
    AS
        SELECT
            c.SEGMENT,
            c.COUNTRY,
            COUNT(DISTINCT c.CUSTOMER_ID) AS NUM_CUSTOMERS,
            COUNT(o.ORDER_ID) AS TOTAL_ORDERS,
            SUM(o.TOTAL_AMOUNT) AS TOTAL_REVENUE,
            ROUND(SUM(o.TOTAL_AMOUNT) / NULLIF(COUNT(DISTINCT c.CUSTOMER_ID), 0), 2) AS REVENUE_PER_CUSTOMER
        FROM DT_DEMO_DB.STAGING.STG_CUSTOMERS c
        LEFT JOIN DT_DEMO_DB.STAGING.STG_ORDERS o ON c.CUSTOMER_ID = o.CUSTOMER_ID
        GROUP BY c.SEGMENT, c.COUNTRY;
```

---

## 15. Controller Dynamic Table Pattern

When you have a complex graph with many dynamic tables and want to control the entire pipeline with a single command:

```sql
-- Set all DTs to DOWNSTREAM
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS SET TARGET_LAG = DOWNSTREAM;
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_CUSTOMERS SET TARGET_LAG = DOWNSTREAM;
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_PRODUCTS SET TARGET_LAG = DOWNSTREAM;

-- Create controller that reads from all leaf tables
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER
    TARGET_LAG = '30 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT 1 AS CTRL
        FROM DT_DEMO_DB.ANALYTICS.ORDER_SUMMARY,
             DT_DEMO_DB.ANALYTICS.DAILY_SALES,
             DT_DEMO_DB.ANALYTICS.SEGMENT_ANALYSIS
        LIMIT 0;

-- Now control entire pipeline with one command:
ALTER DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER SET TARGET_LAG = '1 hour';

-- Manual refresh of entire pipeline:
ALTER DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER REFRESH;
```

---

## 16. Transient Dynamic Tables

Transient DTs reduce storage costs by not retaining data beyond Time Travel.

```sql
CREATE OR REPLACE TRANSIENT DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.TEMP_METRICS
    TARGET_LAG = '15 minutes'
    WAREHOUSE = DT_WH
    AS
        SELECT
            PRODUCT_ID,
            COUNT(*) AS ORDER_COUNT,
            SUM(TOTAL_AMOUNT) AS REVENUE
        FROM DT_DEMO_DB.STAGING.STG_ORDERS
        GROUP BY PRODUCT_ID;
```

---

## 17. Managing Dynamic Tables

### SHOW Dynamic Tables

```sql
SHOW DYNAMIC TABLES IN SCHEMA DT_DEMO_DB.STAGING;

SHOW DYNAMIC TABLES LIKE '%ORDER%' IN DATABASE DT_DEMO_DB;
```

### DESCRIBE Dynamic Table

```sql
DESCRIBE DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS;
```

### SUSPEND and RESUME

```sql
-- Suspend (stop auto-refresh)
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS SUSPEND;

-- Resume (restart auto-refresh)
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS RESUME;
```

### Manual Refresh

```sql
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS REFRESH;
```

### Change Warehouse

```sql
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS SET WAREHOUSE = LARGER_WH;
```

### Use Separate Initialization Warehouse

```sql
ALTER DYNAMIC TABLE DT_DEMO_DB.STAGING.STG_ORDERS SET INITIALIZATION_WAREHOUSE = 'XLARGE_WH';
```

### DROP

```sql
DROP DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.TEMP_METRICS;
```

---

## 18. Monitoring & Debugging

### Check Refresh History

```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DT_DEMO_DB.STAGING.STG_ORDERS'
))
ORDER BY REFRESH_START_TIME DESC
LIMIT 20;
```

### Check Graph Dependencies

```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_GRAPH_HISTORY(
    NAME => 'DT_DEMO_DB.ANALYTICS.ORDER_SUMMARY'
));
```

### Query from ACCOUNT_USAGE

```sql
SELECT
    NAME,
    SCHEMA_NAME,
    TARGET_LAG,
    REFRESH_MODE,
    IS_TRANSIENT,
    SCHEDULING_STATE
FROM SNOWFLAKE.ACCOUNT_USAGE.DYNAMIC_TABLES
WHERE DELETED IS NULL
ORDER BY NAME;
```

### Check Current Lag

```sql
SHOW DYNAMIC TABLES IN SCHEMA DT_DEMO_DB.STAGING;
-- Look at the "scheduling_state" and "data_timestamp" columns
```

---

## 19. Dynamic Tables with Cortex AI Functions

```sql
-- Sentiment analysis on product reviews
CREATE OR REPLACE TABLE DT_DEMO_DB.RAW.REVIEWS (
    REVIEW_ID NUMBER AUTOINCREMENT,
    PRODUCT_ID NUMBER,
    REVIEW_TEXT VARCHAR(1000),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO DT_DEMO_DB.RAW.REVIEWS (PRODUCT_ID, REVIEW_TEXT) VALUES
    (101, 'Amazing laptop, blazing fast performance!'),
    (102, 'Mouse stopped working after 2 weeks, very disappointed.'),
    (103, 'Comfortable chair, great for long working hours.'),
    (105, 'Noise cancellation is mediocre at best.');

-- Dynamic table with AI-powered sentiment
CREATE OR REPLACE DYNAMIC TABLE DT_DEMO_DB.ANALYTICS.REVIEW_SENTIMENT
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = DT_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            r.REVIEW_ID,
            p.PRODUCT_NAME,
            r.REVIEW_TEXT,
            SNOWFLAKE.CORTEX.SENTIMENT(r.REVIEW_TEXT) AS SENTIMENT_SCORE,
            r.CREATED_AT
        FROM DT_DEMO_DB.RAW.REVIEWS r
        JOIN DT_DEMO_DB.RAW.PRODUCTS p ON r.PRODUCT_ID = p.PRODUCT_ID;
```

---

## 20. Limitations

### General Limitations

- Max 50,000 dynamic tables per account
- Cannot TRUNCATE data from a dynamic table
- Cannot create temporary dynamic tables
- Cannot use secondary roles (refreshes act as owner role)
- Cannot use dynamic SQL (session variables, unbound variables) in definition
- DT becomes stale if not refreshed within MAX_DATA_EXTENSION_TIME_IN_DAYS
- Cannot read from external tables, streams, materialized views, or directory tables
- Cannot read from views that query other dynamic tables (unless wrapped in DYNAMIC_TABLE_REFRESH_BOUNDARY())
- Cannot use QAS (Query Acceleration Service) for refreshes

### Incremental Refresh Limitations

- PIVOT, UNPIVOT, SAMPLE not supported
- Sequences not supported
- WITH RECURSIVE not supported
- Subqueries outside FROM not supported
- External functions not supported
- Volatile UDFs not supported
- LATERAL JOIN not supported (except LATERAL FLATTEN)
- Outer joins with non-equality predicates not supported
- CURRENT_TIMESTAMP/CURRENT_DATE only in WHERE/HAVING/QUALIFY

---

## 21. Best Practices

1. **Chain pipelines:** Break complex logic into smaller, focused dynamic tables
2. **Use DOWNSTREAM for intermediates:** Save compute by only refreshing when needed
3. **Use INCREMENTAL where possible:** Set explicit REFRESH_MODE = INCREMENTAL in production
4. **Avoid AUTO in production:** AUTO's behavior may change between Snowflake releases
5. **Cluster source tables:** By join/group keys for better incremental performance
6. **Use inner joins over outer joins:** Better performance with incremental refresh
7. **Don't use SELECT *:** List columns explicitly to avoid breakage when source changes
8. **Use transient for non-critical data:** Reduce storage costs
9. **Set appropriate target lag:** Balance freshness vs cost
10. **Monitor refresh history:** Regularly check for failed/skipped refreshes
11. **Use controller pattern:** For complex graphs, use a single controller DT
12. **Separate initialization warehouse:** Use a larger WH for initial load, smaller for refreshes

---

## 22. Interview Questions: Basic

**Q1: What is a dynamic table in Snowflake?**

A dynamic table is a table whose content is defined by a SELECT query and is automatically refreshed by Snowflake based on a specified target lag. It simplifies data pipelines by replacing the need for streams, tasks, and MERGE statements with a declarative approach.

---

**Q2: What is target lag?**

Target lag defines the maximum acceptable delay between changes in base tables and when those changes appear in the dynamic table. It can be a time duration (e.g., '5 minutes') or DOWNSTREAM, meaning the DT only refreshes when a downstream DT needs it.

---

**Q3: How is a dynamic table different from a regular view?**

A view re-executes the query every time you query it. A dynamic table materializes (stores) the results and refreshes them periodically. Dynamic tables are faster to query because the data is pre-computed, but they consume storage and compute for refreshes.

---

**Q4: Can you INSERT, UPDATE, or DELETE rows in a dynamic table?**

No. Dynamic tables are read-only. Their content is entirely managed by the automated refresh process based on the defining SELECT query. You cannot perform any DML operations on them.

---

**Q5: What is the difference between INITIALIZE = ON_CREATE vs ON_SCHEDULE?**

- ON_CREATE (default): The dynamic table is populated immediately when created. The CREATE statement blocks until the initial refresh completes.
- ON_SCHEDULE: The initial population happens at the next scheduled refresh time based on the target lag.

---

**Q6: How do you create a simple dynamic table?**

```sql
CREATE OR REPLACE DYNAMIC TABLE my_dt
    TARGET_LAG = '10 minutes'
    WAREHOUSE = my_wh
    AS
        SELECT col1, col2, col3
        FROM my_source_table;
```

---

**Q7: Can a dynamic table query from multiple tables?**

Yes. Dynamic tables support JOINs (INNER, LEFT, RIGHT, FULL OUTER, CROSS) in both incremental and full refresh modes.

---

**Q8: How do you check the current state of a dynamic table?**

```sql
SHOW DYNAMIC TABLES LIKE 'MY_DT%';
-- or
DESCRIBE DYNAMIC TABLE my_database.my_schema.my_dt;
```

---

## 23. Interview Questions: Intermediate

**Q9: What are the three refresh modes? When would you use each?**

| Mode | When to Use |
|------|------------|
| INCREMENTAL | <5% data changes, supported operators, good data locality |
| FULL | Large % changes, unsupported operators, poor locality |
| AUTO | Prototyping only. Snowflake picks at creation time. Avoid in production. |

---

**Q10: What is snapshot isolation in dynamic tables?**

When a dynamic table refreshes, it Time Travels to the same data timestamp across all upstream dependencies. This ensures a consistent "snapshot" of data. All tables in a pipeline chain see the same version of base data during a single refresh cycle.

---

**Q11: What happens when you set TARGET_LAG = DOWNSTREAM on all tables in a chain?**

No table will refresh automatically because there's no downstream consumer with a time-based target lag to drive the schedule. The entire pipeline is effectively suspended for scheduled refreshes. You would need to manually refresh the most downstream table to trigger the chain.

---

**Q12: How does Snowflake decide when to refresh a dynamic table?**

Snowflake schedules refreshes slightly earlier than the target lag to allow processing time. For example, with a 5-minute target lag, refreshes might run every ~4 minutes. The actual interval depends on warehouse size, data volume, and query complexity.

---

**Q13: Can you create a stream on a dynamic table?**

Yes, but only on dynamic tables that use incremental refresh mode. Only standard (delta) streams are supported. Streams on full-refresh dynamic tables are not supported.

---

**Q14: What is the controller dynamic table pattern?**

When you have many dynamic tables and want to control the entire graph with a single command:
1. Set all DTs to TARGET_LAG = DOWNSTREAM
2. Create a controller DT that reads from all leaf tables with LIMIT 0
3. Use the controller to set lag, trigger manual refresh, or suspend/resume the whole pipeline

---

**Q15: How do dynamic tables handle schema changes in base tables?**

- New column added / unused column removed: No impact, refreshes continue
- Base table recreated with same columns: Reinitialization occurs
- Base table column used by DT is dropped: Refresh fails; DT must be recreated
- DT uses SELECT *: Refresh fails on any schema change; must be recreated

---

**Q16: What is the INITIALIZATION_WAREHOUSE parameter?**

It lets you use a separate (typically larger) warehouse for the initial data population, while using a smaller, cost-effective warehouse for regular incremental refreshes.

```sql
CREATE DYNAMIC TABLE my_dt
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = 'XS_WAREHOUSE'
    INITIALIZATION_WAREHOUSE = '4XL_WAREHOUSE'
    AS <query>;
```

---

## 24. Interview Questions: Advanced

**Q17: Explain incremental refresh in detail. How does it work internally?**

1. Snowflake enables change tracking on all base tables used by the DT
2. On each refresh, Snowflake analyzes the DT's query to understand what changed
3. It computes only the delta (new/updated/deleted rows) since the last refresh
4. It merges the delta into the dynamic table
5. This is much faster than full refresh when only a small percentage of data changes
6. Not all operators support incremental refresh — unsupported operators force full refresh

---

**Q18: Can an incremental dynamic table be downstream of a full-refresh dynamic table?**

Yes, but ONLY if the upstream full-refresh DT has a **system-derived reliable unique key** (primary key). This allows Snowflake to compute row-level changes across full refreshes. You must set REFRESH_MODE = INCREMENTAL explicitly on the downstream table — AUTO mode won't resolve to incremental in this scenario.

---

**Q19: What are immutability constraints? How do they improve performance?**

Immutability constraints let you mark portions of a dynamic table as static using an IMMUTABLE WHERE clause. Snowflake skips those rows during refresh, which dramatically improves performance for tables with large amounts of historical data. Backfill extends this by copying existing data into the DT without computing it.

---

**Q20: How does target lag work in a chain of dynamic tables?**

Target lag is measured relative to the **root** dynamic tables (those reading from base tables), not the immediate upstream DT. Snowflake coordinates refresh schedules across the chain to maintain snapshot isolation. The target lag of a DT cannot be shorter than its upstream DTs' target lag (unless using DYNAMIC_TABLE_REFRESH_BOUNDARY).

---

**Q21: What is DYNAMIC_TABLE_REFRESH_BOUNDARY()?**

It allows a dynamic table to reference an upstream DT as if it belongs to a separate pipeline. The downstream DT reads whatever version of the upstream data is available at refresh time, rather than requiring a coordinated snapshot. This breaks snapshot isolation but allows shorter target lags on downstream tables.

---

**Q22: How do masking/row access policies affect dynamic table refresh?**

- Policies on the DT itself: No impact on refresh mode
- Policies on base tables using CURRENT_ROLE or IS_ROLE_IN_SESSION: Incremental refresh supported
- Policies on base tables using other functions or mapping table lookups: Incremental refresh NOT supported
- Any policy change on base tables triggers reinitialization for incremental DTs

---

**Q23: What happens when a dynamic table becomes stale?**

If a DT is not refreshed within the MAX_DATA_EXTENSION_TIME_IN_DAYS period of its input tables, it becomes stale. Once stale, it must be **recreated** — it cannot simply be resumed. This is because the change tracking data on the base tables has expired.

---

**Q24: How are CURRENT_TIMESTAMP and similar functions handled?**

CURRENT_TIMESTAMP, CURRENT_DATE, and CURRENT_TIME can only be used in WHERE/HAVING/QUALIFY clauses, not in SELECT. This is because dynamic tables are refreshed by a system process, and using these functions in SELECT would produce different results on each refresh.

---

## 25. Interview Questions: Scenario-Based

**Q25: Your company has a raw_events table with 10 billion rows, and 100K new rows arrive every hour. You need a cleaned, deduplicated, aggregated version for dashboards. How would you design this with dynamic tables?**

```
Layer 1 (Staging):
  DT: stg_events
  - TARGET_LAG = DOWNSTREAM
  - Clean, cast types, filter invalid rows
  - REFRESH_MODE = INCREMENTAL (small % changes)

Layer 2 (Dedup):
  DT: dedup_events
  - TARGET_LAG = DOWNSTREAM
  - Use ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY ts DESC) to deduplicate
  - QUALIFY ROW_NUMBER() = 1

Layer 3 (Aggregated):
  DT: hourly_event_summary
  - TARGET_LAG = '15 minutes'
  - GROUP BY DATE_TRUNC('HOUR', event_ts), event_type
  - COUNT, SUM, AVG metrics
```

This approach processes only the delta at each layer. The 15-minute target lag on the final layer drives the entire chain.

---

**Q26: You're migrating a Streams + Tasks pipeline to dynamic tables. The existing pipeline uses a stored procedure that calls MERGE with complex WHEN MATCHED/NOT MATCHED logic. How do you convert it?**

You cannot use MERGE or stored procedures in dynamic tables. Instead:
1. Rewrite the MERGE logic as a SELECT with window functions
2. Use QUALIFY with ROW_NUMBER() to get the latest version of each record
3. Use CASE expressions for conditional logic that was in WHEN clauses

```sql
-- Instead of MERGE with upsert logic:
CREATE DYNAMIC TABLE target_dt
    TARGET_LAG = '5 minutes'
    WAREHOUSE = my_wh
    AS
        SELECT id, state AS last_state, ts AS most_recent_ts
        FROM source_table
        QUALIFY ROW_NUMBER() OVER (
            PARTITION BY id ORDER BY ts DESC
        ) = 1;
```

---

**Q27: Your dynamic table's refresh is taking 30 minutes but the target lag is set to 10 minutes. What happens? How do you fix it?**

Snowflake will skip refreshes to try to stay current. The actual lag will exceed the target lag. The DT will show a scheduling state of "EXECUTING" for extended periods.

Fixes:
1. **Increase warehouse size** — faster compute reduces refresh time
2. **Increase target lag** — set to 1 hour if business can tolerate it
3. **Switch to INCREMENTAL** — if currently on FULL refresh
4. **Cluster source tables** — by join/group keys to improve data locality
5. **Split the DT** — break complex query into smaller intermediate DTs
6. **Add immutability constraints** — mark historical data as static

---

**Q28: Can you use dynamic tables for SCD Type 2? How?**

Yes. Dynamic tables support window functions needed for SCD2:

```sql
CREATE DYNAMIC TABLE scd2_customers
    TARGET_LAG = '10 minutes'
    WAREHOUSE = my_wh
    AS
        SELECT
            customer_id,
            name,
            email,
            updated_at AS valid_from,
            LEAD(updated_at) OVER (
                PARTITION BY customer_id
                ORDER BY updated_at
            ) AS valid_to,
            CASE
                WHEN LEAD(updated_at) OVER (
                    PARTITION BY customer_id ORDER BY updated_at
                ) IS NULL THEN TRUE
                ELSE FALSE
            END AS is_current
        FROM change_log_table;
```

---

**Q29: You have 200 dynamic tables across 5 schemas. How do you monitor which ones are failing?**

```sql
-- Check all refresh failures in the last 24 hours
SELECT
    NAME,
    REFRESH_START_TIME,
    REFRESH_END_TIME,
    STATE,
    STATE_MESSAGE
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
WHERE STATE = 'FAILED'
    AND REFRESH_START_TIME > DATEADD('DAY', -1, CURRENT_TIMESTAMP())
ORDER BY REFRESH_START_TIME DESC;

-- Check scheduling state of all DTs
SHOW DYNAMIC TABLES IN DATABASE DT_DEMO_DB;
-- Look for scheduling_state = 'SUSPENDED' or any error states
```

---

**Q30: What is the cost model for dynamic tables? How do you optimize costs?**

Costs come from two sources:
1. **Compute:** Warehouse credits used during refresh
2. **Storage:** Materialized data storage + Time Travel + Fail-safe

Optimization strategies:
- Use **DOWNSTREAM** lag for intermediate tables (refresh only when needed)
- Use **INCREMENTAL** mode to process only changed data
- Use **transient** DTs for non-critical data (no fail-safe storage)
- **Right-size** the warehouse (no bigger than needed)
- **Increase target lag** for non-time-sensitive data
- **Cluster source tables** to improve incremental refresh efficiency
- Use **INITIALIZATION_WAREHOUSE** for separate initial vs regular refresh sizing

---

## Quick Reference: Complete Syntax

```sql
-- CREATE
CREATE [ OR REPLACE ] [ TRANSIENT ] DYNAMIC TABLE <name>
    TARGET_LAG = { '<duration>' | DOWNSTREAM }
    WAREHOUSE = <wh>
    [ REFRESH_MODE = { AUTO | FULL | INCREMENTAL } ]
    [ INITIALIZE = { ON_CREATE | ON_SCHEDULE } ]
    [ INITIALIZATION_WAREHOUSE = <wh> ]
    AS <SELECT>;

-- ALTER
ALTER DYNAMIC TABLE <name> SET TARGET_LAG = '<duration>';
ALTER DYNAMIC TABLE <name> SET WAREHOUSE = <wh>;
ALTER DYNAMIC TABLE <name> SUSPEND;
ALTER DYNAMIC TABLE <name> RESUME;
ALTER DYNAMIC TABLE <name> REFRESH;

-- INFO
SHOW DYNAMIC TABLES [ LIKE '<pattern>' ] [ IN { DATABASE | SCHEMA } <name> ];
DESCRIBE DYNAMIC TABLE <name>;

-- DROP
DROP DYNAMIC TABLE <name>;
```
