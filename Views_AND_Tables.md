-- ============================================================
-- ALL TABLE & VIEW TYPES IN SNOWFLAKE
-- ============================================================

-- TABLE TYPES:
--   1. Permanent Table       (default)
--   2. Transient Table
--   3. Temporary Table
--   4. External Table
--   5. Hybrid Table
--   6. Iceberg Table
--   7. Dynamic Table
--   8. Event Table

-- VIEW TYPES:
--   1. Regular View          (default)
--   2. Secure View
--   3. Materialized View
--   4. Secure Materialized View


-- ############################################################
-- ##################### VIEW TYPES ###########################
-- ############################################################


-- ============================================================
-- VIEW 1: REGULAR VIEW (Default)
-- ============================================================
--
-- ── WHAT IS A VIEW? (in simple words) ───────────────────────────
--
-- A view is a SAVED SELECT QUERY with a name.
-- It does NOT store any data. Every time you query a view,
-- Snowflake runs the saved query from scratch and gives you
-- the latest result.
--
-- Think of it like a bookmark for a query.
-- Instead of writing a long complex query every time, you
-- save it as a view and just do: SELECT * FROM my_view;
--
--
-- ── WHY DO WE NEED VIEWS? ──────────────────────────────────────
--
-- REASON 1: SIMPLIFY COMPLEX QUERIES
--   Your team has a 50-line query with 5 JOINs.
--   Instead of everyone copy-pasting it, create a view.
--   Now everyone just does: SELECT * FROM sales_summary;
--
-- REASON 2: HIDE SENSITIVE COLUMNS
--   The employees table has salary and SSN columns.
--   Create a view that excludes those columns.
--   Give users access to the VIEW, not the TABLE.
--   They can never see salary or SSN.
--
-- REASON 3: BUSINESS LOGIC IN ONE PLACE
--   "Active customer" means status='active' AND last_order < 90 days.
--   Put that logic in a view. If the definition changes,
--   update ONE view instead of 100 queries.
--
-- REASON 4: BACKWARD COMPATIBILITY
--   You rename a column from "cust_name" to "customer_name".
--   Create a view with the old column name as an alias.
--   Old reports keep working without changes.
--
--
-- ── HOW IT WORKS ────────────────────────────────────────────────
--
--   CREATE VIEW my_view AS SELECT ...;
--
--   ┌──────────────────────────────────────────────────────────┐
--   │  SELECT * FROM my_view;                                 │
--   │                                                         │
--   │  1. Snowflake looks up the saved query                  │
--   │  2. Replaces "my_view" with the actual SELECT           │
--   │  3. Runs the full query against the base table(s)       │
--   │  4. Returns the result                                  │
--   │                                                         │
--   │  Nothing is stored. It runs fresh EVERY time.           │
--   └──────────────────────────────────────────────────────────┘
--
--
-- ── EXAMPLE 1: Simplify a complex query ─────────────────────────

-- CREATE OR REPLACE VIEW demo_db.public.v_employee_directory AS
-- SELECT
--     employee_id,
--     first_name || ' ' || last_name AS full_name,
--     email,
--     department
-- FROM demo_db.public.employees
-- WHERE is_active = TRUE;

-- Now anyone can just do:
-- SELECT * FROM demo_db.public.v_employee_directory;


-- ── EXAMPLE 2: Hide sensitive columns ───────────────────────────

-- CREATE OR REPLACE VIEW demo_db.public.v_employees_safe AS
-- SELECT
--     employee_id,
--     first_name,
--     last_name,
--     department,
--     hire_date
-- FROM demo_db.public.employees;
-- (salary is excluded — users of this view can never see it)


-- ── EXAMPLE 3: Multi-table JOIN saved as a view ─────────────────

-- CREATE OR REPLACE VIEW demo_db.public.v_order_details AS
-- SELECT
--     o.order_id,
--     o.order_date,
--     c.customer_name,
--     p.product_name,
--     oi.quantity,
--     oi.unit_price,
--     oi.quantity * oi.unit_price AS line_total
-- FROM orders o
-- JOIN order_items oi ON o.order_id = oi.order_id
-- JOIN products p     ON oi.product_id = p.product_id
-- JOIN customers c    ON o.customer_id = c.customer_id;

-- Instead of writing this 12-line JOIN every time:
-- SELECT * FROM demo_db.public.v_order_details WHERE order_date = CURRENT_DATE();


-- ── FEATURES ────────────────────────────────────────────────────
--
--   - Stores NO data (zero storage cost)
--   - Always returns latest data (100% live)
--   - Can reference multiple tables (JOINs, subqueries, UNIONs)
--   - Can use window functions, aggregations, CTEs — anything
--   - Anyone can see the view definition (SHOW VIEWS / GET_DDL)
--   - Query optimizer CAN see through the view and optimize
--
-- ── LIMITATIONS ─────────────────────────────────────────────────
--
--   - Runs the full query every time (slow on large data)
--   - View definition is visible to anyone with access
--   - Cannot INSERT/UPDATE/DELETE through a view (read-only)


-- ============================================================
-- VIEW 2: SECURE VIEW
-- ============================================================
--
-- ── WHAT IS A SECURE VIEW? ──────────────────────────────────────
--
-- A secure view is the same as a regular view, EXCEPT:
--
--   1. The view DEFINITION (the SQL query) is HIDDEN.
--      Users can query the view but CANNOT see how it was built.
--      GET_DDL() returns nothing. SHOW VIEWS hides the text.
--
--   2. The query optimizer CANNOT bypass the view's filters.
--      In a regular view, a clever user could trick the optimizer
--      into revealing hidden rows. Secure views prevent this.
--
-- In simple words: a secure view is a view with a LOCKED door.
-- You can see the output, but you cannot see how it works inside.
--
--
-- ── WHY DO WE NEED SECURE VIEWS? ───────────────────────────────
--
-- REASON 1: DATA SHARING WITH OTHER ACCOUNTS
--   When you share data with another Snowflake account via
--   Secure Data Sharing, you MUST use a secure view (or secure UDF).
--   You cannot share raw tables directly (security risk).
--   The consumer sees the data but NOT your table structure
--   or business logic.
--
-- REASON 2: ROW-LEVEL SECURITY
--   Different customers should see only THEIR data.
--   A secure view filters rows using CURRENT_ACCOUNT() or
--   CURRENT_ROLE(). The optimizer can't bypass this filter,
--   so users CANNOT see other customers' rows.
--
-- REASON 3: HIDE BUSINESS LOGIC
--   Your pricing formula is in the view definition.
--   A regular view exposes it. A secure view hides it.
--   Competitors who have query access can't reverse-engineer
--   your logic.
--
-- REASON 4: PREVENT OPTIMIZER TRICKS
--   In a regular view, a user could write a query that causes
--   a specific error (like division by zero) to figure out which
--   rows exist — even rows they shouldn't see. Secure views
--   block this by evaluating the view's WHERE clause FIRST.
--
--
-- ── WHAT EXACTLY IS HIDDEN? ─────────────────────────────────────
--
--   Regular view:
--   SHOW VIEWS → shows the full SQL definition
--   GET_DDL()  → returns the full CREATE VIEW statement
--   EXPLAIN    → shows the base table names and columns
--
--   Secure view:
--   SHOW VIEWS → definition column is EMPTY
--   GET_DDL()  → returns NOTHING (unless you own the view)
--   EXPLAIN    → hides base table details from non-owners
--
--
-- ── EXAMPLE 1: Data Sharing — each account sees only their data ─

-- CREATE OR REPLACE SECURE VIEW demo_db.public.sv_shared_sales AS
-- SELECT
--     order_id,
--     product_name,
--     quantity,
--     sale_date,
--     amount
-- FROM demo_db.public.sales_data sd
-- JOIN demo_db.public.account_access aa
--     ON sd.access_group = aa.access_group
-- WHERE aa.snowflake_account = CURRENT_ACCOUNT();

-- Consumer in Account A sees only Account A's data.
-- Consumer in Account B sees only Account B's data.
-- Neither can see the access_group logic or the base tables.


-- ── EXAMPLE 2: Role-based row filtering ─────────────────────────

-- CREATE OR REPLACE SECURE VIEW demo_db.public.sv_department_data AS
-- SELECT
--     employee_id,
--     first_name,
--     last_name,
--     department,
--     salary
-- FROM demo_db.public.employees
-- WHERE department = (
--     SELECT allowed_dept FROM demo_db.public.role_department_map
--     WHERE role_name = CURRENT_ROLE()
-- );

-- HR role sees HR employees. Engineering role sees Engineering employees.
-- Nobody can see the filtering logic.


-- ── EXAMPLE 3: Hide pricing formula ─────────────────────────────

-- CREATE OR REPLACE SECURE VIEW demo_db.public.sv_product_pricing AS
-- SELECT
--     product_id,
--     product_name,
--     base_price * markup_factor * regional_adjustment AS final_price
-- FROM demo_db.public.pricing_internal;

-- Users see product_id, product_name, final_price.
-- They CANNOT see base_price, markup_factor, or the formula.


-- ── REGULAR VIEW vs SECURE VIEW ─────────────────────────────────
--
--   ┌─────────────────────────┬──────────────────┬──────────────────┐
--   │                         │  REGULAR VIEW    │  SECURE VIEW     │
--   ├─────────────────────────┼──────────────────┼──────────────────┤
--   │ SQL definition visible? │ YES (to all)     │ NO (owner only)  │
--   │ Optimizer can peek?     │ YES              │ NO (locked)      │
--   │ Performance             │ Faster (optimizer│ Slightly slower  │
--   │                         │ has more info)   │ (restricted opt.)│
--   │ Data Sharing allowed?   │ NO               │ YES (required)   │
--   │ Security level          │ Basic            │ High             │
--   │ Storage cost            │ $0               │ $0               │
--   └─────────────────────────┴──────────────────┴──────────────────┘
--
-- PERFORMANCE NOTE: Secure views can be slower because the optimizer
-- cannot push predicates or reorder operations freely. Use secure
-- views only when you NEED the security. Don't use them everywhere.


