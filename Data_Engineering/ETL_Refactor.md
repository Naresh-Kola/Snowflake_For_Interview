# ETL Refactor: Legacy Job → Snowflake Stored Procedure

---

## 1. Background — What Did the Legacy ETL Job Do?

The legacy ETL job (built on DataStage / Automic) was responsible for loading **200+ small files (each ~15 KB)** from a source path into a target table, while **logging every file's status** at a granular level.

### Legacy ETL Flow (High Level)

```
START
  │
  ├── Generate ONE Batch ID for the whole batch
  ├── Insert into etl_batch table → Status = 'INPROGRESS'
  │
  └── FOR EACH FILE in source path:
        ├── Generate a File ID
        ├── Insert into log table → Status = 'INPROGRESS'
        ├── Add file into a FTM (Temporary File / File Transfer Mechanism)
        ├── IF data type error found:
        │     └── Update log table → Status = 'FAILED' + Raise error
        └── ELSE:
              └── Update log table → Status = 'SUCCESS'
  │
  ├── Merge all FTM files → One consolidated FTM file
  ├── Load consolidated FTM file → Target Table
  └── Update etl_batch table → Status = 'SUCCESS'
```

**Achievement:** This approach worked, but it was entirely file-by-file, loop-heavy, and tightly coupled to the IICS taskflow execution model.

---

## 2. The Problem in IICS (New System)

### Root Cause

IICS (Informatica Intelligent Cloud Services) has a **hard limit of 20,000 taskflows per ETL job**.

When processing 200+ files, each file triggers multiple taskflow invocations for:
- File pickup
- Data type validation
- Log updates (INPROGRESS → SUCCESS / FAILED)
- FTM staging

With a large number of files and multiple taskflow hops per file, the **20,000 taskflow ceiling is breached**, causing the job to be **suspended automatically by IICS**.

### Why Couldn't It Be Fixed Inside IICS?

The design was fundamentally **per-file and sequential inside a loop**. Each iteration triggered new taskflows. Restructuring inside IICS to avoid this would require a complete redesign anyway — so the decision was made to **move the core processing logic into a Snowflake Stored Procedure**, leaving only orchestration (batch ID generation, triggering the proc) in IICS.

---

## 3. The Solution — Snowflake Stored Procedure

### Design Philosophy Shift

| Aspect | Legacy ETL (IICS) | Snowflake Procedure |
|---|---|---|
| File loading | One file at a time in a loop | All files in ONE `COPY INTO` command |
| Validation | Per-file taskflow checks | Set-based SQL integrity checks on temp table |
| Logging | Per-file insert inside loop | Bulk insert outside loop using mapping table |
| Execution | 200+ taskflow hops | Single procedure call |
| Performance | Baseline | ~20x improvement |

---

## 4. Snowflake Procedure — Step-by-Step Implementation

### Step 1 — Bulk Load All Files into a Raw Temp Table

Instead of loading files one by one, a **single dynamic `COPY INTO` command** loads all files from the S3 stage path at once into a raw temp table.

#### Temp Table Structure

```sql
-- All columns are VARCHAR — no type enforcement yet at this stage
-- Two extra metadata columns are added:
--   file_name  → captured from S3 metadata
--   File_ID    → initialized to -9999 (will be updated later in Step 3)

CREATE OR REPLACE TEMP TABLE Raw_Data (
    Column1  VARCHAR,
    Column2  VARCHAR,   -- Will be validated as Number in Step 2
    Column3  VARCHAR,   -- Will be validated as Date in Step 2
    file_name VARCHAR,
    File_ID   INTEGER
);
```

#### Dynamic COPY Command

```sql
-- The S3 path is passed as input parameter to the procedure
-- metadata$file_name captures which S3 file each row came from
-- File_ID is seeded as -9999 (placeholder — real IDs assigned in Step 3)

Copy_query := 'COPY INTO Raw_Data
    SELECT $1, $2, $3,
           metadata$file_name AS file_name,
           -9999              AS File_ID
    FROM @NYHPETL_INBOUND_STAGE/' || :input_S3_Folder_Path ||
   ' FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = '','')';

Copy_Res := EXECUTE IMMEDIATE Copy_query;
```

> **Key Design Point:** `Copy_Res` (the resultset from COPY INTO) contains **per-file stats** — file name + row count loaded per file. This resultset is reused in Step 3 for logging.

---

### Step 2 — Data Integrity Check (Set-Based Validation)

Instead of validating per file inside a loop, **one SQL query scans the entire Raw_Data table** and flags all bad rows in a single pass.

#### Part A — Identify Bad Records

