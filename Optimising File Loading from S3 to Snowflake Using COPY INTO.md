# Optimising File Loading from S3 to Snowflake Using COPY INTO

Every Technique, Option & Best Practice with Examples

---

## Section 1: Why File Optimization Matters

When loading data from S3 into Snowflake using COPY INTO, how you prepare and configure your files has a HUGE impact on:

- Load **SPEED** (minutes vs hours)
- **COST** (warehouse credits consumed)
- **POST-LOAD** query performance (small file problem)
- **ERROR** handling and recovery

The key areas to optimize:

1. File **SIZING** (most important)
2. File **FORMAT** (CSV, Parquet, JSON)
3. **COMPRESSION**
4. File **STRUCTURE** & organization
5. **COPY INTO** options
6. **Warehouse sizing** for loading
7. **Error handling** strategy
8. **Parallelism** & concurrency

---

## Section 2: File Sizing — The #1 Optimization

**Snowflake recommends: 100 MB to 250 MB COMPRESSED per file.**

### Why This Range?

**TOO SMALL (< 10 MB each):**
- Snowflake spends more time OPENING files than READING data
- Creates many tiny micro-partitions (small file problem)
- Overhead per file: metadata tracking, staging, listing
- 10,000 x 1KB files = MUCH slower than 1 x 10MB file

**TOO LARGE (> 500 MB each):**
- Imagine you have 8 workers (threads) ready to carry boxes. You give them ONE giant 5 GB box. Only 1 worker carries it, the other 7 stand idle doing nothing. That's wasted effort. With 20 x 250 MB files, all 8 workers carry files at the same time!
- If that one giant file has an error midway, the ENTIRE file fails. You lose ALL progress and must reload the whole 5 GB again. With smaller files, only the 1 failed file needs to be reloaded.
- Bottom line: 1 big file = 1 worker busy, 7 idle = SLOW. Many right-sized files = all workers busy at once = FAST.

**IDEAL (100-250 MB compressed):**
- Snowflake can distribute files across parallel threads
- Each file creates well-sized micro-partitions
- Good balance of parallelism and efficiency

### What Are Threads? (Simple Explanation)

A **THREAD** is like a single worker inside the warehouse computer.

When you run COPY INTO, Snowflake doesn't load files one-by-one. It loads MULTIPLE files at the SAME TIME using multiple threads.

Think of a supermarket:
- 1 billing counter (1 thread) = customers wait in long queue = SLOW
- 8 billing counters (8 threads) = 8 customers served at once = FAST

Each thread picks up ONE file, loads it, then picks up the next file.

How many threads you get depends on **WAREHOUSE SIZE**:

| Warehouse Size | Servers | Approximate Parallel Threads |
|---------------|---------|------------------------------|
| X-Small | 1 | 8 threads (8 files at once) |
| Small | 2 | 16 threads (16 files at once) |
| Medium | 4 | 32 threads (32 files at once) |
| Large | 8 | 64 threads (64 files at once) |

**Example:** 100 files with a Medium warehouse (32 threads):
- Round 1: 32 files loaded simultaneously
- Round 2: 32 more files loaded simultaneously
- Round 3: 32 more files loaded simultaneously
- Round 4: Remaining 4 files loaded
- Total: 4 rounds instead of 100 sequential loads!

**BUT** if you have 1 giant file:
- Only 1 thread can work on it
- The other 31 threads sit idle, doing NOTHING
- You're paying for 32 threads but using only 1

**THAT'S WHY FILE COUNT MATTERS:**
- 100 right-sized files + Medium WH = 32 threads busy = FAST
- 1 giant file + Medium WH = 1 thread busy, 31 wasted = SLOW
- 100,000 tiny files + Medium WH = 32 threads busy BUT each file has overhead, so total time wasted on open/close = SLOW

### How to Right-Size Files Before Loading

#### Option A: Merge Small Files (Combining Many Tiny Files into Fewer Large Ones)

**Problem:** Your upstream system dumps 10,000 x 50 KB CSV files into S3 daily.
**Goal:** Combine them into ~2 x 250 MB files before loading into Snowflake.

