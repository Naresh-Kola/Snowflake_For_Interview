# Greenplum → Snowflake: Stored Procedure Migration Guide

A complete step-by-step walkthrough — from connecting to Greenplum and extracting procedures for a schema, to auto-converting them in Python and deploying to Snowflake.

---

## STEP 1 — Connect to Greenplum

Greenplum is PostgreSQL-compatible, so use `psycopg2`.

### Install the driver

```bash
pip install psycopg2-binary
```

### Basic connection

```python
import psycopg2

conn = psycopg2.connect(
    host="your-greenplum-host",      # e.g. "10.0.0.5" or "gp-master.internal"
    port=5432,                        # default Greenplum port
    dbname="your_database",
    user="your_username",
    password="your_password",
    connect_timeout=10
)
cursor = conn.cursor()
print("Connected to Greenplum successfully")
```

### Test the connection

```python
cursor.execute("SELECT version();")
print(cursor.fetchone())
```

---

## STEP 2 — Extract All Stored Procedures for a Schema

Greenplum stores procedure/function definitions in the `pg_catalog` system tables.

### Query to fetch all procedures in a schema

```python
SCHEMA_NAME = "your_schema_name"   # e.g. "claims", "finance", "member"

query = """
    SELECT
        n.nspname                          AS schema_name,
        p.proname                          AS procedure_name,
        pg_get_function_identity_arguments(p.oid)  AS arguments,
        pg_get_functiondef(p.oid)          AS procedure_definition,
        l.lanname                          AS language,
        p.prorettype::regtype              AS return_type,
        p.provolatile                      AS volatility,   -- i=immutable, s=stable, v=volatile
        obj_description(p.oid, 'pg_proc')  AS description
    FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    JOIN pg_catalog.pg_language l ON l.oid = p.prolang
    WHERE n.nspname = %s
      AND p.prokind IN ('f', 'p')          -- f=function, p=procedure (GP6+)
    ORDER BY p.proname;
"""

cursor.execute(query, (SCHEMA_NAME,))
procedures = cursor.fetchall()

columns = ["schema_name", "procedure_name", "arguments",
           "procedure_definition", "language", "return_type",
           "volatility", "description"]

import pandas as pd
df = pd.DataFrame(procedures, columns=columns)
print(f"Found {len(df)} procedures in schema '{SCHEMA_NAME}'")
print(df[["procedure_name", "language", "return_type"]].to_string())
```

### Save raw definitions to files (one file per procedure)

```python
import os

OUTPUT_DIR = f"./gp_procedures/{SCHEMA_NAME}"
os.makedirs(OUTPUT_DIR, exist_ok=True)

for _, row in df.iterrows():
    filename = f"{row['procedure_name']}.sql"
    filepath = os.path.join(OUTPUT_DIR, filename)
    with open(filepath, "w") as f:
        f.write(f"-- Schema: {row['schema_name']}\n")
        f.write(f"-- Language: {row['language']}\n")
        f.write(f"-- Return Type: {row['return_type']}\n\n")
        f.write(row["procedure_definition"])
    print(f"Saved: {filepath}")
```

---

## STEP 3 — Understand the Key Differences

Before converting, know what breaks in Snowflake.

| Greenplum Feature | Snowflake Equivalent | Notes |
|---|---|---|
| `LANGUAGE plpgsql` | `LANGUAGE SQL` (Snowflake Scripting) | Use `DECLARE / BEGIN / EXCEPTION / END` |
| `LANGUAGE plpythonu` | `LANGUAGE PYTHON` | Handler function required |
| `RAISE NOTICE 'msg'` | No direct equivalent | Use `RETURN 'msg'` or log to audit table |
| `RAISE EXCEPTION 'msg'` | `RAISE` statement or `SIGNAL SQLSTATE` | Handled in `EXCEPTION WHEN OTHER THEN` |
| `$$...$$` dollar quoting | `$$...$$` | Same — supported in Snowflake |
| `RETURN QUERY SELECT ...` | `RETURN TABLE(...)` | Different syntax |
| `RECORD` type | Use `RESULTSET` or table | No direct RECORD type |
| `%ROWTYPE` | Not supported | Rewrite to individual variable declarations |
| `%TYPE` | Not supported | Use explicit data types |
| `PERFORM` (discard result) | Just call the proc/function | Remove `PERFORM` keyword |
| `EXECUTE format(...)` | `EXECUTE IMMEDIATE` | Syntax changes slightly |
| `pg_sleep(n)` | `SYSTEM$WAIT(n)` | Snowflake system function |
| `NOW()` / `CURRENT_TIMESTAMP` | `CURRENT_TIMESTAMP()` | Both work actually |
| `SERIAL` / sequences | `AUTOINCREMENT` or sequences | Different DDL |
| `ARRAY` types | `ARRAY` | Supported but different functions |
| Schema-qualified calls | Schema-qualified calls | Supported |
| `INSERT ... ON CONFLICT` | `MERGE INTO` | No ON CONFLICT in Snowflake |
| `RETURNING` clause | Not supported | Capture via MERGE or separate SELECT |

