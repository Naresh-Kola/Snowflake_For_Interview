Now I have everything I need. Let me build a comprehensive, visually rich explanation of schema evolution handling in Snowflake.Here's the complete, production-ready implementation of that pipeline.

---

## The full SQL implementation

### Step 1 — Schema Registry table

This is the audit log. Every column ever seen in your source tables lives here.

```sql
CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.SCHEMA_REGISTRY (
    table_name   VARCHAR        NOT NULL,
    column_name  VARCHAR        NOT NULL,
    data_type    VARCHAR        NOT NULL,
    first_seen_at TIMESTAMP     DEFAULT CURRENT_TIMESTAMP(),
    approved     BOOLEAN        DEFAULT FALSE,
    CONSTRAINT pk_schema_registry PRIMARY KEY (table_name, column_name)
);
```

The `approved` flag is critical — it's your manual gate. New columns land here as `FALSE`. Nothing downstream moves until an engineer flips it to `TRUE`.

---

### Step 2 — Detection procedure (corrected)

Your original logic was right. Here's the fixed, production version with proper error handling:

```sql
CREATE OR REPLACE PROCEDURE DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    rows_inserted INTEGER DEFAULT 0;
BEGIN
    -- Find any column in INFORMATION_SCHEMA that isn't in the registry yet
    INSERT INTO DEMO_DB.PUBLIC.SCHEMA_REGISTRY (table_name, column_name, data_type)
    SELECT
        c.TABLE_NAME,
        c.COLUMN_NAME,
        c.DATA_TYPE
    FROM INFORMATION_SCHEMA.COLUMNS c
    LEFT JOIN DEMO_DB.PUBLIC.SCHEMA_REGISTRY r
        ON  c.TABLE_NAME  = r.table_name
        AND c.COLUMN_NAME = r.column_name
    WHERE c.TABLE_SCHEMA = 'PUBLIC'
      AND c.TABLE_NAME   = 'RAW_CUSTOMERS'  -- scope to your monitored tables
      AND r.column_name  IS NULL;           -- only the NEW columns

    rows_inserted := SQLROWCOUNT;

    RETURN 'Schema check complete. New columns found: ' || rows_inserted;
END;
$$;
```

Run it manually once to seed the registry with your baseline columns:

```sql
CALL DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION();
```

---

### Step 3 — Stream on SCHEMA_REGISTRY

The stream acts as a change-data-capture layer. Every time the procedure inserts a new row (new column detected), the stream captures it.

```sql
-- append_only = TRUE because we only ever INSERT into the registry, never UPDATE/DELETE
CREATE OR REPLACE STREAM DEMO_DB.PUBLIC.SCHEMA_REGISTRY_STREAM
    ON TABLE DEMO_DB.PUBLIC.SCHEMA_REGISTRY
    APPEND_ONLY = TRUE
    COMMENT = 'Captures new column detections for alert pipeline';
```

You can verify the stream has data at any time:

```sql
SELECT SYSTEM$STREAM_HAS_DATA('DEMO_DB.PUBLIC.SCHEMA_REGISTRY_STREAM');
-- Returns TRUE/FALSE
```

---

### Step 4 — Alert procedure (builds and sends the email)

Snowflake's built-in `SYSTEM$SEND_EMAIL()` handles delivery — no external webhook needed.

```sql
-- One-time setup: enable the email integration (run once per account)
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS EMAIL_INTEGRATION
    TYPE = EMAIL
    ENABLED = TRUE;

-- The procedure that builds and sends the alert
CREATE OR REPLACE PROCEDURE DEMO_DB.PUBLIC.SEND_SCHEMA_ALERT()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    email_body    VARCHAR DEFAULT '';
    change_count  INTEGER DEFAULT 0;
    summary_line  VARCHAR;
BEGIN
    -- Build the email body from the stream contents
    -- We aggregate all pending changes into one message
    SELECT
        COUNT(*),
        LISTAGG(
            '• Table: ' || table_name ||
            ' | Column: ' || column_name ||
            ' | Type: '   || data_type  ||
            ' | First seen: ' || TO_VARCHAR(first_seen_at, 'YYYY-MM-DD HH24:MI:SS UTC'),
            '\n'
        ) WITHIN GROUP (ORDER BY first_seen_at)
    INTO :change_count, :email_body
    FROM DEMO_DB.PUBLIC.SCHEMA_REGISTRY_STREAM
    WHERE METADATA$ACTION = 'INSERT';

    -- Only send if there's actually something to report
    IF (change_count > 0) THEN
        summary_line := change_count || ' new column(s) detected in RAW_CUSTOMERS. Review required before downstream propagation.';

        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION',
            'data-engineering@yourcompany.com',       -- recipient(s), comma-separated
            '[SNOWFLAKE ALERT] Schema Evolution Detected — ' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYY-MM-DD'),
            summary_line || '\n\nChanges:\n' || email_body ||
            '\n\nAction required:\n' ||
            '1. Review each column above.\n' ||
            '2. If needed downstream: add to staging model + set approved = TRUE.\n' ||
            '3. If not needed: no action required — pipeline stays unchanged.\n\n' ||
            'Update approval status:\n' ||
            'UPDATE DEMO_DB.PUBLIC.SCHEMA_REGISTRY SET approved = TRUE\n' ||
            'WHERE table_name = ''RAW_CUSTOMERS'' AND column_name = ''<column_name>'';'
        );

        RETURN 'Alert sent for ' || change_count || ' change(s).';
    ELSE
        RETURN 'No new changes to report.';
    END IF;
END;
$$;
```

