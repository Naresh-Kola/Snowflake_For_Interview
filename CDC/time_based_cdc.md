# TIME-BASED CDC (TIMESTAMP-BASED CHANGE DATA CAPTURE)

## Complete Guide with Implementation

---

## 1. What is Time-Based CDC?

Time-Based CDC = Using a **TIMESTAMP column** (like `updated_at`, `modified_at`) to identify which rows have changed since the last extraction.

### How It Works:
1. Source table has a timestamp column that updates on every change
2. You record the `MAX(timestamp)` after each successful load
3. Next run: `SELECT * WHERE updated_at > last_recorded_timestamp`
4. Only changed rows are extracted

**This is the MOST COMMON CDC method in the industry.**
It does NOT require Snowflake Streams. Works across any database.

### Simple Analogy:
- You check your email at 9:00 AM
- Next time you check at 11:00 AM
- You only read emails received AFTER 9:00 AM
- The "9:00 AM" is your **watermark/checkpoint**

---

## 2. Where Do We Use Time-Based CDC?

| USE CASE | WHY TIME-BASED CDC |
|----------|-------------------|
| ETL from transactional databases (Oracle, SQL Server, PostgreSQL) | Source has UPDATED_AT column. No native CDC support needed |
| IICS/Informatica incremental loads | Filter by last_run_timestamp |
| dbt incremental models | `WHERE updated_at > MAX(this)` |
| Data lake ingestion | Partition by date, load delta |
| Cross-platform replication (Greenplum → Snowflake) | Works regardless of source DB |
| API-based data extraction | Filter: `?modified_after=<ts>` |
| Legacy systems without CDC support | Only option when no streams/log-based CDC is available |

---

## 3. Advantages and Disadvantages

### Advantages:
- Simple to implement (just a WHERE clause)
- Works on ANY database (no vendor-specific features needed)
- No additional infrastructure (no streams, no log readers)
- Easy to debug (just check timestamps)
- Supports any ETL tool (IICS, dbt, Airflow, custom scripts)
- Low overhead on source system (simple query, no log parsing)
- Can handle late-arriving data with lookback window
- Easy to re-process (just change the watermark/checkpoint)
- Works well with batch pipelines (hourly, daily, etc.)

