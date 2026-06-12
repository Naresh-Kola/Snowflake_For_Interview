-- ============================================================
-- USER DEFINED FUNCTIONS (UDFs) IN SNOWFLAKE
-- Complete Guide with 10+ Examples & Usage in Procedures
-- ============================================================

-- ============================================================
-- WHAT IS A UDF?
-- ============================================================
-- A UDF is a reusable function you create to encapsulate logic.
-- Unlike procedures, UDFs:
--   - Return a value (scalar or tabular)
--   - Can be used inside SELECT, WHERE, JOIN, etc.
--   - Cannot perform DML (INSERT/UPDATE/DELETE)
--   - Are deterministic or non-deterministic
--
-- Types of UDFs in Snowflake:
--   1. SQL UDF (LANGUAGE SQL)
--   2. JavaScript UDF (LANGUAGE JAVASCRIPT)
--   3. Python UDF (LANGUAGE PYTHON)
--   4. Java UDF (LANGUAGE JAVA)
--   5. Scalar UDF (returns single value)
--   6. Table UDF / UDTF (returns rows)
-- ============================================================

-- ============================================================
-- EXAMPLE 1: Basic Scalar UDF - Calculate Annual Bonus
-- ============================================================
CREATE OR REPLACE FUNCTION calc_bonus(salary NUMBER, rating INT)
RETURNS NUMBER(10,2)
LANGUAGE SQL
AS
$$
    CASE
        WHEN rating = 5 THEN salary * 0.20
        WHEN rating = 4 THEN salary * 0.15
        WHEN rating = 3 THEN salary * 0.10
        WHEN rating = 2 THEN salary * 0.05
        ELSE 0
    END
$$;

-- Usage:
SELECT calc_bonus(100000, 5);  -- Returns 20000.00
SELECT calc_bonus(80000, 3);   -- Returns 8000.00

