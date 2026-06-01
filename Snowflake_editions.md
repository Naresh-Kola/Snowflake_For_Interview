# Snowflake Editions: Standard vs Enterprise vs Business Critical vs VPS

## Overview

Snowflake has **4 editions**, each building on the previous one:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│   VPS (Virtual Private Snowflake)    ← Highest security         │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │                                                         │   │
│   │   Business Critical              ← Compliance/regulated │   │
│   │   ┌─────────────────────────────────────────────────┐   │   │
│   │   │                                                 │   │   │
│   │   │   Enterprise                  ← Large orgs      │   │   │
│   │   │   ┌─────────────────────────────────────────┐   │   │   │
│   │   │   │                                         │   │   │   │
│   │   │   │   Standard               ← Entry level  │   │   │   │
│   │   │   │                                         │   │   │   │
│   │   │   └─────────────────────────────────────────┘   │   │   │
│   │   │                                                 │   │   │
│   │   └─────────────────────────────────────────────────┘   │   │
│   │                                                         │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Quick Comparison

| Feature | Standard | Enterprise | Business Critical | VPS |
|---------|----------|------------|-------------------|-----|
| **Price** | $ | $$ | $$$ | $$$$ |
| **Time Travel** | 1 day | Up to 90 days | Up to 90 days | Up to 90 days |
| **Multi-cluster WH** | ❌ | ✅ | ✅ | ✅ |
| **Materialized Views** | ❌ | ✅ | ✅ | ✅ |
| **Search Optimization** | ❌ | ✅ | ✅ | ✅ |
| **Column Masking** | ❌ | ✅ | ✅ | ✅ |
| **Row Access Policies** | ❌ | ✅ | ✅ | ✅ |
| **Data Classification** | ❌ | ✅ | ✅ | ✅ |
| **Tri-Secret Secure (BYOK)** | ❌ | ❌ | ✅ | ✅ |
| **Private Connectivity** | ❌ | ❌ | ✅ | ✅ |
| **Failover/Failback** | ❌ | ❌ | ✅ | ✅ |
| **HIPAA/PCI Compliance** | ❌ | ❌ | ✅ | ✅ |
| **Dedicated Resources** | ❌ | ❌ | ❌ | ✅ |

---

## Edition Details

### 1. Standard Edition

**Who it's for:** Small teams, startups, dev/test environments, non-sensitive data.

**What you get:**
- Full SQL support, all data types
- Snowpipe, Streams, Tasks
- 1 day Time Travel
- Fail-Safe (7 days)
- Basic encryption (automatic)
- Network policies
- MFA support
- All connectors (JDBC, ODBC, Python, etc.)
- Snowpark, Streamlit, Cortex AI
- Database replication

**What you DON'T get:**
- No extended Time Travel (max 1 day)
- No multi-cluster warehouses
- No materialized views
- No search optimization
- No column/row security policies
- No data classification

---

### 2. Enterprise Edition

**Who it's for:** Large organizations needing performance optimization and data governance.

**What you get (in addition to Standard):**
- **Extended Time Travel** — up to 90 days
- **Multi-cluster warehouses** — auto-scale for concurrency
- **Materialized Views** — pre-computed query results
- **Search Optimization Service** — fast point lookups
- **Query Acceleration Service** — serverless burst compute
- **Column-level Security** — masking policies
- **Row-level Security** — row access policies
- **Aggregation policies** — enforce privacy
- **Projection policies** — restrict column access
- **Data Classification** — detect PII automatically
- **Access History** — audit who queried what
- **Periodic rekeying** — enhanced encryption rotation

---

### 3. Business Critical Edition

**Who it's for:** Healthcare, financial services, government — anyone with strict compliance needs.

**What you get (in addition to Enterprise):**
- **Tri-Secret Secure (BYOK)** — customer-managed encryption keys
- **Private Connectivity** — AWS PrivateLink / Azure Private Link / GCP Private Service Connect
- **Account Failover/Failback** — disaster recovery across regions
- **Client Redirect** — redirect apps to DR account
- **HIPAA & HITRUST compliance** — for PHI data
- **PCI DSS compliance** — for payment card data
- **FedRAMP compliance** — for government workloads
- **Replication of all objects** — users, roles, warehouses, integrations
- **Network rule replication**

---

### 4. Virtual Private Snowflake (VPS)

**Who it's for:** Banks, intelligence agencies, defense contractors — highest security requirements.

**What you get (in addition to Business Critical):**
- **Completely isolated environment** — no shared infrastructure with other Snowflake customers
- **Dedicated metadata store** — separate from all other accounts
- **Dedicated compute pool** — no resource sharing
- **Full encryption of internal transmissions** — even between internal components
- **Custom account locator format**

