# SNOWFLAKE COPY INTO: DEBUGGING, VALIDATION & FILE TRACKING
## How to debug errors, validate files, track loaded/remaining files

---

## 1. THE PROBLEM: COPY INTO FAILED — NOW WHAT?

You ran COPY INTO and got an error. Or it loaded "partially". Questions you need to answer:

1. **WHAT** went wrong? (which rows/columns/files had errors?)
2. **HOW MANY** files were loaded successfully?
3. **WHICH** files are still remaining (not loaded)?
4. **HOW** to fix and reload only the failed files?

### Snowflake gives you 5 tools:

| Tool | Purpose |
|------|---------|
| **VALIDATE()** | Get ALL errors from a specific COPY run |
| **VALIDATION_MODE** | Test files BEFORE actually loading |
| **COPY_HISTORY()** | See load history (last 14 days) |
| **LOAD_HISTORY view** | Same but as a view (10K row limit) |
| **ACCOUNT_USAGE.COPY_HISTORY** | Load history up to 365 days |

---

## 2. VALIDATE() — GET ALL ERRORS FROM A FAILED COPY

- **WHAT:** A table function that returns ALL errors from a COPY INTO run.
- **WHEN:** After a COPY INTO completes with errors (partial load or skip).
- **WHY:** COPY INTO only shows the FIRST error. VALIDATE() shows ALL of them.

**IMPORTANT RULES:**
- Only works if ON_ERROR was **NOT** ABORT_STATEMENT (the default!)
- You MUST use `ON_ERROR = CONTINUE` or `SKIP_FILE` for VALIDATE() to work
- The staged files must still exist at the same location
- Copy history metadata expires after 64 days

### Step 1: Run COPY with ON_ERROR = CONTINUE
```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/
FILE_FORMAT = my_csv_format
ON_ERROR = CONTINUE;
```

### Step 2: Get ALL errors from the LAST copy command in this session
```sql
SELECT * FROM TABLE(VALIDATE(my_db.my_schema.employees, JOB_ID => '_last'));
```

**Example result:**

| FILE | LINE | COLUMN | ROW_NUM | ERROR |
|------|------|--------|---------|-------|
| emp_01.csv | 45 | 3 | 44 | Numeric value 'abc' not valid |
| emp_01.csv | 102 | 5 | 101 | Date '31/13/2024' not recognized |
| emp_03.csv | 8 | 2 | 7 | NULL result in non-null column |

Now you know EXACTLY which file, line, column, and error to fix!

### Step 3: Use a specific QUERY_ID (from Query History in Snowsight)
```sql
SELECT * FROM TABLE(VALIDATE(
    my_db.my_schema.employees,
    JOB_ID => '01b2c3d4-e5f6-7890-abcd-ef1234567890'
));
```

### Step 4: Save errors to a table for analysis
```sql
CREATE OR REPLACE TABLE my_db.my_schema.load_errors AS
SELECT * FROM TABLE(VALIDATE(my_db.my_schema.employees, JOB_ID => '_last'));
```

### Step 5: Get count of errors per file
```sql
SELECT
    "FILE",
    COUNT(*) AS error_count,
    MIN("LINE") AS first_error_line,
    LISTAGG(DISTINCT "ERROR", ' | ') AS error_types
FROM TABLE(VALIDATE(my_db.my_schema.employees, JOB_ID => '_last'))
GROUP BY "FILE"
ORDER BY error_count DESC;
```

---

## 3. WHY VALIDATE() RETURNS EMPTY RESULTS

**COMMON GOTCHA:** You run VALIDATE() and get 0 rows. WHY?

| Reason | Explanation | Fix |
|--------|-------------|-----|
| **ON_ERROR = ABORT_STATEMENT** | The DEFAULT! COPY aborted on first error, no load job recorded | Re-run with `ON_ERROR = CONTINUE` or `SKIP_FILE` |
| **Used VALIDATION_MODE** | Tests files but doesn't load them. No load job = nothing to reference | Use VALIDATE() after actual COPY, not VALIDATION_MODE |
| **Staged files deleted/moved** | VALIDATE() needs original files at the same path | Ensure files are still on stage |
| **Metadata expired** | Copy history metadata expires after 64 days | Run within 64 days of the COPY |
| **Table was dropped/recreated** | Load history is tied to the table object. DROP removes it | Check before dropping |
| **Different session with '_last'** | `'_last'` refers to last COPY in CURRENT session only | Use the specific JOB_ID instead |

