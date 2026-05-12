# DATA MODELING: COMPLETE GUIDE
## OLTP vs OLAP, Fact & Dimension Tables, Star Schema, Snowflake Schema, SCD, and Data Architecture

---

## 1. OLTP vs OLAP

### OLTP (Online Transaction Processing)

The system that **runs your business** — handles day-to-day transactions.

**Examples:** E-commerce checkout, banking transfers, hotel bookings, inventory updates.

**Characteristics:**

| Aspect | OLTP |
|--------|------|
| Purpose | Process transactions |
| Operations | INSERT, UPDATE, DELETE (many small writes) |
| Query pattern | Get single record by ID (`WHERE order_id = 123`) |
| Users | Application users (thousands/millions) |
| Data | Current state only (latest values) |
| Schema | Highly normalized (3NF) to avoid redundancy |
| Response time | Milliseconds |
| Example DB | MySQL, PostgreSQL, Oracle, SQL Server |

**Example OLTP table structure (normalized):**
```
orders (order_id, customer_id, order_date, status)
customers (customer_id, name, email, address_id)
addresses (address_id, street, city, state, zip)
order_items (item_id, order_id, product_id, quantity, price)
products (product_id, name, category_id, price)
categories (category_id, name)
```
> 6 tables, no data duplication, JOINs required for every query.

### OLAP (Online Analytical Processing)

The system that **analyzes your business** — answers questions like "What were sales last quarter by region?"

**Examples:** Revenue dashboards, customer segmentation, forecasting, trend analysis.

**Characteristics:**

| Aspect | OLAP |
|--------|------|
| Purpose | Analyze data for insights |
| Operations | SELECT with aggregations (SUM, COUNT, AVG) |
| Query pattern | Scan millions of rows (`GROUP BY region, month`) |
| Users | Analysts, data scientists (tens/hundreds) |
| Data | Historical data (years of history) |
| Schema | Denormalized (star/snowflake schema) for fast reads |
| Response time | Seconds to minutes |
| Example DB | Snowflake, BigQuery, Redshift, Databricks |

**Example OLAP table structure (denormalized):**
```
fct_orders (order_id, customer_name, customer_email, city, state,
            product_name, category, order_date, quantity, price, total_amount)
```
> 1 table, data IS duplicated (customer_name repeated), but NO JOINs needed.

### Side-by-Side Comparison:

| Feature | OLTP | OLAP |
|---------|------|------|
| **Data model** | Normalized (3NF) | Denormalized (Star/Snowflake) |
| **Primary use** | Run operations | Analyze trends |
| **Write pattern** | Many small writes | Bulk loads (batch/streaming) |
| **Read pattern** | Point lookups (1 row) | Full scans (millions of rows) |
| **JOINs** | Many (normalized) | Few (pre-joined) |
| **History** | Current state only | Full history preserved |
| **Indexes** | B-tree on PK/FK | Column-oriented storage |
| **Users** | Apps, APIs | Analysts, BI tools |
| **Examples** | MySQL, PostgreSQL | Snowflake, BigQuery |

### How They Connect:

```
OLTP (Source)          ETL / ELT            OLAP (Warehouse)
┌──────────┐          ┌──────────┐         ┌──────────────┐
│ MySQL    │ ──────→  │ Fivetran │ ──────→ │ Snowflake    │
│ Orders   │  extract │ Airbyte  │  load   │ fct_orders   │
│ Customers│          │ Spark    │         │ dim_customers│
│ Products │          │ dbt      │         │ dim_products │
└──────────┘          └──────────┘         └──────────────┘
  (writes)              (transform)          (reads)
```

---

## 2. WHAT IS DATA MODELING?

**Data modeling** is the process of designing HOW data is structured, stored, and related in a database to serve specific use cases (reporting, analytics, ML).

### Why it matters:
- Bad model → slow queries, duplicate data, wrong answers
- Good model → fast dashboards, consistent metrics, easy maintenance

### Three levels of data modeling:

| Level | What | Who | Example |
|-------|------|-----|---------|
| **Conceptual** | Business entities and relationships | Business analysts | "Customers place Orders for Products" |
| **Logical** | Tables, columns, data types, relationships | Data architects | Entity-Relationship (ER) diagram |
| **Physical** | Actual DDL, partitions, clustering, indexes | Data engineers | `CREATE TABLE fct_orders (...)` |

