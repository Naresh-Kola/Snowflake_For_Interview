# Snowflake Streams -- Complete Guide
## Definitions | Internal Architecture | Examples | Interview Questions
### From Scratch to Architect Level

---

# Part 1: What Is a Stream?

## 1.1 Definition

A STREAM is a Snowflake object that records DML changes (INSERT, UPDATE, DELETE) made to a source object. It is Snowflake's native mechanism for Change Data Capture (CDC).

Think of a stream as a **BOOKMARK** in a table's change history. It tells you: "What changed since the last time I looked?"

**Key Facts:**
- A stream does NOT store actual data -- only an OFFSET (a pointer)
- It returns CDC records by leveraging the table's versioning history
- Multiple streams on the same table are INDEPENDENT (separate offsets)
- A stream advances its offset ONLY when consumed in a DML transaction
- Simply querying (SELECT) a stream does NOT advance the offset
- Hidden columns are added to the source table for change tracking (small storage overhead)
- Streams can be created on: tables, views, directory tables, dynamic tables, Iceberg tables, event tables, external tables

**Analogy:**

Imagine a library book with a bookmark. The bookmark (stream) marks where you stopped reading. The book (table) keeps getting new pages added. When you read (consume in DML), you move the bookmark forward. Just peeking at the page (SELECT) does NOT move the bookmark. You can have multiple bookmarks (streams) in the same book.

## 1.2 What Problems Do Streams Solve?

**Without streams (the old way):**
1. Full table scans to detect changes (expensive, slow)
2. Timestamp-based CDC: `WHERE updated_at > @last_run` (misses deletes)
3. Trigger-based CDC: Overhead on source, complex to maintain
4. Manual diff: Compare two snapshots (expensive at scale)

**With streams:**
1. Automatic: Snowflake tracks every INSERT, UPDATE, DELETE
2. Efficient: Only changed rows are surfaced -- zero full scans
3. Complete: Captures inserts, updates, AND deletes
4. Transactional: Exactly-once processing via offset advancement
5. Lightweight: Only stores an offset, not data copies

---

# Part 2: Internal Architecture -- How Streams Work

## 2.1 Table Versioning

Every committed DML transaction creates a new TABLE VERSION. Snowflake maintains a timeline of these versions internally.

A new table version is created for: standard tables, directory tables, dynamic tables, external tables, Apache Iceberg tables, and underlying tables for a view.

```
Timeline:  v1 -> v2 -> v3 -> v4 -> v5 -> v6 -> v7 -> v8 -> v9 -> v10
                        ^                                          ^
                   Stream offset                            Current version
                   (between v3 & v4)                        (v10)
```

When queried, the stream returns all changes from v4 through v10. This is the "delta" or "change set". The stream provides the MINIMAL set of changes from its current offset to the current version of the table.

## 2.2 Offset Storage

- **When a stream is CREATED**: Offset is initialized to the CURRENT transactional version. No existing data appears in the stream (unless `SHOW_INITIAL_ROWS = TRUE`).
- **When the stream is CONSUMED in a DML transaction**: Offset advances to the transaction start time. All change data between the old offset and new offset is "consumed".
- **When the stream is QUERIED (SELECT only)**: Offset stays the same -- nothing moves. You can preview changes without losing them.

**Important**: The stream stores ONLY the offset pointer. It does NOT copy or store any table rows. CDC records are reconstructed on-the-fly from the table's versioning history and the hidden change tracking columns.

## 2.3 Change Tracking Metadata (Hidden Columns)

When the FIRST stream is created on a table (or `CHANGE_TRACKING = TRUE` is set), Snowflake adds HIDDEN columns to the source table:

- Row-level change metadata
- Version information for each row
- Row identity tracking

These columns are INVISIBLE in normal queries but consume a SMALL amount of additional storage.

The CDC records returned by the stream come from: Stream's stored offset + Table's hidden change tracking metadata.

For VIEWS: change tracking must be enabled EXPLICITLY on the view AND its underlying tables:

```sql
ALTER TABLE t SET CHANGE_TRACKING = TRUE;
ALTER VIEW v SET CHANGE_TRACKING = TRUE;
```

## 2.4 Stream Metadata Columns

When you query a stream, you get ALL the source table's columns PLUS three additional metadata columns:

| Column | Description |
|--------|-------------|
| METADATA$ACTION | `'INSERT'` or `'DELETE'` (there is no `'UPDATE'` -- see below) |
| METADATA$ISUPDATE | TRUE if this row is part of an UPDATE operation; FALSE for pure inserts or deletes |
| METADATA$ROW_ID | Unique, immutable row identifier. Tracks the same row across changes over time. May change if CHANGE_TRACKING is disabled/re-enabled |

**How Updates Are Represented:**

An UPDATE is stored as TWO rows:
- Row 1: `METADATA$ACTION = 'DELETE'`, `METADATA$ISUPDATE = TRUE` (old values)
- Row 2: `METADATA$ACTION = 'INSERT'`, `METADATA$ISUPDATE = TRUE` (new values)

Both rows share the same METADATA$ROW_ID.

**Example:**

```sql
UPDATE employees SET salary = 90000 WHERE id = 1;
```

Stream output:

| ID | SALARY | METADATA$ACTION | METADATA$ISUPDATE | METADATA$ROW_ID |
|----|--------|-----------------|-------------------|-----------------|
| 1 | 80000 | DELETE | TRUE | abc123 | (old)
| 1 | 90000 | INSERT | TRUE | abc123 | (new)

## 2.5 Net Change (Delta) Computation -- Standard Streams

A STANDARD stream returns the NET MINIMUM set of changes. It performs a join on inserted and deleted rows to compute the delta.

**Scenarios:**

1. Row inserted then deleted (between two offsets): NOT returned (cancels out)
2. Row inserted then updated: Returned as a SINGLE INSERT with the LATEST values. `METADATA$ISUPDATE = FALSE` (because net effect is a new row)
3. Row updated multiple times: Returned as ONE DELETE (old) + ONE INSERT (new) with final values
4. Row deleted: Returned as DELETE, `METADATA$ISUPDATE = FALSE`
5. Row updated then deleted: Returned as DELETE, `METADATA$ISUPDATE = FALSE` (net = removed)

This "net delta" behavior makes standard streams efficient: you only see the minimum changes needed to bring the target up to date.

## 2.6 Repeatable Read Isolation

Streams support REPEATABLE READ isolation (not read committed).

Within a transaction, ALL queries to the same stream see IDENTICAL data -- even if the source table changes mid-transaction.

