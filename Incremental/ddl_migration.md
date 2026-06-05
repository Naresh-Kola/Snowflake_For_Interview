# Greenplum → Snowflake DDL Migration Guide

## Overview

This guide covers an automated pipeline to migrate **450+ tables** from **Greenplum** to **Snowflake** — extracting DDLs, converting them, and creating tables in Snowflake in bulk with full logging and error recovery.

---

## Architecture

```
Greenplum DB
    │
    ▼
[Step 1] Extract DDLs
    │   pg_get_tabledef() / information_schema
    │
    ▼
[Step 2] Parse & Convert DDL
    │   Type mapping, constraint rewriting, distribution clause removal
    │
    ▼
[Step 3] Create Tables in Snowflake
    │   Parallel execution via ThreadPoolExecutor
    │
    ▼
[Step 4] Reports & Logs
        migration_report.csv + migration.log
```

---

## Why This Approach?

| Concern | Solution |
|---|---|
| 450+ tables = slow serial execution | `ThreadPoolExecutor` with configurable workers |
| DDL differences between GP & SF | Regex-based type mapper + clause stripper |
| Partial failures mid-run | Per-table error capture, resume from checkpoint |
| Audit trail needed | CSV report with status per table |
| Secrets management | `.env` file or env vars, never hardcoded |

---

## Step 1 — Extract DDLs from Greenplum

Greenplum is PostgreSQL-based. We use `psycopg2` to connect and query `information_schema.columns` to reconstruct DDLs programmatically (safer than `pg_dump` for selective migration).

**What we extract per table:**
- Column names, data types, character lengths, numeric precision/scale
- `NOT NULL` constraints
- Default values
- Primary key constraints (from `information_schema.table_constraints`)

---

## Step 2 — DDL Conversion (Greenplum → Snowflake)

This is the most critical step. Greenplum and Snowflake differ in several ways:

### Data Type Mapping

| Greenplum Type | Snowflake Type | Notes |
|---|---|---|
| `serial` / `bigserial` | `NUMBER AUTOINCREMENT` | Greenplum's serial is a sequence shorthand |
| `int4` / `integer` | `INTEGER` | Direct map |
| `int8` / `bigint` | `BIGINT` | Direct map |
| `int2` / `smallint` | `SMALLINT` | Direct map |
| `float4` / `real` | `FLOAT` | |
| `float8` / `double precision` | `DOUBLE` | |
| `numeric(p,s)` / `decimal` | `NUMBER(p,s)` | Preserve precision/scale |
| `varchar(n)` / `character varying` | `VARCHAR(n)` | |
| `bpchar` / `char(n)` | `CHAR(n)` | |
| `text` | `TEXT` | |
| `bool` / `boolean` | `BOOLEAN` | |
| `date` | `DATE` | |
| `timestamp` / `timestamptz` | `TIMESTAMP_NTZ` / `TIMESTAMP_TZ` | |
| `bytea` | `BINARY` | |
| `json` / `jsonb` | `VARIANT` | Snowflake's semi-structured type |
| `uuid` | `VARCHAR(36)` | Snowflake has no native UUID |
| `xml` | `VARIANT` | |
| `array` types | `VARIANT` | Flatten or keep as VARIANT |
| `oid` | `NUMBER` | Internal PG type |
| `name` | `VARCHAR(128)` | Internal PG identifier type |

### Clauses Removed (Snowflake doesn't support these)
- `DISTRIBUTED BY (col)` — Greenplum distribution key
- `DISTRIBUTED RANDOMLY` — Same
- `WITH (appendonly=true, ...)` — Greenplum storage parameters
- `ENCODING (...)` — Column encoding directives
- `TABLESPACE ...` — Tablespace references
- `INHERITS (...)` — Table inheritance
- `WITHOUT OIDS` — Old PG syntax

### Identifiers
- Reserved keywords in Snowflake are automatically double-quoted
- All identifiers normalized to uppercase (Snowflake default behavior)

---

## Step 3 — Parallel Table Creation in Snowflake

We use `snowflake-connector-python` and Python's `ThreadPoolExecutor`:

- Default **10 parallel workers** (tunable via `--workers`)
- Each worker gets its own Snowflake connection (connections are not thread-safe)
- Failed tables are logged and can be retried independently

---

## Step 4 — Output Reports

After migration, two files are generated:

### `migration_report.csv`
```
schema,table,status,error_message,duration_seconds
public,orders,SUCCESS,,0.42
public,legacy_audit,FAILED,"invalid type oid","—"
```

### `migration.log`
Full verbose log with timestamps for every table attempt.

---

## Prerequisites

```bash
pip install psycopg2-binary snowflake-connector-python python-dotenv tqdm
```

### `.env` File
```ini
# Greenplum
GP_HOST=your-greenplum-host
GP_PORT=5432
GP_DATABASE=your_db
GP_USER=your_user
GP_PASSWORD=your_password
GP_SCHEMA=public          # comma-separated for multiple: public,sales,hr

# Snowflake
SF_ACCOUNT=your_account.region
SF_USER=your_user
SF_PASSWORD=your_password
SF_DATABASE=YOUR_DB
SF_SCHEMA=PUBLIC
SF_WAREHOUSE=COMPUTE_WH
SF_ROLE=SYSADMIN
```

---

## Usage

```bash
# Full migration (all tables in schema)
python gp_to_snowflake.py

# Dry run — generate DDLs only, don't create in Snowflake
python gp_to_snowflake.py --dry-run

# Migrate specific tables
python gp_to_snowflake.py --tables orders,customers,products

# Control parallelism
python gp_to_snowflake.py --workers 20

# Resume — skip tables that already exist in Snowflake
python gp_to_snowflake.py --skip-existing

# Override schema
python gp_to_snowflake.py --gp-schema sales --sf-schema SALES
```

---

## Key Design Decisions

1. **Parallel execution** — 10x faster than serial for 450+ tables
2. **Per-connection pooling** — Each thread owns its Snowflake connection to avoid race conditions
3. **Idempotent by default** — `CREATE TABLE IF NOT EXISTS` prevents duplicate errors on re-runs
4. **Type mapping is extensible** — Add custom mappings via `CUSTOM_TYPE_MAP` dict in the script
5. **DDLs saved to disk** — Every converted DDL is saved to `./ddl_output/` for audit/review
6. **Checkpoint file** — Tracks completed tables so you can safely resume interrupted runs

---

## Limitations & Manual Review Cases

Some things require **manual intervention** after automated migration:

- **Foreign keys** — Not migrated (referential integrity differs; create post-load)
- **Sequences** — Converted to `AUTOINCREMENT` but verify start values
- **Triggers / Functions** — Not applicable in Snowflake
- **Row-level security** — Migrate to Snowflake Row Access Policies manually
- **Partitioned tables** — Greenplum partitions → review Snowflake clustering keys
- **Custom domain types** — Resolved to base types; verify correctness
- **`bytea` columns > 8MB** — Snowflake `BINARY` max is 8MB
