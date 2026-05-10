# Kafka Topics Explained -- Weather Prediction Pipeline

This file explains the **3 Kafka topics** used in our weather prediction pipeline,
what kind of data each topic stores, and includes sample JSON messages.

---

## Quick Overview

Think of Kafka topics like **separate mailboxes** in a post office:

| Topic | Purpose | Analogy |
|-------|---------|---------|
| weather-raw-data | Live sensor readings from cities | A thermometer taking readings every few seconds |
| weather-predictions | 7-day weather forecasts | The weekly weather forecast section in a newspaper |
| weather-alerts | Warning messages for dangerous conditions | Emergency weather alerts on your phone |

---

## Topic 1: weather-raw-data

### What It Stores

This topic receives **real-time weather sensor readings** -- one message per city, every 3 seconds.
Each message is a snapshot of current weather conditions at a specific city at a specific moment.

- **Partitions**: 3
- **Replication Factor**: 2 (data is copied across both brokers for safety)
- **Message Key**: City name (e.g., `Hyderabad`) -- ensures all data for one city goes to the same partition
- **Frequency**: 6 messages per batch (one per city), every 3 seconds

### What Each Field Means

| Field | Type | Description | Example Range |
|-------|------|-------------|---------------|
| city | string | City name | Hyderabad, Mumbai, Delhi, Bangalore, Chennai, Kolkata |
| 	imestamp | string | ISO 8601 date-time when reading was taken | `2026-04-13T20:20:35.123456` |
| 	emperature_c | float | Temperature in Celsius | 15 C to 40 C (varies by city and season) |
| humidity_pct | float | Relative humidity percentage | 30% to 90% |
| wind_speed_kmh | float | Wind speed in km/h | 0 to 25 km/h |
| pressure_hpa | float | Atmospheric pressure in hectopascals | 990 to 1030 hPa |
| cloud_cover_pct | float | Percentage of sky covered by clouds | 0% to 100% |
| uv_index | float | UV radiation index | 0 to 11+ |
| isibility_km | float | How far you can see in km | 1 to 15 km |
| ain_probability_pct | float | Chance of rain as percentage | 0% to 100% |
| conditions | string | Human-readable weather summary | Clear, Partly Cloudy, Cloudy, Light Rain, Heavy Rain |

### Sample JSON Message

`json
{
     city: Hyderabad,
    timestamp: 2026-04-13T20:20:35.123456,
    temperature_c: 28.7,
    humidity_pct: 64.6,
    wind_speed_kmh: 14.0,
    pressure_hpa: 1012.3,
    cloud_cover_pct: 45.2,
    uv_index: 2.1,
    visibility_km: 9.8,
    rain_probability_pct: 16.0,
    conditions: Partly Cloudy
}
`

### Real-Life Analogy

Imagine a **digital weather station** installed in each city. Every 3 seconds it takes a
photo of the current weather -- temperature, humidity, wind, etc. -- and mails that
photo to the `weather-raw-data` mailbox. Anyone who subscribes to this mailbox gets
a continuous stream of live weather snapshots from all 6 cities.

---

## Topic 2: weather-predictions

### What It Stores

This topic receives **7-day weather forecasts** -- one forecast per city, generated
every 5th batch (approximately every 15 seconds). The forecast uses the last several
raw readings to predict what the weather will be like over the next 7 days.

- **Partitions**: 3
- **Replication Factor**: 2
- **Message Key**: City name
- **Frequency**: 6 messages every 5th batch (one forecast per city, roughly every 15 seconds)

### What Each Field Means

| Field | Type | Description |
|-------|------|-------------|
| city | string | City being forecasted |
| generated_at | string | When the forecast was created |
| ased_on_readings | int | How many historical readings were used |
| predictions | array | List of 7 daily forecasts (one per day) |

**Each prediction entry contains:**

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| day | int | Day number (1 = tomorrow, 7 = next week) | 1 to 7 |
| date | string | The date being forecasted | `2026-04-14` |
| high_temp_c | float | Predicted maximum temperature | 33.5 |
| low_temp_c | float | Predicted minimum temperature | 24.2 |
| conditions | string | Expected weather conditions | Partly Cloudy |
| ain_probability_pct | float | Predicted chance of rain | 25.0 |
| confidence_pct | float | How confident the prediction is (decreases for later days) | 85.0 (Day 1) to 40.0 (Day 7) |

### Sample JSON Message

