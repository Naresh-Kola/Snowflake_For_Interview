# Data Quality — Zero to Hero Complete Guide

> From fundamentals to production-level problem solving. Types of issues, detection methods, frameworks, and real-world solutions.

---

## 1. What is Data Quality?

Data quality measures how well data serves its intended purpose. High-quality data is accurate, complete, consistent, timely, and trustworthy for decision-making.

**The Cost of Bad Data:**
- Wrong business decisions based on incorrect dashboards
- Failed SLA deliveries due to missing/delayed data
- Compliance violations (GDPR, HIPAA, SOX)
- Customer churn from incorrect billing or recommendations
- Engineering time wasted debugging downstream failures

---

## 2. The 6 Dimensions of Data Quality

| Dimension | Definition | Example Issue |
|-----------|-----------|---------------|
| **Accuracy** | Data correctly represents real-world values | Customer age = 250, revenue = -$1M |
| **Completeness** | All required data is present | 30% of email addresses are NULL |
| **Consistency** | Same data doesn't conflict across systems | CRM says "Active", billing says "Cancelled" |
| **Timeliness** | Data arrives when expected | Daily pipeline delivers 6 hours late |
| **Uniqueness** | No unintended duplicates | Same order appears 3 times in fact table |
| **Validity** | Data conforms to business rules/formats | Phone number has 15 digits, date = "2023-13-45" |

### Additional Dimensions (Advanced)

| Dimension | Definition | Example Issue |
|-----------|-----------|---------------|
| **Integrity** | Referential relationships are maintained | FK points to non-existent parent record |
| **Conformity** | Data follows agreed formats/standards | Mix of "USA", "US", "United States" |
| **Relevance** | Data is useful for its intended purpose | Collecting fax numbers for a mobile app |
| **Accessibility** | Authorized users can access data when needed | Dashboard times out due to missing indexes |

---

## 3. Types of Data Quality Issues (Complete Taxonomy)

### 3.1 Schema-Level Issues

| Issue | Description | Impact |
|-------|-------------|--------|
| Missing columns | Expected column doesn't exist | Pipeline crashes |
| Wrong data types | String in integer column | Silent truncation or errors |
| Schema drift | Source adds/removes/renames columns | Downstream breakage |
| Encoding issues | UTF-8 vs Latin-1 mismatch | Garbled text, failed loads |
| Column order changes | Positional loads break | Wrong data in wrong columns |

### 3.2 Row-Level Issues

| Issue | Description | Impact |
|-------|-------------|--------|
| Duplicates | Same record appears multiple times | Inflated metrics |
| Missing rows | Expected records not loaded | Understated metrics |
| Orphan records | Child without parent (broken FK) | JOIN failures, NULLs |
| Late-arriving data | Records arrive after window closes | Incomplete aggregations |
| Out-of-order events | Event timestamp < previous event | Wrong state calculations |

### 3.3 Column-Level Issues

| Issue | Description | Impact |
|-------|-------------|--------|
| NULL values | Required field is empty | Failed calculations |
| Out-of-range values | Age = -5, price = 999999999 | Wrong aggregations |
| Format violations | Date as "DD/MM/YYYY" vs "YYYY-MM-DD" | Parse failures |
| Truncation | "New York City" → "New York C" | Data loss |
| Default value leakage | Placeholder "TBD", "N/A", "0" treated as real | Misleading reports |
| Stale values | Address not updated in 5 years | Wrong geographic analysis |

### 3.4 Cross-System / Consistency Issues

| Issue | Description | Impact |
|-------|-------------|--------|
| Source-target mismatch | Row count differs between systems | Data loss/duplication |
| Aggregation mismatch | SUM in source ≠ SUM in target | Finance reconciliation fails |
| Timing inconsistency | System A loads at 2AM, System B at 8AM | Mismatched snapshots |
| Business logic divergence | "Active customer" defined differently | Conflicting reports |
| Currency/timezone issues | USD vs INR not converted, UTC vs IST | Wrong revenue figures |

### 3.5 Pipeline / Operational Issues

| Issue | Description | Impact |
|-------|-------------|--------|
| Pipeline failure | ETL job crashes mid-run | Partial/no data |
| Silent failure | Job "succeeds" but loads 0 rows | Missing data undetected |
| Backfill corruption | Re-running pipeline creates duplicates | Inflated historical data |
| Dependency failure | Upstream table not ready when downstream runs | Stale joins |
| Resource exhaustion | OOM, timeout, warehouse suspend | Incomplete processing |

---

## 4. How to Detect Data Quality Issues in Production

### 4.1 Proactive Detection Methods

#### Row Count Monitoring
```sql
-- Compare today's count with historical average
WITH daily_counts AS (
    SELECT 
        DATE(loaded_at) AS load_date,
        COUNT(*) AS row_count
    FROM analytics.orders_fact
    GROUP BY 1
),
stats AS (
    SELECT 
        AVG(row_count) AS avg_count,
        STDDEV(row_count) AS stddev_count
    FROM daily_counts
    WHERE load_date >= CURRENT_DATE - 30
)
SELECT 
    dc.load_date,
    dc.row_count,
    s.avg_count,
    CASE 
        WHEN ABS(dc.row_count - s.avg_count) > 2 * s.stddev_count 
        THEN 'ANOMALY'
        ELSE 'NORMAL'
    END AS status
FROM daily_counts dc
CROSS JOIN stats s
WHERE dc.load_date = CURRENT_DATE;
```

