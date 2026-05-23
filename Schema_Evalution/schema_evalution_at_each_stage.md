# Schema Evolution Handling Across All Data Layers

## Problem Statement

RAW layer uses `COPY + MATCH_BY_COLUMN_NAME + ENABLE_SCHEMA_EVOLUTION` which auto-adds new columns. But downstream layers (Staging, Curated, Consumption) use `INSERT INTO` with hardcoded column names which **BREAK** when RAW schema changes.

> **Key Fact from Snowflake Docs:**  
> "Schema evolution is limited to COPY INTO statements and Snowpipe. INSERT operations CANNOT evolve the target table schema automatically."

---

## Section 1: RAW Layer Setup (Schema Evolution Enabled)

```sql
CREATE DATABASE IF NOT EXISTS SCHEMA_EVOLUTION_DEMO;
USE DATABASE SCHEMA_EVOLUTION_DEMO;
CREATE SCHEMA IF NOT EXISTS RAW;
CREATE SCHEMA IF NOT EXISTS STAGING;
CREATE SCHEMA IF NOT EXISTS CURATED;
CREATE SCHEMA IF NOT EXISTS CONSUMPTION;
CREATE SCHEMA IF NOT EXISTS CONTROL;

CREATE OR REPLACE TABLE RAW.RAW_ORDERS (
    ORDER_ID VARCHAR(50),
    CUSTOMER_ID VARCHAR(50),
    ORDER_DATE VARCHAR(50),
    AMOUNT VARCHAR(50),
    STATUS VARCHAR(50),
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
) ENABLE_SCHEMA_EVOLUTION = TRUE;

CREATE OR REPLACE TABLE STAGING.STG_ORDERS (
    ORDER_ID VARCHAR(50),
    CUSTOMER_ID VARCHAR(50),
    ORDER_DATE DATE,
    AMOUNT NUMBER(18,2),
    STATUS VARCHAR(50),
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### Simulate Schema Evolution

Source file now has NEW columns "DISCOUNT" and "REGION" that didn't exist before. After `COPY INTO RAW` with `MATCH_BY_COLUMN_NAME`, RAW table gets these columns auto-added. But `STAGING.STG_ORDERS` doesn't have them.

```sql
ALTER TABLE RAW.RAW_ORDERS ADD COLUMN DISCOUNT VARCHAR(50);
ALTER TABLE RAW.RAW_ORDERS ADD COLUMN REGION VARCHAR(50);

INSERT INTO RAW.RAW_ORDERS (ORDER_ID, CUSTOMER_ID, ORDER_DATE, AMOUNT, STATUS, DISCOUNT, REGION) VALUES
    ('ORD001', 'C001', '2025-01-15', '100.00', 'COMPLETED', '10.00', 'US-EAST'),
    ('ORD002', 'C002', '2025-01-16', '200.00', 'PENDING', NULL, 'EU-WEST'),
    ('ORD003', 'C003', '2025-01-17', '150.00', 'SHIPPED', '5.00', NULL);
```

---

## Section 2: The Problem - Hardcoded INSERT Breaks

```sql
INSERT INTO STAGING.STG_ORDERS (ORDER_ID, CUSTOMER_ID, ORDER_DATE, AMOUNT, STATUS)
SELECT ORDER_ID, CUSTOMER_ID, TRY_TO_DATE(ORDER_DATE), TRY_CAST(AMOUNT AS NUMBER(18,2)), STATUS
FROM RAW.RAW_ORDERS;
```

This "works" but **silently IGNORES** new columns (DISCOUNT, REGION). You lose data without knowing it!

---

## Section 3: All Ways to Handle Schema Evolution at Each Layer

### Way 1: Dynamic SQL Stored Procedure (Best for Production)

Automatically discovers matching columns between source & target.

```sql
CREATE OR REPLACE PROCEDURE CONTROL.SP_DYNAMIC_LOAD(
    P_SOURCE_TABLE VARCHAR,
    P_TARGET_TABLE VARCHAR,
    P_ADD_MISSING_COLUMNS BOOLEAN DEFAULT FALSE
)
RETURNS VARIANT
LANGUAGE SQL
AS

DECLARE
    v_common_columns VARCHAR;
    v_new_columns VARIANT;
    v_sql VARCHAR;
    v_source_db VARCHAR;
    v_source_schema VARCHAR;
    v_source_table VARCHAR;
    v_target_db VARCHAR;
    v_target_schema VARCHAR;
    v_target_table VARCHAR;
    v_result VARIANT;
    c_new_cols CURSOR FOR
        SELECT COLUMN_NAME, DATA_TYPE
        FROM INFORMATION_SCHEMA.COLUMNS
        WHERE TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME = UPPER(:P_SOURCE_TABLE)
          AND COLUMN_NAME NOT IN (
              SELECT COLUMN_NAME
              FROM INFORMATION_SCHEMA.COLUMNS
              WHERE TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME = UPPER(:P_TARGET_TABLE)
          );
