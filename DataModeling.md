# Data Modeling: From Scratch to Real Project

> This guide teaches you data modeling by building a complete E-Commerce Analytics Data Warehouse
> on Snowflake. Every concept is explained first, then immediately applied to the project.
> By the end, you will have a production-ready data model you built yourself.

---

# PART 1 — FOUNDATIONS (The "Why" and "What")

---

## Chapter 1: What is Data Modeling and Why Should You Care?

Imagine you're building a house. You wouldn't start laying bricks without a blueprint.
Data modeling is that blueprint — but for your data.

**Data Modeling** = The process of designing how data is structured, stored, related, and
accessed in a database or data warehouse.

Let's break down each of these terms with examples:

- **Structured** — Defining the shape of data: columns, data types, and constraints.
  > Example: A `CUSTOMERS` table with columns `CUSTOMER_ID INT`, `NAME VARCHAR(100)`, `EMAIL VARCHAR(255)`, `CREATED_AT TIMESTAMP`. You're deciding *what* fields exist and what types they hold.

- **Stored** — Deciding *how* and *where* data physically lives: table types, partitioning, materialization strategy.
  > Example: Choosing to store daily sales as a **Dynamic Table** that auto-refreshes, vs. a regular table loaded by a batch job, vs. a view that computes on the fly. In dbt terms, choosing `materialized='table'` vs `materialized='view'`.

- **Related** — Defining how tables connect to each other via keys and joins (relationships).
  > Example: `ORDERS.CUSTOMER_ID` references `CUSTOMERS.CUSTOMER_ID` — this is a foreign key relationship. It lets you join orders to customers. A star schema has a central **fact** table (e.g., `FACT_SALES`) related to multiple **dimension** tables (`DIM_CUSTOMER`, `DIM_PRODUCT`, `DIM_DATE`).

- **Accessed** — Designing for how users and applications will query the data: indexing, clustering, access patterns.
  > Example: If analysts always filter sales by `REGION` and `DATE`, you might cluster the table on those columns (`CLUSTER BY (REGION, SALE_DATE)`) so queries run faster. Or you create a pre-aggregated summary table so dashboards don't scan billions of rows.

In short: **structured** = what the data looks like, **stored** = where/how it lives, **related** = how tables connect, **accessed** = how it's optimized for querying.

### The Real-World Problem

Without data modeling, this happens:
```
❌ Analyst: "What was our revenue last month?"
❌ Engineer: "Which revenue? The orders table has 'amount', the payments table has 'total',
             and the invoices table has 'revenue'. They all show different numbers."
❌ Analyst: "...I don't know. Just give me something."
```

With proper data modeling:
```
✅ Analyst: "What was our revenue last month?"
✅ Engineer: "SELECT SUM(revenue) FROM fact_sales WHERE month = last_month"
✅ Result: $2,450,000 — one source of truth, always consistent.
```

### What Data Modeling Gives You

| Problem Without Modeling       | Solution With Modeling              |
|-------------------------------|-------------------------------------|
| Duplicate/conflicting data     | Single source of truth              |
| Slow queries (scanning everything) | Optimized structure for fast reads |
| Nobody knows what data means   | Clear definitions and relationships |
| Changing one thing breaks everything | Flexible, maintainable design   |
| Can't answer new business questions | Model supports evolving needs    |

---

## Chapter 2: The Three Levels of Data Modeling

Every data model goes through three stages. Think of it as zooming in.

### Level 1: Conceptual Model — "The Napkin Sketch"

**Who:** Business stakeholders, product managers
**What:** Just entities and relationships. No columns, no data types.
**Purpose:** Everyone agrees on WHAT data exists and HOW things connect.

For our E-Commerce project:
```
┌──────────┐    places     ┌─────────┐    contains    ┌──────────┐
│ CUSTOMER │──────────────>│  ORDER  │───────────────>│ PRODUCT  │
└──────────┘               └─────────┘                └──────────┘
                               │
                               │ paid via
                               ▼
                          ┌──────────┐
                          │ PAYMENT  │
                          └──────────┘
```

**Key question at this stage:** "What are the main things (entities) our business cares about?"

For e-commerce: Customers, Orders, Products, Payments, Categories, Stores/Channels.

### Level 2: Logical Model — "The Architect's Drawing"

**Who:** Data architects, analysts, data engineers
**What:** Entities + all attributes + keys + relationships + data types
**Purpose:** Define EXACTLY what each entity contains, independent of any specific database.

For our E-Commerce project:
```
CUSTOMER                    ORDER                       ORDER_ITEM
─────────────────           ─────────────────           ─────────────────
customer_id (PK)            order_id (PK)               order_item_id (PK)
first_name : string         customer_id (FK)            order_id (FK)
last_name : string          order_date : date           product_id (FK)
email : string              status : string             quantity : integer
phone : string              shipping_address : string   unit_price : decimal
city : string               total_amount : decimal      discount : decimal
state : string              
country : string            PRODUCT                     PAYMENT
signup_date : date          ─────────────────           ─────────────────
segment : string            product_id (PK)             payment_id (PK)
                            product_name : string       order_id (FK)
                            category_id (FK)            payment_method : string
                            brand : string              amount : decimal
                            price : decimal             payment_date : date
                            cost : decimal              status : string

                            CATEGORY
                            ─────────────────
                            category_id (PK)
                            category_name : string
                            department : string
```

**Key questions at this stage:**
- What attributes does each entity have?
- What uniquely identifies each entity? (Primary Key)
- How do entities connect? (Foreign Keys)
- What are the relationships? (one-to-many, many-to-many)

### Level 3: Physical Model — "The Construction Blueprint"

**Who:** Database developers, data engineers
**What:** Actual CREATE TABLE statements for a specific database (Snowflake)
**Purpose:** The exact implementation — data types, constraints, storage options.

