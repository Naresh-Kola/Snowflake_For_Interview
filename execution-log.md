# Snowpipe Streaming Execution Log

> This file documents every step executed during the Snowpipe Streaming setup,
> including commands, outputs, errors encountered, and fixes applied.

---

## Table of Contents

1. [Step 1: Create Database and Schema](#step-1-create-database-and-schema)
2. [Step 2: Create Tables](#step-2-create-tables)
3. [Step 3: Create Role and User](#step-3-create-role-and-user)
4. [Step 4: Generate RSA Key Pair](#step-4-generate-rsa-key-pair)
5. [Step 5: Assign Public Key to User](#step-5-assign-public-key-to-user)
6. [Step 6: Download Snowflake Kafka Connector JAR](#step-6-download-snowflake-kafka-connector-jar)
7. [Step 7: Update Docker Compose for Kafka Connect](#step-7-update-docker-compose-for-kafka-connect)
8. [Step 8: Start Docker Containers](#step-8-start-docker-containers)
9. [Step 9: Create Connector Configuration Files](#step-9-create-connector-configuration-files)
10. [Step 10: Deploy Connectors via REST API](#step-10-deploy-connectors-via-rest-api)
11. [Step 11: Start Weather Producer](#step-11-start-weather-producer)
12. [Step 12: Verify Data in Snowflake](#step-12-verify-data-in-snowflake)
13. [Errors Encountered and Fixes](#errors-encountered-and-fixes)

---

## Step 1: Create Database and Schema

**SQL File**: `sql/01_create_database_schema.sql`

**What we did**: Created the `WEATHER_PIPELINE` database and `KAFKA_DATA` schema to hold all weather data tables.

```sql
CREATE DATABASE IF NOT EXISTS WEATHER_PIPELINE;
USE DATABASE WEATHER_PIPELINE;
CREATE SCHEMA IF NOT EXISTS KAFKA_DATA;
```

**Output**: `Statement executed successfully.`

**Why**: Snowflake requires a database and schema before creating tables. The Kafka connector needs to know where to write data.

---

## Step 2: Create Tables

**SQL File**: `sql/02_create_tables.sql`

**What we did**: Created 3 tables matching the 3 Kafka topics:

1. **WEATHER_RAW_DATA** -- Stores raw sensor readings (temperature, humidity, wind, etc.)
2. **WEATHER_PREDICTIONS** -- Stores 7-day weather forecasts with a VARIANT column for the nested predictions array
3. **WEATHER_ALERTS** -- Stores weather alerts (heat warnings, wind alerts, visibility warnings, rain alerts)

Each table includes a `RECORD_METADATA VARIANT` column that Snowflake's Kafka connector automatically populates with Kafka metadata (topic, partition, offset, timestamps).

**Output**: All 3 `CREATE TABLE` statements executed successfully.

---

## Step 3: Create Role and User

**SQL File**: `sql/03_create_role_and_user.sql`

**What we did**: Created a dedicated Snowflake role and user for the Kafka connector:

- **Role**: `KAFKA_CONNECTOR_ROLE` -- with INSERT, SELECT, CREATE TABLE, and USAGE privileges
- **User**: `KAFKA_CONNECTOR_USER` -- with key pair authentication (no password), default warehouse `COMPUTE_WH`

**Grants applied**:
```
USAGE on DATABASE WEATHER_PIPELINE
USAGE on SCHEMA WEATHER_PIPELINE.KAFKA_DATA
INSERT, SELECT on ALL TABLES in SCHEMA KAFKA_DATA
CREATE TABLE on SCHEMA KAFKA_DATA (needed for schematization)
USAGE on WAREHOUSE COMPUTE_WH
```

**Output**: `Statement executed successfully.` for all statements.

---

## Step 4: Generate RSA Key Pair

**What we did**: Generated an RSA 2048-bit key pair for Snowflake key pair authentication.

**Problem**: OpenSSL was not available on the Windows system.

**Solution**: Used Python's `cryptography` library:

```python
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
```

**Files generated**:
- `snowflake_kafka_key.p8` -- Private key (PKCS#8 PEM format, unencrypted)
- `snowflake_kafka_key.pub` -- Public key (PEM format)

---

## Step 5: Assign Public Key to User

**SQL File**: `sql/04_assign_public_key.sql`

**What we did**: Assigned the RSA public key to `KAFKA_CONNECTOR_USER`:

```sql
ALTER USER KAFKA_CONNECTOR_USER SET RSA_PUBLIC_KEY='MIIBIjANBgk...';
```

**Verification**:
```sql
DESC USER KAFKA_CONNECTOR_USER;
-- RSA_PUBLIC_KEY_FP: SHA256:kxbvLQQPsZS4TF2P5WX4Wj55o9a32S3X5fMdIp0xkqk=
```

**Output**: Key fingerprint confirmed -- public key is correctly assigned.

---

## Step 6: Download Snowflake Kafka Connector JAR

**What we did**: Downloaded the Snowflake Kafka Connector 2.4.1 JAR and BouncyCastle FIPS dependency JARs.

**Files placed in** `connect-plugins/snowflake-kafka-connector/`:
- `snowflake-kafka-connector-2.4.1.jar` (154,864,486 bytes)
- `bc-fips-1.0.2.4.jar` (3,799,777 bytes)
- `bcpkix-fips-1.0.7.jar` (876,753 bytes)

### Error: Corrupt JAR from Previous Session

The JAR downloaded in a prior session was only 114,173,888 bytes (truncated by ~40MB). This caused:
- ServiceLoader found zero connector classes
- ReflectionScanner found zero connector classes
- REST API only showed built-in MirrorMaker connectors

**Fix**: Re-downloaded from Maven Central:
```
https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/2.4.1/snowflake-kafka-connector-2.4.1.jar
```
Downloaded to `C:\temp\` first (to avoid OneDrive sync issues), then copied to the plugin directory.

**Verification**: Used .NET `System.IO.Compression.ZipArchive` to confirm the JAR contains `com/snowflake/kafka/connector/SnowflakeSinkConnector.class`.

---

## Step 7: Update Docker Compose for Kafka Connect

**File**: `docker-compose.yml`

### Error: Apache Kafka Image JAX-RS Incompatibility

The original setup used `apache/kafka:3.7.0` for the kafka-connect service. This caused:
- Jersey JAX-RS provider warnings in logs
- REST API endpoints partially broken (ConnectorPluginsResource ignored)
- Only built-in Mirror connectors visible

**Fix**: Switched to `confluentinc/cp-kafka-connect-base:7.6.0` which is purpose-built for Kafka Connect.

**Key configuration** (via environment variables):
```yaml
kafka-connect:
  image: confluentinc/cp-kafka-connect-base:7.6.0
  environment:
    CONNECT_BOOTSTRAP_SERVERS: broker-1:19092,broker-2:19092
    CONNECT_GROUP_ID: snowflake-connect-cluster
    CONNECT_PLUGIN_PATH: /usr/share/confluent-hub-components
  volumes:
    - ./connect-plugins/snowflake-kafka-connector:/usr/share/confluent-hub-components/snowflake-kafka-connector
    - ./snowflake_kafka_key.p8:/opt/kafka/snowflake_kafka_key.p8:ro
```

**Why Confluent image**: The Confluent image uses environment variables (prefixed `CONNECT_`) instead of a properties file, handles classloader isolation properly, and has correct JAX-RS dependencies.

---

## Step 8: Start Docker Containers

```powershell
docker compose up -d
```

**Output**:
```
[+] Running 5/5
 - Network kafka_sf_default  Created
 - Container broker-1        Started
 - Container broker-2        Started
 - Container kafka-ui        Started
 - Container kafka-connect   Started
```

**Pre-requisite cleanup**: Deleted old Connect internal topics from previous apache/kafka worker to avoid format incompatibility:
```
connect-configs, connect-offsets, connect-status
```

**Verification** (after startup):
```powershell
Invoke-RestMethod http://localhost:8083/connector-plugins
```
Output included `com.snowflake.kafka.connector.SnowflakeSinkConnector` -- confirmed the Snowflake connector is loaded.

---

## Step 9: Create Connector Configuration Files

**Files created**:
- `connect-snowflake-raw.json` -- For `weather-raw-data` topic
- `connect-snowflake-predictions.json` -- For `weather-predictions` topic
- `connect-snowflake-alerts.json` -- For `weather-alerts` topic

### Error: `snowflake.private.key must be non-empty`

The initial configs used `snowflake.private.key.path` pointing to the .p8 file inside the container. However, with `SNOWPIPE_STREAMING` ingestion method, the connector requires `snowflake.private.key` with the **inline base64 key body** (no PEM headers/footers).

**Fix**: Extracted the key body from the .p8 file (1,624 chars of base64) and placed it directly in the `snowflake.private.key` config field.

### Error: `Cannot connect to Snowflake` (HTTP 404)

The initial URL was `EKJGUYM-MV47222.snowflakecomputing.com`, using the org+locator format.

**Diagnosis**:
```powershell
# From inside the kafka-connect container:
curl https://ekjguym-mv47222.snowflakecomputing.com  # -> 404 (WRONG)
curl https://mv47222.snowflakecomputing.com           # -> 404 (WRONG)
curl https://ekjguym-fl96854.snowflakecomputing.com   # -> 405 (CORRECT!)
```

**Root cause**: `MV47222` is the account **locator**, not the account **name**. The correct URL format uses `orgname-accountname`:
```sql
SELECT CURRENT_ACCOUNT(), CURRENT_ORGANIZATION_NAME(), CURRENT_ACCOUNT_NAME();
-- MV47222,              EKJGUYM,                     FL96854
```

**Fix**: Updated all 3 configs to use `ekjguym-fl96854.snowflakecomputing.com`.

### Final connector config (example: raw data):
```json
{
  "name": "snowflake-raw-data",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "snowflake.url.name": "ekjguym-fl96854.snowflakecomputing.com",
    "snowflake.user.name": "KAFKA_CONNECTOR_USER",
    "snowflake.private.key": "<inline base64 key body>",
    "snowflake.database.name": "WEATHER_PIPELINE",
    "snowflake.schema.name": "KAFKA_DATA",
    "snowflake.role.name": "KAFKA_CONNECTOR_ROLE",
    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
    "snowflake.enable.schematization": "true",
    "topics": "weather-raw-data",
    "snowflake.topic2table.map": "weather-raw-data:WEATHER_RAW_DATA",
    "tasks.max": "2",
    "buffer.count.records": "1000",
    "buffer.flush.time": "10"
  }
}
```

---

## Step 10: Deploy Connectors via REST API

Deployed all 3 connectors using `POST http://localhost:8083/connectors`:

```powershell
# Deploy raw data connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors" -Method Post `
  -ContentType "application/json" -Body (Get-Content connect-snowflake-raw.json -Raw)
# Result: SUCCESS: snowflake-raw-data deployed

# Deploy predictions connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors" -Method Post `
  -ContentType "application/json" -Body (Get-Content connect-snowflake-predictions.json -Raw)
# Result: SUCCESS: snowflake-predictions deployed

# Deploy alerts connector
Invoke-RestMethod -Uri "http://localhost:8083/connectors" -Method Post `
  -ContentType "application/json" -Body (Get-Content connect-snowflake-alerts.json -Raw)
# Result: SUCCESS: snowflake-alerts deployed
```

**Connector status verification**:
```
snowflake-raw-data   | connector: RUNNING | tasks: [0:RUNNING, 1:RUNNING]
snowflake-predictions | connector: RUNNING | tasks: [0:RUNNING]
snowflake-alerts     | connector: RUNNING | tasks: [0:RUNNING]
```

---

## Step 11: Start Weather Producer

```powershell
python weather_producer.py
```

The producer generates synthetic weather data for 6 Indian cities (Hyderabad, Mumbai, Delhi, Bangalore, Chennai, Kolkata) and sends to 3 Kafka topics:
- `weather-raw-data` -- Every 3 seconds, raw readings for all 6 cities
- `weather-predictions` -- Every 5th batch, 7-day forecasts for all cities
- `weather-alerts` -- Threshold-based alerts (heat, wind, visibility, rain)

**Sample output**:
```
--- Batch #34 at 2026-04-14 09:27:34 ---
  [RAW]   Hyderabad    temp=37.9C  humidity=45.0%  wind=13.0km/h  rain=0%
  [ALERT] Hyderabad    [HIGH] Heat warning! Temperature above 33 C -- Hyderabad: 37.9
  [RAW]   Mumbai       temp=34.5C  humidity=61.1%  wind=17.8km/h  rain=17.4%
  [ALERT] Mumbai       [HIGH] Heat warning! Temperature above 33 C -- Mumbai: 34.5
  ...
  [PRED]  Delhi        Day1: 39.8/32.8C Partly Cloudy  Day7: 30.3/29.5C ...
```

---

## Step 12: Verify Data in Snowflake

### Row Counts

```sql
SELECT 'WEATHER_RAW_DATA' AS TABLE_NAME, COUNT(*) FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
UNION ALL SELECT 'WEATHER_PREDICTIONS', COUNT(*) FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_PREDICTIONS
UNION ALL SELECT 'WEATHER_ALERTS', COUNT(*) FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS;
```

| Table | Row Count |
|-------|-----------|
| WEATHER_RAW_DATA | 1,110+ |
| WEATHER_PREDICTIONS | 206+ |
| WEATHER_ALERTS | 728+ |

*(Row counts continue to increase as the producer runs)*

### Sample Raw Data

```sql
SELECT * FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA LIMIT 3;
```

| CITY | TEMPERATURE_C | HUMIDITY_PCT | WIND_SPEED_KMH | RAIN_PROBABILITY_PCT |
|------|--------------|-------------|----------------|---------------------|
| Hyderabad | 27.7 | 57.8 | 9.1 | 11.7 |
| Mumbai | 25.2 | 71.9 | 11.7 | 27.4 |
| Kolkata | 28.0 | 73.5 | 2.2 | 32.3 |

### Sample Predictions (LATERAL FLATTEN)

```sql
SELECT p.CITY, f.value:date::STRING AS forecast_date,
       f.value:temp_high_c::FLOAT AS temp_high,
       f.value:temp_low_c::FLOAT AS temp_low,
       f.value:condition::STRING AS condition,
       f.value:confidence_pct::FLOAT AS confidence
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_PREDICTIONS p,
     LATERAL FLATTEN(input => p.PREDICTIONS) f
WHERE p.CITY = 'Delhi' LIMIT 7;
```

| CITY | FORECAST_DATE | TEMP_HIGH | TEMP_LOW | CONDITION | CONFIDENCE |
|------|--------------|-----------|----------|-----------|------------|
| Delhi | 2026-04-14 | 31.8 | 21.8 | Partly Cloudy | 87.5% |
| Delhi | 2026-04-15 | 30.8 | 22.9 | Partly Cloudy | 82.7% |
| Delhi | 2026-04-16 | 29.0 | 22.9 | Partly Cloudy | 71.6% |
| Delhi | 2026-04-17 | 27.5 | 23.2 | Partly Cloudy | 63.0% |
| Delhi | 2026-04-18 | 25.6 | 23.3 | Partly Cloudy | 55.0% |
| Delhi | 2026-04-19 | 26.5 | 14.9 | Partly Cloudy | 47.6% |
| Delhi | 2026-04-20 | 16.8 | 14.6 | Partly Cloudy | 38.8% |

### Sample Alerts

```sql
SELECT * FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS LIMIT 3;
```

| CITY | SEVERITY | ALERT_TYPE | ACTUAL_VALUE | THRESHOLD | MESSAGE |
|------|----------|------------|-------------|-----------|---------|
| Mumbai | MEDIUM | visibility_km | 7.3 | 8 | Low visibility warning! |
| Chennai | MEDIUM | visibility_km | 6.4 | 8 | Low visibility warning! |
| Mumbai | MEDIUM | visibility_km | 6.8 | 8 | Low visibility warning! |

---

## Errors Encountered and Fixes

| # | Error | Root Cause | Fix |
|---|-------|-----------|-----|
| 1 | Connector plugins not loading (only MirrorMaker visible) | apache/kafka:3.7.0 image has JAX-RS incompatibility with Kafka Connect REST API | Switched to `confluentinc/cp-kafka-connect-base:7.6.0` |
| 2 | Zero Snowflake connector classes found | JAR was corrupt/truncated (114MB instead of 154MB) | Re-downloaded from Maven Central |
| 3 | `snowflake.private.key must be non-empty` | Used `snowflake.private.key.path` (file path) instead of inline key | Changed to `snowflake.private.key` with base64 key body |
| 4 | `Cannot connect to Snowflake` (HTTP 404) | URL used account locator (`MV47222`) instead of account name (`FL96854`) | Changed to `ekjguym-fl96854.snowflakecomputing.com` |
| 5 | OneDrive file sync reverting writes | Files on OneDrive-synced path get reverted | Write to `C:\temp\` first, then copy to final location |
| 6 | OpenSSL not available for key generation | Not installed on Windows system | Used Python `cryptography` library instead |
| 7 | Connect internal topic format incompatibility | Old topics from apache/kafka worker | Deleted and let Confluent worker recreate them |

---

## Final Architecture

```
weather_producer.py
        |
        v
  [Kafka Brokers]  (broker-1, broker-2 - KRaft mode)
        |
   3 Topics:
   - weather-raw-data     (3 partitions, RF=2)
   - weather-predictions   (3 partitions, RF=2)
   - weather-alerts       (2 partitions, RF=2)
        |
        v
  [Kafka Connect]  (Confluent cp-kafka-connect-base:7.6.0)
   3 Snowflake Sink Connectors (SNOWPIPE_STREAMING)
        |
        v
  [Snowflake]  WEATHER_PIPELINE.KAFKA_DATA
   - WEATHER_RAW_DATA     (schematized columns)
   - WEATHER_PREDICTIONS  (with VARIANT PREDICTIONS array)
   - WEATHER_ALERTS       (schematized columns)
```

---

*Generated: April 14, 2026*
