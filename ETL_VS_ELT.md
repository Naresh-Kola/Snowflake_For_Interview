# ETL vs ELT — Complete Guide

---

## Definitions

### ETL (Extract → Transform → Load)

Data is extracted from sources, **transformed in a separate processing engine** (outside the warehouse), and then loaded into the destination in its final form.

```
┌──────────┐      ┌────────────────────────┐      ┌──────────────┐
│  SOURCE  │ ──→  │  TRANSFORM (external)  │ ──→  │  WAREHOUSE   │
│ (API, DB,│      │  Informatica, SSIS,    │      │  (clean data │
│  files)  │      │  Talend, DataStage     │      │   arrives)   │
└──────────┘      └────────────────────────┘      └──────────────┘
                  Data is cleaned, joined,
                  and shaped BEFORE loading.
```

The warehouse only stores the final, ready-to-query result. Heavy computation happens outside.

---

### ELT (Extract → Load → Transform)

Data is extracted from sources, **loaded raw into the warehouse first**, and then transformed inside the warehouse using its own compute power (SQL, dbt, stored procs).

```
┌──────────┐      ┌──────────────┐      ┌────────────────────────┐
│  SOURCE  │ ──→  │  WAREHOUSE   │ ──→  │  TRANSFORM (inside)    │
│ (API, DB,│      │  (raw data   │      │  SQL, dbt, Snowflake   │
│  files)  │      │   lands)     │      │  stored procs, tasks   │
└──────────┘      └──────────────┘      └────────────────────────┘
                  Raw data loaded        Warehouse compute does
                  as-is, fast.           the heavy lifting.
```

The warehouse stores raw data AND performs all transformations. This is the modern cloud-native approach.

---

## Side-by-Side Comparison

| Aspect | ETL | ELT |
|--------|-----|-----|
| **Transform location** | External server/engine | Inside the warehouse |
| **Data loaded as** | Clean, final form | Raw, as-is |
| **Compute for transforms** | Separate infrastructure (Informatica, SSIS, Spark) | Warehouse compute (Snowflake, BigQuery, Redshift) |
| **Raw data in warehouse?** | No — only transformed data | Yes — full raw history preserved |
| **Speed of ingestion** | Slower (transform before load) | Faster (load first, transform later) |
| **Scalability** | Limited by ETL server capacity | Scales with warehouse (elastic cloud compute) |
| **Cost model** | ETL tool license + server infra + warehouse | Warehouse compute only (+ tool like dbt, which is free OSS) |
| **Flexibility to re-transform** | Must re-extract from source and re-run pipeline | Re-run SQL on raw data already in warehouse |
| **Schema changes** | Require pipeline redesign | Just update the SQL/dbt model |
| **Best era** | On-premise, pre-cloud (2000s-2010s) | Cloud-native (2015+) |
| **Example tools** | Informatica, SSIS, Talend, DataStage, Ab Initio | dbt, Snowflake Tasks, Matillion, Fivetran + dbt |

---

## Why the Shift from ETL to ELT?

The shift happened because **cloud warehouses changed the economics**:

| Old World (On-Premise) | New World (Cloud) |
|------------------------|-------------------|
| Warehouse compute was expensive and fixed | Warehouse compute is elastic and pay-per-second |
| Storage was expensive | Storage is cheap ($23/TB/month on Snowflake) |
| Loading raw data = wasting precious warehouse resources | Loading raw data = cheap; transform with scalable compute on demand |
| Made sense to pre-transform to save warehouse capacity | Makes sense to load everything and transform inside |

**In Snowflake specifically**, ELT is the recommended approach because:
- You can spin up a dedicated `WH_TRANSFORM` warehouse just for transformations
- It auto-suspends when done (pay only for active compute)
- Storage is cheap — keep all raw data for re-processing
- SQL in Snowflake is massively parallel — transformations run fast
- Dynamic Tables and Streams+Tasks automate the "T" step

---

## Advantages & Disadvantages

### ETL Advantages

| Advantage | Explanation |
|-----------|-------------|
| **Less warehouse storage** | Only final data is stored; raw data never enters the warehouse |
| **Data quality enforced early** | Bad data is caught before it reaches the warehouse |
| **Compliance/privacy** | PII can be masked or removed before loading — sensitive data never enters the warehouse |
| **Mature tooling** | Decades of enterprise tools (Informatica, DataStage) with GUI-based pipelines |
| **Lower warehouse compute cost** | Warehouse only runs queries, not transforms |

### ETL Disadvantages

| Disadvantage | Explanation |
|--------------|-------------|
| **Slow iteration** | Changing a transform requires modifying the ETL pipeline, redeploying, re-extracting |
| **Bottleneck on ETL server** | Transform server is fixed capacity — can't elastically scale like cloud warehouse |
| **Raw data lost** | If you need to re-transform or fix a bug, you must re-extract from source (which may have changed) |
| **High tool cost** | Enterprise ETL tools cost $100K-$1M+/year in licenses |
| **Complex infrastructure** | Separate servers, scheduling, monitoring for the ETL layer |
| **Longer time to insight** | Data must pass through transform before anyone can query it |
| **Tight coupling** | Source schema change → ETL pipeline breaks → warehouse gets no data |

