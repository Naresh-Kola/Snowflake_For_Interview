# GP → S3 Export: Complete Code Explanation

## Overview

This script exports **450 tables from Greenplum (GP) to Amazon S3** using Python **multiprocessing** and GP's **Writable External Tables**. Multiple worker processes run in parallel, each exporting different tables simultaneously.

### Architecture Diagram

```
Main Process (1)
  │
  ├── 1. Fetches all 450 table names from GP
  ├── 2. Builds a task list (one dict per table)
  ├── 3. Launches a Pool of N worker processes
  │       ├── Worker 1 → exports tables 1..112
  │       ├── Worker 2 → exports tables 113..225
  │       ├── Worker 3 → exports tables 226..337
  │       └── Worker 4 → exports tables 338..450
  ├── 4. Collects all results
  └── 5. Writes summary CSV + prints report
```

---

## Section 1: Imports

```python
import multiprocessing    # spawn parallel worker processes
import psycopg2           # PostgreSQL/Greenplum database driver
import logging            # structured log messages with severity levels
import time               # measure elapsed time with time.time()
import csv                # read/write CSV files
import os                 # access environment variables, file paths
import re                 # regular expressions for sanitizing strings
import argparse           # parse command-line arguments (--workers, --schema, etc.)
from datetime import datetime  # timestamps for S3 paths and filenames
```

---

## Section 2: Configuration

### DB_CONFIG — Database Connection Settings

```python
DB_CONFIG = {
    "host"    : os.getenv("GP_HOST",     "your-greenplum-host"),
    "port"    : int(os.getenv("GP_PORT", "5432")),
    "dbname"  : os.getenv("GP_DBNAME",   "your_database"),
    "user"    : os.getenv("GP_USER",     "your_user"),
    "password": os.getenv("GP_PASSWORD", "your_password"),
    "connect_timeout": 30,
}
```

**Key syntax — `os.getenv(name, default)`:**
- Reads an environment variable
- If the variable isn't set, uses the default value
- This lets you configure the script via env vars (secure) or fall back to hardcoded defaults (development)

```
os.getenv("GP_HOST", "your-greenplum-host")
         ↑ env var     ↑ fallback value
```

**Why `int(os.getenv(...))`?**
- `os.getenv()` always returns a **string** (e.g. `"5432"`)
- `int()` converts it to an integer since the port must be a number

### S3_CONFIG — S3 Destination Settings

```python
S3_CONFIG = {
    "bucket"    : os.getenv("S3_BUCKET",    "your-s3-bucket"),
    "prefix"    : os.getenv("S3_PREFIX",    "gp-exports"),
    "region"    : os.getenv("S3_REGION",    "us-east-1"),
    "access_key": os.getenv("AWS_ACCESS_KEY_ID",     ""),
    "secret_key": os.getenv("AWS_SECRET_ACCESS_KEY", ""),
}
```

- `bucket` — S3 bucket name (e.g. `my-data-lake`)
- `prefix` — folder path inside the bucket
- `access_key` / `secret_key` — AWS credentials (empty string = use IAM role instead)

### EXPORT_CONFIG — Export Behavior Settings

```python
EXPORT_CONFIG = {
    "schema"         : "public",
    "num_workers"    : 4,
    "format"         : "CSV",
    "delimiter"      : ",",
    "include_header" : True,
    "output_dir"     : "exports",
    "log_level"      : "INFO",
    "dry_run"        : False,
}
```

- `num_workers: 4` — run 4 parallel processes
- `dry_run: False` — when `True`, prints SQL without executing (safe testing)

---

## Section 3: Logging Setup

### setup_logging()

```python
def setup_logging(level: str = "INFO"):
    log_format = "%(asctime)s [%(processName)-20s] %(levelname)-7s %(message)s"
    logging.basicConfig(
        level   = getattr(logging, level.upper(), logging.INFO),
        format  = log_format,
        handlers= [
            logging.StreamHandler(),
            logging.FileHandler("gp_export.log", mode="a"),
        ],
    )
```

**Parameter type hint — `level: str = "INFO"`:**
- `: str` tells readers the parameter should be a string
- `= "INFO"` is the default value if no argument is passed

