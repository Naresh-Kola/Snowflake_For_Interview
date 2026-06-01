# Dynamic Table Chaining: Complete Hands-On Guide

Chaining = One dynamic table reads from another dynamic table. This builds a multi-layer pipeline where each layer transforms data and passes it to the next.

---

## What Is Chaining?

Chaining means connecting dynamic tables in a sequence:

```
Base Table → DT1 → DT2 → DT3
              │      │      │
            Bronze  Silver  Gold
            (clean) (join)  (aggregate)
```

Each DT reads from the previous one. When the base table changes, the change flows through the entire chain automatically.

**WITHOUT CHAINING** (everything in one giant query):
- One massive DT with 200-line SQL, 6 JOINs, 10 aggregations → Hard to debug, test, reuse

**WITH CHAINING** (broken into layers):
- DT1: Clean raw data (10 lines)
- DT2: Join with dimensions (15 lines)
- DT3: Aggregate for dashboard (10 lines)
- → Each layer is simple, testable, and reusable

---

## How TARGET LAG Works in a Chain

Target lag is measured from the **ROOT** (base tables), NOT from the immediate upstream DT.

**Example:**
```
Base Table → DT1 (DOWNSTREAM) → DT2 (DOWNSTREAM) → DT3 (10 min)

DT3 says: "My data should be no more than 10 min behind the BASE TABLE"
Snowflake works backwards:
  - DT3 needs fresh data → triggers DT2
  - DT2 needs fresh data → triggers DT1
  - DT1 reads base table → refreshes
  - DT2 reads DT1 → refreshes
  - DT3 reads DT2 → refreshes
  - Total chain completes within 10 min
```

### Target Lag Combinations

| DT1 Lag | DT2 Lag | Result |
|---------|---------|--------|
| DOWNSTREAM | 10 minutes | DT2 drives the schedule. DT1 refreshes only when DT2 needs it. Most efficient. |
| 5 minutes | 10 minutes | Both refresh independently. DT1 every ~5min, DT2 every ~10min. |
| DOWNSTREAM | DOWNSTREAM | **NOTHING REFRESHES!** No time-based lag to drive the schedule. Dead pipe. |
| 10 minutes | DOWNSTREAM | DT1 refreshes every ~10min. DT2 NEVER refreshes. AVOID THIS. |

**Rule of Thumb:**
- Set intermediate DTs to **DOWNSTREAM** (refresh on-demand)
- Set the **FINAL** DT (dashboards query it) to a time-based lag
- The final DT drives the entire chain

---

## Setup: Database, Schemas, and Source Data