---

## STEP 4 — Python Script to Auto-Convert GP Procedures to Snowflake

This script reads each `.sql` file from Step 2 and applies rule-based transformations.

```python
import re
import os

# ─────────────────────────────────────────────
# CORE TRANSFORMATION RULES
# Each rule is (pattern, replacement, description)
# ─────────────────────────────────────────────

TRANSFORMATIONS = [

    # ── LANGUAGE DECLARATION ──────────────────────────────────────────────────
    (r"LANGUAGE\s+plpgsql", "LANGUAGE SQL", "plpgsql → SQL Scripting"),
    (r"LANGUAGE\s+plpythonu", "LANGUAGE PYTHON\n  RUNTIME_VERSION = '3.8'\n  HANDLER = 'run'",
     "plpythonu → Snowflake Python"),
    (r"LANGUAGE\s+sql\b", "LANGUAGE SQL", "sql → SQL"),

    # ── PROCEDURE vs FUNCTION HEADER ─────────────────────────────────────────
    # Greenplum uses CREATE OR REPLACE FUNCTION for both; Snowflake has PROCEDURE
    # NOTE: This is heuristic — procedures with VOID return type → CREATE PROCEDURE
    (r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+(\w+\.?\w+)\s*\(([^)]*)\)\s*RETURNS\s+void",
     r"CREATE OR REPLACE PROCEDURE \1(\2)\n  RETURNS STRING",
     "RETURNS void → CREATE PROCEDURE RETURNS STRING"),

    # ── DOLLAR QUOTING → AS $$ ────────────────────────────────────────────────
    # Snowflake supports $$, keep it but standardize
    (r"\$\$\s*\n\s*DECLARE", "$$\nDECLARE", "Normalize $$ DECLARE"),

    # ── DECLARE / BEGIN / END ────────────────────────────────────────────────
    # plpgsql has DECLARE before BEGIN; Snowflake Scripting also uses DECLARE/BEGIN
    # No change needed structurally — but add RETURNS STRING guard
    (r"\bBEGIN\b(?!\s+TRANSACTION)", "BEGIN", "BEGIN stays"),

    # ── RAISE NOTICE → log table insert ──────────────────────────────────────
    (r"RAISE\s+NOTICE\s+'([^']+)'(?:\s*,\s*([^;]+))?;",
     r"-- RAISE NOTICE replaced: INSERT INTO proc_log(msg, logged_at) VALUES('\1', CURRENT_TIMESTAMP());",
     "RAISE NOTICE → log table comment"),

    # ── RAISE EXCEPTION → Snowflake RAISE ────────────────────────────────────
    (r"RAISE\s+EXCEPTION\s+'([^']+)'(?:\s*,\s*([^;]+))?;",
     r"RAISE (USING MESSAGE => '\1');",
     "RAISE EXCEPTION → RAISE"),

    # ── PERFORM (discard result) ──────────────────────────────────────────────
    (r"\bPERFORM\b\s+", "CALL ",
     "PERFORM → CALL (review manually)"),

    # ── EXECUTE format(...) → EXECUTE IMMEDIATE ──────────────────────────────
    (r"\bEXECUTE\s+format\s*\(", "EXECUTE IMMEDIATE format(",
     "EXECUTE format → EXECUTE IMMEDIATE format"),

    (r"\bEXECUTE\s+(?!IMMEDIATE)(')", r"EXECUTE IMMEDIATE \1",
     "EXECUTE 'sql' → EXECUTE IMMEDIATE 'sql'"),

    # ── %ROWTYPE / %TYPE → remove (flag for manual review) ───────────────────
    (r"(\w+)\s+(\w+)%ROWTYPE", r"-- TODO: \1 \2%ROWTYPE not supported — declare columns individually",
     "%ROWTYPE → TODO comment"),

    (r"(\w+)\s+(\w+\.\w+)%TYPE", r"-- TODO: \1 \2%TYPE not supported — use explicit type",
     "%TYPE → TODO comment"),

    # ── RETURN QUERY SELECT → RETURN TABLE ───────────────────────────────────
    (r"RETURN\s+QUERY\s+SELECT\s+", "-- TODO: RETURN QUERY → use RETURN TABLE() or RESULTSET\nSELECT ",
     "RETURN QUERY → TODO"),

    # ── RECORD type ───────────────────────────────────────────────────────────
    (r"(\w+)\s+RECORD;", r"-- TODO: \1 RECORD — use table variable or RESULTSET in Snowflake",
     "RECORD → TODO comment"),

    # ── pg_sleep → SYSTEM$WAIT ────────────────────────────────────────────────
    (r"pg_sleep\s*\(([^)]+)\)", r"SYSTEM$WAIT(\1)",
     "pg_sleep → SYSTEM$WAIT"),

    # ── NOW() stays, CLOCK_TIMESTAMP → CURRENT_TIMESTAMP ─────────────────────
    (r"\bCLOCK_TIMESTAMP\s*\(\)", "CURRENT_TIMESTAMP()",
     "CLOCK_TIMESTAMP → CURRENT_TIMESTAMP"),

    (r"\btimeofday\s*\(\)", "CURRENT_TIMESTAMP()::STRING",
     "timeofday() → CURRENT_TIMESTAMP()::STRING"),

    # ── INSERT ... ON CONFLICT → MERGE hint ──────────────────────────────────
    (r"INSERT\s+INTO\s+(\w+\.?\w+)([^;]+)ON\s+CONFLICT([^;]+);",
     r"-- TODO: ON CONFLICT not supported — rewrite as MERGE INTO \1 ...",
     "ON CONFLICT → TODO MERGE"),

    # ── RETURNING clause ─────────────────────────────────────────────────────
    (r"\bRETURNING\b\s+[^;]+;",
     "-- TODO: RETURNING clause not supported — use separate SELECT or MERGE OUTPUT",
     "RETURNING → TODO"),

    # ── Array functions ───────────────────────────────────────────────────────
    (r"\barray_agg\s*\(", "ARRAY_AGG(",  "array_agg → ARRAY_AGG"),
    (r"\bunnest\s*\(", "FLATTEN(INPUT => ", "unnest → FLATTEN (review)"),
    (r"\bARRAY\[([^\]]+)\]", r"ARRAY_CONSTRUCT(\1)", "ARRAY[] → ARRAY_CONSTRUCT()"),

    # ── String functions ──────────────────────────────────────────────────────
    (r"\bSPLIT_PART\s*\(", "SPLIT_PART(",   "SPLIT_PART — same"),
    (r"\bREGEXP_REPLACE\s*\(", "REGEXP_REPLACE(", "REGEXP_REPLACE — same"),
    (r"\bSTRPOS\s*\(([^,]+),([^)]+)\)", r"POSITION(\2 IN \1)",
     "strpos(str,sub) → POSITION(sub IN str)"),
    (r"\bCHR\s*\(", "CHAR(",             "CHR → CHAR"),
    (r"\bASCII\s*\(", "ASCII(",           "ASCII — same"),
    (r"\bLPAD\s*\(", "LPAD(",             "LPAD — same"),
    (r"\bRPAD\s*\(", "RPAD(",             "RPAD — same"),

    # ── Date functions ────────────────────────────────────────────────────────
    (r"\bDATE_TRUNC\s*\('(\w+)',\s*([^)]+)\)",
     r"DATE_TRUNC('\1', \2)",
     "DATE_TRUNC — same signature"),

    (r"\bEXTRACT\s*\(\s*(\w+)\s+FROM\s+([^)]+)\)",
     r"DATE_PART('\1', \2)",
     "EXTRACT(x FROM y) → DATE_PART('x', y)"),

    (r"\bAGE\s*\(([^)]+)\)",
     r"DATEDIFF('year', \1, CURRENT_DATE())",
     "AGE() → DATEDIFF (review semantics)"),

    (r"\bINTERVAL\s+'(\d+)\s+days?'", r"INTERVAL '\1 DAYS'",
     "INTERVAL normalization"),

    # ── Type casts ────────────────────────────────────────────────────────────
    (r"::\s*integer\b", "::INTEGER",     "::integer → ::INTEGER"),
    (r"::\s*bigint\b",  "::BIGINT",      "::bigint → ::BIGINT"),
    (r"::\s*numeric\b", "::NUMBER",      "::numeric → ::NUMBER"),
    (r"::\s*varchar\b", "::VARCHAR",     "::varchar → ::VARCHAR"),
    (r"::\s*text\b",    "::VARCHAR",     "::text → ::VARCHAR"),
    (r"::\s*boolean\b", "::BOOLEAN",     "::boolean → ::BOOLEAN"),
    (r"::\s*timestamp\b", "::TIMESTAMP", "::timestamp → ::TIMESTAMP"),
    (r"::\s*date\b",    "::DATE",        "::date → ::DATE"),

    # ── Exception handling ────────────────────────────────────────────────────
    (r"EXCEPTION\s+WHEN\s+OTHERS\s+THEN",
     "EXCEPTION WHEN OTHER THEN",
     "WHEN OTHERS → WHEN OTHER"),

    (r"\bSQLSTATE\b", "SQLSTATE",        "SQLSTATE — same variable name"),
    (r"\bSQLERRM\b",  "SQLERRM",         "SQLERRM — same variable name"),

    # ── Common system catalog refs ────────────────────────────────────────────
    (r"\bpg_catalog\.", "",               "Remove pg_catalog. prefix"),
    (r"\binformation_schema\.", "INFORMATION_SCHEMA.", "information_schema caps"),

    # ── Transaction control (not in Snowflake SP) ─────────────────────────────
    (r"\bCOMMIT\s*;", "-- COMMIT; -- not needed inside Snowflake SP (auto-commit)",
     "COMMIT → comment"),
    (r"\bROLLBACK\s*;", "-- ROLLBACK; -- use EXCEPTION block instead",
     "ROLLBACK → comment"),
]


def convert_gp_to_snowflake(sql_text: str) -> tuple[str, list]:
    """Apply all transformation rules and return (converted_sql, change_log)."""
    result = sql_text
    change_log = []

    for pattern, replacement, description in TRANSFORMATIONS:
        new_result, count = re.subn(pattern, replacement, result, flags=re.IGNORECASE)
        if count > 0:
            change_log.append(f"  [{count}x] {description}")
            result = new_result

    return result, change_log


def convert_all_procedures(input_dir: str, output_dir: str):
    """Process all .sql files in input_dir and write converted files to output_dir."""
    os.makedirs(output_dir, exist_ok=True)
    summary = []

    for filename in sorted(os.listdir(input_dir)):
        if not filename.endswith(".sql"):
            continue

        input_path = os.path.join(input_dir, filename)
        output_path = os.path.join(output_dir, filename)

        with open(input_path, "r") as f:
            original_sql = f.read()

        converted_sql, change_log = convert_gp_to_snowflake(original_sql)

        # Prepend a header with change summary
        header = (
            f"-- ═══════════════════════════════════════════\n"
            f"-- AUTO-CONVERTED: Greenplum → Snowflake\n"
            f"-- Source: {filename}\n"
            f"-- Changes applied:\n"
        )
        for log_line in change_log:
            header += f"--   {log_line}\n"
        header += (
            f"-- ⚠ Review TODO comments before deploying\n"
            f"-- ═══════════════════════════════════════════\n\n"
        )

        with open(output_path, "w") as f:
            f.write(header + converted_sql)

        summary.append((filename, len(change_log)))
        print(f"✓ {filename} — {len(change_log)} rule(s) applied")

    print(f"\nDone. {len(summary)} files written to: {output_dir}")
    return summary


# ─── ENTRY POINT ──────────────────────────────────────────────────────────────
if __name__ == "__main__":
    SCHEMA       = "claims"
    INPUT_DIR    = f"./gp_procedures/{SCHEMA}"
    OUTPUT_DIR   = f"./sf_procedures/{SCHEMA}"

    convert_all_procedures(INPUT_DIR, OUTPUT_DIR)
```