The function `TRY_TO_DATE()` and `TRY_TO_NUMBER()` return `NULL` when the value cannot be converted. This is used to filter invalid rows.

```sql
-- LIMIT 1: Even a single bad record fails the whole load
-- File_name is included so we know WHICH file caused the problem

CREATE OR REPLACE TEMP TABLE tmp_errors AS
SELECT
    Column2,
    Column3,
    TRY_TO_NUMBER(Column2)           IS NULL AS Column2_is_Invalid,
    TRY_TO_DATE(Column3, 'YYYYMMDD') IS NULL AS Column3_is_Invalid,
    file_name
FROM Raw_Data
WHERE TRY_TO_NUMBER(Column2)           IS NULL
   OR TRY_TO_DATE(Column3, 'YYYYMMDD') IS NULL
LIMIT 1;
```

**Why `TRY_TO_DATE` and not `TO_DATE`?**

| Function | Behavior on bad data |
|---|---|
| `TO_DATE('20260135','YYYYMMDD')` | Throws exception — hard to control |
| `TRY_TO_DATE('20260135','YYYYMMDD')` | Returns `NULL` — safe to filter on |

```sql
-- Example behavior:
SELECT TRY_TO_DATE('20260210', 'YYYYMMDD');  -- Returns: 2026-02-10  ✅
SELECT TRY_TO_DATE('20260135', 'YYYYMMDD');  -- Returns: NULL        ❌ (day 35 doesn't exist)
```

#### Part B — Raise a Descriptive Exception

If `tmp_errors` has rows, a **dynamic exception** is constructed with the file name and the exact bad value per column, so developers debugging know exactly what failed.

```sql
-- Extract values from tmp_errors
Column2_data       := (SELECT Column2             FROM tmp_errors);
Column3_data       := (SELECT Column3             FROM tmp_errors);
Column2_is_Invalid := (SELECT Column2_is_Invalid  FROM tmp_errors);
Column3_is_Invalid := (SELECT Column3_is_Invalid  FROM tmp_errors);
File_name          := (SELECT file_name           FROM tmp_errors);

error_msg := '';

-- Build error message dynamically based on which columns failed
IF (Column2_is_Invalid) THEN
    error_msg := 'Invalid data found: cannot parse ''' || Column2_data || ''' to Number';
END IF;

IF (Column3_is_Invalid) THEN
    error_msg := error_msg || '\r\n' ||
                 'Invalid data found: cannot parse ''' || Column3_data ||
                 ''' to date ''YYYYMMDD'' from file ' || File_name;
END IF;

-- Raise a custom Snowflake exception dynamically
Dynamic_exception_query :=
    'DECLARE
         invalid_data_exception EXCEPTION (-20001, ''' || :error_msg || ''');
     BEGIN
         RAISE invalid_data_exception;
     END;';

EXECUTE IMMEDIATE :Dynamic_exception_query;
```

**Example error messages raised:**

```
-- Only Column3 bad:
Invalid data found: cannot parse '20260135' to date 'YYYYMMDD' from file file1.csv

-- Both columns bad:
Invalid data found: cannot parse '123abc' to Number
Invalid data found: cannot parse '20260135' to date 'YYYYMMDD' from file file1.csv
```

---

### Step 3 — Generate File IDs and Log Each File (INPROGRESS)

This is the most important optimization over the legacy design.

#### The Problem with a Naive Loop

A straightforward loop doing 3 operations per file:
1. Generate File_ID
2. INSERT into log table
3. UPDATE Raw_Data

...would be slow for 200+ files because each iteration hits the database separately.

#### The Optimized Pattern — Minimize Work Inside the Loop

Only **one lightweight INSERT** happens inside the loop (into a temp mapping table). All heavy operations happen **outside the loop in bulk**.

```sql
-- Step 3a: Create a mapping table to hold file_name → File_ID pairs
CREATE OR REPLACE TEMP TABLE File_ID_Mapping (
    file_name  VARCHAR,
    File_ID    NUMBER
);

-- Step 3b: Loop over the COPY result — one insert per iteration (fast)
FOR record IN Copy_Res LOOP
    file_name := record.file_name;
    File_ID   := File_ID_seq.NEXTVAL;   -- Pull next value from existing DB sequence

    INSERT INTO File_ID_Mapping
    SELECT :file_name, :File_ID;
END LOOP;

-- Step 3c: BULK insert into log table OUTSIDE the loop (one statement for all files)
INSERT INTO File_history_log_table (File_ID, file_name, Status)
SELECT File_ID, file_name, 'INPROGRESS'
FROM File_ID_Mapping;

-- Step 3d: BULK update Raw_Data with real File_IDs (replaces the -9999 placeholders)
UPDATE Raw_Data raw
SET    raw.File_ID = map.File_ID
FROM   File_ID_Mapping map
WHERE  raw.file_name = map.file_name;
```