---

## 3. FACT TABLES AND DIMENSION TABLES

### Fact Table (the "what happened")

Stores **measurable business events** — transactions, activities, metrics.

**Characteristics:**
- Contains numeric/quantitative values (amount, quantity, count)
- Very LARGE (millions/billions of rows)
- Grows over time (new events keep appending)
- Contains FOREIGN KEYS to dimension tables
- Named with `fct_` prefix by convention

**Example:**
```sql
CREATE TABLE fct_orders (
    order_key INT,                -- surrogate key
    customer_key INT,             -- FK → dim_customers
    product_key INT,              -- FK → dim_products
    date_key INT,                 -- FK → dim_date
    store_key INT,                -- FK → dim_stores
    order_id VARCHAR,             -- business/natural key
    quantity INT,                 -- MEASURE
    unit_price NUMBER(10,2),      -- MEASURE
    discount_amount NUMBER(10,2), -- MEASURE
    total_amount NUMBER(10,2),    -- MEASURE
    tax_amount NUMBER(10,2)       -- MEASURE
);
```

### Three types of fact tables:

| Type | Description | Example |
|------|-------------|---------|
| **Transaction Fact** | One row per event/transaction | Each order line item |
| **Periodic Snapshot** | One row per entity per period | Monthly account balance |
| **Accumulating Snapshot** | One row per lifecycle, updated at milestones | Order: created → shipped → delivered |

**Transaction Fact Example:**
```
| order_key | customer_key | product_key | date_key | quantity | total_amount |
|-----------|-------------|-------------|----------|----------|--------------|
| 1         | 101         | 501         | 20240601 | 2        | 100000       |
| 2         | 102         | 502         | 20240601 | 1        | 1500         |
| 3         | 101         | 503         | 20240602 | 5        | 12500        |
```

**Periodic Snapshot Example:**
```
| account_key | date_key | balance    | transactions_count | avg_transaction |
|-------------|----------|------------|--------------------|-----------------|
| 1001        | 20240601 | 500000.00  | 15                 | 33333.33        |
| 1001        | 20240701 | 480000.00  | 12                 | 40000.00        |
| 1002        | 20240601 | 250000.00  | 8                  | 31250.00        |
```

**Accumulating Snapshot Example:**
```
| order_key | created_date | paid_date  | shipped_date | delivered_date | days_to_deliver |
|-----------|-------------|------------|--------------|----------------|-----------------|
| 1         | 2024-06-01  | 2024-06-01 | 2024-06-03   | 2024-06-05     | 4               |
| 2         | 2024-06-02  | 2024-06-02 | 2024-06-04   | NULL           | NULL            |
```

### Dimension Table (the "who, what, where, when")

Stores **descriptive attributes** that give context to facts.

**Characteristics:**
- Contains textual/descriptive values (name, category, region)
- Relatively SMALL (thousands to millions of rows)
- Changes slowly (customer name, product category)
- Contains SURROGATE KEYS (auto-increment) + NATURAL KEYS (business key)
- Named with `dim_` prefix by convention

**Example:**
```sql
CREATE TABLE dim_customers (
    customer_key INT,             -- surrogate key (warehouse-generated)
    customer_id VARCHAR,          -- natural key (from source system)
    first_name VARCHAR,
    last_name VARCHAR,
    email VARCHAR,
    phone VARCHAR,
    city VARCHAR,
    state VARCHAR,
    country VARCHAR,
    customer_segment VARCHAR,     -- Gold, Silver, Bronze
    registration_date DATE,
    is_active BOOLEAN
);

CREATE TABLE dim_products (
    product_key INT,
    product_id VARCHAR,
    product_name VARCHAR,
    category VARCHAR,
    subcategory VARCHAR,
    brand VARCHAR,
    supplier VARCHAR,
    unit_cost NUMBER(10,2),
    unit_price NUMBER(10,2),
    is_active BOOLEAN
);

CREATE TABLE dim_date (
    date_key INT,                 -- YYYYMMDD format (20240601)
    full_date DATE,
    day_of_week VARCHAR,          -- Monday, Tuesday, ...
    day_of_month INT,
    month_name VARCHAR,           -- January, February, ...
    month_number INT,
    quarter INT,                  -- 1, 2, 3, 4
    year INT,
    is_weekend BOOLEAN,
    is_holiday BOOLEAN,
    fiscal_year INT,
    fiscal_quarter INT
);
```

