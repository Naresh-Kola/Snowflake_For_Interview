# Snowflake Streams — Complete Internal Workflow

## 1. What Is a Stream?

A Stream is a **BOOKMARK** (called "offset") on a table's version history. It tracks: "last time I was consumed, the table was at version X." When you query the stream, it shows: "what changed from version X to now?"

A Stream does **NOT** store data. It's just a pointer.

```
Table versions: v1 → v2 → v3 → v4 → v5 → v6 → v7 (current)
                            ▲                        ▲
                            │                        │
                       Stream OFFSET           Current version
                       (last consumed)         (latest)

SELECT * FROM stream → shows net changes from v3 to v7
```

---

## 2. How a Stream Works Internally

| Step | Action | Detail |
|------|--------|--------|
| 1 | CREATE STREAM | Records current table version as offset. No data copied. |
| 2 | DML happens | Table versions advance (v3→v4→v5...). Stream does nothing. |
| 3 | SELECT FROM stream | Computes net delta (offset vs now). **Offset does NOT move.** |
| 4 | Consume in DML | `INSERT INTO target SELECT * FROM stream;` → Offset advances. |

**Key Rules:**
- SELECT alone does NOT advance the offset (you can peek without consuming)
- Only DML that reads from the stream advances the offset
- If you don't consume for too long → stream goes STALE (data retention expires)

---

## 3. Net Delta in Streams — Same Logic as Dynamic Tables

Streams compute net delta the EXACT same way as DTs:
1. Compare partition snapshot at OFFSET vs partition snapshot NOW
2. Find ADDED/REMOVED partitions
3. Match ROW_IDs to detect updates vs genuine inserts/deletes
4. Cancel out unchanged rows

### Example 1: INSERT → UPDATE → UPDATE (same row)

Stream created at v1. Table has rows 1-5.

- v2: INSERT id=6, price=100
- v3: UPDATE id=6, price=200
- v4: UPDATE id=6, price=300

**SELECT * FROM stream:** (compares v1 vs v4)

| METADATA$ACTION | METADATA$ISUPDATE | DATA |
|-----------------|-------------------|------|
| INSERT | FALSE | (6, price=300) |

> At v1, row 6 didn't exist. At v4, it exists with price=300. Intermediate prices (100, 200) are invisible.

---

### Example 2: UPDATE existing row

Stream at v1. Row id=2 exists with price=500.

- v2: UPDATE id=2, price=600
- v3: UPDATE id=2, price=750

**SELECT * FROM stream:** (compares v1 vs v3)

| METADATA$ACTION | METADATA$ISUPDATE | DATA |
|-----------------|-------------------|------|
| DELETE | TRUE | (2, price=500) ← old value |
| INSERT | TRUE | (2, price=750) ← new value |

> Same ROW_ID in both → ISUPDATE=TRUE → this is a modification. Price 600 is invisible.

---

### Example 3: INSERT then DELETE (cancels out)

Stream at v1. Row id=9 does NOT exist.

- v2: INSERT id=9, price=50
- v3: DELETE id=9

**SELECT * FROM stream:** EMPTY (no rows)

> At v1, row 9 didn't exist. At v3, row 9 doesn't exist. Born and died between reads → invisible.

---

### Example 4: DELETE existing row

Stream at v1. Row id=3 exists with status='ACTIVE'.

- v2: DELETE id=3

**SELECT * FROM stream:**

| METADATA$ACTION | METADATA$ISUPDATE | DATA |
|-----------------|-------------------|------|
| DELETE | FALSE | (3, status=ACTIVE) |

> No corresponding INSERT with same ROW_ID → ISUPDATE=FALSE. Genuine deletion.

---

### Example 5: Mixed operations on multiple rows

Stream at v1. Table has: id=1(A), id=2(B), id=3(C)

- INSERT id=4(D)
- UPDATE id=1 → A becomes A2
- DELETE id=3
- INSERT id=5(E), then DELETE id=5

**SELECT * FROM stream:**

| METADATA$ACTION | METADATA$ISUPDATE | DATA |
|-----------------|-------------------|------|
| DELETE | TRUE | (1, A) ← old value |
| INSERT | TRUE | (1, A2) ← new value |
| DELETE | FALSE | (3, C) ← genuinely gone |
| INSERT | FALSE | (4, D) ← genuinely new |

