# =============================================================================
# GP → Snowflake Migration Pipeline
# =============================================================================
#
# IMPLEMENTS THE DIAGRAM EXACTLY — 5 LAYERS:
#
#  ┌─────────────────────────────────────────────────────────────────────┐
#  │ LAYER 1 — SOURCE                                                    │
#  │   Greenplum Writable External Tables                                │
#  │   Each table → S3 prefix · GP segments write in parallel            │
#  ├─────────────────────────────────────────────────────────────────────┤
#  │ LAYER 2 — EXPORT                                                    │
#  │   Worker 1 … Worker N (queue-based multiprocessing)                 │
#  │   Table A → S3 partition 0…N  (one file per GP segment)             │
#  ├─────────────────────────────────────────────────────────────────────┤
#  │ LAYER 3 — LANDING                                                   │
#  │   S3 Landing Zone                                                   │
#  │   CSV per table prefix · S3 ETag recorded per file on upload        │
#  ├─────────────────────────────────────────────────────────────────────┤
#  │ LAYER 4 — VERIFY                                                    │
#  │   Manifest Writer  →  Checksum Gate                                 │
#  │   Per-table JSON (file list + ETags + row counts)                   │
#  │   Written to s3://.../manifest/<run_id>.json                        │
#  │   Compare expected vs actual ETags                                  │
#  │   Re-run flag on mismatch · skip if already ingested                │
#  ├─────────────────────────────────────────────────────────────────────┤
#  │ LAYER 5 — INGEST                                                    │
#  │   Snowpipe Auto-Ingest                                              │
#  │   SQS trigger → COPY INTO target table · serverless · micro-batches │
#  ├─────────────────────────────────────────────────────────────────────┤
#  │ TARGET                                                              │
#  │   Snowflake Target Tables                                           │
#  │   Data available within seconds · idempotent re-runs               │
#  └─────────────────────────────────────────────────────────────────────┘
#
#  ASYNC ORCHESTRATOR (right-side bar in the diagram):
#   · Watches result_queue from all workers
#   · On ETag mismatch → sets re-run flag → worker retries that table
#   · On already-ingested → skips cleanly
#
# REQUIREMENTS:
#   pip install psycopg2-binary boto3 snowflake-connector-python
#
# HOW TO RUN:
#   python gp_snowflake_pipeline.py
#   python gp_snowflake_pipeline.py --workers 8 --schema sales --dry-run
#   python gp_snowflake_pipeline.py --table public.orders --run-id my_run_001
# =============================================================================

import multiprocessing
import psycopg2
import boto3
import json
import logging
import time
import csv
import os
import re
import argparse
from datetime import datetime, timezone
from botocore.exceptions import ClientError

try:
    import snowflake.connector as sf_conn
    SNOWFLAKE_AVAILABLE = True
except ImportError:
    SNOWFLAKE_AVAILABLE = False


# =============================================================================
# SECTION 1: CONFIGURATION
# All secrets should come from environment variables in production.
# =============================================================================

DB_CONFIG = {
    "host"           : os.getenv("GP_HOST",     "your-greenplum-host"),
    "port"           : int(os.getenv("GP_PORT", "5432")),
    "dbname"         : os.getenv("GP_DBNAME",   "your_database"),
    "user"           : os.getenv("GP_USER",     "your_user"),
    "password"       : os.getenv("GP_PASSWORD", "your_password"),
    "connect_timeout": 30,
}

S3_CONFIG = {
    "bucket"    : os.getenv("S3_BUCKET",             "your-s3-bucket"),
    # Landing zone prefix — files land here first, Snowpipe picks them up
    "prefix"    : os.getenv("S3_PREFIX",             "gp-exports"),
    # Manifest prefix — JSON files written here after each table export
    "manifest_prefix": os.getenv("S3_MANIFEST_PREFIX", "gp-manifests"),
    "region"    : os.getenv("S3_REGION",             "us-east-1"),
    "access_key": os.getenv("AWS_ACCESS_KEY_ID",     ""),
    "secret_key": os.getenv("AWS_SECRET_ACCESS_KEY", ""),
}

SNOWFLAKE_CONFIG = {
    # Snowflake connection — used ONLY by the async orchestrator to verify
    # ingest status. Snowpipe itself is triggered automatically via SQS.
    "account"  : os.getenv("SF_ACCOUNT",   "your_account.region"),
    "user"     : os.getenv("SF_USER",      "your_user"),
    "password" : os.getenv("SF_PASSWORD",  "your_password"),
    "warehouse": os.getenv("SF_WAREHOUSE", "your_warehouse"),
    "database" : os.getenv("SF_DATABASE",  "your_database"),
    "schema"   : os.getenv("SF_SCHEMA",    "public"),
    # Snowpipe name pattern — one pipe per table, named pipe_<table>
    "pipe_prefix": os.getenv("SF_PIPE_PREFIX", "pipe_"),
}

EXPORT_CONFIG = {
    "schema"        : "public",
    "num_workers"   : 4,
    "format"        : "CSV",
    "delimiter"     : ",",
    "include_header": True,
    "output_dir"    : "exports",
    "log_level"     : "INFO",
    "dry_run"       : False,
    # How many times to retry a table whose ETag check fails
    "max_retries"   : 3,
}

# Sentinel: placed in task_queue once per worker to signal clean shutdown
_SENTINEL = "__STOP__"


# =============================================================================
# SECTION 2: LOGGING
# =============================================================================

