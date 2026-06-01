# Hybrid Tables, Directory Tables & Event Tables — Complete Practical Guide

---

## Table of Contents

1. [Hybrid Tables](#hybrid-tables)
2. [Directory Tables](#directory-tables)
3. [Event Tables](#event-tables)
4. [Comparison Summary](#comparison-summary)

---

## Hybrid Tables

### What is a Hybrid Table?

A hybrid table is a Snowflake table type optimized for **low-latency, high-throughput transactional workloads** using index-based random reads and writes. It combines OLTP (transactional) and OLAP (analytical) capabilities in a single platform — known as **Unistore**.

### Architecture

- **Primary storage**: Row-oriented (row store) for fast point lookups and writes
- **Secondary storage**: Data is asynchronously copied to columnar object storage for analytical scans
- **Locking**: Row-level (not table/partition-level like standard tables)
- **Constraints**: PRIMARY KEY (required, enforced), FOREIGN KEY (enforced), UNIQUE (enforced), NOT NULL (enforced)

### When to Use Hybrid Tables

| Use Case | Why Hybrid Table |
|----------|-----------------|
| Application metadata / state management | High-concurrency single-row updates from many workers |
| Low-latency API serving | Precomputed aggregates served with sub-second reads |
| Lightweight transactional apps | Relational data models with referential integrity |
| User profiles / session stores | Fast point lookups by ID |
| Inventory / reservation systems | Row-level locking prevents conflicts |
| Config / feature flag stores | Frequent reads + occasional writes |

### When NOT to Use Hybrid Tables

| Scenario | Use Instead |
|----------|-------------|
| Bulk analytical scans (millions of rows) | Standard tables |
| Append-heavy ingestion (Snowpipe, COPY INTO) | Standard tables |
| Time-series / event logging | Standard tables or Event tables |
| Large data warehouse fact tables | Standard tables |
| Cost-sensitive large storage | Standard tables (better compression) |

### Key Differences: Hybrid vs Standard

| Feature | Hybrid Table | Standard Table |
|---------|-------------|----------------|
| Storage layout | Row-oriented (primary) + columnar (secondary) | Columnar micro-partitions |
| Locking | Row-level | Partition/table-level |
| PRIMARY KEY | Required, enforced | Optional, not enforced |
| FOREIGN KEY | Optional, enforced | Optional, not enforced |
| UNIQUE | Optional, enforced | Optional, not enforced |
| Indexes | Supported (secondary indexes) | Search optimization service |
| Best for | Point reads/writes, transactions | Large scans, aggregations |
| Storage footprint | Larger (less compression) | Smaller (columnar compression) |

### Syntax

```sql
CREATE [ OR REPLACE ] HYBRID TABLE <table_name> (
    <col_name> <data_type> [ NOT NULL ] [ UNIQUE ],
    ...
    PRIMARY KEY (<col_name> [, ...]),
    [ FOREIGN KEY (<col_name>) REFERENCES <parent_table>(<col_name>) ],
    [ INDEX <index_name> (<col_name> [, ...]) ]
);
```

### Practical Example: E-Commerce Order System

```sql
-- Step 1: Create a hybrid table for products (dimension)
CREATE OR REPLACE HYBRID TABLE products (
    product_id INT NOT NULL,
    name STRING NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    stock_quantity INT DEFAULT 0,
    PRIMARY KEY (product_id)
);

-- Step 2: Create a hybrid table for orders (transactional)
CREATE OR REPLACE HYBRID TABLE orders (
    order_id INT NOT NULL,
    product_id INT NOT NULL,
    customer_id INT NOT NULL,
    quantity INT NOT NULL,
    order_status STRING DEFAULT 'PENDING',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    PRIMARY KEY (order_id),
    FOREIGN KEY (product_id) REFERENCES products(product_id),
    INDEX idx_customer (customer_id),
    INDEX idx_status (order_status)
);

-- Step 3: Insert products
INSERT INTO products VALUES
    (1, 'Laptop', 999.99, 50),
    (2, 'Mouse', 29.99, 500),
    (3, 'Keyboard', 79.99, 200);

-- Step 4: Place an order (transactional - with FK enforcement)
INSERT INTO orders (order_id, product_id, customer_id, quantity)
VALUES (1001, 1, 42, 2);

-- Step 5: This FAILS — FK violation (product_id 999 doesn't exist)
INSERT INTO orders (order_id, product_id, customer_id, quantity)
VALUES (1002, 999, 42, 1);
-- Error: Foreign key constraint was violated

-- Step 6: Concurrent updates with row-level locking
BEGIN;
UPDATE orders SET order_status = 'SHIPPED' WHERE order_id = 1001;
-- Another session can simultaneously update a DIFFERENT order without waiting
COMMIT;

-- Step 7: Reduce stock (atomic transaction across tables)
BEGIN;
UPDATE products SET stock_quantity = stock_quantity - 2 WHERE product_id = 1;
UPDATE orders SET order_status = 'CONFIRMED' WHERE order_id = 1001;
COMMIT;

-- Step 8: Fast point lookup by primary key (sub-millisecond)
SELECT * FROM orders WHERE order_id = 1001;

-- Step 9: Index-based lookup
SELECT * FROM orders WHERE customer_id = 42;

-- Step 10: Join hybrid table with standard table for analytics
SELECT
    o.order_id,
    p.name AS product_name,
    o.quantity,
    o.quantity * p.price AS total_amount
FROM orders o
JOIN products p ON o.product_id = p.product_id
WHERE o.order_status = 'CONFIRMED';
```

### UNIQUE Constraint Example

```sql
-- UNIQUE constraint prevents duplicate emails
CREATE OR REPLACE HYBRID TABLE users (
    user_id INT NOT NULL,
    email STRING NOT NULL UNIQUE,
    username STRING NOT NULL,
    PRIMARY KEY (user_id)
);

INSERT INTO users VALUES (1, 'alice@example.com', 'alice');

-- This FAILS — duplicate email
INSERT INTO users VALUES (2, 'alice@example.com', 'alice2');
-- Error: Duplicate key value violates unique constraint
```

### Limitations

- Available only in AWS and Azure commercial regions
- Cannot be cloned or replicated
- No Time Travel beyond 1 day
- No clustering keys
- Larger storage footprint than standard tables
- No support for external tables or materialized views on hybrid tables
- Cannot be used as targets for Snowpipe or COPY INTO with notifications

---

## Directory Tables

### What is a Directory Table?

A directory table is an **implicit metadata layer on a stage** (not a standalone database object). It stores file-level metadata about data files in the stage — similar to a file system index.

### Architecture

- Not a separate database object — layered on top of a stage
- Stores metadata: file path, size, last modified timestamp, MD5 hash, ETag, file URL
- Supports both internal and external stages
- Metadata must be refreshed (manually or automatically) to stay in sync

### When to Use Directory Tables

| Use Case | Why Directory Table |
|----------|-------------------|
| Querying list of files on a stage | Get metadata without listing files manually |
| Building unstructured data pipelines | Process images, PDFs, videos via file URLs |
| Creating views joining file metadata with business data | Combine file URLs with relational metadata |
| File inventory management | Track what's on a stage with size/timestamp |
| ML model input catalogs | Index training data files on stages |
| Document management systems | Query documents with metadata |

### When NOT to Use Directory Tables

| Scenario | Use Instead |
|----------|-------------|
| Structured data loading/querying | Standard tables with COPY INTO |
| Real-time streaming ingestion | Snowpipe + standard tables |
| Transactional file operations | Hybrid tables for metadata |
| Version control of files | External versioning systems |

### Columns Available in Directory Tables

| Column | Type | Description |
|--------|------|-------------|
| RELATIVE_PATH | TEXT | Path to the file relative to the stage |
| SIZE | NUMBER | File size in bytes |
| LAST_MODIFIED | TIMESTAMP_TZ | When file was last updated |
| MD5 | HEX | MD5 checksum |
| ETAG | HEX | ETag header |
| FILE_URL | TEXT | Snowflake file URL for accessing the file |

### Syntax

```sql
-- Create a stage with directory table enabled
CREATE [ OR REPLACE ] STAGE <stage_name>
    [ URL = '<cloud_storage_url>' ]
    DIRECTORY = (
        ENABLE = TRUE
        [ AUTO_REFRESH = TRUE ]
    );

-- Enable directory table on existing stage
ALTER STAGE <stage_name> SET DIRECTORY = ( ENABLE = TRUE );

-- Query the directory table
SELECT * FROM DIRECTORY( @<stage_name> );

-- Refresh metadata manually
ALTER STAGE <stage_name> REFRESH;
```

### Practical Example: Document Processing Pipeline

```sql
-- Step 1: Create an internal stage with directory table enabled
CREATE OR REPLACE STAGE document_stage
    DIRECTORY = (ENABLE = TRUE, AUTO_REFRESH = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Step 2: Upload files (via PUT command or Snowsight UI)
-- PUT file:///local/path/invoice_001.pdf @document_stage/invoices/;
-- PUT file:///local/path/contract_A.pdf @document_stage/contracts/;

-- Step 3: Query all files on the stage
SELECT * FROM DIRECTORY(@document_stage);

-- Step 4: Filter by file type
SELECT
    RELATIVE_PATH,
    SIZE,
    LAST_MODIFIED,
    FILE_URL
FROM DIRECTORY(@document_stage)
WHERE RELATIVE_PATH LIKE '%.pdf';

-- Step 5: Find large files (over 1 MB)
SELECT
    RELATIVE_PATH,
    ROUND(SIZE / 1024 / 1024, 2) AS size_mb,
    LAST_MODIFIED
FROM DIRECTORY(@document_stage)
WHERE SIZE > 1048576
ORDER BY SIZE DESC;

-- Step 6: Create a metadata table for business context
CREATE OR REPLACE TABLE document_metadata (
    file_url STRING,
    document_type STRING,
    department STRING,
    uploaded_by STRING,
    upload_date DATE
);

INSERT INTO document_metadata VALUES
    ('https://account.snowflakecomputing.com/api/files/db.schema.document_stage/invoices/invoice_001.pdf',
     'invoice', 'finance', 'john', '2025-01-15'),
    ('https://account.snowflakecomputing.com/api/files/db.schema.document_stage/contracts/contract_A.pdf',
     'contract', 'legal', 'sarah', '2025-02-01');

-- Step 7: Join directory table with metadata for a unified view
CREATE OR REPLACE VIEW document_catalog AS
SELECT
    d.RELATIVE_PATH,
    d.SIZE,
    d.LAST_MODIFIED,
    d.FILE_URL,
    m.document_type,
    m.department,
    m.uploaded_by
FROM DIRECTORY(@document_stage) d
LEFT JOIN document_metadata m ON d.FILE_URL = m.file_url;

SELECT * FROM document_catalog;
```

### External Stage with Directory Table (S3)

```sql
-- Create external stage pointing to S3
CREATE OR REPLACE STAGE ext_data_stage
    URL = 's3://my-bucket/data-files/'
    STORAGE_INTEGRATION = my_s3_integration
    DIRECTORY = (
        ENABLE = TRUE,
        AUTO_REFRESH = TRUE
    );

-- Query files from external stage
SELECT
    RELATIVE_PATH,
    SIZE,
    LAST_MODIFIED
FROM DIRECTORY(@ext_data_stage)
ORDER BY LAST_MODIFIED DESC;

-- Find files added in the last 7 days
SELECT *
FROM DIRECTORY(@ext_data_stage)
WHERE LAST_MODIFIED > DATEADD(DAY, -7, CURRENT_TIMESTAMP());
```

### Auto-Refresh vs Manual Refresh

| Method | How | Best For |
|--------|-----|----------|
| Auto-Refresh | Event notifications (SQS, Pub/Sub, Event Grid) | Production pipelines with frequent file changes |
| Manual Refresh | `ALTER STAGE <name> REFRESH` | Ad-hoc stages, infrequent changes |

### Billing

- Auto-refresh overhead appears as Snowpipe charges (uses event notifications)
- Manual refresh overhead charged via cloud services billing model
- Query `PIPE_USAGE_HISTORY` to monitor auto-refresh costs

### Access Control

| Operation | Required Privilege |
|-----------|-------------------|
| SELECT from directory table (internal stage) | READ on stage |
| SELECT from directory table (external stage) | READ or USAGE on stage |
| Upload files (PUT) | WRITE on stage |
| Remove files (REMOVE) | WRITE on stage (internal) or WRITE/USAGE (external) |
| Refresh metadata (ALTER STAGE REFRESH) | WRITE on stage (internal) or WRITE/USAGE (external) |

---

## Event Tables

### What is an Event Table?

An event table is a **special Snowflake table with predefined columns** designed to collect telemetry data (logs, metrics, traces) from UDFs, stored procedures, Streamlit apps, and other Snowflake executables. It follows the **OpenTelemetry** data model.

### Architecture

- Predefined schema — you do NOT specify columns when creating it
- Follows OpenTelemetry (OTel) standard for telemetry data
- Default event table: `SNOWFLAKE.TELEMETRY.EVENTS` (active by default)
- Can be associated at account level or database level
- Database-level association takes precedence over account-level

### When to Use Event Tables

| Use Case | Why Event Table |
|----------|----------------|
| Debugging UDFs and stored procedures | Capture log messages from handler code |
| Performance monitoring | CPU/memory metrics collected automatically |
| Distributed tracing | See execution flow across procedures |
| Production observability | Detect errors, latency, resource issues |
| Audit UDF execution | Track who ran what and when |
| Native App monitoring | Provider visibility into consumer-side execution |

### When NOT to Use Event Tables

| Scenario | Use Instead |
|----------|-------------|
| Business event logging (orders, clicks) | Standard tables |
| Change data capture | Streams + dynamic tables |
| Application state storage | Hybrid tables |
| File metadata tracking | Directory tables |
| Data quality monitoring | DMF (Data Metric Functions) |

### Predefined Columns

| Column | Type | Description |
|--------|------|-------------|
| TIMESTAMP | TIMESTAMP_NTZ | When event was created (UTC) |
| START_TIMESTAMP | TIMESTAMP_NTZ | For spans: when execution started |
| OBSERVED_TIMESTAMP | TIMESTAMP_NTZ | Same as TIMESTAMP (for logs) |
| TRACE | OBJECT | Contains trace_id and span_id |
| RESOURCE_ATTRIBUTES | OBJECT | Source info: database, schema, user, warehouse |
| SCOPE | OBJECT | Namespace of code emitting the event |
| RECORD_TYPE | STRING | LOG, SPAN, SPAN_EVENT, METRIC, or EVENT |
| RECORD | OBJECT | Core event data (severity, name, kind) |
| RECORD_ATTRIBUTES | OBJECT | Variable metadata (code location, custom attributes) |
| VALUE | VARIANT | Log message, metric value, or event payload |

### Record Types Explained

| RECORD_TYPE | What It Captures | Generated By |
|-------------|-----------------|--------------|
| LOG | Individual log messages | Your handler code (Python logging, Java SLF4J) |
| SPAN | Execution duration of a function/procedure | Snowflake automatically |
| SPAN_EVENT | Named events within a span | Your handler code (trace events) |
| METRIC | CPU and memory measurements | Snowflake automatically |
| EVENT | Operation events (e.g., Iceberg auto-refresh) | Snowflake automatically |

### Syntax

```sql
-- Create a custom event table
CREATE [ OR REPLACE ] EVENT TABLE <database>.<schema>.<name>;

-- Set event table for the account
ALTER ACCOUNT SET EVENT_TABLE = <database>.<schema>.<name>;

-- Set event table for a specific database
ALTER DATABASE <db_name> SET EVENT_TABLE = <database>.<schema>.<name>;

-- Set telemetry levels
ALTER DATABASE <db_name> SET LOG_LEVEL = 'INFO';
ALTER DATABASE <db_name> SET TRACE_LEVEL = 'ON_EVENT';
```

### Practical Example: Full Observability Setup

```sql
-- Step 1: Create a custom event table
CREATE OR REPLACE EVENT TABLE my_db.observability.app_events;

-- Step 2: Associate with a database
ALTER DATABASE my_db SET EVENT_TABLE = my_db.observability.app_events;

-- Step 3: Set telemetry levels
ALTER DATABASE my_db SET LOG_LEVEL = 'INFO';
ALTER DATABASE my_db SET TRACE_LEVEL = 'ON_EVENT';

-- Step 4: Create a procedure that emits logs
CREATE OR REPLACE PROCEDURE my_db.public.process_order(order_id INT)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import logging

logger = logging.getLogger('order_processor')

def run(session, order_id):
    logger.info(f"Processing order: {order_id}")

    try:
        result = session.sql(f"SELECT * FROM orders WHERE id = {order_id}").collect()
        if not result:
            logger.warning(f"Order not found: {order_id}")
            return "NOT_FOUND"

        logger.info(f"Order {order_id} processed successfully")
        return "SUCCESS"
    except Exception as e:
        logger.error(f"Failed to process order {order_id}: {str(e)}")
        raise
$$;

-- Step 5: Execute the procedure
CALL my_db.public.process_order(12345);

-- Step 6: Query log messages
SELECT
    TIMESTAMP,
    VALUE AS log_message,
    RECORD:severity_text::STRING AS severity,
    RESOURCE_ATTRIBUTES:snow.executable.name::STRING AS procedure_name,
    RESOURCE_ATTRIBUTES:db.user::STRING AS executed_by
FROM my_db.observability.app_events
WHERE RECORD_TYPE = 'LOG'
ORDER BY TIMESTAMP DESC
LIMIT 20;

-- Step 7: Query execution spans (duration analysis)
SELECT
    RESOURCE_ATTRIBUTES:snow.executable.name::STRING AS executable,
    RESOURCE_ATTRIBUTES:snow.query.id::STRING AS query_id,
    START_TIMESTAMP,
    TIMESTAMP AS end_timestamp,
    DATEDIFF('millisecond', START_TIMESTAMP, TIMESTAMP) AS duration_ms
FROM my_db.observability.app_events
WHERE RECORD_TYPE = 'SPAN'
ORDER BY TIMESTAMP DESC;

-- Step 8: Query metrics (CPU and memory)
SELECT
    TIMESTAMP,
    RECORD:metric.name::STRING AS metric_name,
    VALUE::NUMBER AS metric_value,
    RECORD:metric.unit::STRING AS unit,
    RESOURCE_ATTRIBUTES:snow.executable.name::STRING AS executable
FROM my_db.observability.app_events
WHERE RECORD_TYPE = 'METRIC'
ORDER BY TIMESTAMP DESC;

-- Step 9: Find errors
SELECT
    TIMESTAMP,
    VALUE AS error_message,
    RECORD_ATTRIBUTES:exception.type::STRING AS exception_type,
    RECORD_ATTRIBUTES:exception.stacktrace::STRING AS stacktrace,
    RESOURCE_ATTRIBUTES:snow.query.id::STRING AS query_id
FROM my_db.observability.app_events
WHERE RECORD_TYPE = 'LOG'
  AND RECORD:severity_text::STRING IN ('ERROR', 'FATAL')
ORDER BY TIMESTAMP DESC;

-- Step 10: Execution frequency by procedure (last 24 hours)
SELECT
    RESOURCE_ATTRIBUTES:snow.executable.name::STRING AS procedure_name,
    COUNT(*) AS execution_count,
    AVG(DATEDIFF('ms', START_TIMESTAMP, TIMESTAMP)) AS avg_duration_ms,
    MAX(DATEDIFF('ms', START_TIMESTAMP, TIMESTAMP)) AS max_duration_ms
FROM my_db.observability.app_events
WHERE RECORD_TYPE = 'SPAN'
  AND TIMESTAMP > DATEADD(HOUR, -24, CURRENT_TIMESTAMP())
GROUP BY 1
ORDER BY execution_count DESC;
```

### Using the Default Event Table

```sql
-- Query the default event table directly (requires ACCOUNTADMIN or EVENTS_ADMIN)
SELECT * FROM SNOWFLAKE.TELEMETRY.EVENTS
WHERE TIMESTAMP > DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
LIMIT 100;

-- Use the safer EVENTS_VIEW (can be shared via EVENTS_VIEWER role)
SELECT * FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'LOG'
  AND RECORD:severity_text::STRING = 'ERROR'
ORDER BY TIMESTAMP DESC;

-- Grant access to other roles
GRANT APPLICATION ROLE SNOWFLAKE.EVENTS_VIEWER TO ROLE analyst_role;
GRANT APPLICATION ROLE SNOWFLAKE.EVENTS_ADMIN TO ROLE admin_role;
```

### Telemetry Levels

| Level Type | Values | Controls |
|-----------|--------|----------|
| LOG_LEVEL | TRACE, DEBUG, INFO, WARN, ERROR, FATAL, OFF | Which log messages are captured |
| TRACE_LEVEL | ALWAYS, ON_EVENT, OFF | Whether trace spans/events are captured |
| METRIC_LEVEL | ALL, NONE | Whether CPU/memory metrics are captured |

```sql
-- Set at different scopes (narrower scope takes precedence)
ALTER ACCOUNT SET LOG_LEVEL = 'WARN';
ALTER DATABASE my_db SET LOG_LEVEL = 'INFO';
ALTER PROCEDURE my_db.public.critical_proc(INT) SET LOG_LEVEL = 'DEBUG';
```

### Cost Considerations

- Event tables incur storage costs (like any table)
- Auto-generated metrics increase storage without code changes
- High-volume UDFs can generate millions of log entries
- Best practice: Use WARN level in production, lower only for debugging
- Use `TRUNCATE` or retention policies to manage growth

---

## Comparison Summary

| Aspect | Hybrid Table | Directory Table | Event Table |
|--------|-------------|-----------------|-------------|
| **What it is** | Row-store transactional table | Metadata layer on a stage | Telemetry collection table |
| **Primary purpose** | Low-latency OLTP workloads | File inventory & URLs | Logging, tracing, metrics |
| **Created via** | `CREATE HYBRID TABLE` | `DIRECTORY = (ENABLE=TRUE)` on stage | `CREATE EVENT TABLE` |
| **Schema** | User-defined columns | Predefined (path, size, URL, etc.) | Predefined (OpenTelemetry) |
| **Data source** | DML operations (INSERT/UPDATE/DELETE) | Files on stages | UDFs, procedures, Snowflake internals |
| **Constraints** | PK required, FK/UNIQUE enforced | None | None |
| **Availability** | AWS + Azure commercial regions | All regions | All regions |
| **Typical users** | Application developers | Data engineers, ML engineers | DevOps, platform engineers |
| **Query pattern** | Point lookups, small writes | File discovery, JOIN with tables | Log analysis, debugging |
| **Cost driver** | Row store storage + compute | Event notifications (auto-refresh) | Storage for telemetry data |

### Decision Matrix: Which Table Type to Use?

```
Is it transactional data needing referential integrity?
├── YES → HYBRID TABLE
│
Is it metadata about files on a stage?
├── YES → DIRECTORY TABLE
│
Is it telemetry/observability data from code execution?
├── YES → EVENT TABLE
│
Is it analytical/warehouse data?
└── YES → STANDARD TABLE
```