`json
{
    city: Mumbai,
    generated_at: 2026-04-13T20:20:47.654321,
    based_on_readings: 5,
    predictions: [
        {
            day: 1,
            date: 2026-04-14,
            high_temp_c: 29.4,
            low_temp_c: 20.8,
            conditions: Light Rain,
            rain_probability_pct: 55.3,
            confidence_pct: 87.4
        },
        {
            day: 2,
            date: 2026-04-15,
            high_temp_c: 30.1,
            low_temp_c: 21.2,
            conditions: Cloudy,
            rain_probability_pct: 48.7,
            confidence_pct: 78.2
        },
        {
            day: 3,
            date: 2026-04-16,
            high_temp_c: 31.5,
            low_temp_c: 22.0,
            conditions: Partly Cloudy,
            rain_probability_pct: 35.1,
            confidence_pct: 68.9
        },
        {
            day: 4,
            date: 2026-04-17,
            high_temp_c: 32.8,
            low_temp_c: 22.5,
            conditions: Partly Cloudy,
            rain_probability_pct: 28.4,
            confidence_pct: 59.1
        },
        {
            day: 5,
            date: 2026-04-18,
            high_temp_c: 34.2,
            low_temp_c: 23.0,
            conditions: Clear,
            rain_probability_pct: 15.6,
            confidence_pct: 51.3
        },
        {
            day: 6,
            date: 2026-04-19,
            high_temp_c: 36.0,
            low_temp_c: 19.5,
            conditions: Cloudy,
            rain_probability_pct: 40.2,
            confidence_pct: 45.8
        },
        {
            day: 7,
            date: 2026-04-20,
            high_temp_c: 40.2,
            low_temp_c: 16.9,
            conditions: Cloudy,
            rain_probability_pct: 42.0,
            confidence_pct: 42.5
        }
    ]
}
`

### Key Observations About Predictions

1. **Confidence drops over time**: Day 1 prediction has ~85-87% confidence, but by Day 7
   it drops to ~40%. This mirrors real weather forecasting -- the further out you predict,
   the less certain you can be.

2. **Temperature range widens**: The gap between high and low temperature grows for later
   days, reflecting increasing uncertainty.

3. **Based on recent data**: The `based_on_readings` field tells you how many raw readings
   were used to generate the forecast. More readings = potentially better forecast.

### Real-Life Analogy

Think of the **7-day forecast you see on a weather app**. The app looks at recent weather
patterns, considers trends (is it getting hotter or cooler?), and makes predictions for
each of the next 7 days. Notice how the forecast for tomorrow is usually accurate, but
the forecast for next week is often wrong? That is exactly what the `confidence_pct`
field represents -- the app knows its own limitations.

---

## Topic 3: weather-alerts

### What It Stores

This topic receives **weather warning messages** whenever a reading crosses a dangerous
threshold. Alerts are generated by checking each raw reading against a set of rules.
Not every reading produces an alert -- only readings with unusual or dangerous values do.

- **Partitions**: 2 (fewer partitions because alerts are less frequent than raw data)
- **Replication Factor**: 2
- **Message Key**: City name
- **Frequency**: Variable -- depends on weather conditions. Some batches produce 0 alerts,
  others produce 5-10 alerts across cities.

### Alert Rules

These are the conditions that trigger an alert:

| Rule | Condition | Threshold | Severity | When It Triggers |
|------|-----------|-----------|----------|-----------------|
| Heat Warning | temperature > 33 C | 33 C | HIGH | Hot summer afternoons, heat waves |
| Cold Warning | temperature < 22 C | 22 C | HIGH | Cool winter mornings, hill stations |
| High Wind | wind_speed > 18 km/h | 18 km/h | HIGH | Storms, coastal winds |
| Low Visibility | visibility < 8 km | 8 km | MEDIUM | Fog, heavy rain, smog |
| High Humidity | humidity > 75% | 75% | LOW | Monsoon season, coastal cities |
| Rain Likely | rain_probability > 40% | 40% | MEDIUM | Approaching rain, monsoon |

### Severity Levels

| Severity | Meaning | Action Needed |
|----------|---------|---------------|
| **HIGH** | Dangerous conditions | Immediate action -- stay indoors, evacuate, etc. |
| **MEDIUM** | Notable conditions | Be cautious -- carry umbrella, drive carefully |
| **LOW** | Advisory | Be aware -- may affect comfort or plans |

### What Each Field Means

| Field | Type | Description |
|-------|------|-------------|
| lert_id | string | Unique identifier for this alert (UUID) |
| city | string | City where the alert was triggered |
| 	imestamp | string | When the alert was generated |
| severity | string | HIGH, MEDIUM, or LOW |
| ield | string | Which measurement triggered the alert |
| condition | string | The comparison used (gt = greater than, lt = less than) |
| 	hreshold | float | The threshold value that was exceeded |
| ctual_value | float | The actual reading that triggered the alert |
| message | string | Human-readable description of the alert |
| eading | object | The full weather reading that caused the alert |

### Sample JSON Messages

**HIGH severity -- Cold Warning:**

`json
{
    alert_id: a1b2c3d4-e5f6-7890-abcd-ef1234567890,
    city: Bangalore,
    timestamp: 2026-04-13T20:20:38.789012,
    severity: HIGH,
    field: temperature_c,
    condition: lt,
    threshold: 22,
    actual_value: 21.5,
    message: Cold warning! Temperature below 22 C -- Bangalore: 21.5,
    reading: {
        city: Bangalore,
        timestamp: 2026-04-13T20:20:38.789012,
        temperature_c: 21.5,
        humidity_pct: 62.7,
        wind_speed_kmh: 5.1,
        pressure_hpa: 1015.2,
        cloud_cover_pct: 52.3,
        uv_index: 0.8,
        visibility_km: 5.8,
        rain_probability_pct: 31.0,
        conditions: Partly Cloudy
    }
}
`