### Fact vs Dimension Summary:

| Aspect | Fact Table | Dimension Table |
|--------|-----------|----------------|
| Content | Measures (numbers) | Attributes (descriptions) |
| Size | Very large (billions) | Small (thousands-millions) |
| Growth | Grows fast (events) | Grows slowly (new entities) |
| Keys | FKs to dimensions | Surrogate key + natural key |
| Example cols | amount, quantity, count | name, category, city |
| Named | `fct_` prefix | `dim_` prefix |

---

## 4. STAR SCHEMA

The most common OLAP data model. Called "star" because the diagram looks like a star — one fact table in the center surrounded by dimension tables.

```
                    dim_customers
                         │
                         │ customer_key
                         │
dim_products ──── fct_orders ──── dim_date
                         │
                         │ store_key
                         │
                    dim_stores
```

### Characteristics:
- **One fact table** at the center
- **Multiple dimension tables** connected directly to the fact
- Dimensions are **denormalized** (flat, no sub-tables)
- Simple JOINs (fact → dimension, always 1 level)
- Optimized for OLAP queries (aggregations, GROUP BY)

### Example Star Schema:

```sql
-- FACT TABLE (center)
CREATE TABLE fct_sales (
    sale_key INT,
    customer_key INT,       -- FK → dim_customers
    product_key INT,        -- FK → dim_products
    store_key INT,          -- FK → dim_stores
    date_key INT,           -- FK → dim_date
    quantity INT,
    unit_price NUMBER(10,2),
    discount_pct NUMBER(5,2),
    total_amount NUMBER(10,2)
);

-- DIMENSION: Customers (denormalized — city, state, country all in one table)
CREATE TABLE dim_customers (
    customer_key INT,
    customer_id VARCHAR,
    name VARCHAR,
    email VARCHAR,
    city VARCHAR,           -- denormalized (no separate city table)
    state VARCHAR,          -- denormalized
    country VARCHAR,        -- denormalized
    segment VARCHAR
);

-- DIMENSION: Products (denormalized — category, subcategory in same table)
CREATE TABLE dim_products (
    product_key INT,
    product_id VARCHAR,
    product_name VARCHAR,
    category VARCHAR,       -- denormalized (no separate category table)
    subcategory VARCHAR,    -- denormalized
    brand VARCHAR
);

-- DIMENSION: Stores
CREATE TABLE dim_stores (
    store_key INT,
    store_id VARCHAR,
    store_name VARCHAR,
    city VARCHAR,
    state VARCHAR,
    region VARCHAR,
    store_type VARCHAR      -- Online, Retail, Wholesale
);

-- DIMENSION: Date
CREATE TABLE dim_date (
    date_key INT,
    full_date DATE,
    day_name VARCHAR,
    month_name VARCHAR,
    quarter INT,
    year INT,
    is_weekend BOOLEAN
);
```

### Querying a Star Schema:
```sql
-- "Total revenue by product category and quarter"
SELECT
    p.category,
    d.quarter,
    d.year,
    SUM(f.total_amount) AS revenue,
    COUNT(*) AS transactions
FROM fct_sales f
JOIN dim_products p ON f.product_key = p.product_key
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY p.category, d.quarter, d.year
ORDER BY d.year, d.quarter;
```

### Pros and Cons:

| Pros | Cons |
|------|------|
| Simple to understand and query | Data redundancy in dimensions |
| Fast queries (few JOINs) | Dimension tables can be wide |
| BI tools work well with it | Not normalized (storage overhead) |
| Easy to add new dimensions | Updates require changing many rows |

---

## 5. SNOWFLAKE SCHEMA

An extension of star schema where **dimension tables are normalized** into sub-dimensions.

```
                           dim_customers
                                │
                                │ customer_key
                                │
dim_categories ── dim_products ── fct_orders ── dim_date
                                │
                                │ store_key
                                │
                    dim_stores ── dim_regions
```

### Difference from Star:

