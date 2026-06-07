# Real Life ETL Pipeline Failure — Debug & Recovery Flow

---

## Phase 1 — Detection (How Do You Know It Failed?)

You don't always find out yourself. In production, failure is detected through one of these:

```
1. IICS Job Monitor     → Job shows RED / SUSPENDED status
2. Automic / Control-M  → Dependent jobs are waiting, alert fires
3. Email / PagerDuty    → Automated alert sent to on-call engineer
4. End User Complaint   → "Dashboard has no data for today" (worst way to find out)
5. SLA Breach Alert     → Data expected by 8 AM, it is 9 AM, nothing arrived
```

The moment you get the alert — **do not start fixing immediately**. First understand the full scope.

---

## Phase 2 — First Response (What Is the Blast Radius?)

Before touching anything, answer these three questions:

```
Q1. Is this job alone failed or are downstream jobs also stuck?
Q2. What time did it fail? How much data is missing?
Q3. Is this a one-time failure or has it been failing for multiple runs?
```

**Check IICS / Automic job dependency chain:**

```
IICS Job: LOAD_FILES_TO_TARGET   ← FAILED here
    ↓
Control-M: TRANSFORM_TARGET       ← WAITING (blocked)
    ↓
Control-M: LOAD_DATAMART           ← WAITING (blocked)
    ↓
WebFocus / Dashboard               ← End users see stale data
```

Now you know — fixing the first job will unblock the entire chain.

---

## Phase 3 — Identify the Failure Point (Where Did It Break?)

### Step 3.1 — Check etl_batch First (Batch Level)

```sql
-- First query you run — tells you which step broke and what the error was
SELECT
    ETL_Batch_ID,
    Status,
    Failed_Step,
    Error_Msg,
    Start_Time,
    End_Time,
    DATEDIFF('minute', Start_Time, End_Time) AS Duration_Mins
FROM etl_batch
WHERE Start_Time >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
ORDER BY Start_Time DESC;
```

**What you read from the output:**

```
ETL_Batch_ID  Status  Failed_Step             Error_Msg
------------  ------  ----------------------  -----------------------------------------
100023        FAILED  STEP_2_INTEGRITY_CHECK  [BATCH:100023][STEP:STEP_2_INTEGRITY_CHECK]
                                              [CODE:-20001][STATE:P0001]
                                              [ERROR: DATA INTEGRITY FAILED |
                                               Total bad rows: 4 | ...]
```

Now you know exactly which step failed. Go deeper based on the step.

---

### Step 3.2 — Check File_history_log_table (File Level)

```sql
-- Which files were affected and what happened to each
SELECT
    File_ID,
    file_name,
    Status,
    Failed_Step,
    Rows_Loaded,
    Error_Msg,
    Load_Start_TS,
    Load_End_TS
FROM File_history_log_table
WHERE ETL_Batch_ID = 100023
ORDER BY Load_Start_TS;
```

**Possible outputs and what they mean:**

```
-- Scenario A: Failed at Step 2 (Integrity) — no files were logged yet
(0 rows returned)
→ Failure happened before Step 3 ran. File logging never started.

-- Scenario B: Failed at Step 4 (Target Insert) — all files show FAILED
File_ID  file_name   Status  Failed_Step           Error_Msg
-------  ---------   ------  --------------------  --------------------------
1001     fileA.csv   FAILED  STEP_4_TARGET_INSERT  Table TARGET_TABLE does
1002     fileB.csv   FAILED  STEP_4_TARGET_INSERT  not exist
1003     fileC.csv   FAILED  STEP_4_TARGET_INSERT  ...
```

---

### Step 3.3 — If Step 2 Failed — Check ETL_Error_Log (Data Level)

```sql
-- Full list of every bad row, every file, every column
SELECT
    file_name,
    Row_Num_In_File,
    Column2_Value,    Column2_Error_Desc,
    Column3_Value,    Column3_Error_Desc,
    Logged_TS
FROM ETL_Error_Log
WHERE ETL_Batch_ID = 100023
ORDER BY file_name, Row_Num_In_File;

-- Summary: how many errors per file
SELECT
    file_name,
    COUNT(*)                                              AS Total_Bad_Rows,
    SUM(CASE WHEN Column2_Invalid THEN 1 ELSE 0 END)     AS Column2_Errors,
    SUM(CASE WHEN Column3_Invalid THEN 1 ELSE 0 END)     AS Column3_Errors
FROM ETL_Error_Log
WHERE ETL_Batch_ID = 100023
GROUP BY file_name
ORDER BY Total_Bad_Rows DESC;
```

**Output:**

```
file_name    Row_Num  Column3_Value  Column3_Error_Desc
---------    -------  -------------  -------------------------------------------
fileB.csv    12       20260135       Cannot parse '20260135' to DATE (YYYYMMDD)
fileB.csv    45       20261340       Cannot parse '20261340' to DATE (YYYYMMDD)
fileB.csv    78       99999999       Cannot parse '99999999' to DATE (YYYYMMDD)
fileF.csv    3        abc123         Cannot parse 'abc123' to NUMBER
```

You now know exactly what is wrong, in which file, on which row, in which column,
with which value — without running the job a second time.

---

