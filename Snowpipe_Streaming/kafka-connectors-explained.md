# Kafka Connectors Explained

---

## What is Kafka Connect?

Kafka Connect is a **built-in framework** in Apache Kafka that moves data **into** and **out of** Kafka automatically -- without you writing custom code.

Think of it as a **delivery service**:
- Kafka is the **warehouse** (stores messages)
- Kafka Connect is the **delivery truck** (moves data between the warehouse and destinations)
- Connectors are the **drivers** (know the specific route to each destination)

```
  [Data Sources]  --->  Kafka Connect  --->  [Kafka Topics]  --->  Kafka Connect  --->  [Destinations]
   (databases,          (Source              (messages sit          (Sink                 (Snowflake,
    APIs, files)         Connectors)          here)                 Connectors)            S3, DBs)
```

### Two types of connectors

| Type | Direction | Example |
|------|-----------|---------|
| **Source Connector** | External system --> Kafka | Read rows from PostgreSQL, push into Kafka topic |
| **Sink Connector** | Kafka --> External system | Read from Kafka topic, write into Snowflake table |

**Our project uses a Sink Connector** -- the Snowflake Kafka Connector. It reads messages from Kafka topics and writes them into Snowflake tables.

---

## Common Misconception: Connectors Do NOT Talk TO Kafka Connect

A common misunderstanding is thinking the flow works like this:

```
WRONG understanding:
  Connectors  --->  communicate to  --->  Kafka Connect  --->  Snowflake
  (separate)        (separate)                                  (separate)
```

**This is incorrect.** Connectors do not communicate TO Kafka Connect. Connectors run INSIDE Kafka Connect. They are not separate services.

### The correct relationship

```
+----------------------------------------------------------+
|                    Kafka Connect                          |
|                (the framework / runtime)                  |
|                                                          |
|   +--------------------------------------------------+   |
|   |       Snowflake Kafka Connector (plugin)         |   |
|   |       Loaded from the JAR file at startup        |   |
|   |                                                  |   |
|   |   +------------------+  +--------------------+   |   |
|   |   | Task-0           |  | Task-1             |   |   |
|   |   | reads partition 0|  | reads partition 1  |   |   |
|   |   | writes to SF     |  | writes to SF       |   |   |
|   |   +------------------+  +--------------------+   |   |
|   +--------------------------------------------------+   |
|                                                          |
+----------------------------------------------------------+
         |                                    |
         | reads from                         | writes to
         v                                    v
   Kafka Topics                         Snowflake Tables
   (broker-1, broker-2)                 (via Snowpipe Streaming)
```

### Analogy

| Concept | Analogy |
|---------|---------|
| **Kafka Connect** | A car (the engine, wheels, fuel system) |
| **Snowflake Kafka Connector** | The driver sitting INSIDE the car (knows the route to Snowflake) |
| **Connector JSON config** | GPS destination (tells the driver where to go) |

The driver does not "communicate to" the car -- the driver **runs inside** the car. The car provides the engine (offset tracking, parallelism, REST API, error handling), and the driver uses it to get to the destination (Snowflake).

### There is no separate "Snowflake Kafka Connect" service

In our Docker setup, there is only ONE service for all of this:

```yaml
# docker-compose.yml -- only ONE service handles everything
kafka-connect:
  image: confluentinc/cp-kafka-connect-base:7.6.0    # <-- This IS Kafka Connect
  volumes:
    - ./connect-plugins/snowflake-kafka-connector:/usr/share/...  # <-- Connector JAR loaded INTO it
```

When this container starts:
1. Kafka Connect (the framework) boots up
2. It scans the plugin directory and finds the Snowflake connector JAR
3. It loads the JAR into memory (like installing an app on your phone)
4. Now the Snowflake connector is available INSIDE Kafka Connect
5. When you deploy a config via REST API, Kafka Connect creates a connector instance INSIDE itself

### The correct step-by-step flow

```
Step 1: Docker starts the kafka-connect container
        (Kafka Connect framework boots up)
               |
               v
Step 2: Kafka Connect loads Snowflake connector JAR from plugin directory
        (the connector plugin is now available inside Kafka Connect)
               |
               v
Step 3: You deploy a connector config via REST API
        (Invoke-RestMethod -Method Post ... -InFile "connect-snowflake-raw.json")
               |
               v
Step 4: Kafka Connect creates a connector instance INSIDE itself
        (named "snowflake-raw-data", with the settings from your JSON)
               |
               v
Step 5: The connector (running inside Kafka Connect) reads from Kafka topics
        (connects to broker-1:19092, broker-2:19092)
               |
               v
Step 6: The connector (running inside Kafka Connect) writes to Snowflake
        (opens Snowpipe Streaming channels, inserts rows into tables)
               |
               v
Step 7: Data appears in Snowflake tables within seconds
```

