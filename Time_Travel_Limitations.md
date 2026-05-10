# Time Travel in Snowflake — Limitations, Gotchas & Complete Guide

---

## Part 1: What is Time Travel?

Time Travel lets you access historical data that has been changed or deleted within a defined retention period. You can:

- Query data as it existed at a past point in time
- Clone tables/schemas/databases to a past state
- Restore (UNDROP) accidentally dropped objects

### Syntax Options

| Syntax | Meaning |
|--------|---------|
| `AT(TIMESTAMP => ...)` | Data AT that exact moment (inclusive) |
| `AT(OFFSET => -N)` | Data N seconds ago |
| `AT(STATEMENT => 'id')` | Data as of that query's completion |
| `BEFORE(STATEMENT => 'id')` | Data just BEFORE that query completed |

---

## Part 2: Retention Period Limits (By Edition & Table Type)

| Table Type | Edition | Max Retention | Fail-Safe |
|-----------|---------|---------------|-----------|
| Permanent | Standard | 0 or 1 day | 7 days |
| Permanent | Enterprise+ | 0 to 90 days | 7 days |
| Transient | Any | 0 or 1 day | 0 days (NO Fail-safe) |
| Temporary | Any | 0 or 1 day | 0 days (NO Fail-safe) |

**KEY TAKEAWAYS:**
- Standard Edition: you can NEVER go beyond 1 day of history
- Transient/Temporary tables: max 1 day regardless of edition
- Temporary tables: retention ends when the table is dropped or session ends
- You CANNOT extend retention for transient/temporary tables — ever

---

## Part 3: All Limitations of Time Travel

### Limitation 1: Retention Period is a Hard Boundary

Once data moves past the retention period into Fail-safe, Time Travel queries FAIL. Fail-safe is for Snowflake disaster recovery ONLY — you cannot query or restore from Fail-safe yourself.

Example: Table has 1-day retention. You try to query 2 days ago:

```sql
SELECT * FROM my_table AT(TIMESTAMP => DATEADD('DAY', -2, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ);
-- ERROR: Time travel data is not available for table MY_TABLE
```

---

### Limitation 2: Metadata (DDL) Changes Are Not Reversed

Time Travel returns data using the CURRENT table schema, NOT the schema at the historical point in time. If you dropped a column, Time Travel queries will NOT show that column.

```sql
CREATE TABLE test (col1 VARCHAR, col2 INT);
INSERT INTO test VALUES ('a', 1), ('b', 2);
SET qid = LAST_QUERY_ID();
ALTER TABLE test DROP COLUMN col2;
SELECT * FROM test AT(STATEMENT => $qid);
-- Returns only col1! col2 is gone because current schema has no col2.
```

**WORKAROUND:** Use CLONE instead of SELECT for DDL recovery:

```sql
CREATE TABLE test_restored CLONE test AT(STATEMENT => $qid);
-- This restores the table WITH the dropped column
```

---

### Limitation 3: Constraints Are Not Time Traveled

When you restore a table via Time Travel, the CURRENT constraints are used, not the constraints that existed at the historical point. If you dropped a primary key or added a NOT NULL constraint after the historical point, the restored data uses today's constraint definitions.

---

### Limitation 4: Cannot Time Travel Certain Object Types

The following objects CANNOT be cloned via Time Travel:
- External tables
- Internal (Snowflake) stages
- Hybrid tables (schema-level clone not supported; database-level skips them)
- User tasks are NOT cloned when using `CREATE SCHEMA ... CLONE ... AT(TIMESTAMP)`

---

### Limitation 5: Statement ID Expires After 14 Days

The `STATEMENT => 'query_id'` parameter only works for queries executed within the last 14 days, regardless of your retention period setting.

```sql
SELECT * FROM my_table BEFORE(STATEMENT => 'old-query-id-from-30-days-ago');
-- ERROR: statement old-query-id not found
```

**WORKAROUND:** Use TIMESTAMP instead of STATEMENT for older references:

