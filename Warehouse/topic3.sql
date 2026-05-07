-- ============================================================================
-- OPTIMISING FILE LOADING FROM S3 TO SNOWFLAKE USING COPY INTO
-- Every Technique, Option & Best Practice with Examples
-- ============================================================================


-- ============================================================================
-- SECTION 1: WHY FILE OPTIMIZATION MATTERS
-- ============================================================================
/*
    When loading data from S3 into Snowflake using COPY INTO, how you
    prepare and configure your files has a HUGE impact on:

    - Load SPEED (minutes vs hours)
    - COST (warehouse credits consumed)
    - POST-LOAD query performance (small file problem)
    - ERROR handling and recovery

    The key areas to optimize:
    1. File SIZING (most important)
    2. File FORMAT (CSV, Parquet, JSON)
    3. COMPRESSION
    4. File STRUCTURE & organization
    5. COPY INTO options
    6. Warehouse sizing for loading
    7. Error handling strategy
    8. Parallelism & concurrency
*/


-- ============================================================================
-- SECTION 2: FILE SIZING — THE #1 OPTIMIZATION
-- ============================================================================
/*
    Snowflake recommends: 100 MB to 250 MB COMPRESSED per file.

    WHY THIS RANGE?
    ─────────────────────────────────────────────────────────────
    TOO SMALL (< 10 MB each):
    - Snowflake spends more time OPENING files than READING data
    - Creates many tiny micro-partitions (small file problem)
    - Overhead per file: metadata tracking, staging, listing
    - 10,000 x 1KB files = MUCH slower than 1 x 10MB file

    TOO LARGE (> 500 MB each):
    - Imagine you have 8 workers (threads) ready to carry boxes.
      You give them ONE giant 5 GB box. Only 1 worker carries it,
      the other 7 stand idle doing nothing. That's wasted effort.
      With 20 x 250 MB files, all 8 workers carry files at the same time!
    - If that one giant file has an error midway, the ENTIRE file fails.
      You lose ALL progress and must reload the whole 5 GB again.
      With smaller files, only the 1 failed file needs to be reloaded.
    - Bottom line: 1 big file = 1 worker busy, 7 idle = SLOW.
      Many right-sized files = all workers busy at once = FAST.

    WHAT ARE THREADS? (Simple Explanation):
    ───────────────────────────────────────
    A THREAD is like a single worker inside the warehouse computer.
    
    When you run COPY INTO, Snowflake doesn't load files one-by-one.
    It loads MULTIPLE files at the SAME TIME using multiple threads.
    
    Think of a supermarket:
    - 1 billing counter (1 thread) = customers wait in long queue = SLOW
    - 8 billing counters (8 threads) = 8 customers served at once = FAST
    
    Each thread picks up ONE file, loads it, then picks up the next file.
    
    How many threads you get depends on WAREHOUSE SIZE:
    ┌────────────────┬──────────┬─────────────────────────────────┐
    │ Warehouse Size │ Servers  │ Approximate Parallel Threads    │
    ├────────────────┼──────────┼─────────────────────────────────┤
    │ X-Small        │ 1        │ 8 threads (8 files at once)     │
    │ Small          │ 2        │ 16 threads (16 files at once)   │
    │ Medium         │ 4        │ 32 threads (32 files at once)   │
    │ Large          │ 8        │ 64 threads (64 files at once)   │
    └────────────────┴──────────┴─────────────────────────────────┘
    
    So if you have 100 files and use a Medium warehouse (32 threads):
    - Round 1: 32 files loaded simultaneously
    - Round 2: 32 more files loaded simultaneously
    - Round 3: 32 more files loaded simultaneously
    - Round 4: Remaining 4 files loaded
    - Total: 4 rounds instead of 100 sequential loads!
    
    BUT if you have 1 giant file:
    - Only 1 thread can work on it
    - The other 31 threads sit idle, doing NOTHING
    - You're paying for 32 threads but using only 1
    
    THAT'S WHY FILE COUNT MATTERS:
    - 100 right-sized files + Medium WH = 32 threads busy = FAST
    - 1 giant file + Medium WH = 1 thread busy, 31 wasted = SLOW
    - 100,000 tiny files + Medium WH = 32 threads busy BUT each 
      file has overhead, so total time wasted on open/close = SLOW

    IDEAL (100-250 MB compressed):
    - Snowflake can distribute files across parallel threads
    - Each file creates well-sized micro-partitions
    - Good balance of parallelism and efficiency

    HOW TO RIGHT-SIZE FILES BEFORE LOADING:
    ─────────────────────────────────────────
    Option A: Merge small files in S3 before loading
              (Use AWS Glue, Lambda, or CLI scripts)
    Option B: Split large files into 100-250 MB chunks
    Option C: Configure your ETL tool to output right-sized files


    OPTION A — MERGE SMALL FILES (Combining many tiny files into fewer large ones):
    ──────────────────────────────────────────────────────────────────────────────

    Problem: Your upstream system dumps 10,000 x 50 KB CSV files into S3 daily.
    Goal:    Combine them into ~2 x 250 MB files before loading into Snowflake.

    Method 1: AWS GLUE (Managed ETL service)
    - Create a Glue Job that reads all small files from the source S3 path
    - Writes them back as fewer, larger files (called "compaction")
    - Glue supports coalesce(1) to reduce output file count
    - Glue can also convert CSV → Parquet during compaction (bonus!)
    - Schedule the Glue Job to run before your Snowflake COPY INTO

    Method 2: AWS LAMBDA (Serverless function)
    - Trigger a Lambda function when files arrive in S3
    - Lambda reads multiple small files, concatenates them into one buffer
    - Writes the combined file to a "ready-to-load" S3 folder
    - Best for: near real-time merging of small files
    - Limitation: Lambda has 15-min timeout and 10 GB memory limit
      so it works for moderate volumes, not massive merges

    Method 3: AWS CLI / S3 CONCAT (Manual or scripted)
    - Use a script (Python/Bash) on EC2 or locally:
      1. Download small files from S3
      2. Concatenate them into one larger file
      3. Re-upload the merged file to a "processed" S3 folder
    - Simple but slower — involves download + upload
    - Example (Python boto3): read all CSVs, write combined CSV, upload

    Method 4: S3 SELECT + ATHENA
    - Use AWS Athena to query small files with CTAS (CREATE TABLE AS)
    - Athena outputs fewer, larger files in Parquet format
    - Then point your Snowflake stage at the Athena output folder

    When to use which:
    ┌───────────────────────┬───────────────────────────────────────┐
    │ Method                │ Best For                              │
    ├───────────────────────┼───────────────────────────────────────┤
    │ AWS Glue              │ Scheduled daily/hourly compaction     │
    │ AWS Lambda            │ Real-time merging on file arrival     │
    │ CLI/Python script     │ One-time or ad-hoc merging            │
    │ Athena CTAS           │ Merging + format conversion to Parquet│
    └───────────────────────┴───────────────────────────────────────┘


    OPTION B — SPLIT LARGE FILES (Breaking one huge file into smaller pieces):
    ──────────────────────────────────────────────────────────────────────────

    Problem: Your source system generates a single 20 GB CSV file daily.
    Goal:    Split it into ~80 x 250 MB files for parallel loading.

    WHY SPLIT?
    - Snowflake loads files in PARALLEL — one file per thread
    - 1 x 20 GB file → only 1 thread works, others sit idle
    - 80 x 250 MB files → 80 threads work simultaneously → MUCH faster

    Method 1: Linux SPLIT command (simplest)
    - Run on EC2 or any Linux machine before uploading to S3:
      $ split -b 250m large_file.csv part_
      This creates: part_aa, part_ab, part_ac, ... (each ~250 MB)
    - Note: This splits by BYTES, so a row might get cut in half!
      Use: split -l 1000000 large_file.csv part_
      (splits by line count instead — safer for CSV)

    Method 2: Python script
    - Read the large CSV in chunks of N rows
    - Write each chunk to a separate file
    - Upload all chunks to S3
    - Advantage: respects row boundaries (no split rows)

    Method 3: AWS Glue with repartition()
    - Read the single large file
    - Use repartition(80) to split into 80 output files
    - Write output back to S3

    Method 4: Let Snowflake handle it (for uncompressed CSV only!)
    - Snowflake can PARALLEL SCAN large uncompressed CSV files
    - Conditions: COMPRESSION='NONE', MULTI_LINE=FALSE, > 128 MB
    - But this only works for uncompressed files, not gzipped

    When to use which:
    ┌───────────────────────┬───────────────────────────────────────┐
    │ Method                │ Best For                              │
    ├───────────────────────┼───────────────────────────────────────┤
    │ Linux split           │ Quick one-time splits on a server     │
    │ Python script         │ Automated pipeline, row-safe splits   │
    │ AWS Glue repartition  │ Cloud-native, scheduled splitting     │
    │ Snowflake parallel CSV│ Uncompressed files only (no pre-work) │
    └───────────────────────┴───────────────────────────────────────┘


    OPTION C — CONFIGURE ETL TOOL TO OUTPUT RIGHT-SIZED FILES:
    ──────────────────────────────────────────────────────────

    Problem: Your ETL pipeline (Spark, Airflow, Fivetran, etc.) creates files.
    Goal:    Tell it to produce 100-250 MB files from the start.

    THIS IS THE BEST APPROACH — fix at the source, no post-processing needed.

    Apache Spark:
    - df.coalesce(N) or df.repartition(N) before writing to S3
    - N = total data size / 250 MB
    - Example: 5 GB data → repartition(20) → 20 x 250 MB files
    - Spark also supports maxRecordsPerFile option

    Apache Airflow:
    - In your DAG, configure the export step to produce chunked files
    - Use operators that support row-limit or size-limit per file

    Fivetran / Airbyte / Matillion:
    - These tools often handle file sizing automatically
    - Check their settings for "max file size" or "batch size"

    AWS Kinesis Firehose (for streaming):
    - Set BufferSizeInMBs = 128 (buffer until 128 MB, then write file)
    - Set BufferIntervalInSeconds = 300 (or write every 5 min)
    - This ensures files are at least 128 MB before landing in S3

    Custom Application:
    - Track bytes written per file
    - When approaching 250 MB, close current file, open new one
    - Name files with sequence numbers: data_001.csv.gz, data_002.csv.gz
*/


