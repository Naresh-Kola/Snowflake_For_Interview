# SCD Type 3 Implementation Guide

## Overview

Slowly Changing Dimension (SCD) Type 3 tracks **current and one previous value** for selected attributes. Unlike Type 2, it updates in place — no new rows are added — making it simpler but limited to a single historical snapshot.

**Best suited for:** attributes that change infrequently where only the most recent change matters (e.g. sales territory, customer segment, pricing tier).

---

## Dimension Table Schema

```sql
CREATE TABLE dim_customer (
    customer_key     INT PRIMARY KEY IDENTITY(1,1),
    customer_id      INT NOT NULL,
    current_city     VARCHAR(100),
    prev_city        VARCHAR(100),          -- previous value
    current_segment  VARCHAR(50),
    prev_segment     VARCHAR(50),           -- previous value
    effective_date   DATE,                  -- when current value was last set
    load_date        DATE DEFAULT CURRENT_DATE
);
```

---

## Staging Table Schema

```sql
CREATE TABLE stg_customer (
    customer_id  INT,
    city         VARCHAR(100),
    segment      VARCHAR(50),
    load_date    DATE
);
```

---

## Merge Logic

### Option 1: Separate UPDATE + INSERT

```sql
-- Step 1: Update existing records — shift current → previous
UPDATE dim_customer d
SET
    prev_city        = d.current_city,
    prev_segment     = d.current_segment,
    current_city     = s.city,
    current_segment  = s.segment,
    effective_date   = CURRENT_DATE
FROM stg_customer s
WHERE d.customer_id = s.customer_id
  AND (d.current_city != s.city OR d.current_segment != s.segment);

-- Step 2: Insert new records (no match in dim)
INSERT INTO dim_customer (
    customer_id, current_city, prev_city,
    current_segment, prev_segment, effective_date
)
SELECT
    s.customer_id,
    s.city,
    NULL,
    s.segment,
    NULL,
    CURRENT_DATE
FROM stg_customer s
LEFT JOIN dim_customer d ON s.customer_id = d.customer_id
WHERE d.customer_id IS NULL;
```

### Option 2: MERGE Statement (recommended)

```sql
MERGE INTO dim_customer d
USING stg_customer s
    ON d.customer_id = s.customer_id
WHEN MATCHED AND (d.current_city != s.city OR d.current_segment != s.segment) THEN
    UPDATE SET
        prev_city       = d.current_city,
        prev_segment    = d.current_segment,
        current_city    = s.city,
        current_segment = s.segment,
        effective_date  = CURRENT_DATE
WHEN NOT MATCHED THEN
    INSERT (customer_id, current_city, prev_city, current_segment, prev_segment, effective_date)
    VALUES (s.customer_id, s.city, NULL, s.segment, NULL, CURRENT_DATE);
```

---

## Example: Before and After

**Before load** (customer moved from Hyderabad to Bangalore):

| customer_key | customer_id | current_city | prev_city | effective_date |
|---|---|---|---|---|
| 1 | 101 | Hyderabad | NULL | 2024-01-15 |

**After load:**

| customer_key | customer_id | current_city | prev_city | effective_date |
|---|---|---|---|---|
| 1 | 101 | Bangalore | Hyderabad | 2026-06-10 |

---

## Trade-offs

| Aspect | Type 3 |
|---|---|
| History tracked | Current + 1 previous only |
| Row count | Unchanged (update in place) |
| Storage overhead | Low (extra columns per tracked attribute) |
| Query complexity | Simple |
| Data loss risk | High — third change overwrites second |

---

## When to Use Each Type

- **Type 1** — history doesn't matter; just overwrite
- **Type 2** — full history needed; new row per change
- **Type 3** — only the most recent change matters; low cardinality attributes

---

## Notes

- Only add `prev_*` columns for attributes you actually need to track historically.
- The `effective_date` reflects when the *current* value was set, not when the previous value was originally assigned.
- For full audit history, prefer Type 2 or a separate audit/history table alongside Type 3.