### Disadvantages:
- CANNOT detect DELETES (deleted rows don't update the timestamp)
- Requires UPDATED_AT column on source table (not always available)
- Source must RELIABLY update the timestamp on every change
- Clock skew issues (source and target clocks must be in sync)
- Missing updates if batch runs during a transaction (race condition)
- Cannot capture intermediate states (only latest state per row)
- Backdated/late-arriving data may be missed without lookback window
- Full table scan with WHERE filter (no push-down on some sources)
- No ordering guarantee (which change came first within same second?)

### Comparison with Other CDC Methods:

| FEATURE | TIME-BASED CDC | LOG-BASED CDC | STREAMS (SF) |
|---------|---------------|---------------|--------------|
| Detects INSERTs | ✓ | ✓ | ✓ |
| Detects UPDATEs | ✓ | ✓ | ✓ |
| Detects DELETEs | ✗ | ✓ | ✓ |
| Source impact | Low (query) | Minimal (logs) | Minimal |
| Requires source change | Yes (add column) | No | No |
| Works cross-platform | ✓ | Vendor-specific | Snowflake only |
| Real-time capable | ✗ (batch) | ✓ | ✓ |
| Complexity | Low | High | Medium |
| Handles schema change | Manual | Depends | Depends |

---

## 4. Implementation - Practical

### 4.1 Setup: Source and Target Tables

```sql
CREATE DATABASE IF NOT EXISTS CDC_TIMEBASED;
CREATE SCHEMA IF NOT EXISTS CDC_TIMEBASED.RAW;
CREATE SCHEMA IF NOT EXISTS CDC_TIMEBASED.DW;

-- SOURCE TABLE (simulates a transactional system)
CREATE OR REPLACE TABLE CDC_TIMEBASED.RAW.EMPLOYEES (
    EMP_ID INT,
    NAME VARCHAR(100),
    DEPARTMENT VARCHAR(50),
    SALARY DECIMAL(12,2),
    CITY VARCHAR(50),
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- TARGET TABLE (data warehouse)
CREATE OR REPLACE TABLE CDC_TIMEBASED.DW.EMPLOYEES (
    EMP_ID INT,
    NAME VARCHAR(100),
    DEPARTMENT VARCHAR(50),
    SALARY DECIMAL(12,2),
    CITY VARCHAR(50),
    CREATED_AT TIMESTAMP_NTZ,
    UPDATED_AT TIMESTAMP_NTZ,
    DW_LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- WATERMARK TABLE (stores last successful extraction timestamp)
CREATE OR REPLACE TABLE CDC_TIMEBASED.DW.CDC_WATERMARKS (
    TABLE_NAME VARCHAR(100),
    LAST_EXTRACTED_AT TIMESTAMP_NTZ,
    LAST_RUN_STATUS VARCHAR(20),
    LAST_RUN_ROWS INT,
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### 4.2 Initial Full Load (First Run)

```sql
-- Insert source data
INSERT INTO CDC_TIMEBASED.RAW.EMPLOYEES (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CREATED_AT, UPDATED_AT) VALUES
(1, 'Rahul Sharma', 'Engineering', 120000, 'Mumbai', '2024-01-15 09:00:00', '2024-01-15 09:00:00'),
(2, 'Priya Patel', 'Marketing', 85000, 'Delhi', '2024-02-01 10:00:00', '2024-02-01 10:00:00'),
(3, 'Amit Kumar', 'Engineering', 95000, 'Bangalore', '2024-02-15 11:00:00', '2024-02-15 11:00:00'),
(4, 'Sneha Reddy', 'Finance', 110000, 'Hyderabad', '2024-03-01 08:00:00', '2024-03-01 08:00:00'),
(5, 'Vikram Singh', 'Engineering', 130000, 'Chennai', '2024-03-10 14:00:00', '2024-03-10 14:00:00');

-- Full load into target
INSERT INTO CDC_TIMEBASED.DW.EMPLOYEES 
    (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CREATED_AT, UPDATED_AT)
SELECT EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CREATED_AT, UPDATED_AT
FROM CDC_TIMEBASED.RAW.EMPLOYEES;

-- Record the watermark (MAX updated_at from source)
INSERT INTO CDC_TIMEBASED.DW.CDC_WATERMARKS (TABLE_NAME, LAST_EXTRACTED_AT, LAST_RUN_STATUS, LAST_RUN_ROWS)
SELECT 'EMPLOYEES', MAX(UPDATED_AT), 'SUCCESS', COUNT(*)
FROM CDC_TIMEBASED.RAW.EMPLOYEES;
```

### 4.3 Simulate Changes in Source

```sql
-- New employee joined
INSERT INTO CDC_TIMEBASED.RAW.EMPLOYEES (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CREATED_AT, UPDATED_AT) VALUES
(6, 'Kavita Joshi', 'Marketing', 78000, 'Pune', '2024-04-01 09:00:00', '2024-04-01 09:00:00'),
(7, 'Deepak Mehta', 'Finance', 92000, 'Jaipur', '2024-04-05 10:00:00', '2024-04-05 10:00:00');

-- Salary update
UPDATE CDC_TIMEBASED.RAW.EMPLOYEES 
SET SALARY = 140000, UPDATED_AT = '2024-04-10 11:00:00'
WHERE EMP_ID = 1;

-- Department transfer
UPDATE CDC_TIMEBASED.RAW.EMPLOYEES 
SET DEPARTMENT = 'Product', CITY = 'Gurgaon', UPDATED_AT = '2024-04-12 15:00:00'
WHERE EMP_ID = 2;
```

### 4.4 Incremental Load (Time-Based CDC)

```sql
-- Step 1: Get the last watermark
SELECT LAST_EXTRACTED_AT 
FROM CDC_TIMEBASED.DW.CDC_WATERMARKS 
WHERE TABLE_NAME = 'EMPLOYEES';
-- Returns: 2024-03-10 14:00:00 (from initial load)

-- Step 2: Extract only changed rows (WHERE updated_at > watermark)
SELECT * FROM CDC_TIMEBASED.RAW.EMPLOYEES
WHERE UPDATED_AT > (
    SELECT LAST_EXTRACTED_AT 
    FROM CDC_TIMEBASED.DW.CDC_WATERMARKS 
    WHERE TABLE_NAME = 'EMPLOYEES'
);
-- Returns: 4 rows (emp 6, 7 = new; emp 1, 2 = updated)

-- Step 3: MERGE changes into target
MERGE INTO CDC_TIMEBASED.DW.EMPLOYEES AS TGT
USING (
    SELECT * FROM CDC_TIMEBASED.RAW.EMPLOYEES
    WHERE UPDATED_AT > (
        SELECT LAST_EXTRACTED_AT 
        FROM CDC_TIMEBASED.DW.CDC_WATERMARKS 
        WHERE TABLE_NAME = 'EMPLOYEES'
    )
) AS SRC
ON TGT.EMP_ID = SRC.EMP_ID
WHEN MATCHED THEN UPDATE SET
    TGT.NAME = SRC.NAME,
    TGT.DEPARTMENT = SRC.DEPARTMENT,
    TGT.SALARY = SRC.SALARY,
    TGT.CITY = SRC.CITY,
    TGT.UPDATED_AT = SRC.UPDATED_AT,
    TGT.DW_LOADED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CREATED_AT, UPDATED_AT)
