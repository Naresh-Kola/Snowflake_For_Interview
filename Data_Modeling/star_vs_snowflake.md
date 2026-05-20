# Data Engineering Interview Guide: Star vs Snowflake Schema

> Fact tables · Dimension tables · Real use cases · Advantages & Disadvantages · Interview Q&A

---

## 1. Core Building Blocks

### Fact Table

**What it is:** Stores measurable business events. One row = one transaction. The center of every dimensional model.

**SALES_FACT — Columns:**

| Column | Description |
|--------|-------------|
| `order_fact_key` | Surrogate primary key |
| `date_key` | → date_dim |
| `customer_key` | → customer_dim |
| `product_key` | → product_dim |
| `revenue_amount` | Additive — SUM any dim ✓ |
| `quantity_sold` | Additive — SUM any dim ✓ |
| `discount_amount` | Additive — SUM any dim ✓ |
| `payment_method` | Degenerate dim |

**Key Characteristics:**
- **Grows fast:** Billions of rows — every transaction adds a row
- **Define grain first:** "1 row = 1 order line item" — always
- **No text descriptions:** Only keys, measures, degenerate dims

---

### Dimension Table

**What it is:** Stores descriptive context — the "who, what, where, when" surrounding every fact. Filters & slicers for analysis.

**CUSTOMER_DIM — Columns:**

| Column | Description |
|--------|-------------|
| `customer_key` | Surrogate key (SK) |
| `customer_id` | Natural key from CRM |
| `full_name` | Descriptive attribute |
| `city, state, country` | Denormalized geography |
| `customer_segment` | Retail / Wholesale / B2B |
| `loyalty_tier` | Silver / Gold / Platinum |
| `effective_start_date` | SCD Type 2 — track history |
| `is_current` | 1=current, 0=historical |

**Key Characteristics:**
- **Small & wide:** Few rows, many descriptive columns
- **SCD Type 2:** Track history — "city at time of order"
- **Date dim:** Pre-build with fiscal quarters & holiday flags

---

## 2. Schema Architecture — Visual Diagrams & Deep Dive

### ⭐ Star Schema (Denormalized)

**Fact table at center.** Dimension tables connect directly — one JOIN away. All attributes stored flat in one dimension row.

```
            ┌──────────┐
            │ Date dim │
            └────┬─────┘
                 │
┌──────────┐    │    ┌─────────────┐
│ Customer ├────┼────┤  Sales Fact  │
└──────────┘    │    └──────┬──────┘
                │           │
            ┌───┴────┐  ┌──┴───────┐
            │  Store  │  │ Product  │
            │   dim   │  │   dim    │
            └─────────┘  └──────────┘
```

**Advantages ✅**
- **Faster queries:** Only 2–4 JOINs — BI tools love it
- **Analyst-friendly:** Simple SQL, no deep join chains
- **BI optimized:** Power BI, Tableau designed for this
- **Easy ETL:** Fewer tables, simpler pipelines

**Disadvantages ❌**
- **Data redundancy:** "Mumbai" repeated in millions of rows
- **Flat only:** Cannot model deep 4+ level hierarchies

---

### ❄️ Snowflake Schema (Normalized)

**Dimensions split into sub-dimensions** — removes redundancy. Dimensions reference other dimensions, forming a branching snowflake structure.

```
                    ┌──────────┐
            ┌──────┤   City   │
            │      └──────────┘
┌────────┐  │      ┌──────────┐
│  Date  ├──┘  ┌───┤  Brand   │
└───┬────┘     │   └──────────┘
    │          │
    │    ┌─────┴────┐    ┌──────────┐
    ├────┤Sales Fact ├────┤ Customer │
    │    └─────┬────┘    └──────────┘
    │          │
┌───┴────┐    │   ┌──────────┐
│ Month  │    └───┤ Product  │
└────────┘        └────┬─────┘
                       │
                  ┌────┴─────┐
                  │ Category │
                  └──────────┘
```

**Advantages ✅**
- **Storage efficient:** City stored once, referenced many
- **Data consistency:** Update city in one place only
- **Deep hierarchies:** Natural fit for 4–6 level hierarchies

**Disadvantages ❌**
- **Slower queries:** 4–6+ JOINs per query
- **Complex SQL:** Analysts need more expertise
- **BI friction:** Power BI says "Less Preferred"

---

## 3. Full Feature Comparison

| Feature | ⭐ Star Schema | ❄️ Snowflake Schema |
|---------|---------------|---------------------|
| Structure | Simple — denormalized | Complex — normalized |
| Number of tables | Fewer tables | More tables (sub-dims) |
| Joins per query | 2–4 joins | 4–6+ joins |
| Query speed | Faster | Slower |
| Storage cost | Higher — redundant data | Lower — no redundancy |
| Data consistency | Update risk | Single source of truth |
| Hierarchy support | Flat only | Deep hierarchies ✓ |
| Analyst complexity | Simple — beginner-friendly | Complex — SQL expertise |
| Power BI / Tableau | Excellent — Recommended | OK with mat. views |
| DAX / Measures | Easy & intuitive | Hard — ambiguous paths |
| Best used for | BI dashboards & analytics | Enterprise DWH |

