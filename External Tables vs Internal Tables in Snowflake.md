# External Tables vs Internal Tables in Snowflake — Complete Guide

---

## Part 1: Definitions

### Internal Table (Regular/Native Snowflake Table)

An internal table is the standard table in Snowflake where data is stored **INSIDE Snowflake's managed cloud storage**. Snowflake controls the storage, organizes data into micro-partitions, manages metadata, and handles all optimization (clustering, pruning, caching).

**Three subtypes:**
- **PERMANENT** — full Time Travel + Fail-safe (default)
- **TRANSIENT** — Time Travel (0-1 day), NO Fail-safe
- **TEMPORARY** — exists only for session lifetime, no Fail-safe

When you run INSERT, UPDATE, DELETE, MERGE — data lives in Snowflake.

---

### External Table

An external table lets you query files stored **OUTSIDE of Snowflake** — in Amazon S3, Azure Blob Storage, or Google Cloud Storage — as if they were a regular table. The data **NEVER moves** into Snowflake's storage. Snowflake only stores lightweight metadata (file names, partition info).

External tables are **READ-ONLY**. You cannot INSERT, UPDATE, or DELETE. You query them with SELECT just like any other table.

> Think of it as: *"a window into your data lake, without copying data."*

---

## Part 2: How They Work Internally

### Internal Table

```
INSERT INTO orders ...
       │
       ▼
┌──────────────────────────────────────┐
│ SNOWFLAKE MANAGED STORAGE            │
│                                      │
│  ┌──────────┐ ┌──────────┐          │
│  │ Micro-   │ │ Micro-   │ ...      │
│  │ Partition│ │ Partition│          │
│  │ 1 (50MB) │ │ 2 (50MB) │          │
│  └──────────┘ └──────────┘          │
│                                      │
│  Metadata: min/max per column,       │
│  distinct count, null count, etc.    │
│  → enables partition pruning         │
│  → enables Time Travel              │
│  → enables clustering               │
└──────────────────────────────────────┘
```

### External Table

```
SELECT * FROM ext_orders WHERE ...
       │
       ▼
┌──────────────────────────────────────┐
│ SNOWFLAKE (metadata only)            │
│                                      │
│  File registry:                      │
│   s3://bucket/orders/2025/01/a.parq  │
│   s3://bucket/orders/2025/01/b.parq  │
│   s3://bucket/orders/2025/02/c.parq  │
│                                      │
│  Partition info, file-level metadata  │
└──────────────┬───────────────────────┘
               │ reads at query time
               ▼
┌──────────────────────────────────────┐
│ YOUR CLOUD STORAGE (S3/Azure/GCS)    │
│                                      │
│  /orders/2025/01/a.parquet           │
│  /orders/2025/01/b.parquet           │
│  /orders/2025/02/c.parquet           │
│                                      │
│  You own and manage these files.     │
│  Snowflake reads them on demand.     │
└──────────────────────────────────────┘
```

---

## Part 3: Side-by-Side Comparison

| Feature | Internal Table | External Table |
|---------|---------------|----------------|
| **Data location** | Snowflake managed storage (S3/Azure/GCS behind the scenes, but managed) | Your cloud storage (S3/Azure/GCS you manage directly) |
| **Read/Write** | Full DML (INSERT, UPDATE, DELETE, MERGE) | READ-ONLY (SELECT only) |
| **Query performance** | Fast — micro-partition pruning, caching, search optimization | Slower — reads from remote storage each time (no local cache) |
| **Time Travel** | Yes (1-90 days) | No |
| **Fail-safe** | Yes (7 days, permanent) | No |
| **Clustering keys** | Yes | No |
| **Search optimization** | Yes | No |
| **Materialized views** | Yes | Yes (recommended to improve perf) |
| **Cloning (CLONE)** | Yes (zero-copy) | No |
| **Replication** | Yes | No |
| **Data sharing** | Yes | No |
| **Streams (CDC)** | Yes | Limited |
| **Snowflake storage cost** | Yes — you pay for Snowflake storage | No — data stays in your own storage |
| **Compute cost for queries** | Standard warehouse credits | Standard warehouse credits + metadata refresh overhead |
| **Schema enforcement** | Schema-on-write (defined at CREATE) | Schema-on-read (define virtual cols) |
| **Supported formats** | Any (loaded via COPY) | CSV, JSON, Parquet, Avro, ORC (NOT XML) |
| **Partitioning** | Automatic micro-partitions (transparent to user) | Manual path-based partitioning |