**`getattr(logging, level.upper(), logging.INFO)`:**
- `getattr(object, name, default)` gets an attribute by name from an object
- `logging.INFO` is the same as `getattr(logging, "INFO")` which equals `20`
- This converts the string `"INFO"` into the actual constant `logging.INFO`
- If an invalid level is passed, falls back to `logging.INFO`

**Format string — `%(processName)-20s`:**
- `-20s` means left-aligned, padded to 20 characters
- This keeps log lines aligned even when process names differ in length

```
2025-05-17 10:30:45 [MainProcess          ] INFO    Starting...
2025-05-17 10:30:46 [ForkPoolWorker-1     ] INFO    Exporting...
                     ↑ always 20 chars wide ↑
```

**`handlers` — where logs go:**
- `StreamHandler()` → prints to terminal (stdout)
- `FileHandler("gp_export.log", mode="a")` → appends to a log file
- Both receive every log message simultaneously

### get_logger()

```python
def get_logger() -> logging.Logger:
    return logging.getLogger(__name__)
```

**Return type hint — `-> logging.Logger`:**
- Tells readers this function returns a Logger object
- Purely informational — Python doesn't enforce it

---

## Section 4: Database Helpers

### get_connection()

```python
def get_connection() -> psycopg2.extensions.connection:
    return psycopg2.connect(**DB_CONFIG)
```

A thin wrapper so every function calls the same connection logic. Each worker calls this independently — **database connections must never be shared across processes**.

### get_all_tables()

```python
def get_all_tables(schema: str) -> list[dict]:
```

**Return type — `list[dict]`:**
- Returns a list of dictionaries
- Each dict represents one table

**The SQL query:**

```sql
SELECT
    t.table_schema,
    t.table_name,
    pg_catalog.pg_relation_size(
        pg_catalog.quote_ident(t.table_schema) || '.' ||
        pg_catalog.quote_ident(t.table_name)
    ) AS size_bytes,
    c.reltuples::BIGINT AS estimated_rows
FROM information_schema.tables t
JOIN pg_catalog.pg_class      c ON c.relname = t.table_name
JOIN pg_catalog.pg_namespace  n ON n.oid = c.relnamespace
                               AND n.nspname = t.table_schema
WHERE t.table_schema = %s
  AND t.table_type   = 'BASE TABLE'
ORDER BY t.table_name
```

- `information_schema.tables` — standard catalog of all tables
- `pg_class` — PostgreSQL internal catalog with stats (row estimates, size)
- `pg_namespace` — maps schemas to their internal OIDs
- `JOIN` combines these to get table name + size + row estimate in one query
- `quote_ident()` safely quotes identifiers (prevents issues with special characters)
- `||` is string concatenation in SQL: `'public' || '.' || 'orders'` = `'public.orders'`
- `::BIGINT` is a PostgreSQL type cast (like `CAST(x AS BIGINT)`)

**Building the result list:**

```python
tables = [
    {
        "schema"        : r[0],
        "table"         : r[1],
        "full_name"     : f"{r[0]}.{r[1]}",
        "size_bytes"    : r[2] or 0,
        "estimated_rows": r[3] or 0,
    }
    for r in rows
]
```

- List comprehension that builds one dict per row
- `r[2] or 0` — if `r[2]` is `None` (null), use `0` instead
- This is Python's "truthy" shortcut: `None or 0` evaluates to `0`

### get_column_definitions()

```python
def get_column_definitions(cursor, full_table_name: str) -> str:
    schema, table = full_table_name.split(".", 1)
```

**`split(".", 1)`:**
- Splits string at the first dot only
- `"public.orders".split(".", 1)` → `["public", "orders"]`
- The `1` limits it to one split (important if table names contain dots)

**Column type mapping:**

```python
if data_type == "character varying":
    type_str = f"VARCHAR({char_len})" if char_len else "TEXT"
```

- Ternary syntax: `value_if_true if condition else value_if_false`
- Converts `information_schema` type names to GP-compatible SQL types

**Returns:** `"id INTEGER, name VARCHAR(100), created_at TIMESTAMP"`

---

## Section 5: S3 Path Builder

```python
def build_s3_location(table_info: dict, cfg: dict) -> str:
    today = datetime.now().strftime("%Y-%m-%d")
```