```sql
CREATE DATABASE IF NOT EXISTS CHAIN_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS CHAIN_DEMO_DB.RAW;
CREATE SCHEMA IF NOT EXISTS CHAIN_DEMO_DB.STAGING;
CREATE SCHEMA IF NOT EXISTS CHAIN_DEMO_DB.INTERMEDIATE;
CREATE SCHEMA IF NOT EXISTS CHAIN_DEMO_DB.ANALYTICS;

CREATE OR REPLACE TABLE CHAIN_DEMO_DB.RAW.CUSTOMERS (
    CUSTOMER_ID   NUMBER,
    FIRST_NAME    VARCHAR(50),
    LAST_NAME     VARCHAR(50),
    EMAIL         VARCHAR(100),
    PHONE         VARCHAR(20),
    COUNTRY       VARCHAR(50),
    SEGMENT       VARCHAR(20),
    CREATED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CHAIN_DEMO_DB.RAW.PRODUCTS (
    PRODUCT_ID    NUMBER,
    PRODUCT_NAME  VARCHAR(100),
    CATEGORY      VARCHAR(50),
    BRAND         VARCHAR(50),
    COST_PRICE    NUMBER(10,2),
    LIST_PRICE    NUMBER(10,2),
    IS_ACTIVE     BOOLEAN DEFAULT TRUE
);

CREATE OR REPLACE TABLE CHAIN_DEMO_DB.RAW.ORDERS (
    ORDER_ID      NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    CUSTOMER_ID   NUMBER,
    ORDER_DATE    TIMESTAMP_NTZ,
    ORDER_STATUS  VARCHAR(20),
    SHIPPING_CITY VARCHAR(50),
    UPDATED_AT    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE CHAIN_DEMO_DB.RAW.ORDER_ITEMS (
    ITEM_ID       NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    ORDER_ID      NUMBER,
    PRODUCT_ID    NUMBER,
    QUANTITY      NUMBER,
    UNIT_PRICE    NUMBER(10,2),
    DISCOUNT_PCT  NUMBER(5,2) DEFAULT 0
);

INSERT INTO CHAIN_DEMO_DB.RAW.CUSTOMERS VALUES
    (1, 'Rohit',   'Sharma',  'rohit@example.com',   '+91-9876543210', 'India',          'Premium',    '2024-01-15'),
    (2, 'Priya',   'Patel',   'priya@example.com',   '+91-9876543211', 'India',          'Standard',   '2024-02-20'),
    (3, 'James',   'Wilson',  'james@example.com',   '+1-555-0101',    'United States',  'Premium',    '2024-03-10'),
    (4, 'Emily',   'Brown',   'emily@example.com',   '+44-20-7946001', 'United Kingdom', 'Standard',   '2024-04-05'),
    (5, 'Amit',    'Kumar',   'amit@example.com',    '+91-9876543212', 'India',          'Enterprise', '2024-05-15'),
    (6, 'Sarah',   'Johnson', 'sarah@example.com',   '+1-555-0102',    'United States',  'Enterprise', '2024-06-01'),
    (7, 'Michael', 'Davis',   'michael@example.com', '+1-555-0103',    'Canada',         'Standard',   '2024-07-20'),
    (8, 'Ananya',  'Reddy',   'ananya@example.com',  '+91-9876543213', 'India',          'Premium',    '2024-08-10');

INSERT INTO CHAIN_DEMO_DB.RAW.PRODUCTS VALUES
    (101, 'Laptop Pro 15',       'Electronics',  'TechCorp',  600.00,  999.99,  TRUE),
    (102, 'Wireless Mouse',      'Electronics',  'TechCorp',  15.00,   29.99,   TRUE),
    (103, 'Office Chair',        'Furniture',    'ComfortCo', 120.00,  249.99,  TRUE),
    (104, 'Standing Desk',       'Furniture',    'ComfortCo', 280.00,  549.99,  TRUE),
    (105, 'Headphones NC',       'Electronics',  'AudioMax',  80.00,   199.99,  TRUE),
    (106, 'USB-C Hub',           'Accessories',  'TechCorp',  25.00,   59.99,   TRUE),
    (107, 'Mechanical Keyboard', 'Accessories',  'KeyMaster', 40.00,   89.99,   TRUE),
    (108, 'Monitor 27"',         'Electronics',  'ViewPro',   200.00,  399.99,  TRUE),
    (109, 'Webcam HD',           'Accessories',  'TechCorp',  20.00,   49.99,   TRUE),
    (110, 'Laptop Stand',        'Accessories',  'ComfortCo', 15.00,   39.99,   TRUE);

INSERT INTO CHAIN_DEMO_DB.RAW.ORDERS (CUSTOMER_ID, ORDER_DATE, ORDER_STATUS, SHIPPING_CITY) VALUES
    (1, '2025-01-10 10:30:00', 'COMPLETED', 'Delhi'),
    (2, '2025-01-15 14:00:00', 'COMPLETED', 'Mumbai'),
    (3, '2025-02-01 09:00:00', 'SHIPPED',   'New York'),
    (1, '2025-02-10 16:45:00', 'COMPLETED', 'Delhi'),
    (4, '2025-02-15 11:30:00', 'PENDING',   'London'),
    (5, '2025-03-01 08:00:00', 'COMPLETED', 'Bangalore'),
    (6, '2025-03-10 13:20:00', 'SHIPPED',   'Chicago'),
    (2, '2025-03-15 15:00:00', 'COMPLETED', 'Mumbai'),
    (7, '2025-04-01 10:00:00', 'COMPLETED', 'Toronto'),
    (8, '2025-04-10 12:00:00', 'PENDING',   'Hyderabad'),
    (3, '2025-04-15 14:30:00', 'COMPLETED', 'San Francisco'),
    (5, '2025-05-01 09:15:00', 'SHIPPED',   'Bangalore'),
    (1, '2025-05-10 16:00:00', 'COMPLETED', 'Delhi'),
    (6, '2025-05-20 11:45:00', 'COMPLETED', 'New York'),
    (4, '2025-06-01 08:30:00', 'COMPLETED', 'London');

INSERT INTO CHAIN_DEMO_DB.RAW.ORDER_ITEMS (ORDER_ID, PRODUCT_ID, QUANTITY, UNIT_PRICE, DISCOUNT_PCT) VALUES
    (1,  101, 1, 999.99, 0),  (1,  102, 2, 29.99,  10),
    (2,  105, 1, 199.99, 0),  (3,  103, 1, 249.99, 5),
    (3,  106, 3, 59.99,  0),  (4,  107, 1, 89.99,  0),
    (4,  102, 1, 29.99,  0),  (5,  104, 1, 549.99, 15),
    (6,  101, 2, 999.99, 10), (6,  108, 1, 399.99, 0),
    (7,  108, 3, 399.99, 5),  (8,  107, 1, 89.99,  0),
    (9,  106, 4, 59.99,  0),  (10, 101, 1, 999.99, 0),
    (11, 102, 3, 29.99,  0),  (11, 110, 2, 39.99,  0),
    (12, 103, 2, 249.99, 10), (13, 107, 1, 89.99,  0),
    (14, 105, 2, 199.99, 5),  (15, 108, 1, 399.99, 0);

-- Verify data
SELECT 'CUSTOMERS' AS TBL, COUNT(*) AS ROWS FROM CHAIN_DEMO_DB.RAW.CUSTOMERS
UNION ALL SELECT 'PRODUCTS', COUNT(*) FROM CHAIN_DEMO_DB.RAW.PRODUCTS
UNION ALL SELECT 'ORDERS', COUNT(*) FROM CHAIN_DEMO_DB.RAW.ORDERS
UNION ALL SELECT 'ORDER_ITEMS', COUNT(*) FROM CHAIN_DEMO_DB.RAW.ORDER_ITEMS;
```

