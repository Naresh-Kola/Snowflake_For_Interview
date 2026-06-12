-- ============================================================
-- EXCEPTION HANDLING IN SNOWFLAKE STORED PROCEDURES
-- Complete Guide with All Types and Examples
-- ============================================================

-- ============================================================
-- WHY EXCEPTION HANDLING?
-- ============================================================
-- Without exception handling, a procedure stops immediately on error.
-- With exception handling, you can:
--   - Catch and handle errors gracefully
--   - Log errors for debugging
--   - Return meaningful error messages to callers
--   - Clean up resources (temp tables, etc.)
--   - Continue processing remaining records
--   - Retry failed operations
-- ============================================================

-- ============================================================
-- BASIC SYNTAX OF EXCEPTION HANDLING
-- ============================================================
/*
BEGIN
    -- statements that might fail
EXCEPTION
    WHEN <exception_name> THEN
        -- handle the error
    WHEN OTHER THEN
        -- catch-all for any unhandled exception
END;
*/

-- ============================================================
-- TYPES OF EXCEPTIONS IN SNOWFLAKE
-- ============================================================
-- 1. Built-in Exceptions (predefined by Snowflake)
--    - STATEMENT_ERROR         : SQL statement execution error
--    - EXPRESSION_ERROR        : Expression evaluation error
--    - OTHER                   : Catch-all for any exception
--
-- 2. User-Defined Exceptions (DECLARE your own)
--    - You name them and RAISE them manually
--
-- 3. Conditional RAISE (raise with custom message/code)
-- ============================================================


-- ============================================================
-- EXAMPLE 1: Basic EXCEPTION with WHEN OTHER (Catch-All)
-- ============================================================
CREATE OR REPLACE PROCEDURE basic_exception_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    -- This will fail: dividing by zero
    LET result NUMBER := 10 / 0;
    RETURN 'Result: ' || :result;
EXCEPTION
    WHEN OTHER THEN
        RETURN 'An error occurred: ' || SQLERRM;
END;

CALL basic_exception_demo();
-- Returns: 'An error occurred: Division by zero'


-- ============================================================
-- EXAMPLE 2: STATEMENT_ERROR - Catching SQL Execution Errors
-- ============================================================
CREATE OR REPLACE PROCEDURE statement_error_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    -- This will fail: table doesn't exist
    SELECT * FROM non_existent_table_xyz;
    RETURN 'Query succeeded';
EXCEPTION
    WHEN STATEMENT_ERROR THEN
        RETURN 'SQL Error Code: ' || SQLCODE || ' | Message: ' || SQLERRM;
    WHEN OTHER THEN
        RETURN 'Unknown error: ' || SQLERRM;
END;

CALL statement_error_demo();
-- Returns: 'SQL Error Code: 2003 | Message: SQL compilation error: ...'


-- ============================================================
-- EXAMPLE 3: EXPRESSION_ERROR - Catching Expression Failures
-- ============================================================
CREATE OR REPLACE PROCEDURE expression_error_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    -- This will fail: invalid type conversion
    LET val NUMBER := 'not_a_number'::NUMBER;
    RETURN 'Value: ' || :val;
EXCEPTION
    WHEN EXPRESSION_ERROR THEN
        RETURN 'Expression Error: ' || SQLERRM;
    WHEN OTHER THEN
        RETURN 'Other Error: ' || SQLERRM;
END;

CALL expression_error_demo();
-- Returns: 'Expression Error: Numeric value 'not_a_number' is not recognized'


-- ============================================================
-- EXAMPLE 4: User-Defined Exception (DECLARE and RAISE)
-- ============================================================
CREATE OR REPLACE PROCEDURE user_defined_exception_demo(p_age INT)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    e_underage EXCEPTION (-20001, 'Employee must be at least 18 years old');
    e_overage EXCEPTION (-20002, 'Employee cannot be older than 65 years');
BEGIN
    IF (:p_age < 18) THEN
        RAISE e_underage;
    ELSEIF (:p_age > 65) THEN
        RAISE e_overage;
    END IF;

    RETURN 'Age ' || :p_age || ' is valid. Employee can be registered.';
