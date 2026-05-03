# SCD Type 1 & Type 2 — Complete Step-by-Step Guide

> Slowly Changing Dimensions with **SQL**, **MERGE**, and **Streams** in Snowflake

---

## Setup

```sql
CREATE OR REPLACE DATABASE SCD_PRACTICE_DB;
USE DATABASE SCD_PRACTICE_DB;
CREATE OR REPLACE SCHEMA SCD_SCHEMA;
USE SCHEMA SCD_SCHEMA;
```

---

# SCD TYPE 1 — Overwrite (No History Kept)

---

## Step 1: Create Source and Target Tables

```sql
CREATE OR REPLACE TABLE customer_source (
    customer_id   INT,
    customer_name VARCHAR(100),
    email         VARCHAR(200),
    city          VARCHAR(100),
    phone         VARCHAR(20)
);

CREATE OR REPLACE TABLE customer_dim_scd1 (
    customer_id   INT,
    customer_name VARCHAR(100),
    email         VARCHAR(200),
    city          VARCHAR(100),
    phone         VARCHAR(20)
);
```

---

## Step 2: DAY 1 — Initial Data Arrives in Source

```sql
INSERT INTO customer_source VALUES
    (101, 'Rohit Sharma', 'rohit@gmail.com',  'Mumbai', '9876543210'),
    (102, 'Virat Kohli',  'virat@gmail.com',  'Delhi',  '9876543211'),
    (103, 'MS Dhoni',     'dhoni@gmail.com',   'Ranchi', '9876543212');
```

| customer_id | customer_name | email | city | phone |
|---|---|---|---|---|
| 101 | Rohit Sharma | rohit@gmail.com | Mumbai | 9876543210 |
| 102 | Virat Kohli | virat@gmail.com | Delhi | 9876543211 |
| 103 | MS Dhoni | dhoni@gmail.com | Ranchi | 9876543212 |

---

## Step 3: DAY 1 — First Load into Target (Simple INSERT)

```sql
INSERT INTO customer_dim_scd1
SELECT * FROM customer_source;
```

Target now has the same 3 rows. No MERGE needed for initial load.

---

## Step 4: DAY 2 — New Data Arrives in Source (With Changes!)

```sql
TRUNCATE TABLE customer_source;

INSERT INTO customer_source VALUES
    (101, 'Rohit Sharma',   'rohit@gmail.com',      'Mumbai',    '9876543210'),
    (102, 'Virat Kohli',    'virat_new@yahoo.com',  'Delhi',     '9876543211'),
    (103, 'MS Dhoni',       'dhoni@gmail.com',       'Chennai',   '9876543212'),
    (104, 'Jasprit Bumrah', 'bumrah@gmail.com',      'Ahmedabad', '9876543213'),
    (105, 'KL Rahul',       'rahul@gmail.com',       'Bangalore', '9876543214');
```

### What Changed?

| customer_id | Change |
|---|---|
| 101 | No change |
| 102 | email changed: `virat@gmail.com` → `virat_new@yahoo.com` |
| 103 | city changed: `Ranchi` → `Chennai` |
| 104 | **NEW** customer |
| 105 | **NEW** customer |

---

## Step 5: Target BEFORE Merge (Still Has Day 1 Data)

| customer_id | customer_name | email | city | phone |
|---|---|---|---|---|
| 101 | Rohit Sharma | rohit@gmail.com | Mumbai | 9876543210 |
| 102 | Virat Kohli | virat@gmail.com | Delhi | 9876543211 |
| 103 | MS Dhoni | dhoni@gmail.com | Ranchi | 9876543212 |

---

## Step 6: Solution — Using MERGE

```sql
MERGE INTO customer_dim_scd1 T1
USING (
    SELECT * FROM customer_source
    QUALIFY ROW_NUMBER() OVER (PARTITION BY CUSTOMER_ID ORDER BY (SELECT NULL)) <= 1
) T2
ON T1.CUSTOMER_ID = T2.CUSTOMER_ID
WHEN MATCHED THEN UPDATE SET
    T1.CUSTOMER_NAME = T2.CUSTOMER_NAME,
    T1.EMAIL = T2.EMAIL,
    T1.CITY = T2.CITY,
    T1.PHONE = T2.PHONE
WHEN NOT MATCHED THEN INSERT (CUSTOMER_ID, CUSTOMER_NAME, EMAIL, CITY, PHONE)
    VALUES (T2.CUSTOMER_ID, T2.CUSTOMER_NAME, T2.EMAIL, T2.CITY, T2.PHONE);
```

