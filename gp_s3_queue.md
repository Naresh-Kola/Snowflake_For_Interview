# GP → S3 Export (Queue-Based): Complete Line-by-Line Explanation

---

## Header Comments — Architecture Overview

```python
# ARCHITECTURE (Queue-based — workers self-serve tasks):
#
#   Main Process
#     └─ fetches all 450 table names from GP
#     └─ fills  task_queue  with 450 items
#     └─ fills result_queue to collect outcomes
#     └─ launches N worker processes
```

**What is a Queue?**
A queue is a FIFO (First In, First Out) data structure — like a line at a grocery store. The first item added is the first item removed.

```
PUT → [task_450] [task_449] ... [task_2] [task_1] → GET
       ↑ back of line                    front ↑
```

**Why Queue > pool.map()?**

```
pool.map() pre-assigns work:
  Worker 1: [huge_table...........]  Worker 2: [tiny][tiny][tiny]  Worker 3: idle  Worker 4: idle
                                      ↑ finished early, can't help Worker 1

Queue — workers grab next available:
  Worker 1: [huge_table...........]
  Worker 2: [tiny][tiny][tiny][tiny][tiny][tiny]  ← keeps grabbing work
  Worker 3: [tiny][tiny][tiny][tiny][tiny]        ← keeps grabbing work
  Worker 4: [tiny][tiny][tiny][tiny]              ← keeps grabbing work
```

**How GP Segments work:**

```
Python fires: INSERT INTO ext_table SELECT * FROM source
                         │
                         ▼
              GP Master receives SQL
                    │
        ┌───────────┼───────────┐
        ▼           ▼           ▼
     Segment 0   Segment 1   Segment 2
        │           │           │
        ▼           ▼           ▼
  orders_0000.csv orders_0001.csv orders_0002.csv   ← written to S3 in parallel
```

Each segment is a separate PostgreSQL instance holding a horizontal slice of data. They all write to S3 simultaneously — Python just waits.

---

## Imports

```python
import multiprocessing
```
Provides `Process`, `Queue` for spawning real OS-level processes (not threads). Each worker is a separate Python interpreter with its own memory.

```python
import psycopg2
```
PostgreSQL/Greenplum database adapter. Lets Python send SQL to GP and receive results.

```python
import logging
```
Python's built-in logging framework. Supports severity levels (DEBUG, INFO, WARNING, ERROR, CRITICAL), formatters, and multiple output destinations.

```python
import time
```
`time.time()` returns current time as a float (seconds since 1970-01-01). Used to measure elapsed time:
```python
start = time.time()       # → 1716000000.123
# ... work ...
elapsed = time.time() - start  # → 3.45 (seconds)
```

```python
import csv
```
Built-in module to read/write CSV files. `csv.DictWriter` writes dictionaries as CSV rows.

```python
import os
```
Operating system interface. Used here for:
- `os.getenv("VAR", "default")` — read environment variables
- `os.makedirs(path, exist_ok=True)` — create directories
- `os.path.join(a, b)` — build file paths

```python
import re
```
Regular expressions module. Used for `re.sub()` to sanitize strings by replacing characters matching a pattern.

```python
import argparse
```
Command-line argument parser. Turns `--workers 8 --dry-run` into a Python object with `.workers = 8` and `.dry_run = True`.

```python
from datetime import datetime
```
Date/time handling. `datetime.now()` returns current date/time. `.strftime()` formats it as a string.

---

## Section 1: Configuration

### DB_CONFIG

```python
DB_CONFIG = {
    "host"           : os.getenv("GP_HOST",     "your-greenplum-host"),
```
**`os.getenv("GP_HOST", "your-greenplum-host")`:**
- Checks if environment variable `GP_HOST` is set
- If set: uses its value (e.g. `"10.0.1.50"`)
- If not set: uses the default `"your-greenplum-host"`
- **Output:** `"10.0.1.50"` or `"your-greenplum-host"`

```python
    "port"           : int(os.getenv("GP_PORT", "5432")),
```
- `os.getenv()` always returns a **string** (`"5432"`)
- `int()` converts it to integer `5432`
- psycopg2 needs port as an integer
- **Output:** `5432`

```python
    "dbname"         : os.getenv("GP_DBNAME",   "your_database"),
    "user"           : os.getenv("GP_USER",     "your_user"),
    "password"       : os.getenv("GP_PASSWORD", "your_password"),
    "connect_timeout": 30,
```
- `connect_timeout: 30` — if GP doesn't respond within 30 seconds, raise an error instead of hanging forever
- **Output:** Complete dict like `{"host": "10.0.1.50", "port": 5432, "dbname": "mydb", ...}`

### S3_CONFIG

```python
S3_CONFIG = {
    "bucket"    : os.getenv("S3_BUCKET",             "your-s3-bucket"),
    "prefix"    : os.getenv("S3_PREFIX",             "gp-exports"),
    "region"    : os.getenv("S3_REGION",             "us-east-1"),
    "access_key": os.getenv("AWS_ACCESS_KEY_ID",     ""),
    "secret_key": os.getenv("AWS_SECRET_ACCESS_KEY", ""),
}
```
- `access_key` / `secret_key` default to empty string `""`
- Empty means "use IAM role attached to the GP server" (more secure than hardcoded keys)
- **Output:** `{"bucket": "my-data-lake", "prefix": "gp-exports", "region": "us-east-1", ...}`

### EXPORT_CONFIG