EXCEPTION
    WHEN e_underage THEN
        RETURN 'Validation Failed [' || SQLCODE || ']: ' || SQLERRM;
    WHEN e_overage THEN
        RETURN 'Validation Failed [' || SQLCODE || ']: ' || SQLERRM;
    WHEN OTHER THEN
        RETURN 'Unexpected error: ' || SQLERRM;
END;

-- Test cases:
CALL user_defined_exception_demo(25);  -- Valid
CALL user_defined_exception_demo(15);  -- Underage error
CALL user_defined_exception_demo(70);  -- Overage error


-- ============================================================
-- EXAMPLE 5: RAISE with User-Defined Exceptions (Multiple)
-- ============================================================
CREATE OR REPLACE PROCEDURE raise_inline_demo(p_salary NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    e_negative_salary EXCEPTION (-20003, 'Salary cannot be negative');
    e_exceeds_limit EXCEPTION (-20004, 'Salary exceeds maximum allowed limit');
BEGIN
    IF (:p_salary < 0) THEN
        RAISE e_negative_salary;
    END IF;

    IF (:p_salary > 10000000) THEN
        RAISE e_exceeds_limit;
    END IF;

    RETURN 'Salary ' || :p_salary || ' is within valid range.';
EXCEPTION
    WHEN e_negative_salary THEN
        RETURN 'Validation Error [' || SQLCODE || ']: ' || SQLERRM;
    WHEN e_exceeds_limit THEN
        RETURN 'Limit Error [' || SQLCODE || ']: ' || SQLERRM;
    WHEN OTHER THEN
        RETURN 'Error: ' || SQLERRM;
END;

CALL raise_inline_demo(50000);      -- Valid
CALL raise_inline_demo(-1000);      -- Negative salary error
CALL raise_inline_demo(99999999);   -- Exceeds limit error


-- ============================================================
-- EXAMPLE 6: Multiple WHEN Clauses (Prioritized Handling)
-- ============================================================
CREATE OR REPLACE PROCEDURE multiple_when_demo(p_action VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    e_invalid_action EXCEPTION (-20010, 'Invalid action specified');
BEGIN
    IF (:p_action = 'DIVIDE') THEN
        LET x NUMBER := 1 / 0;
    ELSEIF (:p_action = 'QUERY') THEN
        SELECT * FROM table_that_does_not_exist;
    ELSEIF (:p_action = 'CAST') THEN
        LET y NUMBER := 'abc'::NUMBER;
    ELSE
        RAISE e_invalid_action;
    END IF;

    RETURN 'Action completed successfully';
EXCEPTION
    WHEN e_invalid_action THEN
        RETURN 'Custom Error: ' || SQLERRM;
    WHEN EXPRESSION_ERROR THEN
        RETURN 'Expression Error: ' || SQLERRM;
    WHEN STATEMENT_ERROR THEN
        RETURN 'Statement Error: ' || SQLERRM;
    WHEN OTHER THEN
        RETURN 'Catch-All Error: ' || SQLERRM;
END;

CALL multiple_when_demo('DIVIDE');   -- Expression Error
CALL multiple_when_demo('QUERY');    -- Statement Error
CALL multiple_when_demo('CAST');     -- Expression Error
CALL multiple_when_demo('UNKNOWN');  -- Custom Error


-- ============================================================
-- EXAMPLE 7: Nested BEGIN...EXCEPTION Blocks
-- ============================================================
-- You can nest exception handlers for fine-grained control
CREATE OR REPLACE PROCEDURE nested_exception_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_result VARCHAR DEFAULT '';
BEGIN
    -- Outer block
    BEGIN
        -- Inner block 1: This will fail but is handled locally
        LET x NUMBER := 10 / 0;
        v_result := 'Division succeeded';
    EXCEPTION
        WHEN OTHER THEN
            v_result := 'Inner block 1 caught: ' || SQLERRM;
    END;

    -- Execution continues here because inner block handled the error
    BEGIN
        -- Inner block 2: This will also fail
        SELECT * FROM fake_table_12345;
    EXCEPTION
        WHEN STATEMENT_ERROR THEN
            v_result := :v_result || ' | Inner block 2 caught: ' || SQLERRM;
    END;

    RETURN :v_result;
EXCEPTION
    WHEN OTHER THEN
        RETURN 'Outer block caught: ' || SQLERRM;
END;

CALL nested_exception_demo();
-- Both errors are handled independently; execution continues through both blocks


-- ============================================================
-- EXAMPLE 8: Re-Raising an Exception (RAISE without arguments)
-- ============================================================
-- Catch an exception, do something (like logging), then re-raise it
CREATE OR REPLACE PROCEDURE reraise_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    BEGIN
        LET x NUMBER := 1 / 0;
    EXCEPTION
        WHEN OTHER THEN
            -- Log the error (insert into an error log table, etc.)
            INSERT INTO error_log (error_time, error_msg)
                VALUES (CURRENT_TIMESTAMP(), SQLERRM);
            -- Re-raise to the outer block
            RAISE;
    END;

    RETURN 'This will not be reached';
EXCEPTION
    WHEN OTHER THEN
        RETURN 'Outer handler caught re-raised error: ' || SQLERRM;
END;


-- ============================================================
-- EXAMPLE 9: Error Logging Pattern
-- ============================================================
-- Create an error log table
CREATE OR REPLACE TABLE error_log (
    log_id INT AUTOINCREMENT,
    procedure_name VARCHAR(100),
    error_code INT,
    error_message VARCHAR(1000),
    error_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE error_logging_demo(p_divisor NUMBER)
RETURNS VARCHAR
LANGUAGE SQL
AS
BEGIN
    LET result NUMBER := 100 / :p_divisor;
    RETURN 'Result: ' || :result;
EXCEPTION
    WHEN OTHER THEN
        INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('error_logging_demo', SQLCODE, SQLERRM);
        RETURN 'Error logged. Code: ' || SQLCODE || ' Message: ' || SQLERRM;
END;

CALL error_logging_demo(5);   -- Returns 'Result: 20'
CALL error_logging_demo(0);   -- Logs error and returns message

-- View logged errors
SELECT * FROM error_log ORDER BY error_time DESC;


-- ============================================================
-- EXAMPLE 10: Transaction Control with Exception Handling
-- ============================================================
-- Rollback on failure, commit on success
CREATE OR REPLACE TABLE accounts (
    account_id INT,
    account_name VARCHAR(50),
    balance NUMBER(12,2)
);

INSERT INTO accounts VALUES (1, 'Savings', 50000), (2, 'Current', 100000);

CREATE OR REPLACE PROCEDURE transfer_funds(
    p_from_account INT,
    p_to_account INT,
    p_amount NUMBER
)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_balance NUMBER(12,2);
    e_insufficient_funds EXCEPTION (-20100, 'Insufficient funds for transfer');
BEGIN
    BEGIN TRANSACTION;

    -- Check balance
    SELECT balance INTO :v_balance FROM accounts WHERE account_id = :p_from_account;

    IF (:v_balance < :p_amount) THEN
        RAISE e_insufficient_funds;
    END IF;

    -- Debit source account
    UPDATE accounts SET balance = balance - :p_amount WHERE account_id = :p_from_account;

    -- Credit destination account
    UPDATE accounts SET balance = balance + :p_amount WHERE account_id = :p_to_account;

    COMMIT;
    RETURN 'Transfer successful. Amount: ' || :p_amount;

EXCEPTION
    WHEN e_insufficient_funds THEN
        ROLLBACK;
        RETURN 'Transfer failed: ' || SQLERRM;
    WHEN OTHER THEN
        ROLLBACK;
        INSERT INTO error_log (procedure_name, error_code, error_message)
            VALUES ('transfer_funds', SQLCODE, SQLERRM);
        RETURN 'Transfer failed unexpectedly: ' || SQLERRM;
END;

-- Test cases:
CALL transfer_funds(1, 2, 10000);   -- Success: debit Savings, credit Current
CALL transfer_funds(1, 2, 999999);  -- Fail: insufficient funds

SELECT * FROM accounts;


-- ============================================================
-- EXAMPLE 11: Loop with Continue-on-Error Pattern
-- ============================================================
-- Process multiple records; log errors but don't stop
CREATE OR REPLACE TABLE batch_input (id INT, value VARCHAR);
INSERT INTO batch_input VALUES (1, '100'), (2, 'abc'), (3, '300'), (4, 'xyz'), (5, '500');

CREATE OR REPLACE TABLE batch_output (id INT, converted_value NUMBER);

CREATE OR REPLACE PROCEDURE batch_process_with_errors()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_success INT DEFAULT 0;
    v_failed INT DEFAULT 0;
    cur CURSOR FOR SELECT id, value FROM batch_input;
BEGIN
    FOR rec IN cur DO
        BEGIN
            -- This will fail for non-numeric values
            INSERT INTO batch_output VALUES (rec.id, rec.value::NUMBER);
            v_success := v_success + 1;
        EXCEPTION
            WHEN OTHER THEN
                -- Log the error and continue with next record
                INSERT INTO error_log (procedure_name, error_code, error_message)
                    VALUES ('batch_process row ' || rec.id, SQLCODE, SQLERRM);
                v_failed := v_failed + 1;
        END;
    END FOR;

    RETURN 'Processing complete. Success: ' || v_success || ', Failed: ' || v_failed;
END;

CALL batch_process_with_errors();
-- Returns: 'Processing complete. Success: 3, Failed: 2'

SELECT * FROM batch_output;  -- Only rows 1, 3, 5 (numeric values)
SELECT * FROM error_log WHERE procedure_name LIKE 'batch_process%';


-- ============================================================
-- EXAMPLE 12: SQLCODE and SQLERRM - Error Information Variables
-- ============================================================
/*
Built-in variables available inside EXCEPTION block:

  SQLCODE  - Numeric error code
             * Snowflake system errors: positive numbers (e.g., 2003, 100)
             * User-defined exceptions: the code you specified (e.g., -20001)

  SQLERRM  - Error message string
             * Snowflake system errors: descriptive message from Snowflake
             * User-defined exceptions: the message you specified

  SQLSTATE - 5-character ANSI SQL state code (e.g., '02000' for no data)
*/

CREATE OR REPLACE PROCEDURE error_info_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    e_custom EXCEPTION (-99999, 'This is my custom error message');
BEGIN
    RAISE e_custom;
EXCEPTION
    WHEN e_custom THEN
        RETURN 'SQLCODE: ' || SQLCODE || ' | SQLERRM: ' || SQLERRM || ' | SQLSTATE: ' || SQLSTATE;
END;

CALL error_info_demo();
-- Returns: 'SQLCODE: -99999 | SQLERRM: This is my custom error message | SQLSTATE: P0001'


-- ============================================================
-- EXAMPLE 13: Exception Handling with Dynamic SQL (EXECUTE IMMEDIATE)
-- ============================================================
CREATE OR REPLACE PROCEDURE dynamic_sql_exception(p_table_name VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_count INT;
    v_sql VARCHAR;
BEGIN
    v_sql := 'SELECT COUNT(*) FROM ' || :p_table_name;
    EXECUTE IMMEDIATE :v_sql;

    RETURN 'Table ' || :p_table_name || ' exists and is accessible';
EXCEPTION
    WHEN STATEMENT_ERROR THEN
        RETURN 'Failed to query table "' || :p_table_name || '": ' || SQLERRM;
    WHEN OTHER THEN
        RETURN 'Unexpected error: ' || SQLERRM;
END;

CALL dynamic_sql_exception('accounts');             -- Success
CALL dynamic_sql_exception('nonexistent_table');    -- Statement error


-- ============================================================
-- EXAMPLE 14: Retry Pattern with Exception Handling
-- ============================================================
CREATE OR REPLACE PROCEDURE retry_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_attempts INT DEFAULT 0;
    v_max_retries INT DEFAULT 3;
    v_success BOOLEAN DEFAULT FALSE;
BEGIN
    WHILE (:v_attempts < :v_max_retries AND NOT :v_success) DO
        v_attempts := v_attempts + 1;
        BEGIN
            -- Simulate an operation that might fail
            -- Replace with actual logic (API call, complex query, etc.)
            IF (:v_attempts < 3) THEN
                RAISE STATEMENT_ERROR 'Simulated transient failure';
            END IF;
            v_success := TRUE;
        EXCEPTION
            WHEN OTHER THEN
                INSERT INTO error_log (procedure_name, error_code, error_message)
                    VALUES ('retry_demo attempt ' || :v_attempts, SQLCODE, SQLERRM);
                -- If not last attempt, continue loop
                IF (:v_attempts >= :v_max_retries) THEN
                    RETURN 'Failed after ' || :v_max_retries || ' attempts: ' || SQLERRM;
                END IF;
        END;
    END WHILE;

    RETURN 'Succeeded on attempt ' || :v_attempts;
END;

CALL retry_demo();


-- ============================================================
-- EXAMPLE 15: Cleanup Pattern (Simulating TRY-FINALLY)
-- ============================================================
-- Snowflake doesn't have FINALLY, but you can simulate it
CREATE OR REPLACE PROCEDURE cleanup_demo()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_status VARCHAR DEFAULT 'UNKNOWN';
BEGIN
    -- Setup: create temp working table
    CREATE OR REPLACE TEMPORARY TABLE temp_work (id INT, data VARCHAR);
    INSERT INTO temp_work VALUES (1, 'test');

    -- Main logic that might fail
    BEGIN
        LET x NUMBER := 1 / 0;  -- This will fail
        v_status := 'SUCCESS';
    EXCEPTION
        WHEN OTHER THEN
            v_status := 'FAILED: ' || SQLERRM;
    END;

    -- Cleanup always runs (acts like FINALLY)
    DROP TABLE IF EXISTS temp_work;

    RETURN 'Status: ' || :v_status || ' | Cleanup completed';
END;

CALL cleanup_demo();


-- ============================================================
-- SUMMARY: EXCEPTION HANDLING QUICK REFERENCE
-- ============================================================
/*
┌──────────────────────────────────────────────────────────────┐
│ EXCEPTION TYPE        │ USE CASE                             │
├──────────────────────────────────────────────────────────────┤
│ STATEMENT_ERROR       │ SQL execution failures               │
│                       │ (bad table name, syntax, permissions)│
├──────────────────────────────────────────────────────────────┤
│ EXPRESSION_ERROR      │ Expression evaluation failures       │
│                       │ (division by zero, bad cast)         │
├──────────────────────────────────────────────────────────────┤
│ User-Defined          │ Business logic violations            │
│ (DECLARE + RAISE)     │ (custom validations, rules)          │
├──────────────────────────────────────────────────────────────┤
│ OTHER                 │ Catch-all for anything unhandled     │
│                       │ (always include as last WHEN)        │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ BUILT-IN VARIABLES    │ DESCRIPTION                          │
├──────────────────────────────────────────────────────────────┤
│ SQLCODE               │ Numeric error code                   │
│ SQLERRM               │ Error message text                   │
│ SQLSTATE              │ 5-char ANSI SQL state code           │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ PATTERNS              │ DESCRIPTION                          │
├──────────────────────────────────────────────────────────────┤
│ Basic try-catch       │ BEGIN ... EXCEPTION WHEN ... END     │
│ Nested blocks         │ Inner BEGIN...END inside outer       │
│ Re-raise              │ RAISE (no args) in EXCEPTION block   │
│ Error logging         │ INSERT into log table in handler     │
│ Transaction safety    │ BEGIN TRANSACTION + ROLLBACK on error│
│ Continue-on-error     │ Loop with inner BEGIN...EXCEPTION    │
│ Retry pattern         │ WHILE loop with attempt counter      │
│ Cleanup (finally)     │ Nested block + cleanup after         │
└──────────────────────────────────────────────────────────────┘
*/
