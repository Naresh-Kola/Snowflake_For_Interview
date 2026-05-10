# Weather Producer Python Code - Complete Explanation for Beginners

This document explains every section of `create_topics.py` and `weather_producer.py` in plain English with real-life analogies.

---

# PART 1: create_topics.py (Topic Creator)

## What Does This Script Do?

Before sending any weather data, we need to create "mailboxes" (topics) in Kafka. This script creates 3 topics:

| Topic Name            | Purpose                                      | Partitions | Replication |
|-----------------------|----------------------------------------------|------------|-------------|
| weather-raw-data      | Stores raw weather readings from cities       | 3          | 2           |
| weather-predictions   | Stores 7-day weather forecasts                | 3          | 2           |
| weather-alerts        | Stores severe weather warnings                | 2          | 2           |

**Real-life analogy:** Before a post office can operate, you need to set up different mailbox categories -- one for regular mail, one for packages, one for urgent deliveries. This script sets up those categories.

---

## Line-by-Line Breakdown

### Imports

```python
from kafka.admin import KafkaAdminClient, NewTopic
from kafka.errors import TopicAlreadyExistsError
```

- `KafkaAdminClient` -- This is like a **remote control** for Kafka. It lets you create topics, delete topics, and manage the cluster from Python.
- `NewTopic` -- A blueprint for a topic you want to create. Like filling out a "new mailbox request" form.
- `TopicAlreadyExistsError` -- An error that Kafka throws if the topic already exists. We catch it so the script doesn't crash.

---

### Configuration

```python
BOOTSTRAP_SERVERS = "localhost:9092,localhost:9094"
```

This is the **address book** for Kafka. It lists the brokers your script should connect to. `localhost:9092` is broker-1, `localhost:9094` is broker-2.

**Why list both?** If broker-1 is down, the script can still connect via broker-2. It is a backup plan.

---

### Topic Definitions

```python
TOPICS = [
    {
        "name": "weather-raw-data",
        "partitions": 3,
        "replication_factor": 2,
        "description": "Raw weather readings from cities",
    },
    ...
]
```

Each topic is defined with:
- **name** -- The topic name (like a mailbox label)
- **partitions: 3** -- Split the topic into 3 parts so multiple consumers can read in parallel
- **replication_factor: 2** -- Copy the data to 2 brokers, so if one dies, the other still has the data

**Real-life analogy:**
- **Partitions = 3** is like having 3 delivery trucks. Instead of one truck delivering all packages, 3 trucks work simultaneously, each handling a portion.
- **Replication = 2** is like keeping a photocopy of every letter at two different branch offices.

**Why does weather-alerts have only 2 partitions?** Alerts are rare events. We don't need as much parallel processing power for them.

---

### The create_topics() Function

```python
admin = KafkaAdminClient(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    client_id="weather-topic-creator",
)
```

- Creates a connection to Kafka using the admin API
- `client_id` is just a label so Kafka's logs show which program connected ("weather-topic-creator")

```python
admin.create_topics(new_topics=[topic_obj], validate_only=False)
```

- `create_topics()` sends the request to Kafka to create the topic
- `validate_only=False` means "actually create it" (if set to True, it would only check if creation would succeed without doing it)

```python
except TopicAlreadyExistsError:
    print(f"  [EXISTS]   {topic_info['name']:<25} -- already exists, skipping")
```

If the topic already exists, we catch the error and print a friendly message instead of crashing.

**Real-life analogy:** If you try to register a mailbox that already exists, the post office says "That mailbox already exists" instead of shutting down.

---

---

# PART 2: weather_producer.py (Data Generator + Predictor)

## The Big Picture

This script is like a **weather station network** that:
1. Takes weather readings from 6 cities every 3 seconds
2. Sends those readings to Kafka (raw data)
3. Every 5th reading cycle, generates a 7-day weather forecast
4. Checks every reading for dangerous conditions and sends alerts

