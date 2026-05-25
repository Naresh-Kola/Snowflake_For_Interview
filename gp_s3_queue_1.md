# GP → Snowflake Migration Pipeline — Study Notes

---

## 1. Pipeline Overview

The GP → Snowflake Migration Pipeline moves data from Greenplum to Snowflake using these key technologies:

- **Writable External Tables** — GP writes directly to S3, no staging temp files
- **Multiprocessing** — parallel workers, one per table
- **Manifest / Checksum** — integrity verification before ingestion
- **Snowpipe Auto-Ingest** — serverless, continuous micro-batch loading
- **Async Orchestrator** — handles retries on mismatch

### Pipeline Stages

| Stage | Component | What it does |
|---|---|---|
| SOURCE | Greenplum — Writable External S3 Tables | Each table points to an S3 prefix; GP segments write in parallel |
| EXPORT | Worker 1 … Worker N | Each worker exports one table → S3 partitions (part0…N) |
| LANDING | S3 Landing Zone | Parquet/CSV per table prefix; S3 ETag recorded per file on upload |
| VERIFY | Manifest Writer + Checksum Gate | Writes manifest JSON; compares expected vs actual ETags |
| INGEST | Snowpipe — Auto-Ingest | SQS trigger → COPY INTO target table; serverless; continuous micro-batches |
| TARGET | Snowflake Target Tables | Data available within seconds; zero manual COPY commands; idempotent re-runs |

---

## 2. Manifest Writer and Checksum Gate (VERIFY Stage)

This is the integrity guard that sits between S3 and Snowpipe. It prevents corrupt or incomplete data from ever reaching Snowflake.

### Manifest Writer

After each GP worker uploads files to S3, the Manifest Writer generates a per-table JSON file written to `s3://.../manifest/<run_id>.json`.

Each entry in the manifest records:
- **File path** — the S3 key of the uploaded file
- **ETag** — the MD5 checksum S3 assigns to every object on upload
- **Row count** — number of rows written by the GP worker

```json
{
  "file": "tableA/part0.parquet",
  "etag": "abc123",
  "rows": 50000
}
```

### Checksum Gate

The gate reads the manifest and re-queries S3 live, then compares:

| | Expected | Actual |
|---|---|---|
| Source | Manifest JSON (written at upload time) | Live S3 API query |
| Contains | File paths, ETags, row counts | ETags of files currently in S3, file existence |
| Purpose | "What should be there" | "What is actually there" |

### What happens on mismatch

- A **re-run flag** is set
- The async orchestrator retries the export for that table only (not the whole pipeline)
- On retry, if a file's ETag is already recorded as loaded in Snowflake, Snowpipe **skips it** (idempotency)

### Why this step is necessary

Parallel multiprocessing exports are fast but risky. With N workers writing N partitions simultaneously you can get:
- Partial uploads
- Network interruptions
- Silent failures where a file exists but has wrong data

Without the checksum gate, Snowflake would ingest corrupted or incomplete data silently.

---

## 3. Post-Load Row Count Reconciliation

The pipeline as shown stops at Snowpipe ingestion. A production pipeline should add a reconciliation step after loading.

### How it works

The manifest already has row counts per file. After Snowpipe finishes, compare against Snowflake:

```sql
SELECT COUNT(*) AS actual_rows
FROM target_schema.table_a;
```

In your orchestrator (Python/Airflow):

```python
expected = sum(f["rows"] for f in manifest["files"])  # from manifest JSON
actual   = snowflake_cursor.fetchone()[0]              # from COUNT(*)

if actual != expected:
    raise ValueError(f"Row mismatch: expected {expected}, got {actual}")
```

### How to know Snowpipe is done before checking

Snowpipe is async — you can't check immediately. Standard approaches:

- **Poll `COPY_HISTORY`** — wait until all expected files show status `LOADED`
- **Fixed delay** — simple but fragile
- **SQS completion event** — Snowpipe emits events; orchestrator listens and triggers check

### Mismatch causes and remediation

