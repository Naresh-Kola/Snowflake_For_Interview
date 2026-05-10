# Kafka Weather Prediction Project - Complete Setup Guide (Step by Step)

This document tracks every single step and command executed from the very beginning to get this project running. Follow this guide to reproduce the entire setup from scratch.

---

## Prerequisites

Before starting, make sure you have:
- **Docker Desktop** installed and running on Windows
- **Python 3.12+** installed

---

## Step 1: Start Docker Desktop

Open Docker Desktop and wait for it to fully initialize. The whale icon in the system tray should be steady (not animating).

**Why wait?** If Docker's backend isn't fully ready, API calls will fail with a 500 Internal Server Error (we learned this the hard way).

---

## Step 2: Create the Project Folder

Create a folder called `Kafka_SF` on your Desktop (or wherever you prefer). This is where all project files will live.

---

## Step 3: Set Up the Python Virtual Environment

A virtual environment keeps your project's Python packages separate from your system Python. This avoids version conflicts between projects.

### Command: Create the virtual environment

```powershell
python -m venv env
```

This creates an `env/` folder inside `Kafka_SF/` containing a private copy of Python.

**What's inside `env/`?**
- `env\Scripts\` -- Contains `python.exe`, `pip.exe`, and the `activate` script
- `env\Lib\` -- Where installed packages are stored
- `env\pyvenv.cfg` -- Configuration file pointing to the base Python

### Command: Activate the virtual environment

```powershell
.\env\Scripts\Activate
```

After activation, your terminal prompt changes to show `(env)` at the beginning:
```
(env) PS C:\Users\...\Kafka_SF>
```

This means any `python` or `pip` commands now use the virtual environment, not your system Python.

### Command: Install dependencies from requirements.txt

```powershell
pip install -r requirements.txt
```

**Output:**
```
Successfully installed kafka-python-2.3.0
```

### Command: Verify the installation

```powershell
pip list
```

**Output:**
```
Package      Version
------------ -------
kafka-python 2.3.0
pip          25.0.1
```

**To deactivate the virtual environment later:**
```powershell
deactivate
```

---

## Step 4: Create docker-compose.yml

Create the `docker-compose.yml` file inside the `Kafka_SF` folder. This file defines 3 services:
- 2 Kafka brokers (KRaft mode, no Zookeeper)
- 1 Kafka UI dashboard

See `docker-compose-explained.md` for a detailed explanation of every line.

---

## Step 5: Start the Kafka Cluster

### Command 1: First attempt to start services

```powershell
docker compose up -d
```

**What happened:** FAILED with 500 Internal Server Error.

```
unable to get image 'apache/kafka:3.7.0': request returned 500 Internal Server Error
for API route and version http://%2F%2F.%2Fpipe%2FdockerDesktopLinuxEngine/v1.54/images/apache/kafka:3.7.0/json,
check if the server supports the requested API version
```

**Root cause:** Docker Desktop's Linux engine was not fully initialized yet.

---

### Command 2: Check Docker daemon status

```powershell
docker info
```

**Output (key parts):**
```
Client:
 Version:    29.4.0
 Context:    desktop-linux
Server:
 Server Version: 29.4.0
 Storage Driver: overlayfs2
