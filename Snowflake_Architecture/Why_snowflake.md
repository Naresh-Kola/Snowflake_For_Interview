# Before Snowflake -- What Existed, What Failed, and Why Snowflake Was Born

A Complete Guide to Pre-Snowflake Data Infrastructure

---

## Part 1: The Data Journey -- How Did Companies Store Data Before Snowflake?

Before Snowflake (founded 2012, GA 2015), companies went through multiple generations of data infrastructure:

| Era | Period | Technology |
|---|---|---|
| ERA 1 | 1970s-1990s | Flat Files & Spreadsheets |
| ERA 2 | 1980s-2000s | Traditional Databases (OLTP) |
| ERA 3 | 1990s-2010s | On-Premise Data Warehouses |
| ERA 4 | 2006-2015 | Hadoop / Big Data Ecosystem |
| ERA 5 | 2010-2015 | Cloud-Lifted Warehouses |
| ERA 6 | 2015-Present | Snowflake (Cloud-Native) |

Each era solved SOME problems but created NEW ones. Snowflake was built to solve ALL of them at once.

---

## Part 2: Era 1 -- Flat Files & Spreadsheets

### How It Worked

- Data stored in CSV files, Excel sheets, Access databases
- Each department maintained its own files
- No central source of truth

### Example

```
Sales team -> sales_jan.xlsx, sales_feb.xlsx
Finance    -> budget_2005.csv
Marketing  -> campaign_results.xls
```

### Disadvantages

1. **No single source of truth** -- Every department has different numbers
2. **Data silos** -- Sales says revenue is $10M, Finance says $9.5M
3. **No concurrency** -- Only one person can edit an Excel file at a time
4. **Size limits** -- Excel crashes beyond ~1M rows
5. **No security** -- Anyone with the file can see/change everything
6. **No audit trail** -- Who changed what? When? Nobody knows
7. **Manual ETL** -- Copy-paste between sheets = human errors

---

## Part 3: Era 2 -- Traditional Databases (OLTP Systems)

Companies moved to relational databases for transactional workloads.

### Popular Systems

- Oracle Database (1979)
- Microsoft SQL Server (1989)
- MySQL (1995)
- PostgreSQL (1996)
- IBM DB2 (1983)

### How It Worked

- Row-based storage optimized for INSERT/UPDATE/DELETE
- ACID transactions for data integrity
- SQL for querying
- Installed on company's own servers

### What They Solved

- Central data storage
- Concurrent access with locking
- Data integrity via constraints
- Security via users/roles

### Disadvantages for Analytics

1. **Row-based storage** -- Reads entire rows even if you need 2 columns
   ```sql
   SELECT AVG(salary) FROM employees;  -- Reads ALL columns, wastes I/O
   ```

2. **Slow for analytics** -- Designed for OLTP (small reads/writes), NOT for scanning millions of rows for reports

3. **Single server** -- One machine does everything: app transactions + reports + backups = resource contention

4. **Expensive licensing** -- Oracle/SQL Server licenses cost hundreds of thousands of dollars per year

5. **Schema rigidity** -- Changing a table structure = downtime + migration

6. **No separation of workloads** -- The same database serves:
   - App users doing transactions
   - Analysts running heavy reports
   - ETL jobs loading data
   - Result: Everyone slows everyone else down

---

## Part 4: Era 3 -- On-Premise Data Warehouses (The Big Shift)

To solve the analytics problem, companies built SEPARATE systems just for reporting and analysis.

### Popular Systems

- Teradata (1979) -- Pioneer of data warehousing
- Oracle Exadata (2008) -- Engineered system for Oracle
- IBM Netezza (2003) -- Appliance-based analytics
- Microsoft SQL Server (Analysis Services)
- SAP BW (Business Warehouse)
- Greenplum (2005) -- MPP on PostgreSQL
- Vertica (2005) -- Columnar analytics database

### How It Worked

1. Buy dedicated hardware (MPP appliances)
2. Install warehouse software
3. Build ETL pipelines (Informatica, DataStage, SSIS) to move data from OLTP to Warehouse
4. Create star/snowflake schemas
5. Users run reports and dashboards

### What They Solved

- Separated analytics from transactional systems
- Columnar storage for fast aggregations (Vertica, Netezza)
- MPP (Massively Parallel Processing) for large datasets
- Optimized for read-heavy analytical queries

### Disadvantages

#### 1. Storage + Compute Coupled