BEGIN
    -- Step 1: If ADD_MISSING_COLUMNS = TRUE, add new columns to target
    IF (P_ADD_MISSING_COLUMNS) THEN
        FOR rec IN c_new_cols DO
            EXECUTE IMMEDIATE 'ALTER TABLE ' || P_TARGET_TABLE || ' ADD COLUMN IF NOT EXISTS ' || rec.COLUMN_NAME || ' ' || rec.DATA_TYPE;
        END FOR;
    END IF;

    -- Step 2: Find columns that exist in BOTH source and target
    SELECT LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION) INTO :v_common_columns
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME = UPPER(:P_TARGET_TABLE)
      AND COLUMN_NAME IN (
          SELECT COLUMN_NAME
          FROM INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME = UPPER(:P_SOURCE_TABLE)
      );

    -- Step 3: Build and execute dynamic INSERT
    v_sql := 'INSERT INTO ' || P_TARGET_TABLE || ' (' || v_common_columns || ') ' ||
             'SELECT ' || v_common_columns || ' FROM ' || P_SOURCE_TABLE;

    EXECUTE IMMEDIATE :v_sql;

    v_result := OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'source', P_SOURCE_TABLE,
        'target', P_TARGET_TABLE,
        'columns_loaded', v_common_columns,
        'sql_executed', v_sql
    );
    RETURN v_result;
END;
```

**Usage:**

```sql
-- Load only matching columns (safe, no breakage)
CALL CONTROL.SP_DYNAMIC_LOAD(
    'SCHEMA_EVOLUTION_DEMO.RAW.RAW_ORDERS',
    'SCHEMA_EVOLUTION_DEMO.STAGING.STG_ORDERS',
    FALSE
);

-- Auto-add new columns to target, then load all
CALL CONTROL.SP_DYNAMIC_LOAD(
    'SCHEMA_EVOLUTION_DEMO.RAW.RAW_ORDERS',
    'SCHEMA_EVOLUTION_DEMO.STAGING.STG_ORDERS',
    TRUE
);
```

---

### Way 2: Enable Schema Evolution on Staging + COPY Through Stage

Use an intermediate internal stage to keep COPY-based evolution working. This is the **ONLY way** to get true schema evolution at STAGING layer because INSERT cannot trigger schema evolution.

```sql
ALTER TABLE STAGING.STG_ORDERS SET ENABLE_SCHEMA_EVOLUTION = TRUE;

CREATE OR REPLACE STAGE CONTROL.INTER_STAGE FILE_FORMAT = (TYPE = PARQUET);

-- Step A: Unload RAW to stage
COPY INTO @CONTROL.INTER_STAGE/raw_orders/
  FROM SCHEMA_EVOLUTION_DEMO.RAW.RAW_ORDERS
  FILE_FORMAT = (TYPE = PARQUET)
  OVERWRITE = TRUE;

-- Step B: COPY from stage into STAGING (schema evolves automatically!)
COPY INTO STAGING.STG_ORDERS
  FROM @CONTROL.INTER_STAGE/raw_orders/
  FILE_FORMAT = (TYPE = PARQUET)
  MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

---

### Way 3: VARIANT RAW Column (Store Entire Payload, Parse Later)

Zero schema issues - raw stores everything as JSON.

```sql
CREATE OR REPLACE TABLE RAW.RAW_ORDERS_VARIANT (
    RAW_DATA VARIANT,
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    SOURCE_FILE VARCHAR(500)
);

-- Then staging query dynamically extracts what it needs:
CREATE OR REPLACE VIEW STAGING.V_STG_ORDERS_FROM_VARIANT AS
SELECT
    RAW_DATA:ORDER_ID::VARCHAR AS ORDER_ID,
    RAW_DATA:CUSTOMER_ID::VARCHAR AS CUSTOMER_ID,
    TRY_TO_DATE(RAW_DATA:ORDER_DATE::VARCHAR) AS ORDER_DATE,
    TRY_CAST(RAW_DATA:AMOUNT::VARCHAR AS NUMBER(18,2)) AS AMOUNT,
    RAW_DATA:STATUS::VARCHAR AS STATUS,
    TRY_CAST(RAW_DATA:DISCOUNT::VARCHAR AS NUMBER(18,2)) AS DISCOUNT,
    RAW_DATA:REGION::VARCHAR AS REGION,
    LOADED_AT
FROM RAW.RAW_ORDERS_VARIANT;
```

