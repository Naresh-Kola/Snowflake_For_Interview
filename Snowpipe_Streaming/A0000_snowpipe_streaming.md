# Snowpipe Streaming - Complete Guide

A Production-Level Explanation with Architecture, Pros, Cons, Use Cases, and Step-by-Step Examples

---

## 1. WHAT IS SNOWPIPE STREAMING?

Snowpipe Streaming is Snowflake's **real-time ingestion service** that enables applications to load streaming data directly into Snowflake tables as **individual rows** arrive — without staging files, without intermediate storage, and without managing infrastructure.

### Key Characteristics:
- **Row-based ingestion** (not file-based)
- **Sub-10 second latency** (data queryable within ~5 seconds)
- **Up to 10 GB/s throughput** per table
- **Exactly-once delivery** (built-in offset tracking)
- **Ordered ingestion** within each channel
- **Serverless** (no warehouse needed, auto-scales)
- **Schema evolution** support

### Simple Analogy:
- **Snowpipe (file-based)** = Dropping mail at a post office → sorted and delivered in batches
- **Snowpipe Streaming** = Real-time phone call → message arrives instantly as spoken

---

## 2. ARCHITECTURE

```
┌──────────────────────────────────────────────────────────────────────┐
│                        DATA SOURCES                                    │
│   IoT Devices │ Kafka Topics │ Application Events │ CDC Streams       │
└──────────────────────────┬───────────────────────────────────────────┘
                           │
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│               SNOWPIPE STREAMING SDKs / CONNECTORS                    │
│                                                                       │
│   ┌─────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌───────┐ │
│   │Java SDK │  │Python SDK│  │Node.js   │  │REST API  │  │Kafka  │ │
│   │(Java 11+)│  │(Py 3.9+) │  │SDK(20+)  │  │(IoT/Edge)│  │Connect│ │
│   └────┬────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───┬───┘ │
│        │             │             │             │             │      │
│        └─────────────┴─────────────┴─────────────┴─────────────┘      │
│                    Shared Rust-based Client Core                       │
└──────────────────────────┬───────────────────────────────────────────┘
                           │ Rows sent via HTTPS
                           ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    SNOWFLAKE SERVER SIDE                               │
│                                                                       │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │                    PIPE OBJECT                                 │   │
│   │  - Schema validation (server-side)                            │   │
│   │  - In-flight transformations (COPY syntax)                    │   │
│   │  - Pre-clustering at ingest time                              │   │
│   │  - Schema evolution (auto ADD COLUMN)                         │   │
│   └──────────────────────────────┬───────────────────────────────┘   │
│                                  │                                    │
│                                  ▼                                    │
│   ┌──────────────────────────────────────────────────────────────┐   │
│   │               TARGET TABLE (Standard or Iceberg)              │   │
│   │  - Data available for query within ~5 seconds                 │   │
│   │  - Exactly-once delivery via offset tokens                    │   │
│   │  - Ordered within each channel                                │   │
│   └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. KEY CONCEPTS

### 3.1 CHANNELS

A **channel** is a logical connection between a client and a target table. It:
- Maintains ordering guarantees (rows arrive in order within a channel)
- Tracks offset tokens for exactly-once delivery
- Maps naturally to source partitions (e.g., Kafka partition = 1 channel)

### 3.2 PIPE OBJECT

The **PIPE object** is the server-side processing layer:
- Handles schema validation
- Applies in-flight transformations (filter rows, cast types, reorder columns)
- Enables pre-clustering at ingest time
- A **default pipe** is auto-created for each table
- You can create **custom pipes** for advanced processing

### 3.3 OFFSET TOKENS

**Offset tokens** enable exactly-once delivery:
- Your application assigns an offset token to each batch of rows
- Snowflake tracks the last committed offset
- On failure/recovery, replay from last committed offset
- No duplicate data, no data loss

### 3.4 SCHEMA EVOLUTION

When `ENABLE_SCHEMA_EVOLUTION = TRUE` on the target table:
- New columns detected in the incoming stream are automatically added
- No manual DDL changes needed
- Pipeline never breaks due to schema changes

---

## 4. SNOWPIPE STREAMING vs SNOWPIPE (File-Based)

| Category | Snowpipe Streaming | Snowpipe (File-Based) |
|---|---|---|
| Data format | Rows | Files (CSV, JSON, Parquet, etc.) |
| Latency | ~5 seconds | 30 seconds - few minutes |
| How it works | SDK/API sends rows directly | Files land in stage → auto-loaded |
| Ordering | Ordered within each channel | No ordering guarantee |
| Exactly-once | Built-in via offset tokens | At-least-once (dedup needed) |
| Staging files | Not needed | Required (S3/Azure/GCS) |
| Transformations | In-flight via PIPE object | Limited (COPY INTO options) |
| Schema evolution | Supported | Supported |
| Billing | Per-GB ingested (flat rate) | Per-second compute + file overhead |
| Best for | Row-level streaming data | Batch files already in cloud storage |

---

## 5. PROS (ADVANTAGES)

| # | Advantage | Details |
|---|---|---|
| 1 | **Ultra-low latency** | Data queryable within ~5 seconds of ingestion. Near real-time analytics without waiting for file batching. |
| 2 | **Exactly-once delivery** | Built-in offset token tracking prevents duplicates and data loss. No need for custom deduplication logic. |
| 3 | **Ordered ingestion** | Rows arrive in order within each channel. Critical for CDC pipelines where order matters. |
| 4 | **No staging files** | Write rows directly to tables. No need to create/manage files in S3/Azure/GCS. Simpler architecture. |
| 5 | **Serverless & auto-scaling** | No warehouse needed. Compute scales automatically based on load. Zero infrastructure management. |
| 6 | **High throughput** | Up to 10 GB/s per table. Handles massive IoT, clickstream, and event workloads. |
| 7 | **Schema evolution** | Automatically adds new columns when detected in the stream. Pipeline self-heals on schema changes. |
| 8 | **In-flight transformations** | Filter, cast, reshape data during ingestion using COPY syntax in the PIPE object. No separate ETL step. |
| 9 | **Pre-clustering at ingest** | Sort data during ingestion for optimized query performance. No post-load clustering needed. |
| 10 | **Multi-language SDKs** | Java, Python, Node.js SDKs plus REST API. Fits any tech stack. |
| 11 | **Transparent pricing** | Flat per-GB rate. Predictable costs. No hidden compute charges. |
| 12 | **Iceberg table support** | Stream into Snowflake-managed Apache Iceberg tables (v2 and v3). Open table format analytics. |
| 13 | **Kafka connector native** | Snowflake Kafka Connector v4 uses Snowpipe Streaming natively. Drop-in for Kafka pipelines. |

---

## 6. CONS (DISADVANTAGES)

| # | Disadvantage | Details |
|---|---|---|
| 1 | **Requires custom application** | You must write/maintain a client application (Java/Python/Node.js) to call the SDK. Not as simple as "drop a file." |
| 2 | **Not for file-based sources** | If your data already arrives as files in S3/Azure/GCS, use regular Snowpipe instead. Snowpipe Streaming adds unnecessary complexity for file sources. |
| 3 | **Schema evolution limitations** | Only supports adding new columns. Type changes, renames, and column removal are NOT automatic. Iceberg tables don't support schema evolution at all. |
| 4 | **No partitioned Iceberg tables** | Cannot stream into partitioned Iceberg tables. |
| 5 | **Key-pair authentication only** | Must use RSA key-pair auth (no password auth). Adds setup complexity. (OAuth not supported in Kafka connector v4.) |
| 6 | **Client must handle failures** | Your application must implement retry logic, error handling, and ensure continuous operation. SDK doesn't auto-recover. |
| 7 | **Cost at high volume** | Per-GB pricing can be expensive for very high throughput (10+ GB/s). File-based loading may be cheaper for batch workloads. |
| 8 | **Classic architecture deprecation** | Classic architecture (Java-only snowflake-ingest-sdk) is planned for deprecation mid-2026. Existing users must migrate to high-performance architecture. |
| 9 | **No SQL-based loading** | Cannot use INSERT statements or stored procedures to trigger streaming. Must use SDK/API. |
| 10 | **Limited error visibility (classic)** | In classic architecture, error handling is client-side only. High-performance architecture improves this with server-side validation and error tables. |
| 11 | **Network dependency** | Requires constant outbound connectivity to Snowflake and cloud storage (S3/Azure/GCS). Network interruptions = ingestion stops. |
| 12 | **Java 11+ / Python 3.9+ / Node.js 20+** | Minimum runtime requirements. Legacy applications on older runtimes need upgrading. |

---

## 7. WHEN TO USE SNOWPIPE STREAMING

### USE IT WHEN:
- ✓ Data arrives as individual rows or events (not files)
- ✓ Need sub-10 second latency (real-time dashboards, alerts)
- ✓ Ingesting from Kafka topics
- ✓ IoT sensor data / telemetry
- ✓ Application event streams (clickstream, user activity)
- ✓ CDC pipelines from Debezium/Kafka
- ✓ Fraud detection requiring immediate data availability
- ✓ Need exactly-once delivery guarantees
- ✓ Need ordered ingestion
- ✓ Want to avoid managing staging files

### DO NOT USE IT WHEN:
- ✗ Data already arrives as files (use Snowpipe instead)
- ✗ Batch latency (minutes/hours) is acceptable
- ✗ Source is a database you control (use Streams + Tasks)
- ✗ Simple one-time or ad-hoc loads (use COPY INTO)
- ✗ Team lacks SDK/programming expertise
- ✗ Extremely cost-sensitive and low-volume workloads

---

## 8. STEP-BY-STEP EXAMPLES

### 8.1 EXAMPLE 1: Setup Using Python SDK

#### Step 1: Snowflake Objects Setup

```sql
-- Create dedicated role and user
CREATE ROLE IF NOT EXISTS STREAMING_ROLE;
CREATE USER IF NOT EXISTS STREAMING_USER
    DEFAULT_ROLE = STREAMING_ROLE;

