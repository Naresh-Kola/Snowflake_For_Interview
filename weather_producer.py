"""
Weather Data Producer & Predictor for Kafka
---------------------------------------------
1. Generates realistic synthetic weather data for Indian cities
2. Publishes raw readings to 'weather-raw-data' topic
3. Computes 7-day forecasts and publishes to 'weather-predictions' topic
4. Detects severe conditions and publishes to 'weather-alerts' topic

Usage:
    python weather_producer.py
    Press Ctrl+C to stop.
"""

import json
import math
import random
import time
from collections import defaultdict
from datetime import datetime, timedelta
from kafka import KafkaProducer

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
BOOTSTRAP_SERVERS = "localhost:9092,localhost:9094"
RAW_TOPIC = "weather-raw-data"
PREDICTION_TOPIC = "weather-predictions"
ALERT_TOPIC = "weather-alerts"
PRODUCE_INTERVAL_SECONDS = 3  # seconds between each city batch

# ---------------------------------------------------------------------------
# City baseline profiles (approximate real-world annual averages)
# ---------------------------------------------------------------------------
CITY_PROFILES = {
    "Hyderabad": {
        "base_temp": 30, "temp_range": 10, "base_humidity": 55,
        "base_wind": 12, "base_pressure": 1012, "lat": 17.4,
    },
    "Mumbai": {
        "base_temp": 29, "temp_range": 6, "base_humidity": 72,
        "base_wind": 14, "base_pressure": 1010, "lat": 19.1,
    },
    "Delhi": {
        "base_temp": 28, "temp_range": 18, "base_humidity": 50,
        "base_wind": 10, "base_pressure": 1014, "lat": 28.6,
    },
    "Bangalore": {
        "base_temp": 25, "temp_range": 7, "base_humidity": 60,
        "base_wind": 11, "base_pressure": 1013, "lat": 12.9,
    },
    "Chennai": {
        "base_temp": 31, "temp_range": 7, "base_humidity": 68,
        "base_wind": 13, "base_pressure": 1011, "lat": 13.1,
    },
    "Kolkata": {
        "base_temp": 29, "temp_range": 12, "base_humidity": 65,
        "base_wind": 9, "base_pressure": 1012, "lat": 22.6,
    },
}

WIND_DIRECTIONS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

# History buffer: stores recent readings for prediction
city_history = defaultdict(list)
MAX_HISTORY = 20  # keep last 20 readings per city

# ---------------------------------------------------------------------------
# Helper: realistic weather generation
# ---------------------------------------------------------------------------

def get_seasonal_factor(day_of_year):
    """Returns a value between -1 and 1 based on time of year.
    Peak summer ~ day 150 (end of May), peak winter ~ day 350 (mid-Dec)."""
    return math.sin(2 * math.pi * (day_of_year - 80) / 365)


def get_time_of_day_factor(hour):
    """Returns a value between -1 and 1. Coldest at 4am, hottest at 2pm."""
    return math.sin(2 * math.pi * (hour - 4) / 24)


def generate_weather_reading(city, profile, timestamp):
    """Generate a single realistic weather reading for a city."""
    now = timestamp
    day_of_year = now.timetuple().tm_yday
    hour = now.hour

    seasonal = get_seasonal_factor(day_of_year)
    time_of_day = get_time_of_day_factor(hour)

    # Temperature: base + seasonal swing + daily swing + noise
    temp = (
        profile["base_temp"]
        + seasonal * (profile["temp_range"] / 2)
        + time_of_day * 4
        + random.gauss(0, 1.5)
    )

    # Humidity: inversely related to temperature + noise
    humidity = max(10, min(100,
        profile["base_humidity"]
        - (temp - profile["base_temp"]) * 1.2
        + random.gauss(0, 5)
    ))

    # Wind speed: base + noise, slightly higher in afternoon
    wind_speed = max(0,
        profile["base_wind"]
        + time_of_day * 3
        + random.gauss(0, 3)
    )

    # Pressure: base + small seasonal variation + noise
    pressure = (
        profile["base_pressure"]
        + seasonal * 3
        + random.gauss(0, 2)
    )

    # Cloud cover: correlated with humidity
    cloud_cover = max(0, min(100,
        humidity * 0.8 + random.gauss(0, 15)
    ))

    # UV index: high during midday, low at night
    uv_base = max(0, 6 + time_of_day * 5 - cloud_cover * 0.05)
    uv_index = round(max(0, min(11, uv_base + random.gauss(0, 0.5))), 1)

    # Visibility: reduced by humidity and cloud cover
    visibility = max(0.5, min(20,
        15 - humidity * 0.08 - cloud_cover * 0.04 + random.gauss(0, 1)
    ))

    # Rain probability: based on humidity and cloud cover
    rain_probability = max(0, min(100,
        (humidity - 50) * 1.2 + (cloud_cover - 40) * 0.5 + random.gauss(0, 5)
    ))

    reading = {
        "city": city,
        "timestamp": now.isoformat(),
        "temperature_c": round(temp, 1),
        "humidity_pct": round(humidity, 1),
        "wind_speed_kmh": round(wind_speed, 1),
        "wind_direction": random.choice(WIND_DIRECTIONS),
        "pressure_hpa": round(pressure, 1),
        "cloud_cover_pct": round(cloud_cover, 1),
        "uv_index": uv_index,
        "visibility_km": round(visibility, 1),
        "rain_probability_pct": round(rain_probability, 1),
    }
    return reading


