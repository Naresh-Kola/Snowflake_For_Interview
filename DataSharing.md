# Snowflake Data Sharing — Complete Guide

> Definition | Architecture | Direct Shares | Listings | Marketplace | Secure Views | Reader Accounts | Cross-Region | Interview Questions | From Scratch to Architect Level

---

## Table of Contents

- [Part 1: What is Data Sharing?](#part-1-what-is-data-sharing)
- [Part 2: Internal Architecture — How It Works](#part-2-internal-architecture--how-it-works)
- [Part 3: Sharing Options — Direct Share vs Listing vs Data Exchange](#part-3-sharing-options--direct-share-vs-listing-vs-data-exchange)
- [Part 4: Direct Share — Step-by-Step with SQL](#part-4-direct-share--step-by-step-with-sql)
- [Part 5: Secure Views — The Backbone of Safe Data Sharing](#part-5-secure-views--the-backbone-of-safe-data-sharing)
- [Part 6: Reader Accounts — Sharing with Non-Snowflake Users](#part-6-reader-accounts--sharing-with-non-snowflake-users)
- [Part 7: Sharing Management Commands (SQL Reference)](#part-7-sharing-management-commands-sql-reference)
- [Part 8: Cross-Region & Cross-Cloud Sharing](#part-8-cross-region--cross-cloud-sharing)
- [Part 9: Billing & Cost Model](#part-9-billing--cost-model)
- [Part 10: Best Practices & Gotchas](#part-10-best-practices--gotchas)
- [Part 11: Practical Scenarios with Executable SQL](#part-11-practical-scenarios-with-executable-sql)
- [Part 12: Interview Questions — Level 1: Beginner](#part-12-interview-questions--level-1-beginner)
- [Part 13: Interview Questions — Level 2: Intermediate](#part-13-interview-questions--level-2-intermediate)
- [Part 14: Interview Questions — Level 3: Advanced](#part-14-interview-questions--level-3-advanced)
- [Part 15: Interview Questions — Level 4: Architect](#part-15-interview-questions--level-4-architect)
- [Part 16: Quick Reference Cheat Sheet](#part-16-quick-reference-cheat-sheet)

---

## Part 1: What is Data Sharing?

### 1.1 Definition

Secure Data Sharing lets you share selected objects in a database with OTHER Snowflake accounts — without copying, moving, or transferring any data.

The data stays in the PROVIDER's account. Consumers get READ-ONLY access to a live, always-current view of the shared data using their OWN compute.

**Key Facts:**
- NO data is copied or moved — zero storage cost for consumers
- Consumers pay ONLY for compute (warehouse) to query shared data
- Shared objects are READ-ONLY (consumers cannot modify them)
- Changes by the provider are INSTANTLY visible to consumers
- Access can be revoked at any time by the provider
- Sharing is done via SHARES — named Snowflake objects
- Works within the same region (direct share) or across regions (listings)

**Shareable Objects:**
- Databases, Schemas, Tables (standard, dynamic, external, Iceberg)
- Views (regular, secure, secure materialized, semantic)
- User-Defined Functions (UDFs) — secure and non-secure
- Cortex Search services, Models (USER_MODEL, CORTEX_FINETUNED, DOC_AI)

**Analogy:** Imagine a library (provider) that lets other libraries (consumers) see their catalog and read their books — but the books NEVER leave the original library. There's no photocopying, no shipping. The other libraries just get a window into the originals. If a book is updated, everyone sees the update instantly. The provider can close the window at any time.

---

### 1.2 Why Use Data Sharing?

**WITHOUT data sharing (the old way):**
1. ETL/ELT pipelines to copy data between accounts → expensive, slow
2. FTP / S3 / API exports → stale data, security risks
3. Database replication → storage duplication, sync lag
4. Email CSV files → manual, error-prone, no governance
5. Each consumer maintains their own copy → data drift, inconsistency

**WITH data sharing:**
1. Zero-copy: No data duplication, no storage cost for consumers
2. Real-time: Changes are instantly visible, always fresh
3. Secure: Role-based access, secure views, row-level filtering
4. Governed: Provider controls what's shared and with whom
5. Scalable: Share with 1 or 1,000 accounts, same effort
6. No infrastructure: No pipelines, no ETL, no APIs to maintain

---

### 1.3 Providers vs Consumers

**PROVIDER:** The account that CREATES the share and OWNS the data.
- Creates a SHARE object
- Grants access to specific databases, schemas, tables, views
- Adds consumer accounts to the share
- Controls what data is visible (via secure views)
- Can revoke access at any time
- Pays for STORAGE of the data

**CONSUMER:** The account that RECEIVES and QUERIES the shared data.
- Creates a DATABASE from the share (read-only)
- Queries shared data using their OWN warehouse
- Pays for COMPUTE only (no storage cost)
- Cannot modify shared data (read-only)
- Can join shared data with their own local data

**BOTH ROLES:** Any Snowflake account can be BOTH a provider AND a consumer.

---

## Part 2: Internal Architecture — How It Works

### 2.1 Zero-Copy Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  PROVIDER ACCOUNT                                                  │
│                                                                    │
│  ┌──────────────────┐   ┌──────────────────────────────────────┐  │
│  │  Database: mydb  │   │  SHARE: my_share                     │  │
│  │                  │   │                                      │  │
│  │  Schema: public  │──→│  GRANT USAGE ON DATABASE mydb        │  │
│  │  Table: orders   │   │  GRANT USAGE ON SCHEMA mydb.public   │  │
│  │  View: sv_orders │   │  GRANT SELECT ON VIEW sv_orders      │  │
│  └──────────────────┘   │                                      │  │
│                         │  Accounts: CONSUMER_ACCT_1,          │  │
│  Storage Layer:         │            CONSUMER_ACCT_2           │  │
│  [Micro-partitions]     └──────────────────────────────────────┘  │
│  (data lives HERE)                     │                          │
└────────────────────────────────────────┼──────────────────────────┘
                                         │ Metadata pointer
                                         │ (NO data movement)
                                         ▼
┌────────────────────────────────────────────────────────────────────┐
│  CONSUMER ACCOUNT                                                  │
│                                                                    │
│  CREATE DATABASE shared_db FROM SHARE provider_acct.my_share;     │
│                                                                    │
│  ┌──────────────────────┐                                          │
│  │  Database: shared_db │  ← Read-only. Points to provider's data │
│  │  View: sv_orders     │  ← Queries use CONSUMER's warehouse     │
│  └──────────────────────┘                                          │
│                                                                    │
│  SELECT * FROM shared_db.public.sv_orders;                        │
│  → Reads provider's micro-partitions directly                      │
│  → Consumer pays for compute, NOT storage                          │
└────────────────────────────────────────────────────────────────────┘
```

**KEY:** The consumer's database is a METADATA-ONLY pointer. No micro-partitions are copied. The consumer's warehouse reads the provider's storage layer directly via Snowflake's services layer.

---

### 2.2 What is a SHARE?

A SHARE is a named Snowflake object that encapsulates:
1. A database reference
2. Granted privileges on specific objects (schemas, tables, views, UDFs)
3. A list of consumer accounts that can access the share

A share is NOT a copy of data. It's a METADATA CONTAINER that tells Snowflake: "These accounts can read these objects in this database."

**Rules:**
- One share can include objects from ONE database (or multiple via database roles)
- Multiple shares can reference the same database
- A consumer can only create ONE database per share
- Shares are created by ACCOUNTADMIN (or role with CREATE SHARE)

---

## Part 3: Sharing Options — Direct Share vs Listing vs Data Exchange

### 3.1 Comparison Table

| Feature | Direct Share | Listing (Private) | Listing (Public Marketplace) |
|---------|-------------|-------------------|------------------------------|
| Share with whom? | Same region only | Any region/cloud | Anyone on Marketplace |
| Cross-cloud/region? | No | Yes (auto-fulfill) | Yes |
| Charge for data? | No | Yes (paid listings) | Yes |
| Offer publicly? | No | No (private only) | Yes |
| Consumer metrics? | No | Yes | Yes |
| Metadata (title, description)? | No | Yes | Yes |
| Setup complexity | Simple (SQL) | Medium (Snowsight) | High (approval) |

---

### 3.2 Data Exchange — Private Marketplace for a Group

**What Is It?**

A Data Exchange is a PRIVATE, invite-only marketplace managed by one Snowflake account (the Data Exchange Admin). It provides a data hub where a selected group of members (accounts) can publish and discover data listings among themselves.

**Think Of It As:** A "members-only club" for data sharing. Only invited accounts can participate. The admin controls who joins, who can publish, and who can consume. It's like having your own private Snowflake Marketplace just for your organization or partner network.

**When to Use a Data Exchange:**
- Internal departments sharing data within a large enterprise
- Industry consortiums (e.g., healthcare providers sharing anonymized data)
- Vendor/supplier networks (e.g., retailer sharing inventory with suppliers)
- Regulated industries where sharing must be tightly controlled and audited
- When you need a CATALOG of available datasets for your group

**When NOT to Use:**
- Sharing with 1-2 accounts → use a Direct Share (simpler)
- Sharing publicly → use Snowflake Marketplace (listings)
- One-time data transfer → use a Direct Share

**Key Facts:**
- Must be provisioned by Snowflake Support (not self-service)
- One account acts as DATA EXCHANGE ADMIN
- Admin invites members and assigns roles: PROVIDER, CONSUMER, or BOTH
- Members publish LISTINGS within the exchange
- Listings can be FREE or PERSONALIZED (request-based access)
- Admin can review and approve/deny listings before they go live
- Consumer usage metrics are available to providers
- Supports cross-region via auto-fulfillment (like regular listings)

**Roles in a Data Exchange:**

| Role | What they can do |
|------|-----------------|
| Data Exchange Admin (one account) | Create exchange, invite/remove members, assign roles, approve listings & profiles, delegate admin |
| Provider (invited member) | Create listings, publish data, define access rules (free or personalized) |
| Consumer (invited member) | Browse listings, request/get data, create database from share, query data |
| Provider + Consumer (dual role) | Can do both: publish AND consume listings |

**How It Works (Step-by-Step):**

```
STEP 1: SETUP (one-time, by Snowflake Support)
  Company contacts Snowflake Support → Data Exchange provisioned
  One account designated as Data Exchange Admin

STEP 2: ADMIN INVITES MEMBERS (Snowsight UI)
  Snowsight → Data Sharing → External Sharing → Manage Exchanges
  → Select Exchange → Members → Add Member
  → Enter account name → Assign role (Provider/Consumer/Both)

STEP 3: PROVIDER PUBLISHES A LISTING
  Provider creates a share (SQL), then wraps it as a listing
  in the Data Exchange via Snowsight

STEP 4: CONSUMER DISCOVERS AND ACCESSES DATA
  Snowsight → Data Sharing → Shared With You → Browse Exchange
  → Find listing → Click "Get" (free) or "Request" (personalized)
  → Create database from the share → Query using own warehouse
```

**Architecture Visual:**

```
┌─────────────────────────────────────────────────────────────┐
│              DATA EXCHANGE (Private Hub)                     │
│              Admin: HEADQUARTERS_ACCT                        │
│                                                             │
│   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│   │  FINANCE     │  │  ANALYTICS   │  │  HR          │    │
│   │  (Provider)  │  │  (Both)      │  │  (Provider)  │    │
│   │              │  │              │  │              │    │
│   │ Publishes:   │  │ Publishes:   │  │ Publishes:   │    │
│   │ • Revenue    │  │ • KPIs       │  │ • Headcount  │    │
│   │ • Expenses   │  │ • Forecasts  │  │ • Attrition  │    │
│   └──────┬───────┘  └──────┬───────┘  └──────┬───────┘    │
│          │                 │                  │             │
│          └────────┬────────┴──────────┬───────┘             │
│                   ▼                   ▼                     │
│   ┌──────────────────┐  ┌──────────────────┐              │
│   │  MARKETING       │  │  VENDOR_1         │              │
│   │  (Consumer)      │  │  (Consumer)       │              │
│   │  Accesses:       │  │  Accesses:        │              │
│   │  • Revenue       │  │  • KPIs           │              │
│   │  • KPIs          │  │  (limited view)   │              │
│   │  • Headcount     │  │                    │              │
│   └──────────────────┘  └──────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

**Admin Privileges Delegation:**

```sql
GRANT MANAGE DATA EXCHANGE MEMBERSHIPS ON ACCOUNT TO ROLE exchange_mgr;
GRANT MANAGE DATA EXCHANGE LISTINGS ON ACCOUNT TO ROLE exchange_mgr;
```

**Listing Types in a Data Exchange:**

- **FREE LISTING:** Consumer clicks "Get" → instant access → database created automatically. No approval needed from the provider.
- **PERSONALIZED LISTING:** Consumer clicks "Request" → provider gets email notification → provider approves/denies → consumer gets access if approved. Used for sensitive data, tiered access, compliance requirements.

---

### 3.3 Data Clean Room

**What Is It?**

A Data Clean Room lets you share data while CONTROLLING WHAT QUERIES consumers can run. The consumer gets INSIGHTS, not raw data access.

**How It Differs From Regular Sharing:**
- Regular Share: Consumer gets SELECT access → can run ANY query.
- Clean Room: Provider defines ALLOWED ANALYSES → consumer can ONLY run those pre-approved queries. Raw data is never exposed.

**Use Cases:**
- Advertising: Brand + Publisher share audience data for overlap analysis without exposing individual user records
- Healthcare: Hospitals share patient data for research without exposing PII
- Retail: Retailer + CPG company analyze joint sales without raw data access

Snowflake provides a native Data Clean Rooms product for this. Setup is done via Snowsight or the DCR Collaboration API.

---

### 3.4 Private Listing vs Marketplace Listing — Deep Explanation

A LISTING is a wrapper around a SHARE that adds:
- Title, description, sample queries (metadata for discovery)
- Cross-region/cross-cloud auto-fulfillment
- Consumer usage metrics for the provider
- Paid/free access control

**Private Listing:**
- Shared with SPECIFIC accounts you choose. Only those accounts can see and access it. Nobody else on Snowflake knows it exists.
- Analogy: Sending a private Google Drive link to specific people. Only they can see it. It's not searchable by others.
- When to use: Partners/customers, cross-region sharing, internal BU sharing, when you want metadata but NOT public visibility.
- Setup: Snowsight → Data Products → Provider Studio → + Listing → "Only Specified Consumers"
- Refresh interval: As low as 1 MINUTE (for cross-region auto-fulfillment)
- Approval: None. Publish instantly.

**Marketplace Listing (Public):**
- Published to the Snowflake Marketplace. ANYONE with a Snowflake account can discover and access it.
- Analogy: Listing a product on Amazon. Anyone can find it, browse it, and "buy" (get) it.
- When to use: Monetize data, provide free public datasets, promote your company as a data provider.
- Setup: Snowsight → Data Products → Provider Studio → + Listing → "Anyone on the Snowflake Marketplace" → Submit for Snowflake approval
- Refresh interval: Minimum 8 DAYS (for cross-region auto-fulfillment)
- Approval: Required. Snowflake reviews listing quality & compliance.

**Side-by-Side Comparison:**

| Feature | Private Listing | Marketplace Listing |
|---------|----------------|-------------------|
| Visibility | Only specified accounts | ALL Snowflake users |
| Discovery | Not searchable | Searchable in Marketplace |
| Who can access? | Accounts you add | Anyone who clicks "Get" |
| Cross-region? | Yes (auto-fulfillment) | Yes (auto-fulfillment) |
| Min refresh interval | 1 MINUTE | 8 DAYS |
| Snowflake approval? | No | Yes (review process) |
| Paid listings? | Yes (personalized) | Yes (free or paid) |
| Usage metrics? | Yes | Yes |
| Best for | Partners, internal teams | Public data monetization |

**Direct Share vs Private Listing:**

| | Direct Share | Private Listing |
|--|-------------|----------------|
| Cross-region/cloud | NO (same region only) | YES (auto-fulfillment) |
| Metadata (title, docs) | NO | YES |
| Usage metrics | NO | YES |
| Setup | SQL only (simple) | Snowsight UI (medium) |
| Paid access | NO | YES |
| When to use | Quick, same-region sharing | Cross-region, governed, need metrics |

**Visual:**

```
PRIVATE LISTING:
┌──────────────────┐         ┌──────────────┐
│  PROVIDER         │────────→│  PARTNER A   │  ← explicitly added
│                   │────────→│  PARTNER B   │  ← explicitly added
│  "Sales Data"     │    ✗    │  RANDOM USER │  ← cannot see it
└──────────────────┘         └──────────────┘

MARKETPLACE LISTING:
┌──────────────────┐         ┌──────────────┐
│  PROVIDER         │────────→│  ANYONE      │  ← visible to all
│                   │────────→│  WORLDWIDE   │  ← searchable
│  "Weather Data"   │────────→│  ANY ACCOUNT │  ← click "Get"
└──────────────────┘         └──────────────┘
```

---

### 3.5 Complete Decision Tree — Which Sharing Method?

```
START
  │
  ├── Share with 1-2 accounts in SAME region?
  │     └── YES → DIRECT SHARE (simplest, SQL only)
  │
  ├── Share across regions or clouds?
  │     └── YES → LISTING (Private) with auto-fulfillment
  │
  ├── Share publicly with anyone on Snowflake?
  │     └── YES → LISTING (Public) on Marketplace
  │
  ├── Manage a GROUP of accounts sharing with each other?
  │     └── YES → DATA EXCHANGE (private hub, admin-controlled)
  │
  ├── Consumer should NOT have raw data access?
  │     └── YES → DATA CLEAN ROOM (controlled queries only)
  │
  └── Consumer does NOT have a Snowflake account?
        └── YES → READER ACCOUNT (provider pays compute)
```

---

## Part 4: Direct Share — Step-by-Step with SQL

### 4.1 Provider Side: Create and Configure a Share

```sql
-- STEP 1: Create the database and data to share
CREATE OR REPLACE DATABASE sales_db;
CREATE OR REPLACE SCHEMA sales_db.public;

CREATE OR REPLACE TABLE sales_db.public.orders (
    order_id       INT,
    customer_name  STRING,
    product        STRING,
    amount         DECIMAL(10,2),
    region         STRING,
    order_date     DATE
);

INSERT INTO sales_db.public.orders VALUES
    (1, 'Alice',   'Widget A', 250.00, 'US-East',  '2026-04-01'),
    (2, 'Bob',     'Widget B', 450.00, 'US-West',  '2026-04-02'),
    (3, 'Charlie', 'Widget A', 175.00, 'EU-West',  '2026-04-03'),
    (4, 'Diana',   'Widget C', 800.00, 'US-East',  '2026-04-04'),
    (5, 'Eve',     'Widget B', 320.00, 'APAC',     '2026-04-05');

-- STEP 2: Create a SECURE VIEW (best practice — never share raw tables)
CREATE OR REPLACE SECURE VIEW sales_db.public.sv_orders AS
    SELECT order_id, product, amount, region, order_date
    FROM sales_db.public.orders;
-- Secure view hides customer_name (PII) from consumers.

-- STEP 3: Create the share
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE SHARE sales_share
    COMMENT = 'Sales order data for partner analytics';

-- STEP 4: Grant privileges to the share
GRANT USAGE ON DATABASE sales_db TO SHARE sales_share;
GRANT USAGE ON SCHEMA sales_db.public TO SHARE sales_share;
GRANT SELECT ON VIEW sales_db.public.sv_orders TO SHARE sales_share;

-- STEP 5: Add consumer accounts
ALTER SHARE sales_share ADD ACCOUNTS = ORG1.CONSUMER_ACCT;

-- Verify the share
SHOW SHARES;
SHOW GRANTS TO SHARE sales_share;
DESCRIBE SHARE sales_share;
```

---

### 4.2 Consumer Side: Access the Shared Data

```sql
-- STEP 1: View available shares
SHOW SHARES;

-- STEP 2: Describe what's in the share
DESCRIBE SHARE PROVIDER_ORG.PROVIDER_ACCT.sales_share;

-- STEP 3: Create a database from the share
CREATE DATABASE sales_from_partner FROM SHARE PROVIDER_ORG.PROVIDER_ACCT.sales_share;

-- STEP 4: Grant access to roles in your account
GRANT IMPORTED PRIVILEGES ON DATABASE sales_from_partner TO ROLE analyst_role;

-- STEP 5: Query the shared data
USE ROLE analyst_role;
SELECT * FROM sales_from_partner.public.sv_orders;
SELECT region, SUM(amount) FROM sales_from_partner.public.sv_orders GROUP BY region;
```

---

### 4.3 Using Database Roles (Recommended — Granular Access)

Instead of granting directly to a share, create database roles. This allows MULTIPLE ACCESS LEVELS within the SAME share.

```sql
CREATE DATABASE ROLE sales_db.analyst_role;
CREATE DATABASE ROLE sales_db.executive_role;

GRANT USAGE ON SCHEMA sales_db.public TO DATABASE ROLE sales_db.analyst_role;
GRANT SELECT ON VIEW sales_db.public.sv_orders TO DATABASE ROLE sales_db.analyst_role;

GRANT USAGE ON SCHEMA sales_db.public TO DATABASE ROLE sales_db.executive_role;
GRANT SELECT ON VIEW sales_db.public.sv_orders TO DATABASE ROLE sales_db.executive_role;
-- Executive role could also get access to additional views/tables

GRANT USAGE ON DATABASE sales_db TO SHARE sales_share;
GRANT DATABASE ROLE sales_db.analyst_role TO SHARE sales_share;

-- Consumer grants the database role to their local roles:
-- GRANT DATABASE ROLE sales_from_partner.analyst_role TO ROLE local_analyst;
```

---

## Part 5: Secure Views — The Backbone of Safe Data Sharing

### 5.1 Why Secure Views?

NEVER share raw tables directly. Always use SECURE VIEWS because:

1. HIDE sensitive columns (PII, internal IDs, etc.)
2. FILTER rows per consumer (multi-tenant sharing)
3. HIDE the view definition from consumers
4. PREVENT query plan exposure (optimizer fence)
5. PROTECT against function-based side-channel attacks

Regular views expose their SQL definition to consumers. Secure views do NOT — the definition is hidden from SHOW CREATE VIEW.

---

### 5.2 Basic Secure View (Column Filtering)

```sql
CREATE OR REPLACE SECURE VIEW sales_db.public.sv_orders_public AS
    SELECT order_id, product, amount, region, order_date
    FROM sales_db.public.orders;
-- Hides: customer_name
```

---

### 5.3 Row-Level Filtering Per Consumer (Multi-Tenant Sharing)

Share DIFFERENT rows with DIFFERENT consumers from the SAME share. Uses `CURRENT_ACCOUNT()` to identify which consumer is querying.

```sql
CREATE OR REPLACE TABLE sales_db.public.account_access (
    region         STRING,
    consumer_acct  STRING
);

INSERT INTO sales_db.public.account_access VALUES
    ('US-East', 'CONSUMER_EAST'),
    ('US-West', 'CONSUMER_WEST'),
    ('EU-West', 'CONSUMER_EU'),
    ('APAC',    'CONSUMER_APAC');

CREATE OR REPLACE SECURE VIEW sales_db.public.sv_orders_filtered AS
    SELECT o.order_id, o.product, o.amount, o.region, o.order_date
    FROM sales_db.public.orders o
    JOIN sales_db.public.account_access a
        ON o.region = a.region
    WHERE a.consumer_acct = CURRENT_ACCOUNT();
```

- Consumer CONSUMER_EAST sees only US-East orders.
- Consumer CONSUMER_EU sees only EU-West orders.
- ALL from the SAME share. Zero data duplication.

**Test with simulation:**
```sql
ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'CONSUMER_EAST';
SELECT * FROM sales_db.public.sv_orders_filtered;
```

---

### 5.4 Sharing Secure UDFs

```sql
CREATE OR REPLACE SECURE FUNCTION sales_db.public.get_total_by_region(r STRING)
    RETURNS DECIMAL(12,2)
    LANGUAGE SQL
AS
$$
    SELECT SUM(amount) FROM sales_db.public.orders WHERE region = r
$$;

GRANT USAGE ON FUNCTION sales_db.public.get_total_by_region(STRING) TO SHARE sales_share;
```

---

## Part 6: Reader Accounts — Sharing with Non-Snowflake Users

### 6.1 What is a Reader Account?

A READER ACCOUNT is a lightweight Snowflake account created BY the provider for consumers who do NOT have their own Snowflake account.

**Key Facts:**
- Created and managed by the provider
- Provider pays for the reader account's compute and storage
- Reader can ONLY consume data from the provider who created it
- Reader CANNOT load data, run DML, or create databases
- Reader CANNOT access shares from other providers
- Think of it as a "read-only sandbox" owned by the provider

```sql
-- Create a reader account:
CREATE MANAGED ACCOUNT reader_partner1
    ADMIN_NAME = 'partner_admin',
    ADMIN_PASSWORD = 'SecureP@ss123!',
    TYPE = READER,
    COMMENT = 'Reader account for Partner 1';

-- Add the reader account to your share:
SHOW MANAGED ACCOUNTS;  -- Get the account locator
ALTER SHARE sales_share ADD ACCOUNTS = ORG.READER_PARTNER1;
```

---

## Part 7: Sharing Management Commands (SQL Reference)

### 7.1 Provider Commands

```sql
CREATE SHARE my_share;
CREATE OR REPLACE SHARE my_share COMMENT = 'Description here';

GRANT USAGE ON DATABASE my_db TO SHARE my_share;
GRANT USAGE ON SCHEMA my_db.my_schema TO SHARE my_share;
GRANT SELECT ON TABLE my_db.my_schema.my_table TO SHARE my_share;
GRANT SELECT ON VIEW my_db.my_schema.my_view TO SHARE my_share;
GRANT USAGE ON FUNCTION my_db.my_schema.my_func(STRING) TO SHARE my_share;
GRANT SELECT ON ALL TABLES IN SCHEMA my_db.my_schema TO SHARE my_share;

GRANT DATABASE ROLE my_db.my_role TO SHARE my_share;

ALTER SHARE my_share ADD ACCOUNTS = ORG1.ACCT1, ORG2.ACCT2;
ALTER SHARE my_share REMOVE ACCOUNTS = ORG2.ACCT2;

REVOKE SELECT ON VIEW my_db.my_schema.my_view FROM SHARE my_share;

SHOW SHARES;
DESCRIBE SHARE my_share;
SHOW GRANTS TO SHARE my_share;
SHOW GRANTS OF SHARE my_share;

DROP SHARE my_share;
```

---

### 7.2 Consumer Commands

```sql
SHOW SHARES;
DESCRIBE SHARE provider_org.provider_acct.share_name;

CREATE DATABASE local_name FROM SHARE provider_org.provider_acct.share_name;
GRANT IMPORTED PRIVILEGES ON DATABASE local_name TO ROLE my_role;
GRANT DATABASE ROLE local_name.role_name TO ROLE my_role;

DROP DATABASE local_name;  -- Removes access, does not affect provider
```

---

## Part 8: Cross-Region & Cross-Cloud Sharing

### 8.1 The Challenge

Direct shares work ONLY within the same Snowflake region. If provider is in AWS US-East-1 and consumer is in Azure West Europe, a direct share will NOT work.

**SOLUTION:** Use LISTINGS with AUTO-FULFILLMENT. Snowflake automatically replicates the shared data to the consumer's region. Provider pays for replication costs.

---

### 8.2 How Auto-Fulfillment Works

```
┌────────────────────────────────┐          ┌────────────────────────┐
│  Provider Account              │          │  Consumer Account      │
│  Region: AWS US-East-1         │          │  Region: Azure EU-West │
│                                │          │                        │
│  Listing: "Sales Data"         │──────→   │  Gets the listing      │
│  Share: sales_share            │ AUTO-    │  Creates database      │
│                                │ FULFILL  │  from share            │
└────────────────────────────────┘          └────────────────────────┘
                                  │
                       Snowflake replicates data
                       to consumer's region
                       (provider pays replication cost)
```

**Steps:**
1. Provider creates a LISTING (via Snowsight Provider Studio)
2. Provider adds consumer's account (in any region)
3. Snowflake detects cross-region → enables auto-fulfillment
4. Provider sets replication refresh interval
5. Consumer "gets" the listing → database is created
6. Data is replicated to consumer's region automatically

---

### 8.3 Cross-Region Setup (Same Cloud, Different Region)

**Scenario:**
- Provider: AWS US-East-1
- Consumer: AWS EU-West-1
- Same cloud (AWS), different region → CROSS-REGION

**Provider Side:**

```sql
-- STEP 1: Create the database and objects to share
CREATE OR REPLACE DATABASE cross_region_db;
CREATE OR REPLACE SCHEMA cross_region_db.analytics;

CREATE OR REPLACE TABLE cross_region_db.analytics.sales (
    sale_id        INT,
    product        STRING,
    amount         DECIMAL(10,2),
    region         STRING,
    sale_date      DATE
);

INSERT INTO cross_region_db.analytics.sales VALUES
    (1, 'Widget A', 250.00, 'US-East',  '2026-04-01'),
    (2, 'Widget B', 450.00, 'US-West',  '2026-04-02'),
    (3, 'Widget A', 175.00, 'EU-West',  '2026-04-03'),
    (4, 'Widget C', 800.00, 'APAC',     '2026-04-04'),
    (5, 'Widget B', 320.00, 'EU-North', '2026-04-05');

CREATE OR REPLACE SECURE VIEW cross_region_db.analytics.sv_sales AS
    SELECT sale_id, product, amount, region, sale_date
    FROM cross_region_db.analytics.sales;

-- STEP 2: Create the share
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE SHARE cross_region_share
    COMMENT = 'Sales data for cross-region partner';

GRANT USAGE ON DATABASE cross_region_db TO SHARE cross_region_share;
GRANT USAGE ON SCHEMA cross_region_db.analytics TO SHARE cross_region_share;
GRANT SELECT ON VIEW cross_region_db.analytics.sv_sales TO SHARE cross_region_share;

-- STEP 3: Create a LISTING (Snowsight UI)
--   Provider Studio → + Listing → "Only Specified Consumers"
--   Add Data → Select share → Add Consumer Account
--   Snowflake detects cross-region → shows Auto-Fulfillment options
--   Set refresh interval (e.g., 10 MINUTES) → Publish
```

**What Happens Behind the Scenes:**

```
┌──────────────────────────┐         ┌──────────────────────────┐
│  PROVIDER                │         │  CONSUMER                │
│  AWS US-East-1           │         │  AWS EU-West-1           │
│                          │         │                          │
│  cross_region_db         │         │                          │
│    └─ sv_sales           │         │                          │
│                          │         │                          │
│  Listing published ──────┼────→    │  Consumer gets listing   │
└──────────────────────────┘         └────────────┬─────────────┘
             │                                    │
             ▼                                    │
┌──────────────────────────┐                     │
│  SECURE SHARE AREA (SSA) │                     │
│  AWS EU-West-1           │←────────────────────┘
│  (managed by Snowflake)  │   Consumer reads from SSA
│                          │   (local to their region)
│  Replicated data:        │
│  sv_sales + base tables  │
│  Refreshed every 10 min  │
└──────────────────────────┘
```

- Data path: Provider storage → SSA in EU-West-1 → Consumer queries
- Network: AWS internal transfer (US-East-1 → EU-West-1)
- Cost: Provider pays for replication + SSA storage + data transfer
- Latency: Up to 10 min stale (based on refresh interval)

**Consumer Side:**

```sql
-- Snowsight → Data Products → Shared With You → Find listing → Click "Get"
-- Or SQL:
CREATE DATABASE partner_sales FROM SHARE PROVIDER_ORG.PROVIDER_ACCT.cross_region_share;
GRANT IMPORTED PRIVILEGES ON DATABASE partner_sales TO ROLE analyst;
SELECT * FROM partner_sales.analytics.sv_sales;
```

---

### 8.4 Cross-Cloud Setup (Different Cloud Provider Entirely)

**Scenario:**
- Provider: AWS US-East-1
- Consumer: Azure West Europe
- Different cloud entirely → CROSS-CLOUD

The setup is IDENTICAL to cross-region. Snowflake handles cloud-to-cloud replication automatically via auto-fulfillment. The only difference is where the SSA is created (Azure instead of AWS).

```sql
-- Provider side (same SQL pattern):
CREATE OR REPLACE DATABASE cross_cloud_db;
CREATE OR REPLACE SCHEMA cross_cloud_db.finance;

CREATE OR REPLACE TABLE cross_cloud_db.finance.revenue (
    quarter    STRING,
    product    STRING,
    revenue    DECIMAL(12,2),
    currency   STRING
);

INSERT INTO cross_cloud_db.finance.revenue VALUES
    ('2026-Q1', 'Widget A', 1250000.00, 'USD'),
    ('2026-Q1', 'Widget B', 890000.00,  'USD'),
    ('2026-Q1', 'Widget C', 2100000.00, 'USD'),
    ('2026-Q2', 'Widget A', 1400000.00, 'USD'),
    ('2026-Q2', 'Widget B', 950000.00,  'USD');

CREATE OR REPLACE SECURE VIEW cross_cloud_db.finance.sv_revenue AS
    SELECT quarter, product, revenue, currency
    FROM cross_cloud_db.finance.revenue;

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE SHARE cross_cloud_share
    COMMENT = 'Revenue data for Azure-based partner';

GRANT USAGE ON DATABASE cross_cloud_db TO SHARE cross_cloud_share;
GRANT USAGE ON SCHEMA cross_cloud_db.finance TO SHARE cross_cloud_share;
GRANT SELECT ON VIEW cross_cloud_db.finance.sv_revenue TO SHARE cross_cloud_share;
```

**Behind the Scenes (Cross-Cloud):**

```
┌──────────────────────────┐         ┌──────────────────────────┐
│  PROVIDER                │         │  CONSUMER                │
│  AWS US-East-1           │         │  AZURE West-Europe       │
│  cross_cloud_db          │         │                          │
│    └─ sv_revenue         │         │                          │
│  Listing published ──────┼────→    │  Consumer gets listing   │
└──────────────────────────┘         └────────────┬─────────────┘
             │                                    │
             ▼                                    │
┌──────────────────────────┐                     │
│  SECURE SHARE AREA (SSA) │                     │
│  AZURE West-Europe       │←────────────────────┘
│  (managed by Snowflake)  │   Consumer reads from SSA
│  Replicated data         │
│  Refreshed every 1 hour  │
└──────────────────────────┘

Data path: AWS S3 → (cross-cloud transfer) → Azure Blob → SSA → Consumer
Cost: Provider pays replication + SSA storage + cross-cloud data transfer
```

---

### 8.5 Cross-Region vs Cross-Cloud — Key Differences

| Factor | Cross-Region | Cross-Cloud |
|--------|-------------|-------------|
| Provider | AWS US-East-1 | AWS US-East-1 |
| Consumer | AWS EU-West-1 | Azure West-Europe |
| Same cloud? | YES (both AWS) | NO (AWS → Azure) |
| Setup | Identical (listing) | Identical (listing) |
| Auto-fulfillment | Yes | Yes |
| SSA location | AWS EU-West-1 | Azure West-Europe |
| Data transfer path | AWS internal (cheaper) | AWS → Azure (more costly) |
| Replication speed | Faster (same cloud) | Slower (cross-cloud hop) |
| Provider/Consumer SQL | Same | Same |

**Bottom Line:** From the SQL/setup perspective, cross-region and cross-cloud are IDENTICAL. The only differences are COST and SPEED — cross-cloud is more expensive and slightly slower.

---

### 8.6 Manage Auto-Fulfillment (Provider Side)

```sql
-- Check replication status:
SELECT * FROM SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_REFRESH_DAILY;

-- Trigger an on-demand refresh:
SELECT SYSTEM$TRIGGER_LISTING_REFRESH('<listing_global_name>');

-- View auto-fulfillment storage usage:
SELECT * FROM SNOWFLAKE.DATA_SHARING_USAGE.LISTING_AUTO_FULFILLMENT_DATABASE_STORAGE_DAILY;

-- Check listing access history:
SELECT * FROM SNOWFLAKE.DATA_SHARING_USAGE.LISTING_ACCESS_HISTORY;

-- Check which regions/clouds your data is replicated to:
SHOW LISTINGS;
```

**Refresh Options:**

| Refresh Type | Description |
|-------------|-------------|
| Interval-based (default) | Refresh every N minutes/hours/days. Range: 1 minute to 8 days. |
| Trigger-based (manual) | `SYSTEM$TRIGGER_LISTING_REFRESH('listing')`. Best when ETL completes. |
| Schedule-based (cron-like) | Refresh at specific timestamp + schedule. |

Note: Interval-based and schedule-based CANNOT be used simultaneously.

---

### 8.7 Cross-Region Costs

Auto-fulfillment costs are paid by the PROVIDER:

| Cost Component | Description |
|---------------|-------------|
| Initial replication (one-time) | Full copy of shared objects to SSA |
| Incremental refresh (recurring) | Only changes since last refresh |
| SSA storage (recurring) | Storage of replicated data in consumer's region |
| Data transfer (recurring) | Network transfer between regions/clouds |
| Compute for replication (recurring) | Warehouse used for replication process |

**Cost Optimization:**
1. Share SECURE VIEWS with aggregated/filtered data (less data to replicate)
2. Use longer refresh intervals for non-critical data
3. Use trigger-based refresh to replicate only when ETL completes
4. Use SUB_DATABASE mode (default) — only replicates objects in the share
5. Monitor costs via LISTING_AUTO_FULFILLMENT_DATABASE_STORAGE_DAILY
6. 10 TB limit per auto-fulfilled database (contact support to increase)

---

### 8.8 Objects Supported for Auto-Fulfillment

**Supported:**
- Tables (standard, dynamic)
- Views (regular, secure)
- Secure UDFs (SQL, JavaScript, Python, Java, Scala)
- Sequences
- Schemas
- Database roles
- Row access policies, masking policies
- Tags

**NOT supported:**
- External tables
- Streams on shared objects
- Stages
- Pipes
- Tasks
- Alerts

---

## Part 9: Billing & Cost Model

### 9.1 Cost Overview

**Provider Costs:**

| Cost Component | Description |
|---------------|-------------|
| Storage | Provider pays for their own data storage |
| Share object | FREE — a share is just metadata |
| Direct share (same region) | FREE — no data movement |
| Auto-fulfillment (cross-region) | Provider pays for replication (data transfer + storage) |

**Consumer Costs:**

| Cost Component | Description |
|---------------|-------------|
| Storage | ZERO — no data is copied to consumer |
| Compute (warehouse) | Consumer pays for their own queries |
| Imported database | FREE — just a metadata pointer |

**Reader Account Costs:** Provider pays for ALL reader account costs (compute + storage).

---

## Part 10: Best Practices & Gotchas

1. **ALWAYS use SECURE VIEWS**, never share raw tables directly. Raw tables expose all columns, including sensitive/internal data.

2. **Use ROW-LEVEL FILTERING** via `CURRENT_ACCOUNT()` for multi-tenant sharing. One share, one view, multiple consumers seeing different data.

3. **Use DATABASE ROLES** for granular access control. Consumers map database roles to their local roles.

4. **CLUSTERING KEYS** on base tables improve query performance for consumers. Large shared tables benefit significantly from clustering.

5. **Test with SIMULATED_DATA_SHARING_CONSUMER** before adding accounts.
   ```sql
   ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'ACCT_NAME';
   SELECT * FROM my_secure_view;
   ```

6. **Monitor consumer usage** via SNOWFLAKE.DATA_SHARING_USAGE schema.

7. **Shared data is READ-ONLY.** Consumers cannot INSERT, UPDATE, DELETE.

8. **Consumer can create only ONE database per share.** If you need multiple access patterns, use database roles within one share.

9. **REVOKE access instantly** by removing accounts from the share:
   ```sql
   ALTER SHARE my_share REMOVE ACCOUNTS = CONSUMER_ACCT;
   ```

10. **Direct shares are same-region ONLY.** Use listings for cross-region.

---

## Part 11: Practical Scenarios with Executable SQL

### 11.1 Share Aggregated Data (Hide Raw Details)

```sql
CREATE OR REPLACE SECURE VIEW sales_db.public.sv_monthly_summary AS
    SELECT
        DATE_TRUNC('month', order_date) AS month,
        region,
        COUNT(*) AS order_count,
        SUM(amount) AS total_revenue,
        AVG(amount) AS avg_order_value
    FROM sales_db.public.orders
    GROUP BY DATE_TRUNC('month', order_date), region;

-- Share only the summary, not individual orders:
GRANT SELECT ON VIEW sales_db.public.sv_monthly_summary TO SHARE sales_share;
```

---

### 11.2 Share with Multiple Consumers (Different Data Each)

```sql
CREATE OR REPLACE TABLE sales_db.public.partner_access (
    partner_account STRING,
    allowed_products ARRAY
);

INSERT INTO sales_db.public.partner_access
    SELECT 'PARTNER_A', ARRAY_CONSTRUCT('Widget A', 'Widget B')
    UNION ALL
    SELECT 'PARTNER_B', ARRAY_CONSTRUCT('Widget C');

CREATE OR REPLACE SECURE VIEW sales_db.public.sv_partner_orders AS
    SELECT o.order_id, o.product, o.amount, o.region, o.order_date
    FROM sales_db.public.orders o
    JOIN sales_db.public.partner_access p
        ON ARRAY_CONTAINS(o.product::VARIANT, p.allowed_products)
    WHERE p.partner_account = CURRENT_ACCOUNT();
-- Partner A sees Widget A and Widget B orders.
-- Partner B sees only Widget C orders.
```

---

### 11.3 Share an Entire Schema

```sql
GRANT SELECT ON ALL TABLES IN SCHEMA sales_db.public TO SHARE sales_share;
GRANT SELECT ON ALL VIEWS IN SCHEMA sales_db.public TO SHARE sales_share;

-- For future objects too (via database roles):
GRANT SELECT ON FUTURE TABLES IN SCHEMA sales_db.public TO DATABASE ROLE sales_db.analyst_role;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA sales_db.public TO DATABASE ROLE sales_db.analyst_role;
```

---

### 11.4 Add / Remove Objects from a Live Share

```sql
-- Provider adds a new table (consumers see it immediately):
CREATE OR REPLACE TABLE sales_db.public.products (
    product_id INT, name STRING, category STRING, price DECIMAL(10,2)
);
INSERT INTO sales_db.public.products VALUES (1, 'Widget A', 'Hardware', 125.00);
GRANT SELECT ON TABLE sales_db.public.products TO SHARE sales_share;
-- Consumers instantly see the new table.

-- Provider removes a table:
REVOKE SELECT ON TABLE sales_db.public.products FROM SHARE sales_share;
-- Consumers instantly lose access.
```

---

### 11.5 Consumer Joins Shared Data with Local Data

```sql
-- Consumer side:
SELECT
    s.order_id, s.product, s.amount,
    l.customer_segment, l.lifetime_value
FROM partner_data.public.sv_orders s
JOIN local_db.public.customer_mapping l
    ON s.order_id = l.external_order_id;
-- KEY advantage: consumers enrich shared data with their own data.
```

---

## Part 12: Interview Questions — Level 1: Beginner

**Q1: What is Snowflake Secure Data Sharing?**
> A feature that lets you share selected database objects (tables, views, UDFs) with other Snowflake accounts WITHOUT copying or moving any data. Consumers get read-only access to live data using their own compute. No ETL, no data duplication, no storage cost for consumers.

**Q2: Is any data copied when you share?**
> NO. Sharing uses Snowflake's services layer and metadata store. The shared database in the consumer account is a metadata pointer — it reads the provider's micro-partitions directly. Zero-copy architecture.

**Q3: Who pays for what in data sharing?**
> Provider pays for STORAGE (their data) and auto-fulfillment replication (if cross-region). Consumer pays for COMPUTE (their warehouse to query the shared data). The share object itself is free. No data transfer costs within the same region.

**Q4: What is a SHARE object?**
> A named Snowflake object created by the provider that encapsulates: database reference, granted privileges on specific objects, and a list of consumer accounts. It's metadata, not a data copy.

**Q5: Can a consumer modify shared data?**
> NO. All shared objects are strictly READ-ONLY. Consumers cannot INSERT, UPDATE, DELETE, or ALTER any shared object.

**Q6: What objects can you share?**
> Databases, schemas, tables (standard, dynamic, external, Iceberg), views (regular, secure, materialized, semantic), UDFs (secure and non-secure), Cortex Search services, and certain model types.

**Q7: What role is needed to create a share?**
> ACCOUNTADMIN by default. You can grant CREATE SHARE to other roles: `GRANT CREATE SHARE ON ACCOUNT TO ROLE my_sharing_role;`

**Q8: Can a consumer create multiple databases from the same share?**
> NO. Only ONE database per share per consumer account. If you need multiple access patterns, use database roles within the share.

---

## Part 13: Interview Questions — Level 2: Intermediate

**Q9: Why should you use secure views instead of sharing tables directly?**
> Secure views: (1) hide sensitive columns, (2) enable row-level filtering per consumer, (3) hide the view definition from consumers, (4) prevent query plan exposure, (5) protect against side-channel attacks. Raw tables expose everything to all consumers.

**Q10: How do you share different data with different consumers from one share?**
> Use a secure view with `CURRENT_ACCOUNT()` function. Create a mapping table that maps consumer account names to data partitions (region, tenant, etc.). The secure view joins the data table with the mapping table and filters by `CURRENT_ACCOUNT()`. Each consumer sees only their rows.

**Q11: What is SIMULATED_DATA_SHARING_CONSUMER?**
> A session parameter that lets the provider TEST what a specific consumer will see, without actually sharing the data: `ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'ACCT_NAME';` Then query your secure views to verify row-level filtering.

**Q12: What is a Reader Account?**
> A lightweight Snowflake account created BY the provider for consumers who don't have their own Snowflake account. The provider pays for the reader's compute and storage. Readers can ONLY consume data from the provider who created them. They cannot load data or access other shares.

**Q13: What is the difference between a direct share and a listing?**
> Direct share: SQL-based, same region only, no metadata, no usage metrics, no cross-cloud support. Listing: Snowsight-based, any region/cloud, includes metadata (title, description, sample queries), provides usage metrics, supports cross-region auto-fulfillment, and can be offered publicly on the Marketplace or for a fee.

**Q14: What is auto-fulfillment?**
> When a listing is shared with a consumer in a DIFFERENT region/cloud, Snowflake automatically replicates the shared data to the consumer's region. The provider pays for replication. The consumer sees the data as if it were local. Replication happens on a provider-defined schedule.

**Q15: What are database roles in the context of sharing?**
> Instead of granting privileges directly to a share, you create database roles, grant privileges to those roles, then grant the roles to the share. Consumers map the database roles to their local roles. This provides granular, multi-level access control within a single share.

**Q16: How do you revoke a consumer's access to shared data?**
> `ALTER SHARE my_share REMOVE ACCOUNTS = CONSUMER_ACCT;` Access is revoked immediately. The consumer's imported database becomes inaccessible. No data is deleted — it was never copied.

---

## Part 14: Interview Questions — Level 3: Advanced

**Q17: How does sharing work at the storage layer?**
> Snowflake's services layer maintains metadata about micro-partitions. When a share is created, the consumer's imported database points to the SAME micro-partitions in the provider's storage. The consumer's warehouse reads those micro-partitions directly. No files are copied or moved. This is possible because Snowflake separates storage from compute.

**Q18: What happens to shared data when the provider updates the source table?**
> Changes are INSTANTLY visible to all consumers. Since consumers read the provider's actual micro-partitions, any INSERT/UPDATE/DELETE by the provider is reflected in the consumer's next query. Zero lag within the same region. For cross-region listings, there is a replication lag based on the auto-fulfillment refresh interval.

**Q19: Can you share data from multiple databases in one share?**
> Not directly with `GRANT ... TO SHARE` (one database per share). But you can use DATABASE ROLES that reference objects in the share's database. Alternatively, create views in the shared database that reference tables in other databases (the provider account must have access). The share only includes the shared database, but the views can pull from anywhere.

**Q20: How do you enable non-ACCOUNTADMIN roles to manage sharing?**
> `GRANT CREATE SHARE ON ACCOUNT TO ROLE sharing_admin;` `GRANT IMPORT SHARE ON ACCOUNT TO ROLE sharing_admin;` For listings: `GRANT CREATE LISTING ON ACCOUNT TO ROLE listing_admin;` The role also needs USAGE + GRANT OPTION on databases being shared.

**Q21: What are the limitations of data sharing?**
> - Consumer data is read-only (no DML)
> - One database per share per consumer
> - Direct shares: same region only
> - Cannot share from a database created from a share (no chaining)
> - Time Travel is NOT available on shared data (consumer side)
> - Streams on shared tables have limitations (append-only only in some cases)
> - Shared secure views may have performance overhead (optimizer fence)
> - Reader accounts can only access data from their creating provider

**Q22: Can consumers create streams on shared tables?**
> Yes, but with restrictions. Consumers can create APPEND_ONLY streams on shared tables. Standard streams (which track updates and deletes) may not be supported on shared objects. The provider must enable CHANGE_TRACKING on the source table for streams to work.

**Q23: How do you monitor who is accessing your shared data?**
> Via the SNOWFLAKE.DATA_SHARING_USAGE schema (account usage views): LISTING_ACCESS_HISTORY (who accessed which listing), LISTING_CONSUMPTION_DAILY (daily consumption metrics). For direct shares: `SHOW GRANTS OF SHARE` to see which accounts have access. For listings: Snowsight Provider Studio provides usage dashboards.

---

## Part 15: Interview Questions — Level 4: Architect

**Q24: Design a multi-tenant data sharing architecture for a SaaS company that needs to share analytics with 500 customers.**
> Architecture:
> 1. Single database with all customer data
> 2. Mapping table: customer_account → tenant_id
> 3. Secure view with `CURRENT_ACCOUNT()` filter
> 4. ONE share with the secure view
> 5. Add all 500 accounts to the share
>
> Each customer queries the same view but sees only their tenant's data.
>
> For cross-region customers: Use a LISTING with auto-fulfillment.
> For customers without Snowflake: Create READER ACCOUNTS (provider pays compute).
>
> Access control: Database roles for different levels (basic, premium, enterprise).
> Performance: Cluster base tables by tenant_id for partition pruning.
> Monitoring: DATA_SHARING_USAGE views + alerts on unusual patterns.

**Q25: How would you handle data sharing across three cloud providers (AWS, Azure, GCP) and five regions?**
> Use LISTINGS with AUTO-FULFILLMENT:
> 1. Provider creates listings (not direct shares)
> 2. Lists are published privately to specific consumer accounts
> 3. Snowflake auto-detects cross-region consumers
> 4. Provider configures replication refresh interval
> 5. Snowflake creates SSAs in each consumer region
> 6. Data is replicated to SSAs automatically
>
> Cost: Provider pays replication to each region + SSA storage. Optimize by sharing aggregated/filtered views.
> Limitation: Only auto-fulfillment-supported objects. Replication lag = refresh interval.

**Q26: Compare data sharing vs data replication vs data exchange.**
> **DATA SHARING:** Zero-copy (same region) or auto-fulfilled (cross-region). Consumer gets read-only access. Provider controls access. Best for: sharing with external partners/customers.
>
> **DATA REPLICATION:** Full copy of database to another account/region. Consumer gets a writable replica (after failover). Used for DR and business continuity. Best for: multi-region deployments within same org.
>
> **DATA EXCHANGE:** Private marketplace for a managed group of accounts. Invite-only membership. Members can publish and consume listings. Best for: industry consortiums, internal organizational sharing.

**Q27: How would you migrate from ETL-based data distribution to data sharing?**
> Migration plan:
> 1. Identify all data feeds currently sent via ETL to partners
> 2. Create SECURE VIEWs that produce the same output
> 3. Test with SIMULATED_DATA_SHARING_CONSUMER
> 4. Create a SHARE or LISTING
> 5. Add partner accounts
> 6. Partners validate shared data matches ETL output (parallel run)
> 7. Decommission ETL pipelines once validated
>
> Benefits: Eliminate ETL infrastructure, real-time data, zero consumer storage cost, centralized governance.
> Challenges: Partners need Snowflake accounts (or reader accounts), cross-region costs, read-only access.

**Q28: How do you ensure data governance and compliance in a sharing scenario?**
> Governance framework:
> 1. SECURE VIEWS only — never expose raw tables
> 2. Row-level filtering via `CURRENT_ACCOUNT()` mapping tables
> 3. Column masking via secure views (exclude PII columns)
> 4. DATABASE ROLES for tiered access (basic, premium, enterprise)
> 5. TAG-BASED GOVERNANCE: Tag sensitive columns, auto-apply masking policies
> 6. SIMULATED_DATA_SHARING_CONSUMER testing before production
> 7. Monitoring: DATA_SHARING_USAGE views + alerts on anomalies
> 8. Regular access reviews: SHOW GRANTS OF SHARE
> 9. Instant revocation: ALTER SHARE REMOVE ACCOUNTS
> 10. Audit trail: QUERY_HISTORY shows consumer queries
>
> Compliance (GDPR/CCPA): Never share PII directly; right to deletion (remove from source → instantly gone for consumers); data residency via region-specific auto-fulfillment; consent tracking via mapping tables.

---

## Part 16: Quick Reference Cheat Sheet

### Provider

```sql
CREATE SHARE s;
GRANT USAGE ON DATABASE db TO SHARE s;
GRANT USAGE ON SCHEMA db.schema TO SHARE s;
GRANT SELECT ON VIEW db.schema.sv TO SHARE s;
ALTER SHARE s ADD ACCOUNTS = ORG.ACCT;
ALTER SHARE s REMOVE ACCOUNTS = ORG.ACCT;
SHOW GRANTS TO SHARE s;
DROP SHARE s;
```

### Consumer

```sql
SHOW SHARES;
CREATE DATABASE mydb FROM SHARE provider.share_name;
GRANT IMPORTED PRIVILEGES ON DATABASE mydb TO ROLE r;
```

### Secure View (Row-Level Filtering)

```sql
CREATE SECURE VIEW sv AS
    SELECT ... FROM t
    JOIN mapping m ON t.key = m.key
    WHERE m.account = CURRENT_ACCOUNT();
```

### Test

```sql
ALTER SESSION SET SIMULATED_DATA_SHARING_CONSUMER = 'ACCT';
SELECT * FROM my_secure_view;
```

### Database Roles

```sql
CREATE DATABASE ROLE db.role_name;
GRANT SELECT ON VIEW ... TO DATABASE ROLE db.role_name;
GRANT DATABASE ROLE db.role_name TO SHARE s;
-- Consumer: GRANT DATABASE ROLE imported_db.role_name TO ROLE local_role;
```

### Sharing Options Summary

| Option | Use Case |
|--------|----------|
| Direct Share | Same region, SQL, free, no metadata |
| Listing (Private) | Any region, auto-fulfill, metadata, optional paid |
| Listing (Marketplace) | Public, any region, paid/free, approval required |
| Data Exchange | Private marketplace, invite-only group |
| Data Clean Room | Controlled queries, no raw access |
| Reader Account | For non-Snowflake consumers, provider pays all costs |

---

*End of Snowflake Data Sharing Complete Guide*
