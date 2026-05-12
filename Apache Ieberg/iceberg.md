# SNOWFLAKE ICEBERG TABLES: COMPLETE GUIDE
## What, Why, When, Setup, Architecture, Pros/Cons, Interview Questions

---

## 1. WHAT ARE ICEBERG TABLES?

Apache Iceberg is an **OPEN TABLE FORMAT** that stores data as Parquet files in YOUR cloud storage (S3/Azure/GCS) with a metadata layer on top.

In Snowflake, Iceberg tables let you:
- Store data in YOUR storage (S3 bucket you own) instead of Snowflake's
- Use OPEN formats (Parquet) readable by Spark, Flink, Trino, Presto
- Query the data using Snowflake SQL with full performance

```
┌─────────────────────────────────────────────────────────────────┐
│  Regular Snowflake Table:                                       │
│    Data lives INSIDE Snowflake → Snowflake manages everything  │
│    You CANNOT access the data files directly                   │
│    Only Snowflake can read/write                               │
│                                                                 │
│  Iceberg Table:                                                 │
│    Data lives in YOUR S3/Azure/GCS bucket as Parquet files     │
│    Snowflake reads/writes through an external volume           │
│    Spark, Flink, Trino can ALSO read the same data             │
│    YOU own the storage, YOU control access                     │
└─────────────────────────────────────────────────────────────────┘
```

### Iceberg provides:
- **ACID transactions** (safe concurrent reads/writes)
- **Schema evolution** (add/rename/drop columns without rewriting data)
- **Hidden partitioning** (automatic, no user-managed partition columns)
- **Table snapshots** (time travel via Iceberg metadata)
- **Open format** (no vendor lock-in)

---

## 2. WHY DO WE NEED ICEBERG TABLES?

| Problem | Solution with Iceberg |
|---------|----------------------|
| **Vendor Lock-in:** Data inside Snowflake's proprietary storage. Must EXPORT to use Spark. | Stores data as open Parquet files. Any engine can read it. |
| **Multi-Engine Access:** DE uses Spark, analysts use Snowflake, ML uses Trino. Each needs a copy. | ONE copy of data, MULTIPLE engines read directly. |
| **Storage Cost Control:** Snowflake charges for storage + compute. Can't control pricing. | Data in YOUR S3 bucket. Pay S3 rates directly. |
| **Data Lake + Warehouse:** S3 data lake AND Snowflake = data duplication. | Query your data lake directly from Snowflake. No duplication. |
| **Regulatory / Data Residency:** Some regulations require data in storage you control. | Data stays in YOUR account, YOUR region, YOUR encryption. |

---

## 3. WHEN TO USE ICEBERG TABLES

### USE ICEBERG WHEN:
- Multiple engines need to access the same data (Spark + Snowflake)
- You want to avoid vendor lock-in
- You have an existing data lake in S3/Azure/GCS
- You need open file formats for compliance/portability
- You want to control storage costs independently
- Your ML team needs direct Parquet file access
- Cross-platform pipelines (Spark writes, Snowflake reads)