```

**Result:** Docker daemon was running but the image API was temporarily unavailable.

---

### Command 3: Manually pull the Kafka image

```powershell
docker pull apache/kafka:3.7.0
```

**Output:**
```
3.7.0: Pulling from apache/kafka
59648cfc069f: Pull complete
6d5007388037: Pull complete
...
Status: Downloaded newer image for apache/kafka:3.7.0
docker.io/apache/kafka:3.7.0
```

**Result:** SUCCESS -- The image pulled correctly once Docker was ready.

---

### Command 4: Second attempt to start services

```powershell
docker compose up -d
```

**What happened:** PARTIALLY FAILED.

```
Container broker-1 Started
Container broker-2 Started
Container kafka-ui Error response from daemon: Conflict. The container name "/kafka-ui"
is already in use by container "46544933dd03..."
```

**Root cause:** A leftover `kafka-ui` container from a previous run was blocking creation.

---

### Command 5: Remove the stale container

```powershell
docker rm -f kafka-ui
```

**Output:**
```
kafka-ui
```

**Result:** SUCCESS -- Stale container removed.

---

### Command 6: Third attempt to start services

```powershell
docker compose up -d
```

**What happened:** PARTIALLY FAILED again.

```
Container broker-1 Running
Container broker-2 Running
Container kafka-ui Error response from daemon: ports are not available:
exposing port TCP 0.0.0.0:8080 -> 127.0.0.1:0:
listen tcp 0.0.0.0:8080: bind: Only one usage of each socket address
(protocol/network address/port) is normally permitted.
```

**Root cause:** Port 8080 was already in use by another process.

---

### Command 7: Find what's using port 8080

```powershell
netstat -ano | Select-String ":8080 "
```

**Output:**
```
TCP    0.0.0.0:8080    0.0.0.0:0    LISTENING    4080
TCP    [::]:8080       [::]:0       LISTENING    4080
```

---

### Command 8: Identify the process on port 8080

```powershell
Get-Process -Id 4080 | Select-Object Id, ProcessName, Path
```

**Output:**
```
  Id ProcessName Path
  -- ----------- ----
4080 TNSLSNR
```

**Result:** Oracle TNS Listener (TNSLSNR) was occupying port 8080.

---

### Command 9: Fix -- Remap kafka-ui port in docker-compose.yml

Changed the port mapping in `docker-compose.yml`:

```yaml
# BEFORE:
    ports:
      - "8080:8080"

# AFTER:
    ports:
      - "8081:8080"
```

This maps host port 8081 to container port 8080, avoiding the conflict.

---

### Command 10: Start kafka-ui with the new port

```powershell
docker compose up -d kafka-ui
```

**Output:**
```
Container broker-1 Running
Container broker-2 Running
Container kafka-ui Recreated
Container kafka-ui Started
```

**Result:** SUCCESS -- All 3 containers are now running.

---

### Command 11: Verify all containers are running

```powershell
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

**Output:**
```
NAMES      STATUS              PORTS
kafka-ui   Up 27 seconds       0.0.0.0:8081->8080/tcp, [::]:8081->8080/tcp
broker-2   Up About a minute   0.0.0.0:9094->9094/tcp, [::]:9094->9094/tcp
broker-1   Up About a minute   0.0.0.0:9092->9092/tcp, [::]:9092->9092/tcp
```

**Result:** All 3 services running successfully.

---

## Step 6: Verify Kafka UI in Browser

Open your web browser and navigate to:

```
http://localhost:8081
```

You should see the Kafka UI dashboard showing the cluster "local-kraft" with 2 brokers.

---

## Step 7: Create Kafka Topics

### Command 12: Run the topic creator script

```powershell
python create_topics.py
```

**Output:**
```
Connecting to Kafka at localhost:9092,localhost:9094...
  [CREATED]  weather-raw-data          partitions=3  replication=2  -- Raw weather readings from cities
  [CREATED]  weather-predictions       partitions=3  replication=2  -- 7-day weather forecast predictions
  [CREATED]  weather-alerts            partitions=2  replication=2  -- Severe weather alerts (storms, extreme temps, etc.)

All topics in cluster: ['weather-raw-data']

Done.
```

**Result:** SUCCESS -- All 3 topics created.

**Topics created:**

| Topic                 | Partitions | Replication Factor | Purpose                         |
|-----------------------|------------|--------------------|---------------------------------|
| weather-raw-data      | 3          | 2                  | Raw sensor readings from cities |
| weather-predictions   | 3          | 2                  | 7-day weather forecasts         |
| weather-alerts        | 2          | 2                  | Severe weather warnings         |

---

## Step 8: Start the Weather Data Producer

### Command 13: Run the weather producer

```powershell
python weather_producer.py
```

