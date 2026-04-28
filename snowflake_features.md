# Snowflake Complete Features Guide
## All Major Features Explained with Simple Examples

### Key Snowflake Highlights

1. Major cloud platform support
2. Unlimited storage and compute
3. Data platform as a service
4. Unique 3-layer architecture
5. Virtual warehouses
6. Support for structured and unstructured data
7. Time travel and fail-safe
8. Clone or zero-copy clone
9. Continuous data loading via Snowpipe and connectors
10. Support for ANSI SQL + extended SQL
11. Micro-partitions and data clustering
12. Data encryption and security
13. RBAC and DAC
14. Data sharing and reader account
15. Data replication and failover
16. Connectors and drivers
17. Partner connect
18. Data marketplace

---

## 1. Virtual Warehouses (Compute Engine)

Virtual warehouses provide the compute resources for queries and DML. They can be started, stopped, and resized independently.

```sql
CREATE WAREHOUSE my_warehouse
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 3
    SCALING_POLICY = 'STANDARD';

ALTER WAREHOUSE my_warehouse SET WAREHOUSE_SIZE = 'MEDIUM';
ALTER WAREHOUSE my_warehouse SUSPEND;
ALTER WAREHOUSE my_warehouse RESUME;
```

---

## 2. Databases and Schemas

Databases are top-level containers. Schemas organize objects within databases.

```sql
CREATE DATABASE sales_db;
CREATE SCHEMA sales_db.retail_schema;

CREATE TABLE sales_db.retail_schema.orders (
    order_id INT,
    customer_name STRING,
    amount DECIMAL(10,2),
    order_date DATE
);

INSERT INTO sales_db.retail_schema.orders VALUES
    (1, 'Alice', 250.00, '2025-01-15'),
    (2, 'Bob', 180.50, '2025-01-16'),
    (3, 'Charlie', 320.75, '2025-01-17');
```

---

## 3. Time Travel

Access historical data at any point within a retention period (up to 90 days).

```sql
CREATE TABLE demo_time_travel (id INT, name STRING)
    DATA_RETENTION_TIME_IN_DAYS = 7;

INSERT INTO demo_time_travel VALUES (1, 'Original');
UPDATE demo_time_travel SET name = 'Modified' WHERE id = 1;

-- Query data as it was 5 minutes ago
SELECT * FROM demo_time_travel AT(OFFSET => -60*5);

-- Query data at a specific timestamp
SELECT * FROM demo_time_travel AT(TIMESTAMP => '2025-01-15 10:00:00'::TIMESTAMP);

-- Restore a dropped table
DROP TABLE demo_time_travel;
UNDROP TABLE demo_time_travel;
```

---

## 4. Zero-Copy Cloning

Create instant copies of databases, schemas, or tables without duplicating data.

```sql
CREATE TABLE original_table (id INT, value STRING);
INSERT INTO original_table VALUES (1, 'data1'), (2, 'data2');

CREATE TABLE cloned_table CLONE original_table;

-- Clone an entire database
CREATE DATABASE cloned_db CLONE sales_db;

-- Clone an entire schema
CREATE SCHEMA cloned_schema CLONE sales_db.retail_schema;
```

---

## 5. Fail-Safe

7-day non-configurable recovery period after Time Travel expires. Snowflake support can recover data during this window. No user-accessible SQL -- this is an automatic protection layer.

```sql
-- Check data retention and fail-safe status
SHOW TABLES LIKE 'orders' IN SCHEMA sales_db.retail_schema;
```

---

## 6. Table Types

