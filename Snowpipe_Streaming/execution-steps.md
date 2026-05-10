# Kafka to Snowflake Weather Pipeline - Execution Steps

Step-by-step instructions to run the entire project from scratch.

---

## Prerequisites

- **Docker Desktop** installed and running
- **Python 3.10+** installed
- **Snowflake account** with ACCOUNTADMIN or equivalent privileges
- **pip** package manager

---

## Phase 1: Snowflake Setup

Run these SQL scripts in Snowflake (Snowsight or SnowSQL) using the ACCOUNTADMIN role, in order:

### Step 1: Create Database and Schema

```sql
-- File: sql/01_create_database_schema.sql
CREATE DATABASE IF NOT EXISTS WEATHER_PIPELINE;
USE DATABASE WEATHER_PIPELINE;
CREATE SCHEMA IF NOT EXISTS KAFKA_DATA;
```

### Step 2: Create Tables

```sql
-- File: sql/02_create_tables.sql
-- Run this script to create 3 tables:
--   WEATHER_RAW_DATA
--   WEATHER_PREDICTIONS
--   WEATHER_ALERTS
```

### Step 3: Create Role and User

```sql
-- File: sql/03_create_role_and_user.sql
-- Creates KAFKA_CONNECTOR_ROLE and KAFKA_CONNECTOR_USER
-- Grants necessary privileges (USAGE, INSERT, SELECT, CREATE TABLE)
```

### Step 4: Generate RSA Key Pair

OpenSSL is not available on most Windows systems. Use Python to generate the key pair instead.

#### Step 4a: Install the cryptography library

```powershell
pip install cryptography
```

#### Step 4b: Create the key generation script

Save the following as `generate_keys.py` in the project directory:

```python
"""
RSA Key Pair Generator for Snowflake Key Pair Authentication
-------------------------------------------------------------
Generates:
  1. snowflake_kafka_key.p8  -- Private key (PKCS#8 PEM, unencrypted)
  2. snowflake_kafka_key.pub -- Public key (PEM)

The private key is used by the Kafka connector to authenticate to Snowflake.
The public key is assigned to the KAFKA_CONNECTOR_USER in Snowflake.

Usage:
    python generate_keys.py
"""

from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization


def generate_key_pair():
    # --- Step 1: Generate a 2048-bit RSA private key ---
    # 2048 bits is the minimum recommended key size for security.
    # public_exponent=65537 is the standard value used by almost all RSA implementations.
    print("Generating 2048-bit RSA key pair...")
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )

    # --- Step 2: Save the private key in PKCS#8 PEM format (unencrypted) ---
    # PKCS#8 is the format Snowflake expects for private keys.
    # NoEncryption() means no passphrase -- acceptable for development.
    # For PRODUCTION, use BestAvailableEncryption(b"your-passphrase") instead.
    private_key_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,             # PEM = base64 text format
        format=serialization.PrivateFormat.PKCS8,         # PKCS#8 = Snowflake-compatible format
        encryption_algorithm=serialization.NoEncryption(), # No passphrase (dev only)
    )

    with open("snowflake_kafka_key.p8", "wb") as f:
        f.write(private_key_bytes)
    print("  [SAVED] snowflake_kafka_key.p8  (private key -- NEVER share this)")

    # --- Step 3: Extract and save the public key ---
    # The public key is derived from the private key.
    # This is what you register with the Snowflake user via ALTER USER.
    public_key_bytes = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    with open("snowflake_kafka_key.pub", "wb") as f:
        f.write(public_key_bytes)
    print("  [SAVED] snowflake_kafka_key.pub (public key -- assign to Snowflake user)")

    # --- Step 4: Print the public key body for easy copy-paste ---
    # Strip the -----BEGIN/END PUBLIC KEY----- header/footer lines.
    # This is the base64 string you paste into the ALTER USER SQL command.
    public_key_str = public_key_bytes.decode("utf-8")
    public_key_body = "".join(
        line for line in public_key_str.splitlines()
        if "PUBLIC KEY" not in line
    )

    print("\n--- Public key body (copy this into ALTER USER SQL) ---")
    print(public_key_body)
    print("--- End of public key body ---")

    # --- Step 5: Print the private key body for connector config ---
    # Strip the -----BEGIN/END PRIVATE KEY----- header/footer lines.
    # This is the base64 string you paste into the connector JSON config
    # as the value of "snowflake.private.key".
    private_key_str = private_key_bytes.decode("utf-8")
    private_key_body = "".join(
        line for line in private_key_str.splitlines()
        if "PRIVATE KEY" not in line
    )

    print("\n--- Private key body (copy this into connector JSON configs) ---")
    print(private_key_body)
    print("--- End of private key body ---")

    print("\nDone. Next steps:")
    print("  1. Run the ALTER USER SQL with the public key body above")
    print("  2. Paste the private key body into all 3 connect-snowflake-*.json files")


if __name__ == "__main__":
    generate_key_pair()
```