How it works:
1. Transaction 1 begins at time T1
2. Query stream -> sees changes from offset to T1
3. Another process inserts rows into the source table at T2
4. Query stream again in same transaction -> still sees T1 snapshot
5. Transaction 1 commits -> stream advances to T1
6. Transaction 2 begins -> NOW sees changes from T1 onward

This ensures consistent CDC processing within a single transaction.

**Important**: Within an explicit transaction (BEGIN...COMMIT): the stream is LOCKED when consumed in DML. Parallel DML on the source table is tracked but does NOT update the stream until the explicit transaction commits.

## 2.7 Visual: Complete Stream Data Flow

```
+--------------------------------------------------------------+
|  SOURCE TABLE                                                |
|                                                              |
|  INSERT INTO t VALUES (1, 'Alice');   -- creates version v4  |
|  UPDATE t SET name='Bob' WHERE id=2;  -- creates version v5  |
|  DELETE FROM t WHERE id=3;            -- creates version v6  |
+----------------------------+---------------------------------+
                             |
                             |  Hidden change tracking columns
                             |  record every row-level change
                             v
+--------------------------------------------------------------+
|  STREAM (offset at v3)                                       |
|                                                              |
|  SELECT * FROM my_stream;                                    |
|  -> Returns net delta: v4 + v5 + v6 changes                 |
|  -> Offset does NOT move (just a SELECT)                     |
+----------------------------+---------------------------------+
                             |
                             |  Consume in DML transaction
                             v
+--------------------------------------------------------------+
|  MERGE INTO target USING my_stream ...                       |
|                                                              |
|  -> Transaction commits successfully                         |
|  -> Stream offset advances to v6                             |
|  -> Stream is now EMPTY (all changes consumed)               |
+--------------------------------------------------------------+
```

## 2.8 Deep Dive -- "If Streams Don't Store Data, How Can I See Data?"

When you run `SELECT * FROM my_stream;`, Snowflake does NOT read rows from a "stream storage location." Instead, it DYNAMICALLY RECONSTRUCTS the change set by:

1. Reading the stream's stored OFFSET (a table version number)
2. Reading the SOURCE TABLE's hidden change tracking columns
3. Computing the delta between the offset version and the current version
4. Returning the result as if it were a table

The stream is essentially a VIRTUAL TABLE -- a read-only query that Snowflake generates behind the scenes every time you SELECT from it.

**Analogy:** Think of a SQL VIEW. A view doesn't store data either. When you `SELECT * FROM my_view`, Snowflake runs the underlying query and returns results. The view just stores a QUERY DEFINITION. Similarly, a stream stores an OFFSET. When you query it, Snowflake runs an internal query that says: "Give me all row-level changes between offset version X and the current table version, using the hidden columns." The data lives in the SOURCE TABLE (+ its micro-partition history). The stream just tells Snowflake WHERE to look.

## 2.9 What's Physically Stored: A Visual Breakdown

```
+---------------------------------------------------------------------+
|                     SOURCE TABLE (employees)                        |
|                                                                     |
|  VISIBLE COLUMNS          |  HIDDEN COLUMNS (added by stream)       |
|  (your data)              |  (change tracking metadata)             |
|                           |                                         |
|  emp_id  name     salary  |  __row_version  __is_deleted  __row_id  |
|  ------  -------  ------  |  ------------  -----------  ---------   |
|  1       Alice    80000   |  v3            FALSE        abc001      |
|  2       Bob      85000   |  v5            FALSE        abc002      |
|  4       Diana    70000   |  v4            FALSE        abc004      |
|                           |                                         |
|  (emp_id=3 was deleted    |  v6            TRUE         abc003      |
|   -- still tracked in     |                                         |
|   historical versions)    |                                         |
+---------------------------------------------------------------------+

+---------------------------------------------------------------------+
|                     STREAM (employees_stream)                       |
|                                                                     |
|  What's stored:                                                     |
|    * Offset = v3  (just a single version pointer)                   |
|    * Source object reference = employees table                      |
|    * Stream type = STANDARD                                         |
|                                                                     |
|  That's it. NO rows. NO copies of data.                            |
+---------------------------------------------------------------------+
```

When you run `SELECT * FROM employees_stream;`, Snowflake internally executes something conceptually like:

> "Find all rows in employees (and its Time Travel history) where __row_version > v3 (the stream offset) and compute the net delta using __is_deleted and __row_id and return them with METADATA$ACTION, METADATA$ISUPDATE, METADATA$ROW_ID"

The result is COMPUTED ON THE FLY from the source table's data.

## 2.10 What Are the Hidden Columns?

When the FIRST stream is created on a table (or you manually set `CHANGE_TRACKING = TRUE`), Snowflake adds hidden columns to the table.

These columns are:
- INVISIBLE in `SELECT *` -- you cannot see or query them directly
- INVISIBLE in `DESCRIBE TABLE` -- they don't appear in the schema
- AUTOMATICALLY MAINTAINED by Snowflake on every DML operation
- Used INTERNALLY to compute change deltas for streams

They track:
1. Which version a row was created/modified in
2. Whether a row was deleted (stored in Time Travel micro-partitions)
3. A unique row identifier for tracking the same row across versions

**Proof That They Exist:**

```sql
CREATE OR REPLACE TABLE ct_test (id INT, val STRING);
INSERT INTO ct_test SELECT SEQ4(), 'row_' || SEQ4()
    FROM TABLE(GENERATOR(ROWCOUNT => 1000000));

SELECT BYTES FROM TABLE(INFORMATION_SCHEMA.TABLE_STORAGE_METRICS())
    WHERE TABLE_NAME = 'CT_TEST';

ALTER TABLE ct_test SET CHANGE_TRACKING = TRUE;
INSERT INTO ct_test VALUES (0, 'trigger_rewrite');
DELETE FROM ct_test WHERE id = 0;

SELECT BYTES FROM TABLE(INFORMATION_SCHEMA.TABLE_STORAGE_METRICS())
    WHERE TABLE_NAME = 'CT_TEST';
-- BYTES will be slightly LARGER now -- that's the hidden columns
```

## 2.11 Step-by-Step: What Happens When You Query a Stream

**Setup:** Table: employees (has 3 rows at version v3). Stream: employees_stream (offset = v3).

**Step 1:** `INSERT INTO employees VALUES (4, 'Diana', 'Sales', 70000);`
- Table version becomes v4
- Hidden columns record: row abc004, version v4, not deleted