> **Note:** The `QUALIFY ROW_NUMBER()` deduplicates source data to prevent the "Duplicate row detected during DML action" error.

> **Note:** Snowflake does NOT support `WHEN NOT MATCHED BY SOURCE`. Deletes must be handled separately (see Step 9).

---

## Step 7: Solution — Using Normal SQL Statements

```sql
INSERT INTO customer_dim_scd1
SELECT * FROM customer_source
WHERE CUSTOMER_ID NOT IN (SELECT CUSTOMER_ID FROM customer_dim_scd1);

UPDATE customer_dim_scd1 T1
SET
    T1.CUSTOMER_NAME = T2.CUSTOMER_NAME,
    T1.EMAIL = T2.EMAIL,
    T1.CITY = T2.CITY,
    T1.PHONE = T2.PHONE
FROM customer_source T2
WHERE T1.CUSTOMER_ID = T2.CUSTOMER_ID;
```

> **Note:** Snowflake UPDATE syntax is `UPDATE...SET...FROM...WHERE` (not `UPDATE...USING...ON`).

---

## Step 8: Expected Output After Day 2 Merge

| customer_id | customer_name | email | city | phone | Status |
|---|---|---|---|---|---|
| 101 | Rohit Sharma | rohit@gmail.com | Mumbai | 9876543210 | NO CHANGE |
| 102 | Virat Kohli | virat_new@yahoo.com | Delhi | 9876543211 | email OVERWRITTEN |
| 103 | MS Dhoni | dhoni@gmail.com | Chennai | 9876543212 | city OVERWRITTEN |
| 104 | Jasprit Bumrah | bumrah@gmail.com | Ahmedabad | 9876543213 | NEW ROW |
| 105 | KL Rahul | rahul@gmail.com | Bangalore | 9876543214 | NEW ROW |

```sql
SELECT * FROM customer_dim_scd1 ORDER BY customer_id;
```

---

## Step 9: DAY 3 — Handling DELETES in SCD Type 1

```sql
TRUNCATE TABLE customer_source;

INSERT INTO customer_source VALUES
    (101, 'Rohit Sharma',   'rohit@gmail.com',      'Mumbai',    '9876543210'),
    (102, 'Virat Kohli',    'virat_new@yahoo.com',  'Bangalore', '9876543211'),
    (104, 'Jasprit Bumrah', 'bumrah@gmail.com',      'Ahmedabad', '9876543213'),
    (105, 'KL Rahul',       'rahul@gmail.com',       'Bangalore', '9876543214');
```

### What Changed?

| customer_id | Change |
|---|---|
| 101 | No change |
| 102 | city changed: `Delhi` → `Bangalore` |
| 103 | **DELETED** (missing from source) |
| 104 | No change |
| 105 | No change |

### Solution: MERGE + Separate DELETE

```sql
MERGE INTO customer_dim_scd1 T1
USING customer_source T2
ON T1.CUSTOMER_ID = T2.CUSTOMER_ID
WHEN MATCHED THEN UPDATE SET
    T1.CUSTOMER_NAME = T2.CUSTOMER_NAME,
    T1.EMAIL = T2.EMAIL,
    T1.CITY = T2.CITY,
    T1.PHONE = T2.PHONE
WHEN NOT MATCHED THEN INSERT (CUSTOMER_ID, CUSTOMER_NAME, EMAIL, CITY, PHONE)
    VALUES (T2.CUSTOMER_ID, T2.CUSTOMER_NAME, T2.EMAIL, T2.CITY, T2.PHONE);

DELETE FROM customer_dim_scd1
WHERE CUSTOMER_ID NOT IN (SELECT CUSTOMER_ID FROM customer_source);
```

