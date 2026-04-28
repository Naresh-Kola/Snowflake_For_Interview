# Snowflake Data Loading -- Complete Interview Guide
## From Basics to Architect Level
### Stages | Batch | Streaming | Best Practices | Interview Questions

---

# Part 1: Stages -- The Foundation of Data Loading

## What Is a Stage?

A stage = a location where data files sit before (or after) loading. Think of it as a "parking lot" for your files before they enter a table. Snowflake CANNOT directly read from your local machine. Files must first go to a stage, then COPY INTO loads them into tables.

```
[Your Files] -> [Stage] -> [COPY INTO] -> [Snowflake Table]
```

---

## Internal Stages (Snowflake-managed storage)

Files are stored INSIDE Snowflake's own cloud storage. You upload files using the PUT command (SnowSQL/drivers only).

### Type 1: User Stage (`@~`)

Every user gets one automatically. Cannot be altered or dropped. Best for: single user staging files for personal use. Reference: `@~` or `@~/<path>`

```sql
PUT file:///tmp/data.csv @~;
LIST @~;
COPY INTO my_table FROM @~/data.csv FILE_FORMAT = (TYPE = 'CSV');
```

### Type 2: Table Stage (`@%<table_name>`)

Every table gets one automatically. Cannot be altered or dropped. Best for: files that will ONLY load into that specific table. Reference: `@%my_table`

```sql
PUT file:///tmp/orders.csv @%orders;
LIST @%orders;
COPY INTO orders FROM @%orders FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

### Type 3: Named Internal Stage

Explicitly created. Most flexible. Supports access control (GRANT/REVOKE). Best for: shared staging area, team collaboration, reusable across tables.

```sql
CREATE STAGE my_internal_stage
    FILE_FORMAT = (TYPE = 'CSV' FIELD_DELIMITER = ',' SKIP_HEADER = 1)
    COMMENT = 'Shared staging area for sales data';

PUT file:///tmp/sales_q1.csv @my_internal_stage/2025/q1/;
LIST @my_internal_stage;
COPY INTO sales FROM @my_internal_stage/2025/q1/;
```

---

## External Stages (Customer-managed cloud storage)

Files live OUTSIDE Snowflake in your own S3/GCS/Azure bucket. You manage the files; Snowflake just reads from them. No PUT command needed -- files are already in cloud storage.

```sql
-- Amazon S3 External Stage
CREATE STAGE my_s3_stage
    URL = 's3://my-bucket/data/'
    STORAGE_INTEGRATION = my_s3_integration
    FILE_FORMAT = (TYPE = 'PARQUET');

-- Google Cloud Storage External Stage
CREATE STAGE my_gcs_stage
    URL = 'gcs://my-bucket/data/'
    STORAGE_INTEGRATION = my_gcs_integration;

-- Microsoft Azure External Stage
CREATE STAGE my_azure_stage
    URL = 'azure://myaccount.blob.core.windows.net/mycontainer/data/'
    STORAGE_INTEGRATION = my_azure_integration;

-- Loading from external stage
COPY INTO my_table FROM @my_s3_stage/2025/;
LIST @my_s3_stage;
```

---

## Storage Integration (Secure way to connect to cloud storage)

Instead of hardcoding credentials, use a storage integration object. It uses IAM roles (AWS), service accounts (GCS), or service principals (Azure).

```sql
CREATE STORAGE INTEGRATION my_s3_integration
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/my-snowflake-role'
    ENABLED = TRUE
    STORAGE_ALLOWED_LOCATIONS = ('s3://my-bucket/data/', 's3://my-bucket/backup/');

DESC INTEGRATION my_s3_integration;
-- ^ Use the output to configure the trust policy in AWS IAM
```

---

## Internal vs External Stages -- Comparison

| Feature | Internal Stage | External Stage |
|---------|---------------|----------------|
| Storage | Snowflake-managed | Customer-managed (S3/GCS) |
| Upload method | PUT command | Cloud provider tools |
| Encryption | Auto AES-256 | User manages (or SSE) |
| Cost | Snowflake storage billing | Your cloud storage cost |
| Access control | Snowflake RBAC | Cloud IAM + Snowflake |
| Snowpipe support | Yes | Yes |
| Best for | Quick loads, small files | Data lakes, large volumes |

---

# Part 2: File Formats

Reusable file format objects avoid repeating options in every COPY command.

```sql
CREATE FILE FORMAT my_csv_format
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('NULL', 'null', '')
    EMPTY_FIELD_AS_NULL = TRUE
    TRIM_SPACE = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