**Method 1: AWS GLUE (Managed ETL service)**
- Create a Glue Job that reads all small files from the source S3 path
- Writes them back as fewer, larger files (called "compaction")
- Glue supports `coalesce(1)` to reduce output file count
- Glue can also convert CSV to Parquet during compaction (bonus!)
- Schedule the Glue Job to run before your Snowflake COPY INTO

**Method 2: AWS LAMBDA (Serverless function)**
- Trigger a Lambda function when files arrive in S3
- Lambda reads multiple small files, concatenates them into one buffer
- Writes the combined file to a "ready-to-load" S3 folder
- Best for: near real-time merging of small files
- Limitation: Lambda has 15-min timeout and 10 GB memory limit

**Method 3: AWS CLI / S3 CONCAT (Manual or scripted)**
- Use a script (Python/Bash) on EC2 or locally:
  1. Download small files from S3
  2. Concatenate them into one larger file
  3. Re-upload the merged file to a "processed" S3 folder
- Simple but slower — involves download + upload

**Method 4: S3 SELECT + ATHENA**
- Use AWS Athena to query small files with CTAS (CREATE TABLE AS)
- Athena outputs fewer, larger files in Parquet format
- Then point your Snowflake stage at the Athena output folder

| Method | Best For |
|--------|----------|
| AWS Glue | Scheduled daily/hourly compaction |
| AWS Lambda | Real-time merging on file arrival |
| CLI/Python script | One-time or ad-hoc merging |
| Athena CTAS | Merging + format conversion to Parquet |

#### Option B: Split Large Files (Breaking One Huge File into Smaller Pieces)

**Problem:** Your source system generates a single 20 GB CSV file daily.
**Goal:** Split it into ~80 x 250 MB files for parallel loading.

**WHY SPLIT?**
- Snowflake loads files in PARALLEL — one file per thread
- 1 x 20 GB file = only 1 thread works, others sit idle
- 80 x 250 MB files = 80 threads work simultaneously = MUCH faster

**Method 1: Linux SPLIT command (simplest)**

```bash
split -b 250m large_file.csv part_
# splits by line count (safer for CSV):
split -l 1000000 large_file.csv part_
```

**Method 2: Python script**
- Read the large CSV in chunks of N rows
- Write each chunk to a separate file
- Upload all chunks to S3
- Advantage: respects row boundaries (no split rows)

**Method 3: AWS Glue with repartition()**
- Read the single large file
- Use `repartition(80)` to split into 80 output files
- Write output back to S3

**Method 4: Let Snowflake handle it (for uncompressed CSV only!)**
- Snowflake can PARALLEL SCAN large uncompressed CSV files
- Conditions: `COMPRESSION='NONE'`, `MULTI_LINE=FALSE`, > 128 MB

| Method | Best For |
|--------|----------|
| Linux split | Quick one-time splits on a server |
| Python script | Automated pipeline, row-safe splits |
| AWS Glue repartition | Cloud-native, scheduled splitting |
| Snowflake parallel CSV | Uncompressed files only (no pre-work) |

#### Option C: Configure ETL Tool to Output Right-Sized Files

THIS IS THE BEST APPROACH — fix at the source, no post-processing needed.

**Apache Spark:**
- `df.coalesce(N)` or `df.repartition(N)` before writing to S3
- N = total data size / 250 MB
- Example: 5 GB data -> `repartition(20)` -> 20 x 250 MB files

**AWS Kinesis Firehose (for streaming):**
- Set `BufferSizeInMBs = 128` (buffer until 128 MB, then write file)
- Set `BufferIntervalInSeconds = 300` (or write every 5 min)

**Custom Application:**
- Track bytes written per file
- When approaching 250 MB, close current file, open new one
- Name files with sequence numbers: `data_001.csv.gz`, `data_002.csv.gz`

---

## Section 3: Choose the Right File Format