---

## 4. VALIDATION_MODE — TEST FILES BEFORE LOADING

- **WHAT:** Validates files WITHOUT loading any data.
- **WHEN:** BEFORE running the actual load (dry run / pre-flight check).
- **WHY:** Catch errors before they cause partial loads or failures.

**OPTIONS:**

| Option | What it does |
|--------|-------------|
| `RETURN_5_ROWS` | Parse first 5 rows and return them (preview) |
| `RETURN_ERRORS` | Return first error per file |
| `RETURN_ALL_ERRORS` | Return ALL errors across all files |

### Preview first 5 rows (see if parsing works)
```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/
FILE_FORMAT = my_csv_format
VALIDATION_MODE = 'RETURN_5_ROWS';
```

### Find ALL errors without loading anything
```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/
FILE_FORMAT = my_csv_format
VALIDATION_MODE = 'RETURN_ALL_ERRORS';
```

> NO DATA IS LOADED. The table remains untouched. This is your **PRE-FLIGHT CHECK**.

### Save validation errors and export bad records for fixing
```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/
FILE_FORMAT = my_csv_format
VALIDATION_MODE = 'RETURN_ALL_ERRORS';

SET qid = LAST_QUERY_ID();

COPY INTO @my_stage/errors/load_errors.csv
FROM (SELECT rejected_record FROM TABLE(RESULT_SCAN($qid)));
```

---

## 5. COPY_HISTORY() — TRACK WHAT FILES WERE LOADED (Last 14 days)

- **WHAT:** Information Schema table function showing load history.
- **WHEN:** To check which files loaded successfully, partially, or failed.
- **WHY:** Answer "what loaded and what didn't?"

**KEY COLUMNS:**

| Column | Purpose |
|--------|---------|
| FILE_NAME | Name of the source file |
| STATUS | `Loaded` / `Load failed` / `Partially loaded` / `Load skipped` |
| ROW_COUNT | Rows successfully loaded |
| ROW_PARSED | Rows parsed (attempted) |
| ERROR_COUNT | Number of errors in this file |
| FIRST_ERROR_MESSAGE | First error encountered |
| LAST_LOAD_TIME | When it was loaded |

### See ALL load activity for a table in the last 24 hours
```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(hours, -24, CURRENT_TIMESTAMP())
));
```

### Find FAILED and PARTIALLY LOADED files
```sql
SELECT
    FILE_NAME, STATUS, ROW_COUNT, ROW_PARSED,
    ERROR_COUNT, FIRST_ERROR_MESSAGE, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(days, -14, CURRENT_TIMESTAMP())
))
WHERE STATUS IN ('Load failed', 'Partially loaded', 'Load skipped')
ORDER BY LAST_LOAD_TIME DESC;
```

### Summary: how many files in each status
```sql
SELECT
    STATUS,
    COUNT(*) AS file_count,
    SUM(ROW_COUNT) AS total_rows_loaded,
    SUM(ERROR_COUNT) AS total_errors
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(days, -14, CURRENT_TIMESTAMP())
))
GROUP BY STATUS;
```

### For Snowpipe loads, filter by pipe name
```sql
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(days, -7, CURRENT_TIMESTAMP()),
    PIPE_NAME => 'MY_DB.MY_SCHEMA.MY_PIPE'
));
```

---

## 6. LOAD_HISTORY VIEW — ALTERNATIVE TO COPY_HISTORY()

- **WHAT:** Information Schema view (not function) for load history.
- **LIMIT:** Max 10,000 rows. Use COPY_HISTORY() for more.
- **WHEN:** Quick check for recent loads.

```sql
SELECT
    TABLE_NAME, FILE_NAME, STATUS, ROW_COUNT,
    ERROR_COUNT, FIRST_ERROR_MESSAGE, LAST_LOAD_TIME
FROM INFORMATION_SCHEMA.LOAD_HISTORY
WHERE TABLE_NAME = 'EMPLOYEES'
ORDER BY LAST_LOAD_TIME DESC
LIMIT 50;
```

---

## 7. ACCOUNT_USAGE.COPY_HISTORY — LONG-TERM HISTORY (365 days)