-- ============================================================
-- VIEW 3: MATERIALIZED VIEW
-- ============================================================
--
-- ── WHAT IS A MATERIALIZED VIEW? ────────────────────────────────
--
-- A materialized view is a view that STORES its query results.
--
-- Regular view:   runs the query every time you read it.
-- Materialized:   runs the query ONCE, stores the result,
--                 and Snowflake keeps it updated automatically
--                 in the background when the base table changes.
--
-- Think of it like a pre-cooked meal.
-- A regular view cooks from scratch every time you order.
-- A materialized view pre-cooks the meal and keeps it warm.
-- When you order, it's served instantly.
--
--
-- ── WHY DO WE NEED MATERIALIZED VIEWS? ─────────────────────────
--
-- REASON 1: SPEED UP REPEATED EXPENSIVE QUERIES
--   You have a query that scans 500 million rows and takes 30
--   seconds. 50 users run this same query every hour.
--   That's 50 × 30 sec = 25 minutes of compute per hour.
--   A materialized view stores the result → each query takes 1 sec.
--
-- REASON 2: SPEED UP QUERIES ON EXTERNAL TABLES
--   External tables (data in S3) are slower than native tables.
--   A materialized view on an external table caches the result
--   inside Snowflake for fast reads.
--
-- REASON 3: THE OPTIMIZER USES THEM AUTOMATICALLY
--   Even if you query the BASE TABLE directly, Snowflake's
--   optimizer may secretly use the materialized view instead
--   if it knows the MV has the data you need (automatic rewrite).
--
--
-- ── HOW IT STAYS UP-TO-DATE ─────────────────────────────────────
--
--   When the base table changes (INSERT/UPDATE/DELETE), a
--   background serverless process updates the materialized view.
--   You NEVER update it manually. It's always consistent.
--
--   If the MV is slightly behind, Snowflake reads fresh data
--   from the base table for the changed parts and combines it
--   with the cached MV data. Result is ALWAYS accurate.
--
--
-- ── LIMITATIONS (important!) ────────────────────────────────────
--
--   ✗ Can query ONLY ONE table (no JOINs)
--   ✗ No window functions, no HAVING, no ORDER BY, no LIMIT
--   ✗ No UDFs, no non-deterministic functions (CURRENT_TIME, etc.)
--   ✗ No nested subqueries
--   ✗ Supported aggregates: SUM, COUNT, AVG, MIN, MAX, STDDEV, etc.
--   ✗ Cannot INSERT/UPDATE/DELETE into an MV
--   ✗ Costs storage + serverless compute for background maintenance
--   ✗ Requires Enterprise Edition or higher
--
--
-- ── EXAMPLE 1: Speed up a heavy aggregation ─────────────────────

-- CREATE OR REPLACE MATERIALIZED VIEW demo_db.public.mv_daily_revenue AS
-- SELECT
--     order_date,
--     COUNT(*)        AS total_orders,
--     SUM(amount)     AS total_revenue,
--     AVG(amount)     AS avg_order_value
-- FROM demo_db.public.raw_orders
-- GROUP BY order_date;

-- Query it (fast — data is pre-computed):
-- SELECT * FROM demo_db.public.mv_daily_revenue WHERE order_date >= '2026-04-01';

-- Even this query against the BASE TABLE may use the MV automatically:
-- SELECT order_date, SUM(amount) FROM demo_db.public.raw_orders GROUP BY order_date;
-- (optimizer rewrites it to read from the MV instead!)


-- ── EXAMPLE 2: Filter a huge table ──────────────────────────────

-- CREATE OR REPLACE MATERIALIZED VIEW demo_db.public.mv_recent_orders AS
-- SELECT order_id, customer, amount, order_date
-- FROM demo_db.public.raw_orders
-- WHERE order_date >= '2026-01-01';

-- This MV stores only 2026 data. Queries on 2026 data are fast.
-- Queries on older data still go to the base table.


-- ── EXAMPLE 3: Materialized view with clustering ────────────────

-- CREATE OR REPLACE MATERIALIZED VIEW demo_db.public.mv_orders_by_region
--     CLUSTER BY (region)
-- AS
-- SELECT region, order_date, SUM(amount) AS revenue, COUNT(*) AS orders
-- FROM demo_db.public.raw_orders
-- GROUP BY region, order_date;

-- Clustering the MV on region means queries like:
-- WHERE region = 'US-West' are extremely fast (pruning).


-- ── COST ────────────────────────────────────────────────────────
--
-- Materialized views cost money in TWO ways:
--   1. STORAGE: the pre-computed results take up space
--   2. COMPUTE: Snowflake's background process uses serverless
--      credits to keep the MV updated when the base table changes
--
-- Monitor cost:
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.MATERIALIZED_VIEW_REFRESH_HISTORY());
--
-- Suspend maintenance (to save cost when not needed):
-- ALTER MATERIALIZED VIEW mv_daily_revenue SUSPEND;
-- ALTER MATERIALIZED VIEW mv_daily_revenue RESUME;


-- ============================================================
-- VIEW 4: SECURE MATERIALIZED VIEW
-- ============================================================
--
-- ── WHAT IS IT? ─────────────────────────────────────────────────
--
-- It is a materialized view + secure view combined.
-- You get BOTH benefits:
--   1. Pre-computed results (fast reads, like materialized view)
--   2. Hidden definition (like secure view)
--
-- CREATE SECURE MATERIALIZED VIEW = fast + private
--
--
-- ── WHEN TO USE? ────────────────────────────────────────────────
--
-- USE CASE 1: SHARE PRE-COMPUTED DATA SECURELY
--   You share aggregated sales data with a partner account.
--   The partner sees fast pre-computed results but CANNOT see
--   your base tables, formulas, or business logic.
--
-- USE CASE 2: EXTERNAL TABLE + SECURITY
--   You have data in S3 (external table). You create a secure
--   materialized view on it. Consumers get fast reads + no
--   visibility into your data lake structure.
--
-- USE CASE 3: FAST ROLE-BASED DASHBOARDS
--   Different roles see different pre-computed summaries.
--   The filtering logic is hidden. The data is fast to read.
--
--
-- ── EXAMPLE ─────────────────────────────────────────────────────

-- CREATE OR REPLACE SECURE MATERIALIZED VIEW demo_db.public.smv_partner_revenue AS
-- SELECT
--     region,
--     product_category,
--     order_date,
--     SUM(revenue) AS total_revenue
-- FROM demo_db.public.internal_sales
-- GROUP BY region, product_category, order_date;

-- Partner account can query this (fast, pre-computed).
-- Partner CANNOT see:
--   - The table "internal_sales"
--   - Any other columns (like cost, margin, supplier)
--   - The GROUP BY logic


-- ============================================================
-- ALL 4 VIEW TYPES: COMPARISON AT A GLANCE
-- ============================================================
/*
┌──────────────────────┬──────────┬───────────┬──────────────┬────────────────────┐
│ Feature              │ Regular  │ Secure    │ Materialized │ Secure Materialized│
│                      │ View     │ View      │ View         │ View               │
├──────────────────────┼──────────┼───────────┼──────────────┼────────────────────┤
│ Stores data?         │ NO       │ NO        │ YES          │ YES                │
│ Definition hidden?   │ NO       │ YES       │ NO           │ YES                │
│ Always live data?    │ YES      │ YES       │ YES (auto)   │ YES (auto)         │
│ Query speed          │ Slow     │ Slow      │ Fast         │ Fast               │
│                      │ (recomp.)│ (recomp.) │ (pre-stored) │ (pre-stored)       │
│ Multi-table JOINs?   │ YES      │ YES       │ NO (1 table) │ NO (1 table)       │
│ Storage cost         │ $0       │ $0        │ YES          │ YES                │
│ Compute cost         │ Per query│ Per query │ Background + │ Background +       │
│                      │          │           │ per query    │ per query           │
│ Data Sharing?        │ NO       │ YES       │ NO           │ YES                │
│ Optimizer bypass     │ Allowed  │ Blocked   │ Allowed      │ Blocked            │
│ Edition required     │ Standard │ Standard  │ Enterprise   │ Enterprise         │
└──────────────────────┴──────────┴───────────┴──────────────┴────────────────────┘
*/

-- ── WHEN TO USE WHICH VIEW? ─────────────────────────────────────
--
--   ┌─────────────────────────────────────────────────────────────┐
--   │  Simple query, small data, no security needed              │
--   │  → REGULAR VIEW                                            │
--   │                                                            │
--   │  Need to hide logic OR share with other accounts           │
--   │  → SECURE VIEW                                             │
--   │                                                            │
--   │  Heavy aggregation on large data, queried often            │
--   │  → MATERIALIZED VIEW                                       │
--   │                                                            │
--   │  Heavy aggregation + need to hide logic / share data       │
--   │  → SECURE MATERIALIZED VIEW                                │
--   └─────────────────────────────────────────────────────────────┘