```sql
-- Permanent Table (default) -- full Time Travel + Fail-Safe
CREATE TABLE permanent_tbl (id INT, data STRING);

-- Transient Table -- Time Travel only (0 or 1 day), no Fail-Safe
CREATE TRANSIENT TABLE transient_tbl (id INT, data STRING);

-- Temporary Table -- session-scoped, auto-dropped at session end
CREATE TEMPORARY TABLE temp_tbl (id INT, data STRING);

-- External Table -- reads data from external stages (S3, GCS, Azure)
CREATE EXTERNAL TABLE ext_tbl (...)
    LOCATION = @my_stage
    FILE_FORMAT = (TYPE = 'PARQUET');

-- Iceberg Table -- open table format with external catalog support
CREATE ICEBERG TABLE ice_tbl (...)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'my_vol'
    BASE_LOCATION = 'ice/';
```

---

## 7. Views

```sql
-- Standard View -- stored query, no data storage
CREATE VIEW active_orders AS
    SELECT * FROM sales_db.retail_schema.orders WHERE amount > 200;

-- Secure View -- hides definition from unauthorized users
CREATE SECURE VIEW secure_orders AS
    SELECT order_id, amount FROM sales_db.retail_schema.orders;

-- Materialized View -- pre-computed and auto-maintained
CREATE MATERIALIZED VIEW mv_order_summary AS
    SELECT order_date, SUM(amount) AS total_amount
    FROM sales_db.retail_schema.orders
    GROUP BY order_date;
```

---

## 8. Stages (Data Loading/Unloading)

```sql
-- Internal Stage (Snowflake-managed storage)
CREATE STAGE my_internal_stage;

-- Named External Stage (pointing to cloud storage)
CREATE STAGE my_s3_stage
    URL = 's3://my-bucket/path/'
    CREDENTIALS = (AWS_KEY_ID='...' AWS_SECRET_KEY='...');

-- List files in a stage
LIST @my_internal_stage;

-- File Formats
CREATE FILE FORMAT csv_format
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1;

CREATE FILE FORMAT json_format
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE;

CREATE FILE FORMAT parquet_format
    TYPE = 'PARQUET';
```

---

## 9. Data Loading (COPY INTO)

```sql
-- Load data from stage into table
COPY INTO sales_db.retail_schema.orders
    FROM @my_internal_stage/orders.csv
    FILE_FORMAT = (FORMAT_NAME = csv_format);

-- Load JSON data
COPY INTO json_table
    FROM @my_internal_stage/data.json
    FILE_FORMAT = (TYPE = 'JSON');

-- Snowpipe: continuous auto-loading
CREATE PIPE my_pipe AUTO_INGEST = TRUE AS
    COPY INTO orders FROM @my_s3_stage FILE_FORMAT = csv_format;
```

---

## 10. Data Unloading (COPY INTO Stage)

```sql
-- Unload table data to a stage
COPY INTO @my_internal_stage/export/
    FROM sales_db.retail_schema.orders
    FILE_FORMAT = (TYPE = 'CSV' HEADER = TRUE);
```

---

## 11. Streams (Change Data Capture)

Streams track DML changes (inserts, updates, deletes) on a table.

```sql
CREATE TABLE products (id INT, name STRING, price DECIMAL(10,2));
INSERT INTO products VALUES (1, 'Laptop', 999.99), (2, 'Mouse', 29.99);

CREATE STREAM product_changes ON TABLE products;

-- Make changes
INSERT INTO products VALUES (3, 'Keyboard', 79.99);
UPDATE products SET price = 899.99 WHERE id = 1;
DELETE FROM products WHERE id = 2;

-- Query the stream to see all changes
SELECT * FROM product_changes;
-- Shows: INSERT for id=3, UPDATE for id=1, DELETE for id=2
-- Columns: METADATA$ACTION, METADATA$ISUPDATE, METADATA$ROW_ID
```

---

## 12. Tasks (Scheduling)

Tasks schedule SQL statements on a cron or interval basis.

