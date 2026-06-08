# Snowflake Subquery Migration Guide
### Greenplum → Snowflake: Unsupported Subqueries & JOIN Rewrites

---

## Table Setup

### Table 1: `members`

```sql
CREATE OR REPLACE TABLE members (
    member_id     VARCHAR(10)   NOT NULL,
    member_name   VARCHAR(100)  NOT NULL,
    plan_type     VARCHAR(20),
    state_cd      VARCHAR(2),
    enroll_dt     DATE,
    term_dt       DATE
);

INSERT INTO members VALUES
    ('M001', 'Alice Johnson',   'MEDICAID', 'NY', '2022-01-01', NULL),
    ('M002', 'Brian Smith',     'CHIP',     'NY', '2021-06-15', NULL),
    ('M003', 'Carol Davis',     'MEDICAID', 'NJ', '2023-03-01', NULL),
    ('M004', 'David Lee',       'MEDICARE', 'NY', '2020-09-01', NULL),
    ('M005', 'Eva Martinez',    'MEDICAID', 'CT', '2022-11-01', NULL);
```

**Sample data:**

| member_id | member_name   | plan_type | state_cd | enroll_dt  | term_dt |
|-----------|---------------|-----------|----------|------------|---------|
| M001      | Alice Johnson | MEDICAID  | NY       | 2022-01-01 | NULL    |
| M002      | Brian Smith   | CHIP      | NY       | 2021-06-15 | NULL    |
| M003      | Carol Davis   | MEDICAID  | NJ       | 2023-03-01 | NULL    |
| M004      | David Lee     | MEDICARE  | NY       | 2020-09-01 | NULL    |
| M005      | Eva Martinez  | MEDICAID  | CT       | 2022-11-01 | NULL    |

---

### Table 2: `claims`

```sql
CREATE OR REPLACE TABLE claims (
    claim_id      VARCHAR(10)   NOT NULL,
    member_id     VARCHAR(10)   NOT NULL,
    claim_dt      DATE          NOT NULL,
    claim_year    NUMBER(4)     NOT NULL,
    claim_amt     NUMBER(10,2)  NOT NULL,
    claim_status  VARCHAR(20)   NOT NULL,
    service_type  VARCHAR(30)
);

INSERT INTO claims VALUES
    ('C001', 'M001', '2024-01-10', 2024, 1500.00, 'APPROVED',  'INPATIENT'),
    ('C002', 'M001', '2024-03-22', 2024,  320.50, 'APPROVED',  'OUTPATIENT'),
    ('C003', 'M001', '2023-11-05', 2023,  800.00, 'APPROVED',  'PHARMACY'),
    ('C004', 'M002', '2024-02-14', 2024, 2200.00, 'DENIED',    'INPATIENT'),
    ('C005', 'M002', '2024-06-30', 2024,  450.75, 'APPROVED',  'OUTPATIENT'),
    ('C006', 'M004', '2023-07-19', 2023, 5100.00, 'APPROVED',  'INPATIENT'),
    ('C007', 'M004', '2024-08-01', 2024, 3300.00, 'APPROVED',  'INPATIENT'),
    ('C008', 'M004', '2024-09-15', 2024,  980.00, 'PENDING',   'OUTPATIENT');

-- Note: M003 (Carol Davis) and M005 (Eva Martinez) have NO claims at all
```

**Sample data:**

| claim_id | member_id | claim_dt   | claim_year | claim_amt | claim_status | service_type |
|----------|-----------|------------|------------|-----------|--------------|--------------|
| C001     | M001      | 2024-01-10 | 2024       | 1500.00   | APPROVED     | INPATIENT    |
| C002     | M001      | 2024-03-22 | 2024       | 320.50    | APPROVED     | OUTPATIENT   |
| C003     | M001      | 2023-11-05 | 2023       | 800.00    | APPROVED     | PHARMACY     |
| C004     | M002      | 2024-02-14 | 2024       | 2200.00   | DENIED       | INPATIENT    |
| C005     | M002      | 2024-06-30 | 2024       | 450.75    | APPROVED     | OUTPATIENT   |
| C006     | M004      | 2023-07-19 | 2023       | 5100.00   | APPROVED     | INPATIENT    |
| C007     | M004      | 2024-08-01 | 2024       | 3300.00   | APPROVED     | INPATIENT    |
| C008     | M004      | 2024-09-15 | 2024       | 980.00    | PENDING      | OUTPATIENT   |

---

## Pattern 1 — Correlated Subquery in FROM Clause

**Goal:** For each member, get their most recent claim date.

### ❌ Greenplum Query (Fails in Snowflake)