CREATE FILE FORMAT my_json_format
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    STRIP_NULL_VALUES = TRUE;

CREATE FILE FORMAT my_parquet_format
    TYPE = 'PARQUET'
    SNAPPY_COMPRESSION = TRUE;
```

Supported formats: CSV, JSON, AVRO, ORC, PARQUET, XML

---

# Part 3: Batch Data Loading (COPY INTO)

## Basic COPY INTO

```sql
COPY INTO target_table
    FROM @my_stage/path/
    FILE_FORMAT = (FORMAT_NAME = my_csv_format)
    ON_ERROR = 'CONTINUE';
```

## Key COPY Options

### ON_ERROR: What happens when a file has errors?

- `CONTINUE` -- Skip bad rows, load good ones
- `SKIP_FILE` -- Skip the entire file if any error
- `SKIP_FILE_<n>` -- Skip file if error count >= n
- `SKIP_FILE_<n>%` -- Skip file if error % >= n%
- `ABORT_STATEMENT` -- Abort the entire COPY (default)

### Other Important Options

```sql
-- PURGE: Auto-delete files from stage after successful load
COPY INTO my_table FROM @my_stage PURGE = TRUE;

-- FORCE: Reload files even if they were loaded before (ignores load metadata)
COPY INTO my_table FROM @my_stage FORCE = TRUE;

-- LOAD_UNCERTAIN_FILES: Load files with expired metadata (>64 days old)
COPY INTO my_table FROM @my_stage LOAD_UNCERTAIN_FILES = TRUE;

-- RETURN_FAILED_ONLY: Only show failed files in output
COPY INTO my_table FROM @my_stage RETURN_FAILED_ONLY = TRUE;

-- MATCH_BY_COLUMN_NAME: Match file columns to table columns by name
COPY INTO my_table FROM @my_stage
    FILE_FORMAT = (TYPE = 'PARQUET')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- FILES: Specify exact files to load (max 1000 files -- fastest method)
COPY INTO my_table FROM @my_stage FILES = ('file1.csv', 'file2.csv');

-- PATTERN: Regex pattern matching (slowest but flexible)
COPY INTO my_table FROM @my_stage PATTERN = '.*sales.*[.]csv';

-- SIZE_LIMIT: Stop loading after this many bytes
COPY INTO my_table FROM @my_stage SIZE_LIMIT = 1073741824; -- 1 GB
```

## Transformations During Load

You can reorder, omit, cast, and transform columns during COPY INTO.

```sql
COPY INTO orders (order_id, customer, amount, order_date)
    FROM (
        SELECT
            $1::INT,                          -- Column reordering
            UPPER($3::STRING),                -- Transformation
            $4::DECIMAL(10,2),                -- Type casting
            TO_DATE($2, 'YYYY-MM-DD')        -- Date parsing
        FROM @my_stage/orders.csv
    )
    FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);

-- Loading JSON with transformations
COPY INTO events (event_id, event_type, event_time)
    FROM (
        SELECT
            $1:id::INT,
            $1:type::STRING,
            $1:timestamp::TIMESTAMP_NTZ
        FROM @my_stage/events.json
    )
    FILE_FORMAT = (TYPE = 'JSON');
```

## Schema Detection (Auto-detect columns from files)

```sql
SELECT * FROM TABLE(
    INFER_SCHEMA(
        LOCATION => '@my_stage/data/',
        FILE_FORMAT => 'my_parquet_format'
    )
);

CREATE TABLE auto_table
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@my_stage/data/',
                FILE_FORMAT => 'my_parquet_format'
            )
        )
    );
