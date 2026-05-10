# TRIGGER-BASED CDC (CHANGE DATA CAPTURE) - COMPLETE GUIDE

Trigger-based CDC uses database triggers to capture row-level changes (INSERT, UPDATE, DELETE) and write them to a separate change log table. This is one of the OLDEST and most widely used CDC methods in OLTP databases.

---

## 1. WHAT IS TRIGGER-BASED CDC?

A **DATABASE TRIGGER** is a stored procedure that automatically fires BEFORE or AFTER a DML event (INSERT, UPDATE, DELETE) on a table.

**Trigger-Based CDC** = Attaching triggers to source tables that capture every change and write it to a CDC log table.

### FLOW:

```
Application → INSERT/UPDATE/DELETE on source table
                       │
                       ▼
             TRIGGER FIRES AUTOMATICALLY
                       │
                       ▼
             Writes change record to CDC_LOG table
             (operation type, old values, new values, timestamp)
                       │
                       ▼
             CDC_LOG is consumed by ETL/ELT pipeline
             (export to S3, load to Snowflake, etc.)
```

### SUPPORTED DATABASES:

| Database | Trigger Syntax |
|---|---|
| Oracle | CREATE TRIGGER (BEFORE/AFTER, FOR EACH ROW) |
| SQL Server | CREATE TRIGGER (AFTER, INSTEAD OF) |
| PostgreSQL | CREATE TRIGGER + CREATE FUNCTION |
| MySQL | CREATE TRIGGER (BEFORE/AFTER) |
| Greenplum | CREATE TRIGGER (limited support) |

---

## 2. ORACLE EXAMPLE: TRIGGER-BASED CDC

> NOTE: This is Oracle PL/SQL syntax (NOT Snowflake SQL). Shown here for understanding how trigger CDC works at the source.

### 2.1 SOURCE TABLE (Oracle)

```sql
CREATE TABLE HR.EMPLOYEES (
    EMP_ID      NUMBER PRIMARY KEY,
    NAME        VARCHAR2(100),
    DEPARTMENT  VARCHAR2(50),
    SALARY      NUMBER(12,2),
    CITY        VARCHAR2(50),
    UPDATED_AT  TIMESTAMP DEFAULT SYSTIMESTAMP
);
```

### 2.2 CDC LOG TABLE (Oracle)

```sql
CREATE TABLE HR.EMPLOYEES_CDC_LOG (
    CDC_ID              NUMBER GENERATED ALWAYS AS IDENTITY,
    EMP_ID              NUMBER NOT NULL,
    OPERATION           VARCHAR2(1) NOT NULL,  -- 'I' = Insert, 'U' = Update, 'D' = Delete
    -- Before Image (old values)
    OLD_NAME            VARCHAR2(100),
    OLD_DEPARTMENT      VARCHAR2(50),
    OLD_SALARY          NUMBER(12,2),
    OLD_CITY            VARCHAR2(50),
    -- After Image (new values)
    NEW_NAME            VARCHAR2(100),
    NEW_DEPARTMENT      VARCHAR2(50),
    NEW_SALARY          NUMBER(12,2),
    NEW_CITY            VARCHAR2(50),
    -- Metadata
    CHANGE_TIMESTAMP    TIMESTAMP DEFAULT SYSTIMESTAMP,
    CHANGE_USER         VARCHAR2(50) DEFAULT USER,
    TRANSACTION_ID      VARCHAR2(100) DEFAULT SYS_CONTEXT('USERENV','CURRENT_SQL'),
    PROCESSED_FLAG      VARCHAR2(1) DEFAULT 'N'  -- 'N' = not yet consumed, 'Y' = consumed
);

CREATE INDEX IDX_CDC_LOG_PROCESSED ON HR.EMPLOYEES_CDC_LOG(PROCESSED_FLAG, CHANGE_TIMESTAMP);
```

### 2.3 THE TRIGGER (Oracle PL/SQL)

```sql
CREATE OR REPLACE TRIGGER HR.TRG_EMPLOYEES_CDC
AFTER INSERT OR UPDATE OR DELETE ON HR.EMPLOYEES
FOR EACH ROW
DECLARE
    v_operation VARCHAR2(1);
BEGIN
    -- Determine operation type
    IF INSERTING THEN
        v_operation := 'I';
    ELSIF UPDATING THEN
        v_operation := 'U';
    ELSIF DELETING THEN
        v_operation := 'D';
    END IF;

    -- Write to CDC log
    INSERT INTO HR.EMPLOYEES_CDC_LOG (
        EMP_ID, OPERATION,
        OLD_NAME, OLD_DEPARTMENT, OLD_SALARY, OLD_CITY,
        NEW_NAME, NEW_DEPARTMENT, NEW_SALARY, NEW_CITY
    ) VALUES (
        COALESCE(:NEW.EMP_ID, :OLD.EMP_ID),
        v_operation,
        -- Before image (NULL for INSERT)
        :OLD.NAME, :OLD.DEPARTMENT, :OLD.SALARY, :OLD.CITY,
        -- After image (NULL for DELETE)
        :NEW.NAME, :NEW.DEPARTMENT, :NEW.SALARY, :NEW.CITY
    );
END;
/
```