**MEDIUM severity -- Rain Alert:**

`json
{
    alert_id: f9e8d7c6-b5a4-3210-fedc-ba9876543210,
    city: Mumbai,
    timestamp: 2026-04-13T20:20:38.456789,
    severity: MEDIUM,
    field: rain_probability_pct,
    condition: gt,
    threshold: 40,
    actual_value: 46.2,
    message: Rain likely! Rain probability above 40% -- Mumbai: 46.2,
    reading: {
        city: Mumbai,
        timestamp: 2026-04-13T20:20:38.456789,
        temperature_c: 29.4,
        humidity_pct: 73.6,
        wind_speed_kmh: 8.0,
        pressure_hpa: 1009.7,
        cloud_cover_pct: 68.1,
        uv_index: 1.2,
        visibility_km: 6.8,
        rain_probability_pct: 46.2,
        conditions: Light Rain
    }
}
`

**LOW severity -- Humidity Alert:**

`json
{
    alert_id: 12345678-abcd-ef01-2345-678901234567,
    city: Chennai,
    timestamp: 2026-04-13T20:20:41.234567,
    severity: LOW,
    field: humidity_pct,
    condition: gt,
    threshold: 75,
    actual_value: 79.6,
    message: High humidity alert! Humidity above 75% -- Chennai: 79.6,
    reading: {
        city: Chennai,
        timestamp: 2026-04-13T20:20:41.234567,
        temperature_c: 28.5,
        humidity_pct: 79.6,
        wind_speed_kmh: 11.5,
        pressure_hpa: 1010.5,
        cloud_cover_pct: 72.4,
        uv_index: 0.9,
        visibility_km: 5.2,
        rain_probability_pct: 36.8,
        conditions: Cloudy
    }
}
`

### Real-Life Analogy

Think of **emergency weather alerts on your phone**. You do not get an alert every time
the temperature changes -- only when something unusual or dangerous happens:

- Your phone buzzes with a **red alert** when a heat wave is expected (HIGH severity)
- You get a **yellow notification** when heavy rain is approaching (MEDIUM severity)
- A **blue info message** tells you humidity is high today (LOW severity)

The `weather-alerts` topic works the same way. It stays quiet during normal weather,
but speaks up when conditions become concerning.

---

## How Data Flows Between Topics

`
                    weather_producer.py
                          |
            +-------------+-------------+
            |             |             |
            v             v             v
   [weather-raw-data] [weather-predictions] [weather-alerts]
            |             |             |
     Every reading    Every 5th      Only when
     from every city  batch (15s)    thresholds
     (6 msgs / 3s)   (6 forecasts)  are crossed
`

### Flow Summary

1. **Step 1**: The producer generates a weather reading for each city (6 readings per batch)
2. **Step 2**: Each reading is sent to `weather-raw-data`
3. **Step 3**: Each reading is checked against alert rules. If any rule triggers, an alert
   message is sent to `weather-alerts`
4. **Step 4**: Every 5th batch, the producer uses the accumulated raw readings to generate
   a 7-day forecast for each city and sends it to `weather-predictions`

### Data Volume Comparison

| Topic | Messages Per Batch | Messages Per Minute | Data Size Per Message |
|-------|-------------------|--------------------|-----------------------|
| weather-raw-data | 6 (always) | ~120 | ~300 bytes |
| weather-predictions | 6 (every 5th batch) | ~24 | ~1.5 KB |
| weather-alerts | 0-12 (variable) | ~40-80 | ~500 bytes |

---

## Why 3 Separate Topics?

Having 3 topics instead of 1 provides several benefits:

1. **Different consumers need different data**: A dashboard showing live readings subscribes
   only to `weather-raw-data`. An alerting system subscribes only to `weather-alerts`.
   Neither needs to filter through irrelevant messages.

2. **Different retention needs**: Raw data might be kept for 7 days, predictions for 30 days,
   and alerts for 90 days. Separate topics allow separate retention policies.

3. **Different processing speeds**: Raw data arrives fast (every 3 seconds) and consumers
   need to keep up. Alerts arrive infrequently and can be processed at leisure. Separate
   topics prevent slow alert processing from blocking fast raw data processing.

4. **Independent scaling**: If raw data volume increases (more cities), you can add more
   partitions to `weather-raw-data` without affecting the alert topic.

---

## Partition Strategy

| Topic | Partitions | Why This Number |
|-------|-----------|-----------------|
| weather-raw-data | 3 | High throughput -- 6 cities distributed across 3 partitions |
| weather-predictions | 3 | Matches raw data partitioning for consistency |
| weather-alerts | 2 | Lower volume -- fewer partitions are sufficient |

All topics use the **city name as the message key**. Kafka hashes the key to determine
which partition receives the message. This guarantees:

- All messages for Hyderabad always go to the same partition
- Messages within a partition are strictly ordered by time
- A consumer reading one partition gets a complete, ordered history for specific cities