| Format | Speed | Compression | Best For |
|--------|-------|-------------|----------|
| CSV | Fast | GZIP, ZSTD, BZ2 | Simple tabular data |
| PARQUET | Fastest* | Snappy, LZO | Columnar analytics, best compression ratio |
| JSON | Moderate | GZIP, ZSTD | Semi-structured data |
| AVRO | Moderate | Snappy, Deflate | Schema evolution needs |
| ORC | Fast | Snappy, ZLIB | Hive/Hadoop ecosystems |

*Parquet is columnar — Snowflake only reads columns you need.

**RECOMMENDATION:**
- Use **PARQUET** if your upstream system supports it (best overall)
- Use **compressed CSV (GZIP)** for simple, flat data
- Use **JSON** only when data is truly semi-structured

### Create Named File Formats for Reuse

```sql
CREATE OR REPLACE FILE FORMAT CSV_OPTIMIZED
    TYPE = 'CSV'
    COMPRESSION = 'AUTO'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    NULL_IF = ('NULL', 'null', '')
    EMPTY_FIELD_AS_NULL = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

CREATE OR REPLACE FILE FORMAT PARQUET_OPTIMIZED
    TYPE = 'PARQUET'
    COMPRESSION = 'AUTO'
    USE_VECTORIZED_SCANNER = TRUE;

CREATE OR REPLACE FILE FORMAT JSON_OPTIMIZED
    TYPE = 'JSON'
    COMPRESSION = 'AUTO'
    STRIP_OUTER_ARRAY = TRUE
    STRIP_NULL_VALUES = TRUE;
```

---

## Section 4: Compression — Always Compress

**ALWAYS** compress files before loading. Benefits:
- Faster transfer from S3 to Snowflake (less data over network)
- Less storage in S3 (lower S3 costs)
- Snowflake auto-detects and decompresses

### Compression Comparison

| Algorithm | Compression | Speed | Recommendation |
|-----------|-------------|-------|----------------|
| GZIP | Good (60-70%) | Moderate | Best default choice |
| ZSTD | Better (65-75%) | Fast | Best balance |
| SNAPPY | OK (50-60%) | Fastest | Best for Parquet |
| BZ2 | Best (70-80%) | Slowest | Only if size matters |
| BROTLI | Best (70-80%) | Slow | Must specify in COPY |
| NONE | No compression | Fastest decomp | Never for production |

```sql
COPY INTO my_table
FROM @my_s3_stage/data/
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'GZIP');

COPY INTO my_table
FROM @my_s3_stage/data/
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'ZSTD');
```

---

## Section 5: Organise Files in S3 by Path

### Structure Your S3 Bucket with Logical Paths

```
s3://my-bucket/
+-- sales/
|   +-- 2025/
|   |   +-- 01/
|   |   +-- 02/
|   |   +-- 03/
|   +-- 2026/
|       +-- 01/
|       +-- 02/
+-- customers/
    +-- daily/
        +-- 2026-01-01/
        +-- 2026-01-02/
```

### Why This Matters

- Load specific paths: `FROM @stage/sales/2026/01/`
- Avoid scanning ENTIRE bucket each time
- Easier error isolation (only reload failed folder)
- Enables incremental loading by date

### Example

```sql
CREATE OR REPLACE STAGE MY_S3_STAGE
    URL = 's3://my-data-bucket/sales/'
    STORAGE_INTEGRATION = my_s3_integration
    FILE_FORMAT = CSV_OPTIMIZED;

-- Load only January 2026 data
COPY INTO SALES_TABLE
FROM @MY_S3_STAGE/2026/01/
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');

-- Load only February 2026 data
COPY INTO SALES_TABLE
FROM @MY_S3_STAGE/2026/02/
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
```

---

## Section 6: COPY INTO Options That Improve Performance

### Option 1: FILES — Load Specific Files (FASTEST Method)

Providing exact file names is the fastest approach. Max: 1000 files per COPY statement.

```sql
COPY INTO SALES
FROM @MY_S3_STAGE
FILES = ('sales_001.csv.gz', 'sales_002.csv.gz', 'sales_003.csv.gz')
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
```

