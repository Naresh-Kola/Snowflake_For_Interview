# LATERAL IN SNOWFLAKE — Complete Guide

LATERAL, LATERAL FLATTEN, and LATERAL SPLIT_TO_TABLE explained with examples.
Written for someone with ZERO knowledge of LATERAL.

---

## SECTION 1: WHAT IS LATERAL?

LATERAL is a keyword used in the FROM clause that allows an inline view (subquery or table function) to **REFERENCE COLUMNS** from a table that appears **BEFORE** it in the FROM clause.

**Without LATERAL:**
A subquery in FROM cannot see columns from other tables in the same FROM.

**With LATERAL:**
The subquery/function CAN access columns from the preceding table, and it runs ONCE PER ROW of the left table (like a loop).

### ANALOGY

Think of it like a FOR-EACH loop:

```
FOR EACH ROW in left_table:
    Execute the right-side subquery/function using that row's values
    Join the results back to that row
```

### SYNTAX

```sql
SELECT ...
FROM left_table,
     LATERAL ( <subquery or table function> )
```

### WHEN TO USE

1. Flattening arrays within arrays (nested JSON)
2. Calling table functions with row-specific arguments
3. Splitting strings per row
4. Any time you need the right side to "see" the left side's columns

---

## SECTION 2: LATERAL WITH A SUBQUERY (Basic Example)

```sql
CREATE OR REPLACE TABLE departments (
    department_id INT,
    name VARCHAR(50)
);

CREATE OR REPLACE TABLE employees (
    employee_id INT,
    last_name VARCHAR(50),
    department_id INT
);

INSERT INTO departments VALUES (1, 'Engineering'), (2, 'Support');
INSERT INTO employees VALUES (101, 'Richards', 1), (102, 'Paulson', 1), (103, 'Johnson', 2);
```

**WITHOUT LATERAL (normal join):**

```sql
SELECT *
FROM departments d, employees e
WHERE e.department_id = d.department_id
ORDER BY employee_id;
```

**WITH LATERAL (subquery references d.department_id from the LEFT table):**

```sql
SELECT *
FROM departments AS d,
     LATERAL (
         SELECT * FROM employees AS e
         WHERE e.department_id = d.department_id  -- ← references left table!
     ) AS lateral_result
ORDER BY employee_id;
```

### EXPLANATION

- For department_id = 1 (Engineering):
  - Execute subquery → finds employees 101, 102
  - Join those to the Engineering row
- For department_id = 2 (Support):
  - Execute subquery → finds employee 103
  - Join that to the Support row

### RESULT

| DEPARTMENT_ID | NAME        | EMPLOYEE_ID | LAST_NAME | DEPARTMENT_ID |
|---------------|-------------|-------------|-----------|---------------|
| 1             | Engineering | 101         | Richards  | 1             |
| 1             | Engineering | 102         | Paulson   | 1             |
| 2             | Support     | 103         | Johnson   | 2             |

---

## SECTION 3: LATERAL FLATTEN — Exploding Arrays/JSON into Rows

### WHAT IS FLATTEN?

FLATTEN is a Snowflake TABLE FUNCTION that takes an ARRAY or OBJECT and produces ONE ROW per element.

### WHY COMBINE WITH LATERAL?

Because FLATTEN needs to reference a column from the LEFT table (the array column for EACH row). LATERAL allows that reference.

### SYNTAX

```sql
SELECT ...
FROM my_table,
     LATERAL FLATTEN(INPUT => my_table.array_column) AS f
```

### BREAKING DOWN EACH WORD

| Keyword | Meaning |
|---------|---------|
| LATERAL | "for each row, run the function using that row's data" |
| FLATTEN | table function that explodes arrays into rows |
| INPUT => | the parameter name (what to flatten) |
| my_table.col | the array/variant column to explode |
| AS f | alias for the flattened output (gives access to f.value, f.index, etc.) |

### EXAMPLE: Explode a JSON array column

```sql
CREATE OR REPLACE TABLE orders (
    order_id INT,
    customer VARCHAR(10),
    items VARIANT
);

INSERT INTO orders
SELECT 1, 'C001', PARSE_JSON('[{"product":"Laptop","qty":1},{"product":"Mouse","qty":2}]')
UNION ALL
SELECT 2, 'C002', PARSE_JSON('[{"product":"Keyboard","qty":1}]')
UNION ALL
SELECT 3, 'C003', PARSE_JSON('[]');  -- empty array (0 items)
```

**View raw data:**

```sql
SELECT * FROM orders;
```

| ORDER_ID | CUSTOMER | ITEMS |
|----------|----------|-------|
| 1 | C001 | [{"product":"Laptop","qty":1},{"product":"Mouse","qty":2}] |
| 2 | C002 | [{"product":"Keyboard","qty":1}] |
| 3 | C003 | [] |

**LATERAL FLATTEN to explode items array:**