---

## Part 4: When to Use Which?

### Use Internal Tables When:
- Data needs to be updated (INSERT/UPDATE/DELETE/MERGE)
- You need fast query performance (dashboards, BI, ad-hoc)
- You need Time Travel or Fail-safe for recovery
- You need clustering, search optimization, or result caching
- Data is used frequently and justifies Snowflake storage cost
- You need to share data via Snowflake Secure Data Sharing
- You need streams/tasks for CDC pipelines

### Use External Tables When:
- Data must stay in your own cloud storage (compliance, governance)
- Data is shared across multiple engines (Spark, Presto, Snowflake)
- You want to query a data lake without copying data into Snowflake
- Data is rarely queried (cold/archive data) — avoid storage cost
- Data is write-once, append-only logs/events
- You need a quick exploration layer before deciding to load data

---

## Part 5: Step-by-Step Examples

### Example 1: Creating an Internal Table

```sql
CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.ORDERS_INTERNAL (
    ORDER_ID        VARCHAR NOT NULL,
    CUSTOMER_ID     VARCHAR,
    ORDER_DATE      DATE,
    AMOUNT          NUMBER(12,2),
    REGION          VARCHAR,
    STATUS          VARCHAR
);

INSERT INTO DEMO_DB.PUBLIC.ORDERS_INTERNAL VALUES
    ('ORD-001', 'C-100', '2025-05-01', 250.00, 'US-EAST', 'COMPLETED'),
    ('ORD-002', 'C-101', '2025-05-01', 180.00, 'EUROPE',  'PENDING'),
    ('ORD-003', 'C-102', '2025-05-02', 320.00, 'APAC',    'COMPLETED');

-- Full DML is supported
UPDATE DEMO_DB.PUBLIC.ORDERS_INTERNAL SET STATUS = 'SHIPPED' WHERE ORDER_ID = 'ORD-002';
DELETE FROM DEMO_DB.PUBLIC.ORDERS_INTERNAL WHERE ORDER_ID = 'ORD-003';

-- Time Travel works
SELECT * FROM DEMO_DB.PUBLIC.ORDERS_INTERNAL AT(OFFSET => -60);

-- Query uses micro-partition pruning, caching, etc.
SELECT * FROM DEMO_DB.PUBLIC.ORDERS_INTERNAL WHERE ORDER_DATE = '2025-05-01';
```

### Example 2: Creating an External Table

```sql
-- Step 1: Create an external stage pointing to your cloud storage
CREATE OR REPLACE STAGE DEMO_DB.PUBLIC.MY_S3_STAGE
    URL = 's3://my-bucket/orders/'
    STORAGE_INTEGRATION = my_s3_integration
    FILE_FORMAT = (TYPE = 'PARQUET');

-- Step 2: Create the external table with virtual columns
CREATE OR REPLACE EXTERNAL TABLE DEMO_DB.PUBLIC.ORDERS_EXTERNAL (
    ORDER_ID    VARCHAR AS (VALUE:order_id::VARCHAR),
    CUSTOMER_ID VARCHAR AS (VALUE:customer_id::VARCHAR),
    ORDER_DATE  DATE    AS (VALUE:order_date::DATE),
    AMOUNT      NUMBER(12,2) AS (VALUE:amount::NUMBER(12,2)),
    REGION      VARCHAR AS (VALUE:region::VARCHAR),
    STATUS      VARCHAR AS (VALUE:status::VARCHAR)
)
PARTITION BY (ORDER_DATE)
LOCATION = @DEMO_DB.PUBLIC.MY_S3_STAGE
AUTO_REFRESH = TRUE
FILE_FORMAT = (TYPE = 'PARQUET');

-- Step 3: Refresh metadata (registers existing files)
ALTER EXTERNAL TABLE DEMO_DB.PUBLIC.ORDERS_EXTERNAL REFRESH;

-- Step 4: Query just like a regular table
SELECT ORDER_ID, AMOUNT, REGION
FROM DEMO_DB.PUBLIC.ORDERS_EXTERNAL
WHERE ORDER_DATE = '2025-05-01';

-- DML is NOT allowed (will error):
-- INSERT INTO DEMO_DB.PUBLIC.ORDERS_EXTERNAL ...  -> ERROR!
-- UPDATE DEMO_DB.PUBLIC.ORDERS_EXTERNAL ...       -> ERROR!
-- DELETE FROM DEMO_DB.PUBLIC.ORDERS_EXTERNAL ...  -> ERROR!
```

