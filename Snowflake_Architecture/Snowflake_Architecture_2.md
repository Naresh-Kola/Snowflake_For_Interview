# Snowflake Architecture -- Complete Guide (Beginner to Pro)

**Covers:**
1. Three-Layer Architecture (every feature in each layer)
2. Shared-Disk vs Shared-Nothing vs Snowflake's Hybrid
3. Vertical Scaling vs Horizontal Scaling (Scale Up vs Scale Out)
4. Virtual Warehouses -- Deep Dive
5. Multiple Warehouses Running in Parallel
6. Query Lifecycle (from submission to result)
7. Interview Questions (Beginner -> Intermediate -> Pro)

---

# Section 1: Snowflake's Three-Layer Architecture

Snowflake has 3 FULLY INDEPENDENT layers:

```
+----------------------------------------------------------------------+
|   LAYER 3: CLOUD SERVICES LAYER            (The Brain)              |
|   Authentication, Security, Metadata, Query Optimization,            |
|   Access Control, Infrastructure Management, Result Cache            |
+----------------------------------------------------------------------+
|   LAYER 2: COMPUTE LAYER                   (The Muscle)             |
|   Virtual Warehouses -- independent compute clusters                 |
|   Each warehouse: CPU + RAM + Local SSD Cache                        |
+----------------------------------------------------------------------+
|   LAYER 1: STORAGE LAYER                   (The Memory)             |
|   Cloud object storage (S3 / Azure Blob / GCS)                      |
|   Data in micro-partitions, columnar, compressed, encrypted          |
+----------------------------------------------------------------------+
```

**Key Point:** Each layer scales INDEPENDENTLY.

---

## 1A. Storage Layer -- Every Feature Explained

Storage lives on cloud object storage: **AWS** -> S3, **Azure** -> Blob, **GCP** -> GCS.

### Feature 1: Micro-Partitions
- Every table auto-divided into immutable files (50-500 MB compressed)
- No manual partitioning -- Snowflake handles it
- Enables partition pruning via MIN/MAX metadata per column
- Enables parallel processing (MPP)

### Feature 2: Columnar Storage
- Data stored by COLUMN within each micro-partition
- Query reads ONLY needed columns (50-col table, 2-col query = 4% data read)
- Better compression (4x-10x), faster aggregations, vectorized execution

### Feature 3: Immutability
- Micro-partitions NEVER modified in place; UPDATE/DELETE creates NEW partitions
- Enables Time Travel, zero-copy cloning, consistent snapshots, crash recovery

### Feature 4: Automatic Compression
- Auto-selects best algorithm per column (Dictionary, Delta, LZ4/ZSTD)
- Typical 4x-10x compression; 1 TB raw -> ~150 GB stored

### Feature 5: Automatic Encryption
- AES-256 at rest, TLS 1.2+ in transit, always ON
- Tri-Secret Secure available (Business Critical Edition)

### Feature 6: Centralized Access
- Data stored ONCE; ALL warehouses read the SAME data
- No duplication; single source of truth

### Feature 7: Time Travel Storage
- Old partitions retained: Standard 0-1 day, Enterprise 0-90 days
- Then 7-day Fail-safe, then purged

### Feature 8: Zero-Copy Cloning
- Clone shares same micro-partitions; no extra storage until data diverges
- Works for tables, schemas, databases; instant even for 10 TB

---

## 1B. Compute Layer -- Every Feature Explained

### Feature 1: Virtual Warehouses
Named cluster of CPU + RAM + SSD cache. Does NOT store data.

| Size | Credits/Hour |
|---|---|
| XS | 1 |
| S | 2 |
| M | 4 |
| L | 8 |
| XL | 16 |
| 2XL | 32 |
| 3XL | 64 |
| 4XL | 128 |

### Feature 2: Auto-Suspend
Stops after idle period (configurable). Zero cost when suspended. SSD cache lost.
```sql
ALTER WAREHOUSE IF EXISTS COMPUTE_WH SET AUTO_SUSPEND = 60;
```

### Feature 3: Auto-Resume
Starts automatically when query arrives (1-2 seconds).
```sql
ALTER WAREHOUSE IF EXISTS COMPUTE_WH SET AUTO_RESUME = TRUE;
```

