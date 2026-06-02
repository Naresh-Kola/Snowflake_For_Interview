# Snowflake Data Masking: Complete Guide (Beginner to Architect)

## Table of Contents
1. [What is Data Masking?](#1-what-is-data-masking)
2. [Dynamic Data Masking Fundamentals](#2-dynamic-data-masking-fundamentals)
3. [Prerequisites & Editions](#3-prerequisites--editions)
4. [Privileges & Role Setup](#4-privileges--role-setup)
5. [Creating Masking Policies](#5-creating-masking-policies)
6. [Applying Policies to Columns](#6-applying-policies-to-columns)
7. [Masking Policy Patterns (Beginner to Advanced)](#7-masking-policy-patterns)
8. [Conditional Masking](#8-conditional-masking)
9. [Tag-Based Masking Policies](#9-tag-based-masking-policies)
10. [External Tokenization](#10-external-tokenization)
11. [Management Approaches (Centralized, Hybrid, Decentralized)](#11-management-approaches)
12. [Masking with Data Sharing](#12-masking-with-data-sharing)
13. [Monitoring & Auditing](#13-monitoring--auditing)
14. [Runtime Behavior & Anti-Patterns](#14-runtime-behavior--anti-patterns)
15. [Interactions with Other Features](#15-interactions-with-other-features)
16. [Architect-Level Best Practices](#16-architect-level-best-practices)
17. [Troubleshooting](#17-troubleshooting)
18. [DDL Reference](#18-ddl-reference)

---

## 1. What is Data Masking?

Data masking hides sensitive data from unauthorized users while allowing authorized users to see the actual values. Snowflake offers **Dynamic Data Masking** — meaning data is masked **at query time**, not at rest.

```
┌─────────────────────────────────────────────────────────────┐
│                    TABLE: EMPLOYEES                          │
│  NAME        | EMAIL                  | SSN         | SALARY│
│  John Smith  | john@company.com       | 123-45-6789 | 95000 │
└─────────────────────────────────────────────────────────────┘
                          │
              ┌───────────┼───────────┐
              ▼                       ▼
┌──────────────────────┐  ┌──────────────────────┐
│   ROLE: HR_ADMIN     │  │   ROLE: ANALYST      │
│   (Authorized)       │  │   (Unauthorized)     │
│                      │  │                      │
│  john@company.com    │  │  *****@company.com   │
│  123-45-6789         │  │  ***-**-****         │
│  95000               │  │  NULL                │
└──────────────────────┘  └──────────────────────┘
```

### Key Characteristics:
- **Dynamic**: Masking happens at query runtime, NOT on stored data
- **Policy-driven**: Centrally managed via schema-level objects
- **Role-based**: Conditions evaluate execution context (role, user, account)
- **Reusable**: One policy can protect thousands of columns
- **Transparent**: Query rewrites happen automatically

### Dynamic Masking vs Static Masking

| Aspect | Dynamic (Snowflake) | Static (Traditional) |
|--------|-------------------|---------------------|
| Data at rest | Unchanged (plain text) | Permanently altered |
| When applied | Query time | ETL/load time |
| Reversible | Yes (change role) | No |
| Multiple views | Yes (per role) | Requires multiple copies |
| Maintenance | Single policy | Multiple data copies |

---

## 2. Dynamic Data Masking Fundamentals

### How It Works Internally

1. User runs a query: `SELECT email FROM customers;`
2. Snowflake detects a masking policy on the `email` column
3. Snowflake **rewrites** the query internally:
   ```sql
   SELECT <masking_policy_expression>(email) FROM customers;
   ```
4. The policy expression evaluates conditions (role, user, etc.)
5. Returns masked or unmasked data based on conditions

### Masking Policy Structure

```sql
CREATE MASKING POLICY <name>
  AS (val <data_type>) RETURNS <data_type> ->
  <expression>
```

- **Input and output data types MUST match**
- The policy is a SQL expression (typically a CASE statement)
- It receives the column value as input and returns the masked/unmasked value

---

## 3. Prerequisites & Editions

| Requirement | Details |
|------------|---------|
| Edition | **Enterprise Edition or higher** |
| Object hierarchy | Database and schema must exist before creating a policy |
| Policy scope | Schema-level object |
| Supported on | Tables, Views, Materialized Views, Dynamic Tables |

---

## 4. Privileges & Role Setup

### Required Privileges

| Privilege | Scope | Purpose |
|-----------|-------|---------|
| `CREATE MASKING POLICY` | Schema | Create new policies |
| `APPLY MASKING POLICY` | Account | Set/unset policies on columns |
| `APPLY` | Masking Policy | Decentralized: allow object owners to apply a specific policy |
| `OWNERSHIP` | Masking Policy | Full control (alter, drop) |

### Setting Up the Masking Admin Role

```sql
-- Step 1: Create a dedicated masking admin role
USE ROLE USERADMIN;
CREATE ROLE masking_admin;

-- Step 2: Grant privileges
USE ROLE SECURITYADMIN;
GRANT CREATE MASKING POLICY ON SCHEMA mydb.myschema TO ROLE masking_admin;
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE masking_admin;

-- Step 3: Assign to a user
GRANT ROLE masking_admin TO USER security_officer;
```

### Optional: Decentralized Apply

```sql
-- Allow table owners to apply a specific policy
GRANT APPLY ON MASKING POLICY ssn_mask TO ROLE table_owner;
```

---

## 5. Creating Masking Policies

### Basic Syntax

```sql
CREATE [ OR REPLACE ] MASKING POLICY [ IF NOT EXISTS ] <name>
  AS (val <data_type> [, <col_name> <data_type>, ... ]) RETURNS <data_type> ->
  <expression>
  [ COMMENT = '<comment>' ]
  [ EXEMPT_OTHER_POLICIES = { TRUE | FALSE } ];
```

### Simple Example

```sql
CREATE OR REPLACE MASKING POLICY email_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('HR_ADMIN', 'PAYROLL') THEN val
    ELSE '***MASKED***'
  END;
```

---

## 6. Applying Policies to Columns

### Option A: At Table/View Creation

```sql
-- Apply during CREATE TABLE
CREATE TABLE employees (
  name STRING,
  email STRING MASKING POLICY email_mask,
  ssn STRING MASKING POLICY ssn_mask,
  salary NUMBER MASKING POLICY salary_mask
);

-- Apply during CREATE VIEW
CREATE VIEW emp_view (email MASKING POLICY email_mask) AS
  SELECT email FROM employees;
```

### Option B: On Existing Table/View (ALTER)

```sql
-- Set policy on existing column
ALTER TABLE employees MODIFY COLUMN email SET MASKING POLICY email_mask;

-- Unset policy
ALTER TABLE employees MODIFY COLUMN email UNSET MASKING POLICY;

-- Replace policy (atomic with FORCE)
ALTER TABLE employees MODIFY COLUMN email SET MASKING POLICY email_mask_v2 FORCE;
```

---

## 7. Masking Policy Patterns

### Level 1: Full Mask (Beginner)

```sql
-- Return fixed value for unauthorized users
CREATE OR REPLACE MASKING POLICY full_mask_string
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('ADMIN') THEN val
    ELSE '********'
  END;
```

### Level 2: NULL Mask

```sql
-- Return NULL for unauthorized users
CREATE OR REPLACE MASKING POLICY null_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('ANALYST') THEN val
    ELSE NULL
  END;
```

### Level 3: Partial Mask (Email — show domain only)

```sql
CREATE OR REPLACE MASKING POLICY email_partial_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('HR_ADMIN') THEN val
    WHEN CURRENT_ROLE() IN ('SUPPORT') THEN REGEXP_REPLACE(val, '.+\\@', '*****@')
    ELSE '********'
  END;
-- HR_ADMIN sees: john.doe@company.com
-- SUPPORT sees:  *****@company.com
-- Others see:    ********
```

### Level 4: Partial Mask (Phone — show last 4 digits)

```sql
CREATE OR REPLACE MASKING POLICY phone_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('SUPPORT') THEN val
    ELSE CONCAT('***-***-', RIGHT(val, 4))
  END;
-- SUPPORT sees: 555-123-4567
-- Others see:   ***-***-4567
```

### Level 5: SHA2 Hash (Preserve Analytical Value)

```sql
CREATE OR REPLACE MASKING POLICY hash_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('ANALYST') THEN val
    ELSE SHA2(val)
  END;
-- Hashed values are consistent (same input = same hash)
-- Enables COUNT DISTINCT, GROUP BY without exposing data
-- WARNING: Possible hash collisions
```

### Level 6: Timestamp Masking

```sql
CREATE OR REPLACE MASKING POLICY ts_mask
  AS (val TIMESTAMP_NTZ) RETURNS TIMESTAMP_NTZ ->
  CASE
    WHEN CURRENT_ROLE() IN ('ANALYST') THEN val
    ELSE DATE_FROM_PARTS(0001, 01, 01)::TIMESTAMP_NTZ
  END;
-- Input/output types MUST match — cannot return STRING for TIMESTAMP
```

### Level 7: NUMBER Masking

```sql
CREATE OR REPLACE MASKING POLICY salary_mask
  AS (val NUMBER) RETURNS NUMBER ->
  CASE
    WHEN CURRENT_ROLE() IN ('PAYROLL') THEN val
    ELSE 0
  END;
```

### Level 8: VARIANT/JSON Masking

```sql
CREATE OR REPLACE MASKING POLICY json_mask
  AS (val VARIANT) RETURNS VARIANT ->
  CASE
    WHEN CURRENT_ROLE() IN ('ANALYST') THEN val
    ELSE OBJECT_INSERT(val, 'USER_IPADDRESS', '****', TRUE)
  END;
```

### Level 9: Account-Based Masking (Prod vs Non-Prod)

```sql
CREATE OR REPLACE MASKING POLICY prod_only_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ACCOUNT() IN ('PROD_ACCOUNT_ID') THEN val
    ELSE '*********'
  END;
```

### Level 10: Entitlement Table (Enterprise Pattern)

```sql
CREATE OR REPLACE MASKING POLICY entitlement_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN EXISTS (
      SELECT 1 FROM governance.public.entitlements
      WHERE mask_method = 'unmask' AND role_name = CURRENT_ROLE()
    ) THEN val
    ELSE '***MASKED***'
  END;
-- Use EXISTS (not IN) for subqueries in policies
```

### Level 11: Role Hierarchy with IS_ROLE_IN_SESSION

```sql
CREATE OR REPLACE MASKING POLICY hierarchy_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('HR_ADMIN') THEN val
    ELSE '***MASKED***'
  END;
-- IS_ROLE_IN_SESSION respects role hierarchy
-- If ACCOUNTADMIN inherits HR_ADMIN, ACCOUNTADMIN also sees unmasked
```

### Level 12: UDF-Based Masking

```sql
CREATE OR REPLACE MASKING POLICY udf_mask
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('ANALYST') THEN val
    ELSE my_custom_mask_udf(val)
  END;
```

### Level 13: Memoizable Function (Performance)

```sql
-- Create a cached lookup function
CREATE FUNCTION is_role_authorized(role_name VARCHAR)
  RETURNS BOOLEAN
  MEMOIZABLE
AS
$$
  SELECT ARRAY_CONTAINS(
    role_name::VARIANT,
    (SELECT ARRAY_AGG(role) FROM auth_roles WHERE is_authorized = TRUE)
  )
$$;

-- Use in masking policy
CREATE OR REPLACE MASKING POLICY memo_mask
  AS (val VARCHAR) RETURNS VARCHAR ->
  CASE
    WHEN is_role_authorized(CURRENT_ROLE()) THEN val
    ELSE NULL
  END;
```

---

## 8. Conditional Masking

Conditional masking uses **additional columns** to determine whether to mask data.

### Concept

```sql
-- Standard masking: only takes the column value
CREATE MASKING POLICY standard AS (val STRING) RETURNS STRING -> ...

-- Conditional masking: takes additional columns as arguments
CREATE MASKING POLICY conditional AS (val STRING, visibility STRING) RETURNS STRING -> ...
```

### Example: Mask Based on Another Column's Value

```sql
CREATE OR REPLACE MASKING POLICY email_visibility_mask
  AS (email VARCHAR, visibility_flag STRING) RETURNS VARCHAR ->
  CASE
    WHEN CURRENT_ROLE() = 'ADMIN' THEN email
    WHEN visibility_flag = 'PUBLIC' THEN email
    ELSE '***MASKED***'
  END;
```

### Applying Conditional Masking

```sql
-- At table creation
CREATE TABLE contacts (
  email STRING MASKING POLICY email_visibility_mask USING (email, visibility),
  visibility STRING
);

-- On existing table
ALTER TABLE contacts MODIFY COLUMN email
  SET MASKING POLICY email_visibility_mask USING (email, visibility);
```

### Rules:
- First argument = column being masked
- Additional arguments = conditional columns (must exist in same table/view)
- Minimize conditional columns for performance

---

## 9. Tag-Based Masking Policies

Tag-based masking combines **object tagging** + **masking policies** for automatic, scalable protection.

### Why Tag-Based Masking?

| Without Tags | With Tags |
|-------------|-----------|
| Manually apply policy to each column | Apply tag to table → all matching columns auto-protected |
| New columns unprotected until manually set | New columns protected automatically via inheritance |
| Manage 1000s of individual assignments | Manage a few tags |

### How It Works

```
┌─────────────┐     SET MASKING POLICY     ┌──────────────────┐
│    TAG       │ ◄──────────────────────── │  MASKING POLICY  │
│  "PII"       │                            │  (per data type) │
└──────┬───────┘                            └──────────────────┘
       │ SET TAG
       ▼
┌─────────────────────────────────────┐
│          TABLE                       │
│  col1 (STRING) → policy applies     │
│  col2 (NUMBER) → policy applies     │
│  col3 (DATE)   → no policy (no      │
│                   DATE policy on tag)│
└─────────────────────────────────────┘
```

### Step-by-Step: Tag-Based Masking

```sql
-- Step 1: Create a tag
CREATE TAG governance.tags.pii;

-- Step 2: Create masking policies for each data type
CREATE MASKING POLICY string_pii_mask AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_ROLE_IN_SESSION('DATA_OWNER') THEN val
    ELSE '***PII_MASKED***'
  END;

CREATE MASKING POLICY number_pii_mask AS (val NUMBER) RETURNS NUMBER ->
  CASE
    WHEN IS_ROLE_IN_SESSION('DATA_OWNER') THEN val
    ELSE -1
  END;

-- Step 3: Assign policies to the tag (one per data type)
ALTER TAG governance.tags.pii SET
  MASKING POLICY string_pii_mask,
  MASKING POLICY number_pii_mask;

-- Step 4: Apply tag to a table (all columns auto-protected by matching data type)
ALTER TABLE hr.employees SET TAG governance.tags.pii = 'sensitive';

-- Step 5: Verify
SELECT * FROM TABLE(
  INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_DOMAIN => 'TABLE',
    REF_ENTITY_NAME => 'hr.employees'
  )
);
```

### Tag-Based Masking on Database/Schema Level

```sql
-- Protect ALL tables in a schema automatically
ALTER SCHEMA hr SET TAG governance.tags.pii = 'schema-level';
-- New tables added to this schema are automatically protected!
```

### Precedence Rule
> A masking policy **directly assigned** to a column takes precedence over a tag-based masking policy.

### Using Tag String Values in Policy Conditions

```sql
CREATE MASKING POLICY dynamic_tag_mask AS (val STRING) RETURNS STRING ->
  CASE
    WHEN SYSTEM$GET_TAG_ON_CURRENT_COLUMN('governance.tags.pii') = 'public' THEN val
    ELSE '***MASKED***'
  END;
```

---

## 10. External Tokenization

External Tokenization uses a **third-party provider** to tokenize data BEFORE loading into Snowflake, and detokenize at query time via **external functions**.

### How It Differs from Dynamic Masking

| Feature | Dynamic Data Masking | External Tokenization |
|---------|---------------------|----------------------|
| Data loaded as | Plain text | Tokenized |
| At query time | Masks plain text | Detokenizes tokens |
| Requires | Built-in functions only | External function (API call) |
| Unauthorized see | Masked/NULL values | Tokenized values |
| Analytical value | Limited (masked = lost) | Yes (consistent tokens enable GROUP BY) |

### Example

```sql
-- External tokenization policy
CREATE MASKING POLICY ssn_detokenize
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('PAYROLL') THEN ssn_unprotect(val)  -- external function
    ELSE val  -- return tokenized value as-is
  END;
```

### When to Choose External Tokenization:
- Data must NEVER exist in plain text in Snowflake
- Compliance requires pre-load tokenization
- Need to preserve analytical value (GROUP BY on tokenized values)
- Already using a tokenization provider (Protegrity, Voltage, etc.)

---

## 11. Management Approaches

### Centralized (Recommended for Compliance-Heavy Orgs)

```sql
-- One team creates AND applies all policies
USE ROLE ACCOUNTADMIN;
CREATE ROLE security_officer;
GRANT CREATE MASKING POLICY ON SCHEMA governance.policies TO ROLE security_officer;
GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE security_officer;
```

| Pros | Cons |
|------|------|
| Consistent enforcement | Bottleneck on security team |
| Single source of truth | Slower policy rollout |
| Strongest SoD | Less agile |

### Hybrid (Recommended for Most Organizations)

```sql
-- Security team creates policies
GRANT CREATE MASKING POLICY ON SCHEMA governance.policies TO ROLE security_officer;

-- Individual teams apply policies to their tables
GRANT APPLY ON MASKING POLICY ssn_mask TO ROLE hr_team;
GRANT APPLY ON MASKING POLICY card_mask TO ROLE finance_team;
```

| Pros | Cons |
|------|------|
| Consistent policy definitions | Teams must know which policy to use |
| Faster application | Risk of missed columns |
| Good balance of control + speed | |

### Decentralized (Small Teams / Startups)

```sql
-- Each team creates and applies their own policies
GRANT CREATE MASKING POLICY ON SCHEMA hr.policies TO ROLE hr_team;
GRANT CREATE MASKING POLICY ON SCHEMA fin.policies TO ROLE finance_team;
```

| Pros | Cons |
|------|------|
| Maximum speed | Inconsistent policies |
| Team ownership | Possible data exposure |
| No bottleneck | Harder to audit |

---

## 12. Masking with Data Sharing

### Important Rules

1. **CURRENT_ROLE() returns NULL** in consumer accounts (because provider doesn't control consumer roles)
2. **CURRENT_USER() returns NULL** in consumer accounts
3. Use **CURRENT_ACCOUNT()** or **IS_DATABASE_ROLE_IN_SESSION()** instead

### Best Practice for Shared Data

```sql
-- BAD: Won't work in consumer account
CREATE MASKING POLICY bad_shared_policy AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('ANALYST') THEN val  -- always NULL in consumer!
    ELSE '***MASKED***'
  END;

-- GOOD: Use CURRENT_ACCOUNT or database roles
CREATE MASKING POLICY good_shared_policy AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ACCOUNT() IN ('CONSUMER_ACCT_1') THEN val
    ELSE '***MASKED***'
  END;

-- BEST: Use shared database roles
CREATE MASKING POLICY best_shared_policy AS (val STRING) RETURNS STRING ->
  CASE
    WHEN IS_DATABASE_ROLE_IN_SESSION('AUTHORIZED_READER') THEN val
    ELSE '***MASKED***'
  END;
```

### Limitations with Sharing:
- External functions (tokenization) cannot be used with shares
- Consumer cannot apply policies to shared objects (use local view as workaround)
- Tag-based masking policies on shared schemas ARE enforced in consumer accounts

---

## 13. Monitoring & Auditing

### Discover All Masking Policies

```sql
-- List all policies in account
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.MASKING_POLICIES
ORDER BY POLICY_NAME;

-- Show policies (if you have APPLY privilege)
SHOW MASKING POLICIES IN SCHEMA mydb.myschema;

-- Describe a specific policy
DESCRIBE MASKING POLICY mydb.myschema.email_mask;

-- Get DDL of existing policy
SELECT GET_DDL('MASKING_POLICY', 'mydb.myschema.email_mask');
```

### Find All Column Assignments

```sql
-- Account-level: all columns with policies
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE POLICY_KIND = 'MASKING_POLICY'
ORDER BY POLICY_NAME, REF_COLUMN_NAME;

-- Database-level: policies on a specific table
SELECT * FROM TABLE(
  mydb.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => 'mydb.public.employees',
    REF_ENTITY_DOMAIN => 'TABLE'
  )
);

-- Find all columns protected by a specific policy
SELECT * FROM TABLE(
  INFORMATION_SCHEMA.POLICY_REFERENCES(
    POLICY_NAME => 'email_mask'
  )
);
```

### Snowsight Governance Dashboard

Navigate to: **Governance & Security > Tags & Policies**

Features:
- **Coverage**: % of tables/columns with policies
- **Prevalence**: Most-used policies
- Requires GOVERNANCE_VIEWER + OBJECT_VIEWER database roles

```sql
-- Grant dashboard access
GRANT DATABASE ROLE SNOWFLAKE.GOVERNANCE_VIEWER TO ROLE data_engineer;
GRANT DATABASE ROLE SNOWFLAKE.OBJECT_VIEWER TO ROLE data_engineer;
```

---

## 14. Runtime Behavior & Anti-Patterns

### Where Masking Applies

The policy is applied **everywhere** the column appears:
- SELECT projections
- WHERE clauses
- JOIN predicates
- ORDER BY
- GROUP BY

### Anti-Pattern 1: Filtering on Masked Column

```sql
-- User query:
SELECT email FROM customers WHERE email = 'john@company.com';

-- Snowflake rewrites to:
SELECT mask(email) FROM customers WHERE mask(email) = 'john@company.com';
-- Result: 0 rows (masked value never equals 'john@company.com')
```

### Anti-Pattern 2: JOINing on Masked Columns

```sql
-- User query:
SELECT * FROM t1 JOIN t2 ON t1.email = t2.email;

-- Snowflake rewrites to:
SELECT * FROM t1 JOIN t2 ON mask(t1.email) = mask(t2.email);
-- If mask returns fixed value: ALL rows join (cartesian)
-- If mask returns NULL: NO rows join
```

### Nested Policy Execution Order

```
table policy → view_1 policy → view_2 policy → ... → view_n policy
```

The table-level policy always executes FIRST, then view policies in order.

---

## 15. Interactions with Other Features

| Feature | Behavior |
|---------|----------|
| **Streams** | Policies carry over to streams on the same table |
| **Cloning** | Cloned table retains policy assignments |
| **CTAS** | Masked data is written to the new table |
| **COPY INTO (unload)** | Policy applied — unauthorized users export masked data |
| **Materialized Views** | Cannot set policy on table column IF MV exists on it |
| **Dynamic Tables** | Supports masking policies |
| **Replication** | Policies replicate with databases/replication groups |
| **Time Travel** | Policy uses CURRENT schema — historical data uses current policy |
| **Row Access Policies** | Same column cannot be in both a masking policy AND row access policy |
| **Search Optimization** | Works with tables that have masking policies |

---

## 16. Architect-Level Best Practices

### 1. Governance Schema Pattern

```
GOVERNANCE_DB
├── TAGS/
│   ├── PII (tag)
│   ├── PHI (tag)
│   └── FINANCIAL (tag)
├── MASKING_POLICIES/
│   ├── string_pii_mask
│   ├── number_pii_mask
│   ├── timestamp_pii_mask
│   ├── email_partial_mask
│   └── ssn_full_mask
└── ENTITLEMENTS/
    └── auth_roles (mapping table)
```

### 2. Policy Design Principles

1. **One policy per data type per classification** (e.g., STRING+PII, NUMBER+PII)
2. **Use IS_ROLE_IN_SESSION()** instead of CURRENT_ROLE() for hierarchy support
3. **Use memoizable functions** for lookup table patterns (performance)
4. **Use FORCE keyword** for atomic policy replacement (no gap)
5. **Prefer tag-based masking** for scalability (1 tag vs 1000 ALTER TABLE statements)

### 3. Segregation of Duties (SoD)

```
ACCOUNTADMIN → Should NOT see masked data
SECURITY_OFFICER → Creates and applies policies
TABLE_OWNER → Cannot unset policies (by design)
ANALYST → Sees masked or partially masked data
```

### 4. Policy Naming Convention

```
<classification>_<data_type>_<mask_type>
Examples:
  pii_string_full_mask
  pii_string_partial_email
  phi_number_null_mask
  financial_number_zero_mask
```

### 5. Testing with POLICY_CONTEXT

```sql
-- Simulate how a query would behave with specific roles
EXECUTE USING POLICY_CONTEXT(
  SNOWFLAKE$SESSION_ACTIVATED_ROLES => ('ANALYST', 'PUBLIC')
)
AS SELECT * FROM employees;
```

### 6. Data Classification → Auto-Masking Pipeline

```
1. Run SYSTEM$CLASSIFY on tables → identifies PII columns
2. Apply appropriate tags (PII, PHI, etc.) based on classification
3. Tags have masking policies assigned → columns auto-protected
4. Monitor via POLICY_REFERENCES + Snowsight dashboard
```

---

## 17. Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Insufficient privileges to operate on account` | Role lacks CREATE MASKING POLICY | `GRANT CREATE MASKING POLICY ON SCHEMA ... TO ROLE ...` |
| `Database does not exist or not authorized` | Role lacks APPLY MASKING POLICY | `GRANT APPLY MASKING POLICY ON ACCOUNT TO ROLE ...` |
| `Masking policy does not exist or not authorized` | Role needs APPLY on specific policy | `GRANT APPLY ON MASKING POLICY ... TO ROLE ...` |
| `Policy cannot be dropped as it is associated` | Policy still set on columns | UNSET from all columns first |
| `Specified column already attached to another policy` | One column = one policy max | UNSET existing, then SET new |
| `Masking policy function argument and return type mismatch` | Input/output types differ | Must be same data type |
| `Unsupported feature CREATE ON MASKING POLICY COLUMN` | Materialized view conflict | Apply to base table or MV, not both |
| `Column mapped to multiple masking policies by tags` | Multiple tags with policies on same column | Fix tag assignments |

### Useful Debugging Commands

```sql
-- View policy definition
DESCRIBE MASKING POLICY mydb.myschema.my_policy;

-- Check what policies are on a table
SELECT * FROM TABLE(
  mydb.INFORMATION_SCHEMA.POLICY_REFERENCES('my_table', 'table')
);

-- Simulate behavior
EXECUTE USING POLICY_CONTEXT(
  SNOWFLAKE$SESSION_ACTIVATED_ROLES => ('PUBLIC')
) AS SELECT * FROM my_table;
```

---

## 18. DDL Reference

| Command | Purpose |
|---------|---------|
| `CREATE MASKING POLICY` | Create a new policy |
| `ALTER MASKING POLICY ... SET BODY ->` | Update policy logic (no need to unset first) |
| `DROP MASKING POLICY` | Delete (must unset from all columns first) |
| `SHOW MASKING POLICIES` | List policies |
| `DESCRIBE MASKING POLICY` | View definition |
| `ALTER TABLE ... MODIFY COLUMN ... SET MASKING POLICY` | Apply to column |
| `ALTER TABLE ... MODIFY COLUMN ... UNSET MASKING POLICY` | Remove from column |
| `ALTER TABLE ... MODIFY COLUMN ... SET MASKING POLICY ... FORCE` | Replace atomically |
| `ALTER TAG ... SET MASKING POLICY` | Assign policy to tag |
| `ALTER TAG ... UNSET MASKING POLICY` | Remove policy from tag |

### Quick Reference: Alter Policy Body Without Re-applying

```sql
-- This updates the logic WITHOUT unset/set on columns
ALTER MASKING POLICY email_mask SET BODY ->
  CASE
    WHEN IS_ROLE_IN_SESSION('HR_ADMIN') THEN val
    WHEN IS_ROLE_IN_SESSION('SUPPORT') THEN CONCAT('***@', SPLIT_PART(val, '@', 2))
    ELSE '***MASKED***'
  END;
-- All columns using this policy immediately get the new logic
```

---

## Summary: Beginner → Architect Progression

```
BEGINNER:
  ✓ Understand dynamic vs static masking
  ✓ Create simple CASE-based policies
  ✓ Apply policies to columns with ALTER TABLE

INTERMEDIATE:
  ✓ Partial masking (email domain, last 4 digits)
  ✓ Role hierarchy with IS_ROLE_IN_SESSION
  ✓ Conditional masking (using multiple columns)
  ✓ Entitlement tables with EXISTS subqueries

ADVANCED:
  ✓ Tag-based masking at schema/database level
  ✓ Memoizable functions for performance
  ✓ POLICY_CONTEXT for testing
  ✓ External Tokenization with third-party providers

ARCHITECT:
  ✓ Governance schema design patterns
  ✓ Classification → Tag → Policy pipeline
  ✓ Segregation of duties (SoD) enforcement
  ✓ Data sharing with masking (database roles)
  ✓ Monitoring + auditing with POLICY_REFERENCES
  ✓ Centralized/Hybrid/Decentralized management decision
  ✓ Tag inheritance for auto-protection of new objects
  ✓ Cross-account, replication, and cloning behaviors
```
