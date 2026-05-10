# Kafka to Snowflake Pipeline -- Complete Setup Guide

This guide walks through every step we followed to build a real-time data pipeline that streams weather data from Apache Kafka into Snowflake using Snowpipe Streaming.

---

## Architecture Overview

```
 Python Producer (weather_producer.py)
         |
         | JSON messages
         v
 +-------------------+
 |   Kafka Brokers   |  (broker-1, broker-2 -- KRaft mode, no Zookeeper)
 |   Docker Compose  |
 +-------------------+
         |
    3 Kafka Topics:
    - weather-raw-data      (3 partitions, RF=2)
    - weather-predictions   (3 partitions, RF=2)
    - weather-alerts        (2 partitions, RF=2)
         |
         v
 +-------------------+
 |   Kafka Connect   |  (Confluent cp-kafka-connect-base:7.6.0)
 | 3 Sink Connectors |  (Snowflake Kafka Connector 2.4.1)
 +-------------------+
         |
         | Snowpipe Streaming (direct row insert, no staging files)
         v
 +-------------------+
 |    Snowflake      |  WEATHER_PIPELINE.KAFKA_DATA
 | 3 Target Tables   |
 +-------------------+
```

**Data flow**: The Python producer generates synthetic weather data for 6 Indian cities every 3 seconds. Kafka Connect reads from the 3 topics and inserts rows directly into Snowflake tables via Snowpipe Streaming -- no intermediate file staging, sub-10-second latency.

---

## Prerequisites

- Docker Desktop installed and running
- Python 3.8+ with a virtual environment
- A Snowflake account (with ACCOUNTADMIN or equivalent privileges for initial setup)
- Internet access (to pull Docker images and download JARs)

---

## Step 1: Set Up Docker Compose (Kafka Cluster)

We use Docker Compose to run 2 Kafka brokers in KRaft mode (no Zookeeper), a Kafka UI for monitoring, and a Kafka Connect worker.

**File**: `docker-compose.yml`

```yaml
version: '3.8'

services:
  broker-1:
    image: apache/kafka:3.7.0
    container_name: broker-1
    hostname: broker-1
    ports:
      - "9092:9092"
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:19092,CONTROLLER://0.0.0.0:9093,EXTERNAL://0.0.0.0:9092
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker-1:19092,EXTERNAL://localhost:9092
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@broker-1:9093,2@broker-2:9093
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 2
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 2
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_NUM_PARTITIONS: 3
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      CLUSTER_ID: 'MkU3OEVBNTcwNTJENDM2Qk'
    volumes:
      - broker1-data:/var/lib/kafka/data

  broker-2:
    image: apache/kafka:3.7.0
    container_name: broker-2
    hostname: broker-2
    ports:
      - "9094:9094"
    environment:
      KAFKA_NODE_ID: 2
      KAFKA_PROCESS_ROLES: broker,controller
      KAFKA_LISTENERS: PLAINTEXT://0.0.0.0:19092,CONTROLLER://0.0.0.0:9093,EXTERNAL://0.0.0.0:9094
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://broker-2:19092,EXTERNAL://localhost:9094
      KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,EXTERNAL:PLAINTEXT
      KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
      KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
      KAFKA_CONTROLLER_QUORUM_VOTERS: 1@broker-1:9093,2@broker-2:9093
      KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS: 0
      KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 2
      KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 2
      KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 1
      KAFKA_NUM_PARTITIONS: 3
      KAFKA_LOG_DIRS: /var/lib/kafka/data
      CLUSTER_ID: 'MkU3OEVBNTcwNTJENDM2Qk'
    volumes:
      - broker2-data:/var/lib/kafka/data

  kafka-ui:
    image: provectuslabs/kafka-ui:latest
    container_name: kafka-ui
    ports:
      - "8081:8080"
    environment:
      KAFKA_CLUSTERS_0_NAME: local-kraft
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: broker-1:19092,broker-2:19092
      KAFKA_CLUSTERS_0_KAFKACONNECT_0_NAME: snowflake-connect
      KAFKA_CLUSTERS_0_KAFKACONNECT_0_ADDRESS: http://kafka-connect:8083
    depends_on:
      - broker-1
      - broker-2

  kafka-connect:
    image: confluentinc/cp-kafka-connect-base:7.6.0
    container_name: kafka-connect
    hostname: kafka-connect
    ports:
      - "8083:8083"
    environment:
      CONNECT_BOOTSTRAP_SERVERS: broker-1:19092,broker-2:19092
      CONNECT_REST_PORT: 8083
      CONNECT_REST_ADVERTISED_HOST_NAME: kafka-connect
      CONNECT_GROUP_ID: snowflake-connect-cluster
      CONNECT_CONFIG_STORAGE_TOPIC: connect-configs
      CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR: 2
      CONNECT_OFFSET_STORAGE_TOPIC: connect-offsets
      CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR: 2
      CONNECT_OFFSET_STORAGE_PARTITIONS: 3
      CONNECT_STATUS_STORAGE_TOPIC: connect-status
      CONNECT_STATUS_STORAGE_REPLICATION_FACTOR: 2
      CONNECT_STATUS_STORAGE_PARTITIONS: 3
      CONNECT_KEY_CONVERTER: org.apache.kafka.connect.storage.StringConverter
      CONNECT_VALUE_CONVERTER: org.apache.kafka.connect.json.JsonConverter
      CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE: "false"
      CONNECT_PLUGIN_PATH: /usr/share/confluent-hub-components
    volumes:
      - ./connect-plugins/snowflake-kafka-connector:/usr/share/confluent-hub-components/snowflake-kafka-connector
      - ./snowflake_kafka_key.p8:/opt/kafka/snowflake_kafka_key.p8:ro
    depends_on:
      - broker-1
      - broker-2

volumes:
  broker1-data:
  broker2-data:
```