-- Grant necessary privileges
GRANT USAGE ON DATABASE MY_DB TO ROLE STREAMING_ROLE;
GRANT USAGE ON SCHEMA MY_DB.RAW TO ROLE STREAMING_ROLE;
GRANT CREATE TABLE ON SCHEMA MY_DB.RAW TO ROLE STREAMING_ROLE;
GRANT CREATE PIPE ON SCHEMA MY_DB.RAW TO ROLE STREAMING_ROLE;
GRANT ROLE STREAMING_ROLE TO USER STREAMING_USER;

-- Create target table
CREATE OR REPLACE TABLE MY_DB.RAW.IOT_EVENTS (
    DEVICE_ID VARCHAR(50),
    TEMPERATURE FLOAT,
    HUMIDITY FLOAT,
    BATTERY_LEVEL INT,
    EVENT_TIMESTAMP TIMESTAMP_NTZ,
    LOCATION VARIANT
)
ENABLE_SCHEMA_EVOLUTION = TRUE;

-- Grant EVOLVE SCHEMA for schema evolution
GRANT EVOLVE SCHEMA ON TABLE MY_DB.RAW.IOT_EVENTS TO ROLE STREAMING_ROLE;

-- Generate key pair for authentication
-- Run in terminal:
-- openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
-- openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub

-- Assign public key to user
ALTER USER STREAMING_USER SET RSA_PUBLIC_KEY='MIIBIjANBgkqhk...YOUR_KEY_HERE...';
```

#### Step 2: Install Python SDK

```bash
pip install snowpipe-streaming
```

#### Step 3: Python Application Code

```python
import json
import time
from datetime import datetime
from snowpipe_streaming import SnowpipeStreamingClient

# Configuration
config = {
    "account": "your_account_identifier",
    "user": "STREAMING_USER",
    "private_key_file": "rsa_key.p8",
    "role": "STREAMING_ROLE",
    "database": "MY_DB",
    "schema": "RAW"
}

# Create client (one client per table/pipe)
client = SnowpipeStreamingClient(
    name="iot_ingestion_client",
    account=config["account"],
    user=config["user"],
    private_key_file=config["private_key_file"],
    role=config["role"],
    database=config["database"],
    schema=config["schema"],
    pipe="IOT_EVENTS-STREAMING"  # Default pipe name convention
)

# Open a channel
channel = client.open_channel(
    channel_name="iot_channel_1",
    offset_token="0"  # Start from beginning
)

# Simulate streaming IoT data
for i in range(1000):
    row = {
        "DEVICE_ID": f"sensor_{i % 10}",
        "TEMPERATURE": 22.5 + (i * 0.1),
        "HUMIDITY": 45.0 + (i * 0.05),
        "BATTERY_LEVEL": max(0, 100 - i),
        "EVENT_TIMESTAMP": datetime.utcnow().isoformat(),
        "LOCATION": {"lat": 12.9716, "lon": 77.5946}
    }
    
    channel.append_row(row)
    
    # Every 100 rows, commit and track offset
    if (i + 1) % 100 == 0:
        channel.commit(offset_token=str(i + 1))
        print(f"Committed offset: {i + 1}")

