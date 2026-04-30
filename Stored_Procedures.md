# Snowflake Stored Procedures & UDFs — Complete Guide

> From Scratch to Architect Level with Interview Scenarios

---

## This Guide Covers

1. UDFs (User-Defined Functions) — SQL, Python, JavaScript
2. Stored Procedures — SQL, Python, JavaScript
3. SQL Stored Procedure Returning TABLE Data (with examples)
4. UDTFs (User-Defined Table Functions)
5. External Functions
6. Key Differences (UDF vs Stored Procedure)
7. Interview Questions — Scenario-Based (Beginner → Architect)

---

## Section 1: UDFs (User-Defined Functions)

### Simple Definition

A UDF is a FUNCTION you create that takes input, does something, and returns a SINGLE VALUE (one row in, one row out — scalar).

### Analogy

Think of a UDF like a formula in Excel. You give it inputs, it gives you one calculated result back. You can use it inside SELECT, WHERE, etc.

### Key Rules

1. UDFs are called INSIDE SQL statements (SELECT, WHERE, JOIN, etc.)
2. UDFs CANNOT execute DML (INSERT, UPDATE, DELETE, CREATE)
3. UDFs return ONE value per input row
4. UDFs are DETERMINISTIC by default (same input = same output)
5. UDFs support: SQL, Python, JavaScript, Java, Scala

---

### 1A. SQL UDF

```sql
CREATE OR REPLACE FUNCTION calculate_tax(price NUMBER, tax_rate NUMBER)
RETURNS NUMBER(12,2)
LANGUAGE SQL
AS
$$
  SELECT price * (tax_rate / 100)
$$;
```

**Usage:**
```sql
SELECT product_name, price, calculate_tax(price, 18) AS tax_amount
FROM products;
```

**Result:**

| PRODUCT_NAME | PRICE | TAX_AMOUNT |
|-------------|-------|-----------|
| Laptop | 50000 | 9000.00 |
| Phone | 20000 | 3600.00 |

---

### 1B. Python UDF

```sql
CREATE OR REPLACE FUNCTION mask_email(email VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
HANDLER = 'mask'
AS
$$
def mask(email):
    parts = email.split('@')
    if len(parts) == 2:
        name = parts[0]
        masked_name = name[0] + '***' + name[-1] if len(name) > 1 else name
        return masked_name + '@' + parts[1]
    return email
$$;
```

**Usage:**
```sql
SELECT email, mask_email(email) AS masked
FROM customers;
```

**Result:**

| EMAIL | MASKED |
|-------|--------|
| rohit@gmail.com | r***t@gmail.com |
| john.doe@company.com | j***e@company.com |

---

### 1C. JavaScript UDF

```sql
CREATE OR REPLACE FUNCTION generate_slug(title VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
AS
$$
  return TITLE.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
$$;
```

**Usage:**
```sql
SELECT title, generate_slug(title) AS slug FROM articles;
```

**Result:**

| TITLE | SLUG |
|-------|------|
| Hello World! First Post | hello-world-first-post |

> **IMPORTANT:** JavaScript UDF arguments are AUTOMATICALLY UPPERCASED. Inside `$$`, use `TITLE` (not `title`), or the variable will be undefined.

---

## Section 2: Stored Procedures

### Simple Definition

A Stored Procedure is a PROGRAM you create that can execute multiple SQL statements, use variables, loops, IF/ELSE, and perform DML operations (INSERT, UPDATE, DELETE, CREATE, DROP).

### Analogy

If a UDF is like a single formula cell in Excel, a Stored Procedure is like a VBA Macro — it can do MANY things: create tables, insert data, loop through records, handle errors.

### Key Rules

1. Called with CALL statement (not inside SELECT)
2. CAN execute DML (INSERT, UPDATE, DELETE, CREATE, DROP, GRANT)
3. CAN have IF/ELSE, loops, variables, error handling
4. Returns a SINGLE value (string, number, variant) OR a TABLE
5. Supports: SQL (Snowflake Scripting), Python, JavaScript, Java, Scala
6. Has CALLER'S RIGHTS vs OWNER'S RIGHTS security model

---

### 2A. SQL Stored Procedure (Snowflake Scripting) — Basic

```sql
CREATE OR REPLACE PROCEDURE greet_user(user_name VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
  RETURN 'Hello, ' || user_name || '! Welcome to Snowflake.';
END;
```