```

## Validation Mode (Dry run -- check for errors without loading)

```sql
COPY INTO my_table FROM @my_stage VALIDATION_MODE = 'RETURN_ERRORS';
COPY INTO my_table FROM @my_stage VALIDATION_MODE = 'RETURN_ALL_ERRORS';
COPY INTO my_table FROM @my_stage VALIDATION_MODE = 'RETURN_5_ROWS';
```

## Validate Function (Check errors after a load)

```sql
SELECT * FROM TABLE(VALIDATE(my_table, JOB_ID => '_last'));
SELECT * FROM TABLE(VALIDATE(my_table, JOB_ID => '01a1234-0000-abcd-0000-00000001'));
```

## Copy History (Track what was loaded)

```sql
-- Information Schema (real-time, last 14 days)
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'my_table',
    START_TIME => DATEADD('day', -7, CURRENT_TIMESTAMP())
));

-- Account Usage (up to 1 year, slight delay)
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE TABLE_NAME = 'MY_TABLE'
ORDER BY LAST_LOAD_TIME DESC;
```

---

# Part 4: Continuous Loading -- Snowpipe

## What Is Snowpipe?

Snowpipe = serverless, continuous, micro-batch file loading. It uses a PIPE object that wraps a COPY INTO statement. When new files arrive in the stage, Snowpipe auto-loads them. Compute is Snowflake-managed (serverless). Latency is ~1 minute.

```sql
CREATE PIPE my_auto_pipe
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-loads CSV files from S3'
AS
    COPY INTO sales
    FROM @my_s3_stage/incoming/
    FILE_FORMAT = (FORMAT_NAME = my_csv_format);

SELECT SYSTEM$PIPE_STATUS('my_auto_pipe');
ALTER PIPE my_auto_pipe REFRESH;
ALTER PIPE my_auto_pipe SET PIPE_EXECUTION_PAUSED = TRUE;
ALTER PIPE my_auto_pipe SET PIPE_EXECUTION_PAUSED = FALSE;
```

## How AUTO_INGEST Works (Event-driven)

- **AWS**: S3 Event Notification -> SQS Queue -> Snowpipe
- **GCS**: GCS Pub/Sub Notification -> Snowpipe
- **Azure**: Event Grid -> Azure Queue -> Snowpipe

Flow: File lands -> Cloud event fires -> Snowpipe receives notification -> Serverless compute loads file -> Metadata recorded

## Snowpipe Billing

Two components: (1) Compute cost -- serverless credits per-second, (2) File overhead cost -- metadata management per file. Target 100-250 MB compressed per file. Overhead INCREASES with more files queued.

## What Does "Serverless" Mean?

"Serverless" does NOT mean "no servers." It means YOU don't manage the servers. You just use the service, and pay only for what you consume. Like electricity at home -- you flip the switch, the electric company handles everything.

### Two Types of Compute in Snowflake

**1. User-Managed (Virtual Warehouses):** YOU create, size, start, stop. YOU pay even when idle. COPY INTO uses your warehouse.

**2. Serverless (Snowflake-managed):** SNOWFLAKE provides and auto-scales. YOU pay only for actual consumption. Examples: Snowpipe, Serverless Tasks, Auto-Clustering, Search Optimization, Materialized View Maintenance.

## Snowpipe Architecture Internals

```
[S3 / GCS / Azure]
      |  file lands
      v
[Cloud Event Notification]
      |  SQS / Pub/Sub / Event Grid
      v
[SNOWFLAKE METADATA SERVICE]  (Cloud Services Layer)
  * Polls message queue
  * Dedup check (load metadata)
  * Adds new files to Internal File Queue
      |
      v
[INTERNAL FILE QUEUE]  (Per-pipe, ordered, multi-consumer)
      |
  +---+---+---+
  v   v   v   v
[Worker 1][Worker 2][Worker 3]  <-- Serverless Compute Pool
  |   |   |
  v   v   v
[TARGET TABLE]  (micro-partitions written + committed)
      |
      v
