# Snowflake Cloning - Complete Guide With Examples

## 1. What Is Cloning in Snowflake?

Cloning (also called "Zero-Copy Cloning") creates a copy of a database, schema, or table **without physically copying the underlying data**.

### What does "without physically copying" mean?

Snowflake stores table data in small files called **micro-partitions**. When you clone, Snowflake does NOT duplicate those files. Instead it creates a new metadata pointer that references the SAME partitions.

**Before Clone:**
```
orders table  ->  [Part A] [Part B] [Part C]     (100 GB on disk)
```

**After Clone (instant, 0 extra storage):**
```
orders table       ->  [Part A] [Part B] [Part C]   <- shared!
orders_clone table ->  [Part A] [Part B] [Part C]   <- same files!
```

**After Modifying the Clone:**
```sql
UPDATE orders_clone SET status = 'NEW' WHERE id = 5;
```
```
orders table       ->  [Part A] [Part B]  [Part C]  <- unchanged
orders_clone table ->  [Part A] [Part B'] [Part C]  <- B' is NEW
```

Only Part B' (the changed partition) costs extra storage. Part A and Part C are still shared -- no duplication.

**Example:** A 500 GB table with 5000 micro-partitions
- Clone cost at creation = **0 GB** (just metadata pointers)
- Update 1% of clone data = **~5 GB** (only modified partitions are new)
- The other 495 GB remains shared with the original table

### Key Properties

- **Metadata-only operation:** The clone's metadata points to the same micro-partitions as the source. No additional storage cost at the time of cloning. Storage costs only begin when data in the clone is modified (INSERT, UPDATE, DELETE), because new micro-partitions are created for changes.
- **Recursive:** Cloning a DATABASE clones all schemas and all objects within them. Cloning a SCHEMA clones all objects within the schema.

---

## 2. Objects That Can Be Cloned

Databases, Schemas, Tables, Dynamic Tables, Event Tables, Streams, Tasks, Alerts, Stages (external; internal with `INCLUDE INTERNAL STAGES`), File Formats, Sequences, Database Roles

**Cannot be cloned:**
- External tables
- Pipes referencing internal stages
- Hybrid tables at schema or table level (only at database level)

---

## 3. Basic Cloning Syntax

### 3a. Clone a Database
```sql
CREATE DATABASE my_db_clone CLONE my_production_db;
```

### 3b. Clone a Schema
```sql
CREATE SCHEMA my_schema_clone CLONE my_production_db.my_schema;
```

### 3c. Clone a Table
```sql
CREATE TABLE orders_clone CLONE orders;
```

### 3d. Clone with OR REPLACE (drops existing object first)
```sql
CREATE OR REPLACE TABLE orders_clone CLONE orders;
```

### 3e. Clone with IF NOT EXISTS
```sql
CREATE TABLE IF NOT EXISTS orders_clone CLONE orders;
```

---

## 4. Cloning With Time Travel

You can clone objects as they existed at a specific point in the past, as long as the data is still within the Time Travel retention period.

### 4a. Clone using a Timestamp
```sql
CREATE TABLE orders_backup CLONE orders
  AT (TIMESTAMP => '2026-04-25 10:00:00'::TIMESTAMP_TZ);
```

### 4b. Clone using an Offset (seconds in the past)
Example: clone from 1 hour ago (-3600 seconds)
```sql
CREATE TABLE orders_1hr_ago CLONE orders
  AT (OFFSET => -3600);
```

### 4c. Clone using a Statement (query ID)
```sql
CREATE TABLE orders_before_delete CLONE orders
  BEFORE (STATEMENT => '8e5d0ca9-005e-44e6-b858-a8f5b37c5726');
```

### 4d. Clone a Database at a point in the past
```sql
CREATE DATABASE my_db_restored CLONE my_production_db
  AT (TIMESTAMP => DATEADD(days, -2, CURRENT_TIMESTAMP)::TIMESTAMP_TZ);
```

### 4e. Skip tables with insufficient data retention during Time Travel clone
```sql
CREATE DATABASE my_db_restored CLONE my_production_db
  AT (TIMESTAMP => DATEADD(days, -4, CURRENT_TIMESTAMP)::TIMESTAMP_TZ)
  IGNORE TABLES WITH INSUFFICIENT DATA RETENTION;
```

---

## 5. Practical Use Cases

### Use Case 1: Create Dev/QA environments from Production (zero cost initially)
```sql
CREATE DATABASE DEV_DB CLONE PROD_DB;
CREATE DATABASE QA_DB  CLONE PROD_DB;
```

### Use Case 2: Create a snapshot before a risky operation
```sql
CREATE TABLE customers_backup CLONE customers;

-- Run your risky operation...
UPDATE customers SET status = 'INACTIVE' WHERE last_login < '2025-01-01';

-- If something goes wrong, restore from the clone:
CREATE OR REPLACE TABLE customers CLONE customers_backup;
```