```
[Weather Station]          [Kafka Cluster]              [Consumers]
                                                        (your apps)
  Hyderabad  ----\
  Mumbai     -----\    weather-raw-data ---------> Dashboard
  Delhi      ------+-> weather-predictions ------> Forecast App
  Bangalore  -----/    weather-alerts -----------> Alert System
  Chennai   ----/
  Kolkata  ---/
```

---

## Section 1: Imports

```python
import json
import math
import random
import time
from collections import defaultdict
from datetime import datetime, timedelta
from kafka import KafkaProducer
```

| Import          | What It Does                                                            | Real-Life Analogy                                      |
|-----------------|-------------------------------------------------------------------------|--------------------------------------------------------|
| `json`          | Converts Python dictionaries to JSON strings (text format)              | Translating a form into a standard language everyone reads |
| `math`          | Provides mathematical functions like `sin()` for seasonal patterns      | A calculator for wave-like seasonal temperature curves  |
| `random`        | Generates random numbers for realistic data variation                   | Dice rolls -- weather is never exactly predictable      |
| `time`          | Lets us pause between data batches (`time.sleep`)                       | A timer -- "wait 3 seconds before sending the next batch" |
| `defaultdict`   | A dictionary that auto-creates empty lists for new keys                 | A filing cabinet that creates a new folder when you first use a label |
| `datetime`      | Works with dates and times                                              | A calendar and clock                                   |
| `timedelta`     | Represents time differences (e.g., "3 days from now")                   | Counting forward on a calendar                         |
| `KafkaProducer` | The Kafka client that sends (produces) messages to topics               | A mail truck that delivers letters to the post office  |

---

## Section 2: Configuration Constants

```python
BOOTSTRAP_SERVERS = "localhost:9092,localhost:9094"
RAW_TOPIC = "weather-raw-data"
PREDICTION_TOPIC = "weather-predictions"
ALERT_TOPIC = "weather-alerts"
PRODUCE_INTERVAL_SECONDS = 3
```

These are like **settings at the top of a control panel:**
- **BOOTSTRAP_SERVERS** -- Where to find Kafka (both broker addresses)
- **RAW_TOPIC / PREDICTION_TOPIC / ALERT_TOPIC** -- The 3 mailboxes we created earlier
- **PRODUCE_INTERVAL_SECONDS = 3** -- Generate new data every 3 seconds

**Why constants at the top?** So you can change settings in one place instead of hunting through the code. Like having all light switches on one panel instead of scattered across the house.

---

## Section 3: City Profiles

```python
CITY_PROFILES = {
    "Hyderabad": {
        "base_temp": 30, "temp_range": 10, "base_humidity": 55,
        "base_wind": 12, "base_pressure": 1012, "lat": 17.4,
    },
    ...
}
```

Each city has a **personality profile** based on real-world averages:

| Field           | Meaning                                                      | Example (Hyderabad)  |
|-----------------|--------------------------------------------------------------|----------------------|
| `base_temp`     | Average annual temperature in Celsius                        | 30 C                 |
| `temp_range`    | How much temperature swings between summer and winter        | 10 C (25-35 range)   |
| `base_humidity` | Average humidity percentage                                  | 55%                  |
| `base_wind`     | Average wind speed in km/h                                   | 12 km/h              |
| `base_pressure` | Average atmospheric pressure in hPa (hectopascals)           | 1012 hPa             |
| `lat`           | Latitude (not used in generation, but available for future)  | 17.4 N               |

**Real-life analogy:** Each city's profile is like a character sheet in a game. Delhi has extreme swings (temp_range=18 -- very hot summers, cold winters), while Bangalore is mild (temp_range=7).

**Why Mumbai has base_humidity 72 but Delhi has 50:** Mumbai is coastal (more moisture), Delhi is inland (drier).

---

## Section 4: History Buffer

```python
city_history = defaultdict(list)
MAX_HISTORY = 20
```

- `city_history` stores the last 20 weather readings per city
- This is used later to calculate forecasts (you need past data to predict the future)

