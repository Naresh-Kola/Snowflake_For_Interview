# Custom Incremental Dynamic Tables (REFRESH USING) — Complete Guide

> **Preview Feature** — Available to all accounts.
> When standard refresh modes (INCREMENTAL, FULL) can't express your transformation, custom incrementalization lets you write MERGE or INSERT logic that Snowflake executes on each refresh.

---

## Table of Contents

1. [Syntax](#syntax)
2. [Key Requirements](#key-requirements)
3. [When to Use Custom Incrementalization](#when-to-use-custom-incrementalization)
4. [SELECT-Based vs Custom Incremental](#comparison-select-based-vs-custom-incremental)
5. [The SELF Keyword](#the-self-keyword)
6. [The CHANGES Clause](#the-changes-clause)
7. [BACKFILL FROM and START AT](#backfill-from-and-start-at)
8. [INITIALIZE = ON_SCHEDULE](#initialize--on_schedule)
9. [Examples](#examples)
10. [Important Usage Notes](#important-usage-notes)
11. [Limitations](#limitations)
12. [When to Use Each Refresh Mode](#comparison-when-to-use-each-refresh-mode)
13. [Migrating from Streams and Tasks](#migrating-from-streams-and-tasks)
14. [Detailed Scenarios: Why SELECT Won't Work](#detailed-explanation-why-select-based-dynamic-tables-wont-work)

---

## Syntax

```sql
CREATE [ OR REPLACE ] DYNAMIC TABLE <name> (
  <col_name> <col_type> [ , ... ]
)
  TARGET_LAG = { '<time_spec>' | DOWNSTREAM }
  WAREHOUSE = <warehouse_name>
  [ REFRESH_MODE = { AUTO | CUSTOM_INCREMENTAL } ]
  [ INITIALIZE = ON_SCHEDULE ]
  [ BACKFILL FROM <table_name> ]
  [ START AT ({
      STREAM => '<stream_name>'
    | TIMESTAMP => <timestamp>
    | STATEMENT => <query_id>
    | OFFSET => -<seconds>
  }) ]
  REFRESH USING ( <dml_statement> )
```

---

## Key Requirements

1. **EXPLICIT COLUMN LIST IS REQUIRED**
   - Snowflake can't infer schema from DML (unlike SELECT-based dynamic tables)

2. **REFRESH_MODE = AUTO** resolves to CUSTOM_INCREMENTAL when REFRESH USING is present

3. **ONLY ONE DML STATEMENT** per REFRESH USING block
   - No multi-statement transactions allowed

4. **DML must be either:**
   - `MERGE INTO SELF ...`
   - `INSERT INTO SELF ...`

---

## When to Use Custom Incrementalization

Use custom incrementalization when SELECT-based dynamic tables can't express the transformation you need:

| Scenario | Why SELECT Won't Work |
|----------|----------------------|
| Stream-static joins with conditional logic | Not expressible as SELECT |
| Soft-deletes / conditional updates per row | Need explicit control |
| Audit trails / accumulators / point-in-time snapshots | User-defined output semantics |
| Running totals / top-K leaderboards | State reuse across refreshes |
| Migrating from streams and tasks | Direct port of MERGE/INSERT |

---

## Comparison: SELECT-Based vs Custom Incremental

| Aspect | SELECT-based Dynamic Tables | Custom Incremental |
|--------|---------------------------|-------------------|
| Logic type | Declarative SELECT | Imperative MERGE or INSERT |
| Incremental strategy | Auto-inferred by Snowflake | User-defined |
| Semantics | Delayed-view equivalence | User-defined (no system guarantee) |
| Best for | Transformations as SELECT | CDC, stream-static joins, audits |
| Migration | Requires rewrite to SELECT | Accepts MERGE or INSERT directly |

---

## The SELF Keyword

SELF has two roles inside REFRESH USING:

1. **WRITE TARGET:** `MERGE INTO SELF` or `INSERT INTO SELF`
2. **READ SOURCE:** `FROM SELF AS cur` (reads current contents of the dynamic table)

**IMPORTANT:**
- You CANNOT reference the dynamic table by its object name inside REFRESH USING
- Use SELF exclusively
- `CHANGES()` on SELF is NOT allowed

---

## The CHANGES Clause

`CHANGES()` replaces stream semantics. Snowflake automatically binds the change interval to refresh boundaries (no time bounds needed).

### Constraints
- Cannot use CHANGES on SELF
- Base tables must have change tracking enabled
- Cannot specify time bounds (AT, BEFORE, END) — managed automatically

### INFORMATION Modes

| Mode | What's Visible |
|------|---------------|
| `DEFAULT` | Inserts, updates, and deletes |
| `APPEND_ONLY` | Only inserts |

### Metadata Columns

| Column | Description |
|--------|-------------|
| `METADATA$ACTION` | `'INSERT'` or `'DELETE'` (updates = DELETE + INSERT pair) |
| `METADATA$ISUPDATE` | `TRUE` if row is part of an UPDATE operation |

---

## BACKFILL FROM and START AT

These control initial population and where subsequent refreshes begin.

| Configuration | Initial Population | Subsequent Refresh Start |
|--------------|-------------------|------------------------|
| Neither (default) | Processes all existing rows as INSERTs | From creation time |
| BACKFILL FROM `<table>` | Cloned from backfill table (bypasses DML) | From creation time |
| BACKFILL FROM + START AT | Cloned from backfill table (bypasses DML) | From the START AT point |

### START AT Options

| Option | Description |
|--------|-------------|
| `TIMESTAMP => <timestamp>` | A specific point in time |
| `STATEMENT => <query_id>` | After a specific query completed |
| `STREAM => '<stream_name>'` | Current offset of an existing stream |
| `OFFSET => -<seconds>` | Negative offset from current time |

> **NOTE:** BACKFILL FROM and START AT can ONLY be set at creation time. Cannot be changed via ALTER or CREATE OR ALTER.

---

## INITIALIZE = ON_SCHEDULE

By default, a dynamic table is initialized immediately upon creation. `INITIALIZE = ON_SCHEDULE` defers the first refresh to the normal schedule, meaning the table starts empty and gets populated on the first scheduled refresh.

**Useful for:**
- Audit/log tables where you only want future changes captured
- Avoiding expensive initial backfill of historical data through DML logic

---

## Examples

### Example 1: MERGE INTO SELF — Incremental Aggregation (Running Totals)

```sql
-- Source table
CREATE OR REPLACE TABLE match_results (
    player_id INT,
    score INT,
    match_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

ALTER TABLE match_results SET CHANGE_TRACKING = TRUE;

-- Custom incremental dynamic table
CREATE OR REPLACE DYNAMIC TABLE dt_player_scores (
    player_id INT,
    total_score INT
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        MERGE INTO SELF AS tgt
        USING (
            SELECT player_id, SUM(score) AS batch_score
            FROM match_results CHANGES(INFORMATION => APPEND_ONLY)
            GROUP BY player_id
        ) AS src
        ON tgt.player_id = src.player_id
        WHEN MATCHED THEN
            UPDATE SET tgt.total_score = tgt.total_score + src.batch_score
        WHEN NOT MATCHED THEN
            INSERT (player_id, total_score) VALUES (src.player_id, src.batch_score)
    );
```

#### Test DML

```sql
-- Batch 1: Insert initial scores
INSERT INTO match_results (player_id, score) VALUES
    (1, 100),
    (2, 150),
    (3, 200);

-- Wait ~1 minute for refresh, then check
SELECT * FROM dt_player_scores;
-- Expected: player_id 1=100, 2=150, 3=200

-- Batch 2: Same players score again (tests UPDATE path)
INSERT INTO match_results (player_id, score) VALUES
    (1, 50),
    (2, 75),
    (1, 25);

-- Wait ~1 minute for refresh, then check
SELECT * FROM dt_player_scores;
-- Expected: player_id 1=175 (100+50+25), 2=225 (150+75), 3=200

-- Batch 3: Mix of new and existing players
INSERT INTO match_results (player_id, score) VALUES
    (4, 300),
    (5, 180),
    (3, 100);

-- Wait ~1 minute for refresh, then check
SELECT * FROM dt_player_scores;
-- Expected: 1=175, 2=225, 3=300 (200+100), 4=300, 5=180

-- Batch 4: Single high score
INSERT INTO match_results (player_id, score) VALUES
    (1, 500);

-- Wait ~1 minute for refresh, then check
SELECT * FROM dt_player_scores ORDER BY total_score DESC;
-- Expected: 1=675, 4=300, 3=300, 2=225, 5=180

-- Verify source vs dynamic table totals match
SELECT player_id, SUM(score) AS expected_total
FROM match_results
GROUP BY player_id
ORDER BY expected_total DESC;
```

**How it works:**
- Each refresh only processes NEW rows added since last refresh
- Existing players get their score incremented (UPDATE)
- New players get inserted with their first batch score
- Avoids re-scanning entire match_results history every refresh

---

### Example 2: INSERT INTO SELF — Append-Only Enrichment (Stream-Static Join)

```sql
-- Source tables
CREATE OR REPLACE TABLE clicks (
    click_id INT,
    user_id INT,
    page_id INT,
    click_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE pages (
    page_id INT,
    page_title STRING,
    section STRING
);

ALTER TABLE clicks SET CHANGE_TRACKING = TRUE;

-- Custom incremental dynamic table
CREATE OR REPLACE DYNAMIC TABLE dt_enriched_clicks (
    click_id INT,
    user_id INT,
    page_title STRING,
    section STRING,
    click_ts TIMESTAMP
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        INSERT INTO SELF
        SELECT c.click_id, c.user_id, p.page_title, p.section, c.click_ts
        FROM clicks CHANGES(INFORMATION => APPEND_ONLY) AS c
        LEFT OUTER JOIN pages AS p ON c.page_id = p.page_id
    );
```

**How it works:**
- Only new clicks since last refresh are processed
- LEFT JOIN enriches each click with page metadata
- `pages` table is read at its current state (not incrementally)
- No re-scanning of historical clicks

---

### Example 3: INSERT INTO SELF — Audit Deletes Log

```sql
CREATE OR REPLACE TABLE users (
    id INT,
    name STRING,
    email STRING
);

ALTER TABLE users SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE dt_deletions_log (
    id INT,
    name STRING,
    email STRING
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    INITIALIZE = ON_SCHEDULE
    REFRESH USING (
        INSERT INTO SELF
        SELECT * EXCLUDE (METADATA$ISUPDATE, METADATA$ACTION)
        FROM users CHANGES(INFORMATION => DEFAULT)
        WHERE NOT METADATA$ISUPDATE AND METADATA$ACTION = 'DELETE'
    );
```

**How it works:**
- Uses DEFAULT information mode to see all change types
- Filters to only standalone DELETEs (excludes DELETE half of UPDATEs)
- EXCLUDE strips metadata columns before insertion
- `INITIALIZE = ON_SCHEDULE` means table starts empty, captures only future deletes

---

### Example 4: MERGE INTO SELF — Full CDC (Upserts + Deletes)

```sql
CREATE OR REPLACE TABLE raw_customers (
    customer_id INT,
    name STRING,
    email STRING,
    status STRING,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

ALTER TABLE raw_customers SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE dt_customers_current (
    customer_id INT,
    name STRING,
    email STRING,
    status STRING,
    last_updated TIMESTAMP
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        MERGE INTO SELF AS tgt
        USING (
            SELECT customer_id, name, email, status, updated_at,
                   METADATA$ACTION, METADATA$ISUPDATE
            FROM raw_customers CHANGES(INFORMATION => DEFAULT)
        ) AS src
        ON tgt.customer_id = src.customer_id
        WHEN MATCHED AND src.METADATA$ACTION = 'DELETE' AND NOT src.METADATA$ISUPDATE THEN
            DELETE
        WHEN MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            UPDATE SET tgt.name = src.name,
                       tgt.email = src.email,
                       tgt.status = src.status,
                       tgt.last_updated = src.updated_at
        WHEN NOT MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            INSERT (customer_id, name, email, status, last_updated)
            VALUES (src.customer_id, src.name, src.email, src.status, src.updated_at)
    );
```

#### Test DML

```sql
-- Batch 1: Insert new customers
INSERT INTO raw_customers (customer_id, name, email, status) VALUES
    (1, 'Alice', 'alice@example.com', 'active'),
    (2, 'Bob', 'bob@example.com', 'active'),
    (3, 'Charlie', 'charlie@example.com', 'pending'),
    (4, 'Diana', 'diana@example.com', 'active');

-- Wait ~5 minutes for refresh, then check
SELECT * FROM dt_customers_current ORDER BY customer_id;
-- Expected: 4 rows with all customers

-- Batch 2: Update existing customers (tests UPDATE path via DELETE+INSERT pair)
UPDATE raw_customers SET email = 'alice.new@example.com', status = 'premium' WHERE customer_id = 1;
UPDATE raw_customers SET status = 'active' WHERE customer_id = 3;

-- Wait ~5 minutes for refresh, then check
SELECT * FROM dt_customers_current ORDER BY customer_id;
-- Expected: customer 1 has new email + 'premium', customer 3 now 'active'

-- Batch 3: Delete a customer (tests DELETE path)
DELETE FROM raw_customers WHERE customer_id = 2;

-- Wait ~5 minutes for refresh, then check
SELECT * FROM dt_customers_current ORDER BY customer_id;
-- Expected: Only customers 1, 3, 4 remain (Bob deleted)

-- Batch 4: Mix of all operations
INSERT INTO raw_customers (customer_id, name, email, status) VALUES
    (5, 'Eve', 'eve@example.com', 'active');
UPDATE raw_customers SET name = 'Diana Prince', status = 'premium' WHERE customer_id = 4;
DELETE FROM raw_customers WHERE customer_id = 3;

-- Wait ~5 minutes for refresh, then check
SELECT * FROM dt_customers_current ORDER BY customer_id;
-- Expected: 1=Alice(premium), 4=Diana Prince(premium), 5=Eve(active)
-- customer 3 deleted, customer 2 was already deleted

-- Final verification: source and dynamic table should match
SELECT * FROM raw_customers ORDER BY customer_id;
SELECT * FROM dt_customers_current ORDER BY customer_id;
```

**How it works:**
- DEFAULT mode exposes inserts, updates, and deletes
- Updates appear as DELETE + INSERT pairs (`METADATA$ISUPDATE = TRUE`)
- Standalone deletes: removes row from target
- Inserts/Updates (`ACTION='INSERT'`): upserts into target
- Maintains current state of customers incrementally

---

### Example 5: BACKFILL FROM + START AT

```sql
-- Scenario: You have an existing table with historical data and want to
-- start processing changes from a specific point in time.

CREATE OR REPLACE DYNAMIC TABLE dt_orders_incremental (
    order_id INT,
    customer_id INT,
    amount DECIMAL(10,2),
    order_status STRING
)
    TARGET_LAG = '10 minutes'
    WAREHOUSE = COMPUTE_WH
    BACKFILL FROM orders_snapshot_20250601
    START AT (TIMESTAMP => '2025-06-01 00:00:00'::TIMESTAMP)
    REFRESH USING (
        MERGE INTO SELF AS tgt
        USING (
            SELECT order_id, customer_id, amount, order_status,
                   METADATA$ACTION
            FROM raw_orders CHANGES(INFORMATION => DEFAULT)
        ) AS src
        ON tgt.order_id = src.order_id
        WHEN MATCHED AND src.METADATA$ACTION = 'DELETE' THEN
            DELETE
        WHEN MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            UPDATE SET tgt.amount = src.amount,
                       tgt.order_status = src.order_status
        WHEN NOT MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            INSERT VALUES (src.order_id, src.customer_id, src.amount, src.order_status)
    );

-- Initial state: Cloned from orders_snapshot_20250601 (fast, no DML execution)
-- Subsequent refreshes: Process changes from 2025-06-01 onwards
```

---

### Example 6: READING SELF — Top-K Leaderboard with State Reuse

```sql
CREATE OR REPLACE DYNAMIC TABLE dt_top_players (
    player_id INT,
    total_score INT,
    rank INT
)
    TARGET_LAG = '5 minutes'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        MERGE INTO SELF AS tgt
        USING (
            -- Combine current leaderboard with new scores
            SELECT player_id, total_score,
                   ROW_NUMBER() OVER (ORDER BY total_score DESC) AS rank
            FROM (
                -- Existing top players
                SELECT player_id, total_score
                FROM SELF AS cur
                UNION ALL
                -- New scores since last refresh
                SELECT player_id, SUM(score) AS total_score
                FROM game_scores CHANGES(INFORMATION => APPEND_ONLY)
                GROUP BY player_id
            )
            -- Re-aggregate in case player appears in both
            GROUP BY player_id
            HAVING SUM(total_score) > 0
            QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(total_score) DESC) <= 100
        ) AS src
        ON tgt.player_id = src.player_id
        WHEN MATCHED THEN
            UPDATE SET tgt.total_score = src.total_score, tgt.rank = src.rank
        WHEN NOT MATCHED THEN
            INSERT VALUES (src.player_id, src.total_score, src.rank)
    );

-- Note: This reads SELF to combine existing state with new changes
-- Avoids re-scanning all historical game_scores each refresh
```

---

## Important Usage Notes

### 1. Transaction Semantics
- Each refresh executes as a single autocommit transaction
- If REFRESH USING fails, the entire refresh rolls back

### 2. Data Retention
- If retention expires on a base table queried through `CHANGES()` before the next refresh, the refresh **FAILS**
- Set retention periods to exceed your longest expected refresh gap

### 3. Primary Keys
- Custom incremental DTs don't automatically derive primary keys
- Add RELY primary key constraint manually for downstream consumers

### 4. Nondeterminism
- MERGE is subject to standard nondeterminism rules
- If multiple source rows match same target row, result is nondeterministic
- Use `ROW_NUMBER()` with `QUALIFY` to deduplicate

### 5. Dimension Tables in Joins
- Objects outside `CHANGES()` are read at refresh snapshot time
- They are NOT processed incrementally

### 6. RELY Primary Key Effect on CHANGES()
- Without RELY PK: DELETE + INSERT of same values = two separate change rows
- With RELY PK: DELETE + INSERT of same key = cancel out (net zero change)
- Useful for INSERT OVERWRITE patterns

---

## Limitations

- No cloning or replicating custom incremental dynamic tables
- No dbt or DCM integration
- Only CREATE OR ALTER can modify REFRESH USING definition
- Upstream schema changes cause next refresh to fail (compile error)
- Cannot combine with FROZEN WHERE or INSERT ONLY INPUTS
- CHANGES from Iceberg tables with external catalog needs RELY on source PK
- Managed Iceberg tables: external writes cause permanent refresh failure

---

## Comparison: When to Use Each Refresh Mode

| Refresh Mode | Best For |
|-------------|---------|
| INCREMENTAL | Append-heavy, <5% data change, SELECT-expressible logic |
| FULL | Unsupported constructs, high churn, bulk-reload patterns |
| AUTO | Exploration/prototyping (resolves to INCREMENTAL or FULL) |
| ADAPTIVE | Mixed append + occasional bulk loads |
| CUSTOM_INCREMENTAL | CDC with deletes, stream-static joins, audit trails, running aggregations, migrating from streams & tasks |

---

## Migrating from Streams and Tasks

If you have an existing pattern like:

```sql
CREATE STREAM my_stream ON TABLE raw_data;
CREATE TASK my_task ...
AS
    MERGE INTO target USING (SELECT * FROM my_stream) ...
```

You can port it directly to:

```sql
CREATE DYNAMIC TABLE target (...)
    TARGET_LAG = '1 minute'
    WAREHOUSE = transform_wh
    REFRESH USING (
        MERGE INTO SELF
        USING (SELECT * FROM raw_data CHANGES(INFORMATION => DEFAULT)) AS src
        ON ...
    );
```

**Benefits:**
- Managed scheduling (no TASK management)
- Automatic retry and monitoring
- Pipeline-aware dependency tracking
- Transactional guarantees per refresh

---

## Detailed Explanation: Why SELECT-Based Dynamic Tables Won't Work

### Scenario 1: Stream-Static Joins with Conditional Logic

**WHY SELECT WON'T WORK:**
- A SELECT-based dynamic table re-evaluates the entire query on each refresh
- You cannot express "only process NEW rows from table A, join with table B, and apply different logic depending on whether the joined row exists or not"
- SELECT has no concept of "what changed since last time"

**EXAMPLE:** Enrich new orders with customer tier, apply different discount logic based on tier, and skip orders for suspended customers.

```sql
CREATE OR REPLACE TABLE orders_raw (
    order_id INT,
    customer_id INT,
    amount DECIMAL(10,2),
    order_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
ALTER TABLE orders_raw SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE TABLE customer_tiers (
    customer_id INT,
    tier STRING,
    is_suspended BOOLEAN DEFAULT FALSE
);

CREATE OR REPLACE DYNAMIC TABLE dt_processed_orders (
    order_id INT,
    customer_id INT,
    original_amount DECIMAL(10,2),
    final_amount DECIMAL(10,2),
    tier STRING,
    processed_at TIMESTAMP
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        INSERT INTO SELF
        SELECT
            o.order_id,
            o.customer_id,
            o.amount,
            CASE
                WHEN c.tier = 'gold' THEN o.amount * 0.80
                WHEN c.tier = 'silver' THEN o.amount * 0.90
                ELSE o.amount
            END AS final_amount,
            COALESCE(c.tier, 'unknown') AS tier,
            CURRENT_TIMESTAMP()
        FROM orders_raw CHANGES(INFORMATION => APPEND_ONLY) AS o
        LEFT JOIN customer_tiers AS c
            ON o.customer_id = c.customer_id
        WHERE c.is_suspended = FALSE OR c.customer_id IS NULL
    );

-- Test DML
INSERT INTO customer_tiers VALUES (1, 'gold', FALSE), (2, 'silver', FALSE), (3, 'bronze', TRUE);

INSERT INTO orders_raw (order_id, customer_id, amount) VALUES
    (101, 1, 100.00),   -- Gold: gets 20% off -> 80.00
    (102, 2, 100.00),   -- Silver: gets 10% off -> 90.00
    (103, 3, 100.00),   -- Suspended: SKIPPED
    (104, 9, 50.00);    -- Unknown customer: full price, tier='unknown'

-- After refresh:
SELECT * FROM dt_processed_orders;
-- Expected: 3 rows (order 103 skipped), with tier-based discounts applied
```

> **KEY POINT:** The conditional logic (CASE on tier) + filtering (skip suspended) + joining only new orders with a static dimension table is not expressible as a single SELECT-based dynamic table that Snowflake can auto-incrementalize.

---

### Scenario 2: Soft-Deletes / Conditional Updates Per Row

**WHY SELECT WON'T WORK:**
- SELECT-based DTs produce `output = f(input)`. They can't say "if this row was deleted, don't remove it, just mark it as deleted"
- You need explicit MERGE control: `WHEN MATCHED AND action=DELETE THEN UPDATE SET is_deleted=TRUE` — this is imperative logic, not declarative SELECT

**EXAMPLE:** Maintain a customer table where deletes are soft (flagged, not removed) and updates preserve the previous version's timestamp.

```sql
CREATE OR REPLACE TABLE customers_source (
    id INT,
    name STRING,
    email STRING,
    modified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
ALTER TABLE customers_source SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE dt_customers_soft_delete (
    id INT,
    name STRING,
    email STRING,
    is_deleted BOOLEAN,
    deleted_at TIMESTAMP,
    last_modified TIMESTAMP
)
    TARGET_LAG = '2 minutes'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        MERGE INTO SELF AS tgt
        USING (
            SELECT id, name, email, modified_at,
                   METADATA$ACTION, METADATA$ISUPDATE
            FROM customers_source CHANGES(INFORMATION => DEFAULT)
        ) AS src
        ON tgt.id = src.id
        -- Soft delete: mark as deleted instead of removing
        WHEN MATCHED AND src.METADATA$ACTION = 'DELETE' AND NOT src.METADATA$ISUPDATE THEN
            UPDATE SET tgt.is_deleted = TRUE,
                       tgt.deleted_at = CURRENT_TIMESTAMP()
        -- Update: apply new values
        WHEN MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            UPDATE SET tgt.name = src.name,
                       tgt.email = src.email,
                       tgt.is_deleted = FALSE,
                       tgt.deleted_at = NULL,
                       tgt.last_modified = src.modified_at
        -- New row
        WHEN NOT MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            INSERT (id, name, email, is_deleted, deleted_at, last_modified)
            VALUES (src.id, src.name, src.email, FALSE, NULL, src.modified_at)
    );

-- Test DML
INSERT INTO customers_source (id, name, email) VALUES
    (1, 'Alice', 'alice@co.com'),
    (2, 'Bob', 'bob@co.com');

-- After refresh: both rows with is_deleted=FALSE
SELECT * FROM dt_customers_soft_delete;

-- Now delete Bob from source
DELETE FROM customers_source WHERE id = 2;

-- After refresh: Bob still exists but is_deleted=TRUE, deleted_at is set
SELECT * FROM dt_customers_soft_delete;
-- Expected: id=1 (is_deleted=FALSE), id=2 (is_deleted=TRUE, deleted_at populated)

-- Re-insert Bob (reactivation)
INSERT INTO customers_source (id, name, email) VALUES (2, 'Bob Returns', 'bob.new@co.com');

-- After refresh: Bob is back with is_deleted=FALSE
SELECT * FROM dt_customers_soft_delete WHERE id = 2;
-- Expected: name='Bob Returns', is_deleted=FALSE, deleted_at=NULL
```

> **KEY POINT:** A SELECT can only produce rows or not produce them. It cannot say "when a source row is deleted, keep it in output but flip a flag." That requires imperative MERGE logic with conditional UPDATE on DELETE action.

---

### Scenario 3: Audit Trails / Accumulators / Point-in-Time Snapshots

**WHY SELECT WON'T WORK:**
- SELECT-based DTs produce "current state" — they don't accumulate history
- An audit trail needs to APPEND every change as a new row, preserving all historical states. SELECT would just show the latest state.
- User-defined output semantics: "I want one row PER CHANGE, not per entity"

**EXAMPLE:** Record every status change of an order as a separate audit row.

```sql
CREATE OR REPLACE TABLE orders_status (
    order_id INT,
    status STRING,
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
ALTER TABLE orders_status SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE dt_order_audit_trail (
    audit_id INT AUTOINCREMENT,
    order_id INT,
    old_status STRING,
    new_status STRING,
    change_type STRING,
    recorded_at TIMESTAMP
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    INITIALIZE = ON_SCHEDULE
    REFRESH USING (
        INSERT INTO SELF (order_id, old_status, new_status, change_type, recorded_at)
        SELECT
            src.order_id,
            prev.status AS old_status,
            CASE
                WHEN src.METADATA$ACTION = 'DELETE' AND NOT src.METADATA$ISUPDATE THEN NULL
                ELSE src.status
            END AS new_status,
            CASE
                WHEN NOT src.METADATA$ISUPDATE AND src.METADATA$ACTION = 'INSERT' THEN 'CREATED'
                WHEN src.METADATA$ISUPDATE AND src.METADATA$ACTION = 'INSERT' THEN 'UPDATED'
                WHEN NOT src.METADATA$ISUPDATE AND src.METADATA$ACTION = 'DELETE' THEN 'DELETED'
                ELSE 'UNKNOWN'
            END AS change_type,
            CURRENT_TIMESTAMP()
        FROM orders_status CHANGES(INFORMATION => DEFAULT) AS src
        LEFT JOIN SELF AS prev ON src.order_id = prev.order_id
            AND prev.recorded_at = (
                SELECT MAX(recorded_at) FROM SELF WHERE order_id = src.order_id
            )
        WHERE src.METADATA$ACTION = 'INSERT'
           OR (src.METADATA$ACTION = 'DELETE' AND NOT src.METADATA$ISUPDATE)
    );

-- Test DML
INSERT INTO orders_status VALUES (1, 'pending', CURRENT_TIMESTAMP());

-- After refresh:
SELECT * FROM dt_order_audit_trail;
-- Expected: 1 row — order_id=1, old_status=NULL, new_status='pending', change_type='CREATED'

UPDATE orders_status SET status = 'shipped', changed_at = CURRENT_TIMESTAMP() WHERE order_id = 1;

-- After refresh:
SELECT * FROM dt_order_audit_trail ORDER BY recorded_at;
-- Expected: 2 rows — CREATED + UPDATED (old='pending', new='shipped')

DELETE FROM orders_status WHERE order_id = 1;

-- After refresh:
SELECT * FROM dt_order_audit_trail ORDER BY recorded_at;
-- Expected: 3 rows — CREATED + UPDATED + DELETED
```

> **KEY POINT:** SELECT-based DTs show current state. They cannot accumulate an ever-growing log of changes. INSERT INTO SELF appends new audit rows without touching existing history.

---

### Scenario 4: Running Totals / Top-K Leaderboards (State Reuse)

**WHY SELECT WON'T WORK:**
- A running total needs to READ the previous accumulated value and ADD to it
- SELECT-based DTs don't have "memory" of previous refresh output
- Without SELF reference, you'd need to re-scan ALL historical data every refresh (which defeats the purpose of incrementalization)

**EXAMPLE:** Maintain a top-10 leaderboard that only processes new game scores each refresh and re-ranks using existing accumulated totals.

```sql
CREATE OR REPLACE TABLE game_events (
    event_id INT AUTOINCREMENT,
    player_name STRING,
    points INT,
    event_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
ALTER TABLE game_events SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE dt_leaderboard_top10 (
    player_name STRING,
    total_points INT,
    games_played INT,
    current_rank INT
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        MERGE INTO SELF AS tgt
        USING (
            SELECT
                player_name,
                total_points,
                games_played,
                ROW_NUMBER() OVER (ORDER BY total_points DESC) AS current_rank
            FROM (
                -- Existing leaderboard state
                SELECT player_name, total_points, games_played
                FROM SELF

                UNION ALL

                -- New events since last refresh
                SELECT player_name, SUM(points) AS total_points, COUNT(*) AS games_played
                FROM game_events CHANGES(INFORMATION => APPEND_ONLY)
                GROUP BY player_name
            )
            -- Re-aggregate (player may be in both SELF and new events)
            GROUP BY player_name
            HAVING SUM(total_points) > 0
            QUALIFY ROW_NUMBER() OVER (ORDER BY SUM(total_points) DESC) <= 10
        ) AS src
        ON tgt.player_name = src.player_name
        WHEN MATCHED THEN
            UPDATE SET tgt.total_points = src.total_points,
                       tgt.games_played = src.games_played,
                       tgt.current_rank = src.current_rank
        WHEN NOT MATCHED THEN
            INSERT VALUES (src.player_name, src.total_points, src.games_played, src.current_rank)
    );

-- Test DML
INSERT INTO game_events (player_name, points) VALUES
    ('Alice', 500), ('Bob', 300), ('Charlie', 700),
    ('Diana', 450), ('Eve', 600);

-- After refresh:
SELECT * FROM dt_leaderboard_top10 ORDER BY current_rank;
-- Expected: Charlie(700)=1, Eve(600)=2, Alice(500)=3, Diana(450)=4, Bob(300)=5

-- More games — Alice and Bob play again
INSERT INTO game_events (player_name, points) VALUES
    ('Alice', 400), ('Bob', 800), ('Frank', 350);

-- After refresh:
SELECT * FROM dt_leaderboard_top10 ORDER BY current_rank;
-- Expected: Bob(1100)=1, Alice(900)=2, Charlie(700)=3, Eve(600)=4, Diana(450)=5, Frank(350)=6
```

> **KEY POINT:** The query reads FROM SELF to get previous totals, combines with new events, re-aggregates, and keeps only top 10. Without SELF, you'd need to scan ALL game_events history every refresh — which could be millions of rows. State reuse is impossible in a pure SELECT-based dynamic table.

---

### Scenario 5: Migrating from Streams and Tasks

**WHY SELECT WON'T WORK:**
- Existing stream+task patterns use `MERGE INTO target USING stream`
- These cannot be rewritten as a single SELECT without losing:
  - DELETE handling
  - Conditional update logic
  - Multi-clause MERGE semantics
- Custom incremental is a direct 1:1 port with zero logic changes

**EXAMPLE:** Migrate an existing inventory sync (stream+task) to dynamic table.

#### BEFORE: Stream + Task Pattern

```sql
CREATE STREAM inventory_stream ON TABLE raw_inventory;

CREATE TASK sync_inventory
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('inventory_stream')
AS
    MERGE INTO inventory_current AS tgt
    USING (SELECT * FROM inventory_stream) AS src
    ON tgt.sku = src.sku
    WHEN MATCHED AND src.METADATA$ACTION = 'DELETE' AND src.quantity = 0 THEN
        DELETE
    WHEN MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
        UPDATE SET tgt.quantity = src.quantity,
                   tgt.warehouse_id = src.warehouse_id,
                   tgt.last_restock = src.last_restock
    WHEN NOT MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
        INSERT (sku, product_name, quantity, warehouse_id, last_restock)
        VALUES (src.sku, src.product_name, src.quantity, src.warehouse_id, src.last_restock);
```

#### AFTER: Direct Port to Custom Incremental Dynamic Table

```sql
CREATE OR REPLACE TABLE raw_inventory (
    sku STRING,
    product_name STRING,
    quantity INT,
    warehouse_id INT,
    last_restock TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);
ALTER TABLE raw_inventory SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE DYNAMIC TABLE dt_inventory_current (
    sku STRING,
    product_name STRING,
    quantity INT,
    warehouse_id INT,
    last_restock TIMESTAMP
)
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH USING (
        MERGE INTO SELF AS tgt
        USING (
            SELECT sku, product_name, quantity, warehouse_id, last_restock,
                   METADATA$ACTION, METADATA$ISUPDATE
            FROM raw_inventory CHANGES(INFORMATION => DEFAULT)
        ) AS src
        ON tgt.sku = src.sku
        WHEN MATCHED AND src.METADATA$ACTION = 'DELETE' AND src.quantity = 0 THEN
            DELETE
        WHEN MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            UPDATE SET tgt.quantity = src.quantity,
                       tgt.warehouse_id = src.warehouse_id,
                       tgt.last_restock = src.last_restock
        WHEN NOT MATCHED AND src.METADATA$ACTION = 'INSERT' THEN
            INSERT (sku, product_name, quantity, warehouse_id, last_restock)
            VALUES (src.sku, src.product_name, src.quantity, src.warehouse_id, src.last_restock)
    );

-- Test DML
INSERT INTO raw_inventory VALUES
    ('SKU-001', 'Widget A', 100, 1, CURRENT_TIMESTAMP()),
    ('SKU-002', 'Widget B', 50, 1, CURRENT_TIMESTAMP()),
    ('SKU-003', 'Widget C', 200, 2, CURRENT_TIMESTAMP());

-- After refresh:
SELECT * FROM dt_inventory_current ORDER BY sku;
-- Expected: 3 items in inventory

-- Restock Widget B, deplete Widget C
UPDATE raw_inventory SET quantity = 150, last_restock = CURRENT_TIMESTAMP() WHERE sku = 'SKU-002';
UPDATE raw_inventory SET quantity = 0 WHERE sku = 'SKU-003';

-- After refresh:
SELECT * FROM dt_inventory_current ORDER BY sku;
-- Expected: SKU-001(100), SKU-002(150). SKU-003 DELETED (quantity=0 triggers DELETE clause)

-- Add new product
INSERT INTO raw_inventory VALUES ('SKU-004', 'Widget D', 75, 2, CURRENT_TIMESTAMP());

-- After refresh:
SELECT * FROM dt_inventory_current ORDER BY sku;
-- Expected: SKU-001(100), SKU-002(150), SKU-004(75)
```

> **KEY POINT:** The MERGE logic is an exact copy of the original task.
>
> Changes from stream+task to custom incremental:
> - STREAM reference → `CHANGES(INFORMATION => DEFAULT)`
> - Target table → `SELF`
> - TASK scheduling → `TARGET_LAG`
> - `SYSTEM$STREAM_HAS_DATA` → automatic (Snowflake skips refresh if no changes)
>
> **Benefits gained:**
> - No manual stream/task lifecycle management
> - Automatic retry on transient failures
> - Pipeline dependency tracking (DOWNSTREAM lag)
> - Single DDL instead of 3 objects (stream + task + target table)