### 2.4 WHAT HAPPENS WHEN DML EXECUTES

```sql
-- INSERT a new employee
INSERT INTO HR.EMPLOYEES (EMP_ID, NAME, DEPARTMENT, SALARY, CITY)
VALUES (101, 'Rahul Sharma', 'Engineering', 120000, 'Bangalore');
```

**CDC_LOG captures:**

| CDC_ID | EMP_ID | OP | OLD_NAME | NEW_NAME | OLD_SALARY | NEW_SALARY | TIMESTAMP |
|---|---|---|---|---|---|---|---|
| 1 | 101 | I | NULL | Rahul Sharma | NULL | 120000 | 2024-06-01 10:00:00 |

```sql
-- UPDATE salary
UPDATE HR.EMPLOYEES SET SALARY = 140000 WHERE EMP_ID = 101;
```

**CDC_LOG captures:**

| CDC_ID | EMP_ID | OP | OLD_NAME | NEW_NAME | OLD_SALARY | NEW_SALARY | TIMESTAMP |
|---|---|---|---|---|---|---|---|
| 2 | 101 | U | Rahul Sharma | Rahul Sharma | 120000 | 140000 | 2024-06-01 14:00:00 |

```sql
-- DELETE employee
DELETE FROM HR.EMPLOYEES WHERE EMP_ID = 101;
```

**CDC_LOG captures:**

| CDC_ID | EMP_ID | OP | OLD_NAME | NEW_NAME | OLD_SALARY | NEW_SALARY | TIMESTAMP |
|---|---|---|---|---|---|---|---|
| 3 | 101 | D | Rahul Sharma | NULL | 140000 | NULL | 2024-06-01 18:00:00 |

---

## 3. SQL SERVER EXAMPLE: TRIGGER-BASED CDC

```sql
CREATE TRIGGER dbo.trg_Employees_CDC
ON dbo.Employees
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    -- Handle INSERTs
    INSERT INTO dbo.Employees_CDC_Log (EMP_ID, OPERATION, NEW_NAME, NEW_SALARY, NEW_DEPARTMENT)
    SELECT EMP_ID, 'I', NAME, SALARY, DEPARTMENT
    FROM INSERTED
    WHERE NOT EXISTS (SELECT 1 FROM DELETED WHERE DELETED.EMP_ID = INSERTED.EMP_ID);

    -- Handle DELETEs
    INSERT INTO dbo.Employees_CDC_Log (EMP_ID, OPERATION, OLD_NAME, OLD_SALARY, OLD_DEPARTMENT)
    SELECT EMP_ID, 'D', NAME, SALARY, DEPARTMENT
    FROM DELETED
    WHERE NOT EXISTS (SELECT 1 FROM INSERTED WHERE INSERTED.EMP_ID = DELETED.EMP_ID);

    -- Handle UPDATEs (row exists in both INSERTED and DELETED)
    INSERT INTO dbo.Employees_CDC_Log (EMP_ID, OPERATION, OLD_NAME, NEW_NAME, OLD_SALARY, NEW_SALARY)
    SELECT d.EMP_ID, 'U', d.NAME, i.NAME, d.SALARY, i.SALARY
    FROM DELETED d
    INNER JOIN INSERTED i ON d.EMP_ID = i.EMP_ID;
END;
GO
```

---

## 4. POSTGRESQL EXAMPLE: TRIGGER-BASED CDC

PostgreSQL uses trigger FUNCTIONS (not inline logic):

```sql
-- Step 1: Create the trigger function
CREATE OR REPLACE FUNCTION fn_employees_cdc()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO employees_cdc_log (emp_id, operation, new_name, new_salary)
        VALUES (NEW.emp_id, 'I', NEW.name, NEW.salary);
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO employees_cdc_log (emp_id, operation, old_name, new_name, old_salary, new_salary)
        VALUES (OLD.emp_id, 'U', OLD.name, NEW.name, OLD.salary, NEW.salary);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO employees_cdc_log (emp_id, operation, old_name, old_salary)
        VALUES (OLD.emp_id, 'D', OLD.name, OLD.salary);
        RETURN OLD;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Step 2: Attach trigger to table
CREATE TRIGGER trg_employees_cdc
AFTER INSERT OR UPDATE OR DELETE ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_employees_cdc();
```

---

