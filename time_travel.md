# Time Travel Internals -- How It REALLY Works Under the Hood

Deep dive into: Files, Data, Metadata, Partition Maps, Snapshots, and the complete internal lifecycle with examples

---

# Part 1: The Foundation -- Immutable Micro-Partitions

To understand Time Travel, you MUST first understand that Snowflake NEVER modifies a file once it's written. This is the key.

Every table in Snowflake is made up of micro-partition files:
- Each file: 50-500 MB compressed
- Stored as columnar, compressed, encrypted files in cloud storage
- Each file has a UNIQUE ID (like: MP_001, MP_002, etc.)
- Once written -> NEVER changed -> IMMUTABLE

**What does "immutable" mean in practice?**

- When you INSERT data -> new files are CREATED
- When you UPDATE data -> old files are REPLACED by new files
- When you DELETE data -> old files are REPLACED by new files (without deleted rows)

BUT THE OLD FILES ARE NOT DELETED. They are kept around. THIS is what enables Time Travel.

---

# Part 2: Table State = A List of File Pointers (Not the Files Themselves)

A table in Snowflake is NOT "a collection of files." A table is a METADATA POINTER to a SET of active micro-partition files.

```
+---------------------------------------------------------------------+
|  TABLE: ORDERS                                                      |
|  Current State (Version 5):                                         |
|    Active Files: [MP_003, MP_007, MP_012, MP_015, MP_018]           |
|                                                                     |
|  Cloud Services (Metadata) knows:                                   |
|    - Which files make up the CURRENT version                        |
|    - Which files made up EVERY PREVIOUS version                     |
|    - When each version was created                                  |
|    - What DML statement created each version                        |
+---------------------------------------------------------------------+
```

**Real-Life Analogy:**

Think of a PHOTO ALBUM app (like Google Photos). Your album "Vacation 2025" contains 10 photos. You delete 2 photos from the album. The photos still exist in "Trash" (not permanently deleted). The album NOW shows 8 photos -- but the 2 are recoverable.

In Snowflake:
- Album = Table metadata (list of active file pointers)
- Photos = Micro-partition files (immutable, stored in cloud storage)
- Trash = Historical files (retained for Time Travel)

---

# Part 3: Metadata -- The Brain Behind Time Travel

The Cloud Services layer stores RICH METADATA for every micro-partition. This metadata is what makes Time Travel possible WITHOUT scanning data.

```
+---------------------------------------------------------------------+
|  METADATA STORED PER MICRO-PARTITION FILE                           |
+---------------------------------------------------------------------+
|                                                                     |
|  1. FILE IDENTITY                                                   |
|     - Unique file ID (internal identifier)                          |
|     - Cloud storage path (S3/Azure/GCS location)                    |
|     - File size (compressed bytes)                                  |
|     - Encryption key reference                                      |
|                                                                     |
|  2. COLUMN-LEVEL STATISTICS                                         |
|     - MIN value per column                                          |
|     - MAX value per column                                          |
|     - Number of DISTINCT values per column                          |
|     - Number of NULL values per column                              |
|     - Total row count in this partition                             |
|                                                                     |
|  3. LIFECYCLE INFORMATION (KEY FOR TIME TRAVEL)                     |
|     - Created timestamp (when this file was written)                |
|     - Created by which DML statement (query ID)                     |
|     - Marked-deleted timestamp (when this file was superseded)      |
|     - Marked-deleted by which DML statement (query ID)              |
|     - Current state: ACTIVE | TIME_TRAVEL | FAIL_SAFE | PURGED     |
|                                                                     |
+---------------------------------------------------------------------+
```

**This is the secret:** Snowflake doesn't keep "snapshots" of the entire table. It keeps the LIFECYCLE of every individual file. To reconstruct the table at ANY point in time, Snowflake asks: "Which files were ACTIVE at that timestamp?" This is a METADATA-ONLY operation. No data scanning needed.

---

# Part 4: Complete Internal Walkthrough -- INSERT, UPDATE, DELETE

## Step 1: CREATE TABLE and INSERT DATA

```sql
CREATE TABLE ORDERS (
    ORDER_ID    INT,
    CUSTOMER    VARCHAR,
    AMOUNT      NUMBER(10,2),
    STATUS      VARCHAR,
    ORDER_DATE  DATE
) DATA_RETENTION_TIME_IN_DAYS = 7;
```

After inserting 1 million rows, Snowflake creates micro-partition files:

```
AFTER INSERT (Version 1) -- Timestamp: 2026-04-28 10:00:00

Cloud Storage (S3/Azure/GCS):
  +----------------------+  +----------------------+
  |  File: MP_001        |  |  File: MP_002        |
  |  Rows: 500,000       |  |  Rows: 500,000       |
  |  Size: 120 MB comp.  |  |  Size: 115 MB comp.  |
  |  ORDER_ID: 1-500K    |  |  ORDER_ID: 500K-1M   |
  |  CUSTOMER: A-M       |  |  CUSTOMER: N-Z        |
  |  STATUS: all NEW     |  |  STATUS: all NEW      |
  |  ORDER_DATE: Jan-Jun |  |  ORDER_DATE: Jul-Dec  |
  +----------------------+  +----------------------+

Metadata (Cloud Services Layer):
  Table ORDERS -> Active Files: [MP_001, MP_002]
  MP_001: created=10:00, created_by=INSERT_QID_001, deleted=NULL
  MP_002: created=10:00, created_by=INSERT_QID_001, deleted=NULL
  MP_001 column stats:
    ORDER_ID: min=1, max=500000, distinct=500000, nulls=0
    CUSTOMER: min='Aaron', max='Mike', distinct=45000, nulls=0
    AMOUNT: min=10.00, max=9999.99
    STATUS: min='NEW', max='NEW', distinct=1
    ORDER_DATE: min=2026-01-01, max=2026-06-30
```

**Version History:**
- Version 1 (10:00) = [MP_001, MP_002] <- current & only version

---

## Step 2: UPDATE -- This Is Where It Gets Interesting

At 2:00 PM, someone runs:
```sql
UPDATE ORDERS SET STATUS = 'SHIPPED' WHERE ORDER_ID BETWEEN 100 AND 200;
```

**What happens internally:**

1. Cloud Services PARSES the SQL and creates an execution plan
2. Cloud Services checks METADATA to find which files contain ORDER_ID between 100 and 200:
   - MP_001: ORDER_ID min=1, max=500000 -> MIGHT contain rows 100-200 (scan needed)
   - MP_002: ORDER_ID min=500001, max=1000000 -> CANNOT contain them (PRUNED)
3. Warehouse reads MP_001 from cloud storage
4. Warehouse processes the update:
   - Reads ALL rows from MP_001 (500,000 rows)
   - Changes STATUS to 'SHIPPED' for rows 100-200 (101 rows)
   - Writes ALL 500,000 rows (with 101 modified) to a NEW file: MP_003
5. Cloud Services updates metadata:
   - MP_001: marked-deleted = 14:00, deleted_by = UPDATE_QID_002
   - MP_003: created = 14:00, created_by = UPDATE_QID_002
   - Table ORDERS -> Active Files: [MP_003, MP_002]

```
AFTER UPDATE (Version 2) -- Timestamp: 2026-04-28 14:00:00

Cloud Storage:
  MP_001  [TIME_TRAVEL]  <- STILL EXISTS! Not deleted. Historical.
  MP_003  [ACTIVE]       <- NEW file replacing MP_001 (101 rows modified)
  MP_002  [ACTIVE]       <- UNTOUCHED (not involved in UPDATE)

Metadata:
  Table ORDERS -> Active Files: [MP_003, MP_002]
  MP_001: created=10:00, deleted=14:00  (TIME_TRAVEL state)
  MP_002: created=10:00, deleted=NULL   (ACTIVE)
  MP_003: created=14:00, deleted=NULL   (ACTIVE)
```

**Version History:**
- Version 1 (10:00) = [MP_001, MP_002] <- historical (Time Travel)
- Version 2 (14:00) = [MP_003, MP_002] <- current

---

## Step 3: DELETE -- Another New Version

At 4:00 PM, someone runs:
```sql
DELETE FROM ORDERS WHERE ORDER_DATE < '2026-04-01';
```

**What happens:**

1. Cloud Services checks metadata:
   - MP_003: ORDER_DATE min=Jan, max=Jun -> contains dates < Apr (scan needed)
   - MP_002: ORDER_DATE min=Jul, max=Dec -> does NOT contain dates < Apr (PRUNED)
2. Warehouse reads MP_003 (500,000 rows), filters out rows where ORDER_DATE < 2026-04-01
   - 250,000 rows deleted, 250,000 remain
   - Writes remaining 250,000 rows to NEW file: MP_004
