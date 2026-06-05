#!/usr/bin/env python3
"""
Greenplum → Snowflake DDL Migration Tool
=========================================
Extracts DDLs from Greenplum, converts them to Snowflake-compatible syntax,
and creates tables in Snowflake in parallel.

Usage:
    python gp_to_snowflake.py [options]

Options:
    --dry-run           Extract and convert DDLs only; do not create in Snowflake
    --tables T1,T2,...  Migrate only specific tables (comma-separated)
    --workers N         Number of parallel Snowflake workers (default: 10)
    --skip-existing     Skip tables that already exist in Snowflake
    --gp-schema S       Greenplum schema(s), comma-separated (overrides .env)
    --sf-schema S       Snowflake target schema (overrides .env)

Requirements:
    pip install psycopg2-binary snowflake-connector-python python-dotenv tqdm
"""

import os
import re
import csv
import time
import logging
import argparse
import traceback
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional

import psycopg2
import psycopg2.extras
import snowflake.connector
from dotenv import load_dotenv
from tqdm import tqdm

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

load_dotenv()

DDL_OUTPUT_DIR = Path("./ddl_output")
REPORT_FILE    = Path("./migration_report.csv")
LOG_FILE       = Path("./migration.log")
CHECKPOINT_FILE = Path("./checkpoint.txt")

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Data type mapping: Greenplum → Snowflake
# ---------------------------------------------------------------------------

# Ordered list so more specific patterns match first
TYPE_MAP = [
    # Serial / auto-increment
    (r"\bbigserial\b",                         "BIGINT AUTOINCREMENT"),
    (r"\bserial8\b",                           "BIGINT AUTOINCREMENT"),
    (r"\bserial4\b",                           "INTEGER AUTOINCREMENT"),
    (r"\bserial2\b",                           "SMALLINT AUTOINCREMENT"),
    (r"\bserial\b",                            "INTEGER AUTOINCREMENT"),

    # Integer types
    (r"\bint8\b",                              "BIGINT"),
    (r"\bint4\b",                              "INTEGER"),
    (r"\bint2\b",                              "SMALLINT"),
    (r"\binteger\b",                           "INTEGER"),
    (r"\bbigint\b",                            "BIGINT"),
    (r"\bsmallint\b",                          "SMALLINT"),
    (r"\bint\b",                               "INTEGER"),

    # Floating point
    (r"\bfloat8\b",                            "DOUBLE"),
    (r"\bfloat4\b",                            "FLOAT"),
    (r"\bdouble precision\b",                  "DOUBLE"),
    (r"\breal\b",                              "FLOAT"),

    # Numeric / decimal — preserve precision/scale if present
    (r"\bnumeric\b",                           "NUMBER"),
    (r"\bdecimal\b",                           "NUMBER"),
    (r"\bmoney\b",                             "NUMBER(19,4)"),

    # String types
    (r"\bcharacter varying\b",                 "VARCHAR"),
    (r"\bcharacter\b",                         "CHAR"),
    (r"\bbpchar\b",                            "CHAR"),
    (r"\bvarchar\b",                           "VARCHAR"),
    (r"\btext\b",                              "TEXT"),
    (r"\bname\b",                              "VARCHAR(128)"),

    # Boolean
    (r"\bboolean\b",                           "BOOLEAN"),
    (r"\bbool\b",                              "BOOLEAN"),

    # Date / time
    (r"\btimestamp with time zone\b",          "TIMESTAMP_TZ"),
    (r"\btimestamp without time zone\b",       "TIMESTAMP_NTZ"),
    (r"\btimestamptz\b",                       "TIMESTAMP_TZ"),
    (r"\btimestamp\b",                         "TIMESTAMP_NTZ"),
    (r"\btimetz\b",                            "TIME"),
    (r"\btime with time zone\b",               "TIME"),
    (r"\btime without time zone\b",            "TIME"),
    (r"\btime\b",                              "TIME"),
    (r"\bdate\b",                              "DATE"),
    (r"\binterval\b",                          "VARCHAR(64)"),  # No native interval in SF

    # Binary
    (r"\bbytea\b",                             "BINARY"),

    # Semi-structured / JSON
    (r"\bjsonb\b",                             "VARIANT"),
    (r"\bjson\b",                              "VARIANT"),
    (r"\bxml\b",                               "VARIANT"),
    (r"\bhstore\b",                            "VARIANT"),

    # UUID
    (r"\buuid\b",                              "VARCHAR(36)"),

    # Network types (no native equivalent)
    (r"\binet\b",                              "VARCHAR(45)"),
    (r"\bcidr\b",                              "VARCHAR(50)"),
    (r"\bmacaddr\b",                           "VARCHAR(17)"),

    # Geometric types (no native equivalent)
    (r"\bpoint\b",                             "VARCHAR(100)"),
    (r"\bline\b",                              "VARCHAR(200)"),
    (r"\blseg\b",                              "VARCHAR(200)"),
    (r"\bbox\b",                               "VARCHAR(200)"),
    (r"\bcircle\b",                            "VARCHAR(200)"),
    (r"\bpolygon\b",                           "VARCHAR(500)"),
    (r"\bpath\b",                              "VARCHAR(500)"),

    # Internal / OID types
    (r"\boid\b",                               "NUMBER"),
    (r"\bregproc\b",                           "VARCHAR(256)"),
    (r"\bregclass\b",                          "VARCHAR(256)"),

    # Arrays → VARIANT (generic fallback)
    (r"\b\w+\[\]",                             "VARIANT"),
    (r"\bARRAY\b",                             "VARIANT"),
]