**Real-life analogy:** A weather station keeps a logbook of recent observations. To predict tomorrow's weather, you look at trends from the past few readings. "Temperature has been rising for the last 5 readings, so it'll probably be hotter tomorrow."

---

## Section 5: Seasonal and Time-of-Day Factors

### get_seasonal_factor(day_of_year)

```python
def get_seasonal_factor(day_of_year):
    return math.sin(2 * math.pi * (day_of_year - 80) / 365)
```

This creates a **wave pattern** over the year:
- Returns **+1** around late May (peak summer in India)
- Returns **-1** around late November (winter)
- Returns **0** around February and August (transitions)

**Why a sine wave?** Temperature across the year follows a smooth wave pattern -- it doesn't jump from 20 C to 40 C overnight. The sine function creates this natural smooth curve.

```
Temperature over the year:

  Hot  +1  |        ****
           |      **    **
     0  ---|----*----------*----------
           |  *              **
  Cold -1  |*                  ****
           Jan  Mar  May  Jul  Sep  Nov
```

### get_time_of_day_factor(hour)

```python
def get_time_of_day_factor(hour):
    return math.sin(2 * math.pi * (hour - 4) / 24)
```

Same idea but for **daily temperature swings:**
- Returns **+1** around 4 PM (hottest part of the day)
- Returns **-1** around 4 AM (coldest part of the night)

**Real-life analogy:** You know how mornings are cool, afternoons are hot, and nights are cool again? This function recreates that natural daily cycle mathematically.

---

## Section 6: generate_weather_reading() -- The Core Data Generator

This function creates **one weather snapshot** for a city. Here's how each measurement is calculated:

### Temperature

```python
temp = (
    profile["base_temp"]
    + seasonal * (profile["temp_range"] / 2)
    + time_of_day * 4
    + random.gauss(0, 1.5)
)
```

**Formula breakdown:**
1. Start with the city's average: `30 C` (Hyderabad)
2. Add seasonal swing: `+5 C in summer, -5 C in winter`
3. Add daily swing: `+4 C in afternoon, -4 C at dawn`
4. Add random noise: `random.gauss(0, 1.5)` -- a random number centered at 0 with most values within +/- 3 C