---

## 4. When to Choose Which Schema

### ⭐ Choose Star When...

- Team uses **Power BI, Tableau, Looker**
- **Query speed** is the top priority
- Dimension hierarchies are **1–3 levels** deep
- **Retail, fintech, SaaS, hospitality**
- Mixed SQL skill levels — keep it **simple**

### ❄️ Choose Snowflake When...

- **Deep hierarchies (4+ levels)** — BOM, telecom, medical
- **Storage cost** is a hard constraint
- **Consistency is non-negotiable** — regulatory systems
- **Healthcare, telecom, manufacturing, pharma**
- Engineering team writes queries, not analysts

---

## 5. Real-World Industry Use Cases

### ⭐ Star Schema Industries

| Industry | Companies | Use Case | Key Tables |
|----------|-----------|----------|------------|
| **Retail / E-commerce** | Amazon, Flipkart, Myntra | Daily sales dashboards — revenue by region, top products by week. Analysts use Tableau. Flat dims = fast answers without SQL expertise | `order_fact`, `customer_dim`, `product_dim`, `date_dim` |
| **Banking / Fintech** | HDFC, SBI, Paytm, Razorpay | Fraud detection on billions of transaction rows. Flat merchant_dim and account_dim makes filters and aggregations sub-second | `transaction_fact`, `account_dim`, `channel_dim` |
| **Hospitality / Travel** | OYO, MakeMyTrip, Airbnb | Occupancy & RevPAR dashboards queried hourly by revenue managers. Flat dimensions — no deep hierarchies needed | `booking_fact`, `property_dim`, `date_dim` |
| **EdTech / SaaS** | BYJU'S, Coursera, Unacademy | PMs track completion rate, drop-off, session duration by subject and device using Redash — simple SQL, no join chains | `session_fact`, `course_dim`, `user_dim` |

### ❄️ Snowflake Schema Industries

| Industry | Companies | Use Case | Key Tables |
|----------|-----------|----------|------------|
| **Healthcare** | Apollo, Medanta, NHS, Fortis | ICD-10 codes form 4-level deep hierarchies. Procedure → Sub-specialty → Specialty → Department. Legal consistency requirement | `procedure_dim`, `specialty_dim`, `dept_dim` |
| **Telecom** | Airtel, Jio, Vodafone | India's 22 telecom circles → zones → districts. Territory restructuring updates one row in geography_dim, not millions | `cdr_fact`, `circle_dim`, `region_dim` |
| **Manufacturing** | Tata Motors, Bosch, Mahindra | Bill of Materials (BOM) — a car has 6+ component levels. Components → Sub-assembly → Assembly → Product. Classic snowflake | `component_dim`, `assembly_dim` |
| **Pharma / Life Sciences** | Sun Pharma, Dr. Reddy's, Pfizer | Drug → Molecule → Therapeutic Area → Category. Reclassifications cascade correctly — normalization is non-negotiable for compliance | `drug_dim`, `molecule_dim`, `area_dim` |

---

## 6. Medallion Architecture — Where Schemas Live

> **Rule:** Schemas organize data for analytics. Bronze and Silver layers are raw and cleaned data — they never use star/snowflake structure.

### Bronze Layer — Raw Ingestion

Raw data as-is from source systems. Append-only. No transformation, no schema enforcement. JSON, CSV, Parquet from APIs and DB dumps.

- No star schema
- Append-only
- Raw JSON/CSV
- Schema-on-read

### Silver Layer — Cleaned & Conformed

Deduplicated, type-enforced, entity-resolved tables. Business rules applied. Tables are in 3NF or flat staging format. No analytical schema yet.

- No star schema
- SRF shaping
- Deduplication
- Schema enforcement

### Gold Layer — Analytics Ready ➡️ Star / ❄️ Snowflake Live Here

Fact and dimension tables materialized here for analysts/platforms. Star for BI-facing marts. Snowflake for complex enterprise hierarchies. Read-optimized only.

- ⭐ Snowflake schema
- Fact tables
- Dimension tables
- BI dashboards
- ML features

---

## 7. Common Beginner Mistakes

### ⚠️ Everything in one table
Mixing facts and dimensions in one wide table kills performance and makes slicing impossible.

**→ Always separate fact & dimension tables**

### ⚠️ Snowflake everywhere
Normalizing every dim when analysts run Tableau daily = broken DAX, confused filters, unhappy team.

**→ Default to star; snowflake only for deep hierarchies**