# ---------------------------------------------------------------------------
# Prediction: 7-day forecast from recent readings
# ---------------------------------------------------------------------------

def generate_7day_prediction(city, history):
    """Generate a 7-day forecast based on recent readings for a city.
    Uses weighted moving average of recent data + daily drift + randomness."""
    if len(history) < 3:
        return None  # need at least 3 readings

    # Weighted average: recent readings matter more
    weights = list(range(1, len(history) + 1))
    total_w = sum(weights)

    avg_temp = sum(r["temperature_c"] * w for r, w in zip(history, weights)) / total_w
    avg_humidity = sum(r["humidity_pct"] * w for r, w in zip(history, weights)) / total_w
    avg_wind = sum(r["wind_speed_kmh"] * w for r, w in zip(history, weights)) / total_w
    avg_pressure = sum(r["pressure_hpa"] * w for r, w in zip(history, weights)) / total_w
    avg_cloud = sum(r["cloud_cover_pct"] * w for r, w in zip(history, weights)) / total_w
    avg_rain = sum(r["rain_probability_pct"] * w for r, w in zip(history, weights)) / total_w

    # Detect trend from last few readings
    recent_temps = [r["temperature_c"] for r in history[-5:]]
    if len(recent_temps) >= 2:
        temp_trend = (recent_temps[-1] - recent_temps[0]) / len(recent_temps)
    else:
        temp_trend = 0

    now = datetime.now()
    predictions = []

    for day_offset in range(1, 8):
        future_date = now + timedelta(days=day_offset)
        day_of_year = future_date.timetuple().tm_yday
        seasonal = get_seasonal_factor(day_of_year)

        # Each day drifts further from current, adding uncertainty
        drift = day_offset * temp_trend * 0.5
        uncertainty = day_offset * 0.8

        pred_temp_high = round(avg_temp + drift + 4 + random.gauss(0, uncertainty), 1)
        pred_temp_low = round(avg_temp + drift - 4 + random.gauss(0, uncertainty), 1)
        pred_humidity = round(max(10, min(100, avg_humidity + random.gauss(0, 3 * day_offset))), 1)
        pred_wind = round(max(0, avg_wind + random.gauss(0, 2 * day_offset)), 1)
        pred_rain = round(max(0, min(100, avg_rain + random.gauss(0, 5 * day_offset))), 1)

        # Determine condition label
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

        predictions.append({
            "date": future_date.strftime("%Y-%m-%d"),
            "day_name": future_date.strftime("%A"),
            "temp_high_c": pred_temp_high,
            "temp_low_c": pred_temp_low,
            "humidity_pct": pred_humidity,
            "wind_speed_kmh": pred_wind,
            "rain_probability_pct": pred_rain,
            "condition": condition,
            "confidence_pct": round(max(30, 95 - day_offset * 8 + random.gauss(0, 2)), 1),
        })

    forecast = {
        "city": city,
        "generated_at": now.isoformat(),
        "forecast_days": 7,
        "based_on_readings": len(history),
        "predictions": predictions,
    }
    return forecast


# ---------------------------------------------------------------------------
# Alert detection
# ---------------------------------------------------------------------------

