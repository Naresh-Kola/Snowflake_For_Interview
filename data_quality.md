# DATA QUALITY IN MIGRATION PROJECTS (Greenplum → Snowflake)

Complete guide on what data quality means, where and when it's checked, and how to implement it in a real 450+ table migration project.

---

## 1. WHAT IS DATA QUALITY?

**Data Quality** = The degree to which data is ACCURATE, COMPLETE, CONSISTENT, TIMELY, and RELIABLE for its intended purpose.

In simple terms: "Can you TRUST the data to make business decisions?"

### THE 6 DIMENSIONS OF DATA QUALITY:

| DIMENSION | MEANING | EXAMPLE |
|---|---|---|
| 1. ACCURACY | Is the data correct? | Customer age = 25 (not 250) |
| 2. COMPLETENESS | Is anything missing? | No NULL emails for active users |
| 3. CONSISTENCY | Same data everywhere? | Status = 'active' not 'ACTV' |
| 4. TIMELINESS | Is it fresh/current? | Data loaded within SLA |
| 5. UNIQUENESS | No duplicates? | One row per customer_id |
| 6. VALIDITY | Follows business rules? | Order amount > 0 |

### IN A MIGRATION PROJECT:

Data Quality = "After moving 450 tables from Greenplum to Snowflake, is the data in Snowflake EXACTLY the same as Greenplum?" (Zero data loss, zero corruption, zero transformation errors)

---

## 2. WHERE AND WHEN DO WE CHECK DATA QUALITY? (Migration Lifecycle)

### PHASE 1: PRE-MIGRATION (Before any data moves)
- Profile source data (understand current quality)
- Document known issues in Greenplum
- Define acceptance criteria / thresholds
- Create reconciliation framework

### PHASE 2: DURING MIGRATION (As data moves)
- Row count validation (source vs target)
- Column-level checksum comparison
- NULL count comparison
- Min/Max/Sum/Avg comparison for numerics
- Duplicate detection
- Data type compatibility checks

### PHASE 3: POST-MIGRATION (After data lands in Snowflake)
- Full reconciliation report
- Business rule validation
- Downstream report comparison (same numbers?)
- Performance testing (queries return same results?)
- Sign-off from business stakeholders

### PHASE 4: ONGOING (After go-live)
- Daily/hourly quality monitors
- Anomaly detection (sudden row count drops)
- SLA monitoring (data freshness)
- Automated alerts on quality failures

---

## 3. REAL PROJECT SCENARIO: 450 TABLE MIGRATION

**PROJECT SETUP:**
- Source: Greenplum (on-prem, 450+ tables, ~50 TB)
- Target: Snowflake (cloud)
- Tool: Informatica IICS / custom Python scripts
- Timeline: 6 months
- Tables: 450+ (mix of fact, dimension, staging, audit)

**TEAM STRUCTURE:**
- Migration Engineer: Moves data (ETL/ELT)
- Data Quality Engineer: Validates data (YOU)
- DBA: Source access, performance tuning
- Business Analyst: Validates business logic
- Project Manager: Tracks progress, sign-offs

**YOUR ROLE (Data Quality Engineer):**
1. Build automated reconciliation framework
2. Run validations after each batch of tables migrates
3. Report discrepancies
4. Work with migration team to fix issues
5. Get business sign-off

---

## 4. DATA QUALITY CHECKS: WHAT TO VALIDATE

### 4.1 CHECK 1: ROW COUNT VALIDATION

The most basic check. Source rows must equal target rows. If they don't match → data loss or duplication.

```sql
-- On Greenplum (source):
-- SELECT COUNT(*) FROM public.orders;  -- Result: 12,345,678

-- On Snowflake (target):
SELECT COUNT(*) FROM MIGRATION_DB.PUBLIC.ORDERS;  -- Must be: 12,345,678

-- Store results in a reconciliation table:
CREATE OR REPLACE TABLE MIGRATION_DB.DQ.ROW_COUNT_RECONCILIATION (
    TABLE_NAME VARCHAR(200),
    SOURCE_COUNT NUMBER,
    TARGET_COUNT NUMBER,
    DIFFERENCE NUMBER,
    MATCH_STATUS VARCHAR(10),
    CHECKED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Example insert (after running counts on both sides):
INSERT INTO MIGRATION_DB.DQ.ROW_COUNT_RECONCILIATION VALUES
('ORDERS',       12345678, 12345678, 0,  'PASS', CURRENT_TIMESTAMP()),
('CUSTOMERS',    5000000,  5000000,  0,  'PASS', CURRENT_TIMESTAMP()),
('PAYMENTS',     8900000,  8899998,  2,  'FAIL', CURRENT_TIMESTAMP()),
('PRODUCTS',     45000,    45000,    0,  'PASS', CURRENT_TIMESTAMP()),
('ORDER_ITEMS',  67000000, 67000000, 0,  'PASS', CURRENT_TIMESTAMP());

-- Report failures:
SELECT * FROM MIGRATION_DB.DQ.ROW_COUNT_RECONCILIATION
WHERE MATCH_STATUS = 'FAIL';
```