**Real-life analogy:** The actual temperature = base average + "is it summer or winter?" + "is it day or night?" + "random daily variation" (sometimes it's cloudier than expected, etc.)

### Humidity

```python
humidity = max(10, min(100,
    profile["base_humidity"]
    - (temp - profile["base_temp"]) * 1.2
    + random.gauss(0, 5)
))
```

Humidity goes **down** when temperature goes **up** (hot air holds more moisture, so relative humidity drops). The `max(10, min(100, ...))` clamps the value between 10% and 100% -- humidity can't be negative or above 100%.

**Real-life analogy:** On a very hot day, the air feels drier (lower humidity). On a cool morning, you see dew (higher humidity). This formula recreates that inverse relationship.

### Wind Speed

```python
wind_speed = max(0,
    profile["base_wind"] + time_of_day * 3 + random.gauss(0, 3)
)
```

Wind is slightly higher in the afternoon (thermal convection) and has random variation. `max(0, ...)` ensures wind speed is never negative.

### Pressure, Cloud Cover, UV Index, Visibility, Rain Probability

Each follows a similar pattern:
- Start with a base value or derive from other measurements
- Add realistic correlations (more clouds = less UV, more humidity = more rain probability)
- Add random noise
- Clamp to valid ranges

**Key relationships:**
- **Cloud cover** increases with humidity (moist air forms clouds)
- **UV index** decreases with cloud cover (clouds block sunlight)
- **Visibility** decreases with humidity and clouds (fog, haze)
- **Rain probability** increases with humidity and cloud cover

### The Return Value

```python
reading = {
    "city": "Hyderabad",
    "timestamp": "2026-04-13T19:30:00",
    "temperature_c": 32.5,
    "humidity_pct": 48.3,
    "wind_speed_kmh": 14.2,
    "wind_direction": "SE",
    "pressure_hpa": 1013.5,
    "cloud_cover_pct": 35.8,
    "uv_index": 7.2,
    "visibility_km": 12.4,
    "rain_probability_pct": 15.3,
}
```

This dictionary is what gets sent to Kafka as a JSON message. Each reading is a **snapshot** of one city at one moment.

---

## Section 7: generate_7day_prediction() -- The Forecast Engine

### When Does It Run?

Every 5th batch (every ~15 seconds). It looks at the stored history for each city and predicts the next 7 days.

### Step 1: Weighted Moving Average

```python
weights = list(range(1, len(history) + 1))  # [1, 2, 3, ..., 20]
avg_temp = sum(r["temperature_c"] * w for r, w in zip(history, weights)) / total_w
```

**What is a weighted average?** Recent readings matter more than older ones. If you have 20 readings, the 20th (newest) gets weight 20, and the 1st (oldest) gets weight 1.

**Real-life analogy:** If you're predicting tomorrow's weather, today's reading matters much more than last week's reading. Weighted average gives more importance to recent data.

**Example:**
- Reading 1 (old): 28 C, weight 1 --> contributes 28
- Reading 2 (newer): 30 C, weight 2 --> contributes 60
- Reading 3 (newest): 33 C, weight 3 --> contributes 99
- Weighted average = (28 + 60 + 99) / (1 + 2 + 3) = 187 / 6 = 31.2 C

A simple average would give 30.3 C, but the weighted average (31.2 C) is closer to the recent trend.

### Step 2: Trend Detection

```python
recent_temps = [r["temperature_c"] for r in history[-5:]]
temp_trend = (recent_temps[-1] - recent_temps[0]) / len(recent_temps)
```

Looks at the last 5 readings to see if temperature is **rising or falling**.

**Example:** If the last 5 temps are [28, 29, 30, 31, 32], the trend = (32 - 28) / 5 = +0.8 C per reading (getting hotter).

### Step 3: Future Day Predictions

```python
for day_offset in range(1, 8):  # Days 1 through 7
    drift = day_offset * temp_trend * 0.5
    uncertainty = day_offset * 0.8
    pred_temp_high = round(avg_temp + drift + 4 + random.gauss(0, uncertainty), 1)
```

For each of the next 7 days:
- **drift** -- If temp is trending up, future days continue that trend
- **uncertainty** -- Gets larger for days further out (Day 7 is less certain than Day 1)
- **+4 / -4** -- Daily high is ~4 degrees above average, low is ~4 below

**Real-life analogy:** Weather apps show Day 1 forecast as very accurate (87% confidence) but Day 7 as less reliable (39% confidence). This code models that same behavior -- uncertainty grows each day.

### Step 4: Condition Labels

```python
if pred_rain > 70:
    condition = "Heavy Rain"
elif pred_rain > 40:
    condition = "Light Rain"
elif avg_cloud > 60:
    condition = "Cloudy"
elif avg_cloud > 30:
    condition = "Partly Cloudy"
else:
    condition = "Sunny"
```

Converts numbers into human-readable weather conditions -- exactly like what you see on your phone's weather app.

### Step 5: Confidence Score

```python
"confidence_pct": round(max(30, 95 - day_offset * 8 + random.gauss(0, 2)), 1)
```

- Day 1: ~87% confidence
- Day 4: ~63% confidence
- Day 7: ~39% confidence

This matches real-world forecast accuracy -- no weather service is confident about Day 7.

---

## Section 8: Alert Detection -- check_alerts()

### Alert Rules

```python
ALERT_RULES = [
    {"field": "temperature_c", "condition": "gt", "threshold": 42, "severity": "HIGH",
     "message": "Extreme heat warning! Temperature above 42 C"},
    {"field": "visibility_km", "condition": "lt", "threshold": 2, "severity": "MEDIUM",
     "message": "Low visibility warning! Visibility below 2 km"},
    ...
]
```

Each rule says: "If [field] is [greater than / less than] [threshold], trigger an alert."

| Rule                   | Trigger Condition    | Severity | Real-World Equivalent                |
|------------------------|----------------------|----------|--------------------------------------|
| Extreme heat           | temp > 42 C          | HIGH     | Heatstroke danger, stay indoors      |
| Extreme cold           | temp < 5 C           | HIGH     | Hypothermia risk                     |
| High wind              | wind > 40 km/h       | HIGH     | Flying debris, tree damage           |
| Low visibility         | visibility < 2 km    | MEDIUM   | Driving hazard, fog warning          |
| Very high humidity     | humidity > 90%       | LOW      | Discomfort, mold risk                |
| Heavy rain likely      | rain_prob > 80%      | MEDIUM   | Carry umbrella, possible flooding    |

### How It Works

```python
def check_alerts(reading):
    alerts = []
    for rule in ALERT_RULES:
        value = reading.get(rule["field"], 0)
        if rule["condition"] == "gt" and value > rule["threshold"]:
            triggered = True
        ...
```

For every weather reading, the function loops through all rules and checks if any condition is met. If yes, it creates an alert message and adds it to the list.

**Real-life analogy:** Like a smoke detector in your house. It constantly monitors the air. If smoke level exceeds a threshold, the alarm triggers. This code has 6 "detectors" running simultaneously for different weather dangers.

---

## Section 9: The Main Loop -- main()

### Creating the Producer

```python
producer = KafkaProducer(
    bootstrap_servers=BOOTSTRAP_SERVERS,
    value_serializer=lambda v: json.dumps(v, indent=2).encode("utf-8"),
    key_serializer=lambda k: k.encode("utf-8") if k else None,
)
```

| Parameter           | What It Does                                                     | Real-Life Analogy                              |
|---------------------|------------------------------------------------------------------|------------------------------------------------|
| `bootstrap_servers` | Addresses of Kafka brokers to connect to                         | Phone numbers of the post office branches      |
| `value_serializer`  | Converts Python dict to JSON bytes before sending                | Putting a letter in an envelope (formatting)   |
| `key_serializer`    | Converts the message key (city name) to bytes                    | Writing the destination city on the envelope   |

**Why do we need serializers?** Kafka only understands **bytes** (raw binary data). Python dictionaries need to be converted to bytes before Kafka can store them. `json.dumps()` converts dict to string, `.encode("utf-8")` converts string to bytes.

### The Infinite Loop

```python
while True:
    batch_count += 1
    now = datetime.now()
```

The producer runs **forever** (until you press Ctrl+C), generating a new batch of weather readings every 3 seconds.

### Step 1: Generate and Send Raw Data

```python
reading = generate_weather_reading(city, profile, now)
producer.send(RAW_TOPIC, key=city, value=reading)
```

- Generate a weather reading for each city
- Send it to the `weather-raw-data` topic
- The **key=city** means all messages for "Hyderabad" go to the same partition (Kafka uses the key to decide which partition)

**Why use the city as the key?** All readings for one city go to the same partition, keeping them in order. A consumer reading "Hyderabad" data will always see readings in chronological order.

### Step 2: Store History

```python
city_history[city].append(reading)
if len(city_history[city]) > MAX_HISTORY:
    city_history[city] = city_history[city][-MAX_HISTORY:]
```

Save the reading for future prediction calculations. Keep only the last 20 readings (trim old ones to save memory).

**Real-life analogy:** A weather station logbook has limited pages. When it fills up, you tear out the oldest pages and keep only the recent 20 entries.

### Step 3: Check Alerts

```python
alerts = check_alerts(reading)
for alert in alerts:
    producer.send(ALERT_TOPIC, key=city, value=alert)
```

Every reading is checked against alert rules. If any dangerous condition is detected, an alert is published to the `weather-alerts` topic.

### Step 4: Generate Forecasts (Every 5th Batch)

```python
if batch_count % 5 == 0:
    for city in CITY_PROFILES:
        forecast = generate_7day_prediction(city, history)
        producer.send(PREDICTION_TOPIC, key=city, value=forecast)
```

`batch_count % 5 == 0` means "every 5th batch" (batches 5, 10, 15, 20...). Predictions are heavier computations, so we don't do them every 3 seconds.

**Real-life analogy:** A weather station takes temperature readings every few minutes but only publishes a full 7-day forecast a few times per day.

### Step 5: Flush and Sleep

```python
producer.flush()
time.sleep(PRODUCE_INTERVAL_SECONDS)
```

- `flush()` forces all buffered messages to be sent to Kafka immediately (the producer normally batches messages for efficiency)
- `sleep(3)` waits 3 seconds before the next batch

### Graceful Shutdown

```python
except KeyboardInterrupt:
    print("\nShutting down producer...")
finally:
    producer.close()
```

When you press **Ctrl+C**, the script catches the interrupt, prints a goodbye message, and properly closes the Kafka connection (so no data is lost in the buffer).

---

## Sample Output

When you run the producer, you will see output like this:

```
============================================================
  WEATHER DATA PRODUCER
============================================================
  Kafka Brokers : localhost:9092,localhost:9094
  Topics        : weather-raw-data, weather-predictions, weather-alerts
  Cities        : Hyderabad, Mumbai, Delhi, Bangalore, Chennai, Kolkata
  Interval      : 3s between batches
============================================================

--- Batch #1 at 2026-04-13 19:30:00 ---
  [RAW]   Hyderabad    temp=32.5C  humidity=48.3%  wind=14.2km/h  rain=15.3%
  [RAW]   Mumbai       temp=29.8C  humidity=68.1%  wind=16.5km/h  rain=35.7%
  [RAW]   Delhi        temp=35.2C  humidity=42.1%  wind=11.3km/h  rain=8.2%
  [RAW]   Bangalore    temp=26.1C  humidity=58.4%  wind=12.8km/h  rain=22.1%
  [RAW]   Chennai      temp=33.7C  humidity=62.5%  wind=15.1km/h  rain=28.9%
  [RAW]   Kolkata      temp=31.4C  humidity=59.8%  wind=10.5km/h  rain=19.6%

--- Batch #5 at 2026-04-13 19:30:12 ---
  [RAW]   ...

  Generating 7-day forecasts...
  [PRED]  Hyderabad    Day1: 36.2/28.8C Partly Cloudy  Day7: 35.1/27.5C Sunny  confidence: 88.3%-41.2%
  [PRED]  Mumbai       Day1: 33.1/26.2C Cloudy         Day7: 32.8/25.9C Light Rain  confidence: 86.1%-38.5%
```

---

## How to Run

### Step 1: Create Topics (run once)

```bash
python create_topics.py
```

### Step 2: Start the Producer (runs continuously)

```bash
python weather_producer.py
```

### Step 3: View Data in Kafka UI

Open `http://localhost:8081` in your browser and navigate to the Topics section. You will see messages flowing into all 3 topics in real time.

---

## Data Flow Diagram

```
                    create_topics.py (run once)
                           |
                    Creates 3 topics
                           |
                           v
  +-----------------------------------------------------+
  |              KAFKA CLUSTER                            |
  |                                                       |
  |   weather-raw-data  (3 partitions, 2 replicas)        |
  |   weather-predictions (3 partitions, 2 replicas)      |
  |   weather-alerts (2 partitions, 2 replicas)           |
  +-----------------------------------------------------+
                           ^
                           |
                  weather_producer.py
                   (runs continuously)
                           |
              +------------+------------+
              |            |            |
         Raw readings  Forecasts    Alerts
         (every 3s)    (every 15s)  (when triggered)
              |            |            |
     6 cities x 11    6 cities x    Only when
     measurements     7-day outlook  thresholds
     per reading      per forecast   are exceeded
```
