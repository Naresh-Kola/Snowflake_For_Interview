# Bad Data Handling in a Snowflake Data Warehouse — Interview Reference

**Role:** Snowflake Warehouse Designer  
**Context:** End-to-end data engineering pipeline — from source ingestion to gold layer serving

---

## 1. Types of Bad Data I Have Handled in My Project

### 1.1 Schema-Level Issues

| Issue | Example | Layer Detected |
|-------|---------|---------------|
| Unexpected NULL in non-nullable column | `ORDER_ID = NULL` in fact table | Raw → Staging |
| Data type mismatch | `AMOUNT = 'N/A'` instead of numeric | Staging |
| Schema drift | Upstream added a new column without notice | Raw ingestion |
| Column renamed at source | `CUST_ID` renamed to `CUSTOMER_ID` overnight | Raw ingestion |
| Extra or missing columns in flat file | CSV arrives with 18 cols, expected 20 | Ingestion |

### 1.2 Value-Level Issues

| Issue | Example | Layer Detected |
|-------|---------|---------------|
| Unparseable date format | `Jan-15-2024` when pipeline expects `YYYY/MM/DD` | Staging transform |
| Negative values in non-negative fields | `QUANTITY = -5` | Staging |
| Future-dated records | `ORDER_DATE = 2099-01-01` | Staging |
| Invalid email / phone format | `email = 'notanemail'` | Staging |
| Out-of-range values | `AGE = 999`, `DISCOUNT_PCT = 150` | Staging |
| Invalid referential key | `PRODUCT_ID` not found in `DIM_PRODUCT` | Integration layer |
| Duplicate primary keys | Same `ORDER_ID` arriving twice | Staging / DWH load |
| Encoding issues | Special characters breaking string columns | Raw ingestion |

### 1.3 Business-Rule Violations

| Issue | Example | Layer Detected |
|-------|---------|---------------|
| Orphan fact rows | Fact record with no matching dimension key | Integration |
| Contradictory data | `SHIP_DATE < ORDER_DATE` | Business rule layer |
| Zero-division risk in metrics | `REVENUE / UNITS` where `UNITS = 0` | Aggregation |
| Incorrect currency codes | `CURRENCY = 'XX'` | Staging |

---

## 2. Pipeline Design — Never Fail on Bad Data

### 2.1 Core Architecture: Staging Table with Status Column

Instead of writing two separate INSERT statements (clean table + quarantine table), every row lands in a single **staging table** with a `ROW_STATUS` column decided by `CASE WHEN` logic in one SQL scan.

```sql
INSERT INTO STAGING_WITH_STATUS
SELECT
    ID,
    RAW_VALUE,
    OTHER_COL,

    -- Transform attempt
    CASE
        WHEN <validation_condition> THEN <transform_logic>
        ELSE NULL
    END AS TRANSFORMED_VALUE,

    -- Row classification
    CASE
        WHEN AMOUNT < 0                        THEN 'QUARANTINE'
        WHEN ORDER_DATE > CURRENT_DATE()       THEN 'QUARANTINE'
        WHEN EMAIL NOT LIKE '%@%.%'            THEN 'QUARANTINE'
        WHEN TRY_TO_DATE(DATE_COL,'YYYY/MM/DD') IS NULL THEN 'QUARANTINE'
        ELSE 'CLEAN'
    END AS ROW_STATUS,

    -- Exact error reason per row
    CASE
        WHEN AMOUNT < 0                        THEN 'Negative amount: ' || AMOUNT
        WHEN ORDER_DATE > CURRENT_DATE()       THEN 'Future date: ' || ORDER_DATE
        WHEN EMAIL NOT LIKE '%@%.%'            THEN 'Invalid email: ' || EMAIL
        WHEN TRY_TO_DATE(DATE_COL,'YYYY/MM/DD') IS NULL THEN 'Unparseable date: ' || DATE_COL
        ELSE NULL
    END AS ERROR_REASON,

    CURRENT_TIMESTAMP() AS PROCESSED_AT,
    FALSE               AS IS_REPROCESSED

FROM RAW_TABLE
WHERE NOT EXISTS (
    SELECT 1 FROM STAGING_WITH_STATUS S WHERE S.ID = RAW_TABLE.ID  -- idempotency guard
);
```