### 4.2 CHECK 2: COLUMN-LEVEL AGGREGATE VALIDATION

For numeric columns: compare SUM, MIN, MAX, AVG between source and target. Catches: truncation, rounding, type conversion errors.

```sql
-- On Snowflake:
SELECT 
    SUM(AMOUNT) AS TOTAL_AMOUNT,
    MIN(AMOUNT) AS MIN_AMOUNT,
    MAX(AMOUNT) AS MAX_AMOUNT,
    ROUND(AVG(AMOUNT), 2) AS AVG_AMOUNT
FROM MIGRATION_DB.PUBLIC.ORDERS;
-- Must match exactly (or within acceptable tolerance for floating point)
```

### 4.3 CHECK 3: NULL COUNT VALIDATION

Compare NULL counts per column. Catches: default value issues, NOT NULL violations.

```sql
-- On Snowflake:
SELECT COUNT(*) - COUNT(EMAIL) AS NULL_EMAIL_COUNT FROM MIGRATION_DB.PUBLIC.CUSTOMERS;
-- Must be: 1500 (same as source)
```

### 4.4 CHECK 4: DUPLICATE DETECTION

Ensure primary key uniqueness is maintained after migration.

```sql
-- Check for duplicates in target:
SELECT ORDER_ID, COUNT(*) AS CNT
FROM MIGRATION_DB.PUBLIC.ORDERS
GROUP BY ORDER_ID
HAVING COUNT(*) > 1;
-- Must return ZERO rows
```

### 4.5 CHECK 5: DISTINCT VALUE COMPARISON

For categorical/enum columns: ensure all distinct values exist. Catches: encoding issues, truncation, case sensitivity differences.

```sql
-- On Snowflake:
SELECT DISTINCT STATUS FROM MIGRATION_DB.PUBLIC.ORDERS ORDER BY 1;
-- Must return same values (watch for case: 'Pending' vs 'pending' vs 'PENDING')
```

### 4.6 CHECK 6: DATA TYPE COMPATIBILITY VALIDATION

Greenplum and Snowflake have different type systems. Common issues:

| Greenplum Type | Snowflake Type | Potential Issue |
|---|---|---|
| NUMERIC(10,4) | NUMBER(10,4) | Usually OK |
| TEXT | VARCHAR(16777216) | OK (Snowflake is larger) |
| BOOLEAN | BOOLEAN | OK |
| TIMESTAMP | TIMESTAMP_NTZ | Timezone handling! |
| TIMESTAMPTZ | TIMESTAMP_TZ | Offset may differ |
| BYTEA | BINARY | Encoding differences |
| INTERVAL | NOT SUPPORTED | Must convert to seconds |
| ARRAY | ARRAY/VARIANT | Parsing needed |
| JSON/JSONB | VARIANT | Usually OK |
| SERIAL | NUMBER + SEQUENCE | Identity handling |
| MONEY | NUMBER(19,4) | Precision check |
| CHAR(10) | CHAR(10)/VARCHAR | Trailing spaces! |

**CRITICAL ISSUE: TIMESTAMP vs TIMESTAMP_NTZ**
- Greenplum TIMESTAMP = no timezone info (local time assumed)
- Snowflake TIMESTAMP_NTZ = no timezone info
- Snowflake TIMESTAMP_LTZ = local timezone applied
- Snowflake TIMESTAMP_TZ = stores timezone offset
- WRONG TYPE = data shifted by hours!

### 4.7 CHECK 7: HASH-BASED ROW COMPARISON (Gold Standard)