```sql
CREATE TASK daily_summary_task
    WAREHOUSE = my_warehouse
    SCHEDULE = 'USING CRON 0 8 * * * America/New_York'
AS
    INSERT INTO daily_summary
    SELECT CURRENT_DATE(), COUNT(*), SUM(amount)
    FROM sales_db.retail_schema.orders
    WHERE order_date = CURRENT_DATE();

-- Tasks are created in suspended state; must be resumed
ALTER TASK daily_summary_task RESUME;

-- Task with interval (every 10 minutes)
CREATE TASK frequent_task
    WAREHOUSE = my_warehouse
    SCHEDULE = '10 MINUTE'
AS
    CALL my_stored_procedure();

-- Task Trees (parent -> child dependencies)
CREATE TASK child_task
    WAREHOUSE = my_warehouse
    AFTER daily_summary_task
AS
    CALL post_summary_cleanup();
```

---

## 13. Dynamic Tables

Declarative data pipelines -- Snowflake auto-refreshes based on a target lag.

```sql
CREATE DYNAMIC TABLE order_aggregates
    TARGET_LAG = '10 minutes'
    WAREHOUSE = my_warehouse
AS
    SELECT
        customer_name,
        COUNT(*) AS order_count,
        SUM(amount) AS total_spent
    FROM sales_db.retail_schema.orders
    GROUP BY customer_name;

-- Query like a regular table; Snowflake keeps it fresh
SELECT * FROM order_aggregates;
```

---

## 14. Stored Procedures

```sql
-- SQL Stored Procedure
CREATE OR REPLACE PROCEDURE greet(name STRING)
    RETURNS STRING
    LANGUAGE SQL
AS
BEGIN
    RETURN 'Hello, ' || name || '!';
END;

CALL greet('Snowflake');

-- JavaScript Stored Procedure
CREATE OR REPLACE PROCEDURE add_numbers(a FLOAT, b FLOAT)
    RETURNS FLOAT
    LANGUAGE JAVASCRIPT
AS
$$
    return A + B;
$$;

CALL add_numbers(10, 20);
```

---

## 15. User-Defined Functions (UDFs)

```sql
-- SQL UDF
CREATE FUNCTION celsius_to_fahrenheit(c FLOAT)
    RETURNS FLOAT
AS
$$
    c * 9/5 + 32
$$;

SELECT celsius_to_fahrenheit(100); -- Returns 212

-- Python UDF
CREATE OR REPLACE FUNCTION reverse_string(s STRING)
    RETURNS STRING
    LANGUAGE PYTHON
    RUNTIME_VERSION = '3.11'
    HANDLER = 'reverse_it'
AS
$$
def reverse_it(s):
    return s[::-1]
$$;

SELECT reverse_string('Snowflake'); -- Returns 'ekalfwonS'

-- Table Function (UDTF)
CREATE FUNCTION split_to_rows(input STRING, delim STRING)
    RETURNS TABLE(val STRING)
    LANGUAGE SQL
AS
$$
    SELECT VALUE::STRING AS val
    FROM TABLE(SPLIT_TO_TABLE(input, delim))
$$;

SELECT * FROM TABLE(split_to_rows('a,b,c', ','));
```

---

## 16. Semi-Structured Data (VARIANT, OBJECT, ARRAY)

```sql
CREATE TABLE events (
    event_id INT,
    event_data VARIANT
);

INSERT INTO events SELECT 1, PARSE_JSON('{
    "user": "alice",
    "action": "login",
    "details": {"ip": "192.168.1.1", "browser": "Chrome"},
    "tags": ["web", "auth"]
}');

-- Access nested fields
SELECT
    event_data:user::STRING AS user_name,
    event_data:details.ip::STRING AS ip_address,
    event_data:tags[0]::STRING AS first_tag
FROM events;

-- Flatten arrays
SELECT f.value::STRING AS tag
FROM events, LATERAL FLATTEN(input => event_data:tags) f;
```

---

## 17. Role-Based Access Control (RBAC)

