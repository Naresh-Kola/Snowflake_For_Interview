# Change Tracking in Dynamic Tables: Complete Deep Dive

Change tracking is the HIDDEN ENGINE behind incremental refresh. Without it, dynamic tables would have to rebuild everything every time. With it, they process only what changed.

---

## Section 1: What Is Change Tracking?

Change tracking is a Snowflake feature that records **WHAT CHANGED** in a table at the micro-partition level. It adds hidden metadata columns that track:
- Which rows were INSERTED
- Which rows were DELETED
- Which rows were UPDATED (tracked as DELETE old + INSERT new)

You **NEVER** see these hidden columns in a normal `SELECT *`. They exist only in Snowflake's internal metadata layer.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ VISIBLE DATA (what you see)    │ HIDDEN METADATA (what Snowflake sees)  │
├──────────────────────────────────────────────────────────────────────────┤
│ ORDER_ID │ PRODUCT │ PRICE     │ METADATA$ACTION │ METADATA$ISUPDATE   │
│ 1        │ Laptop  │ 999.99    │ INSERT          │ FALSE               │
│ 2        │ Mouse   │ 29.99     │ INSERT          │ FALSE               │
└──────────────────────────────────────────────────────────────────────────┘
```

When a dynamic table with `REFRESH_MODE = INCREMENTAL` is created, Snowflake **AUTOMATICALLY** enables change tracking on all base tables. You don't have to do anything.

---

## Section 2: How Change Tracking Works (Micro-Partition Level)

Snowflake stores data in **MICRO-PARTITIONS** (50-500 MB compressed chunks). Change tracking works at this level:

```
INITIAL STATE: Table has 3 micro-partitions

 Partition P1        Partition P2        Partition P3
 ┌───────────┐      ┌───────────┐      ┌───────────┐
 │ Row 1     │      │ Row 4     │      │ Row 7     │
 │ Row 2     │      │ Row 5     │      │ Row 8     │
 │ Row 3     │      │ Row 6     │      │ Row 9     │
 └───────────┘      └───────────┘      └───────────┘
