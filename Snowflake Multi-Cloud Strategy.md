# Snowflake Multi-Cloud Strategy — Complete Guide

## What is a Multi-Cloud Strategy?

A multi-cloud strategy means running your data platform across **more than one cloud provider** (AWS, Azure, GCP) simultaneously, rather than being locked into a single vendor. Snowflake is the **only major data platform** that runs as a truly native service on all three major clouds with identical functionality.

```
┌─────────────────────────────────────────────────────────────────┐
│                    SNOWFLAKE PLATFORM                            │
│                                                                 │
│   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐       │
│   │   AWS         │   │  Microsoft   │   │   Google     │       │
│   │   Amazon Web  │   │  Azure       │   │   Cloud      │       │
│   │   Services    │   │              │   │   Platform   │       │
│   │              │   │              │   │              │       │
│   │  US-West-2   │   │  East-US-2   │   │  US-Central1 │       │
│   │  US-East-1   │   │  West-Europe │   │  Europe-West2│       │
│   │  EU-West-1   │   │  Australia   │   │  Asia-NE1    │       │
│   │  AP-SE-1     │   │  Canada      │   │  ...         │       │
│   └──────────────┘   └──────────────┘   └──────────────┘       │
│                                                                 │
│   Same SQL. Same features. Same security. Everywhere.           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why Go Multi-Cloud?

| Reason | Problem It Solves |
|--------|-------------------|
| **Avoid vendor lock-in** | If AWS raises prices 30%, you can shift workloads to Azure/GCP |
| **Data residency & compliance** | GDPR requires EU data stays in EU — run Snowflake on Azure West Europe |
| **Disaster recovery** | AWS US-East-1 goes down (it has) — failover to Azure or GCP automatically |
| **Meet customers where they are** | Your client is on GCP, you're on AWS — share data cross-cloud with zero copy |
| **Best-of-breed cloud services** | Use AWS S3 for storage, Azure for ML, GCP for analytics — Snowflake bridges them |
| **M&A integration** | Acquired company uses Azure, you use AWS — Snowflake unifies without migration |

---

## How Snowflake Enables Multi-Cloud (6 Pillars)

### Pillar 1: Native Multi-Cloud Deployment

Snowflake runs as a **first-class native service** on all three clouds. It's not a VM running on someone else's cloud — it deeply integrates with each provider's storage and networking:

| Cloud | Storage Layer | Regions |
|-------|---------------|---------|
| AWS | Amazon S3 | 20+ regions globally |
| Azure | Azure Blob Storage | 15+ regions globally |
| GCP | Google Cloud Storage | 10+ regions globally |

**Key point:** You write SQL once. It runs identically on AWS, Azure, or GCP. No code changes, no dialect differences, no feature gaps between clouds.

---

### Pillar 2: Cross-Cloud Replication

Replicate databases, schemas, tables, users, roles, warehouses, and more from one cloud/region to another — automatically on a schedule.

**What can be replicated:**
- Databases (with all contained objects: tables, views, streams, tasks, policies, etc.)
- Shares
- Users and Roles (Business Critical+)
- Warehouses (Business Critical+)
- Integrations (Security, API, Notification, Storage)
- Network policies
- Resource monitors

```
┌──────────────────────┐        Replication        ┌──────────────────────┐
│  PRIMARY ACCOUNT      │ ────── Group ──────────→ │  SECONDARY ACCOUNT    │
│  AWS US-West-2        │   (auto-scheduled)       │  Azure East-US-2      │
│                       │                          │                       │
│  Database: ANALYTICS  │    Databases + Shares    │  Database: ANALYTICS  │
│  Roles: all           │    Users + Roles         │  Roles: all           │
│  Users: all           │    Warehouses            │  Users: all           │
│  Shares: SHARE_FIN    │    Network policies      │  Shares: SHARE_FIN    │
└──────────────────────┘                           └──────────────────────┘
```

**SQL to set this up:**

```sql
-- Step 1: On primary account (AWS), create a replication group
USE ROLE ACCOUNTADMIN;

CREATE REPLICATION GROUP RG_MULTI_CLOUD
    OBJECT_TYPES = DATABASES, SHARES, USERS, ROLES, WAREHOUSES
    ALLOWED_DATABASES = ANALYTICS, RAW_DATA
    ALLOWED_SHARES = SHARE_FINANCE
    ALLOWED_ACCOUNTS = MY_ORG.AZURE_ACCOUNT, MY_ORG.GCP_ACCOUNT
    REPLICATION_SCHEDULE = '10 MINUTE';

