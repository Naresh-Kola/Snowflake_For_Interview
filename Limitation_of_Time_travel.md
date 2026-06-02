# Time Travel vs Clone: Recovering Dropped Columns

## The Problem

When you **drop a column** from a table, Time Travel queries **cannot** retrieve that column — but a **Clone** can. Here's why:

---

## Time Travel Uses CURRENT Schema (DDL)

Time Travel only preserves **data**, NOT **metadata/structure**. When you query with `AT` or `BEFORE`, Snowflake uses the **current table definition** (current DDL) to return results.

### Example:

```sql
-- Table has 2 columns: col1, col2
CREATE TABLE my_table (col1 VARCHAR, col2 INT);
INSERT INTO my_table VALUES ('a', 1), ('b', 2);

-- Save a query ID before the drop
SET qid = LAST_QUERY_ID();

-- Drop col2
ALTER TABLE my_table DROP COLUMN col2;

-- Time Travel query — ONLY returns col1 (col2 is gone!)
SELECT * FROM my_table AT(STATEMENT => $qid);
-- Result: only col1 is visible
```

**Why?** Time Travel reads historical *data* but maps it to the *current schema*. Since `col2` no longer exists in the table definition, it won't appear — even though the data still exists internally.

---

## Clone Restores BOTH Schema + Data

A **Clone with Time Travel** creates a full copy of the table as it existed at that point in time — including the **metadata (DDL) AND the data**.

### Example:

```sql
-- Clone the table to a point BEFORE the column was dropped
CREATE TABLE restored_table CLONE my_table AT(STATEMENT => $qid);

-- Now query the clone — col2 is back!
SELECT * FROM restored_table;
-- Result: col1 AND col2 are both visible
```

**Why?** The `CREATE ... CLONE ... AT(...)` command recreates the **entire table object** (structure + data) as it was at that timestamp.

---

## Summary Comparison

| Feature | Time Travel (`SELECT ... AT`) | Clone (`CREATE ... CLONE ... AT`) |
|---------|-------------------------------|-----------------------------------|
| Restores data (rows) | Yes | Yes |
| Restores schema/DDL (columns) | **No** — uses current schema | **Yes** — restores original schema |
| Creates a new object | No (queries in-place) | Yes (new table) |
| Use case | Query old row values | Recover from DDL changes (dropped columns, altered types) |

---

## Key Takeaway

- **Time Travel** = time-travels the **data only**, always viewed through the **current** table structure
- **Clone at a timestamp** = creates a **snapshot of the entire table** (structure + data) at that point in time

So if you accidentally drop a column:
```sql
-- This WON'T work (column missing from current DDL):
SELECT * FROM my_table BEFORE(STATEMENT => '<drop_statement_id>');

-- This WILL work (clone restores full DDL + data):
CREATE TABLE recovered CLONE my_table BEFORE(STATEMENT => '<drop_statement_id>');
SELECT * FROM recovered;  -- dropped column is back
```