#### Freshness Monitoring
```sql
-- Alert if data is older than expected
SELECT 
    table_name,
    MAX(loaded_at) AS last_load_time,
    DATEDIFF('hour', MAX(loaded_at), CURRENT_TIMESTAMP()) AS hours_since_load,
    CASE 
        WHEN DATEDIFF('hour', MAX(loaded_at), CURRENT_TIMESTAMP()) > 4 
        THEN 'STALE'
        ELSE 'FRESH'
    END AS freshness_status
FROM information_schema.tables t
JOIN analytics.pipeline_metadata pm ON t.table_name = pm.table_name
GROUP BY 1;
```

#### NULL Rate Monitoring
```sql
-- Track NULL percentage trends
SELECT 
    'email' AS column_name,
    COUNT(*) AS total_rows,
    COUNT(email) AS non_null_rows,
    ROUND(100.0 * (COUNT(*) - COUNT(email)) / COUNT(*), 2) AS null_pct,
    CASE 
        WHEN (COUNT(*) - COUNT(email))::FLOAT / COUNT(*) > 0.05 
        THEN 'ALERT'
        ELSE 'OK'
    END AS status
FROM customers_dim;
```

#### Duplicate Detection
```sql
-- Find duplicates by business key
SELECT 
    order_id,
    COUNT(*) AS occurrence_count
FROM orders_fact
GROUP BY order_id
HAVING COUNT(*) > 1
ORDER BY occurrence_count DESC;
```

#### Distribution Anomaly Detection
```sql
-- Detect unusual value distributions
WITH current_dist AS (
    SELECT 
        payment_method,
        COUNT(*) AS cnt,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) AS pct
    FROM orders_fact
    WHERE order_date = CURRENT_DATE
    GROUP BY 1
),
baseline_dist AS (
    SELECT 
        payment_method,
        ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER(), 2) AS baseline_pct
    FROM orders_fact
    WHERE order_date BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE - 1
    GROUP BY 1
)
SELECT 
    c.payment_method,
    c.pct AS today_pct,
    b.baseline_pct,
    ABS(c.pct - b.baseline_pct) AS drift
FROM current_dist c
JOIN baseline_dist b ON c.payment_method = b.payment_method
WHERE ABS(c.pct - b.baseline_pct) > 10;
```

### 4.2 Reactive Detection Methods

| Method | When Used | Example |
|--------|-----------|---------|
| User-reported issues | Dashboard shows wrong numbers | "Revenue dropped 90% yesterday" |
| Failed downstream jobs | Pipeline errors on bad data | INSERT fails on type mismatch |
| Reconciliation mismatches | Source vs target comparison | Finance team finds $1M difference |
| Alert fatigue analysis | Too many alerts = hidden real issues | Review suppressed alerts |
| Audit findings | Compliance team discovers gaps | SOX audit finds missing records |

---

## 5. Data Quality Frameworks — How to Build Them

### 5.1 Framework Types Overview

| Framework Type | Complexity | Best For | Tools |
|----------------|-----------|----------|-------|
| **SQL-based checks** | Low | Small teams, quick wins | Pure SQL + scheduler |
| **dbt tests** | Medium | dbt-centric pipelines | dbt test, dbt-expectations |
| **Great Expectations** | Medium-High | Python pipelines, complex rules | Python + GE library |
| **Snowflake DMFs** | Medium | Snowflake-native monitoring | Built-in DMF framework |
| **Monte Carlo / Soda** | High | Enterprise observability | SaaS platforms |
| **Custom framework** | High | Specific org requirements | Python/SQL + orchestrator |

---

### 5.2 Framework 1: Pure SQL Checks (Simplest)

```sql
-- Create a checks results table
CREATE TABLE IF NOT EXISTS data_quality.check_results (
    check_id VARCHAR,
    check_name VARCHAR,
    table_name VARCHAR,
    check_type VARCHAR,
    status VARCHAR,         -- PASS / FAIL / WARN
    metric_value NUMBER,
    threshold NUMBER,
    executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Check: Row count within bounds
INSERT INTO data_quality.check_results
SELECT 
    UUID_STRING() AS check_id,
    'orders_row_count' AS check_name,
    'orders_fact' AS table_name,
    'volume' AS check_type,
    CASE 
        WHEN COUNT(*) BETWEEN 10000 AND 500000 THEN 'PASS'
        ELSE 'FAIL'
    END AS status,
    COUNT(*) AS metric_value,
    10000 AS threshold,
    CURRENT_TIMESTAMP()
FROM orders_fact
WHERE order_date = CURRENT_DATE;

-- Check: No NULL in required field
INSERT INTO data_quality.check_results
SELECT 
    UUID_STRING(),
    'customer_email_not_null',
    'customers_dim',
    'completeness',
    CASE 
        WHEN SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END,
    SUM(CASE WHEN email IS NULL THEN 1 ELSE 0 END),
    0,
    CURRENT_TIMESTAMP()
FROM customers_dim
WHERE is_current = TRUE;

-- Check: Referential integrity
INSERT INTO data_quality.check_results
SELECT 
    UUID_STRING(),
    'orders_customer_fk_valid',
    'orders_fact',
    'integrity',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END,
    COUNT(*),
    0,
    CURRENT_TIMESTAMP()
FROM orders_fact o
LEFT JOIN customers_dim c ON o.customer_key = c.customer_key
WHERE c.customer_key IS NULL;

-- Check: No future dates
INSERT INTO data_quality.check_results
SELECT 
    UUID_STRING(),
    'orders_no_future_dates',
    'orders_fact',
    'validity',
    CASE 
        WHEN COUNT(*) = 0 THEN 'PASS'
        ELSE 'FAIL'
    END,
    COUNT(*),
    0,
    CURRENT_TIMESTAMP()
FROM orders_fact
WHERE order_date > CURRENT_DATE;
```