### DO NOT USE ICEBERG WHEN:
- You only use Snowflake (regular tables are simpler and faster)
- You need Fail-safe (Iceberg tables don't have Fail-safe)
- You need maximum query performance (regular tables have better pruning)
- You want Snowflake to manage everything (storage, maintenance, etc.)
- You need temporary or transient tables
- Small lookup/dimension tables (overhead not worth it)

---

## 4. TWO TYPES OF ICEBERG TABLES IN SNOWFLAKE

### TYPE 1: SNOWFLAKE-MANAGED (Snowflake is the catalog)
- Snowflake manages the Iceberg metadata
- Full read + write access
- Full Snowflake features (DML, clustering, streams, Time Travel)
- Snowflake handles compaction and maintenance
- Other engines can READ via Snowflake Horizon Catalog
- Config: `CATALOG = 'SNOWFLAKE'`

### TYPE 2: EXTERNALLY MANAGED (External catalog like AWS Glue, Polaris)
- External system manages the Iceberg metadata
- Snowflake has read access (+ write with REST catalog)
- Limited Snowflake features (no clustering, limited streams)
- YOU handle compaction and maintenance
- Config: Uses `CATALOG_INTEGRATION`

| Snowflake-Managed | Externally Managed |
|--------------------|--------------------|
| Snowflake is your primary engine | Spark/Flink is primary engine |
| Full DML (INSERT/UPDATE/DELETE) | Read-heavy from Snowflake |
| Need clustering + Time Travel | Catalog already exists (Glue) |
| Want Snowflake to handle maintenance | Want external tools to manage |

---

## 5. PROS AND CONS

### PROS:
- Open format: No vendor lock-in. Data in Parquet, readable by any engine
- Multi-engine: Spark, Flink, Trino, Snowflake all read the same files
- Cost control: You own storage. Pay cloud provider rates, not Snowflake
- ACID transactions: Safe concurrent reads and writes
- Schema evolution: Add/rename/drop columns without rewriting all data
- Hidden partitioning: Automatic partitioning without user-visible columns
- Time Travel: Via Iceberg snapshots (Snowflake-managed tables)
- No data duplication: One copy of data for all consumers

### CONS:
- No Fail-safe: If data is deleted from storage, it's GONE
- Slower queries: ~10-20% slower than native Snowflake tables (external I/O)
- Setup complexity: External volumes, IAM roles, catalog integrations
- Storage management: YOU are responsible for storage (backups, lifecycle)
- Limited features for external catalog: No clustering, limited streams
- Egress costs: If Snowflake and storage are in different regions
- No encryption by Snowflake: You must configure your own encryption
- No temporary/transient Iceberg tables

### Native Table vs Iceberg Table:

| Feature | Native Table | Iceberg Table |
|---------|-------------|---------------|
| Storage | Snowflake-managed | Your cloud storage |
| File format | Proprietary | Open Parquet |
| Multi-engine access | No | Yes |
| Query performance | Fastest | Slightly slower |
| Fail-safe | Yes (7 days) | No |
| Time Travel | Up to 90 days | Via Iceberg snapshots |
| Storage cost | Snowflake rates | Cloud provider rates |
| Clustering | Yes | Yes (managed only) |
| DML support | Full | Full (managed only) |
| Vendor lock-in | Yes | No |
| Setup complexity | Simple | More complex |

---

## 6. PRACTICAL SETUP: SNOWFLAKE-MANAGED ICEBERG TABLE (AWS S3)

### STEP 1: Create an External Volume
```sql
CREATE OR REPLACE EXTERNAL VOLUME iceberg_ext_vol
  STORAGE_LOCATIONS = (
    (
      NAME = 'my-s3-iceberg'
      STORAGE_PROVIDER = 'S3'
      STORAGE_BASE_URL = 's3://my-company-datalake/iceberg/'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-iceberg-role'
      STORAGE_AWS_EXTERNAL_ID = 'my_external_id'
    )
  )
  ALLOW_WRITES = TRUE;
```

- Creates a named connection to your S3 bucket
- `ALLOW_WRITES = TRUE` is required for Snowflake-managed tables
- One external volume can serve multiple Iceberg tables

```sql
SELECT SYSTEM$VERIFY_EXTERNAL_VOLUME('iceberg_ext_vol');
DESC EXTERNAL VOLUME iceberg_ext_vol;
```

### STEP 2: Create Database and Schema
```sql
CREATE OR REPLACE DATABASE iceberg_demo;
CREATE OR REPLACE SCHEMA iceberg_demo.analytics;
```

### STEP 3: Create a Snowflake-Managed Iceberg Table
```sql
CREATE OR REPLACE ICEBERG TABLE iceberg_demo.analytics.orders (
    order_id INT,
    customer_id INT,
    order_date DATE,
    product_name VARCHAR,
    quantity INT,
    amount NUMBER(10,2),
    status VARCHAR,
    region VARCHAR
)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'iceberg_ext_vol'
    BASE_LOCATION = 'orders';
```

- Data files (Parquet) stored at: `s3://my-company-datalake/iceberg/orders.XXXXXXXX/data/`
- Metadata files stored at: `s3://my-company-datalake/iceberg/orders.XXXXXXXX/metadata/`

### STEP 4: Insert Data
```sql
INSERT INTO iceberg_demo.analytics.orders VALUES
    (1, 101, '2024-06-01', 'Laptop', 1, 50000.00, 'delivered', 'Mumbai'),
    (2, 102, '2024-06-02', 'Mouse', 3, 4500.00, 'shipped', 'Delhi'),
    (3, 103, '2024-06-03', 'Keyboard', 2, 5000.00, 'pending', 'Bangalore'),
    (4, 101, '2024-06-04', 'Monitor', 1, 25000.00, 'delivered', 'Mumbai'),
    (5, 104, '2024-06-05', 'Headphones', 5, 12500.00, 'cancelled', 'Chennai');

SELECT * FROM iceberg_demo.analytics.orders WHERE region = 'Mumbai';
```

### STEP 5: DML Operations (Full support for managed tables)
```sql
UPDATE iceberg_demo.analytics.orders SET status = 'delivered' WHERE order_id = 2;

DELETE FROM iceberg_demo.analytics.orders WHERE status = 'cancelled';

MERGE INTO iceberg_demo.analytics.orders t
USING (SELECT 6 AS order_id, 105 AS customer_id, '2024-06-06'::DATE AS order_date,
       'Tablet' AS product_name, 1 AS quantity, 30000.00 AS amount,
       'pending' AS status, 'Pune' AS region) s
ON t.order_id = s.order_id
WHEN NOT MATCHED THEN INSERT VALUES (s.order_id, s.customer_id, s.order_date,
    s.product_name, s.quantity, s.amount, s.status, s.region);
```

### STEP 6: Add Clustering (Managed tables only)
```sql
ALTER ICEBERG TABLE iceberg_demo.analytics.orders CLUSTER BY (region, order_date);
```

### STEP 7: View Iceberg Table Metadata
```sql
SHOW ICEBERG TABLES IN SCHEMA iceberg_demo.analytics;
SELECT SYSTEM$GET_ICEBERG_TABLE_INFORMATION('iceberg_demo.analytics.orders');
```

---

## 7. PRACTICAL SETUP: EXTERNALLY MANAGED ICEBERG TABLE (AWS Glue)

### STEP 1: Create a Catalog Integration
```sql
CREATE OR REPLACE CATALOG INTEGRATION glue_catalog_int
    CATALOG_SOURCE = GLUE
    CATALOG_NAMESPACE = 'my_glue_database'
    TABLE_FORMAT = ICEBERG
    GLUE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-glue-role'
    GLUE_CATALOG_ID = '123456789012'
    GLUE_REGION = 'us-east-1'
    ENABLED = TRUE;
```

### STEP 2: Create External Volume (read-only)
```sql
CREATE OR REPLACE EXTERNAL VOLUME glue_ext_vol
  STORAGE_LOCATIONS = (
    (
      NAME = 'glue-s3-location'
      STORAGE_PROVIDER = 'S3'
      STORAGE_BASE_URL = 's3://my-datalake/glue-tables/'
      STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::123456789012:role/snowflake-read-role'
    )
  )
  ALLOW_WRITES = FALSE;
```

### STEP 3: Create the Externally Managed Iceberg Table
```sql
CREATE OR REPLACE ICEBERG TABLE iceberg_demo.analytics.ext_events
    EXTERNAL_VOLUME = 'glue_ext_vol'
    CATALOG = 'glue_catalog_int'
    CATALOG_TABLE_NAME = 'events';
```

### STEP 4: Query and Refresh
```sql
SELECT * FROM iceberg_demo.analytics.ext_events LIMIT 10;
ALTER ICEBERG TABLE iceberg_demo.analytics.ext_events REFRESH;
```

---

## 8. ICEBERG TABLE WITH PARTITIONING

```sql
CREATE OR REPLACE ICEBERG TABLE iceberg_demo.analytics.events_partitioned (
    event_id INT, user_id INT, event_type VARCHAR, event_date DATE, payload VARIANT
)
    PARTITION BY (event_date)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'iceberg_ext_vol'
    BASE_LOCATION = 'events_partitioned';
```

Iceberg uses **hidden partitioning**: you specify `PARTITION BY (event_date)`, users query normally with `WHERE event_date = '2024-06-01'`, and Iceberg handles partition pruning automatically. No partition column in queries needed (unlike Hive).

---

## 9. CONVERT EXISTING NATIVE TABLE TO ICEBERG

You **CANNOT** directly convert. You must CREATE a new Iceberg table and INSERT data:

```sql
CREATE OR REPLACE ICEBERG TABLE iceberg_demo.analytics.orders_iceberg
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'iceberg_ext_vol'
    BASE_LOCATION = 'orders_iceberg'
AS
    SELECT * FROM my_db.my_schema.orders_native;
```

---

## 10. MANAGING ICEBERG TABLES

```sql
SHOW ICEBERG TABLES;
DESCRIBE ICEBERG TABLE iceberg_demo.analytics.orders;
ALTER ICEBERG TABLE iceberg_demo.analytics.orders ADD COLUMN discount NUMBER(10,2);
ALTER ICEBERG TABLE iceberg_demo.analytics.orders RENAME COLUMN discount TO discount_amount;
DROP ICEBERG TABLE iceberg_demo.analytics.orders;
```

---

## 11. ICEBERG IN dbt

dbt-snowflake adapter (1.7.0+) supports Iceberg tables:

```sql
-- models/iceberg_orders.sql
{{ config(
    materialized='table',
    table_format='iceberg',
    external_volume='iceberg_ext_vol',
    base_location_subpath='dbt_orders/'
) }}

SELECT order_id, customer_id, order_date, amount
FROM {{ ref('stg_orders') }}
```

---

## 12. INTERVIEW QUESTIONS

### BEGINNER:

**Q1: What is an Iceberg table in Snowflake?**
> An Iceberg table uses the Apache Iceberg open table format to store data as Parquet files in external cloud storage (S3/Azure/GCS) while allowing Snowflake to query it with full SQL support.

**Q2: What file format do Iceberg tables use?**
> Apache Parquet.

**Q3: What is an external volume?**
> A named Snowflake object that connects Snowflake to your external cloud storage. It stores the IAM credentials Snowflake uses to read/write your Parquet files.

**Q4: What is the difference between a native Snowflake table and an Iceberg table?**
> Native: data in Snowflake-managed storage, proprietary format. Iceberg: data in YOUR storage, open Parquet format, multi-engine access. Native is faster; Iceberg is more portable.

**Q5: Do Iceberg tables have Fail-safe?**
> No. You must manage your own backups and lifecycle.

### INTERMEDIATE:

**Q6: What are the two catalog modes for Iceberg tables?**
> Snowflake-managed (`CATALOG='SNOWFLAKE'`) — full read/write. Externally managed — uses external catalog like AWS Glue, read access from Snowflake.

**Q7: Can Spark read a Snowflake-managed Iceberg table?**
> Yes, via the Snowflake Horizon Iceberg REST Catalog.

**Q8: What is hidden partitioning in Iceberg?**
> You define `PARTITION BY (column)`, but users don't need to know about partitions. Iceberg automatically prunes during queries.

**Q9: How do you refresh an externally managed Iceberg table?**
> `ALTER ICEBERG TABLE my_table REFRESH;`

**Q10: Can you use clustering on Iceberg tables?**
> Only on Snowflake-managed. Not supported for externally managed.

**Q11: How do you create an Iceberg table in dbt?**
> Use `table_format='iceberg'` in the config with `external_volume` and `base_location_subpath`. Requires dbt-snowflake 1.7.0+.

### ADVANCED:

**Q12: When would you choose Iceberg over a native Snowflake table?**
> Multi-engine access, vendor portability, storage cost control, or regulatory requirements.

**Q13: What are the performance implications of Iceberg vs native tables?**
> ~10-20% slower due to external I/O and metadata overhead. Native tables benefit from Snowflake's internal micro-partition optimization.

**Q14: Your company has 100TB in S3 as Parquet files managed by Spark. How do you make it queryable in Snowflake?**
> Create catalog integration to AWS Glue + external volume to S3 + externally managed Iceberg tables. No data movement needed.

**Q15: How does Time Travel work with Iceberg tables?**
> Via Iceberg snapshots stored in the metadata directory. Each write creates a new snapshot. Works as long as snapshot metadata and referenced Parquet files still exist.

**Q16: What is a catalog-linked database?**
> A Snowflake database that auto-discovers and syncs with tables from a remote Iceberg REST catalog. No manual CREATE ICEBERG TABLE needed.

**Q17: Can you convert an externally managed Iceberg table to Snowflake-managed?**
> Yes. `ALTER ICEBERG TABLE my_table CONVERT TO MANAGED.`

**Q18: How do you handle storage maintenance for Iceberg tables?**
> Snowflake-managed: automatic compaction. Externally managed: run Spark's `rewrite_data_files` + `expire_snapshots` manually.

**Q19: What happens if someone deletes Parquet files from S3?**
> Queries will FAIL. No Fail-safe. You must have your own backups (S3 versioning).

**Q20: Design a lakehouse where Spark writes raw data and Snowflake serves analytics.**
> 1. Spark writes Iceberg tables to S3 registered in Glue. 2. Snowflake reads via catalog integration + external volume. 3. Raw layer: externally managed Iceberg. 4. Analytics layer: Snowflake-managed Iceberg. 5. ML team reads S3 Parquet directly. Single copy, two engines, no duplication.

---

## 13. ICEBERG ARCHITECTURE: DEEP DIVE

Apache Iceberg has a **3-LAYER ARCHITECTURE**:

### LAYER 1: CATALOG (the "phone book")

Stores a POINTER to the current metadata file for each table. When you query a table, the engine first asks the catalog: *"Where is the latest metadata file for table X?"*

Examples: Snowflake catalog, AWS Glue, Polaris/Open Catalog

The catalog stores ONE thing per table:
```
table_name → s3://bucket/metadata/v3.metadata.json
```

On every WRITE, the catalog **atomically swaps** this pointer from the old metadata file to the new one.

### LAYER 2: METADATA (the "table of contents")

Files stored in YOUR S3 bucket under `/metadata/` directory:

```
metadata/
├── v1.metadata.json    ← snapshot 1 (initial load)
├── v2.metadata.json    ← snapshot 2 (after INSERT)
├── v3.metadata.json    ← snapshot 3 (after UPDATE) ← CURRENT
├── snap-001.avro       ← manifest list for snapshot 1
├── snap-002.avro       ← manifest list for snapshot 2
├── snap-003.avro       ← manifest list for snapshot 3
├── manifest-aaa.avro   ← manifest file (lists data files)
├── manifest-bbb.avro   ← manifest file
└── manifest-ccc.avro   ← manifest file
```

**Each metadata.json contains:**
- Table schema (column names, types)
- Partition spec
- List of ALL snapshots (history)
- Current snapshot ID
- Pointer to the manifest list for each snapshot

**Each manifest list (snap-XXX.avro) contains:**
- List of manifest files that belong to this snapshot

**Each manifest file (manifest-XXX.avro) contains:**
- List of actual DATA files (Parquet paths)
- Per-file statistics: min/max values, row count, null count
- Partition info for each data file

### LAYER 3: DATA FILES (the actual data)

```
data/
├── part-00001-abc123.parquet   (100MB, rows 1-500K)
├── part-00002-def456.parquet   (100MB, rows 500K-1M)
├── part-00003-ghi789.parquet   (80MB, rows 1M-1.4M)
└── part-00004-jkl012.parquet   (50MB, rows from UPDATE)
```

- Apache Parquet format (columnar, compressed)
- Each file is **immutable** (never modified, only added/removed)
- Typical size: 100-250MB per file

### FULL HIERARCHY:

```
Catalog
  └── metadata pointer → v3.metadata.json
                            ├── schema: {order_id INT, ...}
                            ├── partitions: [order_date]
                            ├── current-snapshot: snap-003
                            └── snapshots:
                                ├── snap-001 → snap-001.avro (manifest list)
                                │                └── manifest-aaa.avro
                                │                      ├── part-00001.parquet (stats)
                                │                      └── part-00002.parquet (stats)
                                ├── snap-002 → snap-002.avro (manifest list)
                                │                ├── manifest-aaa.avro (reused!)
                                │                └── manifest-bbb.avro
                                │                      └── part-00003.parquet (stats)
                                └── snap-003 → snap-003.avro (manifest list)
                                                 ├── manifest-aaa.avro (reused!)
                                                 ├── manifest-bbb.avro (reused!)
                                                 └── manifest-ccc.avro
                                                       └── part-00004.parquet (stats)
```

---

## 14. HOW READS WORK (Query Execution Flow)

**QUERY:** `SELECT * FROM orders WHERE order_date = '2024-06-01' AND region = 'Mumbai'`

### STEP 1: CATALOG LOOKUP
Snowflake asks the catalog: *"Where is the current metadata for table 'orders'?"*
Catalog returns: `s3://bucket/metadata/v3.metadata.json`

### STEP 2: READ METADATA FILE
Snowflake downloads `v3.metadata.json` from S3.
Finds: `current-snapshot-id = snap-003` → `snap-003.avro`

### STEP 3: READ MANIFEST LIST
Snowflake downloads `snap-003.avro`. Finds 3 manifest files: `manifest-aaa.avro`, `manifest-bbb.avro`, `manifest-ccc.avro`

### STEP 4: READ MANIFEST FILES + PARTITION PRUNING
Snowflake reads each manifest file. Each contains data file paths + column statistics (min/max):

```
manifest-aaa.avro:
  part-00001.parquet → order_date range: [2024-05-01, 2024-05-31] → SKIP!
  part-00002.parquet → order_date range: [2024-06-01, 2024-06-15] → KEEP!

manifest-bbb.avro:
  part-00003.parquet → order_date range: [2024-06-01, 2024-06-30] → KEEP!

manifest-ccc.avro:
  part-00004.parquet → order_date range: [2024-07-01, 2024-07-31] → SKIP!
```

### STEP 5: READ ONLY RELEVANT PARQUET FILES
Snowflake downloads ONLY `part-00002.parquet` and `part-00003.parquet`. (Skipped 2 out of 4 files = 50% pruning)

Within each Parquet file, Snowflake uses row group statistics and column projection for further optimization.

### STEP 6: APPLY REMAINING FILTERS
Snowflake applies `WHERE region = 'Mumbai'` on the remaining rows. Returns matching rows.

### READ PERFORMANCE OPTIMIZATION CHAIN:
```
1. Manifest-level pruning (partition stats)    → SKIP files
2. Parquet row-group pruning (column stats)    → SKIP groups
3. Column projection (only read needed columns)→ Less I/O
4. Predicate pushdown (apply WHERE in reader)  → Less data
```

---

## 15. HOW WRITES WORK (INSERT / UPDATE / DELETE / MERGE)

### INSERT (Append new data)

```sql
INSERT INTO orders VALUES (7, 107, '2024-07-01', 'Tablet', 1, 30000, 'pending', 'Pune');
```

1. Snowflake writes new Parquet file(s) to S3 → `data/part-00005-mno345.parquet`
2. Creates a NEW manifest file referencing the new data file
3. Creates a NEW manifest list including all existing manifests + the new one
4. Writes a NEW metadata file with `current-snapshot: snap-004`
5. Catalog atomically updates the pointer to new metadata

**NO existing files are modified!** Old Parquet files are UNTOUCHED. Only NEW files are added.

```
data/
├── part-00001.parquet  (untouched)
├── part-00002.parquet  (untouched)
├── part-00003.parquet  (untouched)
├── part-00004.parquet  (untouched)
└── part-00005.parquet  ← NEW
```

### UPDATE (Copy-on-Write)

```sql
UPDATE orders SET status = 'delivered' WHERE order_id = 3;
```

Iceberg uses **COPY-ON-WRITE** for Snowflake-managed tables:

1. Identify which Parquet file(s) contain `order_id=3` → found in `part-00003.parquet`
2. Read `part-00003.parquet`, modify the matching row, write the **ENTIRE file** as a NEW Parquet file → `part-00006-xyz.parquet`
3. Create a new snapshot where `part-00003` is REMOVED and `part-00006` is ADDED
4. New metadata file + catalog pointer update

```
data/
├── part-00001.parquet  (still referenced)
├── part-00002.parquet  (still referenced)
├── part-00003.parquet  ← still EXISTS on S3 but NOT in current snapshot
├── part-00004.parquet  (still referenced)
├── part-00005.parquet  (still referenced)
└── part-00006.parquet  ← NEW (replaces part-00003 in current snapshot)
```

> **KEY POINT:** `part-00003` is NOT deleted from S3 immediately! It's just no longer referenced by the current snapshot. This is how Time Travel works — old snapshots still reference it. Eventually, maintenance will clean it up.

### DELETE

Same as UPDATE — Copy-on-Write:
1. Find files containing matching rows
2. Rewrite those files WITHOUT the deleted rows
3. New snapshot references rewritten files, drops old ones
4. Old files remain on S3 for Time Travel until cleanup

### MERGE

Combination of INSERT + UPDATE logic:
1. MATCHED rows: Copy-on-Write (rewrite affected Parquet files)
2. NOT MATCHED rows: Write new Parquet files (append)
3. Single atomic snapshot with all changes

> ALL write operations create a new snapshot atomically. If the write FAILS, no snapshot is created → table is unchanged. This is **ACID**: Atomicity, Consistency, Isolation, Durability.

---

## 16. HOW TIME TRAVEL WORKS IN ICEBERG

### Native Snowflake Time Travel:
- Uses Snowflake's internal storage to keep old micro-partitions
- Configurable: 0-90 days
- Plus 7-day Fail-safe
- Query with: `AT(TIMESTAMP => ...)` or `BEFORE(STATEMENT => ...)`

### Iceberg Time Travel:
- Uses **ICEBERG SNAPSHOTS** (metadata files that reference old Parquet files)
- Each write creates a new snapshot
- Old snapshots reference old Parquet files (NOT deleted immediately)
- Works as long as: (a) snapshot metadata exists and (b) referenced Parquet files exist

### Timeline of Writes:

```
Day 1: CREATE TABLE + INSERT 1000 rows
       → Snapshot 1 (snap-001) → references part-00001.parquet

Day 3: INSERT 500 more rows
       → Snapshot 2 (snap-002) → references part-00001 + part-00002.parquet

Day 5: UPDATE 100 rows (in part-00001)
       → Snapshot 3 (snap-003) → references part-00001-v2 + part-00002.parquet
       (part-00001 original still on S3, referenced by snap-001 and snap-002)

Day 7: DELETE 50 rows (from part-00002)
       → Snapshot 4 (snap-004) → references part-00001-v2 + part-00002-v2.parquet
       (CURRENT snapshot)
```

### Querying Historical Snapshots:

```sql
-- Current state (Snapshot 4):
SELECT * FROM orders;
-- Reads: part-00001-v2 + part-00002-v2 → updated + deleted state

-- As of Day 1 (Snapshot 1):
SELECT * FROM orders AT(TIMESTAMP => '2024-06-01'::TIMESTAMP);
-- Reads: part-00001 (ORIGINAL!) → 1000 rows, no updates

-- As of Day 3 (Snapshot 2):
SELECT * FROM orders AT(TIMESTAMP => '2024-06-03'::TIMESTAMP);
-- Reads: part-00001 + part-00002 → 1500 rows, before updates

-- As of Day 5 (Snapshot 3):
SELECT * FROM orders AT(TIMESTAMP => '2024-06-05'::TIMESTAMP);
-- Reads: part-00001-v2 + part-00002 → updated rows, before delete
```

### Snapshot Lifecycle:

```
Snapshot 1 ──→ Snapshot 2 ──→ Snapshot 3 ──→ Snapshot 4
(Day 1)        (Day 3)        (Day 5)        (Day 7 = CURRENT)

Each snapshot is IMMUTABLE.
Old snapshots RETAINED until cleanup (expiration).
Old Parquet files RETAINED until no snapshot references them.

Snowflake maintenance:
  1. Expire old snapshots (based on retention settings)
  2. Delete orphaned Parquet files (not referenced by any snapshot)
  3. Compact small files into larger ones (performance)
```

### Differences from Native Time Travel:

| Feature | Native Table | Iceberg Table |
|---------|-------------|---------------|
| Mechanism | Micro-partition versioning | Iceberg snapshots + Parquet files |
| Max retention | 0-90 days (configurable) | Based on snapshot expiration |
| Fail-safe | Yes (7 days extra) | No |
| Storage cost | Snowflake charges | S3 charges (your bucket) |
| Cleanup | Automatic (Snowflake) | Snowflake maintenance (managed) or manual (external) |
| UNDROP TABLE | Yes | Not supported |

---

## 17. HOW SCHEMA EVOLUTION WORKS

Iceberg supports schema evolution **WITHOUT rewriting existing data files**:

### ADD COLUMN
```sql
ALTER ICEBERG TABLE orders ADD COLUMN discount NUMBER(10,2);
```
- New metadata file written with updated schema
- Existing Parquet files NOT modified (return NULL for new column)
- New writes include the column

### RENAME COLUMN
```sql
ALTER ICEBERG TABLE orders RENAME COLUMN discount TO discount_amount;
```
- Only metadata updated (column name mapping)
- Iceberg uses FIELD IDs internally (not names)
- Existing files NOT modified. Instant.

### DROP COLUMN
```sql
ALTER ICEBERG TABLE orders DROP COLUMN discount_amount;
```
- Metadata updated to remove column
- Files STILL contain data physically but queries skip it
- Next compaction may rewrite files without the column

### TYPE WIDENING
```sql
ALTER ICEBERG TABLE orders ALTER COLUMN quantity SET DATA TYPE BIGINT;
```
- Metadata records type change (INT → BIGINT)
- Existing files read and widened at query time
- New writes use BIGINT

> **KEY INSIGHT:** Schema evolution is METADATA-ONLY. No data files rewritten. Instant, safe, backward-compatible.

---

## 18. COMPACTION AND MAINTENANCE

**PROBLEM:** Many small writes create many small Parquet files. Querying 10,000 tiny files is MUCH slower than 100 large files.

**SOLUTION:** COMPACTION — merge small files into larger ones.

### Snowflake-Managed Tables:
- Automatic background compaction
- Merges small files into ~100-250MB
- Cleans up expired snapshots and orphaned files
- Disable with: `ALTER ICEBERG TABLE t SET AUTO_COMPACTION = FALSE;`

### Externally Managed Tables:
- Snowflake does NOT compact (read-only)
- YOU must run compaction via Spark:
  - `spark.sql("CALL catalog.system.rewrite_data_files('db.orders')")`
  - `spark.sql("CALL catalog.system.expire_snapshots('db.orders')")`
- Then: `ALTER ICEBERG TABLE my_external_table REFRESH;`

### What Compaction Does:

```
Before:                          After:
data/                            data/
├── part-001.parquet  (2MB)      └── part-006.parquet  (15MB) ← merged
├── part-002.parquet  (5MB)
├── part-003.parquet  (1MB)      Same data, fewer files, faster queries
├── part-004.parquet  (3MB)
└── part-005.parquet  (4MB)
    5 files, 15MB                    1 file, 15MB
```

---

## 19. COMPLETE ARCHITECTURE DIAGRAM

```
┌───────────────────────────────────────────────────────────────────────┐
│                        YOUR CLOUD STORAGE (S3)                        │
│  s3://my-company-datalake/iceberg/orders.XXXXXXXX/                   │
│                                                                       │
│  ┌─── metadata/ ──────────────────────────────────────────────────┐  │
│  │  v1.metadata.json  (schema, partitions, snapshot list)         │  │
│  │  v2.metadata.json                                               │  │
│  │  v3.metadata.json  ← CURRENT (catalog points here)            │  │
│  │  snap-001.avro     (manifest list for snapshot 1)              │  │
│  │  snap-002.avro     (manifest list for snapshot 2)              │  │
│  │  snap-003.avro     (manifest list for snapshot 3)              │  │
│  │  manifest-aaa.avro (data file list + column stats)             │  │
│  │  manifest-bbb.avro                                              │  │
│  │  manifest-ccc.avro                                              │  │
│  └────────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌─── data/ ──────────────────────────────────────────────────────┐  │
│  │  part-00001-abc.parquet  (100MB, rows 1-500K)                  │  │
│  │  part-00002-def.parquet  (100MB, rows 500K-1M)                 │  │
│  │  part-00003-ghi.parquet  (80MB, from UPDATE rewrite)           │  │
│  └────────────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
         ▲                                              ▲
         │ IAM Role (read/write)                        │ IAM Role (read)
         │                                              │
┌────────┴─────────┐                          ┌────────┴─────────┐
│   SNOWFLAKE       │                          │   SPARK / FLINK   │
│   (query engine)  │                          │   (query engine)  │
│                   │                          │                   │
│ External Volume   │                          │ Direct S3 access  │
│ connects via IAM  │                          │ reads Parquet     │
│                   │                          │                   │
│ CATALOG=SNOWFLAKE │                          │ Uses Glue/Polaris │
│ manages metadata  │                          │ for metadata      │
└───────────────────┘                          └───────────────────┘
```

### QUERY FLOW (Snowflake):
1. User: `SELECT * FROM orders WHERE date='2024-06-01'`
2. Snowflake → Catalog: "Where is current metadata for 'orders'?"
3. Catalog → Snowflake: `s3://bucket/metadata/v3.metadata.json`
4. Snowflake reads metadata → finds current snapshot
5. Snowflake reads manifest list → finds manifest files
6. Snowflake reads manifests → uses stats to **PRUNE** files
7. Snowflake reads ONLY relevant Parquet files from S3
8. Snowflake applies remaining filters → returns results

### WRITE FLOW (Snowflake):
1. User: `INSERT INTO orders VALUES (...)`
2. Snowflake writes new Parquet file(s) to S3 `data/` directory
3. Snowflake creates new manifest → manifest list → metadata file
4. Snowflake atomically updates catalog pointer to new metadata
5. Old metadata + old Parquet files remain for Time Travel
6. Background maintenance eventually cleans up expired files