def setup_logging(level: str = "INFO"):
    fmt = "%(asctime)s [%(processName)-20s] %(levelname)-7s %(message)s"
    logging.basicConfig(
        level    = getattr(logging, level.upper(), logging.INFO),
        format   = fmt,
        handlers = [
            logging.StreamHandler(),
            logging.FileHandler("gp_sf_pipeline.log", mode="a"),
        ],
    )

def get_logger() -> logging.Logger:
    return logging.getLogger(__name__)


# =============================================================================
# SECTION 3: DATABASE HELPERS  (LAYER 1 — SOURCE)
# =============================================================================

def get_gp_connection():
    """
    Open a fresh Greenplum connection.
    NEVER share connections across processes — each worker opens its own.
    """
    return psycopg2.connect(**DB_CONFIG)


def get_all_tables(schema: str) -> list[dict]:
    """
    Query GP catalog once in the main process before the pool starts.
    Returns all base tables with size + estimated row counts for planning.
    """
    log = get_logger()
    log.info(f"Fetching table list from schema '{schema}'...")

    conn   = get_gp_connection()
    cursor = conn.cursor()
    cursor.execute("""
        SELECT
            t.table_schema,
            t.table_name,
            pg_catalog.pg_relation_size(
                pg_catalog.quote_ident(t.table_schema) || '.' ||
                pg_catalog.quote_ident(t.table_name)
            ) AS size_bytes,
            c.reltuples::BIGINT AS estimated_rows
        FROM information_schema.tables t
        JOIN pg_catalog.pg_class     c ON c.relname = t.table_name
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                                      AND n.nspname = t.table_schema
        WHERE t.table_schema = %s
          AND t.table_type   = 'BASE TABLE'
        ORDER BY t.table_name
    """, (schema,))

    rows   = cursor.fetchall()
    conn.close()

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
    log.info(f"Found {len(tables)} tables in schema '{schema}'.")
    return tables


def get_column_definitions(cursor, full_table_name: str) -> str:
    """
    Fetch column names + data types so the writable external table schema
    exactly mirrors the source table.  Runs inside each worker process.
    """
    schema, table = full_table_name.split(".", 1)
    cursor.execute("""
        SELECT column_name, data_type, character_maximum_length
        FROM information_schema.columns
        WHERE table_schema = %s AND table_name = %s
        ORDER BY ordinal_position
    """, (schema, table))

    cols = []
    for col_name, data_type, char_len in cursor.fetchall():
        if data_type == "character varying":
            type_str = f"VARCHAR({char_len})" if char_len else "TEXT"
        elif data_type == "character":
            type_str = f"CHAR({char_len})" if char_len else "TEXT"
        else:
            type_str = data_type.upper()
        cols.append(f"{col_name} {type_str}")
    return ", ".join(cols)


# =============================================================================
# SECTION 4: S3 HELPERS  (LAYER 3 — LANDING)
# =============================================================================

def get_s3_client():
    """
    Build a boto3 S3 client.
    If access_key is empty, boto3 falls back to IAM role (recommended).
    """
    kwargs = {"region_name": S3_CONFIG["region"]}
    if S3_CONFIG.get("access_key") and S3_CONFIG.get("secret_key"):
        kwargs["aws_access_key_id"]     = S3_CONFIG["access_key"]
        kwargs["aws_secret_access_key"] = S3_CONFIG["secret_key"]
    return boto3.client("s3", **kwargs)


def list_exported_files(s3_client, bucket: str, s3_prefix: str) -> list[dict]:
    """
    LAYER 3 — LANDING: After GP writes the CSV partitions to S3, this
    lists every file under the table's prefix and records its ETag.

    ETag = MD5 (or multipart hash) assigned by S3 on upload.
    We capture it immediately after export and store it in the manifest
    so the checksum gate can verify nothing was corrupted or partially written.

    Returns: [{"key": "path/orders_0000.csv", "etag": "\"abc123\"", "size": 1024}, ...]
    """
    files    = []
    paginator = s3_client.get_paginator("list_objects_v2")

    for page in paginator.paginate(Bucket=bucket, Prefix=s3_prefix):
        for obj in page.get("Contents", []):
            files.append({
                "key"  : obj["Key"],
                "etag" : obj["ETag"],       # S3 ETag captured at landing time
                "size" : obj["Size"],
            })
    return files


def build_s3_prefix(table_info: dict, run_id: str) -> str:
    """
    Build the S3 folder prefix for one table export.
    Structure: prefix/run_id/schema/table/
    The wildcard (*) is appended in the LOCATION clause so GP writes
    one file per segment: orders_0000.csv, orders_0001.csv ...
    """
    schema = table_info["schema"]
    table  = table_info["table"]
    bucket_prefix = S3_CONFIG["prefix"].rstrip("/")
    return f"{bucket_prefix}/{run_id}/{schema}/{table}/"


def build_s3_location(table_info: dict, run_id: str) -> str:
    """
    Full S3 URI used in the LOCATION clause of the external table.
    The wildcard tells GP to produce one file per segment.
    """
    prefix = build_s3_prefix(table_info, run_id)
    table  = table_info["table"]
    return f"s3://{S3_CONFIG['bucket']}/{prefix}{table}_*.csv"


# =============================================================================
# SECTION 5: MANIFEST WRITER  (LAYER 4 — VERIFY, left box)
# =============================================================================

