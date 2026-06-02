# Centene Healthcare Domain — Star Schema Design

## Overview

This document describes a **Star Schema** for the **Centene Corporation** healthcare domain. Centene is a managed care organization (MCO) operating across Medicaid, Medicare, CHIP, and Marketplace lines of business. The schema is designed for an **enterprise data warehouse (EDW)** supporting analytics, quality reporting (HEDIS), claims adjudication, member management, and provider network performance.

The schema consists of **1 central Fact Table** and **9 Dimension Tables**, following Ralph Kimball's dimensional modeling principles.

---

## Schema Diagram (Conceptual)

```
                    ┌──────────────────┐
                    │  DIM_DATE        │
                    └────────┬─────────┘
                             │
     ┌────────────┐   ┌──────┴──────────────┐   ┌─────────────────┐
     │ DIM_MEMBER ├───┤                      ├───┤  DIM_PROVIDER   │
     └────────────┘   │   FACT_CLAIMS        │   └─────────────────┘
                      │   (Central Fact)     │
     ┌────────────┐   │                      │   ┌─────────────────┐
     │ DIM_PLAN   ├───┤                      ├───┤  DIM_DIAGNOSIS  │
     └────────────┘   └──────┬──────────────┘   └─────────────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
┌───────┴──────┐   ┌─────────┴──────┐   ┌────────┴──────────┐
│ DIM_FACILITY │   │ DIM_PROCEDURE  │   │ DIM_GEOGRAPHY     │
└──────────────┘   └────────────────┘   └───────────────────┘
                             │
                   ┌─────────┴──────┐
                   │ DIM_PHARMACY   │
                   └────────────────┘
```

---

## Tables

### 1. FACT_CLAIMS *(Central Fact Table)*

The central fact table capturing every adjudicated claim — medical, behavioral, pharmacy — submitted to Centene's health plans.

| Column Name              | Data Type     | Description                                      |
|--------------------------|---------------|--------------------------------------------------|
| `claim_key`              | BIGINT (PK)   | Surrogate primary key                            |
| `member_key`             | INT (FK)      | Reference to DIM_MEMBER                          |
| `provider_key`           | INT (FK)      | Reference to DIM_PROVIDER                        |
| `facility_key`           | INT (FK)      | Reference to DIM_FACILITY                        |
| `plan_key`               | INT (FK)      | Reference to DIM_PLAN                            |
| `diagnosis_key`          | INT (FK)      | Reference to DIM_DIAGNOSIS (primary diagnosis)   |
| `procedure_key`          | INT (FK)      | Reference to DIM_PROCEDURE                       |
| `pharmacy_key`           | INT (FK)      | Reference to DIM_PHARMACY (null for medical)     |
| `geography_key`          | INT (FK)      | Reference to DIM_GEOGRAPHY                       |
| `service_date_key`       | INT (FK)      | Reference to DIM_DATE (date of service)          |
| `paid_date_key`          | INT (FK)      | Reference to DIM_DATE (date claim paid)          |
| `claim_id`               | VARCHAR(30)   | Original claim identifier from source system     |
| `claim_type_cd`          | VARCHAR(10)   | M=Medical, P=Pharmacy, B=Behavioral              |
| `claim_status_cd`        | VARCHAR(10)   | PAID, DENIED, PENDED, ADJUSTED                   |
| `billed_amount`          | DECIMAL(12,2) | Amount billed by provider                        |
| `allowed_amount`         | DECIMAL(12,2) | Contracted allowed amount                        |
| `paid_amount`            | DECIMAL(12,2) | Amount actually paid to provider                 |
| `member_copay_amount`    | DECIMAL(12,2) | Member cost-sharing / copay                      |
| `member_deductible_amt`  | DECIMAL(12,2) | Applied toward member deductible                 |
| `coinsurance_amount`     | DECIMAL(12,2) | Member coinsurance portion                       |
| `units_of_service`       | DECIMAL(8,2)  | Units, days, or quantity dispensed               |
| `drg_code`               | VARCHAR(10)   | Diagnosis Related Group (inpatient only)         |
| `place_of_service_cd`    | VARCHAR(5)    | CMS place-of-service code (11=Office, 21=IP, …)  |
| `lob_cd`                 | VARCHAR(20)   | Line of Business: Medicaid, Medicare, Marketplace|
| `authorization_id`       | VARCHAR(30)   | Prior authorization reference (if required)      |
| `capitation_flag`        | CHAR(1)       | Y if claim is capitated, N if FFS                |
| `fraud_score`            | DECIMAL(5,4)  | Predictive fraud/waste/abuse score (0–1)         |