```sql
CREATE ROLE analyst_role;
CREATE ROLE data_engineer_role;

GRANT USAGE ON WAREHOUSE my_warehouse TO ROLE analyst_role;
GRANT USAGE ON DATABASE sales_db TO ROLE analyst_role;
GRANT USAGE ON SCHEMA sales_db.retail_schema TO ROLE analyst_role;
GRANT SELECT ON ALL TABLES IN SCHEMA sales_db.retail_schema TO ROLE analyst_role;

GRANT ROLE analyst_role TO USER some_user;

-- Hierarchy: child roles inherit parent privileges
GRANT ROLE analyst_role TO ROLE data_engineer_role;
```

---

## 18. Data Sharing (Secure Data Sharing)

Share data with other Snowflake accounts without copying.

```sql
CREATE SHARE orders_share;
GRANT USAGE ON DATABASE sales_db TO SHARE orders_share;
GRANT USAGE ON SCHEMA sales_db.retail_schema TO SHARE orders_share;
GRANT SELECT ON TABLE sales_db.retail_schema.orders TO SHARE orders_share;

-- Add consumer account
ALTER SHARE orders_share ADD ACCOUNTS = consumer_account;

-- Consumer side: create database from share
CREATE DATABASE shared_orders FROM SHARE provider_account.orders_share;
```

---

## 19. Masking Policies (Dynamic Data Masking)

```sql
CREATE MASKING POLICY mask_email AS (val STRING)
    RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('ADMIN') THEN val
        ELSE '***MASKED***'
    END;

ALTER TABLE sales_db.retail_schema.orders
    MODIFY COLUMN customer_name
    SET MASKING POLICY mask_email;
```

---

## 20. Row Access Policies

```sql
CREATE ROW ACCESS POLICY region_policy AS (region STRING)
    RETURNS BOOLEAN ->
    CURRENT_ROLE() = 'ADMIN'
    OR region = CURRENT_ROLE();

ALTER TABLE regional_sales ADD ROW ACCESS POLICY region_policy ON (region);
```

---

## 21. Tags and Tag-Based Policies

```sql
CREATE TAG sensitivity ALLOWED_VALUES 'PII', 'CONFIDENTIAL', 'PUBLIC';

ALTER TABLE sales_db.retail_schema.orders
    SET TAG sensitivity = 'PII';

ALTER TABLE sales_db.retail_schema.orders
    MODIFY COLUMN customer_name
    SET TAG sensitivity = 'PII';

-- Query tags
SELECT * FROM TABLE(INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
    'sales_db.retail_schema.orders', 'TABLE'));
```

---

## 22. Resource Monitors

Control credit consumption with alerts and actions.

```sql
CREATE RESOURCE MONITOR monthly_monitor
    WITH CREDIT_QUOTA = 1000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS
        ON 75 PERCENT DO NOTIFY
        ON 90 PERCENT DO NOTIFY
        ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE my_warehouse SET RESOURCE_MONITOR = monthly_monitor;
```

---

## 23. Snowpipe (Continuous Data Ingestion)

```sql
CREATE PIPE auto_load_pipe
    AUTO_INGEST = TRUE
AS
    COPY INTO sales_db.retail_schema.orders
    FROM @my_s3_stage
    FILE_FORMAT = csv_format;

-- Check pipe status
SELECT SYSTEM$PIPE_STATUS('auto_load_pipe');
```

---

## 24. Snowpipe Streaming

Low-latency row-level ingestion using the Snowflake Ingest SDK. No staging files required -- data lands directly into tables. Configured via Snowflake Ingest SDK (Java/Python), not SQL.

---

## 25. Transactions

```sql
BEGIN;
    INSERT INTO sales_db.retail_schema.orders VALUES (4, 'Diana', 450.00, '2025-02-01');
    UPDATE sales_db.retail_schema.orders SET amount = 500.00 WHERE order_id = 4;
COMMIT;

-- Rollback on error
BEGIN;
    DELETE FROM sales_db.retail_schema.orders WHERE order_id = 999;
ROLLBACK;
```

---

## 26. Sequences

```sql
CREATE SEQUENCE order_seq START = 1000 INCREMENT = 1;

INSERT INTO sales_db.retail_schema.orders
    VALUES (order_seq.NEXTVAL, 'Eve', 150.00, CURRENT_DATE());

SELECT order_seq.NEXTVAL;
```

