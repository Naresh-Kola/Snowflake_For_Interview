# Stop Cleaning Up Bad Data: CHECK Constraints, Error Tables & AI-Powered Automation in Snowflake

---

## The Story

Bad data is expensive. Not because it's hard to find, but because **you find it too late**.

An order lands with `status = 'actve'` instead of `'active'`. A JSON event arrives with `amount: "banana"`. A NULL slips into a non-nullable dimension key. By the time your validation catches it, the bad rows are already in your tables, your dashboards are wrong, and someone's asking why revenue dropped 40% overnight.

**What if the database itself rejected bad data before it ever touched your tables?**

This guide walks you through the complete journey — from the old painful way, to Snowflake's native solution, all the way to automating error handling at production scale.

---

## Table of Contents

1. [The Old Way: Post-Load Validation (The Problem)](#1-the-old-way-post-load-validation-the-problem)
2. [The New Way: CHECK Constraints (Enforce at Write Time)](#2-the-new-way-check-constraints-enforce-at-write-time)
3. [Without Error Logging: Hard Rejection](#3-without-error-logging-hard-rejection)
4. [With Error Logging: Capture Bad Rows Without Stopping](#4-with-error-logging-capture-bad-rows-without-stopping)
5. [Manual Error Review & Correction](#5-manual-error-review--correction)
6. [Production Scale: The `error-tables-ops` Skill](#6-production-scale-the-error-tables-ops-skill)
7. [Email Alerts: Get Notified When Bad Data Arrives](#7-email-alerts-get-notified-when-bad-data-arrives)
8. [Auto-Generate Corrected INSERT Statements](#8-auto-generate-corrected-insert-statements)
9. [Quick Reference: What You Can Enforce](#9-quick-reference-what-you-can-enforce)
10. [Key Takeaways](#10-key-takeaways)

---

## 1. The Old Way: Post-Load Validation (The Problem)

Without enforced constraints, data teams rely on **post-load validation** — using tools like dbt tests, Monte Carlo, or custom SQL checks that run **after** data has landed. The pattern is always the same:

```
Pipeline loads data into orders  ──>  including bad rows
                                           │
Validation step runs AFTER the load  ──>  finds 47 rows with status = 'actve'
                                           │
Alert fires  ──>  engineer investigates
                        │
Manual fix   ──>  UPDATE orders SET status = 'active' WHERE status = 'actve'
                        │
Trace source ──>  fix upstream pipeline, redeploy
```

**Total time: hours to days. Bad data was queryable the entire time.**

Whether it's a dbt `accepted_values` test, a Great Expectations suite, or a hand-rolled SQL check, the fundamental problem is the same: **post-load validation catches problems after the fact**.

---

## 2. The New Way: CHECK Constraints (Enforce at Write Time)

> **Best Practice:** Define your data quality rules directly on the table. Let the database enforce them on every INSERT, UPDATE, and MERGE.

CHECK constraints move validation to **the moment data is written**. Define the rules once on the table; Snowflake enforces them automatically.

```sql
-- ============================================================
-- BEST PRACTICE: Define ALL your data quality rules as CHECK
-- constraints directly on the table definition.
-- One place. Always enforced. Zero maintenance.
-- ============================================================

CREATE OR REPLACE TABLE orders (
    order_id    INT          NOT NULL,
    customer_id INT          NOT NULL,
    status      VARCHAR(20)  CHECK (status IN ('active', 'pending', 'shipped',
                                               'delivered', 'returned')),
    amount      NUMBER(10,2) CHECK (amount > 0),
    order_date  DATE,
    ship_date   DATE,
    event_data  VARIANT,

    -- Cross-column logic
    CONSTRAINT chk_ship_after_order CHECK (ship_date >= order_date),

    -- Required JSON fields
    CONSTRAINT chk_evt_type    CHECK (event_data:type::STRING IS NOT NULL),
    CONSTRAINT chk_evt_source  CHECK (event_data:source::STRING IS NOT NULL),

    -- VARIANT type enforcement
    CONSTRAINT chk_evt_meta_obj CHECK (event_data:metadata IS NULL
                                       OR IS_OBJECT(event_data:metadata)),
    CONSTRAINT chk_evt_tags_arr CHECK (event_data:tags IS NULL
                                       OR IS_ARRAY(event_data:tags)),

    -- Malformed value rejection
    CONSTRAINT chk_evt_amount  CHECK (event_data:amount IS NULL
                                      OR TRY_CAST(event_data:amount::STRING
                                                   AS NUMBER) IS NOT NULL)
);
```

> **What makes this powerful:** You're enforcing rules on regular columns, cross-column logic, JSON fields inside VARIANT, type checks on nested data, AND malformed value rejection — all in a single table definition.

---

## 3. Without Error Logging: Hard Rejection

When error logging is **not** enabled, any row that violates a CHECK constraint **kills the entire statement**. Good rows AND bad rows are all rejected.

### Try inserting valid data — it works:

```sql
-- This succeeds: all constraints satisfied
INSERT INTO orders SELECT
    1, 100, 'pending', 49.99, '2026-01-15'::DATE, NULL,
    PARSE_JSON('{"type":"web","source":"checkout",
                 "metadata":{"browser":"chrome"},"amount":49.99}');
```

**Result:** 1 row inserted.

### Now try inserting bad data — it throws an error:

```sql
-- This FAILS: status = 'actve' is not in the allowed list
INSERT INTO orders SELECT
    2, 101, 'actve', 29.99, '2026-01-16'::DATE, NULL,
    PARSE_JSON('{"type":"web","source":"cart"}');
```

**Result:**
```
Error: CHECK constraint "SYS_CONSTRAINT_...", which requires that
       status IN ('active','pending','shipped','delivered','returned'),
       was violated
```

The typo **never makes it into the table**. The database said no.

### The problem with hard rejection

This is great for one-off inserts. But what about a pipeline loading **5 million rows** where only **3 rows** are bad? Hard rejection means:

- **All 5 million rows are rejected** — including the 4,999,997 good ones
- The pipeline fails completely
- You have to find the 3 bad rows, fix them, and re-run everything

**This doesn't work for production pipelines.**

---

## 4. With Error Logging: Capture Bad Rows Without Stopping

> **Best Practice:** Always enable `ERROR_LOGGING = TRUE` on tables in production pipelines. Good rows land; bad rows are captured for review.

One property on the table changes everything:

```sql
-- ============================================================
-- BEST PRACTICE: Enable error logging so pipelines never stop.
-- Bad rows go to an error table instead of killing the load.
-- This is a metadata-only operation — instant, no table scan.
-- ============================================================

ALTER TABLE orders SET ERROR_LOGGING = TRUE;
```

Now let's insert 5 rows — 3 valid, 2 with constraint violations:

```sql
INSERT INTO orders SELECT
    10, 200, 'shipped', 99.99, '2026-02-01', '2026-02-03',
    PARSE_JSON('{"type":"api","source":"mobile","amount":99.99}')
UNION ALL SELECT
    11, 201, 'INVALID', 50.00, '2026-02-01', NULL,
    PARSE_JSON('{"type":"web","source":"checkout"}')
UNION ALL SELECT
    12, 202, 'pending', -5.00, '2026-02-02', NULL,
    PARSE_JSON('{"type":"api","source":"pos"}')
UNION ALL SELECT
    13, 203, 'delivered', 149.99, '2026-02-03', '2026-02-05',
    PARSE_JSON('{"type":"web","source":"checkout",
                 "metadata":{"device":"iphone"}}')
UNION ALL SELECT
    14, 204, 'returned', 25.00, '2026-02-04', '2026-02-06',
    PARSE_JSON('{"type":"api","source":"returns"}');

-- Result: 3 rows inserted successfully (order_ids 10, 13, 14)
--         2 rows captured in error table (order_ids 11, 12)
--         NO ERROR THROWN. Pipeline continues.
```

**The pipeline didn't break.** Three good rows landed in the table. Two bad rows were silently routed to an error table.

---

## 5. Manual Error Review & Correction

### Step 1: See what was rejected

```sql
-- ============================================================
-- BEST PRACTICE: Use ERROR_TABLE() function to query rejected
-- rows. This is NOT a physical table name — it's a function
-- that takes the source table as an argument.
-- ============================================================

SELECT * FROM ERROR_TABLE(orders);
```

**Error table columns:**

| Column | Type | What it tells you |
|--------|------|-------------------|
| `TIMESTAMP` | TIMESTAMP_LTZ | When the error occurred |
| `QUERY_ID` | VARCHAR | Which query caused it |
| `ERROR_CODE` | NUMBER | Snowflake error code (100320 = CHECK violation) |
| `ERROR_METADATA` | OBJECT | Contains error_message, error_code, sql_state |
| `ERROR_DATA` | OBJECT | The full rejected row with all column values |

### Step 2: Parse the error details

```sql
SELECT
    TIMESTAMP,
    ERROR_CODE,
    ERROR_METADATA:error_message::STRING AS ERROR_MESSAGE,
    ERROR_DATA:ORDER_ID::INT             AS ORDER_ID,
    ERROR_DATA:STATUS::STRING            AS STATUS,
    ERROR_DATA:AMOUNT::NUMBER(10,2)      AS AMOUNT
FROM ERROR_TABLE(orders)
ORDER BY TIMESTAMP DESC;
```

**Result:**

| TIMESTAMP | ERROR_CODE | ERROR_MESSAGE | ORDER_ID | STATUS | AMOUNT |
|-----------|-----------|---------------|----------|--------|--------|
| 2026-05-14 03:42:36 | 100320 | ...status IN ('active','pending',...) was violated | 11 | INVALID | 50.00 |
| 2026-05-14 03:42:36 | 100320 | ...amount > 0, was violated | 12 | pending | -5.00 |

### Step 3: Fix and re-insert the corrected rows

```sql
-- Order 11: Fixed STATUS from 'INVALID' to 'pending'
INSERT INTO orders SELECT
    11, 201, 'pending', 50.00, '2026-02-01'::DATE, NULL,
    PARSE_JSON('{"source":"checkout","type":"web"}');

-- Order 12: Fixed AMOUNT from -5.00 to 5.00 (absolute value)
INSERT INTO orders SELECT
    12, 202, 'pending', 5.00, '2026-02-02'::DATE, NULL,
    PARSE_JSON('{"source":"pos","type":"api"}');
```

### Step 4: Verify everything landed

```sql
SELECT * FROM orders ORDER BY order_id;
```

**This works great when you have 2 error rows.** But what about production?

---

## 6. Production Scale: The `error-tables-ops` Skill

> **The Real Question:** What happens when you have **thousands** of rejected rows across **dozens** of constraint types, arriving every hour, and you can't manually review each one?

This is where **Cortex Code Skills** come in. We built a custom skill called `error-tables-ops` that automates the entire error handling workflow.

### What is a Cortex Code Skill?

A skill is a set of instructions that lives in your workspace at `.snowflake/cortex/skills/<skill-name>/SKILL.md`. When you ask Cortex Code a question that matches the skill's triggers, it automatically loads the skill and follows its instructions.

### What the `error-tables-ops` skill does:

| Capability | What it does |
|-----------|-------------|
| **View all errors** | Parses ERROR_DATA to show rejected rows with all column values |
| **Classify violations** | Uses CASE expressions to categorize each error (Invalid status, Non-positive amount, etc.) |
| **Summarize by constraint** | Groups errors by constraint type with counts |
| **Send email alerts** | Builds an error summary and sends it via SYSTEM$SEND_EMAIL |
| **Generate corrected INSERTs** | Creates ready-to-run INSERT statements with fixed values |
| **Truncate error table** | Cleans up after errors are resolved |

### How to use it:

Just ask Cortex Code in natural language:

```
"Analyze my error table for orders"
"Show me rejected rows for the orders table"
"What constraint violations happened on orders?"
```

Cortex Code automatically detects the skill, loads it, and runs the full analysis.

### The skill code

The skill lives at `.snowflake/cortex/skills/error-tables-ops/SKILL.md` and contains these key queries:

**View all errors with parsed row data:**

```sql
SELECT
    TIMESTAMP,
    QUERY_ID,
    ERROR_CODE,
    ERROR_METADATA:error_message::STRING    AS ERROR_MESSAGE,
    ERROR_DATA:ORDER_ID::INT                AS ORDER_ID,
    ERROR_DATA:CUSTOMER_ID::INT             AS CUSTOMER_ID,
    ERROR_DATA:STATUS::STRING               AS STATUS,
    ERROR_DATA:AMOUNT::NUMBER(10,2)         AS AMOUNT,
    ERROR_DATA:ORDER_DATE::DATE             AS ORDER_DATE,
    ERROR_DATA:SHIP_DATE::DATE              AS SHIP_DATE,
    ERROR_DATA:EVENT_DATA                   AS EVENT_DATA
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
ORDER BY TIMESTAMP DESC;
```

**Classify each violation type automatically:**

```sql
-- ============================================================
-- BEST PRACTICE: Use CASE expressions to classify error types.
-- This turns raw error messages into human-readable categories
-- that can be grouped, counted, and alerted on.
-- ============================================================

SELECT
    TIMESTAMP,
    ERROR_CODE,
    ERROR_DATA:ORDER_ID::INT AS ORDER_ID,
    CASE
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%status IN%'
            THEN 'Invalid status'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%amount > 0%'
            THEN 'Non-positive amount'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%ship_date >= order_date%'
            THEN 'Ship date before order date'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:type%'
            THEN 'Missing event type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:source%'
            THEN 'Missing event source'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_OBJECT(event_data:metadata)%'
            THEN 'Invalid metadata type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_ARRAY(event_data:tags)%'
            THEN 'Invalid tags type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:amount%'
            THEN 'Non-numeric event amount'
        ELSE 'Other'
    END AS VIOLATION_TYPE,
    ERROR_DATA
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
ORDER BY TIMESTAMP DESC;
```

**Summarize error counts by constraint:**

```sql
SELECT
    ERROR_CODE,
    ERROR_METADATA:error_message::STRING AS ERROR_MESSAGE,
    COUNT(*) AS ERROR_COUNT
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
GROUP BY 1, 2
ORDER BY ERROR_COUNT DESC;
```

---

## 7. Email Alerts: Get Notified When Bad Data Arrives

> **Best Practice:** Don't wait for someone to check. Set up email alerts so your team knows the moment bad data hits the error table.

### One-time setup: Create a notification integration

```sql
-- ============================================================
-- BEST PRACTICE: Create a dedicated notification integration
-- for error alerts. ALLOWED_RECIPIENTS restricts who can
-- receive emails through this integration.
-- ============================================================

CREATE NOTIFICATION INTEGRATION IF NOT EXISTS orders_error_email_int
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('190040236ece@gmail.com');
```

> **Important:** The recipient email must be a verified Snowflake user email. Verify with:

```sql
CALL SYSTEM$START_USER_EMAIL_VERIFICATION('190040236ece@gmail.com');
```

### Send the alert with error summary

```sql
-- ============================================================
-- BEST PRACTICE: Include error counts per constraint AND the
-- reason in your alerts. This gives on-call engineers enough
-- context to triage without logging into Snowflake.
-- ============================================================

CALL SYSTEM$SEND_EMAIL(
    'orders_error_email_int',
    '190040236ece@gmail.com',
    'Orders Error Table Alert - ' || CURRENT_DATE()::STRING,
    (SELECT LISTAGG(
        'Constraint: ' || VIOLATION_TYPE ||
        ' | Error Code: ' || ERROR_CODE::STRING ||
        ' | Count: ' || ERROR_COUNT::STRING ||
        ' | Reason: ' || REASON,
        '\n'
    )
    FROM (
        SELECT
            CASE
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%status IN%'
                    THEN 'Invalid status'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%amount > 0%'
                    THEN 'Non-positive amount'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%ship_date >= order_date%'
                    THEN 'Ship date before order date'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:type%'
                    THEN 'Missing event type'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:source%'
                    THEN 'Missing event source'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_OBJECT(event_data:metadata)%'
                    THEN 'Invalid metadata type'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_ARRAY(event_data:tags)%'
                    THEN 'Invalid tags type'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:amount%'
                    THEN 'Non-numeric event amount'
                ELSE 'Other'
            END AS VIOLATION_TYPE,
            ERROR_CODE,
            COUNT(*) AS ERROR_COUNT,
            ANY_VALUE(ERROR_METADATA:error_message::STRING) AS REASON
        FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
        GROUP BY 1, 2
        ORDER BY ERROR_COUNT DESC
    ))
);
```

**Sample email you'll receive:**

```
Subject: Orders Error Table Alert - 2026-05-14

Constraint: Invalid status | Error Code: 100320 | Count: 1 | Reason: ...status IN ('active','pending',...) was violated
Constraint: Non-positive amount | Error Code: 100320 | Count: 1 | Reason: ...amount > 0, was violated
```

---

## 8. Auto-Generate Corrected INSERT Statements

The skill also generates corrected INSERT statements using these fix rules:

| Violation Type | Auto-Fix Rule |
|---------------|---------------|
| Invalid status | Replace with `'pending'` (safe default) |
| Non-positive amount | Use `ABS(amount)`, or `1.00` if zero |
| Ship date before order date | Set `ship_date = order_date` |
| Missing event type | Set `event_data:type = 'unknown'` |
| Missing event source | Set `event_data:source = 'unknown'` |
| Invalid metadata type | Set `event_data:metadata = {}` |
| Invalid tags type | Set `event_data:tags = []` |
| Non-numeric event amount | Remove `event_data:amount` |

**Example output from the skill:**

```sql
-- Order 11: Fixed STATUS from 'INVALID' -> 'pending'
INSERT INTO SQL.PROBLEMS.ORDERS SELECT
    11, 201, 'pending', 50.00, '2026-02-01'::DATE, NULL,
    PARSE_JSON('{"source":"checkout","type":"web"}');

-- Order 12: Fixed AMOUNT from -5.00 -> 5.00
INSERT INTO SQL.PROBLEMS.ORDERS SELECT
    12, 202, 'pending', 5.00, '2026-02-02'::DATE, NULL,
    PARSE_JSON('{"source":"pos","type":"api"}');
```

> **Best Practice:** Always review corrected INSERTs before executing. Auto-fix rules give you a starting point, but business logic may require different corrections.

---

## 9. Quick Reference: What You Can Enforce

CHECK constraints support **any deterministic scalar expression**:

| Use Case | Example |
|----------|---------|
| Allowed values | `status IN ('pending', 'shipped', 'delivered', 'returned')` |
| Range enforcement | `amount > 0` |
| Cross-column logic | `ship_date >= order_date` |
| Required JSON fields | `event_data:type::STRING IS NOT NULL` |
| Nested VARIANT paths | `event_data:address:city::STRING IS NOT NULL` |
| VARIANT type enforcement | `IS_OBJECT(event_data:metadata)`, `IS_ARRAY(event_data:tags)` |
| Malformed value rejection | `TRY_CAST(event_data:amount::STRING AS NUMBER) IS NOT NULL` |
| Array bounds | `ARRAY_SIZE(tags) > 0 AND ARRAY_SIZE(tags) <= 10` |
| Pattern matching | `email LIKE '%@%.%'` |

> **Note:** CHECK constraints are enforced on INSERT, UPDATE, MERGE, and CTAS. COPY INTO and Snowpipe support is on the roadmap.

---

## 10. Key Takeaways

### The Complete Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                     DATA QUALITY LIFECYCLE                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. DEFINE     ──>  CHECK constraints on the table                  │
│                     (data rules live WITH the data)                 │
│                                                                     │
│  2. PROTECT    ──>  ERROR_LOGGING = TRUE                            │
│                     (pipelines never stop; bad rows captured)       │
│                                                                     │
│  3. DETECT     ──>  ERROR_TABLE() function                          │
│                     (see exactly what was rejected and why)         │
│                                                                     │
│  4. ALERT      ──>  SYSTEM$SEND_EMAIL                               │
│                     (team gets notified immediately)                │
│                                                                     │
│  5. FIX        ──>  Corrected INSERT statements                     │
│                     (auto-generated, human-reviewed)                │
│                                                                     │
│  6. AUTOMATE   ──>  Cortex Code Skill (error-tables-ops)            │
│                     (all of the above in one natural language ask)  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Best Practices Summary

| Practice | Why It Matters |
|----------|---------------|
| **Define CHECK constraints on the table** | Rules live with the data. No separate validation layer to maintain. |
| **Use named constraints** (`CONSTRAINT chk_...`) | Makes error messages readable. Easier to debug and maintain. |
| **Always enable `ERROR_LOGGING = TRUE` in production** | Pipelines never stop. Good rows land. Bad rows are captured. |
| **Use `ENABLE NOVALIDATE` for existing tables** | Enforces on future writes without scanning existing data. Instant. |
| **Classify errors with CASE expressions** | Turns raw error messages into actionable categories. |
| **Set up email alerts** | Don't wait for someone to check. Get notified immediately. |
| **Review auto-generated fixes before executing** | Automation gives you a starting point, not the final answer. |
| **Use Cortex Code Skills for repeatable workflows** | One natural language ask replaces dozens of manual SQL queries. |

---

*Built with Snowflake CHECK Constraints, Error Tables, and Cortex Code Skills.*

https://www.snowflake.com/en/engineering-blog/snowflake-check-constraints-error-tables/?utm_campaign=&utm_content=1778608047&utm_medium=Snowflake+Developers&utm_source=linkedin