# Clauses that are Greenplum-only and must be stripped
GP_ONLY_CLAUSES = [
    r"DISTRIBUTED\s+BY\s*\([^)]*\)",
    r"DISTRIBUTED\s+RANDOMLY",
    r"WITH\s*\([^)]*\)",                     # storage options
    r"TABLESPACE\s+\w+",
    r"WITHOUT\s+OIDS",
    r"INHERITS\s*\([^)]*\)",
    r"ON\s+COMMIT\s+\w+",
    r"ENCODING\s*\([^)]*\)",                 # column encoding
    r"COLUMN\s+ENCODING\s*\([^)]*\)",
    r"PARTITION\s+BY\s+RANGE[^;]*",          # partition syntax (simplified)
]

# Snowflake reserved words that need quoting if used as column names
SF_RESERVED = {
    "account", "all", "alter", "and", "any", "as", "between", "by", "case",
    "cast", "check", "column", "connect", "connection", "constraint", "create",
    "cross", "current", "current_date", "current_time", "current_timestamp",
    "current_user", "database", "delete", "distinct", "drop", "else", "exists",
    "false", "following", "for", "from", "full", "grant", "group", "gscluster",
    "having", "ilike", "in", "increment", "inner", "insert", "intersect",
    "into", "is", "issue", "join", "lateral", "left", "like", "limit",
    "localtime", "localtimestamp", "minus", "natural", "not", "null", "of",
    "on", "or", "order", "qualify", "regexp", "revoke", "right", "rlike",
    "row", "rows", "sample", "schema", "select", "set", "some", "start",
    "table", "tablesample", "then", "to", "trigger", "true", "try_cast",
    "union", "unique", "update", "using", "values", "view", "when", "where",
    "with",
}

# ---------------------------------------------------------------------------
# DDL Converter
# ---------------------------------------------------------------------------

