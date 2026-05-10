# LOG-BASED CDC (TRANSACTION LOG CHANGE DATA CAPTURE)

Complete Guide with Deep Explanations

---

## 1. WHAT IS LOG-BASED CDC?

Log-Based CDC = Reading the database's **TRANSACTION LOG** (redo log, WAL, binlog) to capture every change (INSERT, UPDATE, DELETE) as it happens.

Every relational database maintains a transaction log:
- **Oracle**: Redo Logs / Archive Logs
- **SQL Server**: Transaction Log (tlog)
- **PostgreSQL**: Write-Ahead Log (WAL)
- **MySQL**: Binary Log (binlog)
- **Greenplum**: WAL segments

These logs record EVERY DML operation for crash recovery purposes. Log-based CDC "taps into" these logs to extract change events.

### HOW IT WORKS:
1. Application writes to source database (INSERT/UPDATE/DELETE)
2. Database writes the change to its transaction log
3. CDC tool (Debezium, Oracle GoldenGate, AWS DMS, etc.) reads the log
4. Tool converts log entries into change events
5. Events are delivered to target (Kafka, S3, Snowflake, etc.)

### SIMPLE ANALOGY:
- Database = Office building
- Transaction log = Security camera recording
- Log-based CDC = Watching the security footage to know who entered, left, or moved between rooms
- You see EVERYTHING that happened, in exact order

### vs Time-Based CDC:
- Time-based = Checking attendance register every hour
- You see who's present NOW, but don't know about someone who came and left between checks

---

## 2. WHY LOG-BASED CDC EXISTS

### PROBLEMS WITH TIME-BASED CDC:
1. Cannot detect DELETEs
2. Cannot capture intermediate changes
3. Requires source table modification (add updated_at)
4. Has latency (batch-based)
5. Can miss data during race conditions

