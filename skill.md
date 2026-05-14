---
name: error-tables-ops
description: Use when the user wants to read, query, analyze, or troubleshoot DML errors from the error table for the orders table. Triggers include error table, error logging, rejected rows, failed inserts, constraint violations, check constraint errors, orders errors, orders error table.
---

# Instructions

This skill reads and analyzes the error table for `SQL.PROBLEMS.ORDERS` (ERROR_LOGGING = TRUE).

## Orders Table Schema

| Column | Type | Nullable |
|--------|------|----------|
| ORDER_ID | NUMBER(38,0) | NOT NULL |
| CUSTOMER_ID | NUMBER(38,0) | NOT NULL |
| STATUS | VARCHAR(20) | YES |
| AMOUNT | NUMBER(10,2) | YES |
| ORDER_DATE | DATE | YES |
| SHIP_DATE | DATE | YES |
| EVENT_DATA | VARIANT | YES |

## CHECK Constraints on Orders

| Constraint Name | Rule |
|-----------------|------|
| SYS_CONSTRAINT (status) | `status IN ('active', 'pending', 'shipped', 'delivered', 'returned')` |
| SYS_CONSTRAINT (amount) | `amount > 0` |
| CHK_SHIP_AFTER_ORDER | `ship_date >= order_date` |
| CHK_EVT_TYPE | `event_data:type::STRING IS NOT NULL` |
| CHK_EVT_SOURCE | `event_data:source::STRING IS NOT NULL` |
| CHK_EVT_META_OBJ | `event_data:metadata IS NULL OR IS_OBJECT(event_data:metadata)` |
| CHK_EVT_TAGS_ARR | `event_data:tags IS NULL OR IS_ARRAY(event_data:tags)` |
| CHK_EVT_AMOUNT | `event_data:amount IS NULL OR TRY_CAST(event_data:amount::STRING AS NUMBER) IS NOT NULL` |

## Error Table Schema

The error table (`ERROR_TABLE(SQL.PROBLEMS.ORDERS)`) has these columns:

| Column | Type | Description |
|--------|------|-------------|
| TIMESTAMP | TIMESTAMP_LTZ | When the error occurred |
| QUERY_ID | VARCHAR | The query that caused the error |
| ERROR_CODE | NUMBER | Snowflake error code (e.g. 100320 = CHECK constraint violation) |
| ERROR_METADATA | OBJECT | Contains `error_code`, `error_message`, `sql_state` |
| ERROR_DATA | OBJECT | The rejected row data with column values as keys (ORDER_ID, CUSTOMER_ID, STATUS, AMOUNT, ORDER_DATE, SHIP_DATE, EVENT_DATA) |

## Step 1: View All Errors

```sql
SELECT
    TIMESTAMP,
    QUERY_ID,
    ERROR_CODE,
    ERROR_METADATA:error_message::STRING AS ERROR_MESSAGE,
    ERROR_DATA:ORDER_ID::INT AS ORDER_ID,
    ERROR_DATA:CUSTOMER_ID::INT AS CUSTOMER_ID,
    ERROR_DATA:STATUS::STRING AS STATUS,
    ERROR_DATA:AMOUNT::NUMBER(10,2) AS AMOUNT,
    ERROR_DATA:ORDER_DATE::DATE AS ORDER_DATE,
    ERROR_DATA:SHIP_DATE::DATE AS SHIP_DATE,
    ERROR_DATA:EVENT_DATA AS EVENT_DATA
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
ORDER BY TIMESTAMP DESC;
```

## Step 2: Summarize Errors by Constraint Violated

```sql
SELECT
    ERROR_CODE,
    ERROR_METADATA:error_message::STRING AS ERROR_MESSAGE,
    COUNT(*) AS ERROR_COUNT
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
GROUP BY 1, 2
ORDER BY ERROR_COUNT DESC;
```

## Step 3: Identify Which Constraint Was Violated Per Row

Parse the error message to classify the constraint type:

```sql
SELECT
    TIMESTAMP,
    ERROR_CODE,
    ERROR_DATA:ORDER_ID::INT AS ORDER_ID,
    CASE
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%status IN%' THEN 'Invalid status'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%amount > 0%' THEN 'Non-positive amount'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%ship_date >= order_date%' THEN 'Ship date before order date'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:type%' THEN 'Missing event type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:source%' THEN 'Missing event source'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_OBJECT(event_data:metadata)%' THEN 'Invalid metadata type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_ARRAY(event_data:tags)%' THEN 'Invalid tags type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:amount%' THEN 'Non-numeric event amount'
        ELSE 'Other'
    END AS VIOLATION_TYPE,
    ERROR_DATA
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
ORDER BY TIMESTAMP DESC;
```

## Step 4: Recent Errors (Last 24 Hours)

```sql
SELECT
    TIMESTAMP,
    ERROR_CODE,
    ERROR_METADATA:error_message::STRING AS ERROR_MESSAGE,
    ERROR_DATA
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
WHERE TIMESTAMP >= DATEADD(HOUR, -24, CURRENT_TIMESTAMP())
ORDER BY TIMESTAMP DESC;
```