[Load Metadata Recorded -- 14 days per pipe]
```

## Snowpipe Cost Details

- **TEXT files** (CSV, JSON, XML): Charged on UNCOMPRESSED file size
- **BINARY files** (Parquet, Avro, ORC): Charged on OBSERVED file size
- Cannot use Resource Monitors for Snowpipe

```sql
SELECT TO_DATE(start_time) AS date, pipe_name, SUM(credits_used) AS credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.PIPE_USAGE_HISTORY
WHERE start_time >= DATEADD('month', -1, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 3 DESC;
```

## Snowpipe vs Warehouse COPY -- Comparison

| Aspect | COPY INTO (Warehouse) | Snowpipe |
|--------|----------------------|----------|
| Compute managed by | YOU | SNOWFLAKE |
| Warehouse required | YES | NO |
| Scaling | Manual | Automatic |
| Cost when idle | YES | NO (zero) |
| Billing model | Credits/hour by WH size | Credits/GB loaded |
| Load metadata | 64 days (per table) | 14 days (per pipe) |
| Resource Monitor | YES | NO |
| Trigger | Manual | Auto (event/REST) |
| Best for | Large batch loads | Continuous streams |

---

# Part 5: Real-Time Streaming -- Snowpipe Streaming

Snowpipe Streaming = row-level, real-time data ingestion. Loads ROWS directly (no staging files). Latency ~5 seconds. Throughput up to 10 GB/s per table. Exactly-once via offset tokens.

**Use Cases:** IoT sensor data, Real-time CDC, Live dashboards, Fraud detection

| Feature | Snowpipe | Snowpipe Streaming |
|---------|----------|-------------------|
| Input | Files | Rows (no files) |
| Latency | ~1 minute | ~5 seconds |
| Compute | Serverless | Serverless |
| Ordering | Not guaranteed | Ordered within channel |
| Exactly-once | Via load metadata | Via offset tokens |
| Best for | File-based pipelines | Real-time row streams |
| API | SQL (CREATE PIPE) | Java/Python SDK, REST API, Kafka Connector |
| Schema Evolution | No | Yes |
| Iceberg Support | No | Yes |

---

# Part 6: Kafka Connector

Two modes: `SNOWPIPE` (default, file-based) and `SNOWPIPE_STREAMING` (row-based, lower latency). Kafka Connector v4+ natively uses Snowpipe Streaming.

Key properties: `buffer.flush.time = 10`, `buffer.count.records = 10000`, `buffer.size.bytes = 20000000`, `snowflake.streaming.max.client.lag = 30`

---

# Part 7: Other Data Loading Methods

## Snowsight Web UI Loading

Load small files (<50 MB) directly from Snowsight. Good for quick ad-hoc loads.

## INSERT Using SELECT

```sql
INSERT INTO target_table
    SELECT * FROM source_table WHERE created_date > '2025-01-01';
```

## External Tables (Query without loading)

```sql
CREATE EXTERNAL TABLE ext_orders (
    order_id INT AS (VALUE:order_id::INT),
    amount DECIMAL(10,2) AS (VALUE:amount::DECIMAL(10,2))
)
WITH LOCATION = @my_s3_stage/orders/
FILE_FORMAT = (TYPE = 'PARQUET')
AUTO_REFRESH = TRUE;

SELECT * FROM ext_orders WHERE amount > 100;
```

---

# Part 8: Data Loading Best Practices

## File Sizing (Most Important)

**Target: 100-250 MB compressed per file**

| File Size | Impact |
|-----------|--------|
| < 10 MB | BAD -- Too much metadata overhead |
| 10-100 MB | OK -- Acceptable but not optimal |
| 100-250 MB | IDEAL -- Best balance of parallelism and throughput |
| 250-500 MB | OK -- Slightly less parallel |
| > 500 MB | BAD -- Poor parallelism |
| > 100 GB | NOT RECOMMENDED -- Risk of timeout |

## Other Best Practices

- **Organize by path**: Use date-based paths (`@my_stage/sales/2025/01/15/`)
- **Compression**: Snowflake auto-compresses during PUT. Pre-compress for external stages. Supported: gzip, bzip2, deflate, raw_deflate, Brotli, Zstandard
- **Encryption**: Internal stages auto-encrypted (AES-256). External stages: provide your own key
- **Warehouse sizing**: XSMALL=1 node, SMALL=2, MEDIUM=4, LARGE=8, XLARGE=16. Match warehouse size to file count
- **Load metadata**: 64-day tracking prevents duplicates. After expiry use `LOAD_UNCERTAIN_FILES` or `FORCE`
- **Semi-structured tips**: Use `STRIP_NULL_VALUES = TRUE`, ensure consistent types, max 200 elements extracted per partition

---

# Part 9: Data Unloading (COPY INTO Stage)

```sql
COPY INTO @my_stage/export/orders_
    FROM (SELECT * FROM orders WHERE order_date >= '2025-01-01')
    FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'GZIP' HEADER = TRUE)
    MAX_FILE_SIZE = 268435456
    OVERWRITE = TRUE
    SINGLE = FALSE;