#### What each part does

| Part | What it does | Output |
|------|-------------|--------|
| Step 1 - `rsa.generate_private_key()` | Generates a random 2048-bit RSA key pair in memory | Key object in memory |
| Step 2 - `private_key.private_bytes()` | Serializes the private key to PKCS#8 PEM format | `snowflake_kafka_key.p8` |
| Step 3 - `public_key().public_bytes()` | Extracts and serializes the public key to PEM format | `snowflake_kafka_key.pub` |
| Step 4 - Print public key body | Strips PEM headers so you can paste directly into SQL | Console output for ALTER USER |
| Step 5 - Print private key body | Strips PEM headers so you can paste into connector configs | Console output for JSON configs |

#### Step 4c: Run the script

```powershell
python generate_keys.py
```

Expected output:
```
Generating 2048-bit RSA key pair...
  [SAVED] snowflake_kafka_key.p8  (private key -- NEVER share this)
  [SAVED] snowflake_kafka_key.pub (public key -- assign to Snowflake user)

--- Public key body (copy this into ALTER USER SQL) ---
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA...
--- End of public key body ---

--- Private key body (copy this into connector JSON configs) ---
MIIEvQIBADANBgkqhkiG9w0BAQEFAASC...
--- End of private key body ---

Done. Next steps:
  1. Run the ALTER USER SQL with the public key body above
  2. Paste the private key body into all 3 connect-snowflake-*.json files
```

#### Files generated

| File | Format | Who uses it | Security |
|------|--------|-------------|----------|
| `snowflake_kafka_key.p8` | PKCS#8 PEM (private key) | Kafka connector (mounted into Docker container) | NEVER commit to git. Add `*.p8` to `.gitignore` |
| `snowflake_kafka_key.pub` | PEM (public key) | Snowflake (registered via ALTER USER) | Safe to share |


### Step 5: Assign Public Key to Snowflake User

Open `snowflake_kafka_key.pub`, copy the base64 content (without the `-----BEGIN/END PUBLIC KEY-----` lines), and run:

```sql
-- File: sql/04_assign_public_key.sql
ALTER USER KAFKA_CONNECTOR_USER SET RSA_PUBLIC_KEY='<paste base64 key body here>';
```

Verify:

```sql
DESC USER KAFKA_CONNECTOR_USER;
-- Check that RSA_PUBLIC_KEY_FP shows a SHA256 fingerprint
```

---

## Phase 2: Kafka Infrastructure

### Step 6: Start Docker Containers

From the project directory:

```powershell
docker compose up -d
```

This starts 4 containers:
- **broker-1** (port 9092) -- Kafka broker
- **broker-2** (port 9094) -- Kafka broker
- **kafka-ui** (port 8081) -- Web UI for monitoring
- **kafka-connect** (port 8083) -- Kafka Connect with Snowflake connector

Wait ~30 seconds for all containers to be healthy:

```powershell
docker compose ps
```

All containers should show status `running`.

### Step 7: Verify Kafka Connect is Ready

```powershell
Invoke-RestMethod http://localhost:8083/connector-plugins
```

You should see `com.snowflake.kafka.connector.SnowflakeSinkConnector` in the output. If Kafka Connect is still starting, wait a few more seconds and retry.

---

## Phase 3: Python Environment Setup

### Step 8: Create Virtual Environment and Install Dependencies

```powershell
python -m venv env
.\env\Scripts\Activate.ps1
pip install kafka-python
```

---

## Phase 4: Create Topics and Deploy Connectors

### Step 9: Create Kafka Topics

```powershell
python create_topics.py
```