```sql
SELECT * FROM my_table AT(TIMESTAMP => '2025-12-01 10:00:00'::TIMESTAMP_LTZ);
```

---

### Limitation 6: Cannot Query Before Object Creation Time

If you specify a timestamp before the table was created, it fails:

```sql
CREATE TABLE new_table (id INT);  -- created at 2025-05-01 10:00:00
SELECT * FROM new_table AT(TIMESTAMP => '2025-04-30 10:00:00'::TIMESTAMP_NTZ);
-- ERROR: Time travel data is not available
```

---

### Limitation 7: Time Travel on CTEs is Not Supported

You CANNOT apply AT/BEFORE on a CTE reference. The clause must be inside the CTE definition, not outside it.

**WRONG (will fail):**

```sql
WITH cte AS (SELECT * FROM my_table)
SELECT * FROM cte AT(TIMESTAMP => '2025-01-01'::TIMESTAMP_NTZ);
```

**CORRECT:**

```sql
WITH cte AS (SELECT * FROM my_table AT(TIMESTAMP => '2025-01-01'::TIMESTAMP_NTZ))
SELECT * FROM cte;
```

---

### Limitation 8: Hybrid Table Restrictions

Hybrid tables have significant Time Travel restrictions:
- Only TIMESTAMP parameter is supported in AT clause
- OFFSET, STATEMENT, and STREAM parameters are NOT supported
- BEFORE clause is NOT supported at all
- When joining hybrid + standard tables, the TIMESTAMP must be identical for all tables in the same database
- Database-level CLONE with STATEMENT parameter fails if hybrid tables exist

---

### Limitation 9: Storage Costs Scale with Churn

Time Travel is NOT free. Every modified/deleted micro-partition is retained for the full retention period + 7 days of Fail-safe.

**HIGH-CHURN TABLE EXAMPLE:**

| Component | Size |
|-----------|------|
| Active storage | 200 GB |
| Time Travel storage (200GB x 20 updates x 1 day) | 4 TB |
| Fail-safe storage (200GB x 20 updates x 7 days) | 28 TB |
| **TOTAL** | **32.2 TB (161x the active data!)** |

**WORKAROUND for high-churn tables:**
1. Make the table TRANSIENT with `DATA_RETENTION_TIME_IN_DAYS = 0`
2. Periodically clone/backup to a permanent table
3. This reduces total storage from 32.2 TB to ~2 TB

---

### Limitation 10: Dropped Container Overrides Child Retention

When you DROP a DATABASE or SCHEMA, ALL child objects inherit the parent's retention period — even if the child had a different (longer) setting.