```

---

# Part 10: Interview Questions -- Basics to Architect Level

## Level 1: Beginner

**Q1**: Three types of internal stages? User Stage (`@~`), Table Stage (`@%table_name`), Named Internal Stage.

**Q2**: Internal vs external stages? Internal = Snowflake storage + PUT command. External = your cloud storage + cloud tools.

**Q3**: Load command? `COPY INTO <table> FROM <stage>`

**Q4**: File format object? Reusable named object defining how to parse files (type, delimiter, header, etc.).

**Q5**: Supported file types? CSV, JSON, Avro, ORC, Parquet, XML.

**Q6**: SKIP_HEADER = 1? Skips the first line (header row) of CSV.

**Q7**: View files in stage? `LIST @stage_name;`

**Q8**: PURGE option? Auto-deletes files from stage after successful load. Default FALSE.

**Q9**: Load from local machine directly? No. Must PUT to stage first, then COPY INTO.

**Q10**: Default ON_ERROR? `ABORT_STATEMENT`.

## Level 2: Intermediate

**Q11**: VALIDATION_MODE? Dry run -- checks for errors without loading. Options: RETURN_ERRORS, RETURN_ALL_ERRORS, RETURN_n_ROWS.

**Q12**: Duplicate prevention? Load metadata tracks file name + ETag for 64 days per table. Same file = skip.

**Q13**: MATCH_BY_COLUMN_NAME? Matches by column name instead of position. CASE_SENSITIVE or CASE_INSENSITIVE.

**Q14**: INFER_SCHEMA? Auto-detects column names/types from staged files. Pair with `CREATE TABLE ... USING TEMPLATE`.

**Q15**: Storage integration? Stores cloud credentials (IAM role/service account). Secure, reusable, auditable.

**Q16**: 3 ways to select files? (1) PATH -- prefix filtering (medium speed), (2) FILES -- explicit list, max 1000 (fastest), (3) PATTERN -- regex (slowest).

**Q17**: STRIP_NULL_VALUES? Removes "null" strings from JSON VARIANT columns. Saves storage, improves performance.

**Q18**: Transform during COPY? Yes -- column reordering, casting, expressions via SELECT subquery in FROM.

**Q19**: Schema evolution? Auto-adds new columns from incoming files. Requires `ENABLE_SCHEMA_EVOLUTION = TRUE`.

**Q20**: COPY INTO vs INSERT INTO? COPY = files to table (bulk optimized, dedup, ON_ERROR). INSERT = SQL expressions/tables.

## Level 3: Advanced

**Q21**: Biggest Snowpipe mistake? Wrong file size. Target 100-250 MB compressed. <10 MB = overhead dominates. >500 MB = poor parallelism.

**Q22**: AUTO_INGEST per cloud? AWS: S3 Event -> SQS -> Snowpipe. GCS: Pub/Sub -> Snowpipe. Azure: Event Grid -> Queue -> Snowpipe.

**Q23**: Snowpipe charges? Compute credits (per-second) + file management overhead (per-file). Small files = disproportionate overhead.

**Q24**: Snowpipe vs Streaming? Snowpipe = file-based, ~1 min. Streaming = row-based, ~5 sec, ordering, exactly-once, schema evolution, Iceberg support.

**Q25**: 64-day metadata? Within 64 days = dedup works. After = files skipped. Use `LOAD_UNCERTAIN_FILES` or `FORCE`.

**Q26**: Parallel CSV scanning? If file is >128 MB, uncompressed, MULTI_LINE=FALSE, RFC 4180, ON_ERROR=ABORT/CONTINUE -- Snowflake splits into chunks for parallel threads.

**Q27**: Subcolumnarization? JSON VARIANT elements extracted to internal columns (up to 200/partition). Not extracted if: "null" values present or mixed types. Non-extracted = full VARIANT scan = slow.

**Q28**: SKIP_FILE_n%? Skips file if error percentage exceeds n%. Good for data quality thresholds.

**Q29**: Incremental loading? Snowpipe, Stream+Task, COPY by path, Snowpipe Streaming, Dynamic Tables.

**Q30**: Event filtering? Cloud-side event filtering recommended over PATTERN. Reduces notifications, noise, latency.

## Level 4: Architect

**Q31**: IoT pipeline (1M events/sec)? Kafka -> Kafka Connector (Streaming mode) -> Landing Table -> Stream+Task -> Dynamic Table. Use clustering on timestamp, schema evolution, MAX_CLIENT_LAG=5s.

**Q32**: 500 TB migration? Export to Parquet (250 MB/file), date-partitioned folders, LARGE/XLARGE warehouse, COPY by partition, ON_ERROR=CONTINUE, verify row counts. ~3-4 days with XLARGE.

**Q33**: FORCE vs LOAD_UNCERTAIN_FILES vs default? Default = safest, no dupes. LOAD_UNCERTAIN = good for backfills, slight risk. FORCE = dangerous, guaranteed dupes if files exist.

**Q34**: Multi-region architecture? Single-region + replicate, multi-region local + merge, or hybrid with failover groups. Use DATABASE REPLICATION and FAILOVER GROUPS.

**Q35**: 4-hour COPY for 100 GB? Check: file count, warehouse size, compression, network region, transformations, ON_ERROR overhead, clustering cost, concurrent loads, query profile.

**Q36**: Exactly-once in Streaming? Offset tokens per channel. On reopen, Snowflake returns last committed offset. Client replays from there.

**Q37**: Streaming file migration? SDK buffers -> flushes at MAX_CLIENT_LAG -> small micro-partitions -> background migration compacts. Set MAX_CLIENT_LAG as high as SLA allows.

**Q38**: Streaming REST API? HTTP row-level ingestion. 4 MB/request limit. Best for lightweight/IoT/serverless. For high-throughput, prefer Java/Python SDK.

**Q39**: Zero-data-loss financial system? Kafka (RF=3, acks=all) -> Streaming (exactly-once) -> Landing table (error logging) -> Stream+Task (dedup+merge) -> Dynamic Table -> FAILOVER GROUP.

**Q40**: COPY_HISTORY for Snowpipe vs Streaming? Snowpipe = COPY_HISTORY views. Streaming = SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY view.

---

## Bonus: Tricky Interview Scenarios

**Scenario 1**: 10,000 small JSON files (1 KB each) via Snowpipe, costs skyrocketing. Per-file overhead dominates. Solution: aggregate to 100-250 MB using Amazon Data Firehose.

**Scenario 2**: COPY INTO silently skipping all files. Files already loaded (metadata match). Use `FORCE = TRUE` or `LOAD_UNCERTAIN_FILES = TRUE`.

**Scenario 3**: Sub-second freshness needed. Snowpipe can't (~1 min). Snowpipe Streaming with `MAX_CLIENT_LAG = 1 second`. Tiny partitions until migration compacts.

**Scenario 4**: Mixed JSON types causing slow queries. Mixed types prevent subcolumnarization. Fix at source, cast during COPY, or create view with casts.

**Scenario 5**: Accidentally loaded file twice with FORCE. Use COPY_HISTORY + ROW_NUMBER() to dedup. Never use FORCE in production.

---

## Complete Data Loading Methods Summary

| Method | Type | Latency | Best For |
|--------|------|---------|----------|
| COPY INTO (bulk) | Batch | Minutes | Large file loads |
| Snowpipe (AUTO_INGEST) | Continuous | ~1 min | Auto file loads |
| Snowpipe Streaming | Streaming | ~5 sec | Real-time rows |
| Kafka Connector | Streaming | Depends | Kafka topics |
| Snowsight UI | Manual | Minutes | Small ad-hoc |
| INSERT INTO ... SELECT | SQL | Varies | Table-to-table |
| External Tables | N/A | N/A | Query in-place |

---

# Part 11: Load Metadata -- Deep Dive

## What Is Load Metadata?

An invisible "receipt" Snowflake keeps for every loaded file. Records: file name, size, ETag, rows loaded, timestamp, errors. Stored per-TABLE internally. Purpose: prevent duplicate loads.

## Loading Steps: S3 -> Snowflake Table

1. **Enumerate**: S3 ListObjects to find files
2. **Dedup Check**: Match file name + ETag against load metadata
3. **Download & Parse**: Warehouse nodes download, decompress, parse, transform, validate in parallel
4. **Handle Errors**: Based on ON_ERROR setting
5. **Write Micro-Partitions**: 50-500 MB compressed, columnar, immutable, encrypted
6. **Atomic Commit**: Data immediately queryable
7. **Record Metadata**: Per file, expires after 64 days (COPY) or 14 days (Snowpipe)
8. **Purge** (optional): Delete loaded files from stage if PURGE=TRUE

## Dedup Decision Tree

```
File in stage -> Metadata exists?
  YES -> ETag same? -> YES: SKIP (already loaded)
                    -> NO:  SKIP (content changed, use FORCE)
  NO  -> Older than 64 days? -> YES: SKIP (uncertain, use LOAD_UNCERTAIN_FILES)
                              -> NO:  LOAD (new file)