### Key design decisions

- **KRaft mode**: Both brokers run as `broker,controller` -- no separate Zookeeper needed. They share a `CLUSTER_ID`.
- **Confluent image for Kafka Connect**: We use `confluentinc/cp-kafka-connect-base:7.6.0` instead of `apache/kafka:3.7.0` because the Apache image has JAX-RS incompatibility issues that prevent the Snowflake connector from registering properly.
- **3 listeners per broker**: `PLAINTEXT` (inter-broker on port 19092), `CONTROLLER` (KRaft consensus on 9093), `EXTERNAL` (client access from host on 9092/9094).
- **Plugin isolation**: The Snowflake connector JAR is mounted into a subdirectory under `CONNECT_PLUGIN_PATH` for proper classloader isolation.

### Start the cluster

```powershell
docker compose up -d
```

Verify all containers are running:
```powershell
docker ps
```

Expected: `broker-1`, `broker-2`, `kafka-ui`, `kafka-connect` all in "Up" state.

---

## Step 2: Create Kafka Topics

**File**: `create_topics.py`

This Python script uses `KafkaAdminClient` to create 3 topics:

```python
from kafka.admin import KafkaAdminClient, NewTopic

admin = KafkaAdminClient(bootstrap_servers=['localhost:9092', 'localhost:9094'])

topics = [
    NewTopic(name='weather-raw-data',     num_partitions=3, replication_factor=2),
    NewTopic(name='weather-predictions',   num_partitions=3, replication_factor=2),
    NewTopic(name='weather-alerts',        num_partitions=2, replication_factor=2),
]

admin.create_topics(new_topics=topics, validate_only=False)
```

Run it:
```powershell
python create_topics.py
```

Verify topics exist at `http://localhost:8081` (Kafka UI).

---

## Step 3: Create Snowflake Database, Schema, and Tables

All SQL is organized into separate files in the `sql/` folder.

### 3a. Create Database and Schema

**File**: `sql/01_create_database_schema.sql`

```sql
CREATE DATABASE IF NOT EXISTS WEATHER_PIPELINE;
CREATE SCHEMA IF NOT EXISTS WEATHER_PIPELINE.KAFKA_DATA;
```

### 3b. Create Target Tables

**File**: `sql/02_create_tables.sql`

One table per Kafka topic. Each table has a `RECORD_METADATA VARIANT` column that Snowflake's Kafka connector auto-populates with Kafka metadata (topic, partition, offset, timestamps).

