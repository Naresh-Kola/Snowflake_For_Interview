# Oracle GoldenGate to Snowflake — Complete Guide

> A full conversation covering what Oracle GoldenGate is, how it replicates changes from Oracle DB to Snowflake via S3, with step-by-step SQL code, data examples, and concept clarifications.

---

## Table of Contents

1. [What is Oracle GoldenGate?](#1-what-is-oracle-goldengate)
2. [How Does It Work? (Step by Step)](#2-how-does-it-work-step-by-step)
3. [Real-World Use Cases](#3-real-world-use-cases)
4. [Oracle to Snowflake — Full Replication Process](#4-oracle-to-snowflake--full-replication-process)
   - [Step 1 — Oracle Setup & EMPLOYEE Table](#step-1--oracle-setup--employee-table)
   - [Step 2 — Make 3 Changes: INSERT, UPDATE, DELETE](#step-2--make-3-changes-insert-update-delete)
   - [Step 3 — GoldenGate EXTRACT](#step-3--goldengate-extract)
   - [Step 4 — GoldenGate Data Pump](#step-4--goldengate-data-pump)
   - [Step 5 — GoldenGate for Big Data → S3](#step-5--goldengate-for-big-data--s3)
   - [Step 6 — Snowflake MERGE](#step-6--snowflake-merge)
   - [Step 7 — Final Result in Snowflake](#step-7--final-result-in-snowflake)
5. [Why the S3 Bucket? — Connector Clarification](#5-why-the-s3-bucket--connector-clarification)
6. [Trail Files & Batching — Concept Clarification](#6-trail-files--batching--concept-clarification)
7. [Key Terms Glossary](#7-key-terms-glossary)

---

## 1. What is Oracle GoldenGate?

### The Big Idea — A "Copy Machine for Data"

Imagine your company has two offices — one in Hyderabad and one in London. Both offices have their own filing cabinets (databases) storing customer information. Whenever someone updates a file in Hyderabad, you want that same update to **automatically appear** in London too — instantly, without anyone manually doing it.

That is exactly what **Oracle GoldenGate** does, but for computer databases.

> **Oracle GoldenGate** is a software product that allows you to replicate, filter, and transform data from one database to another database. It moves committed transactions across multiple systems in your enterprise.

### Real-World Banking Example

A bank with branches worldwide needs every transaction from a Bangalore branch synchronized with the central database in the UK. The volume is massive, and any delay impacts the business. Oracle GoldenGate handles this automatically, in real time.

### In One Line

> **Oracle GoldenGate is like a real-time, automatic courier service for your data — instantly delivering every change from one database to another, anywhere in the world, without any manual effort.**

---

## 2. How Does It Work? (Step by Step)

Think of it like a **relay race** with 3 workers:

### Worker 1 — The Watcher (Extract)
Sits on the source database and captures every single change:
- New records added ✅
- Existing records edited ✅
- Records deleted ✅
- Unchanged records → **completely ignored**

### Worker 2 — The Carrier (Data Pump)
Picks up the captured changes and ships them over the network to the target environment. Like a courier delivering a package to another city.

### Worker 3 — The Applier (Replicat)
Reads the shipped changes and applies them to the destination database (e.g., Snowflake).

```
Watcher (Extract) → Carrier (Pump) → Applier (Replicat)
```

### What Makes It Special — CDC (Change Data Capture)

GoldenGate identifies and replicates **only the changes** made to the data. It does NOT transfer everything at each synchronization. This significantly reduces network load and improves performance.

---

## 3. Real-World Use Cases

| Situation | How GoldenGate Helps |
|---|---|
| 🏦 Bank with global branches | Keeps all branch databases in sync in real time |
| 🔄 Upgrading to a new system | Migrates data smoothly with zero downtime |
| 🛡️ Disaster recovery | If one database crashes, a backup is always ready |
| 📊 Data analytics | Sends live data to Snowflake/reporting systems |

> GoldenGate ensures **99.999% uptime** — designed to almost never fail.

---

## 4. Oracle to Snowflake — Full Replication Process

### Overall Architecture

```
Oracle DB → GoldenGate Extract → Trail File → Data Pump → GoldenGate for Big Data → S3 Bucket → Snowflake
```

---

### Step 1 — Oracle Setup & EMPLOYEE Table

#### 1a — Enable Supplemental Logging

Before GoldenGate can watch for changes, Oracle must record every INSERT / UPDATE / DELETE in its redo log. Think of this as turning on **"Track Changes"** in a Word document.

```sql
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

ALTER TABLE HR.EMPLOYEE
  ADD SUPPLEMENTAL LOG DATA
  (ALL) COLUMNS;
-- Now Oracle records before+after values
-- for every changed row in the redo log.
```

#### 1b — Create GoldenGate User

```sql
CREATE USER ggadmin IDENTIFIED BY 'Secret123';

GRANT DBA TO ggadmin;
GRANT SELECT ANY TABLE TO ggadmin;
EXEC DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE('ggadmin');
```

#### EMPLOYEE Table — Starting State (3 rows)

| EMP_ID | NAME | DEPT | SALARY |
|---|---|---|---|
| 101 | Ravi Kumar | Finance | 60000 |
| 102 | Priya Nair | HR | 55000 |
| 103 | Arjun Rao | IT | 70000 |

---

### Step 2 — Make 3 Changes: INSERT, UPDATE, DELETE

A user runs three SQL statements in Oracle. GoldenGate will capture **only these changes** — NOT the full table.

#### INSERT — Add a new employee

```sql
INSERT INTO HR.EMPLOYEE (EMP_ID, NAME, DEPT, SALARY)
VALUES (104, 'Sneha Reddy', 'Marketing', 62000);
COMMIT;
-- → New employee added. GoldenGate sees a new row in the redo log.
```

#### UPDATE — Give Ravi a salary raise

```sql
UPDATE HR.EMPLOYEE
SET    SALARY = 75000
WHERE  EMP_ID = 101;   -- Ravi got a raise
COMMIT;
-- → GoldenGate captures: before SALARY=60000, after SALARY=75000.
```

#### DELETE — Arjun left the company

```sql
DELETE FROM HR.EMPLOYEE
WHERE  EMP_ID = 103;   -- Arjun left the company
COMMIT;
-- → GoldenGate captures: EMP_ID=103 was deleted. Will remove from Snowflake too.
```

#### Oracle Table After Changes

| EMP_ID | NAME | DEPT | SALARY | Change |
|---|---|---|---|---|
| 101 | Ravi Kumar | Finance | **75000** | ✏️ UPDATED |
| 102 | Priya Nair | HR | 55000 | — unchanged |
| ~~103~~ | ~~Arjun Rao~~ | ~~IT~~ | ~~70000~~ | ❌ DELETED |
| 104 | Sneha Reddy | Marketing | 62000 | ✅ INSERTED |

---

### Step 3 — GoldenGate EXTRACT

The Extract process reads Oracle's redo log and writes **only the 3 changed rows** into a local Trail File. Unchanged rows (like Priya's) are completely ignored.

#### Extract Parameter File (EXTRACT.prm)

```
-- Tell GoldenGate to start an Extract named EXTORA
EXTRACT EXTORA

-- Connect to Oracle using the ggadmin user
USERIDALIAS ogg DOMAIN OracleGoldenGate

-- Write changes to trail file with prefix 'et'
EXTTRAIL ./dirdat/et

-- Capture supplemental columns (before + after values)
LOGALLSUPCOLS
UPDATERECORDFORMAT COMPACT

-- Watch ONLY the EMPLOYEE table
TABLE HR.EMPLOYEE;
```

#### Start the Extract Process

```
-- Inside GoldenGate command shell (GGSCI)
GGSCI> ADD EXTRACT EXTORA, INTEGRATED TRANLOG, BEGIN NOW
GGSCI> ADD EXTTRAIL ./dirdat/et, EXTRACT EXTORA
GGSCI> START EXTRACT EXTORA
-- Output: EXTRACT EXTORA starting
```

#### Trail File Content — What GoldenGate Wrote (et000001)

```
[INS] HR.EMPLOYEE | EMP_ID=104 | NAME='Sneha Reddy' | DEPT='Marketing' | SALARY=62000 | TS=2024-01-15 10:32:01
[UPD] HR.EMPLOYEE | EMP_ID=101 | BEFORE: SALARY=60000 | AFTER: SALARY=75000 | TS=2024-01-15 10:32:45
[DEL] HR.EMPLOYEE | EMP_ID=103 | NAME='Arjun Rao' | DEPT='IT' | SALARY=70000 | TS=2024-01-15 10:33:10
```

> ✓ Only 3 records in the trail file. Priya's row (EMP_ID=102) is not here — she was untouched.

---

### Step 4 — GoldenGate Data Pump

The Data Pump reads the local trail file and transfers it over the network to the GoldenGate for Big Data server (running near the S3 bucket). Think of it as a **courier**.

#### Data Pump Parameter File (PUMP.prm)

```
EXTRACT PMPSNOW               -- name of this pump

USERIDALIAS ogg DOMAIN OracleGoldenGate

-- Read from the local trail file (EXTORA wrote here)
RMTHOST gg-bigdata-server.aws.com, MGRPORT 7809

-- Write to remote trail on the Big Data server
RMTTRAIL ./dirdat/rt

-- Pass through all changes for EMPLOYEE
TABLE HR.EMPLOYEE;
```

#### Start the Pump

```
GGSCI> ADD EXTRACT PMPSNOW, EXTTRAILSOURCE ./dirdat/et
GGSCI> ADD RMTTRAIL ./dirdat/rt, EXTRACT PMPSNOW
GGSCI> START EXTRACT PMPSNOW
-- Trail file et000001 transferred → remote trail rt000001
```

#### Flow

```
📄 Local trail (./dirdat/et000001)
    → 🌐 Network (TCP port 7809)
        → 📄 Remote trail (./dirdat/rt000001)
```

---

### Step 5 — GoldenGate for Big Data → S3

The Replicat on the Big Data server reads the remote trail file, formats each change as an Avro file, and uploads it to the S3 staging bucket.

#### Replicat Parameter File (RSNOW.prm)

```
REPLICAT RSNOW
TARGETDB LIBFILE libggjava.so
  SET property=dirprm/rsnow.props

-- Map Oracle columns → Snowflake columns
MAP HR.EMPLOYEE, TARGET MYDB.PUBLIC.EMPLOYEE;
```

#### Properties File (rsnow.props) — S3 Stage Config

```properties
gg.handlerlist=snowflake

## Snowflake connection
gg.handler.snowflake.type=snowflake
gg.handler.snowflake.connectionURL=jdbc:snowflake://myacct.snowflakecomputing.com/?warehouse=COMPUTE_WH&db=MYDB&schema=PUBLIC
gg.handler.snowflake.UserName=sf_user
gg.handler.snowflake.Password=SfPass123

## Use S3 as external staging area
gg.handler.snowflake.stageType=S3
gg.handler.snowflake.stageName=s3://my-gg-stage/employee/
gg.handler.snowflake.storageIntegration=SNOWFLAKE_S3_INTEGRATION

## Format: Avro (compact binary)
gg.handler.snowflake.format=avro_row_ocf
```

#### Files Uploaded to S3 Bucket

```
s3://my-gg-stage/employee/
  ├── GG_EMPLOYEE_20240115_103201_INS.avro   → INSERT  — Sneha Reddy (EMP_ID 104)  • 1.2 KB
  ├── GG_EMPLOYEE_20240115_103245_UPD.avro   → UPDATE  — Ravi Kumar salary change   • 0.9 KB
  └── GG_EMPLOYEE_20240115_103310_DEL.avro   → DELETE  — Arjun Rao (EMP_ID 103)    • 0.8 KB
```

---

### Step 6 — Snowflake MERGE

GoldenGate triggers Snowflake to read the Avro files from S3 and run a MERGE statement — which handles INSERT, UPDATE, and DELETE all in one SQL command.

#### Step 6a — Snowflake External Stage (One-Time Setup)

```sql
-- Storage integration (grants Snowflake access to S3)
CREATE STORAGE INTEGRATION SNOWFLAKE_S3_INTEGRATION
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = S3
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456:role/SnowflakeRole'
  STORAGE_ALLOWED_LOCATIONS = ('s3://my-gg-stage/');

-- External stage pointing to our S3 bucket
CREATE STAGE GG_EMP_STAGE
  URL = 's3://my-gg-stage/employee/'
  STORAGE_INTEGRATION = SNOWFLAKE_S3_INTEGRATION
  FILE_FORMAT = (TYPE = AVRO);
```

#### Step 6b — MERGE Statement (Auto-Generated by GoldenGate)

```sql
MERGE INTO MYDB.PUBLIC.EMPLOYEE AS target
USING (
  SELECT
    $1:EMP_ID::INT        AS EMP_ID,
    $1:NAME::STRING       AS NAME,
    $1:DEPT::STRING       AS DEPT,
    $1:SALARY::NUMBER     AS SALARY,
    $1:gg_op::STRING      AS OP    -- I/U/D flag
  FROM @GG_EMP_STAGE
) AS src
ON target.EMP_ID = src.EMP_ID

-- If row exists AND it's an UPDATE → update columns
WHEN MATCHED AND src.OP = 'U' THEN UPDATE SET
  target.NAME   = src.NAME,
  target.DEPT   = src.DEPT,
  target.SALARY = src.SALARY

-- If row exists AND it's a DELETE → remove it
WHEN MATCHED AND src.OP = 'D' THEN DELETE

-- If row does NOT exist AND it's an INSERT → add it
WHEN NOT MATCHED AND src.OP = 'I' THEN INSERT
  (EMP_ID, NAME, DEPT, SALARY)
VALUES
  (src.EMP_ID, src.NAME, src.DEPT, src.SALARY);
```

---

### Step 7 — Final Result in Snowflake

#### Snowflake EMPLOYEE Table — Final State

| EMP_ID | NAME | DEPT | SALARY | Applied Change |
|---|---|---|---|---|
| 101 | Ravi Kumar | Finance | **75000** | ✏️ UPDATED ✓ |
| 102 | Priya Nair | HR | 55000 | — untouched |
| 104 | Sneha Reddy | Marketing | 62000 | ✅ INSERTED ✓ |

> EMP_ID 103 (Arjun Rao) is gone — the DELETE was applied. ✓

#### Verify in Snowflake

```sql
SELECT * FROM MYDB.PUBLIC.EMPLOYEE ORDER BY EMP_ID;

-- Result:
-- EMP_ID  NAME          DEPT       SALARY
-- ------  ------------  ---------  ------
-- 101     Ravi Kumar    Finance    75000   ← salary updated
-- 102     Priya Nair    HR         55000   ← unchanged
-- 104     Sneha Reddy   Marketing  62000   ← new row
```

#### End-to-End Summary Flow

```
Oracle DB          →  Extract         →  Pump             →  S3 Bucket          →  Snowflake ✓
(3 changes made)      (trail file)       (transferred)       (3 Avro files)         (MERGE done)
```

> This entire cycle — from Oracle commit to Snowflake MERGE — happens in **seconds**, continuously and automatically.

---

## 5. Why the S3 Bucket? — Connector Clarification

### The Common Confusion

When documentation says **"no direct connector"** to Snowflake, it means GoldenGate cannot push rows **directly into Snowflake's tables row by row** like it does with another Oracle database.

BUT — GoldenGate **does have a Snowflake Handler** (a plugin) that connects to Snowflake via JDBC and:
1. Formats changes into Avro/CSV files
2. Uploads those files to S3
3. Connects to Snowflake via JDBC
4. Executes the MERGE SQL on Snowflake automatically

### So Who Runs the MERGE?

**GoldenGate itself runs the MERGE** — through its JDBC connection to Snowflake.

```
GoldenGate Replicat
      │
      ├── 1. Formats changes into Avro/CSV files
      ├── 2. Uploads those files → S3 bucket
      ├── 3. Connects to Snowflake via JDBC
      └── 4. Executes MERGE SQL on Snowflake
                (using the S3 files as the source)
```

### Why Not Skip S3 and Go Directly?

| Approach | Problem |
|---|---|
| Row-by-row insert into Snowflake | Very slow, costly — not how Snowflake is designed |
| Bulk file load via S3 + MERGE | Fast, efficient — Snowflake's natural strength |

Snowflake is a **cloud warehouse** optimized to load data in **bulk from files**, not to receive thousands of tiny row-by-row inserts. S3 acts as a **fast loading dock** — GoldenGate drops files there, then tells Snowflake to pick them up and process them all at once.

---

## 6. Trail Files & Batching — Concept Clarification

### Trail Files — One File, Many Changes

Trail files do **not** work one-per-change. Think of a trail file like a **running diary/logbook**.

```
Trail file:  et000001
─────────────────────────────────────────────────────────
 10:32:01  INSERT  EMP_ID=104  Sneha Reddy
 10:32:45  UPDATE  EMP_ID=101  Ravi Kumar (salary change)
 10:33:10  DELETE  EMP_ID=103  Arjun Rao
 10:35:22  INSERT  EMP_ID=105  Kiran Sharma
 10:38:01  UPDATE  EMP_ID=102  Priya Nair
 ... keeps growing until size limit (default 500MB)
─────────────────────────────────────────────────────────
```

- All changes go into **one trail file**, one after another
- Only when it hits the **size limit** (default 500MB) does GoldenGate roll over to `et000002`
- One trail file = **many changes**, not one change per file

### S3 Files — Micro-Batches, Not One-Per-Change

S3 itself does **nothing** — it is just a dumb storage bucket that holds files. GoldenGate:
- Groups changes into **micro-batches** (e.g. every 30 seconds or every 1000 rows)
- Writes **one Avro/CSV file per micro-batch** to S3
- S3 receives multiple small files over time

```
S3 bucket:
  GG_EMPLOYEE_103201.avro  → batch 1 (few changes)
  GG_EMPLOYEE_103500.avro  → batch 2 (few changes)
  GG_EMPLOYEE_104012.avro  → batch 3 (few changes)
```

### The MERGE — Processes All Files Together

GoldenGate connects to Snowflake via JDBC and fires a MERGE that reads **all those small Avro files from S3** and applies them to the Snowflake table in one shot.

The MERGE handles all operations in one SQL statement — Snowflake reads all small files from S3, processes them together, and applies to the table. That is the efficiency.

### Restaurant Kitchen Analogy

| Component | Analogy |
|---|---|
| Trail file | The order ticket pad (all orders written together) |
| GoldenGate batching | Waiter collecting several orders before going to kitchen |
| S3 | The kitchen counter where orders are placed |
| MERGE | Chef cooking all orders at once in one batch |
| Snowflake | The dining table where food finally arrives |

The chef (Snowflake) does not cook one dish per second — it waits for a small batch of orders to pile up on the counter (S3), then cooks them all efficiently. That is exactly how the MERGE works.

---

## 7. Key Terms Glossary

| Term | Simple Meaning |
|---|---|
| **Replicate** | To make an exact copy and keep it updated continuously |
| **GoldenGate** | Oracle's software that copies changes between databases in real time |
| **CDC (Change Data Capture)** | Technology that detects and captures only what changed |
| **Extract** | GoldenGate component that watches and captures changes from source |
| **Trail File** | A log file where GoldenGate stores captured changes (like a diary) |
| **Data Pump** | GoldenGate component that ships trail files over the network |
| **Replicat** | GoldenGate component that applies changes to the target (Snowflake) |
| **S3 Bucket** | AWS cloud storage used as a temporary landing area for Avro files |
| **Avro** | A compact binary file format used to carry change data |
| **MERGE** | A SQL command that handles INSERT + UPDATE + DELETE in one statement |
| **JDBC** | A standard Java connection used by GoldenGate to talk to Snowflake |
| **Supplemental Logging** | Oracle feature that records before/after values of every changed row |
| **Snowpipe** | Snowflake's service that auto-loads files from S3 (alternative to MERGE) |
| **Stage** | A Snowflake concept — a location (S3 or internal) where files land before loading |

---

*Document generated from a technical Q&A conversation on Oracle GoldenGate and Snowflake data replication.*