## 5. PROS (ADVANTAGES) OF TRIGGER-BASED CDC

| # | Advantage | Details |
|---|---|---|
| 1 | **Captures ALL DML operations** | INSERT, UPDATE, DELETE - nothing is missed. Unlike time-based CDC which cannot detect deletes. |
| 2 | **Before and After images** | `:OLD` gives you the previous value, `:NEW` gives you the new value. You know exactly what changed (useful for audit). |
| 3 | **Real-time capture** | Trigger fires immediately with the DML statement. No polling delay. Change is recorded in the SAME TRANSACTION as the source DML. |
| 4 | **No special database features required** | Works on ANY database version that supports triggers. No need for LogMiner, supplemental logging, replication slots. No extra licenses. |
| 5 | **Fine-grained control** | You choose exactly which columns to track. You can add conditional logic (only capture if salary > 100000). You can enrich with metadata (user, timestamp, session info). |
| 6 | **Simple to understand** | SQL-based, no external tools needed. Easy to debug (just query the CDC log table). No Kafka, no Debezium, no infrastructure. |
| 7 | **Transaction-consistent** | CDC record is written in the SAME transaction as the DML. If the DML rolls back, the CDC record also rolls back. No orphan CDC records. |
| 8 | **Database-agnostic pattern** | Same concept works on Oracle, SQL Server, PostgreSQL, MySQL. Portable knowledge across platforms. |
| 9 | **Works with any target** | CDC log table can be exported to S3, Kafka, Snowflake, anywhere. No vendor lock-in on the consumption side. |

---

## 6. CONS (DISADVANTAGES) OF TRIGGER-BASED CDC

| # | Disadvantage | Details |
|---|---|---|
| 1 | **Performance impact on source database** | Every INSERT/UPDATE/DELETE now does DOUBLE the work. Original DML + trigger INSERT into CDC log. Increases transaction latency by 20-100%. Row-level locks held longer. |
| 2 | **Scalability issues** | High-volume OLTP tables (10,000+ TPS) become bottlenecked. CDC log table grows rapidly. Index maintenance on CDC log adds overhead. Bulk operations are extremely slow. |
| 3 | **Maintenance burden** | Trigger must be updated when source table schema changes. Adding a column to source = must ALTER trigger. Multiple triggers on same table can conflict. Debugging is hard (silent failures). |
| 4 | **No DDL capture** | Triggers only fire on DML (INSERT/UPDATE/DELETE). Cannot capture ALTER TABLE, DROP TABLE, TRUNCATE. TRUNCATE bypasses triggers entirely (data loss in CDC). |
| 5 | **Ordering challenges** | Multiple triggers on same table: execution order is not always guaranteed. Nested triggers are hard to reason about. Recursive trigger calls can cause infinite loops. |
| 6 | **Disabled during bulk operations** | Many DBAs disable triggers during bulk loads for performance. Data loaded while triggers are disabled = MISSED CHANGES. |
| 7 | **CDC log table management** | Log table grows infinitely if not managed. Need cleanup/archival process. If cleanup is too aggressive = data loss. If cleanup is too slow = storage bloat. |
| 8 | **Cannot capture direct log writes** | SQL*Loader DIRECT PATH = bypasses triggers. SQL Server BULK INSERT with FIRE_TRIGGERS = OFF = bypasses triggers. Any tool that writes directly to data files = invisible to triggers. |
| 9 | **Tight coupling** | Trigger is tightly coupled to the source table. Source team changes schema → trigger breaks → CDC stops. No isolation between source workload and CDC workload. |
| 10 | **Replication conflicts** | In active-active replication setups, triggers can fire on replicated DML, causing duplicate CDC records. Need special handling to avoid trigger cascading in replicas. |

---

## 7. HOW TO OVERCOME THE DISADVANTAGES

### 7.1 OVERCOMING: Performance Impact

**PROBLEM:** Trigger adds latency to every DML operation.

#### Solution A: Minimize Trigger Logic

Keep trigger as lightweight as possible. Only capture the columns you actually need. Avoid complex logic, joins, or function calls inside triggers.

```sql
-- BAD: Heavy trigger with joins and function calls
CREATE OR REPLACE TRIGGER HR.TRG_HEAVY_CDC
AFTER UPDATE ON HR.EMPLOYEES
FOR EACH ROW
BEGIN
    -- Don't do this: calling functions inside trigger
    INSERT INTO HR.EMPLOYEES_CDC_LOG (...)
    VALUES (..., get_department_name(:NEW.DEPT_ID), calculate_tax(:NEW.SALARY));
END;

-- GOOD: Lightweight trigger - just capture raw values
CREATE OR REPLACE TRIGGER HR.TRG_LIGHT_CDC
AFTER UPDATE ON HR.EMPLOYEES
FOR EACH ROW
BEGIN
    INSERT INTO HR.EMPLOYEES_CDC_LOG (EMP_ID, OPERATION, OLD_SALARY, NEW_SALARY, CHANGE_TS)
    VALUES (:OLD.EMP_ID, 'U', :OLD.SALARY, :NEW.SALARY, SYSTIMESTAMP);
END;
```