### Expected Output After Day 3

| customer_id | customer_name | email | city | phone | Status |
|---|---|---|---|---|---|
| 101 | Rohit Sharma | rohit@gmail.com | Mumbai | 9876543210 | NO CHANGE |
| 102 | Virat Kohli | virat_new@yahoo.com | Bangalore | 9876543211 | city OVERWRITTEN |
| 104 | Jasprit Bumrah | bumrah@gmail.com | Ahmedabad | 9876543213 | NO CHANGE |
| 105 | KL Rahul | rahul@gmail.com | Bangalore | 9876543214 | NO CHANGE |
| | | | | | 103 MS Dhoni **DELETED** |

```sql
SELECT * FROM customer_dim_scd1 ORDER BY customer_id;
```

---

---

# SCD TYPE 2 — Keep Full History (Expire Old Row, Add New Row)

---

## Step 1: Create Source and Target Tables

```sql
CREATE OR REPLACE TABLE employee_source (
    emp_id      INT,
    emp_name    VARCHAR(100),
    department  VARCHAR(100),
    salary      DECIMAL(10,2),
    location    VARCHAR(100)
);

CREATE OR REPLACE TABLE employee_dim_scd2 (
    surrogate_key  INT AUTOINCREMENT,
    emp_id         INT,
    emp_name       VARCHAR(100),
    department     VARCHAR(100),
    salary         DECIMAL(10,2),
    location       VARCHAR(100),
    is_current     BOOLEAN DEFAULT TRUE,
    effective_from DATE,
    effective_to   DATE DEFAULT '9999-12-31'::DATE
);
```

---

## Step 2: DAY 1 — Initial Data Arrives in Source

```sql
INSERT INTO employee_source VALUES
    (201, 'Ananya Gupta', 'Analytics',    1500000.00, 'Bangalore'),
    (202, 'Rahul Verma',  'DevOps',       1500000.00, 'Hyderabad'),
    (203, 'Priya Singh',  'Data Science', 2000000.00, 'Mumbai');
```

---

## Step 3: DAY 1 — First Load into Target

```sql
INSERT INTO employee_dim_scd2 (emp_id, emp_name, department, salary, location, is_current, effective_from, effective_to)
SELECT emp_id, emp_name, department, salary, location, TRUE, '2025-01-01', '9999-12-31'
FROM employee_source;
```

| surrogate_key | emp_id | emp_name | department | salary | location | is_current | effective_from | effective_to |
|---|---|---|---|---|---|---|---|---|
| 1 | 201 | Ananya Gupta | Analytics | 1500000.00 | Bangalore | TRUE | 2025-01-01 | 9999-12-31 |
| 2 | 202 | Rahul Verma | DevOps | 1500000.00 | Hyderabad | TRUE | 2025-01-01 | 9999-12-31 |
| 3 | 203 | Priya Singh | Data Science | 2000000.00 | Mumbai | TRUE | 2025-01-01 | 9999-12-31 |

---

## Step 4: DAY 2 — New Data Arrives in Source (With Changes!)

```sql
TRUNCATE TABLE employee_source;

INSERT INTO employee_source VALUES
    (201, 'Ananya Gupta', 'Data Engineering', 1800000.00, 'Bangalore'),
    (202, 'Rahul Verma',  'DevOps',           1500000.00, 'Hyderabad'),
    (203, 'Priya Singh',  'Data Science',     2200000.00, 'Mumbai'),
    (204, 'Arjun Reddy',  'Backend',          1600000.00, 'Chennai');
```

### What Changed?

| emp_id | Change |
|---|---|
| 201 | dept changed: `Analytics` → `Data Engineering`, salary: `15L` → `18L` |
| 202 | No change |
| 203 | salary changed: `20L` → `22L` |
| 204 | **NEW** employee |

---

## Step 5: Solution — SCD Type 2 MERGE (Two-Step Process)

SCD Type 2 needs **two operations** because Snowflake's MERGE can't UPDATE and INSERT for the same matched row:

### Operation 1: MERGE — Expire Old Rows + Insert New Employees

