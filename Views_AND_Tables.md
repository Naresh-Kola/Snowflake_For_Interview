# Snowflake Tables & Views - Complete Reference Guide

> **All Table & View types in Snowflake, explained with examples, use cases, and comparisons.**

---

## Table of Contents

- [VIEW TYPES](#view-types)
  - [1. Regular View](#1-regular-view)
  - [2. Secure View](#2-secure-view)
  - [3. Materialized View](#3-materialized-view)
  - [4. Secure Materialized View](#4-secure-materialized-view)
  - [Views - Comparison at a Glance](#views---comparison-at-a-glance)
- [TABLE TYPES](#table-types)
  - [1. Permanent Table](#1-permanent-table)
  - [2. Transient Table](#2-transient-table)
  - [3. Temporary Table](#3-temporary-table)
  - [4. External Table](#4-external-table)
  - [5. Hybrid Table](#5-hybrid-table)
  - [6. Iceberg Table](#6-iceberg-table)
  - [7. Dynamic Table](#7-dynamic-table)
  - [8. Event Table](#8-event-table)
  - [Tables - Comparison at a Glance](#tables---comparison-at-a-glance)
- [Decision Guide: When to Use What](#decision-guide-when-to-use-what)
- [Storage Cost Comparison](#storage-cost-comparison)

---

# VIEW TYPES

| # | Type | Stores Data? | Definition Hidden? | Best For |
|---|------|-------------|-------------------|----------|
| 1 | Regular View | No | No | Simplify queries, hide columns |
| 2 | Secure View | No | Yes (owner only) | Data sharing, row-level security |
| 3 | Materialized View | Yes | No | Speed up heavy aggregations |
| 4 | Secure Materialized View | Yes | Yes (owner only) | Fast + private data sharing |

---

## 1. Regular View

### What Is a View?

A view is a **saved SELECT query** with a name. It does **NOT** store any data. Every time you query a view, Snowflake runs the saved query from scratch and gives you the latest result.

> Think of it like a **bookmark** for a query. Instead of writing a long complex query every time, you save it as a view and just do: `SELECT * FROM my_view;`

### Why Do We Need Views?

| Reason | Explanation |
|--------|-------------|
| **Simplify complex queries** | Your team has a 50-line query with 5 JOINs. Instead of everyone copy-pasting it, create a view. Now everyone just does: `SELECT * FROM sales_summary;` |
| **Hide sensitive columns** | The `employees` table has `salary` and `SSN` columns. Create a view that excludes those columns. Give users access to the VIEW, not the TABLE. |
| **Business logic in one place** | "Active customer" means `status='active' AND last_order < 90 days`. Put that logic in a view. Update ONE view instead of 100 queries. |
| **Backward compatibility** | You rename a column from `cust_name` to `customer_name`. Create a view with the old column name as an alias. Old reports keep working. |

### How It Works

```
SELECT * FROM my_view;

1. Snowflake looks up the saved query
2. Replaces "my_view" with the actual SELECT
3. Runs the full query against the base table(s)
4. Returns the result

Nothing is stored. It runs fresh EVERY time.
```

### Example 1: Simplify a Complex Query

```sql
CREATE OR REPLACE VIEW demo_db.public.v_employee_directory AS
SELECT
    employee_id,
    first_name || ' ' || last_name AS full_name,
    email,
    department
FROM demo_db.public.employees
WHERE is_active = TRUE;

-- Now anyone can just do:
SELECT * FROM demo_db.public.v_employee_directory;
```

### Example 2: Hide Sensitive Columns

```sql
CREATE OR REPLACE VIEW demo_db.public.v_employees_safe AS
SELECT
    employee_id, first_name, last_name, department, hire_date
FROM demo_db.public.employees;
-- salary is excluded - users of this view can never see it
```

### Example 3: Multi-Table JOIN Saved as a View

```sql
CREATE OR REPLACE VIEW demo_db.public.v_order_details AS
SELECT
    o.order_id, o.order_date, c.customer_name, p.product_name,
    oi.quantity, oi.unit_price,
    oi.quantity * oi.unit_price AS line_total
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN products p     ON oi.product_id = p.product_id
JOIN customers c    ON o.customer_id = c.customer_id;

SELECT * FROM demo_db.public.v_order_details WHERE order_date = CURRENT_DATE();
```

### Features

- Stores **NO** data (zero storage cost)
- Always returns **latest data** (100% live)
- Can reference multiple tables (JOINs, subqueries, UNIONs)
- Can use window functions, aggregations, CTEs
- Anyone can see the view definition (`SHOW VIEWS` / `GET_DDL`)
- Query optimizer **CAN** see through the view and optimize

### Limitations

- Runs the full query every time (slow on large data)
- View definition is visible to anyone with access
- Cannot INSERT/UPDATE/DELETE through a view (read-only)

---

## 2. Secure View

### What Is a Secure View?

A secure view is the same as a regular view, **EXCEPT**:

1. **The view DEFINITION is HIDDEN.** Users can query the view but CANNOT see how it was built.
2. **The query optimizer CANNOT bypass the view's filters.** Prevents clever users from tricking the optimizer into revealing hidden rows.

> A secure view is a view with a **LOCKED door**. You can see the output, but you cannot see how it works inside.

### Why Do We Need Secure Views?

| Reason | Explanation |
|--------|-------------|
| **Data sharing with other accounts** | You **MUST** use a secure view for Secure Data Sharing. The consumer sees the data but NOT your table structure. |
| **Row-level security** | Filter rows using `CURRENT_ACCOUNT()` or `CURRENT_ROLE()`. The optimizer can't bypass this filter. |
| **Hide business logic** | Your pricing formula is in the view definition. A secure view hides it. |
| **Prevent optimizer tricks** | Blocks users from using error-based techniques to reveal hidden rows. |

### What Exactly Is Hidden?

| | Regular View | Secure View |
|---|---|---|
| `SHOW VIEWS` | Shows the full SQL definition | Definition column is **EMPTY** |
| `GET_DDL()` | Returns the full `CREATE VIEW` statement | Returns **NOTHING** (unless you own the view) |
| `EXPLAIN` | Shows base table names and columns | Hides base table details from non-owners |

### Example 1: Data Sharing - Each Account Sees Only Their Data

```sql
CREATE OR REPLACE SECURE VIEW demo_db.public.sv_shared_sales AS
SELECT order_id, product_name, quantity, sale_date, amount
FROM demo_db.public.sales_data sd
JOIN demo_db.public.account_access aa
    ON sd.access_group = aa.access_group
WHERE aa.snowflake_account = CURRENT_ACCOUNT();
```

### Example 2: Role-Based Row Filtering

```sql
CREATE OR REPLACE SECURE VIEW demo_db.public.sv_department_data AS
SELECT employee_id, first_name, last_name, department, salary
FROM demo_db.public.employees
WHERE department = (
    SELECT allowed_dept FROM demo_db.public.role_department_map
    WHERE role_name = CURRENT_ROLE()
);
```

### Example 3: Hide Pricing Formula

```sql
CREATE OR REPLACE SECURE VIEW demo_db.public.sv_product_pricing AS
SELECT
    product_id, product_name,
    base_price * markup_factor * regional_adjustment AS final_price
FROM demo_db.public.pricing_internal;
-- Users CANNOT see base_price, markup_factor, or the formula.
```

### Regular View vs Secure View

| | Regular View | Secure View |
|---|---|---|
| SQL definition visible? | YES (to all) | NO (owner only) |
| Optimizer can peek? | YES | NO (locked) |
| Performance | Faster (optimizer has more info) | Slightly slower |
| Data Sharing allowed? | NO | YES (required) |
| Security level | Basic | High |
| Storage cost | $0 | $0 |

> **Performance Note:** Secure views can be slower because the optimizer cannot push predicates freely. Use only when you NEED the security.

---

## 3. Materialized View

### What Is a Materialized View?

A materialized view is a view that **STORES** its query results.

| Type | Behavior |
|---|---|
| Regular view | Runs the query **every time** you read it |
| Materialized view | Runs the query **ONCE**, stores the result, keeps it updated automatically |

> A regular view cooks from scratch every time. A materialized view **pre-cooks** the meal and keeps it warm.

### Why Do We Need Materialized Views?

| Reason | Explanation |
|--------|-------------|
| **Speed up repeated expensive queries** | 500M row scan takes 30 sec. 50 users/hour = 25 min compute/hour. MV: each query ~1 sec. |
| **Speed up external table queries** | MV caches external (S3) data inside Snowflake. |
| **Automatic optimizer rewrite** | Snowflake may use the MV even when you query the base table directly. |

### How It Stays Up-to-Date

A background serverless process updates the MV when the base table changes. You **NEVER** update it manually. Result is **ALWAYS accurate**.

### Limitations (Important!)

- Can query **ONLY ONE table** (no JOINs)
- No window functions, HAVING, ORDER BY, LIMIT
- No UDFs, no non-deterministic functions
- Cannot INSERT/UPDATE/DELETE into an MV
- Costs storage + serverless compute
- **Requires Enterprise Edition or higher**

### Example 1: Speed Up a Heavy Aggregation

```sql
CREATE OR REPLACE MATERIALIZED VIEW demo_db.public.mv_daily_revenue AS
SELECT
    order_date,
    COUNT(*) AS total_orders, SUM(amount) AS total_revenue, AVG(amount) AS avg_order_value
FROM demo_db.public.raw_orders
GROUP BY order_date;
```

### Example 2: Materialized View with Clustering

```sql
CREATE OR REPLACE MATERIALIZED VIEW demo_db.public.mv_orders_by_region
    CLUSTER BY (region)
AS
SELECT region, order_date, SUM(amount) AS revenue, COUNT(*) AS orders
FROM demo_db.public.raw_orders
GROUP BY region, order_date;
```

### Cost

```sql
-- Monitor cost:
SELECT * FROM TABLE(INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY());

-- Suspend / Resume maintenance:
ALTER MATERIALIZED VIEW mv_daily_revenue SUSPEND;
ALTER MATERIALIZED VIEW mv_daily_revenue RESUME;
```

---

## 4. Secure Materialized View

**Materialized view + Secure view** combined = **fast + private**

### When to Use?

| Use Case | Description |
|----------|-------------|
| **Share pre-computed data securely** | Partner sees fast results but CANNOT see your tables or logic. |
| **External table + security** | Fast reads + no visibility into your data lake structure. |
| **Fast role-based dashboards** | Different roles, different summaries. Logic is hidden. |

```sql
CREATE OR REPLACE SECURE MATERIALIZED VIEW demo_db.public.smv_partner_revenue AS
SELECT region, product_category, order_date, SUM(revenue) AS total_revenue
FROM demo_db.public.internal_sales
GROUP BY region, product_category, order_date;
```

---

## Views - Comparison at a Glance

| Feature | Regular View | Secure View | Materialized View | Secure Materialized View |
|---------|-------------|-------------|-------------------|--------------------------|
| Stores data? | NO | NO | YES | YES |
| Definition hidden? | NO | YES | NO | YES |
| Always live data? | YES | YES | YES (auto) | YES (auto) |
| Query speed | Slow (recompute) | Slow (recompute) | Fast (pre-stored) | Fast (pre-stored) |
| Multi-table JOINs? | YES | YES | NO (1 table) | NO (1 table) |
| Storage cost | $0 | $0 | YES | YES |
| Data Sharing? | NO | YES | NO | YES |
| Optimizer bypass | Allowed | Blocked | Allowed | Blocked |
| Edition required | Standard | Standard | Enterprise | Enterprise |

### When to Use Which View?

| Scenario | Use |
|----------|-----|
| Simple query, small data, no security needed | **Regular View** |
| Need to hide logic OR share with other accounts | **Secure View** |
| Heavy aggregation on large data, queried often | **Materialized View** |
| Heavy aggregation + hide logic / share data | **Secure Materialized View** |

---
﻿
# TABLE TYPES

| # | Type | Storage | Best For |
|---|------|---------|----------|
| 1 | Permanent Table | Snowflake | Production data, long-lived datasets |
| 2 | Transient Table | Snowflake | ETL staging, intermediate data |
| 3 | Temporary Table | Snowflake (session) | Session-scoped scratch work |
| 4 | External Table | External (S3/GCS/Azure) | Data lake querying |
| 5 | Hybrid Table | Row + Columnar | Low-latency OLTP workloads |
| 6 | Iceberg Table | External (Parquet) | Open lakehouse, multi-engine |
| 7 | Dynamic Table | Snowflake | Auto-refresh data pipelines |
| 8 | Event Table | Snowflake | UDF/procedure logging |

---

## 1. Permanent Table

The standard Snowflake table. Data is stored in columnar micro-partitions with full platform support.

### How Columnar Micro-Partitions Work

When you INSERT data, Snowflake automatically splits it into **micro-partitions** (50-500 MB uncompressed each). Inside each micro-partition, data is stored **COLUMN-BY-COLUMN**, not row-by-row.

**Example:** 8 rows inserted into `employees`. Snowflake creates 2 micro-partitions (MP1 and MP2), 4 rows each.

**Original rows (logical view):**

| ID | NAME | DEPARTMENT | SALARY |
|----|------|-----------|--------|
| 1 | Rohit | Engineering | 95000 |
| 2 | Virat | Marketing | 85000 |
| 3 | Dhoni | Engineering | 120000 |
| 4 | Bumrah | Sales | 78000 |
| 5 | Jadeja | Engineering | 92000 |
| 6 | Pant | Marketing | 88000 |
| 7 | Rahul | Sales | 75000 |
| 8 | Gill | Engineering | 90000 |

Rows 1-4 = **MP1**, rows 5-8 = **MP2**.

**Physical storage (columnar inside each micro-partition):**

```
+--- MP1 -----------------------------------------------------------+
|  ID column:         [1, 2, 3, 4]               (compressed)       |
|  NAME column:       [Rohit, Virat, Dhoni, Bumrah]  (compressed)   |
|  DEPARTMENT column: [Eng, Mkt, Eng, Sales]      (compressed)      |
|  SALARY column:     [95000, 85000, 120000, 78000]  (compressed)   |
|                                                                    |
|  METADATA: ID range [1-4], SALARY range [78000-120000]            |
+--------------------------------------------------------------------+

+--- MP2 -----------------------------------------------------------+
|  ID column:         [5, 6, 7, 8]               (compressed)       |
|  NAME column:       [Jadeja, Pant, Rahul, Gill]    (compressed)   |
|  DEPARTMENT column: [Eng, Mkt, Sales, Eng]      (compressed)      |
|  SALARY column:     [92000, 88000, 75000, 90000]   (compressed)   |
|                                                                    |
|  METADATA: ID range [5-8], SALARY range [75000-92000]             |
+--------------------------------------------------------------------+
```

### Why Columnar?

`SELECT AVG(salary) FROM employees;` - Snowflake reads **ONLY** the SALARY column. Other columns are **NEVER** touched. Huge I/O savings.

### Why Micro-Partition Metadata Matters (Pruning)

`SELECT * FROM employees WHERE salary > 100000;`

- MP1 salary range = [78000-120000] - MIGHT have matches - **SCAN**
- MP2 salary range = [75000-92000] - NO value > 100000 - **SKIP!**

On millions of micro-partitions, this skips 90%+ of data.

### Metadata Stored Per Micro-Partition

- Min/Max range per column
- Number of distinct values per column
- Number of NULLs per column
- Total row count

### Clustering and Reclustering

```sql
ALTER TABLE employees CLUSTER BY (department);
```

After reclustering: `WHERE department = 'Engineering'` scans ONLY MP1, skips MP2.

### Key Takeaways

1. Micro-partitions are **automatic**
2. **Columnar** = only read columns your query needs
3. **Metadata** = skip micro-partitions that can't have your data
4. **Clustering keys** = reduce overlap for better pruning
5. Each column compressed independently
6. Typical table: thousands to millions of micro-partitions

### Features

- **Time Travel:** up to 90 days (Enterprise+), 1 day (Standard)
- **Fail-safe:** 7 days of additional recovery
- Cloning, Replication, Streams, Tasks, Dynamic Tables - all supported
- Clustering keys for large table optimization

### Example

```sql
CREATE OR REPLACE TABLE demo_db.public.employees (
    employee_id     INT AUTOINCREMENT PRIMARY KEY,
    first_name      VARCHAR(50)   NOT NULL,
    last_name       VARCHAR(50)   NOT NULL,
    email           VARCHAR(100)  NOT NULL,
    department      VARCHAR(50),
    salary          NUMBER(12,2),
    hire_date       DATE DEFAULT CURRENT_DATE(),
    is_active       BOOLEAN DEFAULT TRUE
);

INSERT INTO demo_db.public.employees (first_name, last_name, email, department, salary)
VALUES
    ('Rohit', 'Sharma', 'rohit@example.com', 'Engineering', 95000),
    ('Virat', 'Kohli',  'virat@example.com', 'Marketing',   85000),
    ('MS',    'Dhoni',  'dhoni@example.com', 'Engineering', 120000);

-- Time Travel (5 minutes ago):
SELECT * FROM demo_db.public.employees AT(OFFSET => -60*5);

-- Zero-copy clone:
CREATE TABLE demo_db.public.employees_backup CLONE demo_db.public.employees;
```

---

## 2. Transient Table

### What Is It?

Like a permanent table but with **TWO** cost-saving trade-offs:
1. **NO Fail-safe** (permanent has 7 days)
2. **Time Travel: 0 or 1 day only** (permanent allows up to 90)

> Use when you **CAN RECREATE** the data if it is lost.

### Why Does This Save Money?

**Permanent Table** (1 TB):

| Layer | Cost |
|-------|------|
| Active data | $23/month |
| Time Travel (90 days) | up to $23/month |
| Fail-safe (7 days) | ~$5/month |
| **Total** | **~$51/month** |

**Transient Table** (1 TB, retention=0):

| Layer | Cost |
|-------|------|
| Active data | $23/month |
| Time Travel | $0 |
| Fail-safe | $0 |
| **Total** | **$23/month (~55% cheaper!)** |

### Use Case 1: ETL/ELT Staging

```sql
CREATE OR REPLACE TRANSIENT TABLE demo_db.public.stg_orders_raw (
    raw_json  VARIANT, file_name VARCHAR(200),
    loaded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) DATA_RETENTION_TIME_IN_DAYS = 0;
```

### Use Case 2: Intermediate Transformations

```sql
CREATE OR REPLACE TRANSIENT TABLE demo_db.public.cleaned_sales (
    transaction_id VARCHAR(50), product_name VARCHAR(100),
    quantity INT, unit_price NUMBER(10,2), sale_date DATE
) DATA_RETENTION_TIME_IN_DAYS = 1;
```

### Use Case 3: Dev/Sandbox Tables

```sql
CREATE OR REPLACE TRANSIENT TABLE demo_db.public.dev_experiment_users (
    user_id INT, user_name VARCHAR(50), signup_date DATE
);
```

### Use Case 4: Dashboard Snapshots

```sql
CREATE OR REPLACE TRANSIENT TABLE demo_db.public.daily_sales_summary (
    report_date DATE, total_revenue NUMBER(15,2),
    total_orders INT, avg_order_value NUMBER(10,2)
) DATA_RETENTION_TIME_IN_DAYS = 0;
```

### Other Use Cases

- Data Sharing Preparation
- ML Feature / Training Tables
- Log Tables with External Backup

### When NOT to Use Transient

- Production fact/dimension tables
- Financial or compliance data
- Data that CANNOT be recreated
- Need > 1 day Time Travel

> **Decision:** Can I recreate this data if completely lost? **YES** = Transient | **NO** = Permanent

---

## 3. Temporary Table

Exists **ONLY** for the session duration. Automatically dropped when session ends. Visible **ONLY** to the creating session.

### Features

- Time Travel: 0 or 1 day
- Fail-safe: NONE
- **NOT** visible to other sessions
- Can shadow permanent/transient tables
- No storage after session ends

```sql
CREATE OR REPLACE TEMPORARY TABLE demo_db.public.temp_high_earners (
    employee_id INT, full_name VARCHAR(100), salary NUMBER(12,2)
);

INSERT INTO demo_db.public.temp_high_earners
SELECT employee_id, first_name || ' ' || last_name, salary
FROM demo_db.public.employees WHERE salary > 90000;
-- Disappears when session closes.
```

---

## 4. External Table

**Read-only** table referencing data files in an external stage (S3, GCS, Azure Blob).

### Features

- **READ-ONLY** (no INSERT/UPDATE/DELETE)
- Schema-on-read via `VALUE` (VARIANT)
- Virtual columns for typed access
- Auto-refresh metadata via cloud events
- Materialized views can be built on top
- No Time Travel, no Fail-safe

```sql
CREATE OR REPLACE EXTERNAL TABLE demo_db.public.ext_web_logs (
    log_date    DATE         AS (VALUE:log_date::DATE),
    ip_address  VARCHAR(50)  AS (VALUE:ip_address::VARCHAR),
    endpoint    VARCHAR(200) AS (VALUE:endpoint::VARCHAR),
    status_code INT          AS (VALUE:status_code::INT)
)
PARTITION BY (log_date)
WITH LOCATION = @demo_db.public.my_s3_stage/web_logs/
FILE_FORMAT  = (TYPE = 'PARQUET')
AUTO_REFRESH = TRUE;
```

---

## 5. Hybrid Table

### What Is a Hybrid Table?

Built for **SPEED** on single-row operations. Works like MySQL/PostgreSQL but inside Snowflake.

- **Normal tables** = COLUMNAR (great for scans, bad for point lookups)
- **Hybrid tables** = ROW-BASED + columnar background copy (great for BOTH)

### The Problem It Solves

**Before:** App -> PostgreSQL (OLTP) + ETL -> Snowflake (analytics) = two databases, stale data, double cost.

**After:** App -> Snowflake Hybrid Tables (OLTP) + Standard Tables (analytics) = one platform, always fresh, no ETL.

### How It Stores Data

1. Row goes to **ROW STORE** (fast, indexed)
2. Background copy to **COLUMNAR STORAGE**
3. Snowflake auto-picks the best path per query

### Constraints ARE Enforced

| Constraint | Standard Table | Hybrid Table |
|-----------|---------------|-------------|
| PRIMARY KEY | Optional, **NOT** enforced | **REQUIRED, ENFORCED** |
| FOREIGN KEY | Not enforced | **ENFORCED** |
| UNIQUE | Not enforced | **ENFORCED** |

### Use Case 1: User Profiles (~5-10ms lookups)

```sql
CREATE OR REPLACE HYBRID TABLE demo_db.public.user_profiles (
    user_id      INT           PRIMARY KEY,
    username     VARCHAR(50)   NOT NULL UNIQUE,
    email        VARCHAR(100)  NOT NULL,
    display_name VARCHAR(100),
    plan_type    VARCHAR(20)   DEFAULT 'free',
    INDEX idx_email (email)
);
```

### Use Case 2: Shopping Cart (row-level locking)

```sql
CREATE OR REPLACE HYBRID TABLE demo_db.public.shopping_cart (
    cart_item_id INT PRIMARY KEY AUTOINCREMENT,
    user_id      INT NOT NULL,
    product_id   INT NOT NULL,
    quantity     INT DEFAULT 1,
    INDEX idx_cart_user (user_id)
);
```

### Use Case 3: IoT Device State

```sql
CREATE OR REPLACE HYBRID TABLE demo_db.public.device_state (
    device_id      VARCHAR(50) PRIMARY KEY,
    status         VARCHAR(20) DEFAULT 'offline',
    battery_pct    NUMBER(5,2),
    last_heartbeat TIMESTAMP_NTZ,
    INDEX idx_status (status)
);
```

### Hybrid vs Standard Table

| | Standard | Hybrid |
|---|---|---|
| Storage | Columnar | Row + Columnar |
| Best for | Scan millions | Read/write 1 row |
| Point lookup | ~200ms | ~5-10ms |
| PRIMARY KEY | Optional, not enforced | Required, enforced |
| Locking | Partition/table | Row-level |
| Concurrency | Moderate | High (16K ops/s) |
| Indexes | No | Yes (secondary) |
| Max data/DB | Unlimited | 2 TB |
| Streams | Yes | No |
| Fail-safe | Yes (7 days) | No |
| Clouds | All | AWS + Azure only |

> **Decision:** Need fast single-row ops with high concurrency? **YES** = Hybrid | **NO** = Standard

---
﻿
## 6. Iceberg Table

Apache Iceberg open table format in Snowflake. Data stored in Parquet files on **YOUR** external storage.

### Features

- Open Parquet format (readable by Spark, Trino, Flink)
- **Snowflake catalog:** full DML, clustering, compaction
- **External catalog** (Glue, Open Catalog, REST): read + limited write
- ACID transactions, schema evolution, hidden partitioning
- Time Travel via Iceberg snapshots
- No Fail-safe, no Snowflake storage cost

```sql
CREATE OR REPLACE ICEBERG TABLE demo_db.public.iceberg_events (
    event_id   INT, event_type VARCHAR(50),
    event_data VARCHAR, created_at TIMESTAMP_NTZ
)
CATALOG = 'SNOWFLAKE' EXTERNAL_VOLUME = 'my_ext_volume' BASE_LOCATION = 'events/';

INSERT INTO demo_db.public.iceberg_events
VALUES (1, 'click', '{"page":"home"}', CURRENT_TIMESTAMP());
```

---

## 7. Dynamic Table

### What Is a Dynamic Table?

You define a SELECT query. Snowflake **automatically** runs it, stores the result, and keeps it updated when the source changes.

> Like hiring someone to refresh a report for you so it's always ready.

### View vs Dynamic Table

| | View | Dynamic Table |
|---|---|---|
| Stores data? | NO | YES |
| When computed? | Every query | Background (TARGET_LAG) |
| Query speed | SLOW (recomputes) | FAST (pre-computed) |
| Data freshness | 100% live | Slightly behind |
| Storage cost | $0 | Costs storage |

### What Happens When Source Changes?

**View:** Re-scans ALL rows every time. Always live, but slow.

**Dynamic Table** (TARGET_LAG = '1 hour'):

| Time | Event |
|------|-------|
| 2:00 PM | 1000 new rows inserted |
| 2:01 PM | Query DT - new rows NOT included yet (but fast!) |
| 2:30 PM | Snowflake refreshes (processes only the 1000 new rows) |
| 2:31 PM | Query DT - new rows now included (still fast!) |

### The Problem It Solves

**Before:** Source -> Stream -> Task (proc) -> Table A -> Stream -> Task -> Table B (complex!)

**After:** Source -> Dynamic Table A (SELECT) -> Dynamic Table B (SELECT) (simple!)

### Example 1: Daily Sales Summary

```sql
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.daily_customer_totals
    TARGET_LAG = '1 hour'
    WAREHOUSE  = COMPUTE_WH
AS
    SELECT customer, order_date,
           SUM(amount) AS total_amount, COUNT(*) AS order_count
    FROM demo_db.public.raw_orders
    GROUP BY customer, order_date;
```

### Example 2: Chaining (Multi-Step Pipeline)

```
raw_orders -> daily_customer_totals (DT1) -> vip_customers (DT2)
```

```sql
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.vip_customers
    TARGET_LAG = '1 hour'
    WAREHOUSE  = COMPUTE_WH
AS
    SELECT customer,
           SUM(total_amount) AS lifetime_spend, SUM(order_count) AS lifetime_orders
    FROM demo_db.public.daily_customer_totals
    GROUP BY customer
    HAVING SUM(total_amount) > 500;
```

### Example 3: E-Commerce Analytics Pipeline

```sql
-- Step 1: Join raw data (10 min refresh)
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.enriched_orders
    TARGET_LAG = '10 minutes' WAREHOUSE = COMPUTE_WH
AS
    SELECT o.order_id, o.order_date, c.customer_name, c.region,
           p.product_name, p.category, oi.quantity, oi.unit_price,
           oi.quantity * oi.unit_price AS line_total
    FROM orders o
    JOIN order_items oi ON o.order_id = oi.order_id
    JOIN products p     ON oi.product_id = p.product_id
    JOIN customers c    ON o.customer_id = c.customer_id;

-- Step 2: Aggregate for dashboards (30 min refresh)
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.sales_dashboard
    TARGET_LAG = '30 minutes' WAREHOUSE = COMPUTE_WH
AS
    SELECT region, category, order_date,
           SUM(line_total) AS revenue, COUNT(DISTINCT order_id) AS num_orders
    FROM demo_db.public.enriched_orders
    GROUP BY region, category, order_date;
```

### Use Cases

| Use Case | Description |
|----------|-------------|
| **ETL/ELT Pipelines** | Replace Streams + Tasks with SELECTs |
| **Real-Time Dashboards** | Refreshes every few minutes |
| **Data Warehouse Layers** | Bronze -> Silver (DT) -> Gold (DT) |
| **Data Sharing** | Always-fresh, pre-computed data |
| **ML Feature Engineering** | Features always up-to-date |

### TARGET_LAG Explained

Not a schedule - a **freshness guarantee**.

| Value | Meaning | Cost |
|-------|---------|------|
| `'1 minute'` | At most 1 min behind | Highest |
| `'1 hour'` | At most 1 hour behind | Good balance |
| `'1 day'` | At most 1 day behind | Cheapest |
| `DOWNSTREAM` | Just-in-time refresh | Avoids unnecessary refreshes |

### Monitoring

```sql
SELECT * FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'DEMO_DB.PUBLIC.DAILY_CUSTOMER_TOTALS'));

SHOW DYNAMIC TABLES IN SCHEMA demo_db.public;

ALTER DYNAMIC TABLE demo_db.public.daily_customer_totals SUSPEND;
ALTER DYNAMIC TABLE demo_db.public.daily_customer_totals RESUME;
```

### Dynamic Table vs View vs Materialized View

| | View | Materialized View | Dynamic Table |
|---|---|---|---|
| Stores data? | No | Yes | Yes |
| Query speed | Slow | Fast | Fast |
| Source support | Any SQL | 1 table only | JOINs, aggs, subqueries |
| Chaining | Yes | No | Yes (DAG) |
| Freshness | Always live | Auto | TARGET_LAG |

> **Simple Rule:** Always-live + simple = **View** | Fast + single table = **MV** | Fast + complex + pipeline = **Dynamic Table**

---

## 8. Event Table

### What Is It?

Where Snowflake saves **LOG MESSAGES** from your code (stored procedures, UDFs, Snowpark apps).

> A diary your code writes while it runs. Query it with SQL to debug.

### Setup (Step-by-Step)

**Step 1:** Enable logging

```sql
ALTER ACCOUNT SET LOG_LEVEL = 'INFO';
ALTER ACCOUNT SET TRACE_LEVEL = 'ON_EVENT';
```

**Step 2:** Verify event table

```sql
SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT;
```

**Step 3:** Create and run a test procedure

```sql
CREATE OR REPLACE PROCEDURE demo_db.public.test_logging()
RETURNS VARCHAR LANGUAGE PYTHON RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python') HANDLER = 'run'
AS $$
import logging
logger = logging.getLogger('test_logging')
def run(session):
    logger.info("Step 1: Logging test started")
    logger.warning("Step 2: This is a WARNING")
    logger.error("Step 3: This is a fake ERROR")
    return "Done - check EVENTS_VIEW!"
$$;

CALL demo_db.public.test_logging();
```

**Step 4:** Wait 1-2 minutes, then query

```sql
SELECT
    TIMESTAMP,
    RECORD['severity_text']::VARCHAR AS log_level,
    VALUE::VARCHAR                   AS message
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'LOG'
ORDER BY TIMESTAMP DESC LIMIT 20;
```

### Troubleshooting

| Check | Fix |
|-------|-----|
| Wait 1-2 minutes? | Logs have a delay |
| LOG_LEVEL = OFF? | `ALTER ACCOUNT SET LOG_LEVEL = 'INFO';` |
| Database override? | `ALTER DATABASE demo_db SET LOG_LEVEL = 'INFO';` |

### LOG_LEVEL Options

| Level | Captures |
|-------|----------|
| `OFF` | Nothing |
| `ERROR` | Only errors |
| `WARN` | Errors + warnings |
| `INFO` | Errors + warnings + info **(recommended)** |
| `DEBUG` | Everything (verbose) |

### Use Cases

| Use Case | Description |
|----------|-------------|
| **Debug failed procedures** | Exact error, which row, when |
| **Monitor UDF performance** | Call duration, slow inputs |
| **Audit data processing** | Rows processed, skipped, errored |
| **Snowpark observability** | Log each pipeline step |

---

## Tables - Comparison at a Glance

| Feature | Permanent | Transient | Temporary | External | Hybrid | Iceberg | Dynamic | Event |
|---------|-----------|-----------|-----------|----------|--------|---------|---------|-------|
| Data Storage | Snowflake | Snowflake | Snowflake | External | Row Store | External | Snowflake | Snowflake |
| Read/Write | Full DML | Full DML | Full DML | Read only | Full DML | Full* | Auto only | System |
| Time Travel | 0-90 days | 0-1 day | 0-1 day | No | Limited | Yes** | Yes | Yes |
| Fail-safe | 7 days | No | No | No | No | No | Yes | Yes |
| Cloning | Yes | Yes | No | No | Limited | Yes | Yes | No |
| Streams | Yes | Yes | Yes | No | No | Partial | Yes | No |
| Clustering | Yes | Yes | Yes | N/A | By PK | Yes* | Yes | No |
| Constraints | Not enforced | Not enforced | Not enforced | N/A | **Enforced** | Not enforced | Not enforced | N/A |
| Replication | Yes | Yes | No | No | No | Yes* | Yes | No |
| Session Scoped | No | No | **YES** | No | No | No | No | No |
| Visible to All | Yes | Yes | **NO** | Yes | Yes | Yes | Yes | Yes |

> \* Iceberg: Full DML/clustering/replication only with Snowflake catalog.
> \*\* Iceberg: Time Travel via Iceberg snapshots.

---

## Decision Guide: When to Use What

| Scenario | Table Type |
|----------|-----------|
| Production fact/dimension tables | **Permanent** |
| ETL staging / intermediate data | **Transient** |
| Session-scoped scratch / ad-hoc analysis | **Temporary** |
| Query data lake files without ingestion | **External** |
| Low-latency app backend / OLTP workloads | **Hybrid** |
| Open lakehouse / multi-engine interop | **Iceberg** |
| Declarative data pipelines / auto-refresh | **Dynamic** |
| UDF/procedure logging and observability | **Event** |

---

## Storage Cost Comparison

| Table Type | Active Storage | Time Travel Storage | Fail-safe Storage |
|-----------|---------------|--------------------|--------------------|
| Permanent | YES | YES (0-90 days) | YES (7 days) |
| Transient | YES | YES (0-1 day) | NO |
| Temporary | YES (session) | YES (0-1 day) | NO |
| External | NO (external) | NO | NO |
| Hybrid | YES (row store) | YES (limited) | NO |
| Iceberg | NO (external) | Via snapshots | NO |
| Dynamic | YES | YES | YES |
| Event | YES | YES | YES |