**Usage:**
```sql
CALL greet_user('Rohit');
-- Result: Hello, Rohit! Welcome to Snowflake.
```

---

### 2B. SQL Stored Procedure — With Variables, IF/ELSE, DML

```sql
CREATE OR REPLACE PROCEDURE process_order(order_id INT, action VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
  current_status VARCHAR;
  result_msg VARCHAR;
BEGIN
  SELECT status INTO current_status
    FROM orders WHERE id = :order_id;

  IF (action = 'APPROVE' AND current_status = 'PENDING') THEN
    UPDATE orders SET status = 'APPROVED' WHERE id = :order_id;
    result_msg := 'Order ' || order_id || ' approved.';
  ELSEIF (action = 'CANCEL') THEN
    UPDATE orders SET status = 'CANCELLED' WHERE id = :order_id;
    result_msg := 'Order ' || order_id || ' cancelled.';
  ELSE
    result_msg := 'No action taken. Current status: ' || current_status;
  END IF;

  RETURN result_msg;
END;
```

**Usage:**
```sql
CALL process_order(1001, 'APPROVE');
-- Result: Order 1001 approved.
```

---

### 2C. SQL Stored Procedure — With Loops and Cursors

```sql
CREATE OR REPLACE PROCEDURE archive_old_orders(cutoff_date DATE)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
  row_count INTEGER DEFAULT 0;
  res RESULTSET DEFAULT (
    SELECT id FROM orders WHERE order_date < :cutoff_date AND status = 'COMPLETED'
  );
  cur CURSOR FOR res;
BEGIN
  FOR rec IN cur DO
    INSERT INTO orders_archive SELECT * FROM orders WHERE id = rec.id;
    DELETE FROM orders WHERE id = rec.id;
    row_count := row_count + 1;
  END FOR;

  RETURN 'Archived ' || row_count || ' orders.';
END;
```

**Usage:**
```sql
CALL archive_old_orders('2024-01-01');
-- Result: Archived 145 orders.
```

---

### 2D. Python Stored Procedure

```sql
CREATE OR REPLACE PROCEDURE cleanup_staging(db_name VARCHAR, schema_name VARCHAR, days_old INT)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'run'
AS
$$
def run(session, db_name, schema_name, days_old):
    query = f"""
        SELECT table_name FROM {db_name}.information_schema.tables
        WHERE table_schema = '{schema_name}'
          AND table_name LIKE 'STG_%'
          AND created < DATEADD('day', -{days_old}, CURRENT_TIMESTAMP())
    """
    tables = session.sql(query).collect()
    dropped = 0
    for row in tables:
        session.sql(f"DROP TABLE IF EXISTS {db_name}.{schema_name}.{row['TABLE_NAME']}").collect()
        dropped += 1
    return f"Dropped {dropped} staging tables older than {days_old} days."
$$;
```

**Usage:**
```sql
CALL cleanup_staging('MY_DB', 'PUBLIC', 30);
```

---

### 2E. JavaScript Stored Procedure

```sql
CREATE OR REPLACE PROCEDURE bulk_grant_select(db_name VARCHAR, schema_name VARCHAR, role_name VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
EXECUTE AS CALLER
AS
$$
  var sql = `SELECT table_name FROM ${DB_NAME}.information_schema.tables
             WHERE table_schema = '${SCHEMA_NAME}' AND table_type = 'BASE TABLE'`;
  var stmt = snowflake.createStatement({sqlText: sql});
  var rs = stmt.execute();
  var count = 0;

  while (rs.next()) {
    var tbl = rs.getColumnValue(1);
    var grant_sql = `GRANT SELECT ON TABLE ${DB_NAME}.${SCHEMA_NAME}.${tbl} TO ROLE ${ROLE_NAME}`;
    snowflake.createStatement({sqlText: grant_sql}).execute();
    count++;
  }

  return 'Granted SELECT on ' + count + ' tables to role ' + ROLE_NAME;
$$;
```

**Usage:**
```sql
CALL bulk_grant_select('ANALYTICS_DB', 'PUBLIC', 'ANALYST_ROLE');
```

> **IMPORTANT:**
> - `EXECUTE AS CALLER` → runs with the caller's privileges.
> - `EXECUTE AS OWNER` (default) → runs with the procedure owner's privileges.
> - JavaScript arguments are AUTO-UPPERCASED: use `DB_NAME`, not `db_name`.