Expected output:
```
Connecting to Kafka at localhost:9092,localhost:9094...
  [CREATED]  weather-raw-data          partitions=3  replication=2
  [CREATED]  weather-predictions       partitions=3  replication=2
  [CREATED]  weather-alerts            partitions=2  replication=2
```

### Step 10: Update Connector Configs with Your Private Key

Before deploying connectors, update the `snowflake.private.key` field in all 3 connector config files with **your** private key body (base64 content from `snowflake_kafka_key.p8`, without the `-----BEGIN/END PRIVATE KEY-----` lines):

- `connect-snowflake-raw.json`
- `connect-snowflake-predictions.json`
- `connect-snowflake-alerts.json`

Also update `snowflake.url.name` if your Snowflake account URL differs.

### Step 11: Deploy Snowflake Sink Connectors

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

### Step 12: Verify Connectors are Running

```powershell
# List all connectors
Invoke-RestMethod http://localhost:8083/connectors

# Check status of each connector
Invoke-RestMethod http://localhost:8083/connectors/snowflake-raw-data/status
Invoke-RestMethod http://localhost:8083/connectors/snowflake-predictions/status
Invoke-RestMethod http://localhost:8083/connectors/snowflake-alerts/status
```

All connectors and their tasks should show `RUNNING` state.

---

## Phase 5: Run the Producer

### Step 13: Start the Weather Producer

```powershell
python weather_producer.py
```

The producer runs continuously, generating data every 3 seconds for 6 Indian cities (Hyderabad, Mumbai, Delhi, Bangalore, Chennai, Kolkata):
- **Raw readings** -- every 3 seconds (6 messages per batch)
- **7-day forecasts** -- every 5th batch (~15 seconds)
- **Alerts** -- when thresholds are exceeded (heat, wind, visibility, rain)

Press `Ctrl+C` to stop the producer.

---

## Phase 5.5: Understanding the Consumption Process (Kafka -> Snowflake)

Once the producer is running and connectors are deployed, data is automatically consumed from Kafka and written to Snowflake. No additional scripts are needed -- the 3 Snowflake Sink Connectors handle everything.

### How It Works (End-to-End Flow)

`
weather_producer.py  (generates data every 3 seconds)
        |
        v
  Kafka Brokers  (broker-1:9092, broker-2:9094)
   |          |          |
   v          v          v
weather-   weather-   weather-
raw-data   predictions  alerts
   |          |          |
   v          v          v
  Kafka Connect  (kafka-connect:8083)
  3 Snowflake Sink Connectors running inside:
   - snowflake-raw-data      (2 tasks, buffer: 1000 records / 10s)
   - snowflake-predictions   (1 task,  buffer: 100 records / 30s)
   - snowflake-alerts        (1 task,  buffer: 50 records / 5s)
        |
        v  (Snowpipe Streaming API -- direct row insert, no staging files)
  Snowflake  WEATHER_PIPELINE.KAFKA_DATA
   |          |          |
   v          v          v
WEATHER_   WEATHER_   WEATHER_
RAW_DATA   PREDICTIONS  ALERTS
`

### Snowpipe Streaming vs Traditional Snowpipe

This project uses **Snowpipe Streaming** (not the older file-based Snowpipe):

| Aspect | Traditional Snowpipe | Snowpipe Streaming (this project) |
|--------|---------------------|-----------------------------------|
| How it works | Writes files to S3/Azure/GCS, then Snowpipe loads them | Inserts rows directly into Snowflake tables via API |
| Latency | 1-2 minutes | < 10 seconds |
| Intermediate storage | Requires cloud stage | None needed |
| Setup | Stage + Pipe + Notification | Just connector + table |
| Config key | (default) | `snowflake.ingestion.method: SNOWPIPE_STREAMING` |

### What Each Connector Does

**1. snowflake-raw-data** (high volume)
- Consumes from: `weather-raw-data` topic (3 partitions)
- Writes to: `WEATHER_RAW_DATA` table
- Runs 2 parallel tasks for throughput
- Buffers 1000 records OR flushes every 10 seconds (whichever comes first)
- Schematizes JSON fields into typed columns (CITY, TEMPERATURE_C, HUMIDITY_PCT, etc.)

