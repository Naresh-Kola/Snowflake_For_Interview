# Bad Data Handling in a Snowflake Data Warehouse
**Role:** Snowflake Warehouse Designer  
**Approach:** Native Snowflake `ERROR_LOGGING` — no manual error table design needed

---

## 1. What is Snowflake ERROR_LOGGING

Snowflake provides a native error logging mechanism. When you enable `ERROR_LOGGING` on a table, Snowflake **automatically creates a shadow error table** named `<table_name>$errors` and **automatically inserts every rejected row** into it — with the error reason, row number, column name, and raw value.

No custom error table DDL. No manual INSERT into error table. Snowflake handles it.

```sql
-- Enable error logging on your staging table — one time setup
ALTER TABLE STAGING_ORDERS ENABLE ERROR_LOGGING;

-- Snowflake auto-creates: STAGING_ORDERS$errors
-- Every rejected row during INSERT / MERGE / COPY INTO lands there automatically
```

---

## 2. What Snowflake Puts Inside the $errors Table

Once enabled, every failed row is automatically captured with full context:

| Column | What It Contains |
|--------|-----------------|
| `TIMESTAMP` | When the error occurred |
| `ROW_NUMBER` | Which row in the source failed |
| `COLUMN_NAME` | Which column caused the failure |
| `COLUMN_TYPE` | Expected data type |
| `ERROR_TYPE` | Type of error (e.g. `Cast failed`) |
| `ERROR_MESSAGE` | Exact Snowflake error message |
| `RAW_LINE` | The full raw row that failed |

You query it like any normal table:

```sql
-- See all bad rows for your staging table
SELECT *
FROM STAGING_ORDERS$errors
ORDER BY TIMESTAMP DESC;

-- How many errors today
SELECT
    ERROR_TYPE,
    COUNT(*) AS ERROR_COUNT
FROM STAGING_ORDERS$errors
WHERE TIMESTAMP::DATE = CURRENT_DATE()
GROUP BY ERROR_TYPE;

-- Find exact bad values
SELECT
    ROW_NUMBER,
    COLUMN_NAME,
    ERROR_MESSAGE,
    RAW_LINE
FROM STAGING_ORDERS$errors
WHERE ERROR_TYPE = 'Cast failed';
```

---

## 3. Full Pipeline Procedure Using ERROR_LOGGING

### Step 1 — One-time Setup: Enable Error Logging on Target Tables

```sql
-- Do this once per table in your warehouse setup
ALTER TABLE STAGING_ORDERS      ENABLE ERROR_LOGGING;
ALTER TABLE INTEGRATION_ORDERS  ENABLE ERROR_LOGGING;
ALTER TABLE FACT_ORDERS         ENABLE ERROR_LOGGING;

-- Snowflake auto-creates:
--   STAGING_ORDERS$errors
--   INTEGRATION_ORDERS$errors
--   FACT_ORDERS$errors
```

### Step 2 — Procedure: Let Snowflake Handle the Errors