---

## 27. Data Clustering and Search Optimization

```sql
-- Clustering Keys (improve query performance on large tables)
ALTER TABLE sales_db.retail_schema.orders CLUSTER BY (order_date);

-- Search Optimization Service (accelerates point lookups)
ALTER TABLE sales_db.retail_schema.orders ADD SEARCH OPTIMIZATION;

-- Targeted search optimization
ALTER TABLE sales_db.retail_schema.orders ADD SEARCH OPTIMIZATION
    ON EQUALITY(customer_name);
```

---

## 28. Caching

Snowflake has three cache layers (automatic, no SQL to configure):

1. **Result Cache**: Reuses results of identical queries (24 hours)
2. **Local Disk Cache (SSD)**: Warehouse nodes cache recently accessed data
3. **Remote Disk Cache**: Data stored in cloud storage

```sql
-- Example: Run the same query twice -- second run uses result cache
SELECT COUNT(*) FROM sales_db.retail_schema.orders WHERE amount > 100;
-- Run again -- instant result from cache
SELECT COUNT(*) FROM sales_db.retail_schema.orders WHERE amount > 100;
```

---

## 29. Alerts

```sql
CREATE ALERT high_spend_alert
    WAREHOUSE = my_warehouse
    SCHEDULE = '60 MINUTE'
    IF (EXISTS (
        SELECT 1 FROM sales_db.retail_schema.orders
        WHERE amount > 10000 AND order_date = CURRENT_DATE()
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'my_notification',
            'admin@company.com',
            'High Spend Alert',
            'An order exceeding $10,000 was detected today.'
        );

ALTER ALERT high_spend_alert RESUME;
```

---

## 30. Notifications

```sql
CREATE NOTIFICATION INTEGRATION my_email_notification
    TYPE = EMAIL
    ENABLED = TRUE
    ALLOWED_RECIPIENTS = ('admin@company.com');

-- Used with ALERTS, TASKS, and SYSTEM$SEND_EMAIL
```

---

## 31. Query Profile and Optimization

```sql
-- Explain plan
EXPLAIN SELECT * FROM sales_db.retail_schema.orders WHERE amount > 200;

-- Query history
SELECT query_id, query_text, execution_status, total_elapsed_time
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
ORDER BY start_time DESC
LIMIT 10;

-- Account-level query history
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
WHERE start_time > DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 10;
```

---

## 32. Network Policies

```sql
CREATE NETWORK POLICY office_only_policy
    ALLOWED_IP_LIST = ('203.0.113.0/24', '198.51.100.0/24')
    BLOCKED_IP_LIST = ('203.0.113.99');

-- Apply to account
ALTER ACCOUNT SET NETWORK_POLICY = office_only_policy;

-- Apply to specific user
ALTER USER some_user SET NETWORK_POLICY = office_only_policy;
```

---

## 33. Multi-Factor Authentication (MFA)

MFA is configured per user via Snowsight UI or:

```sql
ALTER USER some_user SET MINS_TO_BYPASS_MFA = 0;  -- Enforce MFA
```

---

## 34. Data Encryption

Snowflake encrypts all data at rest (AES-256) and in transit (TLS 1.2+).

- **Tri-Secret Secure**: Customer-managed key + Snowflake key = composite key
- Automatic key rotation every 30 days
- Periodic re-encryption of data

```sql
-- Check encryption status
SELECT SYSTEM$GET_SNOWFLAKE_PLATFORM_INFO();
```

---

## 35. Snowpark (DataFrame API)

Write data pipelines in Python, Java, or Scala that execute in Snowflake.

```python
from snowflake.snowpark import Session
from snowflake.snowpark.functions import col, sum as sp_sum

df = session.table("sales_db.retail_schema.orders")
result = df.filter(col("amount") > 200) \
           .group_by("customer_name") \
           .agg(sp_sum("amount").alias("total")) \
           .sort("total", ascending=False)
result.show()
```

