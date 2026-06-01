# Snowflake Table Types — Comparison Summary

| Feature | Permanent Table | Transient Table | Temporary Table | Iceberg Table | Event Table | Directory Table | Hybrid Table | External Table | Dynamic Table |
|---------|----------------|-----------------|-----------------|---------------|-------------|-----------------|--------------|----------------|---------------|
| **Purpose** | Standard analytics & warehousing | Intermediate/staging data without Fail-safe cost | Session-scoped scratch data | Open-format lakehouse tables (Apache Iceberg) | Telemetry collection (logs, traces, metrics) | File metadata layer on stages | Low-latency transactional (OLTP) workloads | Query data in external storage without loading | Auto-refreshing materialized transformations |
| **Persistence** | Permanent (until dropped) | Permanent (until dropped) | Session only (auto-dropped on session end) | Permanent (until dropped) | Permanent (until dropped) | Tied to stage lifecycle | Permanent (until dropped) | Permanent (until dropped) | Permanent (until dropped) |
| **Storage** | Columnar micro-partitions (Snowflake-managed) | Columnar micro-partitions (Snowflake-managed) | Columnar micro-partitions (Snowflake-managed) | Apache Iceberg format (Parquet + metadata) | Columnar micro-partitions (predefined schema) | Metadata index on stage files | Row-store (primary) + columnar (secondary) | External cloud storage (S3/GCS/Azure) | Columnar micro-partitions (Snowflake-managed) |
| **Schema** | User-defined | User-defined | User-defined | User-defined | Predefined (OpenTelemetry columns) | Predefined (path, size, URL, MD5, etc.) | User-defined (PK required) | User-defined (with file format) | User-defined (derived from SELECT or DML) |
| **Time Travel** | 0–90 days (Enterprise: up to 90) | 0–1 day only | 0–1 day only | 0–90 days (Snowflake-managed catalog) | 0–90 days | Not applicable | 0–1 day only | Not supported | 0–90 days |
| **Fail-safe** | 7 days | None | None | 7 days (Snowflake-managed catalog) | 7 days | Not applicable | None | Not supported | 7 days |
| **DML Support** | Full (INSERT, UPDATE, DELETE, MERGE) | Full (INSERT, UPDATE, DELETE, MERGE) | Full (INSERT, UPDATE, DELETE, MERGE) | Full (INSERT, UPDATE, DELETE, MERGE) | INSERT only (by Snowflake runtime) | None (read-only metadata) | Full (INSERT, UPDATE, DELETE, MERGE) | None (read-only) | None (system-managed refreshes) |
| **Constraints** | NOT NULL only enforced; PK/FK/UNIQUE not enforced | NOT NULL only enforced; PK/FK/UNIQUE not enforced | NOT NULL only enforced; PK/FK/UNIQUE not enforced | NOT NULL only enforced | None | None | PK enforced (required), FK enforced, UNIQUE enforced | None | Not enforced |
| **Indexes** | Search Optimization Service | Search Optimization Service | Search Optimization Service | Not supported | Not supported | Not applicable | Secondary indexes supported | Not supported | Not supported |
| **Clustering** | Supported | Supported | Supported | Supported (Snowflake-managed) | Not supported | Not applicable | Not supported | Not supported | Supported |
| **Cloning** | Supported | Supported | Supported | Supported (Snowflake-managed) | Supported | Not applicable | Not supported | Not supported | Supported (SELECT-based only) |
| **Replication** | Supported | Supported | Not supported | Supported (Snowflake-managed) | Supported | Not applicable | Not supported | Supported | Supported (SELECT-based only) |
| **Data Loading** | COPY INTO, Snowpipe, INSERT | COPY INTO, Snowpipe, INSERT | COPY INTO, INSERT | COPY INTO, INSERT, external engines | Auto-populated by Snowflake runtime | Auto-populated from stage files | INSERT, UPDATE, MERGE | Not loaded (reads in-place) | Auto-populated by refresh |
| **Billing** | Storage + compute | Storage + compute (no Fail-safe) | Storage + compute (session only) | Storage + compute | Storage + compute | Event notification costs (auto-refresh) | Storage (row + columnar) + compute | Compute only (storage external) | Storage + compute (refresh) |
| **Locking** | Partition/table-level | Partition/table-level | Partition/table-level | Partition/table-level | Partition/table-level | Not applicable | Row-level | Not applicable | Not applicable |
| **Access Pattern** | Large analytical scans | Large analytical scans | Large analytical scans | Interoperable analytics (multi-engine) | Observability queries | File discovery & URL access | Point lookups, small writes | Query external data in-place | Downstream pipeline queries |
| **CREATE Syntax** | `CREATE TABLE` | `CREATE TRANSIENT TABLE` | `CREATE TEMPORARY TABLE` | `CREATE ICEBERG TABLE` | `CREATE EVENT TABLE` | `DIRECTORY = (ENABLE=TRUE)` on stage | `CREATE HYBRID TABLE` | `CREATE EXTERNAL TABLE` | `CREATE DYNAMIC TABLE` |
| **Availability** | All editions, all regions | All editions, all regions | All editions, all regions | All editions, all regions | All editions, all regions | All editions, all regions | Enterprise+, AWS & Azure only | All editions, all regions | All editions, all regions |

---

## Quick Decision Guide

```
What's your use case?
│
├─ Standard analytics / data warehouse → PERMANENT TABLE
├─ Staging / ETL intermediate (save on Fail-safe cost) → TRANSIENT TABLE
├─ Session-scoped temp calculations → TEMPORARY TABLE
├─ Open lakehouse / multi-engine access → ICEBERG TABLE
├─ Logging / tracing / metrics from UDFs → EVENT TABLE
├─ Querying file metadata on stages → DIRECTORY TABLE
├─ Low-latency OLTP / app backend → HYBRID TABLE
├─ Query external storage without loading → EXTERNAL TABLE
└─ Auto-refreshing downstream transformations → DYNAMIC TABLE
```

---

## Key Trade-offs at a Glance

| Table Type | Storage Cost | Recovery (Time Travel + Fail-safe) | Write Latency | Read Latency | Best For |
|-----------|-------------|-----------------------------------|---------------|-------------|----------|
| Permanent | Standard | Up to 90 + 7 days | Milliseconds (batch) | Fast scans | Core warehouse tables |
| Transient | Lower (no Fail-safe) | Up to 1 day only | Milliseconds (batch) | Fast scans | ETL staging |
| Temporary | Minimal (session-only) | Up to 1 day only | Milliseconds (batch) | Fast scans | Scratch/temp work |
| Iceberg | Standard + metadata overhead | Up to 90 + 7 days | Milliseconds (batch) | Fast scans | Multi-engine lakehouse |
| Event | Standard | Up to 90 + 7 days | Auto (system writes) | Fast scans | Observability |
| Directory | Negligible (metadata only) | Not applicable | Not applicable | Fast lookups | File catalogs |
| Hybrid | Higher (dual storage) | Up to 1 day only | Sub-millisecond (single row) | Sub-millisecond (point) | OLTP apps |
| External | None (data stays external) | Not available | Not applicable | Higher (external I/O) | Query without loading |
| Dynamic | Standard | Up to 90 + 7 days | Depends on TARGET_LAG | Fast scans | Pipeline automation |