## Phase 4 — Root Cause Analysis (Why Did It Fail?)

Based on what `Failed_Step` told you, the investigation differs per step.

### If Failed at STEP_1_COPY_INTO

```sql
-- Check Snowflake query history for the COPY command
SELECT
    QUERY_TEXT,
    ERROR_MESSAGE,
    START_TIME,
    END_TIME,
    EXECUTION_STATUS
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE QUERY_TEXT ILIKE '%COPY INTO Raw_Data_Staging%'
  AND START_TIME >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC
LIMIT 5;
```

Common root causes:

| Symptom | Root Cause | Who Fixes It |
|---|---|---|
| Stage does not exist or not authorized | Stage dropped or IAM key expired | DBA / Cloud Infra team |
| No files found in path | Upstream did not deliver files or wrong folder | Source system team |
| Column count mismatch | Source added extra columns without notice | Source system team |
| File truncated or corrupted | Network failure during S3 upload | Source system team |

---

### If Failed at STEP_2_INTEGRITY_CHECK

Bad data from the source system. Query `ETL_Error_Log` as shown in Step 3.3.
Contact source system team with exact bad values and row numbers.
Decide whether to fix in `Raw_Data_Staging` directly or ask source to resend files.

---

### If Failed at STEP_4_TARGET_INSERT

```sql
-- Check if target table still exists
SHOW TABLES LIKE 'TARGET_TABLE';

-- Check if role still has INSERT privilege
SHOW GRANTS TO ROLE <your_role>;

-- Check if another session is holding a lock on the table
SELECT *
FROM TABLE(INFORMATION_SCHEMA.LOCK_WAIT_HISTORY())
WHERE START_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP());
```

Common root causes:

| Symptom | Root Cause |
|---|---|
| Table does not exist | Accidental DROP — recover with UNDROP or Time Travel |
| Insufficient privileges | Role was changed during access review — DBA to restore |
| Lock timeout | Another job or manual query holding a lock — kill the session |
| Warehouse timeout | File volume grew — upgrade warehouse size |

---

## Phase 5 — Fix the Issue

### Fix Path A — Data Issue (Step 2 Integrity Failure)

```sql
-- Option 1: Fix directly in Raw_Data_Staging
-- (transient table survived the session — still queryable)
UPDATE Raw_Data_Staging
SET    Column3 = '20260131'         -- corrected value agreed with source team
WHERE  file_name = 'fileB.csv'
  AND  Column3   = '20260135';      -- exact bad value from ETL_Error_Log

-- Option 2: Ask source team to resend corrected files to S3
-- Then re-trigger the job normally — COPY INTO will reload fresh files
```

---

### Fix Path B — Infrastructure Issue (Step 1 or Step 4 Failure)

```sql
-- Target table accidentally dropped — recover with Time Travel
UNDROP TABLE TARGET_TABLE;

-- Verify it is back
SELECT COUNT(*) FROM TARGET_TABLE;
```

```sql
-- Stage credentials expired — re-create stage with new credentials (DBA task)
CREATE OR REPLACE STAGE NYHPETL_INBOUND_STAGE
    URL         = 's3://<YOUR_BUCKET>/'
    CREDENTIALS = (AWS_KEY_ID = '<NEW_KEY>' AWS_SECRET_KEY = '<NEW_SECRET>');
```

---

### Fix Path C — Lock / Concurrency Issue

```sql
-- Identify the blocking query from lock history
-- Then cancel it
SELECT SYSTEM$CANCEL_QUERY('<blocking_query_id>');
```

---

## Phase 6 — Rerun the Job

Before rerunning, always verify and clean the state. Never rerun on a dirty state.

```sql
-- Step 1: Check if partial data landed in target from the failed run
SELECT COUNT(*)
FROM TARGET_TABLE
WHERE ETL_Batch_ID = 100023;
-- Should be 0 if failure was before Step 4
-- If not 0 — partial load exists. Must clean before rerun.

-- Step 2: Delete any partial rows in target (idempotency cleanup)
DELETE FROM TARGET_TABLE
WHERE ETL_Batch_ID = 100023;

-- Step 3: Reset batch status so IICS can rerun
UPDATE etl_batch
SET
    Status      = 'INPROGRESS',
    Failed_Step = NULL,
    Error_Msg   = NULL,
    End_Time    = NULL
WHERE ETL_Batch_ID = 100023;

-- Step 4: Clean up old file log rows for this batch
DELETE FROM File_history_log_table
WHERE ETL_Batch_ID = 100023;

-- Step 5: Clean up old error log rows for this batch
DELETE FROM ETL_Error_Log
WHERE ETL_Batch_ID = 100023;
```

Now retrigger the job from IICS / Automic.

---

## Phase 7 — Verify the Fix (Do Not Close the Ticket Yet)