**2. snowflake-predictions** (moderate volume)
- Consumes from: `weather-predictions` topic (3 partitions)
- Writes to: `WEATHER_PREDICTIONS` table
- Runs 1 task (lower volume -- forecasts generated every 5th batch)
- Buffers 100 records OR flushes every 30 seconds
- The `PREDICTIONS` column stays as VARIANT (nested JSON array of 7-day forecasts)

**3. snowflake-alerts** (low volume, urgent)
- Consumes from: `weather-alerts` topic (2 partitions)
- Writes to: `WEATHER_ALERTS` table
- Runs 1 task
- Buffers only 50 records OR flushes every 5 seconds (fastest flush -- alerts are urgent)
- Schematizes fields: CITY, SEVERITY, ALERT_TYPE, ACTUAL_VALUE, THRESHOLD, MESSAGE

### Schematization

The setting `snowflake.enable.schematization: true` in each connector config tells the connector to map JSON fields to individual table columns automatically:

`
Kafka JSON message:                    Snowflake table row:
{                                      CITY = 'Hyderabad'
  "city": "Hyderabad",         -->     TEMPERATURE_C = 32.5
  "temperature_c": 32.5,              HUMIDITY_PCT = 48.3
  "humidity_pct": 48.3,               WIND_SPEED_KMH = 14.2
  "wind_speed_kmh": 14.2,             ...
  ...
}
`

Without schematization, the entire JSON would land in a single VARIANT column.

### RECORD_METADATA

Each row also gets a `RECORD_METADATA` VARIANT column automatically populated by the connector with Kafka metadata:

`json
{
  "CreateTime": 1713028835123,
  "offset": 42,
  "partition": 1,
  "topic": "weather-raw-data"
}
`

Useful for debugging (which partition/offset did this row come from?) and deduplication.

### Authentication

The connectors authenticate to Snowflake using **RSA key pair authentication**:
- The private key (`snowflake_kafka_key.p8`) is mounted into the kafka-connect container
- The `snowflake.private.key` field in each connector config contains the base64 key body
- Snowflake verifies it against the public key assigned to `KAFKA_CONNECTOR_USER`
- No passwords are transmitted over the network

### How to Monitor the Consumption Process

**Check connector status:**
`powershell
Invoke-RestMethod http://localhost:8083/connectors/snowflake-raw-data/status
Invoke-RestMethod http://localhost:8083/connectors/snowflake-predictions/status
Invoke-RestMethod http://localhost:8083/connectors/snowflake-alerts/status
`

All connectors and tasks should show `RUNNING`.

**Check Kafka Connect logs for errors:**
`powershell
docker logs kafka-connect --tail 50
`

**Measure ingestion latency in Snowflake:**
`sql
SELECT
    MAX(TIMESTAMP) AS LATEST_RECORD,
    CURRENT_TIMESTAMP() AS CURRENT_TIME,
    DATEDIFF('second', MAX(TIMESTAMP), CURRENT_TIMESTAMP()) AS LAG_SECONDS
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA;
`

If `LAG_SECONDS` is consistently under 15, the consumption pipeline is working correctly.

**Check row counts are growing:**
`sql
-- Run this twice with 30 seconds gap; counts should increase
SELECT 'WEATHER_RAW_DATA' AS TBL, COUNT(*) AS ROWS FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
UNION ALL SELECT 'WEATHER_PREDICTIONS', COUNT(*) FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_PREDICTIONS
UNION ALL SELECT 'WEATHER_ALERTS', COUNT(*) FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS;
`

**View messages in Kafka UI:**

Open http://localhost:8081 and navigate to Topics to see messages being produced and consumer group offsets advancing.

---

## Phase 6: Verify Data in Snowflake

### Step 14: Check Row Counts

```sql
-- File: sql/05_verify_data.sql
SELECT 'WEATHER_RAW_DATA' AS TABLE_NAME, COUNT(*) AS ROW_COUNT
  FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
UNION ALL
SELECT 'WEATHER_PREDICTIONS', COUNT(*)
  FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_PREDICTIONS
UNION ALL
SELECT 'WEATHER_ALERTS', COUNT(*)
  FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS;
```

Row counts should increase as the producer runs.

### Step 15: Query Sample Data

**Raw readings:**
```sql
SELECT CITY, TEMPERATURE_C, HUMIDITY_PCT, WIND_SPEED_KMH, RAIN_PROBABILITY_PCT
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA
ORDER BY TIMESTAMP DESC
LIMIT 10;
```

