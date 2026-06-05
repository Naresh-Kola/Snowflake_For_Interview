# GP → Snowflake Migration Pipeline: Complete Deep Dive

> **Architecture keywords:** Writable External Tables · Multiprocessing · Manifest/Checksum · Snowpipe Auto-Ingest · asyncio · Row-count reconciliation · Retry-on-mismatch

---

## Table of Contents

1. [Big Picture Overview](#1-big-picture-overview)
2. [Stage 1 — Source: Greenplum Writable External S3 Tables](#2-stage-1--source-greenplum-writable-external-s3-tables)
3. [Stage 2 — Export: Multiprocessing Workers](#3-stage-2--export-multiprocessing-workers)
4. [Stage 3 — Landing: S3 Landing Zone](#4-stage-3--landing-s3-landing-zone)
5. [Stage 4 — Verify: Manifest Writer](#5-stage-4--verify-manifest-writer)
6. [Stage 5 — Verify: Checksum Gate](#6-stage-5--verify-checksum-gate)
7. [Stage 6 — Ingest: Snowpipe Auto-Ingest](#7-stage-6--ingest-snowpipe-auto-ingest)
8. [Stage 7 — Target: Snowflake Tables](#8-stage-7--target-snowflake-tables)
9. [Stage 8 — Reconciliation: Row-Count Verification + Retry (MISSING LOGIC ADDED)](#9-stage-8--reconciliation-row-count-verification--retry-missing-logic-added)
10. [Async Orchestrator: The Control Plane](#10-async-orchestrator-the-control-plane)
11. [End-to-End Data Flow with Sample State](#11-end-to-end-data-flow-with-sample-state)
12. [Complete Implementation Reference](#12-complete-implementation-reference)
13. [Failure Scenarios & Mitigations](#13-failure-scenarios--mitigations)

---

## 1. Big Picture Overview

```
Greenplum (Source)
      │
      │  INSERT INTO ext_table SELECT ...  (parallel segments write directly to S3)
      ▼
S3 Landing Zone  (Parquet / CSV per table prefix)
      │
      │  Manifest Writer records: file list + ETags + row counts
      ▼
Checksum Gate  (expected ETags == actual S3 ETags?)
      │                        │
   PASS ✓                  FAIL ✗ ──► retry export (up to 2x)
      │
      ▼
Snowpipe Auto-Ingest  (SQS trigger → COPY INTO)
      │
      ▼
Snowflake Target Tables
      │
      │  Row-count reconciliation: GP count == SF count?
      ▼
   MATCH ✓   ──► pipeline done
   MISMATCH ✗ ──► retry full pipeline (up to 2x)   ← THIS WAS MISSING
```

The pipeline has **two independent retry loops**:

| Loop | Triggers on | Max retries |
|------|------------|-------------|
| Checksum Gate retry | S3 ETag mismatch (corrupt upload) | 2 |
| Reconciliation retry | GP row count ≠ SF row count | 2 |

---

## 2. Stage 1 — Source: Greenplum Writable External S3 Tables

### What happens

Greenplum's **Writable External Table** feature lets each segment process write directly to S3 without any intermediate staging file on the database host. You define the external table once; data flows straight from the segment to the S3 prefix during a regular `INSERT INTO`.

### Setup DDL

```sql
-- One external table per source table
CREATE WRITABLE EXTERNAL TABLE ext_orders_s3 (
    order_id        BIGINT,
    customer_id     INT,
    order_date      DATE,
    amount          NUMERIC(12,2),
    status          VARCHAR(20)
)
LOCATION (
    's3://your-bucket/landing/orders/run_20240615/'
)
FORMAT 'PARQUET'          -- or 'CSV' with delimiter
DISTRIBUTED BY (order_id); -- aligns with GP distribution key
```

### Key design decisions

- **No temp files on disk** — segments write directly to S3 objects. Zero disk I/O on the GP host beyond the WAL.
- **Partition 0…N** — each GP segment writes its own S3 object (e.g., `orders_seg0.parquet`, `orders_seg1.parquet`). Parallelism is automatic.
- **Format choice** — Parquet is preferred because it is columnar (faster Snowpipe COPY), self-describing (schema enforcement), and compresses 3–5× better than CSV.
- **S3 prefix per run** — including `run_id` in the prefix makes every run idempotent; a retry writes to a fresh prefix and does not overwrite a previous partial load.

---

## 3. Stage 2 — Export: Multiprocessing Workers

### What happens

A Python orchestrator spawns one **Worker** per table (Worker 1 for Table A, Worker 2 for Table B, Worker N for Table N). Each worker issues the `INSERT INTO ext_<table>_s3 SELECT * FROM <table>` command to Greenplum and waits for completion.

### Why multiprocessing (not multithreading)?

Greenplum queries are CPU + network bound. Python's GIL blocks true CPU parallelism in threads. `multiprocessing.Pool` gives each worker its own Python process and its own GP connection.

### Worker implementation sketch

```python
import multiprocessing
import psycopg2
import logging
from dataclasses import dataclass
from typing import Optional

@dataclass
class ExportResult:
    table_name: str
    run_id: str
    s3_prefix: str
    row_count: int
    success: bool
    error: Optional[str] = None

def export_table(args: dict) -> ExportResult:
    """Runs inside a worker process."""
    table   = args["table"]
    run_id  = args["run_id"]
    bucket  = args["bucket"]
    s3_prefix = f"s3://{bucket}/landing/{table}/{run_id}/"

    conn = psycopg2.connect(**args["gp_conn"])
    try:
        cur = conn.cursor()

        # Step 1: Create (or replace) the writable external table pointing at this run's prefix
        cur.execute(f"""
            CREATE WRITABLE EXTERNAL TABLE ext_{table}_{run_id} (LIKE {table})
            LOCATION ('{s3_prefix}')
            FORMAT 'PARQUET'
            DISTRIBUTED BY ({args['dist_key']});
        """)

        # Step 2: Export
        cur.execute(f"""
            INSERT INTO ext_{table}_{run_id}
            SELECT * FROM {table};
        """)

        # Step 3: Capture GP row count immediately after export
        cur.execute(f"SELECT COUNT(*) FROM {table};")
        row_count = cur.fetchone()[0]

        conn.commit()
        logging.info(f"[{table}] Exported {row_count} rows to {s3_prefix}")
        return ExportResult(table, run_id, s3_prefix, row_count, True)

    except Exception as e:
        conn.rollback()
        logging.error(f"[{table}] Export failed: {e}")
        return ExportResult(table, run_id, s3_prefix, 0, False, str(e))
    finally:
        conn.close()


def run_parallel_export(tables: list, run_id: str, config: dict) -> list[ExportResult]:
    args_list = [
        {
            "table": t,
            "run_id": run_id,
            "bucket": config["bucket"],
            "gp_conn": config["gp_conn"],
            "dist_key": config["dist_keys"].get(t, "1"),
        }
        for t in tables
    ]

    with multiprocessing.Pool(processes=min(len(tables), config["max_workers"])) as pool:
        results = pool.map(export_table, args_list)

    return results
```

### Worker output per table

Each worker produces:

```
s3://your-bucket/landing/orders/run_20240615/
    ├── orders_seg0.parquet   (GP segment 0 data)
    ├── orders_seg1.parquet   (GP segment 1 data)
    ├── orders_seg2.parquet
    └── ...orders_segN.parquet
```

---

## 4. Stage 3 — Landing: S3 Landing Zone

### What happens

S3 is the durable intermediate store. Every file uploaded by GP gets an **ETag** assigned by S3 — this is an MD5 (or multipart equivalent) hash of the file content, computed and stored by S3 at upload time.

### ETag recording

The worker process (or a post-export S3 lister) records the ETag of each uploaded object immediately after upload. This is the **expected ETag** stored in the manifest.

```python
import boto3

def list_s3_files_with_etags(bucket: str, prefix: str) -> list[dict]:
    """List all objects under a prefix and capture their ETags."""
    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")

    files = []
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        for obj in page.get("Contents", []):
            files.append({
                "key":       obj["Key"],
                "etag":      obj["ETag"].strip('"'),   # S3 wraps ETags in quotes
                "size":      obj["Size"],
                "last_mod":  obj["LastModified"].isoformat(),
            })
    return files
```

### Why ETag-based verification?

| Verification method | What it catches |
|--------------------|----------------|
| File existence check | Missing files only |
| File size check | Truncated files |
| **ETag check** | **Bit-level corruption, partial writes, wrong file** |

ETag is the strongest possible check without reading every byte back from S3.

---

## 5. Stage 4 — Verify: Manifest Writer

### What happens

After all workers complete, the **Manifest Writer** consolidates metadata for a run into a single JSON manifest file written back to S3. This manifest is the single source of truth for the Checksum Gate.

### Manifest structure

```json
{
  "run_id": "run_20240615_143022",
  "created_at": "2024-06-15T14:30:22Z",
  "tables": {
    "orders": {
      "s3_prefix": "s3://your-bucket/landing/orders/run_20240615_143022/",
      "gp_row_count": 4823917,
      "files": [
        { "key": "landing/orders/run_20240615_143022/orders_seg0.parquet", "etag": "a1b2c3d4e5f6...", "size_bytes": 18234512 },
        { "key": "landing/orders/run_20240615_143022/orders_seg1.parquet", "etag": "f6e5d4c3b2a1...", "size_bytes": 17981024 }
      ]
    },
    "customers": {
      "s3_prefix": "s3://your-bucket/landing/customers/run_20240615_143022/",
      "gp_row_count": 982341,
      "files": [
        { "key": "landing/customers/run_20240615_143022/customers_seg0.parquet", "etag": "deadbeef1234...", "size_bytes": 5120000 }
      ]
    }
  }
}
```

### Manifest Writer implementation

```python
import json
import boto3
from datetime import datetime, timezone

def write_manifest(run_id: str, export_results: list, bucket: str) -> str:
    tables_meta = {}
    for result in export_results:
        if not result.success:
            raise RuntimeError(f"Cannot write manifest — {result.table_name} export failed")

        files = list_s3_files_with_etags(bucket, f"landing/{result.table_name}/{run_id}/")
        tables_meta[result.table_name] = {
            "s3_prefix":    result.s3_prefix,
            "gp_row_count": result.row_count,
            "files":        files,
        }

    manifest = {
        "run_id":     run_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "tables":     tables_meta,
    }

    manifest_key = f"_manifest/{run_id}.json"
    boto3.client("s3").put_object(
        Bucket=bucket,
        Key=manifest_key,
        Body=json.dumps(manifest, indent=2),
        ContentType="application/json",
    )
    print(f"Manifest written: s3://{bucket}/{manifest_key}")
    return manifest_key
```

---

## 6. Stage 5 — Verify: Checksum Gate

### What happens

The **Checksum Gate** re-lists every file referenced in the manifest and compares the **live S3 ETag** against the **recorded manifest ETag**. If any file's ETag does not match, the gate signals a mismatch and the async orchestrator triggers a **retry of the export + manifest + checksum stages** for the affected table (up to 2 retries).

If all ETags match, a `gate_pass ✓` flag is set and the pipeline proceeds to Snowpipe ingestion.

### Why can ETags mismatch?

- S3 eventual consistency (rare with strong consistency since Dec 2020, but still possible in edge cases)
- Multipart upload interruptions where S3 assembled a corrupt part
- A concurrent process overwrote the file
- Network-level corruption on PUT

### Checksum Gate implementation

```python
import boto3
import json
import logging

class ChecksumGate:
    def __init__(self, bucket: str, manifest_key: str):
        self.bucket = bucket
        self.s3 = boto3.client("s3")
        manifest_obj = self.s3.get_object(Bucket=bucket, Key=manifest_key)
        self.manifest = json.loads(manifest_obj["Body"].read())

    def verify(self) -> dict[str, bool]:
        """Returns {table_name: passed} for every table in the manifest."""
        results = {}
        for table_name, meta in self.manifest["tables"].items():
            passed = True
            for expected_file in meta["files"]:
                actual_etag = self._get_live_etag(expected_file["key"])
                if actual_etag != expected_file["etag"]:
                    logging.warning(
                        f"[{table_name}] ETag MISMATCH for {expected_file['key']}: "
                        f"expected={expected_file['etag']}, actual={actual_etag}"
                    )
                    passed = False
                else:
                    logging.debug(f"[{table_name}] ETag OK: {expected_file['key']}")
            results[table_name] = passed
        return results

    def _get_live_etag(self, key: str) -> str:
        head = self.s3.head_object(Bucket=self.bucket, Key=key)
        return head["ETag"].strip('"')

    def all_passed(self) -> bool:
        return all(self.verify().values())
```

---

## 7. Stage 6 — Ingest: Snowpipe Auto-Ingest

### What happens

**Snowpipe** is Snowflake's serverless, continuous ingestion service. When new files land in S3, S3 publishes an event to an **SQS queue**. Snowpipe polls the SQS queue, discovers new files, and issues a `COPY INTO` for each micro-batch — automatically, without any manual trigger.

### Setup: Snowflake side

```sql
-- 1. Create the target table
CREATE TABLE orders (
    order_id    BIGINT,
    customer_id INT,
    order_date  DATE,
    amount      NUMERIC(12,2),
    status      VARCHAR(20)
);

-- 2. Create an external stage pointing at the S3 landing prefix
CREATE STAGE orders_stage
    URL = 's3://your-bucket/landing/orders/'
    CREDENTIALS = (AWS_ROLE = 'arn:aws:iam::ACCOUNT:role/SnowflakeRole')
    FILE_FORMAT = (TYPE = 'PARQUET');

-- 3. Create the pipe
CREATE PIPE orders_pipe
    AUTO_INGEST = TRUE
    AS
    COPY INTO orders
    FROM @orders_stage
    FILE_FORMAT = (TYPE = 'PARQUET')
    MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

```sql
-- 4. Get the SQS ARN — paste this into your S3 bucket event notification config
SHOW PIPES;
-- Look for notification_channel column → arn:aws:sqs:us-east-1:SNOWFLAKE_ACCOUNT:sf-snowpipe-...
```

### Setup: AWS side

In the S3 bucket → Properties → Event notifications:

```
Event types:  s3:ObjectCreated:*
Prefix:       landing/
Destination:  SQS → <ARN from SHOW PIPES>
```

### Snowpipe load flow

```
GP writes parquet to s3://bucket/landing/orders/run_xyz/orders_seg0.parquet
         │
         ▼
S3 fires s3:ObjectCreated event → SQS queue
         │
         ▼
Snowpipe polls SQS (< 1 minute latency)
         │
         ▼
Snowpipe issues: COPY INTO orders FROM @orders_stage/run_xyz/orders_seg0.parquet
         │
         ▼
Data available in Snowflake orders table within seconds
```

### Idempotency: skip already-ingested files

Snowpipe tracks every loaded file in `COPY_HISTORY`. Re-submitting a file that was already ingested is a no-op — Snowpipe skips it. This is the "skip if already ingested" behaviour shown in the architecture.

```sql
-- Inspect what Snowpipe has loaded
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'ORDERS',
    START_TIME => DATEADD(HOURS, -24, CURRENT_TIMESTAMP())
));
```

---

## 8. Stage 7 — Target: Snowflake Tables

### What is available after ingestion

- Data queryable **within seconds** of Snowpipe picking up the SQS event.
- Zero manual `COPY INTO` commands needed.
- Every run's files are logged in `COPY_HISTORY` for auditability.

### Waiting for Snowpipe to finish

Because Snowpipe is asynchronous, your orchestrator must **poll** until all expected files have been processed before doing the row-count comparison.

```python
import snowflake.connector
import time
import logging

def wait_for_snowpipe_completion(conn_params: dict, table: str,
                                 expected_files: list[str],
                                 timeout_seconds: int = 1800) -> bool:
    conn = snowflake.connector.connect(**conn_params)
    cur  = conn.cursor()
    start = time.time()

    while time.time() - start < timeout_seconds:
        cur.execute(f"""
            SELECT FILE_NAME
            FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
                TABLE_NAME => '{table.upper()}',
                START_TIME => DATEADD(HOURS, -2, CURRENT_TIMESTAMP())
            ))
            WHERE STATUS = 'Loaded';
        """)
        loaded = {row[0].split("/")[-1] for row in cur.fetchall()}
        expected = {f.split("/")[-1] for f in expected_files}

        if expected.issubset(loaded):
            logging.info(f"[{table}] All {len(expected)} files loaded by Snowpipe ✓")
            conn.close()
            return True

        pending = expected - loaded
        logging.info(f"[{table}] Waiting — {len(pending)} files still pending: {list(pending)[:3]}...")
        time.sleep(30)

    conn.close()
    logging.error(f"[{table}] Snowpipe timed out after {timeout_seconds}s")
    return False
```

---

## 9. Stage 8 — Reconciliation: Row-Count Verification + Retry (MISSING LOGIC ADDED)

> ⚠️ **This stage was missing from the original architecture.** The diagram showed a "retry on mismatch" arrow only at the Checksum Gate level. The row-count comparison between Greenplum and Snowflake — and the retry when they don't match — was not implemented.

### Why row-count reconciliation is necessary

The Checksum Gate verifies **file integrity** (bytes landed in S3 correctly). It does **not** verify that Snowpipe actually loaded all rows into Snowflake. Failure modes it misses:

| Failure mode | Checksum Gate catches? | Reconciliation catches? |
|---|---|---|
| S3 upload corruption | ✓ | ✓ |
| Snowpipe skipped a file | ✗ | ✓ |
| Snowpipe partial load (file truncated mid-COPY) | ✗ | ✓ |
| Schema mismatch caused rows to be rejected | ✗ | ✓ |
| Snowpipe SQS event dropped | ✗ | ✓ |

### Reconciliation logic

```python
import snowflake.connector
import psycopg2
import logging
import time

class ReconciliationResult:
    def __init__(self, table: str, gp_count: int, sf_count: int):
        self.table     = table
        self.gp_count  = gp_count
        self.sf_count  = sf_count
        self.match     = gp_count == sf_count
        self.delta     = sf_count - gp_count

    def __repr__(self):
        status = "✓ MATCH" if self.match else f"✗ MISMATCH (delta={self.delta:+,})"
        return f"[{self.table}] GP={self.gp_count:,} | SF={self.sf_count:,} | {status}"


def get_gp_count(gp_conn_params: dict, table: str) -> int:
    conn = psycopg2.connect(**gp_conn_params)
    cur  = conn.cursor()
    cur.execute(f"SELECT COUNT(*) FROM {table};")
    count = cur.fetchone()[0]
    conn.close()
    return count


def get_sf_count(sf_conn_params: dict, table: str) -> int:
    conn = snowflake.connector.connect(**sf_conn_params)
    cur  = conn.cursor()
    cur.execute(f"SELECT COUNT(*) FROM {table.upper()};")
    count = cur.fetchone()[0]
    conn.close()
    return count


def reconcile_table(table: str, gp_conn_params: dict,
                    sf_conn_params: dict) -> ReconciliationResult:
    gp_count = get_gp_count(gp_conn_params, table)
    sf_count = get_sf_count(sf_conn_params, table)
    result = ReconciliationResult(table, gp_count, sf_count)
    logging.info(str(result))
    return result
```

### Retry wrapper (up to 2 retries)

```python
MAX_RECONCILIATION_RETRIES = 2

def run_pipeline_with_reconciliation_retry(
    tables: list[str],
    config: dict,
    attempt: int = 0
) -> dict[str, ReconciliationResult]:
    """
    Full pipeline:  export → manifest → checksum → wait_snowpipe → reconcile
    If reconciliation fails for any table, retry the FULL pipeline for those
    tables (up to MAX_RECONCILIATION_RETRIES times).
    """
    run_id = generate_run_id()   # e.g. f"run_{datetime.utcnow():%Y%m%d_%H%M%S}_attempt{attempt}"

    logging.info(f"=== Pipeline attempt {attempt + 1}/{MAX_RECONCILIATION_RETRIES + 1} "
                 f"for {len(tables)} table(s) ===")

    # ── STEP 1: Export ──────────────────────────────────────────────────────
    export_results = run_parallel_export(tables, run_id, config)
    failed_exports = [r for r in export_results if not r.success]
    if failed_exports:
        raise RuntimeError(f"Export failed for: {[r.table_name for r in failed_exports]}")

    # ── STEP 2: Manifest + Checksum Gate (with its own 2-retry loop) ────────
    manifest_key = write_manifest(run_id, export_results, config["bucket"])
    checksum_results = run_checksum_with_retry(manifest_key, config)   # inner retry loop

    # ── STEP 3: Wait for Snowpipe to land all files in Snowflake ───────────
    for result in export_results:
        files = [f["key"] for f in checksum_results[result.table_name]["files"]]
        landed = wait_for_snowpipe_completion(
            config["sf_conn"], result.table_name, files,
            timeout_seconds=config.get("snowpipe_timeout", 1800)
        )
        if not landed:
            logging.warning(f"[{result.table_name}] Snowpipe did not land all files in time")

    # ── STEP 4: Row-count reconciliation ───────────────────────────────────
    recon_results = {}
    failed_tables = []

    for result in export_results:
        recon = reconcile_table(result.table_name, config["gp_conn"], config["sf_conn"])
        recon_results[result.table_name] = recon

        if not recon.match:
            logging.warning(
                f"[{result.table_name}] Row-count MISMATCH — "
                f"GP={recon.gp_count:,}, SF={recon.sf_count:,}, "
                f"delta={recon.delta:+,}"
            )
            failed_tables.append(result.table_name)

    # ── STEP 5: Retry mismatched tables ────────────────────────────────────
    if failed_tables:
        if attempt < MAX_RECONCILIATION_RETRIES:
            logging.warning(
                f"Reconciliation FAILED for {failed_tables}. "
                f"Retry {attempt + 1}/{MAX_RECONCILIATION_RETRIES} starting..."
            )
            time.sleep(config.get("retry_backoff_seconds", 60) * (attempt + 1))

            # Recurse: only retry the tables that mismatched
            retry_results = run_pipeline_with_reconciliation_retry(
                failed_tables, config, attempt + 1
            )
            # Merge retry results into final results
            recon_results.update(retry_results)
        else:
            # All retries exhausted
            logging.error(
                f"FINAL FAILURE after {MAX_RECONCILIATION_RETRIES} retries. "
                f"Tables with mismatch: {failed_tables}"
            )
            # Raise or return depending on your error handling strategy
            raise RuntimeError(
                f"Row-count mismatch persists for {failed_tables} "
                f"after {MAX_RECONCILIATION_RETRIES} retries"
            )
    else:
        logging.info(f"All {len(tables)} table(s) reconciled successfully ✓")

    return recon_results
```

### What the retry does (step by step)

```
Attempt 1 ─────────────────────────────────────────────────────────────
  Export orders (4,823,917 rows) → S3
  Manifest written
  Checksum gate PASS
  Snowpipe lands files
  Reconcile: GP=4,823,917 | SF=4,820,000 ← MISMATCH (-3,917 rows)
  └─► Retry scheduled (attempt 1/2, backoff=60s)

Attempt 2 ─────────────────────────────────────────────────────────────
  Export orders (4,823,917 rows) → NEW run_id prefix → S3
  Manifest written
  Checksum gate PASS
  Snowpipe lands files
  Reconcile: GP=4,823,917 | SF=4,823,917 ← MATCH ✓
  └─► Done

Attempt 3 (only if attempt 2 also failed) ──────────────────────────────
  [same as above]
  If still MISMATCH after attempt 3 → RAISE RuntimeError, alert on-call
```

### Reconciliation audit log table (recommended)

```sql
-- Create this in Snowflake to track every reconciliation run
CREATE TABLE pipeline_reconciliation_log (
    log_id          NUMBER AUTOINCREMENT,
    run_id          VARCHAR(100),
    table_name      VARCHAR(200),
    attempt_number  INT,
    gp_row_count    BIGINT,
    sf_row_count    BIGINT,
    delta           BIGINT,
    status          VARCHAR(20),   -- 'MATCH' | 'MISMATCH' | 'RETRY_SUCCESS' | 'FINAL_FAIL'
    checked_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

```python
def log_reconciliation(sf_conn_params, run_id, table, attempt, recon: ReconciliationResult):
    conn = snowflake.connector.connect(**sf_conn_params)
    cur  = conn.cursor()
    status = "MATCH" if recon.match else ("RETRY_SUCCESS" if recon.match else "MISMATCH")
    cur.execute("""
        INSERT INTO pipeline_reconciliation_log
            (run_id, table_name, attempt_number, gp_row_count, sf_row_count, delta, status)
        VALUES (%s, %s, %s, %s, %s, %s, %s)
    """, (run_id, table, attempt, recon.gp_count, recon.sf_count, recon.delta, status))
    conn.commit()
    conn.close()
```

---

## 10. Async Orchestrator: The Control Plane

The **async orchestrator** (shown as the right-side vertical bar in the diagram) coordinates all stages. It uses Python `asyncio` so it can await multiple workers/stages concurrently without blocking.

```python
import asyncio
import logging
from datetime import datetime, timezone

async def orchestrate_pipeline(tables: list[str], config: dict):
    run_id = f"run_{datetime.now(timezone.utc):%Y%m%d_%H%M%S}"
    logging.info(f"Pipeline started: {run_id} for tables: {tables}")

    loop = asyncio.get_event_loop()

    try:
        # Run the full pipeline with reconciliation retry in a thread pool
        # (because psycopg2 and snowflake.connector are sync)
        final_results = await loop.run_in_executor(
            None,
            lambda: run_pipeline_with_reconciliation_retry(tables, config)
        )

        # Summary report
        logging.info("=" * 60)
        logging.info("PIPELINE COMPLETE")
        for table, recon in final_results.items():
            logging.info(str(recon))
        logging.info("=" * 60)

    except RuntimeError as e:
        logging.critical(f"Pipeline FAILED: {e}")
        # Trigger PagerDuty / Slack alert here
        raise


if __name__ == "__main__":
    config = {
        "bucket": "your-bucket",
        "max_workers": 8,
        "snowpipe_timeout": 1800,
        "retry_backoff_seconds": 60,
        "gp_conn": {
            "host": "gp-host", "port": 5432,
            "database": "your_db", "user": "etl_user", "password": "***"
        },
        "sf_conn": {
            "account": "your_account", "user": "sf_etl_user",
            "password": "***", "database": "DW", "schema": "PUBLIC",
            "warehouse": "ETL_WH", "role": "ETL_ROLE"
        },
        "dist_keys": {
            "orders": "order_id",
            "customers": "customer_id",
        }
    }

    tables = ["orders", "customers", "products", "line_items"]
    asyncio.run(orchestrate_pipeline(tables, config))
```

---

## 11. End-to-End Data Flow with Sample State

Let's trace one table — `orders` — through every stage.

### Initial state (Greenplum)

```
gp_db=# SELECT COUNT(*) FROM orders;
 count
----------
 4823917
```

### After Stage 2 — S3 Landing

```
s3://your-bucket/landing/orders/run_20240615_143022/
├── orders_seg0.parquet  (ETag: a1b2c3...)  1,205,979 rows
├── orders_seg1.parquet  (ETag: d4e5f6...)  1,206,002 rows
├── orders_seg2.parquet  (ETag: 7a8b9c...)  1,205,967 rows
└── orders_seg3.parquet  (ETag: 1d2e3f...)  1,205,969 rows
                                            ──────────────
                                   Total:   4,823,917 rows
```

### After Stage 5 — Manifest (manifest JSON excerpt)

```json
"orders": {
  "gp_row_count": 4823917,
  "files": [
    { "key": "landing/orders/run_20240615_143022/orders_seg0.parquet", "etag": "a1b2c3..." },
    { "key": "landing/orders/run_20240615_143022/orders_seg1.parquet", "etag": "d4e5f6..." },
    { "key": "landing/orders/run_20240615_143022/orders_seg2.parquet", "etag": "7a8b9c..." },
    { "key": "landing/orders/run_20240615_143022/orders_seg3.parquet", "etag": "1d2e3f..." }
  ]
}
```

### After Stage 6 — Checksum Gate

```
[orders] ETag OK: orders_seg0.parquet ✓
[orders] ETag OK: orders_seg1.parquet ✓
[orders] ETag OK: orders_seg2.parquet ✓
[orders] ETag OK: orders_seg3.parquet ✓
gate_pass ✓  → proceed to Snowpipe
```

### After Stage 7 — Snowpipe COPY_HISTORY

```sql
SELECT FILE_NAME, ROW_COUNT, STATUS
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(TABLE_NAME => 'ORDERS', ...));

FILE_NAME                                    ROW_COUNT  STATUS
-------------------------------------------  ---------  ------
orders/run_.../orders_seg0.parquet           1205979    Loaded
orders/run_.../orders_seg1.parquet           1206002    Loaded
orders/run_.../orders_seg2.parquet           1205967    Loaded
orders/run_.../orders_seg3.parquet           1205969    Loaded
```

### After Stage 8 — Reconciliation

```
[orders] GP=4,823,917 | SF=4,823,917 | ✓ MATCH
Pipeline complete.
```

---

## 12. Complete Implementation Reference

### Project layout

```
gp_to_sf_pipeline/
├── orchestrator.py          ← asyncio entry point
├── export/
│   ├── worker.py            ← multiprocessing export logic
│   └── external_table.py    ← DDL generation for writable ext tables
├── manifest/
│   ├── writer.py            ← Manifest Writer
│   └── checksum_gate.py     ← Checksum Gate + inner retry
├── ingest/
│   └── snowpipe_wait.py     ← poll COPY_HISTORY until complete
├── reconcile/
│   ├── reconciler.py        ← GP vs SF row count comparison
│   └── audit_log.py         ← write results to reconciliation_log table
├── config/
│   └── pipeline_config.yaml ← connection params, bucket, retry settings
└── tests/
    ├── test_checksum_gate.py
    └── test_reconciler.py
```

### Pipeline config YAML

```yaml
pipeline:
  bucket: your-bucket
  max_workers: 8
  snowpipe_timeout_seconds: 1800
  retry_backoff_seconds: 60
  max_reconciliation_retries: 2
  max_checksum_retries: 2

greenplum:
  host: gp-primary.internal
  port: 5432
  database: your_db
  user: etl_user
  password: "{{ GP_PASSWORD }}"

snowflake:
  account: your_account
  user: sf_etl_user
  password: "{{ SF_PASSWORD }}"
  database: DW
  schema: PUBLIC
  warehouse: ETL_WH
  role: ETL_ROLE

tables:
  - name: orders
    dist_key: order_id
  - name: customers
    dist_key: customer_id
  - name: products
    dist_key: product_id
```

---

## 13. Failure Scenarios & Mitigations

| Failure | Where detected | Mitigation |
|---------|---------------|------------|
| GP segment crashes mid-export | Worker fails, export_results.success=False | Worker marks table failed; orchestrator skips to retry |
| S3 upload corruption | Checksum Gate: ETag mismatch | Re-export to new S3 prefix (up to 2×) |
| S3 event missed by SQS | Snowpipe wait timeout | Manual `ALTER PIPE orders_pipe REFRESH` then re-wait |
| Snowpipe partial COPY (schema mismatch) | Reconciliation: SF < GP | Full pipeline retry for that table |
| Snowpipe SQS event dropped | Reconciliation: SF < GP | Full pipeline retry |
| GP data changed between export and count | Reconciliation: delta > 0 | Use snapshot isolation: `BEGIN; SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;` |
| All retries exhausted | Orchestrator raises RuntimeError | PagerDuty alert + manual intervention |
| Snowflake warehouse suspended | Snowpipe COPY queued | Auto-resume on warehouse or use SNOWPARK_OPTIMIZED |

---

## Summary: What Each Retry Covers

```
RETRY LOOP 1 — Checksum Gate (max 2 retries)
  Catches: S3 upload corruption, partial writes
  Action:  Re-run export for that table to a fresh S3 prefix
  Scope:   File integrity only

RETRY LOOP 2 — Reconciliation (max 2 retries)  ← WAS MISSING
  Catches: Snowpipe skips, partial COPYs, rejected rows, SQS drops
  Action:  Re-run full pipeline for mismatched table(s)
  Scope:   End-to-end data completeness (GP source == SF target)
```

Both loops are **table-scoped** — a failure in `orders` does not block or re-run `customers` if `customers` already matched.

---

*Document generated from GP → Snowflake Migration Pipeline architecture review.*
*Last updated: June 2026*