---

## The Chain: 4-Layer Pipeline

```
┌─────────────────────┐
│   RAW TABLES        │   Regular tables (data lands here from ETL)
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  LAYER 1: STAGING   │   DT - Clean, rename, type-cast, filter junk
│  (DOWNSTREAM)       │   4 DTs: stg_customers, stg_products, stg_orders, stg_order_items
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  LAYER 2: INTER-    │   DT - Join staging tables, compute metrics
│  MEDIATE            │   2 DTs: int_order_details, int_customer_orders
│  (DOWNSTREAM)       │
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  LAYER 3: ANALYTICS │   DT - Final aggregations for dashboards
│  (10 minutes)       │   3 DTs: daily_revenue, customer_360, product_performance
└────────┬────────────┘
         │
         ▼
┌─────────────────────┐
│  DASHBOARDS         │   BI tools query the ANALYTICS layer
└─────────────────────┘
```

---

## Layer 1: Staging (Clean + Standardize)

```sql
-- DT 1.1: STG_CUSTOMERS
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.STAGING.STG_CUSTOMERS
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            CUSTOMER_ID,
            TRIM(FIRST_NAME) || ' ' || TRIM(LAST_NAME) AS FULL_NAME,
            LOWER(TRIM(EMAIL)) AS EMAIL,
            PHONE,
            UPPER(TRIM(COUNTRY)) AS COUNTRY,
            UPPER(TRIM(SEGMENT)) AS SEGMENT,
            CREATED_AT
        FROM CHAIN_DEMO_DB.RAW.CUSTOMERS;

-- DT 1.2: STG_PRODUCTS
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.STAGING.STG_PRODUCTS
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            PRODUCT_ID,
            TRIM(PRODUCT_NAME) AS PRODUCT_NAME,
            UPPER(TRIM(CATEGORY)) AS CATEGORY,
            UPPER(TRIM(BRAND)) AS BRAND,
            COST_PRICE, LIST_PRICE,
            LIST_PRICE - COST_PRICE AS PROFIT_MARGIN,
            ROUND((LIST_PRICE - COST_PRICE) / NULLIF(COST_PRICE, 0) * 100, 2) AS MARGIN_PCT
        FROM CHAIN_DEMO_DB.RAW.PRODUCTS
        WHERE IS_ACTIVE = TRUE;

-- DT 1.3: STG_ORDERS
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.STAGING.STG_ORDERS
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            ORDER_ID, CUSTOMER_ID, ORDER_DATE,
            ORDER_DATE::DATE AS ORDER_DATE_ONLY,
            DATE_TRUNC('MONTH', ORDER_DATE)::DATE AS ORDER_MONTH,
            UPPER(TRIM(ORDER_STATUS)) AS ORDER_STATUS,
            TRIM(SHIPPING_CITY) AS SHIPPING_CITY
        FROM CHAIN_DEMO_DB.RAW.ORDERS;

-- DT 1.4: STG_ORDER_ITEMS
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.STAGING.STG_ORDER_ITEMS
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            ITEM_ID, ORDER_ID, PRODUCT_ID,
            QUANTITY, UNIT_PRICE, DISCOUNT_PCT,
            ROUND(QUANTITY * UNIT_PRICE * (1 - DISCOUNT_PCT / 100), 2) AS LINE_TOTAL
        FROM CHAIN_DEMO_DB.RAW.ORDER_ITEMS;
```