---

## STEP 5 — What the Script Covers and What Needs Manual Review

### Auto-converted (safe to trust)

| Category | Examples |
|---|---|
| Language declaration | `plpgsql` → `SQL`, `plpythonu` → `PYTHON` |
| Exception handler | `WHEN OTHERS` → `WHEN OTHER` |
| Type casts | `::text` → `::VARCHAR`, `::numeric` → `::NUMBER` |
| Date functions | `EXTRACT(x FROM y)` → `DATE_PART('x', y)` |
| String functions | `STRPOS` → `POSITION`, `CHR` → `CHAR` |
| System functions | `pg_sleep` → `SYSTEM$WAIT` |
| Array functions | `ARRAY[1,2]` → `ARRAY_CONSTRUCT(1,2)` |
| Transaction control | `COMMIT/ROLLBACK` commented out |
| Dynamic SQL | `EXECUTE '...'` → `EXECUTE IMMEDIATE '...'` |

### Needs manual review (marked with `-- TODO`)

| Pattern | Why Manual Review? |
|---|---|
| `%ROWTYPE` / `%TYPE` | Snowflake has no row-type variable; declare each column explicitly |
| `RETURN QUERY SELECT` | Snowflake uses `RETURN TABLE(...)` with a declared `RESULTSET` |
| `INSERT ... ON CONFLICT` | Rewrite as `MERGE INTO` |
| `RETURNING` clause | Capture output via `MERGE` or separate `SELECT` |
| `PERFORM` → `CALL` | Only valid for procedures, not functions |
| `RAISE NOTICE` | Decide: log to table, or remove entirely |
| Python (`plpythonu`) | Verify handler function name matches `HANDLER = 'run'` |
| `unnest()` → `FLATTEN` | Flatten syntax differs; review query context |