```sql
SELECT
    o.order_id,
    o.customer,
    f.index AS item_index,          -- position in the array (0-based)
    f.value:product::STRING AS product,  -- extract "product" key from JSON object
    f.value:qty::NUMBER AS quantity      -- extract "qty" key from JSON object
FROM orders o,
     LATERAL FLATTEN(INPUT => o.items) f;
```

### RESULT

| ORDER_ID | CUSTOMER | ITEM_INDEX | PRODUCT  | QUANTITY |
|----------|----------|------------|----------|----------|
| 1        | C001     | 0          | Laptop   | 1        |
| 1        | C001     | 1          | Mouse    | 2        |
| 2        | C002     | 0          | Keyboard | 1        |

> **NOTE:** Order 3 (empty array) produces 0 rows — it disappears!
> Use `OUTER => TRUE` to keep it (see below).

**WITH OUTER => TRUE (keeps rows even when array is empty):**

```sql
SELECT
    o.order_id,
    o.customer,
    f.value:product::STRING AS product,
    f.value:qty::NUMBER AS quantity
FROM orders o,
     LATERAL FLATTEN(INPUT => o.items, OUTER => TRUE) f;
```

### RESULT (now includes order 3)

| ORDER_ID | CUSTOMER | PRODUCT  | QUANTITY |
|----------|----------|----------|----------|
| 1        | C001     | Laptop   | 1        |
| 1        | C001     | Mouse    | 2        |
| 2        | C002     | Keyboard | 1        |
| 3        | C003     | NULL     | NULL     |

---

## SECTION 4: FLATTEN OUTPUT COLUMNS

When you alias FLATTEN as "f", you get these columns:

| Column  | Description |
|---------|-------------|
| f.seq   | Unique sequence number across all input rows |
| f.key   | Key name (for objects) or NULL (for arrays) |
| f.path  | Path to this element in the original structure |
| f.index | Array index (0-based) of the current element |
| f.value | The actual value of the current element |
| f.this  | The entire array/object being flattened |

---

## SECTION 5: CHAINING LATERAL FLATTEN (Nested Arrays)

When you have arrays INSIDE arrays, you need MULTIPLE LATERAL FLATTENs. Each subsequent FLATTEN references the output of the previous one.

```sql
CREATE OR REPLACE TABLE contacts AS
SELECT column1 AS id, PARSE_JSON(column2) AS data
FROM VALUES
    (1, '{"name":"John","phones":[{"type":"home","numbers":["555-1234","555-5678"]},{"type":"work","numbers":["555-9999"]}]}'),
    (2, '{"name":"Jane","phones":[{"type":"mobile","numbers":["555-0000"]}]}');
```

**First FLATTEN:** explode the "phones" array
**Second FLATTEN:** explode the "numbers" array within each phone

```sql
SELECT
    c.id,
    c.data:name::STRING AS name,
    f1.value:type::STRING AS phone_type,
    f2.value::STRING AS phone_number
FROM contacts c,
     LATERAL FLATTEN(INPUT => c.data:phones) f1,        -- 1st level: phones array
     LATERAL FLATTEN(INPUT => f1.value:numbers) f2;     -- 2nd level: numbers within each phone
```

### RESULT

| ID | NAME | PHONE_TYPE | PHONE_NUMBER |
|----|------|------------|--------------|
| 1  | John | home       | 555-1234     |
| 1  | John | home       | 555-5678     |
| 1  | John | work       | 555-9999     |
| 2  | Jane | mobile     | 555-0000     |

**WHY LATERAL IS REQUIRED HERE:**
The second FLATTEN references `f1.value` (output of the first FLATTEN). Without LATERAL, it cannot see `f1.value`. LATERAL makes it possible.

---

## SECTION 6: LATERAL SPLIT_TO_TABLE — Splitting Strings into Rows

### WHAT IS SPLIT_TO_TABLE?

A table function that splits a string by a delimiter and returns ONE ROW per segment.

### WHY COMBINE WITH LATERAL?

Because you need to split a DIFFERENT string for EACH ROW. LATERAL lets SPLIT_TO_TABLE reference the current row's column.

### SYNTAX

```sql
SELECT ...
FROM my_table,
     LATERAL SPLIT_TO_TABLE(my_table.string_column, 'delimiter') AS s
```

### BREAKING DOWN EACH WORD

| Keyword | Meaning |
|---------|---------|
| LATERAL | "for each row, run this function with that row's data" |
| SPLIT_TO_TABLE | table function that splits strings into rows |
| (column, ',') | split this column by comma (or any delimiter) |
| AS s | alias for the split output |

### EXAMPLE: Split comma-separated skills into individual rows

```sql
CREATE OR REPLACE TABLE employees_skills (
    emp_id INT,
    emp_name VARCHAR(50),
    skills VARCHAR(200)  -- comma-separated list
);

INSERT INTO employees_skills VALUES
(1, 'Alice', 'Python,SQL,Snowflake'),
(2, 'Bob', 'Java,AWS'),
(3, 'Charlie', 'SQL,dbt,Airflow,Python'),
(4, 'Diana', 'Excel');  -- single skill (no comma)
```

**View raw data:**

```sql
SELECT * FROM employees_skills;
```