```sql
MERGE INTO employee_dim_scd2 T1
USING employee_source T2
ON T1.emp_id = T2.emp_id AND T1.is_current = TRUE

WHEN MATCHED AND (T1.department != T2.department OR T1.salary != T2.salary OR T1.location != T2.location)
THEN UPDATE SET
    T1.is_current = FALSE,
    T1.effective_to = CURRENT_DATE() - 1

WHEN NOT MATCHED THEN INSERT (emp_id, emp_name, department, salary, location, is_current, effective_from, effective_to)
    VALUES (T2.emp_id, T2.emp_name, T2.department, T2.salary, T2.location, TRUE, CURRENT_DATE(), '9999-12-31'::DATE);
```

### Operation 2: INSERT — Add New Version Rows for Expired Records

```sql
INSERT INTO employee_dim_scd2 (emp_id, emp_name, department, salary, location, is_current, effective_from, effective_to)
SELECT T2.emp_id, T2.emp_name, T2.department, T2.salary, T2.location, TRUE, CURRENT_DATE(), '9999-12-31'::DATE
FROM employee_source T2
INNER JOIN employee_dim_scd2 T1
    ON T1.emp_id = T2.emp_id
    AND T1.is_current = FALSE
    AND T1.effective_to = CURRENT_DATE() - 1;
```

> **Why two steps?** MERGE can either UPDATE or INSERT a matched row — not both. So we first expire the old row (UPDATE), then insert the new version (INSERT) by joining on the just-expired records.

---

## Step 6: Expected Output After Day 2

| surrogate_key | emp_id | emp_name | department | salary | location | is_current | effective_from | effective_to | Status |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 201 | Ananya Gupta | Analytics | 1500000.00 | Bangalore | FALSE | 2025-01-01 | 2026-05-02 | EXPIRED |
| 2 | 202 | Rahul Verma | DevOps | 1500000.00 | Hyderabad | TRUE | 2025-01-01 | 9999-12-31 | NO CHANGE |
| 3 | 203 | Priya Singh | Data Science | 2000000.00 | Mumbai | FALSE | 2025-03-01 | 2026-05-02 | EXPIRED |
| 4 | 201 | Ananya Gupta | Data Engineering | 1800000.00 | Bangalore | TRUE | 2026-05-03 | 9999-12-31 | NEW VERSION |
| 5 | 203 | Priya Singh | Data Science | 2200000.00 | Mumbai | TRUE | 2026-05-03 | 9999-12-31 | NEW VERSION |
| 6 | 204 | Arjun Reddy | Backend | 1600000.00 | Chennai | TRUE | 2026-05-03 | 9999-12-31 | NEW EMPLOYEE |

```sql
SELECT * FROM employee_dim_scd2 ORDER BY emp_id, effective_from;

SELECT * FROM employee_dim_scd2 WHERE emp_id = 201 ORDER BY effective_from;

SELECT * FROM employee_dim_scd2 WHERE is_current = TRUE ORDER BY emp_id;
```

---

## Step 7: DAY 3 — Handling DELETES in SCD Type 2 (Soft Delete vs Hard Delete)

### Hard Delete vs Soft Delete

| | Hard Delete | Soft Delete |
|---|---|---|
| What happens | `DELETE FROM` table | `UPDATE is_current = FALSE` + set `effective_to` |
| History | **GONE forever** | **PRESERVED** |
| Recovery | Not possible | Always possible |
| Audit/Compliance | Fails | Passes |
| SCD Type 2 | **NEVER** recommended | **ALWAYS** recommended |

### New Source Data (emp 202 Rahul Verma is DELETED)

```sql
TRUNCATE TABLE employee_source;

INSERT INTO employee_source VALUES
    (201, 'Ananya Gupta', 'Data Engineering', 1800000.00, 'Bangalore'),
    (203, 'Priya Singh',  'Data Science',     2200000.00, 'Mumbai'),
    (204, 'Arjun Reddy',  'Backend',          1600000.00, 'Chennai');
```

| emp_id | Change |
|---|---|
| 201 | No change |
| 202 | **DELETED** (missing from source) |
| 203 | No change |
| 204 | No change |