```sql
CREATE OR REPLACE PROCEDURE TRANSFORM_ORDERS()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    clean_rows    INTEGER DEFAULT 0;
    error_rows    INTEGER DEFAULT 0;
BEGIN

    ------------------------------------------------------------
    -- STAGING LOAD
    -- TRY_ functions handle bad values gracefully (NULL not crash)
    -- ERROR_LOGGING captures any row Snowflake itself rejects
    ------------------------------------------------------------
    INSERT INTO STAGING_ORDERS (
        ORDER_ID,
        PARSED_DATE,
        AMOUNT,
        EMAIL,
        CUSTOMER_ID,
        LOADED_AT
    )
    SELECT
        ORDER_ID,
        COALESCE(
            TRY_TO_DATE(DATE_COL, 'YYYY/MM/DD'),
            TRY_TO_DATE(DATE_COL, 'DD-MM-YYYY'),
            TRY_TO_DATE(DATE_COL, 'YYYY-MM-DD')
        )                          AS PARSED_DATE,
        TRY_TO_NUMBER(AMOUNT_COL)  AS AMOUNT,
        LOWER(TRIM(EMAIL))         AS EMAIL,
        CUSTOMER_ID,
        CURRENT_TIMESTAMP()        AS LOADED_AT
    FROM RAW_ORDERS
    WHERE NOT EXISTS (
        SELECT 1 FROM STAGING_ORDERS S
        WHERE S.ORDER_ID = RAW_ORDERS.ORDER_ID   -- idempotency guard
    );

    -- Capture row counts
    clean_rows := SQLROWCOUNT;

    -- How many landed in $errors automatically
    SELECT COUNT(*) INTO :error_rows
    FROM STAGING_ORDERS$errors
    WHERE TIMESTAMP >= CURRENT_TIMESTAMP() - INTERVAL '1 MINUTE';

    ------------------------------------------------------------
    -- AUDIT LOG — every run recorded
    ------------------------------------------------------------
    INSERT INTO PIPELINE_AUDIT_LOG (
        PIPELINE_NAME,
        LAYER,
        RUN_AT,
        CLEAN_ROWS,
        ERROR_ROWS,
        STATUS
    )
    VALUES (
        'ORDER_PIPELINE',
        'STAGING',
        CURRENT_TIMESTAMP(),
        :clean_rows,
        :error_rows,
        CASE WHEN :error_rows = 0 THEN 'SUCCESS' ELSE 'PARTIAL' END
    );

    RETURN 'Clean: ' || clean_rows || ' | Errors logged to $errors: ' || error_rows;

END;
$$;
```

---

## 4. How You Know Which Rows Are Bad

### 4.1 Query the Auto-Created $errors Table Directly

```sql
-- All bad rows with full context
SELECT
    TIMESTAMP          AS FAILED_AT,
    ROW_NUMBER         AS SOURCE_ROW,
    COLUMN_NAME        AS FAILED_COLUMN,
    ERROR_TYPE,
    ERROR_MESSAGE,
    RAW_LINE           AS ORIGINAL_RAW_ROW
FROM STAGING_ORDERS$errors
ORDER BY TIMESTAMP DESC;
```

### 4.2 Audit Table — Pipeline Run Summary

```sql
CREATE OR REPLACE TABLE PIPELINE_AUDIT_LOG (
    LOG_ID         NUMBER AUTOINCREMENT PRIMARY KEY,
    PIPELINE_NAME  VARCHAR,
    LAYER          VARCHAR,
    RUN_AT         TIMESTAMP,
    CLEAN_ROWS     INTEGER,
    ERROR_ROWS     INTEGER,
    STATUS         VARCHAR    -- 'SUCCESS' | 'PARTIAL' | 'FAILED'
);

-- Check health of every pipeline run
SELECT
    PIPELINE_NAME,
    RUN_AT,
    CLEAN_ROWS,
    ERROR_ROWS,
    ROUND(ERROR_ROWS / NULLIF(CLEAN_ROWS + ERROR_ROWS, 0) * 100, 2) AS ERROR_PCT,
    STATUS
FROM PIPELINE_AUDIT_LOG
ORDER BY RUN_AT DESC;
```

### 4.3 Alert When Error Rate Spikes

```sql
-- Alert query — run this as a Snowflake Task or schedule in your orchestrator
SELECT
    PIPELINE_NAME,
    ERROR_ROWS / NULLIF(CLEAN_ROWS + ERROR_ROWS, 0) * 100 AS ERROR_PCT
FROM PIPELINE_AUDIT_LOG
WHERE RUN_AT::DATE = CURRENT_DATE()
  AND ERROR_ROWS / NULLIF(CLEAN_ROWS + ERROR_ROWS, 0) > 0.05;  -- alert if > 5%
```

A spike from 0.1% to 40% error rate means the **source system changed** — not a data quality blip.

---

## 5. Idempotency — Safe to Re-run Any Number of Times

### 5.1 NOT EXISTS Guard on Every INSERT

```sql
INSERT INTO STAGING_ORDERS (...)
SELECT ...
FROM RAW_ORDERS
WHERE NOT EXISTS (
    SELECT 1 FROM STAGING_ORDERS S
    WHERE S.ORDER_ID = RAW_ORDERS.ORDER_ID
);
```

