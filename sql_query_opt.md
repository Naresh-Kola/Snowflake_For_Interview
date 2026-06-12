# SQL Query Optimization: Complete Scenario Guide

---

## Table of Contents

1. [Indexing Strategies](#1-indexing-strategies)
2. [JOIN Optimization](#2-join-optimization)
3. [Subquery vs CTE vs Temp Table](#3-subquery-vs-cte-vs-temp-table)
4. [Avoiding Full Table Scans](#4-avoiding-full-table-scans)
5. [Aggregate & GROUP BY Optimization](#5-aggregate--group-by-optimization)
6. [Pagination Optimization](#6-pagination-optimization)
7. [N+1 Query Problem](#7-n1-query-problem)
8. [Window Functions Over Subqueries](#8-window-functions-over-subqueries)
9. [EXISTS vs IN vs JOIN](#9-exists-vs-in-vs-join)
10. [Wildcard & LIKE Optimization](#10-wildcard--like-optimization)
11. [NULL Handling](#11-null-handling)
12. [Date & Range Query Optimization](#12-date--range-query-optimization)
13. [DISTINCT Optimization](#13-distinct-optimization)
14. [OR Condition Optimization](#14-or-condition-optimization)
15. [Correlated Subquery Elimination](#15-correlated-subquery-elimination)
16. [Partitioning](#16-partitioning)
17. [Query Plan Analysis (EXPLAIN)](#17-query-plan-analysis-explain)
18. [Bulk Insert & Upsert Optimization](#18-bulk-insert--upsert-optimization)
19. [String & Function on Indexed Columns](#19-string--function-on-indexed-columns)
20. [Denormalization for Read Performance](#20-denormalization-for-read-performance)

---

## 1. Indexing Strategies

### Problem: Missing or wrong indexes cause full scans

```sql
-- ❌ SLOW: No index on email
SELECT * FROM users WHERE email = 'user@example.com';

-- ✅ FIX: Single-column index
CREATE INDEX idx_users_email ON users(email);
```

### Composite Index — Column Order Matters

```sql
-- Query filters on status AND created_at
SELECT * FROM orders WHERE status = 'pending' AND created_at > '2024-01-01';

-- ❌ Wrong order: index on (created_at, status) won't help status-first filters
-- ✅ Correct: put the equality column first (highest cardinality last is secondary)
CREATE INDEX idx_orders_status_created ON orders(status, created_at);
```

### Covering Index — Avoid Heap Lookups

```sql
-- Query only needs id, name, email — no need to hit the base table
-- ✅ Covering index: all selected columns are in the index
CREATE INDEX idx_users_covering ON users(email) INCLUDE (id, name);

SELECT id, name FROM users WHERE email = 'user@example.com';
-- Served entirely from the index; no table lookup needed
```

### Partial Index — Index Only What You Query

```sql
-- Only active users are ever queried
-- ❌ Full index on all 10M rows
CREATE INDEX idx_users_email ON users(email);

-- ✅ Partial index on only the ~5% of rows that are active
CREATE INDEX idx_active_users_email ON users(email) WHERE status = 'active';
```

---

## 2. JOIN Optimization

### Drive the Join from the Smaller Table

```sql
-- ❌ SLOW: large table drives the join
SELECT o.id, u.name
FROM orders o          -- 10M rows
JOIN users u ON u.id = o.user_id  -- 100K rows

-- ✅ BETTER: optimizer hint or rewrite to start from smaller set
SELECT o.id, u.name
FROM users u           -- 100K rows
JOIN orders o ON o.user_id = u.id;
```

### Avoid Functions in JOIN Conditions

```sql
-- ❌ SLOW: function prevents index use
JOIN departments d ON LOWER(e.dept_code) = LOWER(d.code)

-- ✅ FIX: normalize data at write time or use a functional index
CREATE INDEX idx_dept_lower ON departments(LOWER(code));
JOIN departments d ON LOWER(e.dept_code) = LOWER(d.code)
```

### HASH JOIN vs NESTED LOOP

```sql
-- For large table × large table: prefer hash join (set by optimizer or hint)
-- PostgreSQL
SET enable_nestloop = OFF;

-- SQL Server hint
SELECT * FROM orders o
JOIN order_items oi ON oi.order_id = o.id
OPTION (HASH JOIN);
```

---

## 3. Subquery vs CTE vs Temp Table

### Subquery (inline, simple cases)

```sql
-- Fine for small, single-use derivations
SELECT name FROM users
WHERE id IN (SELECT user_id FROM orders WHERE total > 1000);
```

### CTE (readability + reuse within one query)

```sql
-- ✅ CTE: readable, reusable in the same query; optimizer can inline or materialize
WITH high_value_orders AS (
  SELECT user_id, SUM(total) AS lifetime_value
  FROM orders
  GROUP BY user_id
  HAVING SUM(total) > 10000
)
SELECT u.name, hvo.lifetime_value
FROM users u
JOIN high_value_orders hvo ON hvo.user_id = u.id;
```

### Temp Table (when CTE is re-evaluated multiple times)

```sql
-- ✅ Temp table: materializes once, re-used cheaply, can be indexed
CREATE TEMP TABLE high_value_users AS
  SELECT user_id, SUM(total) AS lifetime_value
  FROM orders
  GROUP BY user_id
  HAVING SUM(total) > 10000;

CREATE INDEX ON high_value_users(user_id);

SELECT u.name, hvu.lifetime_value
FROM users u
JOIN high_value_users hvu ON hvu.user_id = u.id;
```

**Rule of thumb:**
| Use | When |
|---|---|
| Subquery | Simple, one-off, small result |
| CTE | Complex logic, readability, referenced once |
| Temp Table | Large intermediate result, referenced multiple times |

---

## 4. Avoiding Full Table Scans

### Sargable Predicates — Let Indexes Work

```sql
-- ❌ NON-SARGABLE: wrapping the column in a function kills index use
WHERE YEAR(created_at) = 2024
WHERE UPPER(last_name) = 'SMITH'
WHERE salary + 500 > 50000

-- ✅ SARGABLE: rewrite to isolate the column
WHERE created_at >= '2024-01-01' AND created_at < '2025-01-01'
WHERE last_name = 'Smith'   -- store normalized, or use functional index
WHERE salary > 49500
```

### Implicit Type Conversion

```sql
-- ❌ Column is INT but literal is VARCHAR — implicit cast kills the index
WHERE user_id = '12345'

-- ✅ Match types explicitly
WHERE user_id = 12345
```

---

## 5. Aggregate & GROUP BY Optimization

### Filter Before Aggregating

```sql
-- ❌ Aggregate everything, then filter
SELECT user_id, SUM(total)
FROM orders
GROUP BY user_id
HAVING user_id > 1000;

-- ✅ Filter rows first with WHERE, then aggregate
SELECT user_id, SUM(total)
FROM orders
WHERE user_id > 1000
GROUP BY user_id;
```

### Pre-aggregate with Materialized Views

```sql
-- ❌ Recomputing daily totals on every dashboard hit
SELECT DATE(created_at), SUM(total) FROM orders GROUP BY 1;

-- ✅ Materialized view refreshed periodically
CREATE MATERIALIZED VIEW daily_order_totals AS
  SELECT DATE(created_at) AS order_date, SUM(total) AS daily_total
  FROM orders
  GROUP BY 1;

REFRESH MATERIALIZED VIEW daily_order_totals; -- scheduled job
```

---

## 6. Pagination Optimization

### Offset Pagination (slow for deep pages)

```sql
-- ❌ SLOW at high offsets: scans and discards 100,000 rows
SELECT id, title FROM posts ORDER BY id LIMIT 20 OFFSET 100000;
```

### Keyset / Cursor Pagination (fast, scalable)

```sql
-- ✅ Keyset: use WHERE to skip, not OFFSET
-- First page:
SELECT id, title FROM posts ORDER BY id LIMIT 20;

-- Next page (pass last seen id = 543):
SELECT id, title FROM posts WHERE id > 543 ORDER BY id LIMIT 20;
-- Uses index on id — O(log n) regardless of depth
```

### When Offset Is Unavoidable — Lazy Evaluation

```sql
-- ✅ Fetch only PKs via offset, then join for full row data
SELECT p.*
FROM posts p
JOIN (
  SELECT id FROM posts ORDER BY created_at DESC LIMIT 20 OFFSET 10000
) sub ON sub.id = p.id;
```

---

## 7. N+1 Query Problem

### The Anti-Pattern

```sql
-- Application code loops:
-- Query 1: SELECT * FROM users LIMIT 100
-- Then for each user: SELECT * FROM orders WHERE user_id = ?
-- = 101 queries total ❌
```

### Fix: Single JOIN or IN Clause

```sql
-- ✅ One query
SELECT u.id, u.name, o.id AS order_id, o.total
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
WHERE u.id IN (/* ids from first query */);
```

### Fix with Aggregation

```sql
-- ✅ Get order counts in a single round-trip
SELECT u.id, u.name, COUNT(o.id) AS order_count
FROM users u
LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.id, u.name;
```

---

## 8. Window Functions Over Subqueries

### Running Totals

```sql
-- ❌ Correlated subquery O(n²)
SELECT id, total,
  (SELECT SUM(total) FROM orders o2 WHERE o2.id <= o1.id) AS running_total
FROM orders o1;

-- ✅ Window function O(n log n)
SELECT id, total,
  SUM(total) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
FROM orders;
```

### Top-N Per Group (without GROUP BY hack)

```sql
-- ❌ Multiple subqueries or self-joins
-- ✅ ROW_NUMBER window function
WITH ranked AS (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY sales DESC) AS rn
  FROM products
)
SELECT * FROM ranked WHERE rn <= 3;
```

### Lag/Lead Instead of Self-Join

```sql
-- ❌ Self-join to get previous row
SELECT a.date, a.revenue, b.revenue AS prev_revenue
FROM daily_sales a
JOIN daily_sales b ON b.date = a.date - INTERVAL '1 day';

-- ✅ LAG — single scan
SELECT date, revenue,
  LAG(revenue) OVER (ORDER BY date) AS prev_revenue
FROM daily_sales;
```

---

## 9. EXISTS vs IN vs JOIN

### EXISTS — Best for Large Subqueries (short-circuits)

```sql
-- ✅ EXISTS stops at first match
SELECT * FROM customers c
WHERE EXISTS (
  SELECT 1 FROM orders o WHERE o.customer_id = c.id AND o.total > 500
);
```

### IN — OK for Small Static Lists

```sql
-- ✅ Fine for small lists
WHERE status IN ('active', 'trial', 'pending')

-- ❌ Avoid for large subqueries — entire subquery materializes first
WHERE id IN (SELECT id FROM orders WHERE ...)  -- use EXISTS instead
```

### NOT IN vs NOT EXISTS — NULL Trap

```sql
-- ❌ DANGEROUS: if subquery returns ANY NULL, entire result is empty
WHERE user_id NOT IN (SELECT user_id FROM banned_users)

-- ✅ SAFE: NOT EXISTS handles NULLs correctly
WHERE NOT EXISTS (
  SELECT 1 FROM banned_users b WHERE b.user_id = u.id
)
```

---

## 10. Wildcard & LIKE Optimization

```sql
-- ❌ Leading wildcard — full table scan, no index
WHERE name LIKE '%Smith%'

-- ✅ Trailing wildcard — index on name is used
WHERE name LIKE 'Smith%'

-- ✅ Full-text search for arbitrary substring matching
-- PostgreSQL
CREATE INDEX idx_name_fts ON users USING gin(to_tsvector('english', name));
SELECT * FROM users WHERE to_tsvector('english', name) @@ plainto_tsquery('Smith');

-- MySQL
CREATE FULLTEXT INDEX idx_name_ft ON users(name);
SELECT * FROM users WHERE MATCH(name) AGAINST ('Smith');
```

---

## 11. NULL Handling

### NULL Comparisons

```sql
-- ❌ Never evaluates to true for NULL values
WHERE column = NULL
WHERE column != NULL

-- ✅ Correct operators
WHERE column IS NULL
WHERE column IS NOT NULL
```

### COALESCE for Default Values

```sql
-- ❌ Wrapping indexed column in ISNULL/NVL kills index
WHERE COALESCE(discount, 0) > 0

-- ✅ Expand the predicate
WHERE discount IS NOT NULL AND discount > 0
```

### COUNT(*) vs COUNT(column)

```sql
-- COUNT(*) counts all rows including NULLs — usually what you want for row counts
-- COUNT(column) counts only non-NULL values
SELECT COUNT(*) AS total_rows,
       COUNT(email) AS rows_with_email  -- excludes NULLs
FROM users;
```

---

## 12. Date & Range Query Optimization

```sql
-- ❌ Function on column — index unusable
WHERE YEAR(created_at) = 2024
WHERE DATE(created_at) = '2024-06-01'

-- ✅ Range predicate — index usable
WHERE created_at >= '2024-01-01' AND created_at < '2025-01-01'
WHERE created_at >= '2024-06-01' AND created_at < '2024-06-02'

-- ✅ BETWEEN (inclusive on both ends — be careful with DATETIME)
WHERE created_at BETWEEN '2024-01-01 00:00:00' AND '2024-12-31 23:59:59'
```

### Index on Computed Date Column (PostgreSQL)

```sql
-- ✅ If you must query by extracted part, create a functional index
CREATE INDEX idx_orders_year ON orders(EXTRACT(YEAR FROM created_at));
WHERE EXTRACT(YEAR FROM created_at) = 2024;  -- now index is used
```

---

## 13. DISTINCT Optimization

```sql
-- ❌ DISTINCT on large result sets is expensive — sorts or hashes everything
SELECT DISTINCT user_id FROM orders;

-- ✅ EXISTS is often faster when checking membership
SELECT id FROM users u
WHERE EXISTS (SELECT 1 FROM orders o WHERE o.user_id = u.id);

-- ✅ GROUP BY can be faster than DISTINCT when optimizer differs
SELECT user_id FROM orders GROUP BY user_id;

-- ✅ Use DISTINCT only when you genuinely need deduplication across multiple columns
SELECT DISTINCT category, status FROM products;
```

---

## 14. OR Condition Optimization

```sql
-- ❌ OR across different columns prevents index use
WHERE first_name = 'John' OR email = 'john@example.com'

-- ✅ UNION ALL — each branch uses its own index
SELECT * FROM users WHERE first_name = 'John'
UNION ALL
SELECT * FROM users WHERE email = 'john@example.com' AND first_name != 'John';

-- ✅ Or use UNION (deduplicates) if rows can overlap
SELECT * FROM users WHERE first_name = 'John'
UNION
SELECT * FROM users WHERE email = 'john@example.com';
```

### OR on the Same Column — Use IN Instead

```sql
-- ❌ Redundant ORs
WHERE status = 'active' OR status = 'trial' OR status = 'pending'

-- ✅ IN is cleaner and equivalent
WHERE status IN ('active', 'trial', 'pending')
```

---

## 15. Correlated Subquery Elimination

```sql
-- ❌ Correlated subquery runs once per outer row — O(n²)
SELECT e.name,
  (SELECT d.name FROM departments d WHERE d.id = e.dept_id) AS dept_name
FROM employees e;

-- ✅ JOIN runs once — O(n log n)
SELECT e.name, d.name AS dept_name
FROM employees e
LEFT JOIN departments d ON d.id = e.dept_id;
```

### Aggregated Correlated Subquery

```sql
-- ❌ One aggregate subquery per employee row
SELECT e.name,
  (SELECT COUNT(*) FROM projects p WHERE p.employee_id = e.id) AS project_count
FROM employees e;

-- ✅ Pre-aggregate, then join
SELECT e.name, COALESCE(pc.project_count, 0) AS project_count
FROM employees e
LEFT JOIN (
  SELECT employee_id, COUNT(*) AS project_count
  FROM projects
  GROUP BY employee_id
) pc ON pc.employee_id = e.id;
```

---

## 16. Partitioning

### Range Partitioning on Date (PostgreSQL)

```sql
-- Parent table
CREATE TABLE orders (
  id BIGINT,
  created_at TIMESTAMP,
  total NUMERIC
) PARTITION BY RANGE (created_at);

-- Partitions per year
CREATE TABLE orders_2023 PARTITION OF orders
  FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE orders_2024 PARTITION OF orders
  FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

-- Query targets only the 2024 partition automatically (partition pruning)
SELECT * FROM orders WHERE created_at >= '2024-06-01';
```

### List Partitioning on Status

```sql
CREATE TABLE payments PARTITION BY LIST (status);

CREATE TABLE payments_completed PARTITION OF payments FOR VALUES IN ('completed');
CREATE TABLE payments_pending   PARTITION OF payments FOR VALUES IN ('pending');
CREATE TABLE payments_failed    PARTITION OF payments FOR VALUES IN ('failed');
```

---

## 17. Query Plan Analysis (EXPLAIN)

### PostgreSQL

```sql
-- EXPLAIN: shows estimated plan
EXPLAIN SELECT * FROM orders WHERE status = 'pending';

-- EXPLAIN ANALYZE: runs the query, shows actual vs estimated
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT * FROM orders WHERE status = 'pending';
```

### Key things to look for

| Node Type | Meaning |
|---|---|
| `Seq Scan` | Full table scan — often bad on large tables |
| `Index Scan` | Using an index — good |
| `Index Only Scan` | Covered by index — best |
| `Hash Join` | Good for large set joins |
| `Nested Loop` | Good for small sets, bad for large |
| `Sort` on large rows | May spill to disk — add index |
| High `rows=` vs actual | Stale statistics — run ANALYZE |

```sql
-- Update statistics so the planner has accurate estimates
ANALYZE orders;
-- or full vacuum + analyze
VACUUM ANALYZE orders;
```

### MySQL / MariaDB

```sql
EXPLAIN FORMAT=JSON SELECT * FROM orders WHERE status = 'pending';
EXPLAIN ANALYZE SELECT ...;  -- MySQL 8.0+
```

### SQL Server

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
-- Run query, then check Messages tab for logical reads
```

---

## 18. Bulk Insert & Upsert Optimization

### Batch Inserts

```sql
-- ❌ Single-row inserts in a loop — high overhead per round-trip
INSERT INTO logs (event, ts) VALUES ('click', NOW());
INSERT INTO logs (event, ts) VALUES ('view', NOW());
-- ...

-- ✅ Single multi-row insert
INSERT INTO logs (event, ts) VALUES
  ('click', NOW()),
  ('view',  NOW()),
  ('buy',   NOW());
```

### Upsert (INSERT … ON CONFLICT)

```sql
-- PostgreSQL
INSERT INTO user_settings (user_id, theme, notifications)
VALUES (42, 'dark', true)
ON CONFLICT (user_id) DO UPDATE
  SET theme         = EXCLUDED.theme,
      notifications = EXCLUDED.notifications,
      updated_at    = NOW();

-- MySQL
INSERT INTO user_settings (user_id, theme, notifications)
VALUES (42, 'dark', 1)
ON DUPLICATE KEY UPDATE
  theme = VALUES(theme),
  notifications = VALUES(notifications);
```

### Disable Indexes During Bulk Load (MySQL)

```sql
-- For large initial loads
ALTER TABLE big_table DISABLE KEYS;
LOAD DATA INFILE '/tmp/data.csv' INTO TABLE big_table ...;
ALTER TABLE big_table ENABLE KEYS;  -- rebuilds indexes in bulk — much faster
```

---

## 19. String & Function on Indexed Columns

Any transformation on an indexed column in a WHERE clause makes the index unusable unless a matching functional index exists.

```sql
-- ❌ All of these disable the index on `email`
WHERE LOWER(email) = 'user@example.com'
WHERE TRIM(email) = 'user@example.com'
WHERE SUBSTRING(email, 1, 5) = 'user@'

-- ✅ Option A: Normalize data at write time (store emails as lowercase)
-- ✅ Option B: Functional index (PostgreSQL)
CREATE INDEX idx_users_lower_email ON users(LOWER(email));
WHERE LOWER(email) = 'user@example.com';  -- index now used

-- ✅ Option C: Generated/computed column (MySQL 5.7+, SQL Server)
ALTER TABLE users ADD COLUMN email_lower VARCHAR(255)
  GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX idx_users_email_lower ON users(email_lower);
```

---

## 20. Denormalization for Read Performance

When normalized queries are too slow and can't be fixed with indexes alone, strategic denormalization improves read throughput at the cost of write complexity.

### Store Aggregates

```sql
-- ❌ Recompute order count on every profile page load
SELECT COUNT(*) FROM orders WHERE user_id = 42;

-- ✅ Maintain a counter column
ALTER TABLE users ADD COLUMN order_count INT DEFAULT 0;

-- Increment on insert
UPDATE users SET order_count = order_count + 1 WHERE id = NEW.user_id;
-- Decrement on delete
UPDATE users SET order_count = order_count - 1 WHERE id = OLD.user_id;
```

### Summary / Rollup Tables

```sql
-- Nightly job populates a summary table
INSERT INTO monthly_revenue (month, product_id, total_revenue)
SELECT DATE_FORMAT(created_at, '%Y-%m-01'), product_id, SUM(total)
FROM orders
WHERE created_at >= LAST_RUN AND created_at < NOW()
GROUP BY 1, 2
ON DUPLICATE KEY UPDATE total_revenue = total_revenue + VALUES(total_revenue);

-- Dashboard reads from fast summary, not raw orders
SELECT * FROM monthly_revenue WHERE month = '2024-06-01';
```

### Materialized Views (PostgreSQL)

```sql
CREATE MATERIALIZED VIEW product_stats AS
  SELECT
    p.id,
    p.name,
    COUNT(DISTINCT oi.order_id) AS order_count,
    SUM(oi.quantity)            AS units_sold,
    AVG(r.rating)               AS avg_rating
  FROM products p
  LEFT JOIN order_items oi ON oi.product_id = p.id
  LEFT JOIN reviews r       ON r.product_id = p.id
  GROUP BY p.id, p.name;

-- Refresh on schedule or after bulk writes
REFRESH MATERIALIZED VIEW CONCURRENTLY product_stats;
```

---

## Quick Reference Cheat Sheet

| Scenario | Fix |
|---|---|
| Full table scan | Add index; make predicate sargable |
| Slow deep pagination | Keyset pagination (`WHERE id > last_id`) |
| Correlated subquery | Rewrite as JOIN or pre-aggregated subquery |
| N+1 queries | Batch with JOIN or `IN (ids)` |
| Slow `LIKE '%text%'` | Full-text index |
| `NOT IN` with NULLs | Use `NOT EXISTS` |
| Repeated CTE re-evaluation | Temp table with index |
| Slow aggregates on huge table | Materialized view or summary table |
| OR on multiple columns | UNION ALL with one index per branch |
| Function on indexed column | Functional index or normalize at write |
| Date function in WHERE | Range predicate (`>= / <`) |
| Large JOIN on huge tables | Partitioning + partition pruning |
| Stale query plans | `ANALYZE` / `UPDATE STATISTICS` |