(We'll build this in Part 3 when we construct the project.)

### How the Three Levels Flow Together

```
Business says:  "We sell products to customers through orders"
                            │
                            ▼
Conceptual:     Customer ──> Order ──> Product
                            │
                            ▼
Logical:        customer_id(PK), first_name, email...
                order_id(PK), customer_id(FK), order_date...
                            │
                            ▼
Physical:       CREATE TABLE dim_customer (
                  customer_key INT AUTOINCREMENT,
                  customer_id VARCHAR(20),
                  ...
                );
```

---

## Chapter 3: Relationships and Cardinality

Relationships define how entities connect. Getting this right is CRITICAL.

### One-to-Many (1:M) — Most Common

One customer can place MANY orders, but each order belongs to ONE customer.

```
CUSTOMER (1) ────────>> ORDER (Many)

customer_id = 'C001'  ──>  order_id = 'O001'
                           order_id = 'O002'
                           order_id = 'O003'
```

**Implementation:** Put the FK on the "many" side.
```sql
-- The FK (customer_id) lives in the orders table
CREATE TABLE orders (
    order_id INT PRIMARY KEY,
    customer_id INT REFERENCES customers(customer_id)  -- FK here
);
```

### One-to-One (1:1) — Rare

One employee has ONE parking spot. One user has ONE profile.

```
EMPLOYEE (1) ──────── PARKING_SPOT (1)
```

### Many-to-Many (M:N) — Needs a Bridge Table

One order can contain MANY products. One product can appear in MANY orders.

```
ORDER (Many) ──────── ORDER_ITEM (Bridge) ──────── PRODUCT (Many)
```

**Implementation:** Create a bridge/junction table.
```sql
-- Bridge table breaks M:N into two 1:M relationships
CREATE TABLE order_items (
    order_item_id INT PRIMARY KEY,
    order_id INT REFERENCES orders(order_id),
    product_id INT REFERENCES products(product_id),
    quantity INT,
    unit_price DECIMAL(10,2)
);
```

### Quick Cardinality Reference

| Relationship | Example                        | FK Placement          |
|-------------|--------------------------------|-----------------------|
| 1:1         | User → Profile                 | Either table          |
| 1:M         | Customer → Orders              | On the "many" side    |
| M:N         | Orders ↔ Products              | Bridge table needed   |

---

## Chapter 4: Normalization — Eliminating Data Problems

Normalization is a step-by-step process to remove data redundancy and anomalies.

### Why Normalize? The Problem with Redundant Data

Look at this un-normalized table:

| order_id | customer_name | customer_email      | product_name | product_category | quantity | price |
|----------|--------------|---------------------|--------------|-----------------|----------|-------|
| 1        | John Smith   | john@email.com      | Laptop       | Electronics     | 1        | 999   |
| 2        | John Smith   | john@email.com      | Mouse        | Electronics     | 2        | 29    |
| 3        | Jane Doe     | jane@email.com      | Laptop       | Electronics     | 1        | 999   |
| 4        | John Smith   | john_new@email.com  | Keyboard     | Electronics     | 1        | 79    |

**Problems:**
1. **Update Anomaly:** John's email changed but only in row 4. Now we have conflicting data.
2. **Insert Anomaly:** We can't add a new product without creating a fake order.
3. **Delete Anomaly:** If we delete order 3, we lose Jane Doe entirely.

Normalization fixes ALL of these.

### First Normal Form (1NF): Atomic Values

**Rule:** Every column must contain a single, indivisible value. No lists, no arrays, no repeating groups.

❌ **Violates 1NF:**
| order_id | products              |
|----------|-----------------------|
| 1        | Laptop, Mouse, Cable  |

✅ **After 1NF:**
| order_id | product  |
|----------|----------|
| 1        | Laptop   |
| 1        | Mouse    |
| 1        | Cable    |

**Think of it as:** One cell = one value. Period.

### Second Normal Form (2NF): No Partial Dependencies

**Rule:** Every non-key column must depend on the ENTIRE primary key, not just part of it.
(Only applies when you have a composite primary key.)

❌ **Violates 2NF:** (Composite PK: order_id + product_id)
| order_id | product_id | product_name | quantity |
|----------|------------|--------------|----------|
| 1        | 101        | Laptop       | 2        |
| 2        | 101        | Laptop       | 1        |

`product_name` depends ONLY on `product_id`, not on the full key (order_id + product_id).

✅ **After 2NF:** Split into two tables:
```
order_items:  order_id, product_id, quantity      ← quantity depends on full key
products:     product_id, product_name            ← product_name depends on product_id only
```

**Think of it as:** If a column only needs PART of the key to be identified, it belongs in its own table.

### Third Normal Form (3NF): No Transitive Dependencies

**Rule:** No non-key column should depend on another non-key column.

❌ **Violates 3NF:**
| employee_id | department_id | department_name | department_head |
|-------------|---------------|-----------------|-----------------|

`department_name` and `department_head` depend on `department_id` (a non-key column), NOT on `employee_id`.

✅ **After 3NF:**
```
employees:    employee_id, department_id
departments:  department_id, department_name, department_head
```

**Think of it as:** If column A determines column B, and column A is not a key, then column B belongs in a separate table with A as its key.

### Boyce-Codd Normal Form (BCNF): The Strict Version

**Rule:** Every determinant must be a candidate key. (Handles edge cases 3NF misses.)

In practice, if your model is in 3NF, it's almost always in BCNF too.

### Normalization Summary

```
Raw Data ──> 1NF (atomic values)
         ──> 2NF (no partial deps)
         ──> 3NF (no transitive deps)
         ──> BCNF (strict 3NF)
```

| Form | Rule                                | Memory Aid                                |
|------|-------------------------------------|-------------------------------------------|
| 1NF  | Atomic values, unique rows          | "One cell, one value"                     |
| 2NF  | No partial dependencies             | "Whole key, nothing but the key"          |
| 3NF  | No transitive dependencies          | "Nothing but the key, so help me Codd"    |

---

## Chapter 5: OLTP vs OLAP — Two Different Worlds

This is the most important concept to understand before choosing a modeling approach.

### OLTP (Online Transaction Processing)

**Purpose:** Run the business. Process transactions in real-time.
**Examples:** E-commerce checkout, banking transfers, CRM updates.

```
INSERT INTO orders VALUES (12345, 'C001', NOW(), 'pending', 149.99);
UPDATE inventory SET stock = stock - 1 WHERE product_id = 'P100';
```

**Characteristics:**
- Many small, fast read/write operations
- Normalized (3NF) to avoid update anomalies
- Current state only (no history needed)
- Row-oriented storage

### OLAP (Online Analytical Processing)

**Purpose:** Analyze the business. Answer questions, generate reports, find trends.
**Examples:** Monthly revenue reports, customer segmentation, sales forecasts.

```sql
SELECT
    d.month_name,
    p.category,
    SUM(f.revenue) AS total_revenue,
    COUNT(DISTINCT f.customer_key) AS unique_customers
FROM fact_sales f
JOIN dim_date d ON f.date_key = d.date_key
JOIN dim_product p ON f.product_key = p.product_key
GROUP BY d.month_name, p.category
ORDER BY total_revenue DESC;
```

**Characteristics:**
- Few complex, read-heavy analytical queries
- Denormalized for fast reads (fewer JOINs)
- Historical data (track changes over time)
- Columnar storage (Snowflake is columnar)

### Side-by-Side Comparison

| Aspect           | OLTP                       | OLAP                         |
|------------------|----------------------------|------------------------------|
| Purpose          | Run the business           | Analyze the business         |
| Operations       | INSERT, UPDATE, DELETE     | SELECT (reads)               |
| Query type       | Simple, single-row         | Complex, aggregating millions|
| Normalization    | Highly normalized (3NF)    | Denormalized (Star Schema)   |
| Data scope       | Current state              | Historical + current         |
| Users            | Applications, customers    | Analysts, executives         |
| Example DB       | PostgreSQL, MySQL          | Snowflake, BigQuery, Redshift|

### Where Data Modeling Fits

```
Source Systems (OLTP)              Data Warehouse (OLAP)
┌─────────────────┐                ┌──────────────────────┐
│ E-commerce DB   │──┐             │                      │
│ (Normalized)    │  │   ETL/ELT   │  Star Schema         │
├─────────────────┤  ├────────────>│  (Denormalized)      │
│ CRM System      │  │             │                      │
│ (Normalized)    │──┤             │  fact_sales           │
├─────────────────┤  │             │  dim_customer         │
│ Payment Gateway │  │             │  dim_product          │
│ (API/JSON)      │──┘             │  dim_date             │
└─────────────────┘                └──────────────────────┘
                                              │
                                              ▼
                                   ┌──────────────────────┐
                                   │  Dashboards & Reports│
                                   │  (Tableau, Power BI) │
                                   └──────────────────────┘
```

**Our project focuses on the OLAP side** — building the data warehouse model.

---

## Chapter 6: Dimensional Modeling — The Star Schema

This is the core technique for OLAP data modeling. Invented by Ralph Kimball.

### The Two Building Blocks

**1. Fact Table** — WHAT happened (measurements/metrics)
- Contains numeric, measurable data (revenue, quantity, discount)
- Contains foreign keys pointing to dimension tables
- Usually the largest table (millions/billions of rows)
- Named with prefix `fact_`

**2. Dimension Table** — WHO, WHAT, WHERE, WHEN, HOW, WHY
- Contains descriptive context about the facts
- Used for filtering, grouping, and labeling
- Usually smaller (thousands to millions of rows)
- Named with prefix `dim_`

### How to Identify Facts vs Dimensions

Ask yourself:

| Question                          | Answer = Fact or Dimension?  |
|-----------------------------------|------------------------------|
| Can you add it up / average it?   | **Fact** (measure)           |
| Can you filter or group by it?    | **Dimension** (attribute)    |
| Is it a number you'd SUM/AVG?    | **Fact**                     |
| Is it a label, name, or category? | **Dimension**                |

**Examples:**
- Revenue = $149.99 → **Fact** (you SUM it)
- Product category = "Electronics" → **Dimension** (you GROUP BY it)
- Quantity = 3 → **Fact** (you SUM it)
- Customer city = "Mumbai" → **Dimension** (you filter by it)
- Order date = "2025-03-15" → **Dimension** (you filter/group by it)

### The Star Schema Shape

```
                         ┌──────────────┐
                         │   dim_date   │
                         │──────────────│
                         │ date_key     │
                         │ full_date    │
                         │ day_of_week  │
                         │ month_name   │
                         │ quarter      │
                         │ year         │
                         │ is_weekend   │
                         │ is_holiday   │
                         └──────┬───────┘
                                │
┌──────────────┐         ┌──────┴───────┐         ┌──────────────┐
│ dim_customer │         │  fact_sales  │         │ dim_product  │
│──────────────│         │──────────────│         │──────────────│
│ customer_key │────────>│ sale_id      │<────────│ product_key  │
│ customer_id  │         │ date_key(FK) │         │ product_id   │
│ first_name   │         │ customer_key │         │ product_name │
│ last_name    │         │ product_key  │         │ category     │
│ email        │         │ store_key    │         │ brand        │
│ city         │         │ quantity     │         │ price        │
│ state        │         │ unit_price   │         │ cost         │
│ country      │         │ revenue      │         └──────────────┘
│ segment      │         │ discount     │
└──────────────┘         │ cost_amount  │         ┌──────────────┐
                         └──────┬───────┘         │  dim_store   │
                                │                 │──────────────│
                                └────────────────>│ store_key    │
                                                  │ store_name   │
                                                  │ store_type   │
                                                  │ city         │
                                                  │ country      │
                                                  └──────────────┘
```

It's called a "star" because the fact table sits in the center and dimensions radiate outward like points of a star.

### Star Schema vs Snowflake Schema

**Snowflake Schema** = Star Schema but dimensions are further normalized.

```
Star Schema:     dim_product has columns: product_name, category_name, department
Snowflake Schema: dim_product has category_key → dim_category has category_name, department
```

| Aspect           | Star Schema              | Snowflake Schema              |
|------------------|--------------------------|-------------------------------|
| Dimension tables | Flat / denormalized      | Normalized into sub-tables    |
| Joins needed     | Fewer                    | More                          |
| Query speed      | Faster                   | Slightly slower               |
| Storage          | More redundancy          | Less redundancy               |
| Complexity       | Simple                   | More complex                  |
| Recommendation   | **Use this by default**  | Only if storage is critical   |

**For our project, we will use the Star Schema** — it's simpler, faster, and the industry standard.

---

## Chapter 7: Fact Table Deep Dive

### Three Types of Fact Tables

#### Type 1: Transaction Fact — "One Row Per Event"
```
Every time a sale happens, one row is inserted.

| sale_id | date_key | customer_key | product_key | quantity | revenue |
|---------|----------|-------------|-------------|----------|---------|
| 1       | 20250101 | 1001        | 5001        | 2        | 199.98  |
| 2       | 20250101 | 1002        | 5003        | 1        | 49.99   |
| 3       | 20250102 | 1001        | 5001        | 1        | 99.99   |
```
**Use when:** You need full transaction-level detail.
**Our project uses this type.**

#### Type 2: Periodic Snapshot — "One Row Per Period"
```
End-of-day account balances:

| date_key | account_key | balance    | transactions_count |
|----------|-------------|------------|--------------------|
| 20250101 | 2001        | 15,420.00  | 12                 |
| 20250102 | 2001        | 14,890.00  | 8                  |
| 20250103 | 2001        | 16,200.00  | 15                 |
```
**Use when:** You need to track state at regular intervals.

#### Type 3: Accumulating Snapshot — "One Row Per Lifecycle"
```
Order fulfillment pipeline:

| order_key | order_date | paid_date  | shipped_date | delivered_date | amount  |
|-----------|-----------|------------|-------------|----------------|---------|
| 3001      | 2025-01-01| 2025-01-01| 2025-01-03  | 2025-01-07     | 299.99  |
| 3002      | 2025-01-02| 2025-01-02| NULL        | NULL           | 149.99  |
```
**Use when:** You need to track an entity through milestones.

### Measures: Additive, Semi-Additive, Non-Additive

| Type           | Can SUM across... | Example                | Note                         |
|----------------|-------------------|------------------------|------------------------------|
| Additive       | All dimensions    | Revenue, Quantity      | Most common, easiest         |
| Semi-Additive  | Some dimensions   | Account Balance        | Can't SUM across time        |
| Non-Additive   | None              | Unit Price, Ratio      | Must AVG or use in formulas  |

### The Grain — The Most Critical Decision

**Grain** = What does ONE row in your fact table represent?

You MUST define this BEFORE designing any fact table.

```
"Each row in fact_sales represents ONE product sold in ONE order by ONE customer
at ONE store on ONE date."
```

Wrong grain = wrong numbers. If the grain is "one per order" but you also store line items,
you'll double-count revenue when joining.

**Rules:**
1. Define the grain in a plain English sentence
2. All facts (measures) must be true at that grain
3. All dimension foreign keys must be valid at that grain
4. When in doubt, go with the LOWEST grain (most detail) — you can always aggregate up

---

## Chapter 8: Dimension Table Deep Dive

### The Date Dimension — Every Project Needs One

The date dimension is special: you pre-generate it with ALL possible dates, then join to it.

Why not just use `order_date` directly?
- You can't GROUP BY "month name" or "quarter" without a date dimension
- You can't flag holidays, weekends, fiscal periods
- You'd repeat date logic in every single query

```sql
-- A date dimension row looks like this:
date_key:       20250315
full_date:      2025-03-15
day_of_week:    Saturday
day_name:       Saturday
month_number:   3
month_name:     March
quarter:        Q1
year:           2025
is_weekend:     TRUE
is_holiday:     FALSE
fiscal_quarter: FQ4
```

### Slowly Changing Dimensions (SCD) — Handling Change Over Time

Dimension data changes. A customer moves cities. A product gets re-categorized.
How you handle this is one of the most important decisions in data modeling.

#### SCD Type 0 — Never Update
Keep the original value forever. Simple. Use for immutable facts.
```
Use for: Date of birth, original signup date, SSN
```

#### SCD Type 1 — Overwrite
Replace old value with new value. History is lost.
```
Before: customer_key=1001, city='New York'
After:  customer_key=1001, city='Los Angeles'

"New York" is gone forever.
```
**Use for:** Typo corrections, non-critical updates where history doesn't matter.

#### SCD Type 2 — Add New Row (MOST IMPORTANT)

Create a NEW row for each change. Keep full history.

```
customer_key | customer_id | city        | effective_date | expiry_date | is_current
1001         | C001        | New York    | 2023-01-01     | 2025-06-15  | FALSE
1002         | C001        | Los Angeles | 2025-06-15     | 9999-12-31  | TRUE
```

**Key columns:**
- `customer_key` = surrogate key (different for each version)
- `customer_id` = natural/business key (same across versions)
- `effective_date` = when this version became active
- `expiry_date` = when this version expired (9999-12-31 = still active)
- `is_current` = convenience flag for easy filtering

**Querying SCD Type 2:**
```sql
-- Current state only
SELECT * FROM dim_customer WHERE is_current = TRUE;

-- Historical: what city was customer C001 in on 2024-01-01?
SELECT * FROM dim_customer
WHERE customer_id = 'C001'
  AND '2024-01-01' BETWEEN effective_date AND expiry_date;
```

**Use for:** Any attribute where you need to analyze historical changes.
**Our project implements SCD Type 2 for the customer dimension.**

#### SCD Type 3 — Add Columns for Previous Value

```
customer_key | customer_id | current_city  | previous_city | city_changed_on
1001         | C001        | Los Angeles   | New York      | 2025-06-15
```

**Use for:** When you only need to track ONE previous value. Rarely used.

#### SCD Comparison

| Type | Tracks History? | Storage Growth | Complexity | When to Use                      |
|------|----------------|----------------|------------|----------------------------------|
| 0    | No             | None           | Trivial    | Immutable data                   |
| 1    | No             | None           | Easy       | Corrections, non-critical        |
| 2    | Full history   | Grows over time| Moderate   | Audit trails, trend analysis     |
| 3    | One change     | Fixed          | Moderate   | Rare, limited use case           |

### Surrogate Keys vs Natural Keys

| Aspect          | Surrogate Key                     | Natural Key                      |
|-----------------|-----------------------------------|----------------------------------|
| What it is      | System-generated integer (1,2,3)  | Business identifier (CUST-001)   |
| Changes?        | Never                             | Can change (email, phone)        |
| Join speed      | Fast (integer comparison)         | Slower (string comparison)       |
| Size            | 4-8 bytes                         | Variable (often larger)          |
| Meaning         | None (just a number)              | Business meaning                 |
| Best practice   | **PK in dimension tables**        | Keep as an attribute             |

**Rule:** ALWAYS use surrogate keys as PKs in your dimension tables. Keep the natural key as a regular column for business lookups.

---

## Chapter 9: Denormalization — When to Break the Rules

In OLAP, you INTENTIONALLY add redundancy to make queries faster.

### Before (Normalized — 3 JOINs needed):
```sql
SELECT c.customer_name, p.product_name, cat.category_name, SUM(oi.quantity)
FROM orders o
JOIN customers c ON o.customer_id = c.customer_id
JOIN order_items oi ON o.order_id = oi.order_id
JOIN products p ON oi.product_id = p.product_id
JOIN categories cat ON p.category_id = cat.category_id
GROUP BY c.customer_name, p.product_name, cat.category_name;
```

### After (Denormalized Star Schema — 2 JOINs needed):
```sql
SELECT dc.customer_name, dp.product_name, dp.category_name, SUM(f.quantity)
FROM fact_sales f
JOIN dim_customer dc ON f.customer_key = dc.customer_key
JOIN dim_product dp ON f.product_key = dp.product_key
GROUP BY dc.customer_name, dp.product_name, dp.category_name;
```

Notice: `category_name` is embedded directly in `dim_product`. One less JOIN.

### When to Normalize vs Denormalize

| Scenario                              | Approach          |
|---------------------------------------|-------------------|
| Source system / transactional DB       | Normalize (3NF)   |
| Data warehouse / analytics            | Denormalize (Star) |
| Staging layer in a data pipeline      | Keep as-is (raw)  |
| Frequently joined small lookup tables | Denormalize        |
| Rapidly changing reference data       | Normalize          |

---

## Chapter 10: Data Vault — The Enterprise Alternative

Data Vault is designed for large enterprises with many source systems that change frequently.

### Three Components

```
┌──────────┐          ┌──────────┐          ┌──────────┐
│   HUB    │          │   LINK   │          │SATELLITE │
│──────────│          │──────────│          │──────────│
│ Bus. Key │◄────────>│ FK to Hub│          │ Hub/Link │
│ Load Date│          │ FK to Hub│          │ Attributes│
│ Source   │          │ Load Date│          │ Load Date│
└──────────┘          │ Source   │          │ Source   │
                      └──────────┘          └──────────┘
```

- **Hub:** Business keys only (customer_id, order_id). Never changes.
- **Link:** Relationships between hubs (customer placed order).
- **Satellite:** Descriptive attributes + history (customer name, address — timestamped).

### When to Use Data Vault vs Star Schema

| Aspect             | Star Schema                  | Data Vault                      |
|--------------------|------------------------------|---------------------------------|
| Complexity         | Simple                       | Complex                         |
| Best for           | Reporting / BI               | Enterprise raw data warehouse   |
| Source changes      | Requires rework             | Handles easily                  |
| Auditability       | Moderate                     | Full                            |
| Query performance  | Excellent (direct)           | Needs a "business vault" layer  |
| Team size          | Small-medium                 | Large                           |
| Learning curve     | Low                          | High                            |

**Recommendation for learning:** Start with Star Schema. Move to Data Vault only when you have enterprise-scale complexity.

---

# PART 2 — DATA WAREHOUSE ARCHITECTURE

---

## Chapter 11: The Layered Data Warehouse

A modern data warehouse is organized in layers. Each layer has a specific job.

```
┌─────────────────────────────────────────────────────────────────┐
│                        DATA SOURCES                             │
│  (Databases, APIs, Files, Streams, SaaS Applications)          │
└──────────────────────────────┬──────────────────────────────────┘
                               │ Extract & Load (ELT)
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 1: RAW / STAGING  (Bronze)                               │
│  ─────────────────────────────────                              │
│  - Exact copy of source data                                    │
│  - No transformations                                           │
│  - Append-only or full refresh                                  │
│  - Schema: raw_ecommerce                                        │
│  - Tables: raw_customers, raw_orders, raw_products              │
└──────────────────────────────┬──────────────────────────────────┘
                               │ Clean, Validate, Deduplicate
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 2: STAGING / CLEANED  (Silver)                           │
│  ─────────────────────────────────                              │
│  - Data types corrected                                         │
│  - NULLs handled                                                │
│  - Duplicates removed                                           │
│  - Basic business rules applied                                 │
│  - Schema: stg_ecommerce                                        │
│  - Tables: stg_customers, stg_orders, stg_products              │
└──────────────────────────────┬──────────────────────────────────┘
                               │ Model, Aggregate, Enrich
                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  LAYER 3: PRESENTATION / ANALYTICS  (Gold)                      │
│  ─────────────────────────────────                              │
│  - Star Schema (facts + dimensions)                             │
│  - Business-friendly naming                                     │
│  - Optimized for BI tools                                       │
│  - SCD Type 2 applied                                           │
│  - Schema: analytics                                            │
│  - Tables: fact_sales, dim_customer, dim_product, dim_date      │
└─────────────────────────────────────────────────────────────────┘
```

### Why Layers Matter

| Layer    | Also Called | Purpose                  | Who Uses It           |
|----------|-----------|---------------------------|-----------------------|
| Raw      | Bronze    | Preserve source data      | Data engineers        |
| Staging  | Silver    | Clean and validate        | Data engineers        |
| Analytics| Gold      | Business-ready model      | Analysts, BI tools    |

---

## Chapter 12: ETL vs ELT

### ETL (Extract, Transform, Load) — Traditional
```
Source → [Transform in external tool] → Load into warehouse
```
Transform happens OUTSIDE the warehouse (Informatica, Talend, SSIS).

### ELT (Extract, Load, Transform) — Modern / Snowflake
```
Source → Load raw into warehouse → [Transform inside warehouse using SQL]
```
Transform happens INSIDE the warehouse using Snowflake's compute power.

**Snowflake is built for ELT.** Load raw data first, then use SQL to transform it layer by layer.

### ELT Flow for Our Project

```
Step 1: LOAD raw CSVs / source data into raw_ tables
Step 2: TRANSFORM raw_ → stg_ (clean, deduplicate, type-cast)
Step 3: TRANSFORM stg_ → dim_ and fact_ tables (star schema)
Step 4: AGGREGATE fact_ → report-ready views or tables
```

---

# PART 3 — BUILD THE PROJECT: E-Commerce Data Warehouse on Snowflake

> From this point forward, every SQL statement is part of a real, runnable project.
> Follow along step by step.

---

## Chapter 13: Project Overview

### Business Scenario

You are a data engineer at **ShopFlow**, an online retail company. Your job:
- Build a data warehouse for the analytics team
- Model data so analysts can answer questions like:
  - What is our monthly revenue by product category?
  - Who are our top customers?
  - Which products are trending?
  - How do sales compare across regions?
  - How has customer behavior changed over time?

### Architecture

```
Source Data (CSVs/Raw)
        │
        ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────────┐
│  RAW_ECOMMERCE  │────>│  STG_ECOMMERCE  │────>│     ANALYTICS       │
│  (Bronze Layer) │     │  (Silver Layer) │     │    (Gold Layer)     │
│                 │     │                 │     │                     │
│ raw_customers   │     │ stg_customers   │     │ dim_customer (SCD2) │
│ raw_products    │     │ stg_products    │     │ dim_product         │
│ raw_categories  │     │ stg_categories  │     │ dim_date            │
│ raw_orders      │     │ stg_orders      │     │ dim_store           │
│ raw_order_items │     │ stg_order_items │     │ fact_sales          │
│ raw_stores      │     │ stg_stores      │     │                     │
└─────────────────┘     └─────────────────┘     └─────────────────────┘
```

---

## Chapter 14: Step 1 — Set Up the Snowflake Environment

```sql
--------------------------------------------------------------------
-- STEP 1: CREATE THE DATABASE AND SCHEMAS
--------------------------------------------------------------------

CREATE DATABASE IF NOT EXISTS SHOPFLOW_DW;

-- Bronze layer: raw source data
CREATE SCHEMA IF NOT EXISTS SHOPFLOW_DW.RAW_ECOMMERCE;

-- Silver layer: cleaned and validated
CREATE SCHEMA IF NOT EXISTS SHOPFLOW_DW.STG_ECOMMERCE;

-- Gold layer: star schema for analytics
CREATE SCHEMA IF NOT EXISTS SHOPFLOW_DW.ANALYTICS;
```

---

## Chapter 15: Step 2 — Build the Raw Layer (Bronze)

These tables mirror your source systems exactly. No transformations.

```sql
--------------------------------------------------------------------
-- STEP 2: CREATE RAW TABLES (Bronze Layer)
-- These represent data as it arrives from source systems.
--------------------------------------------------------------------

CREATE OR REPLACE TABLE SHOPFLOW_DW.RAW_ECOMMERCE.RAW_CUSTOMERS (
    customer_id       VARCHAR(20),
    first_name        VARCHAR(100),
    last_name         VARCHAR(100),
    email             VARCHAR(255),
    phone             VARCHAR(30),
    address           VARCHAR(500),
    city              VARCHAR(100),
    state             VARCHAR(100),
    country           VARCHAR(100),
    segment           VARCHAR(50),
    signup_date       VARCHAR(30),
    loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE SHOPFLOW_DW.RAW_ECOMMERCE.RAW_PRODUCTS (
    product_id        VARCHAR(20),
    product_name      VARCHAR(300),
    category_id       VARCHAR(20),
    brand             VARCHAR(100),
    price             VARCHAR(20),
    cost              VARCHAR(20),
    weight_kg         VARCHAR(20),
    is_active         VARCHAR(10),
    loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE SHOPFLOW_DW.RAW_ECOMMERCE.RAW_CATEGORIES (
    category_id       VARCHAR(20),
    category_name     VARCHAR(100),
    department        VARCHAR(100),
    loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE SHOPFLOW_DW.RAW_ECOMMERCE.RAW_ORDERS (
    order_id          VARCHAR(20),
    customer_id       VARCHAR(20),
    store_id          VARCHAR(20),
    order_date        VARCHAR(30),
    status            VARCHAR(30),
    shipping_method   VARCHAR(50),
    total_amount      VARCHAR(20),
    loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE SHOPFLOW_DW.RAW_ECOMMERCE.RAW_ORDER_ITEMS (
    order_item_id     VARCHAR(20),
    order_id          VARCHAR(20),
    product_id        VARCHAR(20),
    quantity          VARCHAR(10),
    unit_price        VARCHAR(20),
    discount_pct      VARCHAR(10),
    loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE SHOPFLOW_DW.RAW_ECOMMERCE.RAW_STORES (
    store_id          VARCHAR(20),
    store_name        VARCHAR(200),
    store_type        VARCHAR(50),
    city              VARCHAR(100),
    state             VARCHAR(100),
    country           VARCHAR(100),
    open_date         VARCHAR(30),
    loaded_at         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

**Notice:** All columns are VARCHAR in raw tables. This is intentional — source data can be messy.
We cast to proper types in the staging layer.

---

## Chapter 16: Step 3 — Load Sample Data

```sql
--------------------------------------------------------------------
-- STEP 3: INSERT SAMPLE DATA
-- In production, this would come from an ELT tool (Fivetran, Airbyte, etc.)
--------------------------------------------------------------------

INSERT INTO SHOPFLOW_DW.RAW_ECOMMERCE.RAW_CATEGORIES VALUES
('CAT001', 'Laptops',       'Electronics',  CURRENT_TIMESTAMP()),
('CAT002', 'Smartphones',   'Electronics',  CURRENT_TIMESTAMP()),
('CAT003', 'Headphones',    'Electronics',  CURRENT_TIMESTAMP()),
('CAT004', 'T-Shirts',      'Clothing',     CURRENT_TIMESTAMP()),
('CAT005', 'Running Shoes', 'Footwear',     CURRENT_TIMESTAMP()),
('CAT006', 'Backpacks',     'Accessories',  CURRENT_TIMESTAMP());

INSERT INTO SHOPFLOW_DW.RAW_ECOMMERCE.RAW_STORES VALUES
('STR001', 'ShopFlow Online',     'Online',  'N/A',       'N/A',         'Global',  '2020-01-01', CURRENT_TIMESTAMP()),
('STR002', 'ShopFlow Mumbai',     'Retail',  'Mumbai',    'Maharashtra', 'India',   '2021-06-15', CURRENT_TIMESTAMP()),
('STR003', 'ShopFlow Delhi',      'Retail',  'New Delhi', 'Delhi',       'India',   '2022-03-01', CURRENT_TIMESTAMP()),
('STR004', 'ShopFlow Marketplace', 'Partner', 'N/A',      'N/A',         'Global',  '2023-01-01', CURRENT_TIMESTAMP());

INSERT INTO SHOPFLOW_DW.RAW_ECOMMERCE.RAW_PRODUCTS VALUES
('P001', 'ProBook Laptop 15',    'CAT001', 'TechPro',   '74999.00', '55000.00', '2.1',  'true',  CURRENT_TIMESTAMP()),
('P002', 'ProBook Laptop 13',    'CAT001', 'TechPro',   '64999.00', '48000.00', '1.5',  'true',  CURRENT_TIMESTAMP()),
('P003', 'Galaxy Phone X',       'CAT002', 'Samsung',   '49999.00', '35000.00', '0.2',  'true',  CURRENT_TIMESTAMP()),
('P004', 'iPhone Ultra',         'CAT002', 'Apple',     '89999.00', '65000.00', '0.2',  'true',  CURRENT_TIMESTAMP()),
('P005', 'BassMax Headphones',   'CAT003', 'AudioTech', '3999.00',  '1800.00',  '0.3',  'true',  CURRENT_TIMESTAMP()),
('P006', 'Classic Cotton Tee',   'CAT004', 'WearWell',  '799.00',   '250.00',   '0.2',  'true',  CURRENT_TIMESTAMP()),
('P007', 'SpeedRunner Pro',      'CAT005', 'RunFast',   '5999.00',  '3200.00',  '0.4',  'true',  CURRENT_TIMESTAMP()),
('P008', 'Urban Backpack',       'CAT006', 'PackIt',    '2499.00',  '1100.00',  '0.8',  'true',  CURRENT_TIMESTAMP()),
('P009', 'NoiseFree Buds',       'CAT003', 'AudioTech', '1999.00',  '800.00',   '0.05', 'true',  CURRENT_TIMESTAMP()),
('P010', 'GamerBook Laptop 17',  'CAT001', 'TechPro',   '124999.00','92000.00', '3.0',  'false', CURRENT_TIMESTAMP());

INSERT INTO SHOPFLOW_DW.RAW_ECOMMERCE.RAW_CUSTOMERS VALUES
('C001','Rohit',  'Sharma',  'rohit@email.com',   '+91-9876543210','123 MG Road',     'Mumbai',    'Maharashtra','India',  'Premium', '2023-01-15', CURRENT_TIMESTAMP()),
('C002','Priya',  'Patel',   'priya@email.com',   '+91-9876543211','456 Park Street',  'Bangalore', 'Karnataka', 'India',  'Regular', '2023-03-22', CURRENT_TIMESTAMP()),
('C003','Amit',   'Singh',   'amit@email.com',    '+91-9876543212','789 Civil Lines',  'Delhi',     'Delhi',     'India',  'Premium', '2023-05-10', CURRENT_TIMESTAMP()),
('C004','Sneha',  'Reddy',   'sneha@email.com',   '+91-9876543213','101 Jubilee Hills','Hyderabad', 'Telangana', 'India',  'Regular', '2023-07-01', CURRENT_TIMESTAMP()),
('C005','Vikram', 'Joshi',   'vikram@email.com',  '+91-9876543214','202 FC Road',      'Pune',      'Maharashtra','India', 'Premium', '2023-09-18', CURRENT_TIMESTAMP()),
('C006','Ananya', 'Gupta',   'ananya@email.com',  '+91-9876543215','303 Lake Road',    'Kolkata',   'West Bengal','India', 'Regular', '2024-01-05', CURRENT_TIMESTAMP()),
('C007','Raj',    'Kumar',   'raj@email.com',     '+91-9876543216','404 Anna Nagar',   'Chennai',   'Tamil Nadu', 'India', 'Regular', '2024-03-12', CURRENT_TIMESTAMP()),
('C008','Meera',  'Nair',    'meera@email.com',   '+91-9876543217','505 Marine Drive', 'Kochi',     'Kerala',    'India',  'Premium', '2024-06-20', CURRENT_TIMESTAMP());

INSERT INTO SHOPFLOW_DW.RAW_ECOMMERCE.RAW_ORDERS VALUES
('ORD001','C001','STR001','2025-01-05','Completed','Express',  '78998.00',  CURRENT_TIMESTAMP()),
('ORD002','C002','STR002','2025-01-08','Completed','Standard', '49999.00',  CURRENT_TIMESTAMP()),
('ORD003','C003','STR001','2025-01-12','Completed','Express',  '93997.00',  CURRENT_TIMESTAMP()),
('ORD004','C001','STR001','2025-01-20','Completed','Standard', '6498.00',   CURRENT_TIMESTAMP()),
('ORD005','C004','STR003','2025-02-01','Completed','Express',  '89999.00',  CURRENT_TIMESTAMP()),
('ORD006','C005','STR001','2025-02-10','Completed','Standard', '131997.00', CURRENT_TIMESTAMP()),
('ORD007','C002','STR004','2025-02-15','Completed','Express',  '4798.00',   CURRENT_TIMESTAMP()),
('ORD008','C006','STR001','2025-02-20','Shipped',  'Standard', '74999.00',  CURRENT_TIMESTAMP()),
('ORD009','C003','STR002','2025-03-01','Shipped',  'Express',  '52498.00',  CURRENT_TIMESTAMP()),
('ORD010','C007','STR001','2025-03-05','Pending',  'Standard', '799.00',    CURRENT_TIMESTAMP()),
('ORD011','C001','STR003','2025-03-10','Pending',  'Express',  '129998.00', CURRENT_TIMESTAMP()),
('ORD012','C008','STR001','2025-03-15','Completed','Standard', '9997.00',   CURRENT_TIMESTAMP()),
('ORD013','C005','STR004','2025-03-18','Shipped',  'Express',  '53998.00',  CURRENT_TIMESTAMP()),
('ORD014','C004','STR001','2025-03-20','Pending',  'Standard', '1598.00',   CURRENT_TIMESTAMP()),
('ORD015','C002','STR002','2025-03-25','Completed','Express',  '65798.00',  CURRENT_TIMESTAMP());

INSERT INTO SHOPFLOW_DW.RAW_ECOMMERCE.RAW_ORDER_ITEMS VALUES
('OI001','ORD001','P001','1','74999.00','0',   CURRENT_TIMESTAMP()),
('OI002','ORD001','P005','1','3999.00', '0',   CURRENT_TIMESTAMP()),
('OI003','ORD002','P003','1','49999.00','0',   CURRENT_TIMESTAMP()),
('OI004','ORD003','P004','1','89999.00','0',   CURRENT_TIMESTAMP()),
('OI005','ORD003','P005','1','3999.00', '0',   CURRENT_TIMESTAMP()),
('OI006','ORD004','P006','3','799.00',  '10',  CURRENT_TIMESTAMP()),
('OI007','ORD004','P009','2','1999.00', '5',   CURRENT_TIMESTAMP()),
('OI008','ORD005','P004','1','89999.00','0',   CURRENT_TIMESTAMP()),
('OI009','ORD006','P001','1','74999.00','5',   CURRENT_TIMESTAMP()),
('OI010','ORD006','P003','1','49999.00','0',   CURRENT_TIMESTAMP()),
('OI011','ORD006','P007','1','5999.00', '10',  CURRENT_TIMESTAMP()),
('OI012','ORD007','P006','2','799.00',  '0',   CURRENT_TIMESTAMP()),
('OI013','ORD007','P008','1','2499.00', '5',   CURRENT_TIMESTAMP()),
('OI014','ORD007','P009','1','1999.00', '15',  CURRENT_TIMESTAMP()),
('OI015','ORD008','P001','1','74999.00','0',   CURRENT_TIMESTAMP()),
('OI016','ORD009','P003','1','49999.00','5',   CURRENT_TIMESTAMP()),
('OI017','ORD009','P008','1','2499.00', '0',   CURRENT_TIMESTAMP()),
('OI018','ORD010','P006','1','799.00',  '0',   CURRENT_TIMESTAMP()),
('OI019','ORD011','P001','1','74999.00','0',   CURRENT_TIMESTAMP()),
('OI020','ORD011','P003','1','49999.00','10',  CURRENT_TIMESTAMP()),
('OI021','ORD011','P007','1','5999.00', '0',   CURRENT_TIMESTAMP()),
('OI022','ORD012','P005','1','3999.00', '0',   CURRENT_TIMESTAMP()),
('OI023','ORD012','P007','1','5999.00', '0',   CURRENT_TIMESTAMP()),
('OI024','ORD013','P003','1','49999.00','0',   CURRENT_TIMESTAMP()),
('OI025','ORD013','P005','1','3999.00', '0',   CURRENT_TIMESTAMP()),
('OI026','ORD014','P006','2','799.00',  '0',   CURRENT_TIMESTAMP()),
('OI027','ORD015','P002','1','64999.00','0',   CURRENT_TIMESTAMP()),
('OI028','ORD015','P006','1','799.00',  '0',   CURRENT_TIMESTAMP());
```

---

## Chapter 17: Step 4 — Build the Staging Layer (Silver)

Clean the raw data: cast types, handle NULLs, remove duplicates.

```sql
--------------------------------------------------------------------
-- STEP 4: CREATE STAGING TABLES (Silver Layer)
-- Clean, validate, and type-cast raw data.
--------------------------------------------------------------------

CREATE OR REPLACE TABLE SHOPFLOW_DW.STG_ECOMMERCE.STG_CUSTOMERS AS
SELECT
    customer_id,
    TRIM(first_name)                            AS first_name,
    TRIM(last_name)                             AS last_name,
    LOWER(TRIM(email))                          AS email,
    TRIM(phone)                                 AS phone,
    TRIM(address)                               AS address,
    TRIM(city)                                  AS city,
    TRIM(state)                                 AS state,
    TRIM(country)                               AS country,
    COALESCE(TRIM(segment), 'Unknown')          AS segment,
    TRY_TO_DATE(signup_date, 'YYYY-MM-DD')      AS signup_date,
    loaded_at
FROM SHOPFLOW_DW.RAW_ECOMMERCE.RAW_CUSTOMERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY loaded_at DESC) = 1;