-- ============================================================================
-- SECTION 3: CHOOSE THE RIGHT FILE FORMAT
-- ============================================================================
/*
    +──────────+──────────────+─────────────────+──────────────────────────+
    | Format   | Speed        | Compression     | Best For                 |
    +──────────+──────────────+─────────────────+──────────────────────────+
    | CSV      | Fast         | GZIP, ZSTD, BZ2 | Simple tabular data      |
    | PARQUET  | Fastest*     | Snappy, LZO     | Columnar analytics, best |
    |          |              |                 | compression ratio        |
    | JSON     | Moderate     | GZIP, ZSTD      | Semi-structured data     |
    | AVRO     | Moderate     | Snappy, Deflate | Schema evolution needs   |
    | ORC      | Fast         | Snappy, ZLIB    | Hive/Hadoop ecosystems   |
    +──────────+──────────────+─────────────────+──────────────────────────+

    * Parquet is columnar — Snowflake only reads columns you need.
    
    RECOMMENDATION:
    - Use PARQUET if your upstream system supports it (best overall)
    - Use compressed CSV (GZIP) for simple, flat data
    - Use JSON only when data is truly semi-structured
*/

-- EXAMPLE: Create a named file format for reuse
CREATE OR REPLACE DATABASE LOADING_OPTIMIZATION_DEMO;
USE DATABASE LOADING_OPTIMIZATION_DEMO;
USE SCHEMA PUBLIC;

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


-- ============================================================================
-- SECTION 4: COMPRESSION — ALWAYS COMPRESS
-- ============================================================================
/*
    ALWAYS compress files before loading. Benefits:
    - Faster transfer from S3 to Snowflake (less data over network)
    - Less storage in S3 (lower S3 costs)
    - Snowflake auto-detects and decompresses

    COMPRESSION COMPARISON:
    +──────────+─────────────────+─────────────────+──────────────────────+
    | Algorithm | Compression     | Speed           | Recommendation       |
    +──────────+─────────────────+─────────────────+──────────────────────+
    | GZIP     | Good (60-70%)   | Moderate        | Best default choice  |
    | ZSTD     | Better (65-75%) | Fast            | Best balance         |
    | SNAPPY   | OK (50-60%)     | Fastest         | Best for Parquet     |
    | BZ2      | Best (70-80%)   | Slowest         | Only if size matters |
    | BROTLI   | Best (70-80%)   | Slow            | Must specify in COPY |
    | NONE     | No compression  | Fastest decomp  | Never for production |
    +──────────+─────────────────+─────────────────+──────────────────────+

    AUTO is the default — Snowflake detects compression automatically.
    Exception: BROTLI must be specified manually.
*/