| Aspect | Star Schema | Snowflake Schema |
|--------|------------|-----------------|
| Dimensions | Flat/denormalized | Normalized into sub-tables |
| JOINs | 1 level (fact → dim) | Multi-level (fact → dim → sub-dim) |
| Redundancy | More (data repeated in dims) | Less (normalized) |
| Query speed | Faster (fewer JOINs) | Slower (more JOINs) |
| Storage | More | Less |
| Complexity | Simple | More complex |

### Example Snowflake Schema:

```sql
-- Star schema dim_products (denormalized):
-- product_key, name, category, subcategory, brand

-- Snowflake schema (normalized into sub-tables):
CREATE TABLE dim_products (
    product_key INT,
    product_id VARCHAR,
    product_name VARCHAR,
    subcategory_key INT,    -- FK → dim_subcategories (not flat!)
    brand_key INT           -- FK → dim_brands (not flat!)
);

CREATE TABLE dim_subcategories (
    subcategory_key INT,
    subcategory_name VARCHAR,
    category_key INT        -- FK → dim_categories
);

CREATE TABLE dim_categories (
    category_key INT,
    category_name VARCHAR,
    department VARCHAR
);

CREATE TABLE dim_brands (
    brand_key INT,
    brand_name VARCHAR,
    manufacturer VARCHAR,
    country_of_origin VARCHAR
);
```

### Querying a Snowflake Schema:
```sql
-- Same query as star, but needs more JOINs:
SELECT
    c.category_name,
    d.quarter,
    SUM(f.total_amount) AS revenue
FROM fct_sales f
JOIN dim_products p ON f.product_key = p.product_key
JOIN dim_subcategories sc ON p.subcategory_key = sc.subcategory_key
JOIN dim_categories c ON sc.category_key = c.category_key   -- extra JOIN!
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY c.category_name, d.quarter;
```

### When to use Snowflake Schema:
- Dimensions have hierarchies (category → subcategory → product)
- Storage is a concern (avoid repeating "Electronics" 10 million times)
- Data quality matters (update category name in ONE place)
- NOT recommended for most modern data warehouses (Snowflake/BigQuery handle denormalization efficiently)

> **Modern recommendation:** Use **Star Schema**. Modern columnar warehouses like Snowflake compress repeated strings so efficiently that the storage "savings" of snowflake schema are negligible, while the extra JOINs hurt query performance.

---

## 6. OTHER DATA MODELING APPROACHES

### 6.1 Data Vault

Designed for enterprise-scale, audit-friendly, historically-tracked data warehousing.

**Three object types:**

| Object | Purpose | Example |
|--------|---------|---------|
| **Hub** | Business keys (unique identifiers) | Hub_Customer (customer_id) |
| **Link** | Relationships between hubs | Link_Order (customer_id ↔ product_id) |
| **Satellite** | Descriptive attributes + history | Sat_Customer (name, email, valid_from) |

```
Hub_Customer ──── Link_Order ──── Hub_Product
     │                                  │
Sat_Customer                      Sat_Product
(name, email,                     (name, price,
 valid_from,                       valid_from,
 valid_to)                         valid_to)
```

**When to use:** Enterprise DWH with strict audit requirements, multiple sources feeding same entities, need full history of every change.

### 6.2 One Big Table (OBT)

Fully denormalized — everything in a single wide table.

```sql
CREATE TABLE obt_sales (
    order_id INT,
    order_date DATE,
    customer_name VARCHAR,
    customer_email VARCHAR,
    customer_city VARCHAR,
    customer_state VARCHAR,
    product_name VARCHAR,
    product_category VARCHAR,
    store_name VARCHAR,
    store_region VARCHAR,
    quantity INT,
    amount NUMBER(10,2)
);
```

**When to use:** Simple dashboards, small datasets, BI tools that struggle with JOINs. Avoid for large-scale or complex analytics.

### 6.3 Activity Schema

One wide fact table for ALL event types + sparse columns.

```sql
CREATE TABLE activity_stream (
    activity_id INT,
    entity_id INT,           -- customer_id, order_id, etc.
    activity_type VARCHAR,   -- 'page_view', 'purchase', 'signup'
    activity_date TIMESTAMP,
    -- Sparse columns (NULL for irrelevant activities):
    page_url VARCHAR,        -- only for page_view
    amount NUMBER,           -- only for purchase
    referral_source VARCHAR  -- only for signup
);
```