```sql
-- 1. Confirm batch completed successfully
SELECT ETL_Batch_ID, Status, Failed_Step, Start_Time, End_Time
FROM   etl_batch
WHERE  ETL_Batch_ID = 100023;
-- Expected: Status = SUCCESS, Failed_Step = NULL

-- 2. Confirm all files loaded successfully
SELECT Status, COUNT(*) AS File_Count
FROM   File_history_log_table
WHERE  ETL_Batch_ID = 100023
GROUP  BY Status;
-- Expected: one row — SUCCESS | 200+
-- No FAILED rows. No INPROGRESS rows.

-- 3. Confirm row count in target table
SELECT COUNT(*) AS Rows_Loaded
FROM   TARGET_TABLE
WHERE  ETL_Batch_ID = 100023;
-- Cross-check this against SUM(Rows_Loaded) in File_history_log_table

-- 4. Row count reconciliation — most important verification query
--    Compares what COPY INTO loaded vs what actually reached the target
SELECT
    f.file_name,
    f.Rows_Loaded                AS Expected_Rows,
    COUNT(t.File_ID)             AS Actual_Rows_In_Target,
    f.Rows_Loaded - COUNT(t.File_ID) AS Difference
FROM      File_history_log_table f
LEFT JOIN TARGET_TABLE           t
       ON t.File_ID      = f.File_ID
      AND t.ETL_Batch_ID = f.ETL_Batch_ID
WHERE f.ETL_Batch_ID = 100023
GROUP BY f.file_name, f.Rows_Loaded
HAVING f.Rows_Loaded <> COUNT(t.File_ID);
-- Should return 0 rows — no difference between expected and actual
-- Any row returned here means data loss — investigate before closing
```

---

## Phase 8 — Unblock Downstream and Notify End Users

Once all verification queries pass:

```
1. Release held downstream jobs in Control-M / Automic
   OR they auto-trigger once etl_batch.Status = 'SUCCESS'

2. Notify end users:
   "Data for 2026-06-07 is now available.
    Delay was caused by [reason].
    All [200] files loaded successfully.
    Dashboard will reflect updated data within [X] minutes."

3. Raise an incident ticket with:
   - ETL_Batch_ID
   - Failed_Step
   - Root cause
   - Fix applied
   - Time to resolution
   - Prevention steps
```

---

## Phase 9 — Post Incident Review (Prevent Recurrence)

Every failure must result in a prevention action. Do not close the incident without one.

| Root Cause Found | Prevention Action |
|---|---|
| Source sent bad date / number values | Add source-side validation. Share SLA with source team defining acceptable formats. |
| S3 credentials / IAM key expired | Automated key rotation alert 30 days before expiry. |
| Target table accidentally dropped | `ALTER TABLE TARGET_TABLE SET DATA_RETENTION_TIME_IN_DAYS = 7`. Restrict DROP privilege to DBA role only. |
| Warehouse timeout | Increase warehouse size for this job. Add `STATEMENT_TIMEOUT_IN_SECONDS` to warehouse config. |
| Duplicate job triggered simultaneously | Idempotency guard: check if batch is already INPROGRESS before starting a new one. |
| Lock contention with another job | Stagger job schedules so conflicting jobs do not overlap. |
| Stage not found after migration | Add stage existence check at start of procedure. Alert before running. |

---

## Full Debug Flow — One Page Summary

```
ALERT FIRES (IICS / Automic / PagerDuty / End User)
    │
    ├── Understand blast radius
    │     └── Which downstream jobs are blocked?
    │
    ├── PHASE 3: Identify failure point
    │     ├── Query etl_batch        → Which step? What error?
    │     ├── Query File_history     → Which files? What status?
    │     └── Query ETL_Error_Log    → Which rows? Which values? (Step 2 only)
    │
    ├── PHASE 4: Root cause analysis
    │     ├── STEP_1 failed → Stage / S3 / file format issue
    │     ├── STEP_2 failed → Bad data from source system
    │     ├── STEP_3 failed → Sequence / log table issue
    │     ├── STEP_4 failed → Target table / privilege / lock issue
    │     └── STEP_5 failed → Log table issue (data already loaded)
    │
    ├── PHASE 5: Fix
    │     ├── Data fix   → Correct Raw_Data_Staging or ask source to resend
    │     ├── Infra fix  → UNDROP / recreate stage / restore privilege
    │     └── Lock fix   → Cancel blocking query
    │
    ├── PHASE 6: Clean state + Rerun
    │     ├── DELETE partial rows from TARGET_TABLE
    │     ├── Reset etl_batch, File_history_log_table, ETL_Error_Log
    │     └── Retrigger from IICS / Automic
    │
    ├── PHASE 7: Verify
    │     ├── etl_batch → SUCCESS
    │     ├── File_history → all SUCCESS, no FAILED / INPROGRESS
    │     └── Row reconciliation → 0 difference between expected and actual
    │
    ├── PHASE 8: Unblock downstream + Notify end users
    │
    └── PHASE 9: Post incident review → Prevention action logged
```

---

## Why the Log Table Design Makes This Flow Possible

Every phase of this debug flow is powered by a specific table:

| Phase | Table Used | What It Answers |
|---|---|---|
| Where did it fail? | `etl_batch.Failed_Step` | Exact step name |
| What was the error? | `etl_batch.Error_Msg` | Full error context with code and state |
| Which files affected? | `File_history_log_table` | File-level status and error per file |
| What data was bad? | `ETL_Error_Log` | Row, column, value, reason — all errors at once |
| Was partial data loaded? | `TARGET_TABLE.ETL_Batch_ID` | Scoped delete before rerun |
| Did the fix work? | All four tables | Full reconciliation before closing |