3. Metadata updated:
   - MP_003: deleted=16:00, deleted_by=DELETE_QID_003
   - MP_004: created=16:00, created_by=DELETE_QID_003
   - Table ORDERS -> Active Files: [MP_004, MP_002]

```
AFTER DELETE (Version 3) -- Timestamp: 2026-04-28 16:00:00

Cloud Storage (ALL files still exist):
  MP_001  [TIME_TRAVEL] created=10:00, deleted=14:00
  MP_002  [ACTIVE]      created=10:00, deleted=NULL
  MP_003  [TIME_TRAVEL] created=14:00, deleted=16:00
  MP_004  [ACTIVE]      created=16:00, deleted=NULL

Active table state: [MP_004, MP_002]
```

**Version History:**
- Version 1 (10:00) = [MP_001, MP_002] <- Time Travel
- Version 2 (14:00) = [MP_003, MP_002] <- Time Travel
- Version 3 (16:00) = [MP_004, MP_002] <- Current

---

# Part 5: How Time Travel Queries Work Internally

### Query 1: "Show me data from 11:00 AM"

```sql
SELECT * FROM ORDERS AT(TIMESTAMP => '2026-04-28 11:00:00'::TIMESTAMP_TZ);
```

**Internal process:**

1. Cloud Services receives the Time Travel query
2. Cloud Services looks at the VERSION HISTORY in metadata
3. Asks: "At 11:00 AM, which files were ACTIVE?"
   - MP_001: created=10:00, deleted=14:00 -> ACTIVE at 11:00 (yes)
   - MP_002: created=10:00, deleted=NULL -> ACTIVE at 11:00 (yes)
   - MP_003: created=14:00 -> didn't exist yet at 11:00 (no)
   - MP_004: created=16:00 -> didn't exist yet at 11:00 (no)
4. Result: Table at 11:00 = [MP_001, MP_002] -> This is Version 1
5. Warehouse reads MP_001 and MP_002 -> returns the original data

**The Formula:**

A file is ACTIVE at time T if:
```
file.created_timestamp <= T AND (file.deleted_timestamp > T OR file.deleted_timestamp IS NULL)
```

This is PURE METADATA. No scanning of actual data files to determine which version to read.

### Query 2: "Show me data from 3:00 PM"

```sql
SELECT * FROM ORDERS AT(TIMESTAMP => '2026-04-28 15:00:00'::TIMESTAMP_TZ);
```

**Internal:**
- MP_001: created=10:00, deleted=14:00 -> NOT active at 15:00
- MP_002: created=10:00, deleted=NULL -> ACTIVE at 15:00
- MP_003: created=14:00, deleted=16:00 -> ACTIVE at 15:00
- MP_004: created=16:00 -> didn't exist yet
- Result: [MP_003, MP_002] -> Version 2 (after UPDATE)

### Query 3: "Show me data BEFORE the DELETE statement"

```sql
SELECT * FROM ORDERS BEFORE(STATEMENT => 'DELETE_QID_003');
```

**Internal:** Cloud Services looks up DELETE_QID_003 -> completed at 16:00. "BEFORE" means just before 16:00. Resolves same as AT(TIMESTAMP => 15:59:59.999...). Result: [MP_003, MP_002] -> Version 2.

---

# Part 6: Complete File Lifecycle -- From Birth to Purge

Every micro-partition file goes through these states:

```
+----------+
|  CREATED  |  File written by INSERT/UPDATE/DELETE/MERGE/COPY
+-----+----+
      |
      v
+----------+
|  ACTIVE   |  Part of the current table state
|           |  Metadata: deleted_timestamp = NULL
|           |  Duration: Until the next DML changes this data
+-----+----+
      |  (DML creates new file, this one is superseded)
      v
+--------------+
| TIME TRAVEL   |  Historical but still accessible
|               |  Metadata: deleted_timestamp = SET
|               |  Duration: DATA_RETENTION_TIME_IN_DAYS
|               |    Standard: 0-1 day, Enterprise: 0-90 days
|               |  User can query, clone, undrop
+-----+--------+
      |  (Retention period expires)
      v
+--------------+
|  FAIL-SAFE    |  Only Snowflake Support can access
|               |  Duration: EXACTLY 7 days (not configurable)
|               |  Only for PERMANENT tables
|               |  Transient/Temporary tables skip this stage
+-----+--------+
      |  (7 days expire)
      v
+--------------+
|   PURGED      |  PERMANENTLY deleted from cloud storage
|               |  Cannot be recovered by anyone
|               |  Storage freed, billing stops
+--------------+
```