# Close channel when done
channel.close()
client.close()
```

#### Step 4: Verify Data in Snowflake

```sql
-- Check row count
SELECT COUNT(*) FROM MY_DB.RAW.IOT_EVENTS;

-- Query latest data (available within ~5 seconds of ingestion)
SELECT *
FROM MY_DB.RAW.IOT_EVENTS
ORDER BY EVENT_TIMESTAMP DESC
LIMIT 10;

-- Check ingestion latency
SELECT 
    MAX(EVENT_TIMESTAMP) AS LATEST_EVENT,
    CURRENT_TIMESTAMP() AS QUERY_TIME,
    DATEDIFF('SECOND', MAX(EVENT_TIMESTAMP), CURRENT_TIMESTAMP()) AS LATENCY_SECONDS
FROM MY_DB.RAW.IOT_EVENTS;
```

---

### 8.2 EXAMPLE 2: Kafka Connector with Snowpipe Streaming

#### Step 1: Snowflake Setup

```sql
-- Create objects
CREATE DATABASE IF NOT EXISTS KAFKA_DB;
CREATE SCHEMA IF NOT EXISTS KAFKA_DB.STREAMING;

-- Create target table
CREATE OR REPLACE TABLE KAFKA_DB.STREAMING.USER_EVENTS (
    USER_ID NUMBER,
    EVENT_TYPE VARCHAR(50),
    EVENT_DATA VARIANT,
    EVENT_TIMESTAMP TIMESTAMP_NTZ
);

-- Create custom pipe with transformations
CREATE OR REPLACE PIPE KAFKA_DB.STREAMING.USER_EVENTS_PIPE AS
    COPY INTO KAFKA_DB.STREAMING.USER_EVENTS (USER_ID, EVENT_TYPE, EVENT_DATA, EVENT_TIMESTAMP)
    FROM (
        SELECT
            $1:user_id::NUMBER,
            $1:event_type::VARCHAR,
            $1:event_data,
            $1:timestamp::TIMESTAMP_NTZ
        FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))
    );

-- Create role for Kafka connector
CREATE ROLE IF NOT EXISTS KAFKA_STREAMING_ROLE;
GRANT USAGE ON DATABASE KAFKA_DB TO ROLE KAFKA_STREAMING_ROLE;
GRANT USAGE ON SCHEMA KAFKA_DB.STREAMING TO ROLE KAFKA_STREAMING_ROLE;
GRANT OWNERSHIP ON TABLE KAFKA_DB.STREAMING.USER_EVENTS TO ROLE KAFKA_STREAMING_ROLE;
GRANT OWNERSHIP ON PIPE KAFKA_DB.STREAMING.USER_EVENTS_PIPE TO ROLE KAFKA_STREAMING_ROLE;
```

#### Step 2: Kafka Connector Configuration (v4)

```json
{
    "name": "snowflake-streaming-sink",
    "config": {
        "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
        "tasks.max": "4",
        "topics": "user_events",
        "snowflake.url.name": "your_account.snowflakecomputing.com:443",
        "snowflake.user.name": "KAFKA_USER",
        "snowflake.private.key": "MIIEvQIBADANB...YOUR_PRIVATE_KEY...",
        "snowflake.role.name": "KAFKA_STREAMING_ROLE",
        "snowflake.database.name": "KAFKA_DB",
        "snowflake.schema.name": "STREAMING",
        "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter": "org.apache.kafka.connect.json.JsonConverter",
        "value.converter.schemas.enable": "false",
        "errors.tolerance": "ALL",
        "errors.deadletterqueue.topic.name": "user_events_dlq"
    }
}
```

#### Step 3: Deploy Connector

```bash
# Deploy in distributed mode
curl -X POST -H "Content-Type: application/json" \
    --data @snowflake-streaming-sink.json \
    http://localhost:8083/connectors

