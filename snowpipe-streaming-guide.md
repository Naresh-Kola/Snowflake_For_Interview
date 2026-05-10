# Consuming Kafka Topics into Snowflake Using Snowpipe Streaming

A step-by-step guide to ingest data from our 3 Kafka topics
(`weather-raw-data`, `weather-predictions`, `weather-alerts`) into Snowflake
tables using the **Snowflake Kafka Connector with Snowpipe Streaming**.

---

## Table of Contents

1. [What is Snowpipe Streaming?](#step-0-what-is-snowpipe-streaming)
2. [Prerequisites Checklist](#step-1-prerequisites-checklist)
3. [Create a Snowflake Database and Schema](#step-2-create-a-snowflake-database-and-schema)
4. [Create the 3 Target Tables in Snowflake](#step-3-create-the-3-target-tables-in-snowflake)
5. [Create a Snowflake Role and User for the Connector](#step-4-create-a-snowflake-role-and-user-for-the-connector)
6. [Generate a Key Pair for Authentication](#step-5-generate-a-key-pair-for-authentication)
7. [Assign the Public Key to the Snowflake User](#step-6-assign-the-public-key-to-the-snowflake-user)
8. [Download the Kafka Connector JAR](#step-7-download-the-kafka-connector-jar)
9. [Add Kafka Connect to Docker Compose](#step-8-add-kafka-connect-to-docker-compose)
10. [Create the Connector Configuration Files](#step-9-create-the-connector-configuration-files)
11. [Deploy the Connectors](#step-10-deploy-the-connectors)
12. [Verify Data is Flowing into Snowflake](#step-11-verify-data-is-flowing-into-snowflake)
13. [Troubleshooting Common Issues](#troubleshooting-common-issues)
14. [Architecture Diagram](#architecture-diagram)

---

## Step 0: What is Snowpipe Streaming?

### The Old Way (Snowpipe / File-based)

In the traditional approach, Kafka data is first written to files (CSV/JSON) in a cloud stage (S3, Azure Blob, GCS), and then Snowpipe picks up those files and loads them into tables. This introduces a **1-2 minute delay** because of the file write and notification cycle.

```
Kafka --> Files on S3 --> Snowpipe notification --> Snowflake table
                  ^                    ^
             (file write delay)   (notification delay)
         Total latency: 1-2 minutes
```

### The New Way (Snowpipe Streaming)

Snowpipe Streaming **skips the file stage entirely**. The Kafka Connector writes rows **directly into Snowflake tables** using the Snowpipe Streaming API. This gives you **sub-second to single-digit-second latency**.

```
Kafka --> Snowflake Kafka Connector --> Snowflake table (directly)
                                    ^
                              No intermediate files!
                         Total latency: < 10 seconds
```

### Real-Life Analogy

- **Old way (Snowpipe)**: Like mailing a letter -- you write the letter, put it in a mailbox, wait for the postman, and then the recipient gets it hours later.
- **New way (Snowpipe Streaming)**: Like sending a text message -- you type it and the recipient sees it within seconds.

### Key Benefits

| Feature | Snowpipe (File-based) | Snowpipe Streaming |
|---------|----------------------|-------------------|
| Latency | 1-2 minutes | < 10 seconds |
| Intermediate storage | Requires cloud stage (S3/Azure/GCS) | None needed |
| Cost | Pay per file loaded | Pay per row inserted (cheaper for small frequent batches) |
| Setup complexity | Need stage + pipe + notification | Just connector + table |
| Best for | Large batch loads | Real-time / near-real-time streaming |

---

## Step 1: Prerequisites Checklist

Before starting, make sure you have everything in place:

| # | Prerequisite | How to Check |
|---|-------------|-------------|
| 1 | Docker containers running (broker-1, broker-2, kafka-ui) | `docker ps` |
| 2 | Kafka topics created | Visit `http://localhost:8081` (Kafka UI) |
| 3 | Weather producer generating data | `python weather_producer.py` shows output |
| 4 | Snowflake account with ACCOUNTADMIN or SYSADMIN access | Log in to Snowflake console |
| 5 | OpenSSL installed (for key pair generation) | `openssl version` in terminal |

### Why Each Prerequisite Matters

- **Docker containers**: The Kafka brokers must be running so the connector can read from them.
- **Kafka topics**: The connector subscribes to topics -- they must exist before the connector starts.
- **Weather producer**: Generates the data that flows through the pipeline.
- **Snowflake account**: The destination database where data lands.
- **OpenSSL**: Used to create RSA key pair for secure authentication (no passwords over the wire).
- **No Java needed on your machine**: Kafka Connect runs inside the Docker container (`apache/kafka:3.7.0`), which already includes Java. You only interact with it via REST API calls.
---

## Step 2: Create a Snowflake Database and Schema

This step creates a dedicated database and schema in Snowflake to hold our weather data.

### Why a Separate Database?

Keeping project data in its own database makes it easy to manage permissions, clean up, and avoid cluttering other databases. Think of it like having a **separate filing cabinet** for this project instead of mixing files into an existing one.

### SQL to Run in Snowflake

```sql
-- Step 2a: Create a dedicated database for the weather pipeline
CREATE DATABASE IF NOT EXISTS WEATHER_PIPELINE;

-- Step 2b: Create a schema to organize our tables
CREATE SCHEMA IF NOT EXISTS WEATHER_PIPELINE.KAFKA_DATA;

-- Step 2c: Verify they exist
SHOW SCHEMAS IN DATABASE WEATHER_PIPELINE;
```

### What Each Command Does

| Command | Purpose |
|---------|---------|
| `CREATE DATABASE IF NOT EXISTS WEATHER_PIPELINE` | Creates the database. `IF NOT EXISTS` prevents errors on re-run. |
| `CREATE SCHEMA IF NOT EXISTS WEATHER_PIPELINE.KAFKA_DATA` | Creates a schema (folder inside the database) for our tables. |
| `SHOW SCHEMAS IN DATABASE WEATHER_PIPELINE` | Lists all schemas so you can confirm KAFKA_DATA was created. |

---

## Step 3: Create the 3 Target Tables in Snowflake

We need one Snowflake table per Kafka topic. The Kafka Connector will insert rows into these tables automatically.

### Important: Schema Design Choice

| Approach | Description | When to Use |
|----------|-------------|-------------|
| **Schematized** | Define individual columns matching each JSON field | When you know the exact schema and want query performance |
| **Semi-structured** | Use a single VARIANT column to store the entire JSON | When schema may change or you want flexibility |

We will use the **schematized approach** because our JSON structure is well-defined and stable.

### SQL to Run in Snowflake

```sql
USE DATABASE WEATHER_PIPELINE;
USE SCHEMA KAFKA_DATA;

-- Table 1: WEATHER_RAW_DATA (from weather-raw-data topic)
-- ~120 rows/minute (6 cities x 20 batches/min)
CREATE OR REPLACE TABLE WEATHER_RAW_DATA (
    RECORD_METADATA         VARIANT,        -- Kafka metadata (offset, partition, topic)
    CITY                    VARCHAR(50),
    TIMESTAMP               TIMESTAMP_NTZ,
    TEMPERATURE_C           FLOAT,
    HUMIDITY_PCT            FLOAT,
    WIND_SPEED_KMH          FLOAT,
    WIND_DIRECTION          VARCHAR(5),
    PRESSURE_HPA            FLOAT,
    CLOUD_COVER_PCT         FLOAT,
    UV_INDEX                FLOAT,
    VISIBILITY_KM           FLOAT,
    RAIN_PROBABILITY_PCT    FLOAT
);

-- Table 2: WEATHER_PREDICTIONS (from weather-predictions topic)
-- ~24 rows/minute (6 cities every 5th batch)
CREATE OR REPLACE TABLE WEATHER_PREDICTIONS (
    RECORD_METADATA         VARIANT,
    CITY                    VARCHAR(50),
    GENERATED_AT            TIMESTAMP_NTZ,
    FORECAST_DAYS           INT,
    BASED_ON_READINGS       INT,
    PREDICTIONS             VARIANT          -- Nested JSON array of 7 daily predictions
);

-- Table 3: WEATHER_ALERTS (from weather-alerts topic)
-- Variable volume (~40-80 rows/minute)
CREATE OR REPLACE TABLE WEATHER_ALERTS (
    RECORD_METADATA         VARIANT,
    CITY                    VARCHAR(50),
    TIMESTAMP               TIMESTAMP_NTZ,
    SEVERITY                VARCHAR(10),     -- HIGH, MEDIUM, or LOW
    ALERT_TYPE              VARCHAR(50),
    ACTUAL_VALUE            FLOAT,
    THRESHOLD               FLOAT,
    MESSAGE                 VARCHAR(500)
);
```

### Why RECORD_METADATA?

Every message the Kafka Connector inserts includes a `RECORD_METADATA` VARIANT column with Kafka metadata:

```json
{
  "CreateTime": 1713028835123,
  "offset": 42,
  "partition": 1,
  "topic": "weather-raw-data"
}
```

Useful for debugging, deduplication, and ordering.

### Why PREDICTIONS is VARIANT?

The `predictions` field is a nested JSON array with 7 objects. We store it as VARIANT and query like this:

```sql
-- Get Day 1 prediction for Mumbai
SELECT
    CITY, GENERATED_AT,
    PREDICTIONS[0]:date::STRING           AS day1_date,
    PREDICTIONS[0]:temp_high_c::FLOAT     AS day1_high,
    PREDICTIONS[0]:temp_low_c::FLOAT      AS day1_low,
    PREDICTIONS[0]:condition::STRING      AS day1_condition,
    PREDICTIONS[0]:confidence_pct::FLOAT  AS day1_confidence
FROM WEATHER_PREDICTIONS
WHERE CITY = 'Mumbai'
ORDER BY GENERATED_AT DESC LIMIT 1;
```
---

## Step 4: Create a Snowflake Role and User for the Connector

The Kafka Connector needs its own Snowflake user with minimum permissions (principle of least privilege).

### Real-Life Analogy

Think of it like giving a **delivery driver a keycard** that only opens the loading dock -- not the master key to the entire building.

### SQL to Run in Snowflake

```sql
-- Create a role for the Kafka connector
CREATE ROLE IF NOT EXISTS KAFKA_CONNECTOR_ROLE;

-- Grant access to our database and schema
GRANT USAGE ON DATABASE WEATHER_PIPELINE TO ROLE KAFKA_CONNECTOR_ROLE;
GRANT USAGE ON SCHEMA WEATHER_PIPELINE.KAFKA_DATA TO ROLE KAFKA_CONNECTOR_ROLE;

-- Grant INSERT and SELECT on all current and future tables
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA WEATHER_PIPELINE.KAFKA_DATA TO ROLE KAFKA_CONNECTOR_ROLE;
GRANT INSERT, SELECT ON FUTURE TABLES IN SCHEMA WEATHER_PIPELINE.KAFKA_DATA TO ROLE KAFKA_CONNECTOR_ROLE;
GRANT CREATE TABLE ON SCHEMA WEATHER_PIPELINE.KAFKA_DATA TO ROLE KAFKA_CONNECTOR_ROLE;

-- Create a dedicated user
CREATE USER IF NOT EXISTS KAFKA_CONNECTOR_USER
    DEFAULT_ROLE = KAFKA_CONNECTOR_ROLE
    DEFAULT_WAREHOUSE = COMPUTE_WH
    COMMENT = 'Service account for Kafka Snowpipe Streaming connector';

-- Assign the role and warehouse access
GRANT ROLE KAFKA_CONNECTOR_ROLE TO USER KAFKA_CONNECTOR_USER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE KAFKA_CONNECTOR_ROLE;
```

### What Each Permission Does

| Permission | Why |
|-----------|-----|
| `USAGE ON DATABASE` | Allows the user to "enter" the database |
| `USAGE ON SCHEMA` | Allows the user to "enter" the schema |
| `INSERT ON TABLES` | Allows writing new rows (what the connector does) |
| `SELECT ON TABLES` | Allows reading rows (needed for schema detection) |
| `CREATE TABLE` | Allows connector to create tables if they do not exist |
| `USAGE ON WAREHOUSE` | Provides compute resources for operations |

---

## Step 5: Generate a Key Pair for Authentication

The Snowflake Kafka Connector uses **key pair authentication** instead of username/password. This is more secure because no password is ever sent over the network, the private key never leaves your machine, and keys can be rotated independently.

### Real-Life Analogy

Think of it like a **house lock with two keys**:
- The **private key** is the key you keep in your pocket (never share it)
- The **public key** is the lock on the door (you give it to Snowflake)
- Only your private key can open the lock

### Commands to Run in Your Terminal

```powershell
# Navigate to the project directory
cd "C:\Users\naresh.kola\OneDrive - InnovaSolutions\Desktop\Kafka_SF"

# Generate a 2048-bit RSA private key (unencrypted for development)
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out snowflake_kafka_key.p8 -nocrypt
# For PRODUCTION, remove -nocrypt and set a passphrase.

# Extract the public key from the private key
openssl rsa -in snowflake_kafka_key.p8 -pubout -out snowflake_kafka_key.pub

# Verify the files were created
dir snowflake_kafka_key*
```

| File | What It Is | Who Sees It |
|------|-----------|-------------|
| `snowflake_kafka_key.p8` | **Private key** -- used by the connector | Only the connector (NEVER share) |
| `snowflake_kafka_key.pub` | **Public key** -- registered with Snowflake | Stored in Snowflake |

**IMPORTANT**: Never commit the private key. Add `*.p8` to `.gitignore`.

---

## Step 6: Assign the Public Key to the Snowflake User

### Get the Public Key Value

```powershell
# Display the public key
Get-Content snowflake_kafka_key.pub

# To get a single-line version (remove header/footer):
(Get-Content snowflake_kafka_key.pub) -notmatch 'PUBLIC KEY' -join ''
```

### SQL to Run in Snowflake

```sql
-- Replace <paste-public-key-here> with the base64 string (no line breaks)
ALTER USER KAFKA_CONNECTOR_USER SET RSA_PUBLIC_KEY = '<paste-public-key-here>';

-- Verify the key was assigned
DESCRIBE USER KAFKA_CONNECTOR_USER;
```
---

## Step 7: Download the Kafka Connector JAR

The Snowflake Kafka Connector is a plugin (JAR file) that runs inside the Kafka Connect Docker container. You download the JAR to your project folder, and Docker mounts it into the container. No Java installation needed on your machine.

### Commands to Run

```powershell
# Create a directory for connector plugins
mkdir connect-plugins

# Download the Snowflake Kafka Connector JAR
curl -L -o connect-plugins/snowflake-kafka-connector-2.4.1.jar `
    "https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/2.4.1/snowflake-kafka-connector-2.4.1.jar"

# Download Bouncy Castle dependencies (required for key pair auth)
curl -L -o connect-plugins/bc-fips-1.0.2.4.jar `
    "https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.4/bc-fips-1.0.2.4.jar"

curl -L -o connect-plugins/bcpkix-fips-1.0.7.jar `
    "https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar"

# Verify
dir connect-plugins
```

| File | Purpose | Size |
|------|---------|------|
| `snowflake-kafka-connector-2.4.1.jar` | Snowflake connector plugin | ~50 MB |
| `bc-fips-1.0.2.4.jar` | Bouncy Castle crypto library | ~6 MB |
| `bcpkix-fips-1.0.7.jar` | Bouncy Castle PKIX support | ~1 MB |

---

## Step 8: Add Kafka Connect to Docker Compose

Kafka Connect is a **separate process** that runs alongside your Kafka brokers. If Kafka brokers are the **post office**, then Kafka Connect is the **delivery truck** that picks up mail and delivers it to Snowflake.

### What to Add to docker-compose.yml

Add this block **after kafka-ui** and **before volumes**:

```yaml
  kafka-connect:
    image: apache/kafka:3.7.0
    container_name: kafka-connect
    hostname: kafka-connect
    ports:
      - "8083:8083"
    environment:
      CONNECT_BOOTSTRAP_SERVERS: broker-1:19092,broker-2:19092
      CONNECT_GROUP_ID: snowflake-connect-group
      CONNECT_CONFIG_STORAGE_TOPIC: _connect-configs
      CONNECT_OFFSET_STORAGE_TOPIC: _connect-offsets
      CONNECT_STATUS_STORAGE_TOPIC: _connect-status
      CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR: 2
      CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR: 2
      CONNECT_STATUS_STORAGE_REPLICATION_FACTOR: 2
      CONNECT_KEY_CONVERTER: org.apache.kafka.connect.storage.StringConverter
      CONNECT_VALUE_CONVERTER: com.snowflake.kafka.connector.records.SnowflakeJsonConverter
      CONNECT_REST_ADVERTISED_HOST_NAME: kafka-connect
      CONNECT_PLUGIN_PATH: /opt/kafka/connect-plugins
    volumes:
      - ./connect-plugins:/opt/kafka/connect-plugins
      - ./snowflake_kafka_key.p8:/opt/kafka/snowflake_kafka_key.p8:ro
    depends_on:
      - broker-1
      - broker-2
    command: >
      /opt/kafka/bin/connect-distributed.sh
      /opt/kafka/config/connect-distributed.properties
```

### Key Settings Explained

| Setting | Purpose |
|---------|---------|
| `CONNECT_BOOTSTRAP_SERVERS` | Where Kafka brokers are (internal Docker ports) |
| `CONNECT_GROUP_ID` | Unique name for this Connect cluster |
| `CONNECT_*_STORAGE_TOPIC` | Internal Kafka topics for storing configs, offsets, status |
| `CONNECT_KEY_CONVERTER` | Deserialize keys (plain strings like "Mumbai") |
| `CONNECT_VALUE_CONVERTER` | Deserialize values (JSON via SnowflakeJsonConverter) |
| `CONNECT_PLUGIN_PATH` | Where connector JARs live inside the container |

### Port 8083: The REST API

Kafka Connect exposes a REST API on port 8083 for managing connectors:
- **POST** `/connectors` -- Create a new connector
- **GET** `/connectors/{name}/status` -- Check health
- **PUT** `/connectors/{name}/pause` -- Pause
- **DELETE** `/connectors/{name}` -- Remove

### Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `./connect-plugins` | `/opt/kafka/connect-plugins` | JAR files for the connector |
| `./snowflake_kafka_key.p8` | `/opt/kafka/snowflake_kafka_key.p8` | Private key (`:ro` = read-only) |
---

## Step 9: Create the Connector Configuration Files

Each Kafka topic needs its own connector configuration -- **3 JSON files, one per topic**.

### Why 3 Separate Connectors (Not 1)?

- **Independent control**: Pause/restart one topic without affecting others
- **Independent monitoring**: See status and lag of each topic separately
- **Independent error handling**: If alerts connector fails, raw data still flows
- **Different settings**: Each table gets different buffer sizes and flush intervals

### File 1: `connect-snowflake-raw.json`

```json
{
    "name": "snowflake-weather-raw",
    "config": {
        "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
        "tasks.max": "2",
        "topics": "weather-raw-data",
        "snowflake.url.name": "<your-account>.snowflakecomputing.com",
        "snowflake.user.name": "KAFKA_CONNECTOR_USER",
        "snowflake.private.key.path": "/opt/kafka/snowflake_kafka_key.p8",
        "snowflake.database.name": "WEATHER_PIPELINE",
        "snowflake.schema.name": "KAFKA_DATA",
        "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
        "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
        "snowflake.enable.schematization": "true",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter": "com.snowflake.kafka.connector.records.SnowflakeJsonConverter",
        "buffer.count.records": "1000",
        "buffer.flush.time": "10",
        "buffer.size.bytes": "5000000"
    }
}
```

### File 2: `connect-snowflake-predictions.json`

```json
{
    "name": "snowflake-weather-predictions",
    "config": {
        "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
        "tasks.max": "2",
        "topics": "weather-predictions",
        "snowflake.url.name": "<your-account>.snowflakecomputing.com",
        "snowflake.user.name": "KAFKA_CONNECTOR_USER",
        "snowflake.private.key.path": "/opt/kafka/snowflake_kafka_key.p8",
        "snowflake.database.name": "WEATHER_PIPELINE",
        "snowflake.schema.name": "KAFKA_DATA",
        "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
        "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
        "snowflake.enable.schematization": "true",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter": "com.snowflake.kafka.connector.records.SnowflakeJsonConverter",
        "buffer.count.records": "100",
        "buffer.flush.time": "30",
        "buffer.size.bytes": "5000000"
    }
}
```

### File 3: `connect-snowflake-alerts.json`

```json
{
    "name": "snowflake-weather-alerts",
    "config": {
        "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
        "tasks.max": "1",
        "topics": "weather-alerts",
        "snowflake.url.name": "<your-account>.snowflakecomputing.com",
        "snowflake.user.name": "KAFKA_CONNECTOR_USER",
        "snowflake.private.key.path": "/opt/kafka/snowflake_kafka_key.p8",
        "snowflake.database.name": "WEATHER_PIPELINE",
        "snowflake.schema.name": "KAFKA_DATA",
        "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
        "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
        "snowflake.enable.schematization": "true",
        "key.converter": "org.apache.kafka.connect.storage.StringConverter",
        "value.converter": "com.snowflake.kafka.connector.records.SnowflakeJsonConverter",
        "buffer.count.records": "50",
        "buffer.flush.time": "5",
        "buffer.size.bytes": "1000000"
    }
}
```

### Key Configuration Fields

| Field | Description |
|-------|-------------|
| `connector.class` | Always `com.snowflake.kafka.connector.SnowflakeSinkConnector` |
| `tasks.max` | Parallel workers: 2 for raw/predictions (3 partitions), 1 for alerts (2 partitions) |
| `snowflake.url.name` | Your Snowflake account URL (e.g., `orgname-acctname.snowflakecomputing.com`) |
| `snowflake.private.key.path` | Path to private key **inside the container** |
| `snowflake.ingestion.method` | **`SNOWPIPE_STREAMING`** -- the key setting that enables direct streaming! |
| `snowflake.enable.schematization` | `true` = map JSON fields to table columns |
| `buffer.count.records` | Flush after N records |
| `buffer.flush.time` | Flush after N seconds even if buffer not full |
| `buffer.size.bytes` | Flush if buffer exceeds this size |

### Why Different Buffer Settings?

| Topic | buffer.count | buffer.flush.time | Reason |
|-------|-------------|-------------------|--------|
| weather-raw-data | 1000 | 10s | High volume -- batch for efficiency |
| weather-predictions | 100 | 30s | Low volume -- can wait longer |
| weather-alerts | 50 | 5s | Alerts are urgent -- flush quickly! |

### IMPORTANT: Replace `<your-account>`

In all 3 files, replace `<your-account>.snowflakecomputing.com` with your actual Snowflake account URL. Find it by logging into Snowflake > Account > Copy Account URL.
---

## Step 10: Deploy the Connectors

Use the Kafka Connect REST API to create each connector.

### Commands to Run

```powershell
# Start all services including kafka-connect
docker compose up -d

# Wait 30-60 seconds, then check readiness
curl http://localhost:8083/connectors
# Should return: []

# Deploy the 3 connectors
curl -X POST http://localhost:8083/connectors `
    -H "Content-Type: application/json" `
    -d (Get-Content connect-snowflake-raw.json -Raw)

curl -X POST http://localhost:8083/connectors `
    -H "Content-Type: application/json" `
    -d (Get-Content connect-snowflake-predictions.json -Raw)

curl -X POST http://localhost:8083/connectors `
    -H "Content-Type: application/json" `
    -d (Get-Content connect-snowflake-alerts.json -Raw)

# Verify all 3 exist
curl http://localhost:8083/connectors
# Should return: ["snowflake-weather-raw","snowflake-weather-predictions","snowflake-weather-alerts"]
```

### Checking Connector Status

```powershell
curl http://localhost:8083/connectors/snowflake-weather-raw/status
curl http://localhost:8083/connectors/snowflake-weather-predictions/status
curl http://localhost:8083/connectors/snowflake-weather-alerts/status
```

A healthy response:
```json
{
    "name": "snowflake-weather-raw",
    "connector": { "state": "RUNNING", "worker_id": "kafka-connect:8083" },
    "tasks": [
        { "id": 0, "state": "RUNNING", "worker_id": "kafka-connect:8083" },
        { "id": 1, "state": "RUNNING", "worker_id": "kafka-connect:8083" }
    ]
}
```

If any task shows `FAILED`: `docker logs kafka-connect --tail 100`

---

## Step 11: Verify Data is Flowing into Snowflake

### Step 11a: Start the Weather Producer

```powershell
cd "C:\Users\naresh.kola\OneDrive - InnovaSolutions\Desktop\Kafka_SF"
.\env\Scripts\Activate.ps1
python weather_producer.py
```

### Step 11b: Wait ~30 Seconds, Then Query Snowflake

```sql
SELECT 'WEATHER_RAW_DATA' AS TABLE_NAME, COUNT(*) AS ROW_COUNT
    FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
UNION ALL
SELECT 'WEATHER_PREDICTIONS', COUNT(*)
    FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_PREDICTIONS
UNION ALL
SELECT 'WEATHER_ALERTS', COUNT(*)
    FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS;
```

### Step 11c: Query the Actual Data

```sql
-- Latest 5 raw readings
SELECT CITY, TIMESTAMP, TEMPERATURE_C, HUMIDITY_PCT, WIND_SPEED_KMH
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
ORDER BY TIMESTAMP DESC LIMIT 5;

-- Latest prediction for Mumbai (flatten nested array)
SELECT CITY, GENERATED_AT,
    f.value:date::STRING AS forecast_date,
    f.value:temp_high_c::FLOAT AS high_temp,
    f.value:temp_low_c::FLOAT AS low_temp,
    f.value:condition::STRING AS condition,
    f.value:confidence_pct::FLOAT AS confidence
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_PREDICTIONS,
    LATERAL FLATTEN(input => PREDICTIONS) f
WHERE CITY = 'Mumbai'
ORDER BY GENERATED_AT DESC, f.index LIMIT 7;

-- All HIGH severity alerts
SELECT CITY, TIMESTAMP, SEVERITY, ALERT_TYPE, ACTUAL_VALUE, THRESHOLD, MESSAGE
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS
WHERE SEVERITY = 'HIGH'
ORDER BY TIMESTAMP DESC LIMIT 10;
```

### Step 11d: Monitor Ingestion Latency

```sql
SELECT
    MAX(TIMESTAMP) AS LATEST_RECORD,
    CURRENT_TIMESTAMP() AS CURRENT_TIME,
    DATEDIFF('second', MAX(TIMESTAMP), CURRENT_TIMESTAMP()) AS LAG_SECONDS
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA;
```

If `LAG_SECONDS` is consistently under 15, Snowpipe Streaming is working correctly.
---

## Troubleshooting Common Issues

### Issue 1: Connector status shows FAILED

| Error Message | Cause | Fix |
|--------------|-------|-----|
| `SnowflakeSQLException: ... authentication` | Wrong key pair or user | Re-check Steps 5 and 6 |
| `Table WEATHER_RAW_DATA does not exist` | Tables not created | Run Step 3 SQL |
| `User does not have INSERT privilege` | Missing permissions | Re-run Step 4 SQL |
| `Connection refused` | Wrong `snowflake.url.name` | Fix account URL in JSON files |

### Issue 2: Tables exist but no data appears

| Check | Command |
|-------|---------|
| Is weather_producer running? | Look at terminal output |
| Is Kafka Connect healthy? | `curl http://localhost:8083/connectors` |
| Are connectors running? | `curl http://localhost:8083/connectors/snowflake-weather-raw/status` |
| Is there Kafka lag? | Check Kafka UI at `http://localhost:8081` |

### Issue 3: Connector keeps restarting

Common causes:
- **JVM memory**: Add `KAFKA_HEAP_OPTS: "-Xms256m -Xmx1g"` to kafka-connect environment
- **Missing JARs**: Verify all 3 JAR files in `connect-plugins/`

### Issue 4: Duplicate rows

Snowpipe Streaming provides **at-least-once delivery**. To deduplicate:

```sql
SELECT * FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY RECORD_METADATA:offset, RECORD_METADATA:partition
    ORDER BY RECORD_METADATA:CreateTime DESC
) = 1;
```

---

## Architecture Diagram

```
Your Machine (Docker Desktop)
+---------------------------------------------------------------+
|                                                               |
|  weather_producer.py                                          |
|       |                                                       |
|       | (produces JSON messages)                              |
|       v                                                       |
|  +-------------------+    +-------------------+               |
|  |   broker-1        |    |   broker-2        |               |
|  |   (Kafka KRaft)   |<-->|   (Kafka KRaft)   |               |
|  |   Port: 9092      |    |   Port: 9094      |               |
|  +-------------------+    +-------------------+               |
|       |                                                       |
|       | (Kafka topics: weather-raw-data,                      |
|       |  weather-predictions, weather-alerts)                 |
|       v                                                       |
|  +---------------------------------------------------+       |
|  |   kafka-connect (Port: 8083)                       |       |
|  |                                                     |      |
|  |   3 Snowflake Sink Connectors:                     |       |
|  |     - snowflake-weather-raw                        |       |
|  |     - snowflake-weather-predictions                |       |
|  |     - snowflake-weather-alerts                     |       |
|  |                                                     |      |
|  |   Uses: Snowpipe Streaming API                     |       |
|  |   Auth:  Key pair (RSA 2048-bit)                   |       |
|  +---------------------------------------------------+       |
|       |                                                       |
+-------|-------------------------------------------------------+
        |
        | (Snowpipe Streaming -- direct row insertion)
        | (encrypted TLS connection over the internet)
        v
+---------------------------------------------------------------+
|   Snowflake Cloud                                             |
|                                                               |
|   Database: WEATHER_PIPELINE                                  |
|   Schema:   KAFKA_DATA                                        |
|                                                               |
|   +------------------+  +---------------------+               |
|   | WEATHER_RAW_DATA |  | WEATHER_PREDICTIONS |               |
|   | ~120 rows/min    |  | ~24 rows/min        |               |
|   +------------------+  +---------------------+               |
|                                                               |
|   +------------------+                                        |
|   | WEATHER_ALERTS   |                                        |
|   | ~40-80 rows/min  |                                        |
|   +------------------+                                        |
|                                                               |
|   User: KAFKA_CONNECTOR_USER                                  |
|   Role: KAFKA_CONNECTOR_ROLE                                  |
+---------------------------------------------------------------+
```

---

## Summary: Execution Order

| Step | What | Where |
|------|------|-------|
| 1 | Check prerequisites | Terminal |
| 2 | Create database and schema | Snowflake SQL |
| 3 | Create 3 target tables | Snowflake SQL |
| 4 | Create role and user | Snowflake SQL |
| 5 | Generate RSA key pair | Terminal (OpenSSL) |
| 6 | Assign public key to user | Snowflake SQL |
| 7 | Download connector JARs | Terminal (curl) |
| 8 | Add kafka-connect to docker-compose.yml | Edit file |
| 9 | Create 3 connector JSON configs | Create files |
| 10 | Deploy connectors via REST API | Terminal (curl) |
| 11 | Verify data in Snowflake | Snowflake SQL |
ca
### New Files After Completing All Steps


```
Kafka_SF/
  docker-compose.yml                     (MODIFIED -- added kafka-connect service)
  create_topics.py
  weather_producer.py
  requirements.txt
  env/
  snowflake_kafka_key.p8                 (NEW -- private key, DO NOT SHARE)
  snowflake_kafka_key.pub                (NEW -- public key)
  connect-plugins/                       (NEW -- directory)
    snowflake-kafka-connector-2.4.1.jar  (NEW -- connector JAR)
    bc-fips-1.0.2.4.jar                  (NEW -- crypto dependency)
    bcpkix-fips-1.0.7.jar               (NEW -- crypto dependency)
  connect-snowflake-raw.json             (NEW -- connector config)
  connect-snowflake-predictions.json     (NEW -- connector config)
  connect-snowflake-alerts.json          (NEW -- connector config)
  errors-encountered.md
  docker-compose-explained.md
  weather-producer-explained.md
  project-setup-guide.md
  kafka-topics-explained.md
  snowpipe-streaming-guide.md            (THIS FILE)
```