```sql
USE DATABASE WEATHER_PIPELINE;
USE SCHEMA KAFKA_DATA;

-- Table 1: Raw weather sensor readings
CREATE OR REPLACE TABLE WEATHER_RAW_DATA (
    RECORD_METADATA         VARIANT,
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

-- Table 2: 7-day weather forecasts (PREDICTIONS is a nested JSON array)
CREATE OR REPLACE TABLE WEATHER_PREDICTIONS (
    RECORD_METADATA         VARIANT,
    CITY                    VARCHAR(50),
    GENERATED_AT            TIMESTAMP_NTZ,
    FORECAST_DAYS           INT,
    BASED_ON_READINGS       INT,
    PREDICTIONS             VARIANT
);

-- Table 3: Weather alerts with severity levels
CREATE OR REPLACE TABLE WEATHER_ALERTS (
    RECORD_METADATA         VARIANT,
    CITY                    VARCHAR(50),
    TIMESTAMP               TIMESTAMP_NTZ,
    SEVERITY                VARCHAR(10),
    ALERT_TYPE              VARCHAR(50),
    ACTUAL_VALUE            FLOAT,
    THRESHOLD               FLOAT,
    MESSAGE                 VARCHAR(500)
);
```

**Why schematized columns instead of a single VARIANT column?** With `snowflake.enable.schematization: true`, the connector maps JSON fields to individual table columns. This gives better query performance, type safety, and readability compared to storing everything as raw JSON.

**Why VARIANT for PREDICTIONS?** The predictions field is a nested array of 7 forecast objects. VARIANT handles this naturally, and you can query it using `LATERAL FLATTEN`.

---

## Step 4: Create Snowflake Role and User (Least Privilege)

**File**: `sql/03_create_role_and_user.sql`

```sql
-- Dedicated role with minimal permissions
CREATE ROLE IF NOT EXISTS KAFKA_CONNECTOR_ROLE;

GRANT USAGE ON DATABASE WEATHER_PIPELINE TO ROLE KAFKA_CONNECTOR_ROLE;
GRANT USAGE ON SCHEMA WEATHER_PIPELINE.KAFKA_DATA TO ROLE KAFKA_CONNECTOR_ROLE;
GRANT INSERT, SELECT ON ALL TABLES IN SCHEMA WEATHER_PIPELINE.KAFKA_DATA
    TO ROLE KAFKA_CONNECTOR_ROLE;
GRANT INSERT, SELECT ON FUTURE TABLES IN SCHEMA WEATHER_PIPELINE.KAFKA_DATA
    TO ROLE KAFKA_CONNECTOR_ROLE;
GRANT CREATE TABLE ON SCHEMA WEATHER_PIPELINE.KAFKA_DATA
    TO ROLE KAFKA_CONNECTOR_ROLE;

-- Service account (key pair auth only, no password)
CREATE USER IF NOT EXISTS KAFKA_CONNECTOR_USER
    DEFAULT_ROLE = KAFKA_CONNECTOR_ROLE
    DEFAULT_WAREHOUSE = COMPUTE_WH
    COMMENT = 'Service account for Kafka Snowpipe Streaming connector';

GRANT ROLE KAFKA_CONNECTOR_ROLE TO USER KAFKA_CONNECTOR_USER;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE KAFKA_CONNECTOR_ROLE;
```

**Why CREATE TABLE permission?** When `snowflake.enable.schematization` is `true`, the connector may need to add columns if the JSON schema evolves.

---

## Step 5: Generate RSA Key Pair for Authentication

Snowpipe Streaming requires key pair authentication (not username/password). We generate an RSA 2048-bit key pair.

**Using Python** (if OpenSSL is not available):

```python
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

# Generate private key
private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

# Save private key (PKCS#8, unencrypted)
with open("snowflake_kafka_key.p8", "wb") as f:
    f.write(private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption()
    ))

# Save public key
with open("snowflake_kafka_key.pub", "wb") as f:
    f.write(private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    ))
```

**Using OpenSSL** (alternative):
```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out snowflake_kafka_key.p8 -nocrypt
openssl rsa -in snowflake_kafka_key.p8 -pubout -out snowflake_kafka_key.pub
```

