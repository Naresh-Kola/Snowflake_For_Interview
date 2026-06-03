"""
Greenplum → Snowflake DDL Migration Script
Connects to Greenplum, introspects tables & sequences,
and emits compatible Snowflake DDL (no data movement).
"""

import psycopg2
import argparse
import sys
from dataclasses import dataclass, field
from typing import Optional

# ─────────────────────────────────────────────
# DATA-TYPE MAPPING  (Greenplum → Snowflake)
# ─────────────────────────────────────────────
GP_TO_SF_TYPE: dict[str, str] = {
    # Integers
    "smallint":           "SMALLINT",
    "int2":               "SMALLINT",
    "integer":            "INTEGER",
    "int":                "INTEGER",
    "int4":               "INTEGER",
    "bigint":             "BIGINT",
    "int8":               "BIGINT",

    # Serials (auto-increment in GP) → plain INT in SF; sequences handled separately
    "smallserial":        "SMALLINT",
    "serial2":            "SMALLINT",
    "serial":             "INTEGER",
    "serial4":            "INTEGER",
    "bigserial":          "BIGINT",
    "serial8":            "BIGINT",

    # Floating point
    "real":               "FLOAT4",
    "float4":             "FLOAT4",
    "double precision":   "FLOAT8",
    "float8":             "FLOAT8",
    "float":              "FLOAT",

    # Exact numeric
    "numeric":            "NUMBER",
    "decimal":            "NUMBER",

    # Boolean
    "boolean":            "BOOLEAN",
    "bool":               "BOOLEAN",

    # Character
    "character":          "CHAR",
    "char":               "CHAR",
    "character varying":  "VARCHAR",
    "varchar":            "VARCHAR",
    "text":               "TEXT",
    "name":               "VARCHAR(128)",

    # Date / Time
    "date":               "DATE",
    "time":               "TIME",
    "time without time zone":       "TIME",
    "time with time zone":          "TIME",
    "timestamp":                    "TIMESTAMP_NTZ",
    "timestamp without time zone":  "TIMESTAMP_NTZ",
    "timestamp with time zone":     "TIMESTAMP_TZ",
    "timestamptz":                  "TIMESTAMP_TZ",
    "interval":           "VARCHAR(64)",   # Snowflake has no INTERVAL; store as string

    # Binary
    "bytea":              "BINARY",

    # JSON
    "json":               "VARIANT",
    "jsonb":              "VARIANT",

    # UUID
    "uuid":               "VARCHAR(36)",

    # Network / misc (not native in SF → VARCHAR)
    "inet":               "VARCHAR(45)",
    "cidr":               "VARCHAR(45)",
    "macaddr":            "VARCHAR(17)",
    "bit":                "BOOLEAN",
    "bit varying":        "VARCHAR",
    "varbit":             "VARCHAR",

    # Array → VARIANT (semi-structured)
    "array":              "VARIANT",

    # XML
    "xml":                "VARCHAR",

    # Money
    "money":              "NUMBER(19,2)",
}


def map_type(pg_type: str, char_max: Optional[int], num_precision: Optional[int],
             num_scale: Optional[int]) -> str:
    """Translate a Greenplum column type to a Snowflake type string."""
    base = pg_type.lower().strip()

    # Strip array suffix; treat as VARIANT
    if base.endswith("[]"):
        return "VARIANT"

    # Parameterised NUMERIC / DECIMAL
    if base in ("numeric", "decimal"):
        if num_precision:
            if num_scale:
                return f"NUMBER({num_precision},{num_scale})"
            return f"NUMBER({num_precision},0)"
        return "NUMBER(38,9)"   # Snowflake default precision

    # VARCHAR / CHAR with length
    if base in ("character varying", "varchar"):
        return f"VARCHAR({char_max})" if char_max else "VARCHAR"
    if base in ("character", "char"):
        return f"CHAR({char_max})" if char_max else "CHAR(1)"

    # TIME / TIMESTAMP with precision (strip it; SF handles precision differently)
    for prefix in ("timestamp without time zone", "timestamp with time zone",
                   "timestamp", "timestamptz",
                   "time without time zone", "time with time zone", "time"):
        if base.startswith(prefix):
            return GP_TO_SF_TYPE.get(prefix, "TIMESTAMP_NTZ")

    return GP_TO_SF_TYPE.get(base, f"VARCHAR  /* UNMAPPED: {pg_type} */")


