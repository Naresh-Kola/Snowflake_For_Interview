# Snowpipe Streaming Execution -- Step-by-Step Explanation

This document explains **what we are doing and why** at each step of the Snowpipe Streaming setup.
For the actual commands and outputs, see `execution-log.md`.
For the SQL files, see the `sql/` folder.

---

## Overview: What Are We Building?

We are connecting our 3 Kafka topics to 3 Snowflake tables using the **Snowflake Connector for Kafka** with **Snowpipe Streaming**. Data flows like this:

```
weather_producer.py
        |
        v
  Kafka Brokers (Docker)
   |        |        |
   v        v        v
weather-  weather-  weather-
raw-data  predictions  alerts
   |        |        |
   v        v        v
  Kafka Connect (Docker)
  + Snowflake Connector
        |
        v (Snowpipe Streaming API -- direct row insert)
  Snowflake Tables
   |        |        |
   v        v        v
WEATHER_  WEATHER_  WEATHER_
RAW_DATA  PREDICTIONS  ALERTS
```

---

## Step 1: Create Database and Schema

**File**: `sql/01_create_database_schema.sql`

**What we do**: Create a new Snowflake database called `WEATHER_PIPELINE` and a schema called `KAFKA_DATA` inside it.

**Why**: Every project should have its own database. This keeps your weather data separate from other data in your Snowflake account. The schema `KAFKA_DATA` is like a folder inside the database -- it groups all our Kafka-related tables together.

**Real-life analogy**: Creating a new filing cabinet (database) and labeling a drawer (schema) for this project.

**Key concepts**:
- `IF NOT EXISTS` -- Makes the command safe to run multiple times. If the database/schema already exists, it just skips instead of throwing an error.
- We use `ACCOUNTADMIN` role to create these objects because it has full permissions.

---

## Step 2: Create 3 Target Tables

**File**: `sql/02_create_tables.sql`

**What we do**: Create 3 tables in the `WEATHER_PIPELINE.KAFKA_DATA` schema -- one for each Kafka topic.

**Why**: The Kafka Connector needs destination tables to write data into. Each topic has a different JSON structure, so each table has different columns.

### Table Mapping

| Kafka Topic | Snowflake Table | Description |
|-------------|----------------|-------------|
| `weather-raw-data` | `WEATHER_RAW_DATA` | Current weather readings (temp, humidity, wind, etc.) |
| `weather-predictions` | `WEATHER_PREDICTIONS` | 7-day forecasts with confidence scores |
| `weather-alerts` | `WEATHER_ALERTS` | Threshold-based alerts (heat, cold, wind, rain) |

### Design choice: Schematized vs Semi-structured

We chose **schematized** (individual columns like `TEMPERATURE_C FLOAT`) instead of a single `VARIANT` column because:
- **Query performance**: Snowflake can prune columns and optimize queries better
- **Type safety**: `FLOAT` ensures numeric comparisons work correctly
- **Readability**: `SELECT TEMPERATURE_C` is clearer than `SELECT data:temperature_c::FLOAT`

The exception is `PREDICTIONS` in `WEATHER_PREDICTIONS` -- it stays as `VARIANT` because it contains a nested JSON array of 7 daily forecasts. Snowflake handles nested arrays well with `LATERAL FLATTEN`.

### What is RECORD_METADATA?

Every table has a `RECORD_METADATA VARIANT` column. The Snowflake Kafka Connector automatically populates this with Kafka metadata:

```json
{
  "CreateTime": 1713028835123,
  "offset": 42,
  "partition": 1,
  "topic": "weather-raw-data"
}
```

This is useful for debugging ("which Kafka partition did this row come from?") and deduplication.

---

## Step 3: Create Role and User for the Connector

**File**: `sql/03_create_role_and_user.sql`

**What we do**: Create a dedicated Snowflake role (`KAFKA_CONNECTOR_ROLE`) and user (`KAFKA_CONNECTOR_USER`) for the Kafka Connector.

**Why**: Security best practice -- **principle of least privilege**. The connector should only have the minimum permissions it needs:
- `INSERT` to write rows
- `SELECT` to read schema information
- `CREATE TABLE` in case it needs to auto-create tables
- `USAGE` on database, schema, and warehouse

We do NOT give it `DELETE`, `UPDATE`, `DROP`, or any admin privileges.

**Real-life analogy**: Giving a delivery driver a keycard that only opens the loading dock, not the master key to the entire building.

### Why a separate user?

- **Audit trail**: All connector activity is logged under `KAFKA_CONNECTOR_USER`, separate from your personal activity
- **Key rotation**: You can rotate the connector's key without affecting your own access
- **Revocation**: If the connector is compromised, disable just that user

---

## Step 4: Generate RSA Key Pair

**What we do**: Generate a 2048-bit RSA private key and extract the public key using OpenSSL.

**Why**: The Snowflake Kafka Connector uses **key pair authentication** instead of username/password. This is more secure because:
- No password is transmitted over the network
- The private key never leaves your machine
- Keys can be rotated independently without changing passwords