---

## 7. SLOWLY CHANGING DIMENSIONS (SCD)

Dimensions change over time (customer moves city, product changes price). SCD defines HOW you handle these changes.

### SCD Type 0: RETAIN ORIGINAL

Never update. Keep the original value forever.

```
BEFORE:  customer_key=1, name="Rahul", city="Mumbai"
AFTER:   customer_key=1, name="Rahul", city="Mumbai"  ← unchanged!
(Even though Rahul moved to Delhi, we keep Mumbai)
```

**When:** Attributes that should never change (date of birth, original registration date).

### SCD Type 1: OVERWRITE

Simply overwrite the old value. No history preserved.

```
BEFORE:  customer_key=1, name="Rahul", city="Mumbai"
UPDATE:  Rahul moves to Delhi
AFTER:   customer_key=1, name="Rahul", city="Delhi"  ← overwritten!
```

```sql
UPDATE dim_customers SET city = 'Delhi' WHERE customer_key = 1;
```

**When:** History doesn't matter (correcting typos, non-critical attributes).

### SCD Type 2: ADD NEW ROW (Most Common)

Keep full history by adding a new row for each change with valid_from/valid_to.

```
BEFORE:
| customer_key | customer_id | name  | city   | valid_from | valid_to   | is_current |
|-------------|-------------|-------|--------|------------|------------|------------|
| 1           | C101        | Rahul | Mumbai | 2024-01-01 | NULL       | TRUE       |

AFTER (Rahul moves to Delhi on June 5):
| customer_key | customer_id | name  | city   | valid_from | valid_to   | is_current |
|-------------|-------------|-------|--------|------------|------------|------------|
| 1           | C101        | Rahul | Mumbai | 2024-01-01 | 2024-06-05 | FALSE      |
| 2           | C101        | Rahul | Delhi  | 2024-06-05 | NULL       | TRUE       |
```

```sql
-- Close old row
UPDATE dim_customers
SET valid_to = '2024-06-05', is_current = FALSE
WHERE customer_id = 'C101' AND is_current = TRUE;

-- Insert new row
INSERT INTO dim_customers VALUES
(2, 'C101', 'Rahul', 'Delhi', '2024-06-05', NULL, TRUE);
```

**When:** Need full history (compliance, audit, "what was the value on date X?").

> **This is what dbt snapshots implement automatically!**

### SCD Type 3: ADD NEW COLUMN

Keep limited history by adding a "previous" column.

```
BEFORE:
| customer_key | name  | current_city | previous_city |
|-------------|-------|-------------|---------------|
| 1           | Rahul | Mumbai      | NULL          |

AFTER:
| customer_key | name  | current_city | previous_city |
|-------------|-------|-------------|---------------|
| 1           | Rahul | Delhi       | Mumbai        |
```

```sql
UPDATE dim_customers
SET previous_city = current_city, current_city = 'Delhi'
WHERE customer_key = 1;
```

**When:** Only need to know current and immediately previous value. Rarely used.

### SCD Type 6: HYBRID (1+2+3 combined)

Combines Type 1 (overwrite current), Type 2 (add new row), and Type 3 (previous column).

```
| customer_key | customer_id | name  | current_city | city_at_time | valid_from | valid_to |
|-------------|-------------|-------|-------------|-------------|------------|----------|
| 1           | C101        | Rahul | Delhi       | Mumbai      | 2024-01-01 | 2024-06-05 |
| 2           | C101        | Rahul | Delhi       | Delhi       | 2024-06-05 | NULL       |
```

> `current_city` = Type 1 (always latest, overwritten on ALL rows)
> Multiple rows = Type 2 (history)
> `city_at_time` = Type 3 (value at that specific time)

### SCD Summary:

| Type | Strategy | History? | Rows per entity | Use case |
|------|----------|----------|-----------------|----------|
| 0 | Retain original | No | 1 | Fixed attributes |
| 1 | Overwrite | No | 1 | Corrections, non-critical |
| 2 | New row | Full | Multiple | Audit, compliance, analytics |
| 3 | New column | Limited (1 previous) | 1 | Rarely used |
| 6 | Hybrid 1+2+3 | Full + current | Multiple | Complex requirements |

---

## 8. SURROGATE KEYS vs NATURAL KEYS