---

## STEP 6 — Deploy Converted Procedures to Snowflake

### Install Snowflake connector

```bash
pip install snowflake-connector-python
```

### Connect to Snowflake

```python
import snowflake.connector

sf_conn = snowflake.connector.connect(
    account   = "your_account_identifier",   # e.g. "abc12345.us-east-1"
    user      = "your_username",
    password  = "your_password",             # or use key-pair auth
    warehouse = "YOUR_WH",
    database  = "YOUR_DB",
    schema    = "YOUR_SCHEMA",
    role      = "YOUR_ROLE"
)
sf_cur = sf_conn.cursor()
print("Connected to Snowflake")
```

### Deploy a single procedure

```python
def deploy_procedure(sf_cursor, filepath: str, dry_run: bool = False):
    with open(filepath, "r") as f:
        sql = f.read()

    # Strip comment header lines before executing
    lines = [l for l in sql.splitlines() if not l.startswith("--")]
    clean_sql = "\n".join(lines).strip()

    if dry_run:
        print(f"[DRY RUN] Would execute:\n{clean_sql[:300]}...\n")
        return True

    try:
        sf_cursor.execute(clean_sql)
        print(f"✓ Deployed: {os.path.basename(filepath)}")
        return True
    except Exception as e:
        print(f"✗ FAILED: {os.path.basename(filepath)}")
        print(f"  Error: {e}")
        return False
```

