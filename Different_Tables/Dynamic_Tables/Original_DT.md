# Dynamic Tables & Streams — Complete Internal Workflow Guide

---

## Section 1: What Is Change Tracking?

Change tracking is a Snowflake feature that records **WHAT CHANGED** in a table at the micro-partition level. It adds hidden metadata columns to the table that track:
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

 Partition P1        Partition P2 (REMOVED)   Partition P3
 ┌───────────┐      ┌───────────┐            ┌───────────┐
 │ Row 1     │      │ Row 4     │  GONE      │ Row 7     │
 │ Row 2     │      │ Row 5 old │  ────►     │ Row 8     │
 │ Row 3     │      │ Row 6     │            │ Row 9     │
 └───────────┘      └───────────┘            └───────────┘

                    Partition P2' (NEW)
                    ┌───────────┐
                    │ Row 4     │
                    │ Row 5 NEW │  ← price=899
                    │ Row 6     │
                    └───────────┘

 CHANGE TRACKING RECORDS:
   - P2 was REMOVED (contains old rows 4, 5, 6)
   - P2' was ADDED  (contains new rows 4, 5_updated, 6)

 By comparing P2 (removed) and P2' (added), Snowflake determines:
   Row 4: unchanged (exists in both)
   Row 5: UPDATED   (different in P2 vs P2')
   Row 6: unchanged (exists in both)
```

**KEY INSIGHT:** Change tracking doesn't store a "log" of operations. It tracks which micro-partitions were ADDED and REMOVED. By diffing the old and new partitions, Snowflake figures out what changed.

---

## Section 3: What Is a Checkpoint?

A checkpoint is a **TIMESTAMP** that Snowflake saves after every successful refresh. It marks: "I have processed all changes up to this moment."

On the next refresh, Snowflake asks: "What changed BETWEEN my last checkpoint and NOW?"

It is like a bookmark in a book. You don't re-read the whole book every time — you open to your bookmark and continue from there.

```
CHECKPOINT LIFECYCLE

TIME ──────────────────────────────────────────────────────────────►

10:00 AM          10:05 AM          10:10 AM          10:15 AM
   │                  │                  │                  │
   ▼                  ▼                  ▼                  ▼
DT Created       1st Refresh       2nd Refresh       3rd Refresh
Checkpoint=T0    Checkpoint=T1     Checkpoint=T2     Checkpoint=T3

At 10:05 (1st refresh):
  Snowflake asks: "What changed between T0 and NOW?"
  Processes those changes. Saves checkpoint = T1.

Between 10:05 and 10:10, someone does:
  INSERT order_id=6
  UPDATE order_id=1 (price changed)

At 10:10 (2nd refresh):
  Snowflake asks: "What changed between T1 and NOW?"
  Finds: INSERT(6) + UPDATE(1). Processes only these 2 changes.
  Saves checkpoint = T2.

Between 10:10 and 10:15, NOTHING changes.

At 10:15 (3rd refresh):
  Snowflake asks: "What changed between T2 and NOW?"
  Finds: NOTHING. Result = NO_DATA. Zero work done.
  Saves checkpoint = T3 (even though nothing happened).
```

### Key Points About Checkpoints:

1. You **NEVER** see the checkpoint directly. It is internal to Snowflake.
2. Each DT has its **OWN** checkpoint. DT_A might be at T5. DT_B might be at T3.
3. Checkpoint = the `DATA_TIMESTAMP` in `SHOW DYNAMIC TABLES`.
4. If checkpoint data EXPIRES (beyond TIME TRAVEL retention), the DT goes STALE.
5. FULL refresh does NOT use checkpoints. Only INCREMENTAL refresh uses them.

```sql
SHOW DYNAMIC TABLES IN SCHEMA CT_DEMO_DB.STAGING;
-- Look at "data_timestamp" column — this reflects the checkpoint
```

---

## Section 2B: How Net Delta Works (Why You Only See the Final State)

Between two checkpoints (T1 → T2), multiple DML operations can happen. Change tracking does NOT record each operation individually. It records only the **NET EFFECT** — the final state compared to the starting state.

### Example: 3 operations on the same row between refreshes

```
Checkpoint T1: DT refreshed. order_id=6 does NOT exist.

10:01 → INSERT order_id=6, price=50
        Micro-partition change: P4 added (contains row 6, price=50)

10:03 → UPDATE order_id=6, price=75
        Micro-partition change: P4 removed, P4' added (row 6, price=75)

10:05 → UPDATE order_id=6, price=100
        Micro-partition change: P4' removed, P4'' added (row 6, price=100)

At refresh time, Snowflake looks at the NET result:
  What partitions existed at T1?     → P4 did NOT exist
  What partitions exist now at T2?   → P4'' exists (row 6, price=100)

  NET DELTA: P4'' was ADDED. That's it.
  Snowflake sees: "order_id=6 is NEW with price=100"
  The intermediate states (price=50, price=75) are INVISIBLE.
```

**WHY ARE THEY INVISIBLE?**

At checkpoint T1, Snowflake takes a SNAPSHOT of which partitions exist. At refresh time T2, it takes ANOTHER snapshot. It compares **ONLY** these two snapshots. Nothing in between.

```
SNAPSHOT AT T1 (10:00):     SNAPSHOT AT T2 (10:10):
┌──────────────────┐       ┌──────────────────┐
│ P1 (rows 1-3)    │       │ P1 (rows 1-3)    │  ← same, ignored
│ P2 (rows 4-5)    │       │ P2 (rows 4-5)    │  ← same, ignored
│ P3 (rows 6-9)    │       │ P3 (rows 6-9)    │  ← same, ignored
│                   │       │ P4'' (row 6=100)  │  ← NEW! process this
└──────────────────┘       └──────────────────┘
```

P4 (price=50) was created at 10:01 and REMOVED at 10:03. P4' (price=75) was created at 10:03 and REMOVED at 10:05. By 10:10, NEITHER exists. They were born and died BETWEEN the two snapshots → **INVISIBLE**.

### Example: INSERT + DELETE cancels out

```
Checkpoint T1: order_id=7 does NOT exist.
10:01 → INSERT order_id=7, product='Tablet'
10:04 → DELETE order_id=7

NET DELTA: NOTHING. The DT doesn't even know order_id=7 ever existed.
Result: REFRESH_ACTION = NO_DATA. Zero rows processed.
```

### Example: UPDATE + DELETE = net DELETE

```
Checkpoint T1: order_id=1 EXISTS with price=999.
10:01 → UPDATE order_id=1, price=899
10:03 → UPDATE order_id=1, price=799
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

> If 1000 UPDATEs happen to the same row between refreshes, the DT processes exactly **1 DELETE + 1 INSERT** (2 row operations). Not 1000. This is why incremental refresh is so efficient.

---

## Section 2C: Deep Dive — INSERT → UPDATE → UPDATE (Full Lifecycle)

### Setup: Starting State at Checkpoint T1

```
STATE AT CHECKPOINT T1 (10:00 AM) — DT last refreshed here

 Micro-Partition P1              Micro-Partition P2
 ┌─────────────────────────┐    ┌─────────────────────────┐
 │ order_id=1, Laptop, 999 │    │ order_id=3, Mouse, 29   │
 │ order_id=2, Phone, 699  │    │                          │
 └─────────────────────────┘    └─────────────────────────┘

 Partition Registry at T1: {P1, P2}
 order_id=4 does NOT exist anywhere.
```

### Step 1: INSERT order_id=4 (at 10:02 AM)

```sql
INSERT INTO orders VALUES (4, 'Tablet', 499);
```

**Micro-Partition Layer:**
```
P1 (unchanged)                P2 (unchanged)
┌─────────────────────────┐  ┌─────────────────────────┐
│ order_id=1, Laptop, 999 │  │ order_id=3, Mouse, 29   │
│ order_id=2, Phone, 699  │  │                          │
└─────────────────────────┘  └─────────────────────────┘

P3 (NEW — just created)
┌─────────────────────────┐
│ order_id=4, Tablet, 499 │  ← brand new partition
└─────────────────────────┘

Partition Registry: {P1, P2, P3}
Change log: P3 ADDED
```

**Metadata Layer:**

| METADATA$ACTION | METADATA$ISUPDATE | METADATA$ROW_ID | DATA |
|-----------------|-------------------|-----------------|------|
| INSERT | FALSE | row-id-4 | 4, Tablet, 499 |

WHY: P3 was ADDED → rows in P3 are new → INSERT. No corresponding DELETE → ISUPDATE = FALSE.

### Step 2: UPDATE order_id=4 price 499→599 (at 10:04 AM)

```sql
UPDATE orders SET price = 599 WHERE order_id = 4;
```

**Micro-Partition Layer:**
```
P3 (REMOVED ✗)               P3' (NEW ✓)
┌─────────────────────────┐  ┌─────────────────────────┐
│ order_id=4, Tablet, 499 │  │ order_id=4, Tablet, 599 │
└─────────────────────────┘  └─────────────────────────┘
       ↑ GONE                        ↑ REPLACES P3

Partition Registry: {P1, P2, P3'}
Change log: P3 REMOVED, P3' ADDED
```

**Metadata Layer (changes from 10:02 to 10:04):**

| METADATA$ACTION | METADATA$ISUPDATE | METADATA$ROW_ID | DATA |
|-----------------|-------------------|-----------------|------|
| DELETE | TRUE | row-id-4 | 4, Tablet, 499 |
| INSERT | TRUE | row-id-4 | 4, Tablet, 599 |

WHY: Same ROW_ID in both → ISUPDATE = TRUE → same row being modified.

### Step 3: UPDATE order_id=4 price 599→749 (at 10:06 AM)

```sql
UPDATE orders SET price = 749 WHERE order_id = 4;
```

**Micro-Partition Layer:**
```
P3 (REMOVED earlier ✗)       P3' (REMOVED ✗)     P3'' (NEW ✓)
┌─────────────────────────┐  ┌──────────────┐    ┌──────────────┐
│ order_id=4, Tablet, 499 │  │ 4,Tablet,599 │    │ 4,Tablet,749 │
└─────────────────────────┘  └──────────────┘    └──────────────┘
       ↑ GONE (10:04)            ↑ GONE (10:06)      ↑ CURRENT

Partition Registry: {P1, P2, P3''}
Full change log since T1:
  10:02 — P3 ADDED
  10:04 — P3 REMOVED, P3' ADDED
  10:06 — P3' REMOVED, P3'' ADDED
```

### Step 4: Net Delta — What the DT Actually Sees at Refresh (10:10 AM)

**What is "Net Delta"?** The FINAL EFFECT of all changes, after cancelling out anything that doesn't matter. Like a bank account — you deposit $499, withdraw $499, deposit $599, withdraw $599, deposit $749. Net effect? "I deposited $749."

**Snapshot Comparison:**
```
SNAPSHOT AT T1 (10:00):        SNAPSHOT AT T2 (10:10):
{P1, P2}                       {P1, P2, P3''}

P1: in BOTH → SKIP
P2: in BOTH → SKIP
P3'': only in T2 → ADDED (its rows are INSERTs)
```

**Why P3 and P3' are invisible:**
```
P3 (price=499):  Created 10:02, Removed 10:04 → NOT in T1, NOT in T2 → INVISIBLE
P3' (price=599): Created 10:04, Removed 10:06 → NOT in T1, NOT in T2 → INVISIBLE
P3'' (price=749): Created 10:06, alive at T2 → NOT in T1, YES in T2 → ADDED
```

**Partition Visibility Rule:**

| In T1? | In T2? | Result |
|--------|--------|--------|
| YES | YES | SKIP (no change) |
| YES | NO | REMOVED → rows become DELETEs |
| NO | YES | ADDED → rows become INSERTs |
| NO | NO | INVISIBLE (born and died between) |

**Generating Metadata Columns:**
- Every row in ADDED partition → METADATA$ACTION = INSERT
- Every row in REMOVED partition → METADATA$ACTION = DELETE
- Match ROW_IDs: same ROW_ID in both → ISUPDATE = TRUE

**Final Net Delta:**

| METADATA$ACTION | METADATA$ISUPDATE | METADATA$ROW_ID | DATA |
|-----------------|-------------------|-----------------|------|
| INSERT | FALSE | row-id-4 | 4, Tablet, 749 |

**ONE ROW.** Not three operations. Just one. ISUPDATE=FALSE because row 4 didn't exist at T1.

### Contrast: What If row_id=4 EXISTED at T1?

If row_id=4 already existed with price=399 in partition P_old:

```
Snapshot T1: {P1, P2, P_old}     (P_old has id=4, price=399)
Snapshot T2: {P1, P2, P3''}      (P3'' has id=4, price=749)

ADDED:   [P3'']    → row (4, Tablet, 749) → INSERT
REMOVED: [P_old]   → row (4, Tablet, 399) → DELETE
Same ROW_ID → ISUPDATE = TRUE

Net Delta: DELETE(399) + INSERT(749) — an UPDATE.
```

### More Examples of Net Delta Collapsing:

| What happened between T1→T2 | Net Delta (what DT sees) |
|------------------------------|--------------------------|
| INSERT → UPDATE → UPDATE | INSERT (final value) |
| INSERT → UPDATE → DELETE | NOTHING (row born+died) |
| INSERT → DELETE → INSERT | INSERT (final value) |
| UPDATE → UPDATE → UPDATE | DELETE(old) + INSERT(final) |
| UPDATE → DELETE | DELETE (original value from T1) |
| UPDATE → DELETE → INSERT | DELETE(T1 val) + INSERT(final) |
| DELETE → INSERT | DELETE(T1 val) + INSERT(new val) |
| DELETE → INSERT → UPDATE | DELETE(T1 val) + INSERT(final) |
| 1000 UPDATEs to same row | DELETE(T1 val) + INSERT(final) |

**Pattern:** No matter how many operations, net delta is always at most DELETE(old) + INSERT(new) per row — 2 records max.

---

## Section 3: Streams vs Dynamic Tables

### 3A: Short Answer

**YES** — Streams and Dynamic Tables use the **SAME** underlying change tracking system (micro-partition versioning + hidden metadata columns).

**BUT** — they USE that system differently:
- **Stream** = EXPOSES the change data to YOU (you decide what to do)
- **Dynamic Table** = CONSUMES the change data ITSELF (automated refresh)

### 3B: The Shared Foundation

Both depend on:
1. Micro-partition versioning (immutable files, add/remove)
2. Hidden metadata columns added to source table
3. METADATA$ACTION, METADATA$ISUPDATE, METADATA$ROW_ID
4. Time Travel data retention for historical access
5. Table version tracking (each DML commit = new version)

### 3C: How a Stream Works

A Stream is a **BOOKMARK** in the table's version history.

```
Table versions: v1 → v2 → v3 → v4 → v5 → v6 → v7 → v8 → v9 → v10
                            ▲                                    ▲
                            │                                    │
                       Stream OFFSET                      Current time
                       (last consumed)                    (latest)

SELECT FROM stream → returns net changes between v3 and v10
```

**Stream Lifecycle:**
1. `CREATE STREAM` → records current table version as offset
2. DML happens → table gets new versions. Stream does NOTHING.
3. `SELECT * FROM stream` → computes net delta. **Offset does NOT move.**
4. Use stream in DML → stream consumed → **offset advances**

**Example:** Same INSERT→UPDATE→UPDATE scenario:
```
10:00 — Stream created. Offset = v1. Table has {id=1, id=2, id=3}
10:02 — INSERT id=4, Tablet, 499
10:04 — UPDATE id=4, price=599
10:06 — UPDATE id=4, price=749
10:07 — SELECT * FROM stream_s1;

RESULT: INSERT │ FALSE │ row-id-4 │ 4,Tab,749

SAME RESULT as Dynamic Table net delta!
```

### 3D: How a Dynamic Table Works

A Dynamic Table is like an **AUTOMATIC STREAM + AUTOMATIC TASK** combined.

1. `CREATE DYNAMIC TABLE ... AS SELECT ...` → full refresh, checkpoint recorded
2. DML happens → DT does NOTHING yet
3. TARGET_LAG triggers → auto computes net delta, applies, advances checkpoint

### 3E: Side-by-Side Comparison

| Aspect | Stream | Dynamic Table |
|--------|--------|---------------|
| Change tracking system | Same (partitions) | Same (partitions) |
| Net delta computation | Same logic | Same logic |
| Metadata columns used | Same 3 columns | Same 3 columns |
| Stores actual data? | NO (just offset) | YES (materialized) |
| Who writes the MERGE? | YOU (in a task) | SNOWFLAKE (auto) |
| Who decides when to run? | YOU (task schedule) | SNOWFLAKE (lag) |
| Offset advances when? | When consumed in DML | After each refresh |
| Can go stale? | YES (if not consumed) | NO (auto-managed) |
| Approach style | IMPERATIVE (you say HOW) | DECLARATIVE (you say WHAT) |

### 3F: Architecture

```
                    ┌─────────────────────────┐
                    │    SOURCE TABLE          │
                    │  (micro-partitions)      │
                    │  DML → versions created  │
                    └──────────┬───────────────┘
                               │
                    ┌──────────▼───────────────┐
                    │  CHANGE TRACKING ENGINE  │
                    │  • Partition versioning  │
                    │  • Hidden CDC columns    │
                    │  • Snapshot comparison   │
                    │  • Net delta computation │
                    └─────┬────────────┬───────┘
                          │            │
             ┌────────────▼──┐    ┌────▼───────────────┐
             │   STREAM      │    │  DYNAMIC TABLE     │
             │ • Bookmark    │    │ • Internal offset  │
             │ • YOU query   │    │ • Auto-refreshes   │
             │ • YOU consume │    │ • Self-maintains   │
             │ • Returns CDC │    │ • Stores result    │
             └───────┬───────┘    └────────┬───────────┘
                     │                     │
                     ▼                     ▼
             ┌───────────────┐    ┌─────────────────────┐
             │ YOUR TASK     │    │ DT OUTPUT TABLE     │
             │ (MERGE INTO   │    │ (automatically      │
             │  target...)   │    │  updated)           │
             └───────────────┘    └─────────────────────┘
```

### 3G: Same Scenario — Stream vs DT

**With Stream + Task:**
```sql
CREATE STREAM order_stream ON TABLE orders;
CREATE TASK apply_changes WAREHOUSE=wh SCHEDULE='1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('order_stream')
  AS
    MERGE INTO target t
      USING (SELECT *, metadata$action, metadata$isupdate FROM order_stream) s
      ON t.order_id = s.order_id
      WHEN MATCHED AND metadata$action='DELETE' AND NOT metadata$isupdate THEN DELETE
      WHEN MATCHED AND metadata$action='INSERT' THEN UPDATE SET t.product=s.product, t.price=s.price
      WHEN NOT MATCHED AND metadata$action='INSERT' THEN INSERT VALUES (s.order_id, s.product, s.price);
```

YOU had to: write MERGE logic, handle cases, create task, monitor staleness.

**With Dynamic Table:**
```sql
CREATE DYNAMIC TABLE dt_orders
  TARGET_LAG = '1 MINUTE'
  WAREHOUSE = wh
  AS SELECT order_id, product, price FROM orders;
```

YOU had to: write ONE SELECT statement. That's it.

**BOTH** processed the SAME net delta. The ONLY difference is WHO does the work.

### 3H: Key Differences in Behavior

**1. Offset Advancement:**
- Stream: SELECT alone does NOT advance. Only DML consumption advances.
- DT: Advances automatically after each successful refresh.

**2. Staleness:**
- Stream: CAN go stale if not consumed within retention period. Must recreate.
- DT: CANNOT go stale. Worst case: does a full refresh.

**3. What You Get Back:**
- Stream: Returns CHANGE RECORDS. Useful for custom logic (audit, SCD2).
- DT: Returns FINAL RESULT. Useful for "keep this table up-to-date."

**4. Net Delta Type:**
- Stream (Standard): Full delta (INSERT + UPDATE + DELETE)
- Stream (Append-Only): Only INSERTs. DTs don't have append-only mode.

### 3I: When to Use Which?

**Use Dynamic Table when:**
- You want "keep this query result fresh" with zero custom code
- Pipeline is a chain of transformations (DT → DT → DT)
- You don't need individual changes, just the result
- You want Snowflake to handle orchestration

**Use Stream + Task when:**
- You need CUSTOM logic (SCD Type 2, audit)
- You need stored procedures or external functions
- You need append-only tracking
- You need multiple consumers
- You need imperative control

### 3J: Newspaper Analogy

- **Printing Press** (Change Tracking Engine): Prints all the news. Same press, same paper.
- **Stream** = Newspaper delivered to YOUR door. YOU decide what to do. If you don't pick it up → delivery stops (staleness).
- **Dynamic Table** = Personal assistant who reads the news and updates your summary document automatically.

**SAME NEWS SOURCE. SAME PRINTING PRESS. Different delivery model.**

---

## Section 4: Hands-On Lab — Complete Internal Workflow

### Step 1: Create Source Table

> Internal: Table is EMPTY. No micro-partitions. Version = v0.

```sql
CREATE OR REPLACE TABLE OPENFLOW_DB.PUBLIC.dt_lab_orders (
    order_id    INT,
    customer    VARCHAR(100),
    product     VARCHAR(100),
    amount      DECIMAL(10,2),
    order_date  DATE
);
```

### Step 2: Insert Initial Data

> Internal: Creates P1 with 5 rows. Hidden ROW_IDs assigned. Registry: {P1}. Version v0→v1.

```sql
INSERT INTO OPENFLOW_DB.PUBLIC.dt_lab_orders VALUES
    (1, 'Alice', 'Laptop',    1299.99, '2024-01-15'),
    (2, 'Bob',   'Phone',      899.99, '2024-01-16'),
    (3, 'Carol', 'Tablet',     599.99, '2024-01-17'),
    (4, 'Dave',  'Monitor',    449.99, '2024-01-18'),
    (5, 'Eve',   'Keyboard',    79.99, '2024-01-19');

SELECT * FROM OPENFLOW_DB.PUBLIC.dt_lab_orders ORDER BY order_id;

SELECT ROW_COUNT, BYTES, LAST_ALTERED
FROM OPENFLOW_DB.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'PUBLIC' AND TABLE_NAME = 'DT_LAB_ORDERS';
```

### Step 3: Create Dynamic Table

> Internal: Full refresh. DT_P1 created with 5 rows + tax. Checkpoint T0 = v1.

```sql
CREATE OR REPLACE DYNAMIC TABLE OPENFLOW_DB.PUBLIC.dt_lab_order_summary
    TARGET_LAG = '1 MINUTE'
    WAREHOUSE = COMPUTE_WH
    AS
    SELECT order_id, customer, product, amount,
           amount * 0.10 AS tax, order_date
    FROM OPENFLOW_DB.PUBLIC.dt_lab_orders;

SELECT * FROM OPENFLOW_DB.PUBLIC.dt_lab_order_summary ORDER BY order_id;
```

### Step 4: INSERT 3 New Rows

> Internal: P2 created with 3 rows. Registry: {P1, P2}. Version v1→v2.

```sql
INSERT INTO OPENFLOW_DB.PUBLIC.dt_lab_orders VALUES
    (6, 'Frank', 'Webcam',  129.99, '2024-01-20'),
    (7, 'Grace', 'SSD',     199.99, '2024-01-21'),
    (8, 'Hank',  'RAM',      89.99, '2024-01-22');
```

### Step 5: UPDATE Existing Row

> Internal: P1 REMOVED, P1' created (id=2 amount changed). Registry: {P1', P2}. Version v2→v3.