```python
EXPORT_CONFIG = {
    "schema"        : "public",     # which GP schema to export
    "num_workers"   : 4,            # number of parallel processes
    "format"        : "CSV",        # output file format
    "delimiter"     : ",",          # column separator character
    "include_header": True,         # write column names as first row
    "output_dir"    : "exports",    # local folder for summary CSV
    "log_level"     : "INFO",       # minimum log severity
    "dry_run"       : False,        # False = actually export; True = print SQL only
}
```

### Sentinel Constant

```python
_SENTINEL = "__STOP__"
```
A special value placed into the queue to tell a worker "there's no more work — shut down." Each worker checks for this and exits its loop when it sees it.

**Why not `None`?** Using a unique string avoids accidental matches if `None` appears as a legitimate value. Convention: prefix with `_` to indicate it's internal.

---

## Section 2: Logging

### setup_logging()

```python
def setup_logging(level: str = "INFO"):
```
- `: str` — type hint saying `level` should be a string
- `= "INFO"` — default value if caller doesn't pass one
- **No output** — this is a function definition, not a call

```python
    log_format = "%(asctime)s [%(processName)-20s] %(levelname)-7s %(message)s"
```
Format template string. Each `%(...)s` is a placeholder:

| Placeholder | Example Output | Description |
|---|---|---|
| `%(asctime)s` | `2025-05-17 10:30:45,123` | Timestamp |
| `%(processName)-20s` | `GPWorker-1          ` | Process name, left-aligned, 20 chars wide |
| `%(levelname)-7s` | `INFO   ` | Log level, left-aligned, 7 chars wide |
| `%(message)s` | `Starting → public.orders` | Your actual message |

**Full output example:**
```
2025-05-17 10:30:45,123 [GPWorker-1          ] INFO    Starting → public.orders
2025-05-17 10:30:45,456 [GPWorker-2          ] ERROR   FAILED ✗ public.bad_table: ...
```

```python
    logging.basicConfig(
        level    = getattr(logging, level.upper(), logging.INFO),
```
**`getattr(logging, level.upper(), logging.INFO)`:**
- `level.upper()` — converts `"info"` → `"INFO"` (case-insensitive)
- `getattr(logging, "INFO")` — same as `logging.INFO` which equals integer `20`
- Third argument `logging.INFO` — fallback if `level` is invalid (e.g. `"BANANA"`)

**Level hierarchy:**
```
DEBUG=10 < INFO=20 < WARNING=30 < ERROR=40 < CRITICAL=50
```
Setting level=INFO means: show INFO, WARNING, ERROR, CRITICAL. Hide DEBUG.

```python
        format   = log_format,
        handlers = [
            logging.StreamHandler(),
```
Sends log output to **terminal** (stdout/stderr).