| EMP_ID | EMP_NAME | SKILLS |
|--------|----------|--------|
| 1 | Alice | Python,SQL,Snowflake |
| 2 | Bob | Java,AWS |
| 3 | Charlie | SQL,dbt,Airflow,Python |
| 4 | Diana | Excel |

**LATERAL SPLIT_TO_TABLE to explode skills:**

```sql
SELECT
    e.emp_id,
    e.emp_name,
    s.seq,                      -- sequence number (unique per input row)
    s.index,                    -- position of this segment (1-based)
    TRIM(s.value) AS skill     -- the split value (trimmed of spaces)
FROM employees_skills e,
     LATERAL SPLIT_TO_TABLE(e.skills, ',') s;
```

### RESULT

| EMP_ID | EMP_NAME | SEQ | INDEX | SKILL     |
|--------|----------|-----|-------|-----------|
| 1      | Alice    | 1   | 1     | Python    |
| 1      | Alice    | 1   | 2     | SQL       |
| 1      | Alice    | 1   | 3     | Snowflake |
| 2      | Bob      | 2   | 1     | Java      |
| 2      | Bob      | 2   | 2     | AWS       |
| 3      | Charlie  | 3   | 1     | SQL       |
| 3      | Charlie  | 3   | 2     | dbt       |
| 3      | Charlie  | 3   | 3     | Airflow   |
| 3      | Charlie  | 3   | 4     | Python    |
| 4      | Diana    | 4   | 1     | Excel     |

### SPLIT_TO_TABLE OUTPUT COLUMNS

| Column  | Description |
|---------|-------------|
| s.seq   | Unique number identifying the source row |
| s.index | Position of this piece in the split (1-based) |
| s.value | The actual string segment after splitting |

---

## SECTION 7: PRACTICAL USE CASE — Find employees who know SQL

```sql
SELECT DISTINCT
    e.emp_id,
    e.emp_name
FROM employees_skills e,
     LATERAL SPLIT_TO_TABLE(e.skills, ',') s
WHERE TRIM(s.value) = 'SQL';
```

### RESULT

| EMP_ID | EMP_NAME |
|--------|----------|
| 1      | Alice    |
| 3      | Charlie  |

---

## SECTION 8: PRACTICAL USE CASE — Count skills per employee

```sql
SELECT
    e.emp_id,
    e.emp_name,
    COUNT(s.value) AS skill_count
FROM employees_skills e,
     LATERAL SPLIT_TO_TABLE(e.skills, ',') s
GROUP BY e.emp_id, e.emp_name
ORDER BY skill_count DESC;
```

### RESULT

| EMP_ID | EMP_NAME | SKILL_COUNT |
|--------|----------|-------------|
| 3      | Charlie  | 4           |
| 1      | Alice    | 3           |
| 2      | Bob      | 2           |
| 4      | Diana    | 1           |

---

## SECTION 9: LATERAL FLATTEN vs LATERAL SPLIT_TO_TABLE — Comparison

| Feature | LATERAL FLATTEN | LATERAL SPLIT_TO_TABLE |
|---------|----------------|------------------------|
| Input type | VARIANT, ARRAY, OBJECT | VARCHAR (string) |
| What it splits | JSON arrays/objects | Delimited strings |
| Delimiter needed? | No (uses array structure) | Yes (e.g. ',') |
| Access element via | f.value | s.value |
| Index column | f.index (0-based) | s.index (1-based) |
| Can go multi-level? | Yes (chain FLATTENs) | No (single level) |
| Handles nested JSON? | Yes | No |
| Use case | JSON/ARRAY/VARIANT data | CSV-like string data |
| OUTER support? | Yes (OUTER => TRUE) | No |

**RULE OF THUMB:**
- Data stored as VARIANT/ARRAY → use LATERAL FLATTEN
- Data stored as comma-separated VARCHAR → use LATERAL SPLIT_TO_TABLE

---

## SECTION 10: SUMMARY — LATERAL SYNTAX PATTERNS

**PATTERN 1: LATERAL with subquery**
```sql
SELECT ... FROM table1 t, LATERAL (SELECT ... WHERE ... = t.col) sub;
```

**PATTERN 2: LATERAL FLATTEN (JSON/Array)**
```sql
SELECT ... FROM table1 t, LATERAL FLATTEN(INPUT => t.array_col) f;
```

**PATTERN 3: LATERAL FLATTEN with nested access**
```sql
SELECT ... FROM table1 t,
    LATERAL FLATTEN(INPUT => t.col) f1,
    LATERAL FLATTEN(INPUT => f1.value:nested_array) f2;
```

**PATTERN 4: LATERAL SPLIT_TO_TABLE (String splitting)**
```sql
SELECT ... FROM table1 t, LATERAL SPLIT_TO_TABLE(t.string_col, ',') s;
```

**PATTERN 5: LATERAL with OUTER (keep rows with empty arrays)**
```sql
SELECT ... FROM table1 t, LATERAL FLATTEN(INPUT => t.col, OUTER => TRUE) f;
```