---

### ELT Advantages

| Advantage | Explanation |
|-----------|-------------|
| **Fast ingestion** | Load raw data immediately — no waiting for transforms. Analysts can see data in minutes |
| **Raw data preserved** | Full history in the warehouse. Re-transform anytime without re-extracting |
| **Elastic compute** | Snowflake scales transforms horizontally. Need more power? Resize warehouse for 5 minutes |
| **Schema flexibility** | Store semi-structured data (JSON, Parquet) as VARIANT. Parse later when you understand it |
| **Faster iteration** | Fix a transform bug? Just update the SQL and re-run. No pipeline redeployment |
| **Lower tool cost** | dbt (free OSS) + Snowflake compute replaces $500K ETL licenses |
| **Version control** | SQL transforms live in Git. Code review, CI/CD, branching — full software engineering practices |
| **Replayability** | Raw data + transform SQL = you can reproduce any historical state |

### ELT Disadvantages

| Disadvantage | Explanation |
|--------------|-------------|
| **Higher storage cost** | Raw data stored in warehouse (mitigated by cheap cloud storage) |
| **Raw data exposure risk** | Sensitive/PII data lands in warehouse before masking. Requires RBAC + masking policies |
| **Warehouse compute cost** | Transforms consume warehouse credits (but elastic scaling makes this manageable) |
| **Data quality delayed** | Bad data enters the warehouse first — must catch it in the transform or downstream testing layer |
| **Requires warehouse expertise** | Teams need strong SQL skills (dbt, window functions, CTEs) vs GUI-based ETL tools |
| **Governance complexity** | More data in warehouse = more to govern, tag, classify, mask |

---

## When to Use Which

### Use ETL When:
- **Regulatory compliance** requires PII never enters the warehouse (e.g., HIPAA, strict GDPR interpretation)
- Source data is extremely dirty and you need **quality gates before loading**
- You're on **on-premise infrastructure** with fixed warehouse capacity
- You already have **mature ETL pipelines** and the cost to migrate is too high
- Transform logic is **extremely complex** and better suited to a programming language (Java, Python) than SQL

### Use ELT When:
- You're on a **cloud data warehouse** (Snowflake, BigQuery, Redshift, Databricks)
- You want **fast time to insight** — load first, ask questions later
- You need to **preserve raw data** for auditing, reprocessing, or ML
- Your team has **strong SQL skills** and uses dbt or similar
- Data sources are **semi-structured** (JSON, Avro, Parquet) and need flexible parsing
- You want **version-controlled, testable transforms** (dbt + Git)

### Use Hybrid (ETL + ELT) When:
- Some sources need **pre-processing** (e.g., PII removal, file format conversion) before loading
- Heavy transforms are done in the warehouse, but **sensitive data** is masked externally first
- This is the **most common real-world pattern** — Fivetran (Extract+Load) → Snowflake (raw) → dbt (Transform)

---

## Real-World Architecture: Modern ELT Stack

```
┌─────────────┐     ┌─────────────┐     ┌──────────────────────────────┐
│ SOURCES      │     │ INGESTION   │     │ SNOWFLAKE                     │
│              │     │             │     │                               │
│ Postgres DB ─┼──→  │ Fivetran    │──→  │ RAW layer (Bronze)            │
│ Salesforce  ─┼──→  │ Airbyte     │     │  └─ raw JSON/CSV as-is       │
│ Stripe API  ─┼──→  │ Snowpipe    │     │                               │
│ S3 files    ─┼──→  │             │     │ STAGING layer (Silver)        │
│ Kafka       ─┼──→  │             │     │  └─ dbt models: clean, dedup  │
└─────────────┘     └─────────────┘     │                               │
                                         │ ANALYTICS layer (Gold)        │
                                         │  └─ dbt models: facts + dims  │
                                         │                               │
                                         │ PRESENTATION layer            │
                                         │  └─ Secure views for BI tools │
                                         └──────────────────────────────┘
                                                       │
                                                       ▼
                                              ┌──────────────────┐
                                              │ BI / CONSUMERS    │
                                              │ Tableau, Looker,  │
                                              │ PowerBI, Analysts │
                                              └──────────────────┘
```

---

## Summary

```
Is your warehouse cloud-based with elastic compute?
  │
  ├── NO  → ETL (transform before loading to conserve warehouse resources)
  │
  └── YES → Does sensitive data need to be removed BEFORE entering the warehouse?
              │
              ├── YES → Hybrid (ETL for sensitive sources, ELT for the rest)
              │
              └── NO  → ELT (load raw, transform inside warehouse with dbt/SQL)
```

**For Snowflake users: ELT is the recommended and most cost-effective approach.** Snowflake's architecture (elastic compute, cheap storage, per-second billing, Dynamic Tables, Streams+Tasks) was specifically designed for ELT workflows.