```

## End-to-End Visual

```
[S3 BUCKET] -> ENUMERATE -> DEDUP CHECK -> DOWNLOAD & PARSE
  -> ON_ERROR CHECK -> WRITE MICRO-PARTITIONS -> ATOMIC COMMIT
    -> RECORD METADATA -> PURGE (optional)
```

## How to View Load Metadata

```sql
-- INFORMATION_SCHEMA.LOAD_HISTORY (real-time, 14 days)
SELECT schema_name, table_name, file_name, last_load_time, status, row_count
FROM INFORMATION_SCHEMA.LOAD_HISTORY
WHERE table_name = 'ORDERS' ORDER BY last_load_time DESC;

-- COPY_HISTORY function (14 days, most detail)
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'ORDERS',
    START_TIME => DATEADD('day', -7, CURRENT_TIMESTAMP())
)) ORDER BY LAST_LOAD_TIME DESC;

-- ACCOUNT_USAGE.COPY_HISTORY (up to 365 days)
SELECT file_name, stage_location, last_load_time, status, row_count, row_parsed, error_count
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE table_name = 'ORDERS' ORDER BY last_load_time DESC;

-- ACCOUNT_USAGE.LOAD_HISTORY (up to 365 days)
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.LOAD_HISTORY
WHERE table_name = 'ORDERS' ORDER BY last_load_time DESC;
```

## Practical Scenarios

- **Normal load**: 5 new files -> all loaded
- **Re-run same COPY**: Same 5 files -> "0 files processed" (dedup)
- **New file arrives**: 6 files found, 5 already loaded -> loads only the new one
- **Modified file, same name**: ETag changed -> STILL SKIPS. Use FORCE or new name
- **Files > 64 days old**: Metadata expired -> SKIPS. Use `LOAD_UNCERTAIN_FILES = TRUE`
- **After TRUNCATE**: Load metadata NOT cleared! Use `FORCE = TRUE`

## Load Metadata Key Facts

| Fact | COPY INTO | Snowpipe |
|------|----------|----------|
| Metadata stored per | TABLE | PIPE |
| Retention | 64 days | 14 days |
| Matches on | File name + ETag | File name + ETag |
| Prevents duplicates | Yes | Yes |
| Auto-reloads modified files | No | No |
| Cleared by TRUNCATE | No | N/A |
| Cleared by DROP + RECREATE | Yes | Yes |
| Override load | FORCE = TRUE | N/A |
| Override uncertain | LOAD_UNCERTAIN_FILES = TRUE | N/A |

### Critical Points

1. **TRUNCATE does NOT clear load metadata.** Use FORCE after truncate.
2. **DROP + RECREATE DOES clear metadata.**
3. **Snowpipe = 14 days**, not 64. Use unique file names with timestamps.
4. **Renaming a file = new file** to Snowflake (different name = different identity).
5. **Same file in different table = loads fine** (metadata is per-table).
6. **"0 files processed"** = most common issue. All files already loaded or not found.

---

*End of Snowflake Data Loading Interview Guide*