#### Solution B: Conditional Triggers (Only fire when specific columns change)

```sql
-- Oracle: Only capture when SALARY or DEPARTMENT actually changes
CREATE OR REPLACE TRIGGER HR.TRG_CONDITIONAL_CDC
AFTER UPDATE ON HR.EMPLOYEES
FOR EACH ROW
WHEN (OLD.SALARY != NEW.SALARY OR OLD.DEPARTMENT != NEW.DEPARTMENT)
BEGIN
    INSERT INTO HR.EMPLOYEES_CDC_LOG (EMP_ID, OPERATION, OLD_SALARY, NEW_SALARY)
    VALUES (:OLD.EMP_ID, 'U', :OLD.SALARY, :NEW.SALARY);
END;

-- SQL Server: Check IF UPDATE(column)
CREATE TRIGGER dbo.trg_conditional
ON dbo.Employees
AFTER UPDATE
AS
BEGIN
    IF UPDATE(SALARY) OR UPDATE(DEPARTMENT)
    BEGIN
        INSERT INTO CDC_LOG (...) SELECT ... FROM INSERTED JOIN DELETED ...
    END
END;
```

#### Solution C: Use UNLOGGED / NOLOGGING CDC Table (Reduce WAL overhead)

```sql
-- PostgreSQL: UNLOGGED table for CDC log (faster writes, no WAL)
CREATE UNLOGGED TABLE employees_cdc_log (...);
-- WARNING: Data lost on crash. Only use if you have another safety net.

-- Oracle: NOLOGGING on CDC log table
ALTER TABLE HR.EMPLOYEES_CDC_LOG NOLOGGING;
-- WARNING: Not recoverable from archive logs.
```

---

### 7.2 OVERCOMING: Scalability Issues

**PROBLEM:** CDC log grows infinitely, high TPS overwhelms trigger.

#### Solution A: Partitioned CDC Log Table (Oracle/PostgreSQL)

```sql
-- Oracle: Partition by day for easy cleanup
CREATE TABLE HR.EMPLOYEES_CDC_LOG (
    CDC_ID NUMBER GENERATED ALWAYS AS IDENTITY,
    ...
    CHANGE_TIMESTAMP TIMESTAMP DEFAULT SYSTIMESTAMP
)
PARTITION BY RANGE (CHANGE_TIMESTAMP) (
    PARTITION p_2024_06 VALUES LESS THAN (TIMESTAMP '2024-07-01 00:00:00'),
    PARTITION p_2024_07 VALUES LESS THAN (TIMESTAMP '2024-08-01 00:00:00'),
    PARTITION p_max VALUES LESS THAN (MAXVALUE)
);

-- Drop old partitions after consumption (instant, no row-by-row delete)
ALTER TABLE HR.EMPLOYEES_CDC_LOG DROP PARTITION p_2024_06;
```

#### Solution B: Asynchronous CDC Pattern (Queue-based)

```sql
-- Instead of heavy INSERT in trigger, push to a lightweight queue
-- Oracle Advanced Queuing example:
CREATE OR REPLACE TRIGGER HR.TRG_ASYNC_CDC
AFTER INSERT OR UPDATE OR DELETE ON HR.EMPLOYEES
FOR EACH ROW
BEGIN
    DBMS_AQ.ENQUEUE(
        queue_name => 'HR.CDC_QUEUE',
        message_properties => ...,
        payload => CDC_MESSAGE_TYPE(:OLD.EMP_ID, :NEW.EMP_ID, ...)
    );
END;
-- A separate consumer process dequeues and writes to CDC log asynchronously
```

#### Solution C: Batch Cleanup with Processed Flag

```sql
-- Mark records as consumed, then batch delete
UPDATE HR.EMPLOYEES_CDC_LOG SET PROCESSED_FLAG = 'Y'
WHERE CDC_ID <= :last_consumed_id;

-- Nightly cleanup
DELETE FROM HR.EMPLOYEES_CDC_LOG
WHERE PROCESSED_FLAG = 'Y'
AND CHANGE_TIMESTAMP < SYSTIMESTAMP - INTERVAL '7' DAY;
```

---

### 7.3 OVERCOMING: Maintenance Burden (Schema Changes)

**PROBLEM:** Adding column to source table requires trigger modification.

#### Solution A: Generic Trigger with JSON/VARIANT Payload