```sql
-- ERROR: Unsupported subquery type — correlated subquery in FROM clause
SELECT m.member_id,
       m.member_name,
       lc.last_claim_dt
FROM   members m,
       (SELECT claim_dt AS last_claim_dt
        FROM   claims c
        WHERE  c.member_id = m.member_id   -- references outer table m
        ORDER  BY claim_dt DESC
        LIMIT  1) lc;
```

**Why it fails:** The inner subquery references `m.member_id` from the outer `FROM` clause.
Snowflake's distributed engine cannot resolve this row-by-row reference across nodes.

### ✅ Snowflake Fix — LEFT JOIN + ROW_NUMBER()

```sql
SELECT m.member_id,
       m.member_name,
       c.claim_dt AS last_claim_dt
FROM   members m
LEFT JOIN (
    SELECT member_id,
           claim_dt,
           ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY claim_dt DESC) AS rn
    FROM   claims
) c ON c.member_id = m.member_id
   AND c.rn = 1;
```

**Expected output:**

| member_id | member_name   | last_claim_dt |
|-----------|---------------|---------------|
| M001      | Alice Johnson | 2024-03-22    |
| M002      | Brian Smith   | 2024-06-30    |
| M003      | Carol Davis   | NULL          |
| M004      | David Lee     | 2024-09-15    |
| M005      | Eva Martinez  | NULL          |

> `ROW_NUMBER()` assigns rank 1 to the latest claim per member.
> `LEFT JOIN` ensures members with no claims (M003, M005) still appear with NULL.

---

## Pattern 2 — Correlated Scalar Subquery in SELECT List

**Goal:** Count each member's approved claims in 2024.

### ❌ Greenplum Query (Slow / Unsupported in Snowflake)

```sql
-- May fail or run extremely slowly in Snowflake at scale
SELECT m.member_id,
       m.member_name,
       (SELECT COUNT(*)
        FROM   claims c
        WHERE  c.member_id = m.member_id   -- correlated reference
          AND  c.claim_year = 2024
          AND  c.claim_status = 'APPROVED') AS approved_cnt_2024
FROM   members m;
```

**Why it's problematic:** Snowflake executes this subquery once per row of `members`.
For 1M+ member rows this becomes a serious performance issue.

### ✅ Snowflake Fix — LEFT JOIN with GROUP BY

```sql
SELECT m.member_id,
       m.member_name,
       COALESCE(c.approved_cnt_2024, 0) AS approved_cnt_2024
FROM   members m
LEFT JOIN (
    SELECT member_id,
           COUNT(*) AS approved_cnt_2024
    FROM   claims
    WHERE  claim_year   = 2024
      AND  claim_status = 'APPROVED'
    GROUP BY member_id
) c ON c.member_id = m.member_id;
```

**Expected output:**

| member_id | member_name   | approved_cnt_2024 |
|-----------|---------------|-------------------|
| M001      | Alice Johnson | 2                 |
| M002      | Brian Smith   | 1                 |
| M003      | Carol Davis   | 0                 |
| M004      | David Lee     | 1                 |
| M005      | Eva Martinez  | 0                 |

> `COALESCE(..., 0)` converts NULL (no matching claims) to 0.
> The inner query aggregates the entire claims table once — far more efficient.

---

## Pattern 3 — NOT IN with Correlated Subquery (NULL Trap)

**Goal:** Find members who had NO claims in 2024.

### ❌ Greenplum Query (NULL trap — wrong results silently)

```sql
-- DANGEROUS: if any row in the subquery returns NULL member_id,
-- the entire NOT IN returns zero rows — a silent data bug
SELECT m.member_id,
       m.member_name
FROM   members m
WHERE  m.member_id NOT IN (
    SELECT member_id          -- if member_id is nullable, this poisons the result
    FROM   claims
    WHERE  claim_year = 2024
);
```

**Why it fails silently:** SQL `NOT IN` with a NULL in the list evaluates to UNKNOWN,
which filters out every row. This is not a Snowflake-specific bug, but it causes
silent wrong results that are very hard to debug during migration.

### ✅ Snowflake Fix — LEFT JOIN Anti-Join Pattern

```sql
SELECT m.member_id,
       m.member_name
FROM   members m
LEFT JOIN claims c
       ON c.member_id  = m.member_id
      AND c.claim_year = 2024
WHERE  c.member_id IS NULL;   -- keeps only members with no 2024 claim match
```

**Expected output:**

| member_id | member_name  |
|-----------|--------------|
| M003      | Carol Davis  |
| M005      | Eva Martinez |

> The `LEFT JOIN` produces NULL on the right side for unmatched rows.
> Filtering `WHERE c.member_id IS NULL` isolates exactly those members.
> This pattern is NULL-safe and performs well at scale.

---

## Pattern 4 — EXISTS / NOT EXISTS (Supported but Rewrite for Performance)

**Goal:** Find members who have at least one APPROVED claim.