- **WHAT:** Account Usage view with up to 365 days of load history.
- **WHEN:** For auditing, long-term tracking, or historical analysis.
- **LATENCY:** Up to 2 hours behind real-time.

```sql
SELECT
    TABLE_NAME, FILE_NAME, STATUS, ROW_COUNT, ROW_PARSED,
    ERROR_COUNT, FIRST_ERROR_MESSAGE, LAST_LOAD_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE TABLE_NAME = 'EMPLOYEES'
  AND LAST_LOAD_TIME >= DATEADD(days, -30, CURRENT_TIMESTAMP())
ORDER BY LAST_LOAD_TIME DESC;
```

---

## 8. FIND FILES REMAINING IN S3 (NOT YET LOADED)

**PROBLEM:** You have 500 files in S3. Some loaded, some didn't. How to find which files are still remaining?

**APPROACH:**
1. LIST all files on the stage (what's in S3)
2. Query COPY_HISTORY (what's been loaded)
3. LEFT JOIN to find what's NOT been loaded

### Step 1: List ALL files on the external stage
```sql
LIST @my_external_stage/employees/;
```

### Step 2: Get all files on stage into a temp table
```sql
CREATE OR REPLACE TEMPORARY TABLE staged_files AS
SELECT
    "name" AS file_path,
    "size" AS file_size_bytes,
    "last_modified" AS last_modified
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
```

### Step 3: Get all successfully loaded files
```sql
CREATE OR REPLACE TEMPORARY TABLE loaded_files AS
SELECT DISTINCT
    FILE_NAME, STATUS, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(days, -14, CURRENT_TIMESTAMP())
))
WHERE STATUS = 'Loaded';
```

### Step 4: Find remaining (unloaded) files
```sql
SELECT
    s.file_path,
    s.file_size_bytes,
    s.last_modified,
    'NOT LOADED' AS load_status
FROM staged_files s
LEFT JOIN loaded_files l
    ON s.file_path LIKE '%' || l.FILE_NAME || '%'
WHERE l.FILE_NAME IS NULL
ORDER BY s.last_modified;
```

### Count: loaded vs remaining
```sql
SELECT
    CASE WHEN l.FILE_NAME IS NOT NULL THEN 'LOADED' ELSE 'REMAINING' END AS status,
    COUNT(*) AS file_count,
    SUM(s.file_size_bytes) AS total_bytes
FROM staged_files s
LEFT JOIN loaded_files l
    ON s.file_path LIKE '%' || l.FILE_NAME || '%'
GROUP BY status;
```

---

## 9. ALTERNATIVE: SIMPLER APPROACH WITH METADATA$FILENAME

If you just want to see what files have been loaded into the TABLE, you can use `METADATA$FILENAME` during the COPY INTO itself. Add a column to your target table that captures the source filename.

### Create table with a metadata column
```sql
CREATE OR REPLACE TABLE my_db.my_schema.employees (
    emp_id INT,
    first_name VARCHAR,
    last_name VARCHAR,
    salary NUMBER,
    hire_date DATE,
    source_file VARCHAR,          -- captures the filename
    load_timestamp TIMESTAMP      -- captures when it was loaded
);
```

### Load with METADATA$ columns
```sql
COPY INTO my_db.my_schema.employees (
    emp_id, first_name, last_name, salary, hire_date,
    source_file, load_timestamp
)
FROM (
    SELECT
        $1, $2, $3, $4, $5,
        METADATA$FILENAME,             -- source file path
        METADATA$START_SCAN_TIME       -- when Snowflake started reading
    FROM @my_stage/employees/
)
FILE_FORMAT = my_csv_format
ON_ERROR = CONTINUE;
```

### See which files were loaded
```sql
SELECT DISTINCT source_file, MIN(load_timestamp) AS loaded_at
FROM my_db.my_schema.employees
GROUP BY source_file
ORDER BY loaded_at;
```

### All available METADATA$ columns:

| Column | Description |
|--------|-------------|
| `METADATA$FILENAME` | Full path of the source file |
| `METADATA$FILE_ROW_NUMBER` | Row number within the file |
| `METADATA$FILE_CONTENT_KEY` | Content hash of the file |
| `METADATA$FILE_LAST_MODIFIED` | When the file was last modified |
| `METADATA$START_SCAN_TIME` | When Snowflake started reading the file |
| `METADATA$ISRAW` | Whether the file is raw (TRUE/FALSE) |

---

## 10. COMPLETE DEBUGGING WORKFLOW (Step-by-Step)

**SCENARIO:** You have 100 CSV files in S3 stage. COPY INTO failed.

### STEP 1: Run COPY with error tolerance
```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/
FILE_FORMAT = my_csv_format
ON_ERROR = CONTINUE;
-- Result: "50 files loaded, 30 partially loaded, 20 failed"
```

### STEP 2: Check the summary
```sql
SELECT
    STATUS, COUNT(*) AS file_count,
    SUM(ROW_COUNT) AS rows_loaded, SUM(ERROR_COUNT) AS errors
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(hours, -1, CURRENT_TIMESTAMP())
))
GROUP BY STATUS;
-- Shows: Loaded=50, Partially loaded=30, Load failed=20
```

### STEP 3: Get ALL error details
```sql
SELECT * FROM TABLE(VALIDATE(my_db.my_schema.employees, JOB_ID => '_last'));
```

### STEP 4: Categorize errors
```sql
SELECT
    "ERROR" AS error_type,
    COUNT(*) AS occurrences,
    LISTAGG(DISTINCT "FILE", ', ') AS affected_files
FROM TABLE(VALIDATE(my_db.my_schema.employees, JOB_ID => '_last'))
GROUP BY "ERROR"
ORDER BY occurrences DESC;
```

### STEP 5: Save errors to a table for the team
```sql
CREATE OR REPLACE TABLE my_db.my_schema.load_errors_2024_06 AS
SELECT *, CURRENT_TIMESTAMP() AS analyzed_at
FROM TABLE(VALIDATE(my_db.my_schema.employees, JOB_ID => '_last'));
```

### STEP 6: Find remaining files not yet loaded
```sql
LIST @my_stage/employees/;

SELECT
    s."name" AS staged_file,
    l.STATUS AS load_status,
    l.ERROR_COUNT,
    l.FIRST_ERROR_MESSAGE
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) s
LEFT JOIN TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(hours, -2, CURRENT_TIMESTAMP())
)) l
    ON s."name" LIKE '%' || l.FILE_NAME || '%';
```

### STEP 7: After fixing source files, reload ONLY the failed ones

**Option A:** Reload specific files
```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/emp_03.csv
FILE_FORMAT = my_csv_format
ON_ERROR = CONTINUE
FORCE = TRUE;        -- FORCE because Snowflake thinks it was already loaded
```

**Option B:** Use PATTERN to match failed files
```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/
FILE_FORMAT = my_csv_format
PATTERN = '.*(emp_03|emp_07|emp_15).*'
ON_ERROR = CONTINUE
FORCE = TRUE;
```

### STEP 8: Verify everything is loaded
```sql
SELECT
    STATUS, COUNT(*) AS files, SUM(ROW_COUNT) AS total_rows
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(hours, -4, CURRENT_TIMESTAMP())
))
GROUP BY STATUS;
```

---

## 11. SNOWFLAKE FILE LOAD TRACKING METADATA

### How Snowflake tracks loaded files:

When you run COPY INTO, Snowflake records metadata about each file:
- File name + path
- File size
- File content hash (ETag/checksum)
- Load timestamp
- Row count
- Error count

This metadata is stored for **64 DAYS**.

### What this means:

- If you run COPY INTO again on the **SAME files** → Snowflake **SKIPS** them (it knows they were already loaded based on the content hash)
- If a file is **MODIFIED** (different content) → Snowflake loads the new version
- If metadata **expires** (>64 days) → Snowflake isn't sure if it was loaded → Use `LOAD_UNCERTAIN_FILES = TRUE` to force loading

### This is why FORCE = TRUE exists:

- `FORCE = TRUE` overrides the metadata check
- Loads files even if they were already loaded
- **WARNING:** Creates DUPLICATE data if the file wasn't actually changed!

```sql
SELECT FILE_NAME, STATUS, ROW_COUNT, LAST_LOAD_TIME
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'EMPLOYEES',
    START_TIME => DATEADD(days, -14, CURRENT_TIMESTAMP())
))
WHERE FILE_NAME LIKE '%emp_03%';
```

---

## 12. PURGE — AUTO-DELETE FILES AFTER SUCCESSFUL LOAD

```sql
COPY INTO my_db.my_schema.employees
FROM @my_stage/employees/
FILE_FORMAT = my_csv_format
ON_ERROR = SKIP_FILE
PURGE = TRUE;
```

**PURGE = TRUE behavior:**
- Successfully loaded files → **DELETED** from stage
- Failed/skipped files → **REMAIN** on stage (not deleted)
- This is a safe way to track remaining files: whatever is still on stage = not loaded yet!

**WARNING:**
- Once purged, you cannot re-validate or re-load those files
- Only use PURGE when you have the files backed up elsewhere
- Or when you're confident the load is complete and correct

---

## 13. SUMMARY: WHICH TOOL WHEN?

| I want to... | Use this |
|-------------|----------|
| See ALL errors from a specific COPY run | `VALIDATE(table, JOB_ID => '_last')` (requires ON_ERROR != ABORT_STATEMENT) |
| Test files BEFORE loading (dry run) | `VALIDATION_MODE = 'RETURN_ALL_ERRORS'` (no data is loaded) |
| Check which files were loaded (last 14 days) | `COPY_HISTORY()` function (Information Schema, no row limit) |
| Quick load history (simple query) | `LOAD_HISTORY` view (Information Schema, 10K row limit) |
| Audit loads (up to 1 year) | `SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY` (up to 2hr latency) |
| Find unloaded files remaining on stage | `LIST @stage` + LEFT JOIN `COPY_HISTORY`. Or use `PURGE=TRUE` |
| Capture source filename in target table | `METADATA$FILENAME` in COPY INTO SELECT |
| Reload failed files after fixing them | `COPY INTO` with `FORCE=TRUE` + specific file path or PATTERN |
| Auto-delete files after successful load | `PURGE = TRUE` in COPY INTO (failed files remain on stage) |

---

## 14. INTERVIEW QUESTIONS

**Q1: Your COPY INTO failed. How do you debug it?**
> 1. Check COPY_HISTORY() for STATUS and FIRST_ERROR_MESSAGE.
> 2. Re-run with ON_ERROR=CONTINUE if it was ABORT_STATEMENT.
> 3. Run VALIDATE(table, JOB_ID => '_last') to get ALL errors.
> 4. Categorize errors by type and fix source files.
> 5. Reload failed files with FORCE=TRUE.

**Q2: What is the difference between VALIDATE() and VALIDATION_MODE?**
> VALIDATE() runs AFTER a COPY (returns errors from a past load). VALIDATION_MODE runs DURING a COPY (dry run, no data loaded). Use VALIDATION_MODE to test first, VALIDATE() to debug after.

**Q3: Why does VALIDATE() return empty results?**
> Most likely ON_ERROR = ABORT_STATEMENT was used (the default). VALIDATE() only works with ON_ERROR = CONTINUE or SKIP_FILE, because ABORT_STATEMENT rolls back the load job entirely.

**Q4: How do you find which files haven't been loaded yet?**
> LIST @stage to get all files, then LEFT JOIN with COPY_HISTORY() to find files with no matching load record. Or use PURGE=TRUE so loaded files are auto-deleted from stage.

**Q5: What is the 64-day metadata limit?**
> Snowflake tracks loaded files for 64 days. After that, it can't determine if a file was already loaded. Running COPY again may skip or re-load the file. Use LOAD_UNCERTAIN_FILES=TRUE to force loading of files with expired metadata.

**Q6: How do you reload only specific failed files?**
> `COPY INTO table FROM @stage/path/to/specific_file.csv FILE_FORMAT = my_format FORCE = TRUE;` FORCE=TRUE is needed because Snowflake thinks it was loaded.

**Q7: What METADATA$ columns are available during COPY?**
> METADATA$FILENAME, METADATA$FILE_ROW_NUMBER, METADATA$FILE_CONTENT_KEY, METADATA$FILE_LAST_MODIFIED, METADATA$START_SCAN_TIME. Useful for auditing and lineage.

**Q8: What is the difference between COPY_HISTORY function, LOAD_HISTORY view, and ACCOUNT_USAGE.COPY_HISTORY?**
> COPY_HISTORY() = 14 days, no row limit, includes Snowpipe loads. LOAD_HISTORY view = 14 days, 10K row limit, COPY only (no Snowpipe). ACCOUNT_USAGE.COPY_HISTORY = 365 days, up to 2hr latency.
