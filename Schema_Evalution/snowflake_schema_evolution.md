# Snowflake Schema Evolution Handling Pipeline

A production-ready pipeline to detect, alert, and safely manage schema changes in Snowflake source tables — without breaking downstream consumers.

---

## Architecture Overview

```
┌─────────────────────┐
│   RAW_CUSTOMERS      │  ← Source table (schema may change anytime)
└────────┬────────────┘
         │ INFORMATION_SCHEMA.COLUMNS
         ▼
┌─────────────────────┐     New columns land here
│   SCHEMA_REGISTRY   │  ←  with approved = FALSE
└────────┬────────────┘
         │ CDC via Stream
         ▼
┌─────────────────────┐
│ SCHEMA_REGISTRY     │  ← Captures every INSERT (new column detected)
│      STREAM         │
└────────┬────────────┘
         │ Triggers Task B
         ▼
┌─────────────────────┐
│   SEND_SCHEMA_ALERT │  ← Emails the data engineering team
│     (Procedure)     │
└─────────────────────┘
         │
         ▼ Engineer reviews & approves
┌─────────────────────┐
│   STG_CUSTOMERS     │  ← Only approved columns appear here (explicit SELECT)
│      (View)         │
└─────────────────────┘
```

---

## Step-by-Step Implementation

---

### Step 1 — Schema Registry Table

The audit log. Every column ever seen in your source tables lives here.

```sql
CREATE OR REPLACE TABLE DEMO_DB.PUBLIC.SCHEMA_REGISTRY (
    table_name    VARCHAR        NOT NULL,
    column_name   VARCHAR        NOT NULL,
    data_type     VARCHAR        NOT NULL,
    first_seen_at TIMESTAMP      DEFAULT CURRENT_TIMESTAMP(),
    approved      BOOLEAN        DEFAULT FALSE,
    CONSTRAINT pk_schema_registry PRIMARY KEY (table_name, column_name)
);
```

> **Key design decision:** The `approved` flag is your manual gate.  
> New columns land here as `FALSE`. Nothing downstream moves until an engineer flips it to `TRUE`.

---

### Step 2 — Detection Procedure

Scans `INFORMATION_SCHEMA.COLUMNS` and inserts any column not yet in the registry.

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
      AND c.TABLE_NAME   = 'RAW_CUSTOMERS'   -- scope to your monitored tables
      AND r.column_name  IS NULL;            -- only the NEW columns

    rows_inserted := SQLROWCOUNT;

    RETURN 'Schema check complete. New columns found: ' || rows_inserted;
END;
$$;
```

**Run once to seed the registry with your baseline columns:**

```sql
CALL DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION();
```

---

### Step 3 — Stream on Schema Registry

Acts as a change-data-capture (CDC) layer. Every time the procedure inserts a new row (new column detected), the stream captures it.

```sql
-- append_only = TRUE because we only ever INSERT into the registry
CREATE OR REPLACE STREAM DEMO_DB.PUBLIC.SCHEMA_REGISTRY_STREAM
    ON TABLE DEMO_DB.PUBLIC.SCHEMA_REGISTRY
    APPEND_ONLY = TRUE
    COMMENT = 'Captures new column detections for alert pipeline';
```

**Verify the stream has data at any time:**

```sql
SELECT SYSTEM$STREAM_HAS_DATA('DEMO_DB.PUBLIC.SCHEMA_REGISTRY_STREAM');
-- Returns TRUE or FALSE
```

---

### Step 4 — Alert Procedure

Builds and sends an email using Snowflake's built-in `SYSTEM$SEND_EMAIL()` — no external webhook needed.

```sql
-- One-time setup: enable the email integration (run once per account)
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS EMAIL_INTEGRATION
    TYPE = EMAIL
    ENABLED = TRUE;