-- Step 2: On secondary account (Azure), create the replica
USE ROLE ACCOUNTADMIN;

CREATE REPLICATION GROUP RG_MULTI_CLOUD
    AS REPLICA OF MY_ORG.AWS_ACCOUNT.RG_MULTI_CLOUD;

-- Step 3: Manual refresh (first time) — subsequent refreshes are automatic
ALTER REPLICATION GROUP RG_MULTI_CLOUD REFRESH;
```

---

### Pillar 3: Cross-Cloud Failover (Business Continuity)

If your primary cloud region goes down, Snowflake can **automatically failover** to a secondary account on a different cloud. This is true disaster recovery across cloud providers.

**Failover groups** extend replication groups with the ability to promote a secondary to primary:

```
NORMAL STATE:
  AWS (Primary, read-write) ←──→ Azure (Secondary, read-only)

AWS OUTAGE:
  AWS (Down) ──✗──→ Azure (Promoted to Primary, read-write)

AWS RECOVERS:
  AWS (now Secondary) ←──→ Azure (Primary)
  You can failback when ready.
```

```sql
-- Create a failover group (instead of replication group)
CREATE FAILOVER GROUP FG_DR
    OBJECT_TYPES = DATABASES, SHARES, USERS, ROLES, WAREHOUSES, INTEGRATIONS
    ALLOWED_DATABASES = ANALYTICS, RAW_DATA
    ALLOWED_SHARES = SHARE_FINANCE
    ALLOWED_ACCOUNTS = MY_ORG.AZURE_ACCOUNT
    REPLICATION_SCHEDULE = '5 MINUTE';

-- On Azure (secondary): Create secondary failover group
CREATE FAILOVER GROUP FG_DR
    AS REPLICA OF MY_ORG.AWS_ACCOUNT.FG_DR;

-- DURING OUTAGE: Promote Azure to primary
ALTER FAILOVER GROUP FG_DR PRIMARY;

-- AFTER RECOVERY: Failback to AWS
-- (Run from AWS account after it recovers)
ALTER FAILOVER GROUP FG_DR PRIMARY;
```

**Edition requirements:**
| Feature | Standard | Enterprise | Business Critical |
|---------|----------|------------|-------------------|
| Database replication | Yes | Yes | Yes |
| Share replication | Yes | Yes | Yes |
| Replication Group | Yes | Yes | Yes |
| Full account replication | No | No | Yes |
| Failover Group | No | No | Yes |

---

### Pillar 4: Cross-Cloud Data Sharing

Share data with anyone on any cloud — **zero copy, real-time, no ETL**.

**Three methods:**

#### Method 1: Direct Sharing (Same Region)
```sql
-- Provider creates a share
CREATE SHARE SHARE_REVENUE_DATA;
GRANT USAGE ON DATABASE ANALYTICS TO SHARE SHARE_REVENUE_DATA;
GRANT USAGE ON SCHEMA ANALYTICS.FINANCE TO SHARE SHARE_REVENUE_DATA;
GRANT SELECT ON VIEW ANALYTICS.FINANCE.V_REVENUE TO SHARE SHARE_REVENUE_DATA;

-- Add consumer account
ALTER SHARE SHARE_REVENUE_DATA ADD ACCOUNTS = CONSUMER_ORG.CONSUMER_ACCT;
```

#### Method 2: Cross-Region Sharing (Different Cloud/Region)
```sql
-- Step 1: Replicate database + share to consumer's region
CREATE REPLICATION GROUP RG_SHARE_CROSS_CLOUD
    OBJECT_TYPES = DATABASES, SHARES
    ALLOWED_DATABASES = ANALYTICS
    ALLOWED_SHARES = SHARE_REVENUE_DATA
    ALLOWED_ACCOUNTS = MY_ORG.TARGET_REGION_ACCOUNT;

-- Step 2: On target region account, create replica + add local consumers
CREATE REPLICATION GROUP RG_SHARE_CROSS_CLOUD
    AS REPLICA OF MY_ORG.SOURCE_ACCOUNT.RG_SHARE_CROSS_CLOUD;

ALTER REPLICATION GROUP RG_SHARE_CROSS_CLOUD REFRESH;
ALTER SHARE SHARE_REVENUE_DATA ADD ACCOUNTS = CONSUMER_ORG.LOCAL_CONSUMER;
```

#### Method 3: Cross-Cloud Auto-Fulfillment (Marketplace)
For Snowflake Marketplace listings, **Cross-Cloud Auto-fulfillment** automatically replicates data to the consumer's region — no manual setup.

```sql
-- Check if auto-fulfillment is enabled
SELECT SYSTEM$IS_GLOBAL_DATA_SHARING_ENABLED_FOR_ACCOUNT();