This is why the logging design is not just an audit requirement — it is the operational
backbone that makes fast, confident incident resolution possible.















###Second Scenario

# Real Life Production ETL Pipeline Failure — Debug, Resolve & Idempotent Rerun

---

## What Is a Production ETL Pipeline?

In a real enterprise environment, an ETL pipeline is not a single job. It is a
**chain of dependent jobs** that moves data from source systems to end users.

```
Source System (Oracle / Greenplum / S3 / API)
    ↓
Extraction Layer  (IICS / DataStage / Python)
    ↓
Staging Layer     (Raw tables in Snowflake / staging DB)
    ↓
Transformation    (Stored Procedures / dbt / IICS mappings)
    ↓
Data Warehouse    (Snowflake fact and dimension tables)
    ↓
Data Mart         (Aggregated / business-ready tables)
    ↓
Reporting Layer   (WebFocus / Tableau / PowerBI dashboards)
    ↓
End Users
```

When any step in this chain fails, **everything below it stops**.
End users see stale or missing data.

---

## How You Come to Know the Pipeline Failed

In production you rarely discover failures yourself.
You are alerted through one of these channels:

| Alert Source | What You See |
|---|---|
| Automic / Control-M | Job in RED or ABEND status. Dependent jobs in WAITING. |
| IICS Job Monitor | Task shows FAILED or SUSPENDED. Run details show error. |
| Email / PagerDuty | Automated alert fired at on-call engineer. |
| Snowflake Alerts | Query-based monitor triggered (e.g. row count = 0 at 8 AM). |
| End User Complaint | "Dashboard shows yesterday's data." Worst way to find out. |
| SLA Breach | Data was due at 7 AM. It is 9 AM. Nothing loaded. |

**Golden Rule: Do not start fixing the moment you see the alert.
Understand the full scope first.**

---

## Phase 1 — Understand the Blast Radius

Before touching anything, answer these questions:

```
Q1. Which job failed and at what time?
Q2. Which downstream jobs are blocked because of this failure?
Q3. Which end users or reports are impacted?
Q4. Is this the first failure or has this been failing for multiple days?
Q5. Is this a data issue or an infrastructure issue?
```

### Check the Dependency Chain

```
Example chain in Automic / Control-M:

JOB_EXTRACT_SALES        ← FAILED (8:03 AM)
    ↓
JOB_TRANSFORM_SALES      ← WAITING (never triggered)
    ↓
JOB_LOAD_DATAMART        ← WAITING (never triggered)
    ↓
JOB_REFRESH_DASHBOARD    ← WAITING (never triggered)
    ↓
Sales Dashboard          ← End users see data from yesterday
```

Now you know:
- One failure cascaded into 3 blocked jobs
- Sales dashboard is stale
- Fixing the first job unblocks the entire chain

---

## Phase 2 — Collect Initial Information Before Debugging

Go to your orchestration tool (Automic / Control-M / IICS) and note down:

```
1. Exact job name that failed
2. Exact error message shown in the job log
3. Job start time and failure time
4. Which step / task inside the job failed
5. Whether it is a scheduled run or a manual trigger
6. Whether it failed on the first attempt or after retries
```

This information guides where you look next. Never skip this step.

---

## Phase 3 — Identify the Failure Layer

A production ETL failure falls into one of four layers.
The layer tells you where to investigate.

### Layer 1 — Infrastructure / Connectivity Failure

The job could not even start or connect to a system.

**Symptoms:**
```
- Connection timeout to source database
- S3 bucket not accessible
- Snowflake warehouse suspended
- IICS Secure Agent is down
- Network firewall rule changed
```

**Where to look:**
```sql
-- Snowflake: check if warehouse is running
SHOW WAREHOUSES LIKE '<your_warehouse>';

-- Snowflake: check recent login / connection failures
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.LOGIN_HISTORY
WHERE EVENT_TIMESTAMP >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
  AND IS_SUCCESS = 'NO'
ORDER BY EVENT_TIMESTAMP DESC;

-- Snowflake: check query failures in last 2 hours
SELECT
    QUERY_TEXT,
    ERROR_MESSAGE,
    START_TIME,
    EXECUTION_STATUS,
    USER_NAME,
    WAREHOUSE_NAME
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE START_TIME    >= DATEADD('hour', -2, CURRENT_TIMESTAMP())
  AND ERROR_MESSAGE IS NOT NULL
ORDER BY START_TIME DESC
LIMIT 20;
```

**Who fixes it:**
- Cloud / Infra team for network, firewall, S3 access
- DBA for Snowflake warehouse, credentials
- IICS admin for Secure Agent

---

### Layer 2 — Data Extraction Failure

The connection worked but the data could not be extracted correctly.

**Symptoms:**
```
- Source table structure changed (column added / renamed / dropped)
- Source query returned 0 rows unexpectedly
- File not delivered to expected S3 path
- File delivered but in wrong format (JSON instead of CSV)
- Encoding issues in source data (special characters breaking parse)
- Volume spike — source sent 10x normal rows, job timed out
```