---

## 36. Snowflake Notebooks

Interactive notebooks in Snowsight supporting SQL, Python, and Markdown. Built-in visualization, collaboration, and Snowpark integration.

Access via Snowsight > Projects > Notebooks

---

## 37. Streamlit in Snowflake

Build interactive data apps directly in Snowflake.

```sql
CREATE STREAMLIT my_app
    ROOT_LOCATION = '@my_stage/streamlit_app'
    MAIN_FILE = 'app.py'
    QUERY_WAREHOUSE = my_warehouse;
```

Example `app.py`:

```python
import streamlit as st
from snowflake.snowpark.context import get_active_session

session = get_active_session()
df = session.sql("SELECT * FROM orders LIMIT 100").to_pandas()
st.dataframe(df)
st.bar_chart(df.set_index('CUSTOMER_NAME')['AMOUNT'])
```

---

## 38. Cortex AI Functions

Built-in AI/ML functions powered by LLMs.

```sql
-- Sentiment Analysis
SELECT SNOWFLAKE.CORTEX.SENTIMENT('This product is amazing and works great!');

-- Summarize Text
SELECT SNOWFLAKE.CORTEX.SUMMARIZE('Snowflake is a cloud data platform that enables
    data storage, processing, and analytics. It separates compute from storage...');

-- Translate Text
SELECT SNOWFLAKE.CORTEX.TRANSLATE('Hello, how are you?', 'en', 'fr');

-- Text Completion (LLM)
SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large',
    'Explain what a data warehouse is in one sentence.');

-- Extract structured data from text
SELECT SNOWFLAKE.CORTEX.EXTRACT_ANSWER(
    'Snowflake was founded in 2012 by Benoit Dageville and Thierry Cruanes.',
    'When was Snowflake founded?'
);
```

---

## 39. Cortex Search

Build hybrid search (vector + keyword) over text data.

```sql
CREATE CORTEX SEARCH SERVICE my_search_service
    ON text_column
    WAREHOUSE = my_warehouse
    TARGET_LAG = '1 hour'
AS (
    SELECT id, text_column, category
    FROM documents_table
);
```

---

## 40. Cortex Analyst

Natural language to SQL using semantic models. Define a semantic model (YAML) mapping business terms to tables/columns. Users ask questions in plain English; Cortex Analyst generates SQL.

---

## 41. Snowflake Marketplace

Discover and access third-party data, apps, and services. Available via Snowsight > Data Products > Marketplace. Providers share data listings; consumers get instant access.

---

## 42. Data Exchange (Private Sharing)

Create a private marketplace for your organization. Invite specific accounts to share and consume data securely.

---

## 43. Replication and Failover

```sql
-- Enable replication for a database
ALTER DATABASE sales_db ENABLE REPLICATION TO ACCOUNTS org.account2;

-- Create failover group
CREATE FAILOVER GROUP my_failover_group
    OBJECT_TYPES = DATABASES, ROLES, WAREHOUSES
    ALLOWED_DATABASES = sales_db
    ALLOWED_ACCOUNTS = org.account2
    REPLICATION_SCHEDULE = '10 MINUTE';
```

---

## 44. External Functions

Call external APIs (AWS Lambda, Azure Functions, etc.) from SQL.

```sql
CREATE EXTERNAL FUNCTION translate_text(text STRING, lang STRING)
    RETURNS STRING
    API_INTEGRATION = my_api_integration
    AS 'https://my-api-gateway.com/translate';

SELECT translate_text('Hello', 'es');
```

---

## 45. External Access Integration

Allow UDFs/procedures to access external endpoints.

```sql
CREATE EXTERNAL ACCESS INTEGRATION my_ext_access
    ALLOWED_NETWORK_RULES = (my_network_rule)
    ENABLED = TRUE;

CREATE NETWORK RULE my_network_rule
    MODE = EGRESS
    TYPE = HOST_PORT
    VALUE_LIST = ('api.example.com:443');
```