-- ############################################################
-- ##################### TABLE TYPES ##########################
-- ############################################################
-- WHAT: The standard Snowflake table. Data is stored in columnar
--       micro-partitions with full platform support.
--
-- ── HOW COLUMNAR MICRO-PARTITIONS WORK ──────────────────────────
--
-- When you INSERT data, Snowflake automatically splits it into
-- micro-partitions (50-500 MB uncompressed each). Inside each
-- micro-partition, data is stored COLUMN-BY-COLUMN, not row-by-row.
--
-- EXAMPLE: Suppose we insert 8 rows into the employees table.
-- Snowflake may create 2 micro-partitions (MP1 and MP2), 4 rows each.
--
--   ORIGINAL ROWS (logical view):
--   ┌────┬────────┬────────────┬──────────┐
--   │ ID │  NAME  │ DEPARTMENT │  SALARY  │
--   ├────┼────────┼────────────┼──────────┤
--   │  1 │ Rohit  │ Engineering│  95000   │  ─┐
--   │  2 │ Virat  │ Marketing  │  85000   │   ├─ MP1 (rows 1-4)
--   │  3 │ Dhoni  │ Engineering│ 120000   │   │
--   │  4 │ Bumrah │ Sales      │  78000   │  ─┘
--   │  5 │ Jadeja │ Engineering│  92000   │  ─┐
--   │  6 │ Pant   │ Marketing  │  88000   │   ├─ MP2 (rows 5-8)
--   │  7 │ Rahul  │ Sales      │  75000   │   │
--   │  8 │ Gill   │ Engineering│  90000   │  ─┘
--   └────┴────────┴────────────┴──────────┘
--
--   PHYSICAL STORAGE (columnar inside each micro-partition):
--
--   ┌─── MP1 ──────────────────────────────────────────────────┐
--   │  ID column:         [1, 2, 3, 4]         (compressed)    │
--   │  NAME column:       [Rohit,Virat,Dhoni,Bumrah] (compr.)  │
--   │  DEPARTMENT column:  [Eng,Mkt,Eng,Sales]  (compressed)   │
--   │  SALARY column:     [95000,85000,120000,78000] (compr.)  │
--   │                                                          │
--   │  METADATA: ID range [1-4], SALARY range [78000-120000],  │
--   │            DEPARTMENT distinct values: 3, row count: 4   │
--   └──────────────────────────────────────────────────────────┘
--
--   ┌─── MP2 ──────────────────────────────────────────────────┐
--   │  ID column:         [5, 6, 7, 8]         (compressed)    │
--   │  NAME column:       [Jadeja,Pant,Rahul,Gill] (compr.)    │
--   │  DEPARTMENT column:  [Eng,Mkt,Sales,Eng]  (compressed)   │
--   │  SALARY column:     [92000,88000,75000,90000] (compr.)   │
--   │                                                          │
--   │  METADATA: ID range [5-8], SALARY range [75000-92000],   │
--   │            DEPARTMENT distinct values: 3, row count: 4   │
--   └──────────────────────────────────────────────────────────┘
--
--   WHY COLUMNAR?
--   Query: SELECT AVG(salary) FROM employees;
--   → Snowflake reads ONLY the SALARY column from each MP.
--     The NAME, DEPARTMENT, ID columns are NEVER touched.
--     This is called "columnar scanning" — huge I/O savings.
--
--   WHY MICRO-PARTITION METADATA MATTERS (PRUNING)?
--   Query: SELECT * FROM employees WHERE salary > 100000;
--   → Snowflake checks metadata FIRST:
--       MP1 salary range = [78000-120000] → MIGHT have matches → SCAN
--       MP2 salary range = [75000-92000]  → NO value > 100000 → SKIP!
--     Result: only MP1 is scanned. MP2 is "pruned" entirely.
--     On a table with millions of micro-partitions, this skips 90%+ of data.
--
--   WHAT METADATA IS STORED PER MICRO-PARTITION?
--     - Min/Max range of values for EACH column
--     - Number of distinct values per column
--     - Number of NULL values per column
--     - Total row count
--     → All used for query pruning decisions
--
--   CLUSTERING & RECLUSTERING:
--   Data is partitioned by insertion order. Over time, DML can mix
--   value ranges across micro-partitions (overlap), hurting pruning.
--   You can define a CLUSTERING KEY to reorganize micro-partitions:
--
--     ALTER TABLE employees CLUSTER BY (department);
--
--   After automatic reclustering:
--   ┌─── MP1 ──────────────────────────────────────────────────┐
--   │  DEPARTMENT: [Eng, Eng, Eng, Eng]   range=[Eng-Eng]      │
--   │  (all Engineering rows packed together — perfect pruning) │
--   └──────────────────────────────────────────────────────────┘
--   ┌─── MP2 ──────────────────────────────────────────────────┐
--   │  DEPARTMENT: [Mkt, Mkt, Sales, Sales] range=[Mkt-Sales]  │
--   └──────────────────────────────────────────────────────────┘
--
--   Now: WHERE department = 'Engineering' → scans ONLY MP1, skips MP2.
--
--   KEY TAKEAWAYS:
--   1. Micro-partitions are automatic — you never create them manually
--   2. Columnar = only read columns your query needs
--   3. Metadata = skip entire micro-partitions that can't have your data
--   4. Clustering keys = reduce overlap for better pruning on large tables
--   5. Each column is compressed independently (best algorithm per column)
--   6. Typical table: thousands to millions of micro-partitions
--
-- ── END MICRO-PARTITION EXPLANATION ─────────────────────────────
--
-- USE WHEN: Production data, long-lived datasets, anything that
--           needs full recovery capabilities.
-- FEATURES:
--   - Time Travel: up to 90 days (Enterprise+), 1 day (Standard)
--   - Fail-safe: 7 days of additional recovery (non-configurable)
--   - Cloning, Replication, Streams, Tasks, Dynamic Tables — all supported
--   - Clustering keys for large table optimization
--   - Storage: counts toward active storage + Time Travel + Fail-safe

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
    ('Virat', 'Kohli', 'virat@example.com', 'Marketing', 85000),
    ('MS',    'Dhoni', 'dhoni@example.com', 'Engineering', 120000);

SELECT * FROM demo_db.public.employees;

-- Time Travel example (query data as it was 5 minutes ago)
-- SELECT * FROM demo_db.public.employees AT(OFFSET => -60*5);

-- Clone a permanent table (zero-copy)
-- CREATE TABLE demo_db.public.employees_backup CLONE demo_db.public.employees;


-- ============================================================
-- 2. TRANSIENT TABLE
-- ============================================================
-- WHAT: Exactly like a permanent table in functionality (full DML,
--       cloning, streams, tasks) but with TWO cost-saving trade-offs:
--       1. NO Fail-safe period (permanent tables have 7 days)
--       2. Time Travel limited to 0 or 1 day (permanent allows up to 90)
--
-- SIMPLE RULE: Use a transient table when you CAN RECREATE the
--              data from somewhere else if it is lost.
--
-- ── WHY DOES THIS SAVE MONEY? ───────────────────────────────────
--
--   Permanent Table storage cost for 1 TB of data:
--   ┌────────────────────┬──────────┬────────────────────────────┐
--   │ Storage Layer      │ Duration │ Cost (approx @ $23/TB/mo)  │
--   ├────────────────────┼──────────┼────────────────────────────┤
--   │ Active data        │ forever  │ $23/month                  │
--   │ Time Travel        │ 90 days  │ up to $23/month (copy)     │
--   │ Fail-safe          │ 7 days   │ ~$5/month (always on)      │
--   └────────────────────┴──────────┴────────────────────────────┘
--   Total worst case: ~$51/month per TB
--
--   Transient Table (with DATA_RETENTION_TIME_IN_DAYS = 0):
--   ┌────────────────────┬──────────┬────────────────────────────┐
--   │ Storage Layer      │ Duration │ Cost                       │
--   ├────────────────────┼──────────┼────────────────────────────┤
--   │ Active data        │ forever  │ $23/month                  │
--   │ Time Travel        │ 0 days   │ $0                         │
--   │ Fail-safe          │ NONE     │ $0                         │
--   └────────────────────┴──────────┴────────────────────────────┘
--   Total: $23/month per TB  →  ~55% cheaper!
--
-- ── USE CASE 1: ETL/ELT STAGING TABLES ──────────────────────────
--
--   SCENARIO: You load raw CSV/JSON from S3 into Snowflake every
--             hour, transform it, then move clean data to a
--             permanent "fact" table.
--
--   WHY TRANSIENT? The staging table is a temporary landing zone.
--   If the data is lost, you simply re-run the COPY INTO from S3.
--   You don't need Fail-safe or 90-day Time Travel for data that
--   lives in S3 anyway. It saves storage on potentially huge
--   raw data volumes.
--
--   EXAMPLE:
--     S3 bucket  →  TRANSIENT stg_orders (raw landing)
--                       ↓ transform
--                   PERMANENT fact_orders (clean, final)