### Hard Delete (NOT Recommended)

```sql
DELETE FROM employee_dim_scd2
WHERE emp_id NOT IN (SELECT emp_id FROM employee_source)
AND is_current = TRUE;
```

> History is LOST forever. Don't do this in production.

### Soft Delete (RECOMMENDED)

```sql
UPDATE employee_dim_scd2 T1
SET
    IS_CURRENT = FALSE,
    EFFECTIVE_TO = CURRENT_DATE() - 1
FROM employee_dim_scd2 T1_ref
LEFT JOIN employee_source T2 ON T1_ref.EMP_ID = T2.EMP_ID
WHERE T1.surrogate_key = T1_ref.surrogate_key
  AND T2.EMP_ID IS NULL
  AND T1.IS_CURRENT = TRUE;
```

> Rahul Verma's row is **expired** (is_current = FALSE) but **still in the table**. History preserved!

### Expected Output After Soft Delete

**Current records (is_current = TRUE):**

| emp_id | emp_name | department | is_current | effective_from | effective_to |
|---|---|---|---|---|---|
| 201 | Ananya Gupta | Data Engineering | TRUE | 2026-05-03 | 9999-12-31 |
| 203 | Priya Singh | Data Science | TRUE | 2026-05-03 | 9999-12-31 |
| 204 | Arjun Reddy | Backend | TRUE | 2026-05-03 | 9999-12-31 |

**Rahul's expired record (still in table):**

| emp_id | emp_name | department | is_current | effective_from | effective_to |
|---|---|---|---|---|---|
| 202 | Rahul Verma | DevOps | FALSE | 2025-01-01 | 2026-05-02 |

```sql
SELECT * FROM employee_dim_scd2 WHERE is_current = TRUE ORDER BY emp_id;

SELECT * FROM employee_dim_scd2 WHERE emp_id = 202 ORDER BY effective_from;
```

---

---

# SCD Using Streams + MERGE (Automated CDC)

> Streams automatically capture INSERT, UPDATE, DELETE changes — no need to compare source vs target manually.

---

## How Streams Track Changes

| METADATA$ACTION | METADATA$ISUPDATE | Meaning |
|---|---|---|
| INSERT | FALSE | New row inserted |
| INSERT | TRUE | Updated row (new values) |
| DELETE | TRUE | Updated row (old values) |
| DELETE | FALSE | Row was deleted |

> **Key insight:** An UPDATE appears as two rows in the stream — a DELETE (old values) + INSERT (new values), both with `METADATA$ISUPDATE = TRUE`.

---

## SCD Type 1 with Streams

### Step 1: Create Tables and Stream

```sql
CREATE OR REPLACE TABLE customer_source_stream (
    customer_id   INT,
    customer_name VARCHAR(100),
    email         VARCHAR(200),
    city          VARCHAR(100),
    phone         VARCHAR(20)
);

CREATE OR REPLACE TABLE customer_dim_scd1_stream (
    customer_id   INT,
    customer_name VARCHAR(100),
    email         VARCHAR(200),
    city          VARCHAR(100),
    phone         VARCHAR(20)
);

CREATE OR REPLACE STREAM customer_changes
ON TABLE customer_source_stream;
```

### Step 2: DAY 1 — Load Initial Data

```sql
INSERT INTO customer_source_stream VALUES
    (101, 'Rohit Sharma', 'rohit@gmail.com',  'Mumbai', '9876543210'),
    (102, 'Virat Kohli',  'virat@gmail.com',  'Delhi',  '9876543211'),
    (103, 'MS Dhoni',     'dhoni@gmail.com',   'Ranchi', '9876543212');
```

### Step 3: Check What the Stream Captured

```sql
SELECT *, METADATA$ACTION, METADATA$ISUPDATE FROM customer_changes;
```

| customer_id | customer_name | METADATA$ACTION | METADATA$ISUPDATE |
|---|---|---|---|
| 101 | Rohit Sharma | INSERT | FALSE |
| 102 | Virat Kohli | INSERT | FALSE |
| 103 | MS Dhoni | INSERT | FALSE |