| Mismatch type | Likely cause | Remediation |
|---|---|---|
| Snowflake < expected | Snowpipe skipped a file or partial load | Check `COPY_HISTORY` for errors; re-trigger COPY for missing files |
| Snowflake > expected | Duplicate load / idempotency failure | Check if file was loaded twice; TRUNCATE + full reload |
| Small difference | Schema mismatch silently dropped rows | Inspect `COPY_HISTORY` error rows |

---

## 4. LOAD_HISTORY vs COPY_HISTORY vs PIPE_STATUS

Three different Snowflake system views — each answers a different question.

### Quick reference

| View | Question it answers | Granularity | Window |
|---|---|---|---|
| `LOAD_HISTORY` | Did this table get loaded? | Table-level | 14 days |
| `COPY_HISTORY` | What happened to each file? | File-level | 14 days |
| `PIPE_STATUS` | Is my Snowpipe healthy? | Pipe/infra level | Real-time |

---

### INFORMATION_SCHEMA.LOAD_HISTORY

**Use when:** You want a quick pass/fail per table. Simple dashboards, high-level alerts.

**Granularity:** One row per table per load operation.

**What you get:** Table name, last load time, status, row count, error count — but NOT which files caused the failure.

**Example query:**

```sql
SELECT table_name, status, row_count, error_count
FROM information_schema.load_history
WHERE table_name = 'ORDERS'
ORDER BY last_load_time DESC;
```

**Example output:**

| TABLE_NAME | LAST_LOAD_TIME | STATUS | ROW_COUNT | ERROR_COUNT |
|---|---|---|---|---|
| ORDERS | 2024-05-25 09:14:00 | LOADED | 50000 | 0 |
| CUSTOMERS | 2024-05-25 09:16:00 | LOAD_FAILED | 0 | 120 |

---

### INFORMATION_SCHEMA.COPY_HISTORY

**Use when:** You need to reconcile row counts, find which partition failed, debug schema mismatches, or build the post-load validator for your GP pipeline. This is the most useful view for your pipeline.

**Granularity:** One row per file. Works for both Snowpipe and manual COPY INTO.

**What you get:** File name, table name, status, row count, first error message per file.

**Example query:**

```sql
SELECT file_name, status, row_count, first_error_message
FROM information_schema.copy_history
WHERE table_name = 'ORDERS'
  AND status != 'LOADED'
ORDER BY last_load_time DESC;
```

**Example output:**

| FILE_NAME | STATUS | ROW_COUNT | FIRST_ERROR_MESSAGE |
|---|---|---|---|
| orders/part0.parquet | LOADED | 12500 | — |
| orders/part2.parquet | LOAD_FAILED | 0 | Value 'N/A' is not valid for col AMOUNT |
| orders/part3.parquet | PARTIALLY_LOADED | 11800 | Null value in NOT NULL column ORDER_ID |

**For reconciliation against the manifest:**

```python
# Sum rows from COPY_HISTORY for LOADED files
# Compare against manifest total
loaded_rows = sum(r["row_count"] for r in copy_history if r["status"] == "LOADED")
manifest_rows = sum(f["rows"] for f in manifest["files"])

if loaded_rows != manifest_rows:
    # find the gap — which files are missing or partial?
    failed = [r for r in copy_history if r["status"] != "LOADED"]
```

---

### SYSTEM$PIPE_STATUS

**Use when:** Files are in S3 but nothing is loading. Check if the pipe is running, SQS is connected, or if there is a growing lag.

**Note:** This tells you nothing about row counts or file content. It tells you whether Snowpipe itself is alive.

**Example query:**

```sql
SELECT SYSTEM$PIPE_STATUS('MY_DB.MY_SCHEMA.ORDERS_PIPE');
```

**Key fields in the JSON response:**

| Field | Example | Meaning |
|---|---|---|
| `executionState` | RUNNING | Pipe is active and polling SQS |
| `pendingFileCount` | 3 | Files waiting to be loaded right now |
| `notificationChannelName` | arn:aws:sqs:... | SQS queue Snowpipe is listening to |
| `lastIngestedTimestamp` | 2024-05-25 09:22:01 | When the last file was picked up |
| `error` | null | Pipe-level config error (not a data error) |