CREATE OR REPLACE TABLE SHOPFLOW_DW.STG_ECOMMERCE.STG_PRODUCTS AS
SELECT
    product_id,
    TRIM(product_name)                          AS product_name,
    category_id,
    TRIM(brand)                                 AS brand,
    TRY_TO_DECIMAL(price, 12, 2)                AS price,
    TRY_TO_DECIMAL(cost, 12, 2)                 AS cost,
    TRY_TO_DECIMAL(weight_kg, 8, 2)             AS weight_kg,
    CASE LOWER(TRIM(is_active))
        WHEN 'true' THEN TRUE
        WHEN 'false' THEN FALSE
        ELSE NULL
    END                                         AS is_active,
    loaded_at
FROM SHOPFLOW_DW.RAW_ECOMMERCE.RAW_PRODUCTS
QUALIFY ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY loaded_at DESC) = 1;

CREATE OR REPLACE TABLE SHOPFLOW_DW.STG_ECOMMERCE.STG_CATEGORIES AS
SELECT
    category_id,
    TRIM(category_name)                         AS category_name,
    TRIM(department)                             AS department,
    loaded_at
FROM SHOPFLOW_DW.RAW_ECOMMERCE.RAW_CATEGORIES
QUALIFY ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY loaded_at DESC) = 1;