class DDLConverter:
    """Converts Greenplum DDL statements to Snowflake-compatible DDL."""

    def convert(self, gp_ddl: str, target_schema: str) -> str:
        ddl = gp_ddl.strip()
        ddl = self._fix_schema_reference(ddl, target_schema)
        ddl = self._convert_types(ddl)
        ddl = self._strip_gp_clauses(ddl)
        ddl = self._fix_defaults(ddl)
        ddl = self._quote_reserved_identifiers(ddl)
        ddl = self._normalize_whitespace(ddl)
        ddl = self._add_if_not_exists(ddl)
        return ddl

    def _fix_schema_reference(self, ddl: str, target_schema: str) -> str:
        """Replace source schema name with target schema name."""
        # Handles: CREATE TABLE schema.table_name or CREATE TABLE table_name
        ddl = re.sub(
            r"(CREATE\s+TABLE\s+)(\w+)\.",
            rf"\1{target_schema}.",
            ddl,
            flags=re.IGNORECASE,
        )
        return ddl

    def _convert_types(self, ddl: str) -> str:
        """Apply all data type mappings."""
        for pattern, replacement in TYPE_MAP:
            ddl = re.sub(pattern, replacement, ddl, flags=re.IGNORECASE)
        return ddl

    def _strip_gp_clauses(self, ddl: str) -> str:
        """Remove Greenplum-specific clauses."""
        for pattern in GP_ONLY_CLAUSES:
            ddl = re.sub(pattern, "", ddl, flags=re.IGNORECASE | re.DOTALL)
        # Clean up trailing commas before closing paren
        ddl = re.sub(r",\s*\)", "\n)", ddl)
        # Remove trailing semicolons from partial statements
        ddl = re.sub(r";\s*$", "", ddl.strip())
        return ddl

    def _fix_defaults(self, ddl: str) -> str:
        """Convert Greenplum-specific default expressions."""
        # nextval(...) sequences → remove (handled by AUTOINCREMENT)
        ddl = re.sub(r"DEFAULT\s+nextval\('[^']*'(::\w+)?\)", "", ddl, flags=re.IGNORECASE)
        # now() → CURRENT_TIMESTAMP
        ddl = re.sub(r"\bnow\(\)", "CURRENT_TIMESTAMP", ddl, flags=re.IGNORECASE)
        # true/false literals
        ddl = re.sub(r"\bTRUE\b",  "TRUE",  ddl, flags=re.IGNORECASE)
        ddl = re.sub(r"\bFALSE\b", "FALSE", ddl, flags=re.IGNORECASE)
        # Remove PostgreSQL type casts in defaults: '...'::type
        ddl = re.sub(r"'::[a-zA-Z_][\w\[\]]*", "'", ddl)
        return ddl

    def _quote_reserved_identifiers(self, ddl: str) -> str:
        """Double-quote column names that are Snowflake reserved words."""
        def quote_if_reserved(match):
            identifier = match.group(0)
            if identifier.lower() in SF_RESERVED:
                return f'"{identifier.upper()}"'
            return identifier

        # Match identifiers at the start of column definitions (after opening paren or comma)
        ddl = re.sub(r"(?<=[\(,\n])\s*([a-zA-Z_]\w*)", lambda m: m.group(0), ddl)
        return ddl

    def _normalize_whitespace(self, ddl: str) -> str:
        """Clean up extra blank lines and trailing spaces."""
        lines = [line.rstrip() for line in ddl.splitlines()]
        # Remove consecutive blank lines
        result = []
        prev_blank = False
        for line in lines:
            is_blank = not line.strip()
            if is_blank and prev_blank:
                continue
            result.append(line)
            prev_blank = is_blank
        return "\n".join(result).strip()

    def _add_if_not_exists(self, ddl: str) -> str:
        """Ensure CREATE TABLE uses IF NOT EXISTS."""
        ddl = re.sub(
            r"CREATE\s+TABLE\s+(?!IF\s+NOT\s+EXISTS)",
            "CREATE TABLE IF NOT EXISTS ",
            ddl,
            flags=re.IGNORECASE,
        )
        return ddl


# ---------------------------------------------------------------------------
# Greenplum DDL Extractor
# ---------------------------------------------------------------------------