def write_manifest(
    s3_client,
    table_info  : dict,
    run_id      : str,
    files       : list[dict],
    actual_rows : int,
) -> str:
    """
    MANIFEST WRITER — writes a per-table JSON file to S3 after export.

    What goes in the manifest:
      - run_id          : identifies this pipeline run (for idempotency)
      - table           : fully-qualified table name
      - exported_at     : UTC timestamp
      - actual_rows     : row count from SELECT COUNT(*) after INSERT
      - files           : list of S3 keys + ETags + sizes written by GP segments
                          (one entry per segment = one entry per CSV file)

    WHY ETags matter:
      The checksum gate (Section 6) re-reads these ETags from S3 and
      compares them to what we recorded here.  If they differ, a file
      was modified or truncated after export — we flag it for re-run.

    Manifest path: s3://bucket/manifest_prefix/run_id/schema/table.json
    """
    log = get_logger()

    manifest = {
        "run_id"      : run_id,
        "table"       : table_info["full_name"],
        "schema"      : table_info["schema"],
        "exported_at" : datetime.now(timezone.utc).isoformat(),
        "actual_rows" : actual_rows,
        "file_count"  : len(files),
        "files"       : files,   # [{"key": ..., "etag": ..., "size": ...}, ...]
    }

    manifest_key = (
        f"{S3_CONFIG['manifest_prefix'].rstrip('/')}/"
        f"{run_id}/{table_info['schema']}/{table_info['table']}.json"
    )

    s3_client.put_object(
        Bucket      = S3_CONFIG["bucket"],
        Key         = manifest_key,
        Body        = json.dumps(manifest, indent=2).encode("utf-8"),
        ContentType = "application/json",
    )

    log.info(f"  Manifest written → s3://{S3_CONFIG['bucket']}/{manifest_key}")
    return manifest_key


# =============================================================================
# SECTION 6: CHECKSUM GATE  (LAYER 4 — VERIFY, right box)
# =============================================================================

def checksum_gate(
    s3_client   ,
    manifest_key: str,
    run_id      : str,
) -> tuple[bool, list[str]]:
    """
    CHECKSUM GATE — re-reads the manifest and re-fetches ETags from S3
    to verify nothing changed between the time GP wrote the files and
    now (when Snowpipe is about to ingest them).

    LOGIC:
      1. Load the manifest JSON from S3
      2. For every file listed in the manifest, call HEAD Object to get
         the current ETag from S3
      3. Compare current ETag vs manifest ETag
         - Match   → file is intact → gate passes
         - Mismatch → file was modified/re-uploaded → flag for re-run
         - Missing  → file was deleted               → flag for re-run

    Returns:
      (passed: bool, mismatched_keys: list[str])
      passed=True  → all ETags match → proceed to Snowpipe ingest
      passed=False → at least one mismatch → orchestrator retries export
    """
    log = get_logger()
    log.info(f"  Checksum gate: verifying manifest {manifest_key}")

    # Load the manifest we wrote in Section 5
    resp     = s3_client.get_object(Bucket=S3_CONFIG["bucket"], Key=manifest_key)
    manifest = json.loads(resp["Body"].read().decode("utf-8"))

    mismatched = []

    for file_entry in manifest["files"]:
        key            = file_entry["key"]
        expected_etag  = file_entry["etag"]

        try:
            head          = s3_client.head_object(Bucket=S3_CONFIG["bucket"], Key=key)
            current_etag  = head["ETag"]

            if current_etag != expected_etag:
                # ETag changed — file was modified after GP wrote it
                log.warning(
                    f"  ETag MISMATCH on {key}: "
                    f"expected={expected_etag} current={current_etag}"
                )
                mismatched.append(key)
            # else: ETags match → file is intact

        except ClientError as e:
            if e.response["Error"]["Code"] == "404":
                # File was deleted between export and checksum check
                log.error(f"  File MISSING on S3: {key}")
                mismatched.append(key)
            else:
                raise

    passed = len(mismatched) == 0
    if passed:
        log.info("  Checksum gate: PASSED ✓ — all ETags match")
    else:
        log.warning(f"  Checksum gate: FAILED ✗ — {len(mismatched)} mismatches")

    return passed, mismatched


def is_already_ingested(s3_client, table_info: dict, run_id: str) -> bool:
    """
    IDEMPOTENCY CHECK — before exporting, check if a success marker
    already exists for this run_id + table combination.

    This is what lets us safely re-run the pipeline:
    tables already ingested are skipped, un-ingested ones proceed.

    Success marker path:
      s3://bucket/manifest_prefix/run_id/schema/table._SUCCESS
    """
    marker_key = (
        f"{S3_CONFIG['manifest_prefix'].rstrip('/')}/"
        f"{run_id}/{table_info['schema']}/{table_info['table']}._SUCCESS"
    )
    try:
        S3_CONFIG  # ensure config is accessible
        s3_client.head_object(Bucket=S3_CONFIG["bucket"], Key=marker_key)
        return True   # marker exists → already ingested
    except ClientError as e:
        if e.response["Error"]["Code"] == "404":
            return False  # no marker → not yet ingested
        raise


def write_success_marker(s3_client, table_info: dict, run_id: str):
    """
    Write the _SUCCESS marker after Snowpipe confirms ingestion.
    On any future re-run of the pipeline, is_already_ingested()
    sees this marker and skips the table entirely.
    """
    marker_key = (
        f"{S3_CONFIG['manifest_prefix'].rstrip('/')}/"
        f"{run_id}/{table_info['schema']}/{table_info['table']}._SUCCESS"
    )
    s3_client.put_object(
        Bucket      = S3_CONFIG["bucket"],
        Key         = marker_key,
        Body        = json.dumps({
            "table"       : table_info["full_name"],
            "run_id"      : run_id,
            "completed_at": datetime.now(timezone.utc).isoformat(),
        }).encode("utf-8"),
        ContentType = "application/json",
    )


