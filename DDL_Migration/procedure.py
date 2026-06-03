"""
Greenplum → Snowflake Procedure Migration Script
Connects to Greenplum, extracts stored procedures, translates
PL/pgSQL bodies to Snowflake Scripting, and emits Snowflake DDL.

Snowflake Scripting is Snowflake's native PL/pgSQL-like language
and is the closest compatible target for Greenplum procedures.
"""

import psycopg2
import argparse
import re
import sys
from dataclasses import dataclass, field
from typing import Optional

# ─────────────────────────────────────────────
# DATA-TYPE MAPPING  (reused from DDL script)
# ─────────────────────────────────────────────
GP_TO_SF_TYPE: dict[str, str] = {
    "smallint": "SMALLINT",       "int2": "SMALLINT",
    "integer": "INTEGER",         "int": "INTEGER",
    "int4": "INTEGER",            "bigint": "BIGINT",
    "int8": "BIGINT",             "real": "FLOAT4",
    "float4": "FLOAT4",           "double precision": "FLOAT8",
    "float8": "FLOAT8",           "float": "FLOAT",
    "numeric": "NUMBER",          "decimal": "NUMBER",
    "boolean": "BOOLEAN",         "bool": "BOOLEAN",
    "character varying": "VARCHAR", "varchar": "VARCHAR",
    "character": "CHAR",          "char": "CHAR",
    "text": "VARCHAR",            "name": "VARCHAR(128)",
    "date": "DATE",               "time": "TIME",
    "time without time zone": "TIME",
    "time with time zone": "TIME",
    "timestamp": "TIMESTAMP_NTZ",
    "timestamp without time zone": "TIMESTAMP_NTZ",
    "timestamp with time zone": "TIMESTAMP_TZ",
    "timestamptz": "TIMESTAMP_TZ",
    "interval": "VARCHAR(64)",
    "bytea": "BINARY",
    "json": "VARIANT",            "jsonb": "VARIANT",
    "uuid": "VARCHAR(36)",
    "inet": "VARCHAR(45)",        "cidr": "VARCHAR(45)",
    "macaddr": "VARCHAR(17)",
    "bit": "BOOLEAN",             "bit varying": "VARCHAR",
    "xml": "VARCHAR",             "money": "NUMBER(19,2)",
    "void": "void",               "record": "VARIANT",
    "trigger": "VARIANT",         "refcursor": "VARCHAR",
    "anyelement": "VARIANT",      "anyarray": "VARIANT",
}


def map_type(pg_type: str) -> str:
    """Translate a Greenplum type string to Snowflake equivalent."""
    base = pg_type.lower().strip()
    if base.endswith("[]"):
        return "VARIANT"
    # Parameterised numeric
    m = re.match(r"(numeric|decimal)\((\d+)(?:,(\d+))?\)", base)
    if m:
        p, s = m.group(2), m.group(3)
        return f"NUMBER({p},{s})" if s else f"NUMBER({p},0)"
    # Parameterised varchar / char
    m = re.match(r"(character varying|varchar)\((\d+)\)", base)
    if m:
        return f"VARCHAR({m.group(2)})"
    m = re.match(r"(character|char)\((\d+)\)", base)
    if m:
        return f"CHAR({m.group(2)})"
    # Timestamp / time prefix
    for prefix in ("timestamp without time zone", "timestamp with time zone",
                   "timestamp", "timestamptz",
                   "time without time zone", "time with time zone", "time"):
        if base.startswith(prefix):
            return GP_TO_SF_TYPE.get(prefix, "TIMESTAMP_NTZ")
    return GP_TO_SF_TYPE.get(base, f"VARCHAR  /* UNMAPPED: {pg_type} */")


# ─────────────────────────────────────────────
# QUERIES
# ─────────────────────────────────────────────

PROCEDURES_QUERY = """
SELECT
    n.nspname                                        AS proc_schema,
    p.proname                                        AS proc_name,
    pg_get_function_identity_arguments(p.oid)        AS identity_args,
    pg_get_function_arguments(p.oid)                 AS full_args,
    pg_get_function_result(p.oid)                    AS return_type,
    l.lanname                                        AS language,
    p.prosrc                                         AS body,
    p.provolatile                                    AS volatility,
    p.proisstrict                                    AS is_strict,
    obj_description(p.oid, 'pg_proc')               AS description
FROM pg_proc        p
JOIN pg_namespace   n ON n.oid = p.pronamespace
JOIN pg_language    l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')
  AND p.prokind = 'p'   -- procedures only (Greenplum 6+/7)
ORDER BY n.nspname, p.proname;
"""