### Option 2: PATTERN — Load Files Matching a Regex

```sql
COPY INTO SALES
FROM @MY_S3_STAGE/2026/
PATTERN = '.*sales_[0-9]+[.]csv[.]gz'
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
```

### Option 3: ON_ERROR — Choose the Right Error Strategy

| Option | Behavior |
|--------|----------|
| ABORT_STATEMENT (default) | Stops on first error. Safe but slow for recovery. |
| CONTINUE | Skips bad rows, loads good rows. Best for dirty data. |
| SKIP_FILE | Skips entire file on error. |
| SKIP_FILE_10 | Skips file if >= 10 errors. |
| 'SKIP_FILE_5%' | Skips file if > 5% rows have errors. |

```sql
-- For clean data: stop on any error
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
ON_ERROR = 'ABORT_STATEMENT';

-- For messy data: skip bad rows
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
ON_ERROR = 'CONTINUE';

-- Skip file if more than 10 errors
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
ON_ERROR = 'SKIP_FILE_10';
```

### Option 4: PURGE — Auto-Delete Files After Loading

```sql
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
PURGE = TRUE;
```

### Option 5: MATCH_BY_COLUMN_NAME — For Semi-Structured Formats

```sql
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'PARQUET_OPTIMIZED')
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE';
```

### Option 6: VALIDATION_MODE — Test Without Loading

```sql
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
VALIDATION_MODE = 'RETURN_ERRORS';
```

### Option 7: SIZE_LIMIT — Control How Much Data Per COPY

```sql
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
SIZE_LIMIT = 524288000;
```

### Option 8: FORCE — Reload Previously Loaded Files

```sql
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
FORCE = TRUE;
```

---

## Section 7: Warehouse Sizing for Loading

| Number of Files | Recommended Warehouse |
|----------------|----------------------|
| 1-10 files | X-Small or Small |
| 10-100 files | Small or Medium |
| 100-1000 files | Medium or Large |
| 1000+ files | Large or X-Large |

**BEST PRACTICE:**
- Use a **DEDICATED** warehouse for loading (separate from queries)
- Auto-suspend after loading to save credits
- Start small, scale up only if needed

---

## Section 8: Use Parquet for Best Performance

### Why Parquet is Better Than CSV

1. **COLUMNAR** format — Snowflake reads only needed columns
2. **Built-in SCHEMA** — column names/types embedded in file
3. **Better COMPRESSION** — Parquet compresses column-by-column
4. **TYPE SAFETY** — data types preserved (no string parsing)
5. **USE_VECTORIZED_SCANNER** — newer, faster reading engine

```sql
COPY INTO SALES
FROM @MY_S3_STAGE/parquet/
FILE_FORMAT = (
    TYPE = 'PARQUET'
    USE_VECTORIZED_SCANNER = TRUE
)
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE';
```

---

## Section 9: Parallel CSV Scanning (Large Uncompressed Files)

For **LARGE UNCOMPRESSED CSV files (> 128 MB):** Snowflake supports PARALLEL SCANNING within a single file!

### Conditions (All Must Be True)

- File is UNCOMPRESSED (`COMPRESSION = 'NONE'`)
- `MULTI_LINE = FALSE` (no multi-line fields)
- `ON_ERROR = 'ABORT_STATEMENT'` or `'CONTINUE'`
- File follows RFC4180 CSV standard

### What is MULTI_LINE?

**SINGLE-LINE (`MULTI_LINE = FALSE` — default):**
Each row = 1 line. Snowflake knows where each row starts and ends.

**MULTI-LINE (`MULTI_LINE = TRUE`):**
A field contains line breaks inside quotes. Row spans multiple lines in the file.

### Why MULTI_LINE Matters for Parallel Loading

**When `MULTI_LINE = FALSE`:** Snowflake can split the file at ANY line break and give portions to different threads. PARALLEL = FAST.

**When `MULTI_LINE = TRUE`:** Snowflake cannot split safely, must read sequentially with 1 thread. NO parallel = SLOW.

### Setup for Parallel CSV Loading

