# Greenplum → Snowflake DDL Migration — Flow Explanation

## Overview

The script is a **read-only schema extractor**. It connects to a live Greenplum database,
introspects its catalog, translates every object definition into Snowflake-compatible DDL,
and writes the result to a `.sql` file (or stdout). No data is moved.

---

## High-Level Flow

```
CLI args
   │
   ▼
Connect to Greenplum (psycopg2)
   │
   ├──► Query sequences       ──► sequence_rows[]
   ├──► Query tables/columns  ──► column_rows[]
   └──► Query primary keys    ──► pk_map{}
          │
          ▼
   Build in-memory model
   TableDef / ColumnDef objects
          │
          ▼
   Render DDL strings
   ├──► Sequence DDL blocks
   └──► Table DDL blocks
          │
          ▼
   Write to file  (or print to stdout)
```

---

## Step-by-Step Breakdown

### 1. CLI Argument Parsing (`main`)

The entry point uses `argparse` to collect:

| Argument | Required | Description |
|---|---|---|
| `--host` | yes | Greenplum server hostname |
| `--port` | no (5432) | Greenplum port |
| `--dbname` | yes | Database name |
| `--user` | yes | DB username |
| `--password` | yes | DB password |
| `--schemas` | no | Space-separated list of schemas to include; all non-system schemas if omitted |
| `--output` | no | Output file path; prints to stdout if omitted |

Errors (connection failure, unexpected exceptions) are caught, printed to `stderr`, and exit with code `1`.

---

### 2. Connecting to Greenplum (`migrate`)

```python
conn = psycopg2.connect(host=..., port=..., dbname=..., user=..., password=..., connect_timeout=15)
```

Greenplum is PostgreSQL-compatible, so `psycopg2` works without any special driver.
A 15-second connection timeout guards against unreachable hosts.

---

### 3. Introspecting Sequences

Queries `information_schema.sequences` for:

- `sequence_schema`, `sequence_name`
- `start_value`, `minimum_value`, `maximum_value`, `increment`

System schemas (`pg_catalog`, `information_schema`, `gp_toolkit`) are excluded.
If `--schemas` is provided, a dynamic `IN (...)` clause narrows the results.

---

### 4. Introspecting Tables & Columns

Queries `information_schema.tables` joined to `information_schema.columns` for every `BASE TABLE` (views and foreign tables are skipped). Fetched per column:

- Table schema and name
- Column name and ordinal position
- Default expression (`column_default`)
- Nullability (`is_nullable`)
- Data type name (`data_type`)
- `character_maximum_length`, `numeric_precision`, `numeric_scale` — used to reconstruct parameterised types like `VARCHAR(255)` or `NUMBER(18,4)`

---

### 5. Introspecting Primary Keys

Queries `information_schema.table_constraints` joined to `information_schema.key_column_usage`,
filtered to `constraint_type = 'PRIMARY KEY'`.

`string_agg` preserves the correct column order.
Results are stored in a dict keyed by `(schema, table)` for O(1) lookup during model building.

---

### 6. Building the In-Memory Model

Two dataclasses hold the translated schema:

**`ColumnDef`**
```
name       – column name (quoted in DDL)
sf_type    – translated Snowflake type string
nullable   – bool
default    – raw default expression or None
```

**`TableDef`**
```
schema      – schema name
name        – table name
columns     – list[ColumnDef]
pk_columns  – list[str] from pk_map
```

Each column row from step 4 passes through `map_type()` (see section 7) and is appended to the matching `TableDef`. If no `TableDef` exists yet for a `(schema, table)` key, one is created and its `pk_columns` are populated from `pk_map`.

---

### 7. Data Type Translation (`map_type`)

`map_type(pg_type, char_max, num_precision, num_scale)` resolves types in priority order:

1. **Array suffix** (`[]`) → `VARIANT`
2. **NUMERIC / DECIMAL with parameters** → `NUMBER(p,s)` or `NUMBER(p,0)` or `NUMBER(38,9)` if unparameterised
3. **VARCHAR / CHAR with length** → `VARCHAR(n)` / `CHAR(n)`
4. **Timestamp / Time prefix match** → strips any fractional-seconds precision, maps to `TIMESTAMP_NTZ`, `TIMESTAMP_TZ`, or `TIME`
5. **Static lookup table** (`GP_TO_SF_TYPE`) — covers ~40 type aliases
6. **Fallback** → `VARCHAR  /* UNMAPPED: <original_type> */` — safe and visible in the output

Notable translation decisions:

| Greenplum type | Snowflake type | Reason |
|---|---|---|
| `SERIAL` / `BIGSERIAL` | `INTEGER` / `BIGINT` | SF has no serial; sequence wires up the auto-increment separately |
| `JSONB` / `JSON` | `VARIANT` | Snowflake's semi-structured native type |
| `INTERVAL` | `VARCHAR(64)` | No native interval in Snowflake |
| `BYTEA` | `BINARY` | Direct binary equivalent |
| `UUID` | `VARCHAR(36)` | Snowflake has no UUID type |
| `INET` / `CIDR` / `MACADDR` | `VARCHAR(45/17)` | No network types in Snowflake |
| `MONEY` | `NUMBER(19,2)` | Fixed-precision equivalent |
| Arrays (`int[]` etc.) | `VARIANT` | Semi-structured storage |

---

### 8. Rendering Sequence DDL (`render_sequence_ddl`)

For each sequence row, emits:

```sql
CREATE OR REPLACE SEQUENCE "schema"."sequence_name"
    START = 1
    INCREMENT = 1
    MINVALUE = 1
    MAXVALUE = 9223372036854775807
    ORDER;
```

`ORDER` ensures sequential value generation — important for migration consistency.

---

### 9. Rendering Table DDL (`render_table_ddl`)

For each `TableDef`, builds a `CREATE OR REPLACE TABLE` statement:

- Columns are emitted in original ordinal order.
- `NOT NULL` is added when `nullable = False`.
- `DEFAULT` is included verbatim **unless** the expression contains `nextval(` — Greenplum's way of linking a column to a sequence. Those references are stripped because Snowflake sequences are invoked differently (`sequence_name.NEXTVAL`), and re-linking is an explicit post-DDL step.
- `PRIMARY KEY (col1, col2)` is appended as the last entry if pk columns exist.
- `DISTRIBUTED BY` clauses are **not emitted** — Snowflake manages data distribution automatically and has no equivalent syntax.

Example output:

```sql
CREATE OR REPLACE TABLE "public"."orders" (
    "order_id"   INTEGER NOT NULL,
    "customer_id" INTEGER NOT NULL,
    "amount"     NUMBER(18,4),
    "created_at" TIMESTAMP_NTZ,
    PRIMARY KEY ("order_id")
);
```

---

### 10. Output

The rendered DDL parts are joined with newlines into a single string.
A header comment block at the top records the source host/database and notes about dropped Greenplum-specific syntax.

- If `--output` was provided → written to that file path (`UTF-8`).
- Otherwise → printed to stdout.

---

## What Is Intentionally Omitted

| Greenplum feature | Disposition |
|---|---|
| `DISTRIBUTED BY` | Dropped — Snowflake auto-distributes |
| `PARTITION BY` (GP range/list) | Not handled (out of scope) |
| Foreign keys | Not emitted (can be added as a follow-up) |
| Indexes | Not emitted (Snowflake uses search optimization hints instead) |
| `nextval()` column defaults | Stripped — must be re-linked manually after DDL apply |
| Views, materialized views | Skipped — only `BASE TABLE` is queried |
| Triggers / functions | Out of scope |

---

## Dependencies

```
psycopg2-binary   # PostgreSQL / Greenplum adapter
```

Install with:

```bash
pip install psycopg2-binary
```

No other third-party libraries are required.