---

## Feature Categories by Edition

### Security & Governance

| Feature | Std | Ent | BC | VPS |
|---------|-----|-----|-----|-----|
| Automatic encryption | ✅ | ✅ | ✅ | ✅ |
| Network policies | ✅ | ✅ | ✅ | ✅ |
| MFA | ✅ | ✅ | ✅ | ✅ |
| SSO / OAuth | ✅ | ✅ | ✅ | ✅ |
| Object-level access control | ✅ | ✅ | ✅ | ✅ |
| Column masking policies | ❌ | ✅ | ✅ | ✅ |
| Row access policies | ❌ | ✅ | ✅ | ✅ |
| Data classification (PII) | ❌ | ✅ | ✅ | ✅ |
| Access history auditing | ❌ | ✅ | ✅ | ✅ |
| Tri-Secret Secure (BYOK) | ❌ | ❌ | ✅ | ✅ |
| Private connectivity | ❌ | ❌ | ✅ | ✅ |
| Dedicated infrastructure | ❌ | ❌ | ❌ | ✅ |

### Performance & Optimization

| Feature | Std | Ent | BC | VPS |
|---------|-----|-----|-----|-----|
| Clustering keys | ✅ | ✅ | ✅ | ✅ |
| Query Acceleration | ✅ | ✅ | ✅ | ✅ |
| Multi-cluster warehouses | ❌ | ✅ | ✅ | ✅ |
| Materialized views | ❌ | ✅ | ✅ | ✅ |
| Search Optimization | ❌ | ✅ | ✅ | ✅ |

### Data Protection & Recovery

| Feature | Std | Ent | BC | VPS |
|---------|-----|-----|-----|-----|
| Time Travel (1 day) | ✅ | ✅ | ✅ | ✅ |
| Fail-Safe (7 days) | ✅ | ✅ | ✅ | ✅ |
| Extended Time Travel (90 days) | ❌ | ✅ | ✅ | ✅ |
| Periodic rekeying | ❌ | ✅ | ✅ | ✅ |
| Account failover/failback | ❌ | ❌ | ✅ | ✅ |
| Client redirect (DR) | ❌ | ❌ | ✅ | ✅ |

### Compliance

| Standard | Std | Ent | BC | VPS |
|----------|-----|-----|-----|-----|
| SOC 2 Type II | ✅ | ✅ | ✅ | ✅ |
| HIPAA / HITRUST | ❌ | ❌ | ✅ | ✅ |
| PCI DSS | ❌ | ❌ | ✅ | ✅ |
| FedRAMP | ❌ | ❌ | ✅ | ✅ |
| IRAP (Protected) | ❌ | ❌ | ✅ | ✅ |

---

## Real-World: Who Uses What?

| Edition | Typical Customer |
|---------|-----------------|
| Standard | Startups, small analytics teams, dev/test, non-sensitive data |
| Enterprise | Mid-large companies, data governance needed, performance-sensitive |
| Business Critical | Healthcare (PHI), banks (PCI), government (FedRAMP), insurance |
| VPS | Top-tier banks, defense/intel, organizations requiring full isolation |

---

## Cost Comparison (Approximate)

Credit costs vary by region. Enterprise is typically ~1.5-2x Standard pricing.

| Edition | On-Demand ($/credit) | Notes |
|---------|---------------------|-------|
| Standard | ~$2-3 | Lowest cost |
| Enterprise | ~$3-4 | ~50% more than Standard |
| Business Critical | ~$4-5 | ~30% more than Enterprise |
| VPS | Custom pricing | Contact Snowflake |

*Exact pricing depends on cloud provider (AWS/Azure/GCP) and region.*

---

## How to Check Your Edition

```sql
SELECT CURRENT_ACCOUNT(), SYSTEM$GET_SNOWFLAKE_PLATFORM_INFO();

-- Or
SELECT edition
FROM SNOWFLAKE.ORGANIZATION_USAGE.ACCOUNTS
WHERE account_name = CURRENT_ACCOUNT();
```

---

## Key Decision Points

**Choose Standard if:**
- Budget-conscious, non-regulated data
- 1 day of Time Travel is sufficient
- No need for column/row masking

**Choose Enterprise if:**
- Need extended Time Travel (compliance/audit)
- Need multi-cluster for concurrency
- Need materialized views or search optimization
- Need data masking / row-level security

**Choose Business Critical if:**
- Store PHI, PCI, or government data
- Need private connectivity (no public internet)
- Need customer-managed encryption keys
- Need cross-region disaster recovery

**Choose VPS if:**
- Cannot share ANY infrastructure with other customers
- Strictest regulatory requirements (defense, intelligence)
- Need dedicated metadata and compute isolation