```sql
CREATE OR REPLACE FILE FORMAT PARALLEL_CSV_FORMAT
    TYPE = 'CSV'
    COMPRESSION = 'NONE'           -- CRITICAL: Must be NONE
    SKIP_HEADER = 1
    FIELD_DELIMITER = ','
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('NULL', 'null', '')
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;

COPY INTO SALES_PARALLEL_LOAD
FROM @PARALLEL_CSV_STAGE/sales_data.csv
FILE_FORMAT = (FORMAT_NAME = 'PARALLEL_CSV_FORMAT')
ON_ERROR = 'CONTINUE';
```

### How to Confirm Parallel Scanning Happened

- Go to Query History -> Find your COPY INTO query -> Query Profile
- You should see MULTIPLE TableScan nodes for the SAME file
- Each TableScan processed a DIFFERENT PORTION of the file

### Performance Comparison

| Method | 2 GB CSV | Approx Time |
|--------|----------|-------------|
| 1 compressed file (.csv.gz) | 1 thread | ~10 minutes |
| 1 uncompressed file (.csv) | Multi-thread | ~2 minutes |
| 8 x 250 MB pre-split files (compressed) | 8 threads | ~2 minutes |

---

## Section 10: Include Metadata — Track Source Files

| Column | Description |
|--------|-------------|
| `METADATA$FILENAME` | Name of the source file |
| `METADATA$FILE_ROW_NUMBER` | Row number within the file |
| `METADATA$FILE_CONTENT_KEY` | Unique key for file content |
| `METADATA$FILE_LAST_MODIFIED` | When file was last modified |
| `METADATA$START_SCAN_TIME` | When Snowflake started scanning |

```sql
COPY INTO SALES_WITH_METADATA (SALE_ID, SALE_DATE, AMOUNT, SOURCE_FILE, FILE_ROW_NUM, LOAD_TIMESTAMP)
FROM (
    SELECT 
        $1, $2, $3,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        METADATA$START_SCAN_TIME
    FROM @MY_S3_STAGE
)
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
```

---

## Section 11: Prevent Duplicate Loading

Snowflake automatically tracks which files have been loaded. It SKIPS files that were already loaded (based on file checksum). This metadata is retained for **64 DAYS**.

| Situation | What Happens |
|-----------|-------------|
| Same file, no changes | SKIPPED (already loaded) |
| Same filename, content changed | LOADED (new checksum) |
| File older than 64 days | SKIPPED (metadata expired) |
| `FORCE = TRUE` | LOADED (ignores tracking) |
| `LOAD_UNCERTAIN_FILES = TRUE` | Tries to load expired files |

```sql
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
LOAD_UNCERTAIN_FILES = TRUE;
```

---

## Section 12: Validate and Debug Loading Errors

```sql
-- Step 1: Validate before loading (dry run)
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
VALIDATION_MODE = 'RETURN_ERRORS';

-- Step 2: After loading with ON_ERROR = CONTINUE, check errors
SELECT * FROM TABLE(VALIDATE(SALES, JOB_ID => '_last'));

-- Step 3: Check load history
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SALES',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- Step 4: List files in stage
LIST @MY_S3_STAGE;
```

---

## Section 13: Complete Optimized Loading Examples

### Example 1: Best Practice CSV Loading from S3

```sql
COPY INTO SALES
FROM @MY_S3_STAGE/2026/01/
FILE_FORMAT = (
    TYPE = 'CSV'
    COMPRESSION = 'AUTO'
    SKIP_HEADER = 1
    FIELD_DELIMITER = ','
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('NULL', 'null', '')
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
)
ON_ERROR = 'SKIP_FILE_10'
PURGE = TRUE;
```

### Example 2: Best Practice Parquet Loading from S3

```sql
COPY INTO SALES
FROM @MY_S3_STAGE/parquet/2026/
FILE_FORMAT = (
    TYPE = 'PARQUET'
    USE_VECTORIZED_SCANNER = TRUE
)
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE'
ON_ERROR = 'ABORT_STATEMENT'
PURGE = TRUE;
```

