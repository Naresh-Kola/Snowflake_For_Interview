# ❄️ Snowflake Table Cloning — Complete Guide with Internal Architecture

> A complete reference covering Data Retention, Cloning, Micro-Partitions, Fail Safe, and Time Travel — with real examples and internal working architecture.

---

## 📋 Table of Contents

1. [Scenario Overview](#scenario-overview)
2. [Q1 — Will Cloned Table Hold Data After Retention Ends?](#q1--will-cloned-table-hold-data-after-retention-ends)
3. [Q2 — Can Cloned Table Access Current Data Only? No Time Travel?](#q2--can-cloned-table-access-current-data-only-no-time-travel)
4. [Q3 — Micro-Partitions, Zero Storage & Fail Safe Ownership](#q3--micro-partitions-zero-storage--fail-safe-ownership)
5. [Q4 — Can We Time Travel on Clone to Get Original Table's Old Data?](#q4--can-we-time-travel-on-clone-to-get-original-tables-old-data)
6. [Internal Architecture Summary](#internal-architecture-summary)
7. [Quick Reference Cheat Sheet](#quick-reference-cheat-sheet)

---

## Scenario Overview

| Detail               | Value                          |
|----------------------|--------------------------------|
| Table Name           | `employee`                     |
| Data Retention Period| 30 days                        |
| Days Remaining       | 2 days                         |
| Clone Created With   | 25 days back data              |
| Clone Created On     | May 16, 2025                   |
| Retention Ends On    | May 18, 2025                   |

```
Timeline:
─────────────────────────────────────────────────────────►
Apr 18          May 16        May 18         May 25
  │               │             │               │
  │               │             │               │
  ▼               ▼             ▼               ▼
[Data Start]  [Clone Made]  [Retention    [Fail Safe
30 days back  25 days data   Ends]         Ends]
```

---

## Q1 — Will Cloned Table Hold Data After Retention Ends?

### ✅ Yes — If It's a Physical / Independent Clone

When you clone the `employee` table, Snowflake creates an **independent copy** of the data at that point in time. The original table's retention policy does **NOT** cascade to the clone.

### Types of Clones

#### ✅ Physical Clone (Safe)

```sql
-- Full physical clone of employee table
CREATE TABLE employee_clone AS
SELECT * FROM employee
WHERE created_date >= CURRENT_DATE - INTERVAL '25 days';

-- OR using Snowflake native zero-copy clone
CREATE TABLE employee_clone CLONE employee;
```

#### ❌ Logical Clone / View (Not Safe)

```sql
-- This is NOT a real clone — it's just a view
-- Data will be lost when original is purged
CREATE VIEW employee_clone AS
SELECT * FROM employee
WHERE created_date >= CURRENT_DATE - INTERVAL '25 days';
```

### What Happens After Retention Ends

```
Day 0 — Today (May 16)
├── employee table         → 30 days of data (Apr 18 → May 16)
└── employee_clone         → 25 days of data (Apr 21 → May 16) ← Independent Copy

Day +2 — Retention Ends (May 18)
├── employee table         → OLD data (before Apr 18) is PURGED ❌
└── employee_clone         → ALL 25 days STILL EXISTS ✅ (not affected)
```

### Verification After Retention Ends

```sql
-- Check row counts before retention ends
SELECT COUNT(*) FROM employee
WHERE created_date >= CURRENT_DATE - INTERVAL '25 days';

-- Should match clone count
SELECT COUNT(*) FROM employee_clone;

-- Confirm date range in clone after retention purge
SELECT MIN(created_date), MAX(created_date), COUNT(*)
FROM employee_clone;
```

### Safe Backup Process (Recommended)

```sql
-- STEP 1: Create backup table
CREATE TABLE employee_backup_25d (
    emp_id      INT,
    name        VARCHAR(100),
    department  VARCHAR(100),
    created_at  DATE
);

-- STEP 2: Insert 25 days of data explicitly
INSERT INTO employee_backup_25d
SELECT * FROM employee
WHERE created_at >= CURRENT_DATE - INTERVAL '25 days';

-- STEP 3: Verify
SELECT COUNT(*) FROM employee_backup_25d;
```

### Summary

| Clone Type                        | After Retention Ends          | Safe? |
|-----------------------------------|-------------------------------|-------|
| Physical `CREATE TABLE AS SELECT` | ✅ Data preserved independently | ✅ Yes |
| View / Logical reference          | ❌ Loses data with source       | ❌ No  |
| Snowflake Zero-Copy Clone         | ⚠️ Depends on Fail Safe        | ⚠️ Verify |
| Explicit `INSERT INTO backup`     | ✅ Always safe                  | ✅ Yes |

---

## Q2 — Can Cloned Table Access Current Data Only? No Time Travel?

### ✅ Correct — Clone is a Frozen Snapshot

The cloned table **only holds the snapshot of data at the time of cloning**. It:
- Cannot time travel to see older data from the original table
- Cannot fetch new data added after the clone was created
- Is completely frozen at the moment of cloning

### Visual Explanation

```
Original Employee Table
├── Time Travel History: Apr 18 → May 18  (30 days full history)
└── Can look back up to 30 days

employee_clone (created May 16)
├── Contains: Apr 21 → May 16 data only (frozen snapshot)
├── NO data before Apr 21 ❌
├── NO data after May 16 ❌
└── Cannot query original's history ❌
```

### Real Example

```sql
-- Clone was created on May 16
CREATE TABLE employee_clone CLONE employee;

-- ✅ Query data within clone's snapshot range
SELECT * FROM employee_clone
WHERE created_date = '2025-05-15';  -- Works! (before clone date)

-- ❌ Query data added AFTER clone creation
SELECT * FROM employee_clone
WHERE created_date = '2025-05-17';  -- Returns NOTHING (not in clone)

-- ✅ Original table can still see May 17 data
SELECT * FROM employee
WHERE created_date = '2025-05-17';  -- Works on original!
```

### The Photograph Analogy 📸

> The clone is like a **photograph** taken on May 16.
> - It captures exactly what existed at that moment
> - It does NOT update when new employees are added
> - It does NOT go back in time before the photo was taken
> - It is NOT affected when the original data changes or is deleted

### Capability Comparison

| Capability                        | Original Table | Cloned Table          |
|-----------------------------------|----------------|-----------------------|
| See current data                  | ✅             | ✅ (as of clone date) |
| Time Travel (past history)        | ✅             | ❌ No                 |
| Auto-update with new rows         | ✅             | ❌ No                 |
| Affected by retention purge       | ✅             | ❌ No (independent)   |
| Query data after clone date       | ✅             | ❌ No                 |

---

## Q3 — Micro-Partitions, Zero Storage & Fail Safe Ownership

### Internal Architecture: How Zero-Copy Clone Works

When you run `CREATE TABLE employee_clone CLONE employee`, Snowflake does **NOT** copy data physically. Instead it creates **metadata pointers** to the same micro-partitions.

#### Phase 1: Clone Created — Zero Storage Cost

```
employee (original)
├── Micro-partition P1  [Apr 18 - Apr 25]  ← Active
├── Micro-partition P2  [Apr 25 - May 02]  ← Active
├── Micro-partition P3  [May 02 - May 10]  ← Active
└── Micro-partition P4  [May 10 - May 16]  ← Active

employee_clone (just created)
├── Pointer → P1  ┐
├── Pointer → P2  │  No new storage created!
├── Pointer → P3  │  Only metadata pointers
└── Pointer → P4  ┘

Storage Cost = $0  (Zero Copy Clone ✅)
```

```sql
-- Zero-copy clone in Snowflake
CREATE TABLE employee_clone CLONE employee;

-- Verify storage usage (should show minimal for clone)
SELECT TABLE_NAME, ACTIVE_BYTES, TIME_TRAVEL_BYTES, FAILSAFE_BYTES
FROM INFORMATION_SCHEMA.TABLE_STORAGE_METRICS
WHERE TABLE_NAME IN ('EMPLOYEE', 'EMPLOYEE_CLONE');
```

#### Phase 2: Original Table Retention Expires — Partitions Move to Fail Safe

```
After May 18 (Retention Ends):

employee (original)
├── P1 → moves to FAIL SAFE ⚠️  (7 day window, Snowflake managed)
├── P2 → moves to FAIL SAFE ⚠️
├── P3 → Still Active ✅
└── P4 → Still Active ✅

employee_clone was pointing to P1 & P2...
Snowflake detects clone still needs P1 & P2 → Takes ownership!
```

#### Phase 3: Clone Takes Ownership of Fail Safe Partitions

```
employee_clone (after retention ends)
├── P1 → NOW OWNED independently by clone ✅  ← Storage cost begins!
├── P2 → NOW OWNED independently by clone ✅  ← Storage cost begins!
├── Pointer → P3  (still shared with original)
└── Pointer → P4  (still shared with original)

Storage Cost = You now PAY for P1 & P2
               Clone took full ownership to preserve data
```

### Complete Timeline

```
TIMELINE
─────────────────────────────────────────────────────────────────►

Clone Created     Retention Ends      Fail Safe Ends
[May 16]          [May 18]            [May 25]
    │                 │                   │
    ▼                 ▼                   ▼
Zero Storage      Clone owns P1,P2    If clone dropped here
Just pointers     Storage cost hits   → P1,P2 DESTROYED ❌
P1,P2,P3,P4       P3,P4 still shared  If clone alive
all shared        with original       → P1,P2 SAFE in clone ✅
```

### Storage Cost Monitoring

```sql
-- Monitor when storage cost increases for clone
SELECT
    TABLE_NAME,
    ACTIVE_BYTES / (1024*1024*1024)      AS ACTIVE_GB,
    TIME_TRAVEL_BYTES / (1024*1024*1024) AS TIME_TRAVEL_GB,
    FAILSAFE_BYTES / (1024*1024*1024)    AS FAILSAFE_GB
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME IN ('EMPLOYEE', 'EMPLOYEE_CLONE')
ORDER BY TABLE_NAME;
```

### Key Rules

| Situation                              | What Happens to Clone              |
|----------------------------------------|------------------------------------|
| Original data is active                | Points to shared micro-partitions (zero cost) |
| Original data moves to Time Travel     | Clone still points, no extra cost  |
| Original data moves to Fail Safe       | Clone **takes ownership**, storage cost begins |
| Fail Safe expires (after 7 days)       | Clone's own partitions survive ✅  |
| Clone dropped before Fail Safe ends    | Partitions released, data lost ❌  |

---

## Q4 — Can We Time Travel on Clone to Get Original Table's Old Data?

### ❌ No — Absolutely Not Possible

The clone's Time Travel **only starts from the moment the clone was created**. It has **zero memory** of the original table's history.

### Why It Cannot Work

```
Original Employee Table
├── Time Travel History: Apr 18 → May 18  (30 days full history)
└── History lives in ORIGINAL table's metadata only

employee_clone (born on May 16)
├── Time Travel starts FROM May 16 onwards ONLY
├── No knowledge of anything before May 16 ❌
└── Cannot reach into original table's history ❌
```

### Proof with SQL

```sql
-- Clone created on May 16
CREATE TABLE employee_clone CLONE employee;

-- ❌ Try to time travel BEFORE clone creation — FAILS
SELECT * FROM employee_clone
AT (TIMESTAMP => '2025-04-18 00:00:00');
-- ERROR: Time travel data not available for table EMPLOYEE_CLONE
--        before 2025-05-16 (clone creation timestamp)

-- ✅ Time travel AFTER clone creation — WORKS
SELECT * FROM employee_clone
AT (TIMESTAMP => '2025-05-17 12:00:00');
-- Works! May 17 is after clone was created on May 16

-- ✅ Time travel using OFFSET (seconds before now)
SELECT * FROM employee_clone
AT (OFFSET => -3600);  -- 1 hour ago — works if after May 16
```

### Time Travel Range Visualization

```
ORIGINAL TABLE Time Travel Range
◄─────────────────────────────────────────────────┤
Apr 18                                          May 18
  ↑                                               ↑
  └── Full 30 days history available              └── Today


CLONE Time Travel Range
                                   ◄──────────────┤
                                 May 16          May 18
                                   ↑
                                   └── Clone created here
                                       Time Travel ONLY from this point
                                       NOTHING before this ❌
```

### What If You Need Old Historical Data?

```sql
-- OPTION 1: Query original table with Time Travel (before it expires) ✅
SELECT * FROM employee
AT (TIMESTAMP => '2025-04-18 00:00:00');

-- OPTION 2: Clone the original AT a specific past point ✅
-- This physically captures the old data into a new clone
CREATE TABLE employee_clone_april
CLONE employee
AT (TIMESTAMP => '2025-04-18 00:00:00');
--                ↑
--   This creates a clone as it existed on Apr 18
--   Old data is now physically in the new clone

-- OPTION 3: Too late — retention expired ❌
-- Data is GONE. Only Snowflake support (Fail Safe) can help
-- Must raise a support ticket within 7-day Fail Safe window
```

### Clone AT Specific Historical Point — Internal Working

```sql
-- When you clone at a past timestamp:
CREATE TABLE employee_april_snapshot
CLONE employee
AT (TIMESTAMP => '2025-04-18 00:00:00');

-- Internally Snowflake:
-- 1. Looks up micro-partitions that were active on Apr 18
-- 2. Creates pointers to THOSE specific historical partitions
-- 3. New clone reflects the state of employee on Apr 18
-- 4. No data movement — still zero-copy at creation!
```

### Summary Table

| Time Travel Query                            | Works?  |
|----------------------------------------------|---------|
| Clone's own history (after clone date)       | ✅ Yes  |
| Before clone creation date via clone         | ❌ No   |
| Original table's history via clone           | ❌ No   |
| Clone at specific past timestamp of original | ✅ Yes (done at clone time) |
| After retention expired on original          | ❌ No   |

> **Think of it this way** — the clone is a **newborn child 👶**. It has its own life from birth (clone date) onwards. It **cannot remember** what happened before it was born, even though its parent (original table) has that memory! 🧠

---

## Internal Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SNOWFLAKE STORAGE LAYERS                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ACTIVE STORAGE                                                    │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │  employee table                                          │     │
│   │  P1 | P2 | P3 | P4   ← Live queryable data              │     │
│   └──────────────────────────────────────────────────────────┘     │
│                │                                                    │
│                ▼  (after DML changes or retention period)           │
│   TIME TRAVEL (0-90 days configurable)                              │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │  Old versions of micro-partitions preserved here         │     │
│   │  Queryable via AT / BEFORE syntax                        │     │
│   └──────────────────────────────────────────────────────────┘     │
│                │                                                    │
│                ▼  (after time travel period ends)                   │
│   FAIL SAFE (7 days, Snowflake managed, not user queryable)         │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │  Last resort recovery — only via Snowflake support       │     │
│   │  Clone takes OWNERSHIP of its needed partitions here     │     │
│   └──────────────────────────────────────────────────────────┘     │
│                │                                                    │
│                ▼  (after fail safe ends)                            │
│   PERMANENTLY DELETED ❌                                            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

CLONE RELATIONSHIP:
employee_clone ──(pointers)──► P1, P2, P3, P4 (shared, zero cost)
                                     │
                          When P1,P2 hit Fail Safe:
employee_clone ──(owns)──► P1, P2  (independent, storage cost)
employee_clone ──(pointers)──► P3, P4 (still shared)
```

---

## Quick Reference Cheat Sheet

```sql
-- Create a zero-copy clone
CREATE TABLE employee_clone CLONE employee;

-- Create a clone from a specific point in time
CREATE TABLE employee_clone_old
CLONE employee
AT (TIMESTAMP => '2025-04-18 00:00:00');

-- Clone with offset (seconds)
CREATE TABLE employee_clone_yesterday
CLONE employee
AT (OFFSET => -86400);  -- 24 hours ago

-- Time travel on clone (only works after clone creation date)
SELECT * FROM employee_clone
AT (TIMESTAMP => '2025-05-17 00:00:00');

-- Check storage metrics for both tables
SELECT TABLE_NAME, ACTIVE_BYTES, TIME_TRAVEL_BYTES, FAILSAFE_BYTES
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME IN ('EMPLOYEE', 'EMPLOYEE_CLONE');

-- Set retention period on clone independently
ALTER TABLE employee_clone
SET DATA_RETENTION_TIME_IN_DAYS = 7;

-- Drop clone when no longer needed
DROP TABLE employee_clone;
```

### Golden Rules to Remember

| Rule | Description |
|------|-------------|
| 📸 Clone = Snapshot | Frozen at creation time, no auto-updates |
| 💰 Zero Cost Initially | Only metadata pointers, no data copied |
| 🔄 Fail Safe Ownership | Clone owns partitions when original expires |
| ⏰ Time Travel Limit | Only from clone creation date onwards |
| 🛡️ Independent Retention | Clone has its own retention policy |
| ❌ No History Access | Cannot access original table's history via clone |

---

*Generated from live Q&A session on Snowflake Cloning & Data Retention Concepts*
*Date: May 18, 2025*