-- ============================================================
-- EXAMPLE 2: String Formatting UDF - Mask Email
-- ============================================================
CREATE OR REPLACE FUNCTION mask_email(email VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    CONCAT(
        LEFT(email, 2),
        '****',
        SUBSTR(email, POSITION('@' IN email))
    )
$$;

-- Usage:
SELECT mask_email('rahul.sharma@gmail.com');  -- Returns 'ra****@gmail.com'
SELECT mask_email('priya@company.com');       -- Returns 'pr****@company.com'

-- ============================================================
-- EXAMPLE 3: Date UDF - Calculate Age from Date of Birth
-- ============================================================
CREATE OR REPLACE FUNCTION calc_age(dob DATE)
RETURNS INT
LANGUAGE SQL
AS
$$
    DATEDIFF('YEAR', dob, CURRENT_DATE())
$$;

-- Usage:
SELECT calc_age('1990-05-15');  -- Returns age in years
SELECT calc_age('2000-12-01');

-- ============================================================
-- EXAMPLE 4: Conditional UDF - Salary Grade Classification
-- ============================================================
CREATE OR REPLACE FUNCTION get_salary_grade(salary NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
AS
$$
    CASE
        WHEN salary >= 150000 THEN 'Executive'
        WHEN salary >= 100000 THEN 'Senior'
        WHEN salary >= 70000 THEN 'Mid-Level'
        WHEN salary >= 40000 THEN 'Junior'
        ELSE 'Entry Level'
    END
$$;

-- Usage:
SELECT get_salary_grade(120000);  -- Returns 'Senior'
SELECT get_salary_grade(55000);   -- Returns 'Junior'

-- ============================================================
-- EXAMPLE 5: Math UDF - Calculate Compound Interest
-- ============================================================
CREATE OR REPLACE FUNCTION compound_interest(
    principal NUMBER,
    rate NUMBER,
    years INT,
    times_per_year INT
)
RETURNS NUMBER(15,2)
LANGUAGE SQL
AS
$$
    principal * POWER((1 + rate / (100 * times_per_year)), times_per_year * years)
$$;

-- Usage:
SELECT compound_interest(100000, 8.5, 5, 4);  -- Rs 1,00,000 at 8.5% for 5 years, compounded quarterly

-- ============================================================
-- EXAMPLE 6: JavaScript UDF - Title Case Conversion
-- ============================================================
CREATE OR REPLACE FUNCTION to_title_case(input_str VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
AS
$$
    if (!INPUT_STR) return null;
    return INPUT_STR.toLowerCase().replace(/\b\w/g, function(char) {
        return char.toUpperCase();
    });
$$;

-- Usage:
SELECT to_title_case('hello world from snowflake');  -- Returns 'Hello World From Snowflake'
SELECT to_title_case('RAHUL SHARMA');                -- Returns 'Rahul Sharma'

-- ============================================================
-- EXAMPLE 7: Python UDF - Validate Phone Number Format
-- ============================================================
CREATE OR REPLACE FUNCTION validate_phone(phone VARCHAR)
RETURNS BOOLEAN
LANGUAGE PYTHON
RUNTIME_VERSION = '3.8'
HANDLER = 'check_phone'
AS
$$
import re
def check_phone(phone):
    if phone is None:
        return False
    pattern = r'^\+?[1-9]\d{9,14}$'
    return bool(re.match(pattern, phone))
$$;

-- Usage:
SELECT validate_phone('+919876543210');  -- Returns TRUE
SELECT validate_phone('12345');          -- Returns FALSE
SELECT validate_phone('+14155551234');   -- Returns TRUE

-- ============================================================
-- EXAMPLE 8: UDF with Multiple Parameters - Tax Calculator
-- ============================================================
CREATE OR REPLACE FUNCTION calc_income_tax(annual_income NUMBER, regime VARCHAR)
RETURNS NUMBER(12,2)
LANGUAGE SQL
AS
$$
    CASE
        WHEN regime = 'OLD' THEN
            CASE
                WHEN annual_income <= 250000 THEN 0
                WHEN annual_income <= 500000 THEN (annual_income - 250000) * 0.05
                WHEN annual_income <= 1000000 THEN 12500 + (annual_income - 500000) * 0.20
                ELSE 12500 + 100000 + (annual_income - 1000000) * 0.30
            END
        WHEN regime = 'NEW' THEN
            CASE
                WHEN annual_income <= 300000 THEN 0
                WHEN annual_income <= 600000 THEN (annual_income - 300000) * 0.05
                WHEN annual_income <= 900000 THEN 15000 + (annual_income - 600000) * 0.10
                WHEN annual_income <= 1200000 THEN 15000 + 30000 + (annual_income - 900000) * 0.15
                ELSE 15000 + 30000 + 45000 + (annual_income - 1200000) * 0.20
            END
        ELSE 0
    END
$$;

-- Usage:
SELECT calc_income_tax(800000, 'OLD');   -- Old regime tax
SELECT calc_income_tax(800000, 'NEW');   -- New regime tax
SELECT calc_income_tax(1500000, 'OLD');  -- High income old regime

-- ============================================================
-- EXAMPLE 9: Table UDF (UDTF) - Generate Date Series
-- ============================================================
CREATE OR REPLACE FUNCTION generate_date_range(start_date DATE, end_date DATE)
RETURNS TABLE(generated_date DATE)
LANGUAGE SQL
AS
$$
    SELECT generated_date
    FROM (
        SELECT DATEADD('DAY', ROW_NUMBER() OVER(ORDER BY 1) - 1, start_date) AS generated_date
        FROM TABLE(GENERATOR(ROWCOUNT => 10000))
    )
    WHERE generated_date <= end_date
$$;

-- Usage: Returns one row per date between the two dates
SELECT * FROM TABLE(generate_date_range('2024-01-01'::DATE, '2024-01-10'::DATE));

-- ============================================================
-- EXAMPLE 10: JavaScript UDF - Parse and Validate JSON Field
-- ============================================================
CREATE OR REPLACE FUNCTION extract_domain(email VARCHAR)
RETURNS VARCHAR
LANGUAGE JAVASCRIPT
AS
$$
    if (!EMAIL) return null;
    var parts = EMAIL.split('@');
    return parts.length === 2 ? parts[1] : null;
$$;

-- Usage:
SELECT extract_domain('user@snowflake.com');   -- Returns 'snowflake.com'
SELECT extract_domain('admin@company.co.in');  -- Returns 'company.co.in'

-- ============================================================
-- EXAMPLE 11: Secure UDF - Prevents Caller from Viewing Definition
-- ============================================================
CREATE OR REPLACE SECURE FUNCTION calculate_discount(amount NUMBER, customer_type VARCHAR)
RETURNS NUMBER(10,2)
LANGUAGE SQL
AS
$$
    CASE customer_type
        WHEN 'PLATINUM' THEN amount * 0.25
        WHEN 'GOLD' THEN amount * 0.15
        WHEN 'SILVER' THEN amount * 0.10
        ELSE amount * 0.05
    END
$$;

-- Usage (definition hidden from non-owners):
SELECT calculate_discount(5000, 'GOLD');  -- Returns 750.00

-- ============================================================
-- EXAMPLE 12: Memoizable UDF - Snowflake Caches Results
-- ============================================================
CREATE OR REPLACE FUNCTION format_currency(amount NUMBER, currency VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
MEMOIZABLE
AS
$$
    CASE currency
        WHEN 'INR' THEN '₹' || TO_VARCHAR(amount, '999,999,999.00')
        WHEN 'USD' THEN '$' || TO_VARCHAR(amount, '999,999,999.00')
        WHEN 'EUR' THEN '€' || TO_VARCHAR(amount, '999,999,999.00')
        ELSE TO_VARCHAR(amount, '999,999,999.00') || ' ' || currency
    END
$$;

-- Usage:
SELECT format_currency(95000, 'INR');  -- Returns '₹95,000.00'
SELECT format_currency(1200, 'USD');   -- Returns '$1,200.00'

-- ============================================================
-- USING UDFs INSIDE STORED PROCEDURES
-- ============================================================

-- Setup: Create a table for demonstration
CREATE OR REPLACE TABLE emp_payroll (
    emp_id INT,
    emp_name VARCHAR(100),
    email VARCHAR(200),
    phone VARCHAR(20),
    department VARCHAR(50),
    base_salary NUMBER(10,2),
    performance_rating INT,
    date_of_birth DATE,
    customer_type VARCHAR(20)
);

INSERT INTO emp_payroll VALUES
    (1, 'rahul sharma', 'rahul@gmail.com', '+919876543210', 'Engineering', 95000, 5, '1990-03-15', 'GOLD'),
    (2, 'priya patel', 'priya@company.com', '+918765432109', 'Sales', 120000, 4, '1988-07-22', 'PLATINUM'),
    (3, 'amit kumar', 'amit@email.com', '12345', 'HR', 65000, 3, '1995-11-08', 'SILVER'),
    (4, 'sneha reddy', 'sneha@org.com', '+917654321098', 'Finance', 150000, 5, '1985-01-30', 'PLATINUM'),
    (5, 'vikram singh', 'vikram@test.com', '+916543210987', 'Engineering', 55000, 2, '1998-06-12', 'SILVER');

-- ============================================================
-- PROCEDURE 1: Process Payroll Using Multiple UDFs
-- ============================================================
CREATE OR REPLACE PROCEDURE process_employee_report()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_count INT DEFAULT 0;
BEGIN
    -- Create a report table using UDFs for transformations
    CREATE OR REPLACE TABLE employee_report AS
    SELECT
        emp_id,
        to_title_case(emp_name) AS formatted_name,
        mask_email(email) AS masked_email,
        validate_phone(phone) AS is_phone_valid,
        department,
        base_salary,
        get_salary_grade(base_salary) AS salary_grade,
        calc_bonus(base_salary, performance_rating) AS bonus_amount,
        base_salary + calc_bonus(base_salary, performance_rating) AS total_compensation,
        calc_age(date_of_birth) AS age,
        format_currency(base_salary, 'INR') AS formatted_salary,
        calculate_discount(base_salary, customer_type) AS loyalty_discount,
        calc_income_tax(base_salary * 12, 'NEW') AS annual_tax_new_regime
    FROM emp_payroll;

    SELECT COUNT(*) INTO :v_count FROM employee_report;

    RETURN 'Report generated successfully. Rows processed: ' || v_count;
END;

-- Execute the procedure
CALL process_employee_report();

-- View the report (all transformations done by UDFs)
SELECT * FROM employee_report;

-- ============================================================
-- PROCEDURE 2: Validate Data Using UDFs Before Insert
-- ============================================================
CREATE OR REPLACE PROCEDURE validate_and_insert(
    p_name VARCHAR,
    p_email VARCHAR,
    p_phone VARCHAR,
    p_salary NUMBER,
    p_dob DATE
)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_errors VARCHAR DEFAULT '';
BEGIN
    -- Use UDFs for validation
    IF (NOT validate_phone(p_phone)) THEN
        v_errors := v_errors || 'Invalid phone number. ';
    END IF;

    IF (calc_age(p_dob) < 18) THEN
        v_errors := v_errors || 'Employee must be at least 18 years old. ';
    END IF;

    IF (get_salary_grade(p_salary) = 'Entry Level' AND p_salary < 25000) THEN
        v_errors := v_errors || 'Salary below minimum wage. ';
    END IF;

    -- If validation passes, insert
    IF (v_errors = '') THEN
        INSERT INTO emp_payroll (emp_id, emp_name, email, phone, department, base_salary, performance_rating, date_of_birth, customer_type)
        VALUES (
            (SELECT COALESCE(MAX(emp_id), 0) + 1 FROM emp_payroll),
            :p_name, :p_email, :p_phone, 'General', :p_salary, 3, :p_dob, 'SILVER'
        );
        RETURN 'Employee inserted successfully. Salary Grade: ' || get_salary_grade(p_salary);
    ELSE
        RETURN 'Validation failed: ' || v_errors;
    END IF;
END;

-- Test: Valid employee
CALL validate_and_insert('Kavita Nair', 'kavita@email.com', '+919988776655', 72000, '1992-04-18');

-- Test: Invalid phone
CALL validate_and_insert('Test User', 'test@email.com', '123', 50000, '1995-01-01');

-- Test: Underage
CALL validate_and_insert('Young User', 'young@email.com', '+919988776655', 30000, '2010-06-15');

-- ============================================================
-- PROCEDURE 3: Batch Processing with UDFs and Cursor
-- ============================================================
CREATE OR REPLACE PROCEDURE generate_salary_report()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_total_bonus NUMBER(12,2) DEFAULT 0;
    v_total_tax NUMBER(12,2) DEFAULT 0;
    v_emp_count INT DEFAULT 0;
    emp_cur CURSOR FOR
        SELECT emp_name, base_salary, performance_rating FROM emp_payroll;
BEGIN
    CREATE OR REPLACE TABLE salary_summary (
        emp_name VARCHAR,
        salary_grade VARCHAR,
        bonus NUMBER(10,2),
        formatted_total VARCHAR,
        annual_tax NUMBER(12,2)
    );

    OPEN emp_cur;
    FOR rec IN emp_cur DO
        LET v_bonus NUMBER(10,2) := calc_bonus(rec.base_salary, rec.performance_rating);
        LET v_tax NUMBER(12,2) := calc_income_tax(rec.base_salary * 12, 'NEW');

        INSERT INTO salary_summary VALUES (
            to_title_case(rec.emp_name),
            get_salary_grade(rec.base_salary),
            :v_bonus,
            format_currency(rec.base_salary + :v_bonus, 'INR'),
            :v_tax
        );

        v_total_bonus := v_total_bonus + :v_bonus;
        v_total_tax := v_total_tax + :v_tax;
        v_emp_count := v_emp_count + 1;
    END FOR;
    CLOSE emp_cur;

    RETURN 'Processed ' || v_emp_count || ' employees. Total Bonus: ' ||
           format_currency(v_total_bonus, 'INR') || ', Total Tax: ' ||
           format_currency(v_total_tax, 'INR');
END;

-- Execute
CALL generate_salary_report();

-- View results
SELECT * FROM salary_summary;

-- ============================================================
-- USING UDFs IN SELECT, WHERE, JOIN, GROUP BY
-- ============================================================

-- In SELECT: Transform output
SELECT emp_name, get_salary_grade(base_salary) AS grade FROM emp_payroll;

-- In WHERE: Filter using UDF
SELECT * FROM emp_payroll WHERE get_salary_grade(base_salary) = 'Senior';

-- In GROUP BY: Aggregate by UDF result
SELECT
    get_salary_grade(base_salary) AS grade,
    COUNT(*) AS emp_count,
    AVG(base_salary) AS avg_salary
FROM emp_payroll
GROUP BY get_salary_grade(base_salary)
ORDER BY avg_salary DESC;

-- In ORDER BY: Sort using UDF
SELECT emp_name, base_salary, calc_bonus(base_salary, performance_rating) AS bonus
FROM emp_payroll
ORDER BY calc_bonus(base_salary, performance_rating) DESC;

-- In HAVING: Filter groups using UDF
SELECT
    department,
    SUM(calc_bonus(base_salary, performance_rating)) AS total_dept_bonus
FROM emp_payroll
GROUP BY department
HAVING SUM(calc_bonus(base_salary, performance_rating)) > 10000;

-- ============================================================
-- USEFUL COMMANDS FOR MANAGING UDFs
-- ============================================================

-- List all UDFs in current schema
SHOW USER FUNCTIONS;

-- Describe a specific UDF
DESCRIBE FUNCTION calc_bonus(NUMBER, INT);

-- Drop a UDF
-- DROP FUNCTION calc_bonus(NUMBER, INT);

-- View UDF definition
SELECT GET_DDL('FUNCTION', 'calc_bonus(NUMBER, INT)');