ALERT_RULES = [
    {
        "field": "temperature_c",
        "condition": "gt",
        "threshold": 33,
        "severity": "HIGH",
        "message": "Heat warning! Temperature above 33 C",
    },
    {
        "field": "temperature_c",
        "condition": "lt",
        "threshold": 22,
        "severity": "HIGH",
        "message": "Cold warning! Temperature below 22 C",
    },
    {
        "field": "wind_speed_kmh",
        "condition": "gt",
        "threshold": 18,
        "severity": "HIGH",
        "message": "High wind alert! Wind speed above 18 km/h",
    },
    {
        "field": "visibility_km",
        "condition": "lt",
        "threshold": 8,
        "severity": "MEDIUM",
        "message": "Low visibility warning! Visibility below 8 km",
    },
    {
        "field": "humidity_pct",
        "condition": "gt",
        "threshold": 75,
        "severity": "LOW",
        "message": "High humidity alert! Humidity above 75%",
    },
    {
        "field": "rain_probability_pct",
        "condition": "gt",
        "threshold": 40,
        "severity": "MEDIUM",
        "message": "Rain likely! Rain probability above 40%",
    },
]


def check_alerts(reading):
    """Check a weather reading against alert rules. Returns a list of alerts."""
    alerts = []
    for rule in ALERT_RULES:
        value = reading.get(rule["field"], 0)
        triggered = False
        if rule["condition"] == "gt" and value > rule["threshold"]:
            triggered = True
        elif rule["condition"] == "lt" and value < rule["threshold"]:
            triggered = True

        if triggered:
            alerts.append({
                "city": reading["city"],
                "timestamp": reading["timestamp"],
                "severity": rule["severity"],
                "alert_type": rule["field"],
                "actual_value": value,
                "threshold": rule["threshold"],
                "message": f"{rule['message']} -- {reading['city']}: {value}",
            })
    return alerts


# ---------------------------------------------------------------------------
# Main producer loop
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("  WEATHER DATA PRODUCER")
    print("=" * 60)
    print(f"  Kafka Brokers : {BOOTSTRAP_SERVERS}")
    print(f"  Topics        : {RAW_TOPIC}, {PREDICTION_TOPIC}, {ALERT_TOPIC}")
    print(f"  Cities        : {', '.join(CITY_PROFILES.keys())}")
    print(f"  Interval      : {PRODUCE_INTERVAL_SECONDS}s between batches")
    print("=" * 60)
    print()

    producer = KafkaProducer(
        bootstrap_servers=BOOTSTRAP_SERVERS,
        value_serializer=lambda v: json.dumps(v, indent=2).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8") if k else None,
    )

    batch_count = 0

    try:
        while True:
            batch_count += 1
            now = datetime.now()
            print(f"--- Batch #{batch_count} at {now.strftime('%Y-%m-%d %H:%M:%S')} ---")

            for city, profile in CITY_PROFILES.items():
                # 1) Generate and send raw weather reading
                reading = generate_weather_reading(city, profile, now)
                producer.send(
                    RAW_TOPIC,
                    key=city,
                    value=reading,
                )
                print(f"  [RAW]   {city:<12} temp={reading['temperature_c']}C  "
                      f"humidity={reading['humidity_pct']}%  "
                      f"wind={reading['wind_speed_kmh']}km/h  "
                      f"rain={reading['rain_probability_pct']}%")

                # 2) Store in history for predictions
                city_history[city].append(reading)
                if len(city_history[city]) > MAX_HISTORY:
                    city_history[city] = city_history[city][-MAX_HISTORY:]

                # 3) Check for alerts
                alerts = check_alerts(reading)
                for alert in alerts:
                    producer.send(
                        ALERT_TOPIC,
                        key=city,
                        value=alert,
                    )
                    print(f"  [ALERT] {city:<12} [{alert['severity']}] {alert['message']}")

            # 4) Generate 7-day predictions every 5 batches
            if batch_count % 5 == 0:
                print()
                print("  Generating 7-day forecasts...")
                for city in CITY_PROFILES:
                    history = city_history.get(city, [])
                    forecast = generate_7day_prediction(city, history)
                    if forecast:
                        producer.send(
                            PREDICTION_TOPIC,
                            key=city,
                            value=forecast,
                        )
                        day1 = forecast["predictions"][0]
                        day7 = forecast["predictions"][6]
                        print(f"  [PRED]  {city:<12} "
                              f"Day1: {day1['temp_high_c']}/{day1['temp_low_c']}C {day1['condition']}  "
                              f"Day7: {day7['temp_high_c']}/{day7['temp_low_c']}C {day7['condition']}  "
                              f"confidence: {day1['confidence_pct']}%-{day7['confidence_pct']}%")

            producer.flush()
            print()
            time.sleep(PRODUCE_INTERVAL_SECONDS)

    except KeyboardInterrupt:
        print("\nShutting down producer...")
    finally:
        producer.close()
        print("Producer closed. Goodbye!")


if __name__ == "__main__":
    main()