**Grain:** One row per claim line (or claim header for pharmacy).

---

### 2. DIM_MEMBER

Slowly Changing Dimension (SCD Type 2) tracking member enrollment and demographics over time.

| Column Name              | Data Type   | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `member_key`             | INT (PK)    | Surrogate key                                     |
| `member_id`              | VARCHAR(20) | Source system member identifier                   |
| `medicaid_id`            | VARCHAR(20) | State Medicaid ID (if applicable)                 |
| `medicare_id`            | VARCHAR(12) | Medicare Beneficiary Identifier (MBI)             |
| `first_name`             | VARCHAR(50) | Member first name                                 |
| `last_name`              | VARCHAR(50) | Member last name                                  |
| `date_of_birth`          | DATE        | Member date of birth                              |
| `gender_cd`              | CHAR(1)     | M / F / U (Unknown)                               |
| `race_cd`                | VARCHAR(10) | Race/ethnicity code (USCDI standard)              |
| `language_cd`            | VARCHAR(10) | Preferred language (ISO 639)                      |
| `enrollment_start_dt`    | DATE        | Effective start of enrollment                     |
| `enrollment_end_dt`      | DATE        | Effective end of enrollment (null = active)       |
| `dual_eligible_flag`     | CHAR(1)     | Y if dual Medicaid+Medicare                       |
| `risk_score`             | DECIMAL(6,4)| HCC risk adjustment score                         |
| `pcp_provider_id`        | VARCHAR(20) | Assigned Primary Care Provider                    |
| `care_management_flag`   | CHAR(1)     | Y if enrolled in care management program          |
| `chronic_condition_cnt`  | INT         | Count of chronic conditions (HEDIS measure input) |
| `row_effective_dt`       | DATE        | SCD2 row effective date                           |
| `row_expiry_dt`          | DATE        | SCD2 row expiry date                              |
| `current_flag`           | CHAR(1)     | Y if current record                               |

---

### 3. DIM_PROVIDER

Providers (physicians, specialists, hospitals, behavioral health) contracted or non-contracted with Centene plans.

| Column Name              | Data Type   | Description                                      |
|--------------------------|-------------|--------------------------------------------------|
| `provider_key`           | INT (PK)    | Surrogate key                                    |
| `npi`                    | CHAR(10)    | National Provider Identifier                     |
| `provider_name`          | VARCHAR(100)| Individual or organization name                  |
| `provider_type_cd`       | VARCHAR(20) | MD, DO, NP, PA, LCSW, Hospital, etc.             |
| `specialty_cd`           | VARCHAR(10) | CMS specialty code                               |
| `specialty_desc`         | VARCHAR(100)| Specialty description                            |
| `taxonomy_cd`            | VARCHAR(15) | NUCC taxonomy code                               |
| `group_npi`              | CHAR(10)    | Organizational NPI (if group practice)           |
| `network_flag`           | CHAR(1)     | Y=In-network, N=Out-of-network                   |
| `network_tier_cd`        | VARCHAR(10) | TIER1, TIER2, PREFERRED                          |
| `contract_type_cd`       | VARCHAR(20) | FFS, Capitated, Value-Based, Bundled              |
| `pcmh_flag`              | CHAR(1)     | Y if Patient-Centered Medical Home designation   |
| `quality_score`          | DECIMAL(4,2)| Provider quality performance score               |
| `credentialing_status`   | VARCHAR(20) | ACTIVE, PENDING, TERMINATED                      |
| `state_license_cd`       | VARCHAR(5)  | State of primary licensure                       |

---

### 4. DIM_PLAN

Health plan and benefit package details across Centene's lines of business and states.