# Fallback for older Greenplum versions that lack prokind
PROCEDURES_QUERY_LEGACY = """
SELECT
    n.nspname                                        AS proc_schema,
    p.proname                                        AS proc_name,
    pg_get_function_identity_arguments(p.oid)        AS identity_args,
    pg_get_function_arguments(p.oid)                 AS full_args,
    pg_get_function_result(p.oid)                    AS return_type,
    l.lanname                                        AS language,
    p.prosrc                                         AS body,
    p.provolatile                                    AS volatility,
    p.proisstrict                                    AS is_strict,
    obj_description(p.oid, 'pg_proc')               AS description
FROM pg_proc        p
JOIN pg_namespace   n ON n.oid = p.pronamespace
JOIN pg_language    l ON l.oid = p.prolang
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')
  AND l.lanname IN ('plpgsql', 'sql', 'plpython3u', 'plpythonu')
  AND p.prorettype = (SELECT oid FROM pg_type WHERE typname = 'void')
ORDER BY n.nspname, p.proname;
"""


# ─────────────────────────────────────────────
# MODELS
# ─────────────────────────────────────────────

@dataclass
class ProcArg:
    name: str
    pg_type: str
    mode: str        # IN / OUT / INOUT
    sf_type: str = ""

    def __post_init__(self):
        self.sf_type = map_type(self.pg_type)


@dataclass
class ProcDef:
    schema: str
    name: str
    args: list[ProcArg]
    return_type: str
    language: str
    body: str
    volatility: str        # i=immutable, s=stable, v=volatile
    is_strict: bool
    description: Optional[str]
    warnings: list[str] = field(default_factory=list)


# ─────────────────────────────────────────────
# ARGUMENT PARSER
# ─────────────────────────────────────────────

def parse_args_string(full_args: str) -> list[ProcArg]:
    """
    Parse Greenplum's pg_get_function_arguments() output into ProcArg list.
    Examples:
      'p_id integer, p_name text'
      'IN p_id integer, OUT p_result text'
      '' (no args)
    """
    if not full_args or not full_args.strip():
        return []

    args: list[ProcArg] = []
    # Split on commas that are not inside parentheses (for types like numeric(10,2))
    parts = re.split(r",\s*(?![^(]*\))", full_args)
    for i, part in enumerate(parts):
        part = part.strip()
        tokens = part.split()
        mode = "IN"
        if tokens and tokens[0].upper() in ("IN", "OUT", "INOUT", "VARIADIC"):
            mode = tokens[0].upper()
            tokens = tokens[1:]

        # tokens: [name, type...] or just [type...] for unnamed args
        if len(tokens) >= 2:
            arg_name = tokens[0]
            arg_type = " ".join(tokens[1:])
        elif len(tokens) == 1:
            arg_name = f"p_arg{i + 1}"
            arg_type = tokens[0]
        else:
            continue

        args.append(ProcArg(name=arg_name, pg_type=arg_type, mode=mode))

    return args


# ─────────────────────────────────────────────
# PL/pgSQL → Snowflake Scripting TRANSLATOR
# ─────────────────────────────────────────────