**Files generated**:
- `snowflake_kafka_key.p8` -- Private key (keep secret, used by connector)
- `snowflake_kafka_key.pub` -- Public key (assigned to Snowflake user)

---

## Step 6: Assign Public Key to Snowflake User

**File**: `sql/04_assign_public_key.sql`

Extract the key body from the `.pub` file (everything between `-----BEGIN PUBLIC KEY-----` and `-----END PUBLIC KEY-----`, joined into one line):

```sql
ALTER USER KAFKA_CONNECTOR_USER SET RSA_PUBLIC_KEY = 'MIIBIjANBgkqhki...DAQAB';

-- Verify the fingerprint is set
DESCRIBE USER KAFKA_CONNECTOR_USER;
```

You should see `RSA_PUBLIC_KEY_FP` populated with a `SHA256:...` fingerprint.

---

## Step 7: Download Snowflake Kafka Connector JARs

Create the plugin directory and download the required JARs:

```powershell
mkdir connect-plugins\snowflake-kafka-connector
```

Download these 3 files into `connect-plugins/snowflake-kafka-connector/`:

| File | Size | Source |
|------|------|--------|
| `snowflake-kafka-connector-2.4.1.jar` | ~154 MB | Maven Central |
| `bc-fips-1.0.2.4.jar` | ~3.8 MB | Maven Central |
| `bcpkix-fips-1.0.7.jar` | ~877 KB | Maven Central |

Download URLs (Maven Central):
```
snowflake-kafka-connector-2.4.1.jar:
  https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/2.4.1/snowflake-kafka-connector-2.4.1.jar

bc-fips-1.0.2.4.jar:
  https://repo1.maven.org/maven2/org/bouncycastle/bc-fips/1.0.2.4/bc-fips-1.0.2.4.jar

bcpkix-fips-1.0.7.jar:
  https://repo1.maven.org/maven2/org/bouncycastle/bcpkix-fips/1.0.7/bcpkix-fips-1.0.7.jar
```

**Important**: The BouncyCastle FIPS JARs are required for Snowpipe Streaming's encryption. Without them, the connector will fail with cryptography errors.

**Important**: Verify the main JAR file size is ~154 MB. A truncated download will cause the connector to silently fail to register (zero connector classes found).

---

## Step 8: Start Docker Compose

```powershell
docker compose up -d
```

Wait ~30 seconds for Kafka Connect to finish starting, then verify the Snowflake plugin is loaded:

```powershell
# PowerShell
(Invoke-RestMethod http://localhost:8083/connector-plugins) | Where-Object { $_.class -like '*Snowflake*' }
```

Expected output should include:
```
class : com.snowflake.kafka.connector.SnowflakeSinkConnector
```

If the Snowflake connector does not appear, check:
1. JAR file is not truncated (should be ~154 MB)
2. JAR is in a subdirectory under `CONNECT_PLUGIN_PATH` (not directly in the root)
3. Container logs: `docker logs kafka-connect --tail 50`

---

## Step 9: Determine Your Snowflake Account URL

This is critical. The connector needs your Snowflake account URL in the format `orgname-accountname.snowflakecomputing.com`.

Run this in Snowflake:
```sql
SELECT CURRENT_ORGANIZATION_NAME(), CURRENT_ACCOUNT_NAME();
```

The URL format is: `<ORGANIZATION>-<ACCOUNT_NAME>.snowflakecomputing.com`

**Common mistake**: Using the account locator instead of the account name. These are different:
- `CURRENT_ACCOUNT()` returns the **locator** (e.g., `MV47222`) -- do NOT use this
- `CURRENT_ACCOUNT_NAME()` returns the **account name** (e.g., `FL96854`) -- use this

Example:
- Wrong: `ekjguym-mv47222.snowflakecomputing.com` (returns HTTP 404)
- Correct: `ekjguym-fl96854.snowflakecomputing.com` (returns HTTP 405 = endpoint exists)

---

## Step 10: Create Connector Configuration Files

We create one JSON config file per topic. Each connector sinks messages from one Kafka topic into one Snowflake table.