| Column Name              | Data Type   | Description                                      |
|--------------------------|-------------|--------------------------------------------------|
| `plan_key`               | INT (PK)    | Surrogate key                                    |
| `plan_id`                | VARCHAR(20) | CMS or state-assigned plan ID                    |
| `plan_name`              | VARCHAR(100)| Full plan name (e.g., "Ambetter from Sunshine")  |
| `plan_type_cd`           | VARCHAR(20) | HMO, PPO, EPO, PFFS, PACE                       |
| `lob_cd`                 | VARCHAR(20) | Medicaid, Medicare, CHIP, Marketplace, Tricare   |
| `state_cd`               | CHAR(2)     | State where plan is offered                      |
| `subsidiary_name`        | VARCHAR(100)| Centene subsidiary (Sunshine, WellCare, etc.)    |
| `metal_tier_cd`          | VARCHAR(10) | Bronze/Silver/Gold/Platinum (ACA plans)          |
| `formulary_id`           | VARCHAR(20) | Pharmacy formulary identifier                    |
| `deductible_individual`  | DECIMAL(8,2)| Individual annual deductible                     |
| `oop_max_individual`     | DECIMAL(8,2)| Individual out-of-pocket maximum                 |
| `contract_year`          | INT         | CMS contract year                               |
| `star_rating`            | DECIMAL(3,1)| CMS Star Quality Rating (Medicare plans)         |
| `effective_dt`           | DATE        | Plan effective date                              |
| `termination_dt`         | DATE        | Plan termination date (null = active)            |

---

### 5. DIM_DIAGNOSIS

Clinical diagnosis codes based on ICD-10-CM standard.

| Column Name              | Data Type   | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `diagnosis_key`          | INT (PK)    | Surrogate key                                     |
| `icd10_code`             | VARCHAR(10) | ICD-10-CM diagnosis code (e.g., E11.9)            |
| `icd10_description`      | VARCHAR(255)| Full ICD-10 diagnosis description                 |
| `icd9_crosswalk`         | VARCHAR(10) | Legacy ICD-9 equivalent (for historical data)     |
| `chapter_cd`             | VARCHAR(5)  | ICD-10 chapter code                               |
| `chapter_desc`           | VARCHAR(100)| Chapter description (e.g., "Endocrine Diseases")  |
| `category_cd`            | VARCHAR(10) | 3-digit category code (e.g., E11)                 |
| `category_desc`          | VARCHAR(100)| Category description                              |
| `hcc_category_cd`        | VARCHAR(10) | CMS Hierarchical Condition Category code          |
| `hcc_description`        | VARCHAR(100)| HCC category description                         |
| `chronic_condition_flag` | CHAR(1)     | Y if CDC chronic condition definition             |
| `behavioral_health_flag` | CHAR(1)     | Y if behavioral/mental health diagnosis           |
| `sdoh_flag`              | CHAR(1)     | Y if Social Determinants of Health code (Z55-Z65) |
| `hedis_measure_cd`       | VARCHAR(20) | NCQA HEDIS measure association (if applicable)    |

---

### 6. DIM_PROCEDURE

Medical and surgical procedures based on CPT-4, HCPCS Level II, and ICD-10-PCS codes.

| Column Name              | Data Type   | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `procedure_key`          | INT (PK)    | Surrogate key                                     |
| `procedure_code`         | VARCHAR(10) | CPT/HCPCS/ICD-10-PCS code                        |
| `code_type_cd`           | VARCHAR(10) | CPT4, HCPCS, ICD10PCS                            |
| `procedure_desc`         | VARCHAR(255)| Full procedure description                        |
| `modifier_1`             | VARCHAR(5)  | First procedure modifier                          |
| `modifier_2`             | VARCHAR(5)  | Second procedure modifier                         |
| `category_cd`            | VARCHAR(20) | E/M, Surgery, Radiology, Lab, Medicine, etc.      |
| `revenue_code`           | VARCHAR(10) | UB-04 revenue code (for facility claims)          |
| `preventive_flag`        | CHAR(1)     | Y if preventive/wellness service                  |
| `hedis_measure_cd`       | VARCHAR(20) | HEDIS measure (e.g., BCS, COL, CDC)               |
| `quality_gap_flag`       | CHAR(1)     | Y if closure of a HEDIS care gap                  |
| `surgery_flag`           | CHAR(1)     | Y if surgical procedure                           |
| `telehealth_flag`        | CHAR(1)     | Y if telehealth-eligible procedure                |

---

### 7. DIM_FACILITY

Healthcare facilities where services are rendered — hospitals, clinics, SNFs, behavioral health centers.

