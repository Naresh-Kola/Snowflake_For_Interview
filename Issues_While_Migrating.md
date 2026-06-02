# Greenplum to Snowflake Migration - Interview Notes

## Project Overview

Migrated data from Greenplum Data Warehouse to Snowflake Cloud Data Platform.

### Migration Flow

```text
Greenplum
    ↓
Python Extraction Scripts
    ↓
CSV / Parquet Files
    ↓
AWS S3 Stage
    ↓
Snowpipe
    ↓
Snowflake Landing Tables
    ↓
Transformation Layer
    ↓
Reporting Layer
```

### Responsibilities

* Data migration from Greenplum to Snowflake
* CDC implementation
* Data validation and reconciliation
* Snowpipe monitoring
* Performance tuning
* Production support
* Data quality checks
* Incident handling after go-live

---

# Migration Challenges

## 1. Data Type Conversion Issues

### Problem

Greenplum and Snowflake support different datatypes.

### Example

Greenplum

```sql
NUMERIC(38,20)
```

Snowflake

```sql
NUMBER(38,20)
```

### Impact

* Precision mismatch
* Data truncation

---

## 2. Timestamp and Timezone Issues

### Problem

Greenplum timestamps may not match Snowflake timestamp behavior.

### Example

Source

```text
2025-01-01 10:00:00 UTC
```

Target

```text
2025-01-01 15:30:00
```

### Impact

* Incorrect reports
* CDC failures

---

## 3. NULL Handling Differences

### Problem

NULL comparison behaves differently.

### Example

```sql
NULL = NULL
```

Returns NULL.

### Solution

```sql
IS NOT DISTINCT FROM
```

Used in CDC comparison logic.

---

## 4. Sequence Migration

### Problem

Sequences are not migrated automatically.

### Example

Greenplum

```sql
nextval('customer_seq')
```

Snowflake

```sql
CREATE SEQUENCE customer_seq;
```

### Impact

* Duplicate key issues
* Missing surrogate keys

---

## 5. Distribution Key Differences

### Problem

Greenplum uses distribution keys.

```sql
DISTRIBUTED BY(customer_id)
```

Snowflake does not.

### Impact

* Query execution changes
* Performance differences

---

## 6. Partition Strategy Changes

### Problem

Greenplum uses explicit partitions.

Snowflake uses automatic micro-partitions.

### Impact

* Existing partition strategy becomes irrelevant
* Need clustering for optimization

---

## 7. Character Encoding Issues

### Problem

Special characters get corrupted.

Example

```text
José
```

becomes

```text
Jos�
```

### Solution

Use UTF-8 validation.

---

## 8. Duplicate Data During Incremental Loads

### Problem

CDC jobs rerun after failure.

### Impact

Duplicate records in target.

### Solution

Use MERGE instead of INSERT.

---

## 9. Corrupted Source Files

### Problem

Bad CSV formatting.

Example

```text
"abc,xyz
```

### Impact

Snowpipe rejects records.

---

## 10. Large Table Migration

### Problem

Tables larger than 10 TB.

### Solution

Load data in chunks.

```sql
WHERE load_date BETWEEN ...
```

---

## 11. Network Transfer Bottlenecks

### Problem

Large volume migration takes too long.

### Example

20 TB data transfer.

### Solution

Parallel file uploads.

---

## 12. Query Performance Differences

### Problem

Same query behaves differently.

Example

```text
Greenplum : 2 min
Snowflake : 20 min
```

### Solution

Warehouse tuning.

---

## 13. Stored Procedure Conversion

### Problem

PL/pgSQL code not supported directly.

### Solution

Rewrite using:

* Snowflake SQL
* JavaScript
* Python

---

## 14. Unsupported Functions

### Example

```sql
generate_series()
```

Needs replacement logic.

---

## 15. CDC Logic Failures

### Problem

Timestamp mismatch.

### Impact

Incremental records skipped.

---

## 16. Referential Integrity Validation

### Problem

Snowflake constraints are informational.

### Impact

Orphan records can enter target.

---

## 17. Reconciliation Failures

### Example

```text
Source : 100,000,000
Target : 99,999,950
```