```

Now you UPDATE Row 5: `UPDATE orders SET price = 899 WHERE order_id = 5;`

Snowflake does **NOT** modify P2 in-place. Micro-partitions are **IMMUTABLE**. Instead:

```
AFTER UPDATE:

 P1 (unchanged)     P2 (REMOVED)            P3 (unchanged)
 ┌───────────┐      ┌───────────┐            ┌───────────┐
 │ Row 1     │      │ Row 4     │  GONE      │ Row 7     │
 │ Row 2     │      │ Row 5 old │  ────►     │ Row 8     │
 │ Row 3     │      │ Row 6     │            │ Row 9     │
 └───────────┘      └───────────┘            └───────────┘

                    P2' (NEW)
                    ┌───────────┐
                    │ Row 4     │
                    │ Row 5 NEW │  ← price=899
                    │ Row 6     │
                    └───────────┘

 CHANGE TRACKING RECORDS:
   - P2 was REMOVED (contains old rows 4, 5, 6)
   - P2' was ADDED  (contains new rows 4, 5_updated, 6)

 By comparing P2 (removed) and P2' (added):
   Row 4: unchanged (exists in both)
   Row 5: UPDATED   (different in P2 vs P2')
   Row 6: unchanged (exists in both)
```

**KEY INSIGHT:** Change tracking doesn't store a "log" of operations. It tracks which micro-partitions were ADDED and REMOVED. By diffing the old and new partitions, Snowflake figures out what changed.

---

## Section 2B: How Net Delta Works (Why You Only See the Final State)

Between two checkpoints (T1 → T2), multiple DML operations can happen. Change tracking records only the **NET EFFECT** — the final state compared to the starting state.

### Example: 3 operations on the same row

```
Checkpoint T1: order_id=6 does NOT exist.

10:01 → INSERT order_id=6, price=50   → P4 added
10:03 → UPDATE order_id=6, price=75   → P4 removed, P4' added
10:05 → UPDATE order_id=6, price=100  → P4' removed, P4'' added

At refresh time (T2):
  Partitions at T1?  → P4 did NOT exist
  Partitions at T2?  → P4'' exists (price=100)

  NET DELTA: P4'' was ADDED. Snowflake sees: "order_id=6 is NEW with price=100"
  Intermediate states (50, 75) are INVISIBLE — born and died between snapshots.
```

### Example: INSERT + DELETE cancels out

```
Checkpoint T1: order_id=7 does NOT exist.
10:01 → INSERT order_id=7
10:04 → DELETE order_id=7

NET DELTA: NOTHING. DT doesn't know row 7 ever existed.
Result: REFRESH_ACTION = NO_DATA. Zero rows processed.
```

### Example: UPDATE + DELETE = net DELETE

```
Checkpoint T1: order_id=1 EXISTS with price=999.
10:01 → UPDATE price=899
10:03 → UPDATE price=799
10:05 → DELETE order_id=1

NET DELTA: DELETE order_id=1 (original price=999).
The 2 intermediate price changes are invisible.
```

### Example: DELETE + RE-INSERT = net UPDATE

```
Checkpoint T1: order_id=2 EXISTS with status='PENDING'.
10:01 → DELETE order_id=2
10:03 → INSERT order_id=2, status='COMPLETED'

NET DELTA: DELETE(PENDING) + INSERT(COMPLETED), ISUPDATE=TRUE
```

### Summary: Net Delta Combinations

| Operations Between Checkpoints | Net Delta (What DT Processes) |
|-------------------------------|-------------------------------|
| INSERT | INSERT (new row) |
| INSERT → UPDATE → UPDATE | INSERT (final state only) |
| INSERT → DELETE | NOTHING (cancelled out) |
| INSERT → UPDATE → DELETE | NOTHING (cancelled out) |
| UPDATE | DELETE(old) + INSERT(new) |
| UPDATE → UPDATE → UPDATE | DELETE(original) + INSERT(final) |
| UPDATE → DELETE | DELETE (original version) |
| DELETE | DELETE (row removed) |
| DELETE → RE-INSERT (same key) | DELETE(old) + INSERT(new) = UPDATE |
| No operations | NOTHING (NO_DATA, zero work) |

> If 1000 UPDATEs happen to the same row between refreshes, the DT processes exactly **1 DELETE + 1 INSERT** (2 row operations). Not 1000.

---

## Setup: Create Demo Environment

```sql
CREATE DATABASE IF NOT EXISTS CT_DEMO_DB;
CREATE SCHEMA IF NOT EXISTS CT_DEMO_DB.RAW;
CREATE SCHEMA IF NOT EXISTS CT_DEMO_DB.STAGING;

CREATE OR REPLACE TABLE CT_DEMO_DB.RAW.ORDERS (
    ORDER_ID      NUMBER,
    CUSTOMER_NAME VARCHAR(50),
    PRODUCT       VARCHAR(50),
    QUANTITY      NUMBER,
    PRICE         NUMBER(10,2),
    STATUS        VARCHAR(20),
    ORDER_DATE    DATE
);

INSERT INTO CT_DEMO_DB.RAW.ORDERS VALUES
    (1, 'Rohit',   'Laptop',     1, 999.99,  'COMPLETED', '2025-01-10'),
    (2, 'Priya',   'Mouse',      2, 29.99,   'COMPLETED', '2025-01-15'),
    (3, 'James',   'Keyboard',   1, 89.99,   'SHIPPED',   '2025-02-01'),
    (4, 'Emily',   'Monitor',    1, 399.99,  'PENDING',   '2025-02-10'),
    (5, 'Amit',    'Headphones', 1, 199.99,  'COMPLETED', '2025-03-01');

SELECT * FROM CT_DEMO_DB.RAW.ORDERS ORDER BY ORDER_ID;
```

---

## Section 3: What Is a Checkpoint?

A checkpoint is a **TIMESTAMP** saved after every successful refresh. It marks: "I have processed all changes up to this moment."

```
CHECKPOINT LIFECYCLE

TIME ──────────────────────────────────────────────────────────────►

10:00 AM          10:05 AM          10:10 AM          10:15 AM
   │                  │                  │                  │
   ▼                  ▼                  ▼                  ▼
DT Created       1st Refresh       2nd Refresh       3rd Refresh
Checkpoint=T0    Checkpoint=T1     Checkpoint=T2     Checkpoint=T3

At 10:05: "What changed between T0 and NOW?" → processes changes → saves T1
At 10:10: "What changed between T1 and NOW?" → INSERT(6) + UPDATE(1) → saves T2
At 10:15: "What changed between T2 and NOW?" → NOTHING → NO_DATA → saves T3
```

### Key Points About Checkpoints:

1. You **NEVER** see the checkpoint directly. It is internal.
2. Each DT has its **OWN** checkpoint. They are independent.
3. Checkpoint ≈ the `DATA_TIMESTAMP` in `SHOW DYNAMIC TABLES`.
4. If checkpoint data EXPIRES (beyond TIME TRAVEL retention), the DT goes STALE.
5. FULL refresh does NOT use checkpoints. Only INCREMENTAL uses them.

```sql
SHOW DYNAMIC TABLES IN SCHEMA CT_DEMO_DB.STAGING;
-- Look at "data_timestamp" column — this reflects the checkpoint
```

---

## Section 4: Seeing Change Tracking in Action (CHANGES Clause)

Snowflake provides a `CHANGES` clause that lets you SEE what change tracking recorded — the SAME metadata that dynamic tables use internally.

```sql
-- STEP 1: Enable change tracking (DTs do this automatically)
ALTER TABLE CT_DEMO_DB.RAW.ORDERS SET CHANGE_TRACKING = TRUE;

-- STEP 2: Save current timestamp as "checkpoint"
SET checkpoint_ts = (SELECT CURRENT_TIMESTAMP());

-- STEP 3: Make changes
INSERT INTO CT_DEMO_DB.RAW.ORDERS VALUES
    (6, 'Sarah', 'Webcam', 1, 49.99, 'PENDING', '2025-04-01');

UPDATE CT_DEMO_DB.RAW.ORDERS
SET PRICE = 899.99, STATUS = 'SHIPPED'
WHERE ORDER_ID = 1;

DELETE FROM CT_DEMO_DB.RAW.ORDERS WHERE ORDER_ID = 3;

-- STEP 4: Query change tracking metadata
SELECT *
FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => DEFAULT)
AT(TIMESTAMP => $checkpoint_ts);
```

**Result:**

| ORDER_ID | CUSTOMER_NAME | PRICE | METADATA$ACTION | METADATA$ISUPDATE |
|----------|---------------|-------|-----------------|-------------------|
| 6 | Sarah | 49.99 | INSERT | FALSE | ← new row |
| 1 | Rohit | 899.99 | INSERT | TRUE | ← new version |
| 1 | Rohit | 999.99 | DELETE | TRUE | ← old version |
| 3 | James | 89.99 | DELETE | FALSE | ← deleted row |

**How UPDATE is tracked:** Row 1 shows up TWICE — DELETE (old: 999.99) + INSERT (new: 899.99), both with ISUPDATE=TRUE. Because micro-partitions are immutable: UPDATE = remove old partition + add new partition.

---

## APPEND_ONLY vs DEFAULT Change Tracking

| Type | Behavior |
|------|----------|
| **DEFAULT** | Shows NET CHANGES (delta). INSERT + DELETE of same row cancels out. |
| **APPEND_ONLY** | Shows ONLY INSERTS. Ignores updates and deletes. Faster. |

```sql
-- DEFAULT: Shows net delta
SELECT * FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => DEFAULT) AT(TIMESTAMP => $checkpoint_ts);