---

## Layer 2: Intermediate (Join + Enrich)

```sql
-- DT 2.1: INT_ORDER_DETAILS (joins orders + items + products + customers)
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.INTERMEDIATE.INT_ORDER_DETAILS
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            o.ORDER_ID, o.ORDER_DATE, o.ORDER_DATE_ONLY, o.ORDER_MONTH,
            o.ORDER_STATUS, o.SHIPPING_CITY,
            c.CUSTOMER_ID, c.FULL_NAME AS CUSTOMER_NAME,
            c.COUNTRY AS CUSTOMER_COUNTRY, c.SEGMENT AS CUSTOMER_SEGMENT,
            i.ITEM_ID, p.PRODUCT_ID, p.PRODUCT_NAME,
            p.CATEGORY AS PRODUCT_CATEGORY, p.BRAND AS PRODUCT_BRAND,
            i.QUANTITY, i.UNIT_PRICE, i.DISCOUNT_PCT, i.LINE_TOTAL,
            p.COST_PRICE * i.QUANTITY AS TOTAL_COST,
            i.LINE_TOTAL - (p.COST_PRICE * i.QUANTITY) AS LINE_PROFIT
        FROM CHAIN_DEMO_DB.STAGING.STG_ORDERS o
        INNER JOIN CHAIN_DEMO_DB.STAGING.STG_ORDER_ITEMS i ON o.ORDER_ID = i.ORDER_ID
        INNER JOIN CHAIN_DEMO_DB.STAGING.STG_PRODUCTS p ON i.PRODUCT_ID = p.PRODUCT_ID
        INNER JOIN CHAIN_DEMO_DB.STAGING.STG_CUSTOMERS c ON o.CUSTOMER_ID = c.CUSTOMER_ID;

-- DT 2.2: INT_CUSTOMER_ORDERS (order-level summary per customer)
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.INTERMEDIATE.INT_CUSTOMER_ORDERS
    TARGET_LAG = DOWNSTREAM
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            ORDER_ID, CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_COUNTRY,
            CUSTOMER_SEGMENT, ORDER_DATE, ORDER_DATE_ONLY, ORDER_MONTH, ORDER_STATUS,
            COUNT(ITEM_ID) AS NUM_ITEMS,
            SUM(QUANTITY) AS TOTAL_QUANTITY,
            SUM(LINE_TOTAL) AS ORDER_TOTAL,
            SUM(LINE_PROFIT) AS ORDER_PROFIT
        FROM CHAIN_DEMO_DB.INTERMEDIATE.INT_ORDER_DETAILS
        GROUP BY ORDER_ID, CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_COUNTRY,
                 CUSTOMER_SEGMENT, ORDER_DATE, ORDER_DATE_ONLY, ORDER_MONTH, ORDER_STATUS;
```

---

## Layer 3: Analytics (Aggregate for Dashboards)