```sql
-- PostgreSQL approach: capture entire row as JSON
-- This trigger NEVER needs modification when columns are added/removed!
CREATE OR REPLACE FUNCTION fn_generic_cdc()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO generic_cdc_log (
        table_name, operation, old_row, new_row, change_ts
    ) VALUES (
        TG_TABLE_NAME,
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN row_to_json(OLD) ELSE NULL END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN row_to_json(NEW) ELSE NULL END,
        NOW()
    );
    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;
```

#### Solution B: Code Generation (Auto-generate triggers from metadata)

```sql
-- Script that reads INFORMATION_SCHEMA and generates trigger DDL
-- Run this after every ALTER TABLE on source:

SELECT 'CREATE OR REPLACE TRIGGER ...' ||
       STRING_AGG(':OLD.' || COLUMN_NAME || ', :NEW.' || COLUMN_NAME, ', ')
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'EMPLOYEES';

-- This approach auto-regenerates the trigger whenever schema changes
```

---

### 7.4 OVERCOMING: TRUNCATE Bypasses Triggers

**PROBLEM:** TRUNCATE TABLE does not fire row-level triggers.

#### Solution A: Revoke TRUNCATE Privilege

```sql
-- Prevent accidental truncates
REVOKE DELETE, TRUNCATE ON HR.EMPLOYEES FROM app_user;
-- Force use of DELETE (which fires triggers)
```

#### Solution B: DDL Trigger (Oracle/SQL Server)

```sql
-- Oracle: System-level trigger to catch TRUNCATE
CREATE OR REPLACE TRIGGER SYS.TRG_CATCH_TRUNCATE
BEFORE TRUNCATE ON DATABASE
BEGIN
    INSERT INTO DBA_AUDIT.DDL_LOG (EVENT, OBJECT_NAME, EVENT_TS, USERNAME)
    VALUES ('TRUNCATE', ORA_DICT_OBJ_NAME, SYSTIMESTAMP, ORA_LOGIN_USER);
END;

-- SQL Server: DDL trigger
CREATE TRIGGER trg_catch_truncate
ON DATABASE
FOR DDL_TABLE_EVENTS
AS
BEGIN
    INSERT INTO audit.ddl_changes (event_data)
    VALUES (EVENTDATA());
END;
```

#### Solution C: Replace TRUNCATE with DELETE in application code

```sql
-- DELETE FROM employees; (fires triggers for each row)
-- Slower, but captures all changes
```

---

### 7.5 OVERCOMING: Bulk Load Bypass

**PROBLEM:** Bulk loaders (SQL*Loader DIRECT, BULK INSERT) skip triggers.

#### Solution A: Use Conventional Path Loading (slower but fires triggers)

```sql
-- Oracle SQL*Loader: use CONVENTIONAL path (not DIRECT)
-- sqlldr control=load.ctl DIRECT=FALSE

-- SQL Server: BULK INSERT with FIRE_TRIGGERS
BULK INSERT dbo.Employees
FROM 'C:\data\employees.csv'
WITH (FIRE_TRIGGERS);
```

#### Solution B: Post-Load Reconciliation

```sql
-- After bulk load, compare source vs target to find missing CDC records
-- Then generate synthetic CDC records for the gaps

SELECT s.EMP_ID
FROM HR.EMPLOYEES s
LEFT JOIN HR.EMPLOYEES_CDC_LOG c ON s.EMP_ID = c.EMP_ID
    AND c.CHANGE_TIMESTAMP > :bulk_load_start_time
WHERE c.EMP_ID IS NULL;
```

---

### 7.6 OVERCOMING: CDC Log Table Growth

**PROBLEM:** Log table grows indefinitely.

#### Solution A: Time-based retention with partitioning (shown above)

#### Solution B: Watermark-based cleanup

```sql
-- Consumer tracks "last consumed CDC_ID"
-- Cleanup job deletes everything below the watermark

DELETE FROM HR.EMPLOYEES_CDC_LOG
WHERE CDC_ID < (SELECT last_consumed_id FROM CDC_WATERMARKS WHERE table_name = 'EMPLOYEES')
AND CHANGE_TIMESTAMP < SYSTIMESTAMP - INTERVAL '24' HOUR;
```

#### Solution C: Move to archive table before delete (for compliance)

```sql
INSERT INTO HR.EMPLOYEES_CDC_ARCHIVE
SELECT * FROM HR.EMPLOYEES_CDC_LOG
WHERE PROCESSED_FLAG = 'Y' AND CHANGE_TIMESTAMP < SYSTIMESTAMP - INTERVAL '7' DAY;

DELETE FROM HR.EMPLOYEES_CDC_LOG
WHERE PROCESSED_FLAG = 'Y' AND CHANGE_TIMESTAMP < SYSTIMESTAMP - INTERVAL '7' DAY;
```

---