### 10a. Extract the Private Key Body

The connector requires the private key as an inline base64 string (no PEM headers):

```powershell
# PowerShell -- extract key body without BEGIN/END lines
$keyLines = Get-Content snowflake_kafka_key.p8 |
    Where-Object { $_ -notmatch 'BEGIN|END' -and $_.Trim() -ne '' } |
    ForEach-Object { $_.Trim() }
$keyBody = $keyLines -join ''
$keyBody  # Copy this value into the connector configs
```

### 10b. Connector for weather-raw-data

**File**: `connect-snowflake-raw.json`

```json
{
  "name": "snowflake-raw-data",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "snowflake.url.name": "YOUR_ORG-YOUR_ACCOUNT_NAME.snowflakecomputing.com",
    "snowflake.user.name": "KAFKA_CONNECTOR_USER",
    "snowflake.private.key": "<PASTE_BASE64_KEY_BODY_HERE>",
    "snowflake.database.name": "WEATHER_PIPELINE",
    "snowflake.schema.name": "KAFKA_DATA",
    "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
    "snowflake.enable.schematization": "true",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "topics": "weather-raw-data",
    "snowflake.topic2table.map": "weather-raw-data:WEATHER_RAW_DATA",
    "tasks.max": "2",
    "buffer.count.records": "1000",
    "buffer.flush.time": "10"
  }
}
```

### 10c. Connector for weather-predictions

**File**: `connect-snowflake-predictions.json`

```json
{
  "name": "snowflake-predictions",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "snowflake.url.name": "YOUR_ORG-YOUR_ACCOUNT_NAME.snowflakecomputing.com",
    "snowflake.user.name": "KAFKA_CONNECTOR_USER",
    "snowflake.private.key": "<PASTE_BASE64_KEY_BODY_HERE>",
    "snowflake.database.name": "WEATHER_PIPELINE",
    "snowflake.schema.name": "KAFKA_DATA",
    "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
    "snowflake.enable.schematization": "true",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "topics": "weather-predictions",
    "snowflake.topic2table.map": "weather-predictions:WEATHER_PREDICTIONS",
    "tasks.max": "1",
    "buffer.count.records": "100",
    "buffer.flush.time": "30"
  }
}
```

### 10d. Connector for weather-alerts

**File**: `connect-snowflake-alerts.json`

```json
{
  "name": "snowflake-alerts",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "snowflake.url.name": "YOUR_ORG-YOUR_ACCOUNT_NAME.snowflakecomputing.com",
    "snowflake.user.name": "KAFKA_CONNECTOR_USER",
    "snowflake.private.key": "<PASTE_BASE64_KEY_BODY_HERE>",
    "snowflake.database.name": "WEATHER_PIPELINE",
    "snowflake.schema.name": "KAFKA_DATA",
    "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
    "snowflake.enable.schematization": "true",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "topics": "weather-alerts",
    "snowflake.topic2table.map": "weather-alerts:WEATHER_ALERTS",
    "tasks.max": "1",
    "buffer.count.records": "50",
    "buffer.flush.time": "5"
  }
}
```

### Connector config explained

| Property | Purpose |
|----------|---------|
| `snowflake.ingestion.method: SNOWPIPE_STREAMING` | Direct row insertion (no intermediate file stage). Sub-10s latency. |
| `snowflake.enable.schematization: true` | Maps JSON fields to individual table columns (not a single VARIANT blob). |
| `snowflake.private.key` | Inline base64 private key body (no PEM headers). Required for SNOWPIPE_STREAMING. |
| `snowflake.topic2table.map` | Explicit mapping from Kafka topic name to Snowflake table name. |
| `tasks.max` | Number of parallel Kafka Connect tasks. Raw data gets 2 (higher volume); others get 1. |
| `buffer.count.records` | Flush to Snowflake after this many records. Alerts use 50 (low latency), raw uses 1000. |
| `buffer.flush.time` | Max seconds before flushing. Alerts=5s (urgent), predictions=30s (less urgent). |
| `key.converter: StringConverter` | Kafka message keys are plain strings (city names). |
| `value.converter: JsonConverter` | Kafka message values are JSON. `schemas.enable=false` since we don't use Avro/schema registry. |