---

### 5.3 Framework 2: dbt Tests (Recommended for dbt projects)

#### Built-in Tests (schema.yml)
```yaml
version: 2

models:
  - name: orders_fact
    description: "Fact table containing all order transactions"
    columns:
      - name: order_id
        tests:
          - not_null
          - unique
      - name: customer_key
        tests:
          - not_null
          - relationships:
              to: ref('customers_dim')
              field: customer_key
      - name: order_amount
        tests:
          - not_null
          - dbt_expectations.expect_column_values_to_be_between:
              min_value: 0
              max_value: 1000000
      - name: order_date
        tests:
          - not_null
          - dbt_expectations.expect_column_values_to_be_between:
              min_value: "'2020-01-01'"
              max_value: "current_date"
      - name: payment_method
        tests:
          - accepted_values:
              values: ['credit_card', 'debit_card', 'upi', 'wallet', 'cod']

    tests:
      - dbt_expectations.expect_table_row_count_to_be_between:
          min_value: 1000
          max_value: 1000000
      - dbt_utils.unique_combination_of_columns:
          combination_of_columns:
            - order_id
            - line_item_id
```

#### Custom Generic Tests
```sql
-- tests/generic/test_no_duplicates_on_key.sql
{% test no_duplicates_on_key(model, column_name) %}

SELECT 
    {{ column_name }},
    COUNT(*) AS cnt
FROM {{ model }}
GROUP BY {{ column_name }}
HAVING COUNT(*) > 1

{% endtest %}
```

#### Custom Singular Tests
```sql
-- tests/singular/test_revenue_reconciliation.sql
-- Fails if source and target revenue differ by more than $100

WITH source_total AS (
    SELECT SUM(amount) AS total FROM {{ source('payments', 'transactions') }}
    WHERE transaction_date = CURRENT_DATE - 1
),
target_total AS (
    SELECT SUM(revenue_amount) AS total FROM {{ ref('orders_fact') }}
    WHERE order_date = CURRENT_DATE - 1
)
SELECT *
FROM source_total s, target_total t
WHERE ABS(s.total - t.total) > 100
```

#### dbt-expectations Package (Advanced)
```yaml
# packages.yml
packages:
  - package: calogica/dbt_expectations
    version: [">=0.8.0", "<0.9.0"]
```

```yaml
# Common dbt_expectations tests
models:
  - name: orders_fact
    tests:
      # Row count doesn't drop more than 10% from yesterday
      - dbt_expectations.expect_table_row_count_to_equal_other_table_times_factor:
          compare_model: ref("orders_fact_yesterday")
          factor: 0.9

      # Column value distribution hasn't shifted
      - dbt_expectations.expect_column_distinct_count_to_be_between:
          column_name: status
          min_value: 3
          max_value: 8

      # Freshness check
      - dbt_expectations.expect_row_values_to_have_recent_data:
          column_name: loaded_at
          datepart: hour
          interval: 6
```

---

### 5.4 Framework 3: Snowflake Data Metric Functions (DMFs)

```sql
-- Create custom DMF for NULL rate
CREATE OR REPLACE DATA METRIC FUNCTION 
    data_quality.null_rate(arg_t TABLE(arg_c VARCHAR))
RETURNS NUMBER
AS
$$
    SELECT 
        ROUND(100.0 * SUM(CASE WHEN arg_c IS NULL THEN 1 ELSE 0 END) / COUNT(*), 2)
    FROM arg_t
$$;

-- Create DMF for duplicate rate
CREATE OR REPLACE DATA METRIC FUNCTION 
    data_quality.duplicate_rate(arg_t TABLE(arg_c VARCHAR))
RETURNS NUMBER
AS
$$
    SELECT 
        ROUND(100.0 * (COUNT(*) - COUNT(DISTINCT arg_c)) / NULLIF(COUNT(*), 0), 2)
    FROM arg_t
$$;

-- Create DMF for freshness (hours since last update)
CREATE OR REPLACE DATA METRIC FUNCTION 
    data_quality.freshness_hours(arg_t TABLE(arg_c TIMESTAMP_NTZ))
RETURNS NUMBER
AS
$$
    SELECT DATEDIFF('hour', MAX(arg_c), CURRENT_TIMESTAMP())
    FROM arg_t
$$;

-- Attach DMFs to tables
ALTER TABLE analytics.orders_fact SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

ALTER TABLE analytics.orders_fact 
    ADD DATA METRIC FUNCTION data_quality.null_rate ON (customer_key);

ALTER TABLE analytics.orders_fact 
    ADD DATA METRIC FUNCTION data_quality.duplicate_rate ON (order_id);

ALTER TABLE analytics.orders_fact 
    ADD DATA METRIC FUNCTION data_quality.freshness_hours ON (loaded_at);

-- Query DMF results
SELECT *
FROM SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS
WHERE TABLE_NAME = 'ORDERS_FACT'
ORDER BY MEASUREMENT_TIME DESC;
```

---

### 5.5 Framework 4: Great Expectations (Python)

```python
import great_expectations as gx

# Initialize context
context = gx.get_context()

# Connect to Snowflake
datasource = context.sources.add_snowflake(
    name="snowflake_prod",
    connection_string="snowflake://user:pass@account/database/schema?warehouse=WH"
)

# Define expectations suite
suite = context.add_expectation_suite("orders_quality_suite")

# Add expectations
suite.add_expectation(
    gx.expectations.ExpectTableRowCountToBeBetween(min_value=10000, max_value=500000)
)
suite.add_expectation(
    gx.expectations.ExpectColumnValuesToNotBeNull(column="order_id")
)
suite.add_expectation(
    gx.expectations.ExpectColumnValuesToBeUnique(column="order_id")
)
suite.add_expectation(
    gx.expectations.ExpectColumnValuesToBeBetween(
        column="order_amount", min_value=0, max_value=1000000
    )
)
suite.add_expectation(
    gx.expectations.ExpectColumnValuesToBeInSet(
        column="status", 
        value_set=["pending", "shipped", "delivered", "cancelled", "returned"]
    )
)

# Run validation
checkpoint = context.add_checkpoint(name="orders_checkpoint")
result = checkpoint.run()

# Result contains pass/fail per expectation with observed values
print(result.success)  # True/False
```