-- EXAMPLE: Loading with explicit compression
/*
COPY INTO my_table
FROM @my_s3_stage/data/
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'GZIP');

COPY INTO my_table
FROM @my_s3_stage/data/
FILE_FORMAT = (TYPE = 'CSV' COMPRESSION = 'ZSTD');
*/


-- ============================================================================
-- SECTION 5: ORGANISE FILES IN S3 BY PATH
-- ============================================================================
/*
    STRUCTURE YOUR S3 BUCKET WITH LOGICAL PATHS:

    s3://my-bucket/
    ├── sales/
    │   ├── 2025/
    │   │   ├── 01/   ← January files
    │   │   ├── 02/   ← February files
    │   │   └── 03/
    │   └── 2026/
    │       ├── 01/
    │       └── 02/
    └── customers/
        └── daily/
            ├── 2026-01-01/
            └── 2026-01-02/

    WHY THIS MATTERS:
    - Load specific paths: FROM @stage/sales/2026/01/
    - Avoid scanning ENTIRE bucket each time
    - Easier error isolation (only reload failed folder)
    - Enables incremental loading by date
*/

-- EXAMPLE: External stage with organized path
/*
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
*/


-- ============================================================================
-- SECTION 6: COPY INTO OPTIONS THAT IMPROVE PERFORMANCE
-- ============================================================================

-- CREATE DEMO TABLE
CREATE OR REPLACE TABLE SALES (
    SALE_ID         INT,
    SALE_DATE       DATE,
    CUSTOMER_ID     INT,
    AMOUNT          DECIMAL(12,2),
    REGION          VARCHAR(50)
);

/*
    OPTION 1: FILES — Load specific files (FASTEST method)
    ──────────────────────────────────────────────────────
    Providing exact file names is the fastest approach.
    Snowflake doesn't need to LIST the stage — goes directly to files.
    Max: 1000 files per COPY statement.
*/
/*
COPY INTO SALES
FROM @MY_S3_STAGE
FILES = ('sales_001.csv.gz', 'sales_002.csv.gz', 'sales_003.csv.gz')
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
*/

/*
    OPTION 2: PATTERN — Load files matching a regex
    ────────────────────────────────────────────────
    Slower than FILES (Snowflake must scan and match names).
    Use when file names follow a naming convention.
*/
/*
COPY INTO SALES
FROM @MY_S3_STAGE/2026/
PATTERN = '.*sales_[0-9]+[.]csv[.]gz'
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
*/

/*
    OPTION 3: ON_ERROR — Choose the right error strategy
    ────────────────────────────────────────────────────
    ABORT_STATEMENT (default): Stops on first error. Safe but slow for recovery.
    CONTINUE:                  Skips bad rows, loads good rows. Best for dirty data.
    SKIP_FILE:                 Skips entire file on error. Good for file-level quality.
    SKIP_FILE_10:              Skips file if >= 10 errors. Balance of quality + progress.
    'SKIP_FILE_5%':            Skips file if > 5% rows have errors.

    CHOOSE BASED ON YOUR SCENARIO:
    - Clean, trusted data     → ABORT_STATEMENT (catch issues immediately)
    - Dirty, external data    → CONTINUE or SKIP_FILE_10 (load what you can)
    - Critical financial data → ABORT_STATEMENT (zero tolerance for errors)
*/
/*
-- For clean data: stop on any error
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
ON_ERROR = 'ABORT_STATEMENT';

-- For messy data: skip bad rows, load everything else
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
ON_ERROR = 'CONTINUE';

-- Skip file if more than 10 errors
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
ON_ERROR = 'SKIP_FILE_10';
*/

/*
    OPTION 4: PURGE — Auto-delete files after loading
    ──────────────────────────────────────────────────
    Removes successfully loaded files from S3 stage.
    Prevents reprocessing and saves S3 storage cost.
*/
/*
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
PURGE = TRUE;
*/

/*
    OPTION 5: MATCH_BY_COLUMN_NAME — For semi-structured formats
    ─────────────────────────────────────────────────────────────
    For Parquet, JSON, Avro, ORC — match file columns to table
    columns by NAME instead of position. Column order doesn't matter!
*/
/*
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'PARQUET_OPTIMIZED')
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE';
*/

/*
    OPTION 6: VALIDATION_MODE — Test without loading
    ────────────────────────────────────────────────
    Dry run! Validates files for errors WITHOUT loading data.
    Use before your first production load!
*/
/*
-- Check first 10 rows for errors
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
VALIDATION_MODE = 'RETURN_10_ROWS';

-- Return ALL errors across all files
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
VALIDATION_MODE = 'RETURN_ERRORS';
*/

/*
    OPTION 7: SIZE_LIMIT — Control how much data per COPY
    ─────────────────────────────────────────────────────
    Useful for batch loading in chunks.
    Stops loading after the limit is exceeded.
*/
/*
-- Load 500 MB worth of data per COPY execution
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
SIZE_LIMIT = 524288000;
*/

/*
    OPTION 8: FORCE — Reload previously loaded files
    ────────────────────────────────────────────────
    By default, Snowflake tracks which files are already loaded
    and SKIPS them. Use FORCE to reload.
*/
/*
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
FORCE = TRUE;
*/


-- ============================================================================
-- SECTION 7: WAREHOUSE SIZING FOR LOADING
-- ============================================================================
/*
    RULE: Match warehouse size to the VOLUME of files, not file size.

    +──────────────────────────────+───────────────────────────+
    | Number of Files              | Recommended Warehouse     |
    +──────────────────────────────+───────────────────────────+
    | 1-10 files                   | X-Small or Small          |
    | 10-100 files                 | Small or Medium           |
    | 100-1000 files               | Medium or Large           |
    | 1000+ files                  | Large or X-Large          |
    +──────────────────────────────+───────────────────────────+

    WHY? Each warehouse node processes files in parallel.
    More nodes = more files loaded simultaneously.

    BUT: For a FEW large files, a bigger warehouse doesn't help much
    because parallelism is FILE-level, not within-file.

    BEST PRACTICE: 
    - Use a DEDICATED warehouse for loading (separate from queries)
    - Auto-suspend after loading to save credits
    - Start small, scale up only if needed
*/