# Check connector status
curl http://localhost:8083/connectors/snowflake-streaming-sink/status
```

#### Step 4: Produce Test Messages to Kafka

```bash
# Using kafka-console-producer
echo '{"user_id": 1, "event_type": "login", "event_data": {"ip": "192.168.1.1"}, "timestamp": "2024-06-01T10:00:00"}' | \
    kafka-console-producer --broker-list localhost:9092 --topic user_events
```

#### Step 5: Verify in Snowflake

```sql
SELECT * FROM KAFKA_DB.STREAMING.USER_EVENTS LIMIT 10;
```

---

### 8.3 EXAMPLE 3: REST API (IoT / Edge Devices)

#### Step 1: Create Table

```sql
CREATE OR REPLACE TABLE MY_DB.RAW.EDGE_TELEMETRY (
    DEVICE_ID VARCHAR(100),
    METRIC_NAME VARCHAR(50),
    METRIC_VALUE FLOAT,
    REPORTED_AT TIMESTAMP_NTZ
);
```

#### Step 2: REST API Call (from IoT device / Edge)

```bash
# Authenticate and get token
# Then send rows via REST API

curl -X POST "https://your_account.snowflakecomputing.com/v1/streaming/channels/my_channel/rows" \
    -H "Authorization: Bearer <TOKEN>" \
    -H "Content-Type: application/json" \
    -d '{
        "rows": [
            {
                "DEVICE_ID": "edge_001",
                "METRIC_NAME": "cpu_temp",
                "METRIC_VALUE": 67.3,
                "REPORTED_AT": "2024-06-01T10:00:00Z"
            },
            {
                "DEVICE_ID": "edge_001",
                "METRIC_NAME": "memory_usage",
                "METRIC_VALUE": 82.1,
                "REPORTED_AT": "2024-06-01T10:00:00Z"
            }
        ],
        "offset_token": "batch_001"
    }'
```

---

### 8.4 EXAMPLE 4: CDC Pipeline (Debezium → Kafka → Snowpipe Streaming → Snowflake)

#### Architecture:

```
┌────────────┐    ┌──────────┐    ┌─────────┐    ┌──────────────────┐    ┌───────────┐
│ PostgreSQL │───→│ Debezium │───→│  Kafka  │───→│  Kafka Connector │───→│ Snowflake │
│  (Source)  │    │Connector │    │  Topic  │    │  (Snowpipe       │    │  (Target  │
│            │    │(WAL read)│    │         │    │   Streaming)     │    │   Table)  │
└────────────┘    └──────────┘    └─────────┘    └──────────────────┘    └───────────┘
```

#### Step 1: Snowflake Target Table

```sql
CREATE OR REPLACE TABLE CDC_DB.STREAMING.ORDERS (
    ORDER_ID NUMBER,
    CUSTOMER_ID NUMBER,
    AMOUNT DECIMAL(10,2),
    STATUS VARCHAR(20),
    OPERATION VARCHAR(1),
    CDC_TIMESTAMP TIMESTAMP_NTZ,
    INGESTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Custom pipe with CDC transformation
CREATE OR REPLACE PIPE CDC_DB.STREAMING.ORDERS_CDC_PIPE AS
    COPY INTO CDC_DB.STREAMING.ORDERS (ORDER_ID, CUSTOMER_ID, AMOUNT, STATUS, OPERATION, CDC_TIMESTAMP)
    FROM (
        SELECT
            COALESCE($1:after:order_id, $1:before:order_id)::NUMBER,
            COALESCE($1:after:customer_id, $1:before:customer_id)::NUMBER,
            COALESCE($1:after:amount, $1:before:amount)::DECIMAL(10,2),
            COALESCE($1:after:status, $1:before:status)::VARCHAR,
            $1:op::VARCHAR,
            TO_TIMESTAMP_NTZ($1:ts_ms::NUMBER / 1000)
        FROM TABLE(DATA_SOURCE(TYPE => 'STREAMING'))
    );
```

#### Step 2: Kafka Connector for CDC

```json
{
    "name": "cdc-orders-sink",
    "config": {
        "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
        "tasks.max": "2",
        "topics": "cdc.public.orders",
        "snowflake.url.name": "account.snowflakecomputing.com:443",
        "snowflake.user.name": "CDC_USER",
        "snowflake.private.key": "...",
        "snowflake.role.name": "CDC_STREAMING_ROLE",
        "snowflake.database.name": "CDC_DB",
        "snowflake.schema.name": "STREAMING",
        "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter": "io.confluent.connect.json.JsonSchemaConverter",
        "value.converter.schema.registry.url": "http://schema-registry:8081"
    }
}
```

#### Step 3: Process CDC in Snowflake (Stream + Task for final table)

```sql
-- Stream on the CDC landing table
CREATE OR REPLACE STREAM CDC_DB.STREAMING.ORDERS_STREAM
    ON TABLE CDC_DB.STREAMING.ORDERS;

-- Final target table (current state)
CREATE OR REPLACE TABLE CDC_DB.DW.ORDERS_CURRENT (
    ORDER_ID NUMBER PRIMARY KEY,
    CUSTOMER_ID NUMBER,
    AMOUNT DECIMAL(10,2),
    STATUS VARCHAR(20),
    LAST_UPDATED TIMESTAMP_NTZ
);

-- Task to apply CDC changes every minute
CREATE OR REPLACE TASK CDC_DB.STREAMING.APPLY_CDC_TASK
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('CDC_DB.STREAMING.ORDERS_STREAM')
AS
MERGE INTO CDC_DB.DW.ORDERS_CURRENT AS TGT
USING (
    SELECT *
    FROM CDC_DB.STREAMING.ORDERS_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY ORDER_ID ORDER BY CDC_TIMESTAMP DESC) = 1
) AS SRC
ON TGT.ORDER_ID = SRC.ORDER_ID
WHEN MATCHED AND SRC.OPERATION = 'd'
    THEN DELETE
