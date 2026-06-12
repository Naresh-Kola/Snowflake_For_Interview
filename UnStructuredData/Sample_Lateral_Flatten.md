# Table to JSON Conversion & LATERAL FLATTEN in Snowflake

## Overview

This guide covers two key topics:
1. Converting relational table data into JSON format
2. Using `LATERAL FLATTEN` to parse JSON arrays back into rows

---

## Part 1: Table Setup

```sql
CREATE OR REPLACE TABLE employees_data (
    emp_id INT,
    emp_name VARCHAR(100),
    department VARCHAR(50),
    designation VARCHAR(50),
    salary NUMBER(10,2),
    joining_date DATE
);

INSERT INTO employees_data VALUES
    (1, 'Rahul Sharma', 'Engineering', 'Senior Developer', 95000.00, '2020-03-15'),
    (2, 'Priya Patel', 'Engineering', 'Tech Lead', 120000.00, '2018-07-01'),
    (3, 'Amit Kumar', 'Sales', 'Sales Manager', 85000.00, '2019-11-20'),
    (4, 'Sneha Reddy', 'HR', 'HR Manager', 78000.00, '2021-01-10'),
    (5, 'Vikram Singh', 'Engineering', 'Junior Developer', 60000.00, '2023-06-05'),
    (6, 'Kavita Nair', 'Finance', 'Analyst', 72000.00, '2022-04-18'),
    (7, 'Rajesh Gupta', 'Sales', 'Account Executive', 68000.00, '2021-09-12'),
    (8, 'Deepa Iyer', 'HR', 'Recruiter', 55000.00, '2023-02-28');
```

---

## Part 2: Converting Table Data to JSON

### Method 1: OBJECT_CONSTRUCT (Row → JSON Object)

Converts each row into a separate JSON object.

```sql
SELECT OBJECT_CONSTRUCT(
    'emp_id', emp_id,
    'emp_name', emp_name,
    'department', department,
    'designation', designation,
    'salary', salary,
    'joining_date', joining_date
) AS employee_json
FROM employees_data;
```

**Output (per row):**
```json
{"emp_id": 1, "emp_name": "Rahul Sharma", "department": "Engineering", "salary": 95000}
```

---

### Method 2: ARRAY_AGG (All Rows → Single JSON Array)

Wraps all rows into one JSON array.

```sql
SELECT ARRAY_AGG(
    OBJECT_CONSTRUCT(
        'emp_id', emp_id,
        'emp_name', emp_name,
        'department', department,
        'designation', designation,
        'salary', salary,
        'joining_date', joining_date
    )
) AS all_employees_json
FROM employees_data;
```

**Output:** A single cell containing `[{...}, {...}, {...}, ...]`

---

### Method 3: Nested JSON (Group by Department)

Creates nested JSON with employees grouped under their department.

```sql
SELECT OBJECT_CONSTRUCT(
    'department', department,
    'employee_count', COUNT(*),
    'employees', ARRAY_AGG(
        OBJECT_CONSTRUCT(
            'emp_id', emp_id,
            'emp_name', emp_name,
            'designation', designation,
            'salary', salary
        )
    )
) AS department_json
FROM employees_data
GROUP BY department;
```

**Output:**
```json
{
  "department": "Engineering",
  "employee_count": 3,
  "employees": [
    {"emp_id": 1, "emp_name": "Rahul Sharma", ...},
    {"emp_id": 2, "emp_name": "Priya Patel", ...}
  ]
}
```

---

### Method 4: Export to a .json File on Stage

Creates an actual JSON file on a Snowflake stage that can be downloaded.

```sql
CREATE OR REPLACE STAGE json_export_stage
    FILE_FORMAT = (TYPE = 'JSON');

COPY INTO @json_export_stage/employees.json
FROM (
    SELECT OBJECT_CONSTRUCT(
        'emp_id', emp_id,
        'emp_name', emp_name,
        'department', department,
        'designation', designation,
        'salary', salary,
        'joining_date', joining_date
    ) AS json_data
    FROM employees_data
)
FILE_FORMAT = (TYPE = 'JSON')
OVERWRITE = TRUE;

-- Verify file exists
LIST @json_export_stage;

-- Read it back
SELECT $1 FROM @json_export_stage/employees.json;
```

---

### Method 5: OBJECT_CONSTRUCT_KEEP_NULL

Automatically includes all columns without naming them. NULLs are preserved in the output.

```sql
SELECT OBJECT_CONSTRUCT_KEEP_NULL(*) AS full_row_json
FROM employees_data;
```

> **Note:** Regular `OBJECT_CONSTRUCT` silently drops keys with NULL values. Use `OBJECT_CONSTRUCT_KEEP_NULL` when you need NULLs to appear explicitly.

---

## Part 3: Inserting JSON Data with PARSE_JSON

To insert raw JSON into a VARIANT column, wrap it in `PARSE_JSON()`:

```sql
CREATE OR REPLACE TABLE table_1 (
    object_ VARIANT
);

INSERT INTO table_1
SELECT PARSE_JSON('{
  "department": "Engineering",
  "employee_count": 3,
  "employees": [
    {"designation": "Senior Developer", "emp_id": 1, "emp_name": "Rahul Sharma", "salary": 95000},
    {"designation": "Tech Lead", "emp_id": 2, "emp_name": "Priya Patel", "salary": 120000},
    {"designation": "Junior Developer", "emp_id": 5, "emp_name": "Vikram Singh", "salary": 60000}
  ]
}');
```

> **Common mistake:** `INSERT INTO table_1 VALUES ({...})` — bare JSON without `PARSE_JSON()` will throw a syntax error.

---

## Part 4: LATERAL FLATTEN — Parsing JSON Arrays into Rows

### What is FLATTEN?

`FLATTEN` takes a JSON array (or object) stored in a VARIANT column and **expands it into multiple rows** — one row per element.

### Syntax

```sql
SELECT <columns>
FROM <table>,
LATERAL FLATTEN(input => <variant_column>:<array_path>) <alias>;
```

| Component | Description |
|-----------|-------------|
| `LATERAL` | Allows FLATTEN to reference columns from the table in the FROM clause |
| `FLATTEN(input => ...)` | The function that explodes the array |
| `input` | The VARIANT expression pointing to the array |
| `<alias>` | The alias (e.g., `f`) used to access each element |

### Output Columns from FLATTEN

| Column | Description |
|--------|-------------|
| `f.value` | The current array element (as VARIANT) |
| `f.index` | The 0-based position in the array |
| `f.key` | The key name (when flattening objects, NULL for arrays) |
| `f.path` | The path to the element |
| `f.this` | The original array/object being flattened |
| `f.seq` | A unique sequence number for each input row |

### Example: Flatten the Employees Array

```sql
SELECT
    object_:department::VARCHAR AS department,
    f.value:emp_id::INT AS emp_id,
    f.value:emp_name::VARCHAR AS emp_name,
    f.value:designation::VARCHAR AS designation,
    f.value:salary::NUMBER AS salary
FROM table_1,
LATERAL FLATTEN(input => object_:employees) f;
```

**How it works:**

1. `object_:employees` — navigates to the `employees` array in the JSON
2. `FLATTEN` — expands 3 array elements into 3 rows
3. `f.value` — represents each element (one employee object)
4. `f.value:emp_name::VARCHAR` — extracts a field from that element and casts it

**Result:**

| department | emp_id | emp_name | designation | salary |
|---|---|---|---|---|
| Engineering | 1 | Rahul Sharma | Senior Developer | 95000 |
| Engineering | 2 | Priya Patel | Tech Lead | 120000 |
| Engineering | 5 | Vikram Singh | Junior Developer | 60000 |

---

### FLATTEN Parameters

```sql
LATERAL FLATTEN(
    input => <expression>,    -- Required: the array/object to flatten
    path => '<path>',         -- Optional: path within input to flatten
    outer => TRUE/FALSE,      -- Optional: if TRUE, keeps rows even when array is empty/NULL
    recursive => TRUE/FALSE,  -- Optional: if TRUE, flattens nested arrays recursively
    mode => 'ARRAY'|'OBJECT'|'BOTH'  -- Optional: what to flatten (default: BOTH)
)
```

### Common FLATTEN Patterns

**Flatten with OUTER (keep rows with empty arrays):**
```sql
SELECT *
FROM table_1,
LATERAL FLATTEN(input => object_:employees, outer => TRUE) f;
```

**Flatten recursively (nested arrays):**
```sql
SELECT f.key, f.value, f.path
FROM table_1,
LATERAL FLATTEN(input => object_, recursive => TRUE) f;
```

**Flatten an object's keys (not an array):**
```sql
SELECT f.key, f.value
FROM table_1,
LATERAL FLATTEN(input => object_, mode => 'OBJECT') f;
```

---

## Quick Reference: JSON Navigation Syntax

| Syntax | Meaning |
|--------|---------|
| `col:key` | Access a top-level key |
| `col:key1.key2` | Access nested keys (dot notation) |
| `col:array[0]` | Access array element by index |
| `col:key::VARCHAR` | Cast the extracted value to a type |
| `col['key with spaces']` | Access keys with special characters |

---

## Summary

| Task | Function |
|------|----------|
| Row → JSON object | `OBJECT_CONSTRUCT('key', value, ...)` |
| All rows → JSON array | `ARRAY_AGG(OBJECT_CONSTRUCT(...))` |
| String → VARIANT | `PARSE_JSON('{"key": "value"}')` |
| JSON array → rows | `LATERAL FLATTEN(input => col:array)` |
| Keep NULLs in JSON | `OBJECT_CONSTRUCT_KEEP_NULL(*)` |
| Export to file | `COPY INTO @stage FROM (SELECT ...) FILE_FORMAT = (TYPE='JSON')` |