### Quick summary

| What it is | Role | Runs where |
|-----------|------|------------|
| **Kafka Connect** | Framework/runtime that manages connectors | Docker container `kafka-connect` |
| **Snowflake Kafka Connector** | Plugin that knows how to write to Snowflake | Loaded INSIDE the Kafka Connect container (from JAR file) |
| **Connector instance** (e.g., `snowflake-raw-data`) | A running instance with specific config (which topic, which table) | Created INSIDE Kafka Connect when you deploy the JSON |
| **Tasks** | Workers that do the actual reading/writing | Created INSIDE the connector instance |

Everything runs inside one Docker container. There is no separate Snowflake service, no separate connector service. Just Kafka Connect with the Snowflake plugin loaded inside it.

---

## Before Connectors: The Manual Way

Without connectors, you would need to write your own consumer code to move data from Kafka to Snowflake.

### Example: Manual consumer (what you would have to build yourself)

```python
# WITHOUT connectors -- you write ALL of this yourself
from kafka import KafkaConsumer
import snowflake.connector
import json

# Step 1: Connect to Kafka
consumer = KafkaConsumer('weather-raw-data', bootstrap_servers='localhost:9092')

# Step 2: Connect to Snowflake
sf = snowflake.connector.connect(user='...', password='...', account='...')
cursor = sf.cursor()

# Step 3: Read messages one by one
for message in consumer:
    data = json.loads(message.value)

    # Step 4: Build INSERT statement manually
    cursor.execute("""
        INSERT INTO WEATHER_RAW_DATA (CITY, TEMPERATURE_C, HUMIDITY_PCT, ...)
        VALUES (%s, %s, %s, ...)
    """, (data['city'], data['temperature_c'], data['humidity_pct'], ...))

    # Step 5: Handle offsets yourself (track what you already processed)
    consumer.commit()

    # Step 6: Handle errors yourself (retries, dead letters, reconnection)
    # Step 7: Handle schema changes yourself
    # Step 8: Handle parallelism yourself (multiple partitions)
    # Step 9: Handle batching yourself (don't INSERT one row at a time)
    # Step 10: Handle monitoring yourself (is it running? is it behind?)
```

### Problems with the manual approach

| Problem | What goes wrong |
|---------|-----------------|
| **Offset tracking** | If your code crashes, which messages did you already process? You lose track and either skip or duplicate data |
| **Error handling** | Network blip to Snowflake? Your code crashes. You need retry logic, backoff, dead letter queues |
| **Schema changes** | Producer adds a new field? Your INSERT breaks. You need to detect and handle this |
| **Parallelism** | Topic has 3 partitions? You need 3 consumer threads, coordinated so they don't read the same message |
| **Batching** | INSERT one row at a time = extremely slow. You need to batch rows and flush periodically |
| **Monitoring** | Is your consumer running? Is it falling behind? You need health checks and lag monitoring |
| **Deployment** | You need to deploy, run, restart, and scale this code yourself |

This is hundreds of lines of production-grade code that you have to write, test, and maintain.

---

## After Connectors: The Kafka Connect Way

With connectors, you write **zero code**. You provide a JSON configuration file, and Kafka Connect handles everything.

### Example: Connector config (what you actually write)

```json
{
  "name": "snowflake-raw-data",
  "config": {
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",
    "topics": "weather-raw-data",
    "snowflake.url.name": "ekjguym-fl96854.snowflakecomputing.com",
    "snowflake.user.name": "KAFKA_CONNECTOR_USER",
    "snowflake.private.key": "MIIEvQ...",
    "snowflake.database.name": "WEATHER_PIPELINE",
    "snowflake.schema.name": "KAFKA_DATA",
    "snowflake.topic2table.map": "weather-raw-data:WEATHER_RAW_DATA",
    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",
    "buffer.flush.time": "10",
    "buffer.count.records": "1000"
  }
}
```

Deploy it with one command:
```powershell
Invoke-RestMethod -Method Post -Uri "http://localhost:8083/connectors" `
  -ContentType "application/json" -InFile "connect-snowflake-raw.json"