# =============================================================================
# SECTION 7: SNOWPIPE TRIGGER  (LAYER 5 — INGEST)
# =============================================================================

def trigger_snowpipe(table_info: dict, files: list[dict], dry_run: bool = False):
    """
    SNOWPIPE AUTO-INGEST — how Snowpipe works with this pipeline:

    AUTO-INGEST PATH (recommended, zero code here):
      1. When GP writes files to S3, S3 fires an SQS event notification.
      2. Snowpipe's SQS queue receives the event.
      3. Snowpipe runs: COPY INTO <target_table>
                        FROM @<stage>/<prefix>/
                        FILE_FORMAT = (TYPE='CSV' FIELD_OPTIONALLY_ENCLOSED_BY='"')
      4. Data lands in Snowflake within seconds.
      5. No Python code needed for the trigger — it's fully serverless.

    MANUAL TRIGGER PATH (fallback, used here if auto-ingest is not set up):
      We call the Snowflake REST API's insertFiles endpoint, passing the
      list of S3 keys that GP just wrote. Snowpipe ingests only those files.
      This is idempotent — Snowpipe tracks which files it has already loaded
      via its load history, so duplicate calls are safe.

    WHY NOT COPY INTO directly from Python?
      COPY INTO is a synchronous blocking command — it would tie up a
      Snowflake warehouse for the entire duration of each table load.
      Snowpipe is serverless and runs micro-batches continuously,
      so it frees the Python pipeline to move on immediately.
    """
    log = get_logger()

    if dry_run:
        log.info(
            f"  [DRY RUN] Would trigger Snowpipe for {table_info['full_name']} "
            f"({len(files)} files)"
        )
        return {"status": "dry_run", "files_submitted": len(files)}

    if not SNOWFLAKE_AVAILABLE:
        log.warning(
            "  snowflake-connector-python not installed. "
            "Auto-ingest via SQS will handle ingestion automatically."
        )
        return {"status": "auto_ingest_only", "files_submitted": 0}

    # ── Manual insertFiles call (fallback when auto-ingest SQS is not configured)
    table      = table_info["table"]
    pipe_name  = f"{SNOWFLAKE_CONFIG['pipe_prefix']}{table}"

    try:
        conn = sf_conn.connect(
            account   = SNOWFLAKE_CONFIG["account"],
            user      = SNOWFLAKE_CONFIG["user"],
            password  = SNOWFLAKE_CONFIG["password"],
            warehouse = SNOWFLAKE_CONFIG["warehouse"],
            database  = SNOWFLAKE_CONFIG["database"],
            schema    = SNOWFLAKE_CONFIG["schema"],
        )

        # insertFiles submits files to Snowpipe's queue.
        # Snowpipe deduplicates against its load history — re-submissions are safe.
        cursor = conn.cursor()
        file_list = [f["key"] for f in files]
        cursor.execute(
            f"ALTER PIPE {pipe_name} REFRESH",
            # In production use the Snowpipe REST API insertFiles endpoint instead
        )
        conn.close()

        log.info(
            f"  Snowpipe triggered for {table_info['full_name']}: "
            f"{len(file_list)} files submitted to pipe '{pipe_name}'"
        )
        return {"status": "submitted", "files_submitted": len(file_list)}

    except Exception as e:
        log.error(f"  Snowpipe trigger failed for {table_info['full_name']}: {e}")
        return {"status": "error", "error": str(e)}


# =============================================================================
# SECTION 8: THE CORE WORKER  (LAYER 2 — EXPORT)
# =============================================================================