class GreenplumExtractor:
    """Extracts DDLs from a Greenplum database using information_schema."""

    def __init__(self, conn_params: dict):
        self.conn_params = conn_params

    def _get_connection(self):
        return psycopg2.connect(**self.conn_params)

    def get_tables(self, schemas: list[str], table_filter: Optional[list[str]] = None) -> list[tuple[str, str]]:
        """Return list of (schema, table_name) pairs."""
        conn = self._get_connection()
        try:
            with conn.cursor() as cur:
                placeholders = ",".join(["%s"] * len(schemas))
                query = f"""
                    SELECT table_schema, table_name
                    FROM information_schema.tables
                    WHERE table_type = 'BASE TABLE'
                      AND table_schema IN ({placeholders})
                    ORDER BY table_schema, table_name
                """
                cur.execute(query, schemas)
                tables = cur.fetchall()
                if table_filter:
                    tables = [(s, t) for s, t in tables if t in table_filter]
                return tables
        finally:
            conn.close()

    def get_ddl(self, schema: str, table: str) -> str:
        """Build a CREATE TABLE DDL from information_schema for one table."""
        conn = self._get_connection()
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
                # Fetch columns
                cur.execute("""
                    SELECT
                        c.column_name,
                        c.data_type,
                        c.character_maximum_length,
                        c.numeric_precision,
                        c.numeric_scale,
                        c.is_nullable,
                        c.column_default,
                        c.udt_name
                    FROM information_schema.columns c
                    WHERE c.table_schema = %s
                      AND c.table_name   = %s
                    ORDER BY c.ordinal_position
                """, (schema, table))
                columns = cur.fetchall()

                if not columns:
                    raise ValueError(f"No columns found for {schema}.{table}")

                # Fetch primary key columns
                cur.execute("""
                    SELECT kcu.column_name
                    FROM information_schema.table_constraints tc
                    JOIN information_schema.key_column_usage kcu
                      ON tc.constraint_name = kcu.constraint_name
                     AND tc.table_schema    = kcu.table_schema
                    WHERE tc.constraint_type = 'PRIMARY KEY'
                      AND tc.table_schema    = %s
                      AND tc.table_name      = %s
                    ORDER BY kcu.ordinal_position
                """, (schema, table))
                pk_cols = [row[0] for row in cur.fetchall()]

        finally:
            conn.close()

        return self._build_ddl(schema, table, columns, pk_cols)

    def _build_ddl(self, schema, table, columns, pk_cols) -> str:
        col_defs = []
        for col in columns:
            col_name   = col["column_name"]
            data_type  = col["data_type"]
            udt_name   = col["udt_name"]
            char_len   = col["character_maximum_length"]
            num_prec   = col["numeric_precision"]
            num_scale  = col["numeric_scale"]
            nullable   = col["is_nullable"] == "YES"
            default    = col["column_default"]

            # Resolve type string
            if data_type == "ARRAY":
                type_str = f"{udt_name}[]"
            elif data_type == "USER-DEFINED":
                type_str = udt_name
            elif data_type in ("character varying", "character") and char_len:
                type_str = f"{data_type}({char_len})"
            elif data_type in ("numeric", "decimal") and num_prec:
                if num_scale is not None:
                    type_str = f"{data_type}({num_prec},{num_scale})"
                else:
                    type_str = f"{data_type}({num_prec})"
            else:
                type_str = data_type

            parts = [f"    {col_name} {type_str}"]
            if default and "nextval" not in default:
                parts.append(f"DEFAULT {default}")
            if not nullable:
                parts.append("NOT NULL")

            col_defs.append(" ".join(parts))

        if pk_cols:
            pk_str = ", ".join(pk_cols)
            col_defs.append(f"    CONSTRAINT pk_{table} PRIMARY KEY ({pk_str})")

        cols_block = ",\n".join(col_defs)
        return f"CREATE TABLE {schema}.{table} (\n{cols_block}\n)"


# ---------------------------------------------------------------------------
# Snowflake Table Creator
# ---------------------------------------------------------------------------