### Use Case 3: Testing schema changes safely
```sql
CREATE SCHEMA test_schema CLONE production_schema;
-- Make changes in test_schema without affecting production
```

### Use Case 4: Point-in-time recovery using Time Travel + Clone
```sql
CREATE TABLE recovered_orders CLONE orders
  AT (TIMESTAMP => '2026-04-26 08:00:00'::TIMESTAMP_TZ);
```

---

## 6. Cloning and Access Control (Privileges)

When cloning a **Database or Schema:**
- Child objects (tables, views, etc.) **retain** their granted privileges.
- The database/schema-level grants are **not** inherited from the source.
- **Ownership** of the clone goes to the role that runs the `CREATE ... CLONE`.

When cloning a **Table individually:**
- No privileges are copied by default.
- Use `COPY GRANTS` to retain privileges from the source table.

```sql
CREATE TABLE orders_clone CLONE orders COPY GRANTS;
```

---

## 7. Cloning and Storage Costs

| Timing | Storage Impact |
|---|---|
| At creation time | Zero additional storage |
| After modifications | Only the changed micro-partitions consume new storage |

**Example:**
- Source table = 100 GB (1000 micro-partitions)
- Clone table = 0 GB additional at creation
- After UPDATE on 10% of rows = ~10 GB new storage for the clone
- The source and clone share the remaining 90 GB of unchanged data

---

## 8. Key Considerations and Gotchas

### 8a. Views referencing fully qualified names still point to the source
After cloning a schema, inspect views to ensure they reference the correct (cloned) objects.

### 8b. Streams in a clone lose unconsumed records
Historical data for streams starts from when the clone was created.

### 8c. Tasks in a clone are suspended by default
You must resume them manually:
```sql
ALTER TASK my_cloned_task RESUME;
```

### 8d. Automatic Clustering is suspended on cloned tables
Resume it manually if needed:
```sql
ALTER TABLE my_cloned_table RESUME RECLUSTER;
```

### 8e. Sequences
If a table and its referenced sequence are in the **same** database/schema, cloning links them correctly. If in different schemas, the cloned table still references the **source** sequence. Fix manually:
```sql
ALTER TABLE cloned_db.cloned_schema.my_table
  ALTER COLUMN id SET DEFAULT cloned_db.cloned_schema.my_sequence.NEXTVAL;
```

### 8f. Pipes referencing internal stages are not cloned
Pipes with `AUTO_INGEST=TRUE` are set to `STOPPED_CLONED` state.

### 8g. DDL during cloning can cause conflicts
Avoid renaming or dropping source objects while cloning is in progress.

### 8h. DML during cloning with `DATA_RETENTION_TIME_IN_DAYS = 0` can fail
Set retention to 1 day before cloning large objects if DML is expected.

---

## 9. Cloning With Hybrid Tables

Hybrid tables can **only** be cloned at the **database level**. Schema-level and table-level cloning of hybrid tables is **not** supported.

```sql
CREATE DATABASE clone_db CLONE source_db;
```

To clone a schema that contains hybrid tables, skip them:
```sql
CREATE SCHEMA clone_schema CLONE source_schema IGNORE HYBRID TABLES;
```

---

## 10. Clone + Swap Pattern (Refreshing Dev/QA Environments)

```sql
-- Step 1: Create a fresh clone from production
CREATE DATABASE DEV_DB_NEW CLONE PROD_DB;

-- Step 2: Swap the old dev database with the new clone
ALTER DATABASE DEV_DB SWAP WITH DEV_DB_NEW;

-- Step 3: Drop the old database (now named DEV_DB_NEW after swap)
DROP DATABASE DEV_DB_NEW;

-- Result: DEV_DB is now a fresh copy of PROD_DB
```

---

## 11. Required Privileges

| Object Type | Required Privilege on Source |
|---|---|
| Database | USAGE |
| Schema | USAGE (or OWNERSHIP for managed access) |
| Table | SELECT |
| Stage | USAGE |
| Task/Stream | OWNERSHIP |
| Database Role | OWNERSHIP + CREATE DATABASE ROLE on target |

Additionally, you need **CREATE** privileges on the target container:
- `CREATE DATABASE` on ACCOUNT for database clones
- `CREATE SCHEMA` on DATABASE for schema clones
- `CREATE TABLE` on SCHEMA for table clones

---

## 12. Summary

- Cloning is a fast, metadata-only operation (zero-copy).
- No storage cost until data in the clone diverges from the source.
- Supports Time Travel for point-in-time cloning.
- Cloning is recursive for databases and schemas.
- Cloned tasks and alerts are suspended by default.
- Ideal for dev/test environments, backups, and safe experimentation.
