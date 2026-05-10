# ERROR HANDLING IN MIGRATION PROJECTS (Production Level)

Greenplum → Snowflake (450+ tables). What errors occur, where they occur, how to catch them, how to fix them, and how to explain this in an interview.

---

## 1. TYPES OF ERRORS IN A MIGRATION PROJECT

Errors occur at EVERY stage of the pipeline:

| STAGE | ERROR TYPE | EXAMPLE |
|---|---|---|
| 1. EXTRACTION (Source → File) | Connection failures | Greenplum timeout |
| | Query timeout | 1B row table hangs |
| | Encoding errors | LATIN1 chars break UTF-8 |
| | Permission denied | Role lacks SELECT access |
| 2. TRANSFER (File → Stage) | Network failure | S3 upload interrupted |
| | File corruption | Parquet file truncated |
| | Disk full | Staging server out of space |
| 3. LOADING (Stage → Table) | Data type mismatch | Infinity in FLOAT col |
| | Schema mismatch | Extra/missing column |
| | Constraint violation | VARCHAR too short |
| | Format errors | Bad date: '2024-13-45' |
| | File format issues | Wrong delimiter in CSV |
| 4. TRANSFORMATION (Table → Table) | SQL errors | Divide by zero |
| | Logic errors | Wrong JOIN = duplicates |
| | NULL handling | NULL in calculation |
| | Type casting failures | '12,345' → NUMBER fails |
| 5. VALIDATION (DQ Checks) | Reconciliation failures | Row count mismatch |
| | Business rule violation | Negative amounts exist |
| | Referential integrity | Orphan child records |
| 6. ORCHESTRATION (Scheduling) | Task failures | Snowflake task suspended |
| | Dependency failures | Parent task failed |
| | Timeout | Warehouse auto-suspend |
| | Resource contention | Warehouse queue full |

---

## 2. ERROR HANDLING STRATEGY: THE 5 PILLARS

| PILLAR | PURPOSE |
|---|---|
| PILLAR 1: PREVENT | Stop errors before they happen |
| PILLAR 2: DETECT | Catch errors immediately when they occur |
| PILLAR 3: LOG | Record every error with full context |
| PILLAR 4: RECOVER | Auto-retry or gracefully handle failures |
| PILLAR 5: ALERT | Notify the right people at the right time |

---

## 3. PILLAR 1: PREVENTION (Stop errors before they happen)

### 3.1 PRE-FLIGHT CHECKS (Run before every load)

```sql
CREATE OR REPLACE TABLE MIGRATION_DB.OPS.PREFLIGHT_CHECKS (
    CHECK_ID INT AUTOINCREMENT,
    TABLE_NAME VARCHAR(200),
    CHECK_NAME VARCHAR(100),
    CHECK_RESULT VARCHAR(10),
    DETAILS VARCHAR(2000),
    CHECKED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE MIGRATION_DB.OPS.SP_PREFLIGHT_CHECK(TABLE_NAME VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_table_exists BOOLEAN;
BEGIN
    SELECT COUNT(*) > 0 INTO :v_table_exists
    FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_NAME = :TABLE_NAME AND TABLE_SCHEMA = 'PUBLIC';
    
    IF (NOT v_table_exists) THEN
        INSERT INTO MIGRATION_DB.OPS.PREFLIGHT_CHECKS (TABLE_NAME, CHECK_NAME, CHECK_RESULT, DETAILS)
        VALUES (:TABLE_NAME, 'TARGET_TABLE_EXISTS', 'FAIL', 'Table does not exist in target schema');
        RETURN 'PREFLIGHT FAILED: Target table missing';
    END IF;
    
    INSERT INTO MIGRATION_DB.OPS.PREFLIGHT_CHECKS (TABLE_NAME, CHECK_NAME, CHECK_RESULT, DETAILS)
    VALUES (:TABLE_NAME, 'TARGET_TABLE_EXISTS', 'PASS', 'Table exists');
    
    RETURN 'PREFLIGHT PASSED';
END;
$$;
```

### 3.2 DATA TYPE MAPPING VALIDATION