**Output (first few batches):**
```
============================================================
  WEATHER DATA PRODUCER
============================================================
  Kafka Brokers : localhost:9092,localhost:9094
  Topics        : weather-raw-data, weather-predictions, weather-alerts
  Cities        : Hyderabad, Mumbai, Delhi, Bangalore, Chennai, Kolkata
  Interval      : 3s between batches
============================================================

--- Batch #1 at 2026-04-13 20:02:55 ---
  [RAW]   Hyderabad    temp=27.7C  humidity=57.8%  wind=9.1km/h  rain=11.7%
  [RAW]   Mumbai       temp=25.2C  humidity=71.9%  wind=11.7km/h  rain=27.4%
  [RAW]   Delhi        temp=30.4C  humidity=37.6%  wind=4.6km/h  rain=0%
  [RAW]   Bangalore    temp=24.3C  humidity=69.8%  wind=8.7km/h  rain=31.7%
  [RAW]   Chennai      temp=31.0C  humidity=75.1%  wind=4.4km/h  rain=25.3%
  [RAW]   Kolkata      temp=28.0C  humidity=73.5%  wind=2.2km/h  rain=32.3%

--- Batch #2 at 2026-04-13 20:02:59 ---
  [RAW]   Hyderabad    temp=29.0C  humidity=59.4%  wind=4.1km/h  rain=17.5%
  [RAW]   Mumbai       temp=25.5C  humidity=75.0%  wind=13.0km/h  rain=36.8%
  [RAW]   Delhi        temp=27.9C  humidity=53.5%  wind=4.4km/h  rain=3.5%
  [RAW]   Bangalore    temp=23.4C  humidity=66.2%  wind=8.8km/h  rain=24.9%
  [RAW]   Chennai      temp=29.5C  humidity=66.6%  wind=7.9km/h  rain=16.5%
  [RAW]   Kolkata      temp=25.6C  humidity=62.4%  wind=6.3km/h  rain=0%

--- Batch #5 at 2026-04-13 20:03:08 ---
  [RAW]   Hyderabad    temp=27.7C  humidity=60.1%  wind=4.4km/h  rain=26.5%
  [RAW]   Mumbai       temp=26.7C  humidity=74.0%  wind=13.1km/h  rain=47.0%
  [RAW]   Delhi        temp=26.2C  humidity=48.6%  wind=1.5km/h  rain=0%
  [RAW]   Bangalore    temp=22.4C  humidity=62.3%  wind=4.3km/h  rain=7.7%
  [RAW]   Chennai      temp=29.1C  humidity=69.6%  wind=12.7km/h  rain=37.3%
  [RAW]   Kolkata      temp=27.9C  humidity=66.9%  wind=9.2km/h  rain=29.2%

  Generating 7-day forecasts...
  [PRED]  Hyderabad    Day1: 33.1/25.4C Partly Cloudy  Day7: 23.5/25.9C Light Rain  confidence: 87.4%-38.8%
  [PRED]  Mumbai       Day1: 31.0/22.4C Light Rain  Day7: 32.3/15.4C Heavy Rain  confidence: 87.3%-41.3%
  [PRED]  Delhi        Day1: 31.8/21.8C Partly Cloudy  Day7: 16.8/14.6C Partly Cloudy  confidence: 87.5%-38.8%
  [PRED]  Bangalore    Day1: 25.7/17.9C Partly Cloudy  Day7: 21.8/18.7C Partly Cloudy  confidence: 87.1%-38.6%
  [PRED]  Chennai      Day1: 33.5/25.6C Partly Cloudy  Day7: 32.4/19.8C Partly Cloudy  confidence: 88.3%-42.6%
  [PRED]  Kolkata      Day1: 31.1/22.9C Partly Cloudy  Day7: 21.4/27.6C Partly Cloudy  confidence: 87.1%-38.7%
```

**Result:** SUCCESS -- Raw data streaming every 3 seconds, 7-day forecasts generated every 5th batch.

Press **Ctrl+C** to stop the producer gracefully.

---

## Step 9: Verify Data in Kafka UI

1. Open `http://localhost:8081` in your browser
2. Click on **Topics** in the left sidebar
3. You should see all 3 topics:
   - `weather-raw-data` -- Click to see raw weather JSON messages
   - `weather-predictions` -- Click to see 7-day forecast JSON messages
   - `weather-alerts` -- Click to see alert messages (may be empty if no extreme conditions were generated)

---

## Complete Command History (Quick Reference)

Here is every command executed in order, for easy copy-paste:

```powershell
# Step 3: Set up virtual environment
python -m venv env                                            # create virtual environment
.\env\Scripts\Activate                                        # activate it
pip install -r requirements.txt                               # install kafka-python
pip list                                                      # verify installation

# Step 5: Start Kafka Cluster
docker compose up -d                                          # attempt 1 -- failed (500 error)
docker info                                                   # check Docker status
docker pull apache/kafka:3.7.0                                # manually pull image
docker compose up -d                                          # attempt 2 -- kafka-ui name conflict
docker rm -f kafka-ui                                         # remove stale container
docker compose up -d                                          # attempt 3 -- port 8080 conflict
netstat -ano | Select-String ":8080 "                         # find process on port 8080
Get-Process -Id 4080 | Select-Object Id, ProcessName, Path   # identify TNSLSNR on 8080
# (manually edit docker-compose.yml: change 8080:8080 to 8081:8080)
docker compose up -d kafka-ui                                 # start kafka-ui on new port
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"  # verify all running

# Step 7: Create Topics
python create_topics.py

# Step 8: Start Producer
python weather_producer.py                                    # Ctrl+C to stop
```

---

## Project File Structure

```
Kafka_SF/
|
|-- env/                                  # Python virtual environment (do not edit)
|-- requirements.txt                      # Python dependencies (kafka-python==2.3.0)
|
|-- docker-compose.yml                    # Docker services definition (2 brokers + UI)
|-- create_topics.py                      # Python script to create 3 Kafka topics
|-- weather_producer.py                   # Weather data generator + predictor + alerter
|
|-- docker-compose-explained.md           # Line-by-line explanation of docker-compose.yml
|-- weather-producer-explained.md         # Line-by-line explanation of Python code
|-- errors-encountered.md                 # All 4 errors documented with causes and fixes
|-- project-setup-guide.md               # THIS FILE -- full step-by-step setup guide
```

---

## Useful Docker Commands for Managing the Cluster

| Command | What It Does |
|---------|-------------|
| `docker compose up -d` | Start all services in background |
| `docker compose down` | Stop and remove containers (keeps data volumes) |
| `docker compose down -v` | Stop, remove containers AND delete all stored data |
| `docker compose ps` | Show status of all services |
| `docker compose logs broker-1` | View logs from broker-1 |
| `docker compose logs broker-2` | View logs from broker-2 |
| `docker compose logs kafka-ui` | View logs from kafka-ui |
| `docker compose restart broker-1` | Restart only broker-1 |
| `docker ps` | List all running containers |
| `docker rm -f <name>` | Force remove a container |

---

## Troubleshooting Quick Reference

| Problem | Solution |
|---------|----------|
| 500 Internal Server Error on image pull | Wait for Docker Desktop to fully start, then retry |
| Container name conflict | Run `docker rm -f <container-name>` then retry |
| Port already in use | Find the process with `netstat -ano`, then either kill it or remap the port |
| `kafka-python` not installed | Activate venv (`.\env\Scripts\Activate`) then `pip install -r requirements.txt` |
| Topics already exist | `create_topics.py` handles this -- it prints `[EXISTS]` and continues |
| Producer can't connect to Kafka | Make sure brokers are running: `docker ps` |
| No data in Kafka UI | Make sure `weather_producer.py` is running and check the correct topic |

---

## Timeline of Events

| Time  | Event |
|-------|-------|
| 19:34 | First `docker compose up -d` -- failed with 500 error |
| 19:35 | `docker info` -- confirmed Docker was running |
| 19:36 | `docker pull apache/kafka:3.7.0` -- image pulled successfully |
| 19:43 | Second `docker compose up -d` -- kafka-ui name conflict |
| 19:43 | `docker rm -f kafka-ui` -- removed stale container |
| 19:43 | Third `docker compose up -d` -- port 8080 conflict |
| 19:43 | Port investigation -- found Oracle TNS Listener on 8080 |
| 19:44 | Edited docker-compose.yml -- remapped kafka-ui to port 8081 |
| 19:44 | `docker compose up -d kafka-ui` -- all 3 containers running |
| 20:02 | `python create_topics.py` -- 3 topics created |
| 20:02 | `python weather_producer.py` -- data streaming to Kafka |