## 8. COMPLETE PRODUCTION EXAMPLE: ORACLE → SNOWFLAKE (Trigger CDC)

### 8.1 ORACLE SIDE: Source table + Trigger + CDC Log

(As shown above in sections 2.1 - 2.3)
- `HR.EMPLOYEES` (source table)
- `HR.EMPLOYEES_CDC_LOG` (change log table)
- `HR.TRG_EMPLOYEES_CDC` (trigger that captures changes)

### 8.2 EXPORT PROCESS: CDC Log → S3 (Scheduled Job)

A scheduled job (cron / Oracle DBMS_SCHEDULER / Airflow) runs every 5 minutes:

1. SELECT unprocessed records from CDC log
2. Export to CSV/Parquet file
3. Upload to S3 bucket
4. Mark records as processed

```python
# Python pseudo-code:
rows = oracle.execute("SELECT * FROM HR.EMPLOYEES_CDC_LOG WHERE PROCESSED_FLAG = 'N' ORDER BY CDC_ID")
write_parquet(rows, f"s3://cdc-bucket/employees/batch_{timestamp}.parquet")
oracle.execute("UPDATE HR.EMPLOYEES_CDC_LOG SET PROCESSED_FLAG = 'Y' WHERE CDC_ID <= :max_id")
oracle.commit()
```

### 8.3 SNOWFLAKE SIDE: Landing + Processing

```sql
-- Create database and schemas
CREATE DATABASE IF NOT EXISTS TRIGGER_CDC_DEMO;
CREATE SCHEMA IF NOT EXISTS TRIGGER_CDC_DEMO.RAW;
CREATE SCHEMA IF NOT EXISTS TRIGGER_CDC_DEMO.DW;

-- External stage pointing to S3 where CDC files land
CREATE OR REPLACE STAGE TRIGGER_CDC_DEMO.RAW.CDC_STAGE
    URL = 's3://cdc-bucket/employees/'
    FILE_FORMAT = (TYPE = 'PARQUET');

-- Landing table for CDC records
CREATE OR REPLACE TABLE TRIGGER_CDC_DEMO.RAW.EMPLOYEES_CDC (
    CDC_ID INT,
    EMP_ID INT,
    OPERATION VARCHAR(1),
    OLD_NAME VARCHAR(100),
    OLD_DEPARTMENT VARCHAR(50),
    OLD_SALARY DECIMAL(12,2),
    OLD_CITY VARCHAR(50),
    NEW_NAME VARCHAR(100),
    NEW_DEPARTMENT VARCHAR(50),
    NEW_SALARY DECIMAL(12,2),
    NEW_CITY VARCHAR(50),
    CHANGE_TIMESTAMP TIMESTAMP_NTZ,
    CHANGE_USER VARCHAR(50),
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Target table (current state)
CREATE OR REPLACE TABLE TRIGGER_CDC_DEMO.DW.EMPLOYEES (
    EMP_ID INT PRIMARY KEY,
    NAME VARCHAR(100),
    DEPARTMENT VARCHAR(50),
    SALARY DECIMAL(12,2),
    CITY VARCHAR(50),
    LAST_OPERATION VARCHAR(1),
    LAST_CHANGE_TS TIMESTAMP_NTZ,
    DW_UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Audit/history table (all changes)
CREATE OR REPLACE TABLE TRIGGER_CDC_DEMO.DW.EMPLOYEES_HISTORY (
    HISTORY_ID INT AUTOINCREMENT,
    EMP_ID INT,
    OPERATION VARCHAR(1),
    OLD_NAME VARCHAR(100),
    NEW_NAME VARCHAR(100),
    OLD_SALARY DECIMAL(12,2),
    NEW_SALARY DECIMAL(12,2),
    OLD_DEPARTMENT VARCHAR(50),
    NEW_DEPARTMENT VARCHAR(50),
    CHANGE_TIMESTAMP TIMESTAMP_NTZ,
    CHANGE_USER VARCHAR(50),
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### 8.4 SIMULATE CDC DATA

```sql
-- Simulate trigger-captured CDC records arriving from Oracle
INSERT INTO TRIGGER_CDC_DEMO.RAW.EMPLOYEES_CDC
    (CDC_ID, EMP_ID, OPERATION, OLD_NAME, OLD_DEPARTMENT, OLD_SALARY, OLD_CITY,
     NEW_NAME, NEW_DEPARTMENT, NEW_SALARY, NEW_CITY, CHANGE_TIMESTAMP, CHANGE_USER)