**Where to look:**
```sql
-- Check if source table structure changed recently (Snowflake source)
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.COLUMNS
WHERE TABLE_NAME   = '<source_table>'
  AND DELETED      IS NOT NULL
ORDER BY DELETED DESC;

-- Check row count in staging vs yesterday
SELECT
    CURRENT_DATE()              AS Load_Date,
    COUNT(*)                    AS Todays_Row_Count
FROM staging_table
WHERE load_date = CURRENT_DATE()

UNION ALL

SELECT
    CURRENT_DATE() - 1,
    COUNT(*)
FROM staging_table
WHERE load_date = CURRENT_DATE() - 1;
-- If today = 0 and yesterday = 500000, extraction failed silently
```

**Who fixes it:**
- Source system team if they changed the schema without notice
- Your team if the extraction query needs updating
- Upstream data team if files were not delivered

---

### Layer 3 — Transformation / Processing Failure

Data was extracted but the transformation logic broke.

**Symptoms:**
```
- Stored procedure threw an exception
- Data type conversion failed (string that should be a date)
- Join produced unexpected row explosion (cartesian product)
- NULL values in NOT NULL columns
- Duplicate records violating unique constraints
- Business logic failure (negative quantities, future dates)
- Memory / spill to disk on large transformation
```

**Where to look:**
```sql
-- Check Snowflake stored procedure execution history
SELECT
    QUERY_TEXT,
    ERROR_MESSAGE,
    START_TIME,
    END_TIME,
    TOTAL_ELAPSED_TIME / 1000   AS Duration_Seconds,
    BYTES_SCANNED,
    ROWS_PRODUCED
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE QUERY_TEXT    ILIKE '%CALL SP_%'
  AND START_TIME    >= DATEADD('hour', -6, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC;

-- Check row counts at each stage of the transformation
SELECT 'staging'     AS layer, COUNT(*) AS rows FROM staging_table    WHERE batch_date = CURRENT_DATE()
UNION ALL
SELECT 'transformed' AS layer, COUNT(*) AS rows FROM transform_table  WHERE batch_date = CURRENT_DATE()
UNION ALL
SELECT 'target'      AS layer, COUNT(*) AS rows FROM target_table     WHERE batch_date = CURRENT_DATE();
-- Each layer should have similar counts. Big drop = data lost in transformation.

-- Check for duplicate records in staging that could cause downstream issues
SELECT
    business_key,
    COUNT(*) AS duplicate_count
FROM staging_table
WHERE batch_date = CURRENT_DATE()
GROUP BY business_key
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC
LIMIT 20;

-- Check for unexpected NULLs in critical columns
SELECT
    COUNT(*)                                            AS total_rows,
    SUM(CASE WHEN customer_id    IS NULL THEN 1 END)   AS null_customer_id,
    SUM(CASE WHEN transaction_dt IS NULL THEN 1 END)   AS null_transaction_dt,
    SUM(CASE WHEN amount         IS NULL THEN 1 END)   AS null_amount
FROM staging_table
WHERE batch_date = CURRENT_DATE();
```

---

### Layer 4 — Load / Target Failure

Transformation succeeded but data could not be written to the target.

**Symptoms:**
```
- Target table does not exist (accidental DROP)
- Insufficient privileges to INSERT / UPDATE / MERGE
- Unique constraint violation in target
- Lock contention — another session has the table locked
- Disk / storage quota exceeded
- Snowflake warehouse timeout during large INSERT
```

**Where to look:**
```sql
-- Check if target table exists
SHOW TABLES LIKE '<target_table_name>';

-- Check grants for your role on the target table
SHOW GRANTS TO ROLE <your_etl_role>;

-- Check for active locks on the target table
SELECT *
FROM TABLE(INFORMATION_SCHEMA.LOCK_WAIT_HISTORY())
WHERE START_TIME >= DATEADD('hour', -1, CURRENT_TIMESTAMP());

-- Check for long running queries that might be blocking
SELECT
    QUERY_ID,
    QUERY_TEXT,
    USER_NAME,
    TOTAL_ELAPSED_TIME / 1000  AS Running_Seconds,
    EXECUTION_STATUS
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE EXECUTION_STATUS = 'RUNNING'
  AND TOTAL_ELAPSED_TIME > 300000   -- running more than 5 minutes
ORDER BY TOTAL_ELAPSED_TIME DESC;
```

---

## Phase 4 — Root Cause Analysis

Once you know the layer, identify the specific root cause.

### Root Cause Decision Tree

```
Job Failed
    │
    ├── Could not connect to source / target?
    │     └── Infrastructure failure
    │           ├── Credentials expired?     → Rotate credentials
    │           ├── Warehouse suspended?     → Resume warehouse
    │           ├── Network blocked?         → Infra team
    │           └── Agent down?              → Restart IICS agent
    │
    ├── Connected but wrong / no data extracted?
    │     └── Extraction failure
    │           ├── Schema changed?          → Update extraction query
    │           ├── File not arrived?        → Chase upstream team
    │           ├── 0 rows from source?      → Source system issue
    │           └── Format changed?          → Update file format config
    │
    ├── Data extracted but transformation broke?
    │     └── Transformation failure
    │           ├── Data type error?         → Validate and clean source data
    │           ├── Duplicates?              → Add dedup logic
    │           ├── NULLs in NOT NULL cols?  → Add NULL handling
    │           ├── Row explosion?           → Fix join logic
    │           └── Timeout?                → Optimize query / scale warehouse
    │
    └── Transformation succeeded but load broke?
          └── Load failure
                ├── Table dropped?           → UNDROP or recreate
                ├── Privilege revoked?       → DBA restores grant
                ├── Lock contention?         → Kill blocking session
                └── Constraint violation?    → Deduplicate before load
```

