# SCD Type 4 — Complete Code Explanation with Actual Data

> Every section below walks through the actual SQL code and shows exactly what
> data exists in each table before and after that block runs.
> Late arrival handling is explained in full detail with a worked example.

---

## Table of Contents

1. [Table Setup — What Each Table Does](#1-table-setup)
2. [Procedure Variables — What They Track](#2-procedure-variables)
3. [Guard 1 — Idempotency Check](#3-guard-1--idempotency-check)
4. [Guard 2 — Staging Validation](#4-guard-2--staging-validation)
5. [Mark Batch as STARTED](#5-mark-batch-as-started)
6. [Step 1 — Late Arrival Detection and Insert](#6-step-1--late-arrival-detection-and-insert)
7. [Step 2 — Push Old Row to History (Normal Change)](#7-step-2--push-old-row-to-history-normal-change)
8. [Step 3 — MERGE into Current Table](#8-step-3--merge-into-current-table)
9. [Step 4 — Mark Batch COMPLETED](#9-step-4--mark-batch-completed)
10. [Exception Handler](#10-exception-handler)
11. [Complete Data State After Every Batch](#11-complete-data-state-after-every-batch)
12. [Query Patterns Explained](#12-query-patterns-explained)

---

## The Story We Will Follow

We have two customers. We run five batches. Each batch demonstrates one concept.

| Batch | What happens | Concept demonstrated |
|---|---|---|
| BATCH_001 | Naresh and Priya loaded for first time | First run |
| BATCH_001 (re-run) | Same batch triggered again | Idempotency guard |
| BATCH_002 | Naresh moves city Hyderabad → Bangalore | Normal change |
| BATCH_003 | Same data, nothing changed | No-op / hash match |
| BATCH_004 | Naresh's email becomes NULL | NULL handling |
| BATCH_005 | A row arrives for Naresh dated BEFORE existing data | **Late arrival** |

---

## 1. Table Setup

### The sequence — surrogate key generator

```sql
CREATE SEQUENCE IF NOT EXISTS seq_customer_sk START 1 INCREMENT 1;
```

**What this does:** Every time a new customer is inserted into `dim_customer`,
the sequence generates the next number (1, 2, 3...) as the surrogate key
(`customer_sk`). This key never changes for a customer even if their data changes.

---

### Staging table — raw incoming data

```sql
CREATE OR REPLACE TRANSIENT TABLE raw.stg_customer (
    customer_id       NUMBER         NOT NULL,
    first_name        VARCHAR(100),
    last_name         VARCHAR(100),
    email             VARCHAR(255),
    city              VARCHAR(100),
    _src_ts           TIMESTAMP_NTZ  NOT NULL,
    _batch_id         VARCHAR(50)    NOT NULL
);
```

**Key column: `_src_ts`** — this is the timestamp from the SOURCE SYSTEM, not
the time the row was loaded. This is critical for late arrival detection.

**Key column: `_batch_id`** — links every row to a specific run. Used by the
idempotency guard to know which rows belong to which batch.

**TRANSIENT** — Snowflake does not keep fail-safe backups for transient tables.
Staging is throwaway data, so this saves storage cost.

**Sample data loaded for BATCH_001:**

| customer_id | first_name | last_name | email | city | _src_ts | _batch_id |
|---|---|---|---|---|---|---|
| 1001 | Naresh | Kumar | naresh@gmail.com | Hyderabad | 2024-06-01 09:00 | BATCH_001 |
| 1002 | Priya | Sharma | priya@gmail.com | Mumbai | 2024-06-01 09:00 | BATCH_001 |

---

### Current table — always the latest version

```sql
CREATE TABLE IF NOT EXISTS dim.dim_customer (
    customer_sk       NUMBER         NOT NULL PRIMARY KEY,
    customer_id       NUMBER         NOT NULL UNIQUE,
    first_name        VARCHAR(100),
    last_name         VARCHAR(100),
    email             VARCHAR(255),
    city              VARCHAR(100),
    effective_from    TIMESTAMP_NTZ  NOT NULL,
    hash_key          VARCHAR(64)    NOT NULL,
    _batch_id         VARCHAR(50)    NOT NULL,
    updated_at        TIMESTAMP_NTZ  NOT NULL
);
```

**Key column: `customer_sk`** — surrogate key from the sequence. One value per
customer, assigned at first load, never changes.

**Key column: `effective_from`** — when THIS version of the record became active.
Comes from `_src_ts` in staging, not from `CURRENT_TIMESTAMP()`. This makes
reruns produce the same result.

**Key column: `hash_key`** — SHA2 fingerprint of all tracked columns. If this
changes between batches, a change has occurred. If it is the same, nothing
happened. One comparison instead of checking every column individually.

**Rule:** Always exactly 1 row per customer. The latest version of their data.

---

### History table — only old expired versions

```sql
CREATE TABLE IF NOT EXISTS dim.dim_customer_hist (
    hist_sk           NUMBER         NOT NULL PRIMARY KEY
                                     DEFAULT seq_customer_sk.NEXTVAL,
    customer_sk       NUMBER         NOT NULL,
    customer_id       NUMBER         NOT NULL,
    first_name        VARCHAR(100),
    last_name         VARCHAR(100),
    email             VARCHAR(255),
    city              VARCHAR(100),
    valid_from        TIMESTAMP_NTZ  NOT NULL,
    valid_to          TIMESTAMP_NTZ  NOT NULL,
    hash_key          VARCHAR(64)    NOT NULL,
    _batch_id         VARCHAR(50)    NOT NULL,
    _is_late_arrival  BOOLEAN        NOT NULL DEFAULT FALSE,
    _inserted_at      TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP()
)
CLUSTER BY (customer_id, valid_from);
```

**Key column: `valid_from`** — when this version of the record started being true.

**Key column: `valid_to`** — when this version stopped being true. This is always
the `effective_from` of the next version that replaced it.

**Key column: `_is_late_arrival`** — TRUE if this row arrived after a newer
version was already loaded. Lets you identify backfilled rows in audits.

**`CLUSTER BY (customer_id, valid_from)`** — Snowflake organises the physical
storage around these two columns. Point-in-time queries that filter by
`customer_id` and a date range will scan far fewer micro-partitions.

**Rule:** A row only enters this table when a newer version replaces it, or when
a late arrival fills a historical gap. The first version of a customer is NOT
in this table until it gets replaced.

---

### Watermark table — idempotency guard and audit log

```sql
CREATE TABLE IF NOT EXISTS audit.etl_watermark (
    batch_id          VARCHAR(50)    NOT NULL PRIMARY KEY,
    entity            VARCHAR(100)   NOT NULL,
    status            VARCHAR(20)    NOT NULL,
    rows_staged       NUMBER,
    rows_inserted     NUMBER,
    rows_updated      NUMBER,
    rows_expired      NUMBER,
    rows_late_arrival NUMBER,
    started_at        TIMESTAMP_NTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    completed_at      TIMESTAMP_NTZ,
    error_message     VARCHAR(4000)
);
```

**Key column: `status`** — three possible values:

| Status | Meaning | Can retry? |
|---|---|---|
| STARTED | Procedure began but has not finished | Yes — MERGE resets it |
| COMPLETED | All steps succeeded | Blocked — Guard 1 returns SKIPPED |
| FAILED | Exception occurred mid-run | Yes — MERGE resets it |

**Key column: `rows_late_arrival`** — count of late arrival rows processed in
this batch. If this is non-zero you know historical data was backfilled.

---

## 2. Procedure Variables

```sql
DECLARE
    v_rows_staged       NUMBER  DEFAULT 0;
    v_rows_inserted     NUMBER  DEFAULT 0;
    v_rows_updated      NUMBER  DEFAULT 0;
    v_rows_expired      NUMBER  DEFAULT 0;
    v_rows_late         NUMBER  DEFAULT 0;
    v_now               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP();
    v_result            OBJECT;
```

**What each variable tracks:**

| Variable | Tracks |
|---|---|
| `v_rows_staged` | Total rows in staging for this batch |
| `v_rows_inserted` | New customers added to dim_customer |
| `v_rows_updated` | Existing customers updated in dim_customer |
| `v_rows_expired` | Rows pushed to history (old versions archived) |
| `v_rows_late` | Late arrival rows inserted into history |
| `v_now` | Captured once at procedure start — used for all `updated_at` stamps |
| `v_result` | The JSON object returned to the caller at the end |

**Why capture `v_now` once at the top?** If you call `CURRENT_TIMESTAMP()`
multiple times inside a procedure, each call may return a slightly different
value. Capturing it once ensures all timestamps written in the same run are
identical and consistent.

---

## 3. Guard 1 — Idempotency Check

```sql
LET already_done RESULTSET := (
    SELECT 1
    FROM   audit.etl_watermark
    WHERE  batch_id = :p_batch_id
      AND  entity   = 'DIM_CUSTOMER'
      AND  status   = 'COMPLETED'
);

IF (ROWCOUNT(already_done) > 0) THEN
    RETURN OBJECT_CONSTRUCT(
        'status',   'SKIPPED',
        'batch_id', :p_batch_id,
        'message',  'Batch already successfully processed — no action taken'
    );
END IF;
```

**What this does:** Before touching any data, the procedure checks whether this
exact batch already ran to completion. If it did, it exits immediately.

### Scenario: BATCH_001 re-run

After BATCH_001 completed, the watermark table looks like this:

| batch_id | entity | status | completed_at |
|---|---|---|---|
| BATCH_001 | DIM_CUSTOMER | COMPLETED | 2024-06-01 09:05 |

When BATCH_001 is called again:

```
SELECT 1 FROM etl_watermark
WHERE batch_id = 'BATCH_001'
  AND entity   = 'DIM_CUSTOMER'
  AND status   = 'COMPLETED'

→ Returns 1 row
→ ROWCOUNT = 1 > 0
→ Procedure returns SKIPPED immediately
→ No MERGE runs. No history rows inserted. Zero writes anywhere.
```

**Return value:**
```json
{
  "status": "SKIPPED",
  "batch_id": "BATCH_001",
  "message": "Batch already successfully processed — no action taken"
}
```

**Why this matters:** Without this guard, a re-run would push the same customer
rows into history a second time, creating duplicates. One lookup prevents
all of that.

---

## 4. Guard 2 — Staging Validation

```sql
SELECT COUNT(*) INTO :v_rows_staged
FROM   raw.stg_customer
WHERE  _batch_id = :p_batch_id;

IF (v_rows_staged = 0) THEN
    RETURN OBJECT_CONSTRUCT(
        'status',   'SKIPPED',
        'batch_id', :p_batch_id,
        'message',  'No rows found in staging for this batch_id'
    );
END IF;
```

**What this does:** Counts staging rows for this specific batch_id. If zero rows
exist, the procedure exits before marking anything as STARTED.

**Why this matters:** If the upstream pipeline failed to load staging but still
called the procedure, without this check the procedure would mark the batch as
STARTED (and eventually COMPLETED) even though nothing was processed. That
creates a false audit trail — it looks like data was loaded when nothing happened.

---

## 5. Mark Batch as STARTED

```sql
MERGE INTO audit.etl_watermark t
USING (SELECT :p_batch_id AS batch_id) s
   ON t.batch_id = s.batch_id
WHEN MATCHED THEN
    UPDATE SET status        = 'STARTED',
               started_at   = :v_now,
               error_message = NULL
WHEN NOT MATCHED THEN
    INSERT (batch_id, entity, status, rows_staged, started_at)
    VALUES (:p_batch_id, 'DIM_CUSTOMER', 'STARTED', :v_rows_staged, :v_now);
```

**Why MERGE instead of INSERT?** If the batch previously FAILED, a row already
exists in the watermark table for that batch_id. A plain INSERT would fail with
a primary key violation. The MERGE handles both cases:

- `NOT MATCHED` → first time this batch runs → INSERT a new row
- `MATCHED` → batch previously FAILED and is being retried → UPDATE the
  existing row, resetting status to STARTED and clearing the error message

**Watermark after this block for BATCH_001:**

| batch_id | entity | status | rows_staged | started_at | completed_at |
|---|---|---|---|---|---|
| BATCH_001 | DIM_CUSTOMER | STARTED | 2 | 2024-06-01 09:00 | NULL |

---

## 6. Step 1 — Late Arrival Detection and Insert

This is the most complex part of the procedure. Read it carefully.

### What is a late arrival?

A late arrival is a staging row whose `_src_ts` (the time the event happened in
the source system) is EARLIER than `effective_from` in `dim_customer` for that
same customer.

```
staging._src_ts  <  dim_customer.effective_from
      ↑                        ↑
when it happened          when we think the latest version started
```

This means data from the past is arriving NOW. The current table already has a
newer version loaded. The late row must be inserted into history at the correct
chronological position — not appended to the end.

### The scenario for BATCH_005

Before BATCH_005 runs, here is the state of customer 1001:

**dim.dim_customer:**

| customer_sk | customer_id | first_name | city | effective_from | hash_key | _batch_id |
|---|---|---|---|---|---|---|
| 1 | 1001 | Naresh | Bangalore | 2024-06-02 09:00 | x7y8z9bb | BATCH_002 |

**dim.dim_customer_hist:**

| hist_sk | customer_id | city | valid_from | valid_to | _is_late_arrival |
|---|---|---|---|---|---|
| 3 | 1001 | Hyderabad | 2024-06-01 09:00 | 2024-06-02 09:00 | FALSE |

**Staging for BATCH_005:**

| customer_id | first_name | city | _src_ts | _batch_id |
|---|---|---|---|---|
| 1001 | Naresh | Chennai | **2024-06-01 06:00** | BATCH_005 |

`_src_ts = 2024-06-01 06:00` is BEFORE `effective_from = 2024-06-02 09:00`.
This is a late arrival. It represents Naresh being in Chennai at 06:00 on
June 1st — three hours before the Hyderabad record that we already have.

### The complete late arrival INSERT code

```sql
INSERT INTO dim.dim_customer_hist (
    customer_sk, customer_id,
    first_name, last_name, email, city,
    valid_from,
    valid_to,
    hash_key,
    _batch_id,
    _is_late_arrival,
    _inserted_at
)
SELECT
    c.customer_sk,
    s.customer_id,
    s.first_name, s.last_name, s.email, s.city,
    s._src_ts  AS valid_from,
    COALESCE(
        (
            SELECT MIN(h2.valid_from)
            FROM   dim.dim_customer_hist h2
            WHERE  h2.customer_id = s.customer_id
              AND  h2.valid_from  > s._src_ts
        ),
        c.effective_from
    ) AS valid_to,
    SHA2(CONCAT_WS('||',
        COALESCE(s.first_name, 'NULL'),
        COALESCE(s.last_name,  'NULL'),
        COALESCE(s.email,      'NULL'),
        COALESCE(s.city,       'NULL')
    ), 256) AS hash_key,
    s._batch_id,
    TRUE        AS _is_late_arrival,
    :v_now
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER BY _src_ts ASC
           ) AS rn
    FROM   raw.stg_customer
    WHERE  _batch_id = :p_batch_id
) s
JOIN dim.dim_customer c ON c.customer_id = s.customer_id
WHERE s._src_ts < c.effective_from   -- late arrival condition
  AND s.rn      = 1
  AND NOT EXISTS (
      SELECT 1 FROM dim.dim_customer_hist h
      WHERE  h.customer_id = s.customer_id
        AND  h.valid_from  = s._src_ts
        AND  h._batch_id   = s._batch_id
  );
```

### Line-by-line explanation with actual data

**Line: `s._src_ts AS valid_from`**

The late row's `valid_from` is simply when it happened in the source.

```
valid_from = 2024-06-01 06:00  (from staging _src_ts)
```

**Lines: the COALESCE subquery for `valid_to`**

```sql
COALESCE(
    (
        SELECT MIN(h2.valid_from)
        FROM   dim.dim_customer_hist h2
        WHERE  h2.customer_id = s.customer_id
          AND  h2.valid_from  > s._src_ts   -- find first version AFTER late row
    ),
    c.effective_from   -- fallback if no history rows are after it
) AS valid_to
```

This finds the version that was already in place immediately after the late row's
timestamp. That version's `valid_from` becomes the late row's `valid_to` — meaning
the late row is valid until the next known version took over.

**Working through the actual data:**

```
late row _src_ts           = 2024-06-01 06:00

Query: MIN(valid_from) from dim_customer_hist
       WHERE customer_id = 1001
         AND valid_from  > '2024-06-01 06:00'

History rows for 1001:
  Hyderabad: valid_from = 2024-06-01 09:00  ← this is > 06:00 ✓

MIN result = 2024-06-01 09:00

valid_to of late row = 2024-06-01 09:00
```

So the late row (Chennai) is valid from 06:00 to 09:00 on June 1st. Then
Hyderabad took over at 09:00. This is correct — it slots perfectly into the gap.

**What if there are no history rows after the late timestamp?**

The `COALESCE` fallback uses `c.effective_from` — the current table's start date.
For example, if no history existed yet:

```
MIN(valid_from where valid_from > late._src_ts) = NULL  (no rows)
COALESCE(NULL, c.effective_from)                = 2024-06-02 09:00
```

The late row would be valid from its `_src_ts` up to when the current version started.

**Line: `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY _src_ts DESC)`**

If the same customer appears multiple times in staging for the same batch
(duplicate CDC events), this picks only the latest one (`rn = 1`). Deduplication
happens inside staging before any writes occur.

**Line: `WHERE s._src_ts < c.effective_from`**

This is the late arrival detection condition. If the staging row's source
timestamp is earlier than what is already in the current table, it is a late arrival.

```
2024-06-01 06:00  <  2024-06-02 09:00  → TRUE → late arrival
```

**Lines: NOT EXISTS guard**

```sql
AND NOT EXISTS (
    SELECT 1 FROM dim.dim_customer_hist h
    WHERE  h.customer_id = s.customer_id
      AND  h.valid_from  = s._src_ts
      AND  h._batch_id   = s._batch_id
)
```

If BATCH_005 is accidentally run twice, the NOT EXISTS check finds the late row
already in history (same customer_id + valid_from + _batch_id) and skips the
insert. This is the second layer of idempotency protection, independent of the
watermark guard.

**Result — dim.dim_customer_hist after BATCH_005 Step 1:**

| hist_sk | customer_id | city | valid_from | valid_to | _is_late_arrival | _batch_id |
|---|---|---|---|---|---|---|
| **5** | **1001** | **Chennai** | **2024-06-01 06:00** | **2024-06-01 09:00** | **TRUE** | **BATCH_005** |
| 3 | 1001 | Hyderabad | 2024-06-01 09:00 | 2024-06-02 09:00 | FALSE | BATCH_001 |

**dim.dim_customer — completely unchanged during Step 1:**

| customer_sk | customer_id | city | effective_from |
|---|---|---|---|
| 1 | 1001 | Bangalore | 2024-06-02 09:00 |

The current table is never touched by late arrivals. It always holds the
chronologically latest version.

```
v_rows_late := SQLROWCOUNT;  → v_rows_late = 1
```

---

## 7. Step 2 — Push Old Row to History (Normal Change)

This step handles customers whose data changed in the current batch and are NOT
late arrivals.

```sql
INSERT INTO dim.dim_customer_hist (
    customer_sk, customer_id,
    first_name, last_name, email, city,
    valid_from,
    valid_to,
    hash_key,
    _batch_id,
    _is_late_arrival,
    _inserted_at
)
SELECT
    c.customer_sk,
    c.customer_id,
    c.first_name, c.last_name, c.email, c.city,
    c.effective_from   AS valid_from,
    s._src_ts          AS valid_to,
    c.hash_key,
    c._batch_id,
    FALSE              AS _is_late_arrival,
    :v_now
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY customer_id
               ORDER BY _src_ts DESC
           ) AS rn
    FROM   raw.stg_customer
    WHERE  _batch_id = :p_batch_id
) s
JOIN dim.dim_customer c ON c.customer_id = s.customer_id
WHERE s._src_ts >= c.effective_from     -- not a late arrival
  AND s.rn       = 1
  AND SHA2(CONCAT_WS('||',
        COALESCE(s.first_name, 'NULL'),
        COALESCE(s.last_name,  'NULL'),
        COALESCE(s.email,      'NULL'),
        COALESCE(s.city,       'NULL')
      ), 256) != c.hash_key             -- hash changed = data changed
  AND NOT EXISTS (
      SELECT 1 FROM dim.dim_customer_hist h
      WHERE  h.customer_id = c.customer_id
        AND  h.hash_key    = c.hash_key
        AND  h.valid_from  = c.effective_from
  );
```

### Scenario: BATCH_002 — Naresh moves to Bangalore

**Before BATCH_002, dim.dim_customer:**

| customer_sk | customer_id | city | hash_key | effective_from |
|---|---|---|---|---|
| 1 | 1001 | Hyderabad | a1b2c3ff | 2024-06-01 09:00 |
| 2 | 1002 | Mumbai | d4e5f6aa | 2024-06-01 09:00 |

**Staging for BATCH_002:**

| customer_id | city | _src_ts | hash from staging |
|---|---|---|---|
| 1001 | Bangalore | 2024-06-02 09:00 | x7y8z9bb |
| 1002 | Mumbai | 2024-06-02 09:00 | d4e5f6aa |

**Hash comparison:**

| customer_id | hash in dim_customer | hash from staging | match? | action |
|---|---|---|---|---|
| 1001 | a1b2c3ff | x7y8z9bb | **NO** | push to history |
| 1002 | d4e5f6aa | d4e5f6aa | **YES** | skip — no write |

**For customer 1001:**

```
valid_from = c.effective_from = 2024-06-01 09:00  (when Hyderabad started)
valid_to   = s._src_ts        = 2024-06-02 09:00  (when Bangalore started)
```

New version's start becomes old version's end. No gaps, no overlaps.

**The hash check line:**

```sql
SHA2(CONCAT_WS('||',
    COALESCE(s.first_name, 'NULL'),
    COALESCE(s.last_name,  'NULL'),
    COALESCE(s.email,      'NULL'),
    COALESCE(s.city,       'NULL')
), 256) != c.hash_key
```

For customer 1002, both sides produce `d4e5f6aa`. The condition is FALSE.
No history row is written for Priya. Zero unnecessary writes.

**dim.dim_customer_hist after Step 2 of BATCH_002:**

| hist_sk | customer_id | city | valid_from | valid_to | _is_late_arrival |
|---|---|---|---|---|---|
| 3 | 1001 | Hyderabad | 2024-06-01 09:00 | 2024-06-02 09:00 | FALSE |

```
v_rows_expired := SQLROWCOUNT;  → v_rows_expired = 1
```

### NULL handling in the hash

**BATCH_004 scenario — Naresh's email becomes NULL:**

```sql
-- Without COALESCE (broken):
SHA2("Naresh" || "Kumar" || NULL || "Bangalore") = NULL
-- NULL != 'x7y8z9bb' evaluates to NULL, not TRUE
-- Change is silently missed

-- With COALESCE (correct):
SHA2(CONCAT_WS('||',
    'Naresh',      -- first_name
    'Kumar',       -- last_name
    'NULL',        -- COALESCE(NULL, 'NULL') → literal string 'NULL'
    'Bangalore'    -- city
)) = p9q0r1cc
-- p9q0r1cc != x7y8z9bb → TRUE → change correctly detected
```

**Why CONCAT_WS with `||` separator?**

Without a separator, columns can accidentally produce the same hash:

```
first_name='Nares',  last_name='hKumar'  → "NareskKumar"
first_name='Naresh', last_name='Kumar'   → "NareskKumar"  ← same! wrong hash
```

With `||` separator:

```
'Nares'  + '||' + 'hKumar' = "Nares||hKumar"
'Naresh' + '||' + 'Kumar'  = "Naresh||Kumar"  ← different. correct.
```

---

## 8. Step 3 — MERGE into Current Table

```sql
MERGE INTO dim.dim_customer tgt
USING (
    SELECT
        customer_id, first_name, last_name, email, city,
        _src_ts, _batch_id,
        SHA2(CONCAT_WS('||',
            COALESCE(first_name, 'NULL'),
            COALESCE(last_name,  'NULL'),
            COALESCE(email,      'NULL'),
            COALESCE(city,       'NULL')
        ), 256) AS hash_key,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY _src_ts DESC
        ) AS rn
    FROM raw.stg_customer
    WHERE _batch_id = :p_batch_id
) src
ON  tgt.customer_id = src.customer_id
AND src.rn          = 1

WHEN NOT MATCHED THEN
    INSERT (customer_sk, customer_id, first_name, last_name, email, city,
            effective_from, hash_key, _batch_id, updated_at)
    VALUES (seq_customer_sk.NEXTVAL, src.customer_id, src.first_name,
            src.last_name, src.email, src.city, src._src_ts,
            src.hash_key, src._batch_id, :v_now)

WHEN MATCHED
     AND src._src_ts  >= tgt.effective_from
     AND tgt.hash_key != src.hash_key
THEN
    UPDATE SET
        first_name=src.first_name, last_name=src.last_name,
        email=src.email, city=src.city,
        effective_from=src._src_ts, hash_key=src.hash_key,
        _batch_id=src._batch_id, updated_at=:v_now

WHEN MATCHED THEN
    UPDATE SET updated_at = :v_now;
```

### Three MERGE cases with actual data

**Case 1: NOT MATCHED — new customer (BATCH_001)**

```
customer 1001 does not exist in dim_customer yet
→ NOT MATCHED fires
→ seq_customer_sk.NEXTVAL = 1 assigned
→ Row inserted with city=Hyderabad, effective_from=2024-06-01 09:00
```

**Case 2: MATCHED + hash changed — data updated (BATCH_002)**

```
customer 1001 exists, hash a1b2c3ff ≠ x7y8z9bb, _src_ts >= effective_from
→ Second WHEN fires
→ city updated to Bangalore
→ effective_from updated to 2024-06-02 09:00
→ hash_key updated to x7y8z9bb
```

**Case 3: MATCHED — late arrival (BATCH_005)**

```
customer 1001 exists
_src_ts = 2024-06-01 06:00 < effective_from = 2024-06-02 09:00
→ Second WHEN condition fails (src._src_ts >= tgt.effective_from is FALSE)
→ Falls through to third WHEN (catch-all)
→ Only updated_at is touched
→ City, hash, effective_from all unchanged
```

This is how late arrivals are excluded from the current table — they fail the
`src._src_ts >= tgt.effective_from` condition and fall into the heartbeat update.

**Case 4: MATCHED + hash same — no change (BATCH_003)**

```
customer 1002, hash d4e5f6aa = d4e5f6aa
→ Second WHEN fails (hash_key != fails)
→ Falls to third WHEN
→ Only updated_at is touched
→ No data change, no history write
```

**dim.dim_customer after BATCH_002 MERGE:**

| customer_sk | customer_id | city | hash_key | effective_from | _batch_id |
|---|---|---|---|---|---|
| 1 | 1001 | **Bangalore** | x7y8z9bb | 2024-06-02 09:00 | BATCH_002 |
| 2 | 1002 | Mumbai | d4e5f6aa | 2024-06-01 09:00 | BATCH_001 |

---

## 9. Step 4 — Mark Batch COMPLETED

```sql
UPDATE audit.etl_watermark
SET
    status            = 'COMPLETED',
    rows_staged       = :v_rows_staged,
    rows_inserted     = :v_rows_inserted,
    rows_updated      = :v_rows_updated,
    rows_expired      = :v_rows_expired,
    rows_late_arrival = :v_rows_late,
    completed_at      = CURRENT_TIMESTAMP()
WHERE batch_id = :p_batch_id
  AND entity   = 'DIM_CUSTOMER';
```

This only runs if every previous step succeeded. If any step throws an error,
the exception handler catches it before reaching here and stamps FAILED instead.

**Watermark after all batches:**

| batch_id | status | rows_staged | rows_inserted | rows_updated | rows_expired | rows_late_arrival |
|---|---|---|---|---|---|---|
| BATCH_001 | COMPLETED | 2 | 2 | 0 | 0 | 0 |
| BATCH_002 | COMPLETED | 2 | 0 | 1 | 1 | 0 |
| BATCH_003 | COMPLETED | 2 | 0 | 0 | 0 | 0 |
| BATCH_004 | COMPLETED | 2 | 0 | 1 | 1 | 0 |
| BATCH_005 | COMPLETED | 1 | 0 | 0 | 0 | 1 |

Reading this table tells you the full operational story:
- BATCH_001: 2 new customers loaded
- BATCH_002: 1 customer changed, 1 old version archived
- BATCH_003: nothing changed — all hashes matched
- BATCH_004: 1 customer's email became NULL, detected and archived
- BATCH_005: 1 late arrival backfilled into history

---

## 10. Exception Handler

```sql
EXCEPTION
    WHEN OTHER THEN
        UPDATE audit.etl_watermark
        SET  status        = 'FAILED',
             error_message = SQLERRM,
             completed_at  = CURRENT_TIMESTAMP()
        WHERE batch_id = :p_batch_id
          AND entity   = 'DIM_CUSTOMER';
        RAISE;
```

**What `WHEN OTHER` catches:** Any unhandled exception — network failure,
constraint violation, out of memory, division by zero, anything.

**`SQLERRM`** — Snowflake's built-in variable that holds the error message text.
This is what gets stored in `error_message`.

**`RAISE`** — re-raises the exception after stamping the watermark. This means
the calling system (Airflow, dbt, etc.) still sees the failure and can alert.
Without RAISE, the procedure would silently return NULL and the caller would
think it succeeded.

**Retry flow for a FAILED batch:**

```
BATCH_002 fails mid-run, watermark stamped FAILED
↓
Operator investigates, fixes root cause
↓
CALL sp_load_dim_customer('BATCH_002') again
↓
Guard 1: looks for COMPLETED → not found (status = FAILED) → passes
↓
Guard 2: staging still has rows → passes
↓
Watermark MERGE: finds existing FAILED row → resets to STARTED
↓
Steps 1-4 run again
↓
NOT EXISTS guards on history inserts prevent any duplicate rows
```

---

## 11. Complete Data State After Every Batch

### After BATCH_001

**dim.dim_customer:**

| customer_sk | customer_id | first_name | city | hash_key | effective_from |
|---|---|---|---|---|---|
| 1 | 1001 | Naresh | Hyderabad | a1b2c3ff | 2024-06-01 09:00 |
| 2 | 1002 | Priya | Mumbai | d4e5f6aa | 2024-06-01 09:00 |

**dim.dim_customer_hist:** *(empty — no previous versions exist)*

---

### After BATCH_002 (Naresh → Bangalore)

**dim.dim_customer:**

| customer_sk | customer_id | city | hash_key | effective_from |
|---|---|---|---|---|
| 1 | 1001 | **Bangalore** | x7y8z9bb | 2024-06-02 09:00 |
| 2 | 1002 | Mumbai | d4e5f6aa | 2024-06-01 09:00 |

**dim.dim_customer_hist:**

| hist_sk | customer_id | city | valid_from | valid_to | _is_late_arrival |
|---|---|---|---|---|---|
| 3 | 1001 | Hyderabad | 2024-06-01 09:00 | 2024-06-02 09:00 | FALSE |

---

### After BATCH_003 (no change)

Both tables identical to after BATCH_002. Only `updated_at` changes in dim_customer.

---

### After BATCH_004 (Naresh email → NULL)

**dim.dim_customer:**

| customer_sk | customer_id | email | city | hash_key | effective_from |
|---|---|---|---|---|---|
| 1 | 1001 | **NULL** | Bangalore | p9q0r1cc | 2024-06-04 09:00 |
| 2 | 1002 | priya@gmail.com | Mumbai | d4e5f6aa | 2024-06-01 09:00 |

**dim.dim_customer_hist:**

| hist_sk | customer_id | email | city | valid_from | valid_to | _is_late_arrival |
|---|---|---|---|---|---|---|
| 3 | 1001 | naresh@gmail.com | Hyderabad | 2024-06-01 09:00 | 2024-06-02 09:00 | FALSE |
| 4 | 1001 | naresh@gmail.com | Bangalore | 2024-06-02 09:00 | 2024-06-04 09:00 | FALSE |

---

### After BATCH_005 (late arrival — Chennai at 06:00)

**dim.dim_customer:** *(unchanged — late arrivals never touch current table)*

| customer_sk | customer_id | city | effective_from |
|---|---|---|---|
| 1 | 1001 | Bangalore | 2024-06-02 09:00 |

**dim.dim_customer_hist:**

| hist_sk | customer_id | city | valid_from | valid_to | _is_late_arrival |
|---|---|---|---|---|---|
| **5** | **1001** | **Chennai** | **2024-06-01 06:00** | **2024-06-01 09:00** | **TRUE** |
| 3 | 1001 | Hyderabad | 2024-06-01 09:00 | 2024-06-02 09:00 | FALSE |
| 4 | 1001 | Bangalore | 2024-06-02 09:00 | 2024-06-04 09:00 | FALSE |

**Complete timeline of customer 1001 in chronological order:**

| period | city | email | source |
|---|---|---|---|
| Jun 01 06:00 → Jun 01 09:00 | Chennai | naresh@gmail.com | HISTORY (late arrival) |
| Jun 01 09:00 → Jun 02 09:00 | Hyderabad | naresh@gmail.com | HISTORY |
| Jun 02 09:00 → Jun 04 09:00 | Bangalore | naresh@gmail.com | HISTORY |
| Jun 04 09:00 → now | Bangalore | NULL | CURRENT |

---

## 12. Query Patterns Explained

### Current state — use for fact table joins

```sql
SELECT * FROM dim.dim_customer;
```

Always 1 row per customer. Fast. No time range logic needed.
This is what you join to `fact_orders` to get the customer's current city.

---

### Full version history for one customer

```sql
SELECT
    customer_id, first_name, email, city,
    effective_from  AS valid_from,
    NULL            AS valid_to,
    'CURRENT'       AS version_type
FROM dim.dim_customer
WHERE customer_id = 1001

UNION ALL

SELECT
    customer_id, first_name, email, city,
    valid_from, valid_to,
    CASE WHEN _is_late_arrival THEN 'LATE ARRIVAL' ELSE 'HISTORY' END
FROM dim.dim_customer_hist
WHERE customer_id = 1001

ORDER BY valid_from;
```

**Why UNION ALL and not just history?** Because the current version lives only
in `dim_customer`. History only has expired rows. To see the complete picture
you must union both tables.

**Result for customer 1001:**

| city | email | valid_from | valid_to | version_type |
|---|---|---|---|---|
| Chennai | naresh@gmail.com | 2024-06-01 06:00 | 2024-06-01 09:00 | LATE ARRIVAL |
| Hyderabad | naresh@gmail.com | 2024-06-01 09:00 | 2024-06-02 09:00 | HISTORY |
| Bangalore | naresh@gmail.com | 2024-06-02 09:00 | 2024-06-04 09:00 | HISTORY |
| Bangalore | NULL | 2024-06-04 09:00 | NULL | CURRENT |

---

### Point-in-time query

```sql
-- Where was customer 1001 on 2024-06-03?
SELECT customer_id, city, email, valid_from, valid_to
FROM dim.dim_customer_hist
WHERE customer_id = 1001
  AND valid_from <= '2024-06-03'::TIMESTAMP_NTZ
  AND valid_to   >  '2024-06-03'::TIMESTAMP_NTZ;
```

**How the filter works:**

```
History rows for 1001:
  Chennai    06:00 → 09:00   →  valid_from(06:00) <= Jun03 ✓  valid_to(09:00) > Jun03 ✗
  Hyderabad  09:00 → Jun02   →  valid_from(Jun01) <= Jun03 ✓  valid_to(Jun02) > Jun03 ✗
  Bangalore  Jun02 → Jun04   →  valid_from(Jun02) <= Jun03 ✓  valid_to(Jun04) > Jun03 ✓ ← match

Result: Bangalore (with email naresh@gmail.com)
```

**For the current version (today):** Query `dim_customer` directly.
No time range logic needed.

---

### Find all late arrivals

```sql
SELECT
    customer_id, city, valid_from, valid_to,
    _batch_id, _inserted_at
FROM dim.dim_customer_hist
WHERE _is_late_arrival = TRUE
ORDER BY _inserted_at DESC;
```

**Result after BATCH_005:**

| customer_id | city | valid_from | valid_to | _batch_id | _inserted_at |
|---|---|---|---|---|---|
| 1001 | Chennai | 2024-06-01 06:00 | 2024-06-01 09:00 | BATCH_005 | 2024-06-06 09:00 |

Use this query in monitoring to alert if the late arrival count spikes — it
signals upstream pipeline delays or source system backfills.

---

### Batch audit summary

```sql
SELECT
    batch_id,
    status,
    rows_staged,
    rows_inserted,
    rows_updated,
    rows_expired,
    rows_late_arrival,
    DATEDIFF('second', started_at, completed_at) AS duration_secs
FROM audit.etl_watermark
ORDER BY started_at DESC;
```

**How to read the output:**

| rows_inserted > 0 | New customers arrived |
|---|---|
| rows_updated > 0 | Existing customers had data changes |
| rows_expired > 0 | Old versions were pushed to history (should equal rows_updated) |
| rows_late_arrival > 0 | Historical data was backfilled — investigate source |
| rows_staged > 0, all others = 0 | Data arrived but nothing changed — normal |
| status = FAILED | Check error_message column for root cause |

---

*End of guide. All SQL code, table states, and query outputs above are derived
from the same six-batch scenario using customers Naresh (1001) and Priya (1002).*