CREATE OR REPLACE TABLE SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDERS AS
SELECT
    order_id,
    customer_id,
    store_id,
    TRY_TO_DATE(order_date, 'YYYY-MM-DD')       AS order_date,
    UPPER(TRIM(status))                          AS status,
    TRIM(shipping_method)                        AS shipping_method,
    TRY_TO_DECIMAL(total_amount, 12, 2)          AS total_amount,
    loaded_at
FROM SHOPFLOW_DW.RAW_ECOMMERCE.RAW_ORDERS
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY loaded_at DESC) = 1;

CREATE OR REPLACE TABLE SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS AS
SELECT
    order_item_id,
    order_id,
    product_id,
    TRY_TO_NUMBER(quantity)                      AS quantity,
    TRY_TO_DECIMAL(unit_price, 12, 2)            AS unit_price,
    TRY_TO_DECIMAL(discount_pct, 5, 2)           AS discount_pct,
    loaded_at
FROM SHOPFLOW_DW.RAW_ECOMMERCE.RAW_ORDER_ITEMS
QUALIFY ROW_NUMBER() OVER (PARTITION BY order_item_id ORDER BY loaded_at DESC) = 1;

CREATE OR REPLACE TABLE SHOPFLOW_DW.STG_ECOMMERCE.STG_STORES AS
SELECT
    store_id,
    TRIM(store_name)                             AS store_name,
    TRIM(store_type)                             AS store_type,
    TRIM(city)                                   AS city,
    TRIM(state)                                  AS state,
    TRIM(country)                                AS country,
    TRY_TO_DATE(open_date, 'YYYY-MM-DD')         AS open_date,
    loaded_at