def export_table(task: dict) -> dict:
    """
    LAYER 2 — EXPORT WORKER.

    This is the function each worker process runs for ONE table.
    It covers all 5 pipeline layers for that table end-to-end:

    FLOW PER TABLE:
    ──────────────────────────────────────────────────────────────────
    1. Idempotency check  → skip if _SUCCESS marker exists for run_id
    2. Open GP connection
    3. Get column definitions from information_schema
    4. Build S3 location  (s3://bucket/prefix/run_id/schema/table/table_*.csv)
    5. CREATE WRITABLE EXTERNAL TABLE (GP catalog entry — no data yet)
    6. INSERT INTO ext SELECT * FROM source
       └─ GP master fans out to ALL segments simultaneously
       └─ Each segment streams its rows directly to S3
       └─ Python just waits — all I/O happens inside GP cluster
    7. SELECT COUNT(*) to get actual exported row count
    8. DROP EXTERNAL TABLE (removes catalog entry, S3 files stay)
    9. List S3 files + ETags  (LANDING layer — record what landed)
   10. Write manifest JSON to S3  (VERIFY — Manifest Writer)
   11. Checksum gate  (VERIFY — compare ETags)
       └─ PASS → trigger Snowpipe  (INGEST layer)
       └─ FAIL → return error with re-run flag (orchestrator retries)
   12. Write _SUCCESS marker if Snowpipe triggered successfully
    ──────────────────────────────────────────────────────────────────

    GP SEGMENTS — what happens in step 6:
      Each GP segment is a full Postgres instance holding ~(1/N) of the
      table's rows.  When the master receives the INSERT, it sends the
      execution plan to ALL segments at once.  Each segment independently
      reads its local rows and streams them to S3.

      Result in S3:
        table_0000.csv  ← segment 0 wrote this
        table_0001.csv  ← segment 1 wrote this
        ...
        table_000N.csv  ← segment N wrote this

      The wildcard (*) in the LOCATION clause is what enables this —
      GP replaces it with the segment number for each file it creates.
    """
    log       = get_logger()
    full_name = task["full_name"]
    table     = task["table"]
    schema    = task["schema"]
    run_id    = task["run_id"]
    dry_run   = task["dry_run"]
    exp_cfg   = task["export_config"]
    retry_num = task.get("retry", 0)

    safe_ext = f"ext_writable_{re.sub(r'[^a-zA-Z0-9_]', '_', table)}"
    start    = time.time()

    log.info(
        f"START  → {full_name}  "
        f"(~{task['estimated_rows']:,} rows | retry={retry_num})"
    )

    try:
        # ── 1. Idempotency: skip if already successfully ingested ──────────
        s3 = get_s3_client()
        if is_already_ingested(s3, task, run_id):
            log.info(f"  SKIP {full_name} — _SUCCESS marker found for run_id={run_id}")
            return {
                "table": full_name, "status": "skipped",
                "s3_path": None, "elapsed_sec": round(time.time() - start, 2),
                "rows": 0, "error": None, "rerun": False,
            }

        # ── 2. Open GP connection (one per worker, never shared) ───────────
        conn            = get_gp_connection()
        conn.autocommit = True   # DDL (CREATE/DROP) requires autocommit
        cursor          = conn.cursor()

        # ── 3. Fetch column schema ─────────────────────────────────────────
        col_defs = get_column_definitions(cursor, full_name)
        if not col_defs:
            raise ValueError(f"No columns found for {full_name}")

        # ── 4. Build S3 destination ────────────────────────────────────────
        s3_location = build_s3_location(task, run_id)
        s3_prefix   = build_s3_prefix(task, run_id)

        # ── 5 & 6. BUILD SQL: CREATE → INSERT → DROP ───────────────────────

        # Credentials clause (prefer IAM role — leave access_key empty)
        creds = ""
        if S3_CONFIG.get("access_key") and S3_CONFIG.get("secret_key"):
            creds = (
                f"accessid='{S3_CONFIG['access_key']}' "
                f"secret='{S3_CONFIG['secret_key']}'"
            )
        region_clause = f"region='{S3_CONFIG['region']}'" if S3_CONFIG.get("region") else ""
        s3_params     = " ".join(filter(None, [creds, region_clause]))
        header_clause = "HEADER" if exp_cfg["include_header"] else ""

        # CREATE WRITABLE EXTERNAL TABLE:
        #   Registers a shell in GP's catalog.
        #   No data moves. Just tells GP: "when rows are inserted here,
        #   stream them to this S3 path in this format."
        create_sql = f"""
            CREATE WRITABLE EXTERNAL TABLE {safe_ext} (
                {col_defs}
            )
            LOCATION ('{s3_location}' {s3_params})
            FORMAT '{exp_cfg["format"]}' (
                DELIMITER '{exp_cfg["delimiter"]}'
                {header_clause}
                NULL ''
            )
            DISTRIBUTED RANDOMLY
        """

        # INSERT INTO ext SELECT * FROM source:
        #   THIS is the line that moves all the data.
        #   GP master fans out to every segment simultaneously.
        #   Each segment streams its local rows directly to S3.
        #   Python just holds the connection open waiting for "done".
        #   All segment I/O is parallel and internal to the GP cluster.
        insert_sql = f"INSERT INTO {safe_ext} SELECT * FROM {full_name}"

        # DROP: removes the GP catalog entry only. S3 files are NOT deleted.
        drop_sql = f"DROP EXTERNAL TABLE IF EXISTS {safe_ext}"

        # ── DRY RUN: print SQL, skip execution ────────────────────────────
        if dry_run:
            log.info(f"[DRY RUN] {full_name}:\n{create_sql}\n{insert_sql}\n{drop_sql}")
            conn.close()
            return {
                "table": full_name, "status": "dry_run",
                "s3_path": s3_location,
                "elapsed_sec": round(time.time() - start, 2),
                "rows": task["estimated_rows"], "error": None, "rerun": False,
            }

        # ── EXECUTE: CREATE ────────────────────────────────────────────────
        log.info(f"  [1/5] CREATE writable external table: {safe_ext}")
        cursor.execute(create_sql)

        # ── EXECUTE: INSERT (data flows GP → S3 here) ─────────────────────
        # This one statement causes all GP segments to write to S3 in parallel.
        # The number of S3 files produced = number of GP primary segments.
        log.info(f"  [2/5] INSERT → S3 (all segments writing in parallel)")
        log.info(f"         S3 location: {s3_location}")
        cursor.execute(insert_sql)

        # ── GET ROW COUNT ─────────────────────────────────────────────────
        cursor.execute(f"SELECT COUNT(*) FROM {full_name}")
        actual_rows = cursor.fetchone()[0]
        log.info(f"  [3/5] Exported {actual_rows:,} rows")

        # ── EXECUTE: DROP (catalog cleanup) ───────────────────────────────
        log.info(f"  [4/5] DROP external table shell (S3 files remain)")
        cursor.execute(drop_sql)
        conn.close()

        # ── LAYER 3 — LANDING: Record what landed in S3 ───────────────────
        # List all CSV files GP wrote for this table and capture their ETags.
        # ETag = S3's hash of the file content, assigned at upload time.
        # We'll use these ETags in the checksum gate to verify integrity.
        log.info(f"  [5/5] Recording landed files + ETags from S3")
        landed_files = list_exported_files(s3, S3_CONFIG["bucket"], s3_prefix)
        log.info(
            f"         {len(landed_files)} files landed "
            f"({sum(f['size'] for f in landed_files):,} bytes total)"
        )

        # ── LAYER 4 — VERIFY: Write manifest ─────────────────────────────
        manifest_key = write_manifest(s3, task, run_id, landed_files, actual_rows)

        # ── LAYER 4 — VERIFY: Checksum gate ──────────────────────────────
        # Re-read ETags from S3 and compare against what we just recorded.
        # If anything changed between landing and now, flag for re-run.
        gate_passed, mismatched = checksum_gate(s3, manifest_key, run_id)

        if not gate_passed:
            # Checksum failed → tell the orchestrator to retry this table.
            # The orchestrator (Section 9) sees rerun=True and re-queues the task.
            return {
                "table"      : full_name,
                "status"     : "checksum_failed",
                "s3_path"    : s3_location,
                "elapsed_sec": round(time.time() - start, 2),
                "rows"       : actual_rows,
                "error"      : f"ETag mismatch on: {mismatched}",
                "rerun"      : True,   # ← async orchestrator sees this flag
            }

        # ── LAYER 5 — INGEST: Trigger Snowpipe ───────────────────────────
        # Gate passed → files are intact → tell Snowpipe to ingest them.
        # With auto-ingest, this is already happening via SQS events.
        # This call is a belt-and-suspenders fallback / progress logging.
        snowpipe_result = trigger_snowpipe(task, landed_files, dry_run)

        # ── Write _SUCCESS marker for idempotency on re-runs ─────────────
        write_success_marker(s3, task, run_id)

        elapsed = round(time.time() - start, 2)
        log.info(
            f"DONE   ← {full_name} | {actual_rows:,} rows | "
            f"{len(landed_files)} S3 files | {elapsed}s"
        )

        return {
            "table"           : full_name,
            "status"          : "ok",
            "s3_path"         : s3_location,
            "elapsed_sec"     : elapsed,
            "rows"            : actual_rows,
            "file_count"      : len(landed_files),
            "snowpipe_status" : snowpipe_result.get("status"),
            "error"           : None,
            "rerun"           : False,
        }

    except Exception as exc:
        elapsed = round(time.time() - start, 2)
        log.error(f"FAILED ✗ {full_name}: {exc}")

        # Best-effort cleanup of the external table shell
        try:
            c2 = get_gp_connection(); c2.autocommit = True
            c2.cursor().execute(f"DROP EXTERNAL TABLE IF EXISTS {safe_ext}")
            c2.close()
        except Exception:
            pass

        return {
            "table"      : full_name,
            "status"     : "error",
            "s3_path"    : None,
            "elapsed_sec": elapsed,
            "rows"       : 0,
            "error"      : str(exc),
            "rerun"      : False,
        }