Data and processing live on the SAME machines. Want more storage? Buy more compute too (and vice versa). Teradata node = CPU + disk + memory as one unit. You CANNOT scale one without the other.

#### 2. Massive Upfront Cost

- Teradata: $500K to $10M+ just for hardware
- Oracle Exadata: $1M+ for a quarter rack
- Plus: data center space, power, cooling, networking
- Plus: DBA team salaries ($100K-$200K per DBA per year)

#### 3. Scaling Takes Weeks or Months

Need more capacity? Submit a purchase order -> wait for approval -> order hardware -> ship -> install -> configure -> migrate data. Total time: 3-6 months. Business can't wait that long.

#### 4. Concurrency Bottleneck

All users share the SAME compute resources. Monday morning: 200 analysts open dashboards simultaneously. ETL jobs running at the same time. Result: Queries queue up, timeouts, frustrated users.

#### 5. Vendor Lock-in

Data stored in proprietary formats. Teradata uses its own storage format -- you can't read it with Spark. Migration to another system = multi-year project.

#### 6. Maintenance Nightmare

DBAs must manually manage:
- Index creation and rebuilding
- Partition management
- Statistics collection (ANALYZE/COLLECT STATS)
- Workload management (priority queues)
- Backup and recovery
- Patching (often requires downtime)
- Space reclamation (VACUUM)
- Performance tuning (query plans, join strategies)

#### 7. Semi-Structured Data = Pain

JSON, XML, log files? Traditional warehouses can't handle them. You need separate ETL to flatten nested data into rows/columns. One schema change upstream = entire pipeline breaks.

#### 8. No Elasticity

Black Friday: need 10x compute for 3 days. You either over-provision (waste money 362 days/year) or under-provision (system crashes on peak days).

---

## Part 5: Era 4 -- Hadoop & Big Data Ecosystem (2006-2015)

Google published papers on MapReduce (2004) and GFS (2003). The open-source world built Hadoop based on those ideas.

### The Hadoop Ecosystem

- **HDFS** (Hadoop Distributed File System) -- distributed storage
- **MapReduce** -- distributed processing framework
- **Hive** (2010) -- SQL-like interface on top of Hadoop
- **Pig** -- scripting language for data transformation
- **HBase** -- NoSQL database on HDFS
- **Spark** (2014) -- faster alternative to MapReduce
- **Kafka** (2011) -- real-time data streaming
- **Presto/Trino** -- interactive SQL on Hadoop

### Why Companies Adopted Hadoop

- **Cheap storage** -- Store petabytes on commodity hardware
- **Schema-on-read** -- Store raw data first, structure later
- **Handles all data types** -- Structured, semi-structured, unstructured
- **Horizontal scaling** -- Just add more commodity servers
- **Open source** -- No licensing cost (but huge ops cost)

### Disadvantages

#### 1. Operational Complexity Is Extreme

A typical Hadoop cluster needs: NameNode, DataNode, ResourceManager, NodeManager, Zookeeper for coordination, Hive Metastore, YARN for resource management, Oozie for scheduling. A 50-node cluster needs a team of 5-10 engineers JUST to keep it running. Most companies spent more on operations than on the hardware itself.

#### 2. Slow for Interactive Queries

MapReduce writes intermediate results to disk. A simple `COUNT(*)` that takes 2 seconds in a warehouse could take 5-10 minutes in Hive on MapReduce. Analysts HATED waiting. They went back to Excel.

#### 3. No ACID Transactions (Initially)

UPDATE and DELETE not supported in early Hive. Hive ACID (v3) was buggy and slow. No data consistency guarantees for concurrent writes.

#### 4. Java-Heavy Development

Writing a MapReduce job = hundreds of lines of Java. Data analysts know SQL, not Java. Hive SQL was limited and slow.

#### 5. No Governance or Security (Initially)

Early Hadoop had no fine-grained access control. Apache Ranger and Sentry came later, but were complex. Auditing and compliance = manual effort.

#### 6. Data Quality Issues

"Data Swamp" -- companies dumped everything into HDFS with no schema enforcement. Finding reliable data became harder than the analysis itself.

#### 7. Cloud Killed the Cost Advantage

Hadoop's pitch: cheap commodity hardware. Cloud's pitch: no hardware at all. Running Hadoop on-premise still meant data centers, power, cooling, and a large engineering team.

---

## Part 6: Era 5 -- Cloud-Lifted Warehouses (2010-2015)

Existing vendors moved their on-premise products to the cloud. This is called "lift and shift" -- same architecture, hosted on cloud.