CREATE OR REPLACE TRANSIENT TABLE demo_db.public.stg_orders_raw (
    raw_json     VARIANT,
    file_name    VARCHAR(200),
    loaded_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
DATA_RETENTION_TIME_IN_DAYS = 0;

-- COPY INTO demo_db.public.stg_orders_raw
-- FROM @my_s3_stage/orders/
-- FILE_FORMAT = (TYPE = 'JSON');


-- ── USE CASE 2: INTERMEDIATE TRANSFORMATION TABLES ──────────────
--
--   SCENARIO: Your pipeline has multiple steps:
--     raw → cleaned → enriched → aggregated → final
--   The "cleaned" and "enriched" tables are intermediate.
--
--   WHY TRANSIENT? These tables are derived from upstream data.
--   If anything goes wrong, you just re-run the pipeline from
--   the raw stage. Paying for Fail-safe on every intermediate
--   table is wasted money.
--
--   EXAMPLE:

CREATE OR REPLACE TRANSIENT TABLE demo_db.public.cleaned_sales (
    transaction_id  VARCHAR(50),
    product_name    VARCHAR(100),
    quantity        INT,
    unit_price      NUMBER(10,2),
    sale_date       DATE
)
DATA_RETENTION_TIME_IN_DAYS = 1;  -- keep 1 day of Time Travel for debugging

-- INSERT INTO demo_db.public.cleaned_sales
-- SELECT ... FROM demo_db.public.stg_orders_raw
-- WHERE raw_json:quantity > 0;  -- filter bad rows


-- ── USE CASE 3: DEVELOPMENT / SANDBOX TABLES ────────────────────
--
--   SCENARIO: Data engineers create tables in a DEV or QA
--             environment to test queries, build prototypes,
--             or experiment with data.
--
--   WHY TRANSIENT? Dev/QA data is disposable. Nobody needs
--   7 days of Fail-safe for a test table. If the table breaks,
--   you recreate it from production. This keeps dev environment
--   costs low, especially when teams clone large production
--   tables for testing.
--
--   EXAMPLE:

CREATE OR REPLACE TRANSIENT TABLE demo_db.public.dev_experiment_users (
    user_id     INT,
    user_name   VARCHAR(50),
    signup_date DATE
);

-- You can even create a TRANSIENT clone of a permanent table:
-- CREATE TRANSIENT TABLE demo_db.public.dev_users_copy
--     CLONE prod_db.public.users;


-- ── USE CASE 4: REPORTING / DASHBOARD SNAPSHOT TABLES ───────────
--
--   SCENARIO: Every morning a job creates a summary table
--             (e.g., daily_sales_summary) that powers a dashboard.
--             The job runs daily and REPLACES the table each time.
--
--   WHY TRANSIENT? The table is rebuilt from scratch every day.
--   If it disappears, the next scheduled run recreates it.
--   Fail-safe for a table that lives only 24 hours is pointless.
--
--   EXAMPLE:

CREATE OR REPLACE TRANSIENT TABLE demo_db.public.daily_sales_summary (
    report_date     DATE,
    total_revenue   NUMBER(15,2),
    total_orders    INT,
    avg_order_value NUMBER(10,2)
)
DATA_RETENTION_TIME_IN_DAYS = 0;


-- ── USE CASE 5: DATA SHARING PREPARATION ────────────────────────
--
--   SCENARIO: You prepare a dataset for sharing with a partner.
--             You filter, mask, and reshape production data into
--             a "share-ready" table, then expose it via a share.
--
--   WHY TRANSIENT? The share-ready table is a derived copy.
--   If lost, regenerate from the production source. No need for
--   Fail-safe on a copy that can always be rebuilt.


-- ── USE CASE 6: MACHINE LEARNING FEATURE / TRAINING TABLES ─────
--
--   SCENARIO: ML engineers create feature tables or training
--             datasets by joining and transforming many source
--             tables. These can be very large (100s of GB).
--
--   WHY TRANSIENT? The feature table is derived from source data.
--   If lost, re-run the feature engineering pipeline. Paying
--   Fail-safe on a 500 GB training dataset you can regenerate
--   wastes ~$2.50/month for nothing.


-- ── USE CASE 7: LOG / AUDIT TABLES WITH EXTERNAL BACKUP ────────
--
--   SCENARIO: Application logs are streamed into Snowflake and
--             also backed up to S3/Azure Blob as the source of
--             truth. The Snowflake table is for querying only.
--
--   WHY TRANSIENT? S3 is the real backup. If the Snowflake table
--   is corrupted or lost, reload from S3. Fail-safe is redundant
--   because you already have an external backup.


-- ── WHEN NOT TO USE TRANSIENT ───────────────────────────────────
--
--   DO NOT use transient for:
--   ✗ Production fact/dimension tables (your source of truth)
--   ✗ Financial or compliance data (regulators may require recovery)
--   ✗ Any data that CANNOT be recreated from another source
--   ✗ Data where you need > 1 day of Time Travel for auditing
--
--   SIMPLE DECISION:
--   ┌─────────────────────────────────────────────────────────┐
--   │  Can I recreate this data if it is completely lost?     │
--   │                                                        │
--   │  YES → TRANSIENT TABLE  (save money)                   │
--   │  NO  → PERMANENT TABLE  (full protection)              │
--   └─────────────────────────────────────────────────────────┘
--
-- FEATURES (same as permanent):
--   - Full DML: INSERT, UPDATE, DELETE, MERGE — all work
--   - Supports cloning, streams, tasks, dynamic tables
--   - Supports clustering keys
--   - Can be replicated to other accounts
--   - Time Travel: 0 or 1 day only (DATA_RETENTION_TIME_IN_DAYS)
--   - Fail-safe: NONE (this is the key difference)

SELECT * FROM demo_db.public.daily_sales_summary;


-- ============================================================
-- 3. TEMPORARY TABLE
-- ============================================================
-- WHAT: Exists ONLY for the duration of the session. Automatically
--       dropped when the session ends. Visible ONLY to the creating session.
-- USE WHEN: Intermediate query results, session-scoped scratch work,
--           ad-hoc analysis, avoiding name collisions between users.
-- FEATURES:
--   - Time Travel: 0 or 1 day (but table is gone after session anyway)
--   - Fail-safe: NONE
--   - NOT visible to other sessions or users
--   - Can shadow (same name as) permanent/transient tables in the schema
--   - No storage cost after session ends

CREATE OR REPLACE TEMPORARY TABLE demo_db.public.temp_high_earners (
    employee_id  INT,
    full_name    VARCHAR(100),
    salary       NUMBER(12,2)
);

INSERT INTO demo_db.public.temp_high_earners
SELECT employee_id,
       first_name || ' ' || last_name,
       salary
FROM demo_db.public.employees
WHERE salary > 90000;

SELECT * FROM demo_db.public.temp_high_earners;
-- This table disappears when your session/worksheet closes.


-- ============================================================
-- 4. EXTERNAL TABLE
-- ============================================================
-- WHAT: A read-only table that references data files in an external
--       stage (S3, GCS, Azure Blob). Data stays outside Snowflake.
-- USE WHEN: Data lake querying, files you cannot or choose not to
--           ingest, cost-sensitive cold data, schema-on-read patterns.
-- FEATURES:
--   - READ-ONLY: no INSERT/UPDATE/DELETE
--   - Schema-on-read via VALUE (VARIANT) column
--   - Virtual columns for strongly typed access
--   - Partitioning (auto or user-defined) for pruning
--   - Auto-refresh metadata via cloud event notifications
--   - Materialized views can be built on top for performance
--   - No Time Travel, no Fail-safe (data is external)
--   - Storage: you pay your cloud provider; Snowflake stores only metadata

-- Example (requires an external stage to exist):
/*
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

SELECT * FROM demo_db.public.ext_web_logs WHERE log_date = '2026-04-01';
*/


-- ============================================================
-- 5. HYBRID TABLE
-- ============================================================
--
-- ── WHAT IS A HYBRID TABLE? (in simple words) ───────────────────
--
-- A Hybrid Table is a Snowflake table built for SPEED on small,
-- fast operations — like reading ONE row by ID or updating ONE
-- row at a time. It works like a traditional database (MySQL,
-- PostgreSQL) but lives inside Snowflake.
--
-- Normal Snowflake tables are COLUMNAR — great for scanning
-- millions of rows (analytics). But terrible for finding ONE
-- specific row quickly.
--
-- Hybrid tables are ROW-BASED — great for finding one row fast.
-- And they ALSO copy data to columnar storage in the background,
-- so you can still run analytical queries on the same data.
--
-- That's why it's called "Hybrid" — it does BOTH:
--   Fast single-row lookups (OLTP)  +  Analytical scans (OLAP)
--
--
-- ── THE PROBLEM IT SOLVES ───────────────────────────────────────
--
-- BEFORE hybrid tables, if your app needed fast reads/writes:
--
--   ┌──────────────┐         ┌──────────────────┐
--   │  Your App    │────────→│  PostgreSQL/MySQL │  (fast single rows)
--   │  (backend)   │         │  (OLTP database)  │
--   └──────────────┘         └────────┬─────────┘
--                                     │ ETL (copy data nightly)
--                                     ▼
--                            ┌──────────────────┐
--                            │  Snowflake        │  (analytics)
--                            │  (standard tables)│
--                            └──────────────────┘
--
--   PROBLEMS with this approach:
--   - Two separate databases to manage
--   - ETL pipeline to sync data (delays, failures, cost)
--   - Data is always stale in Snowflake (hours behind)
--   - Two copies of the same data (double storage cost)
--
-- WITH hybrid tables — everything in ONE place:
--
--   ┌──────────────┐         ┌──────────────────────────────────┐
--   │  Your App    │────────→│  Snowflake                       │
--   │  (backend)   │         │  ┌────────────┐ ┌──────────────┐ │
--   └──────────────┘         │  │ Hybrid     │ │ Standard     │ │
--                            │  │ Tables     │ │ Tables       │ │
--   ┌──────────────┐         │  │ (fast OLTP)│ │ (analytics)  │ │
--   │  Dashboard   │────────→│  └────────────┘ └──────────────┘ │
--   │  (analytics) │         │       ↕ JOIN them together!      │
--   └──────────────┘         └──────────────────────────────────┘
--
--   No ETL needed. No data sync. One platform. Always fresh.
--
--
-- ── HOW IT STORES DATA ──────────────────────────────────────────
--
--   When you INSERT a row into a hybrid table:
--
--   1. The row goes to the ROW STORE first (fast, indexed)
--      → This is why single-row reads are fast (like PostgreSQL)
--
--   2. In the background, Snowflake copies the data to COLUMNAR
--      OBJECT STORAGE (same as standard tables)
--      → This is why analytical scans also work
--
--   3. When you query, Snowflake decides automatically:
--      - Looking up 1 row by ID? → Read from row store (fast)
--      - Scanning 1 million rows? → Read from columnar store (fast)
--
--   You don't choose. Snowflake picks the best path.
--
--
-- ── THE BIG DIFFERENCE: CONSTRAINTS ARE ENFORCED ────────────────
--
-- In standard Snowflake tables, PRIMARY KEY, FOREIGN KEY, and
-- UNIQUE are just labels — Snowflake does NOT enforce them.
-- You can insert duplicate IDs all day. Nobody stops you.
--
-- In hybrid tables, constraints ARE ENFORCED:
--
--   PRIMARY KEY  → REQUIRED. Every hybrid table must have one.
--                  Duplicates are REJECTED with an error.
--
--   FOREIGN KEY  → OPTIONAL but ENFORCED. If you reference a
--                  parent table, the parent row MUST exist.
--
--   UNIQUE       → OPTIONAL but ENFORCED. Duplicate values in
--                  a UNIQUE column are REJECTED.
--
--   NOT NULL     → ENFORCED (same as standard tables).
--
--
-- ── REAL-LIFE USE CASES ─────────────────────────────────────────
--
-- USE CASE 1: USER PROFILE STORE (Web/Mobile App)
--
--   Your app needs to read a user's profile when they log in.
--   That's a single-row lookup by user_id — needs to be fast.
--   Standard Snowflake table: ~100-500ms (too slow for an app).
--   Hybrid table: ~5-10ms (fast enough for real-time).
/*
CREATE OR REPLACE HYBRID TABLE demo_db.public.user_profiles (
    user_id       INT           PRIMARY KEY,
    username      VARCHAR(50)   NOT NULL UNIQUE,
    email         VARCHAR(100)  NOT NULL,
    display_name  VARCHAR(100),
    avatar_url    VARCHAR(500),
    plan_type     VARCHAR(20)   DEFAULT 'free',
    created_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    last_login    TIMESTAMP_NTZ,
    INDEX idx_email (email)
);

INSERT INTO demo_db.public.user_profiles (user_id, username, email, display_name)
VALUES (1, 'rohit_sharma', 'rohit@example.com', 'Rohit Sharma');

-- App does this on every login (fast point lookup):
SELECT * FROM demo_db.public.user_profiles WHERE user_id = 1;

-- App updates last login:
UPDATE demo_db.public.user_profiles
SET last_login = CURRENT_TIMESTAMP()
WHERE user_id = 1;
*/

-- USE CASE 2: SHOPPING CART (E-commerce)
--
--   Users add/remove items from their cart. Each action is a
--   single-row INSERT, UPDATE, or DELETE. Hundreds of users
--   doing this at the same time (high concurrency).
--   Hybrid table handles this with ROW-LEVEL LOCKING — two users
--   updating different rows don't block each other.
/*
CREATE OR REPLACE HYBRID TABLE demo_db.public.shopping_cart (
    cart_item_id   INT          PRIMARY KEY AUTOINCREMENT,
    user_id        INT          NOT NULL,
    product_id     INT          NOT NULL,
    quantity       INT          DEFAULT 1,
    added_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    INDEX idx_cart_user (user_id)
);

-- User adds item to cart:
INSERT INTO demo_db.public.shopping_cart (user_id, product_id, quantity)
VALUES (101, 5001, 2);

-- User changes quantity:
UPDATE demo_db.public.shopping_cart SET quantity = 3 WHERE cart_item_id = 1;

-- Show user's cart (fast lookup by user_id via index):
SELECT * FROM demo_db.public.shopping_cart WHERE user_id = 101;
*/

-- USE CASE 3: IOT DEVICE STATE / METADATA
--
--   You have 100,000 IoT sensors. Each sensor reports its status
--   every few seconds. You need to store the LATEST state of each
--   sensor and look it up by sensor_id.
--   This is a classic "upsert" pattern — INSERT or UPDATE.
/*
CREATE OR REPLACE HYBRID TABLE demo_db.public.device_state (
    device_id       VARCHAR(50)   PRIMARY KEY,
    device_name     VARCHAR(100),
    location        VARCHAR(200),
    status          VARCHAR(20)   DEFAULT 'offline',
    battery_pct     NUMBER(5,2),
    last_heartbeat  TIMESTAMP_NTZ,
    firmware_ver    VARCHAR(20),
    INDEX idx_status (status)
);

-- Device sends heartbeat (upsert):
MERGE INTO demo_db.public.device_state t
USING (SELECT 'sensor-42' AS device_id, 'online' AS status,
              87.5 AS battery_pct, CURRENT_TIMESTAMP() AS ts) s
ON t.device_id = s.device_id
WHEN MATCHED THEN UPDATE SET status = s.status,
    battery_pct = s.battery_pct, last_heartbeat = s.ts
WHEN NOT MATCHED THEN INSERT (device_id, status, battery_pct, last_heartbeat)
    VALUES (s.device_id, s.status, s.battery_pct, s.ts);

-- Dashboard: how many devices are online?
SELECT status, COUNT(*) FROM demo_db.public.device_state GROUP BY status;
*/

-- USE CASE 4: WORKFLOW / JOB STATE TRACKING
--
--   Your ETL pipeline has thousands of parallel workers.
--   Each worker updates its job status in a tracking table.
--   Needs high concurrency — many workers writing at once.
/*
CREATE OR REPLACE HYBRID TABLE demo_db.public.job_tracker (
    job_id        VARCHAR(50)   PRIMARY KEY,
    pipeline_name VARCHAR(100)  NOT NULL,
    status        VARCHAR(20)   DEFAULT 'queued',
    started_at    TIMESTAMP_NTZ,
    finished_at   TIMESTAMP_NTZ,
    error_msg     VARCHAR(1000),
    INDEX idx_pipeline (pipeline_name),
    INDEX idx_status (status)
);

-- Worker starts a job:
INSERT INTO demo_db.public.job_tracker (job_id, pipeline_name, status, started_at)
VALUES ('job-abc-123', 'daily_sales_etl', 'running', CURRENT_TIMESTAMP());

-- Worker completes:
UPDATE demo_db.public.job_tracker
SET status = 'completed', finished_at = CURRENT_TIMESTAMP()
WHERE job_id = 'job-abc-123';

-- Dashboard: show failed jobs today
SELECT * FROM demo_db.public.job_tracker
WHERE status = 'failed' AND started_at >= CURRENT_DATE();
*/

-- USE CASE 5: SERVING PRE-COMPUTED DATA VIA API
--
--   You pre-compute product recommendations daily using
--   standard tables (heavy analytics). Then you store the
--   results in a hybrid table so your API can serve them
--   to users with low latency.
/*
CREATE OR REPLACE HYBRID TABLE demo_db.public.product_recommendations (
    user_id        INT          PRIMARY KEY,
    rec_product_1  INT,
    rec_product_2  INT,
    rec_product_3  INT,
    score_1        FLOAT,
    score_2        FLOAT,
    score_3        FLOAT,
    computed_at    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Nightly job loads recommendations from analytics:
-- INSERT INTO demo_db.public.product_recommendations
-- SELECT ... FROM analytics_db.ml.recommendations;

-- API serves recommendations (fast point lookup):
SELECT * FROM demo_db.public.product_recommendations WHERE user_id = 12345;
*/

-- ── HYBRID TABLE vs STANDARD TABLE COMPARISON ───────────────────
--
--   ┌─────────────────────────┬──────────────────┬──────────────────┐
--   │                         │  STANDARD TABLE  │  HYBRID TABLE    │
--   ├─────────────────────────┼──────────────────┼──────────────────┤
--   │ Storage layout          │ Columnar         │ Row + Columnar   │
--   │ Best for                │ Scan millions    │ Read/write 1 row │
--   │ Single-row lookup       │ Slow (~200ms)    │ Fast (~5-10ms)   │
--   │ Full table scan         │ Fast             │ Also works       │
--   │ PRIMARY KEY             │ Optional, NOT    │ REQUIRED and     │
--   │                         │ enforced         │ ENFORCED         │
--   │ FOREIGN KEY / UNIQUE    │ Not enforced     │ ENFORCED         │
--   │ Locking                 │ Partition/table  │ Row-level        │
--   │ Concurrency             │ Moderate         │ High (16K ops/s) │
--   │ Indexes                 │ No (use Search   │ Yes (secondary)  │
--   │                         │ Optimization Svc)│                  │
--   │ Max data per DB         │ Unlimited        │ 2 TB             │
--   │ Streams                 │ Yes              │ No               │
--   │ Dynamic Tables          │ Yes              │ No               │
--   │ Cloning                 │ Yes              │ Limited          │
--   │ Fail-safe               │ Yes (7 days)     │ No               │
--   │ Replication             │ Yes              │ No               │
--   │ Available on            │ All clouds       │ AWS + Azure only │
--   └─────────────────────────┴──────────────────┴──────────────────┘
--
--
-- ── WHEN NOT TO USE HYBRID TABLES ───────────────────────────────
--
--   ✗ Pure analytics (scanning billions of rows) → use standard table
--   ✗ Data > 2 TB per database → exceeds hybrid table limit
--   ✗ You need Streams, Dynamic Tables, or Snowpipe → not supported
--   ✗ You need Fail-safe or replication → not supported
--   ✗ Your account is on GCP → hybrid tables only on AWS + Azure
--   ✗ Temporary or transient data → hybrid tables can't be transient
--
--
-- ── SIMPLE DECISION ─────────────────────────────────────────────
--
--   ┌──────────────────────────────────────────────────────────┐
--   │  Does your app need to read/write ONE ROW AT A TIME,    │
--   │  very fast, with many users at once?                    │
--   │                                                         │
--   │  YES → HYBRID TABLE                                     │
--   │  NO  → STANDARD TABLE                                   │
--   └──────────────────────────────────────────────────────────┘


-- ============================================================
-- 6. ICEBERG TABLE
-- ============================================================
-- WHAT: Apache Iceberg open table format in Snowflake. Data stored
--       in Parquet files on YOUR external cloud storage. Full read/write
--       when Snowflake is the catalog; read-only with external catalogs.
-- USE WHEN: Open data lakehouse, multi-engine interoperability (Spark,
--           Trino, Flink), avoiding vendor lock-in, large-scale data lakes.
-- FEATURES:
--   - Open Parquet format — readable by any Iceberg-compatible engine
--   - Snowflake-managed catalog: full DML, clustering, compaction
--   - External catalog (Glue, Open Catalog, REST): read + limited write
--   - ACID transactions, schema evolution, hidden partitioning
--   - Catalog-linked databases for auto-discovery of remote tables
--   - Time Travel via Iceberg snapshots
--   - No Fail-safe (you manage external storage)
--   - No Snowflake storage cost (you pay your cloud provider)
--   - Supports Streams (insert-only for external catalog)

-- Example (Snowflake as catalog — requires external volume):
/*
CREATE OR REPLACE ICEBERG TABLE demo_db.public.iceberg_events (
    event_id     INT,
    event_type   VARCHAR(50),
    event_data   VARCHAR,
    created_at   TIMESTAMP_NTZ
)
CATALOG         = 'SNOWFLAKE'
EXTERNAL_VOLUME = 'my_ext_volume'
BASE_LOCATION   = 'events/';

INSERT INTO demo_db.public.iceberg_events
VALUES (1, 'click', '{"page":"home"}', CURRENT_TIMESTAMP());

SELECT * FROM demo_db.public.iceberg_events;
*/


-- ============================================================
-- 7. DYNAMIC TABLE
-- ============================================================
--
-- ── WHAT IS A DYNAMIC TABLE? (in simple words) ─────────────────
--
-- A Dynamic Table is a table where you only define a SELECT query,
-- and Snowflake automatically runs it, stores the result, and
-- keeps it up-to-date whenever the source data changes.
--
-- You write a SELECT query that defines what the table should
-- contain. Snowflake runs that query for you on a schedule and
-- keeps the results fresh. You never INSERT into it manually.
--
-- Think of it like this:
--   A normal table   → YOU put data in, YOU keep it updated.
--   A view           → Runs the query EVERY time someone reads it (slow).
--   A dynamic table  → Snowflake runs the query IN THE BACKGROUND
--                      and stores the result. Reading it is fast
--                      because the data is already computed.
--
-- It's like hiring someone to refresh a report for you every
-- hour so it's always ready when you need it.
--
--
-- ── VIEW vs DYNAMIC TABLE: YOUR DOUBT EXPLAINED ─────────────────
--
-- SHORT ANSWER:
--   A view does NOT store any data. It is just a saved SELECT query.
--   Every time you query a view, Snowflake runs the full SELECT
--   at that moment and gives you the result. So yes — a view always
--   shows the LATEST data, but it re-computes everything every time.
--
-- EXAMPLE: Let's see what happens step by step.
--
--   Suppose we have a table with 10 MILLION orders.
--
--   -- Source table
--   CREATE TABLE demo_db.public.orders (
--       order_id INT, customer VARCHAR, amount NUMBER, order_date DATE
--   );
--   -- (imagine 10 million rows here)
--
--   -- Create a VIEW
--   CREATE VIEW demo_db.public.v_daily_sales AS
--   SELECT order_date, SUM(amount) AS total, COUNT(*) AS num_orders
--   FROM demo_db.public.orders
--   GROUP BY order_date;
--
--   -- Create a DYNAMIC TABLE (same query)
--   CREATE DYNAMIC TABLE demo_db.public.dt_daily_sales
--       TARGET_LAG = '1 hour'  WAREHOUSE = COMPUTE_WH
--   AS
--   SELECT order_date, SUM(amount) AS total, COUNT(*) AS num_orders
--   FROM demo_db.public.orders
--   GROUP BY order_date;
--
--
-- NOW LET'S SEE WHAT HAPPENS WHEN YOU QUERY EACH ONE:
--
--   ┌─────────────────────────────────────────────────────────────┐
--   │  SELECT * FROM v_daily_sales;    -- VIEW                   │
--   │                                                            │
--   │  What happens behind the scenes:                           │
--   │  1. Snowflake sees "v_daily_sales" is a view               │
--   │  2. It replaces it with the stored SELECT query            │
--   │  3. It scans ALL 10 million rows in the orders table       │
--   │  4. It computes SUM and COUNT for every date               │
--   │  5. It returns the result                                  │
--   │  6. Takes ~30 seconds (heavy work every single time)       │
--   │                                                            │
--   │  Next time you run the same SELECT?                        │
--   │  → Same 30 seconds. It does the FULL scan again.           │
--   └─────────────────────────────────────────────────────────────┘
--
--   ┌─────────────────────────────────────────────────────────────┐
--   │  SELECT * FROM dt_daily_sales;   -- DYNAMIC TABLE          │
--   │                                                            │
--   │  What happens behind the scenes:                           │
--   │  1. Snowflake already computed the result in the background │
--   │  2. The result is stored as actual rows in dt_daily_sales  │
--   │  3. It just reads those pre-computed rows                  │
--   │  4. Takes ~1 second (just reading stored data)             │
--   │                                                            │
--   │  Next time you run the same SELECT?                        │
--   │  → Same 1 second. Already computed.                        │
--   └─────────────────────────────────────────────────────────────┘
--
--
-- WHAT HAPPENS WHEN SOURCE TABLE GETS UPDATED?
--
--   Let's say at 2:00 PM someone inserts 1000 new orders.
--
--   VIEW (v_daily_sales):
--   ┌──────────┬────────────────────────────────────────────────┐
--   │ 2:00 PM  │ 1000 new rows inserted into orders table      │
--   │ 2:01 PM  │ You query the view                            │
--   │          │ → View re-scans ALL 10,001,000 rows            │
--   │          │ → Result includes the new 1000 rows            │
--   │          │ → Always 100% live, but SLOW every time        │
--   └──────────┴────────────────────────────────────────────────┘
--
--   DYNAMIC TABLE (dt_daily_sales, TARGET_LAG = '1 hour'):
--   ┌──────────┬────────────────────────────────────────────────┐
--   │ 2:00 PM  │ 1000 new rows inserted into orders table      │
--   │ 2:01 PM  │ You query the dynamic table                   │
--   │          │ → Result does NOT include the new rows yet     │
--   │          │ → It shows data from the last refresh          │
--   │          │ → But it returns in 1 second (fast!)           │
--   │ 2:30 PM  │ Snowflake detects changes, refreshes the DT   │
--   │          │ (processes only the 1000 new rows, not all 10M)│
--   │ 2:31 PM  │ You query again → now includes the new rows   │
--   │          │ → Still returns in 1 second                    │
--   └──────────┴────────────────────────────────────────────────┘
--
--
-- SIDE-BY-SIDE SUMMARY:
--
--   ┌──────────────────────┬──────────────────┬────────────────────┐
--   │                      │      VIEW        │   DYNAMIC TABLE    │
--   ├──────────────────────┼──────────────────┼────────────────────┤
--   │ Stores data?         │ NO (just a query)│ YES (real rows)    │
--   │ When does it compute?│ Every time you   │ In the background, │
--   │                      │ query it         │ based on TARGET_LAG│
--   │ Query speed          │ SLOW (recomputes)│ FAST (pre-computed)│
--   │ Data freshness       │ 100% live, always│ Slightly behind    │
--   │                      │ up-to-date       │ (by TARGET_LAG)    │
--   │ Storage cost         │ $0 (no data)     │ Costs storage      │
--   │ Compute cost         │ Every query costs│ Only refresh costs │
--   │                      │ compute          │ compute            │
--   │ Good for             │ Simple lookups,  │ Heavy aggregations,│
--   │                      │ small tables,    │ large tables,      │
--   │                      │ always-live need │ dashboards, pipes  │
--   └──────────────────────┴──────────────────┴────────────────────┘
--
-- WHEN TO USE WHICH?
--
--   Use a VIEW when:
--     - The underlying table is small (thousands of rows)
--     - You need 100% real-time data (zero lag)
--     - The query is simple (no heavy JOINs or aggregations)
--     - You don't want to pay for extra storage
--
--   Use a DYNAMIC TABLE when:
--     - The underlying data is large (millions/billions of rows)
--     - The query involves heavy JOINs, GROUP BY, window functions
--     - Many users/dashboards query the same result repeatedly
--     - You can tolerate a small delay (1 min to 1 day)
--     - You want to build a multi-step pipeline (chaining)
--
--
-- ── END VIEW vs DYNAMIC TABLE EXPLANATION ───────────────────────
--
--
-- ── THE PROBLEM DYNAMIC TABLES SOLVE ────────────────────────────
--
-- BEFORE dynamic tables, building a data pipeline looked like this:
--
--   STEP 1: Create a Stream on the source table (to track changes)
--   STEP 2: Create a Task that runs every X minutes
--   STEP 3: Write a stored procedure that reads the stream,
--           transforms data, and inserts into the target table
--   STEP 4: Handle errors, retries, ordering, deduplication
--   STEP 5: If you have 5 transformation steps, repeat 1-4 FIVE TIMES
--
--   This is complex, error-prone, and hard to maintain.
--
--   ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
--   │  Source   │───→│ Stream 1 │───→│  Task 1  │───→│ Table A  │
--   │  Table    │    └──────────┘    │ (proc)   │    └────┬─────┘
--   └──────────┘                     └──────────┘         │
--                                                         ▼
--                                    ┌──────────┐    ┌──────────┐
--                                    │ Stream 2 │───→│  Task 2  │───→ Table B
--                                    └──────────┘    │ (proc)   │
--                                                    └──────────┘
--   ^ You have to build & manage ALL of this yourself.
--
-- WITH dynamic tables, the same pipeline becomes:
--
--   ┌──────────┐    ┌────────────────┐    ┌────────────────┐
--   │  Source   │───→│ Dynamic Table A│───→│ Dynamic Table B│
--   │  Table    │    │ (just a SELECT)│    │ (just a SELECT)│
--   └──────────┘    └────────────────┘    └────────────────┘
--
--   ^ That's it. No streams, no tasks, no procedures.
--     Snowflake handles EVERYTHING behind the scenes.
--
--
-- ── HOW IT WORKS ────────────────────────────────────────────────
--
--   1. You write: CREATE DYNAMIC TABLE ... AS SELECT ...
--   2. You set a TARGET_LAG (how fresh you want the data)
--      Examples: '1 minute', '5 minutes', '1 hour', '1 day'
--   3. Snowflake watches the source tables for changes
--   4. When changes happen, Snowflake re-runs your query
--      and updates the dynamic table AUTOMATICALLY
--   5. It tries to do this INCREMENTALLY (only process new/changed
--      rows) instead of recomputing everything from scratch
--
--   TARGET_LAG = '1 hour' means:
--     "The data in this dynamic table should never be more than
--      1 hour behind the source table."
--
--   If someone inserts a row into the source at 2:00 PM,
--   the dynamic table will have that row by 3:00 PM (at most).
--
--
-- ── EXAMPLE 1: BASIC — Daily sales summary ──────────────────────

CREATE OR REPLACE TABLE demo_db.public.raw_orders (
    order_id    INT,
    customer    VARCHAR(50),
    amount      NUMBER(10,2),
    order_date  DATE
);

INSERT INTO demo_db.public.raw_orders VALUES
    (1, 'Alice', 250.00, '2026-04-01'),
    (2, 'Bob',   150.00, '2026-04-01'),
    (3, 'Alice', 300.00, '2026-04-02'),
    (4, 'Carol', 450.00, '2026-04-02');

-- This dynamic table automatically computes daily totals per customer.
-- Whenever new orders are added to raw_orders, this table updates itself.

CREATE OR REPLACE DYNAMIC TABLE demo_db.public.daily_customer_totals
    TARGET_LAG = '1 hour'
    WAREHOUSE  = COMPUTE_WH
AS
    SELECT
        customer,
        order_date,
        SUM(amount)   AS total_amount,
        COUNT(*)      AS order_count
    FROM demo_db.public.raw_orders
    GROUP BY customer, order_date;

-- Now just query it — the data is always fresh:
-- SELECT * FROM demo_db.public.daily_customer_totals;

-- Add more orders to the source...
-- INSERT INTO demo_db.public.raw_orders VALUES (5, 'Alice', 100.00, '2026-04-03');
-- ... within 1 hour, daily_customer_totals will include the new row.


-- ── EXAMPLE 2: CHAINING — Multi-step pipeline ──────────────────
--
-- Real pipelines have multiple steps. Dynamic tables can feed
-- into other dynamic tables, forming a chain (DAG).
--
--   raw_orders
--       ↓
--   daily_customer_totals  (DT1: aggregate per customer per day)
--       ↓
--   vip_customers          (DT2: find customers who spent > $500)
--
-- Each dynamic table is just a SELECT. Snowflake handles the
-- refresh order automatically (it refreshes DT1 before DT2).

/*
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.vip_customers
    TARGET_LAG = '1 hour'
    WAREHOUSE  = COMPUTE_WH
AS
    SELECT
        customer,
        SUM(total_amount) AS lifetime_spend,
        SUM(order_count)  AS lifetime_orders
    FROM demo_db.public.daily_customer_totals
    GROUP BY customer
    HAVING SUM(total_amount) > 500;
*/

-- Chain: raw_orders → daily_customer_totals → vip_customers
-- All automatic. You never write a single INSERT statement.


-- ── EXAMPLE 3: REAL WORLD — E-commerce analytics pipeline ──────
--
-- SOURCE TABLES (raw data from your app):
--   orders, order_items, products, customers
--
-- PIPELINE:
/*
-- Step 1: Clean and join raw data (refresh every 10 minutes)
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.enriched_orders
    TARGET_LAG = '10 minutes'
    WAREHOUSE  = COMPUTE_WH
AS
    SELECT
        o.order_id,
        o.order_date,
        c.customer_name,
        c.region,
        oi.product_id,
        p.product_name,
        p.category,
        oi.quantity,
        oi.unit_price,
        oi.quantity * oi.unit_price AS line_total
    FROM demo_db.public.orders o
    JOIN demo_db.public.order_items oi ON o.order_id = oi.order_id
    JOIN demo_db.public.products p     ON oi.product_id = p.product_id
    JOIN demo_db.public.customers c    ON o.customer_id = c.customer_id;

-- Step 2: Aggregate for dashboards (refresh every 30 minutes)
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.sales_dashboard
    TARGET_LAG = '30 minutes'
    WAREHOUSE  = COMPUTE_WH
AS
    SELECT
        region,
        category,
        order_date,
        SUM(line_total)  AS revenue,
        COUNT(DISTINCT order_id) AS num_orders
    FROM demo_db.public.enriched_orders
    GROUP BY region, category, order_date;

-- Step 3: Detect top-selling products today (refresh every 1 hour)
CREATE OR REPLACE DYNAMIC TABLE demo_db.public.top_products_today
    TARGET_LAG = '1 hour'
    WAREHOUSE  = COMPUTE_WH
AS
    SELECT
        product_name,
        category,
        SUM(quantity)    AS units_sold,
        SUM(line_total)  AS revenue
    FROM demo_db.public.enriched_orders
    WHERE order_date = CURRENT_DATE()
    GROUP BY product_name, category
    ORDER BY revenue DESC
    LIMIT 50;
*/


-- ── USE CASE SUMMARY ────────────────────────────────────────────
--
-- USE CASE 1: ETL/ELT PIPELINES
--   Replace Streams + Tasks chains with simple SELECT statements.
--   raw → cleaned → enriched → aggregated — all dynamic tables.
--
-- USE CASE 2: REAL-TIME DASHBOARDS
--   Power BI / Tableau reads from a dynamic table that refreshes
--   every few minutes. Dashboard is always current, queries are
--   fast because data is pre-computed.
--
-- USE CASE 3: DATA WAREHOUSE LAYERS
--   Build your Bronze → Silver → Gold layers as dynamic tables.
--   Bronze: raw data (regular table)
--   Silver: cleaned/joined (dynamic table, TARGET_LAG = '10 min')
--   Gold: aggregated/business-ready (dynamic table, TARGET_LAG = '1 hr')
--
-- USE CASE 4: SLOWLY CHANGING DIMENSIONS (SCD)
--   Track changes to customer/product data over time.
--   Dynamic tables can handle SCD Type 1 (overwrite) natively.
--
-- USE CASE 5: DATA SHARING
--   Share a dynamic table with another Snowflake account.
--   The consumer always sees fresh, pre-computed data.
--
-- USE CASE 6: FEATURE ENGINEERING (ML)
--   Compute ML features from raw data. The feature table is
--   always up-to-date for model training or inference.
--
--
-- ── TARGET_LAG EXPLAINED ────────────────────────────────────────
--
--   TARGET_LAG is NOT a schedule. It's a FRESHNESS GUARANTEE.
--
--   '1 minute'  → Data is at most 1 minute behind source.
--                  Highest cost (most frequent refreshes).
--
--   '1 hour'    → Data is at most 1 hour behind source.
--                  Good balance for most dashboards.
--
--   '1 day'     → Data is at most 1 day behind source.
--                  Cheapest. Good for daily reports.
--
--   DOWNSTREAM (chained lag):
--     If DT1 has TARGET_LAG = '10 min' and DT2 reads from DT1
--     with TARGET_LAG = '30 min', then DT2 can be up to
--     10 + 30 = 40 minutes behind the original source.
--
--   SPECIAL VALUE: TARGET_LAG = DOWNSTREAM
--     Means "refresh me just in time, right before any
--     downstream dynamic table that depends on me refreshes."
--     This avoids unnecessary refreshes.
--
--
-- ── WHAT YOU CANNOT DO WITH DYNAMIC TABLES ──────────────────────
--
--   ✗ INSERT, UPDATE, DELETE — the data is fully managed by Snowflake
--   ✗ Define clustering keys (Snowflake may cluster automatically)
--   ✗ Use non-deterministic functions that change per call
--     (e.g., CURRENT_TIMESTAMP in the SELECT — use it carefully)
--
--
-- ── MONITORING YOUR DYNAMIC TABLES ──────────────────────────────

-- Check when it last refreshed and how long it took:
-- SELECT * FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
--     NAME => 'DEMO_DB.PUBLIC.DAILY_CUSTOMER_TOTALS'));