WHEN MATCHED AND SRC.OPERATION IN ('u', 'c')
    THEN UPDATE SET
        TGT.CUSTOMER_ID = SRC.CUSTOMER_ID,
        TGT.AMOUNT = SRC.AMOUNT,
        TGT.STATUS = SRC.STATUS,
        TGT.LAST_UPDATED = SRC.CDC_TIMESTAMP
WHEN NOT MATCHED AND SRC.OPERATION IN ('c', 'r')
    THEN INSERT (ORDER_ID, CUSTOMER_ID, AMOUNT, STATUS, LAST_UPDATED)
    VALUES (SRC.ORDER_ID, SRC.CUSTOMER_ID, SRC.AMOUNT, SRC.STATUS, SRC.CDC_TIMESTAMP);

ALTER TASK CDC_DB.STREAMING.APPLY_CDC_TASK RESUME;
```

---

## 9. MONITORING AND OPERATIONS

### 9.1 Check Ingestion Costs

```sql
-- View Snowpipe Streaming costs
SELECT
    DATE_TRUNC('HOUR', START_TIME) AS HOUR,
    NAME AS PIPE_NAME,
    CREDITS_USED
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE SERVICE_TYPE = 'SNOWPIPE_STREAMING'
ORDER BY HOUR DESC;
```

### 9.2 Monitor File Migration (Classic Architecture)

```sql
-- Check file migration history
SELECT *
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWPIPE_STREAMING_FILE_MIGRATION_HISTORY
WHERE TABLE_NAME = 'IOT_EVENTS'
ORDER BY LAST_LOAD_TIME DESC
LIMIT 20;
```

### 9.3 Check Channel Status

```sql
-- View active channels and their offsets
SHOW CHANNELS IN TABLE MY_DB.RAW.IOT_EVENTS;
```

### 9.4 Alerting on Ingestion Lag

```sql
-- Alert if no new data in the last 5 minutes
CREATE OR REPLACE TASK MY_DB.MONITORING.CHECK_STREAMING_LAG
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '5 MINUTE'
AS
BEGIN
    LET last_event TIMESTAMP_NTZ;
    SELECT MAX(EVENT_TIMESTAMP) INTO :last_event FROM MY_DB.RAW.IOT_EVENTS;
    
    IF (DATEDIFF('MINUTE', :last_event, CURRENT_TIMESTAMP()) > 5) THEN
        CALL SYSTEM$SEND_EMAIL(
            'MY_EMAIL_INTEGRATION',
            'data-team@company.com',
            'Streaming Lag Alert',
            'No new IoT events in the last 5 minutes. Last event: ' || :last_event::VARCHAR
        );
    END IF;
