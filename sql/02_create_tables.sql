-- ============================================
-- Step 2: Create Target Tables
-- ============================================
-- One table per Kafka topic. Uses schematized approach
-- (individual columns) for query performance.

USE DATABASE WEATHER_PIPELINE;
USE SCHEMA KAFKA_DATA;

-- Table 1: WEATHER_RAW_DATA (from weather-raw-data topic)
-- ~120 rows/minute (6 cities x 20 batches/min)
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

-- Table 2: WEATHER_PREDICTIONS (from weather-predictions topic)
-- ~24 rows/minute (6 cities every 5th batch)
CREATE OR REPLACE TABLE WEATHER_PREDICTIONS (
    RECORD_METADATA         VARIANT,
    CITY                    VARCHAR(50),
    GENERATED_AT            TIMESTAMP_NTZ,
    FORECAST_DAYS           INT,
    BASED_ON_READINGS       INT,
    PREDICTIONS             VARIANT
);

-- Table 3: WEATHER_ALERTS (from weather-alerts topic)
-- Variable volume (~40-80 rows/minute)
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