```sql
CREATE OR REPLACE TABLE MIGRATION_DB.OPS.TYPE_MAPPING (
    SOURCE_TABLE VARCHAR(200),
    SOURCE_COLUMN VARCHAR(200),
    SOURCE_TYPE VARCHAR(100),
    TARGET_TYPE VARCHAR(100),
    CONVERSION_RULE VARCHAR(500),
    RISK_LEVEL VARCHAR(10)
);

INSERT INTO MIGRATION_DB.OPS.TYPE_MAPPING VALUES
('orders', 'amount',     'NUMERIC(38,10)', 'NUMBER(38,10)',   'Direct mapping', 'LOW'),
('orders', 'order_date', 'TIMESTAMPTZ',    'TIMESTAMP_TZ',   'Preserve timezone offset', 'MEDIUM'),
('payments','tax_rate',  'FLOAT8',         'FLOAT',          'Check for Infinity/NaN', 'HIGH'),
('customers','phone',    'CHAR(15)',       'VARCHAR(15)',     'TRIM trailing spaces', 'MEDIUM'),
('audit_log','event_ts', 'TIMESTAMP',     'TIMESTAMP_NTZ',   'No timezone in source', 'HIGH');

SELECT * FROM MIGRATION_DB.OPS.TYPE_MAPPING WHERE RISK_LEVEL = 'HIGH';
```

---

## 4. PILLAR 2: DETECTION (Catch errors when they occur)

### 4.1 COPY INTO ERROR HANDLING

```sql
-- OPTION A: ON_ERROR = 'CONTINUE' (Load good rows, skip bad rows)
COPY INTO MIGRATION_DB.PUBLIC.ORDERS
FROM @MIGRATION_DB.RAW.GP_STAGE/orders/
FILE_FORMAT = (TYPE = 'PARQUET')
ON_ERROR = 'CONTINUE'
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;

-- Check what was rejected:
SELECT * FROM TABLE(VALIDATE(MIGRATION_DB.PUBLIC.ORDERS, JOB_ID => '_last'));

-- OPTION B: ON_ERROR = 'ABORT_STATEMENT' (Fail entire load on first error)
COPY INTO MIGRATION_DB.PUBLIC.ORDERS
FROM @MIGRATION_DB.RAW.GP_STAGE/orders/
FILE_FORMAT = (TYPE = 'PARQUET')
ON_ERROR = 'ABORT_STATEMENT';

-- OPTION C: ON_ERROR = 'SKIP_FILE' (Skip entire file if it has errors)
COPY INTO MIGRATION_DB.PUBLIC.ORDERS
FROM @MIGRATION_DB.RAW.GP_STAGE/orders/
FILE_FORMAT = (TYPE = 'CSV' FIELD_DELIMITER=',' ERROR_ON_COLUMN_COUNT_MISMATCH=FALSE)
ON_ERROR = 'SKIP_FILE';

-- OPTION D: VALIDATION_MODE (Dry run - don't load, just check for errors)
COPY INTO MIGRATION_DB.PUBLIC.ORDERS
FROM @MIGRATION_DB.RAW.GP_STAGE/orders/
FILE_FORMAT = (TYPE = 'PARQUET')
VALIDATION_MODE = 'RETURN_ALL_ERRORS';
```

### WHICH ON_ERROR TO USE IN PRODUCTION:

| Tier | Setting | Reasoning |
|---|---|---|
| Tier 1 (Critical) | `ABORT_STATEMENT` | Zero tolerance. If even 1 row fails, stop everything. |
| Tier 2 (Core) | `ABORT_STATEMENT` (first), then `VALIDATION_MODE` to analyze | Fix source data, retry |
| Tier 3/4 (Analytics) | `CONTINUE` | Load what you can, log errors, fix later |
| NEVER | `SKIP_FILE` without tracking | Silent data loss — you won't know what was skipped |

### 4.2 ERROR TRACKING TABLE

```sql
CREATE OR REPLACE TABLE MIGRATION_DB.OPS.ERROR_LOG (
    ERROR_ID INT AUTOINCREMENT,
    BATCH_ID VARCHAR(50),
    TABLE_NAME VARCHAR(200),
    ERROR_STAGE VARCHAR(50),
    ERROR_CODE VARCHAR(20),
    ERROR_MESSAGE VARCHAR(4000),
    ERROR_ROW_DATA VARIANT,
    FILE_NAME VARCHAR(500),
    ROW_NUMBER INT,
    COLUMN_NAME VARCHAR(200),
    SEVERITY VARCHAR(10),
    RETRY_COUNT INT DEFAULT 0,
    RESOLUTION VARCHAR(500),
    RESOLVED_AT TIMESTAMP_NTZ,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### 4.3 COPY HISTORY MONITORING

```sql
SELECT 
    TABLE_NAME, FILE_NAME, STATUS,
    ROWS_PARSED, ROWS_LOADED,
    ROWS_PARSED - ROWS_LOADED AS ROWS_REJECTED,
    ERROR_COUNT, FIRST_ERROR_MESSAGE,
    FIRST_ERROR_LINE_NUM, FIRST_ERROR_COLUMN_NAME,
    LAST_LOAD_TIME