-- ============================================================================
-- SECTION 8: USE PARQUET FOR BEST PERFORMANCE
-- ============================================================================
/*
    WHY PARQUET IS BETTER THAN CSV FOR LOADING:
    ─────────────────────────────────────────────
    1. COLUMNAR format — Snowflake reads only needed columns
    2. Built-in SCHEMA — column names/types embedded in file
       (use MATCH_BY_COLUMN_NAME, no column ordering issues)
    3. Better COMPRESSION — Parquet compresses column-by-column
    4. TYPE SAFETY — data types preserved (no string parsing)
    5. USE_VECTORIZED_SCANNER — newer, faster reading engine

    CSV is fine for simple data, but for large-scale loading,
    Parquet is significantly faster and more reliable.
*/
/*
-- Optimized Parquet loading
COPY INTO SALES
FROM @MY_S3_STAGE/parquet/
FILE_FORMAT = (
    TYPE = 'PARQUET'
    USE_VECTORIZED_SCANNER = TRUE
)
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE';
*/


-- ============================================================================
-- SECTION 9: PARALLEL CSV SCANNING (LARGE UNCOMPRESSED FILES)
-- ============================================================================
/*
    For LARGE UNCOMPRESSED CSV files (> 128 MB):
    Snowflake supports PARALLEL SCANNING within a single file!

    CONDITIONS (all must be true):
    - File is UNCOMPRESSED (COMPRESSION = 'NONE')
    - MULTI_LINE = FALSE (no multi-line fields)
    - ON_ERROR = 'ABORT_STATEMENT' or 'CONTINUE'
    - File follows RFC4180 CSV standard

    WHAT IS MULTI_LINE?
    ───────────────────
    In a CSV file, normally each ROW is on ONE line:

    SINGLE-LINE (MULTI_LINE = FALSE — default, normal):
    ┌──────────────────────────────────────────────┐
    │ id,name,address                              │
    │ 1,Rohit,123 Main Street Mumbai               │
    │ 2,Alice,456 Park Avenue Delhi                │
    │ 3,Bob,789 Lake Road Bangalore                │
    └──────────────────────────────────────────────┘
    Each row = 1 line. Simple. Snowflake knows where each row starts and ends.

    MULTI-LINE (MULTI_LINE = TRUE — when a field spans multiple lines):
    ┌──────────────────────────────────────────────┐
    │ id,name,address                              │
    │ 1,Rohit,"123 Main Street                     │
    │ Floor 4                                      │
    │ Mumbai 400001"                               │
    │ 2,Alice,"456 Park Avenue                     │
    │ Delhi 110001"                                │
    └──────────────────────────────────────────────┘
    Here the "address" field has line breaks INSIDE it (wrapped in quotes).
    Row 1 (Rohit) spans 3 lines in the file, but it's actually 1 row of data.

    WHY MULTI_LINE MATTERS FOR PARALLEL LOADING:
    ─────────────────────────────────────────────
    When MULTI_LINE = FALSE:
    - Snowflake can safely split the file at ANY line break
    - It knows each line = 1 complete row
    - So it can give lines 1-1000 to Thread 1, lines 1001-2000 to Thread 2, etc.
    - PARALLEL loading within a single file = FAST

    When MULTI_LINE = TRUE:
    - Snowflake CANNOT split at any line break, because a line break
      might be INSIDE a field (like the address example above)
    - If it splits at the wrong line, it breaks a row in half
    - So Snowflake must read the ENTIRE file sequentially with 1 thread
    - NO parallel loading = SLOW

    BOTTOM LINE:
    - If your CSV has no line breaks inside fields → use MULTI_LINE = FALSE (default)
    - If your CSV has line breaks inside quoted fields → you MUST use MULTI_LINE = TRUE
      but you lose parallel scanning for that file

    This allows Snowflake to split one big file across
    multiple threads — dramatically faster for large files.


    COMPLETE SETUP FOR PARALLEL CSV LOADING — STEP BY STEP:
    ═══════════════════════════════════════════════════════

    SCENARIO: You have a 2 GB uncompressed CSV file (sales_data.csv) in S3.
    Instead of 1 thread taking 10 minutes, Snowflake splits it across
    multiple threads and finishes in ~2 minutes.


    STEP 1: PREPARE YOUR FILE (on your side, before uploading to S3)
    ─────────────────────────────────────────────────────────────────
    - File MUST be UNCOMPRESSED (.csv, NOT .csv.gz)
    - File MUST NOT have multi-line fields (no line breaks inside values)
    - File should follow standard CSV format (RFC4180)
    - Each row = exactly 1 line
    - File should be > 128 MB (parallel scanning only kicks in above this)
    
    Example valid file (sales_data.csv):
    ┌──────────────────────────────────────────────────────────────┐
    │ order_id,customer_name,order_date,amount,region              │  ← header
    │ 1,Rohit,2026-01-01,500.00,NORTH                             │
    │ 2,Alice,2026-01-02,750.00,SOUTH                             │
    │ 3,Bob,2026-01-03,120.00,EAST                                │
    │ ... (millions of rows, total file size = 2 GB)              │
    └──────────────────────────────────────────────────────────────┘

    Example INVALID file (will NOT work with parallel scanning):
    ┌──────────────────────────────────────────────────────────────┐
    │ 1,Rohit,"123 Main Street                                    │
    │ Floor 4                                                     │  ← multi-line!
    │ Mumbai",500.00                                              │
    └──────────────────────────────────────────────────────────────┘


    STEP 2: UPLOAD TO S3 (keep it UNCOMPRESSED)
    ────────────────────────────────────────────
    Upload the uncompressed CSV to your S3 bucket:
    
    aws s3 cp sales_data.csv s3://my-bucket/large_files/sales_data.csv
    
    DO NOT gzip it! Compressed files cannot be split.


    STEP 3: CREATE THE STAGE IN SNOWFLAKE
    ──────────────────────────────────────
*/
/*
CREATE OR REPLACE STAGE PARALLEL_CSV_STAGE
    URL = 's3://my-bucket/large_files/'
    STORAGE_INTEGRATION = MY_S3_INTEGRATION;
*/
/*

    STEP 4: CREATE THE FILE FORMAT (key settings for parallel scanning)
    ───────────────────────────────────────────────────────────────────
*/
/*
CREATE OR REPLACE FILE FORMAT PARALLEL_CSV_FORMAT
    TYPE = 'CSV'
    COMPRESSION = 'NONE'           -- CRITICAL: Must be NONE
    SKIP_HEADER = 1                -- Skip the header row
    FIELD_DELIMITER = ','
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    NULL_IF = ('NULL', 'null', '')
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE;
*/
/*

    STEP 5: CREATE THE TARGET TABLE
    ────────────────────────────────
*/
/*
CREATE OR REPLACE TABLE SALES_PARALLEL_LOAD (
    ORDER_ID        INT,
    CUSTOMER_NAME   VARCHAR(100),
    ORDER_DATE      DATE,
    AMOUNT          DECIMAL(12,2),
    REGION          VARCHAR(50)
);
*/
/*

    STEP 6: LOAD WITH PARALLEL SCANNING
    ────────────────────────────────────
    The magic happens automatically — Snowflake detects the file
    is uncompressed, > 128 MB, and splits it across threads.
*/
/*
COPY INTO SALES_PARALLEL_LOAD
FROM @PARALLEL_CSV_STAGE
FILE_FORMAT = (FORMAT_NAME = 'PARALLEL_CSV_FORMAT')
ON_ERROR = 'CONTINUE';
*/
/*
    -- You can also specify the file directly:
*/
/*
COPY INTO SALES_PARALLEL_LOAD
FROM @PARALLEL_CSV_STAGE/sales_data.csv
FILE_FORMAT = (FORMAT_NAME = 'PARALLEL_CSV_FORMAT')
ON_ERROR = 'CONTINUE';
*/
/*

    STEP 7: VERIFY THE LOAD
    ───────────────────────
*/
/*
-- Check row count
SELECT COUNT(*) FROM SALES_PARALLEL_LOAD;

-- Check for any errors during load
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SALES_PARALLEL_LOAD',
    START_TIME => DATEADD('HOURS', -1, CURRENT_TIMESTAMP())
));
*/
/*

    HOW TO CONFIRM PARALLEL SCANNING HAPPENED:
    ───────────────────────────────────────────
    - Go to Query History → Find your COPY INTO query → Query Profile
    - You should see MULTIPLE TableScan nodes for the SAME file
    - Each TableScan processed a DIFFERENT PORTION of the file
    - If you see only 1 TableScan → parallel scanning did NOT happen
      (check: is file compressed? is MULTI_LINE = TRUE? is file < 128 MB?)


    PERFORMANCE COMPARISON:
    ┌──────────────────────────────┬──────────────┬──────────────┐
    │ Method                       │ 2 GB CSV     │ Approx Time  │
    ├──────────────────────────────┼──────────────┼──────────────┤
    │ 1 compressed file (.csv.gz)  │ 1 thread     │ ~10 minutes  │
    │ 1 uncompressed file (.csv)   │ Multi-thread │ ~2 minutes   │
    │ 8 x 250 MB pre-split files   │ 8 threads    │ ~2 minutes   │
    │ (compressed)                 │              │              │
    └──────────────────────────────┴──────────────┴──────────────┘

    KEY TAKEAWAY:
    - Parallel CSV scanning and pre-splitting achieve SIMILAR speed
    - Parallel scanning = less work upfront (no splitting needed)
    - Pre-splitting = works with COMPRESSED files too
    - Choose based on your pipeline: can you split? → split + compress
      Can't split? → upload uncompressed + let Snowflake parallelize
*/