### ⚠️ Ignoring Date dimension
Raw timestamps in the fact table — you lose fiscal quarters, holiday flags, week numbers for reports.

**→ Build proper date_dim with fiscal periods**

### ⚠️ No grain defined
Building a fact table without deciding "one row = one what?" causes double-counting and broken aggregations.

**→ Define grain before writing DDL**

### ⚠️ Natural keys as FK
Using CRM `customer_id` in fact rows — when your CRM migrates, every fact row breaks instantly.

**→ Use warehouse surrogate integer keys**

### ⚠️ Ignoring SCD Type 2
Overwriting city (SCD Type 1) means historical reports show today's city, not city when order was placed.

**→ SCD Type 2 for historical analysis attributes**

---

## 8. Interview Questions & Model Answers

### Q: Why is star schema preferred in Power BI / Tableau?

Fewer JOINs = faster execution. BI tools generate SQL under the hood — each relationship adds a JOIN. Star also simplifies DAX and avoids ambiguous filter paths. **Microsoft explicitly recommends star schema in Power BI docs.**

---

### Q: When to choose snowflake over star?

When dimensions have **deep hierarchies (4+ levels)** — telecom territories, product BOM, medical codes. Also when storage cost is critical and an engineering team (not analysts) writes queries.

---

### Q: How do you identify a fact table?

(1) Multiple FKs pointing to dims, (2) contains numeric measures, (3) grows continuously with transactions, (4) sits at center of schema. Examples: sales, orders, transactions, events.

---

### Q: What is the grain of a fact table?

The grain defines **what one row represents**. Example: "one order line item." **Define grain before building the schema** — it determines which dimensions connect and prevents double-counting aggregations.

---

### Q: What is a degenerate dimension?

A dimension attribute stored **directly in the fact table** without a separate dim table. Example: order_id, invoice_number, payment_method. No attributes worth a separate table — just identifiers or low-cardinality codes.

---

### Q: Where do schemas sit in Medallion architecture?

Exclusively in the **Gold layer**. Bronze = raw ingestion. Silver = cleaned 3NF staging. Gold = Fact + dimension tables for BI. Gold layer is optimized for reads, never writes.

---

### Q: What is SCD Type 2 and when to use it?

Tracks historical changes by inserting a **new row** when an attribute changes, closing the old one. Use when you need "city at time of order." Columns: `effective_start_date`, `effective_end_date`, `is_current`.

---

### Q: What are additive, semi-additive, and non-additive measures?

- **Additive:** SUM across every dim — revenue, quantity. 
- **Semi-additive:** SUM some dims, not all — account balance (not across time). 
- **Non-additive:** Cannot SUM — ratios, percentages, and prices.

---

## 9. Additional Concepts

### Surrogate Keys vs Natural Keys

| Aspect | Surrogate Key | Natural Key |
|--------|--------------|-------------|
| Definition | System-generated integer (identity/sequence) | Business identifier (email, SSN, product_code) |
| Stability | Never changes | May change with source system migrations |
| Performance | Integer joins are faster | String comparisons are slower |
| Best practice | Always use in dimension tables | Keep as alternate key for lookups |

### Slowly Changing Dimensions (SCD) Types

| Type | Behavior | Use Case |
|------|----------|----------|
| **Type 0** | Never changes | Date of birth, original signup date |
| **Type 1** | Overwrite old value | Typo corrections, non-historical attributes |
| **Type 2** | Add new row, close old | Address history, tier changes, any audit-critical field |
| **Type 3** | Add new column (current + previous) | When only last change matters |
| **Type 4** | Separate history table | High-velocity changes (e.g., pricing) |
| **Type 6** | Hybrid (1+2+3) | Need current, previous, and full history |

### Conformed Dimensions

Dimensions shared across multiple fact tables ensuring consistent reporting. Example: A single `date_dim` used by sales_fact, inventory_fact, and shipping_fact ensures all reports align on fiscal calendar definitions.

### Junk Dimensions

Low-cardinality flags and indicators combined into a single dimension to avoid cluttering the fact table with dozens of flag columns. Example: `is_gift_wrapped`, `is_expedited`, `is_taxable` → combined into `order_flags_dim`.

### Role-Playing Dimensions

A single dimension table used multiple times in different contexts. Example: `date_dim` joined as `order_date`, `ship_date`, and `delivery_date` to the same fact table.

---

## 10. Quick Reference Card

```
Star Schema = Denormalized + Fast Queries + BI-Friendly + Redundant Storage
Snowflake Schema = Normalized + Storage Efficient + Deep Hierarchies + Complex SQL

Gold Rule: Star for dashboards, Snowflake for enterprise DWH with deep hierarchies.
Default: Always start with Star unless you have a compelling reason for Snowflake.
```

---

*Data Modeling Guide · Star & Snowflake Schema · Fact & Dimension Tables · Interview Reference*