VALUES
    (SRC.EMP_ID, SRC.NAME, SRC.DEPARTMENT, SRC.SALARY, SRC.CITY, SRC.CREATED_AT, SRC.UPDATED_AT);

-- Step 4: Update watermark to new MAX(updated_at)
UPDATE CDC_TIMEBASED.DW.CDC_WATERMARKS
SET LAST_EXTRACTED_AT = (SELECT MAX(UPDATED_AT) FROM CDC_TIMEBASED.RAW.EMPLOYEES),
    LAST_RUN_STATUS = 'SUCCESS',
    LAST_RUN_ROWS = 4,
    UPDATED_AT = CURRENT_TIMESTAMP()
WHERE TABLE_NAME = 'EMPLOYEES';
```

---

## 5. Handling Deletes (The Big Problem)

Time-Based CDC **CANNOT** detect deletes natively. When a row is deleted from source, there's no `updated_at` to catch it.

### Solution A: Soft Deletes (Recommended)

Instead of physically deleting rows, mark them as deleted:

```sql
-- Add soft delete columns to source
ALTER TABLE CDC_TIMEBASED.RAW.EMPLOYEES ADD COLUMN IS_DELETED BOOLEAN DEFAULT FALSE;
ALTER TABLE CDC_TIMEBASED.RAW.EMPLOYEES ADD COLUMN DELETED_AT TIMESTAMP_NTZ;

-- "Delete" by soft-delete (instead of actual DELETE)
UPDATE CDC_TIMEBASED.RAW.EMPLOYEES 
SET IS_DELETED = TRUE, 
    DELETED_AT = CURRENT_TIMESTAMP(), 
    UPDATED_AT = CURRENT_TIMESTAMP()
WHERE EMP_ID = 4;
```

The `updated_at` change will be caught by time-based CDC!

### Solution B: Full Outer Join (Detect Hard Deletes)

Periodically compare source vs target to find missing rows:

```sql
-- Find rows that exist in target but not in source (= deleted)
SELECT TGT.EMP_ID, TGT.NAME, 'DELETED' AS CHANGE_TYPE
FROM CDC_TIMEBASED.DW.EMPLOYEES TGT
LEFT JOIN CDC_TIMEBASED.RAW.EMPLOYEES SRC ON TGT.EMP_ID = SRC.EMP_ID
WHERE SRC.EMP_ID IS NULL;
```

### Solution C: Periodic Full Reconciliation

Schedule a weekly/daily full comparison:
- Extract all IDs from source
- Compare with all IDs in target
- Any ID in target NOT in source → mark as deleted

This is a **hybrid approach**: time-based CDC for daily + full recon weekly.

---

## 6. Handling Late-Arriving Data

**PROBLEM:** Some records have `UPDATED_AT` in the past (backdated data). If your watermark is `2024-04-12` and a record arrives with `UPDATED_AT = 2024-04-08`, it will be MISSED.

**SOLUTION:** Use a **LOOKBACK WINDOW**.

```sql
-- Instead of: WHERE updated_at > watermark
-- Use: WHERE updated_at > watermark - INTERVAL '3 days'

