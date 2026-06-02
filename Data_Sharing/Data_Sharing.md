# Snowflake Data Sharing: Complete Guide

## Table of Contents
1. [Sharing Options Overview](#sharing-options-overview)
2. [Sharing with Snowflake Users (Same Region)](#sharing-with-snowflake-users-same-region)
3. [Sharing with Snowflake Users (Different Region)](#sharing-with-snowflake-users-different-region)
4. [Sharing with Non-Snowflake Users](#sharing-with-non-snowflake-users)
5. [Sharing Files (Unstructured Data)](#sharing-files-unstructured-data)
6. [Shareable Objects](#shareable-objects)
7. [Step-by-Step Examples](#step-by-step-examples)

---

## Sharing Options Overview

Snowflake provides multiple mechanisms to share data:

| Method | Target Audience | Cross-Region? | Charge for Data? |
|--------|----------------|---------------|-----------------|
| **Direct Share** | Snowflake accounts (same region) | No | No |
| **Listing (Private)** | Specific Snowflake accounts (any region) | Yes (auto-fulfillment) | Optional |
| **Listing (Marketplace)** | Any Snowflake user (public) | Yes (auto-fulfillment) | Optional |
| **Reader Account** | Non-Snowflake users | No (same region as provider) | No |
| **Replication Group** | Snowflake accounts (cross-region) | Yes (manual) | No |

### Key Concept: Zero-Copy Sharing

Snowflake's Secure Data Sharing does NOT copy or move data. It shares metadata pointers. This means:
- No storage cost for consumers
- Real-time access to latest data
- Provider retains full control
- Consumers only pay for compute (warehouse) to query

---

## Sharing with Snowflake Users (Same Region)

### What is a Direct Share?

A Direct Share allows you to share specific database objects with one or more Snowflake accounts **in the same region**.

### How It Works:
```
┌──────────────────┐                    ┌──────────────────┐
│  PROVIDER ACCT   │                    │  CONSUMER ACCT   │
│  (Same Region)   │                    │  (Same Region)   │
│                  │                    │                  │
│  Database ──────►│───── SHARE ───────►│  Imported DB     │
│  Tables          │  (metadata only)   │  (read-only)     │
│  Views           │                    │                  │
│  UDFs            │                    │                  │
└──────────────────┘                    └──────────────────┘
```

### Step-by-Step: Create a Direct Share

```sql
-- Step 1: Use ACCOUNTADMIN role (required for sharing)
USE ROLE ACCOUNTADMIN;

-- Step 2: Create a share (empty container)
CREATE SHARE my_share
  COMMENT = 'Sharing sales data with partner';

-- Step 3: Grant USAGE on the database to the share
GRANT USAGE ON DATABASE sales_db TO SHARE my_share;

-- Step 4: Grant USAGE on the schema
GRANT USAGE ON SCHEMA sales_db.public TO SHARE my_share;

-- Step 5: Grant SELECT on specific objects (tables, views, etc.)
GRANT SELECT ON TABLE sales_db.public.orders TO SHARE my_share;
GRANT SELECT ON VIEW sales_db.public.revenue_summary TO SHARE my_share;

-- Step 6: Add consumer accounts to the share
ALTER SHARE my_share ADD ACCOUNTS = org1.consumer_account1, org1.consumer_account2;

-- Step 7: Verify the share
SHOW GRANTS TO SHARE my_share;
SHOW GRANTS OF SHARE my_share;
```

### Consumer Side: Access the Shared Data

```sql
-- Consumer runs this in their account:
USE ROLE ACCOUNTADMIN;

-- See available shares
SHOW SHARES;

-- Describe a specific share
DESC SHARE provider_org.provider_acct.my_share;

-- Create a database from the share
CREATE DATABASE shared_sales_db FROM SHARE provider_org.provider_acct.my_share;

-- Grant access to other roles in your account
GRANT IMPORTED PRIVILEGES ON DATABASE shared_sales_db TO ROLE analyst_role;

-- Now analysts can query
USE ROLE analyst_role;
SELECT * FROM shared_sales_db.public.orders;
```

---

## Sharing with Snowflake Users (Different Region)

When the consumer is in a **different cloud region** (e.g., provider in AWS US-East, consumer in Azure Europe), you have two options:

### Option 1: Listings with Cross-Cloud Auto-Fulfillment (Recommended)

Listings automatically replicate data to the consumer's region. This is the simplest approach.

```sql
-- Provider creates a share and then a listing via Snowsight UI:
-- Snowsight → Marketplace → Provider Studio → Create Listing → Specified Consumers

-- Or via SQL:
CREATE SHARE cross_region_share;
GRANT USAGE ON DATABASE analytics_db TO SHARE cross_region_share;
GRANT USAGE ON SCHEMA analytics_db.public TO SHARE cross_region_share;
GRANT SELECT ON TABLE analytics_db.public.metrics TO SHARE cross_region_share;

-- Create listing (typically done in Snowsight UI)
-- When you add a consumer in a different region, auto-fulfillment kicks in
-- Data is replicated automatically to the consumer's region
```

### Option 2: Manual Replication Groups

For more control, you can manually replicate databases and shares.

```sql
-- ============ SOURCE ACCOUNT (Provider) ============
USE ROLE ACCOUNTADMIN;

-- Create a replication group with databases and shares
CREATE REPLICATION GROUP my_rg
  OBJECT_TYPES = DATABASES, SHARES
  ALLOWED_DATABASES = sales_db
  ALLOWED_SHARES = my_share
  ALLOWED_ACCOUNTS = my_org.target_account;

-- ============ TARGET ACCOUNT (Different Region) ============
USE ROLE ACCOUNTADMIN;

-- Create a secondary (replica) replication group
CREATE REPLICATION GROUP my_rg
  AS REPLICA OF my_org.source_account.my_rg;

-- Refresh to pull latest data
ALTER REPLICATION GROUP my_rg REFRESH;

-- Add local consumer accounts to the replicated share
ALTER SHARE my_share ADD ACCOUNTS = consumer_org.consumer_account;
```

### Auto-Refresh Schedule (Optional)

```sql
-- Set up automatic refresh every 10 minutes
ALTER REPLICATION GROUP my_rg SET REPLICATION_SCHEDULE = '10 MINUTE';
```

---

## Sharing with Non-Snowflake Users

Non-Snowflake users don't have their own Snowflake account. To share data with them, you create a **Reader Account**.

### What is a Reader Account?

- A **managed account** created and owned by the provider
- The provider pays for all compute costs
- Consumer can ONLY query shared data (no loading, no writes)
- Limited functionality (no INSERT, UPDATE, DELETE, CREATE PIPE, etc.)
- Can only consume data from the provider that created it

### Restrictions in a Reader Account:
- Cannot upload or modify data
- Cannot create stages, pipes, or streams
- Cannot create shares (no re-sharing)
- Cannot use storage integrations for unloading
- All credit consumption is billed to the provider

### Step-by-Step: Create a Reader Account and Share Data

```sql
-- Step 1: Create the reader account
USE ROLE ACCOUNTADMIN;

CREATE MANAGED ACCOUNT reader_partner1
  ADMIN_NAME = 'partner_admin',
  ADMIN_PASSWORD = 'SecurePassword123!',
  TYPE = READER;

-- This returns: account name, locator, and login URL
-- Example output:
-- {"accountName":"READER_PARTNER1","url":"https://myorg-reader_partner1.snowflakecomputing.com"}

-- Step 2: Create a share (if not already created)
CREATE SHARE partner_share;
GRANT USAGE ON DATABASE analytics_db TO SHARE partner_share;
GRANT USAGE ON SCHEMA analytics_db.public TO SHARE partner_share;
GRANT SELECT ON TABLE analytics_db.public.report_data TO SHARE partner_share;

-- Step 3: Add the reader account to the share
-- First, find the reader account's locator
SHOW MANAGED ACCOUNTS;

-- Add it to the share
ALTER SHARE partner_share ADD ACCOUNTS = <reader_account_locator>;

-- Step 4: (Optional) Set up a resource monitor to limit costs
-- Since you pay for the reader account's compute
CREATE RESOURCE MONITOR reader_monitor
  WITH CREDIT_QUOTA = 100
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 75 PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;
```

### Configure the Reader Account (Provider does this)

```sql
-- Log into the reader account (using the URL from Step 1)
-- Then configure it:

-- Create a warehouse for the reader account users
CREATE WAREHOUSE reader_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE;

-- Create a database from the share
CREATE DATABASE shared_data FROM SHARE <provider_account>.partner_share;

-- Create roles and users for the non-Snowflake partner
CREATE ROLE partner_role;
GRANT IMPORTED PRIVILEGES ON DATABASE shared_data TO ROLE partner_role;
GRANT USAGE ON WAREHOUSE reader_wh TO ROLE partner_role;

CREATE USER partner_user
  PASSWORD = 'UserPassword123!'
  DEFAULT_ROLE = partner_role
  DEFAULT_WAREHOUSE = reader_wh;

GRANT ROLE partner_role TO USER partner_user;
```

### How the Non-Snowflake User Accesses Data

The non-Snowflake user:
1. Logs into the reader account URL provided by the provider
2. Uses their assigned username/password
3. Can query the shared data (read-only)
4. Cannot load, modify, or export data (unless using COPY INTO with direct credentials)

---

## Sharing Files (Unstructured Data)

### Can You Share Files from Stages?

**YES!** You can share files (PDFs, images, CSVs, videos, etc.) stored in Snowflake stages using **Secure Views** combined with **Scoped URLs** or **Pre-signed URLs**.

### Important Concepts:

| Concept | Description |
|---------|-------------|
| **Internal Stage** | Files stored within Snowflake's managed storage |
| **Directory Table** | Metadata catalog of files on a stage (lists file paths, sizes, etc.) |
| **Scoped URL** | Temporary URL requiring Snowflake authentication to access the file |
| **Pre-signed URL** | Temporary URL that allows access WITHOUT authentication (has expiration) |
| **BUILD_SCOPED_FILE_URL()** | Function to generate scoped URLs |
| **GET_PRESIGNED_URL()** | Function to generate pre-signed URLs |

### How File Sharing Works:

```
┌─────────────────────────────────┐
│        PROVIDER ACCOUNT         │
│                                 │
│  @mystage/                      │
│  ├── invoices/inv001.pdf        │
│  ├── invoices/inv002.pdf        │
│  ├── images/product1.jpg        │
│  └── reports/q1_report.pdf      │
│                                 │
│  DIRECTORY TABLE (metadata)     │
│  ┌────────────────────────────┐ │
│  │ RELATIVE_PATH | SIZE | ... │ │
│  │ invoices/inv001.pdf | 2MB  │ │
│  │ invoices/inv002.pdf | 1MB  │ │
│  └────────────────────────────┘ │
│                                 │
│  SECURE VIEW (generates URLs)   │
│  ──────────── SHARE ───────────►│───► CONSUMER
└─────────────────────────────────┘
```

### Step-by-Step: Share Files

```sql
-- ============ PROVIDER ACCOUNT ============
USE ROLE SYSADMIN;

-- Step 1: Create a stage with a directory table enabled
CREATE OR REPLACE STAGE my_file_stage
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

-- Step 2: Upload files to the stage (via Snowsight UI, SnowSQL, or PUT)
-- PUT file:///local/path/document.pdf @my_file_stage/documents/;

-- Step 3: Refresh the directory table to register files
ALTER STAGE my_file_stage REFRESH;

-- Step 4: Verify files are listed
SELECT * FROM DIRECTORY(@my_file_stage);

-- Step 5: Create a secure view using SCOPED URLs (more secure)
CREATE OR REPLACE SECURE VIEW shared_files_scoped AS
SELECT
  RELATIVE_PATH,
  SIZE,
  LAST_MODIFIED,
  BUILD_SCOPED_FILE_URL(@my_file_stage, RELATIVE_PATH) AS file_url
FROM DIRECTORY(@my_file_stage);

-- OR: Create a secure view using PRE-SIGNED URLs (accessible without auth)
CREATE OR REPLACE SECURE VIEW shared_files_presigned AS
SELECT
  RELATIVE_PATH,
  SIZE,
  LAST_MODIFIED,
  GET_PRESIGNED_URL(@my_file_stage, RELATIVE_PATH, 3600) AS file_url  -- expires in 1 hour
FROM DIRECTORY(@my_file_stage);

-- Step 6: Create a share and grant access
USE ROLE ACCOUNTADMIN;

CREATE SHARE file_share;
GRANT USAGE ON DATABASE my_db TO SHARE file_share;
GRANT USAGE ON SCHEMA my_db.public TO SHARE file_share;
GRANT SELECT ON VIEW my_db.public.shared_files_scoped TO SHARE file_share;

-- Step 7: Add consumer accounts
ALTER SHARE file_share ADD ACCOUNTS = consumer_org.consumer_account;
```

### Share Only a Subset of Files

```sql
-- Share only files for a specific client
CREATE OR REPLACE SECURE VIEW client_abc_files AS
SELECT
  BUILD_SCOPED_FILE_URL(@my_file_stage, d.RELATIVE_PATH) AS file_url,
  d.RELATIVE_PATH,
  d.SIZE
FROM DIRECTORY(@my_file_stage) d
JOIN client_file_mapping c ON d.RELATIVE_PATH = c.file_path
WHERE c.client_name = 'ABC';
```

### Consumer Side: Access Shared Files

```sql
-- Consumer creates database from share
CREATE DATABASE shared_files FROM SHARE provider_org.provider_acct.file_share;
GRANT IMPORTED PRIVILEGES ON DATABASE shared_files TO ROLE analyst_role;

-- Query file URLs
USE ROLE analyst_role;
SELECT * FROM shared_files.public.shared_files_scoped;

-- The file_url column contains URLs that can be:
-- - Opened in a browser (pre-signed URLs)
-- - Used in Snowpark/Python for processing
-- - Downloaded programmatically
```

### Scoped URL vs Pre-signed URL

| Feature | Scoped URL | Pre-signed URL |
|---------|-----------|----------------|
| Authentication required | Yes (Snowflake session) | No |
| Expiration | Tied to session | Configurable (seconds) |
| Security | Higher (requires login) | Lower (anyone with URL can access) |
| Use case | Internal Snowflake users | External apps, non-Snowflake users |
| Function | `BUILD_SCOPED_FILE_URL()` | `GET_PRESIGNED_URL()` |

---

## Shareable Objects

The following objects can be shared via Snowflake Secure Data Sharing:

| Object Type | Shareable? | Notes |
|------------|-----------|-------|
| Databases | Yes | Required for every share |
| Tables | Yes | Including dynamic tables, external tables, Iceberg tables |
| Views (Secure) | Yes | Recommended for controlled access |
| Materialized Views (Secure) | Yes | Must be secure |
| Semantic Views | Yes | — |
| UDFs (Secure) | Yes | User-defined functions |
| Cortex Search Services | Yes | — |
| Models | Yes | USER_MODEL, CORTEX_FINETUNED, DOC_AI types |
| Stages (directly) | **No** | Use secure views with URLs instead |
| Streams | **No** | Consumers create their own streams on shared objects |
| Pipes | **No** | — |
| Tasks | **No** | — |
| Stored Procedures | **No** | — |

---

## Step-by-Step Examples

### Example 1: Full Workflow — Share Table with Same-Region Snowflake User

```sql
-- ===== PROVIDER =====
USE ROLE ACCOUNTADMIN;

-- Create share
CREATE SHARE sales_share COMMENT = 'Monthly sales data';

-- Add objects
GRANT USAGE ON DATABASE SALES_DB TO SHARE sales_share;
GRANT USAGE ON SCHEMA SALES_DB.ANALYTICS TO SHARE sales_share;
GRANT SELECT ON TABLE SALES_DB.ANALYTICS.MONTHLY_REVENUE TO SHARE sales_share;
GRANT SELECT ON VIEW SALES_DB.ANALYTICS.TOP_PRODUCTS TO SHARE sales_share;

-- Add consumer
ALTER SHARE sales_share ADD ACCOUNTS = partner_org.partner_acct;

-- Verify
SHOW GRANTS TO SHARE sales_share;
```

### Example 2: Share with Non-Snowflake User via Reader Account

```sql
-- ===== PROVIDER =====
USE ROLE ACCOUNTADMIN;

-- 1. Create reader account
CREATE MANAGED ACCOUNT external_partner
  ADMIN_NAME = 'ext_admin',
  ADMIN_PASSWORD = 'Str0ngP@ss!',
  TYPE = READER;

-- 2. Create and populate share
CREATE SHARE external_share;
GRANT USAGE ON DATABASE REPORTS_DB TO SHARE external_share;
GRANT USAGE ON SCHEMA REPORTS_DB.PUBLIC TO SHARE external_share;
GRANT SELECT ON VIEW REPORTS_DB.PUBLIC.PARTNER_DASHBOARD TO SHARE external_share;

-- 3. Get reader account locator
SHOW MANAGED ACCOUNTS;
-- Note the locator value, e.g., 'AB12345'

-- 4. Add reader account to share
ALTER SHARE external_share ADD ACCOUNTS = AB12345;

-- 5. Now log into the reader account and configure it for end users
-- (Create warehouse, database from share, roles, users)
```

### Example 3: Share Files (PDFs/Images) with Another Account

```sql
-- ===== PROVIDER =====
USE ROLE SYSADMIN;

-- Setup stage with directory table
CREATE STAGE doc_stage DIRECTORY = (ENABLE = TRUE);
-- Upload files...
ALTER STAGE doc_stage REFRESH;

-- Create secure view
CREATE SECURE VIEW shared_documents AS
SELECT
  RELATIVE_PATH AS document_name,
  SIZE AS file_size_bytes,
  LAST_MODIFIED,
  BUILD_SCOPED_FILE_URL(@doc_stage, RELATIVE_PATH) AS download_url
FROM DIRECTORY(@doc_stage)
WHERE RELATIVE_PATH LIKE '%.pdf';

-- Share it
USE ROLE ACCOUNTADMIN;
CREATE SHARE document_share;
GRANT USAGE ON DATABASE MY_DB TO SHARE document_share;
GRANT USAGE ON SCHEMA MY_DB.PUBLIC TO SHARE document_share;
GRANT SELECT ON VIEW MY_DB.PUBLIC.shared_documents TO SHARE document_share;
ALTER SHARE document_share ADD ACCOUNTS = consumer_org.consumer_acct;
```

---

## Summary Decision Tree

```
Do you want to share data?
│
├── Is the consumer a Snowflake user?
│   ├── YES → Are they in the SAME region?
│   │   ├── YES → Use DIRECT SHARE
│   │   └── NO  → Use LISTING (auto-fulfillment) or REPLICATION GROUP
│   └── NO  → Create a READER ACCOUNT
│
└── Do you want to share FILES (not just tables)?
    ├── YES → Create SECURE VIEW with BUILD_SCOPED_FILE_URL or GET_PRESIGNED_URL
    │         on a DIRECTORY TABLE, then share the view
    └── NO  → Share tables/views directly via SHARE
```

---

## Key Takeaways

1. **Same Region, Snowflake User** → Direct Share (simplest, zero-copy)
2. **Different Region, Snowflake User** → Listing with Auto-Fulfillment (data replicates automatically)
3. **Non-Snowflake User** → Reader Account (provider pays compute costs)
4. **Sharing Files** → YES, possible! Use Secure Views + Scoped/Pre-signed URLs over Directory Tables
5. **Stages cannot be shared directly** — but their files can be accessed via secure views
6. **All shared data is read-only** for consumers