### 2.2 Downstream Views — No Extra Tables Needed

```sql
-- Clean rows view
CREATE OR REPLACE VIEW V_CLEAN AS
SELECT * FROM STAGING_WITH_STATUS
WHERE ROW_STATUS = 'CLEAN';

-- Quarantine view — only unresolved bad rows
CREATE OR REPLACE VIEW V_QUARANTINE AS
SELECT * FROM STAGING_WITH_STATUS
WHERE ROW_STATUS = 'QUARANTINE'
  AND IS_REPROCESSED = FALSE;
```

**One table. One scan. Zero pipeline failures.**

### 2.3 Safe Type Conversion — Snowflake TRY_ Functions

Always use safe cast functions in transforms. These return `NULL` instead of throwing an error:

| Unsafe Function | Safe Equivalent |
|----------------|----------------|
| `TO_DATE()` | `TRY_TO_DATE()` |
| `TO_NUMBER()` | `TRY_TO_NUMBER()` |
| `TO_TIMESTAMP()` | `TRY_TO_TIMESTAMP()` |
| `CAST(x AS INT)` | `TRY_CAST(x AS INT)` |

### 2.4 When SQL Is Not Enough — JavaScript Stored Procedure

For custom transform logic with no Snowflake built-in (e.g., a proprietary date format, a complex string parser), I use a **JavaScript stored procedure** with row-level try/catch:

```javascript
CREATE OR REPLACE PROCEDURE TRANSFORM_WITH_ROW_ERROR_HANDLING()
RETURNS STRING
LANGUAGE JAVASCRIPT
AS
$$
    var clean_count = 0;
    var quarantine_count = 0;
    var rows = snowflake.execute({ sqlText: `SELECT ID, DATE_COL, AMOUNT FROM RAW_TABLE` });

    while (rows.next()) {
        var id  = rows.getColumnValue('ID');
        var raw = rows.getColumnValue('DATE_COL');

        try {
            var parsed = customTransform(raw);  // your custom logic

            snowflake.execute({
                sqlText: `INSERT INTO CLEAN_TABLE (ID, PARSED_VALUE)
                          SELECT :1, :2
                          WHERE NOT EXISTS (SELECT 1 FROM CLEAN_TABLE WHERE ID = :1)`,
                binds: [id, parsed]
            });
            clean_count++;

        } catch(err) {
            snowflake.execute({
                sqlText: `INSERT INTO QUARANTINE_TABLE
                              (ID, RAW_VALUE, ERROR_REASON, QUARANTINED_AT, IS_REPROCESSED)
                          SELECT :1, :2, :3, CURRENT_TIMESTAMP(), FALSE
                          WHERE NOT EXISTS (SELECT 1 FROM QUARANTINE_TABLE WHERE ID = :1)`,
                binds: [id, raw, err.message]
            });
            quarantine_count++;
        }
    }

    return `Clean: ${clean_count} | Quarantined: ${quarantine_count}`;

    function customTransform(val) {
        // example: parse "Jan-2024-15" — no built-in handles this
        var match = String(val).match(/^(\w{3})-(\d{4})-(\d{2})$/);
        if (!match) throw new Error('Unrecognised format: ' + val);
        return match[2] + '-' + match[1] + '-' + match[3];
    }
$$;
```

**Key principle:** The `try/catch` is inside the loop — one bad row throws, gets quarantined, loop continues. The pipeline never stops.

---

## 3. How I Know Which Rows Are Bad

### 3.1 Error Reason Column

Every quarantined row stores:

```
ERROR_REASON  = 'Unparseable date: Jan-15-2024'
QUARANTINED_AT = '2024-06-01 14:32:00'
IS_REPROCESSED = FALSE
```

No guessing. The exact failure reason is persisted with the raw value.

### 3.2 Pipeline Run Summary Table

After every procedure call, I log a summary row into a dedicated audit table:

```sql
INSERT INTO PIPELINE_AUDIT_LOG
VALUES (
    :run_id,
    :pipeline_name,
    :total_rows_ingested,
    :clean_rows,
    :quarantine_rows,
    CURRENT_TIMESTAMP(),
    :status   -- 'SUCCESS' | 'PARTIAL' | 'FAILED'
);
```

### 3.3 Anomaly Alert