---

## Section 3: SQL Stored Procedure Returning TABLE Data

### Key Concept

> **Interview Question:** "Can a Snowflake stored procedure return a result set (table)?"
> **Answer:** YES — use `RETURNS TABLE()` and `RETURN TABLE(resultset)`.

In Snowflake Scripting, `RESULTSET` is a data type that POINTS to the result of a query. You declare it, assign a query to it, then return it as `TABLE(resultset_name)`.

---

### 3A. Basic — Return Table with Known Columns

```sql
CREATE OR REPLACE PROCEDURE get_top_customers(min_spend NUMBER)
RETURNS TABLE (customer_name VARCHAR, total_spent NUMBER(12,2))
LANGUAGE SQL
AS
DECLARE
  res RESULTSET DEFAULT (
    SELECT customer_name, SUM(amount) AS total_spent
    FROM orders
    GROUP BY customer_name
    HAVING SUM(amount) >= :min_spend
    ORDER BY total_spent DESC
  );
BEGIN
  RETURN TABLE(res);
END;
```

**Usage:**
```sql
CALL get_top_customers(100000);
```

**Result (returns as a TABLE):**

| CUSTOMER_NAME | TOTAL_SPENT |
|--------------|------------|
| Acme Corp | 250000.00 |
| TechStart Inc | 180000.00 |
| DataCo | 120000.00 |

---

### 3B. Dynamic — Return Table with Dynamic SQL

```sql
CREATE OR REPLACE PROCEDURE search_table(
  table_name VARCHAR,
  column_name VARCHAR,
  search_value VARCHAR
)
RETURNS TABLE ()
LANGUAGE SQL
AS
DECLARE
  res RESULTSET;
  query VARCHAR;
BEGIN
  query := 'SELECT * FROM IDENTIFIER(''' || table_name || ''') WHERE '
           || column_name || ' = ''' || search_value || '''';
  res := (EXECUTE IMMEDIATE :query);
  RETURN TABLE(res);
END;
```

**Usage:**
```sql
CALL search_table('employees', 'department', 'Engineering');
-- Returns ALL columns from employees where department = 'Engineering'
-- Columns are determined at runtime (RETURNS TABLE() with no columns specified)
```

---

### 3C. With Bind Variables (Safer — Prevents SQL Injection)

```sql
CREATE OR REPLACE PROCEDURE find_orders_by_customer(cust_id INT)
RETURNS TABLE (order_id INT, order_date DATE, amount NUMBER(12,2), status VARCHAR)
LANGUAGE SQL
AS
DECLARE
  res RESULTSET DEFAULT (
    SELECT order_id, order_date, amount, status
    FROM orders
    WHERE customer_id = :cust_id
    ORDER BY order_date DESC
  );
BEGIN
  RETURN TABLE(res);
END;
```

**Usage:**
```sql
CALL find_orders_by_customer(42);
```

**Result:**

| ORDER_ID | ORDER_DATE | AMOUNT | STATUS |
|----------|-----------|--------|--------|
| 5001 | 2025-04-15 | 15000.00 | COMPLETED |
| 4832 | 2025-03-01 | 8500.00 | SHIPPED |

---

### 3D. Chaining — Use TABLE Result from One Procedure in Another Query

**Method 1: Pipe operator (-->>)**
```sql
CALL get_top_customers(100000)
  ->> SELECT * FROM $1 WHERE total_spent > 200000;
```

**Method 2: RESULT_SCAN**
```sql
CALL get_top_customers(100000);
SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) WHERE total_spent > 200000;
```

---

## Section 4: UDTFs (User-Defined Table Functions)

### Simple Definition

A UDTF takes ONE input row and returns MULTIPLE output rows (a table). Think of it as "exploding" one row into many rows.

### Analogy

| Type | Input | Output | Example |
|------|-------|--------|---------|
| UDF | 1 row | 1 value | Calculate tax for one item |
| UDTF | 1 row | N rows | Split a comma-separated string into rows |

### Key Rules

1. Called with `TABLE()` in FROM clause: `SELECT * FROM TABLE(my_udtf(args))`
2. Returns multiple rows per input row
3. Supports: SQL, Python, JavaScript, Java, Scala
4. Python UDTFs use a CLASS with `process()` and optional `end_partition()`