### Applying This to Our Example (7-day retention)

**File MP_001:**
- Created: Apr 28, 10:00 (by INSERT)
- Deleted: Apr 28, 14:00 (superseded by UPDATE)
- Time Travel: Apr 28, 14:00 -> May 5, 14:00 (7 days)
- Fail-safe: May 5, 14:00 -> May 12, 14:00 (7 more days)
- Purged: May 12, 14:00 -> file permanently deleted from S3

**File MP_002:**
- Created: Apr 28, 10:00 (by INSERT)
- Deleted: NEVER (still active, never superseded)
- Will enter Time Travel only when a future DML affects it

**File MP_003:**
- Created: Apr 28, 14:00 (by UPDATE)
- Deleted: Apr 28, 16:00 (superseded by DELETE)
- Time Travel: Apr 28, 16:00 -> May 5, 16:00
- Fail-safe: May 5, 16:00 -> May 12, 16:00
- Purged: May 12, 16:00

---

# Part 7: Visual Timeline -- Files Across Time

```
                10:00        14:00        16:00          May 5     May 12
 TIME ----------+------------+------------+--------------+---------+-------->
                |            |            |              |         |
 MP_001  -------[===ACTIVE===]            |              |         |
                |            [==TIME TRAVEL (7 days)=====]         |
                |            |            |              [=FAILSAFE]
                |            |            |              |         [PURGED]
                |            |            |              |         |
 MP_002  -------[==================ACTIVE (never changed)===================>
                |            |            |              |         |
 MP_003         |            [===ACTIVE===]              |         |
                |            |            [==TIME TRAVEL (7d)=====]|
                |            |            |              [=FAILSAFE]
                |            |            |              |         [PURGED]
                |            |            |              |         |
 MP_004         |            |            [=========ACTIVE==================>
                |            |            |              |         |
 TABLE VERSION: V1          V2           V3            V3        V3
 Active files: [001,002]  [003,002]    [004,002]    [004,002]  [004,002]
```

**Key Insight:** At ANY point on this timeline, Snowflake can reconstruct the table by looking at which files were ACTIVE at that moment. This requires ZERO data scanning -- just metadata lookups.

---

# Part 8: DROP TABLE & UNDROP -- Internal Mechanics

### What Happens When You DROP a Table?

```sql
DROP TABLE ORDERS;
```

**Internally:**
1. Cloud Services does NOT delete any files from cloud storage
2. It marks the TABLE METADATA as "dropped" with a timestamp
3. ALL files (active + time travel) are retained
4. The table entry moves to "dropped objects" catalog

```
AFTER DROP TABLE -- Timestamp: 2026-04-28 18:00:00

Table Metadata:
  ORDERS -> status: DROPPED, dropped_at: 18:00
  Last active files: [MP_004, MP_002]
  All historical files still exist: [MP_001, MP_003]

Cloud Storage: ALL 4 files still physically exist
  MP_001 [TIME_TRAVEL]
  MP_002 [RETAINED for DROP recovery]
  MP_003 [TIME_TRAVEL]
  MP_004 [RETAINED for DROP recovery]
```

### UNDROP

```sql
UNDROP TABLE ORDERS;
```

**Internally:**
1. Cloud Services finds the most recently dropped version of ORDERS
2. Restores the table metadata pointer
3. Table becomes active again with the same files
4. NO data is moved, copied, or recreated
5. It's a METADATA-ONLY operation -- takes milliseconds

**Key:** UNDROP is instant because files were NEVER deleted from storage.

**What if retention expires after DROP?**
```sql
DROP TABLE ORDERS;  -- at 18:00, retention = 1 day
-- wait 2 days --
UNDROP TABLE ORDERS;  -- FAILS! Retention expired.
```
The files have moved to Fail-safe -> only Snowflake Support can help.

---

# Part 9: TRUNCATE TABLE -- Different from DELETE

| Operation | Files Affected | New Files Created | Cost |
|---|---|---|---|
| DELETE (with WHERE) | Only files with matching rows | New files with remaining rows | Proportional to rows changed |
| DELETE (no WHERE) | ALL files | None (table is now empty) | ALL files retained in TT |
| TRUNCATE | ALL files | None (table is now empty) | ALL files retained in TT |