FROM SHOPFLOW_DW.RAW_ECOMMERCE.RAW_STORES
QUALIFY ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY loaded_at DESC) = 1;
```

**What's happening here:**
- `TRIM()` removes leading/trailing whitespace
- `TRY_TO_DATE()`, `TRY_TO_DECIMAL()` safely cast types (returns NULL instead of error)
- `COALESCE()` handles NULLs with default values
- `QUALIFY ROW_NUMBER()` deduplicates — keeps only the latest record per business key

---

## Chapter 18: Step 5 — Build the Analytics Layer (Gold) — The Star Schema

This is where data modeling shines. We build fact and dimension tables.

### 18.1 Dimension: dim_date (Pre-Generated Date Dimension)

```sql
--------------------------------------------------------------------
-- DIM_DATE: Pre-generated calendar dimension
-- Covers 2020 to 2030 (adjust as needed)
--------------------------------------------------------------------

CREATE OR REPLACE TABLE SHOPFLOW_DW.ANALYTICS.DIM_DATE AS
WITH date_spine AS (
    SELECT DATEADD(DAY, SEQ4(), '2020-01-01'::DATE) AS full_date
    FROM TABLE(GENERATOR(ROWCOUNT => 4018))
)
SELECT
    TO_NUMBER(TO_CHAR(full_date, 'YYYYMMDD'))       AS date_key,
    full_date,
    DATE_PART(year, full_date)                       AS year,
    DATE_PART(quarter, full_date)                    AS quarter_number,
    'Q' || DATE_PART(quarter, full_date)             AS quarter_name,
    DATE_PART(month, full_date)                      AS month_number,
    TO_CHAR(full_date, 'MMMM')                       AS month_name,
    TO_CHAR(full_date, 'MON')                         AS month_short,
    DATE_PART(week, full_date)                       AS week_of_year,
    DATE_PART(dayofweek, full_date)                  AS day_of_week_number,
    TO_CHAR(full_date, 'DY')                          AS day_of_week_short,
    DAYNAME(full_date)                                AS day_name,
    DATE_PART(day, full_date)                        AS day_of_month,
    DATE_PART(dayofyear, full_date)                  AS day_of_year,
    CASE WHEN DATE_PART(dayofweek, full_date) IN (0, 6) THEN TRUE ELSE FALSE END AS is_weekend,
    DATE_TRUNC('month', full_date)                   AS first_day_of_month,
    LAST_DAY(full_date, 'month')                     AS last_day_of_month,
    DATE_TRUNC('quarter', full_date)                 AS first_day_of_quarter,
    LAST_DAY(full_date, 'quarter')                   AS last_day_of_quarter,
    DATE_TRUNC('year', full_date)                    AS first_day_of_year,
    LAST_DAY(full_date, 'year')                      AS last_day_of_year,
    YEAR(full_date) || '-' || LPAD(MONTH(full_date), 2, '0') AS year_month