---

### Step 5 — Two tasks wired together

You need two tasks: one that runs the detection procedure on a schedule, and one triggered by the stream that fires the alert.

```sql
-- Task A: runs every 60 minutes, calls the detection procedure
CREATE OR REPLACE TASK DEMO_DB.PUBLIC.MONITOR_SCHEMA_EVOLUTION
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE  = '60 MINUTE'
    COMMENT   = 'Periodically scans for new columns in monitored source tables'
AS
    CALL DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION();


-- Task B: fires ONLY when the stream has data (stream-triggered task)
-- This is the key Snowflake pattern — no polling, no wasted credits
CREATE OR REPLACE TASK DEMO_DB.PUBLIC.NOTIFY_SCHEMA_CHANGES
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE  = '5 MINUTE'    -- checks every 5 min whether stream has data
    WHEN SYSTEM$STREAM_HAS_DATA('DEMO_DB.PUBLIC.SCHEMA_REGISTRY_STREAM')
    COMMENT   = 'Sends email alert when new columns are detected'
AS
    CALL DEMO_DB.PUBLIC.SEND_SCHEMA_ALERT();


-- Tasks are created SUSPENDED by default — resume both
ALTER TASK DEMO_DB.PUBLIC.MONITOR_SCHEMA_EVOLUTION  RESUME;
ALTER TASK DEMO_DB.PUBLIC.NOTIFY_SCHEMA_CHANGES     RESUME;
```

The `WHEN SYSTEM$STREAM_HAS_DATA(...)` clause is the key pattern — Task B only actually executes (and burns warehouse credits) when there's something in the stream. The 5-minute schedule is just the evaluation frequency, not the execution frequency.

---

### Step 6 — Engineer approves a column

After receiving the alert, the engineer decides what to do:

```sql
-- Scenario A: column IS needed downstream
-- 1. Approve it in the registry
UPDATE DEMO_DB.PUBLIC.SCHEMA_REGISTRY
SET approved = TRUE
WHERE table_name  = 'RAW_CUSTOMERS'
  AND column_name = 'LOYALTY_TIER';

-- 2. Explicitly add it to the staging model
-- Your staging view/table is safe because it uses explicit columns, not SELECT *
ALTER TABLE DEMO_DB.PUBLIC.STG_CUSTOMERS
ADD COLUMN loyalty_tier VARCHAR;

-- Scenario B: column is NOT needed (PII, irrelevant, etc.)
-- Do nothing. The staging model never touches it.
-- The registry records first_seen_at for audit purposes.
```

---

### How your staging model should look

This is the wall that makes everything safe. Never `SELECT *` in a model that feeds downstream consumers:

```sql
-- SAFE: explicit column list — new source columns are invisible until approved
CREATE OR REPLACE VIEW DEMO_DB.PUBLIC.STG_CUSTOMERS AS
SELECT
    customer_id,
    name,
    email,
    signup_date
    -- loyalty_tier intentionally omitted until reviewed and approved
FROM DEMO_DB.PUBLIC.RAW_CUSTOMERS;

-- UNSAFE: breaks when source adds any column
-- SELECT * FROM DEMO_DB.PUBLIC.RAW_CUSTOMERS;
```

---

## Why this architecture works

| Problem | How this solves it |
|---|---|
| `INSERT INTO target SELECT *` breaks | Staging views use explicit columns — target schema never surprises |
| `UNION ALL` column mismatch | Each branch of the union references only named columns |
| PII leaking downstream | New sensitive columns stay invisible until engineer explicitly approves |
| 3 AM pipeline failure | Alert fires within 5–65 minutes of schema change, before downstream jobs run |
| Cost explosion from wide SELECT * | Only approved, needed columns are scanned |
| Silent wrong data in dashboards | No ordinal position drift — columns referenced by name, not position |

The stream-triggered task is the elegant piece here — Snowflake's `WHEN SYSTEM$STREAM_HAS_DATA()` means Task B is essentially free when nothing changes, and fires within one evaluation cycle when it does.