MERGE INTO CDC_TIMEBASED.DW.EMPLOYEES AS TGT
USING (
    SELECT * FROM CDC_TIMEBASED.RAW.EMPLOYEES
    WHERE UPDATED_AT > DATEADD('day', -3, (
        SELECT LAST_EXTRACTED_AT 
        FROM CDC_TIMEBASED.DW.CDC_WATERMARKS 
        WHERE TABLE_NAME = 'EMPLOYEES'
    ))
) AS SRC
ON TGT.EMP_ID = SRC.EMP_ID
WHEN MATCHED THEN UPDATE SET
    TGT.NAME = SRC.NAME,
    TGT.DEPARTMENT = SRC.DEPARTMENT,
    TGT.SALARY = SRC.SALARY,
    TGT.CITY = SRC.CITY,
    TGT.UPDATED_AT = SRC.UPDATED_AT,
    TGT.DW_LOADED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CREATED_AT, UPDATED_AT)
VALUES
    (SRC.EMP_ID, SRC.NAME, SRC.DEPARTMENT, SRC.SALARY, SRC.CITY, SRC.CREATED_AT, SRC.UPDATED_AT);
```

**Why MERGE is safe with lookback:**
- Re-processing already-loaded rows is harmless with MERGE
- `WHEN MATCHED` → updates with same values (no-op effectively)
- Only new/changed rows actually modify the target
- Slight performance cost but **zero data loss**

---

## 7. Implementation with Stored Procedure

In production, wrap the CDC logic in a stored procedure for error handling, logging, watermark management, and reusability:

```sql
CREATE OR REPLACE PROCEDURE CDC_TIMEBASED.DW.SP_CDC_EMPLOYEES()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_watermark TIMESTAMP_NTZ;
    v_new_watermark TIMESTAMP_NTZ;
    v_rows_affected INT;
BEGIN
    -- Get current watermark
    SELECT LAST_EXTRACTED_AT INTO :v_watermark
    FROM CDC_TIMEBASED.DW.CDC_WATERMARKS
    WHERE TABLE_NAME = 'EMPLOYEES';

    -- Get new max timestamp from source
    SELECT MAX(UPDATED_AT) INTO :v_new_watermark
    FROM CDC_TIMEBASED.RAW.EMPLOYEES
    WHERE UPDATED_AT > DATEADD('day', -3, :v_watermark);

    -- If no new data, exit
    IF (v_new_watermark IS NULL) THEN
        RETURN 'No new data to process';
    END IF;

    -- MERGE changes into target
    MERGE INTO CDC_TIMEBASED.DW.EMPLOYEES AS TGT
    USING (
        SELECT * FROM CDC_TIMEBASED.RAW.EMPLOYEES
        WHERE UPDATED_AT > DATEADD('day', -3, :v_watermark)
    ) AS SRC
    ON TGT.EMP_ID = SRC.EMP_ID
    WHEN MATCHED THEN UPDATE SET
        TGT.NAME = SRC.NAME,
        TGT.DEPARTMENT = SRC.DEPARTMENT,
        TGT.SALARY = SRC.SALARY,
        TGT.CITY = SRC.CITY,
        TGT.UPDATED_AT = SRC.UPDATED_AT,
        TGT.DW_LOADED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT
        (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CREATED_AT, UPDATED_AT)
    VALUES
        (SRC.EMP_ID, SRC.NAME, SRC.DEPARTMENT, SRC.SALARY, SRC.CITY, SRC.CREATED_AT, SRC.UPDATED_AT);

    -- Update watermark
    UPDATE CDC_TIMEBASED.DW.CDC_WATERMARKS
    SET LAST_EXTRACTED_AT = :v_new_watermark,
        LAST_RUN_STATUS = 'SUCCESS',
        UPDATED_AT = CURRENT_TIMESTAMP()
    WHERE TABLE_NAME = 'EMPLOYEES';

    RETURN 'CDC completed. New watermark: ' || :v_new_watermark::VARCHAR;