---

## Step 11: Deploy Connectors via REST API

Deploy each connector by POSTing its JSON config to the Kafka Connect REST API:

```powershell
# Deploy raw data connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors" -Method Post `
  -ContentType "application/json" `
  -Body (Get-Content connect-snowflake-raw.json -Raw)

# Deploy predictions connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors" -Method Post `
  -ContentType "application/json" `
  -Body (Get-Content connect-snowflake-predictions.json -Raw)

# Deploy alerts connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors" -Method Post `
  -ContentType "application/json" `
  -Body (Get-Content connect-snowflake-alerts.json -Raw)
```

### Verify connector status

```powershell
$connectors = @("snowflake-raw-data", "snowflake-predictions", "snowflake-alerts")
foreach ($c in $connectors) {
    $status = Invoke-RestMethod -Uri "http://localhost:8083/connectors/$c/status"
    $tasks = ($status.tasks | ForEach-Object { "$($_.id):$($_.state)" }) -join ", "
    "$($status.name) | connector: $($status.connector.state) | tasks: [$tasks]"
}
```

Expected output:
```
snowflake-raw-data    | connector: RUNNING | tasks: [0:RUNNING, 1:RUNNING]
snowflake-predictions | connector: RUNNING | tasks: [0:RUNNING]
snowflake-alerts      | connector: RUNNING | tasks: [0:RUNNING]
```

All connectors and tasks must show `RUNNING`. If any show `FAILED`, check:
```powershell
Invoke-RestMethod "http://localhost:8083/connectors/<name>/status" | ConvertTo-Json -Depth 5
```

---

## Step 12: Start the Weather Producer

```powershell
python weather_producer.py
```

The producer generates data for 6 cities (Hyderabad, Mumbai, Delhi, Bangalore, Chennai, Kolkata):
- Every 3 seconds: raw weather readings to `weather-raw-data`
- Every 5th batch: 7-day forecasts to `weather-predictions`
- On threshold breach: alerts to `weather-alerts`

Sample output:
```
--- Batch #34 at 2026-04-14 09:27:34 ---
  [RAW]   Hyderabad    temp=37.9C  humidity=45.0%  wind=13.0km/h  rain=0%
  [ALERT] Hyderabad    [HIGH] Heat warning! Temperature above 33 C -- Hyderabad: 37.9
  [RAW]   Mumbai       temp=34.5C  humidity=61.1%  wind=17.8km/h  rain=17.4%
  [PRED]  Delhi        Day1: 39.8/32.8C Partly Cloudy  Day7: 30.3/29.5C
```

---

## Step 13: Verify Data in Snowflake

**File**: `sql/05_verify_data.sql`

### Row counts

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

### Latest raw readings

```sql
SELECT CITY, TIMESTAMP, TEMPERATURE_C, HUMIDITY_PCT, WIND_SPEED_KMH
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
ORDER BY TIMESTAMP DESC LIMIT 5;
```

### Query nested predictions with LATERAL FLATTEN

```sql
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
```

### HIGH severity alerts

```sql
SELECT CITY, TIMESTAMP, SEVERITY, ALERT_TYPE, ACTUAL_VALUE, THRESHOLD, MESSAGE
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS
WHERE SEVERITY = 'HIGH'
ORDER BY TIMESTAMP DESC LIMIT 10;
```

---

## Project File Structure

```
Kafka_SF/
  docker-compose.yml                       # Docker infrastructure
  weather_producer.py                      # Python data producer
  create_topics.py                         # Kafka topic creation script
  requirements.txt                         # Python dependencies
  env/                                     # Python virtual environment
  snowflake_kafka_key.p8                   # RSA private key (DO NOT COMMIT)
  snowflake_kafka_key.pub                  # RSA public key
  connect-snowflake-raw.json               # Connector config: raw data
  connect-snowflake-predictions.json       # Connector config: predictions
  connect-snowflake-alerts.json            # Connector config: alerts
  connect-plugins/
    snowflake-kafka-connector/
      snowflake-kafka-connector-2.4.1.jar  # Snowflake sink connector
      bc-fips-1.0.2.4.jar                 # BouncyCastle FIPS
      bcpkix-fips-1.0.7.jar               # BouncyCastle PKIX FIPS
  sql/
    01_create_database_schema.sql
    02_create_tables.sql
    03_create_role_and_user.sql
    04_assign_public_key.sql
    05_verify_data.sql
```