**Step 2:** `UPDATE employees SET salary = 85000 WHERE emp_id = 2;`
- Table version becomes v5
- Hidden columns record: row abc002, version v5, new values
- Old micro-partition (salary=65000) enters Time Travel

**Step 3:** `DELETE FROM employees WHERE emp_id = 3;`
- Table version becomes v6
- Row enters Time Travel (marked as deleted at v6)

**Step 4:** `SELECT * FROM employees_stream;`
- Snowflake reads: stream offset = v3
- Scans hidden columns for all rows where version > v3
- Retrieves historical (Time Travel) data for deleted/updated rows
- Computes net delta:

| emp_id | name | salary | ACTION | ISUPDATE | ROW_ID |
|--------|------|--------|--------|----------|--------|
| 4 | Diana | 70000 | INSERT | FALSE | abc004 | (new row)
| 2 | Bob | 65000 | DELETE | TRUE | abc002 | (old values)
| 2 | Bob | 85000 | INSERT | TRUE | abc002 | (new values)
| 3 | Charlie | 90000 | DELETE | FALSE | abc003 | (deleted)

- NO data was read from a "stream table" -- all came from the source table and its Time Travel history

**Step 5:** Stream offset is STILL at v3 (SELECT doesn't advance it)

## 2.12 Where Does the "Old Value" Come From in Updates?

When you UPDATE a row, Snowflake:
1. Marks the OLD micro-partition as inactive (enters Time Travel)
2. Writes a NEW micro-partition with the updated values

The stream can show BOTH old and new values because:
- Old values -> read from Time Travel (historical micro-partitions)
- New values -> read from the current active micro-partitions

This is why Time Travel / data retention is critical for streams: If the historical micro-partitions expire (leave Time Travel), the stream can no longer reconstruct the delta -> STALE.

```
Before UPDATE (salary 65000 -> 85000):
+--------------------------------------+
| Active Micro-Partition MP-7          |
| emp_id=2, salary=65000, version=v1   |
+--------------------------------------+

After UPDATE:
+--------------------------------------+    +--------------------------+
| Time Travel Micro-Partition MP-7     |    | Active MP-12             |
| emp_id=2, salary=65000, version=v1   |    | emp_id=2, salary=85000   |
| (retained for data_retention_days)   |    | version=v5               |
+--------------------------------------+    +--------------------------+
       ^                                           ^
  Stream reads this as                    Stream reads this as
  DELETE (old values)                     INSERT (new values)
```

---

# Part 3: Types of Streams

## 3.1 Three Stream Types

| Type | What it tracks | Supported on |
|------|---------------|-------------|
| **STANDARD** (default) | ALL DML: INSERT, UPDATE, DELETE, TRUNCATE. Returns NET delta (joined insert/delete). Cannot track geospatial data changes. | Tables, views, dynamic tables, Iceberg tables, directory tables |
| **APPEND_ONLY** | Only INSERTs. Ignores updates, deletes, truncates. More performant for ELT workloads. Source can be truncated after consumption without overhead on next stream query. | Tables, views, dynamic tables, Iceberg tables |
| **INSERT_ONLY** | Only INSERTs (ignores file removals). Designed for data lake / file-based sources. Overwritten files treated as new inserts. | External tables, externally managed Iceberg |

**When to Use Which:**

- **STANDARD**: You need full CDC (inserts, updates, deletes). MERGE into a target table. SCD Type 1 or Type 2 patterns. Any scenario where rows can be updated or deleted.
- **APPEND_ONLY**: Event logs, click streams, IoT sensor data. Data that is INSERT-only by nature (never updated/deleted). ELT pipelines where you only care about new rows. Better performance than STANDARD for insert-heavy tables.
- **INSERT_ONLY**: External tables (files in S3/GCS/Azure). Data lake patterns. File-based ingestion where files may be overwritten.

---

# Part 4: Streams on Views -- Deep Dive

## 4.1 Requirements for Streams on Views

Streams on views support local views AND shared views (Secure Data Sharing). NOT supported on materialized views.

**View query can only use:**
- Projections (SELECT columns)
- Filters (WHERE clauses)
- Inner joins / Cross joins
- UNION ALL
- System-defined scalar functions
- Nested views / subqueries in FROM (if expanded query is valid)

**NOT supported:**
- GROUP BY
- QUALIFY
- DISTINCT
- LIMIT
- Subqueries NOT in FROM clause
- Correlated subqueries

**Underlying table requirements:** All underlying tables must be native Snowflake tables. CHANGE_TRACKING must be enabled on ALL underlying tables.

## 4.2 Join Behavior in View Streams

When a stream tracks a view with a JOIN, the stream output is:

```
delta_left x right  +  left x delta_right  +  delta_left x delta_right
```

Where:
- delta_left = changes to the left table since the stream offset
- delta_right = changes to the right table since the stream offset
- left = full contents of the left table at the stream offset
- right = full contents of the right table at the stream offset

This means inserting into EITHER table can produce stream records. The stream joins changes against the existing data automatically.

**Important for tasks:** When a task is triggered by a stream on a view, ANY changes to tables referenced by the view will trigger the task, regardless of joins, filters, or aggregations in the view query.

---

# Part 5: Stream Staleness and Data Retention

## 5.1 What Is Staleness?

A stream becomes STALE when its offset falls OUTSIDE the table's data retention period. Once stale, the stream is UNUSABLE. You must DROP and RECREATE it.

```
[------- data retention -------]
                                 ^ current table version
      ^ stream offset (OUTSIDE retention = STALE!)
```

**Why does this happen?** Snowflake uses Time Travel to reconstruct change history. If the stream offset is older than the retention period, the historical data needed to compute the delta no longer exists.

**Protection Mechanism:** If `DATA_RETENTION_TIME_IN_DAYS < 14` days, Snowflake auto-extends retention to the stream's offset, up to `MAX_DATA_EXTENSION_TIME_IN_DAYS` (default 14 days).

| DATA_RETENTION_TIME_IN_DAYS | MAX_DATA_EXTENSION_TIME_IN_DAYS | Consume within |
|----|----|----|
| 14 | 0 | 14 days |
| 1 | 14 | 14 days |
| 0 | 90 | 90 days |

**Checking Staleness:**

```sql
SHOW STREAMS LIKE 'employees_stream';
-- Look at: STALE_AFTER column -> when the stream will become stale
-- Look at: STALE column -> TRUE if already stale

DESCRIBE STREAM employees_stream;
```

**Best Practices:**
1. Consume stream data REGULARLY (within retention period)
2. Set up alerts on STALE_AFTER timestamp
3. Use `SYSTEM$STREAM_HAS_DATA()` in task WHEN clauses
4. Increase `MAX_DATA_EXTENSION_TIME_IN_DAYS` if needed
5. NEVER use `CREATE OR REPLACE TABLE` on a streamed table (stales it)

## 5.2 What Stales a Stream?

**These actions make a stream STALE:**
- `CREATE OR REPLACE TABLE` on the source (drops history)
- `DROP TABLE` + recreate with same name (new table, not same)
- Dropping underlying tables of a view
- Offset falling outside retention period
- Cloning a database/schema (clone's stream has no history)

**These actions do NOT stale a stream:**
- `RENAME TABLE` (stream follows the renamed table)
- `ALTER TABLE ADD COLUMN`
- `TRUNCATE TABLE` (captured as mass DELETE in standard streams)
- Normal DML operations

---

# Part 6: Required Access Privileges

To CREATE a stream:
- CREATE STREAM on the schema
- SELECT on the source table/view

To QUERY a stream:

| Object | Privilege | Notes |
|--------|-----------|-------|
| Database | USAGE | |
| Schema | USAGE | |
| Stream | SELECT | |
| Source Table | SELECT | Streams on tables |
| Source View | SELECT | Streams on views |
| External Stage | USAGE | Streams on directory tables |
| Internal Stage | READ | Streams on directory tables |

```sql
GRANT SELECT ON STREAM employees_stream TO ROLE analyst_role;
GRANT SELECT ON TABLE employees TO ROLE analyst_role;
```

---

# Part 7: Stream Management Commands (SQL Reference)

## 7.1 CREATE STREAM

```sql
CREATE STREAM my_stream ON TABLE my_table;

CREATE STREAM my_stream ON TABLE my_table APPEND_ONLY = TRUE;

CREATE STREAM my_stream ON TABLE my_table SHOW_INITIAL_ROWS = TRUE;

CREATE STREAM my_stream ON VIEW my_view;

CREATE STREAM my_stream ON EXTERNAL TABLE my_ext_table INSERT_ONLY = TRUE;

CREATE STREAM my_stream ON TABLE my_table
    AT (TIMESTAMP => '2026-04-28 10:00:00'::TIMESTAMP_LTZ);

CREATE STREAM my_stream ON TABLE my_table
    BEFORE (STATEMENT => '<query_id>');

CREATE OR REPLACE STREAM my_stream ON TABLE my_table;
```

## 7.2 SHOW, DESCRIBE, CHECK, DROP

```sql
SHOW STREAMS;
SHOW STREAMS LIKE 'employees%';
SHOW STREAMS IN SCHEMA my_db.my_schema;

DESCRIBE STREAM my_stream;

SELECT SYSTEM$STREAM_HAS_DATA('my_stream');

DROP STREAM my_stream;
DROP STREAM IF EXISTS my_stream;
```

---

# Part 8: SQL Examples -- From Basic to Advanced

## 8.1 Basic Stream Creation and Usage

```sql
CREATE OR REPLACE TABLE employees (
    emp_id INT,
    name STRING,
    department STRING,
    salary DECIMAL(10,2)
);

INSERT INTO employees VALUES
    (1, 'Alice', 'Engineering', 80000),
    (2, 'Bob', 'Marketing', 65000),
    (3, 'Charlie', 'Engineering', 90000);

CREATE OR REPLACE STREAM employees_stream ON TABLE employees;

SELECT * FROM employees_stream;
-- Returns: EMPTY (no changes since stream was created)
```

## 8.2 Capturing INSERT, UPDATE, DELETE

```sql
INSERT INTO employees VALUES (4, 'Diana', 'Sales', 70000);
UPDATE employees SET salary = 85000 WHERE emp_id = 2;
DELETE FROM employees WHERE emp_id = 3;

SELECT * FROM employees_stream;
-- Returns:
-- emp_id=4 -> INSERT, ISUPDATE=FALSE              (new row)
-- emp_id=2 -> DELETE (old salary 65000), ISUPDATE=TRUE  (update - old)
-- emp_id=2 -> INSERT (new salary 85000), ISUPDATE=TRUE  (update - new)
-- emp_id=3 -> DELETE, ISUPDATE=FALSE              (deleted row)
```

## 8.3 Stream Does Not Advance on SELECT

```sql
SELECT * FROM employees_stream;
SELECT * FROM employees_stream;
SELECT * FROM employees_stream;
-- All three queries return the SAME data.
-- The offset has NOT moved because no DML consumed it.
```

## 8.4 Consuming a Stream (Offset Advances)

```sql
CREATE OR REPLACE TABLE employees_target (
    emp_id INT,
    name STRING,
    department STRING,
    salary DECIMAL(10,2),
    last_updated TIMESTAMP
);

INSERT INTO employees_target
    SELECT emp_id, name, department, salary, CURRENT_TIMESTAMP()
    FROM employees_stream
    WHERE METADATA$ACTION = 'INSERT' AND METADATA$ISUPDATE = FALSE;

-- NOW the stream is consumed -> offset advances
SELECT * FROM employees_stream;
-- Returns: EMPTY
```

## 8.5 Append-Only Stream

```sql
CREATE OR REPLACE TABLE event_log (
    event_id INT,
    event_type STRING,
    event_time TIMESTAMP
);

CREATE OR REPLACE STREAM event_log_stream
    ON TABLE event_log
    APPEND_ONLY = TRUE;

INSERT INTO event_log VALUES (1, 'LOGIN', CURRENT_TIMESTAMP());
INSERT INTO event_log VALUES (2, 'PURCHASE', CURRENT_TIMESTAMP());
DELETE FROM event_log WHERE event_id = 1;

SELECT * FROM event_log_stream;
-- Returns ONLY the two INSERTs.
-- The DELETE is IGNORED by append-only streams.
```

## 8.6 Insert-Only Stream (External / Iceberg Tables)

INSERT_ONLY streams are designed for EXTERNAL TABLES and externally-managed Iceberg tables. They ONLY track new file additions (row inserts).

**Key Behavior:**
- Tracks ONLY new rows inserted (from new files added to cloud storage)
- Does NOT record file removals or deletions
- Overwritten/appended files are treated as NEW files (old version removed -> not tracked; new version added -> tracked as INSERT)
- No net delta computation -- just raw inserts from new files

**Why not STANDARD/APPEND_ONLY?** External tables are backed by files in S3/GCS/Azure. Snowflake does NOT control or guarantee access to historical file versions. So only INSERT_ONLY is supported.

```sql
CREATE EXTERNAL TABLE ext_sales (
    sale_date DATE AS (VALUE:c1::DATE),
    product STRING AS (VALUE:c2::STRING),
    amount DECIMAL(10,2) AS (VALUE:c3::DECIMAL(10,2))
)
WITH LOCATION = @my_s3_stage/sales/
AUTO_REFRESH = TRUE
FILE_FORMAT = (TYPE = CSV);

CREATE STREAM ext_sales_stream
    ON EXTERNAL TABLE ext_sales
    INSERT_ONLY = TRUE;
```

**Comparison:**

| Stream Type | INSERTs | UPDATEs | DELETEs | Supported On |
|------------|---------|---------|---------|-------------|
| STANDARD | Yes | Yes | Yes | Tables, views, DT |
| APPEND_ONLY | Yes | No | No | Tables, views, DT |
| INSERT_ONLY | Yes | No | No | External tables, ext managed Iceberg |

## 8.7 Stream on a View

```sql
CREATE OR REPLACE TABLE orders (order_id INT, customer_id INT, amount DECIMAL(10,2));
CREATE OR REPLACE TABLE customers (customer_id INT, name STRING);

ALTER TABLE orders SET CHANGE_TRACKING = TRUE;
ALTER TABLE customers SET CHANGE_TRACKING = TRUE;

CREATE OR REPLACE VIEW orders_with_customer AS
    SELECT o.order_id, o.amount, c.name AS customer_name
    FROM orders o
    INNER JOIN customers c ON o.customer_id = c.customer_id;

CREATE OR REPLACE STREAM orders_view_stream ON VIEW orders_with_customer;

INSERT INTO customers VALUES (1, 'Alice');
INSERT INTO orders VALUES (101, 1, 250.00);

SELECT * FROM orders_view_stream;
-- Returns the joined result as an INSERT
```

## 8.8 SHOW_INITIAL_ROWS -- Capturing Existing Data

```sql
CREATE OR REPLACE TABLE products (
    product_id INT,
    name STRING,
    price DECIMAL(10,2)
);

INSERT INTO products VALUES (1, 'Laptop', 999.99), (2, 'Mouse', 29.99);

CREATE OR REPLACE STREAM products_initial_stream
    ON TABLE products
    SHOW_INITIAL_ROWS = TRUE;

SELECT * FROM products_initial_stream;
-- Returns ALL existing rows as INSERTs
-- Useful for initial load into a target table
```

## 8.9 Multiple Streams on the Same Table

```sql
CREATE OR REPLACE STREAM stream_for_analytics ON TABLE employees;
CREATE OR REPLACE STREAM stream_for_audit ON TABLE employees;
CREATE OR REPLACE STREAM stream_for_replication ON TABLE employees;

-- Each stream has its OWN offset
-- Consuming one does NOT affect the others
-- This is the recommended pattern for multiple consumers
```

## 8.10 Stream + MERGE (The CDC Workhorse)

```sql
CREATE OR REPLACE TABLE sales_raw (
    sale_id INT,
    product STRING,
    amount DECIMAL(10,2),
    region STRING
);

CREATE OR REPLACE TABLE sales_final (
    sale_id INT,
    product STRING,
    amount DECIMAL(10,2),
    region STRING,
    last_updated TIMESTAMP
);

CREATE OR REPLACE STREAM sales_cdc ON TABLE sales_raw;

INSERT INTO sales_raw VALUES (1, 'Widget', 100.00, 'East');
INSERT INTO sales_raw VALUES (2, 'Gadget', 200.00, 'West');

MERGE INTO sales_final AS t
USING (
    SELECT sale_id, product, amount, region,
           METADATA$ACTION, METADATA$ISUPDATE
    FROM sales_cdc
) AS s
ON t.sale_id = s.sale_id
WHEN MATCHED AND s.METADATA$ACTION = 'DELETE' AND s.METADATA$ISUPDATE = FALSE
    THEN DELETE
WHEN MATCHED AND s.METADATA$ISUPDATE = TRUE
    THEN UPDATE SET
        t.product = s.product,
        t.amount = s.amount,
        t.region = s.region,
        t.last_updated = CURRENT_TIMESTAMP()
WHEN NOT MATCHED AND s.METADATA$ACTION = 'INSERT'
    THEN INSERT (sale_id, product, amount, region, last_updated)
    VALUES (s.sale_id, s.product, s.amount, s.region, CURRENT_TIMESTAMP());
```

## 8.11 CHANGES Clause (Read-Only Alternative)

```sql
ALTER TABLE employees SET CHANGE_TRACKING = TRUE;

SELECT *
FROM employees
    CHANGES (INFORMATION => DEFAULT)
    AT (TIMESTAMP => DATEADD('hour', -1, CURRENT_TIMESTAMP()));
```

The CHANGES clause:
- Does NOT require creating a stream object
- Does NOT advance any offset (read-only)
- Requires AT | BEFORE clause for a start point
- Requires `CHANGE_TRACKING = TRUE` on the table
- Useful for ad-hoc change inspection

## 8.12 Advancing Offset Without Processing Data

```sql
-- Method 1: Recreate the stream
CREATE OR REPLACE STREAM employees_stream ON TABLE employees;

-- Method 2: Consume with a no-op DML
INSERT INTO employees_target
    SELECT emp_id, name, department, salary, CURRENT_TIMESTAMP()
    FROM employees_stream
    WHERE 1 = 0;
-- This advances the offset but inserts ZERO rows
```

## 8.13 Stream with Explicit Transaction

```sql
BEGIN;
    INSERT INTO sales_final
        SELECT sale_id, product, amount, region, CURRENT_TIMESTAMP()
        FROM sales_cdc
        WHERE METADATA$ACTION = 'INSERT';

    INSERT INTO sales_audit_log
        SELECT sale_id, METADATA$ACTION, METADATA$ISUPDATE, CURRENT_TIMESTAMP()
        FROM sales_cdc;
COMMIT;
-- Both statements see the SAME stream data (repeatable read)
-- Offset advances only when COMMIT succeeds
```

---

# Part 9: Billing and Cost Model

## 9.1 Cost Overview

1. **Storage cost (minimal):** Hidden change tracking columns on the source table. Small overhead, proportional to DML volume. If the stream is not consumed regularly, Snowflake extends the data retention period -> additional Time Travel storage.
2. **Compute cost:** Querying a stream uses warehouse compute time. Charged as normal Snowflake credits. The stream itself has NO per-object charge.
3. **No cost for creating streams:** Streams are just offset pointers. You can create unlimited streams on the same table. No significant storage cost per stream object.

## 9.2 Stream Object Itself -- Free

Creating a stream costs NOTHING. A stream is just a metadata pointer (offset + source reference). You can create 100 streams on the same table with negligible cost.

There is NO: per-stream monthly fee, per-stream storage charge, per-stream compute charge, or limit on the number of streams per table.

## 9.3 Hidden Change Tracking Columns -- Small Storage

Storage impact: typically a FEW PERCENT increase in table size. Proportional to number of rows and DML volume. Compressed along with your data.

Example: Table size before stream: 100 GB. Table size after stream: ~102-105 GB (2-5% increase).

This is a ONE-TIME overhead. Creating 10 more streams on the same table does NOT add more hidden columns.

```sql
SELECT
    TABLE_NAME,
    ACTIVE_BYTES / (1024*1024*1024) AS active_gb,
    TIME_TRAVEL_BYTES / (1024*1024*1024) AS time_travel_gb,
    FAILSAFE_BYTES / (1024*1024*1024) AS failsafe_gb
FROM TABLE(INFORMATION_SCHEMA.TABLE_STORAGE_METRICS())
WHERE TABLE_CATALOG = CURRENT_DATABASE()
ORDER BY ACTIVE_BYTES DESC;
```

## 9.4 Extended Data Retention -- Potentially Significant

**This is the BIGGEST HIDDEN COST of streams.**

Scenario:
- Table has `DATA_RETENTION_TIME_IN_DAYS = 1` (1 day Time Travel)
- Stream was created 10 days ago and NOT consumed
- Snowflake EXTENDS retention behind the scenes to keep the stream valid
- Those 10 days of historical micro-partitions are kept in storage
- You pay for ALL that extra Time Travel storage

**Cost Example:**

If your table has 100 GB and 20% churn per day:
- Normal (1-day retention): ~20 GB Time Travel storage
- With 10-day stream lag: ~200 GB Time Travel storage (10x MORE)

**Prevention:**
1. Consume streams FREQUENTLY (ideally every few minutes via tasks)
2. After consumption, retention reverts to the table's default
3. Monitor STALE_AFTER in SHOW STREAMS
4. Set up alerts for streams not consumed within 24 hours

## 9.5 Compute (Warehouse Credits) -- Normal Query Cost

Querying or consuming a stream uses warehouse compute time. This is the SAME cost as any other SELECT or DML query. No special "stream processing" charge.

**Optimization:**
- Use serverless tasks (no idle warehouse costs)
- Right-size the warehouse for your MERGE workload
- Use APPEND_ONLY streams when possible (cheaper to compute -- no delete/insert join needed for net delta calculation)
- Use `SYSTEM$STREAM_HAS_DATA()` to skip empty runs

## 9.6 Billing Summary Table

| Cost Component | Amount | Notes |
|---------------|--------|-------|
| Stream object creation | FREE | Just a metadata pointer |
| Additional streams on same table | FREE | Hidden columns added only once |
| Hidden change tracking columns | ~2-5% of table size | One-time overhead per table |
| Extended data retention (unconsumed stream) | VARIABLE (can be very large) | BIGGEST hidden cost. Consume regularly. |
| Compute (query/consume) | Standard credits | Same as any warehouse query |
| Time Travel storage (for updates/deletes) | Standard TT rates | Not stream-specific but streams depend on it |

## 9.7 Real-World Cost Example

**Scenario:** E-commerce orders table
- Table size: 500 GB (compressed)
- Daily inserts: 50 million rows (~10 GB/day)
- Daily updates: 5 million rows (~1 GB/day)
- `DATA_RETENTION_TIME_IN_DAYS = 1`
- Stream consumed every 5 minutes via serverless task

**Cost Breakdown:**

1. Hidden columns: ~10-25 GB additional (2-5% of 500 GB). Monthly storage cost: ~$0.50 - $1.25 (at $23/TB/month on-demand)
2. Extended retention: MINIMAL (stream consumed every 5 min). Only ~5 min of extra history retained = negligible
3. Compute: ~288 task runs/day (every 5 min). Each run processes ~5 min of changes (~35K rows). Serverless cost: ~0.05 credits/day ~ $0.15/day ~ $4.50/month
4. Time Travel: Standard 1-day retention on ~11 GB daily churn. ~11 GB Time Travel storage = ~$0.25/month

**Total estimated monthly cost: ~$6-7/month** (very cost effective for real-time CDC on a 500 GB table)

**Bad Scenario:** Stream NOT consumed for 14 days. Extended retention: 14 days x 11 GB/day = 154 GB extra TT storage. Monthly storage cost: ~$3.50/month EXTRA just for retention. Plus risk of stream going STALE.

## 9.8 How to Monitor Stream Costs

```sql
-- 1. Check table storage (includes hidden column overhead):
SELECT TABLE_NAME, ACTIVE_BYTES, TIME_TRAVEL_BYTES, RETAINED_FOR_CLONE_BYTES
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE TABLE_NAME = 'YOUR_TABLE_NAME'
ORDER BY ACTIVE_BYTES DESC;

-- 2. Check if streams are being consumed (extended retention indicator):
SHOW STREAMS IN SCHEMA my_db.my_schema;
-- Compare STALE_AFTER with current time

-- 3. Check task compute costs:
SELECT TASK_NAME, SUM(CREDITS_USED) AS total_credits, COUNT(*) AS run_count
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE START_TIME > DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY TASK_NAME
ORDER BY total_credits DESC;

-- 4. Check warehouse costs for stream consumption:
SELECT WAREHOUSE_NAME, SUM(CREDITS_USED) AS total_credits
FROM SNOWFLAKE.ACCOUNT_USAGE.WAREHOUSE_METERING_HISTORY
WHERE START_TIME > DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY WAREHOUSE_NAME
ORDER BY total_credits DESC;
```

## 9.9 Cost Optimization Best Practices

1. **Consume frequently**: Use triggered tasks (`WHEN SYSTEM$STREAM_HAS_DATA`) to consume within minutes. Prevents extended retention costs.
2. **Use serverless tasks**: No idle warehouse.
3. **Use APPEND_ONLY**: When you don't need full CDC. Cheaper to compute.
4. **Drop unused streams**: Avoid extended retention for unconsumed offsets. If ALL streams are dropped: `ALTER TABLE t SET CHANGE_TRACKING = FALSE;`
5. **Right-size warehouse**: XS or S is usually sufficient for incremental CDC.
6. **Monitor STALE_AFTER**: Set up alerts for approaching staleness.

---

# Part 10: Tricky Scenarios and Gotchas

**Scenario 1:** "Stream always shows 0 rows even though data was inserted."
**Cause:** Someone consumed the stream in a DML (even `INSERT...WHERE 1=0`).
**Fix:** Create separate streams per consumer. Check for rogue DML.

**Scenario 2:** "Stream became stale overnight."
**Cause:** Data retention period expired for the stream's offset.
**Fix:** Increase `MAX_DATA_EXTENSION_TIME_IN_DAYS`. Consume regularly. Recovery: Recreate stream. Use CHANGES clause with Time Travel to manually process missed changes (if within retention).

**Scenario 3:** "Added NOT NULL column and stream queries started failing."
**Cause:** Stream reads historical data that has NULLs for the new column.
**Fix:** Add columns as NULLABLE first. Apply NOT NULL after consuming stream.

**Scenario 4:** "CREATE OR REPLACE TABLE broke my stream."
**Cause:** CREATE OR REPLACE drops the table's history. Stream goes stale.
**Fix:** NEVER use CREATE OR REPLACE on tables with active streams. Use ALTER TABLE instead.

**Scenario 5:** "Two tasks consuming the same stream -- second task gets no data."
**Cause:** First task's DML consumed the stream -> offset advanced.
**Fix:** Create one stream per task. Streams are cheap (just an offset).

**Scenario 6:** "Stream on a view doesn't capture changes I expected."
**Cause:** View has GROUP BY, DISTINCT, or LIMIT (unsupported for streams).
**Fix:** Simplify the view to only use projections, filters, inner joins, and UNION ALL.

**Scenario 7:** "Cloned my production database for testing. Stream is empty."
**Cause:** Cloned streams lose unconsumed records. Clone's stream offset starts at the clone creation time.
**Fix:** This is by design. In the cloned environment, the stream will capture new changes made after the clone.

---

# Part 11: Interview Questions -- Level 1: Beginner

**Q1: What is a Snowflake stream?**
A stream is a Snowflake object that records DML changes (INSERT, UPDATE, DELETE) on a source object. It acts as a "bookmark" tracking what changed since the last time changes were consumed. It stores only an OFFSET, not actual data.

**Q2: What are the three metadata columns in a stream?**
1. `METADATA$ACTION` -> 'INSERT' or 'DELETE'
2. `METADATA$ISUPDATE` -> TRUE if the row is part of an UPDATE
3. `METADATA$ROW_ID` -> Unique, immutable row identifier

**Q3: How are UPDATEs represented in a stream?**
As TWO rows: Row 1 = DELETE with ISUPDATE=TRUE (old values). Row 2 = INSERT with ISUPDATE=TRUE (new values). Both share the same METADATA$ROW_ID.

**Q4: Does querying a stream advance its offset?**
NO. Only consuming the stream in a DML transaction advances the offset.

**Q5: What objects can you create a stream on?**
Standard tables, views, directory tables, dynamic tables, Iceberg tables, event tables, and external tables.

**Q6: How do you check if a stream has new data?**
`SELECT SYSTEM$STREAM_HAS_DATA('stream_name');` Returns TRUE if there are unconsumed changes.

**Q7: What is the difference between a stream and a table?**
A table stores actual data rows. A stream stores only an offset pointer. It reconstructs CDC records on-the-fly from the table's change tracking metadata.

**Q8: Can you create multiple streams on the same table?**
Yes. Each stream has its own independent offset. Consuming one does NOT affect others.

---

# Part 12: Interview Questions -- Level 2: Intermediate

**Q9: What are the three types of streams?**
STANDARD (default): all DML, net delta. APPEND_ONLY: only INSERTs, more performant. INSERT_ONLY: inserts on external/Iceberg tables, ignores file removals.

**Q10: What is "net delta" in a standard stream?**
The minimal set of changes needed to bring a target up to date. Row inserted then deleted -> not returned. Row inserted then updated -> single INSERT with latest values. Row updated 5 times -> one DELETE (old) + one INSERT (final values).

**Q11: When does a stream become stale?**
When its offset falls outside the data retention period. Prevent by consuming regularly, checking STALE_AFTER, increasing MAX_DATA_EXTENSION_TIME_IN_DAYS, and never using CREATE OR REPLACE TABLE on streamed tables.

**Q12: What is the CHANGES clause?**
A SELECT clause that reads change tracking metadata without creating a stream. Read-only, no offset advancement, requires AT|BEFORE clause and CHANGE_TRACKING=TRUE.

**Q13: What operations advance a stream offset?**
Only DML transactions that consume the stream: INSERT INTO...SELECT FROM stream, MERGE USING stream, CTAS FROM stream, COPY INTO FROM stream. Advances ONLY on successful COMMIT.

**Q14: Can you create a stream on a view?**
Yes. View must use only projections, filters, inner/cross joins, UNION ALL, scalar functions. All underlying tables need CHANGE_TRACKING=TRUE.

**Q15: What happens when you TRUNCATE a table with a stream?**
STANDARD streams: captured as mass DELETE. APPEND_ONLY streams: truncate is ignored. Stream remains valid.

**Q16: What is SHOW_INITIAL_ROWS?**
Makes all existing rows appear as INSERTs when the stream is first queried. Useful for initial loads.

**Q17: How do you advance offset without processing data?**
1. Recreate: `CREATE OR REPLACE STREAM s ON TABLE t;`
2. No-op DML: `INSERT INTO temp SELECT * FROM s WHERE 1=0;`

**Q18: What is METADATA$ROW_ID?**
Unique, immutable row identifier. Same ROW_ID across all streams on the same source, across clones and replicas. NOT guaranteed to match between table stream and view stream. May change if CHANGE_TRACKING disabled/re-enabled.

---

# Part 13: Interview Questions -- Level 3: Advanced

**Q19: Explain repeatable read isolation in streams.**
Within a transaction, all queries to the same stream see identical data -- even if the source table changes mid-transaction. If the transaction fails, the offset does NOT advance.

**Q20: How do you handle multiple consumers?**
Create a SEPARATE stream for each consumer. If two consumers share one stream, the first DML advances the offset and the second loses data.

**Q21: What happens when you DROP and recreate the source table?**
Stream becomes STALE immediately. Even same name/schema = new table. RENAME table -> stream stays valid. DROP table -> stream is orphaned.

**Q22: How do streams on joined views work internally?**
Output = delta_left x right + left x delta_right + delta_left x delta_right. Inserting into EITHER table produces stream records. For tasks: ANY change to ANY referenced table triggers the task.

**Q23: What are the limitations of streams?**
- Standard streams cannot track geospatial data changes
- No streams on views with GROUP BY, QUALIFY, DISTINCT, LIMIT
- Adding NOT NULL columns can break stream queries
- CREATE OR REPLACE TABLE stales the stream
- Cloned databases: stream clones lose unconsumed records
- View streams: all underlying tables must be native + change tracking

**Q24: Explain the billing model for streams.**
Streams themselves are free. Costs: hidden columns (~2-5% storage), extended retention (biggest hidden cost if not consumed), compute (normal warehouse credits). Optimize by consuming regularly, using APPEND_ONLY, and serverless tasks.

**Q25: How do streams interact with Time Travel?**
Streams use the same versioning history. Offset points to a specific version. If offset ages out of Time Travel -> stale. Can create stream AT a Time Travel point. Streams on shared tables do NOT extend retention.

**Q26: What happens to streams during database/schema cloning?**
Unconsumed records in the cloned stream are INACCESSIBLE. Clone's stream starts fresh from the clone point.

---

# Part 14: Interview Questions -- Level 4: Architect

**Q27: Design a production CDC pipeline using streams.**

```
SOURCE -> Snowpipe/Streaming -> raw_staging_table
  -> Stream on raw_staging_table
    -> Triggered task (WHEN SYSTEM$STREAM_HAS_DATA)
      -> MERGE INTO curated_table
        -> Stream on curated_table
          -> Triggered task -> MERGE INTO reporting_table
```

Key: One stream per consumer, triggered tasks, explicit transactions, MAX_DATA_EXTENSION=90, SHOW_INITIAL_ROWS for initial load, TASK_HISTORY + STALE_AFTER monitoring.

**Q28: Bronze -> Silver -> Gold CDC architecture?**
- **Bronze**: Snowpipe Streaming -> raw_events. Stream: raw_events_stream (STANDARD)
- **Silver**: Triggered Task -> MERGE with type casting, null handling, dedup, PII masking. Stream: cleansed_events_stream
- **Gold**: Dynamic Table with TARGET_LAG OR Task for aggregations

Each layer has its own stream. Failure in Silver does not affect Bronze.

**Q29: Streams + Tasks vs Dynamic Tables?**
- Streams + Tasks: Full control, handles deletes, complex logic. Must manage scheduling/monitoring. Best for Bronze->Silver.
- Dynamic Tables: Declarative, simpler, TARGET_LAG controls freshness. No DELETE handling. Best for Silver->Gold.

**Q30: How to handle out-of-order events?**
Streams process in table version order. Add event_timestamp and sequence_number. In MERGE: conditional update only if source.seq > target.seq. Partition by primary key in Kafka.

**Q31: Task fails mid-MERGE -- does stream advance?**
NO. Offset advances ONLY on successful COMMIT. Failed transaction = rollback = offset unchanged. Next run retries same changes. This is at-least-once processing.

**Q32: How to monitor streams in production?**
1. Staleness: SHOW STREAMS -> STALE_AFTER
2. Backlog: SYSTEM$STREAM_HAS_DATA persistent TRUE = bottleneck
3. Task health: TASK_HISTORY -> FAILED states
4. Task duration: SCHEDULED_TIME vs COMPLETED_TIME
5. Data freshness: last_updated in target vs current time
6. Alerts: CREATE ALERT for failures and staleness
7. Cost: SERVERLESS_TASK_HISTORY for compute usage

**Q33: Design a zero-data-loss exactly-once CDC pipeline.**
Source DB -> Debezium -> Kafka (RF=3, acks=all) -> Kafka Connector V4 -> Snowpipe Streaming -> landing_table -> Stream -> MERGE with sequence guard -> final_table. Second stream -> audit_log. TASK_AUTO_RETRY_ATTEMPTS=3, finalizer task, dead letter table. Alerts on failures and backlog. FAILOVER GROUP for DR.

**Q34: Migrate from timestamp-based CDC to streams?**
1. Run final timestamp extraction
2. Create stream (offset = current version)
3. Create triggered task with MERGE
4. Verify counts after a few runs
5. Decommission timestamp job

Benefits: captures deletes, no full scans, no dependency on updated_at column.

**Q35: What happens to streams during replication and failover?**
Stream offsets are replicated. On failover: streams continue from last replicated offset. Some changes may be re-processed (at-least-once across failover). METADATA$ROW_ID preserved across replicas.

---

# Part 15: Quick Reference Cheat Sheet

**CREATE STREAM:**
```sql
CREATE STREAM s ON TABLE t;                              -- standard
CREATE STREAM s ON TABLE t APPEND_ONLY = TRUE;           -- append-only
CREATE STREAM s ON EXTERNAL TABLE e INSERT_ONLY = TRUE;  -- insert-only
CREATE STREAM s ON TABLE t SHOW_INITIAL_ROWS = TRUE;     -- initial load
CREATE STREAM s ON VIEW v;                               -- on a view
CREATE STREAM s ON TABLE t AT (TIMESTAMP => '...');      -- time travel
```

**CHECK DATA:**
```sql
SELECT SYSTEM$STREAM_HAS_DATA('s');
```

**INSPECT:**
```sql
SHOW STREAMS;
DESCRIBE STREAM s;
SELECT * FROM s;  -- preview without advancing
```

**CONSUME:**
```sql
INSERT INTO target SELECT * FROM s WHERE ...;  -- advances offset
MERGE INTO target USING s ON ...;              -- advances offset
```

**ADVANCE WITHOUT CONSUMING:**
```sql
CREATE OR REPLACE STREAM s ON TABLE t;
INSERT INTO temp SELECT * FROM s WHERE 1=0;
```

**STALENESS:**
```sql
SHOW STREAMS;  -- check STALE_AFTER column
ALTER TABLE t SET MAX_DATA_EXTENSION_TIME_IN_DAYS = 90;
```

**STREAM METADATA COLUMNS:**
- `METADATA$ACTION` -> 'INSERT' or 'DELETE'
- `METADATA$ISUPDATE` -> TRUE for updates
- `METADATA$ROW_ID` -> Unique row identifier

**MERGE PATTERN:**
- `WHEN MATCHED AND ACTION='DELETE' AND ISUPDATE=FALSE` -> DELETE
- `WHEN MATCHED AND ISUPDATE=TRUE` -> UPDATE SET ...
- `WHEN NOT MATCHED AND ACTION='INSERT'` -> INSERT ...

---

*End of Snowflake Streams Complete Guide*
