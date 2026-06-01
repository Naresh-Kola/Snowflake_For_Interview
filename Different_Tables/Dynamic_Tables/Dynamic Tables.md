# Dynamic Tables — Complete Internal Workflow

## 1. Core Concepts

| Concept | What It Is |
|---------|-----------|
| **Micro-Partition** | Immutable 50-500 MB compressed file. Every change creates NEW partitions and removes OLD ones. |
| **Checkpoint** | A bookmark: "DT has processed all changes up to this table version." Advances after each refresh. |
| **Net Delta** | The FINAL EFFECT of all changes between two checkpoints. Intermediate states are invisible. |
| **METADATA$ACTION** | 'INSERT' or 'DELETE' — what happened to this row. |
| **METADATA$ISUPDATE** | TRUE if an INSERT+DELETE pair represent the SAME row being modified (not a genuine add/remove). |
| **METADATA$ROW_ID** | Hidden unique ID per row. Used to match DELETE and INSERT records as belonging to the same row. |

### How They Work Together
- **Step 1:** Micro-partitions FIND the changes (compare file lists — instant)
- **Step 2:** Metadata columns LABEL each changed row (insert it? delete it? update it?)

---

## 2. Complete 10-Step Internal Process

**Scenario:** Source table has `{P1}` with rows 1-5. DT was created (checkpoint T0). Then: INSERT 3 rows, UPDATE row 2, DELETE row 4. DT refreshes.

| Step | Action | Detail |
|------|--------|--------|
| 1 | Scheduler wakes up | "Source version changed (v1 → v4). Time to refresh." |
| 2 | Fetch partition lists | Checkpoint: `{P1}`, Current: `{P1'', P2}` |
| 3 | Partition set difference | REMOVED = `{P1}`, ADDED = `{P1'', P2}` (milliseconds, no data scan) |
| — | **Micro-partitions job done** | **Now metadata columns take over** |
| 4 | Tag rows from changed partitions | Rows from REMOVED P1 → ACTION='DELETE' (5 rows), Rows from ADDED P1''/P2 → ACTION='INSERT' (7 rows) |
| 5 | Match ROW_IDs | id=1,3,5: same data → CANCEL. id=2: diff → ISUPDATE=TRUE. id=4: DELETE only. id=6,7,8: INSERT only. |
| 6 | Final net delta | 6 change records (3 cancelled out) |
| 7 | Run DT's SELECT on changed rows | Computes transformations (e.g., tax = amount * 0.10) |
| 8 | Apply to DT storage | UPDATE row 2, DELETE row 4, INSERT rows 6,7,8 |
| 9 | DT micro-partitions rebuilt | Old DT_P1 removed, new DT_P1' created |
| 10 | Checkpoint advances (T0 → T1) | Next refresh starts from here |

### Net Delta Result

| METADATA$ACTION | METADATA$ISUPDATE | DATA |
|-----------------|-------------------|------|
| DELETE | TRUE | (2, Bob, Phone, 899.99) |
| INSERT | TRUE | (2, Bob, Phone, 799.99) |
| DELETE | FALSE | (4, Dave, Monitor, 449.99) |
| INSERT | FALSE | (6, Frank, Webcam, 129.99) |
| INSERT | FALSE | (7, Grace, SSD, 199.99) |
| INSERT | FALSE | (8, Hank, RAM, 89.99) |

> 3 DML ops → 6 change records (3 unchanged rows cancelled out)

---

## 3. Net Delta — Why Intermediate States Are Invisible

Net delta compares ONLY two snapshots: checkpoint vs now. Anything born and died in between is invisible.

### Example: INSERT → UPDATE → UPDATE (same row)

- Checkpoint T1: row 4 does NOT exist
- 10:02 INSERT row 4, price=499 → P3 created
- 10:04 UPDATE row 4, price=599 → P3 removed, P3' created
- 10:06 UPDATE row 4, price=749 → P3' removed, P3'' created
- 10:10 DT refreshes (T2)

**Result:** 1 INSERT (id=4, price=749). Prices 499 and 599 never existed from DT's perspective.

### Partition Visibility Rule

| In T1? | In T2? | Result |
|--------|--------|--------|
| YES | YES | SKIP (unchanged) |
| YES | NO | REMOVED → rows become DELETEs |
| NO | YES | ADDED → rows become INSERTs |
| NO | NO | INVISIBLE (born and died between snapshots) |

### Net Delta Combinations

| Operations Between Checkpoints | What DT Processes |
|-------------------------------|-------------------|
| INSERT | INSERT (final value) |
| INSERT → UPDATE(s) | INSERT (final value only) |
| INSERT → DELETE | NOTHING (cancelled out) |
| UPDATE(s) | DELETE(old) + INSERT(final) |
| UPDATE → DELETE | DELETE (original from T1) |
| DELETE | DELETE |
| DELETE → RE-INSERT | DELETE(old) + INSERT(new) |
| No change | NOTHING (zero work) |

