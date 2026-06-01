# Snowpipe: Complete Setup & Debugging Guide

> Step-by-step: Creating external stage, file format, target table, pipe, configuring auto-ingest, loading data, and debugging failures.

---

## Table of Contents

1. [What is Snowpipe?](#1-what-is-snowpipe)
2. [Complete Setup: Step by Step](#2-complete-setup-step-by-step)
3. [Full Architecture Diagram](#3-full-architecture-diagram)
4. [Manual File Loading](#4-manual-file-loading)
5. [Snowpipe Debugging: When Things Go Wrong](#5-snowpipe-debugging-when-things-go-wrong)
6. [Common Failures and Fixes](#6-common-failures-and-fixes)
7. [Debugging Decision Tree](#7-debugging-decision-tree)
8. [Monitoring Snowpipe in Production](#8-monitoring-snowpipe-in-production)
9. [Best Practices](#9-snowpipe-best-practices)
10. [Snowpipe vs COPY INTO vs Streaming](#10-snowpipe-vs-copy-into-vs-snowpipe-streaming)
11. [Interview Questions](#11-interview-questions)

---

## 1. What is Snowpipe?

Snowpipe = Snowflake's **continuous, serverless data loading service**. It automatically loads files from a cloud stage into a table AS SOON AS new files arrive (triggered by cloud event notifications).

### Key Characteristics

- **Serverless** — no warehouse needed for loading
- **Event-driven** — S3 notification, Azure Event Grid, GCS Pub/Sub
- **Near real-time** — files loaded within 30 seconds to a few minutes
- **Pay per use** — billed per file/second of compute, not per warehouse credit
- **Exactly-once** file processing — tracks which files were loaded

### Flow

```
File lands in S3 → S3 sends SQS notification → Snowpipe picks up file
→ Snowpipe loads into table → File marked as loaded (won't reload)
```

---

## 2. Complete Setup: Step by Step

### Step 1: Create Database and Table

```sql
CREATE DATABASE IF NOT EXISTS SNOWPIPE_DEMO;
CREATE SCHEMA IF NOT EXISTS SNOWPIPE_DEMO.RAW;

CREATE OR REPLACE TABLE SNOWPIPE_DEMO.RAW.ORDERS (
    ORDER_ID INT,
    CUSTOMER_ID INT,
    ORDER_DATE DATE,
    AMOUNT DECIMAL(10,2),
    STATUS VARCHAR(20),
    CREATED_AT TIMESTAMP_NTZ
);
```

### Step 2: Create File Format

```sql
-- FOR CSV:
CREATE OR REPLACE FILE FORMAT SNOWPIPE_DEMO.RAW.CSV_FORMAT
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    NULL_IF = ('NULL', 'null', '')
    EMPTY_FIELD_AS_NULL = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- FOR JSON:
CREATE OR REPLACE FILE FORMAT SNOWPIPE_DEMO.RAW.JSON_FORMAT
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    STRIP_NULL_VALUES = FALSE;

-- FOR PARQUET:
CREATE OR REPLACE FILE FORMAT SNOWPIPE_DEMO.RAW.PARQUET_FORMAT
    TYPE = 'PARQUET';
```

### Step 3: Create Storage Integration (One-time setup by ACCOUNTADMIN)

This grants Snowflake permission to access your S3 bucket securely. Uses IAM role (not access keys) — the secure, production way.

```sql
CREATE OR REPLACE STORAGE INTEGRATION S3_INTEGRATION
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-access-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://my-data-bucket/incoming/');

-- After creating, get the AWS IAM details Snowflake needs:
DESC INTEGRATION S3_INTEGRATION;
-- Note: STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
-- Use these to configure the TRUST POLICY on your AWS IAM role.

-- GRANT USAGE to the role that will create stages:
GRANT USAGE ON INTEGRATION S3_INTEGRATION TO ROLE SYSADMIN;
```

### Step 4: Create External Stage

```sql
CREATE OR REPLACE STAGE SNOWPIPE_DEMO.RAW.ORDERS_STAGE
    STORAGE_INTEGRATION = S3_INTEGRATION
    URL = 's3://my-data-bucket/incoming/orders/'
    FILE_FORMAT = SNOWPIPE_DEMO.RAW.CSV_FORMAT;

-- Verify: List files in the stage
LIST @SNOWPIPE_DEMO.RAW.ORDERS_STAGE;

-- Test: Manually load a file to verify stage works
COPY INTO SNOWPIPE_DEMO.RAW.ORDERS
FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE
FILE_FORMAT = SNOWPIPE_DEMO.RAW.CSV_FORMAT;
```

### Step 5: Create the Pipe (Snowpipe Definition)

`AUTO_INGEST = TRUE` means it listens for cloud event notifications.

```sql
CREATE OR REPLACE PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE
    AUTO_INGEST = TRUE
AS
COPY INTO SNOWPIPE_DEMO.RAW.ORDERS
FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE
FILE_FORMAT = SNOWPIPE_DEMO.RAW.CSV_FORMAT
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Get the SQS queue ARN (needed for S3 event notification setup):
SHOW PIPES LIKE 'ORDERS_PIPE' IN SCHEMA SNOWPIPE_DEMO.RAW;
-- Note the 'notification_channel' column → this is the SQS ARN
```

**Alternative: Pipe with transformations:**

```sql
CREATE OR REPLACE PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE_V2
    AUTO_INGEST = TRUE
AS
COPY INTO SNOWPIPE_DEMO.RAW.ORDERS (ORDER_ID, CUSTOMER_ID, ORDER_DATE, AMOUNT, STATUS, CREATED_AT)
FROM (
    SELECT
        $1::INT AS ORDER_ID,
        $2::INT AS CUSTOMER_ID,
        $3::DATE AS ORDER_DATE,
        $4::DECIMAL(10,2) AS AMOUNT,
        $5::VARCHAR AS STATUS,
        $6::TIMESTAMP_NTZ AS CREATED_AT
    FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE
)
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

### Step 6: Configure S3 Event Notification

This tells S3: "When a new file arrives, notify Snowflake's SQS queue."

**Option A: AWS Console**
1. Go to S3 bucket → Properties → Event notifications
2. Create event notification:
   - **Name:** snowpipe-orders-notification
   - **Prefix:** `incoming/orders/` (match your stage path)
   - **Suffix:** `.csv` (or .json, .parquet)
   - **Event types:** `s3:ObjectCreated:*` (All object create events)
   - **Destination:** SQS queue
   - **SQS ARN:** (paste the notification_channel from SHOW PIPES)

**Option B: AWS CLI**
```bash
aws s3api put-bucket-notification-configuration \
  --bucket my-data-bucket \
  --notification-configuration '{
    "QueueConfigurations": [{
      "QueueArn": "arn:aws:sqs:us-east-1:123456789012:sf-snowpipe-...",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "prefix", "Value": "incoming/orders/"},
            {"Name": "suffix", "Value": ".csv"}
          ]
        }
      }
    }]
  }'
```

**Option C: Terraform (Production recommended)**
```hcl
resource "aws_s3_bucket_notification" "snowpipe" {
  bucket = aws_s3_bucket.data.id
  queue {
    queue_arn     = "arn:aws:sqs:us-east-1:..."
    events       = ["s3:ObjectCreated:*"]
    filter_prefix = "incoming/orders/"
    filter_suffix = ".csv"
  }
}
```

### Step 7: Verify Snowpipe is Working

```sql
-- Check pipe status:
SELECT SYSTEM$PIPE_STATUS('SNOWPIPE_DEMO.RAW.ORDERS_PIPE');
-- Returns JSON: {"executionState":"RUNNING","pendingFileCount":0}
-- RUNNING = pipe is active and listening
-- pendingFileCount > 0 = files waiting to be loaded

-- Check if pipe is paused or running:
SHOW PIPES LIKE 'ORDERS_PIPE' IN SCHEMA SNOWPIPE_DEMO.RAW;

-- Resume pipe if paused:
ALTER PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE SET PIPE_EXECUTION_PAUSED = FALSE;

-- Pause pipe (for maintenance):
ALTER PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE SET PIPE_EXECUTION_PAUSED = TRUE;
```

### Step 8: Verify Data is Loading

```sql
-- Check data in target table:
SELECT COUNT(*) FROM SNOWPIPE_DEMO.RAW.ORDERS;
SELECT * FROM SNOWPIPE_DEMO.RAW.ORDERS LIMIT 10;

-- Check pipe load history (last 24 hours):
SELECT *
FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('HOUR', -24, CURRENT_TIMESTAMP()),
    PIPE_NAME => 'SNOWPIPE_DEMO.RAW.ORDERS_PIPE'
));

-- Check COPY history for this table:
SELECT
    FILE_NAME,
    STATUS,
    ROWS_PARSED,
    ROWS_LOADED,
    ERROR_COUNT,
    FIRST_ERROR_MESSAGE,
    LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SNOWPIPE_DEMO.RAW.ORDERS',
    START_TIME => DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;
```

---

## 3. Full Architecture Diagram

```
┌──────────────┐    ┌────────────────┐    ┌──────────────┐    ┌───────────┐
│ Data Source  │───→│  S3 Bucket     │───→│  SQS Queue   │───→│ Snowpipe  │
│ (App/ETL)   │    │ /incoming/     │    │ (Auto-notif) │    │ (Loads)   │
└──────────────┘    └────────────────┘    └──────────────┘    └─────┬─────┘
                                                                    │
                                                                    ▼
                                                             ┌───────────┐
                                                             │ Snowflake │
                                                             │  Table    │
                                                             └───────────┘
```

**Timing:**
- File lands in S3 → SQS notification (< 1 second) → Snowpipe picks up (10-60 seconds) → File loaded → Data queryable
- **TOTAL: 30 seconds to 2 minutes end-to-end**

---

## 4. Manual File Loading

Without auto-ingest, for testing/backfill:

```sql
-- Manually trigger Snowpipe to load specific files:
ALTER PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE REFRESH;
-- This scans the stage and loads any files not yet loaded.

-- Refresh with specific path prefix:
ALTER PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE REFRESH
    PREFIX = 'orders/2024/06/';
-- Only loads files under that prefix.

-- Load files from a specific time range:
ALTER PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE REFRESH
    PREFIX = 'orders/'
    MODIFIED_AFTER = '2024-06-01T00:00:00Z';
```

---

## 5. Snowpipe Debugging: When Things Go Wrong

### 5.1 Debug Method 1: Check Pipe Status

```sql
SELECT SYSTEM$PIPE_STATUS('SNOWPIPE_DEMO.RAW.ORDERS_PIPE');
```

**Possible States:**
| Key | Value | Meaning |
|-----|-------|---------|
| `executionState` | `RUNNING` | Pipe is active and processing |
| `executionState` | `PAUSED` | Pipe is paused (resume it) |
| `executionState` | `STALLED` | Pipe is stuck (check permissions) |
| `pendingFileCount` | `0` | No files waiting (good or bad) |
| `pendingFileCount` | `500` | Backlog (pipe is behind) |
| `notificationChannelName` | `arn:...` | SQS ARN (verify in AWS) |

```sql
-- IF PAUSED:
ALTER PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE SET PIPE_EXECUTION_PAUSED = FALSE;
```

### 5.2 Debug Method 2: Check COPY History (Most Useful for Errors)

```sql
SELECT
    PIPE_NAME,
    FILE_NAME,
    STAGE_LOCATION,
    STATUS,
    ROWS_PARSED,
    ROWS_LOADED,
    ERROR_COUNT,
    FIRST_ERROR_MESSAGE,
    FIRST_ERROR_LINE_NUM,
    FIRST_ERROR_COLUMN_NAME,
    LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SNOWPIPE_DEMO.RAW.ORDERS',
    START_TIME => DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;
```

**STATUS Values:**

| Status | Meaning |
|--------|---------|
| `Loaded` | File loaded successfully |
| `LoadFailed` | File completely failed (check FIRST_ERROR_MESSAGE) |
| `PartiallyLoaded` | Some rows loaded, some rejected |
| `LoadInProgress` | Currently loading |

**Common Errors:**

| Error Message | Cause |
|---------------|-------|
| "Number of columns in file does not match" | Schema mismatch |
| "Numeric value 'abc' is not recognized" | Data type error |
| "NULL result in a non-nullable column" | NOT NULL violation |
| "String is too long and would be truncated" | VARCHAR too short |

### 5.3 Debug Method 3: Validate Files Before Loading

```sql
-- Dry-run: Check for errors WITHOUT actually loading:
COPY INTO SNOWPIPE_DEMO.RAW.ORDERS
FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE/problematic_file.csv
FILE_FORMAT = SNOWPIPE_DEMO.RAW.CSV_FORMAT
VALIDATION_MODE = 'RETURN_ALL_ERRORS';

-- Check just first N rows:
COPY INTO SNOWPIPE_DEMO.RAW.ORDERS
FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE/problematic_file.csv
FILE_FORMAT = SNOWPIPE_DEMO.RAW.CSV_FORMAT
VALIDATION_MODE = 'RETURN_10_ROWS';
```

### 5.4 Debug Method 4: Check Notification Channel

```sql
SHOW PIPES LIKE 'ORDERS_PIPE' IN SCHEMA SNOWPIPE_DEMO.RAW;
-- Look at 'notification_channel' column → this must match your S3 notification config.
```

**Common Issues:**
- S3 notification points to WRONG SQS queue → verify ARN matches
- SQS queue policy doesn't allow S3 to send messages → add S3 service principal to SQS access policy

### 5.5 Debug Method 5: Check If File Was Already Loaded

Snowpipe tracks loaded files. It WON'T reload a file it's already seen.

```sql
-- Option A: Use FORCE = TRUE (loads file even if already loaded)
-- WARNING: Creates duplicates!
COPY INTO SNOWPIPE_DEMO.RAW.ORDERS
FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE/orders_2024_06_01.csv
FILE_FORMAT = SNOWPIPE_DEMO.RAW.CSV_FORMAT
FORCE = TRUE;

-- Option B: Rename/re-upload the file with a different name → Snowpipe sees it as new.

-- Option C: Recreate the pipe (resets load history — DANGEROUS)
-- Only if you also TRUNCATE the table first (otherwise duplicates).
```

### 5.6 Debug Method 6: ACCOUNT_USAGE Views (Historical, up to 365 days)

```sql
-- Load history across all pipes:
SELECT
    PIPE_NAME,
    FILE_NAME,
    PIPE_RECEIVED_TIME,
    FILE_SIZE,
    ROWS_INSERTED,
    ROWS_PARSED,
    FIRST_ERROR_MESSAGE,
    ERROR_COUNT
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE PIPE_NAME = 'ORDERS_PIPE'
    AND LAST_LOAD_TIME > DATEADD('DAY', -7, CURRENT_TIMESTAMP())
ORDER BY LAST_LOAD_TIME DESC;

-- Pipe usage (costs):
SELECT
    PIPE_NAME,
    START_TIME,
    END_TIME,
    CREDITS_USED,
    BYTES_INSERTED,
    FILES_INSERTED
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE PIPE_NAME = 'ORDERS_PIPE'
    AND START_TIME > DATEADD('DAY', -7, CURRENT_TIMESTAMP())
ORDER BY START_TIME DESC;
```

### 5.7 Debug Method 7: Check Stage Files Directly

```sql
-- List files in stage:
LIST @SNOWPIPE_DEMO.RAW.ORDERS_STAGE;

-- Check file content (preview):
SELECT $1, $2, $3, $4, $5, $6
FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE/orders_sample.csv
(FILE_FORMAT => SNOWPIPE_DEMO.RAW.CSV_FORMAT)
LIMIT 5;

-- Check if file is valid Parquet:
SELECT *
FROM @SNOWPIPE_DEMO.RAW.ORDERS_STAGE/orders_sample.parquet
(FILE_FORMAT => SNOWPIPE_DEMO.RAW.PARQUET_FORMAT)
LIMIT 5;
```

---

## 6. Common Failures and Fixes

| # | Symptom | Root Cause & Fix |
|---|---------|-----------------|
| 1 | Files land in S3 but never load | S3 event notification not set up or points to wrong SQS queue. **FIX:** Verify notification_channel matches S3 event config. |
| 2 | Pipe status = PAUSED | Pipe was paused manually or due to errors exceeding threshold. **FIX:** `ALTER PIPE ... SET PIPE_EXECUTION_PAUSED = FALSE;` |
| 3 | COPY_HISTORY shows 'LoadFailed' with "column count mismatch" | Data format doesn't match file format definition. **FIX:** Check SKIP_HEADER, delimiter, and column count. |
| 4 | COPY_HISTORY shows 'LoadFailed' with "not recognized" error | Data type error (e.g., 'abc' in a NUMBER column). **FIX:** Fix source data or change column to VARCHAR. |
| 5 | File loaded but 0 rows inserted | File is empty or SKIP_HEADER skips the only row. **FIX:** Check file content. Verify SKIP_HEADER setting. |
| 6 | Same file loaded multiple times (duplicates) | S3 notification sent multiple times or FORCE=TRUE used. **FIX:** Snowpipe deduplicates by default. If FORCE was used, dedup manually. |
| 7 | Pipe STALLED, notifications pile up | Permission issue. Snowflake can't access stage or table. **FIX:** Check STORAGE INTEGRATION IAM role trust policy. |
| 8 | High latency (files take > 5 min) | Large backlog or very large files. **FIX:** Split large files into smaller chunks (100-250 MB each). |
| 9 | "Pipe definition has changed" | Someone altered the pipe's COPY statement. Old files may re-load. **FIX:** Recreate pipe carefully. May need to backfill. |
| 10 | Costs are higher than expected | Too many tiny files (each file has overhead). Or pipe processes same files repeatedly. **FIX:** Batch files (1 file/min not 1 file/second). Optimal: 100-250 MB per file. |

---

## 7. Debugging Decision Tree

**Q: Files arrive in S3 but data doesn't appear in Snowflake.**

```
STEP 1: Is the pipe RUNNING?
  → SELECT SYSTEM$PIPE_STATUS('pipe_name');
  → If PAUSED → resume it
  → If STALLED → check permissions

STEP 2: Is the notification configured?
  → SHOW PIPES → get notification_channel
  → Check S3 bucket → Properties → Event notifications → Does ARN match?
  → If no notification → set it up

STEP 3: Are files being received?
  → Check COPY_HISTORY → are there ANY records for this table?
  → If YES → pipe is receiving files (go to Step 4)
  → If NO → notification is broken (fix S3 → SQS connection)

STEP 4: Are files loading successfully?
  → Check STATUS column in COPY_HISTORY
  → If 'Loaded' → data should be in table (check table)
  → If 'LoadFailed' → read FIRST_ERROR_MESSAGE → fix data format
  → If 'PartiallyLoaded' → some rows bad → check errors

STEP 5: Is the file format correct?
  → SELECT $1, $2 FROM @stage/file.csv LIMIT 5
  → Does it look right? Columns aligned?
  → Try VALIDATION_MODE = 'RETURN_ALL_ERRORS' to see what fails
```

---

## 8. Monitoring Snowpipe in Production

### 8.1 Alert if No Files Loaded in Last 2 Hours

```sql
CREATE OR REPLACE TASK SNOWPIPE_DEMO.RAW.MONITOR_PIPE_FRESHNESS
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '60 MINUTE'
AS
BEGIN
    LET last_load TIMESTAMP_NTZ;
    SELECT MAX(LAST_LOAD_TIME) INTO :last_load
    FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
        TABLE_NAME => 'SNOWPIPE_DEMO.RAW.ORDERS',
        START_TIME => DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
    ));
    
    IF (:last_load IS NULL OR DATEDIFF('HOUR', :last_load, CURRENT_TIMESTAMP()) > 2) THEN
        CALL SYSTEM$SEND_EMAIL(
            'MY_EMAIL_INT',
            'data-team@company.com',
            'Snowpipe Alert: No data loaded in 2+ hours',
            'Table: ORDERS. Last load: ' || COALESCE(:last_load::VARCHAR, 'NEVER')
        );
    END IF;
END;
```

### 8.2 Daily Cost Report

```sql
SELECT
    PIPE_NAME,
    DATE_TRUNC('DAY', START_TIME) AS DAY,
    SUM(CREDITS_USED) AS TOTAL_CREDITS,
    SUM(FILES_INSERTED) AS TOTAL_FILES,
    SUM(BYTES_INSERTED) / (1024*1024*1024) AS TOTAL_GB
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE START_TIME > DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY PIPE_NAME, DAY
ORDER BY DAY DESC;
```

### 8.3 Error Rate Monitoring

```sql
SELECT
    DATE_TRUNC('HOUR', LAST_LOAD_TIME) AS HOUR,
    COUNT(*) AS TOTAL_FILES,
    SUM(CASE WHEN STATUS = 'Loaded' THEN 1 ELSE 0 END) AS SUCCESS,
    SUM(CASE WHEN STATUS = 'LoadFailed' THEN 1 ELSE 0 END) AS FAILED,
    ROUND(SUM(CASE WHEN STATUS = 'LoadFailed' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS ERROR_RATE_PCT
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SNOWPIPE_DEMO.RAW.ORDERS',
    START_TIME => DATEADD('DAY', -7, CURRENT_TIMESTAMP())
))
GROUP BY HOUR
ORDER BY HOUR DESC;
```

---

## 9. Snowpipe Best Practices

### File Size
- **Optimal:** 100-250 MB compressed per file
- **Bad:** Thousands of tiny files (< 1 MB each) = high overhead
- **Bad:** Huge files (> 1 GB) = longer load time per file

### File Format
- Use Parquet or compressed CSV for best performance
- Always define file format explicitly (don't rely on defaults)
- Include headers in CSV for MATCH_BY_COLUMN_NAME

### Naming
- Use date-partitioned paths: `s3://bucket/orders/2024/06/01/file.parquet`
- Use unique file names (include timestamp or UUID)
- Don't overwrite files (Snowpipe tracks by file name)

### Monitoring
- Check COPY_HISTORY daily for errors
- Monitor PIPE_USAGE_HISTORY for cost spikes
- Alert on staleness (no loads in X hours)
- Alert on high error rate (> 5% failures)

### Security
- Use STORAGE INTEGRATION (not raw credentials)
- Least-privilege IAM role (read-only on specific prefix)
- Separate pipe per data domain (don't mix sensitive data)

---

## 10. Snowpipe vs COPY INTO vs Snowpipe Streaming

| Aspect | Snowpipe | COPY INTO | Streaming |
|--------|----------|-----------|-----------|
| Trigger | Event (auto) | Manual/scheduled | Continuous (SDK) |
| Latency | 30s - minutes | When you run it | ~5 seconds |
| Data format | Files | Files | Rows |
| Compute | Serverless | Warehouse needed | Serverless |
| Cost model | Per-file compute | Warehouse credits | Per-GB |
| Ordering | Not guaranteed | Not guaranteed | Guaranteed |
| Exactly-once | By file name | Manual (FORCE) | Offset tokens |
| Best for | Continuous file auto-loading | Batch/one-time bulk loads | Real-time rows from Kafka/SDK |

---

## 11. Interview Questions

**Q1: What is Snowpipe?**
> Serverless, continuous data loading service that automatically loads files from cloud stages into Snowflake tables when new files arrive.

**Q2: How does auto-ingest work?**
> S3 sends event notification to an SQS queue (created by Snowflake). Snowpipe listens on that queue and loads files as notifications arrive.

**Q3: What's the difference between Snowpipe and COPY INTO?**
> Snowpipe is event-driven (auto), serverless, per-file billing. COPY INTO is manual/scheduled, needs a warehouse, batch-oriented.

**Q4: How do you debug a Snowpipe that's not loading data?**
> 1. `SYSTEM$PIPE_STATUS` (is it running?)
> 2. `SHOW PIPES` (get notification_channel ARN)
> 3. Verify S3 event notification config matches ARN
> 4. Check COPY_HISTORY for errors
> 5. VALIDATION_MODE to test file format
> 6. `LIST @stage` to verify files exist

**Q5: What happens if a file has errors?**
> Depends on configuration. Default: file fails, error logged in COPY_HISTORY. File won't be retried unless you fix and re-upload with new name.

**Q6: Can Snowpipe reload a file it already loaded?**
> No (by default). Snowpipe tracks loaded files by path+name for 14 days. To reload: rename file, or use COPY INTO with FORCE=TRUE (manually).

**Q7: How do you handle late-arriving or out-of-order files?**
> Snowpipe loads in arrival order, not file name order. Downstream models should handle out-of-order with incremental logic (lookback window or MERGE).

**Q8: What's the ideal file size for Snowpipe?**
> 100-250 MB compressed. Avoids tiny-file overhead and large-file delays.

**Q9: How do you monitor Snowpipe in production?**
> SYSTEM$PIPE_STATUS (real-time), COPY_HISTORY (load details), PIPE_USAGE_HISTORY (costs), custom tasks for staleness alerts.

**Q10: How do you backfill historical files through Snowpipe?**
> `ALTER PIPE ... REFRESH PREFIX='path/' MODIFIED_AFTER='timestamp';` — This scans the stage for files not yet loaded and queues them.

---

## Cleanup

```sql
DROP PIPE SNOWPIPE_DEMO.RAW.ORDERS_PIPE;
DROP STAGE SNOWPIPE_DEMO.RAW.ORDERS_STAGE;
DROP TABLE SNOWPIPE_DEMO.RAW.ORDERS;
DROP DATABASE SNOWPIPE_DEMO;
```