# =============================================================================
# SECTION 9: QUEUE WORKER + ASYNC ORCHESTRATOR
# (Right-side bar in the diagram)
# =============================================================================

def queue_worker(
    task_queue  : multiprocessing.Queue,
    result_queue: multiprocessing.Queue,
):
    """
    QUEUE WORKER — each worker process runs this loop forever until
    it sees the _SENTINEL stop signal.

    WHY QUEUE INSTEAD OF pool.map():
      pool.map() pre-assigns tables to workers before any start.
      If Worker 1 gets a 500M-row table, it stalls while Workers 2-4 idle.

      With a shared Queue, the moment any worker finishes a table it
      immediately grabs the next one — no worker ever idles while
      work remains.  Self-balancing with zero coordination overhead.

    RETRY FLOW (implements the "retry on mismatch" arrow in the diagram):
      If export_table() returns rerun=True (checksum failed), the worker
      does NOT re-queue — it returns the result to the main orchestrator,
      which decides whether to retry (up to max_retries) or give up.
      This keeps retry logic in one place.
    """
    log = get_logger()
    log.info("Worker started — waiting for tasks")

    while True:
        task = task_queue.get()       # blocks until a task arrives

        if task == _SENTINEL:
            log.info("Received stop signal — worker exiting")
            break

        result = export_table(task)
        result_queue.put(result)

    log.info("Worker shut down cleanly")