```sql
UPDATE OPENFLOW_DB.PUBLIC.dt_lab_orders SET amount = 799.99 WHERE order_id = 2;
```

### Step 6: DELETE a Row

> Internal: P1' REMOVED, P1'' created (without id=4). Registry: {P1'', P2}. Version v3→v4.

```sql
DELETE FROM OPENFLOW_DB.PUBLIC.dt_lab_orders WHERE order_id = 4;
```

### Step 7: Net Delta Computation

```
Snapshot at T0: {P1}
Snapshot now:   {P1'', P2}

REMOVED: {P1} → 5 DELETEs
ADDED:   {P1'', P2} → 4 + 3 = 7 INSERTs

ROW_ID Matching:
  id=1: DELETE(1299.99) + INSERT(1299.99) → SAME → CANCEL
  id=2: DELETE(899.99)  + INSERT(799.99)  → DIFF → UPDATE
  id=3: DELETE(599.99)  + INSERT(599.99)  → SAME → CANCEL
  id=4: DELETE(449.99)  + no INSERT       → NET DELETE
  id=5: DELETE(79.99)   + INSERT(79.99)   → SAME → CANCEL
  id=6: no DELETE       + INSERT(129.99)  → NET INSERT
  id=7: no DELETE       + INSERT(199.99)  → NET INSERT
  id=8: no DELETE       + INSERT(89.99)   → NET INSERT

Final: 6 change records (3 cancelled out!)
```