-- ============================================================================
-- SECTION 10: INCLUDE METADATA — TRACK SOURCE FILES
-- ============================================================================
/*
    Snowflake provides METADATA$ columns to capture info about
    source files during loading. Very useful for auditing!

    METADATA$FILENAME          → Name of the source file
    METADATA$FILE_ROW_NUMBER   → Row number within the file
    METADATA$FILE_CONTENT_KEY  → Unique key for file content
    METADATA$FILE_LAST_MODIFIED→ When file was last modified
    METADATA$START_SCAN_TIME   → When Snowflake started scanning
*/

CREATE OR REPLACE TABLE SALES_WITH_METADATA (
    SALE_ID         INT,
    SALE_DATE       DATE,
    AMOUNT          DECIMAL(12,2),
    SOURCE_FILE     VARCHAR(500),
    FILE_ROW_NUM    INT,
    LOAD_TIMESTAMP  TIMESTAMP_LTZ
);

/*
-- Load with metadata using COPY transformation
COPY INTO SALES_WITH_METADATA (SALE_ID, SALE_DATE, AMOUNT, SOURCE_FILE, FILE_ROW_NUM, LOAD_TIMESTAMP)
FROM (
    SELECT 
        $1,
        $2,
        $3,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        METADATA$START_SCAN_TIME
    FROM @MY_S3_STAGE
)
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
*/


-- ============================================================================
-- SECTION 11: PREVENT DUPLICATE LOADING
-- ============================================================================
/*
    Snowflake automatically tracks which files have been loaded.
    It SKIPS files that were already loaded (based on file checksum).

    This metadata is retained for 64 DAYS.

    SCENARIOS:
    ┌────────────────────────────────────────────────────────────────┐
    │ Situation                     │ What Happens                  │
    ├────────────────────────────────────────────────────────────────┤
    │ Same file, no changes         │ SKIPPED (already loaded)      │
    │ Same filename, content changed│ LOADED (new checksum)         │
    │ File older than 64 days       │ SKIPPED (metadata expired)    │
    │ FORCE = TRUE                  │ LOADED (ignores tracking)     │
    │ LOAD_UNCERTAIN_FILES = TRUE   │ Tries to load expired files   │
    └────────────────────────────────────────────────────────────────┘

    For files older than 64 days:
*/
/*
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
LOAD_UNCERTAIN_FILES = TRUE;
*/


-- ============================================================================
-- SECTION 12: VALIDATE AND DEBUG LOADING ERRORS
-- ============================================================================

-- STEP 1: Validate before loading (dry run)
/*
COPY INTO SALES
FROM @MY_S3_STAGE
FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
VALIDATION_MODE = 'RETURN_ERRORS';
*/

-- STEP 2: After loading with ON_ERROR = CONTINUE, check errors
/*
SELECT * FROM TABLE(VALIDATE(SALES, JOB_ID => '_last'));
*/

-- STEP 3: Check load history
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'SALES',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- STEP 4: List files in stage to verify
-- LIST @MY_S3_STAGE;


-- ============================================================================
-- SECTION 13: COMPLETE OPTIMIZED LOADING EXAMPLES
-- ============================================================================

-- EXAMPLE 1: Best practice CSV loading from S3
/*
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
*/

-- EXAMPLE 2: Best practice Parquet loading from S3
/*
COPY INTO SALES
FROM @MY_S3_STAGE/parquet/2026/
FILE_FORMAT = (
    TYPE = 'PARQUET'
    USE_VECTORIZED_SCANNER = TRUE
)
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE'
ON_ERROR = 'ABORT_STATEMENT'
PURGE = TRUE;
*/