# Patterns that have direct Snowflake Scripting equivalents
_SYNTAX_RULES: list[tuple[str, str]] = [
    # RAISE NOTICE / INFO / WARNING → Snowflake doesn't support; wrap in comment
    (r"\bRAISE\s+(?:NOTICE|INFO|LOG|DEBUG)\b", "-- RAISE NOTICE"),
    # RAISE EXCEPTION → RAISE (SF Scripting uses RAISE without level)
    (r"\bRAISE\s+EXCEPTION\b", "RAISE"),
    # PERFORM → plain call (strip PERFORM keyword)
    (r"\bPERFORM\b", "CALL"),
    # RETURNING INTO  stays as-is in SF scripting
    # %TYPE / %ROWTYPE  → VARIANT (no catalog type refs in SF)
    (r"\b\w+\s*%TYPE\b", "VARIANT  /* %TYPE: manual review */"),
    (r"\b\w+\s*%ROWTYPE\b", "VARIANT  /* %ROWTYPE: manual review */"),
    # EXECUTE (dynamic SQL) → stays as EXECUTE in SF Scripting
    # FOUND → SF uses ROW_COUNT() > 0  (flag only)
    (r"\bFOUND\b", "/* FOUND → use (ROW_COUNT() > 0) */ FOUND"),
    # RETURN NEXT / RETURN QUERY → not directly supported; flag
    (r"\bRETURN\s+NEXT\b", "/* RETURN NEXT: refactor to result set */ RETURN"),
    (r"\bRETURN\s+QUERY\b", "/* RETURN QUERY: refactor to result set */ RETURN"),
    # RECORD type → VARIANT
    (r"\bRECORD\b", "VARIANT  /* RECORD: manual review */"),
    # SETOF → flag
    (r"\bSETOF\b", "/* SETOF: refactor to TABLE return */ VARIANT"),
    # IS DISTINCT FROM → Snowflake uses IS DISTINCT FROM (same syntax, keep)
    # ILIKE → supported in SF, keep
    # ::cast syntax → CAST() in SF (flag for attention)
    (r"(\w+)::(\w+)", r"CAST(\1 AS \2)  /* cast */"),
    # pg array functions → flag
    (r"\bARRAY_AGG\b", "ARRAY_AGG  /* verify SF compatibility */"),
    (r"\bUNNEST\b", "/* UNNEST: use FLATTEN() in SF */ UNNEST"),
    # NOW() → CURRENT_TIMESTAMP in SF
    (r"\bNOW\(\)", "CURRENT_TIMESTAMP"),
    # CLOCK_TIMESTAMP → CURRENT_TIMESTAMP
    (r"\bCLOCK_TIMESTAMP\(\)", "CURRENT_TIMESTAMP"),
    # COALESCE, NULLIF — same in SF, no change needed
    # STRING_AGG → LISTAGG in SF
    (r"\bSTRING_AGG\b", "LISTAGG  /* was STRING_AGG */"),
    # SUBSTR stays, SUBSTRING stays
    # RETURNING clause in INSERT/UPDATE/DELETE → not supported in SF Scripting; flag
    (r"\bRETURNING\b", "/* RETURNING not supported in SF Scripting */"),
    # TEMP / TEMPORARY tables → SF uses CREATE TEMPORARY TABLE
    (r"\bCREATE\s+TEMP\s+TABLE\b", "CREATE TEMPORARY TABLE"),
    # FOR loop over query: FOR rec IN SELECT ... stays the same in SF Scripting
    # EXCEPTION block → stays (SF Scripting supports EXCEPTION)
    # COMMIT / ROLLBACK inside procedure → supported in SF stored procs
]

_COMPILED_RULES = [(re.compile(pat, re.IGNORECASE), repl)
                   for pat, repl in _SYNTAX_RULES]


def translate_body(body: str, proc: "ProcDef") -> tuple[str, list[str]]:
    """
    Translate a PL/pgSQL procedure body to Snowflake Scripting syntax.
    Returns (translated_body, warnings).
    """
    warnings: list[str] = []
    translated = body

    # ── Language-level checks ──────────────────
    if proc.language not in ("plpgsql", "sql"):
        warnings.append(
            f"Language '{proc.language}' cannot be auto-translated. "
            "Body preserved as-is; manual rewrite required."
        )
        return body, warnings

    # ── Apply syntax rules ─────────────────────
    for pattern, replacement in _COMPILED_RULES:
        translated = pattern.sub(replacement, translated)

    # ── GP-specific checks (flag in warnings) ──
    if re.search(r"\bGP_\w+\b", translated, re.IGNORECASE):
        warnings.append("References to gp_* catalog objects detected — remove or replace.")
    if re.search(r"\bpg_catalog\b", translated, re.IGNORECASE):
        warnings.append("References to pg_catalog detected — not available in Snowflake.")
    if re.search(r"DISTRIBUTED\s+BY", translated, re.IGNORECASE):
        warnings.append("DISTRIBUTED BY inside body — remove, not applicable in Snowflake.")
    if re.search(r"\bCURSOR\b", translated, re.IGNORECASE):
        warnings.append("CURSOR usage detected — review; Snowflake Scripting supports cursors with different syntax.")
    if re.search(r"\bCOPY\b", translated, re.IGNORECASE):
        warnings.append("COPY statement detected — use Snowflake COPY INTO syntax instead.")
    if re.search(r"\bSERIAL\b", translated, re.IGNORECASE):
        warnings.append("SERIAL type inside body — replace with AUTOINCREMENT or a SEQUENCE.")

    return translated, warnings


# ─────────────────────────────────────────────
# DDL RENDERERS
# ─────────────────────────────────────────────