---

## Phase 5 — Fix the Issue

### Fix: Expired Credentials

```sql
-- Re-create S3 stage with new credentials
CREATE OR REPLACE STAGE my_s3_stage
    URL         = 's3://<bucket>/<path>/'
    CREDENTIALS = (AWS_KEY_ID = '<new_key>' AWS_SECRET_KEY = '<new_secret>');

-- Verify stage is accessible
LIST @my_s3_stage;
```

### Fix: Warehouse Suspended

```sql
-- Resume the warehouse
ALTER WAREHOUSE <warehouse_name> RESUME;

-- Verify it is running
SHOW WAREHOUSES LIKE '<warehouse_name>';
```

### Fix: Target Table Accidentally Dropped

```sql
-- Snowflake Time Travel — recover the table
UNDROP TABLE <target_table_name>;

-- Verify row count is intact
SELECT COUNT(*) FROM <target_table_name>;

-- If UNDROP is not available (retention period passed), recreate from clone or backup
CREATE TABLE <target_table_name> CLONE <target_table_name_backup>;
```

### Fix: Lock Contention

```sql
-- Find the blocking session
SELECT
    QUERY_ID,
    USER_NAME,
    QUERY_TEXT,
    TOTAL_ELAPSED_TIME / 1000 AS Running_Seconds
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE EXECUTION_STATUS = 'RUNNING'
ORDER BY TOTAL_ELAPSED_TIME DESC;

-- Cancel the blocking query
SELECT SYSTEM$CANCEL_QUERY('<blocking_query_id>');
```

### Fix: Data Type / Integrity Issue in Source Data

```sql
-- Identify all bad rows in staging
SELECT
    source_file,
    ROW_NUMBER() OVER (PARTITION BY source_file ORDER BY record_key) AS row_num,
    amount_column,
    date_column,
    TRY_TO_NUMBER(amount_column)            IS NULL AS amount_invalid,
    TRY_TO_DATE(date_column, 'YYYYMMDD')    IS NULL AS date_invalid
FROM staging_table
WHERE batch_date = CURRENT_DATE()
  AND (
      TRY_TO_NUMBER(amount_column)           IS NULL
   OR TRY_TO_DATE(date_column, 'YYYYMMDD')   IS NULL
  );

-- Option A: Fix values directly in staging (if you have authority)
UPDATE staging_table
SET    date_column = '20260131'         -- corrected value
WHERE  batch_date  = CURRENT_DATE()
  AND  date_column = '20260135';        -- bad value

-- Option B: Exclude bad rows and load only clean rows (with business approval)
INSERT INTO target_table
SELECT * FROM staging_table
WHERE batch_date = CURRENT_DATE()
  AND TRY_TO_NUMBER(amount_column)           IS NOT NULL
  AND TRY_TO_DATE(date_column, 'YYYYMMDD')   IS NOT NULL;
```

### Fix: Privilege Revoked

```sql
-- DBA runs this to restore the grant
GRANT INSERT, UPDATE, DELETE ON TABLE <target_table> TO ROLE <etl_role>;

-- Verify
SHOW GRANTS TO ROLE <etl_role>;
```

---

## Phase 6 — Prepare for Idempotent Rerun

This is the most critical phase. **Idempotency means: running the job multiple
times produces the same result as running it once.**

Without idempotency, a rerun after partial failure causes:
- Duplicate rows in the target table
- Double-counted metrics in dashboards
- Incorrect SCD history records
- Wrong aggregations in data marts

### What Is a Partial Load?

A partial load happens when the job fails mid-execution after some data was
already written to the target. Example:

```
Batch has 200 files — 120 files loaded to target table successfully
Job fails on file 121 due to a lock timeout
Files 122-200 never loaded

State of target table:
  120 files worth of data → PRESENT (partial)
  80 files worth of data  → MISSING
```

If you rerun without cleaning, files 1-120 get loaded AGAIN → duplicates.

### Step-by-Step Idempotency Cleanup Before Rerun

#### Step 1 — Identify What Was Partially Loaded

```sql
-- Check what landed in the target for today's batch
SELECT
    batch_date,
    batch_id,
    COUNT(*)            AS Rows_In_Target,
    COUNT(DISTINCT source_file) AS Files_In_Target
FROM target_table
WHERE batch_date = CURRENT_DATE()
GROUP BY batch_date, batch_id;

-- Compare against what was expected
SELECT
    COUNT(*) AS Files_In_Staging
FROM staging_table
WHERE batch_date = CURRENT_DATE();
-- If Files_In_Target < Files_In_Staging → partial load confirmed
```

#### Step 2 — Delete the Partial Data From Target

