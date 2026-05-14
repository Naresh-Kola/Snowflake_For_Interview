# Snowflake Sequences — Complete Guide

**From Beginner to Production to Interview**

---

## Table of Contents

- [Part 1: Fundamentals](#part-1-fundamentals)
  - [1. What is a Sequence?](#1-what-is-a-sequence)
  - [2. Creating a Sequence](#2-creating-a-sequence)
  - [3. Using NEXTVAL](#3-using-nextval)
  - [4. Sequence as Column Default](#4-sequence-as-column-default)
  - [5. AUTOINCREMENT vs Sequence](#5-autoincrement-vs-sequence)
- [Part 2: Parameters Deep Dive](#part-2-parameters-deep-dive)
  - [6. START and INCREMENT](#6-start-and-increment)
  - [7. ORDER vs NOORDER](#7-order-vs-noorder)
  - [8. GETNEXTVAL Table Function](#8-getnextval-table-function)
  - [9. No CURRVAL in Snowflake](#9-no-currval-in-snowflake)
- [Part 3: Edge Cases & Gotchas](#part-3-edge-cases--gotchas)
  - [10. Gaps in Sequences](#10-gaps-in-sequences)
  - [11. Multiple NEXTVAL in One SELECT](#11-multiple-nextval-in-one-select)
  - [12. Sequence Exhaustion](#12-sequence-exhaustion)
  - [13. Changing INCREMENT Direction](#13-changing-increment-direction)
  - [14. ALTER SEQUENCE Delayed Effect](#14-alter-sequence-delayed-effect)
  - [15. Dropped Sequence Still Referenced](#15-dropped-sequence-still-referenced)
  - [16. Concurrent Inserts & Value Reservation](#16-concurrent-inserts--value-reservation)
- [Part 4: Production Patterns](#part-4-production-patterns)
  - [17. Primary Key Generation](#17-primary-key-generation)
  - [18. Multi-Table Insert with Shared Keys](#18-multi-table-insert-with-shared-keys)
  - [19. Ingesting & Normalizing Denormalized JSON](#19-ingesting--normalizing-denormalized-json)
  - [20. Debugging Sequences in Production](#20-debugging-sequences-in-production)
  - [21. Monitoring & Metadata Queries](#21-monitoring--metadata-queries)
- [Part 5: Alternatives](#part-5-alternatives)
  - [22. ROW_NUMBER() for Gap-Free Sequences](#22-row_number-for-gap-free-sequences)
  - [23. UUID_STRING() for Distributed IDs](#23-uuid_string-for-distributed-ids)
  - [24. SEQ1/SEQ2/SEQ4/SEQ8 Generators](#24-seq1seq2seq4seq8-generators)
- [Part 6: Interview Questions & Answers](#part-6-interview-questions--answers)

---

## Part 1: Fundamentals

### 1. What is a Sequence?

A sequence is a **schema-level object** that generates unique, incrementing numbers. Think of it as a counter that Snowflake manages for you.

**Key facts:**
- Unique across sessions, statements, and concurrent queries
- **NOT gap-free** — gaps are expected and by design
- Values are 64-bit integers (`-2^63` to `2^63 - 1`)
- Each call to `NEXTVAL` advances the counter — you **cannot go back**
- **No CURRVAL** in Snowflake (unlike Oracle/Postgres)

---

### 2. Creating a Sequence

**Syntax:**

```
CREATE [OR REPLACE] SEQUENCE <name>
  [START [=] <initial_value>]        -- default: 1
  [INCREMENT [BY] [=] <interval>]    -- default: 1
  [{ ORDER | NOORDER }]              -- default: NOORDER (since 2024_01)
  [COMMENT = '<text>']
```

**Example:**

```sql
CREATE OR REPLACE SEQUENCE my_first_seq
    START = 1
    INCREMENT = 1
    ORDER
    COMMENT = 'Demo sequence for learning';

DESCRIBE SEQUENCE my_first_seq;
SHOW SEQUENCES IN SCHEMA;
```

---

### 3. Using NEXTVAL

Each call advances the sequence and returns the next value:

```sql
SELECT my_first_seq.NEXTVAL;    -- returns 1
SELECT my_first_seq.NEXTVAL;    -- returns 2
SELECT my_first_seq.NEXTVAL;    -- returns 3
```

> **Important:** You cannot "peek" without advancing. Every `NEXTVAL` call consumes a value permanently.

---

### 4. Sequence as Column Default

```sql
CREATE OR REPLACE SEQUENCE emp_id_seq START = 1000 INCREMENT = 1 ORDER;

CREATE OR REPLACE TABLE employees (
    emp_id     INT DEFAULT emp_id_seq.NEXTVAL,
    emp_name   VARCHAR(100),
    department VARCHAR(50)
);

-- Omit emp_id — sequence fills it automatically
INSERT INTO employees (emp_name, department) VALUES ('Alice', 'Engineering');
INSERT INTO employees (emp_name, department) VALUES ('Bob', 'Marketing');
INSERT INTO employees (emp_name, department) VALUES ('Charlie', 'Sales');

-- Or explicitly use DEFAULT
INSERT INTO employees VALUES (DEFAULT, 'Diana', 'Engineering');

-- You CAN override the sequence with an explicit value
INSERT INTO employees VALUES (9999, 'Eve', 'Finance');

SELECT * FROM employees ORDER BY emp_id;
-- emp_id: 1000, 1001, 1002, 1003, 9999
```

> **Note:** Overriding with an explicit value does NOT affect the sequence counter.

---

### 5. AUTOINCREMENT vs Sequence

| Feature | AUTOINCREMENT | SEQUENCE |
|---------|---------------|----------|
| Defined in | Column definition | Separate schema object |
| Scope | Private to one table | Shareable across tables |
| Use case | Simple single-table PK | Multi-table FK inserts |
| Control | Limited | Full (ORDER/NOORDER, etc.) |
| Syntax | Simplest | More flexible |

**AUTOINCREMENT example:**

```sql
CREATE OR REPLACE TABLE auto_demo (
    id   INT AUTOINCREMENT START 1 INCREMENT 1,
    name VARCHAR(50)
);
```

**Use SEQUENCE when:**
1. Multiple tables need the same counter (FK relationships)
2. You need to reference the ID in a multi-table INSERT
3. You want explicit control over ORDER vs NOORDER
4. You need to share the counter across sessions/pipelines

**Use AUTOINCREMENT when:**
1. Single table, simple primary key
2. No cross-table ID sharing needed
3. You want the simplest syntax

---

## Part 2: Parameters Deep Dive

### 6. START and INCREMENT

```sql
-- Start at 100, increment by 10
CREATE OR REPLACE SEQUENCE by_tens START = 100 INCREMENT = 10;
SELECT by_tens.NEXTVAL;   -- 100
SELECT by_tens.NEXTVAL;   -- 110
SELECT by_tens.NEXTVAL;   -- 120

-- Negative increment (countdown)
CREATE OR REPLACE SEQUENCE countdown_seq START = 0 INCREMENT = -1;
SELECT countdown_seq.NEXTVAL;   -- 0
SELECT countdown_seq.NEXTVAL;   -- -1
SELECT countdown_seq.NEXTVAL;   -- -2
```

> **Important:** `START` value cannot be changed after creation. You must DROP and re-CREATE to reset it.

---

### 7. ORDER vs NOORDER

This is **critical for production**:

```
┌──────────────────────────────────────┬──────────────────────────────────────┐
│  ORDER                               │  NOORDER                             │
├──────────────────────────────────────┼──────────────────────────────────────┤
│  Values guaranteed in increasing     │  Values are unique but NOT           │
│  order across sequential statements  │  necessarily increasing              │
│                                      │                                      │
│  Slower with concurrent inserts      │  Faster with concurrent inserts      │
│  (global coordination needed)        │  (each node gets its own batch)      │
│                                      │                                      │
│  Use for: audit logs, sequential     │  Use for: high-throughput pipelines, │
│  IDs where order matters             │  PKs where only uniqueness matters   │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

With `NOORDER` and concurrent inserts from multiple sessions:

```
Session A: 1, 2, 3
Session B: 101, 102, 103     ← jumped to a different batch
Session A: 4, 5, 6
Session B: 104, 105, 106
```

> **Since 2024:** `NOORDER` is the default. To force sequential behavior, explicitly specify `ORDER`.

---

### 8. GETNEXTVAL Table Function

When you need the **SAME** sequence value for multiple columns in one row:

```sql
-- WRONG: Two NEXTVAL calls give DIFFERENT values per row
SELECT n, shared_seq.NEXTVAL AS id_a, shared_seq.NEXTVAL AS id_b
FROM demo_table;
-- Row 1: n=100, id_a=1, id_b=2    ← different!

-- RIGHT: GETNEXTVAL gives the SAME value for both columns
SELECT n, s.NEXTVAL AS id_a, s.NEXTVAL AS id_b
FROM demo_table, TABLE(GETNEXTVAL(shared_seq2)) s;
-- Row 1: n=100, id_a=1, id_b=1    ← same!
```

> **Note:** `GETNEXTVAL` is a **table function** — it can only be used in the `FROM` clause of a SELECT, not in a `DEFAULT` expression. For column defaults, use `seq_name.NEXTVAL`.

---

### 9. No CURRVAL in Snowflake

Unlike Oracle/Postgres, Snowflake has **no CURRVAL**. You cannot do:

```sql
-- THIS DOES NOT WORK IN SNOWFLAKE:
INSERT INTO parent ...;
INSERT INTO child (parent_id) VALUES (parent_seq.CURRVAL);
```

**Workaround:** Use `GETNEXTVAL` + multi-table INSERT (see [Section 18](#18-multi-table-insert-with-shared-keys))

---

## Part 3: Edge Cases & Gotchas

### 10. Gaps in Sequences

Snowflake sequences are **NOT gap-free**. Gaps happen because:

1. **Pre-allocation:** Snowflake pre-allocates batches of values to each compute node. Unused values in a batch are lost.
2. **Failed transactions:** If an INSERT fails or is rolled back, consumed sequence values are NOT returned.
3. **NOORDER mode:** Each node gets its own range, creating visible gaps.
4. **Concurrent queries:** Multiple sessions each get their own batch.

> **This is by design.** If you need gap-free numbering, use `ROW_NUMBER()` ([Section 22](#22-row_number-for-gap-free-sequences)).

```sql
INSERT INTO gap_demo (val) VALUES (1), (2), (3);
-- Suppose next query fails → values 4+ consumed but never inserted
INSERT INTO gap_demo (val) VALUES (4), (5);
-- You might see: 1, 2, 3, 6, 7   ← gap at 4 and 5
```

---

### 11. Multiple NEXTVAL in One SELECT

Each `NEXTVAL` reference in a SELECT generates a **DIFFERENT** value:

```sql
SELECT
    multi_ref_seq.NEXTVAL AS col_a,
    multi_ref_seq.NEXTVAL AS col_b,
    multi_ref_seq.NEXTVAL AS col_c
FROM TABLE(GENERATOR(ROWCOUNT => 2));

-- Result:
-- COL_A | COL_B | COL_C
--   1   |   2   |   3      ← row 1: three different values
--   4   |   5   |   6      ← row 2: three different values
```

---

### 12. Sequence Exhaustion

Sequences use 64-bit integers: **-9,223,372,036,854,775,808** to **9,223,372,036,854,775,807**

Exceeding this range causes a query failure. With `INCREMENT = 1`, this would take ~292 billion years at 1 billion values/second — but large increments can exhaust it faster.

---

### 13. Changing INCREMENT Direction

> **WARNING: Duplicate Risk!**

If you change from positive to negative increment (or vice versa), you **WILL** get duplicate values:

```sql
CREATE OR REPLACE SEQUENCE direction_demo START = 1 INCREMENT = 1 ORDER;
INSERT INTO direction_test (val) VALUES (1), (2), (3);
-- IDs: 1, 2, 3

ALTER SEQUENCE direction_demo SET INCREMENT = -1;
INSERT INTO direction_test (val) VALUES (4), (5);
-- IDs might be: 4, 3  ← DUPLICATE 3!
```

---

### 14. ALTER SEQUENCE Delayed Effect

When you `ALTER SEQUENCE ... SET INCREMENT`, the change may **NOT** take effect on the very next `NEXTVAL` call:

```sql
INSERT INTO delay_test (val) VALUES (1), (2), (3);
-- IDs: 1, 2, 3

ALTER SEQUENCE delay_demo SET INCREMENT = -4;
INSERT INTO delay_test (val) VALUES (4), (5);
-- IDs might be: 4, 0   ← First value IGNORES the new increment!
```

> This is documented behavior — Snowflake pre-calculates the next value before the ALTER takes effect.

---

### 15. Dropped Sequence Still Referenced

If a table's `DEFAULT` references a sequence and you DROP the sequence:

```sql
DROP SEQUENCE temp_seq;

-- This will FAIL:
INSERT INTO seq_ref_test (name) VALUES ('Fails');
-- Error: identifier 'TEMP_SEQ' does not exist
```

**Fix:** Recreate the sequence, but set `START` high enough to avoid ID collisions:

```sql
CREATE SEQUENCE temp_seq START = 100 INCREMENT = 1;
```

---

### 16. Concurrent Inserts & Value Reservation

With `NOORDER`, each compute node pre-allocates its own batch independently:

```
Node A gets batch: 1-100
Node B gets batch: 101-200
Node A inserts:    1, 2, 3
Node B inserts:    101, 102
Node A inserts:    4, 5
```

This explains why you see large gaps even when no errors occurred.

---

## Part 4: Production Patterns

### 17. Primary Key Generation

```sql
CREATE OR REPLACE SEQUENCE order_pk_seq START = 1 INCREMENT = 1 ORDER;

CREATE OR REPLACE TABLE prod_orders (
    order_id    INT DEFAULT order_pk_seq.NEXTVAL,
    customer    VARCHAR(100),
    total       NUMBER(12,2),
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO prod_orders (customer, total)
VALUES ('Acme Corp', 1500.00), ('Globex', 2300.50), ('Initech', 890.00);
```

---

### 18. Multi-Table Insert with Shared Keys

The most important production pattern — inserting into **parent + child tables** with matching foreign keys in one statement:

```sql
CREATE OR REPLACE SEQUENCE parent_seq START = 1 INCREMENT = 1;
CREATE OR REPLACE SEQUENCE child_seq START = 1 INCREMENT = 1;

CREATE OR REPLACE TABLE parents (parent_id INT, name VARCHAR);
CREATE OR REPLACE TABLE children (child_id INT, parent_id INT, detail VARCHAR);

INSERT ALL
    WHEN 1=1 THEN INTO parents VALUES (p_id, name)
    WHEN 1=1 THEN INTO children VALUES (c_id, p_id, detail)
SELECT
    parent_seq.NEXTVAL AS p_id,
    child_seq.NEXTVAL AS c_id,
    name,
    detail
FROM (
    SELECT 'Alice' AS name, 'alice@email.com' AS detail
    UNION ALL
    SELECT 'Bob', 'bob@email.com'
);

-- parents.parent_id matches children.parent_id!
```

---

### 19. Ingesting & Normalizing Denormalized JSON

Real-world pattern: JSON with nested contacts → `people` + `contacts` tables:

```sql
CREATE OR REPLACE SEQUENCE people_seq START = 1 INCREMENT = 1;
CREATE OR REPLACE SEQUENCE contact_seq START = 1 INCREMENT = 1;

INSERT INTO json_staging SELECT PARSE_JSON('[
    {
        "firstName": "John", "lastName": "Doe",
        "contacts": [
            {"type": "phone", "data": "555-0100"},
            {"type": "email", "data": "john@example.com"}
        ]
    },
    {
        "firstName": "Jane", "lastName": "Smith",
        "contacts": [
            {"type": "phone", "data": "555-0200"},
            {"type": "email", "data": "jane@example.com"}
        ]
    }
]');

INSERT ALL
    WHEN 1=1 THEN
        INTO contacts VALUES (c_next, p_next, contact_value:type, contact_value:data)
    WHEN contact_index = 0 THEN
        INTO people VALUES (p_next, person_value:firstName, person_value:lastName)
SELECT *
FROM (
    SELECT
        f1.value AS person_value,
        f2.value AS contact_value,
        f2.index AS contact_index,
        p_seq.NEXTVAL AS p_next,
        c_seq.NEXTVAL AS c_next
    FROM json_staging,
         LATERAL FLATTEN(raw) f1,
         TABLE(GETNEXTVAL(people_seq)) p_seq,
         LATERAL FLATTEN(f1.value:contacts) f2,
         TABLE(GETNEXTVAL(contact_seq)) c_seq
);
```

> `GETNEXTVAL` ensures each person gets the **same** `p_next` value across all their contact rows.

---

### 20. Debugging Sequences in Production

| Problem | Cause | Fix |
|---------|-------|-----|
| IDs jumping by 100+ | `NOORDER` mode — nodes pre-allocate batches | Use `ORDER` if sequential IDs matter |
| Insert failed but IDs jumped | Sequence values consumed before transaction completes | Expected behavior — sequences are NOT transactional |
| Two tables have same IDs | Sequence was DROP/recreated (reset to START) | Never DROP/recreate sequences in production |
| IDs not starting where expected | Batches pre-allocated but unused | Run `SHOW SEQUENCES` — check `next_value` column |

---

### 21. Monitoring & Metadata Queries

```sql
SHOW SEQUENCES;
DESCRIBE SEQUENCE order_pk_seq;

SELECT *
FROM INFORMATION_SCHEMA.SEQUENCES
WHERE SEQUENCE_SCHEMA = CURRENT_SCHEMA()
ORDER BY SEQUENCE_NAME;

SELECT GET_DDL('SEQUENCE', 'order_pk_seq');
```

---

## Part 5: Alternatives

### 22. ROW_NUMBER() for Gap-Free Sequences

If you **must** have gap-free numbers (invoices, receipts), don't use sequences:

```sql
SELECT
    ROW_NUMBER() OVER (ORDER BY created_at) AS invoice_number,
    order_id, customer, total
FROM prod_orders
ORDER BY created_at;
```

---

### 23. UUID_STRING() for Distributed IDs

When you need globally unique IDs without a central counter:

```sql
CREATE OR REPLACE TABLE events (
    event_id   VARCHAR DEFAULT UUID_STRING(),
    event_type VARCHAR,
    payload    VARIANT
);
```

| Pros | Cons |
|------|------|
| No coordination needed | Larger storage (36 chars) |
| Works across distributed systems | Not human-readable |
| Zero contention | No natural ordering |

---

### 24. SEQ1/SEQ2/SEQ4/SEQ8 Generators

Built-in functions for generating monotonic integers with `GENERATOR()`:

```sql
SELECT SEQ8() AS row_num FROM TABLE(GENERATOR(ROWCOUNT => 10));

-- Generate 1000 test rows
SELECT
    SEQ4() + 1 AS id,
    'user_' || (SEQ4() + 1)::STRING AS username,
    UNIFORM(18, 65, RANDOM()) AS age
FROM TABLE(GENERATOR(ROWCOUNT => 1000));
```

> These are for **data generation**, NOT for primary keys in real tables.

---

## Part 6: Interview Questions & Answers

### Q1: Are Snowflake sequences gap-free?

**A:** No. Sequences guarantee **uniqueness** but NOT contiguity. Gaps happen due to pre-allocation, failed transactions, NOORDER mode, and concurrent access.

### Q2: What is the difference between ORDER and NOORDER?

**A:** `ORDER` guarantees values increase sequentially across statements. `NOORDER` does not — values are unique but can appear out of order. `NOORDER` is faster because each compute node gets its own batch without global coordination. Since 2024_01 bundle, `NOORDER` is the default.

### Q3: Does Snowflake support CURRVAL?

**A:** No. Workaround: Use `GETNEXTVAL` table function or nested subqueries to share the same value across columns/tables.

### Q4: What happens if two NEXTVAL calls are in the same SELECT?

**A:** Each reference generates a **different** value per row. To get the same value, use: `TABLE(GETNEXTVAL(seq))` in the FROM clause.

### Q5: Can you reset a sequence to start from 1 again?

**A:** You cannot ALTER the START value. You must DROP and re-CREATE. **Warning:** This can cause duplicate IDs if the table still has old data.

### Q6: What happens if you DROP a sequence that a table references?

**A:** INSERTs using DEFAULT will fail with "identifier does not exist". Existing rows are unaffected. Recreating the sequence fixes it, but the new START must avoid collisions.

### Q7: Sequence vs AUTOINCREMENT — when do you use each?

**A:** AUTOINCREMENT: simple, private to one table. SEQUENCE: separate object, shareable across tables, needed for multi-table FK inserts and explicit ORDER/NOORDER control.

### Q8: How do you generate gap-free numbers in Snowflake?

**A:** Use `ROW_NUMBER() OVER (ORDER BY ...)` at query time or during INSERT. Don't use sequences for this.

### Q9: What is the maximum value a sequence can produce?

**A:** `9,223,372,036,854,775,807` (2^63 - 1). Exceeding this causes a query failure.

### Q10: How does NOORDER improve performance?

**A:** Each compute node pre-allocates its own batch independently — no cross-node coordination needed, eliminating a serialization bottleneck.

### Q11: Can concurrent queries ever see the same sequence value?

**A:** No (as long as you don't change the increment sign). Concurrent queries NEVER observe the same value.

### Q12: How do you insert into parent and child tables with matching keys without CURRVAL?

**A:** Use `INSERT ALL` with `GETNEXTVAL`:

```sql
INSERT ALL
  WHEN 1=1 THEN INTO parent VALUES (p_id, name)
  WHEN 1=1 THEN INTO child VALUES (c_id, p_id, detail)
SELECT p_seq.NEXTVAL AS p_id, c_seq.NEXTVAL AS c_id, name, detail
FROM source, TABLE(GETNEXTVAL(parent_seq)) p_seq;
```

### Q13: What is GETNEXTVAL and why does it exist?

**A:** A special 1-row table function that generates one unique value per joined row. Unlike `NEXTVAL` (different value for each reference), `GETNEXTVAL` lets you reference the same value in multiple columns.

### Q14: How would you monitor sequences in production?

**A:** `SHOW SEQUENCES IN SCHEMA` (lists all with `next_value`), `DESCRIBE SEQUENCE <name>`, `INFORMATION_SCHEMA.SEQUENCES`, and `GET_DDL('SEQUENCE', '<name>')`.

### Q15: ALTER SEQUENCE changes don't take effect immediately. Why?

**A:** Snowflake pre-calculates the next value. So `ALTER SEQUENCE SET INCREMENT` might not affect the very next `NEXTVAL` call — it takes effect on the one after that. This is documented behavior.

---

*Built with Snowflake Sequences — from beginner concepts to production-grade patterns.*
