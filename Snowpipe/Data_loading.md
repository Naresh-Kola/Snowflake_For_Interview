# Data Loading from S3 into Snowflake — Complete Guide (Beginner to Architect)

---

## Table of Contents

1. [Data Loading Methods Overview](#data-loading-methods-overview)
2. [Prerequisites: S3 Access Setup](#prerequisites-s3-access-setup)
3. [Method 1: COPY INTO (Bulk Loading)](#method-1-copy-into-bulk-loading)
4. [Method 2: Snowpipe (Continuous Auto-Ingest)](#method-2-snowpipe-continuous-auto-ingest)
5. [Method 3: Snowpipe Streaming](#method-3-snowpipe-streaming)
6. [Method 4: External Tables (Query-in-Place)](#method-4-external-tables-query-in-place)
7. [Common Issues & Debugging](#common-issues--debugging)
8. [Debugging Tools & Commands](#debugging-tools--commands)
9. [File Format Issues](#file-format-issues)
10. [Performance Optimization](#performance-optimization)
11. [Architecture Patterns](#architecture-patterns)
12. [Interview Questions: Beginner to Architect](#interview-questions-beginner-to-architect)

---

## Data Loading Methods Overview

| Method | Type | Latency | Best For | Billing |
|--------|------|---------|----------|---------|
| COPY INTO | Batch/Bulk | Minutes | Scheduled bulk loads, large datasets | User warehouse |
| Snowpipe (Auto-Ingest) | Continuous | ~1 minute | Near-real-time event-driven loads | Serverless (per-file) |
| Snowpipe Streaming | Real-time | Seconds | Sub-second latency requirements | Serverless |
| External Tables | Query-in-place | N/A | Ad-hoc exploration without loading | Query warehouse |

---

## Prerequisites: S3 Access Setup

### Option A: Storage Integration (Recommended)

```sql
-- Step 1: Create storage integration
CREATE OR REPLACE STORAGE INTEGRATION s3_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake_role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://my-bucket/data/');

-- Step 2: Get Snowflake's IAM user ARN and External ID
DESC INTEGRATION s3_int;
-- Note: STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID

-- Step 3: Update AWS IAM Role trust policy with these values
-- (Done in AWS Console)

-- Step 4: Validate the integration
SELECT SYSTEM$VALIDATE_STORAGE_INTEGRATION('s3_int');
```

### Option B: Direct Credentials (Not Recommended for Production)

```sql
-- Inline credentials (avoid in production — secrets exposed in query history)
COPY INTO my_table
FROM 's3://my-bucket/data/'
CREDENTIALS = (AWS_KEY_ID='AKIA...' AWS_SECRET_KEY='wJalr...');
```

### AWS IAM Policy Required for Snowflake

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::my-bucket/data/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::my-bucket",
      "Condition": { "StringLike": { "s3:prefix": ["data/*"] } }
    }
  ]
}
```

---

## Method 1: COPY INTO (Bulk Loading)

### Basic Workflow

```sql
-- Step 1: Create file format
CREATE OR REPLACE FILE FORMAT my_csv_format
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  NULL_IF = ('NULL', 'null', '')
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

-- Step 2: Create external stage
CREATE OR REPLACE STAGE my_s3_stage
  URL = 's3://my-bucket/data/'
  STORAGE_INTEGRATION = s3_int
  FILE_FORMAT = my_csv_format;

-- Step 3: List files on stage (verify access)
LIST @my_s3_stage;

-- Step 4: Load data
COPY INTO my_table
  FROM @my_s3_stage
  PATTERN = '.*[.]csv'
  ON_ERROR = 'CONTINUE';
```

### ON_ERROR Options

| Value | Behavior | Use Case |
|-------|----------|----------|
| `ABORT_STATEMENT` (default) | Stop entire load on first error | Clean data, zero tolerance |
| `CONTINUE` | Skip bad rows, load good ones | Dirty data, want partial load |
| `SKIP_FILE` | Skip entire file on any error | File-level quality control |
| `SKIP_FILE_10` | Skip file if ≥ 10 errors | Tolerance threshold |
| `'SKIP_FILE_5%'` | Skip file if > 5% rows are bad | Percentage-based threshold |

### VALIDATION_MODE (Dry Run)

```sql
-- Validate without loading — find all errors
COPY INTO my_table
  FROM @my_s3_stage
  VALIDATION_MODE = 'RETURN_ALL_ERRORS';

-- Validate first N rows
COPY INTO my_table
  FROM @my_s3_stage
  VALIDATION_MODE = 'RETURN_10_ROWS';
```

---

## Method 2: Snowpipe (Continuous Auto-Ingest)

### Setup

```sql
-- Step 1: Create pipe with auto-ingest
CREATE OR REPLACE PIPE my_pipe
  AUTO_INGEST = TRUE
AS
  COPY INTO my_table
    FROM @my_s3_stage
    FILE_FORMAT = my_csv_format;

-- Step 2: Get SQS queue ARN
SHOW PIPES;
-- Note the "notification_channel" column value

-- Step 3: Configure S3 Event Notification in AWS Console:
--   Event type: s3:ObjectCreated:* (All object create events)
--   Destination: SQS Queue → paste the ARN from step 2
```

### Monitoring Snowpipe

```sql
-- Check pipe status
SELECT SYSTEM$PIPE_STATUS('my_pipe');

-- Check recent load history
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
));

-- Validate failed files
SELECT * FROM TABLE(VALIDATE_PIPE_LOAD(
  PIPE_NAME => 'my_pipe',
  START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
));

-- Refresh pipe (load missed files)
ALTER PIPE my_pipe REFRESH;
```

---

## Method 3: Snowpipe Streaming

### When to Use
- Sub-second latency requirements
- Kafka → Snowflake pipelines
- IoT event ingestion
- Real-time dashboards

### Architecture
- Uses Snowflake Ingest SDK (Java)
- No file staging — rows sent directly via API
- Serverless compute (no warehouse needed)
- Exactly-once semantics with offset tokens

---

## Method 4: External Tables (Query-in-Place)

```sql
-- Query data in S3 without loading
CREATE OR REPLACE EXTERNAL TABLE ext_orders (
    order_id NUMBER AS (VALUE:c1::NUMBER),
    customer_name STRING AS (VALUE:c2::STRING),
    amount DECIMAL(10,2) AS (VALUE:c3::DECIMAL(10,2))
)
  LOCATION = @my_s3_stage
  FILE_FORMAT = my_csv_format
  AUTO_REFRESH = TRUE;

-- Query directly
SELECT * FROM ext_orders WHERE amount > 1000;
```

---

## Common Issues & Debugging

### Issue 1: "Access Denied" / Cannot Access S3

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Failure using stage area` | Invalid AWS credentials | Verify AWS_KEY_ID exists and is active |
| `Access Denied (403)` | Missing IAM permissions | Add s3:GetObject, s3:ListBucket to policy |
| `Integration not found` | Storage integration recreated | Run `ALTER STAGE my_stage SET STORAGE_INTEGRATION = s3_int` |
| `The bucket you are attempting to access must be addressed using the specified endpoint` | Wrong region | Update STORAGE_ALLOWED_LOCATIONS to match bucket region |

**Debugging Steps:**
```sql
-- 1. Check integration config
DESC INTEGRATION s3_int;

-- 2. Validate integration
SELECT SYSTEM$VALIDATE_STORAGE_INTEGRATION('s3_int');

-- 3. Check stage definition
DESC STAGE my_s3_stage;

-- 4. Test listing files
LIST @my_s3_stage;
```

### Issue 2: "Copy executed with 0 files processed"

| Cause | Fix |
|-------|-----|
| Files already loaded (dedup metadata) | Use `FORCE = TRUE` or wait 64 days |
| PATTERN doesn't match any files | Check regex with `LIST @stage` and adjust PATTERN |
| Path mismatch (stage path + COPY path) | Verify combined path matches file locations |
| Files are in archival storage class (Glacier) | Restore files from Glacier before loading |
| Table was truncated but metadata persists | Recreate the pipe or use `FORCE = TRUE` |

**Debugging Steps:**
```sql
-- Check what files Snowflake sees
LIST @my_s3_stage;

-- Check load history (was file already loaded?)
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(DAY, -14, CURRENT_TIMESTAMP())
))
WHERE FILE_NAME LIKE '%your_file%';
```

### Issue 3: Data Parsing Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `Field delimiter found while expecting record delimiter` | Extra commas in unquoted fields | Set `FIELD_OPTIONALLY_ENCLOSED_BY = '"'` |
| `Number of columns in file does not match` | Column count mismatch | Set `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` |
| `NULL result in a non-nullable column` | Empty field → NULL → NOT NULL column | Use `NULL_IF = ()` or make column nullable |
| `Numeric value is not recognized` | String in numeric column | Fix source data or use VARIANT |
| `Date does not match format` | Date format mismatch | Set `DATE_FORMAT = 'YYYY-MM-DD'` |
| `Invalid UTF-8 character` | Encoding issues | Set `REPLACE_INVALID_CHARACTERS = TRUE` or `ENCODING = 'WINDOWS1252'` |
| `String too long` | Data exceeds column VARCHAR length | Set `TRUNCATECOLUMNS = TRUE` or increase column size |

**Debugging Steps:**
```sql
-- Validate and see ALL errors
COPY INTO my_table FROM @my_s3_stage
  VALIDATION_MODE = 'RETURN_ALL_ERRORS';

-- After a failed load, check errors from last query
SELECT * FROM TABLE(VALIDATE(my_table, JOB_ID => '_last'));
```

### Issue 4: Snowpipe Not Loading Files

| Symptom | Cause | Fix |
|---------|-------|-----|
| `lastReceivedMessageTimestamp` is empty | S3 event notification misconfigured | Verify SQS ARN in S3 event settings |
| Messages received but not forwarded | Path mismatch between stage/pipe | Check `SHOW PIPES` definition vs actual file path |
| `executionState = PAUSED` | Pipe paused | `ALTER PIPE my_pipe SET PIPE_EXECUTION_PAUSED = FALSE` |
| Large files not loading | S3 multipart upload event missing | Set S3 event to "All object create events" |
| SNS subscription deleted | SQS disconnected from SNS | Wait 72 hours + recreate pipe |
| Non-safe characters in prefix | AWS doesn't send notification | URL-encode special characters (= → %3D) |

**Debugging Steps:**
```sql
-- Check pipe execution state
SELECT SYSTEM$PIPE_STATUS('my_pipe');

-- Check if file was processed
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP())
))
WHERE FILE_NAME LIKE '%expected_file%';

-- Force load missed files
ALTER PIPE my_pipe REFRESH;
```

### Issue 5: Duplicate Data

| Cause | Fix |
|-------|-----|
| Same file loaded via COPY INTO + Snowpipe | Use only ONE method per path |
| Overlapping pipe paths | Ensure no two pipes cover the same S3 prefix |
| File modified and re-uploaded within 14 days | Snowpipe ignores it; recreate pipe to reload |
| File re-uploaded after 14 days | Snowpipe reloads it (metadata expired); deduplicate downstream |
| FORCE = TRUE used incorrectly | Remove FORCE unless intentional reload |

### Issue 6: File Descriptor Limit Exceeded

**Error:** `Total size for the list of file descriptors exceeded limit (1,073,741,824 bytes)`

| Cause | Fix |
|-------|-----|
| Too many files in stage path | Add prefix: `@stage/year=2025/month=06/` |
| Long file names consuming limit | Shorten file names |
| Accumulated historical files | Purge loaded files or set up lifecycle rules |

**Best Practice:** Keep < 100K files per stage path. Use partitioned paths like `/year/month/day/`.

### Issue 7: Parquet 0-Byte File Error

**Error:** `Invalid: Parquet file size is 0 bytes`

| Cause | Fix |
|-------|-----|
| Tag/marker files created by Hive/Spark | Use PATTERN to exclude: `PATTERN = '.*[.]parquet'` excluding `_SUCCESS` files |
| Empty placeholder files | Delete 0-byte files from S3 |

---

## Debugging Tools & Commands

### Key Functions & Views

| Tool | Purpose | Retention |
|------|---------|-----------|
| `INFORMATION_SCHEMA.LOAD_HISTORY` | COPY INTO history (bulk only) | 14 days, 10K row limit |
| `INFORMATION_SCHEMA.COPY_HISTORY()` | COPY + Snowpipe history | 14 days, no row limit |
| `SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY` | Full load history | 365 days |
| `VALIDATE(table, JOB_ID)` | Errors from last COPY job | Until metadata expires (64 days) |
| `VALIDATE_PIPE_LOAD()` | Errors from Snowpipe loads | 14 days |
| `SYSTEM$PIPE_STATUS()` | Current pipe execution state | Real-time |
| `LIST @stage` | List files visible on stage | Real-time |

### Complete Debugging Workflow

```sql
-- ========================================
-- STEP 1: Verify Stage Access
-- ========================================
LIST @my_s3_stage;
-- If this fails → access/permission issue

-- ========================================
-- STEP 2: Validate Data (Dry Run)
-- ========================================
COPY INTO my_table FROM @my_s3_stage
  VALIDATION_MODE = 'RETURN_ALL_ERRORS';
-- Shows ALL parsing/type errors without loading

-- ========================================
-- STEP 3: Load with Error Handling
-- ========================================
COPY INTO my_table FROM @my_s3_stage
  ON_ERROR = 'CONTINUE'
  RETURN_FAILED_ONLY = TRUE;
-- Loads good rows, returns only failed files

-- ========================================
-- STEP 4: Check What Was Loaded
-- ========================================
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'MY_TABLE',
  START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
));

-- ========================================
-- STEP 5: Investigate Failures
-- ========================================
SELECT * FROM TABLE(VALIDATE(my_table, JOB_ID => '_last'));

-- ========================================
-- STEP 6: Check for Skipped Files (Dedup)
-- ========================================
-- If "0 files processed":
COPY INTO my_table FROM @my_s3_stage
  FORCE = TRUE  -- Bypass dedup (use cautiously)
  VALIDATION_MODE = 'RETURN_10_ROWS';
```

---

## File Format Issues

### CSV Gotchas

| Problem | Solution |
|---------|----------|
| Fields contain commas | Enclose in quotes: `FIELD_OPTIONALLY_ENCLOSED_BY = '"'` |
| Embedded newlines in fields | Set `MULTI_LINE = TRUE` (slower for large files) |
| Backslash at end of line escapes newline | Set `ESCAPE_UNENCLOSED_FIELD = NONE` |
| BOM character causing first column error | Set `SKIP_BYTE_ORDER_MARK = TRUE` (default) |
| Windows line endings (\\r\\n) | Handled automatically by Snowflake |
| Mixed encodings | Specify `ENCODING = 'WINDOWS1252'` or `'ISO88591'` |

### JSON Gotchas

| Problem | Solution |
|---------|----------|
| Array of objects at top level | Set `STRIP_OUTER_ARRAY = TRUE` |
| Multi-line JSON records | Set `MULTI_LINE = TRUE` (default for JSON) |
| Duplicate keys in objects | Set `ALLOW_DUPLICATE = TRUE` |
| Null values bloating storage | Set `STRIP_NULL_VALUES = TRUE` |

### Parquet Gotchas

| Problem | Solution |
|---------|----------|
| Binary columns read as text | Set `BINARY_AS_TEXT = FALSE` |
| Timestamps wrong timezone | Set `USE_LOGICAL_TYPE = TRUE` |
| Slow loading | Set `USE_VECTORIZED_SCANNER = TRUE` |
| Map types not parsing correctly | Set `USE_VECTORIZED_SCANNER = TRUE` |

---

## Performance Optimization

### File Sizing

| File Size | Impact | Recommendation |
|-----------|--------|----------------|
| < 10 MB | Too many files, high overhead | Aggregate into larger files |
| 100–250 MB (compressed) | Optimal | Target this range |
| > 5 GB | Single thread bottleneck | Split into smaller files |

### Parallelism

| Factor | Recommendation |
|--------|---------------|
| Warehouse size | Larger warehouse = more parallel file loads |
| Number of files | Multiple files loaded in parallel across nodes |
| File compression | Compressed files = less network, but can't split for parallel scan |
| Partitioning | Organize by `/year/month/day/` for targeted loading |

### Best Practices

```sql
-- 1. Use a named file format (reusable, auditable)
CREATE FILE FORMAT my_format TYPE = 'CSV' ...;

-- 2. Use PATTERN or FILES to limit scope
COPY INTO t FROM @stage PATTERN = '.*2025-06.*[.]csv';

-- 3. Purge after load (saves storage)
COPY INTO t FROM @stage PURGE = TRUE;

-- 4. Use MATCH_BY_COLUMN_NAME for schema flexibility
COPY INTO t FROM @stage
  FILE_FORMAT = (TYPE = 'PARQUET')
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- 5. Include metadata for lineage
COPY INTO t FROM @stage
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
  INCLUDE_METADATA = (
    source_file = METADATA$FILENAME,
    load_ts = METADATA$START_SCAN_TIME
  );
```

---

## Architecture Patterns

### Pattern 1: Simple Batch (Small Data, Scheduled)

```
S3 Bucket → External Stage → COPY INTO (via Task/Scheduler) → Table
```
- Best for: < 1 TB daily, scheduled ETL
- Cost: Only pay when warehouse runs

### Pattern 2: Event-Driven (Snowpipe)

```
S3 Bucket → S3 Event Notification → SQS Queue → Snowpipe → Table
```
- Best for: Continuous file drops, near-real-time
- Cost: Per-file serverless pricing

### Pattern 3: Fan-Out (SNS + Multiple Consumers)

```
S3 Bucket → S3 Event → SNS Topic → SQS (Snowpipe)
                                  → SQS (Lambda)
                                  → SQS (Other consumers)
```
- Best for: Multi-consumer architectures, replication

### Pattern 4: Landing Zone → Raw → Curated

```
S3 (Landing) → Snowpipe → RAW_DB.RAW_SCHEMA (VARIANT)
                         → Dynamic Table → CURATED_DB (typed columns)
                         → Dynamic Table → ANALYTICS_DB (aggregates)
```
- Best for: Enterprise data pipelines, medallion architecture

### Pattern 5: Schema Evolution Handling

```sql
-- Load JSON/Parquet into VARIANT column (schema-agnostic)
CREATE TABLE raw_events (
    src VARIANT,
    source_file STRING DEFAULT METADATA$FILENAME,
    loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Create views/dynamic tables for typed access
CREATE DYNAMIC TABLE typed_events (...)
  TARGET_LAG = '5 minutes'
  WAREHOUSE = transform_wh
AS
  SELECT
    src:event_id::INT AS event_id,
    src:event_type::STRING AS event_type,
    src:timestamp::TIMESTAMP AS event_ts
  FROM raw_events;
```

---

## Interview Questions: Beginner to Architect

### Beginner Level

**Q1: What are the different ways to load data from S3 into Snowflake?**
> COPY INTO (bulk), Snowpipe (continuous), Snowpipe Streaming (real-time), External Tables (query-in-place without loading).

**Q2: What is a Storage Integration and why use it?**
> A Snowflake object that stores an IAM user for S3 access. Avoids embedding credentials in SQL. More secure, manageable, and reusable across stages.

**Q3: What does `ON_ERROR = CONTINUE` do?**
> Skips bad rows and continues loading good rows. The FIRST_ERROR_MESSAGE in COPY_HISTORY shows what went wrong.

**Q4: How do you check if a file was already loaded?**
> Query `INFORMATION_SCHEMA.COPY_HISTORY()` or `SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY`. Snowflake tracks file metadata for 64 days to prevent duplicates.

**Q5: What is `VALIDATION_MODE`?**
> A dry-run option for COPY INTO that validates files without loading. Options: `RETURN_ERRORS`, `RETURN_ALL_ERRORS`, `RETURN_N_ROWS`.

### Intermediate Level

**Q6: Why does COPY show "0 files processed"?**
> File was already loaded (dedup), PATTERN doesn't match, path mismatch, or files are in Glacier. Use `FORCE = TRUE` to bypass dedup or check `LIST @stage`.

**Q7: How does Snowpipe auto-ingest work with S3?**
> S3 event notification → SQS queue (managed by Snowflake) → Snowpipe reads queue → loads files. The SQS ARN is found via `SHOW PIPES` in the `notification_channel` column.

**Q8: What's the difference between COPY_HISTORY and LOAD_HISTORY?**
> LOAD_HISTORY: only bulk COPY INTO, 10K row limit, 14 days. COPY_HISTORY: bulk + Snowpipe, no row limit, 14 days (Information Schema) or 365 days (Account Usage).

**Q9: How do you handle schema evolution in data loading?**
> Load into VARIANT column (schema-agnostic), use `MATCH_BY_COLUMN_NAME` for Parquet/JSON, or use `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` for CSV.

**Q10: What happens if you modify a file and re-upload to S3?**
> Within 14 days: Snowpipe ignores it (same filename = dedup). After 14 days: Snowpipe reloads it (metadata expired → potential duplicates). Fix: recreate pipe or deduplicate downstream.

### Advanced Level

**Q11: How would you debug a Snowpipe that suddenly stopped loading?**
> 1. `SYSTEM$PIPE_STATUS()` → check executionState, lastReceivedMessageTimestamp
> 2. If no messages received → check S3 event notification, SQS subscription
> 3. If messages received but not forwarded → path mismatch
> 4. Check COPY_HISTORY for errors
> 5. `ALTER PIPE REFRESH` for missed files

**Q12: How do you prevent duplicate loads across COPY INTO and Snowpipe?**
> Use only ONE method per stage path. COPY and Snowpipe have separate dedup metadata. If both run against the same files, duplicates will occur.

**Q13: What is the file descriptor limit and how do you work around it?**
> S3 listing is capped at 1 GB of file descriptor metadata. Fix: partition files into subdirectories, shorten filenames, purge loaded files, use lifecycle rules.

**Q14: How would you design a fault-tolerant loading pipeline?**
> Snowpipe with SNS fan-out (Option 2) + error notifications + dead-letter queue + monitoring via COPY_HISTORY + alerting on pipe failures + `ALTER PIPE REFRESH` for recovery.

### Architect Level

**Q15: Design a multi-region, multi-account data ingestion architecture.**
> - S3 replication across regions for DR
> - Storage integration per region
> - Snowpipe in primary account, replication group for failover
> - SNS → SQS pattern (Option 2) for flexibility
> - Cross-account sharing for consumer access
> - Monitoring: SNOWFLAKE.ORGANIZATION_USAGE.COPY_HISTORY for org-wide visibility

**Q16: How do you handle late-arriving data in a loading pipeline?**
> - Load into raw layer with METADATA$START_SCAN_TIME
> - Use streams + tasks or dynamic tables for incremental processing
> - Watermarks in downstream tables
> - Reprocessing mechanism via FORCE = TRUE or `ALTER PIPE REFRESH` with PREFIX

**Q17: What's your approach to zero-data-loss loading from S3?**
> 1. S3 versioning enabled (prevent accidental deletes)
> 2. Snowpipe with SNS (Option 2) for reliable notification delivery
> 3. S3 event → SNS → SQS (Snowpipe) + SQS (dead-letter for failures)
> 4. Periodic reconciliation: COUNT files on S3 vs COPY_HISTORY loaded count
> 5. `ALTER PIPE REFRESH` for gap-filling
> 6. Error notifications configured for immediate alerting
> 7. COPY_HISTORY monitoring for partial loads / failures

**Q18: How do you optimize cost for high-volume data loading?**
> - File sizing: 100-250 MB compressed (reduce per-file overhead)
> - Snowpipe: costs per file — batch small files before landing in S3
> - COPY INTO: right-size warehouse — XS for few files, M+ for thousands
> - PURGE = TRUE: reduce S3 storage after load
> - External tables for data you rarely query (no load cost)
> - Auto-suspend warehouse aggressively for batch loads
> - Monitor via `PIPE_USAGE_HISTORY` and `WAREHOUSE_METERING_HISTORY`

**Q19: How would you migrate from a stream+task loading pattern to Snowpipe?**
> 1. Create pipe pointing to same stage as current COPY
> 2. Configure S3 event notifications
> 3. Test with new files (don't `ALTER PIPE REFRESH` yet)
> 4. Once confirmed working, suspend the task
> 5. `ALTER PIPE REFRESH` for any gap between task stop and pipe start
> 6. Drop task and stream after validation period

**Q20: What monitoring and alerting would you set up for a production loading pipeline?**
> - **Freshness:** Alert if MAX(LAST_LOAD_TIME) > expected SLA
> - **Error rate:** Alert if ERROR_COUNT / ROW_COUNT > threshold
> - **Pipe health:** SYSTEM$PIPE_STATUS shows STALLED or PAUSED
> - **Cost:** PIPE_USAGE_HISTORY for unexpected spikes
> - **Volume:** Row count trends via COPY_HISTORY aggregations
> - **Implementation:** Snowflake Tasks + Alert objects, or external monitoring (Datadog, PagerDuty)