-- See all dynamic tables and their lag status:
-- SHOW DYNAMIC TABLES IN SCHEMA demo_db.public;

-- Suspend refreshes (save cost when not needed):
-- ALTER DYNAMIC TABLE demo_db.public.daily_customer_totals SUSPEND;

-- Resume refreshes:
-- ALTER DYNAMIC TABLE demo_db.public.daily_customer_totals RESUME;
--
--
-- ── DYNAMIC TABLE vs VIEW vs MATERIALIZED VIEW ─────────────────
--
--   ┌───────────────────┬──────────────┬──────────────────┬────────────────┐
--   │                   │    VIEW      │ MATERIALIZED VIEW│ DYNAMIC TABLE  │
--   ├───────────────────┼──────────────┼──────────────────┼────────────────┤
--   │ Stores data?      │ No           │ Yes              │ Yes            │
--   │ When does it run? │ Every query  │ Auto-maintained  │ Based on lag   │
--   │ Query speed       │ Slow (rerun) │ Fast (stored)    │ Fast (stored)  │
--   │ Source support     │ Any SQL      │ 1 table only     │ JOINs, aggs,  │
--   │                   │              │ (limited)        │ subqueries OK  │
--   │ Chaining          │ Yes          │ No               │ Yes (DAG)      │
--   │ Manual DML        │ N/A          │ No               │ No             │
--   │ Freshness control │ Always live  │ Auto             │ TARGET_LAG     │
--   └───────────────────┴──────────────┴──────────────────┴────────────────┘
--
--   SIMPLE RULE:
--   - Need always-live data, simple query  → VIEW
--   - Need fast reads, single-table agg    → MATERIALIZED VIEW
--   - Need fast reads, complex transforms,
--     multi-table JOINs, pipeline chains   → DYNAMIC TABLE