Re-run the same procedure 10 times — same result every time. No duplicates.

### 5.2 MERGE for Upsert Scenarios

When rows can arrive updated (not just new), use MERGE instead of INSERT:

```sql
MERGE INTO STAGING_ORDERS T
USING RAW_ORDERS S
ON T.ORDER_ID = S.ORDER_ID
WHEN MATCHED AND S.UPDATED_AT > T.LOADED_AT THEN
    UPDATE SET
        T.AMOUNT    = TRY_TO_NUMBER(S.AMOUNT_COL),
        T.LOADED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN
    INSERT (ORDER_ID, PARSED_DATE, AMOUNT, LOADED_AT)
    VALUES (
        S.ORDER_ID,
        TRY_TO_DATE(S.DATE_COL, 'YYYY/MM/DD'),
        TRY_TO_NUMBER(S.AMOUNT_COL),
        CURRENT_TIMESTAMP()
    );
-- ERROR_LOGGING captures any MERGE failures automatically into STAGING_ORDERS$errors
```

### 5.3 Reprocessing Bad Rows After Source Fixes the Data

The `$errors` table stores `RAW_LINE` — the original raw row. After the source fixes the data:

```sql
-- Step 1: See what is still broken
SELECT * FROM STAGING_ORDERS$errors;

-- Step 2: Source fixes the upstream data in RAW_ORDERS

-- Step 3: Re-run the same procedure — NOT EXISTS ensures only
--         previously-failed rows (not already in STAGING_ORDERS) are inserted
CALL TRANSFORM_ORDERS();

-- Step 4: Verify $errors is now empty or reduced
SELECT COUNT(*) FROM STAGING_ORDERS$errors;
```

No separate reprocess procedure needed. The same procedure is idempotent — it naturally picks up rows that were never successfully loaded.

---

## 6. Bad Data at Each Layer of the Architecture

### Layer 1 — Raw / Landing Zone (COPY INTO)

> Files land from S3, Azure Blob, or GCS into Snowflake internal/external stage.

**Common bad data:**

| Issue | Example |
|-------|---------|
| Truncated file | CSV cut off mid-row due to network failure |
| Extra / missing columns | Source added a new column without notice |
| Encoding issues | Latin-1 characters breaking UTF-8 parse |
| Duplicate file load | Same file dropped twice by source team |

**Snowflake handling:**

```sql
-- COPY INTO with ON_ERROR = CONTINUE
-- Bad rows are skipped, good rows land, nothing crashes
COPY INTO RAW_ORDERS
FROM @orders_stage/orders_2024.csv
FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 ENCODING = 'UTF-8')
ON_ERROR = CONTINUE;

-- Inspect what was rejected after the load
SELECT * FROM TABLE(VALIDATE(RAW_ORDERS, JOB_ID => '_last'));
```

---

### Layer 2 — Staging Layer (Raw → Staging / Bronze → Silver)

> Type casting, null handling, deduplication, format standardisation.

**Common bad data:**

| Issue | Snowflake Fix |
|-------|--------------|
| Unparseable date format | `TRY_TO_DATE()` with `COALESCE` of multiple formats |
| Non-numeric amount | `TRY_TO_NUMBER()` |
| NULL in required field | `CASE WHEN col IS NULL THEN ... ERROR_LOGGING captures it` |
| Duplicate records | `QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) = 1` |
| Out-of-range values | `CASE WHEN amount < 0` — bad row excluded from INSERT |

**All failures auto-captured in `STAGING_ORDERS$errors`**

---

### Layer 3 — Integration Layer (Silver → Gold preparation)

> Joining dimensions to facts, surrogate key lookup, SCD Type 2 processing.

**Common bad data:**

| Issue | Snowflake Fix |
|-------|--------------|
| Orphan fact rows — FK not in dimension | `LEFT JOIN` + filter `WHERE DIM_KEY IS NULL` to quarantine |
| Late-arriving dimension | Hold fact row in staging; retry after dim load completes |
| SCD Type 2 date overlap | Validate `EFFECTIVE_FROM < EFFECTIVE_TO` before insert |
| Stale lookup / reference table | Timestamp check on last dimension refresh before join |

