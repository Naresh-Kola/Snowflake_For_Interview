# Greenplum → Snowflake Procedure Migration — Flow Explanation

## Overview

The script connects to a live Greenplum database, extracts all stored **procedures**
(not functions or aggregates), translates their PL/pgSQL bodies to
**Snowflake Scripting** (Snowflake's native SQL-based procedural language),
and emits `CREATE OR REPLACE PROCEDURE` DDL. No data is moved.

---

## High-Level Flow

```
CLI args
   │
   ▼
Connect to Greenplum (psycopg2)
   │
   ├──► Detect GP version  ──► choose query (modern vs legacy)
   │
   └──► Query pg_proc catalog  ──► procedure rows[]
          │
          ▼
   Build in-memory model
   ProcDef / ProcArg objects
   │
   ├──► parse_args_string()  ──► typed argument list
   └──► map_type()           ──► Snowflake-compatible types
          │
          ▼
   Translate PL/pgSQL body
   translate_body()
   ├──► Apply ~20 syntax rewrite rules (regex)
   └──► Flag incompatible patterns as warnings
          │
          ▼
   Render Snowflake DDL
   render_procedure_ddl()
   ├──► Signature (IN args → params, OUT args → RETURNS)
   ├──► LANGUAGE SQL / EXECUTE AS CALLER
   ├──► Translated body in $$ ... $$
   └──► Inline ⚠ warnings as comments
          │
          ▼
   Write to file  (or print to stdout)
   + Warning summary block at end
```

---

## Step-by-Step Breakdown

### 1. CLI Argument Parsing (`main`)

Same interface as the DDL migration script for consistency:

| Argument | Required | Description |
|---|---|---|
| `--host` | yes | Greenplum server hostname |
| `--port` | no (5432) | Greenplum port |
| `--dbname` | yes | Database name |
| `--user` | yes | DB username |
| `--password` | yes | DB password |
| `--schemas` | no | Space-separated schema filter; all non-system schemas if omitted |
| `--output` | no | Output `.sql` file path; stdout if omitted |

---

### 2. Connecting & Version Detection

```python
conn = psycopg2.connect(..., connect_timeout=15)
cur.execute("SELECT version();")
```

After connecting, the script reads the Greenplum version string. This determines which catalog query to run:

| Version | `prokind` column | Query used |
|---|---|---|
| Greenplum 6+ | Available (`'p'` = procedure) | `PROCEDURES_QUERY` |
| Greenplum 4/5 | Not available | `PROCEDURES_QUERY_LEGACY` (filters by `void` return type and language) |

---

### 3. Querying the Procedure Catalog

The script queries `pg_proc` joined to `pg_namespace` and `pg_language`:

```sql
SELECT
    n.nspname,                                    -- schema
    p.proname,                                    -- name
    pg_get_function_arguments(p.oid),             -- full arg list with modes & types
    pg_get_function_result(p.oid),                -- return type
    l.lanname,                                    -- language (plpgsql, sql, etc.)
    p.prosrc,                                     -- raw procedure body
    p.provolatile,                                -- i/s/v
    p.proisstrict,                                -- null-handling
    obj_description(p.oid, 'pg_proc')             -- comment/description
FROM pg_proc ...
WHERE p.prokind = 'p'  -- procedures only
```

`pg_get_function_arguments()` returns the full argument string with names, modes
(`IN`/`OUT`/`INOUT`), and types — exactly what's needed to reconstruct the Snowflake signature.

System schemas (`pg_catalog`, `information_schema`, `gp_toolkit`) are always excluded.
If `--schemas` is provided, a dynamic `IN (...)` clause is injected.

---

### 4. Parsing Arguments (`parse_args_string`)

Greenplum's argument string looks like:

```
IN p_id integer, OUT p_result text, INOUT p_count numeric(10,2)
```

The parser splits on commas that are **not inside parentheses** (to handle types like
`numeric(10,2)` that contain commas), then for each token:

1. Detects and strips the mode keyword (`IN`, `OUT`, `INOUT`, `VARIADIC`); defaults to `IN`
2. Reads the argument name (first token after mode)
3. Reads the type (remaining tokens joined)
4. Passes the type through `map_type()` to get the Snowflake equivalent
5. Stores result in a `ProcArg` dataclass

Unnamed arguments (Greenplum allows them) get auto-names: `p_arg1`, `p_arg2`, etc.

---

### 5. Data Type Mapping (`map_type`)

Same translation logic as the DDL script, extended with procedure-specific types:

| Greenplum type | Snowflake type | Notes |
|---|---|---|
| `void` | `VARIANT` | Procedures that return nothing use `VARIANT` as placeholder |
| `record` | `VARIANT` | No row type in SF; semi-structured |
| `refcursor` | `VARCHAR` | Cursors don't cross the boundary |
| `trigger` | `VARIANT` | Trigger functions can't be ported directly |
| `%TYPE` / `%ROWTYPE` | `VARIANT` | No catalog type references in SF |
| `anyelement` | `VARIANT` | Polymorphic — no direct equivalent |

---

### 6. Translating the Procedure Body (`translate_body`)

This is the core of the script. The body is first checked for language:

- `plpgsql` and `sql` → auto-translated
- `plpython3u`, `plpythonu`, `c`, or other → body is preserved as-is with a warning requiring manual rewrite

For translatable bodies, ~20 regex rewrite rules are applied in sequence:

#### Syntax Rewrites

| PL/pgSQL pattern | Snowflake Scripting equivalent | Notes |
|---|---|---|
| `RAISE NOTICE/INFO/LOG` | `-- RAISE NOTICE` | SF has no server-side `RAISE NOTICE`; commented out |
| `RAISE EXCEPTION` | `RAISE` | SF Scripting uses `RAISE` without a severity level |
| `PERFORM expr` | `CALL expr` | `PERFORM` discards results; SF uses `CALL` for procedures |
| `NOW()` | `CURRENT_TIMESTAMP` | Standard SF equivalent |
| `CLOCK_TIMESTAMP()` | `CURRENT_TIMESTAMP` | No session clock in SF |
| `STRING_AGG(...)` | `LISTAGG(...)` | SF uses `LISTAGG` |
| `UNNEST(...)` | `FLATTEN()` | SF semi-structured equivalent; flagged for review |
| `CREATE TEMP TABLE` | `CREATE TEMPORARY TABLE` | SF requires full keyword |
| `value::type` | `CAST(value AS type)` | GP cast syntax → SF standard CAST |
| `RETURN NEXT` | comment + `RETURN` | SF doesn't support set-returning procedures; flagged |
| `RETURN QUERY` | comment + `RETURN` | Same — must be refactored |
| `FOUND` | inline comment | SF uses `ROW_COUNT() > 0`; flagged |
| `RETURNING` clause | inline comment | Not supported in SF Scripting DML |
| `%TYPE` / `%ROWTYPE` | `VARIANT` + comment | No catalog type references |
| `RECORD` | `VARIANT` + comment | No anonymous row type |
| `SETOF` | `VARIANT` + comment | Set-returning not directly portable |

#### Incompatibility Flags (warnings, body untouched for these)

| Pattern detected | Warning message |
|---|---|
| `GP_*` catalog references | Remove or replace — not in SF |
| `pg_catalog.*` references | Not available in Snowflake |
| `DISTRIBUTED BY` inside body | Not applicable in SF |
| `CURSOR` usage | Review — SF cursor syntax differs |
| `COPY` statement | Use Snowflake `COPY INTO` syntax |
| `SERIAL` type | Replace with `AUTOINCREMENT` or a sequence |

---

### 7. Rendering Snowflake Procedure DDL (`render_procedure_ddl`)

The final DDL is assembled in this order:

**Header comment block**
```sql
-- Procedure: "schema"."proc_name"
-- Description: (if present)
-- ⚠ Migration warnings:
--   • ...
```

**Signature**

Only `IN` and `INOUT` arguments appear as parameters (Snowflake procedure parameters
are always inputs). `OUT` / `INOUT` arguments determine the `RETURNS` type:

| OUT args count | RETURNS type |
|---|---|
| 0 | Mapped return type from `pg_get_function_result` |
| 1 | That argument's Snowflake type |
| 2+ | `TABLE(col1 TYPE1, col2 TYPE2, ...)` |
| `void` return | `VARIANT` (placeholder) |

**Fixed clauses**
```sql
LANGUAGE SQL          -- Snowflake Scripting
EXECUTE AS CALLER     -- preserves caller's privilege context (closest to GP default)
```

**Body**
```sql
AS
$$
  <translated PL/pgSQL body>
$$;
```

---

### 8. Warning Summary

At the end of the output file, a summary block lists every procedure that had
at least one migration warning, with the count per procedure:

```sql
-- ============================================================
-- WARNING SUMMARY
-- ============================================================
-- "public"."process_orders": 3 warning(s)
-- "sales"."refresh_summary": 1 warning(s)
```

This makes it easy to prioritise manual QA without reading through the entire file.

---

## What Is Intentionally Omitted

| Greenplum feature | Disposition |
|---|---|
| `LANGUAGE plpython3u` bodies | Preserved as-is; flagged for manual rewrite |
| `LANGUAGE c` bodies | Preserved as-is; flagged — C extensions don't exist in SF |
| `SECURITY DEFINER` | Not emitted; `EXECUTE AS CALLER` used instead (safer default) |
| `COST` / `ROWS` hints | Not applicable in SF |
| `STRICT` / `CALLED ON NULL INPUT` | Not emitted; SF always calls on null input |
| Trigger procedures | No trigger mechanism in SF; must be redesigned |
| Aggregate procedures | Out of scope (only `prokind = 'p'` fetched) |
| `SET` configuration parameters | Not applicable in SF |

---

## What Requires Manual Review After Migration

Even with auto-translation, some constructs need a human to finish:

1. **`RAISE NOTICE`** lines are commented out — add `SYSTEM$LOG()` calls if logging is needed.
2. **`RETURNING` clauses** in `INSERT`/`UPDATE`/`DELETE` — refactor to separate `SELECT` statements.
3. **`RETURN NEXT` / `RETURN QUERY`** — refactor to a `RESULTSET` variable with `RETURN TABLE(...)`.
4. **Cursor loops** — verify cursor `OPEN`/`FETCH`/`CLOSE` syntax matches SF Scripting.
5. **`CAST` rewrites from `::`** — validate that inferred types are correct.
6. **`%TYPE` / `%ROWTYPE`** replaced with `VARIANT` — replace with concrete types where possible.
7. **`EXECUTE` (dynamic SQL)** — SF Scripting supports it, but binding syntax differs.

---

## Dependencies

```
psycopg2-binary   # PostgreSQL / Greenplum adapter
```

```bash
pip install psycopg2-binary
```

## Usage

```bash
# All non-system schemas
python gp_procedures_to_snowflake.py \
  --host gp-host.example.com \
  --dbname mydb --user myuser --password secret \
  --output snowflake_procedures.sql

# Specific schemas only
python gp_procedures_to_snowflake.py \
  --host gp-host.example.com \
  --dbname mydb --user myuser --password secret \
  --schemas public sales reporting \
  --output snowflake_procedures.sql
```