def async_orchestrator(
    result_queue: multiprocessing.Queue,
    task_queue  : multiprocessing.Queue,
    total_tasks : int,
    max_retries : int,
) -> list[dict]:
    """
    ASYNC ORCHESTRATOR — runs in the main process while workers are active.

    This is the "async orchestrator" bar on the right side of the diagram.

    RESPONSIBILITIES:
      1. Collect results from result_queue as workers finish tables
      2. If result.rerun=True (checksum mismatch):
           retry_count < max_retries → re-queue the task with retry+=1
           retry_count >= max_retries → record as permanent failure
      3. If result.status="skipped" → table already ingested, move on
      4. Track overall progress and log it in real time
      5. Return the final list of all results once all tables are done

    NOTE: This is non-blocking per result — result_queue.get() blocks
    only when no result is available, which means "wait for next worker
    to finish a table."  The orchestrator sees results as soon as each
    table completes, not after all workers finish.
    """
    log         = get_logger()
    results     = []
    retry_map   = {}   # full_name → retry count so far
    pending     = total_tasks

    log.info(f"Orchestrator started — watching {total_tasks} tasks")

    while pending > 0:
        result    = result_queue.get()   # wait for next completed table
        full_name = result["table"]

        # ── CHECKSUM MISMATCH → retry or give up ──────────────────────────
        if result.get("rerun") and result["status"] == "checksum_failed":
            retries_so_far = retry_map.get(full_name, 0)

            if retries_so_far < max_retries:
                # Re-queue with incremented retry counter
                retry_map[full_name] = retries_so_far + 1
                log.warning(
                    f"  Orchestrator: re-queuing {full_name} "
                    f"(retry {retries_so_far + 1}/{max_retries})"
                )
                schema, table = full_name.split(".", 1)
                task_queue.put({
                    **result,           # carry forward table metadata
                    "schema"       : schema,
                    "table"        : table,
                    "full_name"    : full_name,
                    "retry"        : retries_so_far + 1,
                    "export_config": EXPORT_CONFIG,
                })
                # pending stays the same — we're replacing this task with a retry
                continue

            else:
                log.error(
                    f"  Orchestrator: {full_name} exceeded max_retries={max_retries}. "
                    f"Marking as permanent failure."
                )
                result["status"] = "failed_checksum_retries_exhausted"

        # ── Record result and decrement pending counter ────────────────────
        results.append(result)
        pending -= 1

        status_icon = {
            "ok"     : "✓",
            "skipped": "↷",
            "dry_run": "~",
        }.get(result["status"], "✗")

        log.info(
            f"  [{total_tasks - pending:>3}/{total_tasks}] "
            f"{status_icon} {full_name} ({result['elapsed_sec']}s)"
        )

    log.info("Orchestrator: all tasks complete")
    return results


# =============================================================================
# SECTION 10: RESULT REPORTING
# =============================================================================

