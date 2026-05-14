# Snowflake Stages — Complete Guide

**Internal, External, Directory Tables & Data Loading**

---

## Table of Contents

- [Part 1: Fundamentals](#part-1-fundamentals)
  - [1. What is a Stage?](#1-what-is-a-stage)
  - [2. The 3 Types of Internal Stages](#2-the-3-types-of-internal-stages)
  - [3. External Stages](#3-external-stages-s3-gcs-azure)
  - [4. Stage Reference Syntax Cheat Sheet](#4-stage-reference-syntax-cheat-sheet)
- [Part 2: Internal Stages](#part-2-internal-stages)
  - [5. User Stage (@~)](#5-user-stage-)
  - [6. Table Stage (@%table)](#6-table-stage-table)
  - [7. Named Internal Stage (@my_stage)](#7-named-internal-stage-my_stage)
  - [8. PUT — Upload Files](#8-put--upload-files-to-internal-stage)
  - [9. LIST — See What's in a Stage](#9-list--see-whats-in-a-stage)
  - [10. REMOVE — Delete Files](#10-remove--delete-files-from-a-stage)
  - [11. GET — Download Files](#11-get--download-files-from-a-stage)
- [Part 3: External Stages](#part-3-external-stages)
  - [12. Storage Integration](#12-storage-integration-best-practice)
  - [13. S3 External Stage](#13-creating-an-s3-external-stage)
  - [14. Azure External Stage](#14-creating-an-azure-external-stage)
  - [15. GCS External Stage](#15-creating-a-gcs-external-stage)
  - [16. Querying Files Directly](#16-querying-files-directly-on-external-stages)
- [Part 4: Loading Data (COPY INTO)](#part-4-loading-data-with-copy-into)
  - [17. Basic COPY INTO](#17-basic-copy-into-from-stage)
  - [18. COPY with File Format](#18-copy-with-file-format)
  - [19. COPY with Transformations](#19-copy-with-transformations)
  - [20. COPY with Pattern Matching](#20-copy-with-pattern-matching)
  - [21. COPY with Error Handling](#21-copy-with-error-handling-on_error)
  - [22. COPY with MATCH_BY_COLUMN_NAME](#22-copy-with-match_by_column_name)
- [Part 5: Unloading Data](#part-5-unloading-data-copy-into-location)
  - [23. Unload to Internal Stage](#23-unload-to-internal-stage)
  - [24. Unload to External Stage](#24-unload-to-external-stage)
  - [25. Unload as Parquet / JSON](#25-unload-as-parquet--json)
- [Part 6: Directory Tables](#part-6-directory-tables)
  - [26. What is a Directory Table?](#26-what-is-a-directory-table)
  - [27. Creating a Stage with Directory Table](#27-creating-a-stage-with-directory-table)
  - [28. Querying Directory Tables](#28-querying-directory-tables)
  - [29. Auto-Refresh vs Manual Refresh](#29-auto-refresh-vs-manual-refresh)
- [Part 7: Advanced Patterns](#part-7-advanced-patterns)
  - [30. INFER_SCHEMA](#30-infer_schema--auto-detect-file-schema)
  - [31. Schema Evolution](#31-schema-evolution-with-stages)
  - [32. Snowpipe Continuous Loading](#32-staging--snowpipe-continuous-loading)
- [Part 8: Metadata & Troubleshooting](#part-8-metadata--troubleshooting)
  - [33. Stage Metadata Queries](#33-stage-metadata-queries)
  - [34. Common Errors & Fixes](#34-common-errors--fixes)
  - [35. Best Practices Summary](#35-best-practices-summary)

---

## Part 1: Fundamentals

### 1. What is a Stage?

A stage is a **location** where data files sit before (or after) being loaded into Snowflake tables. Think of it as a "landing zone" for files.

Snowflake does **NOT** read from your local machine directly. Files must be in a stage first, then `COPY INTO` loads them into tables.

**The data loading flow:**

```
Local Files ──PUT──> Internal Stage ──COPY INTO──> Snowflake Table

Cloud Storage (S3/GCS/Azure) ──External Stage──COPY INTO──> Snowflake Table
```

Stages can hold **CSV, JSON, Parquet, Avro, ORC, and XML** files.

---

### 2. The 3 Types of Internal Stages

| Type | Reference | Scope | Created By |
|------|-----------|-------|------------|
| **User Stage** | `@~` | 1 user, N tables | Auto (per user) |
| **Table Stage** | `@%table` | N users, 1 table | Auto (per table) |
| **Named Stage** | `@my_stage` | N users, N tables | You (`CREATE STAGE`) |

- **User Stage:** Every user gets one automatically. Private to that user.
- **Table Stage:** Every table gets one automatically. Tied to that table.
- **Named Stage:** You create it. Most flexible. Can be shared via RBAC.

---

### 3. External Stages (S3, GCS, Azure)

External stages point to files in **your** cloud storage (outside Snowflake). Snowflake reads from the cloud location — files stay where they are.

| Provider | URL Format |
|----------|-----------|
| Amazon S3 | `s3://bucket/path/` |
| Google Cloud | `gcs://bucket/path/` |
| Azure Blob | `azure://account.blob.core.windows.net/container/path/` |

> **Authentication:** Use a STORAGE INTEGRATION (recommended) or direct credentials.

---

### 4. Stage Reference Syntax Cheat Sheet

| Reference | What It Points To |
|-----------|-------------------|
| `@~` | Current user's stage |
| `@~/path/` | Subfolder in user stage |
| `@%my_table` | Table stage for my_table |
| `@%my_table/path/` | Subfolder in table stage |
| `@my_named_stage` | Named internal or external stage |
| `@my_named_stage/path/` | Subfolder in named stage |
| `@db.schema.my_stage` | Fully qualified named stage |

---

## Part 2: Internal Stages

### 5. User Stage (@~)

Every user has one. Cannot be altered or dropped.

```sql
LIST @~;
COPY INTO my_table FROM @~ FILE_FORMAT = (TYPE = 'CSV');
```

---

### 6. Table Stage (@%table)

Every table has one. Cannot be altered or dropped. Only the table OWNER can use it. Only loads into **that** table.

```sql
LIST @%my_table;
COPY INTO my_table FROM @%my_table FILE_FORMAT = (TYPE = 'CSV');
```

---

### 7. Named Internal Stage (@my_stage)

Most flexible. You create it. Controlled via RBAC privileges.

```sql
CREATE OR REPLACE STAGE my_csv_stage
    FILE_FORMAT = (TYPE = 'CSV' FIELD_DELIMITER = ',' SKIP_HEADER = 1)
    COMMENT = 'Stage for CSV file loading';

CREATE OR REPLACE STAGE my_json_stage
    FILE_FORMAT = (TYPE = 'JSON' STRIP_OUTER_ARRAY = TRUE)
    COMMENT = 'Stage for JSON file loading';

CREATE OR REPLACE STAGE my_parquet_stage
    FILE_FORMAT = (TYPE = 'PARQUET')
    COMMENT = 'Stage for Parquet file loading';

-- With encryption (default is SNOWFLAKE_FULL = client + server side)
CREATE OR REPLACE STAGE my_secure_stage
    ENCRYPTION = (TYPE = 'SNOWFLAKE_FULL')
    COMMENT = 'Fully encrypted stage';

-- With server-side-only encryption (needed for pre-signed URL access)
CREATE OR REPLACE STAGE my_sse_stage
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
    COMMENT = 'Server-side encrypted stage for URL access';
```

---

### 8. PUT — Upload Files to Internal Stage

PUT uploads files from your **local machine** to an internal stage.

> **Note:** PUT only works from **SnowSQL CLI or drivers** — NOT from Snowsight UI.

**Syntax:**

```
PUT file://<local_path>/<filename> @<stage> [options]
```

**Examples (run from SnowSQL):**

```sql
-- Upload to named stage
PUT file:///tmp/data/employees.csv @my_csv_stage;

-- Upload to user stage
PUT file:///tmp/data/report.json @~;

-- Upload to table stage
PUT file:///tmp/data/orders.csv @%orders;

-- Upload with 8 parallel threads (faster for large files)
PUT file:///tmp/data/big_file.csv @my_csv_stage PARALLEL = 8;

-- Upload without auto-compression
PUT file:///tmp/data/employees.csv @my_csv_stage AUTO_COMPRESS = FALSE;

-- Upload and overwrite existing file
PUT file:///tmp/data/employees.csv @my_csv_stage OVERWRITE = TRUE;

-- Upload multiple files with wildcard
PUT file:///tmp/data/sales_*.csv @my_csv_stage;
```

---

### 9. LIST — See What's in a Stage

```sql
LIST @my_csv_stage;
LIST @~;
LIST @%my_table;

-- With pattern filter
LIST @my_csv_stage PATTERN = '.*employees.*';
```

---

### 10. REMOVE — Delete Files from a Stage

```sql
-- Remove a specific file
REMOVE @my_csv_stage/employees.csv.gz;

-- Remove all files matching a pattern
REMOVE @my_csv_stage PATTERN = '.*2023.*';

-- Remove all files
REMOVE @my_csv_stage;
```

---

### 11. GET — Download Files from a Stage

GET downloads files from an internal stage to your local machine. Like PUT, only works from **SnowSQL CLI**.

```sql
GET @my_csv_stage file:///tmp/downloads/;
GET @%my_table file:///tmp/downloads/;
GET @~ file:///tmp/downloads/;
```

---

## Part 3: External Stages

### 12. Storage Integration (Best Practice)

A storage integration delegates authentication to Snowflake's IAM entity. **No keys in SQL. No credentials in stage definitions.**

```sql
CREATE STORAGE INTEGRATION my_s3_int
    TYPE = EXTERNAL_STAGE
    STORAGE_PROVIDER = 'S3'
    STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/myrole'
    ENABLED = TRUE
    STORAGE_ALLOWED_LOCATIONS = ('s3://my-bucket/data/');

-- Get the IAM values for your trust policy:
DESCRIBE INTEGRATION my_s3_int;
```

---

### 13. Creating an S3 External Stage

```sql
-- With storage integration (recommended)
CREATE OR REPLACE STAGE my_s3_stage
    URL = 's3://my-bucket/data/'
    STORAGE_INTEGRATION = my_s3_int
    FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);

-- With direct credentials (not recommended for production)
CREATE OR REPLACE STAGE my_s3_stage_creds
    URL = 's3://my-bucket/data/'
    CREDENTIALS = (AWS_KEY_ID = 'AKIA...' AWS_SECRET_KEY = '...')
    FILE_FORMAT = (TYPE = 'CSV');
```

---

### 14. Creating an Azure External Stage

```sql
-- With storage integration
CREATE OR REPLACE STAGE my_azure_stage
    URL = 'azure://myaccount.blob.core.windows.net/mycontainer/data/'
    STORAGE_INTEGRATION = my_azure_int
    FILE_FORMAT = (TYPE = 'CSV');

-- With SAS token
CREATE OR REPLACE STAGE my_azure_stage_sas
    URL = 'azure://myaccount.blob.core.windows.net/mycontainer/data/'
    CREDENTIALS = (AZURE_SAS_TOKEN = '?sv=2021-06-08&...')
    FILE_FORMAT = (TYPE = 'CSV');
```

---

### 15. Creating a GCS External Stage

```sql
CREATE OR REPLACE STAGE my_gcs_stage
    URL = 'gcs://my-bucket/data/'
    STORAGE_INTEGRATION = my_gcs_int
    FILE_FORMAT = (TYPE = 'PARQUET');
```

---

### 16. Querying Files Directly on External Stages

You can query staged files **without** loading them first. Useful for previewing data.

```sql
-- Query CSV (columns referenced as $1, $2, $3...)
SELECT $1, $2, $3
FROM @my_s3_stage/employees.csv (FILE_FORMAT => 'my_csv_format')
LIMIT 10;

-- Query Parquet (reference column names directly)
SELECT $1:name::STRING, $1:age::INT
FROM @my_parquet_stage/data.parquet
LIMIT 10;

-- Query JSON
SELECT $1:event_type::STRING, $1:timestamp::TIMESTAMP
FROM @my_json_stage/events.json (FILE_FORMAT => 'my_json_format')
LIMIT 10;
```

---

## Part 4: Loading Data with COPY INTO

### 17. Basic COPY INTO from Stage

```sql
CREATE OR REPLACE TABLE employees (
    emp_id     INT,
    first_name VARCHAR(100),
    last_name  VARCHAR(100),
    salary     NUMBER(12,2),
    hire_date  DATE
);

-- Load from named stage
COPY INTO employees FROM @my_csv_stage;

-- Load from table stage
COPY INTO employees FROM @%employees;

-- Load specific file
COPY INTO employees FROM @my_csv_stage/employees_2024.csv;
```

---

### 18. COPY with File Format

```sql
-- Create named file format
CREATE OR REPLACE FILE FORMAT my_csv_format
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    SKIP_HEADER = 1
    NULL_IF = ('NULL', 'null', '')
    EMPTY_FIELD_AS_NULL = TRUE
    FIELD_OPTIONALLY_ENCLOSED_BY = '"';

-- Use named format
COPY INTO employees
FROM @my_csv_stage
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format');

-- Or inline format options
COPY INTO employees
FROM @my_csv_stage
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1 FIELD_DELIMITER = '|');
```

---

### 19. COPY with Transformations

You can reorder, omit, cast, and transform columns during load:

```sql
-- Reorder columns and cast types
COPY INTO employees (emp_id, first_name, last_name, salary, hire_date)
FROM (
    SELECT $1::INT, $3::VARCHAR, $2::VARCHAR, $4::NUMBER(12,2), $5::DATE
    FROM @my_csv_stage/employees.csv
)
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);

-- Omit columns (file has 10 cols, table has 5)
COPY INTO employees
FROM (SELECT $1, $2, $3, $5, $8 FROM @my_csv_stage)
FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);
```

---

### 20. COPY with Pattern Matching

```sql
-- Load only files matching a regex pattern
COPY INTO employees
FROM @my_csv_stage
PATTERN = '.*employees.*2024.*\.csv'
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format');

-- Load specific list of files
COPY INTO employees
FROM @my_csv_stage
FILES = ('employees_jan.csv', 'employees_feb.csv')
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format');
```

---

### 21. COPY with Error Handling (ON_ERROR)

| ON_ERROR Option | What It Does |
|-----------------|-------------|
| `ABORT_STATEMENT` | Abort entire load on first error (default) |
| `CONTINUE` | Skip bad rows, load the rest |
| `SKIP_FILE` | Skip any file that contains an error |
| `SKIP_FILE_<N>` | Skip file if errors > N |
| `SKIP_FILE_<N>%` | Skip file if error % > N% |

```sql
-- Skip bad rows
COPY INTO employees
FROM @my_csv_stage
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format')
ON_ERROR = 'CONTINUE';

-- Skip file if > 10 errors
COPY INTO employees
FROM @my_csv_stage
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format')
ON_ERROR = 'SKIP_FILE_10';

-- Validate without loading (dry run)
COPY INTO employees
FROM @my_csv_stage
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format')
VALIDATION_MODE = 'RETURN_ERRORS';

-- Return first 100 rows that would be loaded
COPY INTO employees
FROM @my_csv_stage
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format')
VALIDATION_MODE = 'RETURN_100_ROWS';
```

---

### 22. COPY with MATCH_BY_COLUMN_NAME

For Parquet/JSON/Avro/ORC — match file column names to table column names. **No need to worry about column ordering!**

```sql
COPY INTO employees
FROM @my_parquet_stage
FILE_FORMAT = (TYPE = 'PARQUET')
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE';
```

---

## Part 5: Unloading Data (COPY INTO \<location\>)

### 23. Unload to Internal Stage

```sql
-- Unload query results to named stage as CSV
COPY INTO @my_csv_stage/exports/employees_
FROM (SELECT * FROM employees WHERE hire_date >= '2024-01-01')
FILE_FORMAT = (TYPE = 'CSV' HEADER = TRUE)
OVERWRITE = TRUE;

-- Unload to user stage
COPY INTO @~/exports/report_
FROM (SELECT * FROM employees)
FILE_FORMAT = (TYPE = 'CSV' HEADER = TRUE);
```

---

### 24. Unload to External Stage

```sql
COPY INTO @my_s3_stage/exports/employees_
FROM employees
FILE_FORMAT = (TYPE = 'CSV' HEADER = TRUE COMPRESSION = 'GZIP');
```

---

### 25. Unload as Parquet / JSON

```sql
-- Unload as Parquet (columnar, compressed, ideal for analytics)
COPY INTO @my_csv_stage/exports/employees_
FROM employees
FILE_FORMAT = (TYPE = 'PARQUET');

-- Unload as JSON
COPY INTO @my_csv_stage/exports/employees_
FROM employees
FILE_FORMAT = (TYPE = 'JSON');
```

---

## Part 6: Directory Tables

### 26. What is a Directory Table?

A directory table is a **catalog of files** stored in a stage. It stores metadata: file path, size, last modified, ETag, etc.

**Useful for:**
- Querying what files exist in a stage
- Building pipelines that track file arrival
- Generating pre-signed URLs for unstructured data access

---

### 27. Creating a Stage with Directory Table

```sql
CREATE OR REPLACE STAGE my_dir_stage
    DIRECTORY = (ENABLE = TRUE)
    FILE_FORMAT = (TYPE = 'CSV' SKIP_HEADER = 1);

-- External stage with directory table + auto-refresh (S3)
CREATE OR REPLACE STAGE my_s3_dir_stage
    URL = 's3://my-bucket/data/'
    STORAGE_INTEGRATION = my_s3_int
    DIRECTORY = (
        ENABLE = TRUE
        AUTO_REFRESH = TRUE
    );

-- Add directory table to existing stage
ALTER STAGE my_csv_stage SET DIRECTORY = (ENABLE = TRUE);

-- Refresh directory table metadata (required after adding files)
ALTER STAGE my_dir_stage REFRESH;
```

---

### 28. Querying Directory Tables

```sql
SELECT * FROM DIRECTORY(@my_dir_stage);
```

**Useful columns:**

| Column | Description |
|--------|-------------|
| `RELATIVE_PATH` | File path within the stage |
| `SIZE` | File size in bytes |
| `LAST_MODIFIED` | Timestamp of last modification |
| `MD5` | MD5 hash of the file |
| `ETAG` | ETag for the file |
| `FILE_URL` | Scoped URL to the file |

---

### 29. Auto-Refresh vs Manual Refresh

| AUTO_REFRESH = TRUE | AUTO_REFRESH = FALSE (default) |
|---------------------|-------------------------------|
| Snowflake auto-updates metadata when files change in cloud | You run `ALTER STAGE ... REFRESH` manually |
| Requires event notification (S3 events, Azure Event Grid, GCS Pub/Sub) | No notification setup needed |
| Best for external stages with frequent changes | Good for internal stages or infrequent changes |

```sql
-- Manual refresh with subpath (faster for large stages)
ALTER STAGE my_s3_dir_stage REFRESH SUBPATH = '2024/05/';
```

---

## Part 7: Advanced Patterns

### 30. INFER_SCHEMA — Auto-Detect File Schema

Snowflake can read staged files and tell you column names and types. Supports: **Parquet, Avro, ORC, JSON, CSV** (with `PARSE_HEADER = TRUE`).

```sql
-- Detect schema from Parquet file
SELECT *
FROM TABLE(INFER_SCHEMA(
    LOCATION => '@my_parquet_stage/',
    FILE_FORMAT => 'my_parquet_format'
));

-- Auto-create table from detected schema
CREATE TABLE auto_table
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(INFER_SCHEMA(
            LOCATION => '@my_parquet_stage/',
            FILE_FORMAT => 'my_parquet_format'
        ))
    );
```

---

### 31. Schema Evolution with Stages

When source files gain new columns, Snowflake can **auto-add** them to your table:

```sql
ALTER TABLE my_table ENABLE SCHEMA_EVOLUTION;

COPY INTO my_table
FROM @my_parquet_stage
FILE_FORMAT = (TYPE = 'PARQUET')
MATCH_BY_COLUMN_NAME = 'CASE_INSENSITIVE';
-- New columns in the Parquet file are automatically added to the table!
```

---

### 32. Staging + Snowpipe (Continuous Loading)

Snowpipe auto-loads files as soon as they land in a stage. Uses **serverless compute** (no warehouse needed).

```sql
CREATE OR REPLACE PIPE my_pipe
    AUTO_INGEST = TRUE
AS
COPY INTO my_table
FROM @my_s3_stage
FILE_FORMAT = (FORMAT_NAME = 'my_csv_format');

-- Check pipe status
SELECT SYSTEM$PIPE_STATUS('my_pipe');

-- View copy history
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'my_table',
    START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP())
));
```

---

## Part 8: Metadata & Troubleshooting

### 33. Stage Metadata Queries

```sql
SHOW STAGES;
SHOW STAGES IN SCHEMA;
DESCRIBE STAGE my_csv_stage;

-- Recreatable DDL
SELECT GET_DDL('STAGE', 'my_csv_stage');

-- Copy history for a table (last 24 hours)
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'employees',
    START_TIME => DATEADD(HOUR, -24, CURRENT_TIMESTAMP())
));
```

---

### 34. Common Errors & Fixes

| Error | Cause | Fix |
|-------|-------|-----|
| **"File not found"** | File path is wrong or file not uploaded | Run `LIST @my_stage` to verify |
| **"Number of columns in file does not match"** | CSV has more/fewer columns than table | Set `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE` or use COPY transformations |
| **"Failed to cast variant value"** | Data type mismatch (string in NUMBER column) | Use `TRY_CAST` in transformation, or `ON_ERROR = CONTINUE` |
| **"PUT command not supported"** | PUT/GET only work from SnowSQL CLI | Use SnowSQL or Snowsight UI drag-and-drop |
| **"Access denied" on external stage** | Storage integration misconfigured | Run `DESCRIBE INTEGRATION` and verify IAM trust policy |
| **"Stage already has a directory table"** | Re-enabling directory table | Already enabled — run `ALTER STAGE ... REFRESH` instead |
| **COPY loads 0 rows (no error)** | Files already loaded (Snowflake tracks history) | Use `FORCE = TRUE` to reload, or PURGE old files |

---

### 35. Best Practices Summary

| Practice | Why |
|----------|-----|
| **Use NAMED stages** over user/table | RBAC, reusable, shareable |
| **Use STORAGE INTEGRATION** | No credentials in SQL |
| **Attach FILE_FORMAT to stage** | Don't repeat format in every COPY |
| **Compress files before upload** | Faster PUT, less storage |
| **Use 100-250 MB files** | Optimal for parallel loading |
| **Enable DIRECTORY TABLES** | Track file inventory |
| **Use VALIDATION_MODE before first load** | Dry-run catches errors early |
| **Use PURGE = TRUE in COPY** | Auto-delete files after load |
| **Use MATCH_BY_COLUMN_NAME** | Column order doesn't matter |
| **Never put credentials in SQL** | Use integrations instead |
| **Use ON_ERROR = CONTINUE for first run** | See all errors, not just the first |

---

*Built with Snowflake Stages — from file upload to production pipelines.*