### Example 3: JSON Loading with Array Stripping

```sql
COPY INTO EVENTS_RAW
FROM @MY_S3_STAGE/json/
FILE_FORMAT = (
    TYPE = 'JSON'
    COMPRESSION = 'AUTO'
    STRIP_OUTER_ARRAY = TRUE
    STRIP_NULL_VALUES = TRUE
)
ON_ERROR = 'CONTINUE'
PURGE = TRUE;
```

---

## Section 14: Complete Optimization Checklist

### Before Loading (File Preparation)

- [ ] Right-size files: 100-250 MB compressed
- [ ] Compress files: GZIP for CSV, Snappy for Parquet
- [ ] Use Parquet over CSV when possible
- [ ] Organize files by date/path in S3
- [ ] Split large files into multiple smaller files
- [ ] Merge tiny files into larger files

### During Loading (COPY INTO Options)

- [ ] Use named file formats (reusable, consistent)
- [ ] Use `FILES=` for known files (fastest)
- [ ] Use path prefix to narrow scope
- [ ] Set appropriate `ON_ERROR` strategy
- [ ] Use `MATCH_BY_COLUMN_NAME` for Parquet/JSON
- [ ] Enable `USE_VECTORIZED_SCANNER` for Parquet
- [ ] Set `PURGE = TRUE` to auto-cleanup loaded files
- [ ] Use `VALIDATION_MODE` for first-time dry run
- [ ] Use dedicated warehouse for loading
- [ ] Track source files with `METADATA` columns

### After Loading (Post-Load)

- [ ] Check `COPY_HISTORY` for errors
- [ ] Run `VALIDATE()` for error details
- [ ] Verify row counts match expectations
- [ ] Add clustering keys if needed for query performance
- [ ] Consider CTAS to consolidate if small files were loaded

---

## Section 15: Loading Files Using Snowpipe — Complete Guide

### What is Snowpipe?

Think of COPY INTO as a manual truck delivery — you decide WHEN to load. Snowpipe is like an automatic conveyor belt — files are loaded AUTOMATICALLY as soon as they land in S3.

### Key Differences

| | COPY INTO | SNOWPIPE |
|---|----------|----------|
| Trigger | You run it manually or via Task | Automatic on file arrival |
| Warehouse | YOUR warehouse (you pay per-second) | Snowflake-managed serverless (pay per file) |
| Best for | Bulk / batch loads | Continuous / real-time streaming |
| Cost model | Warehouse credits | Serverless credits (based on file count and size) |

---

## Section 16: Snowpipe Setup — Step by Step

```sql
-- Step 1: Storage Integration
CREATE OR REPLACE STORAGE INTEGRATION MY_S3_INTEGRATION
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/my-snowflake-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://my-data-bucket/');

DESC INTEGRATION MY_S3_INTEGRATION;

-- Step 2: External Stage
CREATE OR REPLACE STAGE MY_S3_PIPE_STAGE
    URL = 's3://my-data-bucket/incoming/'
    STORAGE_INTEGRATION = MY_S3_INTEGRATION
    FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');

-- Step 4: Target Table
CREATE OR REPLACE TABLE PIPE_TARGET_TABLE (
    ORDER_ID        INT,
    ORDER_DATE      DATE,
    CUSTOMER_ID     INT,
    AMOUNT          DECIMAL(12,2),
    REGION          VARCHAR(50)
);

-- Step 5: Create the Pipe
CREATE OR REPLACE PIPE MY_AUTO_PIPE
    AUTO_INGEST = TRUE
    AS
    COPY INTO PIPE_TARGET_TABLE
    FROM @MY_S3_PIPE_STAGE
    FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
    ON_ERROR = 'SKIP_FILE';

-- Step 6: Get SQS ARN for AWS S3 Event Notification
SHOW PIPES LIKE 'MY_AUTO_PIPE';

-- Step 7: Grant Permissions
GRANT USAGE ON DATABASE my_db TO ROLE pipe_role;
GRANT USAGE ON SCHEMA my_db.public TO ROLE pipe_role;
GRANT INSERT, SELECT ON TABLE PIPE_TARGET_TABLE TO ROLE pipe_role;
GRANT USAGE ON STAGE MY_S3_PIPE_STAGE TO ROLE pipe_role;
GRANT OWNERSHIP ON PIPE MY_AUTO_PIPE TO ROLE pipe_role;

-- Step 8: Load historical files
ALTER PIPE MY_AUTO_PIPE REFRESH;
```