# ─────────────────────────────────────────────
# QUERIES
# ─────────────────────────────────────────────

COLUMNS_QUERY = """
SELECT
    t.table_schema,
    t.table_name,
    c.column_name,
    c.ordinal_position,
    c.column_default,
    c.is_nullable,
    c.data_type,
    c.character_maximum_length,
    c.numeric_precision,
    c.numeric_scale
FROM information_schema.tables  t
JOIN information_schema.columns c
     ON c.table_schema = t.table_schema AND c.table_name = t.table_name
WHERE t.table_type = 'BASE TABLE'
  AND t.table_schema NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')
ORDER BY t.table_schema, t.table_name, c.ordinal_position;
"""

PK_QUERY = """
SELECT
    tc.table_schema,
    tc.table_name,
    string_agg(kcu.column_name, ', ' ORDER BY kcu.ordinal_position) AS pk_columns
FROM information_schema.table_constraints  tc
JOIN information_schema.key_column_usage   kcu
     ON kcu.constraint_name = tc.constraint_name
     AND kcu.table_schema   = tc.table_schema
WHERE tc.constraint_type = 'PRIMARY KEY'
  AND tc.table_schema NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')
GROUP BY tc.table_schema, tc.table_name;
"""

SEQUENCES_QUERY = """
SELECT
    sequence_schema,
    sequence_name,
    start_value,
    minimum_value,
    maximum_value,
    increment
FROM information_schema.sequences
WHERE sequence_schema NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')
ORDER BY sequence_schema, sequence_name;
"""


# ─────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────

@dataclass
class ColumnDef:
    name: str
    sf_type: str
    nullable: bool
    default: Optional[str]


@dataclass
class TableDef:
    schema: str
    name: str
    columns: list[ColumnDef] = field(default_factory=list)
    pk_columns: list[str] = field(default_factory=list)


def qualify(schema: str, name: str) -> str:
    return f'"{schema}"."{name}"'


def render_sequence_ddl(row: tuple) -> str:
    seq_schema, seq_name, start, minv, maxv, increment = row
    lines = [
        f'CREATE OR REPLACE SEQUENCE {qualify(seq_schema, seq_name)}',
        f'    START = {start}',
        f'    INCREMENT = {increment}',
        f'    MINVALUE = {minv}',
        f'    MAXVALUE = {maxv}',
        f'    ORDER;',
    ]
    return "\n".join(lines)


def render_table_ddl(table: TableDef) -> str:
    col_lines = []
    for col in table.columns:
        null_clause = "" if col.nullable else " NOT NULL"
        default_clause = ""
        if col.default:
            # Strip nextval() refs – sequence linkage is done explicitly in SF
            if "nextval" not in col.default.lower():
                default_clause = f" DEFAULT {col.default}"
        col_lines.append(f'    "{col.name}" {col.sf_type}{null_clause}{default_clause}')

    if table.pk_columns:
        pk_str = ", ".join(f'"{c}"' for c in table.pk_columns)
        col_lines.append(f"    PRIMARY KEY ({pk_str})")

    body = ",\n".join(col_lines)
    return (
        f"CREATE OR REPLACE TABLE {qualify(table.schema, table.name)} (\n"
        f"{body}\n"
        f");"
    )


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────

