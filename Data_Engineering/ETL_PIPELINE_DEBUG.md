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















----------------------------------------------#####Second Scenario-------------------------------------------------------------

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