## Step 5: Send Email Alert with Error Summary

This step builds an HTML email summarizing error counts per constraint and the reason for each, then sends it via SYSTEM$SEND_EMAIL.

**Prerequisites (run once if not already done):**

```sql
CREATE NOTIFICATION INTEGRATION IF NOT EXISTS orders_error_email_int
  TYPE = EMAIL
  ENABLED = TRUE
  ALLOWED_RECIPIENTS = ('190040236ece@gmail.com');
```

The recipient email must be a verified Snowflake user email. Verify it with:

```sql
CALL SYSTEM$START_USER_EMAIL_VERIFICATION('190040236ece@gmail.com');
```

**Send the alert:**

```sql
CALL SYSTEM$SEND_EMAIL(
    'orders_error_email_int',
    '190040236ece@gmail.com',
    'Orders Error Table Alert - ' || CURRENT_DATE()::STRING,
    (SELECT LISTAGG(
        'Constraint: ' || VIOLATION_TYPE ||
        ' | Error Code: ' || ERROR_CODE::STRING ||
        ' | Count: ' || ERROR_COUNT::STRING ||
        ' | Reason: ' || REASON,
        '\n'
    )
    FROM (
        SELECT
            CASE
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%status IN%' THEN 'Invalid status'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%amount > 0%' THEN 'Non-positive amount'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%ship_date >= order_date%' THEN 'Ship date before order date'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:type%' THEN 'Missing event type'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:source%' THEN 'Missing event source'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_OBJECT(event_data:metadata)%' THEN 'Invalid metadata type'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_ARRAY(event_data:tags)%' THEN 'Invalid tags type'
                WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:amount%' THEN 'Non-numeric event amount'
                ELSE 'Other'
            END AS VIOLATION_TYPE,
            ERROR_CODE,
            COUNT(*) AS ERROR_COUNT,
            ANY_VALUE(ERROR_METADATA:error_message::STRING) AS REASON
        FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS)
        GROUP BY 1, 2
        ORDER BY ERROR_COUNT DESC
    ))
);
```

## Step 6: Generate Corrected INSERT Statements for Rejected Rows

After analyzing the errors, generate INSERT statements with corrected values. The assistant should:

1. Query the error table to get all rejected rows:

```sql
SELECT
    ERROR_DATA:ORDER_ID::INT AS ORDER_ID,
    ERROR_DATA:CUSTOMER_ID::INT AS CUSTOMER_ID,
    ERROR_DATA:STATUS::STRING AS STATUS,
    ERROR_DATA:AMOUNT::NUMBER(10,2) AS AMOUNT,
    ERROR_DATA:ORDER_DATE::DATE AS ORDER_DATE,
    ERROR_DATA:SHIP_DATE::DATE AS SHIP_DATE,
    ERROR_DATA:EVENT_DATA AS EVENT_DATA,
    CASE
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%status IN%' THEN 'Invalid status'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%amount > 0%' THEN 'Non-positive amount'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%ship_date >= order_date%' THEN 'Ship date before order date'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:type%' THEN 'Missing event type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:source%' THEN 'Missing event source'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_OBJECT(event_data:metadata)%' THEN 'Invalid metadata type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%IS_ARRAY(event_data:tags)%' THEN 'Invalid tags type'
        WHEN ERROR_METADATA:error_message::STRING ILIKE '%event_data:amount%' THEN 'Non-numeric event amount'
        ELSE 'Other'
    END AS VIOLATION_TYPE
FROM ERROR_TABLE(SQL.PROBLEMS.ORDERS);
```

2. For each rejected row, generate a corrected INSERT statement applying these fix rules:
   - **Invalid status**: Replace with `'pending'` (safe default)
   - **Non-positive amount**: Use `ABS(amount)` (make positive), or `1.00` if amount was 0
   - **Ship date before order date**: Set `ship_date = order_date`
   - **Missing event type**: Set `event_data:type = 'unknown'`
   - **Missing event source**: Set `event_data:source = 'unknown'`
   - **Invalid metadata type**: Set `event_data:metadata = {}`
   - **Invalid tags type**: Set `event_data:tags = []`
   - **Non-numeric event amount**: Remove `event_data:amount`

3. Present the corrected INSERT statements to the user for review before execution.

## Step 7: Truncate Error Table (only if user explicitly requests)

```sql
TRUNCATE ERROR_TABLE(SQL.PROBLEMS.ORDERS);
```

## Notes
- Error code `100320` = CHECK constraint violation.
- `ERROR_DATA` keys match the column names of the orders table in UPPERCASE.
- Always use `ERROR_TABLE(SQL.PROBLEMS.ORDERS)` — not a physical table name.
- Email alert recipient: `190040236ece@gmail.com`
- Notification integration: `orders_error_email_int`
- The recipient email must belong to a verified Snowflake user in the account for SYSTEM$SEND_EMAIL to work.