-- EXAMPLE 3: JSON loading with array stripping
/*
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
*/


-- ============================================================================
-- SECTION 14: COMPLETE OPTIMIZATION CHECKLIST
-- ============================================================================
/*
    ┌──────────────────────────────────────────────────────────────────────┐
    │ BEFORE LOADING (File Preparation)                                   │
    ├──────────────────────────────────────────────────────────────────────┤
    │ [1] Right-size files: 100-250 MB compressed                         │
    │ [2] Compress files: GZIP for CSV, Snappy for Parquet                │
    │ [3] Use Parquet over CSV when possible                              │
    │ [4] Organize files by date/path in S3                               │
    │ [5] Split large files into multiple smaller files                    │
    │ [6] Merge tiny files into larger files                              │
    ├──────────────────────────────────────────────────────────────────────┤
    │ DURING LOADING (COPY INTO Options)                                  │
    ├──────────────────────────────────────────────────────────────────────┤
    │ [7] Use named file formats (reusable, consistent)                   │
    │ [8] Use FILES= for known files (fastest)                            │
    │ [9] Use path prefix to narrow scope                                 │
    │ [10] Set appropriate ON_ERROR strategy                              │
    │ [11] Use MATCH_BY_COLUMN_NAME for Parquet/JSON                      │
    │ [12] Enable USE_VECTORIZED_SCANNER for Parquet                      │
    │ [13] Set PURGE = TRUE to auto-cleanup loaded files                  │
    │ [14] Use VALIDATION_MODE for first-time dry run                     │
    │ [15] Use dedicated warehouse for loading                            │
    │ [16] Track source files with METADATA$ columns                      │
    ├──────────────────────────────────────────────────────────────────────┤
    │ AFTER LOADING (Post-Load)                                           │
    ├──────────────────────────────────────────────────────────────────────┤
    │ [17] Check COPY_HISTORY for errors                                  │
    │ [18] Run VALIDATE() for error details                               │
    │ [19] Verify row counts match expectations                           │
    │ [20] Add clustering keys if needed for query performance            │
    │ [21] Consider CTAS to consolidate if small files were loaded        │
    └──────────────────────────────────────────────────────────────────────┘
*/


-- ============================================================================
-- SECTION 15: LOADING FILES USING SNOWPIPE — COMPLETE GUIDE
-- ============================================================================
/*
    WHAT IS SNOWPIPE?
    ─────────────────
    Think of COPY INTO as a manual truck delivery — you decide WHEN to load.
    Snowpipe is like an automatic conveyor belt — files are loaded
    AUTOMATICALLY as soon as they land in S3.

    COPY INTO:  You run the command → files load → done
    Snowpipe:   File lands in S3 → S3 sends notification → Snowpipe 
                picks it up → loads automatically → no manual work!

    KEY DIFFERENCES:
    ┌─────────────────────┬──────────────────────┬──────────────────────┐
    │                     │ COPY INTO            │ SNOWPIPE             │
    ├─────────────────────┼──────────────────────┼──────────────────────┤
    │ Trigger             │ You run it manually  │ Automatic on file    │
    │                     │ or via Task          │ arrival              │
    │ Warehouse           │ YOUR warehouse       │ Snowflake-managed    │
    │                     │ (you pay per-second) │ serverless (pay per  │
    │                     │                      │ file)                │
    │ Best for            │ Bulk / batch loads   │ Continuous / real-   │
    │                     │                      │ time streaming       │
    │ Cost model          │ Warehouse credits    │ Serverless credits   │
    │                     │                      │ (based on file count │
    │                     │                      │ and size)            │
    └─────────────────────┴──────────────────────┴──────────────────────┘
*/


-- ============================================================================
-- SECTION 16: SNOWPIPE SETUP — STEP BY STEP (IN ORDER)
-- ============================================================================
/*
    STEP 1: Create a Storage Integration (connect Snowflake to S3)
    STEP 2: Create an External Stage (point to S3 bucket)
    STEP 3: Create a File Format
    STEP 4: Create the Target Table
    STEP 5: Create the Pipe
    STEP 6: Configure S3 Event Notifications (in AWS Console)
    STEP 7: Grant Permissions
    STEP 8: Test & Monitor
*/

-- STEP 1: Storage Integration (done once per S3 bucket)
/*
CREATE OR REPLACE STORAGE INTEGRATION MY_S3_INTEGRATION
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    ENABLED = TRUE
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/my-snowflake-role'
    STORAGE_ALLOWED_LOCATIONS = ('s3://my-data-bucket/');

-- Get Snowflake's AWS IAM user ARN and External ID
-- (You need these to configure the trust policy in AWS IAM)
DESC INTEGRATION MY_S3_INTEGRATION;
*/

-- STEP 2: External Stage
/*
CREATE OR REPLACE STAGE MY_S3_PIPE_STAGE
    URL = 's3://my-data-bucket/incoming/'
    STORAGE_INTEGRATION = MY_S3_INTEGRATION
    FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED');
*/

-- STEP 3: File Format (already created earlier, reuse it)
-- CSV_OPTIMIZED, PARQUET_OPTIMIZED, or JSON_OPTIMIZED

-- STEP 4: Target Table
/*
CREATE OR REPLACE TABLE PIPE_TARGET_TABLE (
    ORDER_ID        INT,
    ORDER_DATE      DATE,
    CUSTOMER_ID     INT,
    AMOUNT          DECIMAL(12,2),
    REGION          VARCHAR(50)
);
*/

-- STEP 5: Create the Pipe
/*
CREATE OR REPLACE PIPE MY_AUTO_PIPE
    AUTO_INGEST = TRUE
    AS
    COPY INTO PIPE_TARGET_TABLE
    FROM @MY_S3_PIPE_STAGE
    FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
    ON_ERROR = 'SKIP_FILE';
*/

-- STEP 6: Get the SQS queue ARN (to configure in AWS S3 console)
/*
SHOW PIPES LIKE 'MY_AUTO_PIPE';
-- Look at the "notification_channel" column — this is the SQS ARN
-- Go to AWS S3 → Bucket → Properties → Event Notifications → Create
--   Event type: s3:ObjectCreated:* (All object create events)
--   Destination: SQS Queue → paste the ARN from above
*/