FROM date_spine
WHERE full_date <= '2030-12-31';
```

### 18.2 Dimension: dim_customer (SCD Type 2)

```sql
--------------------------------------------------------------------
-- DIM_CUSTOMER: SCD Type 2 — tracks historical changes
--------------------------------------------------------------------

CREATE OR REPLACE TABLE SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER (
    customer_key       INT AUTOINCREMENT PRIMARY KEY,
    customer_id        VARCHAR(20)   NOT NULL,
    first_name         VARCHAR(100),
    last_name          VARCHAR(100),
    full_name          VARCHAR(200),
    email              VARCHAR(255),
    phone              VARCHAR(30),
    address            VARCHAR(500),
    city               VARCHAR(100),
    state              VARCHAR(100),
    country            VARCHAR(100),
    segment            VARCHAR(50),
    signup_date        DATE,
    effective_date     DATE          NOT NULL,
    expiry_date        DATE          NOT NULL DEFAULT '9999-12-31',
    is_current         BOOLEAN       NOT NULL DEFAULT TRUE
);

INSERT INTO SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER (
    customer_id, first_name, last_name, full_name, email, phone,
    address, city, state, country, segment, signup_date,
    effective_date, expiry_date, is_current
)
SELECT
    customer_id,
    first_name,
    last_name,
    first_name || ' ' || last_name  AS full_name,
    email,
    phone,
    address,
    city,
    state,
    country,
    segment,
    signup_date,
    COALESCE(signup_date, CURRENT_DATE()) AS effective_date,
    '9999-12-31'::DATE                    AS expiry_date,
    TRUE                                  AS is_current
FROM SHOPFLOW_DW.STG_ECOMMERCE.STG_CUSTOMERS;
```

### 18.3 Dimension: dim_product (with denormalized category)

```sql
--------------------------------------------------------------------
-- DIM_PRODUCT: Denormalized with category info (Star Schema style)
--------------------------------------------------------------------

CREATE OR REPLACE TABLE SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT AS
SELECT
    ROW_NUMBER() OVER (ORDER BY p.product_id)   AS product_key,
    p.product_id,
    p.product_name,
    p.brand,
    c.category_name,
    c.department,
    p.price                                     AS current_price,
    p.cost                                      AS current_cost,
    p.price - p.cost                            AS current_margin,
    ROUND((p.price - p.cost) / NULLIF(p.price, 0) * 100, 2) AS margin_pct,
    p.weight_kg,
    p.is_active
FROM SHOPFLOW_DW.STG_ECOMMERCE.STG_PRODUCTS p
LEFT JOIN SHOPFLOW_DW.STG_ECOMMERCE.STG_CATEGORIES c
    ON p.category_id = c.category_id;
```

### 18.4 Dimension: dim_store

```sql
--------------------------------------------------------------------
-- DIM_STORE: Store/channel dimension
--------------------------------------------------------------------

CREATE OR REPLACE TABLE SHOPFLOW_DW.ANALYTICS.DIM_STORE AS
SELECT
    ROW_NUMBER() OVER (ORDER BY store_id)       AS store_key,
    store_id,
    store_name,
    store_type,
    city,
    state,
    country,
    open_date
FROM SHOPFLOW_DW.STG_ECOMMERCE.STG_STORES;
```

### 18.5 Fact Table: fact_sales

```sql
--------------------------------------------------------------------
-- FACT_SALES: The central fact table
-- Grain: One row per product per order (order line item level)
--------------------------------------------------------------------

CREATE OR REPLACE TABLE SHOPFLOW_DW.ANALYTICS.FACT_SALES AS
SELECT
    oi.order_item_id                                             AS sale_id,
    TO_NUMBER(TO_CHAR(o.order_date, 'YYYYMMDD'))                 AS date_key,
    dc.customer_key,
    dp.product_key,
    ds.store_key,
    o.order_id,
    o.status                                                     AS order_status,
    o.shipping_method,
    oi.quantity,
    oi.unit_price,
    oi.discount_pct,
    ROUND(oi.quantity * oi.unit_price, 2)                        AS gross_amount,
    ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100), 2) AS net_revenue,
    ROUND(oi.quantity * dp.current_cost, 2)                      AS cost_amount,
    ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100), 2)
        - ROUND(oi.quantity * dp.current_cost, 2)                AS profit
FROM SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS oi
JOIN SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDERS o
    ON oi.order_id = o.order_id
JOIN SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER dc
    ON o.customer_id = dc.customer_id AND dc.is_current = TRUE
JOIN SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT dp
    ON oi.product_id = dp.product_id
JOIN SHOPFLOW_DW.ANALYTICS.DIM_STORE ds
    ON o.store_id = ds.store_id;