### Step 8: DT Applies Net Delta

DT internally executes:
- ISUPDATE=TRUE pair → UPDATE id=2 (amount=799.99, tax=80.00)
- DELETE ISUPDATE=FALSE → DELETE id=4
- INSERT ISUPDATE=FALSE → INSERT ids 6,7,8 with tax calculated

Checkpoint advances: T0 → T1 (source version v4).

### Step 9: Verify

```sql
SELECT * FROM OPENFLOW_DB.PUBLIC.dt_lab_order_summary ORDER BY order_id;
-- Expected: 7 rows. id=2 updated. id=4 gone. ids 6,7,8 new.
```

### Step 10: Check Refresh History

```sql
SELECT refresh_version, refresh_action, state, state_message,
       refresh_trigger, refresh_start_time, refresh_end_time
FROM TABLE(OPENFLOW_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'OPENFLOW_DB.PUBLIC.DT_LAB_ORDER_SUMMARY'
))
ORDER BY refresh_start_time DESC LIMIT 10;
```

### Step 11: CHANGES Clause

```sql
INSERT INTO OPENFLOW_DB.PUBLIC.dt_lab_orders VALUES
    (9, 'Ivy', 'Headphones', 249.99, '2024-01-23');

SELECT order_id, customer, product, amount,
       METADATA$ACTION, METADATA$ISUPDATE, METADATA$ROW_ID
FROM OPENFLOW_DB.PUBLIC.dt_lab_orders
    CHANGES(INFORMATION => DEFAULT) AT(OFFSET => -300)
ORDER BY order_id;
```