### Example 3: Materialized View Over External Table (Performance Boost)

Since external tables are slow (reading from remote storage each time), create a materialized view to pre-compute and cache results in Snowflake.

```sql
CREATE MATERIALIZED VIEW DEMO_DB.PUBLIC.MV_EXTERNAL_DAILY_REVENUE AS
SELECT
    ORDER_DATE,
    REGION,
    SUM(AMOUNT)   AS TOTAL_REVENUE,
    COUNT(*)       AS ORDER_COUNT
FROM DEMO_DB.PUBLIC.ORDERS_EXTERNAL
GROUP BY 1, 2;

-- Now this is fast (reads from Snowflake's internal storage, not S3):
SELECT * FROM DEMO_DB.PUBLIC.MV_EXTERNAL_DAILY_REVENUE
WHERE ORDER_DATE >= '2025-04-01';
```

### Example 4: Hybrid Pattern — Query External, Load Hot Data to Internal

Best of both worlds: Keep all data in your data lake (external table), but load frequently-queried recent data into an internal table.

```sql
-- Internal table: last 90 days of hot data (fast queries)
CREATE TABLE DEMO_DB.PUBLIC.ORDERS_HOT AS
SELECT ORDER_ID, CUSTOMER_ID, ORDER_DATE, AMOUNT, REGION, STATUS
FROM DEMO_DB.PUBLIC.ORDERS_EXTERNAL
WHERE ORDER_DATE >= DATEADD('DAY', -90, CURRENT_DATE());

-- External table: everything (cold historical data)
SELECT * FROM DEMO_DB.PUBLIC.ORDERS_EXTERNAL
WHERE ORDER_DATE < DATEADD('DAY', -90, CURRENT_DATE());

-- Union view for seamless access:
CREATE VIEW DEMO_DB.PUBLIC.V_ORDERS_ALL AS
SELECT * FROM DEMO_DB.PUBLIC.ORDERS_HOT
UNION ALL
SELECT ORDER_ID, CUSTOMER_ID, ORDER_DATE, AMOUNT, REGION, STATUS
FROM DEMO_DB.PUBLIC.ORDERS_EXTERNAL
WHERE ORDER_DATE < DATEADD('DAY', -90, CURRENT_DATE());
```

---

## Part 6: Performance Comparison

| Operation | Internal Table | External Table |
|-----------|---------------|----------------|
| Simple SELECT (filtered, 1M rows) | ~0.5 - 2 seconds | ~5 - 30 seconds |
| Aggregation query (SUM/COUNT, 10M rows) | ~1 - 5 seconds | ~10 - 60 seconds |
| JOIN with dimension (100M fact rows) | ~2 - 10 seconds | ~30 - 120 seconds |
| Repeated same query | ~0.1 sec (cached) | ~5 - 30 sec (no persistent cache) |

**Why the difference?**
- **Internal:** Data in Snowflake's optimized micro-partitions with metadata, local SSD cache, result cache. Partition pruning skips irrelevant data.
- **External:** Each query must reach out to remote S3/Azure/GCS, read raw files, parse them, and process. No local caching of data files. Partition pruning only works if you defined partitions.

---

## Part 7: Also Consider — Iceberg Tables

If you need the **best of both worlds**, consider Iceberg tables:

- Data stays in **YOUR storage** (like external tables)
- But supports **ACID transactions**
- **Schema evolution** built-in
- Snowflake-managed catalog for **better performance**
- Works with **Spark, Presto, Trino** simultaneously
- **Better query performance** than external tables
- Supports **DML** (INSERT, UPDATE, DELETE, MERGE)

> Snowflake recommends Iceberg tables over external tables for new workloads where data must reside in your storage.

---

## Summary: Decision Flowchart

```
Does data need to stay in YOUR cloud storage?
  │
  ├── NO  -> Use INTERNAL TABLE (best performance, full features)
  │
  └── YES -> Do you need DML (INSERT/UPDATE/DELETE)?
              │
              ├── NO  -> Use EXTERNAL TABLE (read-only, simple)
              │          Add materialized views for performance
              │
              └── YES -> Use ICEBERG TABLE (open format + DML + ACID)
```