### Step 4: Consume Stream with MERGE (Initial Load)

```sql
MERGE INTO customer_dim_scd1_stream T1
USING (
    SELECT * FROM customer_changes
    WHERE METADATA$ACTION = 'INSERT'
) T2
ON T1.CUSTOMER_ID = T2.CUSTOMER_ID
WHEN MATCHED THEN UPDATE SET
    T1.CUSTOMER_NAME = T2.CUSTOMER_NAME,
    T1.EMAIL = T2.EMAIL,
    T1.CITY = T2.CITY,
    T1.PHONE = T2.PHONE
WHEN NOT MATCHED THEN INSERT (CUSTOMER_ID, CUSTOMER_NAME, EMAIL, CITY, PHONE)
    VALUES (T2.CUSTOMER_ID, T2.CUSTOMER_NAME, T2.EMAIL, T2.CITY, T2.PHONE);
```

> **Important:** Once you consume the stream (use it in a DML), the stream resets. It will only show new changes going forward.

### Step 5: DAY 2 — Make Changes on Source (UPDATE + INSERT + DELETE)

```sql
UPDATE customer_source_stream SET email = 'virat_new@yahoo.com' WHERE customer_id = 102;

UPDATE customer_source_stream SET city = 'Chennai' WHERE customer_id = 103;

INSERT INTO customer_source_stream VALUES
    (104, 'Jasprit Bumrah', 'bumrah@gmail.com', 'Ahmedabad', '9876543213');

DELETE FROM customer_source_stream WHERE customer_id = 101;
```

### Step 6: Check What the Stream Captured

```sql
SELECT *, METADATA$ACTION, METADATA$ISUPDATE FROM customer_changes;
```

| customer_id | customer_name | email | city | METADATA$ACTION | METADATA$ISUPDATE | Meaning |
|---|---|---|---|---|---|---|
| 102 | Virat Kohli | virat_new@yahoo.com | Delhi | INSERT | TRUE | Updated (new values) |
| 103 | MS Dhoni | dhoni@gmail.com | Chennai | INSERT | TRUE | Updated (new values) |
| 104 | Jasprit Bumrah | bumrah@gmail.com | Ahmedabad | INSERT | FALSE | New row |
| 101 | Rohit Sharma | rohit@gmail.com | Mumbai | DELETE | FALSE | Deleted |

### Step 7: Consume Stream — Handle All 3 Operations

```sql
MERGE INTO customer_dim_scd1_stream T1
USING (
    SELECT * FROM customer_changes
    WHERE METADATA$ACTION = 'INSERT'
) T2
ON T1.CUSTOMER_ID = T2.CUSTOMER_ID
WHEN MATCHED THEN UPDATE SET
    T1.CUSTOMER_NAME = T2.CUSTOMER_NAME,
    T1.EMAIL = T2.EMAIL,
    T1.CITY = T2.CITY,
    T1.PHONE = T2.PHONE
WHEN NOT MATCHED THEN INSERT (CUSTOMER_ID, CUSTOMER_NAME, EMAIL, CITY, PHONE)
    VALUES (T2.CUSTOMER_ID, T2.CUSTOMER_NAME, T2.EMAIL, T2.CITY, T2.PHONE);
```

> **Wait — what about deletes?** The MERGE above only processes `METADATA$ACTION = 'INSERT'` rows (which covers both new inserts AND the "new value" side of updates). But the stream has already been consumed by this MERGE! So we need to handle deletes **in the same transaction** or use a **stored procedure**.

### Better Approach: Stored Procedure to Handle All Operations