For critical tables: compute a hash of entire row and compare. Most accurate but most expensive.

```sql
-- On Snowflake (compute same hash):
SELECT 
    ORDER_ID,
    MD5(CONCAT_WS('|', 
        COALESCE(ORDER_ID::VARCHAR, ''),
        COALESCE(CUSTOMER_ID::VARCHAR, ''),
        COALESCE(AMOUNT::VARCHAR, ''),
        COALESCE(STATUS, '')
    )) AS ROW_HASH
FROM MIGRATION_DB.PUBLIC.ORDERS
ORDER BY ORDER_ID
LIMIT 10;
```

### 4.8 CHECK 8: REFERENTIAL INTEGRITY

Ensure foreign key relationships are intact after migration. Greenplum may have enforced FK constraints; Snowflake does NOT enforce them.

```sql
-- Check: All order customer_ids exist in customers table
SELECT COUNT(*) AS ORPHAN_ORDERS
FROM MIGRATION_DB.PUBLIC.ORDERS O
LEFT JOIN MIGRATION_DB.PUBLIC.CUSTOMERS C ON O.CUSTOMER_ID = C.CUSTOMER_ID
WHERE C.CUSTOMER_ID IS NULL;
-- Must be 0 (or same as Greenplum if orphans existed in source)
```

### 4.9 CHECK 9: BOUNDARY / EDGE CASE VALIDATION

```sql
-- Very large numbers (overflow risk)
SELECT COUNT(*) FROM MIGRATION_DB.PUBLIC.ORDERS WHERE AMOUNT > 99999999;

-- Very long strings (truncation risk)
SELECT MAX(LENGTH(DESCRIPTION)) FROM MIGRATION_DB.PUBLIC.PRODUCTS;

-- Special characters (encoding risk)
SELECT COUNT(*) FROM MIGRATION_DB.PUBLIC.CUSTOMERS 
WHERE CUSTOMER_NAME LIKE '%é%' OR CUSTOMER_NAME LIKE '%ñ%' OR CUSTOMER_NAME LIKE '%中%';

-- Empty strings vs NULLs
SELECT 
    COUNT(CASE WHEN ADDRESS = '' THEN 1 END) AS EMPTY_STRING_COUNT,
    COUNT(CASE WHEN ADDRESS IS NULL THEN 1 END) AS NULL_COUNT
FROM MIGRATION_DB.PUBLIC.CUSTOMERS;

-- Date boundaries
SELECT 
    COUNT(CASE WHEN ORDER_DATE < '1970-01-01' THEN 1 END) AS PRE_EPOCH,
    COUNT(CASE WHEN ORDER_DATE > '2099-12-31' THEN 1 END) AS FAR_FUTURE
FROM MIGRATION_DB.PUBLIC.ORDERS;
```

### 4.10 CHECK 10: BUSINESS RULE VALIDATION

```sql
-- Rule: Completed orders must have a payment
SELECT COUNT(*) AS ORDERS_WITHOUT_PAYMENT
FROM MIGRATION_DB.PUBLIC.ORDERS O
LEFT JOIN MIGRATION_DB.PUBLIC.PAYMENTS P ON O.ORDER_ID = P.ORDER_ID
WHERE O.STATUS = 'completed' AND P.PAYMENT_ID IS NULL;

-- Rule: Order amount = SUM of order_items
SELECT COUNT(*) AS MISMATCHED_ORDERS
FROM (
    SELECT O.ORDER_ID, O.AMOUNT AS ORDER_AMOUNT, SUM(OI.UNIT_PRICE * OI.QUANTITY) AS CALC_AMOUNT
    FROM MIGRATION_DB.PUBLIC.ORDERS O
    JOIN MIGRATION_DB.PUBLIC.ORDER_ITEMS OI ON O.ORDER_ID = OI.ORDER_ID
    GROUP BY O.ORDER_ID, O.AMOUNT
    HAVING ABS(ORDER_AMOUNT - CALC_AMOUNT) > 0.01
);

-- Rule: No future-dated orders
SELECT COUNT(*) FROM MIGRATION_DB.PUBLIC.ORDERS WHERE ORDER_DATE > CURRENT_DATE();
```

---

## 5. AUTOMATED RECONCILIATION FRAMEWORK