def migrate(host: str, port: int, dbname: str, user: str, password: str,
            schemas: Optional[list[str]], output_file: Optional[str]) -> None:

    print(f"[+] Connecting to Greenplum at {host}:{port}/{dbname} …")
    conn = psycopg2.connect(
        host=host, port=port, dbname=dbname,
        user=user, password=password,
        connect_timeout=15,
    )
    cur = conn.cursor()

    # ── Sequences ──────────────────────────────
    print("[+] Introspecting sequences …")
    seq_query = SEQUENCES_QUERY
    if schemas:
        placeholders = ",".join(["%s"] * len(schemas))
        seq_query += f" AND sequence_schema IN ({placeholders})"
        cur.execute(seq_query, schemas)
    else:
        cur.execute(seq_query)
    sequence_rows = cur.fetchall()
    print(f"    Found {len(sequence_rows)} sequence(s).")

    # ── Columns ────────────────────────────────
    print("[+] Introspecting tables & columns …")
    col_query = COLUMNS_QUERY
    if schemas:
        placeholders = ",".join(["%s"] * len(schemas))
        col_query = col_query.replace(
            "AND t.table_schema NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')",
            f"AND t.table_schema IN ({placeholders})"
        )
        cur.execute(col_query, schemas)
    else:
        cur.execute(col_query)
    column_rows = cur.fetchall()

    # ── Primary Keys ───────────────────────────
    pk_query = PK_QUERY
    if schemas:
        placeholders = ",".join(["%s"] * len(schemas))
        pk_query = pk_query.replace(
            "AND tc.table_schema NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')",
            f"AND tc.table_schema IN ({placeholders})"
        )
        cur.execute(pk_query, schemas)
    else:
        cur.execute(pk_query)
    pk_map: dict[tuple, list[str]] = {}
    for pk_schema, pk_table, pk_cols in cur.fetchall():
        pk_map[(pk_schema, pk_table)] = [c.strip() for c in pk_cols.split(",")]

    cur.close()
    conn.close()

    # ── Build TableDef objects ─────────────────
    tables: dict[tuple, TableDef] = {}
    for row in column_rows:
        (tschema, tname, cname, _pos, cdefault, is_nullable,
         dtype, char_max, num_prec, num_scale) = row

        key = (tschema, tname)
        if key not in tables:
            tables[key] = TableDef(
                schema=tschema,
                name=tname,
                pk_columns=pk_map.get(key, []),
            )

        sf_type = map_type(dtype, char_max, num_prec, num_scale)
        tables[key].columns.append(ColumnDef(
            name=cname,
            sf_type=sf_type,
            nullable=(is_nullable.upper() == "YES"),
            default=cdefault,
        ))

    print(f"    Found {len(tables)} table(s).")

    # ── Render DDL ─────────────────────────────
    ddl_parts: list[str] = []

    ddl_parts.append("-- ============================================================")
    ddl_parts.append("-- Snowflake DDL generated from Greenplum")
    ddl_parts.append(f"-- Source : {host}:{port}/{dbname}")
    ddl_parts.append("-- NOTE   : DISTRIBUTED BY clauses are omitted (not applicable)")
    ddl_parts.append("--          Sequences kept as Snowflake SEQUENCE objects.")
    ddl_parts.append("-- ============================================================\n")

    if sequence_rows:
        ddl_parts.append("-- ────────────────────────────────────────")
        ddl_parts.append("-- SEQUENCES")
        ddl_parts.append("-- ────────────────────────────────────────\n")
        for seq_row in sequence_rows:
            ddl_parts.append(render_sequence_ddl(seq_row))
            ddl_parts.append("")

    if tables:
        ddl_parts.append("-- ────────────────────────────────────────")
        ddl_parts.append("-- TABLES")
        ddl_parts.append("-- ────────────────────────────────────────\n")
        for table in tables.values():
            ddl_parts.append(render_table_ddl(table))
            ddl_parts.append("")

    ddl_output = "\n".join(ddl_parts)

    if output_file:
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(ddl_output)
        print(f"[✓] DDL written to: {output_file}")
    else:
        print("\n" + "=" * 60)
        print(ddl_output)


# ─────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract Greenplum DDL and emit Snowflake-compatible DDL."
    )
    parser.add_argument("--host",     required=True,  help="Greenplum host")
    parser.add_argument("--port",     default=5432,   type=int, help="Greenplum port (default 5432)")
    parser.add_argument("--dbname",   required=True,  help="Greenplum database name")
    parser.add_argument("--user",     required=True,  help="Greenplum username")
    parser.add_argument("--password", required=True,  help="Greenplum password")
    parser.add_argument(
        "--schemas",
        nargs="+",
        default=None,
        metavar="SCHEMA",
        help="One or more schemas to migrate (default: all non-system schemas)",
    )
    parser.add_argument(
        "--output",
        default=None,
        metavar="FILE",
        help="Write DDL to this file instead of stdout",
    )

    args = parser.parse_args()

    try:
        migrate(
            host=args.host,
            port=args.port,
            dbname=args.dbname,
            user=args.user,
            password=args.password,
            schemas=args.schemas,
            output_file=args.output,
        )
    except psycopg2.OperationalError as e:
        print(f"[ERROR] Cannot connect to Greenplum: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[ERROR] {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()