### Feature 4: Instant Resizing
Change size while running. No downtime. Running queries unaffected.
```sql
ALTER WAREHOUSE COMPUTE_WH SET WAREHOUSE_SIZE = 'XLARGE';
ALTER WAREHOUSE COMPUTE_WH SET WAREHOUSE_SIZE = 'SMALL';
```

### Feature 5: Workload Isolation
Each warehouse COMPLETELY independent. WH_ETL does NOT slow WH_ANALYTICS.

### Feature 6: Local SSD Cache
Caches recently scanned data. Per-warehouse. Lost on suspend.

### Feature 7: Multi-Cluster Warehouses (Enterprise Edition)
Multiple clusters (up to 300 for XS). AUTO-SCALE or MAXIMIZED mode. STANDARD or ECONOMY scaling policy.
```sql
CREATE WAREHOUSE WH_PEAK WITH
    WAREHOUSE_SIZE = 'MEDIUM'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 5
    SCALING_POLICY = 'STANDARD';
```

### Feature 8: Per-Second Billing
Minimum 60 seconds. After that, per second.

---

## 1C. Cloud Services Layer -- Every Feature Explained

Always running. Managed by Snowflake. Free if < 10% of daily compute.

- **Authentication & Security:** Login, MFA, SSO, network policies, OAuth, SCIM
- **Metadata Management:** MIN/MAX per column per partition, enables instant COUNT(*) and pruning
- **Query Parsing & Optimization:** AST, validation, execution plan, join strategy, pruning
- **Access Control (RBAC):** Roles, grants, column/row security, data masking
- **Result Cache:** 24-hour cache, same query+data = 0 seconds, per-user, invalidated on DML
- **Infrastructure Management:** Starts/stops warehouses, auto-upgrades (zero downtime)
- **Transaction Management:** ACID, concurrency control, commit/rollback

## Summary: 3 Caching Layers

| Cache Type | Where | Duration | Cost |
|---|---|---|---|
| Metadata Cache | Cloud Services | Permanent | Free |
| Result Cache | Cloud Services | 24 hours | Free |
| Warehouse Cache | Local SSD | While WH running | Part of compute |

---

# Section 2: Shared-Disk vs Shared-Nothing vs Snowflake's Hybrid

## 2A. Shared-Disk
All nodes share ONE central storage. Simple but storage bottleneck. (Oracle RAC, IBM DB2 pureScale)

## 2B. Shared-Nothing
Each node has OWN storage. Great performance but data redistribution on scale. (Teradata, Netezza, Redshift classic, Hadoop)

## 2C. Snowflake's Hybrid -- Best of Both
- **Shared-Disk Part:** All warehouses access SAME central cloud storage
- **Shared-Nothing Part:** Each warehouse is INDEPENDENT (no shared CPU/RAM/cache)

```
+--------------+  +--------------+  +--------------+
| Warehouse A  |  | Warehouse B  |  | Warehouse C  |
| CPU+RAM+SSD  |  | CPU+RAM+SSD  |  | CPU+RAM+SSD  |
+------+-------+  +------+-------+  +------+-------+
       |                 |                 |
       +-----------------+-----------------+
                         |
              +----------+----------+
              |   CENTRAL STORAGE   |
              |   (S3/Blob/GCS)     |
              +---------------------+
```

| Problem | Shared-Disk | Shared-Nothing | Snowflake |
|---|---|---|---|
| Storage bottleneck | Yes | No | No |
| Compute contention | Yes | No | No |
| Scale compute only | Hard | Impossible | Yes |
| Scale storage only | Hard | Impossible | Yes |
| Add nodes = reshuffle | No | Yes | No |
| Node failure = data loss | No | Yes | No |

---

# Section 3: Vertical Scaling vs Horizontal Scaling

## 3A. Scale Up (Vertical)
Change warehouse SIZE. Makes individual queries faster. Max 6XL.
```sql
ALTER WAREHOUSE COMPUTE_WH SET WAREHOUSE_SIZE = 'XLARGE';
```

## 3B. Scale Out (Horizontal)
Add more CLUSTERS. Handles more concurrent queries. Enterprise Edition.
```sql
CREATE WAREHOUSE WH_REPORTS WITH
    WAREHOUSE_SIZE = 'MEDIUM'
    MIN_CLUSTER_COUNT = 1
    MAX_CLUSTER_COUNT = 5
    SCALING_POLICY = 'STANDARD';
```

## 3C. Comparison