| Aspect | Natural Key | Surrogate Key |
|--------|------------|---------------|
| Definition | Business identifier from source | Warehouse-generated ID |
| Example | `customer_id = 'CUST-101'` | `customer_key = 1` |
| Stability | Can change (email, SSN) | Never changes |
| Type | Often VARCHAR | Always INT (fast JOINs) |
| SCD Type 2 | Same across versions | Different per version |
| Use in facts | Not recommended | Used as FK |

**Best practice:** Always use surrogate keys in your warehouse. Keep natural keys for reference.

```sql
CREATE TABLE dim_customers (
    customer_key INT AUTOINCREMENT,   -- surrogate key
    customer_id VARCHAR,               -- natural key (from source)
    name VARCHAR,
    city VARCHAR,
    valid_from DATE,
    valid_to DATE
);
```

---

## 9. COMPLETE DATA ARCHITECTURE (End-to-End)

```
┌─────────────────────────────────────────────────────────────────────┐
│                      DATA ARCHITECTURE                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌─────────┐    ┌──────────┐    ┌──────────────────────────────┐   │
│  │ SOURCES │    │   ETL    │    │      DATA WAREHOUSE          │   │
│  │ (OLTP)  │    │          │    │      (OLAP)                  │   │
│  │         │    │          │    │                               │   │
│  │ MySQL   │───→│ Fivetran │───→│  RAW LAYER (sources)         │   │
│  │ Postgres│    │ Airbyte  │    │  ├── raw.customers            │   │
│  │ APIs    │    │ Kafka    │    │  ├── raw.orders               │   │
│  │ Files   │    │          │    │  └── raw.products             │   │
│  └─────────┘    └──────────┘    │           │                   │   │
│                                  │           ▼                   │   │
│                                  │  STAGING LAYER (cleaned)      │   │
│                       dbt ──────→│  ├── stg_customers (view)     │   │
│                                  │  ├── stg_orders (view)        │   │
│                                  │  └── stg_products (view)      │   │
│                                  │           │                   │   │
│                                  │           ▼                   │   │
│                                  │  MARTS LAYER (modeled)        │   │
│                                  │  ├── dim_customers (table)    │   │
│                                  │  ├── dim_products (table)     │   │
│                                  │  ├── dim_date (table/seed)    │   │
│                                  │  ├── fct_orders (table)       │   │
│                                  │  └── fct_revenue (table)      │   │
│                                  └──────────────────────────────┘   │
│                                              │                       │
│                                              ▼                       │
│                                  ┌──────────────────────┐           │
│                                  │   CONSUMPTION LAYER   │           │
│                                  │   Tableau, Looker,    │           │
│                                  │   Power BI, Python    │           │
│                                  └──────────────────────┘           │
└─────────────────────────────────────────────────────────────────────┘
```

### Layer descriptions:

| Layer | Purpose | Materialization | Naming |
|-------|---------|----------------|--------|
| **Raw** | Exact copy of source data | Table (loaded by ETL) | `raw.table_name` |
| **Staging** | Clean, rename, cast, filter | View (dbt) | `stg_table_name` |
| **Intermediate** | Business logic helpers | Ephemeral or view (dbt) | `int_description` |
| **Marts** | Final star schema (facts + dims) | Table or incremental (dbt) | `fct_` / `dim_` |

---

## 10. INTERVIEW QUESTIONS

### BEGINNER:

**Q1: What is the difference between OLTP and OLAP?**
> OLTP handles transactions (INSERT/UPDATE, point lookups, normalized). OLAP handles analytics (SELECT with aggregations, full scans, denormalized).

**Q2: What is a fact table?**
> A table that stores measurable business events (orders, clicks, payments). Contains numeric measures (amount, quantity) and foreign keys to dimension tables.

**Q3: What is a dimension table?**
> A table that stores descriptive attributes (customer name, product category, date). Gives context to the facts. Typically small and slowly changing.

**Q4: What is a star schema?**
> A data model with one fact table in the center connected to multiple dimension tables. Dimensions are denormalized (flat). Optimized for OLAP queries.

**Q5: What is the difference between a natural key and a surrogate key?**
> Natural key: business identifier from the source (customer_id). Surrogate key: warehouse-generated integer (customer_key). Surrogate keys are stable, fast for JOINs, and support SCD Type 2.