```sql
CREATE OR REPLACE PROCEDURE scd1_stream_merge()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Step 1: Create a temp table to hold stream data (stream is consumed once)
    CREATE OR REPLACE TEMPORARY TABLE temp_changes AS
    SELECT *, METADATA$ACTION, METADATA$ISUPDATE
    FROM customer_changes;

    -- Step 2: Handle INSERTS and UPDATES (ACTION = INSERT covers both)
    MERGE INTO customer_dim_scd1_stream T1
    USING (
        SELECT * FROM temp_changes WHERE METADATA$ACTION = 'INSERT'
    ) T2
    ON T1.CUSTOMER_ID = T2.CUSTOMER_ID
    WHEN MATCHED THEN UPDATE SET
        T1.CUSTOMER_NAME = T2.CUSTOMER_NAME,
        T1.EMAIL = T2.EMAIL,
        T1.CITY = T2.CITY,
        T1.PHONE = T2.PHONE
    WHEN NOT MATCHED THEN INSERT (CUSTOMER_ID, CUSTOMER_NAME, EMAIL, CITY, PHONE)
        VALUES (T2.CUSTOMER_ID, T2.CUSTOMER_NAME, T2.EMAIL, T2.CITY, T2.PHONE);

    -- Step 3: Handle DELETES (ACTION = DELETE and ISUPDATE = FALSE)
    DELETE FROM customer_dim_scd1_stream
    WHERE CUSTOMER_ID IN (
        SELECT CUSTOMER_ID FROM temp_changes
        WHERE METADATA$ACTION = 'DELETE' AND METADATA$ISUPDATE = FALSE
    );

    DROP TABLE temp_changes;
    RETURN 'SCD Type 1 merge completed';
END;
$$;

CALL scd1_stream_merge();
```

### Automate with a Task

```sql
CREATE OR REPLACE TASK scd1_task
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
WHEN
    SYSTEM$STREAM_HAS_DATA('customer_changes')
AS
    CALL scd1_stream_merge();

ALTER TASK scd1_task RESUME;
```

---

## SCD Type 2 with Streams

### Step 1: Create Tables and Stream

```sql
CREATE OR REPLACE TABLE employee_source_stream (
    emp_id      INT,
    emp_name    VARCHAR(100),
    department  VARCHAR(100),
    salary      DECIMAL(10,2),
    location    VARCHAR(100)
);

CREATE OR REPLACE TABLE employee_dim_scd2_stream (
    surrogate_key  INT AUTOINCREMENT,
    emp_id         INT,
    emp_name       VARCHAR(100),
    department     VARCHAR(100),
    salary         DECIMAL(10,2),
    location       VARCHAR(100),
    is_current     BOOLEAN DEFAULT TRUE,
    effective_from DATE,
    effective_to   DATE DEFAULT '9999-12-31'::DATE
);

CREATE OR REPLACE STREAM employee_changes
ON TABLE employee_source_stream;
```

### Step 2: DAY 1 — Load Initial Data

```sql
INSERT INTO employee_source_stream VALUES
    (201, 'Ananya Gupta', 'Analytics',    1500000.00, 'Bangalore'),
    (202, 'Rahul Verma',  'DevOps',       1500000.00, 'Hyderabad'),
    (203, 'Priya Singh',  'Data Science', 2000000.00, 'Mumbai');
```

### Step 3: Consume Stream — Initial Load

```sql
INSERT INTO employee_dim_scd2_stream (emp_id, emp_name, department, salary, location, is_current, effective_from, effective_to)
SELECT emp_id, emp_name, department, salary, location, TRUE, CURRENT_DATE(), '9999-12-31'::DATE
FROM employee_changes
WHERE METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE = FALSE;
```

### Step 4: DAY 2 — Make Changes on Source

```sql
UPDATE employee_source_stream SET department = 'Data Engineering', salary = 1800000.00 WHERE emp_id = 201;

UPDATE employee_source_stream SET salary = 2200000.00 WHERE emp_id = 203;

INSERT INTO employee_source_stream VALUES (204, 'Arjun Reddy', 'Backend', 1600000.00, 'Chennai');

DELETE FROM employee_source_stream WHERE emp_id = 202;
```

### Step 5: Check What the Stream Captured

```sql
SELECT *, METADATA$ACTION, METADATA$ISUPDATE FROM employee_changes;
```