**If `executionState` is STOPPED or `pendingFileCount` keeps growing — the pipe is stuck, not the data.**

---

### Decision guide: which view to use

```
Something is wrong — where do I start?
│
├── Nothing is loading at all
│   └── → SYSTEM$PIPE_STATUS  (is the pipe alive?)
│
├── Some tables loaded, some didn't
│   └── → LOAD_HISTORY  (quick table-level pass/fail)
│
├── Table loaded but row counts don't match
│   └── → COPY_HISTORY  (which partitions failed or were partial?)
│
└── Need to build automated reconciliation
    └── → COPY_HISTORY  (file-level, has row counts and error messages)
```

---

## 5. Idempotency

### Definition

**Idempotency means: doing the same operation twice gives the same result as doing it once.**

The mathematical expression: `f(f(x)) = f(x)`

### Real-world analogy

Pressing an elevator button — press it once or press it ten times, one elevator comes. The extra presses have no additional effect.

### Why it matters in pipelines

In any distributed pipeline, failures and retries are normal — network blips, partial uploads, timeouts. Idempotency is what makes retrying safe.

| Without idempotency | With idempotency |
|---|---|
| "Did the last run partially succeed?" | Just re-run the whole thing |
| "Will I get duplicate data if I retry?" | System skips what's already done |
| "Do I need to clean up before retrying?" | No cleanup needed |
| Retries are dangerous | Retries are free |

### How your pipeline achieves idempotency

Snowpipe uses the **S3 file path + ETag** as a unique key. If it has already loaded a file with that exact ETag, it skips it — no duplicate rows.

**Example:**

| Run | File | ETag | Result |
|---|---|---|---|
| Run 1 | orders/part0.parquet | abc123 | LOADED — 50,000 rows inserted |
| Retry | orders/part0.parquet | abc123 | SKIPPED — already ingested |
| Retry | orders/part0.parquet | abc123 | SKIPPED — already ingested |
| Snowflake total | | | 50,000 rows — always |

If the file was re-exported (content changed), the ETag changes → Snowpipe loads the new version.

### Common idempotency patterns in data pipelines

**1. ETag / hash key (your pipeline)**
Snowpipe tracks each file's ETag. Same file = same ETag = skip.

**2. MERGE instead of INSERT**
```sql
MERGE INTO orders USING staging ON orders.id = staging.id
WHEN MATCHED THEN UPDATE SET ...
WHEN NOT MATCHED THEN INSERT (...)  VALUES (...);
```
Running this 10 times gives the same result as running it once. A plain `INSERT` would add duplicates every time.

**3. Partition overwrite**
Instead of appending, overwrite the entire date partition. Re-running always produces the same partition — no duplicates, no gaps.

**4. Run ID / watermark**
Tag every load with a `run_id`. Before loading, check if that `run_id` already exists and skip if so. The manifest JSON in your pipeline already carries a `run_id` for exactly this purpose.

---

## 6. Summary — Key Concepts

| Concept | One-line summary |
|---|---|
| Writable External Tables | GP writes directly to S3 in parallel — no temp files |
| ETag | MD5 fingerprint S3 assigns to every uploaded object |
| Manifest | JSON file recording expected files, ETags, and row counts for a run |
| Checksum Gate | Compares manifest (expected) vs live S3 (actual) before allowing ingestion |
| Snowpipe | Serverless, event-driven COPY INTO — fires on SQS notification from S3 |
| LOAD_HISTORY | Table-level load summary — quick pass/fail check |
| COPY_HISTORY | File-level load detail — use for reconciliation and debugging |
| PIPE_STATUS | Snowpipe infrastructure health — use when nothing is loading |
| Idempotency | Safe to retry — running the same operation multiple times produces the same result |
| Async Orchestrator | Manages retries; only re-runs the failed table, not the whole pipeline |