-- STEP 7: Grant Permissions
/*
GRANT USAGE ON DATABASE my_db TO ROLE pipe_role;
GRANT USAGE ON SCHEMA my_db.public TO ROLE pipe_role;
GRANT INSERT, SELECT ON TABLE PIPE_TARGET_TABLE TO ROLE pipe_role;
GRANT USAGE ON STAGE MY_S3_PIPE_STAGE TO ROLE pipe_role;
GRANT OWNERSHIP ON PIPE MY_AUTO_PIPE TO ROLE pipe_role;
*/

-- STEP 8: Load any historical files already in S3
/*
ALTER PIPE MY_AUTO_PIPE REFRESH;
-- This queues ALL existing files in the stage path for loading
*/


-- ============================================================================
-- SECTION 17: MONITORING SNOWPIPE — HOW MANY FILES LOADED vs IN QUEUE
-- ============================================================================
/*
    THIS IS THE MOST COMMON QUESTION:
    "I have 10,000 files — how many are loaded and how many are waiting?"

    Snowflake provides multiple ways to check this:
*/

-- METHOD 1: SYSTEM$PIPE_STATUS — Real-time pipe status
/*
SELECT SYSTEM$PIPE_STATUS('MY_AUTO_PIPE');

-- Returns JSON like:
-- {
--   "executionState": "RUNNING",      ← Is the pipe running?
--   "pendingFileCount": 342,          ← FILES STILL IN QUEUE (waiting)
--   "oldestFileTimestamp": "...",      ← Oldest file waiting
--   "lastIngestedTimestamp": "...",    ← When last file was loaded
--   "lastIngestedFilePath": "...",     ← Which file was loaded last
--   "numOutstandingMessagesOnChannel": 500  ← Messages not yet processed
-- }

KEY FIELDS:
    pendingFileCount              → How many files are WAITING to be loaded
    executionState                → RUNNING, PAUSED, or error states
    lastIngestedTimestamp         → When the most recent file finished loading
    lastIngestedFilePath          → Name of the last successfully loaded file
    numOutstandingMessagesOnChannel → S3 notifications received but not processed yet
*/

-- METHOD 2: COPY_HISTORY — See loaded files with details
/*
SELECT 
    FILE_NAME,
    STATUS,
    ROW_COUNT,
    ROW_PARSED,
    FILE_SIZE,
    FIRST_ERROR_MESSAGE,
    ERROR_COUNT,
    PIPE_RECEIVED_TIME,
    LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'PIPE_TARGET_TABLE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC;

-- STATUS values:
-- 'Loaded'           → File loaded successfully
-- 'Load failed'      → File failed to load (check FIRST_ERROR_MESSAGE)
-- 'Partially loaded' → Some rows loaded, some had errors
-- 'Load skipped'     → File was already loaded before (duplicate)
*/

-- METHOD 3: Summary — count by status
/*
SELECT 
    STATUS,
    COUNT(*)                        AS FILE_COUNT,
    SUM(ROW_COUNT)                  AS TOTAL_ROWS_LOADED,
    SUM(ERROR_COUNT)                AS TOTAL_ERRORS
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'PIPE_TARGET_TABLE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
GROUP BY STATUS;

-- Example output:
-- STATUS            | FILE_COUNT | TOTAL_ROWS_LOADED | TOTAL_ERRORS
-- Loaded            | 9,500      | 45,000,000        | 0
-- Load failed       | 200        | 0                 | 200
-- Partially loaded  | 50         | 100,000           | 500
-- Load skipped      | 250        | 0                 | 0
*/

-- METHOD 4: VALIDATE_PIPE_LOAD — Get error details for failed files
/*
SELECT *
FROM TABLE(VALIDATE_PIPE_LOAD(
    PIPE_NAME => 'MY_AUTO_PIPE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
));
*/

-- METHOD 5: PIPE_USAGE_HISTORY — Snowpipe credit consumption
/*
SELECT 
    PIPE_NAME,
    START_TIME,
    END_TIME,
    CREDITS_USED,
    BYTES_INSERTED,
    FILES_INSERTED
FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP()),
    DATE_RANGE_END   => CURRENT_TIMESTAMP(),
    PIPE_NAME        => 'MY_AUTO_PIPE'
))
ORDER BY START_TIME DESC;
*/


-- ============================================================================
-- SECTION 18: ON_ERROR IN SNOWPIPE — HOW ERROR HANDLING WORKS
-- ============================================================================
/*
    IMPORTANT DIFFERENCE FROM COPY INTO:
    ─────────────────────────────────────
    In Snowpipe, you set ON_ERROR INSIDE the pipe definition.
    You CANNOT change it per load — it's fixed when the pipe is created.
    To change it, you must RECREATE the pipe.

    SUPPORTED ON_ERROR OPTIONS FOR SNOWPIPE:
    ┌──────────────────────┬──────────────────────────────────────────────┐
    │ Option               │ What Happens                                 │
    ├──────────────────────┼──────────────────────────────────────────────┤
    │ ABORT_STATEMENT      │ DEFAULT. If ANY row in a file has error,     │
    │                      │ the ENTIRE file is skipped. No partial load. │
    │ SKIP_FILE            │ Same as ABORT_STATEMENT for Snowpipe —       │
    │                      │ skips the file on first error.               │
    │ SKIP_FILE_<num>      │ Skip the file if number of errors >= <num>   │
    │                      │ e.g., SKIP_FILE_10 = skip if 10+ errors      │
    │ 'SKIP_FILE_<pct>%'   │ Skip if error % exceeds threshold            │
    │                      │ e.g., 'SKIP_FILE_5%' = skip if > 5% errors   │
    │ CONTINUE             │ Load good rows, SKIP bad rows.               │
    │                      │ File is partially loaded.                     │
    └──────────────────────┴──────────────────────────────────────────────┘

    NOTE: ABORT_STATEMENT and SKIP_FILE behave the SAME in Snowpipe.
    Both skip the entire file on error. There's no "abort the whole pipe" —
    Snowpipe always moves on to the next file.

    CHOOSING THE RIGHT OPTION:
    ──────────────────────────
    - Clean trusted data (internal systems)  → ABORT_STATEMENT (default)
    - Dirty external data (3rd party feeds)  → CONTINUE (load what you can)
    - Moderate tolerance                     → SKIP_FILE_10 or 'SKIP_FILE_5%'
*/

-- EXAMPLE: Pipe with CONTINUE (load good rows, skip bad)
/*
CREATE OR REPLACE PIPE MY_TOLERANT_PIPE
    AUTO_INGEST = TRUE
    AS
    COPY INTO PIPE_TARGET_TABLE
    FROM @MY_S3_PIPE_STAGE
    FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
    ON_ERROR = 'CONTINUE';
*/