---

## 46. Directory Tables

Query metadata of staged files like a table.

```sql
CREATE STAGE dir_stage DIRECTORY = (ENABLE = TRUE);
ALTER STAGE dir_stage REFRESH;
SELECT * FROM DIRECTORY(@dir_stage);
```

---

## 47. Data Metric Functions (Data Quality)

Monitor data quality with built-in or custom metrics.

```sql
-- Built-in system DMFs:
-- SNOWFLAKE.CORE.NULL_COUNT
-- SNOWFLAKE.CORE.DUPLICATE_COUNT
-- SNOWFLAKE.CORE.UNIQUE_COUNT
-- SNOWFLAKE.CORE.FRESHNESS

-- Attach a DMF to a table
ALTER TABLE sales_db.retail_schema.orders
    ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.NULL_COUNT
    ON (customer_name);
```

---

## 48. Classify (Sensitive Data Classification)

```sql
-- Automatically classify columns for PII/sensitivity
SELECT * FROM TABLE(
    SNOWFLAKE.CORE.DATA_CLASSIFICATION_LATEST(
        'sales_db.retail_schema.orders'
    )
);

-- Run classification
CALL SYSTEM$CLASSIFY('sales_db.retail_schema.orders', {'auto_tag': true});
```

---

## 49. Object Tagging

```sql
CREATE TAG cost_center ALLOWED_VALUES 'engineering', 'marketing', 'finance';
CREATE TAG environment ALLOWED_VALUES 'dev', 'staging', 'prod';

ALTER WAREHOUSE my_warehouse SET TAG cost_center = 'engineering';
ALTER DATABASE sales_db SET TAG environment = 'prod';

-- Find tagged objects
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE TAG_NAME = 'COST_CENTER';
```

---

## 50. Account Usage and Information Schema

```sql
-- Information Schema (real-time, database-scoped)
SELECT * FROM sales_db.INFORMATION_SCHEMA.TABLES;
SELECT * FROM sales_db.INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = 'ORDERS';

-- Account Usage (up to 1 year history, account-wide)
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY ORDER BY EVENT_TIMESTAMP DESC LIMIT 5;
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.STORAGE_USAGE ORDER BY USAGE_DATE DESC LIMIT 5;
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY ORDER BY START_TIME DESC LIMIT 5;
```

---

## 51. Execute Immediate / Execute Immediate From

```sql
-- Dynamic SQL execution
EXECUTE IMMEDIATE 'SELECT CURRENT_DATE()';

-- Execute SQL from a stage file
EXECUTE IMMEDIATE FROM @my_stage/scripts/setup.sql;
```

---

## 52. Snowflake Scripting (Procedural SQL)

```sql
DECLARE
    total_orders INT;
    message STRING;
BEGIN
    SELECT COUNT(*) INTO total_orders FROM sales_db.retail_schema.orders;
    IF (total_orders > 100) THEN
        message := 'High volume: ' || total_orders || ' orders';
    ELSE
        message := 'Normal volume: ' || total_orders || ' orders';
    END IF;
    RETURN message;
END;
```

---

## 53. Window Functions

```sql
SELECT
    order_id,
    customer_name,
    amount,
    ROW_NUMBER() OVER (ORDER BY amount DESC) AS rank,
    SUM(amount) OVER (PARTITION BY customer_name) AS customer_total,
    LAG(amount) OVER (ORDER BY order_date) AS prev_amount,
    LEAD(amount) OVER (ORDER BY order_date) AS next_amount,
    AVG(amount) OVER (ORDER BY order_date ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg
FROM sales_db.retail_schema.orders;
```

---

## 54. Geography and Geometry Data Types

```sql
SELECT TO_GEOGRAPHY('POINT(-122.35 37.55)') AS san_francisco;

SELECT ST_DISTANCE(
    TO_GEOGRAPHY('POINT(-122.35 37.55)'),
    TO_GEOGRAPHY('POINT(-73.98 40.75)')
) AS distance_meters;
```