If quarantine rate crosses a threshold (e.g., > 5% of total rows), I trigger an alert. A sudden spike from 0.1% to 40% quarantine rate means the **source system changed**, not a data quality issue.

```sql
SELECT
    PIPELINE_NAME,
    QUARANTINE_ROWS / TOTAL_ROWS_INGESTED * 100 AS QUARANTINE_PCT
FROM PIPELINE_AUDIT_LOG
WHERE RUN_DATE = CURRENT_DATE()
  AND QUARANTINE_ROWS / TOTAL_ROWS_INGESTED > 0.05;  -- alert threshold: 5%
```

---

## 4. Idempotency — Safe to Re-run Any Number of Times

### 4.1 NOT EXISTS Guard on Every Insert

```sql
INSERT INTO CLEAN_TABLE (ID, PARSED_VALUE, ...)
SELECT ...
FROM RAW_TABLE
WHERE NOT EXISTS (
    SELECT 1 FROM CLEAN_TABLE C WHERE C.ID = RAW_TABLE.ID
);
```

Re-running the same procedure 10 times produces the same result. No duplicates.

### 4.2 Reprocessing Bad Rows After Source Fix

Once the source team fixes the bad data:

```sql
-- Re-evaluate only unresolved quarantined rows
UPDATE STAGING_WITH_STATUS
SET
    TRANSFORMED_VALUE = <your_transform_logic>,
    ROW_STATUS        = 'CLEAN',
    ERROR_REASON      = NULL,
    IS_REPROCESSED    = TRUE,
    PROCESSED_AT      = CURRENT_TIMESTAMP()
WHERE ROW_STATUS      = 'QUARANTINE'
  AND IS_REPROCESSED  = FALSE
  AND <your_validation_condition>;  -- same condition as original
```

Only unresolved rows are touched. Clean rows are never re-evaluated.

### 4.3 Idempotency Contract Summary

| Scenario | Behaviour |
|----------|-----------|
| Re-run on same raw data | No duplicate rows inserted |
| Re-run after partial failure | Only missing rows are inserted |
| Reprocess quarantine after fix | Only `IS_REPROCESSED = FALSE` rows updated |
| New raw rows arrive | Only new IDs (NOT EXISTS) are processed |

---

## 5. Bad Data at Each Layer of the Data Engineering Architecture

### Layer 1 — Source / Ingestion Layer (Landing Zone / Raw)

> **What lands here:** Flat files (CSV, JSON, Parquet), API responses, CDC streams, database extracts.

| Bad Data Type | Root Cause | How I Handle It |
|--------------|-----------|----------------|
| Missing files | Source job failed | File arrival check before pipeline trigger |
| Extra / missing columns | Schema drift at source | Column count validation; alert on mismatch |
| Encoding issues | UTF-8 vs Latin-1 mismatch | Force UTF-8 at COPY INTO stage options |
| Truncated file | Network cut mid-transfer | Row count reconciliation against source manifest |
| Duplicate file load | File re-dropped by source | Stage deduplication using file metadata |

**Snowflake feature used:** `COPY INTO` with `ON_ERROR = CONTINUE` + `VALIDATE()` function to inspect rejected rows before committing.

```sql
COPY INTO RAW_TABLE
FROM @my_stage/data.csv
FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1)
ON_ERROR = CONTINUE;   -- skip bad rows, log them, don't fail the load

-- Inspect what was rejected
SELECT * FROM TABLE(VALIDATE(RAW_TABLE, JOB_ID => '_last'));
```

---

### Layer 2 — Staging Layer (Bronze → Silver)

> **What happens here:** Type casting, null handling, deduplication, basic business rule checks.

| Bad Data Type | Root Cause | How I Handle It |
|--------------|-----------|----------------|
| Unparseable dates | Source format changed | `TRY_TO_DATE()` + quarantine |
| Non-numeric amounts | Currency symbols, free text | `TRY_TO_NUMBER()` + quarantine |
| Nulls in critical columns | Source not enforcing constraints | `CASE WHEN col IS NULL THEN 'QUARANTINE'` |
| Duplicate records | Source system re-sent records | `QUALIFY ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) = 1` |
| Out-of-range values | Data entry error | Range check in CASE WHEN |