```sql
-- Master control table: tracks all 450 tables and their validation status
CREATE OR REPLACE TABLE MIGRATION_DB.DQ.MIGRATION_CONTROL (
    TABLE_ID INT AUTOINCREMENT,
    SOURCE_SCHEMA VARCHAR(100),
    SOURCE_TABLE VARCHAR(200),
    TARGET_DATABASE VARCHAR(100),
    TARGET_SCHEMA VARCHAR(100),
    TARGET_TABLE VARCHAR(200),
    PRIMARY_KEY_COLUMNS VARCHAR(500),
    MIGRATION_STATUS VARCHAR(20) DEFAULT 'PENDING',
    ROW_COUNT_STATUS VARCHAR(10),
    AGGREGATE_STATUS VARCHAR(10),
    NULL_CHECK_STATUS VARCHAR(10),
    DUPLICATE_STATUS VARCHAR(10),
    HASH_CHECK_STATUS VARCHAR(10),
    OVERALL_DQ_STATUS VARCHAR(10),
    MIGRATED_AT TIMESTAMP_NTZ,
    VALIDATED_AT TIMESTAMP_NTZ,
    SIGNED_OFF_BY VARCHAR(100),
    NOTES VARCHAR(2000)
);

-- Dashboard query: Overall migration progress
SELECT 
    MIGRATION_STATUS,
    COUNT(*) AS TABLE_COUNT,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER(), 2) AS PERCENTAGE
FROM MIGRATION_DB.DQ.MIGRATION_CONTROL
GROUP BY MIGRATION_STATUS;
```

---

## 6. STORED PROCEDURE: AUTOMATED ROW COUNT CHECK

```sql
CREATE OR REPLACE PROCEDURE MIGRATION_DB.DQ.SP_VALIDATE_ROW_COUNTS()
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
DECLARE
    v_table VARCHAR;
    v_target_count NUMBER;
    c1 CURSOR FOR 
        SELECT TARGET_TABLE 
        FROM MIGRATION_DB.DQ.MIGRATION_CONTROL 
        WHERE MIGRATION_STATUS = 'MIGRATED';
BEGIN
    FOR record IN c1 DO
        v_table := record.TARGET_TABLE;
        
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM MIGRATION_DB.PUBLIC.' || v_table
            INTO :v_target_count;
        
        UPDATE MIGRATION_DB.DQ.ROW_COUNT_RECONCILIATION
        SET TARGET_COUNT = :v_target_count,
            DIFFERENCE = SOURCE_COUNT - :v_target_count,
            MATCH_STATUS = CASE WHEN SOURCE_COUNT = :v_target_count THEN 'PASS' ELSE 'FAIL' END,
            CHECKED_AT = CURRENT_TIMESTAMP()
        WHERE TABLE_NAME = :v_table;
    END FOR;
    
    RETURN 'Row count validation complete';
END;
$$;
```

---

## 7. COMMON DATA QUALITY ISSUES IN GREENPLUM → SNOWFLAKE MIGRATION

| # | ISSUE | ROOT CAUSE & FIX |
|---|---|---|
| 1 | Row count mismatch | Duplicates from retry logic. Fix: add dedup step or use MERGE instead of INSERT. |
| 2 | Numeric precision loss | NUMERIC(38,10) → NUMBER(38,4). Fix: use correct scale in Snowflake DDL. |
| 3 | Timestamp shift | TIMESTAMPTZ in GP → TIMESTAMP_NTZ in SF. Fix: Use TIMESTAMP_TZ or convert timezone. |
| 4 | Trailing spaces in CHAR | CHAR(10) pads with spaces in GP. SF VARCHAR does not. Fix: TRIM() during migration. |
| 5 | Empty string vs NULL | GP: '' is ''. SF: '' is '' (OK). But some tools convert '' → NULL. Verify! |
| 6 | Boolean representation | GP: true/false. SF: TRUE/FALSE. Some tools load as 't'/'f' strings. Fix! |
| 7 | Sequence/Identity gaps | GP SERIAL → SF IDENTITY. Values may differ if using IDENTITY instead of copying values. |
| 8 | Distribution key ordering | GP distributes by key (rows in diff order). Not a DQ issue but affects hash comparison. |
| 9 | Unicode/encoding | GP: UTF-8 or LATIN1. SF: always UTF-8. LATIN1 special chars may corrupt. Fix: explicit encoding conversion. |
| 10 | Array/JSON handling | GP: ARRAY type, JSONB type. SF: VARIANT. Nested structures may parse differently. |
| 11 | Case sensitivity | GP: case-insensitive identifiers by default. SF: case-insensitive unless quoted. |
| 12 | NaN/Infinity values | GP allows NaN, Infinity in FLOAT. SF: NaN supported, Infinity = error. Fix: Replace Infinity with NULL. |

