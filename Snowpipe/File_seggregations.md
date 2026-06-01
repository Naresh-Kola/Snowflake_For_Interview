# Snowflake File Segregation: Micro-Partitions & Data Files Deep Dive

## Table of Contents
1. [How Data is Stored Internally (Micro-Partitions)](#how-data-is-stored-internally)
2. [How Micro-Partitions are Created During INSERT](#how-micro-partitions-are-created-during-insert)
3. [How Files are Created During UNLOAD (Table → File)](#how-files-are-created-during-unload)
4. [How Files are Split During LOAD (File → Table)](#how-files-are-split-during-load)
5. [Factors That Affect File/Partition Count](#factors-that-affect-filepartition-count)
6. [DML Impact on Micro-Partitions](#dml-impact-on-micro-partitions)
7. [Interview Questions: Beginner to Architect](#interview-questions)

---

## How Data is Stored Internally

### Micro-Partition Basics

Snowflake does NOT use traditional file-based partitions. It uses **micro-partitions**.

```
┌─────────────────────────────────────────────────────────┐
│                    SNOWFLAKE TABLE                       │
├─────────────┬─────────────┬─────────────┬───────────────┤
│    MP-1     │    MP-2     │    MP-3     │    MP-N       │
│  (50-500MB  │  (50-500MB  │  (50-500MB  │  (50-500MB    │
│ uncompressed)│ uncompressed)│ uncompressed)│ uncompressed) │
└─────────────┴─────────────┴─────────────┴───────────────┘
```

| Property | Value |
|----------|-------|
| Size (uncompressed) | 50 MB – 500 MB |
| Size (compressed on disk) | Much smaller (4-5x compression) |
| Storage format | Columnar (PAX hybrid) |
| Creation | Automatic (no user intervention) |
| Fixed size? | NO — ranges between 50-500 MB |
| User-controllable? | NO — Snowflake decides internally |

### What's Inside a Micro-Partition?

```
┌──────────────────────────────────────────┐
│           MICRO-PARTITION                 │
├──────────────────────────────────────────┤
│                                          │
│  ┌──────┐  ┌──────┐  ┌──────┐          │
│  │ Col1 │  │ Col2 │  │ Col3 │  ...     │
│  │(comp)│  │(comp)│  │(comp)│          │
│  └──────┘  └──────┘  └──────┘          │
│                                          │
│  + METADATA HEADER:                      │
│    - Min/Max values per column           │
│    - Distinct count per column           │
│    - Null count per column               │
│    - Total row count                     │
│    - Byte size                           │
│                                          │
└──────────────────────────────────────────┘
```

Key facts:
- Each column is stored **independently** (columnar)
- Each column is compressed **independently** (best algorithm chosen per column)
- Metadata is stored **separately** in the Cloud Services layer (not in the MP itself)
- Rows are grouped together — a row always lives in ONE micro-partition

---

## How Micro-Partitions are Created During INSERT

### The Process

```
INSERT INTO my_table SELECT * FROM source_table;

     Data Stream (rows)
           │
           ▼
  ┌─────────────────────┐
  │   WAREHOUSE NODES   │ (parallel workers)
  │                     │
  │  Worker1  Worker2   │  ← Each worker writes its own MPs
  │     │        │      │
  │     ▼        ▼      │
  │   MP-1     MP-2     │
  │   MP-3     MP-4     │
  └─────────────────────┘
           │
           ▼
     Cloud Storage
  (S3 / Azure Blob / GCS)
```

### Key Rules

| Rule | Detail |
|------|--------|
| Partitioning is automatic | You CANNOT control which rows go to which MP |
| Order matters | Data is partitioned based on **insertion order** |
| Warehouse size affects MP count | Larger warehouse = more workers = more MPs |
| No fixed row count | Each MP holds different number of rows depending on column widths |
| Target size is 50-500 MB | Snowflake aims for this range (uncompressed) |
| Immutable | Once created, an MP is NEVER modified (append-only architecture) |

### Warehouse Size Impact on Micro-Partition Count

```
INSERT INTO table1 SELECT * FROM source (100M rows);

┌──────────────┬─────────┬──────────┐
│ Warehouse    │ Workers │ MP Count │
├──────────────┼─────────┼──────────┤
│ X-Small      │ 1       │ 8        │
│ Small        │ 2       │ 10       │
│ Medium       │ 4       │ 12       │
│ Large        │ 8       │ 14       │
└──────────────┴─────────┴──────────┘
```

**Why?** More workers process rows in parallel. Each worker creates its own set of micro-partitions. This can lead to slightly more (but smaller) MPs with larger warehouses.

### INSERT Types and MP Behavior

| Operation | MP Behavior |
|-----------|-------------|
| `INSERT INTO ... VALUES` | Adds new MP(s) at the end |
| `INSERT INTO ... SELECT` | Adds new MP(s) based on source data order |
| `COPY INTO table` | Adds new MP(s), one or more per input file |
| `CREATE TABLE AS SELECT` | Creates all MPs fresh, ordered by SELECT output |
| Snowpipe (streaming) | Creates small MPs per micro-batch (may be sub-optimal) |

---

## How Files are Created During UNLOAD

### COPY INTO @stage (Table → File)

When you unload data from a table to files:

```sql
COPY INTO @my_stage/output/
FROM my_table
FILE_FORMAT = (TYPE = CSV)
MAX_FILE_SIZE = 64000000;  -- 64 MB
```

### File Size Determination

| Factor | How It Affects File Count |
|--------|--------------------------|
| **MAX_FILE_SIZE** | Upper limit per file (default: 16 MB) |
| **Warehouse size** | More nodes = more parallel files |
| **Number of threads** | Each thread writes its own file |
| **SINGLE = TRUE** | Forces one single file output |
| **PARTITION BY** | Creates files per partition value |
| **Total data size** | More data = more files |

### Default Behavior (No Options)

```sql
COPY INTO @my_stage FROM my_table;

-- Result: Multiple files of ~16 MB each (default MAX_FILE_SIZE)
-- Naming: data_0_0_0.csv.gz, data_0_1_0.csv.gz, ...
```

```
Table (500 MB)
    │
    ├── Thread 1 → data_0_0_0.csv.gz (16 MB)
    ├── Thread 1 → data_0_0_1.csv.gz (16 MB)
    ├── Thread 2 → data_0_1_0.csv.gz (16 MB)
    ├── Thread 2 → data_0_1_1.csv.gz (16 MB)
    ...
    └── ~31 files total
```

### Can You Control the File Size?

| Scenario | How |
|----------|-----|
| Want fewer, larger files | `MAX_FILE_SIZE = 5368709120` (up to 5 GB) |
| Want exactly 1 file | `SINGLE = TRUE` |
| Want files per date | `PARTITION BY (TO_VARCHAR(date_col, 'YYYY-MM-DD'))` |
| Want smaller files | `MAX_FILE_SIZE = 5000000` (5 MB) |

**Important:** `MAX_FILE_SIZE` is an **upper limit**, NOT a guarantee. Files may be smaller based on available memory and parallelism.

### PARTITION BY (Advanced Unload)

```sql
COPY INTO @my_stage
FROM orders
PARTITION BY ('year=' || YEAR(order_date) || '/month=' || MONTH(order_date))
FILE_FORMAT = (TYPE = PARQUET)
MAX_FILE_SIZE = 128000000
HEADER = TRUE;

-- Output:
-- year=2024/month=1/data_<uuid>_0_0.snappy.parquet
-- year=2024/month=2/data_<uuid>_0_0.snappy.parquet
-- year=2024/month=3/data_<uuid>_0_0.snappy.parquet
```

---

## How Files are Split During LOAD

### COPY INTO table (File → Table)

When loading data from files into a table:

```sql
COPY INTO my_table
FROM @my_stage
FILE_FORMAT = (TYPE = CSV);
```

### File → Micro-Partition Mapping

```
Input Files (on stage)              Micro-Partitions Created
┌───────────────────┐              ┌──────────────────────┐
│ file_001.csv.gz   │──── Worker1 ──→ MP-1, MP-2         │
│ file_002.csv.gz   │──── Worker2 ──→ MP-3, MP-4         │
│ file_003.csv.gz   │──── Worker3 ──→ MP-5               │
│ file_004.csv.gz   │──── Worker4 ──→ MP-6, MP-7         │
└───────────────────┘              └──────────────────────┘
```

| Rule | Detail |
|------|--------|
| 1 file ≠ 1 MP | A large file may create multiple MPs |
| Small files = inefficient | Many tiny files create many small, sub-optimal MPs |
| Optimal input file size | **100-250 MB compressed** |
| Parallel loading | Each file is processed by a separate thread |
| Order within file | Preserved in resulting MP(s) |

### Best Practice: Input File Sizing

```
┌────────────────────────────────────────────────────┐
│            RECOMMENDED FILE SIZES                  │
├────────────────────────────────────────────────────┤
│                                                    │
│  TOO SMALL        OPTIMAL           TOO LARGE     │
│  < 10 MB          100-250 MB        > 5 GB        │
│                   (compressed)                     │
│                                                    │
│  Problems:        Benefits:          Problems:     │
│  - Overhead per   - Parallel load    - Sequential  │
│    file is high   - Efficient MPs      processing │
│  - Poor pruning   - Good throughput  - Memory      │
│  - Many MPs       - Balanced work      pressure   │
│                                                    │
└────────────────────────────────────────────────────┘
```

---

## Factors That Affect File/Partition Count

### During Storage (INSERT → MP)

| Factor | More MPs | Fewer MPs |
|--------|----------|-----------|
| Warehouse size | Larger WH | Smaller WH |
| Data volume | More data | Less data |
| Column count/width | Wider rows (fewer rows per MP) | Narrow rows |
| INSERT frequency | Many small inserts | Fewer bulk inserts |
| Snowpipe micro-batches | Creates many small MPs | N/A |

### During Unload (Table → Files)

| Factor | More Files | Fewer Files |
|--------|-----------|-------------|
| MAX_FILE_SIZE | Smaller value | Larger value |
| SINGLE | FALSE (default) | TRUE |
| Warehouse size | More threads | Fewer threads |
| PARTITION BY | More partitions | Fewer partitions |
| Data volume | More data | Less data |

### During Load (Files → Table)

| Factor | More MPs | Fewer MPs |
|--------|----------|-----------|
| Number of input files | More files | Fewer files |
| File size | Many small files | Fewer optimal-sized files |
| Warehouse size | More workers | Fewer workers |

---

## DML Impact on Micro-Partitions

### Immutability Principle

Micro-partitions are **IMMUTABLE** (write-once, never modified). DML creates NEW micro-partitions.

```
UPDATE my_table SET col = 'X' WHERE id = 5;

BEFORE:
  MP-1: [id=1,2,3,4,5]  ← contains the row to update

AFTER:
  MP-1: [id=1,2,3,4,5]  ← marked for deletion (moved to Time Travel)
  MP-1': [id=1,2,3,4,5] ← NEW MP with updated row (id=5 has col='X')
```

### Impact Summary

| Operation | What Happens to MPs |
|-----------|-------------------|
| INSERT | Creates new MP(s) — existing MPs untouched |
| UPDATE 1 row | Recreates the ENTIRE MP containing that row |
| DELETE 1 row | Recreates the MP without that row |
| MERGE | Combination of INSERT + UPDATE behavior |
| TRUNCATE | Metadata-only operation (instant) |
| DROP TABLE | Metadata-only (data moves to Time Travel → Fail-Safe) |

### Why This Matters

```
Scenario: Table with 1000 MPs, UPDATE affects 1 row in each MP

Result: ALL 1000 MPs are rewritten → 1000 NEW MPs created
        Old 1000 MPs go to Time Travel (storage cost!)

Lesson: Bulk UPDATEs that touch many MPs are EXPENSIVE
```

---

## Interview Questions

### Beginner Level

**Q1: What is a micro-partition in Snowflake?**
> A micro-partition is an immutable, compressed, columnar storage unit containing 50-500 MB of uncompressed data. All Snowflake tables are automatically divided into micro-partitions without any user action.

**Q2: What is the size of a micro-partition?**
> 50 to 500 MB of uncompressed data. The actual compressed size on disk is smaller (typically 4-5x compression).

**Q3: Is micro-partition size fixed?**
> No. It varies between 50-500 MB uncompressed. Snowflake determines the optimal size based on the data being inserted.

**Q4: Can users manually create or control micro-partitions?**
> No. Micro-partitioning is fully automatic. Users cannot directly control which rows go into which partition.

**Q5: What metadata does Snowflake store for each micro-partition?**
> Min/Max values per column, distinct value count, null count, and row count. This metadata enables partition pruning.

**Q6: What is the default file size when unloading data with COPY INTO?**
> 16 MB (MAX_FILE_SIZE default).

---

### Intermediate Level

**Q7: How does warehouse size affect micro-partition creation?**
> Larger warehouses have more worker nodes. Each worker creates its own micro-partitions in parallel, so larger warehouses may produce more (but smaller) micro-partitions for the same data.

**Q8: Why does Snowflake recommend 100-250 MB input files for loading?**
> This size allows efficient parallel processing (one file per thread), creates well-sized micro-partitions, avoids overhead of too many small files, and prevents memory pressure from files that are too large.

**Q9: What happens to micro-partitions when you UPDATE a single row?**
> The entire micro-partition containing that row is rewritten as a new MP with the updated value. The old MP is preserved for Time Travel and then moves to Fail-Safe.

**Q10: How does COPY INTO @stage split output files?**
> Snowflake uses parallel threads, each writing its own output file. The number of files depends on: warehouse size (more nodes = more threads), MAX_FILE_SIZE setting, total data volume, and available memory per worker.

**Q11: What is the difference between SINGLE=TRUE and PARTITION BY in COPY INTO?**
> SINGLE=TRUE forces all data into one file (sequential, slower). PARTITION BY splits files by expression values (e.g., date), creating a directory structure. They cannot be used together.

**Q12: If I insert 1 row into a table with 1 billion rows, how many micro-partitions are affected?**
> Only 1 new micro-partition is created for the inserted row. Existing partitions are untouched. INSERT is always an append operation.

---

### Advanced Level

**Q13: Why might Snowpipe create sub-optimal micro-partitions?**
> Snowpipe processes files as they arrive in micro-batches. If files arrive frequently in small sizes, each batch creates small micro-partitions (potentially much less than 50 MB). Over time, this leads to many small partitions that degrade query performance and may require reclustering.

**Q14: Explain the relationship between micro-partitions and Time Travel storage.**
> When DML modifies data, old micro-partitions are not deleted — they're retained for the Time Travel retention period (1-90 days). Each UPDATE/DELETE creates new MPs while keeping the old ones. This means frequent DML on large tables can significantly increase Time Travel storage costs.

**Q15: How does clustering key interact with micro-partition creation?**
> A clustering key doesn't change how MPs are initially created during INSERT. After insertion, the Automatic Clustering service (serverless) runs in the background to reorganize MPs — it reads existing MPs and rewrites them into new MPs that group similar clustering key values together, reducing overlap.

**Q16: A table has 10 MPs. You UPDATE 1 row in each MP. How many total MPs exist afterward (before Time Travel cleanup)?**
> 20 MPs: 10 original (in Time Travel) + 10 new rewritten MPs (active). Storage temporarily doubles until Time Travel expires.

**Q17: How does the number of columns affect micro-partition sizing?**
> More columns = wider rows = fewer rows fit in the 50-500 MB budget. A table with 500 columns will have far fewer rows per MP than a table with 3 columns. This affects both storage efficiency and query pruning granularity.

**Q18: You run the same INSERT ... SELECT on X-Small and X-Large warehouses. The resulting table has different partition counts. Why? Is the data the same?**
> The data is identical but organized differently. X-Large has 128x more workers than X-Small. Each worker writes its own MPs in parallel, creating more but smaller partitions. The total uncompressed data is the same, but distributed across more files. This can affect clustering quality.

---

### Architect Level

**Q19: Design an optimal data loading strategy for a table receiving 10 TB/day from 1000 small files (1 MB each).**
> Problems: 1000 tiny files create 1000+ sub-optimal micro-partitions.
> Solution:
> 1. Stage files in cloud storage
> 2. Use a pre-processing step to merge small files into 100-250 MB chunks (e.g., using external tooling or a staging table)
> 3. Alternatively, load into a staging table, then INSERT INTO final_table SELECT * FROM staging (this consolidates MPs)
> 4. Define a clustering key on the final table to let Automatic Clustering optimize over time
> 5. Monitor with SYSTEM$CLUSTERING_INFORMATION

**Q20: A production table receives continuous Snowpipe ingestion AND analytical queries. Query performance degrades over months. Diagnose and fix.**
> Diagnosis: Snowpipe creates many small micro-partitions. Over months, the clustering depth increases (more overlap), partition pruning becomes inefficient.
> Fix:
> 1. Check: `SELECT SYSTEM$CLUSTERING_INFORMATION('table', '(query_filter_col)')`
> 2. If average_depth is high → add clustering key: `ALTER TABLE t CLUSTER BY (date_col, filter_col)`
> 3. Automatic Clustering will reorganize MPs in background
> 4. Monitor costs with `SYSTEM$ESTIMATE_AUTOMATIC_CLUSTERING_COSTS`
> 5. Consider a separate ingestion table + periodic INSERT INTO analytics table (batch consolidation)

**Q21: Explain how COPY INTO @stage with PARTITION BY creates files differently than without it.**
> Without PARTITION BY: Snowflake assigns rows to files based purely on parallel execution threads. Each thread gets a chunk of rows and writes files up to MAX_FILE_SIZE.
> With PARTITION BY: Snowflake first logically groups rows by the partition expression, then within each group, parallel threads write files. Small partitions may be merged into a single file. Result: directory-structured output (e.g., `date=2024-01-01/data_*.parquet`). This is critical for external tools (Spark, Hive) that use partition discovery.

**Q22: You need to migrate a 50 TB table to a new schema with a different clustering key. What's the most cost-effective approach?**
> Option A (CTAS — recommended):
> ```sql
> CREATE TABLE new_schema.table CLUSTER BY (new_key) AS
> SELECT * FROM old_schema.table ORDER BY new_key;
> ```
> This creates MPs already sorted by the new key, minimizing future reclustering cost.
>
> Option B (Clone + Recluster — if schema is same):
> ```sql
> CREATE TABLE new_table CLONE old_table;
> ALTER TABLE new_table CLUSTER BY (new_key);
> -- Automatic Clustering handles it over time (but 50 TB = expensive)
> ```
> Option A is cheaper because MPs are created in order once. Option B requires ongoing serverless compute to reorganize all existing MPs.

**Q23: How does DROP COLUMN affect micro-partitions? Does it free storage?**
> DROP COLUMN is a **metadata-only** operation. The column data remains in existing micro-partitions — they are NOT rewritten. Storage is NOT freed immediately. The space is only reclaimed when MPs are eventually rewritten by DML, reclustering, or when Time Travel/Fail-Safe expires on the affected MPs.

**Q24: A COPY INTO @stage with MAX_FILE_SIZE = 5 GB still produces multiple files smaller than 5 GB. Why?**
> MAX_FILE_SIZE is an upper limit, not a target. Snowflake uses parallel threads — each thread writes its own file. Even with MAX_FILE_SIZE larger than total data, multiple threads produce multiple files. Use `SINGLE = TRUE` to force one file. Also, available memory per worker limits how much data a single thread can buffer before flushing to a file.

**Q25: Design a strategy for a table that receives both real-time streaming inserts (Snowpipe) and periodic batch corrections (UPDATE/MERGE). Optimize for both write throughput and query performance.**
> Architecture:
> ```
> ┌─────────────────────────────────────────────┐
> │  Landing Table (TRANSIENT, no clustering)   │ ← Snowpipe writes here
> │  - Raw inserts, small MPs, fast ingestion   │
> └──────────────────┬────────────────────────── ┘
>                    │ (Every 15 min via Task)
>                    ▼
> ┌─────────────────────────────────────────────┐
> │  Main Table (PERMANENT, clustered)          │ ← Analytics reads here
> │  - MERGE from landing                       │
> │  - Clustering key on query filters          │
> │  - Well-organized MPs                       │
> └─────────────────────────────────────────────┘
> ```
> Benefits:
> - Snowpipe writes are fast (no clustering overhead)
> - Batch MERGE consolidates small MPs into larger ones
> - Clustering key maintains read performance
> - Time Travel cost is isolated to main table
> - TRANSIENT landing table saves fail-safe storage

---

## Quick Reference

| Concept | Internal Storage (MPs) | File Unload (COPY INTO @stage) | File Load (COPY INTO table) |
|---------|----------------------|-------------------------------|----------------------------|
| Size control | No (automatic 50-500 MB) | MAX_FILE_SIZE (default 16 MB, max 5 GB) | Input file size determines |
| Parallelism | Warehouse nodes | Warehouse threads | One file per thread |
| Format | Columnar, compressed | CSV/JSON/Parquet (your choice) | Any supported format |
| Partitioning | By insertion order | PARTITION BY expression | By input file boundaries |
| Immutability | Yes (write-once) | N/A (external files) | N/A |
| Metadata | Auto-collected (min/max/count) | None (just files) | Triggers MP metadata creation |



TRUNCATE TABLE my_table;

What happens internally:
┌─────────────────────────────────────────┐
│ Cloud Services Layer (Metadata)         │
│                                         │
│ my_table.active_partitions = []  ← just clears this pointer
│                                         │
└─────────────────────────────────────────┘

BEFORE TRUNCATE:
  Metadata: active_partitions → [MP-1, MP-2, MP-3]

AFTER TRUNCATE:
  Metadata: active_partitions → []  (empty — table looks empty)
  Time Travel: still holds pointers to [MP-1, MP-2, MP-3]

The actual MP files still exist on storage
(moved to Time Travel → then Fail-Safe → then deleted)


AFTER: ALTER TABLE t DROP COLUMN col3;

Micro-Partition (unchanged on disk):
┌──────────┬──────────┬──────────┐
│  col1    │  col2    │  col3    │  ← data still physically here
└──────────┴──────────┴──────────┘

Metadata (updated):
  Table schema: [col1, col2]  ← col3 removed from schema definition


  ┌─────────────────────────────────────────────────────┐
│           CLOUD SERVICES LAYER                      │
│           (Always-on, shared across all warehouses) │
├─────────────────────────────────────────────────────┤
│                                                     │
│  TABLE DEFINITION (schema):                         │
│    • Table name, database, schema                   │
│    • Column names, data types, constraints          │
│    • Clustering key definition                      │
│    • Table type (permanent/transient/temporary)     │
│    • Retention days                                 │
│                                                     │
│  SCHEMA DEFINITION:                                 │
│    • List of tables/views in the schema             │
│    • Ownership, grants                              │
│                                                     │
│  CATALOG:                                           │
│    • Maps object names → physical locations         │
│    • "RENAME TABLE" just changes the name entry     │
│      in this registry (like renaming a file)        │
│                                                     │
│  PARTITION MAP:                                     │
│    • Which MPs belong to which table                │
│    • Min/Max per column per MP                      │
│    • Row count, size per MP                         │
│                                                     │
└─────────────────────────────────────────────────────┘