```sql
-- DELETE scoped strictly to today's batch
-- Never delete by date alone if multiple batches run per day
-- Always scope by batch_id for precision

DELETE FROM target_table
WHERE batch_date = CURRENT_DATE()
  AND batch_id   = <failed_batch_id>;

-- Verify deletion
SELECT COUNT(*) FROM target_table
WHERE batch_date = CURRENT_DATE()
  AND batch_id   = <failed_batch_id>;
-- Must return 0 before rerun
```

#### Step 3 — Reset Log Table Statuses

```sql
-- If your pipeline has a batch log table, reset it
UPDATE etl_batch_log
SET
    status      = 'PENDING',
    error_msg   = NULL,
    end_time    = NULL,
    failed_step = NULL
WHERE batch_id  = <failed_batch_id>
  AND batch_date = CURRENT_DATE();

-- If your pipeline has a file-level log table, clean it
DELETE FROM etl_file_log
WHERE batch_id  = <failed_batch_id>
  AND batch_date = CURRENT_DATE();
```

#### Step 4 — Reset Staging If Needed

```sql
-- If staging table was partially populated, clean it too
DELETE FROM staging_table
WHERE batch_date = CURRENT_DATE()
  AND batch_id   = <failed_batch_id>;

-- If using a transient / temp staging table, truncate and reload
TRUNCATE TABLE staging_table;
```

#### Step 5 — Verify Clean State Before Rerun

```sql
-- All three checks must return 0 before you trigger the rerun

-- Check 1: No partial data in target
SELECT COUNT(*) AS must_be_zero
FROM target_table
WHERE batch_id = <failed_batch_id>;

-- Check 2: No stale log entries
SELECT COUNT(*) AS must_be_zero
FROM etl_batch_log
WHERE batch_id = <failed_batch_id>
  AND status  != 'PENDING';

-- Check 3: No stale staging data
SELECT COUNT(*) AS must_be_zero
FROM staging_table
WHERE batch_id = <failed_batch_id>;
```

Only after all three return 0 → trigger the rerun.

---

## Phase 7 — Rerun the Job

### Option A — Rerun From Orchestration Tool (Most Common)

In Automic / Control-M:
```
1. Navigate to the failed job
2. Right-click → Restart / Rerun
3. Confirm the job restarts from the beginning (not mid-way)
4. Watch the first few steps complete successfully
```

In IICS:
```
1. Open the failed taskflow / mapping task
2. Click Run or Re-run
3. Monitor in Activity Monitor
```

### Option B — Manual Trigger From Snowflake (For Stored Procedures)

```sql
-- Trigger the procedure directly if IICS job is skipped
CALL SP_LOAD_FILES_TO_TARGET(
    'inbound/2026/06/07',   -- S3 folder path
    <new_batch_id>          -- Use a NEW batch ID for the rerun
);
```

### Option C — Rerun With a New Batch ID vs Same Batch ID

| Approach | When to Use | Risk |
|---|---|---|
| Same batch_id | Cleanup was complete, log table reset | Safe if cleanup verified |
| New batch_id | Original batch state is uncertain | Safest option for reruns |
| Time Travel rerun | Target table corrupted, need point-in-time restore | Use when partial data cannot be deleted cleanly |

---

## Phase 8 — Verify the Rerun Was Successful

Never close the incident without verifying every layer.

```sql
-- Verification Query 1: Batch completed with SUCCESS status
SELECT batch_id, status, failed_step, start_time, end_time,
       DATEDIFF('minute', start_time, end_time) AS duration_mins
FROM etl_batch_log
WHERE batch_id = <batch_id>
  AND batch_date = CURRENT_DATE();
-- Expected: status = 'SUCCESS', failed_step = NULL

-- Verification Query 2: All files / records loaded
SELECT status, COUNT(*) AS file_count
FROM etl_file_log
WHERE batch_id = <batch_id>
GROUP BY status;
-- Expected: one row — SUCCESS | <total file count>
-- No FAILED. No INPROGRESS.

-- Verification Query 3: Row count in target matches staging
SELECT
    'staging' AS layer, COUNT(*) AS row_count
FROM staging_table
WHERE batch_id = <batch_id>
UNION ALL
SELECT
    'target'  AS layer, COUNT(*) AS row_count
FROM target_table
WHERE batch_id = <batch_id>;
-- Both counts must match exactly

-- Verification Query 4: No duplicates in target
SELECT
    business_key,
    COUNT(*) AS row_count
FROM target_table
WHERE batch_id = <batch_id>
GROUP BY business_key
HAVING COUNT(*) > 1;
-- Must return 0 rows

-- Verification Query 5: Compare today vs yesterday (sanity check)
SELECT
    batch_date,
    COUNT(*)      AS total_rows,
    SUM(amount)   AS total_amount
FROM target_table
WHERE batch_date >= CURRENT_DATE() - 1
GROUP BY batch_date
ORDER BY batch_date;
-- Today's numbers should be in expected range vs yesterday
-- A 10x spike or 0 rows both indicate a problem
```

---

## Phase 9 — Unblock Downstream Jobs and Notify

After all verification queries pass:

### Release Downstream Jobs

```
In Automic / Control-M:
1. Navigate to the held downstream jobs
2. Force-start or release the dependency hold
   OR they auto-trigger when the upstream job status flips to SUCCESS

Jobs to release in sequence:
  JOB_TRANSFORM_SALES    → run and verify
  JOB_LOAD_DATAMART      → run and verify
  JOB_REFRESH_DASHBOARD  → run and verify
```