| Aspect | Scale Up | Scale Out |
|---|---|---|
| What changes | Warehouse SIZE | Number of CLUSTERS |
| Goal | Faster queries | More concurrent queries |
| Best for | Complex/large queries | High concurrency |
| Individual query | Faster | Same speed |
| Max limit | 6XL | Up to 300 clusters |
| Edition | Any | Enterprise+ |
| Analogy | Bigger bus | More buses |

---

# Section 4: Virtual Warehouse -- Deep Dive

```
+-----------------------------------------------+
|          VIRTUAL WAREHOUSE: WH_ANALYTICS      |
|          Size: MEDIUM (4 credits/hr)          |
|  +---------+  +---------+  +---------+       |
|  | Node 1  |  | Node 2  |  | Node 3  | ...  |
|  | CPU/RAM |  | CPU/RAM |  | CPU/RAM |      |
|  | SSD     |  | SSD     |  | SSD     |      |
|  +---------+  +---------+  +---------+      |
|  All nodes work TOGETHER on each query (MPP)  |
+-----------------------------------------------+
```

**Does:** Receives plan, fetches partitions, caches on SSD, processes query, returns results.
**Does NOT:** Store data, parse SQL, manage security, handle metadata.

**Naming:** "Warehouse" = "Virtual Warehouse" = COMPUTE cluster (NOT storage!).

---

# Section 5: Multiple Warehouses in Parallel

```
+----------------------------------------------------------------------+
|                     CLOUD SERVICES LAYER                            |
+-------+----------------------+----------------------+---------------+
        |                      |                      |
+-------+-------+    +--------+--------+    +--------+--------+
|  WH_ETL (XL)  |    |WH_ANALYTICS (M) |    |WH_DASHBOARD (S)|
+-------+-------+    +--------+--------+    +--------+--------+
        |                      |                      |
        +----------------------+----------------------+
                               |
                 +-------------+-------------+
                 |     CENTRAL STORAGE       |
                 +---------------------------+
```

1. **Complete Isolation** -- Each WH has own compute
2. **Shared Storage** -- All read same data, no duplication
3. **Independent Scaling** -- Each scales on its own
4. **No Contention** -- Cloud storage handles massive parallel reads
5. **Metadata Coordination** -- Consistency ensured by Cloud Services

---

# Section 6: Query Lifecycle

1. User submits SQL
2. Cloud Services authenticates
3. Cloud Services parses and validates SQL
4. Result Cache checked -> if HIT, return instantly
5. Query optimized, partitions pruned via metadata
6. Warehouse resumes if suspended
7. Warehouse fetches data (SSD cache first, then cloud storage)
8. Query executed in parallel across nodes (MPP)
9. Result cached and returned to user

```sql
SELECT
    QUERY_ID, QUERY_TEXT, EXECUTION_STATUS,
    TOTAL_ELAPSED_TIME / 1000 AS ELAPSED_SECONDS,
    BYTES_SCANNED / POWER(1024, 2) AS MB_SCANNED,
    PARTITIONS_SCANNED, PARTITIONS_TOTAL,
    PERCENTAGE_SCANNED_FROM_CACHE
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
ORDER BY START_TIME DESC LIMIT 5;
```

---

# Section 7: Interview Questions -- Beginner to Pro

## Beginner (0-1 Year)

**Q1: What is Snowflake's architecture?**
3-layer: Storage (cloud object storage, micro-partitions, columnar), Compute (virtual warehouses), Cloud Services (auth, metadata, optimization, result cache). All scale independently.

**Q2: What is a virtual warehouse?**
Named cluster of CPU + RAM + SSD cache that executes queries. Does NOT store data.

**Q3: What is a micro-partition?**
Immutable file of 50-500 MB (compressed), columnar, with metadata (min/max, row count) for pruning.

**Q4: What is partition pruning?**
Skipping partitions that can't match your WHERE clause by reading metadata.

**Q5: Warehouse vs database?**
Database = DATA. Warehouse = COMPUTE. Independent of each other.

**Q6: Warehouse sizes?**
XS=1, S=2, M=4, L=8, XL=16, 2XL=32, 3XL=64, 4XL=128 credits/hr.

**Q7: Auto-suspend and auto-resume?**
Suspend: stops after idle (zero cost). Resume: starts on query (1-2 sec).

**Q8: Columnar storage?**
Data stored by COLUMN. Reads only needed columns. Huge I/O reduction for analytics.