```sql
-- DT 3.1: DAILY_REVENUE
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE
    TARGET_LAG = '10 minutes'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            ORDER_DATE_ONLY AS SALE_DATE, PRODUCT_CATEGORY,
            COUNT(DISTINCT ORDER_ID) AS NUM_ORDERS,
            COUNT(DISTINCT CUSTOMER_ID) AS UNIQUE_CUSTOMERS,
            SUM(LINE_TOTAL) AS TOTAL_REVENUE,
            SUM(LINE_PROFIT) AS TOTAL_PROFIT,
            ROUND(AVG(LINE_TOTAL), 2) AS AVG_LINE_VALUE,
            SUM(QUANTITY) AS UNITS_SOLD
        FROM CHAIN_DEMO_DB.INTERMEDIATE.INT_ORDER_DETAILS
        GROUP BY ORDER_DATE_ONLY, PRODUCT_CATEGORY;

-- DT 3.2: CUSTOMER_360 (one row per customer, lifetime metrics)
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360
    TARGET_LAG = '10 minutes'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_COUNTRY, CUSTOMER_SEGMENT,
            COUNT(DISTINCT ORDER_ID) AS LIFETIME_ORDERS,
            SUM(ORDER_TOTAL) AS LIFETIME_REVENUE,
            SUM(ORDER_PROFIT) AS LIFETIME_PROFIT,
            ROUND(AVG(ORDER_TOTAL), 2) AS AVG_ORDER_VALUE,
            MIN(ORDER_DATE) AS FIRST_ORDER_DATE,
            MAX(ORDER_DATE) AS LAST_ORDER_DATE,
            DATEDIFF('DAY', MIN(ORDER_DATE), MAX(ORDER_DATE)) AS CUSTOMER_TENURE_DAYS
        FROM CHAIN_DEMO_DB.INTERMEDIATE.INT_CUSTOMER_ORDERS
        GROUP BY CUSTOMER_ID, CUSTOMER_NAME, CUSTOMER_COUNTRY, CUSTOMER_SEGMENT;

-- DT 3.3: PRODUCT_PERFORMANCE
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE
    TARGET_LAG = '10 minutes'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT
            PRODUCT_ID, PRODUCT_NAME, PRODUCT_CATEGORY, PRODUCT_BRAND,
            COUNT(DISTINCT ORDER_ID) AS TIMES_ORDERED,
            SUM(QUANTITY) AS TOTAL_UNITS_SOLD,
            SUM(LINE_TOTAL) AS TOTAL_REVENUE,
            SUM(LINE_PROFIT) AS TOTAL_PROFIT,
            ROUND(AVG(DISCOUNT_PCT), 2) AS AVG_DISCOUNT_PCT,
            COUNT(DISTINCT CUSTOMER_ID) AS UNIQUE_BUYERS
        FROM CHAIN_DEMO_DB.INTERMEDIATE.INT_ORDER_DETAILS
        GROUP BY PRODUCT_ID, PRODUCT_NAME, PRODUCT_CATEGORY, PRODUCT_BRAND;

-- Verify
SELECT * FROM CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE ORDER BY SALE_DATE, PRODUCT_CATEGORY;
SELECT * FROM CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360 ORDER BY LIFETIME_REVENUE DESC;
SELECT * FROM CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE ORDER BY TOTAL_REVENUE DESC;
```

---

## Testing the Chain with DML

### Test 1: INSERT — New customer places an order

```sql
INSERT INTO CHAIN_DEMO_DB.RAW.CUSTOMERS VALUES
    (9, 'Vikram', 'Singh', 'vikram@example.com', '+91-9876543214', 'India', 'Standard', CURRENT_TIMESTAMP());

INSERT INTO CHAIN_DEMO_DB.RAW.ORDERS (CUSTOMER_ID, ORDER_DATE, ORDER_STATUS, SHIPPING_CITY) VALUES
    (9, CURRENT_TIMESTAMP(), 'PENDING', 'Chennai');

INSERT INTO CHAIN_DEMO_DB.RAW.ORDER_ITEMS (ORDER_ID, PRODUCT_ID, QUANTITY, UNIT_PRICE, DISCOUNT_PCT) VALUES
    (16, 101, 1, 999.99, 5),
    (16, 109, 2, 49.99,  0);

-- Refresh final layer (triggers entire chain)
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE REFRESH;
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360 REFRESH;
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE REFRESH;

-- Verify
SELECT * FROM CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360 WHERE CUSTOMER_NAME = 'Vikram Singh';
SELECT * FROM CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE ORDER BY SALE_DATE DESC LIMIT 5;
```

**What happened behind the scenes:**
1. Refreshed Layer 3 → triggered Layer 2 → triggered Layer 1
2. Layer 1 read from RAW → picked up new customer, order, items
3. Changes flowed: RAW → STAGING → INTERMEDIATE → ANALYTICS

### Test 2: UPDATE — Order status changes

```sql
UPDATE CHAIN_DEMO_DB.RAW.ORDERS
SET ORDER_STATUS = 'SHIPPED', UPDATED_AT = CURRENT_TIMESTAMP()
WHERE ORDER_ID = 5;

ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE REFRESH;
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360 REFRESH;

-- Trace through layers
SELECT ORDER_ID, ORDER_STATUS FROM CHAIN_DEMO_DB.STAGING.STG_ORDERS WHERE ORDER_ID = 5;
SELECT ORDER_ID, ORDER_STATUS FROM CHAIN_DEMO_DB.INTERMEDIATE.INT_CUSTOMER_ORDERS WHERE ORDER_ID = 5;
```

