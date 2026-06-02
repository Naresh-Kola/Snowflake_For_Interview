# Snowflake Semantic Models & Semantic Views: Complete Guide

## Table of Contents
1. [What Are Semantics in Snowflake?](#1-what-are-semantics-in-snowflake)
2. [Types of Semantic Definitions](#2-types-of-semantic-definitions)
3. [Semantic Views (Recommended)](#3-semantic-views-recommended)
4. [Legacy Semantic Models (YAML on Stage)](#4-legacy-semantic-models-yaml-on-stage)
5. [Key Concepts](#5-key-concepts)
6. [Dimensions](#6-dimensions)
7. [Facts](#7-facts)
8. [Metrics](#8-metrics)
9. [Relationships](#9-relationships)
10. [Verified Queries](#10-verified-queries)
11. [Where Are Semantics Used?](#11-where-are-semantics-used)
12. [Creating a Semantic View (SQL)](#12-creating-a-semantic-view-sql)
13. [Creating a Semantic View (YAML)](#13-creating-a-semantic-view-yaml)
14. [Querying a Semantic View](#14-querying-a-semantic-view)
15. [Advanced Features](#15-advanced-features)
16. [Privileges & Access Control](#16-privileges--access-control)
17. [Management Commands](#17-management-commands)
18. [Semantic View vs Legacy Semantic Model](#18-semantic-view-vs-legacy-semantic-model)
19. [Best Practices](#19-best-practices)
20. [Complete Example](#20-complete-example)

---

## 1. What Are Semantics in Snowflake?

Semantics in Snowflake define a **business-level translation layer** over your physical tables. They bridge the gap between:

- How **business users describe** data: "revenue", "churn rate", "top customers"
- How **data is stored** in tables: `fact_orders.o_totalprice`, `dim_customer.c_custkey`

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    WITHOUT SEMANTICS                                      │
│                                                                          │
│  Business User: "What was our revenue last quarter?"                     │
│  ↓                                                                       │
│  Must know: table names, column names, joins, SQL syntax                 │
│  ↓                                                                       │
│  SELECT SUM(o_totalprice) FROM tpch_sf1.orders WHERE ...                 │
│                                                                          │
├─────────────────────────────────────────────────────────────────────────┤
│                    WITH SEMANTICS                                         │
│                                                                          │
│  Business User: "What was our revenue last quarter?"                     │
│  ↓                                                                       │
│  Cortex Analyst reads semantic view → understands "revenue" = metric     │
│  ↓                                                                       │
│  Auto-generates correct SQL with proper joins and filters                │
└─────────────────────────────────────────────────────────────────────────┘
```

### What a Semantic Layer Defines:
- **Dimensions**: Categorical attributes (who, what, where, when)
- **Facts**: Raw quantitative values at row level
- **Metrics**: Aggregated measures (SUM, AVG, COUNT)
- **Relationships**: How tables join together
- **Synonyms**: Alternative business terms for the same concept
- **Verified Queries**: Pre-approved question-to-SQL mappings

---

## 2. Types of Semantic Definitions

| Type | Storage | Status | Recommended? |
|------|---------|--------|--------------|
| **Semantic View** | Schema-level object (native) | GA | Yes |
| **Legacy Semantic Model** | YAML file on a stage | Supported (backward compatible) | No (migrate to views) |

---

## 3. Semantic Views (Recommended)

A **semantic view** is a first-class schema-level Snowflake object that defines business semantics over physical tables.

### Benefits Over Legacy Models:
- **Native Snowflake integration**: Full RBAC, sharing, and catalog support
- **Advanced features**: Derived metrics, access modifiers (public/private)
- **Better governance**: Integrated with privileges, tags, and sharing
- **Simplified management**: No YAML files on stages to manage
- **Shareable**: Native Snowflake sharing mechanisms
- **Discoverable**: Appears in INFORMATION_SCHEMA, catalog, search

### How to Create:
1. **SQL DDL** (`CREATE SEMANTIC VIEW` command)
2. **YAML** (via `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML`)
3. **Snowsight UI** (AI & ML → Cortex Analyst → Create)

---

## 4. Legacy Semantic Models (YAML on Stage)

The older approach — a YAML file stored on a Snowflake stage:

```sql
-- Upload YAML to stage
PUT file:///local/path/my_model.yaml @my_stage/;

-- Reference in Cortex Analyst API
"semantic_model_file": "@my_db.my_schema.my_stage/my_model.yaml"
```

### Limitations:
- No native RBAC (depends on stage access)
- No native sharing
- Requires managing files on stages
- No derived metrics
- No access modifiers
- No object tagging
- Requires explicit `join_type` and `relationship_type`

---

## 5. Key Concepts

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    SEMANTIC VIEW STRUCTURE                                │
│                                                                          │
│  SEMANTIC VIEW: revenue_analysis                                         │
│  ├── TABLES (Logical Tables)                                            │
│  │   ├── customers → CUSTOMER (physical table)                          │
│  │   ├── orders → ORDERS (physical table)                               │
│  │   └── line_items → LINEITEM (physical table)                         │
│  │                                                                       │
│  ├── DIMENSIONS (Categorical: who, what, where, when)                   │
│  │   ├── customer_name                                                   │
│  │   ├── order_date (time dimension)                                     │
│  │   └── customer_segment                                                │
│  │                                                                       │
│  ├── FACTS (Raw row-level quantities)                                   │
│  │   ├── order_total                                                     │
│  │   ├── discount_amount                                                 │
│  │   └── line_item_id                                                    │
│  │                                                                       │
│  ├── METRICS (Aggregated measures)                                      │
│  │   ├── total_revenue = SUM(order_total)                               │
│  │   ├── avg_order_value = AVG(order_total)                             │
│  │   └── customer_count = COUNT(DISTINCT customer_id)                   │
│  │                                                                       │
│  ├── RELATIONSHIPS (How tables join)                                    │
│  │   ├── orders → customers (via o_custkey = c_custkey)                 │
│  │   └── line_items → orders (via l_orderkey = o_orderkey)              │
│  │                                                                       │
│  └── VERIFIED QUERIES (Pre-approved Q&A pairs)                          │
│      └── "Top 10 customers by revenue" → SQL                            │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Dimensions

Dimensions are **categorical attributes** that provide context. They answer "who", "what", "where", and "when".

### Types of Dimensions:

| Type | Description | Example |
|------|-------------|---------|
| **Regular** | Text, numeric, or categorical values | customer_name, region, product_line |
| **Time** | Date/timestamp with special handling | order_date, created_at |
| **Boolean filter** | Labels = [filter], resolves to TRUE/FALSE | is_active, high_value |

### Properties:

| Property | Required | Description |
|----------|----------|-------------|
| `name` | Yes | Business-friendly name |
| `expr` | Yes | SQL expression |
| `data_type` | No | Data type |
| `synonyms` | No | Alternative names users might use |
| `description` | No | Human-readable explanation |
| `unique` | No | Whether values are unique |
| `is_enum` | No | Fixed set of possible values |
| `sample_values` | No | Example values for better matching |
| `cortex_search_service` | No | Cortex Search for semantic matching |
| `labels: [filter]` | No | Can be used as a WHERE condition |

### Example:

```sql
DIMENSIONS (
  customers.customer_name AS c_name
    WITH SYNONYMS = ('client name', 'customer')
    COMMENT = 'Full name of the customer',
  orders.order_date AS o_orderdate
    COMMENT = 'Date when the order was placed',
  customers.segment AS c_mktsegment
    COMMENT = 'Market segment (AUTOMOBILE, BUILDING, etc.)'
)
```

### YAML:

```yaml
dimensions:
  - name: customer_name
    synonyms: ["client name", "customer"]
    description: "Full name of the customer"
    expr: c_name
    data_type: VARCHAR
  - name: customer_segment
    description: "Market segment"
    expr: c_mktsegment
    data_type: VARCHAR
    is_enum: true
    sample_values: ["AUTOMOBILE", "BUILDING", "FURNITURE"]
```

---

## 7. Facts

Facts are **row-level quantitative attributes** representing individual transactions or events. They are the building blocks for metrics.

### Facts vs Metrics:
- **Fact**: Individual row value (e.g., one order's total price)
- **Metric**: Aggregation of facts (e.g., SUM of all order totals)

### Properties:

| Property | Description |
|----------|-------------|
| `expr` | SQL expression |
| `data_type` | Data type |
| `access_modifier` | `public_access` (default) or `private_access` |
| `labels: [filter]` | Can be used as a WHERE condition |

### Example:

```sql
FACTS (
  line_items.discounted_price AS l_extendedprice * (1 - l_discount)
    COMMENT = 'Extended price after discount',
  orders.count_line_items AS COUNT(line_items.line_item_id),
  PRIVATE orders.internal_cost AS unit_cost * quantity  -- hidden from queries
)
```

### YAML:

```yaml
facts:
  - name: discounted_price
    description: "Extended price after discount"
    expr: l_extendedprice * (1 - l_discount)
    data_type: "NUMBER(25,4)"
  - name: internal_cost
    expr: unit_cost * quantity
    data_type: NUMBER
    access_modifier: private_access
```

---

## 8. Metrics

Metrics are **aggregated measures** of business performance (SUM, AVG, COUNT, etc.).

### Two Types of Metrics:

| Type | Scope | Can Combine Tables? |
|------|-------|---------------------|
| **Table-level** | Scoped to one logical table | No (single table aggregation) |
| **Derived** | View-level (no table prefix) | Yes (combine metrics from multiple tables) |

### Table-Level Metrics:

```sql
METRICS (
  orders.total_revenue AS SUM(o_totalprice)
    COMMENT = 'Total revenue across all orders',
  orders.avg_order_value AS AVG(o_totalprice),
  customers.customer_count AS COUNT(c_custkey)
)
```

### Derived Metrics (Cross-Table):

```sql
METRICS (
  orders.total_revenue AS SUM(o_totalprice),
  customers.customer_count AS COUNT(c_custkey),
  -- Derived metric: combines metrics from orders + customers
  revenue_per_customer AS orders.total_revenue / customers.customer_count
)
```

### Non-Additive Metrics (Semi-Additive):

For metrics like account balances that shouldn't be summed across time:

```sql
METRICS (
  bank_accounts.m_account_balance
    NON ADDITIVE BY (year_dim, month_dim, day_dim)
    AS SUM(balance)
)
```

### YAML:

```yaml
metrics:
  - name: total_revenue
    description: "Total revenue across all orders"
    expr: SUM(o_totalprice)
  - name: avg_order_value
    description: "Average order value"
    expr: AVG(o_totalprice)

# View-level derived metrics
metrics:
  - name: revenue_per_customer
    description: "Average revenue per customer"
    expr: orders.total_revenue / customers.customer_count
    access_modifier: public_access
```

---

## 9. Relationships

Relationships define how logical tables join together.

### Properties:

| Property | Description |
|----------|-------------|
| `left_table` | Table with the foreign key |
| `right_table` | Table being referenced (has PK) |
| `relationship_columns` | Column pairs to join on |

### Key Difference from Legacy Models:
- Semantic views **automatically infer** join type (many-to-one, one-to-one)
- No need to specify `join_type` or `relationship_type`

### SQL Example:

```sql
RELATIONSHIPS (
  orders_to_customers AS
    orders (o_custkey) REFERENCES customers (c_custkey),
  line_items_to_orders AS
    line_items (l_orderkey) REFERENCES orders (o_orderkey)
)
```

### ASOF Join (Time-Based Range):

```sql
RELATIONSHIPS (
  orders_to_address AS
    orders (o_cust_id, o_ord_date)
    REFERENCES customer_address (ca_cust_id, ASOF ca_start_date)
)
```

### YAML:

```yaml
relationships:
  - name: orders_to_customers
    left_table: orders
    right_table: customers
    relationship_columns:
      - left_column: o_custkey
        right_column: c_custkey
```

---

## 10. Verified Queries

Verified queries are **pre-approved question-to-SQL mappings** that:
- Improve accuracy (Cortex Analyst uses them as examples)
- Build trust (tagged as "verified")
- Serve as onboarding suggestions for users

### SQL:

```sql
AI_VERIFIED_QUERIES (
  top_customers AS (
    QUESTION 'Who are the top 10 customers by revenue?'
    VERIFIED_AT 1772645863
    ONBOARDING_QUESTION TRUE
    VERIFIED_BY '(STEWARD = data_stewards)'
    SQL 'SELECT customer_name, SUM(order_total) as revenue
         FROM revenue_analysis
         GROUP BY customer_name
         ORDER BY revenue DESC LIMIT 10'
  )
)
```

### YAML:

```yaml
verified_queries:
  - name: top_customers_by_revenue
    question: "Who are the top 10 customers by revenue?"
    sql: |
      SELECT customer_name, SUM(order_total) as total_revenue
      FROM revenue_analysis
      GROUP BY customer_name
      ORDER BY total_revenue DESC
      LIMIT 10
    use_as_onboarding_question: true
    verified_by: "data_stewards"
    verified_at: 1772645863
```

---

## 11. Where Are Semantics Used?

| Consumer | How It Uses Semantics |
|----------|----------------------|
| **Cortex Analyst** | Text-to-SQL: translates natural language → SQL using semantic definitions |
| **Snowflake Intelligence** | Powers the conversational UI for business users |
| **Cortex Agents** | Tool selection: uses semantic views as structured data tools |
| **SEMANTIC_VIEW() function** | Direct SQL queries using semantic concepts |
| **Tableau TDS Export** | Export semantic views to Tableau data sources |
| **Snowflake Catalog** | Discoverability: semantic views appear in catalog/search |

---

## 12. Creating a Semantic View (SQL)

```sql
CREATE OR REPLACE SEMANTIC VIEW sales_analysis

  TABLES (
    orders AS MY_DB.SALES.ORDERS
      PRIMARY KEY (order_id)
      WITH SYNONYMS ('sales orders', 'purchases')
      COMMENT = 'All customer orders',
    customers AS MY_DB.SALES.CUSTOMERS
      PRIMARY KEY (customer_id)
      COMMENT = 'Customer master data',
    products AS MY_DB.SALES.PRODUCTS
      PRIMARY KEY (product_id)
      COMMENT = 'Product catalog'
  )

  RELATIONSHIPS (
    orders_to_customers AS
      orders (customer_id) REFERENCES customers,
    orders_to_products AS
      orders (product_id) REFERENCES products
  )

  FACTS (
    orders.order_amount AS amount,
    orders.quantity AS qty,
    orders.discount_amount AS amount * discount_pct
      COMMENT = 'Calculated discount amount'
  )

  DIMENSIONS (
    customers.customer_name AS name
      WITH SYNONYMS = ('client', 'buyer')
      COMMENT = 'Customer full name',
    customers.region AS region
      COMMENT = 'Geographic region',
    orders.order_date AS order_date
      COMMENT = 'Date order was placed',
    products.category AS product_category
      COMMENT = 'Product category'
  )

  METRICS (
    orders.total_revenue AS SUM(amount)
      COMMENT = 'Total revenue',
    orders.avg_order_value AS AVG(amount)
      COMMENT = 'Average order value',
    orders.order_count AS COUNT(order_id)
      COMMENT = 'Number of orders',
    customers.customer_count AS COUNT(customer_id)
      COMMENT = 'Number of unique customers'
  )

  COMMENT = 'Sales analytics semantic view'

  AI_SQL_GENERATION 'Round all numeric results to 2 decimal places.'

  AI_VERIFIED_QUERIES (
    monthly_revenue AS (
      QUESTION 'What is our monthly revenue?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT DATE_TRUNC(''month'', order_date) as month,
                  SUM(order_amount) as revenue
           FROM sales_analysis
           GROUP BY month ORDER BY month'
    )
  );
```

---

## 13. Creating a Semantic View (YAML)

```sql
CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML(
  'my_db.my_schema',
  $$
  name: sales_analysis
  description: "Sales analytics semantic view"

  tables:
    - name: orders
      description: "All customer orders"
      base_table:
        database: MY_DB
        schema: SALES
        table: ORDERS
      primary_key:
        columns:
          - ORDER_ID
      dimensions:
        - name: order_date
          description: "Date order was placed"
          expr: order_date
          data_type: DATE
      facts:
        - name: order_amount
          description: "Order total amount"
          expr: amount
          data_type: NUMBER
      metrics:
        - name: total_revenue
          description: "Total revenue"
          expr: SUM(amount)
        - name: order_count
          description: "Number of orders"
          expr: COUNT(order_id)

    - name: customers
      description: "Customer master data"
      base_table:
        database: MY_DB
        schema: SALES
        table: CUSTOMERS
      primary_key:
        columns:
          - CUSTOMER_ID
      dimensions:
        - name: customer_name
          synonyms: ["client", "buyer"]
          description: "Customer full name"
          expr: name
          data_type: VARCHAR
        - name: region
          description: "Geographic region"
          expr: region
          data_type: VARCHAR
          is_enum: true

  relationships:
    - name: orders_to_customers
      left_table: orders
      right_table: customers
      relationship_columns:
        - left_column: CUSTOMER_ID
          right_column: CUSTOMER_ID

  verified_queries:
    - name: monthly_revenue
      question: "What is our monthly revenue?"
      sql: |
        SELECT DATE_TRUNC('month', order_date) as month,
               SUM(order_amount) as revenue
        FROM sales_analysis
        GROUP BY month ORDER BY month
      use_as_onboarding_question: true
  $$
);
```

---

## 14. Querying a Semantic View

### Direct SQL Query (SEMANTIC_VIEW function):

```sql
SELECT * FROM SEMANTIC_VIEW(
  sales_analysis
  DIMENSIONS orders.order_date, customers.region
  METRICS orders.total_revenue, orders.order_count
);
```

### Via Cortex Analyst (Natural Language):

```
User: "What was our total revenue by region last quarter?"
→ Cortex Analyst reads semantic view → generates SQL → returns results
```

### Via Cortex Agent / Snowflake Intelligence:

The semantic view is attached as a tool. The agent selects it when answering structured data questions.

---

## 15. Advanced Features

### Access Modifiers (Public/Private)

```sql
FACTS (
  PRIVATE orders.internal_cost AS unit_cost * quantity,  -- hidden
  orders.revenue AS sale_price * quantity                 -- visible
)

METRICS (
  PRIVATE orders.helper_metric AS SUM(internal_cost),    -- hidden
  orders.profit_margin AS (orders.revenue - orders.helper_metric) / orders.revenue
)
```

### Custom Instructions for Cortex Analyst

```sql
CREATE SEMANTIC VIEW my_view
  ...
  AI_SQL_GENERATION 'Always round numeric columns to 2 decimal places.
                     Use fiscal year (starts April 1) when user says "year".'
  AI_QUESTION_CATEGORIZATION 'Reject questions about individual employee salaries.
                              Ask for clarification if the user says "revenue" without
                              specifying gross or net.'
```

### Tags (Governance)

```yaml
dimensions:
  - name: customer_email
    expr: email
    tags:
      - name:
          database: governance_db
          schema: tags
          tag: pii_type
        value: "email"
```

### Filters (Entity-Level)

```yaml
dimensions:
  - name: is_active
    expr: last_login > DATEADD(month, -6, CURRENT_DATE())
    labels:
      - filter
```

### Cortex Search Service on Dimensions

```yaml
dimensions:
  - name: product_name
    expr: name
    cortex_search_service:
      service: product_search_svc
      literal_column: product_name
```

---

## 16. Privileges & Access Control

| Operation | Required Privilege |
|-----------|-------------------|
| Create semantic view | `CREATE SEMANTIC VIEW` on schema |
| Query semantic view | `SELECT` on the semantic view |
| Use with Cortex Analyst | `REFERENCES` + `SELECT` on view |
| Describe | Any privilege on the view |
| Drop | `OWNERSHIP` on the view |
| Replace | `OWNERSHIP` on existing view |

### Important:
> To **query** a semantic view, you do NOT need SELECT on the underlying tables — only SELECT on the semantic view itself. This is consistent with standard view behavior.

```sql
-- Grant access for Cortex Analyst users
GRANT REFERENCES, SELECT ON SEMANTIC VIEW my_view TO ROLE analyst_role;

-- Future grants for all new semantic views in a schema
GRANT REFERENCES, SELECT ON FUTURE SEMANTIC VIEWS IN SCHEMA my_schema TO ROLE analyst_role;
```

---

## 17. Management Commands

| Command | Purpose |
|---------|---------|
| `CREATE SEMANTIC VIEW` | Create new |
| `CREATE OR REPLACE SEMANTIC VIEW` | Replace (use COPY GRANTS to preserve) |
| `CREATE OR ALTER SEMANTIC VIEW` | Create or alter (preserves grants automatically) |
| `ALTER SEMANTIC VIEW ... SET COMMENT` | Change comment |
| `ALTER SEMANTIC VIEW ... RENAME TO` | Rename |
| `DROP SEMANTIC VIEW` | Remove |
| `SHOW SEMANTIC VIEWS` | List all in scope |
| `DESCRIBE SEMANTIC VIEW` | View full definition |
| `SHOW SEMANTIC DIMENSIONS` | List dimensions |
| `SHOW SEMANTIC FACTS` | List facts |
| `SHOW SEMANTIC METRICS` | List metrics |
| `SHOW SEMANTIC DIMENSIONS FOR METRIC` | Compatible dimensions for a metric |
| `GET_DDL('SEMANTIC_VIEW', 'name')` | Get DDL |
| `SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW` | Export to YAML |
| `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML` | Create from YAML |
| `SYSTEM$EXPORT_TDS_FROM_SEMANTIC_VIEW` | Export to Tableau TDS |

---

## 18. Semantic View vs Legacy Semantic Model

| Feature | Legacy Semantic Model | Semantic View |
|---------|----------------------|---------------|
| Storage | YAML file on stage | Schema-level object |
| Privileges | Stage-based access | Full Snowflake RBAC |
| Sharing | Manual file sharing | Native Snowflake sharing |
| Join types | Requires `join_type` and `relationship_type` | Automatically inferred |
| Derived metrics | Not supported | Fully supported |
| Access modifiers | Not supported | `public_access` / `private_access` |
| Custom instructions | In YAML file | Set via SQL (AI_SQL_GENERATION, AI_QUESTION_CATEGORIZATION) |
| Object tagging | Not supported | Supported on views, tables, dims, facts, metrics |
| Verified queries | In YAML file | In SQL (AI_VERIFIED_QUERIES) or YAML |
| Catalog discovery | Not in catalog | Appears in INFORMATION_SCHEMA |
| Tableau export | Not supported | `SYSTEM$EXPORT_TDS_FROM_SEMANTIC_VIEW` |

### Migration Tips:
1. Remove `join_type` and `relationship_type` from relationships
2. Use derived metrics for cross-table calculations
3. Add `access_modifier` for private intermediate calculations
4. Move custom instructions to SQL `AI_SQL_GENERATION` clause

---

## 19. Best Practices

### Naming:
- Use business-friendly names (not column names)
- Add synonyms for commonly used alternative terms
- Include descriptions for every dimension and metric

### Design:
- Keep one semantic view per business domain (sales, HR, finance)
- Use `private_access` for intermediate calculations
- Define verified queries for common questions (minimum 5-10)
- Use `is_enum: true` for low-cardinality dimensions
- Add `sample_values` for dimensions likely referenced in questions

### Performance:
- Limit to <30 columns per logical table for best Cortex Analyst accuracy
- Use `NON ADDITIVE BY` for snapshot/balance metrics
- Define primary keys for accurate relationship inference

### Governance:
- Tag PII dimensions with governance tags
- Use `AI_QUESTION_CATEGORIZATION` to reject out-of-scope questions
- Grant `REFERENCES + SELECT` (not OWNERSHIP) to analyst roles

---

## 20. Complete Example

```sql
CREATE OR REPLACE SEMANTIC VIEW ecommerce_analytics

  TABLES (
    orders AS ECOM_DB.PUBLIC.ORDERS
      PRIMARY KEY (order_id)
      WITH SYNONYMS ('purchases', 'transactions')
      COMMENT = 'Customer purchase orders',
    customers AS ECOM_DB.PUBLIC.CUSTOMERS
      PRIMARY KEY (customer_id)
      COMMENT = 'Customer master data',
    products AS ECOM_DB.PUBLIC.PRODUCTS
      PRIMARY KEY (product_id)
      COMMENT = 'Product catalog'
  )

  RELATIONSHIPS (
    orders_to_customers AS orders (customer_id) REFERENCES customers,
    orders_to_products AS orders (product_id) REFERENCES products
  )

  FACTS (
    orders.sale_amount AS unit_price * quantity,
    orders.discount_value AS unit_price * quantity * discount_pct,
    PRIVATE orders.cost AS unit_cost * quantity
  )

  DIMENSIONS (
    customers.customer_name AS full_name
      WITH SYNONYMS = ('client', 'buyer', 'account')
      COMMENT = 'Customer full name',
    customers.country AS country
      COMMENT = 'Customer country',
    customers.segment AS customer_segment
      COMMENT = 'Business segment (Enterprise, SMB, Consumer)',
    orders.order_date AS created_at
      COMMENT = 'Order creation date',
    orders.order_year AS YEAR(created_at)
      COMMENT = 'Year order was placed',
    products.category AS product_category
      COMMENT = 'Product category',
    products.brand AS product_brand
      COMMENT = 'Product brand name'
  )

  METRICS (
    orders.total_revenue AS SUM(orders.sale_amount)
      COMMENT = 'Total gross revenue',
    orders.total_discount AS SUM(orders.discount_value)
      COMMENT = 'Total discounts given',
    orders.net_revenue AS SUM(orders.sale_amount) - SUM(orders.discount_value)
      COMMENT = 'Revenue after discounts',
    orders.order_count AS COUNT(order_id)
      COMMENT = 'Number of orders',
    orders.avg_order_value AS AVG(orders.sale_amount)
      COMMENT = 'Average order value',
    customers.customer_count AS COUNT(DISTINCT customer_id)
      COMMENT = 'Unique customer count',
    -- Derived metric (cross-table)
    revenue_per_customer AS orders.total_revenue / customers.customer_count
  )

  COMMENT = 'E-commerce analytics for revenue, customers, and products'

  AI_SQL_GENERATION 'Round all monetary values to 2 decimal places.
                     When user says "this year" use 2026.
                     Default date ordering is most recent first.'

  AI_QUESTION_CATEGORIZATION 'If the user asks about employee data, reject and suggest
                              they use the HR semantic view instead.'

  AI_VERIFIED_QUERIES (
    monthly_revenue_trend AS (
      QUESTION 'What is our monthly revenue trend?'
      ONBOARDING_QUESTION TRUE
      VERIFIED_BY '(STEWARD = analytics_team)'
      SQL 'SELECT DATE_TRUNC(''month'', order_date) AS month,
                  SUM(sale_amount) AS revenue
           FROM ecommerce_analytics
           GROUP BY month ORDER BY month'
    ),
    top_customers AS (
      QUESTION 'Who are our top 10 customers by revenue?'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT customer_name, SUM(sale_amount) AS total_spent
           FROM ecommerce_analytics
           GROUP BY customer_name
           ORDER BY total_spent DESC LIMIT 10'
    )
  );

-- Grant access
GRANT REFERENCES, SELECT ON SEMANTIC VIEW ecommerce_analytics TO ROLE analyst_role;

-- Query it directly
SELECT * FROM SEMANTIC_VIEW(
  ecommerce_analytics
  DIMENSIONS customers.country, orders.order_year
  METRICS orders.total_revenue, orders.order_count
);
```

---

## Summary

```
SEMANTIC VIEW = Business-level translation layer over physical tables

Components:
  TABLES         → Map logical names to physical tables
  DIMENSIONS     → Categorical attributes (who, what, where, when)
  FACTS          → Row-level quantities (building blocks)
  METRICS        → Aggregated measures (SUM, AVG, COUNT)
  RELATIONSHIPS  → How tables join (auto-inferred)
  VERIFIED QUERIES → Pre-approved Q&A pairs for accuracy

Used by:
  • Cortex Analyst (text-to-SQL)
  • Snowflake Intelligence (conversational UI)
  • Cortex Agents (structured data tool)
  • SEMANTIC_VIEW() SQL function (direct query)
  • Tableau (TDS export)

Best choice: CREATE SEMANTIC VIEW (native object)
Legacy: YAML file on stage (still works, but migrate to views)
```