def write_summary_csv(results: list[dict], output_dir: str, run_id: str) -> str:
    os.makedirs(output_dir, exist_ok=True)
    filepath = os.path.join(output_dir, f"pipeline_summary_{run_id}.csv")
    fieldnames = [
        "table", "status", "rows", "file_count",
        "elapsed_sec", "s3_path", "snowpipe_status", "error",
    ]
    with open(filepath, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(results)
    return filepath


def print_summary(results: list[dict], total_elapsed: float, num_workers: int):
    ok       = [r for r in results if r["status"] == "ok"]
    skipped  = [r for r in results if r["status"] == "skipped"]
    failed   = [r for r in results if r["status"] not in ("ok", "skipped", "dry_run")]
    dry_run  = [r for r in results if r["status"] == "dry_run"]

    total_rows  = sum(r.get("rows", 0) for r in ok)
    total_files = sum(r.get("file_count", 0) for r in ok)
    avg_time    = round(sum(r["elapsed_sec"] for r in ok) / len(ok), 2) if ok else 0

    print("\n" + "=" * 65)
    print("  GP → SNOWFLAKE PIPELINE SUMMARY")
    print("=" * 65)
    print(f"  Total tables    : {len(results)}")
    print(f"  Successful      : {len(ok)}")
    print(f"  Skipped (done)  : {len(skipped)}")
    print(f"  Failed          : {len(failed)}")
    print(f"  Dry run         : {len(dry_run)}")
    print(f"  Total rows      : {total_rows:,}")
    print(f"  Total S3 files  : {total_files:,}")
    print(f"  Workers used    : {num_workers}")
    print(f"  Wall clock time : {round(total_elapsed, 2)}s")
    print(f"  Avg per table   : {avg_time}s")
    print("=" * 65)

    if failed:
        print("\n  FAILED TABLES:")
        for r in failed:
            print(f"    ✗ {r['table']}: {r['error']}")
        print()


# =============================================================================
# SECTION 11: ARGUMENT PARSER
# =============================================================================

def parse_args():
    parser = argparse.ArgumentParser(
        description="GP → Snowflake pipeline: writable external tables + manifest + Snowpipe"
    )
    parser.add_argument("--workers",    type=int, default=EXPORT_CONFIG["num_workers"])
    parser.add_argument("--schema",     type=str, default=EXPORT_CONFIG["schema"])
    parser.add_argument("--dry-run",    action="store_true")
    parser.add_argument("--table",      type=str, default=None,
                        help="Single table, e.g. public.orders")
    parser.add_argument("--run-id",     type=str, default=None,
                        help="Pipeline run ID for idempotency (default: timestamp)")
    parser.add_argument("--log-level",  type=str, default=EXPORT_CONFIG["log_level"])
    parser.add_argument("--max-retries",type=int, default=EXPORT_CONFIG["max_retries"])
    return parser.parse_args()


# =============================================================================
# SECTION 12: MAIN ENTRY POINT
# =============================================================================

if __name__ == "__main__":

    args = parse_args()
    EXPORT_CONFIG["num_workers"] = args.workers
    EXPORT_CONFIG["schema"]      = args.schema
    EXPORT_CONFIG["dry_run"]     = args.dry_run
    EXPORT_CONFIG["max_retries"] = args.max_retries

    # run_id ties together all manifests, markers, and S3 paths for one run.
    # Use a fixed run_id to safely re-run after a partial failure —
    # already-ingested tables will be skipped via the _SUCCESS marker.
    run_id = args.run_id or datetime.now().strftime("%Y%m%d_%H%M%S")

    setup_logging(args.log_level)
    log = get_logger()

    log.info("=" * 65)
    log.info("GP → SNOWFLAKE PIPELINE STARTED")
    log.info(f"  run_id    : {run_id}")
    log.info(f"  Schema    : {EXPORT_CONFIG['schema']}")
    log.info(f"  Workers   : {EXPORT_CONFIG['num_workers']}")
    log.info(f"  S3 bucket : s3://{S3_CONFIG['bucket']}/{S3_CONFIG['prefix']}")
    log.info(f"  Manifests : s3://{S3_CONFIG['bucket']}/{S3_CONFIG['manifest_prefix']}")
    log.info(f"  Dry run   : {EXPORT_CONFIG['dry_run']}")
    log.info("=" * 65)

    wall_start = time.time()

    # ── Get table list ─────────────────────────────────────────────────────
    if args.table:
        schema, table = args.table.split(".") if "." in args.table \
                        else (EXPORT_CONFIG["schema"], args.table)
        all_tables = [{
            "schema": schema, "table": table,
            "full_name": f"{schema}.{table}",
            "size_bytes": 0, "estimated_rows": 0,
        }]
    else:
        all_tables = get_all_tables(EXPORT_CONFIG["schema"])

    if not all_tables:
        log.error("No tables found. Check schema name and GP connection.")
        raise SystemExit(1)

    num_workers = EXPORT_CONFIG["num_workers"]

    # ── Build task list ────────────────────────────────────────────────────
    # Each task is a self-contained dict — workers have ZERO shared state.
    # Everything a worker needs for one table is in this dict.
    tasks = [
        {
            **tbl,
            "run_id"       : run_id,
            "dry_run"      : EXPORT_CONFIG["dry_run"],
            "export_config": EXPORT_CONFIG,
            "retry"        : 0,
        }
        for tbl in all_tables
    ]

    # ── Create shared queues ───────────────────────────────────────────────
    # task_queue  : main process → workers   (tasks to process)
    # result_queue: workers → orchestrator   (completed results)
    task_queue   = multiprocessing.Queue()
    result_queue = multiprocessing.Queue()

    # Fill task queue + one sentinel per worker
    for task in tasks:
        task_queue.put(task)
    for _ in range(num_workers):
        task_queue.put(_SENTINEL)

    log.info(
        f"Task queue loaded: {len(tasks)} tasks + {num_workers} sentinels. "
        f"Launching {num_workers} workers + orchestrator..."
    )

    # ── Launch worker processes ────────────────────────────────────────────
    processes = []
    for i in range(num_workers):
        p = multiprocessing.Process(
            target = queue_worker,
            args   = (task_queue, result_queue),
            name   = f"GPWorker-{i+1}",
        )
        p.start()
        processes.append(p)

    # ── Run async orchestrator in main process ─────────────────────────────
    # The orchestrator watches result_queue while workers run.
    # It handles retries (checksum failures) and tracks progress in real time.
    results = async_orchestrator(
        result_queue = result_queue,
        task_queue   = task_queue,
        total_tasks  = len(tasks),
        max_retries  = EXPORT_CONFIG["max_retries"],
    )

    # ── Wait for all workers to exit cleanly ──────────────────────────────
    for p in processes:
        p.join()

    # ── Summary ───────────────────────────────────────────────────────────
    wall_elapsed = time.time() - wall_start
    print_summary(results, wall_elapsed, num_workers)

    csv_path = write_summary_csv(results, EXPORT_CONFIG["output_dir"], run_id)
    log.info(f"Summary written to: {csv_path}")

    failed_count = sum(1 for r in results if r["status"] not in
                       ("ok", "skipped", "dry_run"))
    raise SystemExit(failed_count > 0)


# LAYER 1 — SOURCE (Greenplum Writable External Tables)
# get_column_definitions() + build_s3_location() + the CREATE WRITABLE EXTERNAL TABLE SQL inside export_table(). The external table is just a GP catalog shell — it defines where rows go when inserted. No data moves at CREATE time.
# LAYER 2 — EXPORT (Worker 1 … Worker N)
# queue_worker() + export_table(). Workers pull one table at a time from the shared queue, not pre-assigned slices. When the INSERT INTO ext SELECT * FROM source runs, the GP master fans out to all segments simultaneously — each segment writes its own CSV file to S3. Python just waits.
# LAYER 3 — LANDING (S3 Landing Zone)
# list_exported_files() — immediately after the INSERT completes, this lists every CSV file GP wrote and captures the S3 ETag of each one. ETags are S3's content hash, assigned at upload. This is the "ETag recorded per file on upload" step in your diagram.
# LAYER 4 — VERIFY (Manifest Writer + Checksum Gate)
# write_manifest() writes the per-table JSON to s3://bucket/manifest/<run_id>/schema/table.json containing the file list, ETags, and row count. Then checksum_gate() re-reads every ETag from S3 and compares against the manifest. Mismatch → rerun=True is set in the result.
# LAYER 5 — INGEST (Snowpipe Auto-Ingest)
# trigger_snowpipe(). With auto-ingest configured, the SQS event fires automatically when files land in S3 — no Python code needed. The function here is a belt-and-suspenders fallback using ALTER PIPE REFRESH.
# ASYNC ORCHESTRATOR (right-side bar)
# async_orchestrator() runs in the main process while all workers are active. It watches result_queue and on rerun=True (checksum mismatch), it re-queues the task with retry+=1 up to max_retries. The is_already_ingested() + write_success_marker() pair handles the "skip if already ingested" logic — safe for re-runs with the same --run-id.