### Test 3: UPDATE — Product price change

```sql
UPDATE CHAIN_DEMO_DB.RAW.PRODUCTS SET LIST_PRICE = 849.99 WHERE PRODUCT_ID = 101;

ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE REFRESH;

SELECT PRODUCT_NAME, LIST_PRICE, PROFIT_MARGIN, MARGIN_PCT
FROM CHAIN_DEMO_DB.STAGING.STG_PRODUCTS WHERE PRODUCT_ID = 101;
```

### Test 4: DELETE — Deactivate a product

```sql
UPDATE CHAIN_DEMO_DB.RAW.PRODUCTS SET IS_ACTIVE = FALSE WHERE PRODUCT_ID = 109;

ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE REFRESH;

SELECT * FROM CHAIN_DEMO_DB.STAGING.STG_PRODUCTS WHERE PRODUCT_ID = 109;
-- 0 rows — filtered out by IS_ACTIVE = TRUE!
```

### Test 5: BULK INSERT — End-of-day batch

```sql
INSERT INTO CHAIN_DEMO_DB.RAW.ORDERS (CUSTOMER_ID, ORDER_DATE, ORDER_STATUS, SHIPPING_CITY) VALUES
    (1, CURRENT_TIMESTAMP(), 'PENDING',   'Delhi'),
    (3, CURRENT_TIMESTAMP(), 'PENDING',   'Boston'),
    (5, CURRENT_TIMESTAMP(), 'COMPLETED', 'Bangalore'),
    (8, CURRENT_TIMESTAMP(), 'PENDING',   'Hyderabad');

INSERT INTO CHAIN_DEMO_DB.RAW.ORDER_ITEMS (ORDER_ID, PRODUCT_ID, QUANTITY, UNIT_PRICE, DISCOUNT_PCT) VALUES
    (17, 104, 1, 549.99, 0),
    (18, 105, 1, 199.99, 10),
    (19, 101, 3, 849.99, 5),
    (19, 107, 2, 89.99,  0),
    (20, 108, 1, 399.99, 0);

ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE REFRESH;
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360 REFRESH;
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE REFRESH;

SELECT * FROM CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360 ORDER BY LIFETIME_REVENUE DESC;
SELECT * FROM CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE ORDER BY TOTAL_REVENUE DESC;
```

---

## Monitoring the Chain

```sql
-- Refresh history for all DTs
SELECT NAME, REFRESH_ACTION, STATE, REFRESH_TRIGGER,
    STATISTICS:numInsertedRows::INT AS INS,
    STATISTICS:numDeletedRows::INT AS DEL,
    REFRESH_START_TIME,
    DATEDIFF('SECOND', REFRESH_START_TIME, REFRESH_END_TIME) AS DURATION_SEC
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY())
WHERE NAME LIKE 'STG%' OR NAME LIKE 'INT%' OR NAME LIKE 'DAILY%'
   OR NAME LIKE 'CUSTOMER%' OR NAME LIKE 'PRODUCT%'
ORDER BY REFRESH_START_TIME DESC LIMIT 30;

-- Dependency graph
SELECT * FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_GRAPH_HISTORY())
ORDER BY VALID_FROM DESC LIMIT 20;

-- Current state of all DTs
SHOW DYNAMIC TABLES IN DATABASE CHAIN_DEMO_DB;
```

---

## Advanced: Controller Pattern

Instead of refreshing 3 analytics DTs separately, create ONE controller that depends on all of them.

```
┌─────────────┐  ┌──────────────┐  ┌────────────────────┐
│DAILY_REVENUE│  │ CUSTOMER_360 │  │PRODUCT_PERFORMANCE │
└──────┬──────┘  └──────┬───────┘  └─────────┬──────────┘
       │                │                     │
       └────────────────┼─────────────────────┘
                        │
                ┌───────▼────────┐
                │  CONTROLLER    │  ← Refresh THIS = refresh EVERYTHING
                └────────────────┘
```