For TRUNCATE and full-table DELETE: ALL micro-partitions enter Time Travel simultaneously. A 1 TB table -> 1 TB in Time Travel + 1 TB in Fail-safe later. This is why TRUNCATE on large tables can be EXPENSIVE for storage.

**Example Storage Impact:**
- Table: 500 GB, retention: 30 days
- `TRUNCATE TABLE orders;`
- Day 1-30: 500 GB in Time Travel (you can recover)
- Day 31-37: 500 GB in Fail-safe (only Snowflake Support)
- Day 38: 500 GB purged. Storage freed.
- Total extra cost: 500 GB x 37 days of storage

---

# Part 10: Clone + Time Travel -- Internal File Sharing

```sql
CREATE TABLE ORDERS_BACKUP CLONE ORDERS
    AT(OFFSET => -7200);  -- Clone from 2 hours ago
```

**What happens internally:**

1. Cloud Services resolves "2 hours ago" = which files were active then
2. Creates NEW table metadata (ORDERS_BACKUP) pointing to those files
3. NO files are copied. Both tables point to the SAME physical files.

```
AFTER CLONE AT(OFFSET => -7200)

Table ORDERS (current):
  Active Files: [MP_004, MP_002]

Table ORDERS_BACKUP (cloned from 2 hrs ago = Version 2):
  Active Files: [MP_003, MP_002]  <- shared files, no copies!

Cloud Storage:
  MP_002 -> shared by BOTH tables (zero extra storage)
  MP_003 -> owned by ORDERS_BACKUP (was in TT only,
            now also actively referenced by the clone)
  MP_004 -> owned by ORDERS only

Storage cost of clone: ~0 (all files are shared/referenced)
```

**When does the clone start costing storage?**

Only when you MODIFY data in either ORDERS or ORDERS_BACKUP. The modification creates NEW files owned by that specific table.

```sql
INSERT INTO ORDERS_BACKUP VALUES (999, 'Test', 10.00, 'NEW', '2026-04-28');
-- Creates MP_005, owned exclusively by ORDERS_BACKUP
-- MP_005 consumes storage, but shared files still don't duplicate
```

---

# Part 11: What Metadata Does NOT Track (Limitations)

Time Travel does NOT preserve:

1. **DDL Changes (Schema History)** -- If you DROP a column today and Time Travel to yesterday, the current schema (without the dropped column) is used. The column is NOT visible. **Workaround:** Use CLONE instead of SELECT for DDL recovery: `CREATE TABLE recovered CLONE my_table BEFORE(STATEMENT => '<drop_col_qid>');`

2. **Constraint History** -- Constraints use current definitions, not historical ones.

3. **Grant / Privilege History** -- Access control always uses current grants, not historical.

4. **External Table Data** -- External tables have NO Time Travel (data is outside Snowflake).

5. **Stages** -- Internal stages have NO Time Travel for staged files.

---

# Part 12: How Storage Billing Works with Time Travel

**You pay for ALL files in ALL states (except PURGED):**

Total Storage = Active Files + Time Travel Files + Fail-safe Files

```
STORAGE BREAKDOWN FOR OUR EXAMPLE TABLE
On Apr 28 at 17:00 (after all DML):

ACTIVE files:
  MP_002: 115 MB  (still active, never modified)
  MP_004: 60 MB   (250K rows after DELETE)
  Active total: 175 MB

TIME TRAVEL files:
  MP_001: 120 MB  (superseded by UPDATE at 14:00)
  MP_003: 120 MB  (superseded by DELETE at 16:00)
  Time Travel total: 240 MB

FAIL-SAFE files: 0 MB (nothing has expired from TT yet)

TOTAL BILLED: 175 + 240 + 0 = 415 MB
(vs 175 MB if Time Travel didn't exist)
```

### Monitor Your Time Travel Storage

```sql
SELECT
    TABLE_NAME,
    ROUND(ACTIVE_BYTES / POWER(1024,3), 3)      AS ACTIVE_GB,
    ROUND(TIME_TRAVEL_BYTES / POWER(1024,3), 3)  AS TIME_TRAVEL_GB,
    ROUND(FAILSAFE_BYTES / POWER(1024,3), 3)     AS FAILSAFE_GB,
    ROUND((ACTIVE_BYTES + TIME_TRAVEL_BYTES + FAILSAFE_BYTES)
          / POWER(1024,3), 3)                    AS TOTAL_GB,
    ROUND(TIME_TRAVEL_BYTES / NULLIF(ACTIVE_BYTES,0), 2) AS TT_TO_ACTIVE_RATIO
FROM SNOWFLAKE.ACCOUNT_USAGE.TABLE_STORAGE_METRICS
WHERE ACTIVE_BYTES > 0
  AND CATALOG_DROPPED IS NULL
ORDER BY TOTAL_GB DESC
LIMIT 20;
```