VALUES
    -- INSERT: New employee Rahul
    (1, 101, 'I', NULL, NULL, NULL, NULL,
     'Rahul Sharma', 'Engineering', 120000, 'Bangalore', '2024-06-01 10:00:00', 'APP_USER'),

    -- INSERT: New employee Priya
    (2, 102, 'I', NULL, NULL, NULL, NULL,
     'Priya Patel', 'Marketing', 95000, 'Mumbai', '2024-06-01 10:05:00', 'APP_USER'),

    -- INSERT: New employee Amit
    (3, 103, 'I', NULL, NULL, NULL, NULL,
     'Amit Kumar', 'Finance', 110000, 'Delhi', '2024-06-01 10:10:00', 'APP_USER'),

    -- UPDATE: Rahul gets a raise
    (4, 101, 'U', 'Rahul Sharma', 'Engineering', 120000, 'Bangalore',
     'Rahul Sharma', 'Engineering', 140000, 'Bangalore', '2024-06-01 14:00:00', 'HR_ADMIN'),

    -- UPDATE: Priya changes department
    (5, 102, 'U', 'Priya Patel', 'Marketing', 95000, 'Mumbai',
     'Priya Patel', 'Product', 105000, 'Mumbai', '2024-06-01 15:00:00', 'HR_ADMIN'),

    -- DELETE: Amit leaves the company
    (6, 103, 'D', 'Amit Kumar', 'Finance', 110000, 'Delhi',
     NULL, NULL, NULL, NULL, '2024-06-02 09:00:00', 'HR_ADMIN'),

    -- UPDATE: Rahul transfers to Hyderabad
    (7, 101, 'U', 'Rahul Sharma', 'Engineering', 140000, 'Bangalore',
     'Rahul Sharma', 'Engineering', 140000, 'Hyderabad', '2024-06-02 11:00:00', 'HR_ADMIN');

-- View the CDC records
SELECT * FROM TRIGGER_CDC_DEMO.RAW.EMPLOYEES_CDC ORDER BY CDC_ID;
```

### 8.5 APPLY CDC TO TARGET (MERGE Statement)

```sql
-- Apply the latest state of each employee to the target table
MERGE INTO TRIGGER_CDC_DEMO.DW.EMPLOYEES AS TGT
USING (
    SELECT
        EMP_ID,
        OPERATION,
        COALESCE(NEW_NAME, OLD_NAME) AS NAME,
        COALESCE(NEW_DEPARTMENT, OLD_DEPARTMENT) AS DEPARTMENT,
        COALESCE(NEW_SALARY, OLD_SALARY) AS SALARY,
        COALESCE(NEW_CITY, OLD_CITY) AS CITY,
        CHANGE_TIMESTAMP
    FROM TRIGGER_CDC_DEMO.RAW.EMPLOYEES_CDC
    QUALIFY ROW_NUMBER() OVER (PARTITION BY EMP_ID ORDER BY CHANGE_TIMESTAMP DESC, CDC_ID DESC) = 1
) AS SRC
ON TGT.EMP_ID = SRC.EMP_ID
WHEN MATCHED AND SRC.OPERATION = 'D'
    THEN DELETE
WHEN MATCHED AND SRC.OPERATION IN ('U', 'I')
    THEN UPDATE SET
        TGT.NAME = SRC.NAME,
        TGT.DEPARTMENT = SRC.DEPARTMENT,
        TGT.SALARY = SRC.SALARY,
        TGT.CITY = SRC.CITY,
        TGT.LAST_OPERATION = SRC.OPERATION,
        TGT.LAST_CHANGE_TS = SRC.CHANGE_TIMESTAMP,
        TGT.DW_UPDATED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED AND SRC.OPERATION IN ('I', 'U')
    THEN INSERT (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, LAST_OPERATION, LAST_CHANGE_TS)
    VALUES (SRC.EMP_ID, SRC.NAME, SRC.DEPARTMENT, SRC.SALARY, SRC.CITY, SRC.OPERATION, SRC.CHANGE_TIMESTAMP);

-- Verify: Should show Rahul (Hyderabad) and Priya (Product). Amit deleted.
SELECT * FROM TRIGGER_CDC_DEMO.DW.EMPLOYEES ORDER BY EMP_ID;
```

**EXPECTED RESULT:**
- ORDER_ID=101: Rahul Sharma, Engineering, 140000, Hyderabad
- ORDER_ID=102: Priya Patel, Product, 105000, Mumbai
- Amit (103) does NOT exist (was deleted)

### 8.6 POPULATE HISTORY TABLE (Full Audit Trail)

```sql
INSERT INTO TRIGGER_CDC_DEMO.DW.EMPLOYEES_HISTORY
    (EMP_ID, OPERATION, OLD_NAME, NEW_NAME, OLD_SALARY, NEW_SALARY,
     OLD_DEPARTMENT, NEW_DEPARTMENT, CHANGE_TIMESTAMP, CHANGE_USER)