```sql
-- Set all analytics DTs to DOWNSTREAM
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE SET TARGET_LAG = DOWNSTREAM;
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360 SET TARGET_LAG = DOWNSTREAM;
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE SET TARGET_LAG = DOWNSTREAM;

-- Create controller
CREATE OR REPLACE DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER
    TARGET_LAG = '10 minutes'
    WAREHOUSE = COMPUTE_WH
    AS
        SELECT 1 AS CTRL
        FROM CHAIN_DEMO_DB.ANALYTICS.DAILY_REVENUE,
             CHAIN_DEMO_DB.ANALYTICS.CUSTOMER_360,
             CHAIN_DEMO_DB.ANALYTICS.PRODUCT_PERFORMANCE
        LIMIT 0;

-- ONE refresh drives the ENTIRE 9-DT pipeline:
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER REFRESH;

-- Change freshness with ONE command:
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER SET TARGET_LAG = '30 minutes';

-- Suspend entire pipeline:
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER SUSPEND;

-- Resume:
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER RESUME;
```

---

## Summary: The Complete Chain

```
RAW.CUSTOMERS ──────┐
RAW.PRODUCTS  ──────┤
RAW.ORDERS    ──────┼──► STAGING (4 DTs, DOWNSTREAM)
RAW.ORDER_ITEMS ────┘         │
                              │
                              ▼
                     INTERMEDIATE (2 DTs, DOWNSTREAM)
                              │
                              ▼
                     ANALYTICS (3 DTs, DOWNSTREAM)
                              │
                              ▼
                     CONTROLLER (1 DT, 10 min)
                              │
                              ▼
                      DASHBOARDS QUERY HERE
```

- **TOTAL:** 10 dynamic tables, 4 raw base tables
- **CONTROL:** 1 single ALTER command manages the entire pipeline
- **REFRESH FLOW:** Controller → Analytics → Intermediate → Staging → Raw
- **DATA FLOW:** Raw → Staging → Intermediate → Analytics → Dashboards

---

## Bonus: SCD-2 with Dynamic Tables (Using Append-Only Source)

```sql
CREATE OR REPLACE TABLE CUSTOMER_CHANGES (
    CUSTOMER_ID    INT,
    FIRST_NAME     VARCHAR(50),
    LAST_NAME      VARCHAR(50),
    EMAIL          VARCHAR(100),
    PHONE_NUMBER   VARCHAR(15),
    FULL_ADDRESS   VARCHAR(365),
    UPDATE_TIME    TIMESTAMP_NTZ(9)
);

INSERT INTO CUSTOMER_CHANGES VALUES
    (1, 'John', 'Doe', 'john.doe@example.com',  '1234567890', '123 Main St, New York, NY, 10001',       '2023-05-25 10:00:00'),
    (2, 'Jane', 'Smith', 'jane.smith@example.com', '0987654321', '456 Pine St, San Francisco, CA, 94101', '2023-05-25 11:00:00'),
    (1, 'John', 'Doe', 'john.doe2@example.com', '1234567890', '789 Broadway St, New York, NY, 10002',   '2023-05-25 12:00:00'),
    (3, 'Jim',  'Brown', 'jim.brown@example.com', '1122334455', '321 Elm St, Chicago, IL, 60601',        '2023-05-25 13:00:00'),
    (2, 'Jane', 'Smith', 'jane.smith2@example.com', '0987654322', '654 Oak St, San Francisco, CA, 94102', '2023-05-25 14:00:00');

CREATE OR REPLACE DYNAMIC TABLE CUSTOMER_HISTORY
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    AS
    SELECT
        CUSTOMER_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE_NUMBER, FULL_ADDRESS,
        UPDATE_TIME AS VALID_FROM,
        LEAD(UPDATE_TIME) OVER (PARTITION BY CUSTOMER_ID ORDER BY UPDATE_TIME ASC) AS VALID_TO,
        CASE WHEN LEAD(UPDATE_TIME) OVER (PARTITION BY CUSTOMER_ID ORDER BY UPDATE_TIME ASC) IS NULL
             THEN TRUE ELSE FALSE END AS IS_VALID
    FROM CUSTOMER_CHANGES;

ALTER DYNAMIC TABLE CUSTOMER_HISTORY REFRESH;

SELECT * FROM CUSTOMER_HISTORY ORDER BY CUSTOMER_ID;
```

---

## Cleanup

```sql
ALTER DYNAMIC TABLE CHAIN_DEMO_DB.ANALYTICS.PIPELINE_CONTROLLER SUSPEND;
-- DROP DATABASE CHAIN_DEMO_DB;
```