When source adds new fields → just add them to the view. No table changes needed.

---

### Way 4: Stream + Dynamic Task (Best for Real-Time Pipelines)

Stream captures RAW changes, Task uses dynamic SQL to load.

```sql
CREATE OR REPLACE STREAM CONTROL.RAW_ORDERS_STREAM
    ON TABLE RAW.RAW_ORDERS
    APPEND_ONLY = TRUE;

CREATE OR REPLACE TASK CONTROL.TASK_LOAD_STAGING
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('SCHEMA_EVOLUTION_DEMO.CONTROL.RAW_ORDERS_STREAM')
AS
    CALL SCHEMA_EVOLUTION_DEMO.CONTROL.SP_DYNAMIC_LOAD(
        'SCHEMA_EVOLUTION_DEMO.RAW.RAW_ORDERS',
        'SCHEMA_EVOLUTION_DEMO.STAGING.STG_ORDERS',
        TRUE
    );

ALTER TASK CONTROL.TASK_LOAD_STAGING RESUME;
```

---

### Way 5: Dynamic Table (Snowflake Auto-Refreshes Downstream)

No INSERT needed. Snowflake manages refresh automatically.

```sql
CREATE OR REPLACE DYNAMIC TABLE STAGING.DT_STG_ORDERS
    TARGET_LAG = '5 minutes'
    WAREHOUSE = COMPUTE_WH
AS
SELECT
    ORDER_ID,
    CUSTOMER_ID,
    TRY_TO_DATE(ORDER_DATE, 'YYYY-MM-DD') AS ORDER_DATE,
    TRY_CAST(AMOUNT AS NUMBER(18,2)) AS AMOUNT,
    STATUS,
    TRY_CAST(DISCOUNT AS NUMBER(18,2)) AS DISCOUNT,
    REGION,
    LOADED_AT
FROM SCHEMA_EVOLUTION_DEMO.RAW.RAW_ORDERS;
```

**Limitation:** When RAW gets new columns, Dynamic Table won't auto-include them unless you recreate/alter the DT definition.

---

### Way 6: Schema Change Detection + Auto-ALTER (Most Automated)

Detect new columns and auto-add them before loading.