FROM SNOWFLAKE.ACCOUNT_USAGE.COPY_HISTORY
WHERE TABLE_NAME = 'ORDERS'
    AND LAST_LOAD_TIME > DATEADD('HOUR', -24, CURRENT_TIMESTAMP())
ORDER BY LAST_LOAD_TIME DESC;
```

---

## 5. PILLAR 3: LOGGING (Record everything for debugging)

### 5.1 MIGRATION BATCH LOG

```sql
CREATE OR REPLACE TABLE MIGRATION_DB.OPS.BATCH_LOG (
    BATCH_ID VARCHAR(50),
    TABLE_NAME VARCHAR(200),
    BATCH_STATUS VARCHAR(20),
    START_TIME TIMESTAMP_NTZ,
    END_TIME TIMESTAMP_NTZ,
    DURATION_SECONDS INT,
    ROWS_EXTRACTED NUMBER,
    ROWS_LOADED NUMBER,
    ROWS_REJECTED NUMBER,
    FILES_PROCESSED INT,
    FILES_FAILED INT,
    ERROR_SUMMARY VARCHAR(2000),
    RETRY_ATTEMPT INT DEFAULT 1,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### 5.2 STORED PROCEDURE WITH TRY-CATCH

```sql
CREATE OR REPLACE PROCEDURE MIGRATION_DB.OPS.SP_MIGRATE_TABLE(
    P_TABLE_NAME VARCHAR, P_BATCH_ID VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_start_time TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_rows_loaded NUMBER DEFAULT 0;
    v_error_message VARCHAR DEFAULT '';
    v_status VARCHAR DEFAULT 'SUCCESS';
BEGIN
    INSERT INTO MIGRATION_DB.OPS.BATCH_LOG (BATCH_ID, TABLE_NAME, BATCH_STATUS, START_TIME)
    VALUES (:P_BATCH_ID, :P_TABLE_NAME, 'RUNNING', :v_start_time);
    
    CALL MIGRATION_DB.OPS.SP_PREFLIGHT_CHECK(:P_TABLE_NAME);
    
    BEGIN
        EXECUTE IMMEDIATE 
            'COPY INTO MIGRATION_DB.PUBLIC.' || :P_TABLE_NAME ||
            ' FROM @MIGRATION_DB.RAW.GP_STAGE/' || LOWER(:P_TABLE_NAME) || '/' ||
            ' FILE_FORMAT = (TYPE = ''PARQUET'')' ||
            ' ON_ERROR = ''ABORT_STATEMENT''' ||
            ' MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE';
        
        EXECUTE IMMEDIATE 
            'SELECT COUNT(*) FROM MIGRATION_DB.PUBLIC.' || :P_TABLE_NAME
            INTO :v_rows_loaded;
    EXCEPTION
        WHEN OTHER THEN
            v_status := 'FAILED';
            v_error_message := SQLERRM;
            INSERT INTO MIGRATION_DB.OPS.ERROR_LOG 
                (BATCH_ID, TABLE_NAME, ERROR_STAGE, ERROR_CODE, ERROR_MESSAGE, SEVERITY)
            VALUES (:P_BATCH_ID, :P_TABLE_NAME, 'LOADING', SQLCODE, :v_error_message, 'HIGH');
    END;
    
    UPDATE MIGRATION_DB.OPS.BATCH_LOG
    SET BATCH_STATUS = :v_status,
        END_TIME = CURRENT_TIMESTAMP(),
        DURATION_SECONDS = DATEDIFF('SECOND', START_TIME, CURRENT_TIMESTAMP()),
        ROWS_LOADED = :v_rows_loaded,
        ERROR_SUMMARY = :v_error_message
    WHERE BATCH_ID = :P_BATCH_ID AND TABLE_NAME = :P_TABLE_NAME;
    
    RETURN :v_status || ': ' || :P_TABLE_NAME || ' (' || :v_rows_loaded || ' rows)';
END;
$$;
```

### 5.3 TASK-LEVEL ERROR HANDLING

```sql
CREATE OR REPLACE TASK MIGRATION_DB.OPS.TASK_MIGRATE_ORDERS
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 2 * * * America/New_York'
    ALLOW_OVERLAPPING_EXECUTION = FALSE
AS
CALL MIGRATION_DB.OPS.SP_MIGRATE_TABLE('ORDERS', 
    'BATCH_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS'));

-- Check task execution history:
SELECT NAME, STATE, ERROR_CODE, ERROR_MESSAGE, SCHEDULED_TIME, COMPLETED_TIME
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'TASK_MIGRATE_ORDERS',
    SCHEDULED_TIME_RANGE_START => DATEADD('DAY', -7, CURRENT_TIMESTAMP())
))
ORDER BY SCHEDULED_TIME DESC;
```

---

## 6. PILLAR 4: RECOVERY (Auto-retry and graceful degradation)

### 6.1 RETRY LOGIC WITH BACKOFF

```sql
CREATE OR REPLACE PROCEDURE MIGRATION_DB.OPS.SP_MIGRATE_WITH_RETRY(
    P_TABLE_NAME VARCHAR, P_MAX_RETRIES INT DEFAULT 3
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_attempt INT DEFAULT 1;
    v_status VARCHAR DEFAULT 'FAILED';
    v_batch_id VARCHAR;
    v_error VARCHAR;
BEGIN
    WHILE (v_attempt <= P_MAX_RETRIES AND v_status != 'SUCCESS') DO
        v_batch_id := 'BATCH_' || :P_TABLE_NAME || '_A' || :v_attempt::VARCHAR;
        BEGIN
            CALL MIGRATION_DB.OPS.SP_MIGRATE_TABLE(:P_TABLE_NAME, :v_batch_id);
            v_status := 'SUCCESS';
        EXCEPTION
            WHEN OTHER THEN
                v_error := SQLERRM;
                v_attempt := v_attempt + 1;
                INSERT INTO MIGRATION_DB.OPS.ERROR_LOG 
                    (BATCH_ID, TABLE_NAME, ERROR_STAGE, ERROR_MESSAGE, SEVERITY, RETRY_COUNT)
                VALUES (:v_batch_id, :P_TABLE_NAME, 'RETRY', 
                    'Attempt ' || (:v_attempt - 1)::VARCHAR || ' failed: ' || :v_error,
                    'MEDIUM', :v_attempt - 1);
        END;
    END WHILE;
    
    IF (v_status != 'SUCCESS') THEN
        INSERT INTO MIGRATION_DB.OPS.ERROR_LOG 
            (BATCH_ID, TABLE_NAME, ERROR_STAGE, ERROR_MESSAGE, SEVERITY)
        VALUES (:v_batch_id, :P_TABLE_NAME, 'ESCALATION', 
            'All ' || :P_MAX_RETRIES::VARCHAR || ' retries failed. Manual intervention required.',
            'CRITICAL');
        RETURN 'FAILED after ' || :P_MAX_RETRIES::VARCHAR || ' attempts';
    END IF;
    RETURN 'SUCCESS on attempt ' || :v_attempt::VARCHAR;
END;
$$;
```

### 6.2 DEAD LETTER TABLE (Quarantine bad records)

```sql
CREATE OR REPLACE TABLE MIGRATION_DB.OPS.DEAD_LETTER_QUEUE (
    DLQ_ID INT AUTOINCREMENT,
    SOURCE_TABLE VARCHAR(200),
    RAW_RECORD VARIANT,
    ERROR_REASON VARCHAR(2000),
    ORIGINAL_FILE VARCHAR(500),
    ORIGINAL_ROW_NUM INT,
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    REPROCESSED_FLAG BOOLEAN DEFAULT FALSE,
    REPROCESSED_AT TIMESTAMP_NTZ
);

-- Pattern: Load with CONTINUE, then move errors to DLQ
COPY INTO MIGRATION_DB.PUBLIC.PAYMENTS
FROM @MIGRATION_DB.RAW.GP_STAGE/payments/
FILE_FORMAT = (TYPE = 'PARQUET')
ON_ERROR = 'CONTINUE';

INSERT INTO MIGRATION_DB.OPS.DEAD_LETTER_QUEUE (SOURCE_TABLE, ERROR_REASON, ORIGINAL_FILE, ORIGINAL_ROW_NUM)
SELECT 'PAYMENTS', ERROR, FILE, LINE
FROM TABLE(VALIDATE(MIGRATION_DB.PUBLIC.PAYMENTS, JOB_ID => '_last'));
```

### 6.3 IDEMPOTENT LOADS (Safe to retry without duplicates)

```sql
-- APPROACH 1: TRUNCATE + RELOAD
TRUNCATE TABLE MIGRATION_DB.PUBLIC.ORDERS;
COPY INTO MIGRATION_DB.PUBLIC.ORDERS FROM @MIGRATION_DB.RAW.GP_STAGE/orders/
FILE_FORMAT = (TYPE = 'PARQUET');

-- APPROACH 2: MERGE (For incremental/delta loads)
MERGE INTO MIGRATION_DB.PUBLIC.ORDERS AS TGT
USING (SELECT $1:order_id::INT AS ORDER_ID, $1:amount::NUMBER AS AMOUNT
       FROM @MIGRATION_DB.RAW.GP_STAGE/orders_delta/ (FILE_FORMAT => 'PARQUET_FORMAT')) AS SRC
ON TGT.ORDER_ID = SRC.ORDER_ID
WHEN MATCHED THEN UPDATE SET TGT.AMOUNT = SRC.AMOUNT
WHEN NOT MATCHED THEN INSERT (ORDER_ID, AMOUNT) VALUES (SRC.ORDER_ID, SRC.AMOUNT);

-- APPROACH 3: DELETE + INSERT (Partition-level reload)
DELETE FROM MIGRATION_DB.PUBLIC.ORDERS WHERE ORDER_DATE BETWEEN '2024-06-01' AND '2024-06-30';
COPY INTO MIGRATION_DB.PUBLIC.ORDERS FROM @MIGRATION_DB.RAW.GP_STAGE/orders/2024/06/
FILE_FORMAT = (TYPE = 'PARQUET');
```

### 6.4 ROLLBACK STRATEGY

```sql
-- OPTION 1: TIME TRAVEL
CREATE OR REPLACE TABLE MIGRATION_DB.PUBLIC.ORDERS
CLONE MIGRATION_DB.PUBLIC.ORDERS AT (TIMESTAMP => '2024-06-01 09:59:00'::TIMESTAMP_NTZ);

-- OPTION 2: PRE-MIGRATION BACKUP (Clone before each load)
CREATE TABLE MIGRATION_DB.BACKUP.ORDERS_PRE_BATCH_001 CLONE MIGRATION_DB.PUBLIC.ORDERS;

-- OPTION 3: SWAP TABLES (Blue-Green deployment)
COPY INTO MIGRATION_DB.STAGING.ORDERS_NEW FROM @MIGRATION_DB.RAW.GP_STAGE/orders/;
-- If PASS:
ALTER TABLE MIGRATION_DB.PUBLIC.ORDERS SWAP WITH MIGRATION_DB.STAGING.ORDERS_NEW;
-- If FAIL:
DROP TABLE MIGRATION_DB.STAGING.ORDERS_NEW;
```

---

## 7. PILLAR 5: ALERTING (Notify the right people)

### 7.1 EMAIL NOTIFICATION ON FAILURE

```sql
CREATE OR REPLACE PROCEDURE MIGRATION_DB.OPS.SP_ALERT_ON_FAILURE(
    P_TABLE_NAME VARCHAR, P_ERROR_MESSAGE VARCHAR, P_SEVERITY VARCHAR
)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    IF (P_SEVERITY IN ('HIGH', 'CRITICAL')) THEN
        CALL SYSTEM$SEND_EMAIL(
            'MY_EMAIL_INT',
            'data-team@company.com',
            'MIGRATION ALERT [' || :P_SEVERITY || ']: ' || :P_TABLE_NAME,
            'Table: ' || :P_TABLE_NAME || CHR(10) ||
            'Error: ' || :P_ERROR_MESSAGE || CHR(10) ||
            'Time: ' || CURRENT_TIMESTAMP()::VARCHAR || CHR(10) ||
            'Action Required: Investigate and fix immediately.'
        );
    END IF;
    RETURN 'Alert sent for ' || :P_TABLE_NAME;
END;
$$;
```

### 7.2 ALERT ESCALATION MATRIX

| SEVERITY | WHO IS NOTIFIED | RESPONSE TIME | EXAMPLE |
|---|---|---|---|
| LOW | Slack channel only | Next business day | 5 rows rejected in Tier 4 table |
| MEDIUM | Slack + Email to migration team | 4 hours | Row count off by 0.01% in Tier 3 |
| HIGH | Email + Phone to on-call engineer | 1 hour | Any Tier 1 table failure |
| CRITICAL | Email + Phone + Escalate to Lead + PM | 30 minutes | Multiple tables failing, systemic issue |

---

## 8. COMMON ERRORS AND THEIR FIXES (Quick Reference)

| # | ERROR | FIX |
|---|---|---|
| 1 | Numeric value 'Infinity' is not recognized | Replace with NULL: `CASE WHEN amount = 'Infinity' THEN NULL` |
| 2 | Numeric value 'NaN' is not recognized | SF supports NaN for FLOAT. If target is NUMBER → replace with NULL |
| 3 | Date 'XXXX-XX-XX' is not recognized | Invalid dates in source. Clean before load or load as VARCHAR |
| 4 | String is too long and would be truncated | ALTER TABLE to increase VARCHAR length |
| 5 | Number of columns in file does not match | Fix DDL or use `MATCH_BY_COLUMN_NAME` |
| 6 | NULL result in a non-nullable column | Remove NOT NULL constraint or fix data |
| 7 | Failed to cast variant to NUMBER | Use `TRY_CAST()` or `::VARIANT` first |
| 8 | File format error: field delimiter not found | Check actual file format (TAB vs COMMA vs PIPE) |
| 9 | Max number of files exceeded | Load in batches using PATTERN or file prefix |
| 10 | Warehouse timeout / credit limit exceeded | Use larger warehouse or partition load |
| 11 | Transaction aborted due to conflict | Concurrent DML. Serialize loads or use staging tables |
| 12 | UTF-8 encoding error | Re-export with UTF-8 encoding specified |

---

## 9. PRODUCTION ERROR HANDLING ARCHITECTURE

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    ORCHESTRATION LAYER (Airflow / Control-M)             │
│                                                                          │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐            │
│  │ Extract  │──→│ Transfer │──→│   Load   │──→│ Validate │            │
│  │ (Source) │   │ (S3/GCS) │   │ (COPY IN)│   │ (DQ)     │            │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘            │
│       ▼               ▼               ▼               ▼                  │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │              ERROR HANDLING AT EACH STAGE                     │       │
│  │  IF ERROR:                                                   │       │
│  │    1. Log to ERROR_LOG table (with full context)             │       │
│  │    2. Retry up to 3 times (with backoff)                     │       │
│  │    3. If still failing → route to Dead Letter Queue          │       │
│  │    4. Alert based on severity                                │       │
│  │    5. Mark batch as FAILED in BATCH_LOG                      │       │
│  │    6. Skip to next table (don't block entire wave)           │       │
│  │    7. At end of wave → generate failure report               │       │
│  └──────────────────────────────────────────────────────────────┘       │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────┐       │
│  │              RECOVERY ACTIONS                                 │       │
│  │  After investigation:                                        │       │
│  │    1. Fix root cause (source data, type mapping, DDL)        │       │
│  │    2. TRUNCATE target table (or TIME TRAVEL restore)         │       │
│  │    3. Re-run the specific table's migration                  │       │
│  │    4. Re-run validation                                      │       │
│  │    5. Update BATCH_LOG with retry result                     │       │
│  │    6. If PASS → proceed | If FAIL again → escalate           │       │
│  └──────────────────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 10. MONITORING DASHBOARD QUERIES

```sql
-- Today's migration status:
SELECT TABLE_NAME, BATCH_STATUS, ROWS_LOADED, ROWS_REJECTED, DURATION_SECONDS, ERROR_SUMMARY
FROM MIGRATION_DB.OPS.BATCH_LOG
WHERE CREATED_AT::DATE = CURRENT_DATE()
ORDER BY CREATED_AT DESC;

-- Tables stuck in FAILED state:
SELECT TABLE_NAME, MAX(RETRY_ATTEMPT) AS MAX_ATTEMPTS, MAX(ERROR_SUMMARY) AS LAST_ERROR
FROM MIGRATION_DB.OPS.BATCH_LOG
WHERE BATCH_STATUS = 'FAILED'
GROUP BY TABLE_NAME
HAVING MAX(CREATED_AT) > DATEADD('HOUR', -24, CURRENT_TIMESTAMP());

-- Error frequency by type:
SELECT ERROR_STAGE, ERROR_CODE, LEFT(ERROR_MESSAGE, 100) AS ERROR_PATTERN,
    COUNT(*) AS OCCURRENCE_COUNT, COUNT(DISTINCT TABLE_NAME) AS TABLES_AFFECTED
FROM MIGRATION_DB.OPS.ERROR_LOG
WHERE CREATED_AT > DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY ERROR_STAGE, ERROR_CODE, ERROR_PATTERN
ORDER BY OCCURRENCE_COUNT DESC LIMIT 20;

-- Dead Letter Queue status:
SELECT SOURCE_TABLE, COUNT(*) AS TOTAL_DLQ_RECORDS,
    SUM(CASE WHEN REPROCESSED_FLAG = TRUE THEN 1 ELSE 0 END) AS REPROCESSED,
    SUM(CASE WHEN REPROCESSED_FLAG = FALSE THEN 1 ELSE 0 END) AS PENDING
FROM MIGRATION_DB.OPS.DEAD_LETTER_QUEUE
GROUP BY SOURCE_TABLE ORDER BY PENDING DESC;

-- Success rate trend by day:
SELECT CREATED_AT::DATE AS MIGRATION_DATE, COUNT(*) AS TOTAL_BATCHES,
    SUM(CASE WHEN BATCH_STATUS = 'SUCCESS' THEN 1 ELSE 0 END) AS SUCCEEDED,
    SUM(CASE WHEN BATCH_STATUS = 'FAILED' THEN 1 ELSE 0 END) AS FAILED,
    ROUND(SUM(CASE WHEN BATCH_STATUS = 'SUCCESS' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS SUCCESS_RATE
FROM MIGRATION_DB.OPS.BATCH_LOG
GROUP BY MIGRATION_DATE ORDER BY MIGRATION_DATE DESC;
```

---

## 11. INTERVIEW: HOW TO EXPLAIN ERROR HANDLING

> "In our migration project, we built a 5-pillar error handling framework:
>
> 1. **PREVENT:** Pre-flight checks before every load. Type mapping document identified 6 high-risk conversions.
>
> 2. **DETECT:** Used VALIDATION_MODE for dry runs on critical tables. ON_ERROR=ABORT for Tier 1, ON_ERROR=CONTINUE for Tier 3/4.
>
> 3. **LOG:** Central ERROR_LOG and BATCH_LOG tables captured every event. Could trace any issue back to exact source record.
>
> 4. **RECOVER:** Retry logic with 3 attempts. Dead Letter Queue for bad records. Idempotent loads (TRUNCATE+RELOAD or MERGE). Time Travel for rollback.
>
> 5. **ALERT:** Tiered escalation matrix. Low=Slack, Medium=Email, High=Phone, Critical=Escalate to lead.
>
> **Results:**
> - 6 tables out of 450 required re-migration (1.3% failure rate)
> - Average time to detect an error: < 5 minutes (automated)
> - Average time to resolve: 4 hours
> - Zero data loss incidents (DLQ caught everything)
> - Zero production incidents post go-live"

---

## 12. REAL PRODUCTION PIPELINE FAILURE STORY

**INTERVIEW QUESTION:** "Give me a real example of a production pipeline failure. What broke, how did you find it, and what changed after?"

### SITUATION:

"We were in Week 4. The DAILY_TRANSACTIONS table (Tier 1, ~200M rows) had been loaded with DUPLICATE ROWS. Row count was 200M in source but 247M in target — 47 million extra rows."

### WHAT BROKE:

The root cause was a **RETRY WITHOUT IDEMPOTENCY.**

1. 2:00 AM — Airflow triggered COPY INTO for DAILY_TRANSACTIONS
2. 2:45 AM — Warehouse AUTO-SUSPENDED (resource monitor hit credit limit)
3. COPY INTO PARTIALLY completed — 153M rows loaded, then failed
4. 3:00 AM — Airflow triggered RETRY
5. **The COPY command had `FORCE = TRUE`** (added by a developer "to be safe")
6. `FORCE = TRUE` bypasses Snowflake's built-in file dedup
7. Files 1-35 loaded TWICE: 153M (first partial) + 200M (full retry) = 47M duplicates

### HOW WE FOUND IT:

- **5:00 AM** — Automated DQ job ran row count check
- **5:01 AM** — ALERT FIRED: Source 200M | Target 247M | Diff: +47M
- **7:30 AM** — Investigated: BATCH_LOG showed 2 entries, COPY_HISTORY showed files loaded twice
- **8:00 AM** — Root cause: `FORCE=TRUE` + partial retry
- **9:00 AM** — Resolved (Time Travel restore + reload without FORCE)

### WHAT CHANGED AFTERWARDS:

1. **BANNED FORCE=TRUE** — Code review rule + CI/CD scan
2. **MADE ALL LOADS IDEMPOTENT** — TRUNCATE+RELOAD or MERGE
3. **ADDED PRE-LOAD ROW COUNT CHECK** — If already loaded today → TRUNCATE first
4. **FIXED RESOURCE MONITOR** — Increased limits, added 80% warning threshold
5. **ADDED DUPLICATE DETECTION** — GROUP BY PK HAVING COUNT>1 after every load

**Result:** Zero duplicate incidents in the remaining 4 months.

---

## 13. HOW TO ENSURE PIPELINES ARE IDEMPOTENT

**INTERVIEW QUESTION:** "How did you ensure pipelines were idempotent — safely re-runnable without duplicates?"

### WHAT IS IDEMPOTENCY?

Idempotent = Running the same operation MULTIPLE times produces the SAME result as running it ONCE.

### THE 4 PATTERNS:

### Pattern 1: TRUNCATE + RELOAD (Full table migration)

```sql
TRUNCATE TABLE MIGRATION_DB.PUBLIC.DAILY_TRANSACTIONS;
COPY INTO MIGRATION_DB.PUBLIC.DAILY_TRANSACTIONS
FROM @MIGRATION_DB.RAW.GP_STAGE/daily_transactions/
FILE_FORMAT = (TYPE = 'PARQUET') ON_ERROR = 'ABORT_STATEMENT';
```

- **Run 1 (fails):** TRUNCATE → loads 80% → fails → table has 80%
- **Run 2 (retry):** TRUNCATE → clears 80% → loads 100% → NO DUPLICATES

### Pattern 2: DELETE + INSERT by Partition

```sql
DELETE FROM MIGRATION_DB.PUBLIC.DAILY_TRANSACTIONS WHERE TXN_DATE = CURRENT_DATE();
COPY INTO MIGRATION_DB.PUBLIC.DAILY_TRANSACTIONS
FROM @MIGRATION_DB.RAW.GP_STAGE/daily_transactions/2024/06/15/
FILE_FORMAT = (TYPE = 'PARQUET') ON_ERROR = 'ABORT_STATEMENT';
```

- Only reloads today's data. Other days untouched. Safe to retry.

### Pattern 3: MERGE (Upsert)

```sql
MERGE INTO MIGRATION_DB.PUBLIC.DAILY_TRANSACTIONS AS TGT
USING (SELECT $1:txn_id::INT AS TXN_ID, $1:amount::NUMBER(10,2) AS AMOUNT,
             $1:status::VARCHAR AS STATUS, $1:txn_date::DATE AS TXN_DATE
       FROM @MIGRATION_DB.RAW.GP_STAGE/daily_transactions/delta/ (FILE_FORMAT => 'PARQUET_FF')
) AS SRC
ON TGT.TXN_ID = SRC.TXN_ID
WHEN MATCHED THEN UPDATE SET TGT.AMOUNT=SRC.AMOUNT, TGT.STATUS=SRC.STATUS
WHEN NOT MATCHED THEN INSERT (TXN_ID, AMOUNT, STATUS, TXN_DATE) 
    VALUES (SRC.TXN_ID, SRC.AMOUNT, SRC.STATUS, SRC.TXN_DATE);
```

- Run it 1 time or 100 times → same result. PK dedup is built-in.

### Pattern 4: STAGING + SWAP (Blue-Green)

```sql
CREATE TABLE IF NOT EXISTS MIGRATION_DB.STAGING.DAILY_TRANSACTIONS_NEW
LIKE MIGRATION_DB.PUBLIC.DAILY_TRANSACTIONS;

TRUNCATE TABLE MIGRATION_DB.STAGING.DAILY_TRANSACTIONS_NEW;
COPY INTO MIGRATION_DB.STAGING.DAILY_TRANSACTIONS_NEW FROM @stage ...;
-- Validate...
-- If PASS:
ALTER TABLE MIGRATION_DB.PUBLIC.DAILY_TRANSACTIONS 
SWAP WITH MIGRATION_DB.STAGING.DAILY_TRANSACTIONS_NEW;
-- If FAIL: DROP staging. Production untouched.
```

### SUMMARY: WHICH PATTERN FOR WHICH SCENARIO

| SCENARIO | PATTERN | WHY |
|---|---|---|
| Full table migration (one-time) | TRUNCATE + RELOAD | Simplest, guaranteed clean slate |
| Daily batch load (date-partitioned) | DELETE + INSERT | Only reloads today's data |
| CDC / Incremental (ongoing changes) | MERGE | Handles inserts+updates with dedup |
| Critical Tier 1 (cannot afford error) | STAGING + SWAP | Zero risk to production |
| Snowpipe (streaming) | Never use FORCE=TRUE | Built-in file tracking prevents re-loading |

---

## BONUS: ANTI-PATTERNS (What NOT to do)

- **ANTI-PATTERN 1:** Plain INSERT without dedup → retry = DOUBLE data
- **ANTI-PATTERN 2:** COPY INTO with `FORCE=TRUE` → bypasses file tracking = duplicates
- **ANTI-PATTERN 3:** No error handling in orchestrator → blind retries without checking state
- **ANTI-PATTERN 4:** Assuming COPY INTO is atomic → it's file-by-file, not all-or-nothing
- **ANTI-PATTERN 5:** Using INSERT OVERWRITE → Snowflake doesn't have this (it's Hive/Spark)

---

### HOW TO SAY IT IN THE INTERVIEW:

> "We ensured all pipelines were idempotent using 4 patterns: TRUNCATE+RELOAD for full migration, DELETE+INSERT by partition for daily loads, MERGE for CDC streams, and STAGING+SWAP for critical financial tables. The key lesson from our duplicate incident was: NEVER use FORCE=TRUE, and ALWAYS design assuming any step can fail and will be retried. After implementing these patterns, we had ZERO duplicate incidents across 450 tables over 4 months."