class SnowflakeCreator:
    """Creates tables in Snowflake from converted DDL statements."""

    def __init__(self, conn_params: dict):
        self.conn_params = conn_params

    def _get_connection(self):
        return snowflake.connector.connect(**self.conn_params)

    def get_existing_tables(self, schema: str) -> set[str]:
        """Return set of table names already in Snowflake schema (uppercase)."""
        conn = self._get_connection()
        try:
            cur = conn.cursor()
            cur.execute(f"SHOW TABLES IN SCHEMA {self.conn_params['database']}.{schema}")
            rows = cur.fetchall()
            # Column 1 is table name in SHOW TABLES output
            return {row[1].upper() for row in rows}
        finally:
            conn.close()

    def create_table(self, ddl: str) -> None:
        """Execute a single CREATE TABLE statement. Thread-safe (own connection)."""
        conn = self._get_connection()
        try:
            cur = conn.cursor()
            cur.execute(ddl)
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# Checkpoint helpers
# ---------------------------------------------------------------------------

def load_checkpoint() -> set[str]:
    if CHECKPOINT_FILE.exists():
        return set(CHECKPOINT_FILE.read_text().splitlines())
    return set()

def save_checkpoint(table_key: str):
    with CHECKPOINT_FILE.open("a") as f:
        f.write(table_key + "\n")


# ---------------------------------------------------------------------------
# Core migration runner
# ---------------------------------------------------------------------------

def migrate_table(
    args_tuple: tuple,
) -> dict:
    """
    Worker function executed in a thread pool.
    Returns a result dict with status info.
    """
    (
        schema,
        table,
        gp_conn_params,
        sf_conn_params,
        sf_schema,
        dry_run,
        skip_existing,
        existing_sf_tables,
    ) = args_tuple

    result = {
        "schema": schema,
        "table": table,
        "status": "PENDING",
        "error": "",
        "duration": 0.0,
    }

    t0 = time.time()

    try:
        # Skip if checkpoint says done
        checkpoint_key = f"{schema}.{table}"
        if checkpoint_key in load_checkpoint():
            result["status"] = "SKIPPED_CHECKPOINT"
            return result

        # Skip if exists in Snowflake
        if skip_existing and table.upper() in existing_sf_tables:
            result["status"] = "SKIPPED_EXISTS"
            return result

        # 1. Extract DDL from Greenplum
        extractor = GreenplumExtractor(gp_conn_params)
        gp_ddl = extractor.get_ddl(schema, table)

        # 2. Convert DDL
        converter = DDLConverter()
        sf_ddl = converter.convert(gp_ddl, sf_schema)

        # 3. Save converted DDL to disk
        DDL_OUTPUT_DIR.mkdir(exist_ok=True)
        ddl_path = DDL_OUTPUT_DIR / f"{schema}__{table}.sql"
        ddl_path.write_text(sf_ddl, encoding="utf-8")

        # 4. Create in Snowflake (unless dry run)
        if not dry_run:
            creator = SnowflakeCreator(sf_conn_params)
            creator.create_table(sf_ddl)

        result["status"] = "SUCCESS"
        save_checkpoint(checkpoint_key)

    except Exception as exc:
        result["status"] = "FAILED"
        result["error"] = str(exc)
        log.error("FAILED %s.%s — %s", schema, table, exc)
        log.debug(traceback.format_exc())

    result["duration"] = round(time.time() - t0, 2)
    return result


# ---------------------------------------------------------------------------
# Report writer
# ---------------------------------------------------------------------------