---

### 4A. SQL UDTF — Split Comma-Separated Values into Rows

```sql
CREATE OR REPLACE FUNCTION split_tags(tag_string VARCHAR)
RETURNS TABLE (tag VARCHAR)
LANGUAGE SQL
AS
$$
  SELECT VALUE::VARCHAR AS tag
  FROM TABLE(SPLIT_TO_TABLE(tag_string, ','))
$$;
```

**Usage:**
```sql
SELECT t.tag
FROM TABLE(split_tags('python,sql,snowflake,dbt')) AS t;
```

**Result:**

| TAG |
|-----|
| python |
| sql |
| snowflake |
| dbt |

---

### 4B. Python UDTF — Generate Date Range Rows

```sql
CREATE OR REPLACE FUNCTION generate_dates(start_date DATE, end_date DATE)
RETURNS TABLE (generated_date DATE)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
HANDLER = 'DateGenerator'
AS
$$
from datetime import timedelta

class DateGenerator:
    def process(self, start_date, end_date):
        current = start_date
        while current <= end_date:
            yield (current,)
            current += timedelta(days=1)
$$;
```

**Usage:**
```sql
SELECT * FROM TABLE(generate_dates('2025-01-01'::DATE, '2025-01-05'::DATE));
```

**Result:**

| GENERATED_DATE |
|---------------|
| 2025-01-01 |
| 2025-01-02 |
| 2025-01-03 |
| 2025-01-04 |
| 2025-01-05 |

---

### 4C. Python UDTF — With PARTITION BY (Process Groups)

```sql
CREATE OR REPLACE FUNCTION running_total(amount NUMBER(12,2))
RETURNS TABLE (row_amount NUMBER(12,2), cumulative_total NUMBER(12,2))
LANGUAGE PYTHON
RUNTIME_VERSION = '3.12'
HANDLER = 'RunningTotal'
AS
$$
class RunningTotal:
    def __init__(self):
        self._total = 0

    def process(self, amount):
        self._total += amount
        yield (amount, self._total)

    def end_partition(self):
        yield (None, self._total)
$$;
```

**Usage:**
```sql
SELECT rt.*
FROM sales s,
     TABLE(running_total(s.amount) OVER (PARTITION BY s.region ORDER BY s.sale_date)) rt;
```

**Lifecycle:**
- `__init__()` → called once per partition (reset total to 0)
- `process()` → called for each row (add to running total)
- `end_partition()` → called after last row in partition (return final total)

---

### 4D. JavaScript UDTF

```sql
CREATE OR REPLACE FUNCTION tokenize(input_text VARCHAR)
RETURNS TABLE (token VARCHAR, position INT)
LANGUAGE JAVASCRIPT
AS
$$
{
  processRow: function(row, rowWriter, context) {
    var text = row.INPUT_TEXT;
    var tokens = text.split(/\s+/);
    for (var i = 0; i < tokens.length; i++) {
      rowWriter.writeRow({TOKEN: tokens[i], POSITION: i + 1});
    }
  }
}
$$;
```

**Usage:**
```sql
SELECT * FROM TABLE(tokenize('Snowflake is amazing'));
```

**Result:**

| TOKEN | POSITION |
|-------|----------|
| Snowflake | 1 |
| is | 2 |
| amazing | 3 |

---

## Section 5: External Functions

### Simple Definition

An External Function calls a REST API endpoint OUTSIDE of Snowflake (e.g., AWS Lambda, Azure Functions, Google Cloud Functions). Snowflake sends data OUT → API processes it → returns results back.

### When to Use

- Call a machine learning model hosted on AWS SageMaker
- Call a third-party API (geocoding, translation, sentiment analysis)
- Run custom logic that can't run inside Snowflake

### Architecture

```
Snowflake → API Integration → API Gateway (AWS/Azure/GCP) → Lambda/Function
```

### Setup Steps

1. Create the external service (e.g., AWS Lambda function)
2. Create an API Gateway that exposes the Lambda as a REST endpoint
3. Create an API INTEGRATION in Snowflake (connects to the gateway)
4. Create the EXTERNAL FUNCTION in Snowflake

### Step 1: Create API Integration (Admin Does This Once)