```python
            logging.FileHandler("gp_export.log", mode="a"),
```
Also writes to **file** `gp_export.log`. `mode="a"` = append (don't overwrite previous runs).

Both handlers receive every log message simultaneously.

### get_logger()

```python
def get_logger() -> logging.Logger:
    return logging.getLogger(__name__)
```
- `-> logging.Logger` — return type hint
- `__name__` — equals `"__main__"` when run directly, or module name when imported
- `getLogger()` returns a singleton: same name → same logger object
- **Output:** a `Logger` object (not a string — it's an object you call methods on)

---

## Section 3: Database Helpers

### get_connection()

```python
def get_connection() -> psycopg2.extensions.connection:
    return psycopg2.connect(**DB_CONFIG)
```
- `**DB_CONFIG` unpacks the dictionary as keyword arguments
- Equivalent to: `psycopg2.connect(host="...", port=5432, dbname="...", user="...", password="...", connect_timeout=30)`
- **Output:** a `connection` object — an open session to the GP database

### get_all_tables()

```python
def get_all_tables(schema: str) -> list[dict]:
```
- Takes a schema name string, returns a list of dictionaries
- **Output type:** `[{"schema": "public", "table": "orders", ...}, ...]`

```python
    log = get_logger()
    log.info(f"Fetching table list from schema '{schema}'...")
```
**Output to terminal:**
```
2025-05-17 10:30:45,123 [MainProcess         ] INFO    Fetching table list from schema 'public'...
```

```python
    conn   = get_connection()
    cursor = conn.cursor()
```
- `conn` — open database session
- `cursor` — object to execute SQL and fetch results

```python
    cursor.execute("""
        SELECT
            t.table_schema,
            t.table_name,
```
- `t.table_schema` → `"public"` (the schema name)
- `t.table_name` → `"orders"` (the table name)

```python
            pg_catalog.pg_relation_size(
                pg_catalog.quote_ident(t.table_schema) || '.' ||
                pg_catalog.quote_ident(t.table_name)
            ) AS size_bytes,
```
- `quote_ident()` — safely quotes identifiers: `my table` → `"my table"`
- `||` — SQL string concatenation: `"public" || '.' || "orders"` → `"public"."orders"`
- `pg_relation_size()` — returns table size in bytes (e.g. `8192`)
- `AS size_bytes` — gives the column an alias
- **Output for this column:** `8192` (integer)

```python
            c.reltuples::BIGINT AS estimated_rows
```
- `c.reltuples` — PostgreSQL's estimated row count (stored as float)
- `::BIGINT` — type cast to integer: `42000.0` → `42000`
- **Output:** `42000` (integer)

```python
        FROM information_schema.tables t
```
- `information_schema.tables` — standard SQL catalog listing all tables
- `t` — alias so you can write `t.table_name` instead of `information_schema.tables.table_name`

```python
        JOIN pg_catalog.pg_class      c ON c.relname = t.table_name
```
- `pg_class` — PostgreSQL's internal catalog with physical storage info
- `JOIN ... ON c.relname = t.table_name` — match rows where the table name is the same
- Gives us access to `c.reltuples` (row estimate)

```python
        JOIN pg_catalog.pg_namespace  n ON n.oid = c.relnamespace
                                       AND n.nspname = t.table_schema
```
- `pg_namespace` — maps schemas to internal OIDs (object identifiers)
- This join ensures we match the correct schema (a table named `orders` could exist in multiple schemas)

```python
        WHERE t.table_schema = %s
          AND t.table_type   = 'BASE TABLE'
        ORDER BY t.table_name
    """, (schema,))
```
- `%s` — parameterized placeholder, replaced safely by `schema` value
- `'BASE TABLE'` — excludes views, materialized views, foreign tables
- `(schema,)` — single-element tuple (trailing comma required)
- **Output:** cursor now holds rows like `[("public", "orders", 8192, 42000), ...]`

```python
    rows = cursor.fetchall()
    conn.close()
```
- `fetchall()` — retrieves ALL result rows as a list of tuples
- `conn.close()` — releases the database connection
- **Output of fetchall():** `[("public", "orders", 8192, 42000), ("public", "users", 16384, 1500), ...]`

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
List comprehension that transforms each tuple into a dict:

| Expression | Input | Output |
|---|---|---|
| `r[0]` | `"public"` | `"public"` |
| `r[1]` | `"orders"` | `"orders"` |
| `f"{r[0]}.{r[1]}"` | — | `"public.orders"` |
| `r[2] or 0` | `8192` or `None` | `8192` or `0` |
| `r[3] or 0` | `42000` or `None` | `42000` or `0` |

**`r[2] or 0`** — Python's truthy shortcut:
- If `r[2]` is `None` (null), `None or 0` evaluates to `0`
- If `r[2]` is `8192`, `8192 or 0` evaluates to `8192`

**Output:**
```python
[
    {"schema": "public", "table": "orders", "full_name": "public.orders", "size_bytes": 8192, "estimated_rows": 42000},
    {"schema": "public", "table": "users",  "full_name": "public.users",  "size_bytes": 16384, "estimated_rows": 1500},
    # ... 448 more
]
```

```python
    log.info(f"Found {len(tables)} tables in schema '{schema}'.")
    return tables
```
**Output to terminal:**
```
2025-05-17 10:30:45,456 [MainProcess         ] INFO    Found 450 tables in schema 'public'.
```

### get_column_definitions()

```python
def get_column_definitions(cursor, full_table_name: str) -> str:
    schema, table = full_table_name.split(".", 1)
```
- `"public.orders".split(".", 1)` → `["public", "orders"]`
- Tuple unpacking: `schema = "public"`, `table = "orders"`
- The `1` limits to one split (handles table names with dots)

```python
    cursor.execute("""
        SELECT column_name, data_type, character_maximum_length
        FROM information_schema.columns
        WHERE table_schema = %s
          AND table_name   = %s
        ORDER BY ordinal_position
    """, (schema, table))
```
- Queries the column catalog for a specific table
- `ordinal_position` — column order (1st column, 2nd column, etc.)
- **Output in cursor:** `[("id", "integer", None), ("name", "character varying", 100), ...]`

```python
    cols = []
    for col_name, data_type, char_len in cursor.fetchall():
```
- Tuple unpacking in a for loop: each row's 3 values go into 3 variables
- **Per iteration:** `col_name="id"`, `data_type="integer"`, `char_len=None`

```python
        if data_type == "character varying":
            type_str = f"VARCHAR({char_len})" if char_len else "TEXT"
```
- `information_schema` stores `VARCHAR(100)` as `data_type="character varying"`, `char_len=100`
- Ternary: if `char_len` has a value → `"VARCHAR(100)"`, otherwise → `"TEXT"`

```python
        elif data_type == "character":
            type_str = f"CHAR({char_len})" if char_len else "TEXT"
        else:
            type_str = data_type.upper()
```
- For all other types: just uppercase the name → `"integer"` becomes `"INTEGER"`

```python
        cols.append(f"{col_name} {type_str}")
```
- Builds strings like `"id INTEGER"`, `"name VARCHAR(100)"`
- **cols after loop:** `["id INTEGER", "name VARCHAR(100)", "amount NUMERIC"]`

```python
    return ", ".join(cols)
```
- Joins list elements with `", "` separator
- **Output:** `"id INTEGER, name VARCHAR(100), amount NUMERIC"`

---

## Section 4: S3 Path Builder

```python
def build_s3_location(table_info: dict, cfg: dict) -> str:
    today    = datetime.now().strftime("%Y-%m-%d")
```
- `datetime.now()` → `datetime(2025, 5, 17, 10, 30, 45)`
- `.strftime("%Y-%m-%d")` → `"2025-05-17"`

```python
    schema   = table_info["schema"]       # "public"
    table    = table_info["table"]        # "orders"
    bucket   = cfg["bucket"]              # "my-data-lake"
    prefix   = cfg["prefix"].rstrip("/")  # "gp-exports" (removes trailing /)
```

```python
    return f"s3://{bucket}/{prefix}/{today}/{schema}/{table}/{table}_*.csv"
```
**Output:** `"s3://my-data-lake/gp-exports/2025-05-17/public/orders/orders_*.csv"`

The `*` wildcard is replaced by GP — each segment creates its own file:
```
orders_0000.csv  ← segment 0
orders_0001.csv  ← segment 1
orders_0002.csv  ← segment 2
```

---

## Section 5: Export Worker — `export_table()`

```python
def export_table(task: dict) -> dict:
```
Takes a task dict, returns a result dict. This is the function that does the actual GP → S3 data movement.

```python
    log        = get_logger()
    full_name  = task["full_name"]       # "public.orders"
    table      = task["table"]           # "orders"
    dry_run    = task["dry_run"]         # False
    s3_cfg     = task["s3_config"]       # S3_CONFIG dict
    exp_cfg    = task["export_config"]   # EXPORT_CONFIG dict
```
Extracts values from the task dict into local variables for readability.

```python
    safe_ext_name = f"ext_writable_{re.sub(r'[^a-zA-Z0-9_]', '_', table)}"
```
**`re.sub(pattern, replacement, string)`:**
- `r'[^a-zA-Z0-9_]'` — regex matching any character that is NOT a letter, digit, or underscore
- `r` prefix makes it a raw string (backslashes are literal)
- Replaces matched characters with `_`

| Input | Output |
|---|---|
| `"orders"` | `"ext_writable_orders"` |
| `"my-table.v2"` | `"ext_writable_my_table_v2"` |
| `"special@table!"` | `"ext_writable_special_table_"` |

Prevents SQL injection by removing all special characters from the table name.

```python
    start_time    = time.time()
```
Records the start time as a float (seconds since epoch). Used later to calculate elapsed time.
**Output:** `1716000000.123`

```python
    log.info(f"START  → {full_name}  (~{task['estimated_rows']:,} rows)")
```
- `:,` format specifier adds thousands separator: `42000` → `"42,000"`
- **Output:** `2025-05-17 10:30:45,123 [GPWorker-1          ] INFO    START  → public.orders  (~42,000 rows)`

```python
    try:
        conn            = get_connection()
        conn.autocommit = True
        cursor          = conn.cursor()
```
- Each worker opens its own connection (connections can't be shared across processes)
- `autocommit = True` — DDL statements (CREATE, DROP) need this; without it GP waits for COMMIT

```python
        col_defs = get_column_definitions(cursor, full_name)
        if not col_defs:
            raise ValueError(f"No columns found for {full_name}")
```
- Gets column definitions like `"id INTEGER, name VARCHAR(100)"`
- If empty string returned (no columns found), raises an error
- `raise ValueError(...)` — creates and throws an exception that the except block will catch

```python
        s3_location = build_s3_location(task, s3_cfg)
```
**Output:** `"s3://my-data-lake/gp-exports/2025-05-17/public/orders/orders_*.csv"`

```python
        if s3_cfg.get("access_key") and s3_cfg.get("secret_key"):
            creds = f"accessid='{s3_cfg['access_key']}' secret='{s3_cfg['secret_key']}'"
        else:
            creds = ""
```
- `.get("access_key")` — returns the value or `None` if key doesn't exist (safer than `["access_key"]`)
- Empty string `""` is falsy in Python, so `"" and ""` evaluates to `""`→ goes to `else`
- If keys are provided: `creds = "accessid='AKIA...' secret='wJal...'"`
- If keys are empty: `creds = ""` (use IAM role)

```python
        region_clause = f"region='{s3_cfg['region']}'" if s3_cfg.get("region") else ""
```
**Output:** `"region='us-east-1'"` or `""`

```python
        s3_params     = " ".join(filter(None, [creds, region_clause]))
```
**`filter(None, [creds, region_clause])`:**
- `filter(None, iterable)` removes all falsy values (empty strings, None, 0)
- If `creds=""` and `region_clause="region='us-east-1'"`:
  - `filter(None, ["", "region='us-east-1'"])` → `["region='us-east-1'"]`
- `" ".join(...)` combines with spaces
- **Output:** `"region='us-east-1'"` (or `"accessid='...' secret='...' region='us-east-1'"`)

```python
        header_clause = "HEADER" if exp_cfg["include_header"] else ""
        delimiter     = exp_cfg["delimiter"]    # ","
```

### CREATE WRITABLE EXTERNAL TABLE

```python
        create_sql = f"""
            CREATE WRITABLE EXTERNAL TABLE {safe_ext_name} (
                {col_defs}
            )
            LOCATION ('{s3_location}' {s3_params})
            FORMAT '{exp_cfg["format"]}' (
                DELIMITER '{delimiter}'
                {header_clause}
                NULL ''
            )
            DISTRIBUTED RANDOMLY
        """
```
**Actual SQL generated:**
```sql
CREATE WRITABLE EXTERNAL TABLE ext_writable_orders (
    id INTEGER, name VARCHAR(100), amount NUMERIC
)
LOCATION ('s3://my-data-lake/gp-exports/2025-05-17/public/orders/orders_*.csv' region='us-east-1')
FORMAT 'CSV' (
    DELIMITER ','
    HEADER
    NULL ''
)
DISTRIBUTED RANDOMLY
```

What each clause does:
- `WRITABLE` — data flows OUT (GP → S3), not in
- `LOCATION` — S3 path where files will be created
- `FORMAT 'CSV'` — output format with delimiter and header options
- `NULL ''` — represent SQL NULL as empty string in CSV
- `DISTRIBUTED RANDOMLY` — rows spread evenly across GP segments

**This only creates a catalog entry. No data moves yet.**

### INSERT — The Data Movement

```python
        insert_sql = f"INSERT INTO {safe_ext_name} SELECT * FROM {full_name}"
```
**Actual SQL:**
```sql
INSERT INTO ext_writable_orders SELECT * FROM public.orders
```

**This is the line that moves ALL the data.** When GP executes this:
1. Master parses the SQL and sends it to all segments
2. Each segment reads its local rows from `public.orders`
3. Each segment writes its rows directly to S3 as a separate file
4. Python just waits for GP to say "done"

### DROP — Cleanup

```python
        drop_sql = f"DROP EXTERNAL TABLE IF EXISTS {safe_ext_name}"
```
**Actual SQL:** `DROP EXTERNAL TABLE IF EXISTS ext_writable_orders`
- Removes the catalog entry only
- S3 files remain untouched
- `IF EXISTS` prevents error if table was already dropped

### Dry Run Mode

```python
        if dry_run:
            log.info(f"[DRY RUN] {full_name}:\n{create_sql}\n{insert_sql}\n{drop_sql}")
            conn.close()
            return {
                "table": full_name, "status": "dry_run",
                "s3_path": s3_location,
                "elapsed_sec": round(time.time() - start_time, 2),
                "rows": task["estimated_rows"], "error": None,
            }
```
- If `dry_run=True`: prints the SQL that WOULD be executed, then returns early
- `round(time.time() - start_time, 2)` — elapsed seconds rounded to 2 decimal places
- **Output:** `{"table": "public.orders", "status": "dry_run", "s3_path": "s3://...", "elapsed_sec": 0.03, "rows": 42000, "error": None}`

### Actual Execution

```python
        log.info(f"  CREATE external table: {safe_ext_name}")
        cursor.execute(create_sql)
```
**Output:** `2025-05-17 10:30:45,200 [GPWorker-1          ] INFO      CREATE external table: ext_writable_orders`
Creates the writable external table shell in GP catalog.

```python
        log.info(f"  INSERT → S3 (all segments writing in parallel): {s3_location}")
        cursor.execute(insert_sql)
```
**Output:** `2025-05-17 10:30:45,300 [GPWorker-1          ] INFO      INSERT → S3 (all segments writing in parallel): s3://...`
This is where data actually flows. May take seconds to minutes depending on table size.

```python
        cursor.execute(f"SELECT COUNT(*) FROM {full_name}")
        actual_rows = cursor.fetchone()[0]
```
Gets the actual row count after export for the result report.
**Output:** `actual_rows = 42000`

```python
        log.info(f"  DROP external table shell")
        cursor.execute(drop_sql)
        conn.close()
```
Removes catalog entry and closes the connection.

```python
        elapsed = round(time.time() - start_time, 2)
```
**Output:** `elapsed = 3.45`

```python
        log.info(
            f"DONE   ← {full_name} | {actual_rows:,} rows | {elapsed}s"
        )
```
**Output:** `2025-05-17 10:30:48,650 [GPWorker-1          ] INFO    DONE   ← public.orders | 42,000 rows | 3.45s`

```python
        return {
            "table": full_name, "status": "ok",
            "s3_path": s3_location, "elapsed_sec": elapsed,
            "rows": actual_rows, "error": None,
        }
```
**Output:**
```python
{"table": "public.orders", "status": "ok", "s3_path": "s3://...", "elapsed_sec": 3.45, "rows": 42000, "error": None}
```

### Error Handling

```python
    except Exception as exc:
        elapsed = round(time.time() - start_time, 2)
        log.error(f"FAILED ✗ {full_name}: {exc}")
```
If ANY error occurs in the try block, execution jumps here.
**Output:** `2025-05-17 10:30:46,000 [GPWorker-1          ] ERROR   FAILED ✗ public.orders: connection refused`

```python
        try:
            conn2 = get_connection(); conn2.autocommit = True
            conn2.cursor().execute(f"DROP EXTERNAL TABLE IF EXISTS {safe_ext_name}")
            conn2.close()
        except Exception:
            pass
```
**Best-effort cleanup:**
- Opens a NEW connection (`conn2`) because the original may be broken
- Tries to DROP the external table shell (in case CREATE succeeded but INSERT failed)
- `pass` — if cleanup itself fails, ignore it (non-fatal)
- **Why `;` on one line?** Python allows multiple statements on one line separated by `;` (compact but less readable)

```python
        return {
            "table": full_name, "status": "error",
            "s3_path": None, "elapsed_sec": elapsed,
            "rows": 0, "error": str(exc),
        }
```
- `str(exc)` converts the exception to a readable string
- Returns error dict so the pool continues processing other tables
- **Output:** `{"table": "public.orders", "status": "error", "s3_path": None, "elapsed_sec": 1.2, "rows": 0, "error": "connection refused"}`

---

## Section 6: Queue Worker

```python
def queue_worker(task_queue: multiprocessing.Queue,
                 result_queue: multiprocessing.Queue):
```
- Takes two Queue objects as parameters
- `multiprocessing.Queue` — a process-safe FIFO queue that uses pipes internally

```python
    log = get_logger()
    log.info("Worker started — waiting for tasks")
```
**Output:** `2025-05-17 10:30:45,100 [GPWorker-1          ] INFO    Worker started — waiting for tasks`

```python
    while True:
        task = task_queue.get()
```
**`task_queue.get()`:**
- **BLOCKS** — the worker pauses here until a task is available in the queue
- When a task arrives, it's removed from the queue and returned
- This is the key mechanism: workers self-serve tasks, no pre-assignment

```
Queue: [task_5] [task_4] [task_3] [task_2] [task_1]
                                            ↑ Worker calls .get()
                                            task_1 is removed and returned

Queue: [task_5] [task_4] [task_3] [task_2]
                                    ↑ Another worker calls .get()
```

```python
        if task == _SENTINEL:
            log.info("Received stop signal — worker exiting cleanly")
            break
```
- When the worker gets the `"__STOP__"` sentinel, it exits the `while True` loop
- `break` — exits the innermost loop
- **Output:** `2025-05-17 10:35:00,000 [GPWorker-1          ] INFO    Received stop signal — worker exiting cleanly`

```python
        result = export_table(task)
        result_queue.put(result)
```
- Calls `export_table()` which does the actual GP → S3 work
- Places the result dict into `result_queue` for the main process to collect
- **`.put(result)`** — adds an item to the back of the result queue

```python
    log.info("Worker shut down")
```
**Output:** `2025-05-17 10:35:00,001 [GPWorker-1          ] INFO    Worker shut down`

**Complete worker lifecycle:**
```
Worker starts → while True → get task → export → put result → get task → ... → get SENTINEL → break → shut down
```

---

## Section 7: Result Reporting

### write_summary_csv()

```python
def write_summary_csv(results: list[dict], output_dir: str) -> str:
    os.makedirs(output_dir, exist_ok=True)
```
- Creates `exports/` directory (and any parent dirs)
- `exist_ok=True` — no error if directory already exists

```python
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
```
**Output:** `"20250517_103500"`

```python
    filepath  = os.path.join(output_dir, f"export_summary_{timestamp}.csv")
```
- `os.path.join("exports", "export_summary_20250517_103500.csv")`
- **Output:** `"exports/export_summary_20250517_103500.csv"`

```python
    fieldnames = ["table", "status", "rows", "elapsed_sec", "s3_path", "error"]
```
Column headers for the CSV.

```python
    with open(filepath, "w", newline="", encoding="utf-8") as f:
```
- `"w"` — write mode (creates new file)
- `newline=""` — prevents double newlines on Windows (CSV module handles its own newlines)
- `encoding="utf-8"` — character encoding
- `with` statement — auto-closes the file when the block ends

```python
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)
```
- `DictWriter` — writes dicts as CSV rows, using `fieldnames` to determine column order
- `writeheader()` — writes: `table,status,rows,elapsed_sec,s3_path,error`
- `writerows(results)` — writes all 450 result dicts as CSV rows

**Output file content:**
```csv
table,status,rows,elapsed_sec,s3_path,error
public.orders,ok,42000,3.45,s3://my-data-lake/.../orders_*.csv,
public.users,ok,1500,1.2,s3://my-data-lake/.../users_*.csv,
public.bad_table,error,0,0.5,,connection refused
```

```python
    return filepath
```
**Output:** `"exports/export_summary_20250517_103500.csv"`

### print_summary()

```python
    ok      = [r for r in results if r["status"] == "ok"]
    failed  = [r for r in results if r["status"] == "error"]
    dry_run = [r for r in results if r["status"] == "dry_run"]
```
List comprehensions that filter results by status. Each produces a subset list.

```python
    total_rows = sum(r["rows"] for r in ok)
```
Generator expression inside `sum()`: adds up all row counts from successful exports.
**Output:** `12345678`

```python
    avg_time   = round(sum(r["elapsed_sec"] for r in ok) / len(ok), 2) if ok else 0
```
- `if ok else 0` — prevents division by zero if no tables succeeded
- Calculates average seconds per table
- **Output:** `3.05`

**Terminal output:**
```
============================================================
  GP → S3 EXPORT SUMMARY
============================================================
  Total tables   : 450
  Successful     : 448
  Failed         : 2
  Dry run        : 0
  Total rows     : 12,345,678
  Workers used   : 4
  Wall clock time: 342.5s
  Avg per table  : 3.05s
============================================================

  FAILED TABLES:
    ✗ public.bad_table: connection refused
    ✗ public.corrupt_table: invalid byte sequence
```

---

## Section 8: Argument Parser

```python
def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export GP tables to S3 — queue-based multiprocessing"
    )
```
- Creates a parser object. `description` is shown in `--help` output.
- `argparse.Namespace` — the return type, an object with attributes for each argument

```python
    parser.add_argument("--workers",   type=int, default=EXPORT_CONFIG["num_workers"])
```
- `--workers` — CLI flag name
- `type=int` — convert input string to integer
- `default=4` — value if flag is not provided
- Usage: `python script.py --workers 8` → `args.workers = 8`

```python
    parser.add_argument("--schema",    type=str, default=EXPORT_CONFIG["schema"])
```
Usage: `python script.py --schema sales` → `args.schema = "sales"`

```python
    parser.add_argument("--dry-run",   action="store_true")
```
- `action="store_true"` — boolean flag, no value needed
- Present: `--dry-run` → `args.dry_run = True`
- Absent: `args.dry_run = False`
- Note: `--dry-run` becomes `args.dry_run` (dash → underscore)

```python
    parser.add_argument("--table",     type=str, default=None,
                        help="Export a single table, e.g. public.orders")
```
- Optional flag for single-table mode
- `default=None` — not provided means export all tables

```python
    parser.add_argument("--log-level", type=str, default=EXPORT_CONFIG["log_level"])
    return parser.parse_args()
```
- `parse_args()` processes `sys.argv` (command-line arguments)
- **Output:** `Namespace(workers=8, schema='sales', dry_run=True, table=None, log_level='INFO')`

---

## Section 9: Main Entry Point

```python
if __name__ == "__main__":
```
This block runs ONLY when the script is executed directly:
- `python script.py` → `__name__ == "__main__"` → runs
- `import script` → `__name__ == "script"` → does NOT run

### 9.1: Merge CLI Args into Config

```python
    args = parse_args()
    EXPORT_CONFIG["num_workers"] = args.workers
    EXPORT_CONFIG["schema"]      = args.schema
    EXPORT_CONFIG["dry_run"]     = args.dry_run
```
CLI arguments override the hardcoded defaults.

### 9.2: Setup Logging

```python
    setup_logging(args.log_level)
    log = get_logger()

    log.info("=" * 60)
```
- `"=" * 60` — string repetition: produces 60 equal signs
- **Output:** `2025-05-17 10:30:45,000 [MainProcess         ] INFO    ============================================================`

```python
    log.info("GP → S3 EXPORT STARTED  (queue-based workers)")
    log.info(f"  Schema   : {EXPORT_CONFIG['schema']}")
    log.info(f"  Workers  : {EXPORT_CONFIG['num_workers']}")
    log.info(f"  S3 bucket: s3://{S3_CONFIG['bucket']}/{S3_CONFIG['prefix']}")
    log.info(f"  Dry run  : {EXPORT_CONFIG['dry_run']}")
```
**Output:**
```
2025-05-17 10:30:45,000 [MainProcess         ] INFO    GP → S3 EXPORT STARTED  (queue-based workers)
2025-05-17 10:30:45,000 [MainProcess         ] INFO      Schema   : public
2025-05-17 10:30:45,000 [MainProcess         ] INFO      Workers  : 4
2025-05-17 10:30:45,000 [MainProcess         ] INFO      S3 bucket: s3://my-data-lake/gp-exports
2025-05-17 10:30:45,000 [MainProcess         ] INFO      Dry run  : False
```

```python
    wall_start = time.time()
```
Records wall-clock start time (total real-world time, not per-table).

### 9.3: Get Table List

```python
    if args.table:
        schema, table = args.table.split(".") if "." in args.table \
                        else (EXPORT_CONFIG["schema"], args.table)
```
- `\` at end of line — line continuation (statement continues on next line)
- `"." in args.table` — checks if the string contains a dot
- `"public.orders".split(".")` → `["public", "orders"]`
- If no dot: use default schema + the provided table name
- **Output:** `schema="public"`, `table="orders"`

```python
        all_tables = [{
            "schema": schema, "table": table,
            "full_name": f"{schema}.{table}",
            "size_bytes": 0, "estimated_rows": 0,
        }]
```
Single-element list for single-table mode.

```python
    else:
        all_tables = get_all_tables(EXPORT_CONFIG["schema"])
```
Normal mode: query GP for all 450 tables.

```python
    if not all_tables:
        log.error("No tables found. Check schema name and GP connection.")
        raise SystemExit(1)
```
- `not all_tables` — True if list is empty (`[]`)
- `raise SystemExit(1)` — exit the program with code 1 (failure)

### 9.4: Build Task List

```python
    tasks = [
        {
            **tbl,
            "dry_run"      : EXPORT_CONFIG["dry_run"],
            "s3_config"    : S3_CONFIG,
            "export_config": EXPORT_CONFIG,
        }
        for tbl in all_tables
    ]
```
**`**tbl` (dict unpacking in a dict literal):**
- Spreads all key-value pairs from `tbl` into the new dict
- Then adds three more keys

**Input `tbl`:** `{"schema": "public", "table": "orders", "full_name": "public.orders", "size_bytes": 8192, "estimated_rows": 42000}`

**Output task:**
```python
{
    "schema": "public", "table": "orders", "full_name": "public.orders",
    "size_bytes": 8192, "estimated_rows": 42000,
    "dry_run": False, "s3_config": {...}, "export_config": {...}
}
```

Each task is **self-contained** — workers need no shared state.

```python
    num_workers = EXPORT_CONFIG["num_workers"]    # 4
```

### 9.5: Create Shared Queues

```python
    task_queue   = multiprocessing.Queue(maxsize=0)
    result_queue = multiprocessing.Queue()
```
- `multiprocessing.Queue` — process-safe queue (uses OS pipes internally)
- `maxsize=0` — unlimited size (all 450 tasks loaded upfront)
- If `maxsize=8`: `.put()` blocks when queue has 8 items (backpressure)
- Two separate queues: tasks flow IN, results flow OUT

```
Main Process                         Workers
    │                                   │
    │── put(task) ──► [task_queue] ──► get() ──► export_table()
    │                                   │
    │◄── get() ◄── [result_queue] ◄── put(result)
```

### 9.6: Fill Task Queue

```python
    for task in tasks:
        task_queue.put(task)
```
Loads all 450 task dicts into the queue. Workers haven't started yet, so all tasks queue up.

```python
    for _ in range(num_workers):
        task_queue.put(_SENTINEL)
```
- `_` — throwaway variable (convention: "I don't need the loop counter")
- Adds one `"__STOP__"` sentinel per worker
- **Queue after this:** `[STOP, STOP, STOP, STOP, task_450, task_449, ..., task_1]`
- When all real tasks are consumed, each worker will get exactly one sentinel and exit

**Why one sentinel per worker?** Each `.get()` removes one item. If we only put one sentinel, only one worker would see it — the other 3 would block forever.

```python
    log.info(
        f"Task queue loaded: {len(tasks)} tasks + {num_workers} sentinels. "
        f"Launching {num_workers} workers..."
    )
```
**Output:** `Task queue loaded: 450 tasks + 4 sentinels. Launching 4 workers...`

### 9.7: Launch Worker Processes

```python
    processes = []
    for i in range(num_workers):
        p = multiprocessing.Process(
            target = queue_worker,
            args   = (task_queue, result_queue),
            name   = f"GPWorker-{i+1}",
        )
```
- `multiprocessing.Process` — creates a new OS process (separate Python interpreter)
- `target` — the function the process will run
- `args` — arguments passed to that function (must be a tuple)
- `name` — process name shown in logs via `%(processName)s`

```python
        p.start()
```
- **Actually launches the process** — a new Python interpreter starts running `queue_worker(task_queue, result_queue)`
- The main process continues immediately (non-blocking)

```python
        processes.append(p)
```
Keeps a reference to each process so we can `.join()` them later.

**After this loop:** 4 worker processes are running in parallel, each pulling tasks from the shared queue.

### 9.8: Collect Results

```python
    results = []
    for i in range(len(tasks)):
        result = result_queue.get()
```
- Loops exactly `len(tasks)` times (450)
- `result_queue.get()` **blocks** until a worker puts a result in the queue
- This is a natural synchronization: main process waits for workers

```python
        results.append(result)
        status_icon = "✓" if result["status"] in ("ok", "dry_run") else "✗"
```
- `in ("ok", "dry_run")` — checks membership in a tuple
- **Output:** `status_icon = "✓"` or `"✗"`

```python
        log.info(
            f"  [{i+1:>3}/{len(tasks)}] {status_icon} {result['table']} "
            f"({result['elapsed_sec']}s)"
        )
```
- `{i+1:>3}` — right-aligned, 3 chars wide: `"  1"`, `" 42"`, `"450"`
- **Output:** `  [  1/450] ✓ public.orders (3.45s)`
- **Output:** `  [450/450] ✗ public.bad_table (0.5s)`

### 9.9: Wait for Workers to Finish

```python
    for p in processes:
        p.join()
```
- `.join()` — blocks until the process terminates
- By this point, all tasks and sentinels have been consumed
- Workers have already exited (or are about to), so this returns quickly
- **Must call `.join()`** to properly clean up child processes (prevent zombies)

### 9.10: Summary and Exit

```python
    wall_elapsed = time.time() - wall_start
    print_summary(results, wall_elapsed, num_workers)
```
Prints the formatted summary table to terminal.

```python
    csv_path = write_summary_csv(results, EXPORT_CONFIG["output_dir"])
    log.info(f"Summary written to: {csv_path}")
```
**Output:** `Summary written to: exports/export_summary_20250517_103500.csv`

```python
    failed_count = sum(1 for r in results if r["status"] == "error")
```
**Generator expression:**
- `1 for r in results if r["status"] == "error"` — yields `1` for each failed result
- `sum(...)` adds them up
- **Output:** `2` (if 2 tables failed)

```python
    raise SystemExit(failed_count > 0)
```
- `failed_count > 0` → `True` (which is `1`) or `False` (which is `0`)
- `SystemExit(0)` — success exit code (all tables exported)
- `SystemExit(1)` — failure exit code (at least one table failed)
- CI/CD pipelines and shell scripts check `$?` (exit code) to determine job status

---

## Complete Data Flow Diagram

```
MAIN PROCESS                          WORKER PROCESSES
═══════════                           ═════════════════

1. parse_args()
2. setup_logging()
3. get_all_tables() → 450 dicts
4. Build 450 task dicts
5. Create task_queue, result_queue
6. Fill task_queue:
   [STOP][STOP][STOP][STOP][t450][t449]...[t2][t1]

7. Start 4 workers ─────────────────► Worker-1: queue_worker() starts
                                       Worker-2: queue_worker() starts
                                       Worker-3: queue_worker() starts
                                       Worker-4: queue_worker() starts

8. result_queue.get() ◄── blocks       Worker-1: task_queue.get() → task_1
                                        Worker-1: export_table(task_1)
                                         ├─ connect to GP
                                         ├─ CREATE WRITABLE EXT TABLE
                                         ├─ INSERT → S3 (segments write)
                                         ├─ DROP EXT TABLE
                                         └─ result_queue.put(result_1) ──► received!

   result_queue.get() ◄── blocks       Worker-2: task_queue.get() → task_2
                                        Worker-2: export_table(task_2) ...
                                        ...

   ... repeats 450 times ...

                                       Worker-1: task_queue.get() → SENTINEL
                                       Worker-1: break → shut down
                                       Worker-2: → SENTINEL → shut down
                                       Worker-3: → SENTINEL → shut down
                                       Worker-4: → SENTINEL → shut down

9. join() all workers
10. print_summary()
11. write_summary_csv()
12. SystemExit(0 or 1)
```