**Example:**
- Database retention: 1 day
- Table inside DB: 90 days
- `DROP DATABASE my_db;`
- The table is ONLY retained for 1 day (the DB's period), NOT 90 days!

**WORKAROUND:** Drop child objects individually BEFORE dropping the container:

```sql
DROP TABLE my_db.my_schema.important_table;   -- uses table's 90-day retention
DROP DATABASE my_db;                           -- now safe
```

---

### Limitation 11: UNDROP Name Conflict

If you drop a table and create a new one with the SAME name, UNDROP fails:

```sql
DROP TABLE orders;
CREATE TABLE orders (id INT);  -- new table with same name
UNDROP TABLE orders;
-- ERROR: Object 'ORDERS' already exists
```

**WORKAROUND:** Rename the current object first, then UNDROP:

```sql
ALTER TABLE orders RENAME TO orders_new;
UNDROP TABLE orders;  -- restores the dropped version
```

---

### Limitation 12: Timestamp Precision & Timezone Gotcha

If you don't explicitly cast your timestamp, it defaults to TIMESTAMP_NTZ (UTC). If your session timezone is different, queries can silently return wrong data or fail unexpectedly.

**WRONG (may fail or return unexpected results):**

```sql
SELECT * FROM t AT(TIMESTAMP => '2025-05-01 09:00:00');
```

**CORRECT (explicit timezone-aware cast):**

```sql
SELECT * FROM t AT(TIMESTAMP => '2025-05-01 09:00:00'::TIMESTAMP_LTZ);
```

The smallest resolution for TIMESTAMP is milliseconds.

---

### Limitation 13: BEFORE Clause Uses Completion Time, Not Start Time

`BEFORE(STATEMENT => 'id')` refers to the point just before the statement COMPLETED, not before it started. If concurrent DML happens between start and completion, those changes ARE included in your results.

**WORKAROUND:** Use TIMESTAMP with a time just before the statement started.

---

### Limitation 14: Cannot Disable Time Travel Account-Wide Permanently

Time Travel cannot be fully deactivated for an account. You can set `DATA_RETENTION_TIME_IN_DAYS = 0` at account level, but individual objects can still override this. There is no master kill switch.

Also, `MIN_DATA_RETENTION_TIME_IN_DAYS` can enforce a minimum retention that overrides per-object settings:

```
Effective retention = MAX(DATA_RETENTION_TIME_IN_DAYS, MIN_DATA_RETENTION_TIME_IN_DAYS)
```

---

## Part 4: Practical Examples

### Example 1: Query Historical Data (Basic Time Travel)

```sql
-- See what data looked like 30 minutes ago
SELECT * FROM MY_DB.PUBLIC.ORDERS
    AT(OFFSET => -60*30);

-- See what data looked like at a specific timestamp
SELECT * FROM MY_DB.PUBLIC.ORDERS
    AT(TIMESTAMP => '2025-05-01 14:00:00'::TIMESTAMP_LTZ);

-- See data just before a specific DML statement ran
SELECT * FROM MY_DB.PUBLIC.ORDERS
    BEFORE(STATEMENT => '01b4d23f-0203-b286-0000-000000012345');
```

---

### Example 2: Restore Accidentally Deleted Rows

```sql
-- Someone ran DELETE without a WHERE clause at 10:00 AM!

-- Step 1: Verify the data existed before the mistake
SELECT COUNT(*) FROM MY_DB.PUBLIC.ORDERS
    AT(TIMESTAMP => '2025-05-01 09:59:00'::TIMESTAMP_LTZ);

-- Step 2: Re-insert the deleted rows
INSERT INTO MY_DB.PUBLIC.ORDERS
    SELECT * FROM MY_DB.PUBLIC.ORDERS
    AT(TIMESTAMP => '2025-05-01 09:59:00'::TIMESTAMP_LTZ);
```

---

### Example 3: Restore a Dropped Table (UNDROP)

```sql
-- Oops, someone dropped the table
-- DROP TABLE MY_DB.PUBLIC.ORDERS;

-- Restore it (must be within retention period)
UNDROP TABLE MY_DB.PUBLIC.ORDERS;

-- If a new table with the same name already exists:
ALTER TABLE MY_DB.PUBLIC.ORDERS RENAME TO MY_DB.PUBLIC.ORDERS_TEMP;
UNDROP TABLE MY_DB.PUBLIC.ORDERS;
```

---

### Example 4: Clone a Table to a Past Point in Time

```sql
-- Clone the table as it was yesterday (zero-copy, instant)
CREATE TABLE MY_DB.PUBLIC.ORDERS_BACKUP
    CLONE MY_DB.PUBLIC.ORDERS
    AT(TIMESTAMP => DATEADD('DAY', -1, CURRENT_TIMESTAMP())::TIMESTAMP_LTZ);
```

---

### Example 5: Recover from a DDL Change (Dropped Column)

```sql
-- Use CLONE to recover the full schema + data before the DDL change
CREATE TABLE MY_DB.PUBLIC.ORDERS_WITH_OLD_COLUMNS
    CLONE MY_DB.PUBLIC.ORDERS
    BEFORE(STATEMENT => 'query-id-of-alter-table-drop-column');
```

---

### Example 6: Compare Data Before and After a Change

```sql
-- Find rows that were deleted or changed by a specific statement
SELECT
    old_data.*,
    new_data.*
FROM MY_DB.PUBLIC.ORDERS
    BEFORE(STATEMENT => '01b4d23f-0203-b286-0000-000000012345') AS old_data
FULL OUTER JOIN MY_DB.PUBLIC.ORDERS
    AT(STATEMENT => '01b4d23f-0203-b286-0000-000000012345') AS new_data
    ON old_data.ORDER_ID = new_data.ORDER_ID
WHERE old_data.ORDER_ID IS NULL
   OR new_data.ORDER_ID IS NULL;
```

---

### Example 7: Check Retention Settings Across Your Account

```sql
-- Check retention for all tables in current schema
SHOW TABLES;
-- Look at the "retention_time" column in results

-- Check retention for all databases (including dropped ones)
SHOW DATABASES HISTORY;

-- Monitor Time Travel storage consumption per table
SELECT
    TABLE_CATALOG,
    TABLE_SCHEMA,
    TABLE_NAME,
    ACTIVE_BYTES / POWER(1024,3)       AS ACTIVE_GB,
    TIME_TRAVEL_BYTES / POWER(1024,3)  AS TIME_TRAVEL_GB,
    FAILSAFE_BYTES / POWER(1024,3)     AS FAILSAFE_GB,
    (TIME_TRAVEL_BYTES + FAILSAFE_BYTES) / NULLIF(ACTIVE_BYTES, 0) AS CDP_RATIO
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE ACTIVE_BYTES > 0
ORDER BY TIME_TRAVEL_BYTES DESC
LIMIT 20;
```

---

### Example 8: Set Retention Periods at Different Levels

```sql
-- Account level (ACCOUNTADMIN only)
ALTER ACCOUNT SET DATA_RETENTION_TIME_IN_DAYS = 7;

-- Enforce a minimum retention across the account
ALTER ACCOUNT SET MIN_DATA_RETENTION_TIME_IN_DAYS = 1;

-- Database level
ALTER DATABASE MY_DB SET DATA_RETENTION_TIME_IN_DAYS = 14;

-- Schema level
ALTER SCHEMA MY_DB.PUBLIC SET DATA_RETENTION_TIME_IN_DAYS = 30;

-- Table level (Enterprise Edition: up to 90 days)
ALTER TABLE MY_DB.PUBLIC.ORDERS SET DATA_RETENTION_TIME_IN_DAYS = 90;

-- Disable Time Travel for a staging table (NOT recommended for important data)
ALTER TABLE MY_DB.STAGING.TEMP_LOAD SET DATA_RETENTION_TIME_IN_DAYS = 0;
```

---

### Example 9: Recovering Data After Table Recreation (Step-by-Step)

**SCENARIO:** You created a table, loaded data, then accidentally ran `CREATE OR REPLACE TABLE` (which drops the old table and creates a new one). Now your data is gone. Here's how to get it back.

The trick: `CREATE OR REPLACE` internally DROPs the old table first. The dropped version still exists in Time Travel.

```sql
-- STEP 1: Setup — Create and populate the original table
CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.EMPLOYEES1 (
    EMP_ID      INT,
    EMP_NAME    VARCHAR(100),
    DEPARTMENT  VARCHAR(50),
    SALARY      NUMBER(10,2)
);

INSERT INTO DEMO_DB.PUBLIC.EMPLOYEES1 VALUES
    (1, 'Rohit Sharma',   'Engineering', 120000),
    (2, 'Virat Kohli',    'Marketing',   95000),
    (3, 'MS Dhoni',       'Engineering', 135000),
    (4, 'Jasprit Bumrah', 'Sales',       88000),
    (5, 'Hardik Pandya',  'Marketing',  102000);

-- Verify: 5 rows with all data
SELECT * FROM DEMO_DB.PUBLIC.EMPLOYEES1;


-- STEP 2: Simulate the accident — CREATE OR REPLACE drops old table
CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.EMPLOYEES1 (
    EMP_ID      INT,
    EMP_NAME    VARCHAR(100),
    DEPARTMENT  VARCHAR(50),
    SALARY      NUMBER(10,2)
);

-- Table is now empty — all data is lost!
SELECT COUNT(*) AS ROW_COUNT FROM DEMO_DB.PUBLIC.EMPLOYEES1;


-- STEP 3: Confirm old table is in Time Travel
SHOW TABLES HISTORY LIKE 'EMPLOYEES1' IN SCHEMA DEMO_DB.PUBLIC;
-- Look for rows where DROPPED_ON is NOT null


-- STEP 4: Rename the new (empty) recreated table
ALTER TABLE DEMO_DB.PUBLIC.EMPLOYEES1 RENAME TO DEMO_DB.PUBLIC.EMPLOYEES_EMPTY;


-- STEP 5: UNDROP the original table
UNDROP TABLE DEMO_DB.PUBLIC.EMPLOYEES1;


-- STEP 6: Verify the recovered data
SELECT * FROM DEMO_DB.PUBLIC.EMPLOYEES1;
SELECT COUNT(*) AS RECOVERED_ROW_COUNT FROM DEMO_DB.PUBLIC.EMPLOYEES1;


-- STEP 7: Cleanup
DROP TABLE IF EXISTS DEMO_DB.PUBLIC.EMPLOYEES_EMPTY;
```

---

### What If the Table Was Dropped and Recreated Multiple Times?

UNDROP always restores the MOST RECENTLY dropped version. To recover older versions, you must UNDROP -> RENAME -> UNDROP repeatedly:

```sql
-- Version 3 (current, active)     <- rename this first
-- Version 2 (dropped 2nd)         <- UNDROP restores this
-- Version 1 (dropped 1st)         <- rename v2, then UNDROP gets this

ALTER TABLE EMPLOYEES RENAME TO EMPLOYEES_V3;
UNDROP TABLE EMPLOYEES;                          -- gets version 2
ALTER TABLE EMPLOYEES RENAME TO EMPLOYEES_V2;
UNDROP TABLE EMPLOYEES;                          -- gets version 1
```

---

### Alternative: Use CLONE Instead (When UNDROP Isn't Possible)

If the retention period hasn't expired, you can also clone from history:

```sql
CREATE TABLE DEMO_DB.PUBLIC.EMPLOYEES_RECOVERED
    CLONE DEMO_DB.PUBLIC.EMPLOYEES
    AT(OFFSET => -3600);  -- from 1 hour ago
```

This works even if the table was never "dropped" — useful for recovering from bad UPDATE/DELETE statements rather than CREATE OR REPLACE.

---

## Summary: Quick-Reference Limitation Matrix

| # | Limitation | Workaround |
|---|-----------|-----------|
| 1 | Hard retention boundary | Increase retention (Enterprise) |
| 2 | DDL changes not reversed | Use CLONE instead of SELECT |
| 3 | Constraints not time traveled | Use CLONE to restore full state |
| 4 | Some objects can't be cloned | Manually recreate ext tables etc |
| 5 | STATEMENT ID expires in 14 days | Use TIMESTAMP instead |
| 6 | Can't query before creation time | No workaround — by design |
| 7 | No AT/BEFORE on CTEs | Put AT/BEFORE inside the CTE |
| 8 | Hybrid table restrictions | Use TIMESTAMP only, no BEFORE |
| 9 | Storage cost scales with churn | Transient + periodic backups |
| 10 | Container drop overrides child | Drop children individually first |
| 11 | UNDROP name conflict | Rename existing, then UNDROP |
| 12 | Timezone/cast gotcha | Always cast to TIMESTAMP_LTZ |
| 13 | BEFORE uses completion time | Use TIMESTAMP before start time |
| 14 | Can't fully disable account-wide | Set retention=0 per object |