```sql
CREATE OR REPLACE API INTEGRATION my_api_integration
  API_PROVIDER = aws_api_gateway
  API_AWS_ROLE_ARN = 'arn:aws:iam::123456789:role/my-api-role'
  API_ALLOWED_PREFIXES = ('https://abc123.execute-api.us-east-1.amazonaws.com/')
  ENABLED = TRUE;
```

### Step 2: Create External Function

```sql
CREATE OR REPLACE EXTERNAL FUNCTION sentiment_analysis(text VARCHAR)
  RETURNS VARIANT
  API_INTEGRATION = my_api_integration
  AS 'https://abc123.execute-api.us-east-1.amazonaws.com/prod/sentiment';
```

### Step 3: Use It Like a Regular Function

```sql
SELECT review_text, sentiment_analysis(review_text) AS sentiment
FROM product_reviews;
```

### Key Points

- External functions are **SLOWER** (network round-trip to cloud API)
- Data **leaves Snowflake** (security/compliance consideration)
- Billed per API call + Snowflake compute
- Supports **batching** (Snowflake sends rows in batches for efficiency)
- Must be **SECURE** for sharing across accounts

---

## Section 6: Key Differences — UDF vs Stored Procedure

### UDF vs Stored Procedure

| Feature | UDF | Stored Procedure |
|---------|-----|-----------------|
| Called with | SELECT, WHERE, JOIN | CALL statement only |
| Returns | Single scalar value | Scalar OR TABLE |
| Can do DML? | NO (read-only) | YES (INSERT, UPDATE...) |
| Can do DDL? | NO | YES (CREATE, DROP...) |
| Security model | N/A | Caller's / Owner's |
| Used in expressions | YES (`col + my_udf(x)`) | NO |
| Transaction control | NO | YES (BEGIN, COMMIT) |
| Use case | Transform/calculate | Automate/orchestrate |

### UDTF vs UDF

| Feature | UDF (Scalar) | UDTF (Table) |
|---------|-------------|--------------|
| Input | 1 row | 1 row |
| Output | 1 value | Multiple rows |
| Called in | SELECT column list | `FROM TABLE(my_udtf())` |
| Use case | Calculate one value | Explode/generate rows |

---

## Section 7: Interview Questions — Scenario-Based

---

### Beginner Level

#### Q1: What is the difference between a UDF and a Stored Procedure?

> "A UDF is a function used INSIDE SQL statements (SELECT, WHERE) that returns a single value and CANNOT modify data. A Stored Procedure is called with CALL, can execute DML/DDL, has control flow (IF/ELSE, loops), and can return a scalar value or a table. Use UDFs for calculations, use Stored Procedures for automation and orchestration."

#### Q2: Can a UDF do an INSERT or CREATE TABLE?

> "No. UDFs are read-only. They cannot perform any DML or DDL operations. If you need to modify data, use a Stored Procedure."

#### Q3: How do you call a UDF vs a Stored Procedure?

> "UDF: `SELECT my_udf(column_name) FROM table;`
> SP: `CALL my_procedure(arguments);`
> A UDF can be used anywhere an expression is valid. A Stored Procedure can ONLY be called with CALL."

#### Q4: What languages can you write UDFs and Stored Procedures in?

> "UDFs: SQL, Python, JavaScript, Java, Scala.
> Stored Procedures: SQL (Snowflake Scripting), Python, JavaScript, Java, Scala.
> SQL and JavaScript handlers must be inline. Python, Java, Scala handlers can be inline or on a stage."

---

### Intermediate Level

#### Q5: SCENARIO — Your team needs to mask PII data (email, phone) in reports. Would you use a UDF or Stored Procedure? Why?

> "I would use a UDF. Masking is a per-row transformation — you take an email and return a masked version. Since it's used inside SELECT statements and doesn't modify data, a UDF is the right choice.
> Example: `SELECT mask_email(email) FROM customers;`
> I might even make it a SECURE UDF so the logic can't be reverse-engineered."

#### Q6: SCENARIO — Every night at 2 AM, you need to: 1) Truncate a staging table, 2) Load data from a stage, 3) Merge into production, 4) Log the result. Would you use a UDF or Stored Procedure?

> "Stored Procedure, 100%. This is multi-step orchestration with DML (TRUNCATE, COPY INTO, MERGE, INSERT into log table). A UDF can't do any of these. I'd write a SQL Stored Procedure with error handling and call it from a Snowflake Task for scheduling."