-- APPEND_ONLY: Shows only inserts (even deleted rows appear as original inserts)
SELECT * FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => APPEND_ONLY) AT(TIMESTAMP => $checkpoint_ts);
```

---

## Section 5: How Dynamic Tables Use Change Tracking (Hidden Workflow)

```
HIDDEN WORKFLOW: INCREMENTAL REFRESH

STEP 1: CHECK CHECKPOINT
  Read last refresh timestamp (T1). "When did I last process data?"

STEP 2: QUERY CHANGE TRACKING
  Internally: SELECT * FROM base_table CHANGES(INFORMATION => DEFAULT) AT(TIMESTAMP => T1)
  Returns delta: all INSERTs, UPDATEs, DELETEs since T1.

STEP 3: APPLY DT's SELECT QUERY TO THE DELTA
  Runs defining query ONLY on changed rows/partitions:
  - GROUP BY → recalculates only affected groups
  - JOIN → joins only changed rows
  - LEAD() → recomputes only affected partitions

STEP 4: MERGE RESULTS INTO DT
  New rows → INSERT. Changed rows → DELETE old + INSERT new. Deleted rows → DELETE.

STEP 5: UPDATE CHECKPOINT
  Records new checkpoint T2. Next refresh looks from T2 onward.

STEP 6: RECORD STATISTICS
  Logs: numInsertedRows, numDeletedRows, executionTimeMs, etc.