**Files generated**:
- `snowflake_kafka_key.p8` -- Private key (PKCS#8 format). This stays on your machine and gets mounted into the Docker container.
- `snowflake_kafka_key.pub` -- Public key. This gets registered with the Snowflake user.

**Real-life analogy**: Like a house lock system:
- The **private key** is the physical key you carry (never share)
- The **public key** is the lock on the door (you give it to Snowflake)
- Only your private key can open the lock

---

## Step 5: Assign Public Key to Snowflake User

**File**: `sql/04_assign_public_key.sql`

**What we do**: Run `ALTER USER KAFKA_CONNECTOR_USER SET RSA_PUBLIC_KEY = '...'` with the actual base64-encoded public key.

**Why**: This links the public key to the user account. When the connector authenticates, it signs a challenge with the private key, and Snowflake verifies it against the stored public key.

---

## Step 6: Download Connector JARs

**What we do**: Download 3 JAR files into a `connect-plugins/` folder:
1. `snowflake-kafka-connector-2.4.1.jar` -- The Snowflake connector plugin
2. `bc-fips-1.0.2.4.jar` -- Bouncy Castle cryptography library
3. `bcpkix-fips-1.0.7.jar` -- Bouncy Castle PKIX support

**Why**: The Snowflake Kafka Connector is a plugin that runs inside Kafka Connect. Kafka Connect loads plugins from a directory -- we mount `connect-plugins/` into the Docker container.

The Bouncy Castle JARs are required for RSA key pair authentication. Without them, the connector cannot read the private key file.

**No Java needed on your machine**: These JARs run inside the Docker container (`apache/kafka:3.7.0`), which already has Java included.

---

## Step 7: Add Kafka Connect to Docker Compose

**What we do**: Add a new `kafka-connect` service to `docker-compose.yml`.

**Why**: Kafka Connect is a separate runtime that hosts connector plugins. It runs as its own Docker container alongside the existing brokers.

### Key configuration:
- **`CONNECT_BOOTSTRAP_SERVERS`**: Points to our 2 Kafka brokers (internal Docker network)
- **`CONNECT_GROUP_ID`**: Groups multiple Connect workers together (we use 1 worker)
- **`CONNECT_*_STORAGE_TOPIC`**: Kafka Connect stores its own state (configs, offsets, status) in special Kafka topics
- **`CONNECT_PLUGIN_PATH`**: Where to find connector JARs inside the container
- **Port 8083**: REST API for managing connectors (create, pause, delete, check status)

### Volume mounts:
- `./connect-plugins` mounts the JAR files
- `./snowflake_kafka_key.p8` mounts the private key (read-only for security)

---

## Step 8: Create Connector Configuration Files

**What we do**: Create 3 JSON config files -- one per Kafka topic.

**Why 3 separate connectors?**
- **Independent control**: Pause/restart one topic without affecting others
- **Independent monitoring**: See status and lag per topic
- **Independent error handling**: If alerts fails, raw data still flows
- **Different buffer settings**: Each topic has different urgency/volume

### Buffer settings explained:

| Topic | buffer.count | buffer.flush.time | Why |
|-------|-------------|-------------------|-----|
| `weather-raw-data` | 1000 | 10s | High volume -- batch for efficiency |
| `weather-predictions` | 100 | 30s | Low volume -- can wait longer |
| `weather-alerts` | 50 | 5s | Urgent -- flush quickly! |

### Key setting: `snowflake.ingestion.method: SNOWPIPE_STREAMING`

This is **the** setting that enables Snowpipe Streaming. Without it, the connector defaults to the old file-based Snowpipe method. With it, rows are written directly to Snowflake tables via the Streaming API -- no intermediate files, sub-10-second latency.

---

## Step 9: Deploy Connectors via REST API

**What we do**: Send HTTP POST requests to the Kafka Connect REST API (port 8083) with each JSON config file.

**Why**: Kafka Connect manages connectors through its REST API. When you POST a config:
1. Kafka Connect validates the config
2. Creates the connector and assigns tasks to workers
3. Tasks start consuming from Kafka topics and writing to Snowflake
4. State is stored in internal Kafka topics (survives restarts)

---

## Step 10: Verify Data Flow

**File**: `sql/05_verify_data.sql`

**What we do**: Query Snowflake to confirm data is arriving in all 3 tables.

**Checks**:
1. **Row counts** -- All 3 tables should have rows
2. **Latest data** -- Recent timestamps confirm real-time flow
3. **Ingestion latency** -- `LAG_SECONDS` under 15 means Snowpipe Streaming is working
4. **Data quality** -- Spot-check actual values make sense

---

## File Summary

| File | Purpose |
|------|---------|
| `sql/01_create_database_schema.sql` | Create WEATHER_PIPELINE database and KAFKA_DATA schema |
| `sql/02_create_tables.sql` | Create 3 target tables matching Kafka topic schemas |
| `sql/03_create_role_and_user.sql` | Create KAFKA_CONNECTOR_ROLE and KAFKA_CONNECTOR_USER |
| `sql/04_assign_public_key.sql` | Assign RSA public key to the connector user |
| `sql/05_verify_data.sql` | Verification queries for data flow |
| `connect-snowflake-raw.json` | Connector config for weather-raw-data topic |
| `connect-snowflake-predictions.json` | Connector config for weather-predictions topic |
| `connect-snowflake-alerts.json` | Connector config for weather-alerts topic |
| `execution-log.md` | Live log of all commands executed and their outputs |