-- ============================================================
-- 8. EVENT TABLE
-- ============================================================
--
-- ── WHAT IS AN EVENT TABLE? (in simple words) ───────────────────
--
-- An Event Table is where Snowflake saves LOG MESSAGES and
-- DIAGNOSTIC DATA from your code — stored procedures, UDFs,
-- UDTFs, and Snowpark apps.
--
-- Think of it like a diary your code writes while it runs.
-- If something goes wrong, you read the diary to find out
-- what happened and where it broke.
--
-- You do NOT insert into this table yourself.
-- Your code writes log messages → Snowflake captures them
-- automatically → they appear in the event table → you query
-- them with SQL to debug or monitor.
--
--
-- ── WHY DO WE NEED IT? ─────────────────────────────────────────
--
-- PROBLEM: You write a stored procedure that processes 1 million
-- rows. It fails silently or returns wrong results. How do you
-- find out what happened?
--
--   Without event table:
--     - You have NO visibility into what your code did
--     - You add RETURN statements to debug (slow, tedious)
--     - You cannot see errors from UDFs at all
--     - You are blind
--
--   With event table:
--     - Your code writes log messages (like print statements)
--     - Snowflake captures them in the event table
--     - You query the event table: "show me all errors from
--       yesterday's procedure run"
--     - You see exactly which line failed and why
--
--
-- ── HOW IT WORKS ────────────────────────────────────────────────
--
--   ┌──────────────────────────────────┐
--   │  Your Code                       │
--   │  (Stored Proc / UDF / Snowpark)  │
--   │                                  │
--   │  logger.info("Processing row 1") │
--   │  logger.error("Column X is NULL")│
--   │  logger.warn("Skipping bad row") │
--   └──────────────┬───────────────────┘
--                  │ Snowflake captures
--                  │ these automatically
--                  ▼
--   ┌──────────────────────────────────┐
--   │  EVENT TABLE                     │
--   │  (SNOWFLAKE.TELEMETRY.EVENTS)    │
--   │                                  │
--   │  Columns:                        │
--   │  - TIMESTAMP    (when it happened)│
--   │  - RESOURCE_ATTRIBUTES (who/what)│
--   │  - RECORD_TYPE  (LOG or SPAN)    │
--   │  - RECORD       (the message)    │
--   │  - VALUE        (extra data)     │
--   └──────────────────────────────────┘
--                  │
--                  ▼
--   ┌──────────────────────────────────┐
--   │  YOU query it with SQL           │
--   │  SELECT * FROM ...EVENTS_VIEW    │
--   │  WHERE RECORD_TYPE = 'LOG'       │
--   │  AND TIMESTAMP > '2026-04-24'    │
--   └──────────────────────────────────┘
--
--
-- ── WHAT DOES IT CAPTURE? ───────────────────────────────────────
--
--   1. LOG MESSAGES — info, warning, error messages from your code
--      (like print/console.log but captured in a table)
--
--   2. TRACE EVENTS (SPANS) — structured data that tracks how
--      long each part of your code took, with key-value pairs
--      you define (like tags)
--
--   3. METRICS — CPU usage, memory usage of your running code
--      (Snowflake generates these automatically)
--
--
-- ── THE DEFAULT EVENT TABLE ─────────────────────────────────────
--
-- Snowflake automatically creates one for you:
--   SNOWFLAKE.TELEMETRY.EVENTS
--
-- BUT you will get EMPTY results if you don't follow these steps.
--
-- ── WHY YOU GOT EMPTY RESULTS (3 common reasons) ───────────────
--
-- REASON 1: LOG_LEVEL is OFF (default). Snowflake won't capture
--           any logs until you turn it ON.
--
-- REASON 2: You never ran any procedure/UDF that writes logs.
--           Regular SQL (SELECT, INSERT, CREATE) does NOT write
--           to the event table. Only code inside procedures/UDFs does.
--
-- REASON 3: Logs have a 1-2 minute delay before they appear.
--           If you query immediately after calling a proc, you
--           may see nothing yet. Wait and try again.
--
-- ── COMPLETE STEP-BY-STEP SETUP (run in this order) ─────────────