**Notice:**
- id=2 unchanged → not in stream (cancelled in ROW_ID match)
- id=5 born+died → invisible
- id=1 modified → DELETE(old) + INSERT(new), ISUPDATE=TRUE

---

## 4. Offset Advancement

### Does NOT advance offset:
```sql
SELECT * FROM my_stream;          -- just peeking
SELECT COUNT(*) FROM my_stream;   -- just counting
```

### ADVANCES offset (stream is "consumed"):
```sql
INSERT INTO target SELECT * FROM my_stream;
MERGE INTO target USING my_stream ...;
CREATE TABLE x AS SELECT * FROM my_stream;
```

**The rule:** Offset moves when the stream is used as a SOURCE in DML that COMMITS successfully.

```
v1 ──── v2 ──── v3 ──── v4 ──── v5 ──── v6
▲                                ▲        ▲
offset                    consume here   now
(created)                (offset moves
                          to v4)

After consuming at v4:
  Next SELECT * FROM stream → shows changes from v4 to v6 only
  Changes v1→v4 are GONE (already processed)
```

---

## 5. Hands-On Lab

```sql
-- Create source table
CREATE OR REPLACE TABLE OPENFLOW_DB.PUBLIC.stream_lab_orders (
    order_id INT, product VARCHAR(50), price DECIMAL(10,2)
);

INSERT INTO OPENFLOW_DB.PUBLIC.stream_lab_orders VALUES
    (1, 'Laptop', 999.99), (2, 'Phone', 699.99), (3, 'Tablet', 399.99);

-- Create stream (offset = current version)
CREATE OR REPLACE STREAM OPENFLOW_DB.PUBLIC.stream_lab_changes
    ON TABLE OPENFLOW_DB.PUBLIC.stream_lab_orders;

-- Stream is empty (no changes since creation)
SELECT * FROM OPENFLOW_DB.PUBLIC.stream_lab_changes;

-- Make changes
INSERT INTO OPENFLOW_DB.PUBLIC.stream_lab_orders VALUES (4, 'Monitor', 349.99);
UPDATE OPENFLOW_DB.PUBLIC.stream_lab_orders SET price = 749.99 WHERE order_id = 2;
DELETE FROM OPENFLOW_DB.PUBLIC.stream_lab_orders WHERE order_id = 3;

-- See net delta
SELECT order_id, product, price,
       METADATA$ACTION, METADATA$ISUPDATE, METADATA$ROW_ID
FROM OPENFLOW_DB.PUBLIC.stream_lab_changes
ORDER BY order_id;

-- Consume the stream (offset advances)
CREATE OR REPLACE TABLE OPENFLOW_DB.PUBLIC.stream_lab_target (
    order_id INT, product VARCHAR(50), price DECIMAL(10,2)
);

INSERT INTO OPENFLOW_DB.PUBLIC.stream_lab_target
SELECT order_id, product, price
FROM OPENFLOW_DB.PUBLIC.stream_lab_changes
WHERE METADATA$ACTION = 'INSERT';

-- Stream is now empty (offset moved past all consumed changes)
SELECT * FROM OPENFLOW_DB.PUBLIC.stream_lab_changes;
```

---

## 6. TRUNCATE + INSERT vs UPDATE — Impact on Streams

### UPDATE (preserves ROW_ID):
```
DELETE(old_value, ISUPDATE=TRUE) + INSERT(new_value, ISUPDATE=TRUE)
```
Stream recognizes it as the SAME row modified.

### DELETE + INSERT (destroys ROW_ID):
```
DELETE(old_value, ISUPDATE=FALSE) + INSERT(new_value, ISUPDATE=FALSE)
```
Stream treats them as a genuine delete and a genuine new row.

### TRUNCATE + INSERT (destroys all ROW_IDs):
```
5 DELETEs (ISUPDATE=FALSE) + 5 INSERTs (ISUPDATE=FALSE) = 10 records
```
Even if data is identical. TRUNCATE breaks ROW_ID linkage. Expensive for CDC pipelines.

> **Best practice:** Prefer UPDATE/MERGE over TRUNCATE + reload when using streams.