```sql
-- Detect orphan fact rows before loading
SELECT F.*
FROM STAGING_ORDERS F
LEFT JOIN DIM_CUSTOMER C ON F.CUSTOMER_ID = C.CUSTOMER_ID
WHERE C.CUSTOMER_ID IS NULL;
-- Route these to $errors or hold in staging for retry
```

---

### Layer 4 — Warehouse Layer (Gold / Fact and Dimension Tables)

> Final aggregations, business metrics, mart tables served to BI tools.

**Common bad data:**

| Issue | Snowflake Fix |
|-------|--------------|
| Division by zero in KPIs | `NULLIF(denominator, 0)` in every division |
| NULL propagating into metrics | `COALESCE(metric_col, 0)` on all measure columns |
| Duplicate metric rows in incremental load | `MERGE` instead of INSERT |
| Fan-out from bad join inflating row count | Row count assertion before and after join |

```sql
-- Safe metric calculation — never crashes on zero
SELECT
    ORDER_ID,
    REVENUE / NULLIF(UNITS_SOLD, 0)   AS REVENUE_PER_UNIT,
    COALESCE(DISCOUNT_AMT, 0)         AS DISCOUNT_AMT
FROM FACT_ORDERS;
```

---

### Layer 5 — Consumption / Serving Layer (BI / Reports / APIs)

> Views, materialised views, dbt models served to Tableau, Power BI, dashboards.

**Common bad data:**

| Issue | Fix |
|-------|-----|
| Stale materialised view | Freshness check on `LAST_REFRESH` timestamp before serving |
| NULL appearing in dashboard KPI | Final `COALESCE` in view definition |
| Wrong grain in report | Grain documented and row count assertion in dbt test |

---

## 7. Full Pipeline Flow with ERROR_LOGGING

```
SOURCE SYSTEM  (S3 / API / DB)
        │
        ▼
COPY INTO — ON_ERROR = CONTINUE
        │                    └──► TABLE(VALIDATE(...)) — rejected rows visible here
        ▼
RAW TABLE  (store everything, never delete, never transform in-place)
        │
        ▼
TRANSFORM_ORDERS() Procedure
  ├── TRY_TO_DATE / TRY_TO_NUMBER  ──► NULL for bad values (not a crash)
  ├── NOT EXISTS guard              ──► idempotency on every INSERT
  └── ERROR_LOGGING enabled         ──► bad rows auto-written to STAGING_ORDERS$errors
        │                                        │
        ▼                                        ▼
STAGING_ORDERS                       STAGING_ORDERS$errors
(clean rows)                         (bad rows — RAW_LINE + ERROR_MESSAGE)
        │                                        │
        ▼                            source fixes upstream data
INTEGRATION LAYER                               │
(dim join, SCD2)                     Re-run TRANSFORM_ORDERS()
        │                            NOT EXISTS picks up unfailed rows only
        ▼
FACT / DIM TABLES (Gold)
        │
        ▼
BI / REPORTS / APIs
```

---

## 8. Key Principles — Interview Cheat Sheet

| Principle | What It Means in Practice |
|-----------|--------------------------|
| **Enable ERROR_LOGGING** | `ALTER TABLE t ENABLE ERROR_LOGGING` — Snowflake auto-creates `t$errors` |
| **TRY_ over TO_** | Every type cast uses the safe version — NULL over crash |
| **NOT EXISTS on every INSERT** | Re-run the procedure 10 times — same result every time |
| **MERGE for updates** | Handles new + updated rows idempotently in one statement |
| **Raw layer is sacred** | Never transform in-place — always preserve the original raw value |
| **$errors has RAW_LINE** | You always have the original bad row — full reprocess context |
| **Audit every run** | Log clean / error counts to PIPELINE_AUDIT_LOG after every procedure call |
| **Alert on rate not count** | 100 errors in 1M rows is fine — 100 errors in 110 rows is a source incident |
| **Same procedure reprocesses** | Idempotent NOT EXISTS means re-running naturally picks up previously failed rows |