---

## 7B. DEEP DIVE: EMPTY STRING vs NULL (Critical Migration Pitfall)

### WHY THIS MATTERS:

**In Greenplum (PostgreSQL-based):**
- `''` (empty string) and `NULL` are DIFFERENT values
- `''` means "field was filled but has no content" (user left it blank)
- `NULL` means "field was never filled / unknown / not applicable"

**In Snowflake:**
- `''` and `NULL` are ALSO different (Snowflake preserves the distinction)
- BUT the PROBLEM is the MIGRATION TOOL, not Snowflake itself

### THE REAL PROBLEM:

Many ETL tools silently convert `''` → `NULL` during data transfer:
- **Informatica:** Some versions treat '' as NULL for VARCHAR
- **CSV export:** Empty field between commas `(,,)` = ambiguous (NULL or ''?)
- **Spark/PySpark:** Reads empty CSV fields as NULL by default
- **COPY INTO with CSV:** Empty field = NULL (unless you configure otherwise)
- **Pandas to_csv:** Writes NULL as empty, reads empty as NaN → NULL

### EXAMPLE:

**GREENPLUM SOURCE TABLE (customers):**

| id | name | email | address |
|---|---|---|---|
| 1 | Rahul | r@x.com | Mumbai |  (all fields filled) |
| 2 | Priya | p@x.com | '' | (address is EMPTY STRING) |
| 3 | Amit | NULL | NULL | (email and address are NULL) |
| 4 | Kavita | k@x.com | '' | (address is EMPTY STRING) |

**AFTER MIGRATION (if tool converts '' → NULL):**

| id | name | email | address |
|---|---|---|---|
| 1 | Rahul | r@x.com | Mumbai | OK |
| 2 | Priya | p@x.com | NULL | WRONG! Was '' now NULL |
| 3 | Amit | NULL | NULL | OK (was already NULL) |
| 4 | Kavita | k@x.com | NULL | WRONG! Was '' now NULL |

### WHY THIS BREAKS THINGS:
- `COUNT(address)` returns 2 instead of 3 (NULL not counted, '' IS counted)
- `WHERE address IS NULL` returns 3 rows instead of 1
- Reports show "60% of customers have no address" instead of "20%"
- Business logic: `IF address IS NULL THEN 'ask user'` — now triggers for users who DID submit

### HOW TO FIX / PREVENT:

1. **Configure COPY INTO:** `FILE_FORMAT = (TYPE='CSV' EMPTY_FIELD_AS_NULL = FALSE)`
2. **In ETL tool:** Set "Treat empty string as NULL" = FALSE
3. **Use Parquet/Avro format** instead of CSV (properly distinguishes NULL vs '')
4. **Post-migration correction** if known columns had empty strings

### SNOWFLAKE-SPECIFIC BEHAVIOR:

```sql
SELECT '' IS NULL;          -- FALSE (empty string is NOT null)
SELECT '' = '';             -- TRUE
SELECT LENGTH('');          -- 0
SELECT LENGTH(NULL);       -- NULL
SELECT COALESCE('', 'x');  -- '' (returns '', not 'x', because '' is not NULL)
```

So Snowflake handles it correctly. The problem is always the TRANSFER LAYER.

---

## 8. INTERVIEW QUESTIONS: DATA QUALITY IN MIGRATION

### LEVEL 1: BASICS

**Q1: What is data quality?**
A: Measure of data's fitness for its intended use. Covers accuracy, completeness, consistency, timeliness, uniqueness, and validity.

**Q2: What's the most basic data quality check in a migration?**
A: Row count comparison between source and target.

**Q3: Why might row counts not match after migration?**
A: Duplicates (retry logic), filtered rows (WHERE clause error), failed records (data type incompatibility), or partial load failure.

**Q4: What tool did you use for data quality checks?**
A: Custom SQL framework on Snowflake + Python scripts for cross-platform comparison. Some teams use Great Expectations, dbt tests, Monte Carlo, or Informatica Data Quality.