**Step 6 in AWS:** Go to S3 -> Bucket -> Properties -> Event Notifications -> Create. Event type: `s3:ObjectCreated:*`. Destination: SQS Queue -> paste the ARN from SHOW PIPES.

---

## Section 17: Monitoring Snowpipe

### Method 1: SYSTEM$PIPE_STATUS — Real-Time Pipe Status

```sql
SELECT SYSTEM$PIPE_STATUS('MY_AUTO_PIPE');
```

Key fields in the returned JSON:
- `pendingFileCount` — How many files are WAITING to be loaded
- `executionState` — RUNNING, PAUSED, or error states
- `lastIngestedTimestamp` — When the most recent file finished loading
- `lastIngestedFilePath` — Name of the last successfully loaded file
- `numOutstandingMessagesOnChannel` — S3 notifications received but not processed yet

### Method 2: COPY_HISTORY — See Loaded Files with Details

```sql
SELECT FILE_NAME, STATUS, ROW_COUNT, ROW_PARSED, FILE_SIZE,
    FIRST_ERROR_MESSAGE, ERROR_COUNT, PIPE_RECEIVED_TIME, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'PIPE_TARGET_TABLE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;
```

**STATUS values:** `Loaded`, `Load failed`, `Partially loaded`, `Load skipped`

### Method 3: Summary — Count by Status

```sql
SELECT STATUS, COUNT(*) AS FILE_COUNT,
    SUM(ROW_COUNT) AS TOTAL_ROWS_LOADED, SUM(ERROR_COUNT) AS TOTAL_ERRORS
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'PIPE_TARGET_TABLE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
GROUP BY STATUS;
```

### Method 4: VALIDATE_PIPE_LOAD

```sql
SELECT *
FROM TABLE(VALIDATE_PIPE_LOAD(
    PIPE_NAME => 'MY_AUTO_PIPE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
));
```

### Method 5: PIPE_USAGE_HISTORY — Credit Consumption

```sql
SELECT PIPE_NAME, START_TIME, END_TIME, CREDITS_USED, BYTES_INSERTED, FILES_INSERTED
FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END => CURRENT_TIMESTAMP(),
    PIPE_NAME => 'MY_AUTO_PIPE'
))
ORDER BY START_TIME DESC;
```

---

## Section 18: ON_ERROR in Snowpipe

In Snowpipe, `ON_ERROR` is set INSIDE the pipe definition. You CANNOT change it per load — you must RECREATE the pipe to change it.

| Option | What Happens |
|--------|-------------|
| ABORT_STATEMENT | DEFAULT. Entire file is skipped on any error. |
| SKIP_FILE | Same as ABORT_STATEMENT for Snowpipe. |
| SKIP_FILE_<num> | Skip file if errors >= num. |
| 'SKIP_FILE_<pct>%' | Skip if error % exceeds threshold. |
| CONTINUE | Load good rows, skip bad rows. Partial load. |

> ABORT_STATEMENT and SKIP_FILE behave the SAME in Snowpipe.

```sql
-- Pipe with CONTINUE
CREATE OR REPLACE PIPE MY_TOLERANT_PIPE
    AUTO_INGEST = TRUE
    AS
    COPY INTO PIPE_TARGET_TABLE
    FROM @MY_S3_PIPE_STAGE
    FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
    ON_ERROR = 'CONTINUE';

-- Find files that failed
SELECT FILE_NAME, STATUS, FIRST_ERROR_MESSAGE, ERROR_COUNT, ROW_COUNT, ROW_PARSED
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'PIPE_TARGET_TABLE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
WHERE STATUS != 'Loaded'
ORDER BY LAST_LOAD_TIME DESC;
```