```

```sql
CREATE OR REPLACE DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_ORDERS
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT ORDER_ID, CUSTOMER_NAME, PRODUCT, QUANTITY, PRICE,
               QUANTITY * PRICE AS TOTAL_AMOUNT, STATUS, ORDER_DATE
        FROM CT_DEMO_DB.RAW.ORDERS;

SELECT * FROM CT_DEMO_DB.STAGING.DT_ORDERS ORDER BY ORDER_ID;
```

---

## Section 6: Step-by-Step Proof — INSERT

```sql
SET ts_before_insert = (SELECT CURRENT_TIMESTAMP());

INSERT INTO CT_DEMO_DB.RAW.ORDERS VALUES
    (7, 'Michael', 'Desk Lamp', 2, 34.99, 'PENDING', '2025-05-01');

-- SEE what change tracking recorded
SELECT ORDER_ID, CUSTOMER_NAME, PRODUCT, PRICE, METADATA$ACTION, METADATA$ISUPDATE
FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => DEFAULT) AT(TIMESTAMP => $ts_before_insert);
-- Result: ORDER_ID=7, ACTION=INSERT, ISUPDATE=FALSE

ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_ORDERS REFRESH;

SELECT * FROM CT_DEMO_DB.STAGING.DT_ORDERS WHERE ORDER_ID = 7;

SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INS,
    STATISTICS:numDeletedRows::INT AS ROWS_DEL
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'CT_DEMO_DB.STAGING.DT_ORDERS'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
-- ROWS_INS=1, ROWS_DEL=0 → only 1 row processed
```

---

## Section 7: Step-by-Step Proof — UPDATE

```sql
SET ts_before_update = (SELECT CURRENT_TIMESTAMP());

UPDATE CT_DEMO_DB.RAW.ORDERS SET PRICE = 449.99, STATUS = 'COMPLETED' WHERE ORDER_ID = 4;

-- SEE change tracking: TWO rows (DELETE old + INSERT new, both ISUPDATE=TRUE)
SELECT ORDER_ID, PRICE, STATUS, METADATA$ACTION, METADATA$ISUPDATE
FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => DEFAULT) AT(TIMESTAMP => $ts_before_update);

ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_ORDERS REFRESH;

SELECT * FROM CT_DEMO_DB.STAGING.DT_ORDERS WHERE ORDER_ID = 4;
-- PRICE=449.99, STATUS=COMPLETED

SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INS,
    STATISTICS:numDeletedRows::INT AS ROWS_DEL
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'CT_DEMO_DB.STAGING.DT_ORDERS'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
-- ROWS_INS=1, ROWS_DEL=1 → 1 old version removed, 1 new version added
```

---

## Section 8: Step-by-Step Proof — DELETE

```sql
SET ts_before_delete = (SELECT CURRENT_TIMESTAMP());