---

# Part 13: Micro-Partition Defragmentation -- Hidden Time Travel Cost

When you load data via INSERT, COPY, or Snowpipe, Snowflake may create SMALL micro-partitions (under 50 MB). A background process called DEFRAGMENTATION merges small partitions into larger ones.

**How it works:**
1. You run 10 small INSERTs, each creating a tiny file
2. Background: Snowflake merges them into 1 optimal partition
3. The 10 small files are marked as deleted -> enter Time Travel
4. The 1 new merged file becomes the active file

**This means:** Even without explicit DML, TIME_TRAVEL_BYTES can be > 0 because defragmentation creates historical files.

**From Snowflake Docs:** "TIME_TRAVEL_BYTES and FAILSAFE_BYTES will incur charges when you load data using INSERT, COPY or SNOWPIPE. That's because small micro-partition defragmentation deletes small micro-partitions and creates a new micro-partition that has the same data."

---

# Part 14: Putting It All Together -- Complete Internal Flow

**User runs:** `SELECT * FROM ORDERS AT(OFFSET => -3600);`

### Step 1: Cloud Services -- Parse & Validate
- Parse SQL, identify AT clause
- Calculate target timestamp: NOW() - 3600 seconds
- Check: Is target within retention period? Yes -> proceed
- Check: Does user have SELECT on ORDERS? Yes -> proceed

### Step 2: Cloud Services -- Resolve Historical File Set
- Read FILE LIFECYCLE METADATA for table ORDERS
- For each file, check: `file.created <= target_time AND (file.deleted > target_time OR file.deleted IS NULL)`
- Build list of files that were ACTIVE at target time
- Example result: [MP_003, MP_002]
- **THIS IS METADATA-ONLY. No data files are read yet.**

### Step 3: Cloud Services -- Optimize & Prune
- Apply any WHERE clause filters using column-level metadata
- Prune files that don't match (via MIN/MAX ranges)
- Create execution plan for the warehouse

### Step 4: Warehouse -- Fetch & Execute
- Receives the file list and execution plan
- Reads the HISTORICAL files from cloud storage (same as reading current files -- just different file IDs)
- Checks local SSD cache first (historical files can be cached!)
- Processes query: filter, aggregate, sort, etc.
- Returns results

### Step 5: Result -- Delivered to User
- Results use CURRENT schema (today's column definitions)
- Result cached for 24 hours (if same TT query repeats)
- Query logged in QUERY_HISTORY

**Performance Note:** Time Travel queries are NOT slower than normal queries. The only difference is which files are read. If the historical files are in the warehouse's SSD cache -> same speed. If not -> one fetch from cloud storage, then cached.

---

# Part 15: Summary -- The 5 Key Insights

1. **Files Are Immutable** -- Snowflake never modifies a file. Every DML creates NEW files. Old files are kept for Time Travel. This is the foundation.

2. **Table = Metadata Pointer, Not Files** -- A table is just a list of "which files are currently active." Changing the table = changing the pointer, not the files.

3. **Time Travel = Reading Old Pointers** -- To query the past, Snowflake looks up which files were active at that time. Pure metadata operation. No data scanning to find the right version.

4. **Every File Has a Lifecycle** -- ACTIVE -> TIME_TRAVEL -> FAIL_SAFE -> PURGED. You pay storage for all states except PURGED.

5. **Metadata Makes It Fast** -- Per-file lifecycle timestamps + per-column statistics enable: instant version resolution, partition pruning on historical data, and zero overhead for Time Travel (no extra copies, no snapshots).

---

## Quick Reference -- Internal Terms

| Term | Definition |
|---|---|
| Micro-partition | Immutable 50-500 MB compressed columnar file |
| File lifecycle | CREATED -> ACTIVE -> TIME_TRAVEL -> FAIL_SAFE -> PURGED |
| Table version | A metadata pointer to a set of active files |
| Version resolution | Finding which files were active at timestamp T |
| Defragmentation | Background merge of small files into optimal ones |
| Retained file | Historical file kept for Time Travel or Fail-safe |
| Clone file sharing | Two tables pointing to the same physical files |
| Purge | Permanent deletion of file from cloud storage |