#### Q7: Can a Stored Procedure return TABLE data? How?

> "Yes. Use `RETURNS TABLE(...)` in the CREATE PROCEDURE statement and `RETURN TABLE(resultset)` in the body. Example:
> ```sql
> CREATE PROCEDURE get_data() RETURNS TABLE(id INT, name VARCHAR) ...
> DECLARE res RESULTSET DEFAULT (SELECT id, name FROM users);
> BEGIN RETURN TABLE(res); END;
> ```
> You can also use `RETURNS TABLE()` with empty parens if column types are determined at runtime (dynamic SQL)."

#### Q8: SCENARIO — You have a JavaScript Stored Procedure but the argument names don't seem to work. What's wrong?

> "JavaScript stored procedures AUTO-UPPERCASE all argument names. If the procedure is defined as `my_proc(user_name VARCHAR)`, inside the JavaScript code you must use `USER_NAME`, not `user_name`. This is a very common bug. Always use UPPERCASE inside `$$ ... $$`."

#### Q9: What's the difference between EXECUTE AS CALLER and EXECUTE AS OWNER?

> **EXECUTE AS OWNER (default):** The procedure runs with the privileges of the ROLE that OWNS the procedure. The caller doesn't need direct access to the underlying tables. Good for controlled data access.
>
> **EXECUTE AS CALLER:** The procedure runs with the privileges of the ROLE that CALLS the procedure. The caller needs direct access to all objects. Good for utility procedures (like granting permissions, dynamic SQL).
>
> **KEY:** Owner's rights procedures CANNOT access session variables. Caller's rights procedures CAN access session variables.

---

### Advanced Level

#### Q10: SCENARIO — You need to split a JSON array in each row into separate rows. UDF or UDTF?

> "UDTF. A UDF returns one value per row, but I need to EXPLODE one row into many rows. A UDTF takes one input row and yields multiple output rows. In Python:
> ```python
> class JsonExploder:
>   def process(self, json_array):
>     for item in json_array:
>       yield (item,)
> ```
> Alternatively, I could use Snowflake's LATERAL FLATTEN built-in."

#### Q11: SCENARIO — You want to call an external ML model (hosted on AWS SageMaker) from a SQL query. How?

> "Use an External Function.
> 1. Create an API Integration pointing to the API Gateway
> 2. Create an External Function that calls the SageMaker endpoint
> 3. Use it in SQL: `SELECT predict_churn(features) FROM customers;`
>
> Key considerations: data leaves Snowflake (security review needed), latency is higher (network round-trip), and I'd batch rows to minimize API calls."

#### Q12: SCENARIO — A Python UDTF with end_partition() is timing out. What do you do?

> "end_partition() is called after ALL rows in a partition are processed. If the partition is too large, it can time out. Solutions:
> 1. Reduce partition size — change PARTITION BY to a higher-cardinality column
> 2. Move heavy computation to process() instead of end_partition()
> 3. Contact Snowflake Support to adjust the timeout threshold
> 4. Consider using a Stored Procedure with batch processing instead"

#### Q13: What's the difference between a UDTF and LATERAL FLATTEN?

> "LATERAL FLATTEN is a BUILT-IN way to explode semi-structured data (arrays, objects) into rows. A UDTF is a CUSTOM function that lets you define ANY logic for generating rows.
> - Use FLATTEN when: you're exploding JSON/ARRAY/OBJECT data.
> - Use UDTF when: you need custom logic (date generation, complex parsing, calling external services, stateful processing)."

---

### Architect Level

#### Q14: SCENARIO — Your company wants to build a data access layer where analysts can only access data through procedures, never direct table access. How do you architect this?

> "I'd use Owner's Rights Stored Procedures combined with RBAC:
> 1. Create a PROCEDURE_OWNER role that owns all procedures and has SELECT on all underlying tables.
> 2. Create procedures like `get_customer_data(customer_id)` that RETURN TABLE with only the allowed columns.
> 3. Grant USAGE on the procedures to the ANALYST role.
> 4. Do NOT grant SELECT on tables to ANALYST role.
> 5. Analysts call `CALL get_customer_data(42)` — they get data but never see the raw tables or other customers' data.
>
> This is the 'Stored Procedure as API' pattern. It enforces row-level and column-level security through code."