---

## 55. Secure Data Sharing with Reader Accounts

Share data with non-Snowflake customers via managed reader accounts.

```sql
CREATE MANAGED ACCOUNT reader1
    ADMIN_NAME = 'reader_admin'
    ADMIN_PASSWORD = '...'
    TYPE = READER;

ALTER SHARE orders_share ADD ACCOUNTS = reader1;
```

---

## 56. Access History

Track which users accessed which data objects.

```sql
SELECT user_name, query_id, direct_objects_accessed, base_objects_accessed
FROM SNOWFLAKE.ACCOUNT_USAGE.ACCESS_HISTORY
ORDER BY query_start_time DESC
LIMIT 10;
```

---

## 57. Listing and Data Products

Publish data products to Snowflake Marketplace or privately. Manage via Snowsight > Data Products > Provider Studio.

---

## 58. Budgets

Monitor and control spending at account or custom scope.

```sql
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!ACTIVATE();
CALL SNOWFLAKE.LOCAL.ACCOUNT_ROOT_BUDGET!SET_SPENDING_LIMIT(5000);
```

---

## 59. Hybrid Tables

OLTP-style tables with fast single-row operations and indexes.

```sql
CREATE HYBRID TABLE user_sessions (
    session_id VARCHAR PRIMARY KEY,
    user_id INT,
    login_time TIMESTAMP,
    INDEX idx_user (user_id)
);
```

---

## 60. Container Services (Snowpark Container Services)

Run custom Docker containers (APIs, ML models, apps) inside Snowflake.

```sql
CREATE COMPUTE POOL my_pool
    MIN_NODES = 1 MAX_NODES = 3
    INSTANCE_FAMILY = CPU_X64_S;

CREATE SERVICE my_service
    IN COMPUTE POOL my_pool
    FROM SPECIFICATION_FILE = 'service_spec.yaml';
```

---

## 61. Logging and Tracing

Capture logs and traces from UDFs and stored procedures.

```sql
CREATE EVENT TABLE my_events;
ALTER ACCOUNT SET EVENT_TABLE = my_db.my_schema.my_events;
```

In Python UDF:

```python
import logging
logger = logging.getLogger("my_udf")
logger.info("Processing row...")
```

---

## 62. Governance Features Summary

| Feature | Purpose |
|---------|---------|
| Masking Policies | Column-level data masking |
| Row Access Policies | Row-level security |
| Tags | Classify and label objects |
| Data Classification | Auto-detect PII/sensitive data |
| Access History | Audit who accessed what |
| Object Dependencies | Track lineage |
| Data Metric Functions | Monitor data quality |

---

## 63. Cost Management Features

```sql
-- Resource Monitors       -> Credit quotas and suspend triggers
-- Budgets                 -> Spending limits and alerts
-- Warehouse Auto-Suspend  -> Stop compute when idle
-- Query Acceleration      -> Offload outlier query partitions

ALTER WAREHOUSE my_warehouse SET
    ENABLE_QUERY_ACCELERATION = TRUE
    QUERY_ACCELERATION_MAX_SCALE_FACTOR = 8;
```

---

## 64. Private Connectivity

AWS PrivateLink, Azure Private Link, GCP Private Service Connect. Ensure Snowflake traffic never traverses the public internet.

```sql
SELECT SYSTEM$GET_PRIVATELINK_CONFIG();
```

---

## 65. SCIM (User Provisioning)

Integrate with identity providers (Okta, Azure AD) for automated user/role provisioning and deprovisioning.

```sql
CREATE SECURITY INTEGRATION my_scim
    TYPE = SCIM
    SCIM_CLIENT = 'OKTA'
    RUN_AS_ROLE = 'OKTA_PROVISIONER';
```

---

*This guide covers 65+ major Snowflake features. Each section includes a brief explanation and practical SQL example.*