### Batch deploy all converted procedures

```python
import os

OUTPUT_DIR = "./sf_procedures/claims"
results = {"success": [], "failed": []}

for filename in sorted(os.listdir(OUTPUT_DIR)):
    if not filename.endswith(".sql"):
        continue
    filepath = os.path.join(OUTPUT_DIR, filename)
    ok = deploy_procedure(sf_cur, filepath, dry_run=False)
    if ok:
        results["success"].append(filename)
    else:
        results["failed"].append(filename)

print(f"\n── Deployment Summary ──────────────────")
print(f"  ✓ Success : {len(results['success'])}")
print(f"  ✗ Failed  : {len(results['failed'])}")
if results["failed"]:
    print("\n  Failed files:")
    for f in results["failed"]:
        print(f"    - {f}")
```

---

## STEP 7 — Verify Procedures Created in Snowflake

```sql
-- List all procedures in your schema
SHOW PROCEDURES IN SCHEMA your_database.your_schema;

-- Describe a specific procedure
DESCRIBE PROCEDURE your_schema.your_procedure_name(VARCHAR);

-- Get the DDL back (round-trip check)
SELECT GET_DDL('PROCEDURE', 'your_schema.your_procedure_name(VARCHAR)');

-- Test call
CALL your_schema.your_procedure_name('param1');
```