---

### Step 4 — Load Data from Temp Table into Target Table

Once Raw_Data has real File_IDs and all data is validated, a single INSERT moves everything to the target.

```sql
INSERT INTO <target_table_name> (column1, column2, column3, file_name, File_ID)
SELECT Column1, Column2, Column3, file_name, File_ID
FROM Raw_Data;
```

---

### Step 5 — Update Log Table to SUCCESS

After successful load, **all file statuses are updated in one bulk statement**.

```sql
UPDATE File_history_log_table log
SET    Status = 'SUCCESS'
FROM   File_ID_Mapping map
WHERE  log.File_ID = map.File_ID;
```

---

## 5. Log Tables — What They Are and Why They Exist

This is the backbone of **auditability and operability** of the pipeline. Two log tables are used.

### Table 1: `etl_batch` — Batch-Level Logging

| Column | Purpose |
|---|---|
| `ETL_BATCH_ID` | Unique ID for the entire batch run |
| `Status` | `INPROGRESS` → `SUCCESS` / `FAILED` |
| `Start_Time` | When the batch started |
| `End_Time` | When it completed |

**Why it exists:**
- Tracks the **overall health** of each batch run
- Used by schedulers (Automic / Control-M) to detect failures
- Enables reprocessing — if batch status is `FAILED`, the batch can be re-triggered
- Managed by the **IICS ETL job** (not the SF procedure) because batch orchestration stays at the pipeline layer

---

### Table 2: `File_history_log_table` — File-Level Logging

| Column | Purpose |
|---|---|
| `File_ID` | Unique ID per file (generated from sequence) |
| `file_name` | S3 file name (from `metadata$file_name`) |
| `Status` | `INPROGRESS` → `SUCCESS` / `FAILED` |

**Why it exists:**

1. **Granular failure tracking** — if 5 out of 200 files fail, you know exactly which 5
2. **Auditability** — you can trace every file that was ever processed, when, and what happened
3. **Idempotency support** — if a file was already processed (`SUCCESS`), upstream logic can skip it on reruns
4. **Debugging** — combined with the error raised in Step 2, developers see file name + bad column + bad value

**Why status starts as `INPROGRESS` before the load:**

Because if the procedure crashes mid-execution (e.g., in Step 4), files in the log table remain `INPROGRESS` — not `SUCCESS`. This correctly signals that **the load did not complete** for those files, enabling safe reruns without silent data corruption.

---

## 6. Overall Flow Summary

```
IICS ETL Job
  │
  ├── Generate ETL_BATCH_ID
  ├── Insert into etl_batch → Status = 'INPROGRESS'
  └── CALL Snowflake Stored Procedure (S3_path, batch_id)
            │
            ├── STEP 1: COPY INTO Raw_Data (all files at once)
            │           └── Capture Copy_Res (file stats resultset)
            │
            ├── STEP 2: Data Integrity Check
            │           ├── Create tmp_errors (TRY_TO_ functions)
            │           └── IF errors → Raise detailed exception (STOP)
            │
            ├── STEP 3: File ID Generation + Logging
            │           ├── Loop over Copy_Res → populate File_ID_Mapping
            │           ├── BULK INSERT → File_history_log_table (INPROGRESS)
            │           └── BULK UPDATE → Raw_Data (assign real File_IDs)
            │
            ├── STEP 4: INSERT Raw_Data → Target Table
            │
            └── STEP 5: BULK UPDATE File_history_log_table → 'SUCCESS'

IICS ETL Job (resumes after proc returns)
  └── Update etl_batch → Status = 'SUCCESS'
```

---

## 7. Key Takeaways

| Design Decision | Reason |
|---|---|
| All-VARCHAR temp table | Defer type enforcement; validate in SQL after load |
| `metadata$file_name` in COPY | Know which S3 file each row came from without extra joins |
| File_ID seeded as -9999 | Safe placeholder; overwritten before target insert |
| One INSERT inside loop (mapping table) | Minimize DB round-trips; bulk ops outside loop |
| `TRY_TO_DATE` / `TRY_TO_NUMBER` | NULL-safe validation without exception handling noise |
| Dynamic exception with file + column detail | Developers can debug failures without querying tables |
| INPROGRESS status before load | Crash-safe; prevents silent success on partial runs |
| Batch logging in IICS, file logging in SF proc | Separation of concerns — orchestration vs. data processing |