```

---

## Chapter 19: Step 6 — Optimize for Performance

```sql
--------------------------------------------------------------------
-- STEP 6: CLUSTERING KEYS
-- Tell Snowflake how to physically organize data for faster queries.
--------------------------------------------------------------------

ALTER TABLE SHOPFLOW_DW.ANALYTICS.FACT_SALES CLUSTER BY (date_key, customer_key);

--------------------------------------------------------------------
-- STEP 6b: USEFUL VIEWS FOR COMMON QUERIES
--------------------------------------------------------------------

CREATE OR REPLACE VIEW SHOPFLOW_DW.ANALYTICS.V_SALES_SUMMARY AS
SELECT
    d.year,
    d.quarter_name,
    d.month_name,
    d.month_number,
    d.full_date,
    c.full_name          AS customer_name,
    c.city               AS customer_city,
    c.state              AS customer_state,
    c.segment            AS customer_segment,
    p.product_name,
    p.brand,
    p.category_name,
    p.department,
    s.store_name,
    s.store_type,
    f.order_id,
    f.order_status,
    f.shipping_method,
    f.quantity,
    f.unit_price,
    f.discount_pct,
    f.gross_amount,
    f.net_revenue,
    f.cost_amount,
    f.profit
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f
JOIN SHOPFLOW_DW.ANALYTICS.DIM_DATE d      ON f.date_key = d.date_key
JOIN SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER c  ON f.customer_key = c.customer_key
JOIN SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT p   ON f.product_key = p.product_key
JOIN SHOPFLOW_DW.ANALYTICS.DIM_STORE s     ON f.store_key = s.store_key;
```

---

## Chapter 20: Step 7 — SCD Type 2 in Action

Here's how to process a customer change using SCD Type 2:

```sql
--------------------------------------------------------------------
-- SCENARIO: Customer C001 (Rohit Sharma) moves from Mumbai to Pune
-- and upgrades from Premium to VIP segment.
--------------------------------------------------------------------

-- Step A: Expire the current record
UPDATE SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER
SET
    expiry_date = CURRENT_DATE(),
    is_current  = FALSE
WHERE customer_id = 'C001'
  AND is_current = TRUE;

-- Step B: Insert the new version
INSERT INTO SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER (
    customer_id, first_name, last_name, full_name, email, phone,
    address, city, state, country, segment, signup_date,
    effective_date, expiry_date, is_current
)
VALUES (
    'C001', 'Rohit', 'Sharma', 'Rohit Sharma', 'rohit@email.com', '+91-9876543210',
    '999 Koregaon Park', 'Pune', 'Maharashtra', 'India', 'VIP', '2023-01-15',
    CURRENT_DATE(), '9999-12-31', TRUE
);

-- Step C: Verify — you should see TWO rows for C001
SELECT customer_key, customer_id, full_name, city, segment,
       effective_date, expiry_date, is_current
FROM SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER
WHERE customer_id = 'C001'
ORDER BY effective_date;

-- EXPECTED RESULT:
-- customer_key | customer_id | full_name     | city     | segment | effective  | expiry     | is_current
-- 1            | C001        | Rohit Sharma  | Mumbai   | Premium | 2023-01-15 | 2026-03-31 | FALSE
-- 9            | C001        | Rohit Sharma  | Pune     | VIP     | 2026-03-31 | 9999-12-31 | TRUE
```

**The power of SCD Type 2:**
```sql
-- Old fact rows still point to customer_key=1 (Mumbai, Premium)
-- New fact rows will point to customer_key=9 (Pune, VIP)
-- Historical analysis automatically uses the correct context!
```

---

## Chapter 21: Step 8 — Validate Your Model with Analytics Queries

Now test your model by answering real business questions.

```sql
--------------------------------------------------------------------
-- QUERY 1: Monthly revenue trend
--------------------------------------------------------------------
SELECT
    d.year,
    d.month_name,
    d.month_number,
    COUNT(DISTINCT f.order_id)     AS total_orders,
    SUM(f.quantity)                 AS items_sold,
    SUM(f.net_revenue)             AS total_revenue,
    SUM(f.profit)                  AS total_profit,
    ROUND(SUM(f.profit) / NULLIF(SUM(f.net_revenue), 0) * 100, 2) AS profit_margin_pct
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f
JOIN SHOPFLOW_DW.ANALYTICS.DIM_DATE d ON f.date_key = d.date_key
GROUP BY d.year, d.month_name, d.month_number
ORDER BY d.year, d.month_number;

--------------------------------------------------------------------
-- QUERY 2: Revenue by product category and department
--------------------------------------------------------------------
SELECT
    p.department,
    p.category_name,
    COUNT(DISTINCT f.order_id)     AS orders,
    SUM(f.quantity)                 AS units_sold,
    SUM(f.net_revenue)             AS revenue,
    SUM(f.profit)                  AS profit,
    ROUND(AVG(f.discount_pct), 2)  AS avg_discount_pct
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f
JOIN SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT p ON f.product_key = p.product_key
GROUP BY p.department, p.category_name
ORDER BY revenue DESC;

--------------------------------------------------------------------
-- QUERY 3: Top customers by lifetime value
--------------------------------------------------------------------
SELECT
    c.full_name,
    c.city,
    c.segment,
    COUNT(DISTINCT f.order_id)     AS total_orders,
    SUM(f.net_revenue)             AS lifetime_revenue,
    SUM(f.profit)                  AS lifetime_profit,
    MIN(d.full_date)               AS first_purchase,
    MAX(d.full_date)               AS last_purchase
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f
JOIN SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER c ON f.customer_key = c.customer_key
JOIN SHOPFLOW_DW.ANALYTICS.DIM_DATE d ON f.date_key = d.date_key
WHERE c.is_current = TRUE
GROUP BY c.full_name, c.city, c.segment
ORDER BY lifetime_revenue DESC;

--------------------------------------------------------------------
-- QUERY 4: Sales by store type and channel
--------------------------------------------------------------------
SELECT
    s.store_type,
    s.store_name,
    COUNT(DISTINCT f.order_id)     AS orders,
    SUM(f.net_revenue)             AS revenue,
    ROUND(SUM(f.net_revenue) * 100.0 /
        SUM(SUM(f.net_revenue)) OVER (), 2) AS revenue_share_pct
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f
JOIN SHOPFLOW_DW.ANALYTICS.DIM_STORE s ON f.store_key = s.store_key
GROUP BY s.store_type, s.store_name
ORDER BY revenue DESC;

--------------------------------------------------------------------
-- QUERY 5: Product performance with margins
--------------------------------------------------------------------
SELECT
    p.product_name,
    p.brand,
    p.category_name,
    SUM(f.quantity)                 AS units_sold,
    SUM(f.net_revenue)             AS revenue,
    SUM(f.cost_amount)             AS total_cost,
    SUM(f.profit)                  AS profit,
    ROUND(SUM(f.profit) / NULLIF(SUM(f.net_revenue), 0) * 100, 2) AS profit_margin_pct
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f
JOIN SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT p ON f.product_key = p.product_key
GROUP BY p.product_name, p.brand, p.category_name
ORDER BY revenue DESC;

--------------------------------------------------------------------
-- QUERY 6: Weekend vs Weekday sales
--------------------------------------------------------------------
SELECT
    CASE WHEN d.is_weekend THEN 'Weekend' ELSE 'Weekday' END AS day_type,
    COUNT(DISTINCT f.order_id)     AS orders,
    SUM(f.net_revenue)             AS revenue,
    ROUND(AVG(f.net_revenue), 2)   AS avg_order_value
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f
JOIN SHOPFLOW_DW.ANALYTICS.DIM_DATE d ON f.date_key = d.date_key
GROUP BY day_type
ORDER BY revenue DESC;
```

---

## Chapter 22: Step 9 — Data Quality Checks

Always validate your model before handing it to analysts.

```sql
--------------------------------------------------------------------
-- DATA QUALITY CHECKS
--------------------------------------------------------------------

-- CHECK 1: Referential integrity — all fact FKs have matching dimensions
SELECT 'Missing date_key'     AS check_name, COUNT(*) AS failures FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f LEFT JOIN SHOPFLOW_DW.ANALYTICS.DIM_DATE d ON f.date_key = d.date_key WHERE d.date_key IS NULL
UNION ALL
SELECT 'Missing customer_key' AS check_name, COUNT(*) AS failures FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f LEFT JOIN SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER c ON f.customer_key = c.customer_key WHERE c.customer_key IS NULL
UNION ALL
SELECT 'Missing product_key'  AS check_name, COUNT(*) AS failures FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f LEFT JOIN SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT p ON f.product_key = p.product_key WHERE p.product_key IS NULL
UNION ALL
SELECT 'Missing store_key'    AS check_name, COUNT(*) AS failures FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES f LEFT JOIN SHOPFLOW_DW.ANALYTICS.DIM_STORE s ON f.store_key = s.store_key WHERE s.store_key IS NULL;

-- CHECK 2: No duplicate facts
SELECT 'Duplicate sale_ids' AS check_name,
       COUNT(*) - COUNT(DISTINCT sale_id) AS failures
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES;

-- CHECK 3: Revenue sanity
SELECT
    'Negative revenue' AS check_name,
    COUNT(*) AS failures
FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES
WHERE net_revenue < 0;

-- CHECK 4: SCD2 integrity — each customer_id has exactly ONE current record
SELECT 'Multiple current records' AS check_name, COUNT(*) AS failures
FROM (
    SELECT customer_id, COUNT(*) AS cnt
    FROM SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER
    WHERE is_current = TRUE
    GROUP BY customer_id
    HAVING COUNT(*) > 1
);