### LOG-BASED CDC SOLVES ALL OF THESE:
- ✓ Captures DELETEs (log records every DELETE statement)
- ✓ Captures EVERY intermediate state (all changes in order)
- ✓ No source table modification needed (reads logs, not tables)
- ✓ Near real-time (reads log as it's written)
- ✓ No race conditions (sequential log reading)

---

## 3. LOG-BASED CDC TOOLS BY DATABASE

| SOURCE DATABASE    | LOG-BASED CDC TOOLS |
|---|---|
| Oracle             | Oracle GoldenGate, Oracle LogMiner, Debezium, AWS DMS, Attunity/Qlik Replicate, IICS CDC |
| SQL Server         | SQL Server CDC (native), Debezium, AWS DMS, Qlik Replicate, IICS CDC |
| PostgreSQL         | Debezium (pgoutput/wal2json), AWS DMS, Fivetran, IICS CDC |
| MySQL              | Debezium (binlog), Maxwell, AWS DMS, Canal, IICS CDC |
| Greenplum          | AWS DMS (limited), custom WAL reader, IICS CDC (via JDBC) |
| MongoDB            | Debezium (oplog/change streams), AWS DMS |
| Snowflake (source) | Snowflake Streams (native, not log-based but equivalent behavior) |

---

## 4. HOW LOG-BASED CDC WORKS (DEEP DIVE)

### STEP 1: APPLICATION WRITES TO DATABASE

Application executes:
```sql
INSERT INTO orders (id, amount, status) VALUES (101, 500, 'pending');
UPDATE orders SET status = 'shipped' WHERE id = 101;
DELETE FROM orders WHERE id = 99;
```

### STEP 2: DATABASE WRITES TO TRANSACTION LOG

The database engine writes to its internal log:

```
LOG ENTRY #4501: [TXN_ID=8827] INSERT orders {id:101, amount:500, status:'pending'}
LOG ENTRY #4502: [TXN_ID=8828] UPDATE orders {id:101} BEFORE:{status:'pending'} AFTER:{status:'shipped'}
LOG ENTRY #4503: [TXN_ID=8829] DELETE orders {id:99} ROW:{id:99, amount:200, status:'completed'}
```

Key: The log contains BOTH before and after images of the row.

### STEP 3: CDC CONNECTOR READS THE LOG

The CDC tool (e.g., Debezium) continuously reads the log and produces change events:

```json
Event 1: {
  "op": "c",
  "table": "orders",
  "after": {"id": 101, "amount": 500, "status": "pending"},
  "ts_ms": 1717200000000
}

Event 2: {
  "op": "u",
  "table": "orders",
  "before": {"id": 101, "amount": 500, "status": "pending"},
  "after": {"id": 101, "amount": 500, "status": "shipped"},
  "ts_ms": 1717200005000
}

Event 3: {
  "op": "d",
  "table": "orders",
  "before": {"id": 99, "amount": 200, "status": "completed"},
  "ts_ms": 1717200010000
}
```

Operation codes: `c` = create/insert, `u` = update, `d` = delete

### STEP 4: EVENTS DELIVERED TO TARGET

CDC events flow to:
- → Kafka topic → Snowpipe Streaming → Snowflake table
- → S3 bucket → Snowpipe → Snowflake staging table
- → Direct write → Snowflake (via connector)

Target table receives a stream of row-level changes with:
- Operation type (INSERT/UPDATE/DELETE)
- Before image (old values)
- After image (new values)
- Timestamp
- Transaction ID

### STEP 5: APPLY TO TARGET (MERGE)

Target consumption logic:
- `op = 'c'` (create) → INSERT into target
- `op = 'u'` (update) → UPDATE target WHERE id = row.id
- `op = 'd'` (delete) → DELETE from target WHERE id = row.id

Or use MERGE to handle all in one statement.

---

## 5. ADVANTAGES AND DISADVANTAGES

### ADVANTAGES:
- ✓ Captures ALL changes: INSERT, UPDATE, DELETE
- ✓ Near real-time latency (seconds, not minutes/hours)
- ✓ No source table modification needed (no updated_at column required)
- ✓ Minimal impact on source database (reads log, not tables)
- ✓ Preserves change order (sequential log reading)
- ✓ Captures intermediate states (all changes, not just latest)
- ✓ Before + After images available (know old AND new values)
- ✓ Transaction-level consistency (respects commit boundaries)
- ✓ Can replay from any point (reset log position = re-extract)
- ✓ No race conditions (log is authoritative, sequential)
- ✓ Supports schema evolution detection (DDL changes in log)

### DISADVANTAGES:
- ✗ Complex setup (log access, permissions, connectors, Kafka, etc.)
- ✗ Vendor-specific (each DB has different log format and access method)
- ✗ Requires special privileges on source (SYSDBA, replication role)
- ✗ Log retention limits (if logs rotate before consumption = data loss)
- ✗ Infrastructure overhead (Kafka cluster, connector, monitoring)
- ✗ Schema changes can break the pipeline (DDL handling is complex)
- ✗ Large transactions can cause memory pressure on CDC connector
- ✗ Initial snapshot is expensive (full table scan for baseline)
- ✗ Sensitive data in logs (security/compliance concerns)
- ✗ Some DBs don't expose full log details (Greenplum limitations)
- ✗ Debugging is harder (log format is binary, not human-readable)
- ✗ Cost (GoldenGate license, Kafka infra, connector maintenance)

### COMPARISON: ALL CDC METHODS

| CRITERIA | TIME-BASED | LOG-BASED | STREAMS (SF) |
|---|---|---|---|
| Latency | Minutes-Hours | Seconds | Seconds |
| Detects DELETEs | ✗ | ✓ | ✓ |
| Source modification | Required | Not required | Not required |
| Source DB impact | Medium (query) | Low (log read) | None |
| Setup complexity | Low | High | Medium |
| Infrastructure needed | Minimal | Kafka + Connector | None (built-in) |
| Cross-platform | ✓ (universal) | ✓ (with tools) | ✗ (SF only) |
| Before/After images | ✗ | ✓ | ✓ (partial) |
| Ordering guarantee | ✗ | ✓ | ✓ |
| Cost | Low | High | Medium |
| Best for | Batch ETL | Real-time CDC | SF-native pipes |

---

## 6. SOLVING THE DISADVANTAGES

### PROBLEM 1: Complex Setup

**SOLUTION:** Use managed CDC services
- AWS DMS (fully managed, no Kafka needed)
- Fivetran / Airbyte (SaaS, zero-infra CDC)
- Snowflake Connector for Kafka (native integration)
- IICS CDC (managed by Informatica)

Instead of: `PostgreSQL → custom WAL reader → Kafka → consumer → Snowflake`
Use: `PostgreSQL → Fivetran → Snowflake` (3 clicks)

### PROBLEM 2: Log Retention (data loss if logs rotate)

**SOLUTION:**
- Increase log retention on source (archive logs)
- Use Kafka as buffer (Kafka retains events even if source logs rotate)
- Monitor CDC lag (alert if connector falls behind)
- Periodic full reconciliation as safety net

```sql
-- Oracle
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
-- Keep archive logs for 7+ days

-- PostgreSQL
-- wal_level = logical
-- max_replication_slots = 10
-- Retain WAL until consumed
```

### PROBLEM 3: Initial Snapshot (baseline load)

**SOLUTION:**
- Most tools do this automatically (Debezium "snapshot" mode)
- First run = full table scan to get current state
- After snapshot = switch to log reading for ongoing changes
- Can be parallelized for large tables

### PROBLEM 4: Schema Changes Breaking Pipeline

**SOLUTION:**
- Debezium: `schema.change.policy = log` (logs DDL changes)
- Kafka: Schema Registry enforces compatibility
- Snowflake: VARIANT column to handle evolving schemas
- Strategy: Land as raw JSON first, transform later (ELT)

```sql
-- Landing table that handles any schema:
CREATE TABLE raw_cdc_events (
    source_table VARCHAR,
    operation VARCHAR,
    before_image VARIANT,
    after_image VARIANT,
    event_timestamp TIMESTAMP_NTZ,
    transaction_id VARCHAR
);
```

### PROBLEM 5: Large Transactions Causing Memory Pressure

**SOLUTION:**
- Debezium: `max.batch.size` and `max.queue.size` settings
- Split large transactions into smaller batches at source
- Use disk-based buffer for large events
- Monitor connector memory and scale if needed

### PROBLEM 6: Sensitive Data in Logs

**SOLUTION:**
- Apply column masking in Kafka (SMT = Single Message Transform)
- Encrypt CDC events in transit (TLS)
- Use Snowflake Dynamic Data Masking on landing tables
- Restrict log access to service accounts only

---

## 7. ARCHITECTURE PATTERNS

### PATTERN 1: Direct CDC (Simple)

```
Source DB → CDC Tool → Snowflake
```

Example: PostgreSQL → AWS DMS → Snowflake

- **Pros:** Simple, low latency, managed
- **Cons:** Limited transformation, tool-specific

### PATTERN 2: CDC via Kafka (Enterprise)

```
Source DB → Debezium → Kafka → Snowflake Kafka Connector → Snowflake
```

Example: Oracle → Debezium → Confluent Kafka → Snowpipe Streaming → SF

- **Pros:** Decoupled, scalable, multiple consumers, replay capability
- **Cons:** More infrastructure, higher cost, more components to manage

### PATTERN 3: CDC to Object Storage (Data Lake)

```
Source DB → CDC Tool → S3/Azure Blob → Snowpipe → Snowflake
```

Example: MySQL → Debezium → S3 (JSON/Parquet) → Snowpipe → SF

- **Pros:** Cheap storage, multiple consumers, schema flexibility
- **Cons:** Higher latency (minutes), file management overhead

### PATTERN 4: CDC with IICS (Our Project Pattern)

```
Source DB → IICS CDC Agent → IICS Cloud → Snowflake
```

Example: Greenplum → IICS PowerExchange CDC → IICS Mapping → Snowflake

- **Pros:** Enterprise support, GUI-based, integrated with IICS ecosystem
- **Cons:** License cost, vendor lock-in

How IICS CDC works:
1. PowerExchange CDC agent installed on source server
2. Agent reads database logs (Oracle redo, SQL Server tlog)
3. Captures changes and sends to IICS Cloud
4. IICS mapping applies transformations
5. Target connector writes to Snowflake via MERGE

---

## 8. PRACTICAL: SIMULATING LOG-BASED CDC IN SNOWFLAKE

Snowflake doesn't have traditional transaction logs you can read. Instead, **STREAMS** provide equivalent CDC functionality natively.

But to simulate how LOG-BASED CDC events look when they arrive in Snowflake (from an external source via Kafka/S3), here's a practical:

### 8.1 CDC EVENTS LANDING TABLE (as received from Kafka/S3)

```sql
CREATE DATABASE IF NOT EXISTS LOG_CDC_DEMO;
CREATE SCHEMA IF NOT EXISTS LOG_CDC_DEMO.RAW;
CREATE SCHEMA IF NOT EXISTS LOG_CDC_DEMO.DW;

-- This simulates what Debezium/Kafka sends to Snowflake
CREATE OR REPLACE TABLE LOG_CDC_DEMO.RAW.CDC_EVENTS (
    EVENT_ID INT AUTOINCREMENT,
    SOURCE_TABLE VARCHAR(100),
    OPERATION VARCHAR(10),
    BEFORE_IMAGE VARIANT,
    AFTER_IMAGE VARIANT,
    EVENT_TIMESTAMP TIMESTAMP_NTZ,
    TRANSACTION_ID VARCHAR(50),
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### 8.2 INSERT SIMULATED CDC EVENTS

```sql
-- Simulate: INSERT a new order
INSERT INTO LOG_CDC_DEMO.RAW.CDC_EVENTS 
    (SOURCE_TABLE, OPERATION, BEFORE_IMAGE, AFTER_IMAGE, EVENT_TIMESTAMP, TRANSACTION_ID)
VALUES (
    'orders', 'INSERT', NULL,
    PARSE_JSON('{"order_id": 201, "customer_id": 1, "amount": 5000, "status": "pending"}'),
    '2024-06-01 10:00:00', 'txn_001'
);

-- Simulate: INSERT another order
INSERT INTO LOG_CDC_DEMO.RAW.CDC_EVENTS 
    (SOURCE_TABLE, OPERATION, BEFORE_IMAGE, AFTER_IMAGE, EVENT_TIMESTAMP, TRANSACTION_ID)
VALUES (
    'orders', 'INSERT', NULL,
    PARSE_JSON('{"order_id": 202, "customer_id": 2, "amount": 3200, "status": "pending"}'),
    '2024-06-01 10:05:00', 'txn_002'
);

-- Simulate: UPDATE order status (before + after images)
INSERT INTO LOG_CDC_DEMO.RAW.CDC_EVENTS 
    (SOURCE_TABLE, OPERATION, BEFORE_IMAGE, AFTER_IMAGE, EVENT_TIMESTAMP, TRANSACTION_ID)
VALUES (
    'orders', 'UPDATE',
    PARSE_JSON('{"order_id": 201, "customer_id": 1, "amount": 5000, "status": "pending"}'),
    PARSE_JSON('{"order_id": 201, "customer_id": 1, "amount": 5000, "status": "shipped"}'),
    '2024-06-01 14:00:00', 'txn_003'
);

-- Simulate: DELETE an order
INSERT INTO LOG_CDC_DEMO.RAW.CDC_EVENTS 
    (SOURCE_TABLE, OPERATION, BEFORE_IMAGE, AFTER_IMAGE, EVENT_TIMESTAMP, TRANSACTION_ID)
VALUES (
    'orders', 'DELETE',
    PARSE_JSON('{"order_id": 202, "customer_id": 2, "amount": 3200, "status": "pending"}'),
    NULL,
    '2024-06-01 16:00:00', 'txn_004'
);

-- Simulate: UPDATE with value change
INSERT INTO LOG_CDC_DEMO.RAW.CDC_EVENTS 
    (SOURCE_TABLE, OPERATION, BEFORE_IMAGE, AFTER_IMAGE, EVENT_TIMESTAMP, TRANSACTION_ID)
VALUES (
    'orders', 'UPDATE',
    PARSE_JSON('{"order_id": 201, "customer_id": 1, "amount": 5000, "status": "shipped"}'),
    PARSE_JSON('{"order_id": 201, "customer_id": 1, "amount": 5000, "status": "delivered"}'),
    '2024-06-02 09:00:00', 'txn_005'
);

-- View all CDC events
SELECT 
    EVENT_ID, SOURCE_TABLE, OPERATION, 
    BEFORE_IMAGE, AFTER_IMAGE, 
    EVENT_TIMESTAMP, TRANSACTION_ID
FROM LOG_CDC_DEMO.RAW.CDC_EVENTS
ORDER BY EVENT_TIMESTAMP;
```

### 8.3 TARGET TABLE

```sql
CREATE OR REPLACE TABLE LOG_CDC_DEMO.DW.ORDERS (
    ORDER_ID INT,
    CUSTOMER_ID INT,
    AMOUNT DECIMAL(10,2),
    STATUS VARCHAR(20),
    LAST_CDC_TIMESTAMP TIMESTAMP_NTZ,
    DW_LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

### 8.4 APPLY CDC EVENTS TO TARGET (The Core Logic)

```sql
-- Process CDC events in order and apply to target
MERGE INTO LOG_CDC_DEMO.DW.ORDERS AS TGT
USING (
    SELECT 
        AFTER_IMAGE:order_id::INT AS ORDER_ID,
        COALESCE(AFTER_IMAGE:customer_id::INT, BEFORE_IMAGE:customer_id::INT) AS CUSTOMER_ID,
        COALESCE(AFTER_IMAGE:amount::DECIMAL(10,2), BEFORE_IMAGE:amount::DECIMAL(10,2)) AS AMOUNT,
        COALESCE(AFTER_IMAGE:status::VARCHAR, BEFORE_IMAGE:status::VARCHAR) AS STATUS,
        OPERATION,
        EVENT_TIMESTAMP,
        COALESCE(AFTER_IMAGE:order_id::INT, BEFORE_IMAGE:order_id::INT) AS MERGE_KEY
    FROM LOG_CDC_DEMO.RAW.CDC_EVENTS
    WHERE SOURCE_TABLE = 'orders'
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY COALESCE(AFTER_IMAGE:order_id::INT, BEFORE_IMAGE:order_id::INT)
        ORDER BY EVENT_TIMESTAMP DESC
    ) = 1
) AS SRC
ON TGT.ORDER_ID = SRC.MERGE_KEY
WHEN MATCHED AND SRC.OPERATION = 'DELETE'
    THEN DELETE
WHEN MATCHED AND SRC.OPERATION = 'UPDATE'
    THEN UPDATE SET
        TGT.CUSTOMER_ID = SRC.CUSTOMER_ID,
        TGT.AMOUNT = SRC.AMOUNT,
        TGT.STATUS = SRC.STATUS,
        TGT.LAST_CDC_TIMESTAMP = SRC.EVENT_TIMESTAMP,
        TGT.DW_LOADED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED AND SRC.OPERATION = 'INSERT'
    THEN INSERT (ORDER_ID, CUSTOMER_ID, AMOUNT, STATUS, LAST_CDC_TIMESTAMP)
    VALUES (SRC.ORDER_ID, SRC.CUSTOMER_ID, SRC.AMOUNT, SRC.STATUS, SRC.EVENT_TIMESTAMP);

-- Verify target
SELECT * FROM LOG_CDC_DEMO.DW.ORDERS;
```

**EXPECTED RESULT:**
- ORDER_ID=201, STATUS='delivered' (went pending→shipped→delivered)
- ORDER_ID=202 does NOT exist (was inserted then deleted)

### 8.5 AUDIT TABLE (Keep Full History of ALL Changes)

```sql
-- For compliance/audit, keep every change event
CREATE OR REPLACE TABLE LOG_CDC_DEMO.DW.ORDERS_AUDIT (
    AUDIT_ID INT AUTOINCREMENT,
    ORDER_ID INT,
    OPERATION VARCHAR(10),
    OLD_STATUS VARCHAR(20),
    NEW_STATUS VARCHAR(20),
    OLD_AMOUNT DECIMAL(10,2),
    NEW_AMOUNT DECIMAL(10,2),
    CHANGED_AT TIMESTAMP_NTZ,
    TRANSACTION_ID VARCHAR(50),
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO LOG_CDC_DEMO.DW.ORDERS_AUDIT 
    (ORDER_ID, OPERATION, OLD_STATUS, NEW_STATUS, OLD_AMOUNT, NEW_AMOUNT, CHANGED_AT, TRANSACTION_ID)
SELECT 
    COALESCE(AFTER_IMAGE:order_id::INT, BEFORE_IMAGE:order_id::INT),
    OPERATION,
    BEFORE_IMAGE:status::VARCHAR,
    AFTER_IMAGE:status::VARCHAR,
    BEFORE_IMAGE:amount::DECIMAL(10,2),
    AFTER_IMAGE:amount::DECIMAL(10,2),
    EVENT_TIMESTAMP,
    TRANSACTION_ID
FROM LOG_CDC_DEMO.RAW.CDC_EVENTS
WHERE SOURCE_TABLE = 'orders'
ORDER BY EVENT_TIMESTAMP;

-- Full audit trail
SELECT * FROM LOG_CDC_DEMO.DW.ORDERS_AUDIT ORDER BY CHANGED_AT;
```

**RESULT:** Complete history of every change:

| ORDER_ID | OPERATION | OLD_STATUS | NEW_STATUS | TIMESTAMP |
|---|---|---|---|---|
| 201 | INSERT | NULL | pending | 2024-06-01 10:00 |
| 202 | INSERT | NULL | pending | 2024-06-01 10:05 |
| 201 | UPDATE | pending | shipped | 2024-06-01 14:00 |
| 202 | DELETE | pending | NULL | 2024-06-01 16:00 |
| 201 | UPDATE | shipped | delivered | 2024-06-02 09:00 |

---

## 9. REAL-WORLD ARCHITECTURE: DEBEZIUM + KAFKA + SNOWFLAKE

This is the most common enterprise log-based CDC architecture:

```
┌─────────────┐     ┌───────────┐     ┌─────────────┐     ┌──────────────────┐     ┌───────────┐
│ Source DB   │────→│ Debezium  │────→│   Kafka     │────→│ Kafka Connector  │────→│ Snowflake │
│ (PostgreSQL)│     │ Connector │     │   Topic     │     │ (Snowpipe Stream)│     │           │
└─────────────┘     └───────────┘     └─────────────┘     └──────────────────┘     └───────────┘
                    reads WAL          stores events       writes to SF              landing table
```

### STEP-BY-STEP SETUP (Conceptual):

**1. SOURCE DATABASE CONFIGURATION:**
```sql
-- PostgreSQL: Enable logical replication
ALTER SYSTEM SET wal_level = logical;
ALTER SYSTEM SET max_replication_slots = 4;
CREATE PUBLICATION my_publication FOR TABLE orders, customers;
```

**2. DEBEZIUM CONNECTOR CONFIGURATION (JSON):**
```json
{
  "name": "postgres-cdc-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "source-db.example.com",
    "database.port": "5432",
    "database.user": "cdc_user",
    "database.password": "***",
    "database.dbname": "production",
    "table.include.list": "public.orders,public.customers",
    "topic.prefix": "cdc",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_slot",
    "snapshot.mode": "initial"
  }
}
```

**3. KAFKA TOPIC (auto-created by Debezium):**
- Topic: `cdc.public.orders`
- Each message = one change event (JSON)

**4. SNOWFLAKE KAFKA CONNECTOR:**
- Reads from Kafka topic
- Writes to Snowflake landing table
- Uses Snowpipe Streaming for low latency

**5. SNOWFLAKE PROCESSING:**
- Landing table receives raw CDC events
- Stream + Task applies changes to target
- Or: Use the MERGE pattern shown in section 8.4

### DEBEZIUM EVENT FORMAT (What arrives in Kafka):

```json
{
  "schema": {},
  "payload": {
    "before": {
      "order_id": 201,
      "status": "pending"
    },
    "after": {
      "order_id": 201,
      "status": "shipped"
    },
    "source": {
      "version": "2.5.0",
      "connector": "postgresql",
      "name": "cdc",
      "ts_ms": 1717200000000,
      "db": "production",
      "schema": "public",
      "table": "orders",
      "txId": 8827,
      "lsn": 123456789
    },
    "op": "u",
    "ts_ms": 1717200001000
  }
}
```

**OPERATION CODES:**
- `"c"` = create (INSERT)
- `"u"` = update
- `"d"` = delete
- `"r"` = read (snapshot - initial load)

---

## 10. SQL SERVER NATIVE CDC (Built-In)

SQL Server has BUILT-IN CDC (no external tool needed):

```sql
-- Enable CDC on database
USE production;
EXEC sys.sp_cdc_enable_db;

-- Enable CDC on specific table
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name = N'orders',
    @role_name = NULL,
    @supports_net_changes = 1;

-- Query changes between two LSNs:
DECLARE @from_lsn binary(10) = sys.fn_cdc_get_min_lsn('dbo_orders');
DECLARE @to_lsn binary(10) = sys.fn_cdc_get_max_lsn();

SELECT *
FROM cdc.fn_cdc_get_net_changes_dbo_orders(@from_lsn, @to_lsn, 'all');
```

**Returns columns:**
- `__$operation`: 1=delete, 2=insert, 3=before-update, 4=after-update
- `__$start_lsn`: log sequence number
- All original table columns

IICS can read from these CDC tables directly using SQL override:
```sql
SELECT * FROM cdc.fn_cdc_get_all_changes_dbo_orders(?, ?, 'all')
```

---

## 11. ORACLE LOGMINER (Built-In)

Oracle LogMiner reads redo logs and presents changes as SQL:

```sql
-- Enable supplemental logging
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER TABLE orders ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Start LogMiner session
BEGIN
  DBMS_LOGMNR.START_LOGMNR(
    STARTTIME => TO_DATE('01-JUN-2024 10:00:00','DD-MON-YYYY HH24:MI:SS'),
    ENDTIME   => TO_DATE('01-JUN-2024 18:00:00','DD-MON-YYYY HH24:MI:SS'),
    OPTIONS   => DBMS_LOGMNR.DICT_FROM_ONLINE_CATALOG
  );
END;

-- Query changes
SELECT 
  OPERATION,
  SQL_REDO,
  SQL_UNDO,
  TABLE_NAME,
  TIMESTAMP,
  SCN
FROM V$LOGMNR_CONTENTS
WHERE TABLE_NAME = 'ORDERS'
  AND OPERATION IN ('INSERT','UPDATE','DELETE');
```

**Example output:**

| OPERATION | SQL_REDO |
|---|---|
| INSERT | `INSERT INTO orders(id,amount,status) VALUES(201,5000,'pending');` |
| UPDATE | `UPDATE orders SET status='shipped' WHERE id=201 AND status='pending';` |
| DELETE | `DELETE FROM orders WHERE id=99 AND amount=200;` |

Tools like GoldenGate and IICS PowerExchange automate this reading.

---

## 12. WHEN TO USE LOG-BASED CDC

### USE LOG-BASED CDC WHEN:
- ✓ You need to capture DELETEs
- ✓ Real-time / near real-time latency required (seconds)
- ✓ Cannot modify source tables (no updated_at column possible)
- ✓ Need full audit trail of every change (compliance, GDPR)
- ✓ High-frequency updates on source (time-based would miss changes)
- ✓ Source is Oracle/SQL Server/PostgreSQL (good log-based CDC support)
- ✓ Enterprise budget available (tools + infrastructure)
- ✓ You need before AND after images (old vs new values)
- ✓ Multiple consumers need the same change stream

### DO NOT USE LOG-BASED CDC WHEN:
- ✗ Source is Snowflake (use Streams instead - native and free)
- ✗ Batch latency is acceptable (time-based CDC is simpler)
- ✗ Budget is limited (Kafka + Debezium + monitoring = expensive)
- ✗ Source DB doesn't support log access (some cloud DBs restrict it)
- ✗ Team lacks Kafka/streaming expertise
- ✗ Source is a flat file / API (no transaction log exists)
- ✗ Simple use case (don't over-engineer for 10 rows/day)

---

## 13. SUMMARY: CHOOSING THE RIGHT CDC METHOD

### DECISION TREE:

**Q1: Is your source Snowflake?**
- YES → Use Snowflake Streams (native, free, best option)
- NO → Continue to Q2

**Q2: Do you need to capture DELETEs?**
- NO → Time-Based CDC is sufficient
- YES → Continue to Q3

**Q3: Is near real-time latency required?**
- NO → Time-Based CDC + periodic full reconciliation (for deletes)
- YES → Continue to Q4

**Q4: Do you have budget for Kafka + CDC infrastructure?**
- NO → Use managed service (Fivetran, AWS DMS, IICS CDC)
- YES → Debezium + Kafka + Snowpipe Streaming (most powerful)

### THE THREE CDC METHODS:

| METHOD | ONE-LINE SUMMARY |
|---|---|
| Time-Based | "What's changed since my last check?" (polling) |
| Log-Based | "Tell me every change as it happens" (streaming) |
| Snowflake Streams | "Snowflake's built-in log-based CDC" (native) |

---

## 14. ORACLE TO SNOWFLAKE CDC - ALL METHODS

### METHOD 1: ORACLE GOLDENGATE → KAFKA → SNOWFLAKE

This is the ENTERPRISE-GRADE real-time CDC path.

```
┌──────────┐    ┌──────────────┐    ┌─────────┐    ┌──────────────────┐    ┌───────────┐
│  Oracle  │───→│  GoldenGate  │───→│  Kafka  │───→│ Kafka Connector  │───→│ Snowflake │
│  (Source)│    │  Extract +   │    │  Topic  │    │ (Snowpipe Stream │    │ (Landing  │
│          │    │  Replicat    │    │         │    │  or Snowpipe)    │    │  Table)   │
└──────────┘    └──────────────┘    └─────────┘    └──────────────────┘    └───────────┘
```

#### STEP 1: ORACLE - Enable Supplemental Logging

```sql
-- On Oracle source database (run as SYSDBA):
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Or table-level (recommended for specific tables):
ALTER TABLE HR.EMPLOYEES ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
ALTER TABLE SALES.ORDERS ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
```

#### STEP 2: GOLDENGATE - Configure EXTRACT Process

```
-- GoldenGate EXTRACT reads Oracle redo logs in real-time
-- Configuration file: dirprm/ext_ora.prm

EXTRACT ext_ora
USERID ogg_user, PASSWORD ***
EXTTRAIL ./dirdat/aa
TABLE HR.EMPLOYEES;
TABLE SALES.ORDERS;
TABLE SALES.PAYMENTS;
```

EXTRACT does:
1. Connects to Oracle using LogMiner API or integrated capture
2. Reads redo log entries for specified tables
3. Writes change records to a local trail file (dirdat/aa)
4. Runs continuously (real-time)

#### STEP 3: GOLDENGATE - Configure DATA PUMP (Optional)

```
-- Data Pump sends trail files to remote machine (if Kafka is remote)
-- Configuration: dirprm/pump_ora.prm

EXTRACT pump_ora
RMTHOST kafka-server, MGRPORT 7809
RMTTRAIL ./dirdat/bb
TABLE HR.EMPLOYEES;
TABLE SALES.ORDERS;
```

#### STEP 4: GOLDENGATE - Configure REPLICAT for Kafka

```
-- GoldenGate for Big Data (Kafka handler)
-- Configuration: dirprm/rkafka.prm

REPLICAT rkafka
TARGETDB LIBFILE libggjava.so SET property=dirprm/kafka.props
REPORTCOUNT EVERY 1 MINUTES, RATE
MAP HR.EMPLOYEES, TARGET HR.EMPLOYEES;
MAP SALES.ORDERS, TARGET SALES.ORDERS;
```

kafka.props:
```properties
gg.handlerlist=kafkahandler
gg.handler.kafkahandler.type=kafka
gg.handler.kafkahandler.topicMappingTemplate=${tableName}
gg.handler.kafkahandler.format=json
gg.handler.kafkahandler.format.includePrimaryKeys=true
gg.handler.kafkahandler.format.includeTokens=true
bootstrap.servers=kafka-broker-1:9092,kafka-broker-2:9092
```

#### STEP 5: KAFKA → SNOWFLAKE (Snowflake Kafka Connector)

```json
{
  "name": "snowflake-sink-connector",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "topics": "HR.EMPLOYEES,SALES.ORDERS",
    "snowflake.url.name": "account.snowflakecomputing.com",
    "snowflake.user.name": "CDC_SERVICE_USER",
    "snowflake.private.key": "***",
    "snowflake.database.name": "CDC_DB",
    "snowflake.schema.name": "RAW",
    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "buffer.flush.time": "10",
    "buffer.count.records": "1000"
  }
}
```

#### STEP 6: SNOWFLAKE - Landing Table

```sql
-- Kafka connector creates/writes to this table:
CREATE OR REPLACE TABLE CDC_DB.RAW.EMPLOYEES_CDC_RAW (
    RECORD_METADATA VARIANT,
    RECORD_CONTENT VARIANT
);
```

Sample `RECORD_CONTENT` from GoldenGate:
```json
{
  "table": "HR.EMPLOYEES",
  "op_type": "U",
  "op_ts": "2024-06-01 10:05:23.000000",
  "current_ts": "2024-06-01 10:05:24.123456",
  "pos": "00000000001234567890",
  "before": {"EMP_ID": 1, "NAME": "Rahul", "SALARY": 120000},
  "after": {"EMP_ID": 1, "NAME": "Rahul", "SALARY": 140000}
}
```

#### STEP 7: SNOWFLAKE - Process CDC Events (Stream + Task)

```sql
-- Create target table
CREATE OR REPLACE TABLE CDC_DB.DW.EMPLOYEES (
    EMP_ID INT,
    NAME VARCHAR(100),
    DEPARTMENT VARCHAR(50),
    SALARY DECIMAL(12,2),
    CITY VARCHAR(50),
    CDC_OPERATION VARCHAR(10),
    CDC_TIMESTAMP TIMESTAMP_NTZ,
    DW_LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Create stream on landing table
CREATE OR REPLACE STREAM CDC_DB.RAW.EMPLOYEES_CDC_STREAM
ON TABLE CDC_DB.RAW.EMPLOYEES_CDC_RAW;

-- Task to process GoldenGate CDC events
CREATE OR REPLACE TASK CDC_DB.RAW.PROCESS_OGG_CDC_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('CDC_DB.RAW.EMPLOYEES_CDC_STREAM')
AS
MERGE INTO CDC_DB.DW.EMPLOYEES AS TGT
USING (
    SELECT 
        RECORD_CONTENT:after:EMP_ID::INT AS EMP_ID,
        COALESCE(RECORD_CONTENT:after:NAME::VARCHAR, RECORD_CONTENT:before:NAME::VARCHAR) AS NAME,
        COALESCE(RECORD_CONTENT:after:DEPARTMENT::VARCHAR, RECORD_CONTENT:before:DEPARTMENT::VARCHAR) AS DEPARTMENT,
        COALESCE(RECORD_CONTENT:after:SALARY::DECIMAL(12,2), RECORD_CONTENT:before:SALARY::DECIMAL(12,2)) AS SALARY,
        COALESCE(RECORD_CONTENT:after:CITY::VARCHAR, RECORD_CONTENT:before:CITY::VARCHAR) AS CITY,
        RECORD_CONTENT:op_type::VARCHAR AS OPERATION,
        RECORD_CONTENT:op_ts::TIMESTAMP_NTZ AS CDC_TIMESTAMP,
        COALESCE(RECORD_CONTENT:after:EMP_ID::INT, RECORD_CONTENT:before:EMP_ID::INT) AS MERGE_KEY
    FROM CDC_DB.RAW.EMPLOYEES_CDC_STREAM
    WHERE RECORD_CONTENT:table::VARCHAR = 'HR.EMPLOYEES'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY MERGE_KEY ORDER BY CDC_TIMESTAMP DESC) = 1
) AS SRC
ON TGT.EMP_ID = SRC.MERGE_KEY
WHEN MATCHED AND SRC.OPERATION = 'D'
    THEN DELETE
WHEN MATCHED AND SRC.OPERATION IN ('U', 'I')
    THEN UPDATE SET
        TGT.NAME = SRC.NAME,
        TGT.DEPARTMENT = SRC.DEPARTMENT,
        TGT.SALARY = SRC.SALARY,
        TGT.CITY = SRC.CITY,
        TGT.CDC_OPERATION = SRC.OPERATION,
        TGT.CDC_TIMESTAMP = SRC.CDC_TIMESTAMP,
        TGT.DW_LOADED_AT = CURRENT_TIMESTAMP()
WHEN NOT MATCHED AND SRC.OPERATION IN ('I', 'U')
    THEN INSERT (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CDC_OPERATION, CDC_TIMESTAMP)
    VALUES (SRC.EMP_ID, SRC.NAME, SRC.DEPARTMENT, SRC.SALARY, SRC.CITY, SRC.OPERATION, SRC.CDC_TIMESTAMP);
```

**FULL FLOW SUMMARY (GoldenGate):**
```
Oracle redo log → GoldenGate Extract → Trail file → GoldenGate Replicat
→ Kafka topic (JSON) → Snowflake Kafka Connector → Landing table (VARIANT)
→ Stream → Task (MERGE) → Target table
```

- **LATENCY:** 5-30 seconds end-to-end
- **COST:** GoldenGate license + Kafka cluster + Snowflake compute

---

### METHOD 2: IICS CDC (INFORMATICA) → SNOWFLAKE

```
┌──────────┐    ┌─────────────────┐    ┌───────────────┐    ┌───────────┐
│  Oracle  │───→│  IICS CDC Agent │───→│ IICS Mapping  │───→│ Snowflake │
│  (Source)│    │  (PowerExchange)│    │  (Cloud)      │    │ (Target)  │
└──────────┘    └─────────────────┘    └───────────────┘    └───────────┘
```

#### STEP 1: ORACLE - Enable Archive Logging

```sql
-- Ensure archive log mode is ON
ALTER DATABASE ARCHIVELOG;

-- Enable supplemental logging
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER TABLE HR.EMPLOYEES ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- Create CDC user for IICS
CREATE USER iics_cdc_user IDENTIFIED BY ***;
GRANT SELECT ON HR.EMPLOYEES TO iics_cdc_user;
GRANT SELECT_CATALOG_ROLE TO iics_cdc_user;
GRANT EXECUTE_CATALOG_ROLE TO iics_cdc_user;
GRANT SELECT ON V_$LOG TO iics_cdc_user;
GRANT SELECT ON V_$LOGFILE TO iics_cdc_user;
GRANT SELECT ON V_$ARCHIVED_LOG TO iics_cdc_user;
```

#### STEP 2: IICS - Install and Configure CDC Agent

Install Informatica Secure Agent on a server with Oracle access. Configure PowerExchange CDC connection:
- Connection Type: Oracle CDC (LogMiner-based)
- Host: oracle-server.company.com
- Port: 1521
- SID: PRODDB
- Username: iics_cdc_user
- Schema: HR
- Tables: EMPLOYEES, ORDERS, PAYMENTS
- Capture Method: Oracle LogMiner
- Start Position: Current (or specific SCN for replay)

#### STEP 3: IICS - Create CDC Mapping (Source → Target)

In IICS Cloud UI:
1. Create new Mapping
2. Source: Oracle CDC connection → HR.EMPLOYEES
   - This automatically provides CDC metadata columns:
     - `DML_IND` (I/U/D)
     - `BEFORE_*` columns (old values)
     - `AFTER_*` columns (new values)
     - `CDC_TIMESTAMP`
3. Transformation: Router
   - Group 1: `DML_IND = 'I'` → INSERT to target
   - Group 2: `DML_IND = 'U'` → UPDATE target
   - Group 3: `DML_IND = 'D'` → DELETE from target
4. Target: Snowflake connection → CDC_DB.DW.EMPLOYEES
   - Insert mode: MERGE (handles all operations)
   - Merge key: EMP_ID
   - Update columns: NAME, DEPARTMENT, SALARY, CITY
   - Delete condition: `DML_IND = 'D'`

#### STEP 4: IICS - Create Taskflow (Schedule/Trigger)

- Name: TF_CDC_Oracle_Employees
- Type: CDC (continuous)
- Mapping: M_CDC_Oracle_Employees
- Schedule: Continuous (runs perpetually) OR every 5 minutes
- Error handling: Retry 3 times, then alert
- Parameters:
  - Batch size: 10000 rows
  - Commit interval: 5000 rows
  - Pushdown optimization: enabled

#### STEP 5: SNOWFLAKE - Target Table Design

```sql
-- IICS writes directly to this table using MERGE
CREATE OR REPLACE TABLE CDC_DB.DW.EMPLOYEES_IICS (
    EMP_ID INT PRIMARY KEY,
    NAME VARCHAR(100),
    DEPARTMENT VARCHAR(50),
    SALARY DECIMAL(12,2),
    CITY VARCHAR(50),
    CDC_OPERATION VARCHAR(1),
    CDC_TIMESTAMP TIMESTAMP_NTZ,
    IICS_LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

#### STEP 6: IICS - What Happens Under the Hood

IICS generates and executes SQL on Snowflake:

```sql
-- For INSERTs:
INSERT INTO CDC_DB.DW.EMPLOYEES_IICS (EMP_ID, NAME, DEPARTMENT, SALARY, CITY, CDC_OPERATION, CDC_TIMESTAMP)
VALUES (6, 'Kavita', 'Marketing', 78000, 'Pune', 'I', '2024-06-01 10:00:00');

-- For UPDATEs:
UPDATE CDC_DB.DW.EMPLOYEES_IICS
SET SALARY = 140000, CDC_OPERATION = 'U', CDC_TIMESTAMP = '2024-06-01 14:00:00'
WHERE EMP_ID = 1;

-- For DELETEs:
DELETE FROM CDC_DB.DW.EMPLOYEES_IICS WHERE EMP_ID = 4;

-- OR (if using MERGE mode - recommended):
MERGE INTO CDC_DB.DW.EMPLOYEES_IICS TGT
USING (staging data from IICS) SRC
ON TGT.EMP_ID = SRC.EMP_ID
WHEN MATCHED AND SRC.DML_IND = 'D' THEN DELETE
WHEN MATCHED AND SRC.DML_IND = 'U' THEN UPDATE SET ...
WHEN NOT MATCHED AND SRC.DML_IND = 'I' THEN INSERT ...
```

**FULL FLOW SUMMARY (IICS):**
```
Oracle redo log → IICS PowerExchange CDC Agent (reads LogMiner)
→ IICS Cloud (mapping + transformation)
→ Snowflake (MERGE into target table)
```

- **LATENCY:** 1-5 minutes (micro-batch)
- **COST:** IICS license (CDC add-on) + Snowflake compute

---

### METHOD 3: SNOWFLAKE STORED PROCEDURE (Poll-Based)

This is NOT true log-based CDC but a HYBRID approach where:
- Oracle exposes changes via a CDC table or audit table
- Snowflake procedure polls and processes those changes

```
┌──────────┐    ┌───────────────────┐    ┌─────────────┐    ┌───────────┐
│  Oracle  │───→│  Oracle CDC Table │───→│ External    │───→│ Snowflake │
│  (Source)│    │  (via trigger or  │    │ Stage (S3)  │    │ Procedure │
│          │    │   native CDC)     │    │             │    │           │
└──────────┘    └───────────────────┘    └─────────────┘    └───────────┘
```

#### STEP 1: ORACLE - Create Change Tracking Table

Trigger approach (works on any Oracle version):

```sql
CREATE TABLE HR.EMPLOYEES_CDC_LOG (
    CDC_ID NUMBER GENERATED ALWAYS AS IDENTITY,
    EMP_ID NUMBER,
    OPERATION VARCHAR2(1),
    OLD_NAME VARCHAR2(100),
    NEW_NAME VARCHAR2(100),
    OLD_SALARY NUMBER,
    NEW_SALARY NUMBER,
    OLD_DEPARTMENT VARCHAR2(50),
    NEW_DEPARTMENT VARCHAR2(50),
    CHANGE_TIMESTAMP TIMESTAMP DEFAULT SYSTIMESTAMP,
    PROCESSED_FLAG VARCHAR2(1) DEFAULT 'N'
);

CREATE OR REPLACE TRIGGER HR.TRG_EMPLOYEES_CDC
AFTER INSERT OR UPDATE OR DELETE ON HR.EMPLOYEES
FOR EACH ROW
BEGIN
    IF INSERTING THEN
        INSERT INTO HR.EMPLOYEES_CDC_LOG (EMP_ID, OPERATION, NEW_NAME, NEW_SALARY, NEW_DEPARTMENT)
        VALUES (:NEW.EMP_ID, 'I', :NEW.NAME, :NEW.SALARY, :NEW.DEPARTMENT);
    ELSIF UPDATING THEN
        INSERT INTO HR.EMPLOYEES_CDC_LOG (EMP_ID, OPERATION, OLD_NAME, NEW_NAME, OLD_SALARY, NEW_SALARY, OLD_DEPARTMENT, NEW_DEPARTMENT)
        VALUES (:OLD.EMP_ID, 'U', :OLD.NAME, :NEW.NAME, :OLD.SALARY, :NEW.SALARY, :OLD.DEPARTMENT, :NEW.DEPARTMENT);
    ELSIF DELETING THEN
        INSERT INTO HR.EMPLOYEES_CDC_LOG (EMP_ID, OPERATION, OLD_NAME, OLD_SALARY, OLD_DEPARTMENT)
        VALUES (:OLD.EMP_ID, 'D', :OLD.NAME, :OLD.SALARY, :OLD.DEPARTMENT);
    END IF;
END;
```

#### STEP 2: EXPORT CDC LOG TO S3/AZURE

A scheduled job (cron/Control-M) exports unprocessed CDC records:
```sql
SELECT * FROM HR.EMPLOYEES_CDC_LOG WHERE PROCESSED_FLAG = 'N'
```
→ Write to CSV/Parquet → Upload to S3 bucket → Mark as `PROCESSED_FLAG = 'Y'`

#### STEP 3: SNOWFLAKE - Create Stage and Load CDC Data

```sql
-- External stage pointing to S3 where Oracle CDC files land
CREATE OR REPLACE STAGE CDC_DB.RAW.ORACLE_CDC_STAGE
    URL = 's3://my-bucket/oracle-cdc/'
    CREDENTIALS = (AWS_KEY_ID='***' AWS_SECRET_KEY='***')
    FILE_FORMAT = (TYPE='PARQUET');

-- Landing table for CDC log
CREATE OR REPLACE TABLE CDC_DB.RAW.ORACLE_CDC_LOG (
    CDC_ID INT,
    EMP_ID INT,
    OPERATION VARCHAR(1),
    OLD_NAME VARCHAR(100),
    NEW_NAME VARCHAR(100),
    OLD_SALARY DECIMAL(12,2),
    NEW_SALARY DECIMAL(12,2),
    OLD_DEPARTMENT VARCHAR(50),
    NEW_DEPARTMENT VARCHAR(50),
    CHANGE_TIMESTAMP TIMESTAMP_NTZ,
    LOADED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Load CDC data from stage (via Snowpipe or COPY INTO)
COPY INTO CDC_DB.RAW.ORACLE_CDC_LOG
FROM @CDC_DB.RAW.ORACLE_CDC_STAGE
FILE_FORMAT = (TYPE='PARQUET')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

#### STEP 4: SNOWFLAKE - Stored Procedure to Apply CDC

```sql
CREATE OR REPLACE PROCEDURE CDC_DB.DW.SP_APPLY_ORACLE_CDC()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    MERGE INTO CDC_DB.DW.EMPLOYEES AS TGT
    USING (
        SELECT 
            EMP_ID,
            OPERATION,
            COALESCE(NEW_NAME, OLD_NAME) AS NAME,
            COALESCE(NEW_SALARY, OLD_SALARY) AS SALARY,
            COALESCE(NEW_DEPARTMENT, OLD_DEPARTMENT) AS DEPARTMENT,
            CHANGE_TIMESTAMP
        FROM CDC_DB.RAW.ORACLE_CDC_LOG
        WHERE LOADED_AT > (SELECT COALESCE(MAX(DW_LOADED_AT), '1900-01-01') FROM CDC_DB.DW.EMPLOYEES)
        QUALIFY ROW_NUMBER() OVER (PARTITION BY EMP_ID ORDER BY CHANGE_TIMESTAMP DESC) = 1
    ) AS SRC
    ON TGT.EMP_ID = SRC.EMP_ID
    WHEN MATCHED AND SRC.OPERATION = 'D'
        THEN DELETE
    WHEN MATCHED AND SRC.OPERATION IN ('U', 'I')
        THEN UPDATE SET
            TGT.NAME = SRC.NAME,
            TGT.SALARY = SRC.SALARY,
            TGT.DEPARTMENT = SRC.DEPARTMENT,
            TGT.CDC_OPERATION = SRC.OPERATION,
            TGT.CDC_TIMESTAMP = SRC.CHANGE_TIMESTAMP,
            TGT.DW_LOADED_AT = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED AND SRC.OPERATION IN ('I', 'U')
        THEN INSERT (EMP_ID, NAME, SALARY, DEPARTMENT, CDC_OPERATION, CDC_TIMESTAMP)
        VALUES (SRC.EMP_ID, SRC.NAME, SRC.SALARY, SRC.DEPARTMENT, SRC.OPERATION, SRC.CHANGE_TIMESTAMP);

    RETURN 'CDC applied successfully';
END;
$$;

-- Schedule the procedure
CREATE OR REPLACE TASK CDC_DB.DW.TASK_APPLY_ORACLE_CDC
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
AS
CALL CDC_DB.DW.SP_APPLY_ORACLE_CDC();

-- ALTER TASK CDC_DB.DW.TASK_APPLY_ORACLE_CDC RESUME;
```

**FULL FLOW SUMMARY (Stored Procedure):**
```
Oracle trigger → CDC log table → Export to S3 (scheduled)
→ Snowpipe/COPY INTO landing table → Snowflake procedure (MERGE)
→ Target table
```

- **LATENCY:** 5-30 minutes (depends on export schedule)
- **COST:** Low (no extra tools), but more manual work

---

### METHOD COMPARISON: WHICH TO CHOOSE?

| CRITERIA | GOLDENGATE+KAFKA | IICS CDC | SP + PROCEDURE |
|---|---|---|---|
| Latency | 5-30 seconds | 1-5 minutes | 5-30 minutes |
| Complexity | Very High | Medium | Low-Medium |
| Cost | $$$$ (licenses) | $$$ (IICS CDC) | $ (DIY) |
| Captures DELETEs | ✓ | ✓ | ✓ |
| Before/After images | ✓ | ✓ | ✓ (via trigger) |
| Ordering | ✓ (guaranteed) | ✓ (micro-batch) | ✓ (by timestamp) |
| Source DB impact | Minimal | Minimal | Medium (trigger) |
| Infrastructure | Kafka cluster | IICS agent | S3 + Snowpipe |
| Managed service | No (or OCI GG) | Yes (IICS Cloud) | Partially |
| Best for | Real-time, mission-critical | Enterprise with IICS already | Small/medium budget-conscious |
| Schema evolution | Handled | Handled | Manual |
| Monitoring | GG console | IICS dashboard | Custom (tasks) |

### RECOMMENDATION:
- Already have IICS? → Use IICS CDC (path of least resistance)
- Need real-time + high volume? → GoldenGate + Kafka
- Small project, low budget? → Trigger + S3 + Snowflake procedure
- Snowflake-to-Snowflake? → Use native Streams (forget all of the above)

---

```sql
-- CLEANUP (optional)
-- DROP DATABASE LOG_CDC_DEMO;
```