**Q5: How do you check for duplicates?**
A: GROUP BY primary key columns HAVING COUNT(*) > 1.

### LEVEL 2: INTERMEDIATE

**Q6: How do you validate numeric columns across systems?**
A: Compare SUM, MIN, MAX, AVG, COUNT DISTINCT. Accept tolerance for floating-point (0.001%). Exact match required for integers and decimals.

**Q7: How do you handle timestamp differences between GP and Snowflake?**
A: Identify if source uses TIMESTAMP (no tz) or TIMESTAMPTZ. Map to TIMESTAMP_NTZ or TIMESTAMP_TZ accordingly. Validate by comparing MIN/MAX dates and spot-checking specific records.

**Q8: What's a hash-based validation? When do you use it?**
A: Compute MD5/SHA256 of concatenated column values per row. Compare hashes between source and target. Use for critical tables where accuracy is non-negotiable. Expensive (full table scan both sides), so use selectively.

**Q9: How do you track DQ status for 450+ tables?**
A: Migration control table with columns for each check type. Automated procedures run checks and update status. Dashboard shows overall progress and failures.

**Q10: What's the difference between technical and business validation?**
A: Technical: row counts, NULLs, types, duplicates (automated). Business: "Does the revenue report show the same number?" (requires business user to compare old vs new system reports).

### LEVEL 3: ADVANCED

**Q11: How do you handle false positives in DQ checks?**
A: Some mismatches are EXPECTED (known data issues in source). Document known issues in a baseline table. DQ framework compares CURRENT mismatches against KNOWN mismatches. Only NEW mismatches are flagged as failures.

**Q12: How do you validate data quality for incremental/CDC loads?**
A: Row count delta, freshness check (MAX timestamp vs current time), anomaly detection (row count suddenly drops 50% = alert), schema drift detection.

**Q13: How do you handle DQ for very large tables (1B+ rows)?**
A: Aggregate checks (SUM, COUNT, MIN/MAX) — fast. Sample-based hash (random 1% of rows). Partition-level counts (by date, region). Trend comparison (this month vs last month).

**Q14: What's your DQ testing strategy for the migration waves?**
A: Wave 1 (50 tables): Full validation, hash-level for critical tables. Wave 2-5 (100 tables each): Automated framework, aggregate checks. Final wave: Full reconciliation + business sign-off. Each wave has a "DQ gate" — cannot proceed until PASS rate > 99%.

**Q15: How do you handle the "empty string vs NULL" problem?**
A: Profile source: count '' and NULL separately. During migration: explicit handling (NULLIF, COALESCE). Post-migration: compare '' counts and NULL counts independently.

### LEVEL 4: ARCHITECT / LEAD

**Q16: Design a data quality framework for a 450-table migration.**
A: Components: Metadata catalog, source profiling, automated validation, reconciliation database, dashboard, alerting, sign-off workflow, exception management.

**Q17: How do you estimate effort for DQ in a migration project?**
A: Rule of thumb: DQ = 30-40% of total migration effort. Framework build: 2-3 weeks (one-time). 450 tables × 2 hours avg = ~900 hours. Automate 80%, manually validate the critical 20%.

**Q18: What metrics do you report to stakeholders?**
A: Tables migrated: 350/450 (78%). DQ Pass rate: 345/350 (98.6%). Critical failures: 2. Blocking issues: 0. Estimated completion: on schedule.

**Q19: How do you handle DQ failures that can't be fixed?**
A: Document as "known issues" with business impact assessment. Options: Fix in source, fix during transformation, accept with sign-off, or flag for post-migration cleanup.

**Q20: How do you ensure DQ after the migration goes live?**
A: Convert migration DQ checks into ONGOING MONITORING: Snowflake DMFs, dbt tests, anomaly detection, weekly reports to data owners, quarterly reconciliation.

---

## 9. SAMPLE RECONCILIATION REPORT