### Examples

- **Amazon Redshift** (2012) -- PostgreSQL-based, columnar, on AWS
- **Google BigQuery** (2010) -- Serverless, separated storage/compute
- **Azure SQL Data Warehouse** (2016) -> now Azure Synapse

### What They Solved

- No hardware to buy or manage
- Faster provisioning (minutes vs months)
- Some elasticity (resize clusters)
- Lower upfront cost (pay-as-you-go)

### Remaining Disadvantages

#### Amazon Redshift

1. Storage + compute still partially coupled (until RA3 nodes, 2019)
2. Concurrency limit -- struggled beyond 15-20 concurrent queries
3. Manual VACUUM and ANALYZE required
4. Resize operations = downtime (classic resize)
5. No native semi-structured data support (pre-SUPER type)
6. No time travel or zero-copy cloning (until recent updates)
7. Complex cluster management (node types, distribution keys, sort keys)

#### Google BigQuery

1. No traditional warehouse concepts (no indexes, no tuning knobs)
2. Slot-based pricing can be unpredictable
3. Limited UPDATE/DELETE performance
4. GCP-only (no multi-cloud)
5. Less control over compute resources

#### General Cloud-Lifted Issues

1. Still required deep DBA knowledge
2. Performance tuning was manual
3. Data sharing across accounts was not native
4. No true separation of storage and compute (for most)

---

## Part 7: The Complete Problem Summary -- Why Snowflake Was Needed

| Problem | ERA 1 Files | ERA 2 OLTP | ERA 3 On-Prem | ERA 4 Hadoop | ERA 5 Cloud DW |
|---|---|---|---|---|---|
| Storage-Compute Coupled | N/A | Yes | Yes | No | Partial |
| High Upfront Cost | No | Yes | Very High | Medium | No |
| Scaling Speed | N/A | Slow | Very Slow | Medium | Medium |
| Concurrency Issues | Yes | Yes | Yes | No | Yes |
| Operational Complexity | Low | Medium | High | Extreme | Medium |
| Semi-Structured Data Support | No | No | No | Yes | Limited |
| Data Sharing | Manual | No | No | No | Limited |
| Zero Maintenance | N/A | No | No | No | No |
| Multi-Cloud | N/A | No | No | No | No |
| Pay-Per-Second | N/A | No | No | No | No |
| Time Travel | No | No | No | No | No |
| Zero-Copy Cloning | No | No | No | No | No |

---

## Part 8: Enter Snowflake -- How It Solved Everything

- **Founded:** 2012 by Benoit Dageville, Thierry Cruanes, Marcin Zukowski
- **GA Launch:** June 2015
- **IPO:** September 2020 (largest software IPO at the time)

**Key Insight:** Don't fix old systems. Build a NEW one from scratch designed for the cloud from day one.

| Pre-Snowflake Problem | Snowflake Solution |
|---|---|
| Storage + Compute coupled | FULLY SEPARATED. Scale each independently. 10 warehouses can query the same data. |
| Massive upfront cost | $0 upfront. Pay per second of actual usage. Auto-suspend when idle. |
| Scaling takes weeks/months | Scale up/down in SECONDS. `ALTER WAREHOUSE SET SIZE = 'XL';` No downtime. No data migration. |
| Concurrency bottleneck | Each team gets its own virtual warehouse. ETL, analysts, and dashboards NEVER compete. |
| Extreme operational complexity | ZERO maintenance. No indexing, no vacuuming, no tuning. Snowflake handles everything via micro-partitions + pruning. |
| Semi-structured data pain | Native VARIANT type. Store and query JSON, Avro, Parquet, XML directly. No flattening needed. |
| No data sharing | Native Secure Data Sharing. Share LIVE data across accounts. No copying, no ETL. |
| Vendor lock-in | Multi-cloud: AWS, Azure, GCP. Choose your cloud and region. |
| No time travel | Built-in Time Travel (up to 90 days). Recover any mistake. |
| Expensive cloning | Zero-Copy Cloning. Instant copy without extra storage. |
| Manual maintenance required | Automatic micro-partitioning, automatic query optimization, automatic statistics, automatic caching (result + local disk). |
| No governance | Row/column-level security, data masking, access history, object tagging, data lineage. |

---

## Part 9: Real-World Migration Example

### Before (Teradata On-Premise)

- 50-node Teradata cluster
- $3M/year in hardware + licensing + support
- Team of 8 DBAs managing it
- 3-month lead time to add capacity
- 20 concurrent query limit before degradation
- ETL window: 11 PM - 5 AM (nobody else can query during load)