---

### 5.6 Framework 5: Custom Production Framework (Enterprise)

```
┌─────────────────────────────────────────────────────────────┐
│                 DATA QUALITY FRAMEWORK                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌───────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │ Rule      │    │ Execution    │    │ Alerting &       │  │
│  │ Registry  │───▶│ Engine       │───▶│ Reporting        │  │
│  └───────────┘    └──────────────┘    └──────────────────┘  │
│       │                  │                     │             │
│       ▼                  ▼                     ▼             │
│  ┌───────────┐    ┌──────────────┐    ┌──────────────────┐  │
│  │ Metadata  │    │ Results      │    │ Slack/PagerDuty  │  │
│  │ Store     │    │ Store        │    │ Dashboard        │  │
│  └───────────┘    └──────────────┘    └──────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

#### Rule Registry Table
```sql
CREATE TABLE data_quality.dq_rules (
    rule_id VARCHAR PRIMARY KEY,
    rule_name VARCHAR NOT NULL,
    rule_type VARCHAR NOT NULL,          -- completeness, accuracy, validity, etc.
    target_database VARCHAR,
    target_schema VARCHAR,
    target_table VARCHAR NOT NULL,
    target_column VARCHAR,
    check_sql TEXT NOT NULL,
    severity VARCHAR DEFAULT 'HIGH',     -- CRITICAL, HIGH, MEDIUM, LOW
    threshold_operator VARCHAR,          -- =, >, <, >=, <=, BETWEEN
    threshold_value NUMBER,
    threshold_upper NUMBER,
    is_active BOOLEAN DEFAULT TRUE,
    owner VARCHAR,
    schedule VARCHAR DEFAULT 'DAILY',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Insert rules
INSERT INTO data_quality.dq_rules VALUES
('R001', 'orders_not_null_order_id', 'completeness', 'ANALYTICS', 'PUBLIC', 'orders_fact', 'order_id',
 'SELECT COUNT(*) FROM analytics.public.orders_fact WHERE order_id IS NULL', 
 'CRITICAL', '=', 0, NULL, TRUE, 'data_engineering', 'HOURLY', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),

('R002', 'orders_no_duplicates', 'uniqueness', 'ANALYTICS', 'PUBLIC', 'orders_fact', 'order_id',
 'SELECT COUNT(*) - COUNT(DISTINCT order_id) FROM analytics.public.orders_fact WHERE order_date = CURRENT_DATE',
 'CRITICAL', '=', 0, NULL, TRUE, 'data_engineering', 'HOURLY', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),

('R003', 'orders_row_count_bounds', 'volume', 'ANALYTICS', 'PUBLIC', 'orders_fact', NULL,
 'SELECT COUNT(*) FROM analytics.public.orders_fact WHERE order_date = CURRENT_DATE',
 'HIGH', 'BETWEEN', 5000, 500000, TRUE, 'data_engineering', 'DAILY', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),

('R004', 'orders_amount_range', 'validity', 'ANALYTICS', 'PUBLIC', 'orders_fact', 'order_amount',
 'SELECT COUNT(*) FROM analytics.public.orders_fact WHERE order_amount < 0 OR order_amount > 1000000',
 'HIGH', '=', 0, NULL, TRUE, 'data_engineering', 'DAILY', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()),

('R005', 'orders_freshness', 'timeliness', 'ANALYTICS', 'PUBLIC', 'orders_fact', 'loaded_at',
 'SELECT DATEDIFF(hour, MAX(loaded_at), CURRENT_TIMESTAMP()) FROM analytics.public.orders_fact',
 'CRITICAL', '<=', 4, NULL, TRUE, 'data_engineering', 'HOURLY', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
```

#### Execution Engine (Stored Procedure)
```sql
CREATE OR REPLACE PROCEDURE data_quality.run_dq_checks(p_schedule VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_rule_id VARCHAR;
    v_check_sql VARCHAR;
    v_threshold_op VARCHAR;
    v_threshold_val NUMBER;
    v_threshold_upper NUMBER;
    v_severity VARCHAR;
    v_result NUMBER;
    v_status VARCHAR;
    v_total_checks NUMBER DEFAULT 0;
    v_failed_checks NUMBER DEFAULT 0;
    
    cur CURSOR FOR 
        SELECT rule_id, check_sql, threshold_operator, threshold_value, threshold_upper, severity
        FROM data_quality.dq_rules
        WHERE is_active = TRUE AND schedule = :p_schedule;
BEGIN
    FOR rec IN cur DO
        v_rule_id := rec.rule_id;
        v_check_sql := rec.check_sql;
        v_threshold_op := rec.threshold_operator;
        v_threshold_val := rec.threshold_value;
        v_threshold_upper := rec.threshold_upper;
        v_severity := rec.severity;
        v_total_checks := v_total_checks + 1;
        
        -- Execute the check SQL
        EXECUTE IMMEDIATE 'SELECT (' || v_check_sql || ')' INTO v_result;
        
        -- Evaluate threshold
        CASE v_threshold_op
            WHEN '=' THEN v_status := IFF(v_result = v_threshold_val, 'PASS', 'FAIL');
            WHEN '>' THEN v_status := IFF(v_result > v_threshold_val, 'PASS', 'FAIL');
            WHEN '<' THEN v_status := IFF(v_result < v_threshold_val, 'PASS', 'FAIL');
            WHEN '>=' THEN v_status := IFF(v_result >= v_threshold_val, 'PASS', 'FAIL');
            WHEN '<=' THEN v_status := IFF(v_result <= v_threshold_val, 'PASS', 'FAIL');
            WHEN 'BETWEEN' THEN v_status := IFF(v_result BETWEEN v_threshold_val AND v_threshold_upper, 'PASS', 'FAIL');
            ELSE v_status := 'ERROR';
        END CASE;
        
        IF (v_status = 'FAIL') THEN
            v_failed_checks := v_failed_checks + 1;
        END IF;
        
        -- Store result
        INSERT INTO data_quality.dq_results (
            result_id, rule_id, metric_value, status, severity, executed_at
        ) VALUES (
            UUID_STRING(), v_rule_id, v_result, v_status, v_severity, CURRENT_TIMESTAMP()
        );
    END FOR;
    
    RETURN v_total_checks || ' checks executed. ' || v_failed_checks || ' failed.';
END;
$$;

-- Schedule with Snowflake Task
CREATE OR REPLACE TASK data_quality.hourly_dq_task
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 * * * * UTC'
AS
    CALL data_quality.run_dq_checks('HOURLY');

CREATE OR REPLACE TASK data_quality.daily_dq_task
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 6 * * * UTC'
AS
    CALL data_quality.run_dq_checks('DAILY');
```

#### Alerting Integration
```sql
-- Create alert for critical failures
CREATE OR REPLACE ALERT data_quality.critical_failure_alert
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON */15 * * * * UTC'
    IF (EXISTS (
        SELECT 1 
        FROM data_quality.dq_results 
        WHERE status = 'FAIL' 
          AND severity = 'CRITICAL'
          AND executed_at > DATEADD('minute', -15, CURRENT_TIMESTAMP())
          AND alerted = FALSE
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'dq_email_integration',
            'data-team@company.com',
            'CRITICAL: Data Quality Check Failed',
            (SELECT LISTAGG(rule_id || ': metric=' || metric_value, '\n') 
             FROM data_quality.dq_results 
             WHERE status = 'FAIL' AND severity = 'CRITICAL'
               AND executed_at > DATEADD('minute', -15, CURRENT_TIMESTAMP()))
        );
```

---

## 6. Solving Data Quality Issues — Production Playbook

### 6.1 Issue: Duplicates in Fact Table

**Root Causes:**
- Pipeline re-runs without idempotency
- Multiple sources loading same data
- Missing deduplication logic
- Late-arriving data processed twice

**Solutions:**

```sql
-- Solution 1: MERGE for idempotent loads
MERGE INTO orders_fact AS target
USING staging.orders_raw AS source
ON target.order_id = source.order_id 
   AND target.line_item_id = source.line_item_id
WHEN MATCHED THEN UPDATE SET
    order_amount = source.order_amount,
    updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT (
    order_id, line_item_id, customer_key, order_amount, order_date, loaded_at
) VALUES (
    source.order_id, source.line_item_id, source.customer_key, 
    source.order_amount, source.order_date, CURRENT_TIMESTAMP()
);

-- Solution 2: Deduplication with ROW_NUMBER
CREATE OR REPLACE TABLE orders_fact_clean AS
SELECT * FROM (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY order_id, line_item_id 
            ORDER BY loaded_at DESC
        ) AS rn
    FROM orders_fact
)
WHERE rn = 1;

-- Solution 3: Prevent at ingestion with DISTINCT
INSERT INTO orders_fact
SELECT DISTINCT 
    order_id, customer_key, product_key, 
    order_amount, order_date, CURRENT_TIMESTAMP()
FROM staging.orders_raw s
WHERE NOT EXISTS (
    SELECT 1 FROM orders_fact f 
    WHERE f.order_id = s.order_id
);
```

---

### 6.2 Issue: NULL Values in Critical Columns

**Root Causes:**
- Source system allows NULLs
- Schema evolution introduced new columns (NULL for old rows)
- Failed transformations producing NULLs
- Outer JOINs introducing NULLs

**Solutions:**

```sql
-- Solution 1: Default value substitution
CREATE OR REPLACE VIEW orders_fact_clean AS
SELECT 
    order_id,
    COALESCE(customer_key, -1) AS customer_key,          -- Unknown customer
    COALESCE(order_amount, 0) AS order_amount,           -- Zero if missing
    COALESCE(order_date, '1900-01-01') AS order_date,    -- Obvious invalid date
    COALESCE(status, 'UNKNOWN') AS status
FROM orders_fact;

-- Solution 2: Quarantine bad records
INSERT INTO data_quality.quarantine_table
SELECT *, 'NULL_CUSTOMER_KEY' AS rejection_reason, CURRENT_TIMESTAMP() AS quarantined_at
FROM staging.orders_raw
WHERE customer_key IS NULL;

-- Load only clean records
INSERT INTO orders_fact
SELECT * FROM staging.orders_raw
WHERE customer_key IS NOT NULL
  AND order_amount IS NOT NULL;

-- Solution 3: Fix at source with NOT NULL constraints
ALTER TABLE orders_fact MODIFY COLUMN order_id SET NOT NULL;
ALTER TABLE orders_fact MODIFY COLUMN customer_key SET NOT NULL;
```

---

### 6.3 Issue: Late-Arriving Data

**Root Causes:**
- Distributed systems with network delays
- Batch windows don't capture all records
- Timezone differences in source systems
- Source system retries after failures

**Solutions:**

```sql
-- Solution 1: Watermark-based processing
CREATE OR REPLACE TABLE pipeline_watermarks (
    table_name VARCHAR,
    last_processed_timestamp TIMESTAMP,
    updated_at TIMESTAMP
);

-- Process only new records since last watermark
INSERT INTO orders_fact
SELECT * FROM staging.orders_raw
WHERE event_timestamp > (
    SELECT last_processed_timestamp 
    FROM pipeline_watermarks 
    WHERE table_name = 'orders_fact'
);

-- Update watermark
UPDATE pipeline_watermarks 
SET last_processed_timestamp = (SELECT MAX(event_timestamp) FROM staging.orders_raw),
    updated_at = CURRENT_TIMESTAMP()
WHERE table_name = 'orders_fact';

-- Solution 2: Reprocess window (look-back)
-- Always reprocess last 3 days to catch late arrivals
MERGE INTO orders_fact AS target
USING (
    SELECT * FROM staging.orders_raw 
    WHERE order_date >= CURRENT_DATE - 3
) AS source
ON target.order_id = source.order_id
WHEN MATCHED THEN UPDATE SET
    order_amount = source.order_amount,
    status = source.status,
    updated_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT VALUES (
    source.order_id, source.customer_key, source.order_amount,
    source.order_date, source.status, CURRENT_TIMESTAMP()
);
```

---

### 6.4 Issue: Schema Drift

**Root Causes:**
- Source team adds/removes columns without notice
- API version changes
- Database migrations upstream

**Solutions:**

```sql
-- Solution 1: Schema change detection
CREATE OR REPLACE PROCEDURE detect_schema_changes()
RETURNS TABLE (change_type VARCHAR, column_name VARCHAR, details VARCHAR)
LANGUAGE SQL
AS
$$
DECLARE
    res RESULTSET;
BEGIN
    -- Compare current schema with expected
    res := (
        SELECT 
            CASE 
                WHEN e.column_name IS NULL THEN 'NEW_COLUMN'
                WHEN c.column_name IS NULL THEN 'DROPPED_COLUMN'
                WHEN e.data_type != c.data_type THEN 'TYPE_CHANGED'
                ELSE 'NO_CHANGE'
            END AS change_type,
            COALESCE(c.column_name, e.column_name) AS column_name,
            COALESCE(c.data_type, '') || ' -> ' || COALESCE(e.data_type, '') AS details
        FROM information_schema.columns c
        FULL OUTER JOIN data_quality.expected_schema e 
            ON c.column_name = e.column_name AND c.table_name = e.table_name
        WHERE c.table_name = 'ORDERS_RAW'
          AND (e.column_name IS NULL OR c.column_name IS NULL OR e.data_type != c.data_type)
    );
    RETURN TABLE(res);
END;
$$;

-- Solution 2: Use COPY with column mapping (resilient to order changes)
COPY INTO orders_staging (order_id, customer_id, amount, order_date)
FROM (
    SELECT $1:order_id, $1:customer_id, $1:amount, $1:order_date
    FROM @raw_stage/orders/
)
FILE_FORMAT = (TYPE = 'JSON');
```

---

### 6.5 Issue: Cross-System Inconsistency

**Root Causes:**
- Different ETL timing across systems
- Business logic defined differently per team
- Manual data entry errors
- Race conditions in concurrent writes

**Solutions:**

```sql
-- Solution 1: Reconciliation framework
CREATE OR REPLACE VIEW data_quality.reconciliation_report AS
WITH source_metrics AS (
    SELECT 
        'SOURCE_CRM' AS system_name,
        COUNT(*) AS row_count,
        COUNT(DISTINCT customer_id) AS unique_customers,
        SUM(revenue) AS total_revenue
    FROM source_crm.customers
    WHERE created_date = CURRENT_DATE - 1
),
target_metrics AS (
    SELECT 
        'TARGET_DWH' AS system_name,
        COUNT(*) AS row_count,
        COUNT(DISTINCT customer_id) AS unique_customers,
        SUM(revenue) AS total_revenue
    FROM analytics.customers_dim
    WHERE loaded_date = CURRENT_DATE - 1
)
SELECT 
    'row_count' AS metric,
    s.row_count AS source_value,
    t.row_count AS target_value,
    s.row_count - t.row_count AS difference,
    CASE WHEN s.row_count = t.row_count THEN 'MATCH' ELSE 'MISMATCH' END AS status
FROM source_metrics s, target_metrics t
UNION ALL
SELECT 
    'total_revenue',
    s.total_revenue,
    t.total_revenue,
    s.total_revenue - t.total_revenue,
    CASE WHEN ABS(s.total_revenue - t.total_revenue) < 0.01 THEN 'MATCH' ELSE 'MISMATCH' END
FROM source_metrics s, target_metrics t;

-- Solution 2: Golden record pattern (single source of truth)
CREATE OR REPLACE TABLE master_customer AS
SELECT 
    COALESCE(crm.customer_id, billing.customer_id) AS customer_id,
    crm.name AS name,                          -- CRM is authoritative for name
    billing.email AS email,                    -- Billing is authoritative for email
    crm.segment AS segment,
    billing.payment_status AS payment_status,
    GREATEST(crm.updated_at, billing.updated_at) AS last_updated
FROM crm_customers crm
FULL OUTER JOIN billing_customers billing 
    ON crm.customer_id = billing.customer_id;
```

---

## 7. Production Data Quality Architecture

### 7.1 Circuit Breaker Pattern

Stop bad data from propagating downstream:

```sql
-- Circuit breaker: halt pipeline if checks fail
CREATE OR REPLACE PROCEDURE pipeline.load_orders_with_circuit_breaker()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_null_count NUMBER;
    v_dup_count NUMBER;
    v_row_count NUMBER;
    v_avg_row_count NUMBER;
BEGIN
    -- Check 1: NULLs in critical columns
    SELECT COUNT(*) INTO v_null_count
    FROM staging.orders_raw
    WHERE order_id IS NULL OR customer_key IS NULL;
    
    IF (v_null_count > 0) THEN
        INSERT INTO data_quality.circuit_breaker_log VALUES (
            CURRENT_TIMESTAMP(), 'orders', 'NULL_CHECK', 'TRIPPED', v_null_count
        );
        RETURN 'CIRCUIT BREAKER TRIPPED: ' || v_null_count || ' NULL records found';
    END IF;
    
    -- Check 2: Duplicate rate
    SELECT COUNT(*) - COUNT(DISTINCT order_id) INTO v_dup_count
    FROM staging.orders_raw;
    
    IF (v_dup_count > 100) THEN
        INSERT INTO data_quality.circuit_breaker_log VALUES (
            CURRENT_TIMESTAMP(), 'orders', 'DUP_CHECK', 'TRIPPED', v_dup_count
        );
        RETURN 'CIRCUIT BREAKER TRIPPED: ' || v_dup_count || ' duplicates found';
    END IF;
    
    -- Check 3: Volume anomaly (>50% drop)
    SELECT COUNT(*) INTO v_row_count FROM staging.orders_raw;
    SELECT AVG(row_count) INTO v_avg_row_count 
    FROM pipeline.daily_row_counts 
    WHERE table_name = 'orders' AND load_date >= CURRENT_DATE - 7;
    
    IF (v_row_count < v_avg_row_count * 0.5) THEN
        INSERT INTO data_quality.circuit_breaker_log VALUES (
            CURRENT_TIMESTAMP(), 'orders', 'VOLUME_CHECK', 'TRIPPED', v_row_count
        );
        RETURN 'CIRCUIT BREAKER TRIPPED: Row count ' || v_row_count || ' is <50% of average ' || v_avg_row_count;
    END IF;
    
    -- All checks passed — proceed with load
    INSERT INTO analytics.orders_fact
    SELECT * FROM staging.orders_raw;
    
    RETURN 'SUCCESS: ' || v_row_count || ' rows loaded';
END;
$$;
```

### 7.2 Quarantine Pattern

Separate good data from bad, process good, investigate bad:

```sql
-- Quarantine architecture
CREATE SCHEMA IF NOT EXISTS data_quality;

CREATE TABLE data_quality.quarantine (
    quarantine_id VARCHAR DEFAULT UUID_STRING(),
    source_table VARCHAR,
    record_data VARIANT,            -- Original record as JSON
    rejection_reasons ARRAY,        -- Multiple reasons possible
    severity VARCHAR,
    quarantined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    resolved_at TIMESTAMP,
    resolved_by VARCHAR,
    resolution_action VARCHAR       -- FIXED, DELETED, ACCEPTED
);

-- Load with quarantine
CREATE OR REPLACE PROCEDURE pipeline.load_with_quarantine()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
BEGIN
    -- Quarantine invalid records
    INSERT INTO data_quality.quarantine (source_table, record_data, rejection_reasons, severity)
    SELECT 
        'orders_raw',
        OBJECT_CONSTRUCT(*),
        ARRAY_CONSTRUCT_COMPACT(
            IFF(order_id IS NULL, 'NULL_ORDER_ID', NULL),
            IFF(order_amount < 0, 'NEGATIVE_AMOUNT', NULL),
            IFF(order_date > CURRENT_DATE, 'FUTURE_DATE', NULL),
            IFF(customer_key IS NULL, 'NULL_CUSTOMER', NULL)
        ),
        CASE 
            WHEN order_id IS NULL THEN 'CRITICAL'
            ELSE 'HIGH'
        END
    FROM staging.orders_raw
    WHERE order_id IS NULL 
       OR order_amount < 0 
       OR order_date > CURRENT_DATE
       OR customer_key IS NULL;
    
    -- Load only clean records
    INSERT INTO analytics.orders_fact
    SELECT order_id, customer_key, product_key, order_amount, order_date, CURRENT_TIMESTAMP()
    FROM staging.orders_raw
    WHERE order_id IS NOT NULL 
      AND order_amount >= 0 
      AND order_date <= CURRENT_DATE
      AND customer_key IS NOT NULL;
    
    RETURN 'Load complete. Check quarantine for rejected records.';
END;
$$;
```

### 7.3 Data Quality Scoring

Assign a quality score to each table/dataset:

```sql
-- Quality score calculation
CREATE OR REPLACE VIEW data_quality.table_quality_scores AS
WITH check_results AS (
    SELECT 
        r.rule_id,
        rl.target_table,
        rl.rule_type,
        rl.severity,
        r.status,
        r.executed_at,
        ROW_NUMBER() OVER (PARTITION BY r.rule_id ORDER BY r.executed_at DESC) AS rn
    FROM data_quality.dq_results r
    JOIN data_quality.dq_rules rl ON r.rule_id = rl.rule_id
),
latest_results AS (
    SELECT * FROM check_results WHERE rn = 1
),
scoring AS (
    SELECT 
        target_table,
        COUNT(*) AS total_checks,
        SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END) AS passed_checks,
        SUM(CASE WHEN status = 'FAIL' AND severity = 'CRITICAL' THEN 1 ELSE 0 END) AS critical_failures,
        SUM(CASE WHEN status = 'FAIL' AND severity = 'HIGH' THEN 1 ELSE 0 END) AS high_failures
    FROM latest_results
    GROUP BY target_table
)
SELECT 
    target_table,
    total_checks,
    passed_checks,
    critical_failures,
    high_failures,
    ROUND(100.0 * passed_checks / NULLIF(total_checks, 0), 1) AS quality_score_pct,
    CASE 
        WHEN critical_failures > 0 THEN 'CRITICAL'
        WHEN high_failures > 0 THEN 'DEGRADED'
        WHEN quality_score_pct >= 95 THEN 'HEALTHY'
        WHEN quality_score_pct >= 80 THEN 'WARNING'
        ELSE 'POOR'
    END AS health_status
FROM scoring;
```

---

## 8. Data Quality Monitoring Dashboard Queries

```sql
-- Overall DQ health summary
SELECT 
    health_status,
    COUNT(*) AS table_count,
    ROUND(AVG(quality_score_pct), 1) AS avg_score
FROM data_quality.table_quality_scores
GROUP BY health_status
ORDER BY 
    CASE health_status 
        WHEN 'CRITICAL' THEN 1 
        WHEN 'DEGRADED' THEN 2 
        WHEN 'WARNING' THEN 3 
        WHEN 'POOR' THEN 4 
        ELSE 5 
    END;

-- Trend over time
SELECT 
    DATE(executed_at) AS check_date,
    COUNT(*) AS total_checks,
    SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END) AS passed,
    SUM(CASE WHEN status = 'FAIL' THEN 1 ELSE 0 END) AS failed,
    ROUND(100.0 * SUM(CASE WHEN status = 'PASS' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pass_rate
FROM data_quality.dq_results
WHERE executed_at >= CURRENT_DATE - 30
GROUP BY 1
ORDER BY 1;

-- Most failing rules
SELECT 
    rl.rule_name,
    rl.target_table,
    rl.rule_type,
    rl.severity,
    COUNT(CASE WHEN r.status = 'FAIL' THEN 1 END) AS failure_count,
    MAX(r.executed_at) AS last_failure
FROM data_quality.dq_results r
JOIN data_quality.dq_rules rl ON r.rule_id = rl.rule_id
WHERE r.executed_at >= CURRENT_DATE - 7
  AND r.status = 'FAIL'
GROUP BY 1, 2, 3, 4
ORDER BY failure_count DESC
LIMIT 10;
```

---

## 9. Best Practices Checklist

### Pipeline Design
- [ ] Every INSERT is idempotent (MERGE or dedup before load)
- [ ] Pipelines have circuit breakers before critical loads
- [ ] Quarantine pattern for invalid records
- [ ] Watermark-based incremental processing
- [ ] Look-back window for late-arriving data

### Monitoring
- [ ] Row count anomaly detection (2 standard deviations)
- [ ] Freshness monitoring with SLA thresholds
- [ ] NULL rate tracking per critical column
- [ ] Duplicate detection on business keys
- [ ] Cross-system reconciliation (source vs target)
- [ ] Distribution drift detection

### Alerting
- [ ] CRITICAL alerts → PagerDuty (immediate response)
- [ ] HIGH alerts → Slack channel (same-day response)
- [ ] MEDIUM alerts → Daily digest email
- [ ] LOW alerts → Weekly report

### Governance
- [ ] DQ rules registered in metadata catalog
- [ ] Each rule has an owner
- [ ] Quality scores visible to stakeholders
- [ ] Quarantine review SLA (24h for CRITICAL, 72h for HIGH)
- [ ] Schema change detection automated
- [ ] Monthly DQ review meetings

---

## 10. Tools & Technology Comparison

| Tool | Type | Best For | Cost |
|------|------|----------|------|
| **Snowflake DMFs** | Native | Snowflake tables, built-in scheduling | Included |
| **dbt tests** | Framework | dbt pipelines, CI/CD integration | Free (OSS) |
| **Great Expectations** | Library | Python pipelines, complex validations | Free (OSS) |
| **Soda Core** | Library | Multi-warehouse, YAML-based checks | Free (OSS) |
| **Monte Carlo** | SaaS | Enterprise observability, ML anomaly detection | $$$ |
| **Atlan** | SaaS | Data catalog + quality combined | $$$ |
| **Datafold** | SaaS | Data diffing, regression testing | $$ |
| **Elementary** | dbt package | dbt-native observability | Free (OSS) |

---

## 11. Interview Questions

**Q: How do you handle data quality in production?**
> Implement a layered approach: circuit breakers prevent bad data from loading, quarantine tables isolate invalid records for investigation, DMFs/dbt tests run post-load for detection, and reconciliation checks compare source vs target. All results feed into a scoring dashboard with severity-based alerting.

**Q: What's the difference between proactive and reactive data quality?**
> Proactive = prevent/detect issues before they impact consumers (circuit breakers, pre-load checks, anomaly detection). Reactive = respond after users report problems (incident investigation, root cause analysis). Goal is 80% proactive, 20% reactive.

**Q: How do you prioritize which checks to implement first?**
> Start with the "big 5": (1) row count anomalies, (2) freshness/timeliness, (3) NULL rates on critical columns, (4) duplicate detection on business keys, (5) referential integrity. These catch 80% of production issues.

**Q: How do you handle false positives in data quality alerts?**
> Tune thresholds using historical baselines (rolling 30-day average ± 2 std devs). Add exception rules for known patterns (holidays, month-end spikes). Implement alert suppression for maintenance windows. Track false positive rate and adjust quarterly.

---

*Data Quality Complete Guide · Detection · Frameworks · Production Solutions · Zero to Hero*