SELECT
    EMP_ID, OPERATION, OLD_NAME, NEW_NAME, OLD_SALARY, NEW_SALARY,
    OLD_DEPARTMENT, NEW_DEPARTMENT, CHANGE_TIMESTAMP, CHANGE_USER
FROM TRIGGER_CDC_DEMO.RAW.EMPLOYEES_CDC
ORDER BY CDC_ID;

-- Full audit trail of every change
SELECT * FROM TRIGGER_CDC_DEMO.DW.EMPLOYEES_HISTORY ORDER BY CHANGE_TIMESTAMP;
```

**RESULT:** Complete history of every change:

| EMP_ID | OPERATION | OLD_NAME | NEW_NAME | OLD_SALARY | NEW_SALARY | TIMESTAMP |
|---|---|---|---|---|---|---|
| 101 | I | NULL | Rahul Sharma | NULL | 120000 | 2024-06-01 10:00 |
| 102 | I | NULL | Priya Patel | NULL | 95000 | 2024-06-01 10:05 |
| 103 | I | NULL | Amit Kumar | NULL | 110000 | 2024-06-01 10:10 |
| 101 | U | Rahul Sharma | Rahul Sharma | 120000 | 140000 | 2024-06-01 14:00 |
| 102 | U | Priya Patel | Priya Patel | 95000 | 105000 | 2024-06-01 15:00 |
| 103 | D | Amit Kumar | NULL | 110000 | NULL | 2024-06-02 09:00 |
| 101 | U | Rahul Sharma | Rahul Sharma | 140000 | 140000 | 2024-06-02 11:00 |

---

## 9. COMPARISON: TRIGGER CDC vs OTHER CDC METHODS

| CRITERIA | TRIGGER CDC | LOG-BASED CDC | TIME-BASED CDC |
|---|---|---|---|
| Captures INSERTs | ✓ | ✓ | ✓ |
| Captures UPDATEs | ✓ | ✓ | ✓ |
| Captures DELETEs | ✓ | ✓ | ✗ |
| Before/After images | ✓ | ✓ | ✗ |
| Source DB impact | HIGH | LOW | MEDIUM |
| Setup complexity | LOW | HIGH | LOW |
| Infrastructure | None extra | Kafka+tools | None extra |
| Handles bulk load | ✗ (bypassed) | ✓ | ✓ |
| Handles TRUNCATE | ✗ | ✓ | ✗ |
| Latency | Real-time | Near real-time | Minutes/Hours |
| Scalability | LOW-MEDIUM | HIGH | HIGH |
| Cost | $ | $$$$ | $ |
| Maintenance | MEDIUM | LOW (once set) | LOW |
| Best for | Low-med volume tables | High volume enterprise | Batch ETL, non-critical |

---

## 10. WHEN TO USE TRIGGER-BASED CDC

### USE TRIGGER CDC WHEN:
- ✓ Low to medium transaction volume (< 5000 TPS on the table)
- ✓ Limited budget (no Kafka, no GoldenGate licenses)
- ✓ Need to capture DELETEs (time-based can't do this)
- ✓ Need before/after images for audit compliance
- ✓ Source database doesn't expose transaction logs
- ✓ Quick proof-of-concept or small project
- ✓ Team has SQL skills but not streaming/Kafka expertise
- ✓ Regulatory requirement for change auditing

### DO NOT USE TRIGGER CDC WHEN:
- ✗ High-volume OLTP tables (> 10,000 TPS) - use log-based instead
- ✗ Bulk loads are common (triggers get bypassed)
- ✗ Source table has frequent schema changes (trigger maintenance hell)
- ✗ Sub-second latency to target is required (trigger adds to transaction time)
- ✗ Source DBA team refuses triggers (common in enterprise - "no triggers" policy)
- ✗ Multiple consumers need the same change stream (use Kafka instead)

---

## 11. MIGRATION PATH: FROM TRIGGER CDC TO LOG-BASED CDC

Many teams start with trigger-based CDC and later migrate to log-based. Here's the migration strategy:

### PHASE 1: Trigger CDC (Day 1 - quick win)
- Implement triggers on source tables
- Export CDC log → S3 → Snowflake
- Works immediately, low infrastructure

### PHASE 2: Dual-Run (Transition period)
- Set up Debezium/DMS reading transaction logs
- Run BOTH trigger CDC and log-based CDC in parallel
- Compare outputs to validate log-based captures everything

### PHASE 3: Log-Based Only (Steady state)
- Disable triggers on source (improves source performance)
- Drop CDC log table (frees source storage)
- Full reliance on log-based CDC

**This gives you:**
- Immediate value (triggers work today)
- Zero-downtime migration (parallel run validates correctness)
- Better long-term performance (log-based has lower source impact)

---

```sql
-- CLEANUP (optional)
-- DROP DATABASE TRIGGER_CDC_DEMO;
```