## Intermediate (1-3 Years)

**Q9: Shared-disk vs shared-nothing?**
Shared-disk: shared storage, bottleneck. Shared-nothing: own storage, redistribution pain. Snowflake: HYBRID (shared storage + isolated compute).

**Q10: Vertical vs horizontal scaling?**
Vertical: change SIZE (faster queries). Horizontal: add CLUSTERS (more concurrent queries).

**Q11: Multi-cluster warehouse?**
Multiple identical clusters, auto-scale on concurrency. Enterprise Edition.

**Q12: 3 caching layers?**
Metadata (permanent, free), Result (24hr, free), Warehouse SSD (while running).

**Q13: Cloud Services responsibilities?**
Auth, parsing, optimization, metadata, RBAC, result cache, infrastructure, transactions. Free < 10%.

**Q14: 10 warehouses query same table?**
All read independently. No locking. Full speed for all.

**Q15: Query lifecycle?**
Submit -> Auth -> Parse -> Cache -> Optimize/Prune -> Resume WH -> Fetch -> MPP Execute -> Return.

**Q16: Scale up vs out?**
UP for slow complex queries. OUT for too many concurrent queries.

## Advanced (3-5 Years)

**Q17: How does hybrid solve both problems?**
Cloud storage = no disk bottleneck. Central storage = no redistribution.

**Q18: Warehouse resize S to XL?**
New nodes for NEW queries. Running queries on old resources. Cache rebuilds. No downtime.

**Q19: Standard vs Economy scaling?**
Standard: starts clusters immediately (responsive). Economy: waits for 6-min workload (saves credits).

**Q20: Result cache invalidation?**
Invalidated on ANY DML to referenced tables. Per-user and per-role.

**Q21: What is spilling?**
Query exceeds memory -> spills RAM -> SSD -> remote storage. Scale UP or optimize.

**Q22: Operations without warehouse?**
SHOW, DESCRIBE, DDL, COUNT(*) from metadata, result cache hits, login.

## Pro / Architect (5+ Years)

**Q23: 200 analysts queuing at 9 AM?**
Multi-cluster (max=5, STANDARD). Separate heavy queries. Optimize common queries. Standardize for cache.

**Q24: Enterprise warehouse strategy?**
WH_ETL (XL, nightly), WH_ANALYTICS (M, multi-cluster), WH_ML (2XL, on-demand), WH_DASHBOARDS (S, multi-cluster). All read same storage.

**Q25: Cloud Services > 10%?**
Too many SHOW/DESCRIBE, frequent resume, heavy Snowpipe. Fix: increase auto-suspend, consolidate, optimize BI metadata queries.

**Q26: Query scans all partitions on 5B rows?**
SYSTEM$CLUSTERING_INFORMATION -> CLUSTER BY (low_card, date) -> wait for auto-clustering -> MV for repeated aggs -> sargable predicates.

**Q27: Storage during MERGE?**
Old partitions historical, new created. All retained for Time Travel. Metadata atomic. ACID compliant. Clustering reduces blast radius.

**Q28: Zero downtime upgrades?**
Rolling deployment. Cloud Services redundant. Running queries on old version. New queries on updated. Storage independent.

---

## Quick Revision -- One-Liners

| Concept | Summary |
|---|---|
| Storage Layer | Cloud object storage, micro-partitions, columnar, compressed, encrypted, centralized, immutable |
| Compute Layer | Virtual warehouses, independent clusters, local SSD cache, MPP execution, auto-scale |
| Cloud Services | Authentication, metadata, query optimization, result cache, RBAC, always running |
| Shared-Disk | All nodes share one storage -> bottleneck |
| Shared-Nothing | Each node owns its data -> redistribution pain |
| Snowflake Hybrid | Shared storage + isolated compute = best of both |
| Scale Up | Bigger warehouse (S->XL), faster queries |
| Scale Down | Smaller warehouse (XL->S), save credits |
| Scale Out | More clusters (1->5), more concurrent queries |
| Scale In | Fewer clusters (5->1), save credits |
| Virtual Warehouse | Compute cluster (NOT storage), named, independent |
| Multi-Cluster WH | Warehouse with multiple clusters, auto-scale |
| Query Lifecycle | Submit -> Auth -> Parse -> Cache Check -> Optimize -> Resume WH -> Fetch -> MPP -> Return |