-- Enable it (requires ORGADMIN)
SELECT SYSTEM$ENABLE_GLOBAL_DATA_SHARING_FOR_ACCOUNT('MY_ORG', 'MY_ACCOUNT');
```

---

### Pillar 5: Region-Specific Deployment for Compliance

Different regulations require data to reside in specific geographic regions:

| Regulation | Requirement | Snowflake Solution |
|------------|------------|-------------------|
| **GDPR** (EU) | EU citizen data stays in EU | Deploy on `AWS EU-West-1`, `Azure West-Europe`, or `GCP Europe-West2` |
| **CCPA** (California) | California resident data protection | Deploy on any US region |
| **Data localization laws** (India, China, Australia) | Data stays in-country | Deploy on region-specific Snowflake instances |
| **HIPAA** (Healthcare) | Protected health info | Use Business Critical Edition with Tri-Secret Secure |

**Strategy: Region-per-regulation with replication**

```
┌──────────────────────┐     ┌──────────────────────┐
│ EU DATA (GDPR)        │     │ US DATA (CCPA)        │
│ Azure West-Europe     │     │ AWS US-East-1          │
│ - EU customer PII     │     │ - US customer PII      │
│ - EU transactions     │     │ - US transactions      │
└──────────┬───────────┘     └──────────┬───────────┘
           │                            │
           │    Replicate aggregated     │
           │    (non-PII) data only      │
           ▼                            ▼
        ┌─────────────────────────────────┐
        │ GLOBAL ANALYTICS (Aggregated)    │
        │ GCP US-Central1                  │
        │ - Revenue by region (no PII)     │
        │ - Product metrics (no PII)       │
        │ - Executive dashboards           │
        └─────────────────────────────────┘
```

---

### Pillar 6: Multi-Cloud Cost Optimization

| Strategy | How It Helps |
|----------|-------------|
| **Negotiate across clouds** | Use Snowflake's cloud-agnostic pricing to negotiate better rates |
| **Right-place workloads** | Run ETL where your source data lives (same cloud = no egress fees) |
| **Use reserved capacity** | Snowflake capacity purchases work across clouds and regions |
| **Monitor cross-cloud costs** | Track replication costs separately from compute |

**Monitor replication costs:**

```sql
-- Replication cost history (last 30 days)
SELECT
    TO_DATE(START_TIME)   AS DATE,
    DATABASE_NAME,
    SUM(CREDITS_USED)     AS REPLICATION_CREDITS,
    SUM(BYTES_TRANSFERRED) / POWER(1024, 3) AS GB_TRANSFERRED
FROM SNOWFLAKE.ACCOUNT_USAGE.REPLICATION_GROUP_USAGE_HISTORY
WHERE START_TIME >= DATEADD('DAY', -30, CURRENT_TIMESTAMP())
GROUP BY 1, 2
ORDER BY 3 DESC;
```

---

## Multi-Cloud Architecture Patterns

### Pattern 1: Active-Passive DR
```
AWS (Active - all workloads) ──replicate──→ Azure (Passive - standby only)
```
- Cheapest. Azure account only consumes storage + replication credits.
- RPO depends on replication schedule (5-60 minutes typical).

### Pattern 2: Active-Active (Read)
```
AWS (Active - writes + reads) ──replicate──→ Azure (Active - reads only)
                                             GCP (Active - reads only)
```
- Writes happen on one cloud. Reads happen on all.
- BI users on Azure query the Azure replica — low latency.

### Pattern 3: Active-Active (Regional Write)
```
AWS US (writes US data) ──replicate──→ Azure EU (writes EU data)
                        ←─replicate──
```
- Each region owns its data. Aggregated views replicate everywhere.
- Most complex. Requires careful data partitioning to avoid conflicts.

---

## Summary: Decision Matrix

| Need | Snowflake Feature | Edition Required |
|------|-------------------|-----------------|
| Run on multiple clouds | Native multi-cloud deployment | Any |
| Replicate databases across clouds | Replication Groups | Standard+ |
| Auto-failover to another cloud | Failover Groups | Business Critical |
| Share data cross-cloud | Replication + Shares | Standard+ |
| Auto-fulfill marketplace listings cross-cloud | Cross-Cloud Auto-fulfillment | Standard+ |
| Replicate users, roles, warehouses | Account Replication | Business Critical |
| Data residency compliance | Region-specific deployment | Any |
| Encrypt with customer-managed keys | Tri-Secret Secure | Business Critical |