| Column Name              | Data Type   | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `facility_key`           | INT (PK)    | Surrogate key                                     |
| `facility_npi`           | CHAR(10)    | Facility National Provider Identifier             |
| `facility_name`          | VARCHAR(150)| Facility name                                     |
| `facility_type_cd`       | VARCHAR(20) | Hospital, SNF, ASC, FQHC, BH Center, Urgent Care |
| `cms_certification_num`  | VARCHAR(10) | Medicare CCN (formerly Provider #)                |
| `bed_count`              | INT         | Licensed bed count (hospitals/SNFs)               |
| `trauma_level_cd`        | VARCHAR(5)  | Trauma center designation (I, II, III, IV)        |
| `teaching_flag`          | CHAR(1)     | Y if teaching/academic medical center             |
| `network_flag`           | CHAR(1)     | Y=In-network, N=Out-of-network                    |
| `joint_commission_flag`  | CHAR(1)     | Y if Joint Commission accredited                  |
| `address_line_1`         | VARCHAR(100)| Street address                                    |
| `city`                   | VARCHAR(50) | City                                              |
| `state_cd`               | CHAR(2)     | State code                                        |
| `zip_code`               | VARCHAR(10) | ZIP+4 postal code                                 |
| `county_cd`              | VARCHAR(10) | FIPS county code                                  |

---

### 8. DIM_PHARMACY

Pharmaceutical products dispensed through Centene's PBM (Envolve Pharmacy Solutions).

| Column Name              | Data Type   | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `pharmacy_key`           | INT (PK)    | Surrogate key                                     |
| `ndc_code`               | VARCHAR(11) | National Drug Code (11-digit)                     |
| `drug_name`              | VARCHAR(100)| Brand or generic drug name                        |
| `generic_name`           | VARCHAR(100)| Generic (INN) name                               |
| `brand_name`             | VARCHAR(100)| Brand/trade name                                  |
| `generic_flag`           | CHAR(1)     | Y if generic, N if brand                         |
| `drug_class_cd`          | VARCHAR(20) | Pharmacological class code                        |
| `drug_class_desc`        | VARCHAR(100)| Class description (e.g., "ACE Inhibitors")        |
| `formulary_tier_cd`      | VARCHAR(10) | Tier 1 (Generic), Tier 2 (Preferred), etc.        |
| `controlled_substance_cd`| VARCHAR(5)  | DEA Schedule (II–V) or null                       |
| `opioid_flag`            | CHAR(1)     | Y if opioid class drug                            |
| `specialty_drug_flag`    | CHAR(1)     | Y if specialty pharmacy drug                      |
| `biosimilar_flag`        | CHAR(1)     | Y if FDA-approved biosimilar                      |
| `maintenance_drug_flag`  | CHAR(1)     | Y if maintenance/chronic medication               |
| `unit_of_measure`        | VARCHAR(20) | Tablet, Capsule, ML, Unit, etc.                   |

---

### 9. DIM_GEOGRAPHY

Geographic dimension capturing where members reside and services are delivered — supporting state regulatory reporting.

| Column Name              | Data Type   | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `geography_key`          | INT (PK)    | Surrogate key                                     |
| `zip_code`               | VARCHAR(10) | ZIP/ZIP+4 postal code                             |
| `city`                   | VARCHAR(50) | City name                                         |
| `county_name`            | VARCHAR(50) | County name                                       |
| `county_fips_cd`         | VARCHAR(5)  | FIPS county code                                  |
| `state_cd`               | CHAR(2)     | Two-letter state code                             |
| `state_name`             | VARCHAR(30) | Full state name                                   |
| `census_region_cd`       | VARCHAR(5)  | US Census region (NE, MW, S, W)                   |
| `msa_cd`                 | VARCHAR(10) | Metropolitan Statistical Area code                |
| `rural_urban_cd`         | VARCHAR(10) | USDA Rural-Urban Continuum Code                   |
| `hpsa_flag`              | CHAR(1)     | Y if Health Professional Shortage Area            |
| `medically_underserved`  | CHAR(1)     | Y if Medically Underserved Area (MUA)             |
| `avg_household_income`   | DECIMAL(10,2)| Census median household income                   |
| `poverty_rate`           | DECIMAL(5,4)| Percentage below federal poverty level            |
| `centene_market_flag`    | CHAR(1)     | Y if Centene operates a plan in this market       |

---

### 10. DIM_DATE

Standard date dimension enabling time-based analysis across all date foreign keys in FACT_CLAIMS.

| Column Name              | Data Type   | Description                                       |
|--------------------------|-------------|---------------------------------------------------|
| `date_key`               | INT (PK)    | Surrogate key in YYYYMMDD integer format          |
| `full_date`              | DATE        | Calendar date                                     |
| `day_of_week_num`        | INT         | 1=Sunday … 7=Saturday                            |
| `day_of_week_name`       | VARCHAR(10) | Monday, Tuesday, etc.                             |
| `day_of_month`           | INT         | Day number within month (1–31)                    |
| `day_of_year`            | INT         | Day number within year (1–366)                    |
| `week_of_year`           | INT         | ISO week number                                   |
| `month_num`              | INT         | Month number (1–12)                               |
| `month_name`             | VARCHAR(10) | January, February, etc.                           |
| `quarter_num`            | INT         | Quarter (1–4)                                     |
| `quarter_name`           | VARCHAR(5)  | Q1, Q2, Q3, Q4                                    |
| `year_num`               | INT         | Four-digit year                                   |
| `fiscal_year`            | INT         | Centene fiscal year                               |
| `fiscal_quarter`         | INT         | Fiscal quarter (1–4)                              |
| `weekend_flag`           | CHAR(1)     | Y if Saturday or Sunday                           |
| `holiday_flag`           | CHAR(1)     | Y if US federal holiday                           |
| `hedis_measurement_year` | INT         | HEDIS measurement year (Jan–Dec)                  |

---

## Relationships Summary

| Foreign Key in FACT_CLAIMS | References Dimension   | Cardinality   |
|----------------------------|------------------------|---------------|
| `member_key`               | DIM_MEMBER             | Many-to-One   |
| `provider_key`             | DIM_PROVIDER           | Many-to-One   |
| `facility_key`             | DIM_FACILITY           | Many-to-One   |
| `plan_key`                 | DIM_PLAN               | Many-to-One   |
| `diagnosis_key`            | DIM_DIAGNOSIS          | Many-to-One   |
| `procedure_key`            | DIM_PROCEDURE          | Many-to-One   |
| `pharmacy_key`             | DIM_PHARMACY           | Many-to-One   |
| `geography_key`            | DIM_GEOGRAPHY          | Many-to-One   |
| `service_date_key`         | DIM_DATE               | Many-to-One   |
| `paid_date_key`            | DIM_DATE               | Many-to-One   |

> **Note:** `DIM_DATE` is referenced twice from the fact table (once for service date, once for paid date) — a standard role-playing dimension pattern.

---

## Key Business Use Cases

This star schema supports a wide range of analytics within Centene's operations:

1. **Claims Analytics** — Total paid amounts by LOB, plan, state, provider, diagnosis.
2. **HEDIS Reporting** — Preventive care gap closure rates (BCS, COL, CDC, CBP measures).
3. **Member Risk Stratification** — HCC risk scores, chronic condition burden, dual eligibility.
4. **Network Performance** — In/out-of-network utilization, provider quality scores, tier usage.
5. **Pharmacy/PBM Analytics** — Generic substitution rates, opioid utilization, specialty drug spend.
6. **Geographic Health Equity** — Service utilization in HPSAs, MUAs, rural/urban disparity analysis.
7. **Fraud, Waste & Abuse (FWA)** — High fraud-score claims by provider, diagnosis, procedure cluster.
8. **Care Management** — High-cost member identification, care management enrollment effectiveness.
9. **Star Ratings** — Medicare Advantage quality measure tracking and projection.
10. **Financial Forecasting** — Medical Loss Ratio (MLR) trend analysis by plan and LOB.

---

## Design Principles Applied

- **Kimball Star Schema** — Single denormalized fact table surrounded by conformed dimensions.
- **Surrogate Keys** — Integer surrogate PKs on all dimension tables for join performance.
- **SCD Type 2** — Applied to DIM_MEMBER to track enrollment history over time.
- **Role-Playing Dimension** — DIM_DATE serves dual roles (service date, paid date).
- **Conformed Dimensions** — DIM_DATE, DIM_GEOGRAPHY, and DIM_MEMBER can be shared across multiple fact tables (e.g., FACT_AUTHORIZATIONS, FACT_ENCOUNTERS).
- **HIPAA Compliance** — PII fields (name, DOB) should be encrypted at rest and masked in non-production environments.
- **Healthcare Standards** — Schema aligns with NCPDP, X12 837/835, ICD-10, CPT-4, NPI, and NDC standards.