### Solution

Reconciliation framework.

---

## 18. Decimal Precision Loss

### Example

Source

```text
12345.678912345678
```

Target

```text
12345.678912
```

### Impact

Financial reporting issues.

---

## 19. Column Mapping Issues

### Problem

CSV column order mismatch.

Source

```text
id,name,salary
```

Target

```text
salary,id,name
```

### Impact

Incorrect data loading.

---

## 20. Late Arriving Data

### Problem

File arrives after CDC cutoff.

### Impact

Missed records.

### Solution

Watermark strategy.

---

# Production Support Challenges

## 21. Snowpipe Lag

### Problem

Files available in S3 but not loaded.

### Validation

```sql
SELECT SYSTEM$PIPE_STATUS('MY_PIPE');
```

---

## 22. Warehouse Suspension

### Problem

Warehouse auto-suspended.

### Solution

```sql
ALTER WAREHOUSE ETL_WH RESUME;
```

---

## 23. COPY INTO Failures

### Validation

```sql
SELECT *
FROM TABLE(VALIDATE(...));
```

---

## 24. Stage Permission Issues

### Error

```text
Access Denied
```

### Cause

Snowflake unable to read S3 files.

---

## 25. Storage Cost Increase

### Problem

Duplicate loads increase storage.

### Solution

Cleanup and retention strategy.

---

# Python + Snowpipe Data Quality Issues

## 1. Duplicate Records

### Detection

```sql
SELECT id,
       COUNT(*)
FROM customer
GROUP BY id
HAVING COUNT(*) > 1;
```

---

## 2. Missing Records

### Validation

```sql
SELECT COUNT(*)
```

Compare source vs target counts.

---

## 3. NULL Values

Mandatory columns loaded as NULL.

Example

```text
customer_name = NULL
```

---

## 4. Invalid Dates

Example

```text
2025-15-50
```

Causes load failures.

---

## 5. Invalid Numeric Data

Example

```text
salary = ABC
```

Cannot convert to NUMBER.

---

## 6. String Truncation

Source

```text
100 character value
```

Target

```text
VARCHAR(50)
```

Data loss occurs.

---

## 7. Encoding Problems

Examples

```text
₹
©
&
#
```

Can become corrupted.

---

## 8. Precision Loss

Source

```text
100.123456789
```

Target

```text
100.12
```

---

## 9. Case Sensitivity Issues

Examples

```text
India
INDIA
india
```

Creates duplicate business keys.

---

## 10. Business Key Violations

Example

```text
Same customer_id
Multiple records
```

---

## 11. Orphan Records

Order exists.

Customer missing.

### Validation

```sql
LEFT JOIN
```

based checks.

---

## 12. Schema Drift

### Problem

Source system adds new columns.

Example

```text
mobile_number
```

### Impact

Snowpipe failures.

---

# Reconciliation Checks Used During Migration

## Row Count Validation

```sql
SELECT COUNT(*)
```

---

## Duplicate Check

```sql
SELECT business_key,
       COUNT(*)
FROM table_name
GROUP BY business_key
HAVING COUNT(*) > 1;
```

---

## NULL Validation

```sql
SELECT COUNT(*)
FROM table_name
WHERE customer_id IS NULL;
```

---

## Aggregate Validation

```sql
SELECT SUM(amount)
```

Compare source and target.

---

## Min/Max Validation

```sql
SELECT MIN(load_date),
       MAX(load_date)
FROM table_name;
```

---

## CDC Validation

Validate:

* Inserts
* Updates
* Deletes

between source and target.

---

# Interview Summary Answer

During Greenplum to Snowflake migration, I was involved in data extraction, data validation, CDC implementation, Snowpipe-based ingestion, reconciliation, and production support activities. Major challenges included datatype conversion, timestamp handling, sequence migration, unsupported functions, partition strategy changes, performance tuning, CDC failures, duplicate records, schema drift, and data quality issues. We implemented reconciliation checks for row counts, aggregates, duplicates, NULL validations, referential integrity, and incremental load verification. Post go-live, I supported Snowpipe monitoring, warehouse management, failed loads, stage permission issues, storage optimization, and production incident resolution.