```sql
CREATE OR REPLACE PROCEDURE CONTROL.SP_SYNC_SCHEMA_AND_LOAD(
    P_SOURCE_TABLE VARCHAR,
    P_TARGET_TABLE VARCHAR
)
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    v_new_cols_count NUMBER DEFAULT 0;
    v_dropped_cols_count NUMBER DEFAULT 0;
    v_columns_loaded VARCHAR;
    v_sql VARCHAR;
    v_result VARIANT;
    c_new CURSOR FOR
        SELECT s.COLUMN_NAME, s.DATA_TYPE
        FROM INFORMATION_SCHEMA.COLUMNS s
        WHERE s.TABLE_CATALOG || '.' || s.TABLE_SCHEMA || '.' || s.TABLE_NAME = UPPER(:P_SOURCE_TABLE)
          AND s.COLUMN_NAME NOT IN (
              SELECT t.COLUMN_NAME
              FROM INFORMATION_SCHEMA.COLUMNS t
              WHERE t.TABLE_CATALOG || '.' || t.TABLE_SCHEMA || '.' || t.TABLE_NAME = UPPER(:P_TARGET_TABLE)
          );
BEGIN
    -- Step 1: Detect and add new columns to target
    FOR rec IN c_new DO
        EXECUTE IMMEDIATE 'ALTER TABLE ' || P_TARGET_TABLE || ' ADD COLUMN ' || rec.COLUMN_NAME || ' ' || rec.DATA_TYPE;
        v_new_cols_count := v_new_cols_count + 1;
    END FOR;

    -- Step 2: Log schema changes
    IF (v_new_cols_count > 0) THEN
        INSERT INTO SCHEMA_EVOLUTION_DEMO.CONTROL.SCHEMA_CHANGE_LOG (SOURCE_TABLE, TARGET_TABLE, CHANGE_TYPE, COLUMNS_AFFECTED, DETECTED_AT)
        VALUES (:P_SOURCE_TABLE, :P_TARGET_TABLE, 'ADD_COLUMN', :v_new_cols_count, CURRENT_TIMESTAMP());
    END IF;

    -- Step 3: Load data using all matching columns
    SELECT LISTAGG(COLUMN_NAME, ', ') WITHIN GROUP (ORDER BY ORDINAL_POSITION) INTO :v_columns_loaded
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME = UPPER(:P_TARGET_TABLE)
      AND COLUMN_NAME IN (
          SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS
          WHERE TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME = UPPER(:P_SOURCE_TABLE)
      );

    v_sql := 'INSERT INTO ' || P_TARGET_TABLE || ' (' || v_columns_loaded || ') SELECT ' || v_columns_loaded || ' FROM ' || P_SOURCE_TABLE;
    EXECUTE IMMEDIATE :v_sql;

    v_result := OBJECT_CONSTRUCT(
        'status', 'SUCCESS',
        'new_columns_added', v_new_cols_count,
        'columns_loaded', v_columns_loaded
    );
    RETURN v_result;
END;
$$;

CREATE OR REPLACE TABLE CONTROL.SCHEMA_CHANGE_LOG (
    LOG_ID NUMBER AUTOINCREMENT,
    SOURCE_TABLE VARCHAR(200),
    TARGET_TABLE VARCHAR(200),
    CHANGE_TYPE VARCHAR(50),
    COLUMNS_AFFECTED NUMBER,
    DETECTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

---

## Section 4: Method Comparison

| # | Method | Auto New Col | Auto Drop Col | Zero Manual | Best For |
|---|--------|:---:|:---:|:---:|------|
| 1 | Dynamic SQL (SP) | ✅ (option) | ✅ (safe) | ✅ | Production ETL |
| 2 | COPY via Stage | ✅ (native) | ❌ | ✅ | File-based pipelines |
| 3 | VARIANT RAW | ✅ (inherent) | ✅ (inherent) | ✅ | Semi-structured data |
| 4 | Stream + Dynamic Task | ✅ | ✅ | ✅ | Real-time/CDC |
| 5 | Dynamic Table | ❌ (manual) | ❌ (manual) | ⚠️ Partial | Simple transformations |
| 6 | Schema Sync + Load | ✅ | ⚠️ (logged) | ✅ | Full automation |

---

## Section 5: Layer-by-Layer Recommended Approach

| Layer | Recommended Approach | Why |
|-------|---------------------|-----|
| **RAW** | COPY + MATCH_BY_COLUMN_NAME + ENABLE_SCHEMA_EVOLUTION | Native schema evolution works perfectly with COPY INTO |
| **STAGING** | WAY 1 (Dynamic SQL) or WAY 6 (Schema Sync + Load) | INSERT can't evolve schema, so we auto-detect & add columns before INSERT |
| **CURATED** | WAY 1 (Dynamic SQL) or WAY 5 (Dynamic Table) | Only load validated columns. New columns need approval first |
| **CONSUMPTION** | WAY 5 (Dynamic Table) or Views on top of Curated | Views auto-reflect changes. Dynamic Tables for materialized |

---

## Section 6: Full End-to-End Automated Pipeline

```sql
CREATE OR REPLACE PROCEDURE CONTROL.SP_FULL_PIPELINE()
RETURNS VARIANT
LANGUAGE SQL
AS
$$
DECLARE
    v_raw_result VARIANT;
    v_staging_result VARIANT;
BEGIN
    -- Step 1: RAW → STAGING (auto-add new columns, load all matching)
    CALL SCHEMA_EVOLUTION_DEMO.CONTROL.SP_SYNC_SCHEMA_AND_LOAD(
        'SCHEMA_EVOLUTION_DEMO.RAW.RAW_ORDERS',
        'SCHEMA_EVOLUTION_DEMO.STAGING.STG_ORDERS'
    ) INTO :v_staging_result;

    RETURN OBJECT_CONSTRUCT(
        'pipeline', 'COMPLETED',
        'staging_result', v_staging_result,
        'executed_at', CURRENT_TIMESTAMP()
    );
END;
$$;

-- Run:
CALL CONTROL.SP_FULL_PIPELINE();
```

---

## Section 7: Key Rules to Remember

1. **ENABLE_SCHEMA_EVOLUTION** only works with `COPY INTO` + `MATCH_BY_COLUMN_NAME`. INSERT, MERGE, INSERT OVERWRITE do NOT trigger schema evolution.

2. **MATCH_BY_COLUMN_NAME** cannot be used with SELECT transformation in COPY. You can't do: `COPY INTO t FROM (SELECT ...) MATCH_BY_COLUMN_NAME = ...`

3. Schema evolution requires **EVOLVE SCHEMA** or **OWNERSHIP** privilege on table.

4. Schema evolution is **NOT supported by Tasks** directly. Workaround: Use tasks that call procedures with dynamic SQL.

5. For CSV: `MATCH_BY_COLUMN_NAME` requires `PARSE_HEADER = TRUE` and `ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE`.

6. Max **100 columns** can be added per COPY operation (contact support for more).

7. Schema evolution tracks changes in `INFORMATION_SCHEMA.COLUMNS` via `SchemaEvolutionRecord` field (`DESCRIBE TABLE` shows it).