#### Q15: SCENARIO — You need to process 500 million rows through a Python function. UDF or Stored Procedure? How do you optimize?

> "For per-row transformation, use a **VECTORIZED Python UDF**. Unlike a regular Python UDF (processes 1 row at a time), a vectorized UDF receives batches as Pandas DataFrames. This is 10-100x faster because:
> - Reduces Python ↔ Snowflake serialization overhead
> - Leverages Pandas vectorized operations (NumPy under the hood)
>
> ```sql
> CREATE FUNCTION fast_calc(val FLOAT)
>   RETURNS FLOAT
>   LANGUAGE PYTHON
>   RUNTIME_VERSION = '3.12'
>   PACKAGES = ('pandas')
>   HANDLER = 'calc'
> AS $$
> import pandas
> from _snowflake import vectorized
>
> @vectorized(input=pandas.DataFrame)
> def calc(df):
>     return df[0] * 1.18
> $$;
> ```
>
> For orchestration (multi-step ETL), use a Stored Procedure."

#### Q16: SCENARIO — A procedure needs to grant roles, create warehouses, and set up a new environment for onboarding. Caller's or Owner's rights?

> "CALLER'S RIGHTS with `EXECUTE AS CALLER`. Here's why:
> - GRANT, CREATE WAREHOUSE, and account-level DDL require the caller to have the appropriate admin role (SYSADMIN, SECURITYADMIN).
> - Owner's rights procedures run in a restricted context and CANNOT perform certain admin operations.
> - The caller must explicitly USE ROLE before calling the procedure.
> - I'd also add validation logic inside the procedure to ensure the caller has the expected role before executing."

#### Q17: SCENARIO — You have a JavaScript Stored Procedure that occasionally returns wrong numbers. The values look slightly off. What's happening?

> "JavaScript has a Number precision limit: -(2^53-1) to (2^53-1). Snowflake NUMBER(38,0) can hold values much larger than this. When a large number is passed to JavaScript, it loses precision.
>
> Example: `4730168494964875235` becomes `4730168494964875000` (last 3 digits lost).
>
> Fix: Use `getColumnValueAsString()` instead of `getColumnValue()` to retrieve large numbers as strings, then process them as strings. Or switch to Python/SQL procedures which handle large numbers natively."

#### Q18: SCENARIO — You want to create a reusable utility that other teams can use across accounts via Snowflake Data Sharing. UDF or Procedure?

> "UDF — specifically a SQL UDF or JavaScript UDF. These are the ONLY types that are SHARABLE via Snowflake Secure Data Sharing.
> - Python, Java, and Scala UDFs are NOT sharable.
> - Stored Procedures are NOT sharable via Data Sharing.
>
> If the utility needs to be a procedure, consider wrapping it in a Native App (Snowflake Marketplace) instead of Data Sharing."

#### Q19: SCENARIO — Your procedure runs fine but sometimes silently returns no data. No error message. What could cause this?

> "Several common causes:
> 1. **Session variable issue** — If using Owner's Rights, it cannot access session variables set before the CALL. Switch to Caller's Rights.
> 2. **Role context** — Owner's Rights runs as the owner's role, which may not have access to the table the caller expects.
> 3. **Warehouse suspended** — If the warehouse auto-suspended between the CALL and execution, there may be a timing issue.
> 4. **Empty RESULTSET** — The query inside returned 0 rows (not an error).
>
> Always add explicit error handling:
> ```sql
> IF (res IS NULL) THEN RETURN 'No data found'; END IF;
> ```"

#### Q20: SCENARIO — Design a self-service data export system where users request data exports and the system generates CSV files on a stage.

> "Architecture:
> 1. Create a STORED PROCEDURE `export_data(query_text, stage_path)` that uses EXECUTE IMMEDIATE to run the user's query and COPY INTO @stage to write results as CSV.
> 2. Use CALLER'S RIGHTS so the procedure respects the user's data access permissions (they can't export data they can't see).
> 3. Add validation: check query_text doesn't contain DDL/DML keywords.
> 4. Log every export to an audit table (who, when, what query, file path).
> 5. Schedule cleanup of old exports with a Task.
> 6. Wrap the procedure call in a Streamlit app for a UI.
>
> This gives you self-service + audit trail + security."

---

*End of Snowflake Stored Procedures & UDFs Complete Guide*