### ⚠️ Greenplum Query (EXISTS — works in Snowflake, but can be slow)

```sql
-- EXISTS is supported in Snowflake but may not optimize as well as a JOIN
SELECT m.member_id,
       m.member_name
FROM   members m
WHERE  EXISTS (
    SELECT 1
    FROM   claims c
    WHERE  c.member_id   = m.member_id
      AND  c.claim_status = 'APPROVED'
);
```

### ✅ Snowflake Preferred — JOIN with DISTINCT

```sql
SELECT DISTINCT
       m.member_id,
       m.member_name
FROM   members m
JOIN   claims c
    ON c.member_id   = m.member_id
   AND c.claim_status = 'APPROVED';
```

**Expected output:**

| member_id | member_name   |
|-----------|---------------|
| M001      | Alice Johnson |
| M002      | Brian Smith   |
| M004      | David Lee     |

> `DISTINCT` prevents duplicate member rows when they have multiple approved claims.
> Snowflake's query optimizer handles JOIN + DISTINCT more efficiently than EXISTS at scale.

---

## Bonus — Combining Multiple Patterns in One Query

**Goal:** Full member claim summary — latest claim date, 2024 approved count,
total 2024 spend, and a flag for members with no claims.

```sql
SELECT
    m.member_id,
    m.member_name,
    m.plan_type,
    m.state_cd,

    -- Latest claim date (Pattern 1)
    latest.claim_dt                           AS last_claim_dt,

    -- 2024 approved claim count (Pattern 2)
    COALESCE(agg.approved_cnt_2024, 0)        AS approved_cnt_2024,

    -- 2024 total spend
    COALESCE(agg.total_spend_2024, 0)         AS total_spend_2024,

    -- No-claims flag (Pattern 3 logic)
    CASE WHEN latest.claim_dt IS NULL
         THEN 'Y' ELSE 'N' END               AS no_claims_flag

FROM members m

-- Latest claim (Pattern 1: ROW_NUMBER anti-pattern)
LEFT JOIN (
    SELECT member_id,
           claim_dt,
           ROW_NUMBER() OVER (PARTITION BY member_id ORDER BY claim_dt DESC) AS rn
    FROM   claims
) latest ON latest.member_id = m.member_id
        AND latest.rn = 1

-- 2024 aggregates (Pattern 2: GROUP BY)
LEFT JOIN (
    SELECT member_id,
           COUNT(CASE WHEN claim_status = 'APPROVED' THEN 1 END) AS approved_cnt_2024,
           SUM(CASE WHEN claim_status = 'APPROVED' THEN claim_amt ELSE 0 END) AS total_spend_2024
    FROM   claims
    WHERE  claim_year = 2024
    GROUP BY member_id
) agg ON agg.member_id = m.member_id

ORDER BY m.member_id;
```

**Expected output:**

| member_id | member_name   | plan_type | state_cd | last_claim_dt | approved_cnt_2024 | total_spend_2024 | no_claims_flag |
|-----------|---------------|-----------|----------|---------------|-------------------|------------------|----------------|
| M001      | Alice Johnson | MEDICAID  | NY       | 2024-03-22    | 2                 | 1820.50          | N              |
| M002      | Brian Smith   | CHIP      | NY       | 2024-06-30    | 1                 | 450.75           | N              |
| M003      | Carol Davis   | MEDICAID  | NJ       | NULL          | 0                 | 0.00             | Y              |
| M004      | David Lee     | MEDICARE  | NY       | 2024-09-15    | 1                 | 3300.00          | N              |
| M005      | Eva Martinez  | MEDICAID  | CT       | NULL          | 0                 | 0.00             | Y              |

---

## Migration Decision Reference

| Scenario | Greenplum Pattern | Snowflake Fix |
|---|---|---|
| Latest row per group | Correlated subquery in FROM | `LEFT JOIN` + `ROW_NUMBER() OVER (PARTITION BY ...)` |
| Aggregate per outer row | Scalar subquery in SELECT | `LEFT JOIN` + `GROUP BY` subquery |
| Exclude rows with matches | `NOT IN (subquery)` | `LEFT JOIN ... WHERE right.key IS NULL` |
| Filter rows with matches | `EXISTS (subquery)` | `JOIN` + `DISTINCT` |

### Key Principles

- **Greenplum** evaluates correlated subqueries row-by-row (nested loop) — flexible but slow at scale.
- **Snowflake** distributes data across nodes in parallel — correlated references across nodes break this model.
- Every correlated subquery can be rewritten as a `JOIN` — and the JOIN version is almost always faster in Snowflake.
- Always use `COALESCE` after a `LEFT JOIN` to handle members/entities with no matching rows.
- Prefer the anti-join `LEFT JOIN ... IS NULL` over `NOT IN` — it is NULL-safe and performs better.