---

## STEP 8 — Full End-to-End Run

```python
# run_migration.py  — tie everything together

import psycopg2
import snowflake.connector
import os

# ─── CONFIG ───────────────────────────────────────────────────────────────────
GP_CONFIG = dict(host="gp-host", port=5432, dbname="mydb",
                 user="gpuser", password="gppass")

SF_CONFIG = dict(account="abc12345.us-east-1", user="sfuser",
                 password="sfpass", warehouse="LOAD_WH",
                 database="MY_DB", schema="CLAIMS", role="SYSADMIN")

SCHEMA        = "claims"
GP_OUTPUT_DIR = f"./gp_procedures/{SCHEMA}"
SF_OUTPUT_DIR = f"./sf_procedures/{SCHEMA}"

# ─── STEP 1: Extract from GP ──────────────────────────────────────────────────
gp_conn   = psycopg2.connect(**GP_CONFIG)
gp_cursor = gp_conn.cursor()

gp_cursor.execute("""
    SELECT p.proname, pg_get_functiondef(p.oid)
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = %s
""", (SCHEMA,))

os.makedirs(GP_OUTPUT_DIR, exist_ok=True)
for name, defn in gp_cursor.fetchall():
    with open(f"{GP_OUTPUT_DIR}/{name}.sql", "w") as f:
        f.write(defn)

gp_conn.close()
print(f"Extracted procedures to {GP_OUTPUT_DIR}")

# ─── STEP 2: Convert ──────────────────────────────────────────────────────────
convert_all_procedures(GP_OUTPUT_DIR, SF_OUTPUT_DIR)

# ─── STEP 3: Deploy to Snowflake ─────────────────────────────────────────────
sf_conn   = snowflake.connector.connect(**SF_CONFIG)
sf_cursor = sf_conn.cursor()

for filename in sorted(os.listdir(SF_OUTPUT_DIR)):
    if filename.endswith(".sql"):
        deploy_procedure(sf_cursor, f"{SF_OUTPUT_DIR}/{filename}")

sf_conn.close()
print("Migration complete.")
```

---

## Quick Reference: Snowflake Procedure Template

For any procedure that needed heavy manual rewrite, use this as your base:

```sql
CREATE OR REPLACE PROCEDURE schema_name.procedure_name(
    p_param1  VARCHAR,
    p_param2  NUMBER
)
RETURNS STRING
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    v_count     NUMBER DEFAULT 0;
    v_message   VARCHAR DEFAULT '';
    v_err_msg   VARCHAR DEFAULT '';
    v_err_code  VARCHAR DEFAULT '';

BEGIN
    -- ── main logic ──────────────────────────────────────────
    SELECT COUNT(*) INTO :v_count
    FROM your_table
    WHERE column1 = :p_param1;

    IF (:v_count = 0) THEN
        RAISE (USING MESSAGE => 'No records found for: ' || :p_param1);
    END IF;

    MERGE INTO target_table t
    USING (SELECT :p_param1 AS col1) s
    ON (t.id = s.col1)
    WHEN MATCHED THEN UPDATE SET t.updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (id, created_at) VALUES (s.col1, CURRENT_TIMESTAMP());

    v_message := 'SUCCESS | rows: ' || :v_count;
    RETURN :v_message;

EXCEPTION
    WHEN OTHER THEN
        v_err_msg  := SQLERRM;
        v_err_code := SQLSTATE;

        INSERT INTO etl_error_log (proc_name, error_msg, error_code, logged_at)
        VALUES ('procedure_name', :v_err_msg, :v_err_code, CURRENT_TIMESTAMP());

        RETURN 'FAILED | ' || :v_err_code || ' | ' || :v_err_msg;
END;
$$;
```

---

*Generated for Greenplum → Snowflake migration | Fidelis Care / Centene platform*
