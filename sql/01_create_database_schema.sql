-- ============================================
-- Step 1: Create Database and Schema
-- ============================================
-- Creates a dedicated database and schema for the weather pipeline.
-- IF NOT EXISTS ensures this is safe to re-run.

CREATE DATABASE IF NOT EXISTS WEATHER_PIPELINE;

CREATE SCHEMA IF NOT EXISTS WEATHER_PIPELINE.KAFKA_DATA;

-- Verify
SHOW SCHEMAS IN DATABASE WEATHER_PIPELINE;