END;
```

---

## 10. BILLING MODEL

### High-Performance Architecture (Current - GA Sep 2025):

| Aspect | Details |
|---|---|
| **Pricing model** | Flat rate per uncompressed GB ingested |
| **What's measured** | Input bytes received (uncompressed data values only, not keys) |
| **Warehouse needed?** | No (serverless) |
| **Scaling** | Automatic |
| **Rate** | See Snowflake Consumption Table for current credits/GB rate |

**Example calculation:**
- Ingesting at 1 MB/s
- Per hour: 1 MB/s × 3600 = 3.6 GB/hour
- Cost: 3.6 GB × (credits per GB rate) = credits consumed per hour

### Classic Architecture (Planned for Deprecation):

| Aspect | Details |
|---|---|
| **Pricing model** | Per-second compute + active client time |
| **Components** | Serverless compute (file migration) + client connection time |
| **Additional** | Temporary storage for intermediate files |

---

## 11. COMPARISON: ALL SNOWFLAKE INGESTION METHODS

| Method | Latency | Best For | Data Form | Ordering | Exactly-Once | Cost Model |
|---|---|---|---|---|---|---|
| **Snowpipe Streaming** | ~5 sec | Real-time events, IoT, CDC | Rows | ✓ | ✓ | Per-GB |
| **Snowpipe** | 30s - min | File-based auto-load | Files | ✗ | ✗ (at-least-once) | Per-file compute |
| **COPY INTO** | Manual | Bulk batch loads | Files | ✗ | ✗ | Warehouse credits |
| **Streams + Tasks** | 1+ min | SF-to-SF transforms | Internal | ✓ | ✓ | Warehouse credits |
| **Dynamic Tables** | 1+ min | Declarative pipelines | Internal | N/A | ✓ | Warehouse credits |
| **INSERT** | Immediate | Ad-hoc small loads | SQL | N/A | N/A | Warehouse credits |

---

## 12. BEST PRACTICES

### Architecture:
1. **One client per table/pipe** — Don't share clients across tables
2. **Channel per source partition** — Map Kafka partitions 1:1 to channels
3. **Batch rows before sending** — Don't send 1 row at a time; batch 100-1000 rows
4. **Use offset tokens** — Always track offsets for exactly-once recovery
5. **Enable schema evolution** — For dynamic schemas, set `ENABLE_SCHEMA_EVOLUTION = TRUE`

### Error Handling:
6. **Implement retry with backoff** — SDK returns errors on backpressure; don't busy-loop
7. **Monitor channel status** — Check `getChannelStatuses()` for error counts
8. **Use Dead Letter Queue** — Route broken records to DLQ for later inspection (Kafka)

### Performance:
9. **Pre-cluster at ingest** — Set `CLUSTER_AT_INGEST_TIME = TRUE` on the pipe if you have clustering keys
10. **Right-size channels** — More channels = more parallelism, but more overhead
11. **Use custom pipe for transforms** — Avoid post-load ETL; transform during ingestion

### Operations:
12. **Monitor costs** — Query `METERING_HISTORY` regularly
13. **Alert on lag** — Set up alerts if data stops flowing
14. **Test failover** — Verify your application recovers correctly from offset tokens

---

## 13. LIMITATIONS

- Maximum 10,000 channels per table
- Schema evolution: Only ADD COLUMN (no type change, no rename, no drop)
- Iceberg tables: No schema evolution, no partitioned tables
- VARCHAR columns on Iceberg: No length constraints allowed
- REST API: Lightweight only; use SDKs for high throughput
- Classic architecture: Planned for deprecation (mid-2026 announcement)
- Kafka Connector v4: No OAuth support, no regex router SMT
- Data must fit supported data types (see Snowflake docs for full list)

---

## 14. DECISION GUIDE

```
Q1: Does your data arrive as files in cloud storage?
    YES → Use Snowpipe (file-based auto-ingest)
    NO  → Continue to Q2

Q2: Do you need sub-10 second latency?
    NO  → Use COPY INTO (batch) or Snowpipe (auto-ingest)
    YES → Continue to Q3

Q3: Is your source Apache Kafka?
    YES → Use Snowflake Kafka Connector v4 (Snowpipe Streaming built-in)
    NO  → Continue to Q4

Q4: Is your source IoT/Edge devices with limited capabilities?
    YES → Use Snowpipe Streaming REST API
    NO  → Use Snowpipe Streaming SDK (Java/Python/Node.js)
```