**Predictions (flattened):**
```sql
SELECT p.CITY,
       f.value:date::STRING AS FORECAST_DATE,
       f.value:temp_high_c::FLOAT AS TEMP_HIGH,
       f.value:temp_low_c::FLOAT AS TEMP_LOW,
       f.value:condition::STRING AS CONDITION,
       f.value:confidence_pct::FLOAT AS CONFIDENCE
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_PREDICTIONS p,
     LATERAL FLATTEN(input => p.PREDICTIONS) f
WHERE p.CITY = 'Delhi'
ORDER BY p.GENERATED_AT DESC
LIMIT 7;
```

**Alerts:**
```sql
SELECT CITY, SEVERITY, ALERT_TYPE, ACTUAL_VALUE, THRESHOLD, MESSAGE
FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_ALERTS
ORDER BY TIMESTAMP DESC
LIMIT 10;
```

---

## Monitoring

### Kafka UI

Open http://localhost:8081 in your browser to:
- View topics and message counts
- Inspect individual messages
- Monitor connector status

### Connector Health Check

```powershell
# Quick status of all connectors
$connectors = Invoke-RestMethod http://localhost:8083/connectors
foreach ($c in $connectors) {
    $status = Invoke-RestMethod "http://localhost:8083/connectors/$c/status"
    Write-Host "$c : $($status.connector.state)"
}
```

---

## Cleanup / Shutdown

### Stop the Producer

Press `Ctrl+C` in the terminal running `weather_producer.py`.

### Delete Connectors (optional)

```powershell
Invoke-RestMethod -Uri "http://localhost:8083/connectors/snowflake-raw-data" -Method Delete
Invoke-RestMethod -Uri "http://localhost:8083/connectors/snowflake-predictions" -Method Delete
Invoke-RestMethod -Uri "http://localhost:8083/connectors/snowflake-alerts" -Method Delete
```

### Stop Docker Containers

```powershell
docker compose down
```

### Stop and Remove Volumes (full reset)

```powershell
docker compose down -v
```

---

## Troubleshooting

| Issue | Diagnosis | Fix |
|-------|-----------|-----|
| Kafka Connect not starting | `docker logs kafka-connect` | Wait longer, or check broker connectivity |
| Snowflake connector not in plugin list | `Invoke-RestMethod http://localhost:8083/connector-plugins` | Verify JAR files in `connect-plugins/snowflake-kafka-connector/` |
| Connector status FAILED | `Invoke-RestMethod http://localhost:8083/connectors/<name>/status` | Check `snowflake.private.key` and `snowflake.url.name` values |
| Cannot connect to Snowflake (404) | Wrong URL format | Use `orgname-accountname.snowflakecomputing.com` (not locator) |
| Private key error | Wrong key format | Use inline base64 body without PEM headers |
| Topics already exist | Normal if re-running | `create_topics.py` handles this gracefully |
| No data in Snowflake | Connector not running or producer not started | Check connector status and producer output |
| `kafka-python` connection refused | Brokers not ready | Wait for brokers to start, check `docker compose ps` |

---

## Project File Reference

```
Kafka_SF/
  docker-compose.yml                    -- Docker infrastructure (2 brokers, UI, Connect)
  connect-distributed.properties        -- Kafka Connect config (reference only)
  connect-plugins/
    snowflake-kafka-connector/
      snowflake-kafka-connector-2.4.1.jar
      bc-fips-1.0.2.4.jar
      bcpkix-fips-1.0.7.jar
  snowflake_kafka_key.p8                -- RSA private key for Snowflake auth
  connect-snowflake-raw.json            -- Connector config: weather-raw-data -> WEATHER_RAW_DATA
  connect-snowflake-predictions.json    -- Connector config: weather-predictions -> WEATHER_PREDICTIONS
  connect-snowflake-alerts.json         -- Connector config: weather-alerts -> WEATHER_ALERTS
  create_topics.py                      -- Creates 3 Kafka topics
  weather_producer.py                   -- Generates and publishes weather data continuously
  sql/
    01_create_database_schema.sql       -- Database + schema creation
    02_create_tables.sql                -- Table definitions
    03_create_role_and_user.sql         -- Role, user, and grants
    04_assign_public_key.sql            -- RSA public key assignment
    05_verify_data.sql                  -- Verification queries
```