**Design principle:** Every row gets a `ROW_STATUS` and `ERROR_REASON`. One insert, one scan, no pipeline failure.

---

### Layer 3 — Integration Layer (Silver → Gold preparation)

> **What happens here:** Joining dimensions to facts, surrogate key lookup, SCD Type 2 processing.

| Bad Data Type | Root Cause | How I Handle It |
|--------------|-----------|----------------|
| Orphan fact rows | FK not found in dimension | LEFT JOIN + flag rows where `DIM_KEY IS NULL` |
| Late-arriving dimensions | Dim record not yet loaded | Hold fact in staging; retry after dim load |
| SCD Type 2 gap | Effective date overlap in dim | Validate `EFFECTIVE_FROM < EFFECTIVE_TO` before insert |
| Stale lookup data | Reference table not refreshed | Timestamp check on last dim refresh before join |

```sql
-- Detect orphan facts (no matching dimension)
SELECT F.*
FROM FACT_ORDERS F
LEFT JOIN DIM_CUSTOMER C ON F.CUSTOMER_KEY = C.CUSTOMER_KEY
WHERE C.CUSTOMER_KEY IS NULL;  -- these are orphan rows
```

---

### Layer 4 — Warehouse Layer (Gold / Presentation)

> **What happens here:** Aggregations, business metrics, mart tables consumed by BI tools.

| Bad Data Type | Root Cause | How I Handle It |
|--------------|-----------|----------------|
| Division by zero in KPIs | Zero denominator in metric calc | `NULLIF(denominator, 0)` in every division |
| Incorrect aggregation grain | Fan-out from bad join | Row count check before and after join |
| Duplicate metric rows | Incremental load without dedup | `MERGE` statement instead of INSERT |
| NULL propagation into reports | Upstream NULL not handled | `COALESCE()` on all metric columns |

```sql
-- Safe division — never divide by zero
SELECT
    REVENUE / NULLIF(UNITS_SOLD, 0)    AS REVENUE_PER_UNIT,
    COALESCE(DISCOUNT_AMT, 0)          AS DISCOUNT_AMT
FROM FACT_SALES;
```

---

### Layer 5 — Consumption / Serving Layer (BI / API)

> **What happens here:** Views, materialized views, data shared to Tableau / Power BI / dbt models.

| Bad Data Type | Root Cause | How I Handle It |
|--------------|-----------|----------------|
| Stale materialized view | Refresh job failed | Freshness check timestamp on MV metadata |
| NULL in dashboard KPI | Upstream bad data reached gold | Final `COALESCE` + data quality test in dbt |
| Incorrect row counts in report | Filter applied at wrong grain | Grain documentation + row count assertion |

---

## 6. Full Pipeline Flow — One Picture

```
SOURCE SYSTEM
     │
     ▼
[COPY INTO — ON_ERROR=CONTINUE]
     │
     ▼
RAW TABLE  (store everything, never delete)
     │
     ▼
[Stored Procedure — CASE WHEN + TRY_ functions]
     │
     ▼
STAGING_WITH_STATUS
     ├── ROW_STATUS = 'CLEAN'       ──► V_CLEAN  ──► INTEGRATION ──► GOLD ──► BI
     └── ROW_STATUS = 'QUARANTINE'  ──► V_QUARANTINE
                                              │
                                    source fixes data
                                              │
                                    [UPDATE — IS_REPROCESSED = TRUE]
                                              │
                                              └──► back to CLEAN path
```

---

## 7. Key Principles — Interview Cheat Sheet

| Principle | What It Means in Practice |
|-----------|--------------------------|
| **Never silent drop** | Every rejected row is stored with an error reason |
| **One scan, one insert** | Use `CASE WHEN` status column — not two separate inserts |
| **Idempotency** | `NOT EXISTS` guard on every insert; `UPDATE` only `IS_REPROCESSED = FALSE` rows |
| **TRY_ over TO_** | Every type cast uses the safe version — null over crash |
| **Quarantine is not a bin** | Quarantine rows are reprocessable — they are not deleted |
| **Audit every run** | Log total / clean / quarantine counts to an audit table |
| **Alert on rate, not count** | 100 bad rows in 1M is fine; 100 bad rows in 110 is a source incident |
| **Raw layer is sacred** | Never transform in-place; always preserve the original raw value |