END;
$$;

-- Run the procedure
CALL CDC_TIMEBASED.DW.SP_CDC_EMPLOYEES();
```

---

## 8. Automate with Snowflake Task

```sql
CREATE OR REPLACE TASK CDC_TIMEBASED.DW.TASK_CDC_EMPLOYEES
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '60 MINUTE'
AS
CALL CDC_TIMEBASED.DW.SP_CDC_EMPLOYEES();

-- Start the task
ALTER TASK CDC_TIMEBASED.DW.TASK_CDC_EMPLOYEES RESUME;

-- Check task history
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'TASK_CDC_EMPLOYEES',
    SCHEDULED_TIME_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP())
));
```

---

## 9. Time-Based CDC in dbt (Incremental Model)

dbt incremental models **ARE** time-based CDC:

```sql
{{ config(materialized='incremental', unique_key='emp_id') }}

SELECT
    emp_id, name, department, salary, city, updated_at
FROM {{ source('raw', 'employees') }}

{% if is_incremental() %}
    WHERE updated_at > (SELECT MAX(updated_at) FROM {{ this }})
{% endif %}
```

This is EXACTLY time-based CDC:
- `{{ this }}` = the target table (watermark stored as `MAX(updated_at)`)
- `is_incremental()` = not first run
- `WHERE updated_at > MAX` = extract only changes since last run

---

## 10. Time-Based CDC in IICS (Informatica)

In IICS, time-based CDC is implemented as:

1. **SOURCE QUALIFIER FILTER:**
   - Filter: `WHERE UPDATED_AT > $$LAST_RUN_TIMESTAMP`
   - `$$LAST_RUN_TIMESTAMP` = session variable from previous run

2. **MAPPING VARIABLE:**
   - Create mapping variable: `$$v_max_timestamp`
   - Set it to: `MAX(UPDATED_AT)` from source during current run
   - Store in repository after successful completion

3. **SESSION PROPERTIES:**
   - Save session value: `$$v_max_timestamp`
   - Load on next run as `$$LAST_RUN_TIMESTAMP`

4. **IN IICS TASKFLOW:**
   - Parameter: `lastRunTimestamp` (persisted between runs)
   - Source filter uses this parameter
   - After success: update parameter with new MAX timestamp

---

## 11. When to Use vs When Not to Use

### Use Time-Based CDC When:
- Source system has a reliable `UPDATED_AT` / `MODIFIED_AT` column
- Cross-database migration (Greenplum → Snowflake, Oracle → SF)
- Using ETL tools like IICS, Talend, DataStage
- Batch processing is acceptable (hourly/daily is fine)
- Source doesn't support log-based CDC
- Simple implementation preferred over complex setup
- Deletes don't happen OR soft-deletes are used
- dbt incremental models

### Do NOT Use Time-Based CDC When:
- Source has NO timestamp column and you can't add one
- Hard deletes must be captured immediately
- Real-time/sub-second latency is required
- Source timestamp is unreliable (set by app, not DB trigger)
- Need to capture every intermediate state (audit requirement)
- Snowflake-to-Snowflake (use Streams instead)

---

## 12. Summary

**TIME-BASED CDC** = Simple, universal, effective for most batch pipelines.

### Key Components:
1. Source table with `UPDATED_AT` column
2. Watermark table tracking last successful extraction
3. `WHERE updated_at > watermark` (with optional lookback window)
4. `MERGE` into target (handles both inserts and updates)
5. Update watermark after successful load

### Formula:
```
New/Changed Rows = SELECT * FROM source WHERE updated_at > last_watermark
```

### Handle Deletes With:
- **Soft deletes** (`IS_DELETED` flag) — best option
- **Periodic full reconciliation** — catches hard deletes
- **Full outer join comparison** — expensive but complete

### Tools That Use This Pattern:
- dbt incremental models
- IICS incremental mappings
- Airflow DAGs with timestamp parameters
- Control-M jobs with parameterized SQL
- Custom Python/Spark ETL scripts