DELETE FROM CT_DEMO_DB.RAW.ORDERS WHERE ORDER_ID = 2;

SELECT ORDER_ID, CUSTOMER_NAME, METADATA$ACTION, METADATA$ISUPDATE
FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => DEFAULT) AT(TIMESTAMP => $ts_before_delete);
-- ORDER_ID=2, ACTION=DELETE, ISUPDATE=FALSE

ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_ORDERS REFRESH;

SELECT * FROM CT_DEMO_DB.STAGING.DT_ORDERS WHERE ORDER_ID = 2;
-- 0 rows — deleted!

SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INS,
    STATISTICS:numDeletedRows::INT AS ROWS_DEL
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'CT_DEMO_DB.STAGING.DT_ORDERS'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
-- ROWS_INS=0, ROWS_DEL=1
```

---

## Section 9: Step-by-Step Proof — Mixed DML

```sql
SET ts_before_mixed = (SELECT CURRENT_TIMESTAMP());

INSERT INTO CT_DEMO_DB.RAW.ORDERS VALUES
    (8, 'Ananya', 'USB Hub', 3, 59.99, 'PENDING', '2025-06-01');

UPDATE CT_DEMO_DB.RAW.ORDERS SET QUANTITY = 5 WHERE ORDER_ID = 5;

DELETE FROM CT_DEMO_DB.RAW.ORDERS WHERE ORDER_ID = 7;

-- SEE all changes
SELECT ORDER_ID, CUSTOMER_NAME, PRODUCT, QUANTITY, PRICE,
       METADATA$ACTION, METADATA$ISUPDATE
FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => DEFAULT) AT(TIMESTAMP => $ts_before_mixed)
ORDER BY ORDER_ID, METADATA$ACTION;
-- ORDER_ID=5 → DELETE(old qty=1) + INSERT(new qty=5), ISUPDATE=TRUE
-- ORDER_ID=7 → DELETE, ISUPDATE=FALSE
-- ORDER_ID=8 → INSERT, ISUPDATE=FALSE

ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_ORDERS REFRESH;

SELECT REFRESH_ACTION,
    STATISTICS:numInsertedRows::INT AS ROWS_INS,
    STATISTICS:numDeletedRows::INT AS ROWS_DEL
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'CT_DEMO_DB.STAGING.DT_ORDERS'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
-- All 3 operations processed in a single refresh cycle
```

---

## Section 10: No Changes → No Work (NO_DATA)

```sql
SET ts_no_change = (SELECT CURRENT_TIMESTAMP());

-- Don't change anything

SELECT ORDER_ID, METADATA$ACTION
FROM CT_DEMO_DB.RAW.ORDERS
CHANGES(INFORMATION => DEFAULT) AT(TIMESTAMP => $ts_no_change);
-- 0 rows — nothing changed

ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_ORDERS REFRESH;

SELECT REFRESH_ACTION, STATE,
    STATISTICS:numInsertedRows::INT AS ROWS_INS,
    STATISTICS:numDeletedRows::INT AS ROWS_DEL
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'CT_DEMO_DB.STAGING.DT_ORDERS'
))
ORDER BY REFRESH_START_TIME DESC LIMIT 1;
-- REFRESH_ACTION = 'NO_DATA'
-- ZERO rows processed. ZERO compute wasted.
```

---

## Section 11: Change Tracking with Aggregations (GROUP BY)

When a DT has GROUP BY, change tracking tells it WHICH grouping keys changed. Only those groups are recomputed.

```sql
CREATE OR REPLACE DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_STATUS_SUMMARY
    TARGET_LAG = '1 minute'
    WAREHOUSE = COMPUTE_WH
    REFRESH_MODE = INCREMENTAL
    AS
        SELECT STATUS, COUNT(*) AS ORDER_COUNT, SUM(QUANTITY * PRICE) AS TOTAL_REVENUE
        FROM CT_DEMO_DB.RAW.ORDERS GROUP BY STATUS;