### After (Snowflake)

- 3 virtual warehouses (ETL=L, Analytics=M, Dashboard=S)
- ~$800K/year (60-70% cost reduction)
- 2 data engineers (no DBAs needed)
- Scale in 2 seconds when needed
- Unlimited concurrency (add more warehouses)
- ETL and queries run simultaneously, no blocking

### Example: How Snowflake Separates Workloads

```sql
CREATE WAREHOUSE IF NOT EXISTS WH_ETL
    WAREHOUSE_SIZE = 'LARGE'
    AUTO_SUSPEND = 120
    AUTO_RESUME = TRUE
    COMMENT = 'For data loading and transformation';

CREATE WAREHOUSE IF NOT EXISTS WH_ANALYTICS
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE
    COMMENT = 'For analyst queries and reports';

CREATE WAREHOUSE IF NOT EXISTS WH_DASHBOARD
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 30
    AUTO_RESUME = TRUE
    COMMENT = 'For BI dashboards with auto-refresh';
```

---

## Part 10: Comparison Summary -- All Eras at a Glance

| Aspect | Files/Excel | OLTP DB | On-Prem DW | Hadoop | Cloud DW | Snowflake |
|---|---|---|---|---|---|---|
| Era | 1970s-90s | 1980s-00s | 1990s-10s | 2006-15 | 2010-15 | 2015+ |
| Cost Model | Free/Low | License | $M upfront | Ops heavy | Pay-as-go | Per second |
| Setup Time | Minutes | Days | Months | Weeks | Hours | Minutes |
| Scalability | None | Vertical | Vertical | Horizontal | Limited | Instant |
| Maintenance | None | DBA team | Large team | Huge team | Medium team | Zero |
| Semi-struct | No | No | No | Yes | Limited | Native |
| Concurrency | 1 user | Limited | Limited | Good | Limited | Unlimited |
| Data Sharing | Email files | No | No | No | Limited | Native |
| Time Travel | No | No | No | No | No | Up to 90d |
| Multi-Cloud | N/A | No | No | No | Single | AWS/Azure/GCP |

---

## Part 11: Interview Questions -- Before Snowflake

**Q1: What existed before Snowflake for data warehousing?**
Companies used on-premise systems like Teradata, Oracle Exadata, IBM Netezza, and Greenplum. These were expensive MPP appliances that coupled storage and compute, required large DBA teams, and took months to scale.

**Q2: What was the biggest problem with traditional data warehouses?**
Storage and compute were tightly coupled. You couldn't scale one without scaling the other. This led to over-provisioning, high costs, and inability to handle variable workloads efficiently.

**Q3: Why didn't Hadoop replace traditional warehouses?**
Hadoop solved the storage cost problem but introduced extreme operational complexity. It was slow for interactive queries, lacked ACID transactions, required Java expertise, and needed large engineering teams just to keep clusters running.

**Q4: How is Snowflake different from Amazon Redshift?**
Snowflake fully separates storage and compute from day one. Multiple independent warehouses query the same data. No VACUUM or ANALYZE needed. Pay-per-second billing with auto-suspend. Native semi-structured data support. Multi-cloud (AWS/Azure/GCP).

**Q5: What is "lift and shift" in cloud migration?**
Moving an existing on-premise architecture to the cloud without redesigning it. Example: running the same Oracle database on an EC2 instance. It reduces hardware cost but doesn't solve architectural problems like coupled storage/compute.

**Q6: Why was Snowflake's architecture revolutionary?**
Snowflake was built from scratch for the cloud -- not an on-premise product moved to cloud. Its 3-layer architecture (Cloud Services + Compute + Storage) allows each layer to scale independently, enabling unlimited concurrency, instant scaling, and zero maintenance.

---

## Part 12: Quick Revision -- One-Liners

| System | Summary |
|---|---|
| Flat Files/Excel | No concurrency, no security, no scalability |
| OLTP Databases | Row-based, bad for analytics, single server |
| Teradata/Netezza | Expensive, coupled, slow to scale, vendor lock-in |
| Hadoop | Cheap storage, extreme complexity, slow queries |
| Redshift (early) | Cloud but still coupled, limited concurrency |
| BigQuery | Serverless but GCP-only, limited control |
| Snowflake | Cloud-native, separated, zero-maintenance, multi-cloud |
| **Key Takeaway** | **Snowflake didn't improve old systems -- it replaced them** |