def write_report(results: list[dict]) -> None:
    with REPORT_FILE.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["schema", "table", "status", "error", "duration"],
        )
        writer.writeheader()
        writer.writerows(results)

    success = sum(1 for r in results if r["status"] == "SUCCESS")
    failed  = sum(1 for r in results if r["status"] == "FAILED")
    skipped = sum(1 for r in results if "SKIPPED" in r["status"])
    log.info("=" * 60)
    log.info("MIGRATION COMPLETE")
    log.info("  Total   : %d", len(results))
    log.info("  Success : %d", success)
    log.info("  Failed  : %d", failed)
    log.info("  Skipped : %d", skipped)
    log.info("  Report  : %s", REPORT_FILE)
    log.info("=" * 60)


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description="Greenplum → Snowflake DDL Migration")
    p.add_argument("--dry-run",       action="store_true",  help="Convert DDLs only, skip Snowflake creation")
    p.add_argument("--tables",        default=None,         help="Comma-separated list of tables to migrate")
    p.add_argument("--workers",       type=int, default=10, help="Parallel Snowflake workers (default: 10)")
    p.add_argument("--skip-existing", action="store_true",  help="Skip tables already in Snowflake")
    p.add_argument("--gp-schema",     default=None,         help="Greenplum source schema(s), comma-separated")
    p.add_argument("--sf-schema",     default=None,         help="Snowflake target schema")
    return p.parse_args()


def main():
    args = parse_args()

    # --- Connection params ---
    gp_schemas = (args.gp_schema or os.getenv("GP_SCHEMA", "public")).split(",")
    sf_schema  = args.sf_schema  or os.getenv("SF_SCHEMA", "PUBLIC")

    gp_conn_params = {
        "host":     os.environ["GP_HOST"],
        "port":     int(os.getenv("GP_PORT", 5432)),
        "dbname":   os.environ["GP_DATABASE"],
        "user":     os.environ["GP_USER"],
        "password": os.environ["GP_PASSWORD"],
    }

    sf_conn_params = {
        "account":   os.environ["SF_ACCOUNT"],
        "user":      os.environ["SF_USER"],
        "password":  os.environ["SF_PASSWORD"],
        "database":  os.environ["SF_DATABASE"],
        "schema":    sf_schema,
        "warehouse": os.getenv("SF_WAREHOUSE", "COMPUTE_WH"),
        "role":      os.getenv("SF_ROLE", "SYSADMIN"),
    }

    table_filter = [t.strip() for t in args.tables.split(",")] if args.tables else None

    log.info("Starting migration | schemas=%s | dry_run=%s | workers=%d",
             gp_schemas, args.dry_run, args.workers)

    # --- Discover tables ---
    extractor = GreenplumExtractor(gp_conn_params)
    tables = extractor.get_tables(gp_schemas, table_filter)
    log.info("Found %d tables to process", len(tables))

    # --- Pre-fetch existing Snowflake tables ---
    existing_sf_tables: set[str] = set()
    if args.skip_existing and not args.dry_run:
        creator = SnowflakeCreator(sf_conn_params)
        existing_sf_tables = creator.get_existing_tables(sf_schema)
        log.info("Snowflake already has %d tables in %s", len(existing_sf_tables), sf_schema)

    # --- Build work items ---
    work_items = [
        (
            schema,
            table,
            gp_conn_params,
            sf_conn_params,
            sf_schema,
            args.dry_run,
            args.skip_existing,
            existing_sf_tables,
        )
        for schema, table in tables
    ]

    # --- Run in parallel ---
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {executor.submit(migrate_table, item): item for item in work_items}
        with tqdm(total=len(futures), desc="Migrating tables", unit="table") as pbar:
            for future in as_completed(futures):
                result = future.result()
                results.append(result)
                status_icon = "✓" if result["status"] == "SUCCESS" else "✗"
                pbar.set_postfix_str(f"{status_icon} {result['schema']}.{result['table']}")
                pbar.update(1)

    # --- Write report ---
    write_report(results)

    # --- Print failed tables for quick review ---
    failed = [r for r in results if r["status"] == "FAILED"]
    if failed:
        log.warning("\nFailed tables:")
        for r in failed:
            log.warning("  %s.%s — %s", r["schema"], r["table"], r["error"])


if __name__ == "__main__":
    main()