```
╔══════════════════════════════════════════════════════════════════════════╗
║              MIGRATION DQ REPORT - WAVE 3 (2024-06-15)                 ║
╠══════════════════════════════════════════════════════════════════════════╣
║ Tables in Wave: 80        Migrated: 80         Validated: 78           ║
║ PASSED: 76 (97.4%)       FAILED: 2 (2.6%)     PENDING: 2              ║
╠══════════════════════════════════════════════════════════════════════════╣
║                                                                        ║
║ FAILURES:                                                              ║
║                                                                        ║
║ 1. PAYMENTS (Row count mismatch)                                       ║
║    Source: 8,900,000 | Target: 8,899,998 | Diff: -2 rows              ║
║    Root cause: 2 records with NaN in amount column rejected by SF      ║
║    Action: Replace NaN with NULL and reload                            ║
║    Owner: Migration Team | ETA: 2024-06-16                             ║
║                                                                        ║
║ 2. AUDIT_LOG (Hash mismatch on 15 rows)                               ║
║    Source: 45,000,000 | Target: 45,000,000 (counts match)             ║
║    Root cause: TIMESTAMPTZ → TIMESTAMP_NTZ lost timezone offset        ║
║    Action: Reload with TIMESTAMP_TZ type                               ║
║    Owner: DBA Team | ETA: 2024-06-17                                   ║
║                                                                        ║
╠══════════════════════════════════════════════════════════════════════════╣
║ SIGN-OFF: Pending (blocked by 2 failures above)                        ║
╚══════════════════════════════════════════════════════════════════════════╝
```

---

## 10. TOOLS USED FOR DATA QUALITY IN REAL PROJECTS

| Tool | Use Case |
|---|---|
| Custom SQL | Row counts, aggregates, duplicates (most common) |
| dbt tests | Ongoing DQ (not_null, unique, relationships) |
| Great Expectations | Open-source DQ framework (Python-based) |
| Monte Carlo | Automated anomaly detection, observability |
| Snowflake DMFs | Native DQ monitoring (freshness, null %, etc.) |
| Informatica DQ | Enterprise DQ profiling and cleansing |
| Ataccama | Data profiling, cataloging, quality rules |
| Python + Pandas | Ad-hoc comparisons, custom validations |
| Snowflake Streams | Detect changes for real-time DQ monitoring |

---

## 11. HOW TO EXPLAIN IN AN INTERVIEW (Step-by-Step Answers)

### QUESTION 1: "What did source data profiling reveal before migration started? Were there any surprises?"

**Structure:** WHAT you did → WHAT you found → SURPRISES → IMPACT

**Answer:**

"Before we started moving any data, we ran a full data profiling exercise on all 450+ tables in Greenplum. This took about 3 weeks with 2 engineers.

**WHAT WE DID:**
- Row counts per table
- Column-level stats: NULL %, distinct count, min, max, avg
- Data type inventory
- Primary key / unique constraint analysis
- String length distributions
- Date range analysis

**SURPRISES:**

1. **DUPLICATE ROWS IN SOURCE:** 8 tables had duplicate primary keys IN Greenplum itself. Documented as 'known issues baseline'.

2. **TIMESTAMP CHAOS:** Some tables used TIMESTAMP, others TIMESTAMPTZ, and 3 tables stored timestamps as VARCHAR strings.

3. **EMPTY STRINGS vs NULLs:** 22 tables had significant empty string usage. Without handling, ETL would convert '' to NULL silently.

4. **INFINITY AND NaN VALUES:** 3 FLOAT columns had Infinity values. Snowflake doesn't support Infinity.

5. **ORPHAN RECORDS:** ~50,000 order_items pointed to non-existent orders.

6. **UNUSED TABLES:** 120 out of 450 tables hadn't been queried in 6+ months. Deprioritized to last wave.

**KEY TAKEAWAY:** 'Profiling saved us 3 weeks of debugging DURING migration.'"

---

### QUESTION 2: "What was your reconciliation strategy — row counts, checksums, aggregates, or sample audits?"

**Structure:** "We used a LAYERED approach" → explain each layer → specific numbers

**Answer:**

"We used a **4-LAYER reconciliation strategy.** Each layer catches different types of issues, going from cheapest to most expensive:

**LAYER 1: ROW COUNTS** (100% of tables, every load)
- COUNT(*) on source vs target
- Cost: Seconds per table
- Catches: Partial loads, duplicates, filtered rows
- Result: 12 tables failed on first attempt

**LAYER 2: AGGREGATE CHECKS** (100% of tables, every load)
- SUM, MIN, MAX, AVG for numerics; COUNT DISTINCT, MAX(LENGTH) for strings; NULL count for all
- Cost: 30-60 seconds per table
- Catches: Truncation, rounding, type conversion
- Result: Caught 5 precision issues, 3 timestamp offsets, 22 empty-string conversions