-- =====================
-- STEP 1: ENABLE LOGGING (requires ACCOUNTADMIN role)
-- =====================
ALTER ACCOUNT SET LOG_LEVEL = 'INFO';
ALTER ACCOUNT SET TRACE_LEVEL = 'ON_EVENT';

-- =====================
-- STEP 2: VERIFY EVENT TABLE IS ACTIVE
-- =====================
SHOW PARAMETERS LIKE 'EVENT_TABLE' IN ACCOUNT;
-- You should see: SNOWFLAKE.TELEMETRY.EVENTS
-- If it shows NONE, uncomment and run this:
-- ALTER ACCOUNT SET EVENT_TABLE = 'SNOWFLAKE.TELEMETRY.EVENTS';

-- =====================
-- STEP 3: CREATE A TEST PROCEDURE (this writes logs)
-- =====================
CREATE OR REPLACE PROCEDURE demo_db.public.test_logging()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import logging
logger = logging.getLogger('test_logging')

def run(session):
    logger.info("Step 1: Logging test started")
    logger.info("Step 2: This is an INFO message")
    logger.warning("Step 3: This is a WARNING message")
    logger.error("Step 4: This is a fake ERROR for testing")
    logger.info("Step 5: Logging test completed")
    return "Logging test done - check EVENTS_VIEW now!"
$$;

-- =====================
-- STEP 4: RUN THE PROCEDURE (no call = no logs!)
-- =====================
CALL demo_db.public.test_logging();

-- =====================
-- STEP 5: WAIT 1-2 MINUTES (logs are not instant)
-- =====================

-- =====================
-- STEP 6: QUERY THE EVENT TABLE (now you should see results!)
-- =====================
SELECT
    TIMESTAMP,
    RECORD['severity_text']::VARCHAR AS log_level,
    VALUE::VARCHAR                   AS message
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'LOG'
ORDER BY TIMESTAMP DESC
LIMIT 20;