---

## Common Errors and How We Fixed Them

### 1. Connector plugin not detected (only MirrorMaker visible)

**Symptom**: `GET /connector-plugins` only returns `MirrorSourceConnector`, `MirrorCheckpointConnector`, `MirrorHeartbeatConnector`.

**Cause**: The `apache/kafka:3.7.0` image has a JAX-RS library conflict that prevents Kafka Connect REST endpoints from registering third-party connectors.

**Fix**: Switch to `confluentinc/cp-kafka-connect-base:7.6.0`. This image is purpose-built for Kafka Connect and handles plugin classloading correctly.

### 2. Corrupt/truncated connector JAR

**Symptom**: Snowflake connector class not found even though the JAR file exists. Logs show "ServiceLoader: loaded 0 connectors" and "ReflectionScanner: found 0 connectors".

**Cause**: Incomplete download. The JAR was 114 MB instead of the expected 154 MB.

**Fix**: Re-download and verify file size is ~154,864,486 bytes.

### 3. `snowflake.private.key must be non-empty`

**Symptom**: Connector deployment fails with this validation error.

**Cause**: Using `snowflake.private.key.path` (file path) instead of `snowflake.private.key` (inline content). When using `SNOWPIPE_STREAMING` ingestion method, the connector requires the key body inline.

**Fix**: Extract the base64 key body from the .p8 file (without `-----BEGIN/END PRIVATE KEY-----` lines) and set it as the value of `snowflake.private.key`.

### 4. Cannot connect to Snowflake (HTTP 404)

**Symptom**: Connector validation returns "Cannot connect to Snowflake". Container logs show `HTTP status=404`.

**Cause**: Wrong account URL. Used `CURRENT_ACCOUNT()` (which returns the locator, e.g., `MV47222`) instead of `CURRENT_ACCOUNT_NAME()` (which returns the account name, e.g., `FL96854`).

**Fix**: Use `CURRENT_ORGANIZATION_NAME()` + `-` + `CURRENT_ACCOUNT_NAME()` as the URL:
```
ekjguym-fl96854.snowflakecomputing.com   (correct -- returns 405)
ekjguym-mv47222.snowflakecomputing.com   (wrong -- returns 404)
```

### 5. Kafka Connect internal topic format mismatch

**Symptom**: Kafka Connect fails to start or behaves erratically after switching Docker images.

**Cause**: The `connect-configs`, `connect-offsets`, and `connect-status` topics were created by the old Apache image with a different internal format.

**Fix**: Delete the old internal topics before starting the new Confluent worker:
```powershell
docker exec broker-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:19092 --delete --topic connect-configs
docker exec broker-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:19092 --delete --topic connect-offsets
docker exec broker-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:19092 --delete --topic connect-status
```

---

## Useful Commands Reference

### Kafka Connect REST API

```powershell
# List all connectors
Invoke-RestMethod http://localhost:8083/connectors

# Check connector status
Invoke-RestMethod http://localhost:8083/connectors/snowflake-raw-data/status

# Pause a connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors/snowflake-raw-data/pause" -Method Put

# Resume a connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors/snowflake-raw-data/resume" -Method Put

# Delete a connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors/snowflake-raw-data" -Method Delete

# View connector config
Invoke-RestMethod http://localhost:8083/connectors/snowflake-raw-data/config

# Restart a failed task
Invoke-RestMethod -Uri "http://localhost:8083/connectors/snowflake-raw-data/tasks/0/restart" -Method Post
```

### Docker

```powershell
# View Kafka Connect logs
docker logs kafka-connect --tail 100 -f

# Check container resource usage
docker stats --no-stream

# Restart a specific container
docker restart kafka-connect

# Stop everything
docker compose down

# Stop and remove volumes (full reset)
docker compose down -v
```