| emp_id | emp_name | department | salary | METADATA$ACTION | METADATA$ISUPDATE | Meaning |
|---|---|---|---|---|---|---|
| 201 | Ananya Gupta | Data Engineering | 1800000.00 | INSERT | TRUE | Updated (new values) |
| 203 | Priya Singh | Data Science | 2200000.00 | INSERT | TRUE | Updated (new values) |
| 204 | Arjun Reddy | Backend | 1600000.00 | INSERT | FALSE | New employee |
| 202 | Rahul Verma | DevOps | 1500000.00 | DELETE | FALSE | Deleted |

### Step 6: Stored Procedure — Handle All Operations for SCD Type 2

```sql
CREATE OR REPLACE PROCEDURE scd2_stream_merge()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Step 1: Capture stream data into temp table (stream consumed once)
    CREATE OR REPLACE TEMPORARY TABLE temp_emp_changes AS
    SELECT *, METADATA$ACTION, METADATA$ISUPDATE
    FROM employee_changes;

    -- Step 2: EXPIRE old rows for UPDATEs (ACTION=INSERT, ISUPDATE=TRUE means "new values of update")
    UPDATE employee_dim_scd2_stream T1
    SET
        IS_CURRENT = FALSE,
        EFFECTIVE_TO = CURRENT_DATE() - 1
    FROM temp_emp_changes T2
    WHERE T1.EMP_ID = T2.EMP_ID
      AND T1.IS_CURRENT = TRUE
      AND T2.METADATA$ACTION = 'INSERT'
      AND T2.METADATA$ISUPDATE = TRUE;

    -- Step 3: INSERT new version rows for UPDATEs
    INSERT INTO employee_dim_scd2_stream (emp_id, emp_name, department, salary, location, is_current, effective_from, effective_to)
    SELECT emp_id, emp_name, department, salary, location, TRUE, CURRENT_DATE(), '9999-12-31'::DATE
    FROM temp_emp_changes
    WHERE METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE = TRUE;

    -- Step 4: INSERT brand new employees
    INSERT INTO employee_dim_scd2_stream (emp_id, emp_name, department, salary, location, is_current, effective_from, effective_to)
    SELECT emp_id, emp_name, department, salary, location, TRUE, CURRENT_DATE(), '9999-12-31'::DATE
    FROM temp_emp_changes
    WHERE METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE = FALSE;

    -- Step 5: SOFT DELETE — expire rows for DELETEs
    UPDATE employee_dim_scd2_stream T1
    SET
        IS_CURRENT = FALSE,
        EFFECTIVE_TO = CURRENT_DATE() - 1
    FROM temp_emp_changes T2
    WHERE T1.EMP_ID = T2.EMP_ID
      AND T1.IS_CURRENT = TRUE
      AND T2.METADATA$ACTION = 'DELETE'
      AND T2.METADATA$ISUPDATE = FALSE;

    DROP TABLE temp_emp_changes;
    RETURN 'SCD Type 2 merge completed';
END;
$$;

CALL scd2_stream_merge();
```

### Step 7: Verify

```sql
SELECT * FROM employee_dim_scd2_stream ORDER BY emp_id, effective_from;

SELECT * FROM employee_dim_scd2_stream WHERE is_current = TRUE ORDER BY emp_id;

SELECT * FROM employee_dim_scd2_stream WHERE emp_id = 202 ORDER BY effective_from;
```

### Automate with a Task

```sql
CREATE OR REPLACE TASK scd2_task
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
WHEN
    SYSTEM$STREAM_HAS_DATA('employee_changes')
AS
    CALL scd2_stream_merge();

ALTER TASK scd2_task RESUME;
```

---

## Summary: Stream METADATA Cheat Sheet

| What Happened | METADATA$ACTION | METADATA$ISUPDATE | SCD1 Action | SCD2 Action |
|---|---|---|---|---|
| **New row** | INSERT | FALSE | INSERT into target | INSERT with is_current=TRUE |
| **Row updated** | INSERT | TRUE | UPDATE target row | Expire old + INSERT new version |
| **Row updated** (old val) | DELETE | TRUE | (ignore) | (ignore — old values) |
| **Row deleted** | DELETE | FALSE | DELETE from target | Soft delete (expire row) |

---

## Cleanup

```sql
-- DROP DATABASE IF EXISTS SCD_PRACTICE_DB;
```