-- EXAMPLE: Pipe with SKIP_FILE_10 (skip file if 10+ errors)
/*
CREATE OR REPLACE PIPE MY_MODERATE_PIPE
    AUTO_INGEST = TRUE
    AS
    COPY INTO PIPE_TARGET_TABLE
    FROM @MY_S3_PIPE_STAGE
    FILE_FORMAT = (FORMAT_NAME = 'CSV_OPTIMIZED')
    ON_ERROR = 'SKIP_FILE_10';
*/

-- FIND FILES THAT FAILED AND WHY:
/*
SELECT 
    FILE_NAME,
    STATUS,
    FIRST_ERROR_MESSAGE,
    ERROR_COUNT,
    ROW_COUNT,
    ROW_PARSED
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'PIPE_TARGET_TABLE',
    START_TIME => DATEADD('HOURS', -24, CURRENT_TIMESTAMP())
))
WHERE STATUS != 'Loaded'
ORDER BY LAST_LOAD_TIME DESC;
*/


-- ============================================================================
-- SECTION 19: COMMON SNOWPIPE ISSUES & FIXES
-- ============================================================================
/*
    ISSUE 1: Files not loading at all
    ──────────────────────────────────
    Check: SELECT SYSTEM$PIPE_STATUS('MY_AUTO_PIPE');
    
    - executionState = 'PAUSED'?
      → ALTER PIPE MY_AUTO_PIPE SET PIPE_EXECUTION_PAUSED = FALSE;
    
    - executionState = 'STOPPED_STAGE_DROPPED'?
      → Recreate the stage and pipe
    
    - lastReceivedMessageTimestamp is old/empty?
      → S3 event notification is misconfigured in AWS
      → Verify SQS ARN matches the pipe's notification_channel

    ISSUE 2: Duplicate data loaded
    ───────────────────────────────
    - Multiple pipes pointing to overlapping S3 paths
      → SHOW PIPES; and check COPY INTO definitions
      → Make sure paths don't overlap
    
    - Ran COPY INTO manually AND Snowpipe on same files
      → COPY INTO and Snowpipe have SEPARATE load tracking
      → Use one method or the other, not both

    ISSUE 3: Files loaded twice after modification
    ───────────────────────────────────────────────
    - Snowpipe tracks files by name for 14 DAYS
    - Same filename with different content within 14 days → SKIPPED
    - Same filename after 14 days → LOADED AGAIN (potential duplicates!)
    - Fix: Use unique file names (include timestamp in filename)

    ISSUE 4: Pipe is slow / high pending file count
    ────────────────────────────────────────────────
    - pendingFileCount is very high (thousands)?
      → Snowpipe scales automatically, but has limits
      → For burst loads, consider COPY INTO with a large warehouse instead
      → Snowpipe is designed for continuous streaming, not one-time bulk loads

    ISSUE 5: Large files not being detected
    ────────────────────────────────────────
    - Files uploaded with multipart upload to S3 generate
      S3:ObjectCreated:CompleteMultipartUpload events
    - If your S3 notification only listens for Put/Post/Copy,
      large files are MISSED
    - Fix: Set S3 event to "All object create events"

    ISSUE 6: CURRENT_TIMESTAMP shows wrong time in loaded data
    ──────────────────────────────────────────────────────────
    - Known issue: CURRENT_TIMESTAMP in pipe's COPY INTO evaluates
      at compile time, not at actual load time
    - Fix: Use METADATA$START_SCAN_TIME instead
*/


-- ============================================================================
-- SECTION 20: MANAGING SNOWPIPE
-- ============================================================================

-- Pause a pipe (stop loading new files)
-- ALTER PIPE MY_AUTO_PIPE SET PIPE_EXECUTION_PAUSED = TRUE;

-- Resume a pipe
-- ALTER PIPE MY_AUTO_PIPE SET PIPE_EXECUTION_PAUSED = FALSE;

-- Refresh: load files already in stage that pipe missed
-- ALTER PIPE MY_AUTO_PIPE REFRESH;

-- Refresh specific path
-- ALTER PIPE MY_AUTO_PIPE REFRESH PREFIX = '2026/05/';

-- View pipe definition
-- SHOW PIPES LIKE 'MY_AUTO_PIPE';

-- View all pipes
-- SHOW PIPES;

-- Drop a pipe
-- DROP PIPE MY_AUTO_PIPE;


-- ============================================================================
-- SECTION 21: SNOWPIPE MONITORING CHEAT SHEET
-- ============================================================================
/*
    ┌────────────────────────────────────────────────────────────────────────┐
    │ WHAT YOU WANT TO KNOW          │ QUERY TO RUN                        │
    ├────────────────────────────────────────────────────────────────────────┤
    │ How many files are waiting?     │ SYSTEM$PIPE_STATUS('pipe_name')     │
    │                                │ → pendingFileCount                  │
    │ Is the pipe running?           │ SYSTEM$PIPE_STATUS('pipe_name')     │
    │                                │ → executionState                    │
    │ Which files loaded/failed?     │ COPY_HISTORY (Information Schema)   │
    │                                │ → STATUS, FIRST_ERROR_MESSAGE       │
    │ How many files loaded today?   │ COPY_HISTORY with GROUP BY STATUS   │
    │ What errors occurred?          │ VALIDATE_PIPE_LOAD()                │
    │ How many credits did pipe use? │ PIPE_USAGE_HISTORY()                │
    │ What's the pipe definition?    │ SHOW PIPES LIKE 'pipe_name'        │
    │ Last file loaded?              │ SYSTEM$PIPE_STATUS → lastIngested   │
    │ Are S3 notifications working?  │ SYSTEM$PIPE_STATUS →                │
    │                                │ lastReceivedMessageTimestamp        │
    └────────────────────────────────────────────────────────────────────────┘
*/


-- ============================================================================
-- CLEANUP
-- ============================================================================
-- DROP TABLE SALES;
-- DROP TABLE SALES_WITH_METADATA;
-- DROP TABLE PIPE_TARGET_TABLE;
-- DROP PIPE MY_AUTO_PIPE;
-- DROP PIPE MY_TOLERANT_PIPE;
-- DROP PIPE MY_MODERATE_PIPE;
-- DROP FILE FORMAT CSV_OPTIMIZED;
-- DROP FILE FORMAT PARQUET_OPTIMIZED;
-- DROP FILE FORMAT JSON_OPTIMIZED;
-- DROP DATABASE LOADING_OPTIMIZATION_DEMO;