**`strftime("%Y-%m-%d")`:**
- Formats a datetime as a string
- `%Y` = 4-digit year, `%m` = month, `%d` = day
- Result: `"2025-05-17"`

**`rstrip("/")`:**
- Removes trailing `/` from the right side of a string
- `"gp-exports/"` → `"gp-exports"`

**Output example:**
```
s3://my-bucket/gp-exports/2025-05-17/public/orders/orders_*.csv
```

The `*` wildcard tells GP to create one file per segment (parallel writes).

---

## Section 6: The Worker Function — `export_table()`

This is the core function that each worker process calls for every table.

```python
def export_table(task: dict) -> dict:
```

### Step 6.1: Sanitize Table Name

```python
safe_ext_name = f"ext_writable_{re.sub(r'[^a-zA-Z0-9_]', '_', table)}"
```

**`re.sub(pattern, replacement, string)`:**
- Replaces all matches of the regex pattern with the replacement
- `[^a-zA-Z0-9_]` matches any character that is NOT a letter, digit, or underscore
- Replaces those characters with `_`
- `"my-table.v2"` → `"ext_writable_my_table_v2"`
- Prevents SQL injection by removing special characters

### Step 6.2: Connection with Autocommit

```python
conn = get_connection()
conn.autocommit = True
```

- DDL statements (`CREATE`, `DROP`) require autocommit mode
- Without it, GP waits for an explicit `COMMIT` that never comes

### Step 6.3: Build the CREATE WRITABLE EXTERNAL TABLE SQL

```sql
CREATE WRITABLE EXTERNAL TABLE ext_writable_orders (
    id INTEGER, name VARCHAR(100), amount NUMERIC
)
LOCATION ('s3://bucket/path/orders_*.csv')
FORMAT 'CSV' (
    DELIMITER ','
    HEADER
    NULL ''
)
DISTRIBUTED RANDOMLY
```

**What this does:**
- Creates a "shell" table in GP's catalog — **no data moves yet**
- `WRITABLE` means data flows OUT (GP → S3), not in
- `LOCATION` tells GP where to write the files
- `DISTRIBUTED RANDOMLY` — rows are spread evenly across segments

### Step 6.4: The INSERT That Moves Data

```sql
INSERT INTO ext_writable_orders
SELECT * FROM public.orders
```

**This is the magic line.** When you INSERT into a writable external table:
- Each GP segment reads its local slice of `public.orders`
- Each segment writes directly to S3 in parallel
- Data does NOT flow through the master node
- 450 tables × multiple segments = massive parallel throughput

### Step 6.5: Cleanup

```python
cursor.execute(f"DROP EXTERNAL TABLE IF EXISTS {safe_ext_name}")
```

- Removes the external table **shell** from GP's catalog
- The S3 files remain — we only delete the GP definition

### Step 6.6: Error Handling

```python
except Exception as exc:
    # ... log error ...
    try:
        conn2 = get_connection()
        conn2.autocommit = True
        cur2 = conn2.cursor()
        cur2.execute(f"DROP EXTERNAL TABLE IF EXISTS {safe_ext_name}")
        conn2.close()
    except Exception:
        pass
```

- If export fails, attempts best-effort cleanup (drop the external table shell)
- Uses a **new connection** (`conn2`) because the original may be broken
- `pass` in the inner except — cleanup failure is non-fatal
- Returns an error dict so the pool continues with remaining tables

---

## Section 7: Result Reporting

### write_summary_csv()

```python
os.makedirs(output_dir, exist_ok=True)
```

- Creates the output directory (and parents) if it doesn't exist
- `exist_ok=True` — don't error if it already exists

```python
with open(filepath, "w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(results)
```

- `csv.DictWriter` writes dicts as CSV rows using the keys as column headers
- `writeheader()` writes the header row
- `writerows(results)` writes all result dicts at once

### print_summary()

```python
ok     = [r for r in results if r["status"] == "ok"]
failed = [r for r in results if r["status"] == "error"]
```

- List comprehensions that filter results by status
- Produces a formatted report like:

```
============================================================
  GP → S3 EXPORT SUMMARY
============================================================
  Total tables   : 450
  Successful     : 448
  Failed         : 2
  Total rows     : 12,345,678
  Workers used   : 4
  Wall clock time: 342.5s
  Avg per table  : 3.05s
============================================================
```

---

## Section 8: Argument Parser

```python
parser.add_argument("--workers", type=int, default=EXPORT_CONFIG["num_workers"],
                    help="Number of parallel worker processes")
parser.add_argument("--dry-run", action="store_true",
                    help="Print SQL without executing")
```

**`action="store_true"`:**
- If `--dry-run` flag is present → `args.dry_run = True`
- If flag is absent → `args.dry_run = False`
- No value needed — it's a boolean flag

**Usage:**
```bash
python gp_to_s3_export.py                          # defaults
python gp_to_s3_export.py --workers 8 --schema sales
python gp_to_s3_export.py --dry-run                 # test without exporting
python gp_to_s3_export.py --table public.orders      # single table only
```

---

## Section 9: Main Entry Point

### `if __name__ == "__main__":`

This block runs ONLY when the script is executed directly (`python script.py`), NOT when imported as a module.

### Step 9.1: Build Task List

```python
tasks = [
    {
        **table_info,
        "dry_run"      : EXPORT_CONFIG["dry_run"],
        "s3_config"    : S3_CONFIG,
        "export_config": EXPORT_CONFIG,
    }
    for table_info in all_tables
]
```

**`**table_info` (dict unpacking):**
- Spreads all key-value pairs from `table_info` into the new dict
- Combined with the additional keys, each task dict is self-contained
- Workers have NO shared state — everything they need is in this dict

### Step 9.2: Launch the Pool

```python
with multiprocessing.Pool(
    processes=EXPORT_CONFIG["num_workers"],
    maxtasksperchild=10,
) as pool:
    results = pool.map(export_table, tasks)
```

**`multiprocessing.Pool`:**
- Creates N worker **processes** (not threads — true parallelism)
- `with` statement ensures the pool is properly cleaned up

**`pool.map(function, iterable)`:**
- Distributes items across workers: worker 1 gets task 0, worker 2 gets task 1, ...
- When a worker finishes one task, it picks up the next available
- Blocks until ALL tasks complete
- Returns results in the same order as input

**`maxtasksperchild=10`:**
- After processing 10 tables, a worker is killed and replaced with a fresh one
- Prevents memory leaks from accumulating over hundreds of tables

### Step 9.3: Exit Code

```python
failed_count = sum(1 for r in results if r["status"] == "error")
raise SystemExit(failed_count > 0)
```

**Generator expression — `sum(1 for r in results if ...)`:**
- Counts how many results have `"error"` status
- More memory-efficient than building a list first

**`SystemExit(failed_count > 0)`:**
- `failed_count > 0` evaluates to `True` (1) or `False` (0)
- Exit code `0` = success (all tables exported)
- Exit code `1` = failure (at least one table failed)
- CI/CD pipelines check this to determine if the job succeeded

---

## Complete Data Flow

```
1. Main process:   parse_args() → setup_logging()
2. Main process:   get_all_tables("public") → 450 table dicts
3. Main process:   build tasks list (450 self-contained dicts)
4. Main process:   Pool(4).map(export_table, tasks)
      │
      ├─ Worker 1:  export_table(task_0)
      │    ├─ psycopg2.connect()         → own connection
      │    ├─ get_column_definitions()    → "id INT, name TEXT"
      │    ├─ build_s3_location()         → "s3://bucket/.../table_*.csv"
      │    ├─ CREATE WRITABLE EXT TABLE   → shell created
      │    ├─ INSERT INTO ext SELECT *    → DATA FLOWS TO S3
      │    ├─ DROP EXTERNAL TABLE         → shell removed
      │    └─ return {"status": "ok", ...}
      │
      ├─ Worker 2:  export_table(task_1)  → same steps
      ├─ Worker 3:  export_table(task_2)  → same steps
      └─ Worker 4:  export_table(task_3)  → same steps
      │
      │  (each worker picks up next task when done)
      │
5. Main process:   print_summary(results)
6. Main process:   write_summary_csv(results)
7. Main process:   SystemExit(0 or 1)
```