> **MAX per row:** 2 records (1 DELETE + 1 INSERT), no matter how many DML operations happened.

---

## 4. Streams vs Dynamic Tables

Both use the SAME change tracking engine (partition diff + metadata columns). The difference is WHO consumes the net delta.

| Aspect | Stream | Dynamic Table |
|--------|--------|---------------|
| Change engine | Same | Same |
| Net delta logic | Same | Same |
| Stores data? | NO (just a pointer) | YES (materialized) |
| Who writes MERGE? | YOU | SNOWFLAKE |
| Who schedules? | YOU (Task) | SNOWFLAKE (lag) |
| Can go stale? | YES | NO (auto-managed) |
| You see change records? | YES | NO (internal) |
| Style | Imperative | Declarative |

### Architecture

```
SOURCE TABLE (micro-partitions)
       │
       ▼
CHANGE TRACKING ENGINE
(partition versioning + hidden CDC columns + snapshot comparison)
       │
       ├──→ STREAM (bookmark, YOU query it, YOU consume, returns CDC)
       │         └──→ YOUR TASK (MERGE INTO target...)
       │
       └──→ DYNAMIC TABLE (internal offset, auto-refreshes, stores result)
                  └──→ DT OUTPUT TABLE (automatically updated)
```

---

## 5. Two Roles — Micro-Partitions & Metadata Columns

| Component | Role |
|-----------|------|
| **MICRO-PARTITIONS** | Enable FAST change detection. Tell us WHICH FILES changed. Without them: full table scan every time. |
| **METADATA$ROW_ID** (hidden) | Connects rows across old and new partitions. Without it: can't tell if a row is modified or new. |
| **METADATA$ACTION** (generated) | Tells DT: "this row should be INSERTED" or "DELETED." The instruction for the MERGE. |
| **METADATA$ISUPDATE** (generated) | Tells DT: "this pair is an UPDATE — modify existing row, don't add new." |
| **DT SELECT QUERY** | Applies YOUR transformations to only the changed rows. |
| **CHECKPOINT** | Remembers where DT left off. Without it: reprocess all history. |

---

## 6. When to Use Dynamic Table vs Stream + Task + Merge

### Use Dynamic Table When:

1. You just want to keep a query result **FRESH** — no custom logic needed
2. Your pipeline is a **chain of transformations** (DT → DT → DT)
3. You DON'T need to see individual change records
4. You want **ZERO orchestration code**
5. Simple transformations: filters, joins, aggregations, window functions
6. You want Snowflake to automatically choose FULL vs INCREMENTAL

### Use Stream + Task + Merge When:

1. You need **CUSTOM LOGIC** (SCD Type 2, audit trails)
2. You need to call **stored procedures or external functions**
3. You need **CONDITIONAL processing** (if/else on changes)
4. You need **APPEND-ONLY tracking** (ignore updates/deletes)
5. You need **MULTIPLE CONSUMERS** for same changes
6. You need **ERROR HANDLING** and retry logic
7. You need to **WRITE TO EXTERNAL SYSTEMS** (Kafka, S3, API)

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

## 7. SCD Type 2 with Dynamic Tables?

**Short Answer:** A DT can **TRANSFORM** history into SCD-2 format, but it **CANNOT CAPTURE** history from a table that overwrites data.

### When DT CAN do SCD-2

If your source already preserves history (append-only event log):

```sql
CREATE DYNAMIC TABLE dim_customer_scd2
  TARGET_LAG = '5 MINUTES'
  WAREHOUSE = wh
  AS
  SELECT
    customer_id, name, city,
    event_time AS valid_from,
    LEAD(event_time) OVER (PARTITION BY customer_id ORDER BY event_time) AS valid_to,
    CASE WHEN valid_to IS NULL THEN TRUE ELSE FALSE END AS is_current
  FROM customer_events;
```

### When DT CANNOT do SCD-2

If source uses UPDATEs (overwrites old values), only a Stream can see `DELETE(old)` + `INSERT(new)`.

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

---

## 8. Complete Flow Diagram

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
   │               YES → trigger refresh
   ▼
SNAPSHOT DIFF ──→ Compare partition sets (T_old vs T_now)
   │               Find ADDED and REMOVED partitions
   ▼
ROW EXTRACTION ──→ Read rows from ADDED/REMOVED partitions
   │
   ▼
ROW_ID MATCHING ──→ Match DELETEs with INSERTs by ROW_ID
   │                 Same ROW_ID + different data = UPDATE
   │                 Same ROW_ID + same data = CANCEL
   ▼
NET DELTA ──→ Minimal set of INSERT/DELETE/UPDATE records
   │
   ▼
DT QUERY EXECUTION ──→ Run DT's SELECT on changed rows only
   │
   ▼
DT MICRO-PARTITIONS ──→ Apply result to DT's own storage
   │
   ▼
CHECKPOINT ADVANCE ──→ "I'm caught up to version vN"
   │
   ▼
DONE ──→ DT is fresh. Wait for next change.
```