def render_procedure_ddl(proc: ProcDef) -> str:
    """Render a Snowflake Scripting CREATE OR REPLACE PROCEDURE statement."""

    lines: list[str] = []

    # ── Header comment ─────────────────────────
    lines.append(f"-- Procedure: \"{proc.schema}\".\"{proc.name}\"")
    if proc.description:
        lines.append(f"-- Description: {proc.description}")
    if proc.warnings:
        lines.append("-- ⚠ Migration warnings:")
        for w in proc.warnings:
            lines.append(f"--   • {w}")
    lines.append("")

    # ── Signature ──────────────────────────────
    in_args = [a for a in proc.args if a.mode in ("IN", "INOUT")]
    out_args = [a for a in proc.args if a.mode in ("OUT", "INOUT")]

    sig_parts = [f"{a.name} {a.sf_type}" for a in in_args]
    sig = ", ".join(sig_parts)

    # Snowflake procedure return type
    if out_args:
        if len(out_args) == 1:
            ret = out_args[0].sf_type
        else:
            # Multiple OUT params → TABLE
            table_cols = ", ".join(f"{a.name} {a.sf_type}" for a in out_args)
            ret = f"TABLE({table_cols})"
    else:
        sf_ret = map_type(proc.return_type) if proc.return_type else "VARIANT"
        ret = "VARIANT" if sf_ret in ("void", "") else sf_ret

    lines.append(f'CREATE OR REPLACE PROCEDURE "{proc.schema}"."{proc.name}"({sig})')
    lines.append(f"RETURNS {ret}")
    lines.append("LANGUAGE SQL")
    lines.append("EXECUTE AS CALLER")
    lines.append("AS")
    lines.append("$$")

    # ── Body ───────────────────────────────────
    translated_body, body_warnings = translate_body(proc.body, proc)
    proc.warnings.extend(body_warnings)

    # Indent body for readability
    for body_line in translated_body.splitlines():
        lines.append(body_line)

    lines.append("$$;")

    return "\n".join(lines)


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

    # ── Detect Greenplum version to choose query ───
    cur.execute("SELECT version();")
    version_str = cur.fetchone()[0]
    use_legacy = "Greenplum Database 5" in version_str or "Greenplum Database 4" in version_str
    print(f"    Detected: {version_str.splitlines()[0]}")

    query = PROCEDURES_QUERY_LEGACY if use_legacy else PROCEDURES_QUERY
    if schemas:
        placeholders = ",".join(["%s"] * len(schemas))
        query = query.replace(
            "AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'gp_toolkit')",
            f"AND n.nspname IN ({placeholders})"
        )
        cur.execute(query, schemas)
    else:
        cur.execute(query)

    rows = cur.fetchall()
    cur.close()
    conn.close()
    print(f"    Found {len(rows)} procedure(s).")

    # ── Build ProcDef objects ──────────────────
    procs: list[ProcDef] = []
    for row in rows:
        (pschema, pname, _identity_args, full_args, return_type,
         language, body, volatility, is_strict, description) = row

        args = parse_args_string(full_args or "")
        procs.append(ProcDef(
            schema=pschema,
            name=pname,
            args=args,
            return_type=return_type or "void",
            language=language,
            body=body or "",
            volatility=volatility,
            is_strict=bool(is_strict),
            description=description,
        ))

    # ── Render DDL ─────────────────────────────
    ddl_parts: list[str] = []

    ddl_parts.append("-- ============================================================")
    ddl_parts.append("-- Snowflake Procedure DDL generated from Greenplum")
    ddl_parts.append(f"-- Source  : {host}:{port}/{dbname}")
    ddl_parts.append("-- Language: Snowflake Scripting (SQL)")
    ddl_parts.append("-- NOTE    : Review all ⚠ warnings before executing.")
    ddl_parts.append("--           Bodies auto-translated; manual QA recommended.")
    ddl_parts.append("-- ============================================================\n")

    warning_summary: list[str] = []

    for proc in procs:
        ddl = render_procedure_ddl(proc)
        ddl_parts.append(ddl)
        ddl_parts.append("")
        if proc.warnings:
            warning_summary.append(
                f'  "{proc.schema}"."{proc.name}": {len(proc.warnings)} warning(s)'
            )

    if warning_summary:
        ddl_parts.append("-- ============================================================")
        ddl_parts.append("-- WARNING SUMMARY")
        ddl_parts.append("-- ============================================================")
        for w in warning_summary:
            ddl_parts.append(f"-- {w}")

    ddl_output = "\n".join(ddl_parts)

    if output_file:
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(ddl_output)
        print(f"[✓] Procedure DDL written to: {output_file}")
        if warning_summary:
            print(f"[⚠] {len(warning_summary)} procedure(s) have migration warnings — review the output file.")
    else:
        print("\n" + "=" * 60)
        print(ddl_output)


# ─────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract Greenplum stored procedures and emit Snowflake Scripting DDL."
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