### Step 12: Verify DT Picks Up New Insert

```sql
SELECT * FROM OPENFLOW_DB.PUBLIC.dt_lab_order_summary ORDER BY order_id;

SELECT refresh_version, refresh_action, state, refresh_trigger, refresh_start_time
FROM TABLE(OPENFLOW_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
    NAME => 'OPENFLOW_DB.PUBLIC.DT_LAB_ORDER_SUMMARY'
))
ORDER BY refresh_start_time DESC LIMIT 5;
```

### Step 13: Complete Lifecycle Summary

| Step | Action | Source Partitions | DT Partitions |
|------|--------|-------------------|---------------|
| 1 | CREATE TABLE | {} (empty) | N/A |
| 2 | INSERT 5 rows | {P1} | N/A |
| 3 | CREATE DT | {P1} | {DT_P1} FULL |
| 4 | INSERT 3 rows | {P1, P2} | {DT_P1} stale |
| 5 | UPDATE id=2 | {P1', P2} | {DT_P1} stale |
| 6 | DELETE id=4 | {P1'', P2} | {DT_P1} stale |
| 7 | DT REFRESH | {P1'', P2} | {DT_P1'} INCR. |
| 8 | INSERT id=9 | {P1'', P2, P3} | {DT_P1'} stale |
| 9 | DT REFRESH | {P1'', P2, P3} | {DT_P1''} INCR. |

### Complete Flow Diagram

```
YOUR DML
   │
   ▼
SOURCE TABLE ──→ Micro-partitions created/replaced (immutable files)
   │
   ▼
TABLE VERSIONS ──→ v1, v2, v3, v4... (each DML commit = new version)
   │
   ▼
DT SCHEDULER ──→ "Has source version changed since my checkpoint?"
   │                YES → trigger refresh
   ▼
SNAPSHOT DIFF ──→ Compare partition sets (T_old vs T_now)
   │                Find ADDED and REMOVED partitions
   ▼
ROW EXTRACTION ──→ Read rows from ADDED/REMOVED partitions
   │
   ▼
ROW_ID MATCHING ──→ Match DELETEs with INSERTs by ROW_ID
   │                 Same ROW_ID + different data = UPDATE
   │                 Same ROW_ID + same data = CANCEL (no change)
   ▼
NET DELTA ──→ Minimal set of INSERT/DELETE/UPDATE records
   │
   ▼
DT QUERY EXECUTION ──→ Run DT's SELECT with net delta as input
   │                    (applies transformations like tax calc)
   ▼
DT MICRO-PARTITIONS ──→ Apply result to DT's own storage
   │
   ▼
CHECKPOINT ADVANCE ──→ Record "I'm now caught up to version vN"
   │
   ▼
DONE ──→ DT is fresh. Ready to serve queries. Wait for next change.
```

### Cleanup

```sql
DROP DYNAMIC TABLE OPENFLOW_DB.PUBLIC.dt_lab_order_summary;
DROP TABLE OPENFLOW_DB.PUBLIC.dt_lab_orders;
```

---

## Section 5: Two Roles — Micro-Partitions for Net Delta, Metadata Columns for Data Retrieval

### The Two Jobs:

- **JOB 1: "WHAT CHANGED?"** ← Micro-Partitions answer this
- **JOB 2: "WHAT DO I DO WITH THE CHANGE?"** ← Metadata Columns answer this

### Phase 1: Micro-Partitions → "What Changed?"

**Why needed:** Immutable files mean Snowflake has a PERFECT RECORD of what the table looked like at any point. Comparison takes MILLISECONDS (comparing partition IDs, not scanning data).

**Without micro-partitions:** Full table scan every time. For billion-row tables = minutes/hours. With partitions = milliseconds.

**What they give us:** Lists of REMOVED and ADDED partitions — the raw material for Phase 2.

### Phase 2: Metadata Columns → "What Do I Do?"

After Phase 1, Snowflake has rows from ADDED/REMOVED partitions. Metadata columns tell the DT:

| Check | Action |
|-------|--------|
| ACTION='INSERT' + ISUPDATE=FALSE | INSERT new row into DT |
| ACTION='INSERT' + ISUPDATE=TRUE | UPDATE existing DT row |
| ACTION='DELETE' + ISUPDATE=FALSE | DELETE this row from DT |
| ACTION='DELETE' + ISUPDATE=TRUE | Old side of UPDATE (identifies which row) |

### Component Summary

| Component | Role |
|-----------|------|
| MICRO-PARTITIONS | Enable FAST change detection. Without: full table scan. |
| METADATA$ROW_ID (hidden) | Connects rows across old/new partitions. |
| METADATA$ACTION (generated) | Instruction: INSERT or DELETE this row. |
| METADATA$ISUPDATE (generated) | "This pair is an UPDATE, not genuine add/remove." |
| DT SELECT QUERY | Applies transformations to changed rows only. |
| CHECKPOINT | Remembers where DT left off. |

### Librarian Analogy

- **Micro-Partitions** = Shelves. Compare shelf labels to know what changed.
- **METADATA$ROW_ID** = Book's ISBN. Match ISBNs to know same book vs new book.
- **METADATA$ACTION** = Sticky notes: "ADD to catalog" / "REMOVE from catalog"
- **METADATA$ISUPDATE** = "This is a NEW EDITION, not a new book — update existing entry."

---

## Section 6: When to Use Dynamic Table vs Stream + Task + Merge

### Use Dynamic Table When:

1. Keep a query result **FRESH** — no custom logic needed
2. Chain of transformations (DT → DT → DT)
3. Don't need individual change records
4. Want **ZERO orchestration code**
5. Simple transformations: filters, joins, aggregations
6. Want Snowflake to auto-choose FULL vs INCREMENTAL

```sql
CREATE DYNAMIC TABLE daily_revenue
  TARGET_LAG = '10 MINUTES'
  WAREHOUSE = wh
  AS
  SELECT region, DATE_TRUNC('day', order_date) AS day,
         SUM(amount) AS total_revenue
  FROM orders GROUP BY region, day;
```

### Use Stream + Task + Merge When:

1. **CUSTOM LOGIC** — SCD Type 2, audit trails
2. **Stored procedures or external functions**
3. **CONDITIONAL processing** — if/else on changes
4. **APPEND-ONLY tracking** — ignore updates/deletes
5. **MULTIPLE CONSUMERS** — same changes to multiple targets
6. **ERROR HANDLING** — retry logic
7. **WRITE TO EXTERNAL SYSTEMS** — Kafka, S3, API

### Decision Guide

| Ask Yourself | Use |
|-------------|-----|
| "I just want this query to stay fresh" | Dynamic Table |
| "I need to keep history of changes" | Stream + Task + Merge |
| "I need to process changes with logic" | Stream + Task + Merge |
| "I want a chain of transformations" | Dynamic Table (chain) |
| "I need to send changes to another system" | Stream + Task |
| "I want zero maintenance" | Dynamic Table |
| "I need append-only event tracking" | Stream (APPEND_ONLY) |
| "I need multiple targets from one source" | Multiple Streams |
| "I need SCD Type 2 or audit trails" | Stream + Task + Merge |

> **Rule of Thumb:** Can you express your entire pipeline as a SELECT? → **Dynamic Table**. Need procedural logic? → **Stream + Task + Merge**.

---

## Section 7: SCD Type 2 with Dynamic Tables?

**Short Answer:** DT can **TRANSFORM** history. It **CANNOT CAPTURE** history.

### When DT CAN do SCD-2

If source already preserves history (append-only event log):

```sql
CREATE DYNAMIC TABLE dim_customer_scd2
  TARGET_LAG = '5 MINUTES'
  WAREHOUSE = wh
  AS
  SELECT customer_id, name, city,
         event_time AS valid_from,
         LEAD(event_time) OVER (PARTITION BY customer_id ORDER BY event_time) AS valid_to,
         CASE WHEN valid_to IS NULL THEN TRUE ELSE FALSE END AS is_current
  FROM customer_events;
```

### When DT CANNOT do SCD-2

If source uses UPDATEs (overwrites old values), old partition is gone. Only a Stream can see `DELETE(old)` + `INSERT(new)`.

### Best of Both Worlds

```
SOURCE TABLE (overwrites) → STREAM → TASK → HISTORY TABLE → DYNAMIC TABLE (SCD-2)
```

| Source Type | DT can SCD-2? | Need Stream+Task? |
|-------------|---------------|-------------------|
| Append-only event log | YES | NO |
| History table (pre-built) | YES | NO |
| Regular table (UPDATEs) | NO | YES (to capture) |
| Regular + Stream→History | YES (on history) | YES (for capture) |

> **Key Insight:** DT can TRANSFORM history. Stream + Task can CAPTURE history. Together they cover the full SCD-2 pipeline.