### INTERMEDIATE:

**Q6: What is the difference between star schema and snowflake schema?**
> Star: dimensions are denormalized (flat, one level of JOINs). Snowflake: dimensions are normalized into sub-tables (multiple levels of JOINs). Star is simpler and faster for queries.

**Q7: What are the types of fact tables?**
> Transaction (one row per event), Periodic Snapshot (one row per entity per period), Accumulating Snapshot (one row per lifecycle, updated at milestones).

**Q8: Explain SCD Type 2.**
> When a dimension attribute changes, the old row is closed (valid_to set) and a new row is inserted. This preserves full history. Each version has valid_from/valid_to timestamps. Current row has valid_to = NULL.

**Q9: When would you use SCD Type 1 vs Type 2?**
> Type 1: corrections, non-critical attributes where history doesn't matter. Type 2: audit-critical attributes where you need to know the value at any point in time.

**Q10: What is a degenerate dimension?**
> A dimension that has no separate table — its value lives directly in the fact table. Example: `order_number` in fct_orders. It's descriptive but doesn't need its own table.

### ADVANCED:

**Q11: You're designing a data model for an e-commerce company. Walk through your approach.**
> 1. Identify business processes (orders, payments, returns, page views)
> 2. For each process, identify the grain (one row per order line item)
> 3. Identify dimensions (customer, product, date, store, promotion)
> 4. Identify measures (quantity, amount, discount, tax)
> 5. Build star schema: fct_order_items at center, dims around it
> 6. Add SCD Type 2 for customer and product dimensions
> 7. Create a shared dim_date and dim_geography
> 8. Layer in dbt: raw → staging → intermediate → marts

**Q12: How do you handle late-arriving dimensions?**
> Insert a placeholder dimension row (customer_key=-1, name='Unknown'). When the dimension data arrives, update the placeholder. For SCD Type 2, you may need to retroactively assign the correct dimension key to fact rows.

**Q13: What is a junk dimension?**
> A dimension that combines multiple low-cardinality flags/indicators into a single table instead of having separate dimensions for each. Example: combining `is_gift_wrapped`, `is_expedited`, `payment_type` into one `dim_order_flags` table.

**Q14: What is a conformed dimension?**
> A dimension shared across multiple fact tables/business processes. Example: dim_date and dim_customers used by fct_orders, fct_returns, and fct_page_views. Ensures consistent reporting across all processes.

**Q15: Star schema vs OBT — when would you choose OBT?**
> OBT when: single-purpose dashboard, small data, BI tool limitations with JOINs. Star schema when: multiple use cases, large data, need to maintain dimensions independently, enterprise reporting with consistent definitions.

**Q16: How does SCD Type 2 affect fact table JOINs?**
> The fact table's customer_key must point to the SPECIFIC version of the customer that was active at the time of the transaction. This ensures historical accuracy: "What city was the customer in when they placed this order?" Without this, all orders would show the customer's current city.

**Q17: What is a role-playing dimension?**
> A single dimension table used multiple times in the same fact table with different meanings. Example: dim_date joined as `order_date_key`, `ship_date_key`, and `delivery_date_key` — same table, three roles.

**Q18: Design a data model for tracking employee department changes with full history.**
> - dim_employees (SCD Type 2): employee_key, emp_id, name, department, title, salary, valid_from, valid_to, is_current
> - fct_attendance: attendance_key, employee_key, date_key, hours_worked, status
> - Each department change creates a new row in dim_employees
> - Fact table links to the employee_key that was active on that date
> - Query: "What department was employee X in on March 15?" → filter dim by valid_from/valid_to

**Q19: What are the Kimball vs Inmon approaches?**
> **Kimball (bottom-up):** Build individual star schema data marts first, then integrate. Business-process focused. Faster to deliver. This is what dbt projects typically follow.
> **Inmon (top-down):** Build a centralized normalized enterprise data warehouse (3NF) first, then create data marts. More comprehensive but takes longer. Better for very large enterprises with complex integration needs.

**Q20: How would you model a many-to-many relationship in a star schema?**
> Use a **bridge table** (factless fact table). Example: a customer belongs to multiple segments, a segment has multiple customers. Create `bridge_customer_segment (customer_key, segment_key)`. Join fact → bridge → dim_segments.