-- CHECK 5: Row counts across layers
SELECT 'raw_order_items'  AS layer, COUNT(*) AS row_count FROM SHOPFLOW_DW.RAW_ECOMMERCE.RAW_ORDER_ITEMS
UNION ALL
SELECT 'stg_order_items'  AS layer, COUNT(*) AS row_count FROM SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS
UNION ALL
SELECT 'fact_sales'        AS layer, COUNT(*) AS row_count FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES;
```

---

# PART 4 — BEYOND THE BASICS

---

## Chapter 23: Incremental Loading Pattern

In production, you don't rebuild everything from scratch each day. You process only new/changed data.

```sql
--------------------------------------------------------------------
-- INCREMENTAL LOAD PATTERN: Only process new order items
--------------------------------------------------------------------

-- Step 1: Find the latest loaded timestamp in fact_sales
-- (In production, track this in a metadata/audit table)

-- Step 2: Load only new records from staging
INSERT INTO SHOPFLOW_DW.ANALYTICS.FACT_SALES
SELECT
    oi.order_item_id                                             AS sale_id,
    TO_NUMBER(TO_CHAR(o.order_date, 'YYYYMMDD'))                 AS date_key,
    dc.customer_key,
    dp.product_key,
    ds.store_key,
    o.order_id,
    o.status                                                     AS order_status,
    o.shipping_method,
    oi.quantity,
    oi.unit_price,
    oi.discount_pct,
    ROUND(oi.quantity * oi.unit_price, 2)                        AS gross_amount,
    ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100), 2) AS net_revenue,
    ROUND(oi.quantity * dp.current_cost, 2)                      AS cost_amount,
    ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100), 2)
        - ROUND(oi.quantity * dp.current_cost, 2)                AS profit
FROM SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS oi
JOIN SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDERS o        ON oi.order_id = o.order_id
JOIN SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER dc          ON o.customer_id = dc.customer_id AND dc.is_current = TRUE
JOIN SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT dp           ON oi.product_id = dp.product_id
JOIN SHOPFLOW_DW.ANALYTICS.DIM_STORE ds             ON o.store_id = ds.store_id
WHERE oi.order_item_id NOT IN (SELECT sale_id FROM SHOPFLOW_DW.ANALYTICS.FACT_SALES);
```

In production, consider using:
- **Snowflake Streams** to capture changes automatically
- **Snowflake Tasks** to schedule incremental loads
- **MERGE** statements for upsert logic

---

## Chapter 24: Automating with Snowflake Streams and Tasks

```sql
--------------------------------------------------------------------
-- STREAMS: Capture changes on staging tables automatically
--------------------------------------------------------------------

CREATE OR REPLACE STREAM SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS_STREAM
ON TABLE SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS;

--------------------------------------------------------------------
-- TASKS: Schedule the incremental load to run every hour
--------------------------------------------------------------------

CREATE OR REPLACE TASK SHOPFLOW_DW.ANALYTICS.LOAD_FACT_SALES_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = '60 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS_STREAM')
AS
    INSERT INTO SHOPFLOW_DW.ANALYTICS.FACT_SALES
    SELECT
        oi.order_item_id                                             AS sale_id,
        TO_NUMBER(TO_CHAR(o.order_date, 'YYYYMMDD'))                 AS date_key,
        dc.customer_key,
        dp.product_key,
        ds.store_key,
        o.order_id,
        o.status                                                     AS order_status,
        o.shipping_method,
        oi.quantity,
        oi.unit_price,
        oi.discount_pct,
        ROUND(oi.quantity * oi.unit_price, 2)                        AS gross_amount,
        ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100), 2) AS net_revenue,
        ROUND(oi.quantity * dp.current_cost, 2)                      AS cost_amount,
        ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100), 2)
            - ROUND(oi.quantity * dp.current_cost, 2)                AS profit
    FROM SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDER_ITEMS_STREAM oi
    JOIN SHOPFLOW_DW.STG_ECOMMERCE.STG_ORDERS o        ON oi.order_id = o.order_id
    JOIN SHOPFLOW_DW.ANALYTICS.DIM_CUSTOMER dc          ON o.customer_id = dc.customer_id AND dc.is_current = TRUE
    JOIN SHOPFLOW_DW.ANALYTICS.DIM_PRODUCT dp           ON oi.product_id = dp.product_id
    JOIN SHOPFLOW_DW.ANALYTICS.DIM_STORE ds             ON o.store_id = ds.store_id;

-- Enable the task
-- ALTER TASK SHOPFLOW_DW.ANALYTICS.LOAD_FACT_SALES_TASK RESUME;
```

---

## Chapter 25: Naming Conventions and Documentation Standards

Consistent naming makes your project maintainable.

### Table Naming

| Layer     | Prefix   | Example                 |
|-----------|----------|-------------------------|
| Raw       | `raw_`   | `raw_customers`         |
| Staging   | `stg_`   | `stg_customers`         |
| Dimension | `dim_`   | `dim_customer`          |
| Fact      | `fact_`  | `fact_sales`            |
| View      | `v_`     | `v_sales_summary`       |
| Materialized View | `mv_` | `mv_daily_revenue` |

### Column Naming

| Type                | Convention              | Example            |
|---------------------|-------------------------|--------------------|
| Surrogate key       | `<entity>_key`          | `customer_key`     |
| Natural/business key| `<entity>_id`           | `customer_id`      |
| Foreign key         | Same as referenced PK   | `customer_key`     |
| Date column         | `<event>_date`          | `order_date`       |
| Date key (FK)       | `date_key`              | `date_key`         |
| Boolean             | `is_<condition>`        | `is_active`        |
| Amount/Money        | Descriptive noun        | `net_revenue`      |
| Count               | `<thing>_count`         | `order_count`      |
| Percentage          | `<thing>_pct`           | `discount_pct`     |

---

## Chapter 26: Your Project Checklist

Use this checklist for ANY data modeling project:

```
PHASE 1: REQUIREMENTS
[ ] Identify business questions the model must answer
[ ] List all source systems and data availability
[ ] Define who will use the model (analysts, BI tools, ML pipelines)
[ ] Document expected data volumes and growth

PHASE 2: DESIGN
[ ] Create conceptual model (entities + relationships)
[ ] Create logical model (all attributes, keys, types)
[ ] Define the grain of each fact table (write it in plain English)
[ ] Identify dimensions and their attributes
[ ] Decide SCD strategy for each dimension
[ ] Choose Star Schema vs Snowflake Schema vs Data Vault
[ ] Document naming conventions

PHASE 3: BUILD
[ ] Create database and schemas (raw, staging, analytics)
[ ] Build raw layer tables
[ ] Build staging layer with type casting, cleaning, dedup
[ ] Build date dimension
[ ] Build all dimension tables
[ ] Build fact tables with proper grain and measures
[ ] Add clustering keys for performance
[ ] Create summary views for common queries

PHASE 4: VALIDATE
[ ] Referential integrity checks (all FKs match)
[ ] No duplicate keys in dimensions or facts
[ ] Row counts match across layers
[ ] Revenue/metric sanity checks
[ ] SCD Type 2 integrity (one current per natural key)
[ ] Test with real analytical queries

PHASE 5: OPERATIONALIZE
[ ] Set up incremental loading (Streams + Tasks or dbt)
[ ] Create monitoring/alerting for data quality
[ ] Document the model (ERD, data dictionary, lineage)
[ ] Set up access controls (roles, grants)
[ ] Schedule regular refreshes
```

---

## Glossary

| Term                 | Definition                                                           |
|----------------------|----------------------------------------------------------------------|
| **Entity**           | A real-world object (Customer, Order, Product)                       |
| **Attribute**        | A property of an entity (name, email, price)                         |
| **Relationship**     | How entities connect (1:1, 1:M, M:N)                                |
| **Primary Key (PK)** | Uniquely identifies each row                                        |
| **Foreign Key (FK)** | References a primary key in another table                            |
| **Surrogate Key**    | System-generated identifier (autoincrement)                          |
| **Natural Key**      | Business-meaningful identifier (customer_id, email)                  |
| **Grain**            | What one row in a fact table represents                              |
| **Fact**             | A measurable event/metric (revenue, quantity)                        |
| **Dimension**        | Descriptive context for a fact (who, what, where, when)              |
| **Star Schema**      | Fact table in center, denormalized dimensions around it              |
| **Snowflake Schema** | Star schema with normalized dimensions                               |
| **Data Vault**       | Hub + Link + Satellite modeling for enterprise DWs                   |
| **SCD**              | Slowly Changing Dimension — strategy for handling changes            |
| **Cardinality**      | Number of unique values in a column / relationship multiplicity      |
| **Normalization**    | Reducing redundancy by splitting into related tables                 |
| **Denormalization**  | Adding redundancy intentionally for query performance                |
| **ETL**              | Extract, Transform, Load (transform outside warehouse)               |
| **ELT**              | Extract, Load, Transform (transform inside warehouse — Snowflake)    |
| **Additive Measure** | Can be summed across all dimensions (revenue)                        |
| **Semi-Additive**    | Can be summed across some dimensions (account balance)               |
| **Non-Additive**     | Cannot be summed (ratios, percentages)                               |
| **Conformed Dimension** | Shared dimension used across multiple fact tables                 |
| **Junk Dimension**   | Combines low-cardinality flags/indicators into one dimension         |
| **Degenerate Dimension** | Dimension attribute stored directly in the fact table (order_id) |
| **Bridge Table**     | Resolves many-to-many relationships                                  |
| **Bronze/Silver/Gold** | Raw / Cleaned / Business-ready data layers                        |