```

```sql
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

    IF (change_count > 0) THEN
        summary_line := change_count || ' new column(s) detected in RAW_CUSTOMERS. Review required before downstream propagation.';

        CALL SYSTEM$SEND_EMAIL(
            'EMAIL_INTEGRATION',
            'data-engineering@yourcompany.com',
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

### Step 5 — Two Tasks Wired Together

```
┌──────────────────────────────────────────────────┐
│  TASK A: MONITOR_SCHEMA_EVOLUTION                │
│  Schedule: every 60 minutes                      │
│  Action: CALL CHECK_SCHEMA_EVOLUTION()           │
│          → Scans INFORMATION_SCHEMA              │
│          → Inserts new columns into registry     │
└─────────────────────┬────────────────────────────┘
                      │ New row in SCHEMA_REGISTRY
                      ▼
              SCHEMA_REGISTRY_STREAM
              (has data = TRUE)
                      │
                      ▼
┌──────────────────────────────────────────────────┐
│  TASK B: NOTIFY_SCHEMA_CHANGES                   │
│  Schedule: every 5 minutes (evaluation only)     │
│  WHEN: SYSTEM$STREAM_HAS_DATA(...)               │
│  Action: CALL SEND_SCHEMA_ALERT()                │
│          → Sends email with change details       │
└──────────────────────────────────────────────────┘
```

```sql
-- Task A: runs every 60 minutes
CREATE OR REPLACE TASK DEMO_DB.PUBLIC.MONITOR_SCHEMA_EVOLUTION
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE  = '60 MINUTE'
    COMMENT   = 'Periodically scans for new columns in monitored source tables'
AS
    CALL DEMO_DB.PUBLIC.CHECK_SCHEMA_EVOLUTION();


-- Task B: fires ONLY when the stream has data
CREATE OR REPLACE TASK DEMO_DB.PUBLIC.NOTIFY_SCHEMA_CHANGES
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE  = '5 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('DEMO_DB.PUBLIC.SCHEMA_REGISTRY_STREAM')
    COMMENT   = 'Sends email alert when new columns are detected'
AS
    CALL DEMO_DB.PUBLIC.SEND_SCHEMA_ALERT();


-- Tasks are created SUSPENDED by default — resume both
ALTER TASK DEMO_DB.PUBLIC.MONITOR_SCHEMA_EVOLUTION  RESUME;
ALTER TASK DEMO_DB.PUBLIC.NOTIFY_SCHEMA_CHANGES     RESUME;
```

> **Cost note:** The `WHEN SYSTEM$STREAM_HAS_DATA(...)` clause means Task B only executes (and burns warehouse credits) when there's something in the stream. The 5-minute schedule is just the *evaluation* frequency, not the execution frequency.

---

### Step 6 — Engineer Reviews & Approves

After receiving the alert, the engineer decides what to do:

```
Alert Email Received
        │
        ├── Column IS needed downstream?
        │         │
        │         ▼  YES
        │   1. Approve in registry (approved = TRUE)
        │   2. Add column to staging model
        │
        └── Column NOT needed (PII, irrelevant)?
                  │
                  ▼  NO ACTION
            Pipeline stays unchanged.
            Registry records first_seen_at for audit.
```

```sql
-- Scenario A: column IS needed downstream

-- 1. Approve it in the registry
UPDATE DEMO_DB.PUBLIC.SCHEMA_REGISTRY
SET approved = TRUE
WHERE table_name  = 'RAW_CUSTOMERS'
  AND column_name = 'LOYALTY_TIER';

-- 2. Explicitly add it to the staging model
ALTER TABLE DEMO_DB.PUBLIC.STG_CUSTOMERS
ADD COLUMN loyalty_tier VARCHAR;


-- Scenario B: column is NOT needed (PII, irrelevant, etc.)
-- Do nothing. The staging model never touches it.
-- The registry records first_seen_at for audit purposes.
```

---

### Step 7 — Safe Staging Model

This is the wall that makes everything safe. **Never use `SELECT *`** in a model that feeds downstream consumers.

```sql
-- ✅ SAFE: explicit column list
-- New source columns are invisible until approved
CREATE OR REPLACE VIEW DEMO_DB.PUBLIC.STG_CUSTOMERS AS
SELECT
    customer_id,
    name,
    email,
    signup_date
    -- loyalty_tier intentionally omitted until reviewed and approved
FROM DEMO_DB.PUBLIC.RAW_CUSTOMERS;


-- ❌ UNSAFE: breaks when source adds any column
-- SELECT * FROM DEMO_DB.PUBLIC.RAW_CUSTOMERS;
```

---

## Why This Architecture Works

| Problem | How This Solves It |
|---|---|
| `INSERT INTO target SELECT *` breaks | Staging views use explicit columns — target schema never surprises |
| `UNION ALL` column mismatch | Each branch of the union references only named columns |
| PII leaking downstream | New sensitive columns stay invisible until engineer explicitly approves |
| 3 AM pipeline failure | Alert fires within 5–65 minutes of schema change, before downstream jobs run |
| Cost explosion from wide `SELECT *` | Only approved, needed columns are scanned |
| Silent wrong data in dashboards | No ordinal position drift — columns referenced by name, not position |

---

## Quick Reference: Full Object List

| Object | Type | Purpose |
|---|---|---|
| `SCHEMA_REGISTRY` | Table | Audit log of all columns ever seen |
| `CHECK_SCHEMA_EVOLUTION` | Procedure | Detects new columns, inserts into registry |
| `SCHEMA_REGISTRY_STREAM` | Stream | CDC layer on the registry table |
| `SEND_SCHEMA_ALERT` | Procedure | Builds and sends the email alert |
| `MONITOR_SCHEMA_EVOLUTION` | Task (60 min) | Runs detection procedure on schedule |
| `NOTIFY_SCHEMA_CHANGES` | Task (5 min eval) | Fires alert when stream has data |
| `STG_CUSTOMERS` | View | Safe staging layer with explicit column list |
| `EMAIL_INTEGRATION` | Notification Integration | Snowflake-native email delivery |