### Notify Stakeholders

```
Email / Slack to data consumers:

Subject: [RESOLVED] ETL Pipeline Delay — Sales Data Now Available

The ETL pipeline for today's sales data experienced a delay due to
[brief root cause — e.g. "a data format issue in the source files"].

Status    : RESOLVED
Impact    : Sales dashboard data was delayed by [X] hours
Data as of: [timestamp of successful load]
Action    : No action required. Dashboard now reflects current data.

If you notice any data discrepancies, please contact the data team.
```

---

## Phase 10 — Post Incident Review

Every production failure must result in a documented review and a prevention action.
Do not close the incident without completing this.

### Incident Report Template

```
INCIDENT REPORT
===============
Date            : 2026-06-07
Job Name        : JOB_EXTRACT_SALES
Batch ID        : 100023
Failed Step     : STEP_2_INTEGRITY_CHECK
Time Detected   : 08:15 AM
Time Resolved   : 10:42 AM
Total Downtime  : 2 hours 27 minutes

ROOT CAUSE:
Source system sent date values in MM/DD/YYYY format instead of YYYYMMDD.
This was caused by a source system configuration change deployed on 2026-06-06
without prior notification to the data team.

IMPACT:
- Sales dashboard showed stale data for 2.5 hours
- 3 downstream jobs were blocked
- 47 end users affected

FIX APPLIED:
- Corrected 4 bad rows directly in staging table
- Confirmed with source team that format will revert to YYYYMMDD
- Reran the pipeline successfully at 10:40 AM
- Verified all 200 files loaded with correct row counts

PREVENTION ACTIONS:
1. Add schema change notification process with source system team
2. Add pre-validation step to detect date format before loading
3. Add automated alert if row count drops more than 20% vs previous day
4. Document expected file format in a data contract shared with source team
```

### Prevention Actions by Root Cause

| Root Cause | Prevention Action |
|---|---|
| Source schema changed without notice | Establish data contract / schema change notification SLA with source team |
| Credentials expired | Automated alert 30 days before credential expiry |
| Table accidentally dropped | Restrict DROP privilege to DBA only. Enable Time Travel retention. |
| Warehouse timeout | Set auto-scaling. Monitor query duration with alerts. |
| Duplicate trigger from scheduler | Idempotency guard: check if batch already INPROGRESS before starting |
| Lock contention | Stagger ETL job schedules. Avoid overlapping jobs on same target table. |
| No rows from source | Add row count check at extraction. Alert if 0 rows at 7 AM. |
| Silent partial load | Always stamp batch_id on every target row. Verify count post-load. |

---

## Complete Debug Flow — One Page Reference

```
ALERT: Pipeline Failed
    │
    ├── 1. UNDERSTAND BLAST RADIUS
    │         Which downstream jobs are blocked?
    │         Which dashboards / users are impacted?
    │
    ├── 2. COLLECT INFORMATION
    │         Job name, error message, failure time, which step
    │
    ├── 3. IDENTIFY FAILURE LAYER
    │         Infrastructure → connectivity, credentials, warehouse
    │         Extraction     → schema change, file not delivered, 0 rows
    │         Transformation → data type, duplicates, NULLs, timeout
    │         Load           → table dropped, privilege, lock, constraint
    │
    ├── 4. ROOT CAUSE ANALYSIS
    │         Query Snowflake query history
    │         Query staging / log tables
    │         Check IICS / Automic job logs
    │
    ├── 5. FIX THE ISSUE
    │         Infrastructure → rotate creds / resume warehouse / restore table
    │         Data           → clean staging / ask source to resend
    │         Privilege      → DBA restores grant
    │         Lock           → cancel blocking session
    │
    ├── 6. IDEMPOTENCY CLEANUP
    │         Check for partial data in target
    │         DELETE partial rows scoped by batch_id
    │         Reset log table statuses
    │         Verify all counts = 0 before rerun
    │
    ├── 7. RERUN
    │         From Automic / Control-M / IICS
    │         Or direct CALL if stored procedure
    │
    ├── 8. VERIFY
    │         Batch log → SUCCESS
    │         Row count → matches staging
    │         No duplicates → 0 rows with COUNT > 1
    │         Sanity check → today vs yesterday comparison
    │
    ├── 9. UNBLOCK DOWNSTREAM + NOTIFY END USERS
    │
    └── 10. POST INCIDENT REVIEW
              Root cause documented
              Prevention action assigned
              Incident report filed
```

---

## Why Idempotency Is Non-Negotiable in Production

| Without Idempotency | With Idempotency |
|---|---|
| Rerun inserts duplicate rows | Rerun produces identical result as first run |
| Dashboard shows doubled revenue | Dashboard shows correct revenue |
| Reconciliation fails | Reconciliation passes |
| Manual data correction needed | No correction needed |
| End users lose trust in data | End users trust the data |

The single design decision that enables idempotency is **stamping every target row
with a batch_id** and using that batch_id to scope all DELETE and verification
queries. Without batch_id on the target row, you cannot safely delete partial
data without risking deletion of data from other good batches.