SELECT * FROM CT_DEMO_DB.STAGING.DT_STATUS_SUMMARY ORDER BY ORDER_COUNT DESC;

-- Change one order's status
UPDATE CT_DEMO_DB.RAW.ORDERS SET STATUS = 'SHIPPED' WHERE ORDER_ID = 8;

ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_STATUS_SUMMARY REFRESH;

-- Only 2 groups recomputed: PENDING (lost a row) and SHIPPED (gained a row)
-- COMPLETED group was NOT touched
SELECT * FROM CT_DEMO_DB.STAGING.DT_STATUS_SUMMARY ORDER BY ORDER_COUNT DESC;
```

---

## Section 12: Change Tracking Expiry (Staleness)

Change tracking metadata is tied to TIME TRAVEL. It's only available for the retention period.

| Time Travel Retention | Change Tracking Available? | DT Status |
|----------------------|---------------------------|-----------|
| Within window (< 1 day) | YES | Normal incremental refresh |
| Beyond window (> 1 day) | NO (expired) | DT becomes STALE (must recreate) |

```sql
-- Increase retention window:
ALTER TABLE CT_DEMO_DB.RAW.ORDERS SET DATA_RETENTION_TIME_IN_DAYS = 7;
```

---

## Section 13: Checking If Change Tracking Is Enabled

```sql
SHOW TABLES LIKE 'ORDERS' IN SCHEMA CT_DEMO_DB.RAW;
-- Look at "change_tracking" column → should be 'ON'

-- Enable manually:
ALTER TABLE CT_DEMO_DB.RAW.ORDERS SET CHANGE_TRACKING = TRUE;

-- Disable (NOT recommended if DTs depend on it):
-- ALTER TABLE CT_DEMO_DB.RAW.ORDERS SET CHANGE_TRACKING = FALSE;
```

---

## Section 14: Full Refresh History

```sql
SELECT NAME, REFRESH_ACTION, STATE,
    STATISTICS:numInsertedRows::INT AS ROWS_INS,
    STATISTICS:numDeletedRows::INT AS ROWS_DEL,
    STATISTICS:numCopiedRows::INT AS ROWS_COPIED,
    STATISTICS:executionTimeMs::INT AS EXEC_MS,
    REFRESH_START_TIME, REFRESH_END_TIME
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME_PREFIX => 'CT_DEMO_DB.STAGING'
))
WHERE STATE = 'SUCCEEDED'
ORDER BY REFRESH_START_TIME DESC LIMIT 20;
```

---

## Summary: Change Tracking — The Complete Picture

| Concept | Detail |
|---------|--------|
| What it is | Hidden metadata recording micro-partition additions/removals |
| How INSERT is tracked | New partition ADDED → METADATA$ACTION = INSERT |
| How DELETE is tracked | Old partition REMOVED → METADATA$ACTION = DELETE |
| How UPDATE is tracked | Old REMOVED + new ADDED → DELETE(old) + INSERT(new), ISUPDATE=TRUE |
| No changes | No partitions added/removed → NO_DATA (zero work) |
| Who enables it | Auto-enabled when you create an incremental DT |
| Where it's stored | Hidden columns in table's metadata layer |
| How long it lasts | DATA_RETENTION_TIME_IN_DAYS (default 1 day) |
| How to view it | `CHANGES(INFORMATION => DEFAULT)` clause |
| FULL refresh uses it? | NO. Only INCREMENTAL uses it. |

### Analogy:

- **Guest book** at library entrance = Change tracking (records every add/remove/move)
- **Librarian** = Dynamic table (reads only the guest book, not every shelf)
- **Shelves** = Micro-partitions (physical storage)

---

## Cleanup

```sql
ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_ORDERS SUSPEND;
ALTER DYNAMIC TABLE CT_DEMO_DB.STAGING.DT_STATUS_SUMMARY SUSPEND;

-- To remove everything:
-- DROP DATABASE CT_DEMO_DB;
```