```

**That is it.** No consumer code. No offset tracking. No error handling. No batching logic. Kafka Connect does it all.

---

## What Does "Deploy" Actually Mean?

This is an important distinction. **Creating** a connector and **deploying** a connector are two different things.

### Creating = Writing the JSON config file

When we say "we created 3 connectors", we mean we wrote 3 JSON configuration files on our local machine:

```
Kafka_SF/
  connect-snowflake-raw.json          <-- config for raw data connector
  connect-snowflake-predictions.json   <-- config for predictions connector
  connect-snowflake-alerts.json        <-- config for alerts connector
```

At this point, **nothing is running**. These are just text files sitting on your computer. Kafka Connect does not know they exist. No data is flowing. It is like writing a recipe but not cooking yet.

### Deploying = Sending the JSON config to Kafka Connect via REST API

**Deploy means telling Kafka Connect: "Here is a connector configuration. Start running it now."**

You do this by sending the JSON file to the Kafka Connect REST API using an HTTP POST request:

```powershell
# Deploy connector 1: raw data
Invoke-RestMethod -Method Post -Uri "http://localhost:8083/connectors" `
  -ContentType "application/json" -InFile "connect-snowflake-raw.json"

# Deploy connector 2: predictions
Invoke-RestMethod -Method Post -Uri "http://localhost:8083/connectors" `
  -ContentType "application/json" -InFile "connect-snowflake-predictions.json"

# Deploy connector 3: alerts
Invoke-RestMethod -Method Post -Uri "http://localhost:8083/connectors" `
  -ContentType "application/json" -InFile "connect-snowflake-alerts.json"
```

### What happens inside Kafka Connect when you deploy

```
You run: Invoke-RestMethod -Method Post ... -InFile "connect-snowflake-raw.json"
                |
                v
  Kafka Connect receives the JSON via REST API (port 8083)
                |
                v
  It reads the config: "connector.class = SnowflakeSinkConnector"
                |
                v
  It loads the Snowflake connector JAR from the plugin directory
                |
                v
  It creates the connector instance named "snowflake-raw-data"
                |
                v
  It stores the config in the internal Kafka topic "connect-configs"
  (so the config survives restarts -- Kafka Connect remembers it)
                |
                v
  It starts worker tasks (tasks.max: 2 --> creates 2 tasks)
                |
                v
  Tasks connect to Kafka topic "weather-raw-data" and start reading
                |
                v
  Tasks connect to Snowflake via Snowpipe Streaming and start writing
                |
                v
  DATA IS NOW FLOWING from Kafka to Snowflake
```

### Analogy

| Step | Analogy | What you do |
|------|---------|-------------|
| **Create** (write JSON) | Writing a delivery address on paper | Edit `connect-snowflake-raw.json` on your machine |
| **Deploy** (POST to API) | Handing the address to the delivery driver | `Invoke-RestMethod -Method Post ...` |
| **Running** (connector active) | Driver is on the road delivering packages | Kafka Connect reads Kafka, writes to Snowflake continuously |

### The complete lifecycle of a connector

```
  CREATE (write JSON)  -->  DEPLOY (POST to API)  -->  RUNNING (data flows)
       |                         |                         |
  Just a file on disk.     Kafka Connect receives      Connector is active.
  Nothing happens yet.     the config and starts        Data moves from Kafka
                           the connector.               to Snowflake.
                                                             |
                                                             v
                                                    Can be PAUSED (stop reading,
                                                    but connector still exists)
                                                             |
                                                             v
                                                    Can be RESUMED (start reading
                                                    again from where it left off)
                                                             |
                                                             v
                                                    Can be DELETED (removed completely,
                                                    must re-deploy to run again)
```

### Our 3 connectors: created vs deployed

| File (Created) | Connector Name (Deployed) | Status after deploy |
|-----------------|--------------------------|---------------------|
| `connect-snowflake-raw.json` | `snowflake-raw-data` | RUNNING -- reads `weather-raw-data` topic, writes to `WEATHER_RAW_DATA` table |
| `connect-snowflake-predictions.json` | `snowflake-predictions` | RUNNING -- reads `weather-predictions` topic, writes to `WEATHER_PREDICTIONS` table |
| `connect-snowflake-alerts.json` | `snowflake-alerts` | RUNNING -- reads `weather-alerts` topic, writes to `WEATHER_ALERTS` table |

### Why is deploy separate from create?

Because the JSON config file and the running connector are independent:

1. **You can edit the JSON file** without affecting a running connector (it is already deployed, changing the file does nothing)
2. **You can delete a running connector** without deleting the JSON file (the file stays, you can re-deploy later)
3. **Kafka Connect remembers deployed connectors** even after restart (stored in Kafka's internal topic `connect-configs`), so you do NOT need to re-deploy after Docker restart
4. **You only deploy once** -- after that, the connector runs until you explicitly delete it or Kafka Connect goes down permanently (losing its internal topics)

### When do you need to re-deploy?

| Scenario | Need to re-deploy? |
|----------|-------------------|
| Docker restart (volumes preserved) | No -- Kafka Connect remembers the config |
| Docker restart (volumes deleted / `docker-compose down -v`) | Yes -- internal topics are wiped |
| Changed the JSON config file | Yes -- delete the old connector, then deploy the updated JSON |
| Connector is in FAILED state | Try restarting first (`/restart`), re-deploy if that fails |
| Offset mismatch after topic recreation | Yes -- delete connector, drop Snowflake table, recreate table, re-deploy |

### How to verify a connector is deployed and running

```powershell
# List all deployed connectors
Invoke-RestMethod http://localhost:8083/connectors
# Output: ["snowflake-raw-data","snowflake-predictions","snowflake-alerts"]

# Check status of a specific connector
Invoke-RestMethod http://localhost:8083/connectors/snowflake-raw-data/status
# Look for: "state": "RUNNING" in both connector and tasks
```

---

## What Each Part of the Config Means

```json
{
  "name": "snowflake-raw-data",           // Unique name for this connector instance

  "config": {
    // WHAT connector to use
    "connector.class": "com.snowflake.kafka.connector.SnowflakeSinkConnector",

    // WHERE to read from (Kafka side)
    "topics": "weather-raw-data",          // Which Kafka topic to consume
    "tasks.max": "2",                      // How many parallel workers (1 per partition ideally)

    // WHERE to write to (Snowflake side)
    "snowflake.url.name": "ekjguym-fl96854.snowflakecomputing.com",
    "snowflake.database.name": "WEATHER_PIPELINE",
    "snowflake.schema.name": "KAFKA_DATA",
    "snowflake.topic2table.map": "weather-raw-data:WEATHER_RAW_DATA",

    // HOW to authenticate
    "snowflake.user.name": "KAFKA_CONNECTOR_USER",
    "snowflake.private.key": "MIIEvQ...",  // RSA private key (base64 body)

    // HOW to ingest
    "snowflake.ingestion.method": "SNOWPIPE_STREAMING",  // Direct row insert, <10s latency
    "snowflake.enable.schematization": "true",            // Auto-map JSON fields to columns

    // WHEN to flush (write buffered records to Snowflake)
    "buffer.flush.time": "10",             // Every 10 seconds
    "buffer.count.records": "1000"         // Or every 1000 records, whichever comes first
  }
}
```

---

## How Data Moves: Step by Step

Here is the complete flow from Python producer to Snowflake table:

```
Step 1          Step 2              Step 3              Step 4           Step 5
Producer  --->  Kafka Topic   --->  Kafka Connect  ---> Snowpipe     --> Snowflake
(Python)        (broker-1/2)        (Sink Connector)    Streaming        Table
```

### Detailed walkthrough

**Step 1: Producer sends a message**
```python
# weather_producer.py sends this JSON to Kafka
producer.send('weather-raw-data', {
    "city": "Mumbai",
    "timestamp": "2025-04-14T10:30:00",
    "temperature_c": 32.5,
    "humidity_pct": 78.0
})
```

**Step 2: Kafka stores the message**
```
Topic: weather-raw-data
  Partition 0: [msg1, msg4, msg7, ...]   <-- broker-1
  Partition 1: [msg2, msg5, msg8, ...]   <-- broker-2
  Partition 2: [msg3, msg6, msg9, ...]   <-- broker-1
```
Messages sit in the topic until someone reads them. Kafka keeps them even after reading (retention period).

**Step 3: Kafka Connect reads messages**
```
Connector: snowflake-raw-data
  Task-0 reads Partition 0 and Partition 2
  Task-1 reads Partition 1

  Each task:
    1. Pulls messages from its assigned partitions
    2. Deserializes JSON
    3. Buffers records in memory
    4. When buffer is full (1000 records) OR timer fires (10 seconds):
       --> Flush to Snowflake
    5. After successful flush, commits offset back to Kafka
       (so if it restarts, it knows where it left off)
```

**Step 4: Snowpipe Streaming writes rows**
```
Connector opens a "channel" to Snowflake for each partition:
  Channel: WEATHER_RAW_DATA.WEATHER-RAW-DATA_0  (partition 0)
  Channel: WEATHER_RAW_DATA.WEATHER-RAW-DATA_1  (partition 1)
  Channel: WEATHER_RAW_DATA.WEATHER-RAW-DATA_2  (partition 2)

Each channel inserts rows directly into the table -- no staging files,
no COPY INTO, no waiting. Rows appear in Snowflake within seconds.
```

**Step 5: Data lands in Snowflake table**
```sql
SELECT * FROM WEATHER_PIPELINE.KAFKA_DATA.WEATHER_RAW_DATA LIMIT 3;

-- CITY    | TIMESTAMP            | TEMPERATURE_C | HUMIDITY_PCT | ...
-- Mumbai  | 2025-04-14 10:30:00  | 32.5          | 78.0         | ...
-- Delhi   | 2025-04-14 10:30:00  | 28.1          | 65.3         | ...
-- Chennai | 2025-04-14 10:30:00  | 34.2          | 82.1         | ...
```

---

## Our Project: 3 Connectors for 3 Data Flows

We use 3 separate connectors because each data flow has different characteristics:

```
weather_producer.py
    |
    |--- sends raw readings -------> [weather-raw-data]     ---> snowflake-raw-data connector
    |                                  3 partitions               tasks.max: 2
    |                                                             flush: 10s or 1000 records
    |                                                             --> WEATHER_RAW_DATA table
    |
    |--- sends forecasts ----------> [weather-predictions]  ---> snowflake-predictions connector
    |                                  3 partitions               tasks.max: 1
    |                                                             flush: 30s or 100 records
    |                                                             --> WEATHER_PREDICTIONS table
    |
    |--- sends threshold alerts ---> [weather-alerts]       ---> snowflake-alerts connector
                                       2 partitions               tasks.max: 1
                                                                  flush: 5s or 50 records
                                                                  --> WEATHER_ALERTS table
```

### Why different settings?

| Connector | Flush Time | Flush Count | Why |
|-----------|-----------|-------------|-----|
| Raw Data | 10 seconds | 1000 records | High volume, moderate urgency. Batch more for efficiency |
| Predictions | 30 seconds | 100 records | Low volume (sent every 5th batch). No rush |
| Alerts | 5 seconds | 50 records | Low volume but HIGH urgency. Alerts should appear fast |

---

## What Kafka Connect Handles For You

| Feature | Manual Code | Kafka Connect |
|---------|------------|---------------|
| Offset tracking | You write it | Automatic (commits after successful flush) |
| Parallelism | You manage threads | Set `tasks.max`, Connect distributes partitions |
| Batching | You implement buffering | Configure `buffer.flush.time` and `buffer.count.records` |
| Error handling | You write retry logic | Built-in retries, error tolerance settings |
| Schema mapping | You parse JSON and build SQL | `schematization: true` auto-maps JSON to columns |
| Monitoring | You build health checks | REST API: `GET /connectors/status` |
| Scaling | You deploy more instances | Increase `tasks.max` or add more Connect workers |
| Restart recovery | You track checkpoints | Resumes from last committed offset automatically |
| Deployment | You run/manage a Python process | One REST API call to deploy, Kafka Connect runs it |

---

## Kafka Connect REST API (How You Manage Connectors)

Kafka Connect exposes a REST API on port 8083 for managing connectors:

```powershell
# List all connectors
Invoke-RestMethod http://localhost:8083/connectors

# Deploy a new connector
Invoke-RestMethod -Method Post -Uri "http://localhost:8083/connectors" `
  -ContentType "application/json" -InFile "connect-snowflake-raw.json"

# Check connector status
Invoke-RestMethod http://localhost:8083/connectors/snowflake-raw-data/status

# Pause a connector (stops reading, does not delete)
Invoke-RestMethod -Method Put -Uri "http://localhost:8083/connectors/snowflake-raw-data/pause"

# Resume a paused connector
Invoke-RestMethod -Method Put -Uri "http://localhost:8083/connectors/snowflake-raw-data/resume"

# Delete a connector (removes completely)
Invoke-RestMethod -Method Delete -Uri "http://localhost:8083/connectors/snowflake-raw-data"

# Check available connector plugins (what JARs are loaded)
Invoke-RestMethod http://localhost:8083/connector-plugins
```

---

## Summary

```
WITHOUT Connectors:
  Producer --> Kafka --> [Your custom Python consumer code] --> Snowflake
                         (hundreds of lines, error-prone, hard to maintain)

WITH Connectors:
  Producer --> Kafka --> [Kafka Connect + JSON config file] --> Snowflake
                         (zero code, production-ready, auto-managed)
```

Connectors let you focus on producing data. The delivery to Snowflake is handled by a battle-tested framework that thousands of companies use in production.