---

## Section 19: Common Snowpipe Issues & Fixes

### Issue 1: Files Not Loading at All
- `executionState = 'PAUSED'`? -> `ALTER PIPE MY_AUTO_PIPE SET PIPE_EXECUTION_PAUSED = FALSE;`
- `executionState = 'STOPPED_STAGE_DROPPED'`? -> Recreate stage and pipe
- `lastReceivedMessageTimestamp` is old/empty? -> S3 event notification misconfigured

### Issue 2: Duplicate Data Loaded
- Multiple pipes pointing to overlapping S3 paths
- Ran COPY INTO manually AND Snowpipe on same files (they have SEPARATE tracking)

### Issue 3: Files Loaded Twice After Modification
- Snowpipe tracks files by name for **14 DAYS**
- Same filename after 14 days -> LOADED AGAIN
- **Fix:** Use unique file names (include timestamp)

### Issue 4: Pipe is Slow / High Pending File Count
- For burst loads, use COPY INTO with a large warehouse instead
- Snowpipe is designed for continuous streaming, not one-time bulk

### Issue 5: Large Files Not Being Detected
- Multipart uploads generate `CompleteMultipartUpload` events
- **Fix:** Set S3 event to "All object create events"

### Issue 6: CURRENT_TIMESTAMP Shows Wrong Time
- `CURRENT_TIMESTAMP` in pipe evaluates at compile time
- **Fix:** Use `METADATA$START_SCAN_TIME` instead

---

## Section 20: Managing Snowpipe

```sql
-- Pause a pipe
ALTER PIPE MY_AUTO_PIPE SET PIPE_EXECUTION_PAUSED = TRUE;

-- Resume a pipe
ALTER PIPE MY_AUTO_PIPE SET PIPE_EXECUTION_PAUSED = FALSE;

-- Refresh: load files already in stage that pipe missed
ALTER PIPE MY_AUTO_PIPE REFRESH;

-- Refresh specific path
ALTER PIPE MY_AUTO_PIPE REFRESH PREFIX = '2026/05/';

-- View pipe definition
SHOW PIPES LIKE 'MY_AUTO_PIPE';

-- View all pipes
SHOW PIPES;

-- Drop a pipe
DROP PIPE MY_AUTO_PIPE;
```

---

## Section 21: Snowpipe Monitoring Cheat Sheet

| What You Want to Know | Query to Run |
|----------------------|-------------|
| How many files are waiting? | `SYSTEM$PIPE_STATUS` -> `pendingFileCount` |
| Is the pipe running? | `SYSTEM$PIPE_STATUS` -> `executionState` |
| Which files loaded/failed? | `COPY_HISTORY` -> `STATUS`, `FIRST_ERROR_MESSAGE` |
| How many files loaded today? | `COPY_HISTORY` with `GROUP BY STATUS` |
| What errors occurred? | `VALIDATE_PIPE_LOAD()` |
| How many credits did pipe use? | `PIPE_USAGE_HISTORY()` |
| What's the pipe definition? | `SHOW PIPES LIKE 'pipe_name'` |
| Last file loaded? | `SYSTEM$PIPE_STATUS` -> `lastIngested` |
| Are S3 notifications working? | `SYSTEM$PIPE_STATUS` -> `lastReceivedMessageTimestamp` |

---

## Cleanup

```sql
DROP TABLE SALES;
DROP TABLE SALES_WITH_METADATA;
DROP TABLE PIPE_TARGET_TABLE;
DROP PIPE MY_AUTO_PIPE;
DROP PIPE MY_TOLERANT_PIPE;
DROP PIPE MY_MODERATE_PIPE;
DROP FILE FORMAT CSV_OPTIMIZED;
DROP FILE FORMAT PARQUET_OPTIMIZED;
DROP FILE FORMAT JSON_OPTIMIZED;
DROP DATABASE LOADING_OPTIMIZATION_DEMO;
```
