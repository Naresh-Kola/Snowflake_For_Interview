# Snowflake Row Access Policies: Complete Guide

## Table of Contents
1. [What is a Row Access Policy?](#1-what-is-a-row-access-policy)
2. [How It Works Internally](#2-how-it-works-internally)
3. [Row Access Policy vs Masking Policy](#3-row-access-policy-vs-masking-policy)
4. [Prerequisites & Privileges](#4-prerequisites--privileges)
5. [Creating Row Access Policies](#5-creating-row-access-policies)
6. [Applying Policies to Tables/Views](#6-applying-policies-to-tablesviews)
7. [Pattern 1: Simple Role-Based Filtering](#7-pattern-1-simple-role-based-filtering)
8. [Pattern 2: Mapping Table Lookup](#8-pattern-2-mapping-table-lookup)
9. [Pattern 3: IS_ROLE_IN_SESSION (Role Hierarchy)](#9-pattern-3-is_role_in_session-role-hierarchy)
10. [Pattern 4: User-Based Filtering](#10-pattern-4-user-based-filtering)
11. [Pattern 5: Multi-Column Policies](#11-pattern-5-multi-column-policies)
12. [Pattern 6: Memoizable Functions (Performance)](#12-pattern-6-memoizable-functions-performance)
13. [Pattern 7: Protecting the Mapping Table Itself](#13-pattern-7-protecting-the-mapping-table-itself)
14. [Pattern 8: Data Sharing with Row Access Policies](#14-pattern-8-data-sharing-with-row-access-policies)
15. [Nested Policies (Table + View)](#15-nested-policies-table--view)a
16. [Interaction with Other Features](#16-interaction-with-other-features)
17. [Performance Guidelines](#17-performance-guidelines)
18. [Monitoring & Auditing](#18-monitoring--auditing)
19. [Management Approaches](#19-management-approaches)
20. [Troubleshooting](#20-troubleshooting)
21. [DDL Reference](#21-ddl-reference)
22. [Complete Real-World Example](#22-complete-real-world-example)

---

## 1. What is a Row Access Policy?

A Row Access Policy (RAP) controls **which rows** a user can see when querying a table or view. It's Snowflake's implementation of **Row-Level Security (RLS)**.

```
┌─────────────────────────────────────────────────────────────────┐
│                    TABLE: SALES_DATA                             │
│  CUSTOMER    | REGION | REVENUE  | PRODUCT                     │
│  Acme Corp   | NA     | 1,500,000| Software                    │
│  Beta Inc    | EU     | 2,500,000| Hardware                    │
│  Gamma Ltd   | APAC   | 800,000  | Services                    │
│  Delta Co    | NA     | 3,200,000| Software                    │
└─────────────────────────────────────────────────────────────────┘
                          │
              ┌───────────┼───────────┐
              ▼                       ▼
┌──────────────────────┐  ┌──────────────────────┐
│  ROLE: NA_MANAGER    │  │  ROLE: EU_MANAGER    │
│  (Sees NA rows only) │  │  (Sees EU rows only) │
│                      │  │                      │
│  Acme Corp | NA      │  │  Beta Inc | EU       │
│  Delta Co  | NA      │  │                      │
└──────────────────────┘  └──────────────────────┘
```

### Key Characteristics:
- **Dynamic**: Evaluated at query runtime (not stored differently)
- **Returns BOOLEAN**: TRUE = show row, FALSE = hide row
- **Schema-level object**: Lives in a schema, reusable across tables
- **Policy owner's rights**: Evaluated with the policy owner's privileges
- **Applies to**: SELECT, UPDATE (rows selected), DELETE (rows selected), MERGE

### What Row Access Policies Do NOT Do:
- Do NOT prevent INSERT of new rows
- Do NOT prevent UPDATE/DELETE of visible rows
- Do NOT protect against DDL operations (DROP TABLE, etc.)

---

## 2. How It Works Internally

```
User runs: SELECT * FROM sales WHERE year = 2024;

  Step 1: Snowflake detects a RAP on the table
  Step 2: Creates a dynamic secure inline view
  Step 3: Binds column values to policy parameters
  Step 4: Evaluates policy expression for EACH row
  Step 5: Returns only rows where policy = TRUE

Internally it becomes:
  SELECT * FROM sales WHERE year = 2024 AND <policy_expression> = TRUE;
```

### Execution Order (Nested Policies):
```
Table policy → View_1 policy → View_2 policy → ... → View_n policy
```
The table-level policy ALWAYS executes first, then view policies sequentially.

---

## 3. Row Access Policy vs Masking Policy

| Feature | Row Access Policy | Masking Policy |
|---------|------------------|----------------|
| Controls | Which **rows** are visible | What **value** a column shows |
| Returns | BOOLEAN (true/false) | Same data type as input |
| Effect | Row is included or excluded | Column value is masked/unmasked |
| Scope | Bound to one or more columns | Bound to one column |
| Evaluation order | First (before masking) | Second (after row filtering) |
| Same column? | Cannot overlap with masking policy on same column | Cannot overlap with RAP on same column |

### Combined Example:
```
Table has:
  - Row Access Policy on REGION column → filters rows by region
  - Masking Policy on SALARY column → masks salary from unauthorized roles

Query flow:
  1. RAP filters rows (only your region's rows returned)
  2. Masking policy masks salary column (on the filtered rows)
```

---

## 4. Prerequisites & Privileges

| Requirement | Details |
|------------|---------|
| Edition | **Enterprise Edition or higher** |
| Object type | Schema-level object |
| Supported on | Tables, Views, External Tables, Dynamic Tables |

### Privilege Matrix

| Operation | Privilege Required |
|-----------|-------------------|
| Create policy | `CREATE ROW ACCESS POLICY` on schema |
| Alter policy body | `OWNERSHIP` on the policy |
| Add/Drop policy on table | `APPLY ROW ACCESS POLICY` on account **OR** `OWNERSHIP` on table + `APPLY` on policy |
| Drop policy | `OWNERSHIP` on policy or schema |
| Show/Describe | `APPLY ROW ACCESS POLICY` or `OWNERSHIP` or `APPLY` on policy |

### Role Setup

```sql
-- Centralized: one role manages everything
USE ROLE SECURITYADMIN;
GRANT CREATE ROW ACCESS POLICY ON SCHEMA governance.policies TO ROLE rap_admin;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE rap_admin;

-- Hybrid: security creates, teams apply
GRANT CREATE ROW ACCESS POLICY ON SCHEMA governance.policies TO ROLE rap_admin;
GRANT APPLY ON ROW ACCESS POLICY governance.policies.sales_rap TO ROLE sales_team;
```

---

## 5. Creating Row Access Policies

### Basic Syntax

```sql
CREATE [ OR REPLACE ] ROW ACCESS POLICY [ IF NOT EXISTS ] <name>
  AS ( <arg1> <data_type> [, <arg2> <data_type>, ... ] ) RETURNS BOOLEAN ->
  <expression>
  [ COMMENT = '<comment>' ];
```

### Rules:
- Must return **BOOLEAN**
- Arguments map to table columns when applied
- Expression uses context functions + conditional logic
- Evaluated with **owner's rights** (not query operator's rights)

---

## 6. Applying Policies to Tables/Views

### At Creation Time

```sql
-- Table
CREATE TABLE sales (
  customer VARCHAR,
  region   VARCHAR,
  revenue  NUMBER
)
WITH ROW ACCESS POLICY region_policy ON (region);

-- View
CREATE VIEW sales_view
  WITH ROW ACCESS POLICY region_policy ON (region)
AS SELECT * FROM sales;
```

### On Existing Table/View (ALTER)

```sql
-- Add policy
ALTER TABLE sales ADD ROW ACCESS POLICY region_policy ON (region);

-- Drop policy
ALTER TABLE sales DROP ROW ACCESS POLICY region_policy;

-- Drop all policies
ALTER TABLE sales DROP ALL ROW ACCESS POLICIES;
```

### Important Rules:
- **One RAP per table/view** (cannot have multiple RAPs on same object)
- A column used in RAP signature **cannot** also be used in a masking policy signature
- Policy can reference multiple columns in its signature

---

## 7. Pattern 1: Simple Role-Based Filtering

The simplest RAP — check the current role directly.

```sql
-- Only the 'it_admin' role can see rows
CREATE OR REPLACE ROW ACCESS POLICY rap_it_only
  AS (empl_id VARCHAR) RETURNS BOOLEAN ->
  CURRENT_ROLE() = 'IT_ADMIN';

-- Apply
ALTER TABLE employees ADD ROW ACCESS POLICY rap_it_only ON (empl_id);
```

### With Multiple Authorized Roles

```sql
CREATE OR REPLACE ROW ACCESS POLICY rap_multi_role
  AS (val VARCHAR) RETURNS BOOLEAN ->
  CURRENT_ROLE() IN ('ADMIN', 'HR_MANAGER', 'COMPLIANCE');
```

### With CASE Statement

```sql
CREATE OR REPLACE ROW ACCESS POLICY rap_case
  AS (region VARCHAR) RETURNS BOOLEAN ->
  CASE
    WHEN CURRENT_ROLE() = 'EXECUTIVE' THEN TRUE           -- sees all
    WHEN CURRENT_ROLE() = 'NA_MANAGER' AND region = 'NA' THEN TRUE
    WHEN CURRENT_ROLE() = 'EU_MANAGER' AND region = 'EU' THEN TRUE
    ELSE FALSE
  END;
```

---

## 8. Pattern 2: Mapping Table Lookup

Use a **mapping table** to define who can see what. This is the most common enterprise pattern.

### Step 1: Create the Mapping Table

```sql
CREATE TABLE governance.security.role_region_mapping (
  role_name VARCHAR,
  region    VARCHAR
);

INSERT INTO governance.security.role_region_mapping VALUES
  ('SALES_EXEC', 'ALL'),       -- sees everything
  ('NA_MANAGER', 'NA'),        -- North America only
  ('EU_MANAGER', 'EU'),        -- Europe only
  ('APAC_MANAGER', 'APAC');    -- Asia Pacific only
```

### Step 2: Create Policy with Subquery

```sql
CREATE OR REPLACE ROW ACCESS POLICY rap_region_mapping
  AS (sales_region VARCHAR) RETURNS BOOLEAN ->
  CURRENT_ROLE() = 'SALES_EXEC'
  OR EXISTS (
    SELECT 1 FROM governance.security.role_region_mapping
    WHERE role_name = CURRENT_ROLE()
      AND (region = sales_region OR region = 'ALL')
  );
```

### Step 3: Apply to Table

```sql
ALTER TABLE sales.public.revenue ADD ROW ACCESS POLICY rap_region_mapping ON (region);
```

### How It Works at Runtime:

```
User with role NA_MANAGER queries: SELECT * FROM revenue;

Snowflake checks for each row:
  Row 1 (region='NA'):  EXISTS returns TRUE  → row visible
  Row 2 (region='EU'):  EXISTS returns FALSE → row hidden
  Row 3 (region='APAC'): EXISTS returns FALSE → row hidden

Result: only NA rows returned
```

### Advantage of Mapping Tables:
- Change access by updating the mapping table (no policy change needed)
- Easy to audit who has access to what
- Central source of truth for entitlements

---

## 9. Pattern 3: IS_ROLE_IN_SESSION (Role Hierarchy)

`CURRENT_ROLE()` only checks the exact active role. `IS_ROLE_IN_SESSION()` respects **role hierarchy** — if a parent role inherits a child role, the parent also gets access.

```sql
-- CURRENT_ROLE() = 'ANALYST' → only TRUE if active role is literally ANALYST
-- IS_ROLE_IN_SESSION('ANALYST') → TRUE if ANALYST is in the role hierarchy
--   (e.g., ACCOUNTADMIN inherits ANALYST → returns TRUE for ACCOUNTADMIN too)
```

### Simple Usage

```sql
CREATE OR REPLACE ROW ACCESS POLICY rap_hierarchy
  AS (region VARCHAR) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('DATA_ADMIN')
  OR (IS_ROLE_IN_SESSION('NA_TEAM') AND region = 'NA')
  OR (IS_ROLE_IN_SESSION('EU_TEAM') AND region = 'EU');
```

### Column-Based Usage (Most Powerful)

Store the authorized role IN the table itself:

```sql
-- Table has a column specifying which role can see the row
CREATE TABLE sensitive_data (
  data_value  VARCHAR,
  auth_role   VARCHAR   -- e.g., 'HR_ROLE', 'FIN_ROLE'
);

INSERT INTO sensitive_data VALUES ('HR data', 'HR_ROLE');
INSERT INTO sensitive_data VALUES ('Finance data', 'FIN_ROLE');

-- Policy uses the column directly
CREATE OR REPLACE ROW ACCESS POLICY rap_column_role
  AS (auth_role VARCHAR) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION(auth_role);

-- Apply
ALTER TABLE sensitive_data ADD ROW ACCESS POLICY rap_column_role ON (auth_role);
```

Now rows are automatically visible only to users whose role hierarchy includes the `auth_role` value.

---

## 10. Pattern 4: User-Based Filtering

Filter based on the current user instead of (or in addition to) role.

```sql
-- User-based entitlement table
CREATE TABLE governance.security.user_access (
  username    VARCHAR,
  department  VARCHAR
);

INSERT INTO governance.security.user_access VALUES
  ('ALICE', 'ENGINEERING'),
  ('BOB', 'FINANCE'),
  ('CAROL', 'ENGINEERING'),
  ('CAROL', 'FINANCE');  -- Carol has access to both

-- Policy
CREATE OR REPLACE ROW ACCESS POLICY rap_user_dept
  AS (department VARCHAR) RETURNS BOOLEAN ->
  EXISTS (
    SELECT 1 FROM governance.security.user_access
    WHERE username = CURRENT_USER()
      AND department = department
  )
  OR IS_ROLE_IN_SESSION('ADMIN');  -- admins see all

-- Apply
ALTER TABLE company_data ADD ROW ACCESS POLICY rap_user_dept ON (department);
```

---

## 11. Pattern 5: Multi-Column Policies

A policy can bind to **multiple columns** for complex filtering.

```sql
-- Policy takes multiple column arguments
CREATE OR REPLACE ROW ACCESS POLICY rap_multi_col
  AS (region VARCHAR, classification VARCHAR) RETURNS BOOLEAN ->
  CASE
    WHEN IS_ROLE_IN_SESSION('EXEC') THEN TRUE
    WHEN IS_ROLE_IN_SESSION('MANAGER') AND classification != 'TOP_SECRET' THEN TRUE
    WHEN IS_ROLE_IN_SESSION('ANALYST') AND region = 'NA' AND classification = 'PUBLIC' THEN TRUE
    ELSE FALSE
  END;

-- Apply to multiple columns
ALTER TABLE intel_data ADD ROW ACCESS POLICY rap_multi_col ON (region, classification);
```

### Important:
- Snowflake must scan ALL columns in the policy signature (even if not in the user's SELECT)
- More columns = more scanning = potential performance impact
- Keep policy arguments minimal

---

## 12. Pattern 6: Memoizable Functions (Performance)

Mapping table lookups via `EXISTS` subqueries can be slow on large tables. **Memoizable functions** cache the lookup results.

### Without Memoizable Function (Slower)

```sql
CREATE OR REPLACE ROW ACCESS POLICY rap_slow
  AS (region_id NUMBER) RETURNS BOOLEAN ->
  EXISTS (SELECT 1 FROM allowed_regions WHERE id = region_id);
```

### With Memoizable Function (Faster)

```sql
-- Step 1: Create memoizable function (results cached per session)
CREATE OR REPLACE FUNCTION allowed_regions()
  RETURNS ARRAY
  MEMOIZABLE
AS 'SELECT ARRAY_AGG(id) FROM governance.security.allowed_regions
    WHERE role_name = CURRENT_ROLE()';

-- Step 2: Use ARRAY_CONTAINS instead of EXISTS
CREATE OR REPLACE ROW ACCESS POLICY rap_fast
  AS (region_id NUMBER) RETURNS BOOLEAN ->
  ARRAY_CONTAINS(region_id::VARIANT, allowed_regions());
```

### Multiple Memoizable Functions

```sql
CREATE OR REPLACE FUNCTION allowed_customers()
  RETURNS ARRAY
  MEMOIZABLE
AS 'SELECT ARRAY_AGG(id) FROM allowed_customers WHERE role_name = CURRENT_ROLE()';

CREATE OR REPLACE FUNCTION allowed_products()
  RETURNS ARRAY
  MEMOIZABLE
AS 'SELECT ARRAY_AGG(id) FROM allowed_products WHERE role_name = CURRENT_ROLE()';

-- Policy using all three
CREATE OR REPLACE ROW ACCESS POLICY rap_memo_multi
  AS (region_id NUMBER, customer_id NUMBER, product_id NUMBER) RETURNS BOOLEAN ->
  ARRAY_CONTAINS(region_id::VARIANT, allowed_regions())
  OR ARRAY_CONTAINS(customer_id::VARIANT, allowed_customers())
  OR ARRAY_CONTAINS(product_id::VARIANT, allowed_products());
```

---

## 13. Pattern 7: Protecting the Mapping Table Itself

If the mapping table contains sensitive information (who can see what), protect it too!

```sql
-- Step 1: Create mapping table
CREATE TABLE sales.tables.regional_managers (
  allowed_regions VARCHAR,
  allowed_roles   VARCHAR
);

INSERT INTO sales.tables.regional_managers VALUES
  ('NA', 'NA_MANAGER'),
  ('EU', 'EU_MANAGER'),
  ('APAC', 'APAC_MANAGER');

-- Step 2: Protect the mapping table with its own RAP
CREATE OR REPLACE ROW ACCESS POLICY rap_protect_mapping
  AS (allowed_roles VARCHAR) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION(allowed_roles);

ALTER TABLE sales.tables.regional_managers
  ADD ROW ACCESS POLICY rap_protect_mapping ON (allowed_roles);

-- Step 3: Create data policy that lookups the protected mapping table
CREATE OR REPLACE ROW ACCESS POLICY rap_data_lookup
  AS (region VARCHAR) RETURNS BOOLEAN ->
  EXISTS (
    SELECT 1 FROM sales.tables.regional_managers
    WHERE allowed_regions = region
  );

-- Step 4: Apply data policy to the actual data table
ALTER TABLE sales.tables.revenue
  ADD ROW ACCESS POLICY rap_data_lookup ON (region);
```

---

## 14. Pattern 8: Data Sharing with Row Access Policies

### The Problem with CURRENT_ROLE/CURRENT_USER in Sharing

```sql
-- BAD: CURRENT_ROLE() returns NULL in consumer account!
CREATE ROW ACCESS POLICY rap_broken_share
  AS (region VARCHAR) RETURNS BOOLEAN ->
  CURRENT_ROLE() = 'ANALYST';  -- always NULL in consumer!
```

### Solution 1: Use CURRENT_ACCOUNT()

```sql
CREATE OR REPLACE ROW ACCESS POLICY rap_account_share
  AS (region VARCHAR) RETURNS BOOLEAN ->
  CASE
    WHEN CURRENT_ACCOUNT() = 'PROVIDER_ACCT' THEN TRUE
    WHEN CURRENT_ACCOUNT() = 'CONSUMER_ACCT_NA' AND region = 'NA' THEN TRUE
    WHEN CURRENT_ACCOUNT() = 'CONSUMER_ACCT_EU' AND region = 'EU' THEN TRUE
    ELSE FALSE
  END;
```

### Solution 2: Use IS_DATABASE_ROLE_IN_SESSION (Best Practice)

```sql
-- Provider creates database roles and shares them
CREATE DATABASE ROLE sales_db.na_reader;
CREATE DATABASE ROLE sales_db.eu_reader;

-- Policy uses database roles
CREATE OR REPLACE ROW ACCESS POLICY rap_db_role_share
  AS (region VARCHAR) RETURNS BOOLEAN ->
  IS_DATABASE_ROLE_IN_SESSION('NA_READER') AND region = 'NA'
  OR IS_DATABASE_ROLE_IN_SESSION('EU_READER') AND region = 'EU'
  OR IS_DATABASE_ROLE_IN_SESSION('GLOBAL_READER');

-- Consumer grants the shared database role to their account roles
-- GRANT DATABASE ROLE sales_db.na_reader TO ROLE consumer_analyst;
```

---

## 15. Nested Policies (Table + View)

You can have a RAP on the table AND a RAP on a view built on that table.

```sql
-- RAP on table: filters by region
CREATE OR REPLACE ROW ACCESS POLICY rap_table_region
  AS (region VARCHAR) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('GLOBAL') OR region = 'NA';

ALTER TABLE sales ADD ROW ACCESS POLICY rap_table_region ON (region);

-- RAP on view: additional filter by classification
CREATE OR REPLACE ROW ACCESS POLICY rap_view_class
  AS (classification VARCHAR) RETURNS BOOLEAN ->
  classification != 'CONFIDENTIAL' OR IS_ROLE_IN_SESSION('EXEC');

CREATE VIEW public_sales
  WITH ROW ACCESS POLICY rap_view_class ON (classification)
AS SELECT * FROM sales;
```

### Evaluation Order:
```
Query on public_sales:
  1. Table RAP (rap_table_region) evaluated FIRST → filters by region
  2. View RAP (rap_view_class) evaluated SECOND → filters by classification
  3. User sees only rows passing BOTH policies
```

---

## 16. Interaction with Other Features

| Feature | Behavior |
|---------|----------|
| **Masking Policies** | RAP evaluated FIRST, then masking on surviving rows |
| **Streams** | RAP applied when stream reads table data |
| **Cloning** | Clone retains policy assignment |
| **CTAS** | New table gets filtered data (no RAP attached) |
| **CREATE TABLE LIKE** | New table is empty, no RAP attached |
| **Time Travel** | RAP uses CURRENT mapping table (not historical) |
| **Materialized Views** | Cannot have RAP on both base table AND MV (choose one) |
| **Dynamic Tables** | Supports RAP |
| **External Tables** | RAP can be applied to VALUE column |
| **Replication** | RAP replicated with database |
| **Search Optimization** | Works with RAP-protected tables |

---

## 17. Performance Guidelines

| Tip | Why |
|-----|-----|
| Minimize policy arguments | Snowflake scans ALL bound columns |
| Use simple CASE/IF over subqueries | No table lookup overhead |
| Replace EXISTS with memoizable functions | Cached results, fewer scans |
| Cluster by filtering columns | Better partition pruning |
| Use Search Optimization Service | Faster point lookups on RAP tables |
| Avoid multiple JOINs in policy body | Complex plans slow evaluation |

### Performance Warning:
```sql
-- Without RAP: SELECT COUNT(*) FROM big_table → instant (uses metadata)
-- With RAP:    SELECT COUNT(*) FROM big_table → full scan (must check each row)
```

---

## 18. Monitoring & Auditing

### Discover All Row Access Policies

```sql
-- Account-level: all policies
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.ROW_ACCESS_POLICIES
ORDER BY POLICY_NAME;

-- Schema-level
SHOW ROW ACCESS POLICIES IN SCHEMA governance.policies;

-- Describe a specific policy
DESCRIBE ROW ACCESS POLICY governance.policies.sales_rap;

-- Get DDL
SELECT GET_DDL('ROW_ACCESS_POLICY', 'governance.policies.sales_rap');
```

### Find All Assignments

```sql
-- Account-wide: which tables have RAPs?
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.POLICY_REFERENCES
WHERE POLICY_KIND = 'ROW_ACCESS_POLICY'
ORDER BY POLICY_NAME;

-- All objects for a specific policy
SELECT * FROM TABLE(
  mydb.INFORMATION_SCHEMA.POLICY_REFERENCES(
    POLICY_NAME => 'mydb.policies.rap1'
  )
);

-- Policies on a specific table
SELECT * FROM TABLE(
  mydb.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => 'mydb.public.sales',
    REF_ENTITY_DOMAIN => 'TABLE'
  )
);
```

### Verify Policy in Query Plan

```sql
EXPLAIN SELECT * FROM protected_table;
-- Look for: operation = 'DynamicSecureView'
--           objects = '"TABLE_NAME (+ RowAccessPolicy)"'
```

### Simulate Policy Behavior

```sql
-- Test what a specific role would see
EXECUTE USING POLICY_CONTEXT(
  SNOWFLAKE$SESSION_ACTIVATED_ROLES => ('ANALYST', 'PUBLIC')
)
AS SELECT * FROM protected_table;
```

---

## 19. Management Approaches

| Approach | Create Policies | Apply Policies | Best For |
|----------|----------------|----------------|----------|
| **Centralized** | Security team | Security team | Compliance-heavy orgs |
| **Hybrid** | Security team | Individual teams | Balanced orgs |
| **Decentralized** | Individual teams | Individual teams | Agile/startup |

### Centralized Setup

```sql
USE ROLE SECURITYADMIN;
GRANT CREATE ROW ACCESS POLICY ON SCHEMA governance.policies TO ROLE security_officer;
GRANT APPLY ROW ACCESS POLICY ON ACCOUNT TO ROLE security_officer;
```

### Hybrid Setup

```sql
-- Security creates policies
GRANT CREATE ROW ACCESS POLICY ON SCHEMA governance.policies TO ROLE security_officer;

-- Teams apply specific policies to their tables
GRANT APPLY ON ROW ACCESS POLICY governance.policies.sales_rap TO ROLE sales_team;
GRANT APPLY ON ROW ACCESS POLICY governance.policies.hr_rap TO ROLE hr_team;
```

---

## 20. Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `return type is not BOOLEAN` | Policy doesn't return BOOLEAN | Add `RETURNS BOOLEAN` |
| `does not have a current database` | No USE DATABASE set | Use fully qualified names |
| `Object already exists` | Policy name taken | Use different name or OR REPLACE |
| `Insufficient privileges to operate on schema` | Missing CREATE privilege | Grant CREATE ROW ACCESS POLICY |
| `does not exist or not authorized` | Missing OWNERSHIP or APPLY privilege | Grant appropriate privilege |
| `cannot be attached to a Materialized view` | RAP already on base table | Remove from base table or use dynamic table |
| Row counts seem wrong | RAP is filtering rows silently | Check CURRENT_ROLE, verify mapping table |
| All rows hidden | Policy returning FALSE for current role | Check policy logic, test with POLICY_CONTEXT |
| Slow queries after RAP | Subquery/mapping table overhead | Use memoizable functions, cluster by filter columns |

### Alter Policy Body (No Unset Needed)

```sql
-- Update policy logic without removing from tables
ALTER ROW ACCESS POLICY sales_rap SET BODY ->
  IS_ROLE_IN_SESSION('EXEC')
  OR (IS_ROLE_IN_SESSION('MANAGER') AND sales_region IN ('NA', 'EU'));
```

---

## 21. DDL Reference

| Command | Purpose |
|---------|---------|
| `CREATE ROW ACCESS POLICY` | Create a new policy |
| `ALTER ROW ACCESS POLICY ... SET BODY ->` | Update policy logic |
| `ALTER ROW ACCESS POLICY ... RENAME TO` | Rename |
| `DROP ROW ACCESS POLICY` | Delete (must remove from all tables first) |
| `SHOW ROW ACCESS POLICIES` | List policies |
| `DESCRIBE ROW ACCESS POLICY` | View definition |
| `ALTER TABLE ... ADD ROW ACCESS POLICY ... ON (col)` | Apply to table |
| `ALTER TABLE ... DROP ROW ACCESS POLICY` | Remove from table |
| `ALTER TABLE ... DROP ALL ROW ACCESS POLICIES` | Remove all from table |
| `ALTER VIEW ... ADD ROW ACCESS POLICY ... ON (col)` | Apply to view |

---

## 22. Complete Real-World Example

### Scenario: Multi-Tenant SaaS Application

Different customers should only see their own data. Internal support team sees all.

```sql
-- ============================================================
-- STEP 1: Create governance infrastructure
-- ============================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS governance;
CREATE SCHEMA IF NOT EXISTS governance.security;
CREATE SCHEMA IF NOT EXISTS governance.policies;

-- ============================================================
-- STEP 2: Create entitlement/mapping table
-- ============================================================
CREATE OR REPLACE TABLE governance.security.tenant_access (
  role_name    VARCHAR,
  tenant_id    VARCHAR,
  access_level VARCHAR  -- 'ALL' or specific tenant
);

INSERT INTO governance.security.tenant_access VALUES
  ('SUPPORT_ROLE', 'ALL', 'FULL'),
  ('TENANT_A_ROLE', 'TENANT_A', 'READ'),
  ('TENANT_B_ROLE', 'TENANT_B', 'READ'),
  ('TENANT_C_ROLE', 'TENANT_C', 'READ');

-- ============================================================
-- STEP 3: Create memoizable function for performance
-- ============================================================
CREATE OR REPLACE FUNCTION governance.security.my_allowed_tenants()
  RETURNS ARRAY
  MEMOIZABLE
AS
$$
  SELECT ARRAY_AGG(tenant_id)
  FROM governance.security.tenant_access
  WHERE role_name = CURRENT_ROLE()
$$;

-- ============================================================
-- STEP 4: Create the row access policy
-- ============================================================
CREATE OR REPLACE ROW ACCESS POLICY governance.policies.rap_tenant_isolation
  AS (tenant_id VARCHAR) RETURNS BOOLEAN ->
  -- Support team sees all tenants
  IS_ROLE_IN_SESSION('SUPPORT_ROLE')
  -- Or user's role has access to 'ALL'
  OR ARRAY_CONTAINS('ALL'::VARIANT, governance.security.my_allowed_tenants())
  -- Or user's role has specific tenant access
  OR ARRAY_CONTAINS(tenant_id::VARIANT, governance.security.my_allowed_tenants());

-- ============================================================
-- STEP 5: Apply policy to all tenant tables
-- ============================================================
ALTER TABLE app_db.public.orders
  ADD ROW ACCESS POLICY governance.policies.rap_tenant_isolation ON (tenant_id);

ALTER TABLE app_db.public.invoices
  ADD ROW ACCESS POLICY governance.policies.rap_tenant_isolation ON (tenant_id);

ALTER TABLE app_db.public.tickets
  ADD ROW ACCESS POLICY governance.policies.rap_tenant_isolation ON (tenant_id);

-- ============================================================
-- STEP 6: Test
-- ============================================================

-- As support: sees all tenants
USE ROLE SUPPORT_ROLE;
SELECT tenant_id, COUNT(*) FROM app_db.public.orders GROUP BY tenant_id;
-- Returns: TENANT_A: 500, TENANT_B: 300, TENANT_C: 200

-- As Tenant A: sees only their data
USE ROLE TENANT_A_ROLE;
SELECT tenant_id, COUNT(*) FROM app_db.public.orders GROUP BY tenant_id;
-- Returns: TENANT_A: 500 (only their rows)

-- ============================================================
-- STEP 7: Add a new tenant (just update mapping table!)
-- ============================================================
INSERT INTO governance.security.tenant_access VALUES
  ('TENANT_D_ROLE', 'TENANT_D', 'READ');
-- No policy change needed! Tenant D now automatically sees only their data.

-- ============================================================
-- STEP 8: Simulate with POLICY_CONTEXT
-- ============================================================
EXECUTE USING POLICY_CONTEXT(
  SNOWFLAKE$SESSION_ACTIVATED_ROLES => ('TENANT_B_ROLE')
)
AS SELECT * FROM app_db.public.orders LIMIT 10;
-- Shows what Tenant B would see
```

---

## Summary: When to Use What

```
Need to hide ROWS based on role/user?
  → ROW ACCESS POLICY

Need to hide COLUMN VALUES (but show the row)?
  → MASKING POLICY

Need both (filter rows AND mask some columns)?
  → Use BOTH (RAP runs first, then masking on surviving rows)
  → But: same column CANNOT be in both RAP signature AND masking policy

Simple logic (1-2 roles)?
  → Direct CURRENT_ROLE() or IS_ROLE_IN_SESSION() check

Complex entitlements (many roles, dynamic)?
  → Mapping table + memoizable function

Data Sharing?
  → Use CURRENT_ACCOUNT() or IS_DATABASE_ROLE_IN_SESSION()
  → NEVER use CURRENT_ROLE() or CURRENT_USER() for shared objects
```
