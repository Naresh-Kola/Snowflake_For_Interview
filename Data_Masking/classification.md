# Snowflake Data Classification for Masking: Complete Guide

## Table of Contents
1. [What is Data Classification?](#1-what-is-data-classification)
2. [Core Concepts](#2-core-concepts)
3. [Privacy Categories](#3-privacy-categories)
4. [Semantic Categories (Native)](#4-semantic-categories-native)
5. [Custom Classifiers](#5-custom-classifiers)
6. [Classification Profiles](#6-classification-profiles)
7. [Auto-Tagging](#7-auto-tagging)
8. [Tag Mapping](#8-tag-mapping)
9. [The Full Pipeline: Classify → Tag → Mask](#9-the-full-pipeline-classify--tag--mask)
10. [Hands-On: Step-by-Step Implementation](#10-hands-on-step-by-step-implementation)
11. [Monitoring & Auditing Classification](#11-monitoring--auditing-classification)
12. [Cost Considerations](#12-cost-considerations)
13. [Limitations](#13-limitations)

---

## 1. What is Data Classification?

Data classification is the **automated process of discovering which columns contain sensitive data** and labeling them with categories (tags). It answers:

- **Where** is my sensitive data?
- **What type** of sensitive data is it? (email, SSN, name, salary, etc.)
- **How sensitive** is it? (Identifier, Quasi-identifier, Sensitive)

```
┌──────────────────────────────────────────────────────────────────────┐
│                     CLASSIFICATION PIPELINE                           │
│                                                                      │
│  ┌─────────┐     ┌──────────────┐     ┌──────────┐     ┌─────────┐ │
│  │  TABLE   │────►│  CLASSIFY    │────►│   TAG    │────►│  MASK   │ │
│  │  (data)  │     │  (discover)  │     │  (label) │     │ (protect)│ │
│  └─────────┘     └──────────────┘     └──────────┘     └─────────┘ │
│                                                                      │
│  Raw columns      Snowflake scans     System & custom   Tag-based   │
│  with unknown     data & identifies   tags applied to   masking     │
│  sensitivity      sensitive columns   classified cols   auto-protects│
└──────────────────────────────────────────────────────────────────────┘
```

### Why Classification Matters for Masking

Without classification, you must **manually identify** every sensitive column and apply masking policies one by one. With classification:

1. Snowflake **automatically discovers** PII/sensitive columns
2. **Tags are applied** automatically (SEMANTIC_CATEGORY, PRIVACY_CATEGORY)
3. **Tag-based masking policies** auto-protect columns based on tags
4. **New tables/columns** get classified and masked automatically

---

## 2. Core Concepts

### Two Dimensions of Classification

Every classified column gets assigned TWO categories:

| Dimension | What It Answers | Examples |
|-----------|----------------|----------|
| **Semantic Category** | What *type* of data is this? | EMAIL, NAME, SSN, PHONE_NUMBER |
| **Privacy Category** | How *sensitive* is this data? | IDENTIFIER, QUASI_IDENTIFIER, SENSITIVE |

### System Tags Applied

When classification runs, Snowflake applies these system-defined tags:

```
SNOWFLAKE.CORE.SEMANTIC_CATEGORY = 'EMAIL'        ← type of data
SNOWFLAKE.CORE.PRIVACY_CATEGORY  = 'IDENTIFIER'   ← sensitivity level
```

### Classification vs Masking (Relationship)

```
Classification = DISCOVERY  → "What sensitive data do I have?"
Masking        = PROTECTION → "How do I hide it from unauthorized users?"

Classification FEEDS masking through TAGS:
  Classify → Tag → Tag-based Masking Policy → Auto-protection
```

---

## 3. Privacy Categories

Snowflake classifies all sensitive data into one of **three privacy categories**:

### IDENTIFIER

Data that **directly identifies** a person or entity on its own.

```
Examples: SSN, Email, Name, Passport, Driver's License, Phone Number
Risk: Single column can identify an individual
Protection: Highest — full mask or tokenize
```

### QUASI_IDENTIFIER

Data that **cannot identify** someone alone, but when **combined** with other data, could re-identify.

```
Examples: Date of Birth, Age, Gender, City, Postal Code, Ethnicity
Risk: 2-3 columns combined → identification possible
Protection: Medium — partial mask, generalize, or restrict
```

### SENSITIVE

Confidential data that doesn't identify anyone but requires protection due to its nature.

```
Examples: Salary, Medical Conditions, Medical Procedures, Medicine Names
Risk: Disclosure of private/confidential information
Protection: Role-based — mask from unauthorized roles
```

### Visual Summary

```
┌─────────────────────────────────────────────────────────────────┐
│                    PRIVACY CATEGORIES                             │
├─────────────────┬─────────────────────┬─────────────────────────┤
│   IDENTIFIER    │  QUASI_IDENTIFIER   │       SENSITIVE          │
│                 │                     │                          │
│  Directly       │  Combined can       │  Private but not         │
│  identifies     │  re-identify        │  identifying             │
│                 │                     │                          │
│  • SSN          │  • Date of Birth    │  • Salary                │
│  • Email        │  • Age              │  • Medical Condition     │
│  • Name         │  • Gender           │  • Medical Procedure     │
│  • Phone        │  • City             │  • Medicine Name         │
│  • Passport     │  • Postal Code      │  • ICD-10 Code           │
│  • IP Address   │  • Ethnicity        │  • Lab Test              │
│  • Bank Account │  • Occupation       │                          │
│  • Payment Card │  • Marital Status   │                          │
│  • VIN          │  • Country          │                          │
│  • IMEI         │  • US County        │                          │
└─────────────────┴─────────────────────┴─────────────────────────┘
```

---

## 4. Semantic Categories (Native)

Snowflake provides **built-in semantic categories** that it can automatically recognize.

### Global Identifiers (Applicable Worldwide)

| Semantic Category | Description |
|------------------|-------------|
| `BANK_ACCOUNT` | Bank account numbers |
| `EMAIL` | Email addresses |
| `IMEI` | Mobile device identifiers |
| `IP_ADDRESS` | IPv4/IPv6 addresses |
| `NAME` | Person names |
| `PAYMENT_CARD` | Credit/debit card numbers |
| `URL` | Web URLs |
| `VIN` | Vehicle identification numbers |

### Country-Specific Identifiers

| Semantic Category | Countries Supported |
|------------------|-------------------|
| `DRIVERS_LICENSE` | US, CA, AU, IN, UK + 25 EU countries |
| `NATIONAL_IDENTIFIER` | US (SSN), CA (SIN), IN (Aadhaar, PAN), UK (NIN), SG, 25+ EU |
| `PASSPORT` | US, CA, AU, IN, SG, UK + 25 EU countries |
| `PHONE_NUMBER` | US, CA, AU, UK, JP |
| `STREET_ADDRESS` | US, CA, NZ |
| `TAX_IDENTIFIER` | US (EIN/ITIN), AU, IN (GST), IT, FR, DE + many more |
| `ORGANIZATION_IDENTIFIER` | AU (ABN/ACN), NZ, SG |
| `MEDICARE_NUMBER` | AU, NZ |

### Global Quasi-Identifiers

| Semantic Category | Privacy Category |
|------------------|-----------------|
| `AGE` | QUASI_IDENTIFIER |
| `COUNTRY` | QUASI_IDENTIFIER |
| `DATE_OF_BIRTH` | QUASI_IDENTIFIER |
| `ETHNICITY` | QUASI_IDENTIFIER |
| `GENDER` | QUASI_IDENTIFIER |
| `LATITUDE` | QUASI_IDENTIFIER |
| `LAT_LONG` | QUASI_IDENTIFIER |
| `LONGITUDE` | QUASI_IDENTIFIER |
| `MARITAL_STATUS` | QUASI_IDENTIFIER |
| `MEDICAL_SPECIALTY` | QUASI_IDENTIFIER |
| `OCCUPATION` | QUASI_IDENTIFIER |
| `YEAR_OF_BIRTH` | QUASI_IDENTIFIER |

### Country-Specific Quasi-Identifiers

| Semantic Category | Countries |
|------------------|-----------|
| `ADMINISTRATIVE_AREA_1` | US (State), CA (Province), NZ (Region) |
| `ADMINISTRATIVE_AREA_2` | US (County) |
| `CITY` | US, CA, NZ |
| `POSTAL_CODE` | US, CA, AU, UK, JP, NZ, CH |

### Sensitive Information

| Semantic Category | Subcategories |
|------------------|--------------|
| `MEDICAL_DATA` | ICD_10_CODE, LAB_TEST_TERM, MEDICAL_CONDITION, MEDICAL_PROCEDURE, MEDICINE_NAME |
| `SALARY` | (no subcategory) |

---

## 5. Custom Classifiers

When your data contains sensitive information that **doesn't fit native categories** (e.g., internal employee IDs, proprietary codes), you create **custom classifiers**.

### Concept

A custom classifier uses **regular expressions** to match data patterns and column names.

### Creating a Custom Classifier

```sql
-- Step 1: Create the classifier instance
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER my_classifier();

-- Step 2: Add regex patterns for your custom category
CALL my_classifier!ADD_REGEX(
  SEMANTIC_CATEGORY => 'EMPLOYEE_ID',
  PRIVACY_CATEGORY  => 'IDENTIFIER',
  VALUE_REGEX       => '^EMP-[0-9]{6}$',       -- matches EMP-123456
  COL_NAME_REGEX    => 'EMP.*ID.*',             -- column name pattern (optional)
  DESCRIPTION       => 'Internal employee IDs',
  THRESHOLD         => 0.8                       -- 80% of values must match
);

-- Step 3: Add another custom category
CALL my_classifier!ADD_REGEX(
  SEMANTIC_CATEGORY => 'INTERNAL_PROJECT_CODE',
  PRIVACY_CATEGORY  => 'SENSITIVE',
  VALUE_REGEX       => '^PRJ-[A-Z]{2}-[0-9]{4}$',  -- matches PRJ-AB-1234
  COL_NAME_REGEX    => '.*PROJECT.*',
  DESCRIPTION       => 'Internal project codes',
  THRESHOLD         => 0.7
);

-- Step 4: Verify
SELECT my_classifier!LIST();
```

### Parameters Explained

| Parameter | Required | Description |
|-----------|----------|-------------|
| `SEMANTIC_CATEGORY` | Yes | Name for your custom category |
| `PRIVACY_CATEGORY` | Yes | IDENTIFIER, QUASI_IDENTIFIER, or SENSITIVE |
| `VALUE_REGEX` | Yes | Regex to match column VALUES |
| `COL_NAME_REGEX` | No | Regex to match COLUMN NAMES |
| `DESCRIPTION` | No | Human-readable description |
| `THRESHOLD` | No | % of values that must match (0.0 to 1.0, default 0.8) |

### Managing Custom Classifiers

```sql
-- List all categories in a classifier
SELECT my_classifier!LIST();

-- Delete a specific category
CALL my_classifier!DELETE_CATEGORY('EMPLOYEE_ID');

-- Drop the entire classifier
DROP SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER my_classifier;

-- Show all classifiers
SHOW SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER;
```

### Access Control for Custom Classifiers

```sql
-- Grant the CLASSIFICATION_ADMIN database role
GRANT DATABASE ROLE SNOWFLAKE.CLASSIFICATION_ADMIN TO ROLE my_role;

-- Grant instance-level access to others
GRANT SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER ROLE
  mydb.myschema.my_classifier!PRIVACY_USER TO ROLE data_analyst;
```

---

## 6. Classification Profiles

A **classification profile** defines HOW and WHEN automatic classification runs.

### What a Profile Controls

| Setting | Description |
|---------|-------------|
| `minimum_object_age_for_classification_days` | How old a table must be before classifying (0 = immediately) |
| `maximum_classification_validity_days` | Days before re-classifying a previously classified table |
| `auto_tag` | Whether to automatically apply tags after classification |
| `classify_views` | Whether to include views (costs more) |
| `tag_map` | Map system tags to custom user-defined tags |
| `custom_classifiers` | Include custom classifiers in the process |
| `snowflake_semantic_categories` | Limit to specific categories (instead of all) |

### Creating a Classification Profile

```sql
-- Basic profile: classify everything, auto-tag, reclassify every 30 days
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE
  my_profile(
    {
      'minimum_object_age_for_classification_days': 0,
      'maximum_classification_validity_days': 30,
      'auto_tag': true,
      'classify_views': false
    }
  );
```

### Profile with Subset of Categories

```sql
-- Only classify NAME, EMAIL, and US-specific tax identifiers
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE
  targeted_profile(
    {
      'minimum_object_age_for_classification_days': 0,
      'auto_tag': true,
      'snowflake_semantic_categories': [
        {'category': 'NAME'},
        {'category': 'EMAIL'},
        {'category': 'TAX_IDENTIFIER', 'country_codes': ['US']}
      ]
    }
  );
```

### Activating Classification on a Database

```sql
-- Set the profile on a database → all tables monitored
ALTER DATABASE my_db
  SET CLASSIFICATION_PROFILE = 'governance_db.classify_sch.my_profile';

-- Or set on a specific schema only
ALTER SCHEMA my_db.sensitive_schema
  SET CLASSIFICATION_PROFILE = 'governance_db.classify_sch.my_profile';

-- Stop classification
ALTER DATABASE my_db UNSET CLASSIFICATION_PROFILE;
```

### Modifying a Profile After Creation

```sql
-- Change auto-tag setting
CALL my_profile!SET_AUTO_TAG(true);

-- Change reclassification interval
CALL my_profile!SET_MAXIMUM_CLASSIFICATION_VALIDITY_DAYS(60);

-- Add custom classifiers
CALL my_profile!SET_CUSTOM_CLASSIFIERS({
  'employee_classifier': employee_classifier!list(),
  'project_classifier': project_classifier!list()
});

-- Describe current config
SELECT my_profile!DESCRIBE();
```

---

## 7. Auto-Tagging

When `auto_tag` is `true`, Snowflake automatically applies system tags after classification:

```sql
-- After classification runs, columns get these system tags:
SNOWFLAKE.CORE.SEMANTIC_CATEGORY = 'EMAIL'         -- on email column
SNOWFLAKE.CORE.PRIVACY_CATEGORY  = 'IDENTIFIER'    -- on email column

SNOWFLAKE.CORE.SEMANTIC_CATEGORY = 'DATE_OF_BIRTH' -- on dob column
SNOWFLAKE.CORE.PRIVACY_CATEGORY  = 'QUASI_IDENTIFIER'

SNOWFLAKE.CORE.SEMANTIC_CATEGORY = 'SALARY'        -- on salary column
SNOWFLAKE.CORE.PRIVACY_CATEGORY  = 'SENSITIVE'
```

### What Happens Without Auto-Tag

If `auto_tag` is `false`:
- Classification still runs and identifies sensitive columns
- Results are stored but NO tags are applied
- You must manually review and apply tags using SYSTEM$GET_CLASSIFICATION_RESULT

```sql
-- Get classification results without auto-tagging
CALL SYSTEM$GET_CLASSIFICATION_RESULT('mydb.myschema.employees');
-- Returns JSON with recommendations (but doesn't apply tags)
```

---

## 8. Tag Mapping

Tag mapping lets you **translate system tags into your own custom tags**. This is critical for connecting classification to tag-based masking.

### Why Tag Mapping?

System tags (`SNOWFLAKE.CORE.SEMANTIC_CATEGORY`) are read-only and managed by Snowflake. Your masking policies likely use **your own tags** (e.g., `governance.tags.pii`). Tag mapping bridges this gap.

### Defining a Tag Map

```sql
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE
  my_profile(
    {
      'minimum_object_age_for_classification_days': 0,
      'auto_tag': true,
      'tag_map': {
        'column_tag_map': [
          {
            'tag_name': 'governance_db.tags.pii',
            'tag_value': 'Highly Confidential',
            'semantic_categories': ['NAME', 'NATIONAL_IDENTIFIER', 'PASSPORT']
          },
          {
            'tag_name': 'governance_db.tags.pii',
            'tag_value': 'Confidential',
            'semantic_categories': ['EMAIL', 'PHONE_NUMBER', 'STREET_ADDRESS']
          },
          {
            'tag_name': 'governance_db.tags.pii',
            'tag_value': 'Internal',
            'semantic_categories': ['DATE_OF_BIRTH', 'AGE', 'GENDER']
          }
        ]
      }
    }
  );
```

### How Tag Mapping Works at Runtime

```
Column classified as EMAIL (IDENTIFIER)
         │
         ▼
System tags applied:
  SNOWFLAKE.CORE.SEMANTIC_CATEGORY = 'EMAIL'
  SNOWFLAKE.CORE.PRIVACY_CATEGORY = 'IDENTIFIER'
         │
         ▼ (tag_map lookup)
User-defined tag applied:
  governance_db.tags.pii = 'Confidential'
         │
         ▼ (tag-based masking policy on pii tag)
Masking policy AUTOMATICALLY PROTECTS the column!
```

### Modify Tag Map After Creation

```sql
CALL my_profile!SET_TAG_MAP(
  {
    'column_tag_map': [
      {
        'tag_name': 'governance_db.tags.data_class',
        'tag_value': 'PII',
        'semantic_categories': ['NAME', 'EMAIL', 'PHONE_NUMBER', 'NATIONAL_IDENTIFIER']
      },
      {
        'tag_name': 'governance_db.tags.data_class',
        'tag_value': 'PHI',
        'semantic_categories': ['MEDICAL_DATA']
      }
    ]
  }
);
```

---

## 9. The Full Pipeline: Classify → Tag → Mask

This is the **architect-level end-to-end pipeline** that connects everything:

```
┌──────────────────────────────────────────────────────────────────────┐
│                    FULL AUTOMATED PIPELINE                            │
│                                                                      │
│  1. CLASSIFICATION PROFILE                                          │
│     ├── Scans tables automatically                                   │
│     ├── Detects: EMAIL, NAME, SSN, SALARY, etc.                     │
│     └── Uses custom classifiers for domain-specific data            │
│                                                                      │
│  2. AUTO-TAGGING                                                    │
│     ├── System tags: SNOWFLAKE.CORE.SEMANTIC_CATEGORY               │
│     └── User tags (via tag_map): governance.tags.pii = 'PII'       │
│                                                                      │
│  3. TAG-BASED MASKING                                               │
│     ├── Masking policy assigned to tag                              │
│     └── All columns with that tag → auto-masked                    │
│                                                                      │
│  4. NEW DATA ARRIVES → Auto-classified → Auto-tagged → Auto-masked │
└──────────────────────────────────────────────────────────────────────┘
```

### Complete Example: End-to-End

```sql
-- ============================================================
-- STEP 1: Create governance infrastructure
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS governance_db;
CREATE SCHEMA IF NOT EXISTS governance_db.tags;
CREATE SCHEMA IF NOT EXISTS governance_db.policies;
CREATE SCHEMA IF NOT EXISTS governance_db.classifiers;

-- Create user-defined tag
CREATE TAG governance_db.tags.data_sensitivity;

-- ============================================================
-- STEP 2: Create masking policies (one per data type)
-- ============================================================
USE SCHEMA governance_db.policies;

CREATE OR REPLACE MASKING POLICY pii_string_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('DATA_OWNER') THEN val
    ELSE '***CLASSIFIED***'
  END;

CREATE OR REPLACE MASKING POLICY pii_number_mask
  AS (val NUMBER) RETURNS NUMBER ->
  CASE
    WHEN IS_ROLE_IN_SESSION('DATA_OWNER') THEN val
    ELSE -1
  END;

CREATE OR REPLACE MASKING POLICY pii_timestamp_mask
  AS (val TIMESTAMP_NTZ) RETURNS TIMESTAMP_NTZ ->
  CASE
    WHEN IS_ROLE_IN_SESSION('DATA_OWNER') THEN val
    ELSE DATE_FROM_PARTS(1900, 01, 01)::TIMESTAMP_NTZ
  END;

-- ============================================================
-- STEP 3: Assign masking policies to the tag
-- ============================================================
ALTER TAG governance_db.tags.data_sensitivity SET
  MASKING POLICY governance_db.policies.pii_string_mask,
  MASKING POLICY governance_db.policies.pii_number_mask,
  MASKING POLICY governance_db.policies.pii_timestamp_mask;

-- ============================================================
-- STEP 4: Create custom classifier (optional, for internal data)
-- ============================================================
USE SCHEMA governance_db.classifiers;

CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CUSTOM_CLASSIFIER internal_ids();

CALL internal_ids!ADD_REGEX(
  SEMANTIC_CATEGORY => 'EMPLOYEE_ID',
  PRIVACY_CATEGORY  => 'IDENTIFIER',
  VALUE_REGEX       => '^EMP-[0-9]{6}$',
  COL_NAME_REGEX    => '.*EMP.*ID.*',
  DESCRIPTION       => 'Internal employee identifier',
  THRESHOLD         => 0.8
);

-- ============================================================
-- STEP 5: Create classification profile with tag mapping
-- ============================================================
CREATE OR REPLACE SNOWFLAKE.DATA_PRIVACY.CLASSIFICATION_PROFILE
  governance_db.classifiers.auto_classify_profile(
    {
      'minimum_object_age_for_classification_days': 0,
      'maximum_classification_validity_days': 30,
      'auto_tag': true,
      'classify_views': false,
      'tag_map': {
        'column_tag_map': [
          {
            'tag_name': 'governance_db.tags.data_sensitivity',
            'tag_value': 'PII',
            'semantic_categories': ['NAME', 'EMAIL', 'NATIONAL_IDENTIFIER',
                                    'PHONE_NUMBER', 'PASSPORT', 'DRIVERS_LICENSE',
                                    'PAYMENT_CARD', 'BANK_ACCOUNT', 'EMPLOYEE_ID']
          },
          {
            'tag_name': 'governance_db.tags.data_sensitivity',
            'tag_value': 'QUASI_PII',
            'semantic_categories': ['DATE_OF_BIRTH', 'AGE', 'GENDER',
                                    'CITY', 'POSTAL_CODE', 'ETHNICITY']
          },
          {
            'tag_name': 'governance_db.tags.data_sensitivity',
            'tag_value': 'SENSITIVE',
            'semantic_categories': ['SALARY', 'MEDICAL_DATA']
          }
        ]
      },
      'custom_classifiers': {
        'internal_ids': internal_ids!list()
      }
    }
  );

-- ============================================================
-- STEP 6: Activate on target database
-- ============================================================
ALTER DATABASE hr_database
  SET CLASSIFICATION_PROFILE = 'governance_db.classifiers.auto_classify_profile';

-- ============================================================
-- RESULT: 
-- All tables in hr_database are now:
--   → Automatically scanned for sensitive data
--   → Tagged with system + user-defined tags
--   → Masked via tag-based masking policies
--   → New tables added later get the same treatment
-- ============================================================
```

---

## 10. Hands-On: Step-by-Step Implementation

### Manual Classification (Testing / One-Off)

```sql
-- Classify a single table (returns JSON, no tags applied)
CALL SYSTEM$CLASSIFY('mydb.myschema.employees', NULL);

-- Classify with a profile (applies tags if auto_tag=true)
CALL SYSTEM$CLASSIFY('mydb.myschema.employees', 'governance_db.classifiers.my_profile');

-- Classify an entire schema
CALL SYSTEM$CLASSIFY_SCHEMA('mydb.myschema', NULL);
```

### View Classification Results

```sql
-- Get results for a specific table
CALL SYSTEM$GET_CLASSIFICATION_RESULT('mydb.myschema.employees');
```

Returns JSON like:
```json
{
  "EMAIL_COL": {
    "recommendation": {
      "semantic_category": "EMAIL",
      "privacy_category": "IDENTIFIER",
      "confidence": "HIGH",
      "coverage": 0.98
    }
  },
  "FIRST_NAME": {
    "recommendation": {
      "semantic_category": "NAME",
      "privacy_category": "IDENTIFIER",
      "confidence": "HIGH",
      "coverage": 1.0
    }
  }
}
```

### Verify Tags Were Applied

```sql
-- Check tags on a specific table
SELECT *
FROM TABLE(
  INFORMATION_SCHEMA.TAG_REFERENCES(
    'mydb.myschema.employees', 'TABLE'
  )
);

-- Account-wide: all classified columns
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TAG_REFERENCES
WHERE TAG_NAME IN ('SEMANTIC_CATEGORY', 'PRIVACY_CATEGORY')
ORDER BY OBJECT_NAME, COLUMN_NAME;
```

---

## 11. Monitoring & Auditing Classification

### Which Databases Are Being Monitored?

```sql
SELECT SYSTEM$SHOW_SENSITIVE_DATA_MONITORED_ENTITIES('DATABASE');
```

### Snowsight Trust Center

Navigate to: **Governance & Security → Trust Center → Data Security**

- View databases monitored
- See classification errors
- Review sensitivity coverage

### Check Classification Costs

```sql
-- Hourly credit consumption
SELECT service_type, start_time, end_time, credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_HISTORY
WHERE service_type = 'SENSITIVE_DATA_CLASSIFICATION'
ORDER BY start_time DESC;

-- Daily consumption
SELECT usage_date, credits_used
FROM SNOWFLAKE.ACCOUNT_USAGE.METERING_DAILY_HISTORY
WHERE service_type = 'SENSITIVE_DATA_CLASSIFICATION'
ORDER BY usage_date DESC;
```

---

## 12. Cost Considerations

| Factor | Impact |
|--------|--------|
| Number of tables | More tables = more compute |
| Number of columns | More columns per table = more compute |
| Classification frequency | Lower `maximum_classification_validity_days` = more frequent re-scans |
| Views | Classifying views costs MORE than tables (query complexity) |
| `minimum_object_age_for_classification_days = 0` | New tables classified immediately (more frequent processing) |

### Cost Optimization Tips:
1. Set `classify_views: false` unless you need view classification
2. Use `snowflake_semantic_categories` to only classify categories you care about
3. Increase `maximum_classification_validity_days` for stable tables
4. Set `minimum_object_age_for_classification_days` > 0 for staging databases

---

## 13. Limitations

| Limitation | Details |
|-----------|---------|
| Edition | Enterprise Edition or higher required |
| Max databases per profile | 1,000 |
| Max schemas per profile (direct) | 10,000 |
| Max tables per schema | 100 million |
| Max columns per table | 10,000 |
| Column name length | Max 255 characters |
| Column name characters | Cannot contain `$` |
| Shared tables | Classification only works from provider side |
| Unsupported data types | BINARY, DECFLOAT, GEOGRAPHY, UUID, VECTOR |
| Semi-structured | Only JSON is supported |
| Unstructured text | Long text columns not supported |
| Delay | 1 hour between setting profile and first classification |

---

## Summary: How Classification Powers Masking

```
WITHOUT Classification:
  DBA manually identifies 500 PII columns across 100 tables
  DBA manually runs ALTER TABLE ... SET MASKING POLICY for each column
  New tables added → unprotected until someone remembers to mask

WITH Classification:
  Classification profile scans ALL tables automatically
  Tags applied automatically to sensitive columns
  Tag-based masking policies auto-protect ALL tagged columns
  New tables → classified → tagged → masked — ZERO manual work

The key insight:
  CLASSIFICATION + TAG MAPPING + TAG-BASED MASKING = AUTOMATED DATA PROTECTION
```