-- ── STILL EMPTY? TROUBLESHOOTING CHECKLIST ──────────────────────
--
-- CHECK 1: Did you wait 1-2 minutes after CALL?
--
-- CHECK 2: Verify account-level log setting:
-- SHOW PARAMETERS LIKE 'LOG_LEVEL' IN ACCOUNT;
--   → If it says OFF → run: ALTER ACCOUNT SET LOG_LEVEL = 'INFO';
--
-- CHECK 3: Database-level can OVERRIDE account-level:
-- SHOW PARAMETERS LIKE 'LOG_LEVEL' IN DATABASE demo_db;
--   → If it says OFF → run: ALTER DATABASE demo_db SET LOG_LEVEL = 'INFO';
--
-- CHECK 4: Try querying with NO filters at all:
-- SELECT * FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
-- ORDER BY TIMESTAMP DESC LIMIT 10;
--
-- LOG_LEVEL HIERARCHY (most specific wins):
--   ACCOUNT → DATABASE → SCHEMA → PROCEDURE/UDF
--   If account = INFO but database = OFF, that database logs nothing.


-- ── EXAMPLE 1: Python Stored Procedure with Logging ─────────────
--
-- This procedure processes employee data and logs what it does.

CREATE OR REPLACE PROCEDURE demo_db.public.process_employees()
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
import logging
logger = logging.getLogger('employee_processor')

def run(session):
    logger.info("Starting employee processing...")

    df = session.table("demo_db.public.employees")
    row_count = df.count()
    logger.info(f"Found {row_count} employees to process")

    high_earners = df.filter(df["SALARY"] > 100000)
    he_count = high_earners.count()
    logger.info(f"Found {he_count} high earners (salary > 100K)")

    if he_count == 0:
        logger.warning("No high earners found - check if salary data is correct")

    logger.info("Employee processing completed successfully")
    return f"Processed {row_count} employees, {he_count} high earners"
$$;

-- Run it:
CALL demo_db.public.process_employees();

-- Wait 1-2 minutes, then query the logs:
SELECT
    TIMESTAMP,
    RECORD['severity_text']::VARCHAR AS log_level,
    VALUE::VARCHAR                   AS message
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'LOG'
  AND RESOURCE_ATTRIBUTES['snow.executable.name'] LIKE '%PROCESS_EMPLOYEES%'
ORDER BY TIMESTAMP DESC;

-- Expected result:
-- ┌─────────────────────┬───────────┬─────────────────────────────────────────┐
-- │ TIMESTAMP           │ LOG_LEVEL │ MESSAGE                                 │
-- ├─────────────────────┼───────────┼─────────────────────────────────────────┤
-- │ 2026-04-24 10:00:03 │ INFO      │ Employee processing completed           │
-- │ 2026-04-24 10:00:02 │ INFO      │ Found 1 high earners (salary > 100K)   │
-- │ 2026-04-24 10:00:01 │ INFO      │ Found 3 employees to process           │
-- │ 2026-04-24 10:00:00 │ INFO      │ Starting employee processing...        │
-- └─────────────────────┴───────────┴─────────────────────────────────────────┘


-- ── EXAMPLE 2: JavaScript UDF with Error Logging ────────────────

CREATE OR REPLACE FUNCTION demo_db.public.parse_order_json(json_str VARCHAR)
RETURNS VARIANT
LANGUAGE JAVASCRIPT
AS
$$
    try {
        var result = JSON.parse(JSON_STR);
        return result;
    } catch(err) {
        snowflake.log("error", "Failed to parse JSON: " + err.message
                      + " | Input: " + JSON_STR.substring(0, 100));
        return null;
    }
$$;

-- Test with valid JSON (works fine):
SELECT demo_db.public.parse_order_json('{"valid": true}');

-- Test with bad JSON (logs an error):
SELECT demo_db.public.parse_order_json('bad json {{{');

-- Wait 1-2 minutes, then find the errors:
SELECT
    TIMESTAMP,
    VALUE::VARCHAR AS error_message
FROM SNOWFLAKE.TELEMETRY.EVENTS_VIEW
WHERE RECORD_TYPE = 'LOG'
  AND RECORD['severity_text']::VARCHAR = 'ERROR'
ORDER BY TIMESTAMP DESC;

-- ── CONTROLLING WHAT GETS CAPTURED (Telemetry Levels) ───────────
--
-- You can control how much logging is captured. More logging =
-- more storage cost. Set the level based on your needs:
--
--   LOG_LEVEL:
--     OFF   → capture nothing
--     ERROR → only errors
--     WARN  → errors + warnings
--     INFO  → errors + warnings + info (recommended)
--     DEBUG → everything (verbose, use for debugging only)
--
--   Set at account, database, schema, or individual object level:

-- ALTER ACCOUNT SET LOG_LEVEL = 'INFO';
-- ALTER DATABASE demo_db SET LOG_LEVEL = 'ERROR';
-- ALTER PROCEDURE demo_db.public.process_employees() SET LOG_LEVEL = 'DEBUG';

-- TRACE_LEVEL (for trace events / spans):
-- ALTER ACCOUNT SET TRACE_LEVEL = 'ON_EVENT';  -- capture trace events
-- ALTER ACCOUNT SET TRACE_LEVEL = 'OFF';        -- no trace events


-- ── WHERE (USE CASES) DO WE USE EVENT TABLES? ──────────────────
--
-- USE CASE 1: DEBUGGING FAILED PROCEDURES
--   Your nightly ETL procedure failed. Query the event table
--   to see the exact error message, which row caused it,
--   and at what time.
--
-- USE CASE 2: MONITORING UDF PERFORMANCE
--   You have a UDF called millions of times. Use trace events
--   to measure how long each call takes, find slow inputs,
--   and optimize.
--
-- USE CASE 3: AUDITING DATA PROCESSING
--   Log how many rows were processed, how many were skipped,
--   how many had errors. Query the event table for a daily
--   processing report.
--
-- USE CASE 4: SNOWPARK APPLICATION OBSERVABILITY
--   Your Snowpark Python app runs complex ML pipelines.
--   Log each step (data load, feature engineering, training,
--   prediction) so you can trace the full execution.
--
-- USE CASE 5: NATIVE APP DIAGNOSTICS
--   You build a Snowflake Native App for consumers.
--   They can't see your code, but the event table captures
--   logs so you can debug issues in their account.
--
--
-- ── CUSTOM EVENT TABLE (optional) ───────────────────────────────
--
-- You usually don't need this. The default one is fine.
-- But if you want a separate event table (e.g., for isolation):
/*
CREATE OR REPLACE EVENT TABLE demo_db.public.my_custom_events;
ALTER ACCOUNT SET EVENT_TABLE = demo_db.public.my_custom_events;
*/
--
-- ── KEY TAKEAWAYS ───────────────────────────────────────────────
--
--   1. Event table = a log file for your Snowflake code
--   2. You don't INSERT into it — your code's log statements go there
--   3. Default one exists: SNOWFLAKE.TELEMETRY.EVENTS (no setup needed)
--   4. Query it via SNOWFLAKE.TELEMETRY.EVENTS_VIEW
--   5. Control verbosity with LOG_LEVEL and TRACE_LEVEL settings
--   6. Captures: log messages, trace spans, CPU/memory metrics
--   7. Works with: Python, JavaScript, Java, Scala UDFs & procedures


-- ============================================================
-- COMPARISON TABLE: ALL TABLE TYPES AT A GLANCE
-- ============================================================
/*
+------------------+------------+----------+-----------+--------+----------+--------+---------+-------+
| Feature          | Permanent  |Transient |Temporary  |External| Hybrid   |Iceberg |Dynamic  |Event  |
+------------------+------------+----------+-----------+--------+----------+--------+---------+-------+
| Data Storage     | Snowflake  |Snowflake |Snowflake  |External|Row Store |External|Snowflake|SF     |
| Read/Write       | Full DML   |Full DML  |Full DML   |Read    |Full DML  |Full*   |Auto only|System |
| Time Travel      | 0-90 days  |0-1 day   |0-1 day    | No     |Limited   |Yes**   |Yes      |Yes    |
| Fail-safe        | 7 days     | No       | No        | No     | No       | No     |Yes      |Yes    |
| Cloning          | Yes        | Yes      | No        | No     | No***    | Yes    |Yes      | No    |
| Streams          | Yes        | Yes      | Yes       | No     | No       |Partial |Yes      | No    |
| Clustering       | Yes        | Yes      | Yes       | N/A    | By PK    | Yes*   |Yes      | No    |
| Constraints      | Not enforced|Not enf. |Not enf.   | N/A    |Enforced  |Not enf.|Not enf. | N/A   |
| Replication      | Yes        | Yes      | No        | No     | No       | Yes*   |Yes      | No    |
| Session Scoped   | No         | No       | YES       | No     | No       | No     | No      | No    |
| Visible to all   | Yes        | Yes      | NO        | Yes    | Yes      | Yes    | Yes     | Yes   |
+------------------+------------+----------+-----------+--------+----------+--------+---------+-------+

*   Iceberg: Full DML when Snowflake is catalog; limited with external catalog.
    Clustering only for Snowflake-managed Iceberg tables.
    Replication only for Snowflake-managed Iceberg tables.
**  Iceberg: Time Travel via Iceberg snapshots.
*** Hybrid: Limited cloning support (see docs for details).
*/


-- ============================================================
-- WHEN TO USE WHAT: DECISION GUIDE
-- ============================================================
/*
SCENARIO                                          → TABLE TYPE
─────────────────────────────────────────────────────────────────
Production fact/dimension tables                  → PERMANENT
ETL staging / intermediate data                   → TRANSIENT
Session-scoped scratch / ad-hoc analysis          → TEMPORARY
Query data lake files without ingestion           → EXTERNAL
Low-latency app backend / OLTP workloads          → HYBRID
Open lakehouse / multi-engine interoperability    → ICEBERG
Declarative data pipelines / auto-refresh         → DYNAMIC
UDF/procedure logging & observability             → EVENT
*/


-- ============================================================
-- STORAGE COST COMPARISON
-- ============================================================
/*
Table Type     | Active Storage | Time Travel Storage | Fail-safe Storage
───────────────┼────────────────┼─────────────────────┼───────────────────
Permanent      | YES            | YES (0-90 days)     | YES (7 days)
Transient      | YES            | YES (0-1 day)       | NO
Temporary      | YES (session)  | YES (0-1 day)       | NO
External       | NO (external)  | NO                  | NO
Hybrid         | YES (row store)| YES (limited)       | NO
Iceberg        | NO (external)  | Via snapshots        | NO
Dynamic        | YES            | YES                 | YES
Event          | YES            | YES                 | YES
*/