**LAYER 3: SAMPLE AUDITS** (100% of tables, once per wave)
- Random 1000 rows, pull from both systems, compare column-by-column
- Cost: 2-5 minutes per table
- Catches: Row-level corruption that aggregates miss
- Result: Found 1 table with wrong column values (JOIN error in ETL)

**LAYER 4: FULL HASH COMPARISON** (Top 50 critical tables only)
- MD5 hash of every row, compare all hashes
- Cost: 10-30 minutes per large table
- Catches: EVERYTHING
- Result: Found 15 rows with timezone shifts in audit_log

**IN NUMBERS:**
- 450 tables validated
- 3,200+ column-level checks per run
- 98.7% pass rate on first attempt
- 6 tables required re-migration
- Average time to detect + fix: 4 hours"

---

### QUESTION 3: "What was your accepted error threshold before go-live? Who made that decision?"

**Structure:** State threshold → WHO defined it → WHY → what happens on breach → real example

**Answer:**

"We had a **TIERED threshold system** — not one single number for everything:

| TIER | TABLES | ROW COUNT TOLERANCE | AGGREGATES | HASH MISMATCH |
|---|---|---|---|---|
| Tier 1 (Critical) | Finance, Payments, Compliance, Audit | 0 rows (exact) | 0.00 (exact) | 0 rows (exact) |
| Tier 2 (High) | Orders, Customers, Products, Inventory | 0 rows (exact) | 0.001% tolerance | < 10 rows |
| Tier 3 (Medium) | Analytics, Staging, Logs, History | < 0.001% (±10 rows per 1M) | 0.01% tolerance | N/A (sample only) |
| Tier 4 (Low) | Temp, Deprecated, Dev/Test | < 0.01% | 0.1% tolerance | N/A |

**WHO MADE THIS DECISION:**
1. **Data Engineering Lead:** Proposed thresholds based on technical feasibility
2. **Business Stakeholders (Finance Director, Compliance):** Mandated zero tolerance for Tier 1
3. **Data Governance Team:** Classified all 450 tables into tiers
4. **Project Manager:** Final sign-off, documented in project charter

**GO-LIVE CRITERIA:**
- All Tier 1: 100% PASS (zero exceptions)
- All Tier 2: 100% PASS (max 2 documented exceptions)
- All Tier 3: 99% PASS rate
- All Tier 4: 95% PASS rate

**Our actual go-live stats:**
- Tier 1: 50/50 PASS (100%)
- Tier 2: 198/200 PASS (99%) + 2 documented exceptions
- Tier 3: 148/150 PASS (98.7%)
- Tier 4: 48/50 PASS (96%)
- Overall: 444/450 PASS (98.7%) with 6 documented exceptions"

---

## 12. INTERVIEW TIPS: HOW TO DELIVER THESE ANSWERS

**TIP 1: USE THE "STAR" FORMAT**
- Situation: "We had 450 tables migrating from Greenplum to Snowflake"
- Task: "I was responsible for ensuring zero data loss"
- Action: "I built a 4-layer reconciliation framework..."
- Result: "98.7% pass rate, 6 exceptions documented, on-time go-live"

**TIP 2: ALWAYS GIVE SPECIFIC NUMBERS**
- Bad: "We checked data quality" (vague)
- Good: "We validated 450 tables across 3,200 columns with 4 layers of checks and achieved 98.7% first-pass success rate" (specific)

**TIP 3: MENTION WHO ELSE WAS INVOLVED**
- Shows you work in teams, not isolation.

**TIP 4: MENTION SURPRISES / CHALLENGES**
- Interviewers LOVE hearing about problems you solved.

**TIP 5: SHOW IMPACT OF YOUR WORK**
- "Source profiling saved us 3 weeks of debugging."
- "The automated framework reduced validation time from 2 days to 45 minutes per wave."
- "Zero data-related incidents in the 3 months after go-live."

**TIP 6: BE READY FOR FOLLOW-UPS**
- "What if the business wanted to change the threshold mid-project?" → Change control process
- "What would you do differently next time?" → Start profiling earlier, use Parquet instead of CSV
- "How did you handle tables being actively written to during migration?" → Cutover strategy with CDC delta
