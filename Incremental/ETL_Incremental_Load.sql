-- ============================================================
-- ETL CONCEPTS IN SNOWFLAKE
-- Incremental Loading, Auditing & Real Project Implementation
-- ============================================================

-- ============================================================
-- PROJECT SCENARIO: E-COMMERCE DATA WAREHOUSE
-- ============================================================
/*
We're building an ETL pipeline for an e-commerce company:
- Source system: Transactional database (orders, customers, products)
- Target: Snowflake data warehouse for analytics
- Requirements:
    * Load new/changed data every hour (not full reload)
    * Track what was loaded, when, how many records
    * Handle late-arriving data and updates
    * Detect and log data quality issues
    * Support reprocessing of failed batches
*/


-- ============================================================
-- SECTION 1: DATABASE SETUP (Raw → Staging → Warehouse)
-- ============================================================

CREATE OR REPLACE DATABASE ECOMMERCE_DW;

-- RAW layer: Landing zone for source data (as-is from source)
CREATE OR REPLACE SCHEMA ECOMMERCE_DW.RAW;

-- STAGING layer: Cleansed, transformed, ready for loading
CREATE OR REPLACE SCHEMA ECOMMERCE_DW.STAGING;

-- WAREHOUSE layer: Final analytics tables (star schema)
CREATE OR REPLACE SCHEMA ECOMMERCE_DW.WAREHOUSE;

-- AUDIT layer: ETL tracking and logging
CREATE OR REPLACE SCHEMA ECOMMERCE_DW.AUDIT;

USE SCHEMA ECOMMERCE_DW.RAW;


-- ============================================================
-- SECTION 2: SOURCE TABLES (Simulating the Source System)
-- ============================================================

-- Source: Customers table
CREATE OR REPLACE TABLE RAW.SRC_CUSTOMERS (
    customer_id INT,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    email VARCHAR(100),
    phone VARCHAR(20),
    city VARCHAR(50),
    state VARCHAR(30),
    country VARCHAR(30),
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);

-- Source: Products table
CREATE OR REPLACE TABLE RAW.SRC_PRODUCTS (
    product_id INT,
    product_name VARCHAR(200),
    category VARCHAR(50),
    sub_category VARCHAR(50),
    brand VARCHAR(50),
    price NUMBER(10,2),
    cost NUMBER(10,2),
    is_active BOOLEAN,
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);

-- Source: Orders table (high volume, main fact)
CREATE OR REPLACE TABLE RAW.SRC_ORDERS (
    order_id INT,
    customer_id INT,
    order_date TIMESTAMP,
    status VARCHAR(20),
    total_amount NUMBER(12,2),
    discount_amount NUMBER(10,2),
    shipping_amount NUMBER(10,2),
    payment_method VARCHAR(30),
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);

-- Source: Order Line Items
CREATE OR REPLACE TABLE RAW.SRC_ORDER_ITEMS (
    item_id INT,
    order_id INT,
    product_id INT,
    quantity INT,
    unit_price NUMBER(10,2),
    discount_pct NUMBER(5,2),
    created_at TIMESTAMP,
    updated_at TIMESTAMP
);

-- Load sample data into source tables
INSERT INTO RAW.SRC_CUSTOMERS
SELECT
    SEQ4() + 1 AS customer_id,
    'First_' || (SEQ4() + 1) AS first_name,
    'Last_' || (SEQ4() + 1) AS last_name,
    'user' || (SEQ4() + 1) || '@email.com' AS email,
    '555-' || LPAD(SEQ4() + 1, 4, '0') AS phone,
    CASE MOD(SEQ4(), 5) WHEN 0 THEN 'Mumbai' WHEN 1 THEN 'Delhi' WHEN 2 THEN 'Bangalore' WHEN 3 THEN 'Chennai' ELSE 'Hyderabad' END AS city,
    CASE MOD(SEQ4(), 5) WHEN 0 THEN 'Maharashtra' WHEN 1 THEN 'Delhi' WHEN 2 THEN 'Karnataka' WHEN 3 THEN 'Tamil Nadu' ELSE 'Telangana' END AS state,
    'India' AS country,
    DATEADD('HOUR', -SEQ4() * 2, CURRENT_TIMESTAMP()) AS created_at,
    DATEADD('HOUR', -SEQ4(), CURRENT_TIMESTAMP()) AS updated_at
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

INSERT INTO RAW.SRC_PRODUCTS
SELECT
    SEQ4() + 1 AS product_id,
    'Product_' || (SEQ4() + 1) AS product_name,
    CASE MOD(SEQ4(), 4) WHEN 0 THEN 'Electronics' WHEN 1 THEN 'Clothing' WHEN 2 THEN 'Home' ELSE 'Sports' END AS category,
    'SubCat_' || MOD(SEQ4(), 10) AS sub_category,
    'Brand_' || MOD(SEQ4(), 20) AS brand,
    ROUND(UNIFORM(100, 50000, RANDOM()), 2) AS price,
    ROUND(UNIFORM(50, 25000, RANDOM()), 2) AS cost,
    TRUE AS is_active,
    DATEADD('DAY', -SEQ4(), CURRENT_TIMESTAMP()) AS created_at,
    DATEADD('DAY', -SEQ4(), CURRENT_TIMESTAMP()) AS updated_at
FROM TABLE(GENERATOR(ROWCOUNT => 200));

INSERT INTO RAW.SRC_ORDERS
SELECT
    SEQ4() + 1 AS order_id,
    UNIFORM(1, 1000, RANDOM()) AS customer_id,
    DATEADD('MINUTE', -SEQ4() * 15, CURRENT_TIMESTAMP()) AS order_date,
    CASE MOD(SEQ4(), 5) WHEN 0 THEN 'PENDING' WHEN 1 THEN 'SHIPPED' WHEN 2 THEN 'DELIVERED' WHEN 3 THEN 'CANCELLED' ELSE 'RETURNED' END AS status,
    ROUND(UNIFORM(500, 100000, RANDOM()), 2) AS total_amount,
    ROUND(UNIFORM(0, 5000, RANDOM()), 2) AS discount_amount,
    ROUND(UNIFORM(50, 500, RANDOM()), 2) AS shipping_amount,
    CASE MOD(SEQ4(), 4) WHEN 0 THEN 'CREDIT_CARD' WHEN 1 THEN 'UPI' WHEN 2 THEN 'DEBIT_CARD' ELSE 'NET_BANKING' END AS payment_method,
    DATEADD('MINUTE', -SEQ4() * 15, CURRENT_TIMESTAMP()) AS created_at,
    DATEADD('MINUTE', -SEQ4() * 10, CURRENT_TIMESTAMP()) AS updated_at
FROM TABLE(GENERATOR(ROWCOUNT => 50000));

INSERT INTO RAW.SRC_ORDER_ITEMS
SELECT
    SEQ4() + 1 AS item_id,
    UNIFORM(1, 50000, RANDOM()) AS order_id,
    UNIFORM(1, 200, RANDOM()) AS product_id,
    UNIFORM(1, 5, RANDOM()) AS quantity,
    ROUND(UNIFORM(100, 50000, RANDOM()), 2) AS unit_price,
    ROUND(UNIFORM(0, 30, RANDOM()), 2) AS discount_pct,
    DATEADD('MINUTE', -SEQ4() * 10, CURRENT_TIMESTAMP()) AS created_at,
    DATEADD('MINUTE', -SEQ4() * 5, CURRENT_TIMESTAMP()) AS updated_at
FROM TABLE(GENERATOR(ROWCOUNT => 150000));


-- ============================================================
-- SECTION 3: ETL AUDIT FRAMEWORK
-- ============================================================
/*
The audit framework tracks:
- EVERY batch that runs (success or failure)
- How many records were inserted, updated, rejected
- Start/end times and duration
- Error details for debugging
- Enables reprocessing of failed batches
*/

USE SCHEMA ECOMMERCE_DW.AUDIT;

-- Master batch log: One row per ETL batch run
CREATE OR REPLACE TABLE AUDIT.ETL_BATCH_LOG (
    batch_id INT AUTOINCREMENT,
    batch_name VARCHAR(100),
    source_table VARCHAR(100),
    target_table VARCHAR(100),
    batch_start_time TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    batch_end_time TIMESTAMP,
    batch_status VARCHAR(20) DEFAULT 'RUNNING',  -- RUNNING, SUCCESS, FAILED
    records_read INT DEFAULT 0,
    records_inserted INT DEFAULT 0,
    records_updated INT DEFAULT 0,
    records_deleted INT DEFAULT 0,
    records_rejected INT DEFAULT 0,
    error_message VARCHAR(2000),
    watermark_value TIMESTAMP,  -- High watermark used for this batch
    new_watermark_value TIMESTAMP,  -- New watermark after this batch
    created_by VARCHAR(50) DEFAULT CURRENT_USER(),
    CONSTRAINT pk_batch_log PRIMARY KEY (batch_id)
);

-- Data quality log: Tracks rejected/problematic records
CREATE OR REPLACE TABLE AUDIT.ETL_DATA_QUALITY_LOG (
    dq_id INT AUTOINCREMENT,
    batch_id INT,
    source_table VARCHAR(100),
    record_id VARCHAR(100),
    column_name VARCHAR(100),
    rule_name VARCHAR(100),
    rule_description VARCHAR(500),
    actual_value VARCHAR(500),
    severity VARCHAR(20),  -- ERROR, WARNING, INFO
    logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Watermark table: Stores last successful extraction point per table
CREATE OR REPLACE TABLE AUDIT.ETL_WATERMARKS (
    table_name VARCHAR(100) PRIMARY KEY,
    last_extracted_at TIMESTAMP,
    last_batch_id INT,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Initialize watermarks (first run starts from beginning of time)
INSERT INTO AUDIT.ETL_WATERMARKS (table_name, last_extracted_at, last_batch_id)
VALUES
    ('SRC_CUSTOMERS', '1900-01-01 00:00:00', 0),
    ('SRC_PRODUCTS', '1900-01-01 00:00:00', 0),
    ('SRC_ORDERS', '1900-01-01 00:00:00', 0),
    ('SRC_ORDER_ITEMS', '1900-01-01 00:00:00', 0);

-- ETL run history summary view
CREATE OR REPLACE VIEW AUDIT.V_ETL_RUN_SUMMARY AS
SELECT
    batch_id,
    batch_name,
    source_table,
    target_table,
    batch_status,
    records_read,
    records_inserted,
    records_updated,
    records_rejected,
    DATEDIFF('SECOND', batch_start_time, batch_end_time) AS duration_seconds,
    watermark_value,
    new_watermark_value,
    batch_start_time,
    batch_end_time,
    error_message
FROM AUDIT.ETL_BATCH_LOG
ORDER BY batch_start_time DESC;


-- ============================================================
-- SECTION 4: INCREMENTAL LOAD - CONCEPT
-- ============================================================
/*
FULL LOAD vs INCREMENTAL LOAD:

FULL LOAD:
- Extracts ALL records every time
- Simple but expensive for large tables
- Use for: small dimension tables, first-time loads

INCREMENTAL LOAD:
- Extracts only NEW or CHANGED records since last run
- Uses a "watermark" (high water mark) to track extraction point
- Much faster and cheaper for large tables

WATERMARK STRATEGIES:
1. TIMESTAMP-BASED: Use updated_at column
   - Most common approach
   - Requires source table to have reliable updated_at
   - Cannot detect hard deletes

2. ID-BASED: Use auto-increment ID
   - Good for append-only tables
   - Cannot detect updates to existing records

3. CDC (Change Data Capture): Use Snowflake Streams
   - Captures inserts, updates, AND deletes
   - Most complete solution
   - Built into Snowflake

4. HASH-BASED: Compare hash of row to detect changes
   - Works when no timestamp/CDC available
   - More expensive (must read all rows to compare)
*/


-- ============================================================
-- SECTION 5: INCREMENTAL LOAD WITH TIMESTAMP WATERMARK
-- ============================================================

USE SCHEMA ECOMMERCE_DW.WAREHOUSE;

-- Target: Customer dimension table (SCD Type 1 - overwrite changes)
CREATE OR REPLACE TABLE WAREHOUSE.DIM_CUSTOMER (
    customer_key INT AUTOINCREMENT,
    customer_id INT,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    full_name VARCHAR(100),
    email VARCHAR(100),
    phone VARCHAR(20),
    city VARCHAR(50),
    state VARCHAR(30),
    country VARCHAR(30),
    etl_batch_id INT,
    etl_loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    etl_updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Procedure: Incremental load for customers
CREATE OR REPLACE PROCEDURE ECOMMERCE_DW.WAREHOUSE.LOAD_DIM_CUSTOMER()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_batch_id INT;
    v_watermark TIMESTAMP;
    v_new_watermark TIMESTAMP;
    v_records_read INT DEFAULT 0;
    v_records_inserted INT DEFAULT 0;
    v_records_updated INT DEFAULT 0;
    v_records_rejected INT DEFAULT 0;
BEGIN
    -- Step 1: Create batch log entry
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG (batch_name, source_table, target_table)
    VALUES ('LOAD_DIM_CUSTOMER', 'RAW.SRC_CUSTOMERS', 'WAREHOUSE.DIM_CUSTOMER');

    SELECT MAX(batch_id) INTO :v_batch_id FROM ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG;

    -- Step 2: Get current watermark
    SELECT last_extracted_at INTO :v_watermark
    FROM ECOMMERCE_DW.AUDIT.ETL_WATERMARKS
    WHERE table_name = 'SRC_CUSTOMERS';

    -- Step 3: Get new watermark (max updated_at from source)
    SELECT MAX(updated_at) INTO :v_new_watermark
    FROM ECOMMERCE_DW.RAW.SRC_CUSTOMERS
    WHERE updated_at > :v_watermark;

    -- If no new data, exit early
    IF (:v_new_watermark IS NULL) THEN
        UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
        SET batch_status = 'SUCCESS',
            batch_end_time = CURRENT_TIMESTAMP(),
            records_read = 0
        WHERE batch_id = :v_batch_id;
        RETURN 'No new data to process';
    END IF;

    -- Step 4: Count records to process
    SELECT COUNT(*) INTO :v_records_read
    FROM ECOMMERCE_DW.RAW.SRC_CUSTOMERS
    WHERE updated_at > :v_watermark AND updated_at <= :v_new_watermark;

    -- Step 5: Data quality checks on incremental data
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
        (batch_id, source_table, record_id, column_name, rule_name, rule_description, actual_value, severity)
    SELECT
        :v_batch_id,
        'SRC_CUSTOMERS',
        customer_id::VARCHAR,
        'EMAIL',
        'INVALID_EMAIL',
        'Email does not contain @ symbol',
        email,
        'WARNING'
    FROM ECOMMERCE_DW.RAW.SRC_CUSTOMERS
    WHERE updated_at > :v_watermark
        AND updated_at <= :v_new_watermark
        AND email NOT LIKE '%@%';

    SELECT COUNT(*) INTO :v_records_rejected
    FROM ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
    WHERE batch_id = :v_batch_id AND severity = 'ERROR';

    -- Step 6: MERGE (upsert) - Insert new, update existing
    MERGE INTO ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER tgt
    USING (
        SELECT
            customer_id,
            first_name,
            last_name,
            first_name || ' ' || last_name AS full_name,
            email,
            phone,
            city,
            state,
            country
        FROM ECOMMERCE_DW.RAW.SRC_CUSTOMERS
        WHERE updated_at > :v_watermark
            AND updated_at <= :v_new_watermark
            AND customer_id NOT IN (
                SELECT record_id::INT FROM ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
                WHERE batch_id = :v_batch_id AND severity = 'ERROR'
            )
    ) src
    ON tgt.customer_id = src.customer_id
    WHEN MATCHED THEN UPDATE SET
        tgt.first_name = src.first_name,
        tgt.last_name = src.last_name,
        tgt.full_name = src.full_name,
        tgt.email = src.email,
        tgt.phone = src.phone,
        tgt.city = src.city,
        tgt.state = src.state,
        tgt.country = src.country,
        tgt.etl_batch_id = :v_batch_id,
        tgt.etl_updated_at = CURRENT_TIMESTAMP()
    WHEN NOT MATCHED THEN INSERT (
        customer_id, first_name, last_name, full_name, email, phone,
        city, state, country, etl_batch_id
    ) VALUES (
        src.customer_id, src.first_name, src.last_name, src.full_name,
        src.email, src.phone, src.city, src.state, src.country, :v_batch_id
    );

    -- Step 7: Get actual insert/update counts
    -- (In production, use DML output or row counts)
    SELECT COUNT(*) INTO :v_records_inserted
    FROM ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER
    WHERE etl_batch_id = :v_batch_id AND etl_loaded_at = etl_updated_at;

    v_records_updated := v_records_read - v_records_inserted - v_records_rejected;

    -- Step 8: Update watermark
    UPDATE ECOMMERCE_DW.AUDIT.ETL_WATERMARKS
    SET last_extracted_at = :v_new_watermark,
        last_batch_id = :v_batch_id,
        updated_at = CURRENT_TIMESTAMP()
    WHERE table_name = 'SRC_CUSTOMERS';

    -- Step 9: Mark batch as success
    UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
    SET batch_status = 'SUCCESS',
        batch_end_time = CURRENT_TIMESTAMP(),
        records_read = :v_records_read,
        records_inserted = :v_records_inserted,
        records_updated = :v_records_updated,
        records_rejected = :v_records_rejected,
        watermark_value = :v_watermark,
        new_watermark_value = :v_new_watermark
    WHERE batch_id = :v_batch_id;

    RETURN 'Batch ' || :v_batch_id || ' completed. Read: ' || :v_records_read ||
           ', Inserted: ' || :v_records_inserted || ', Updated: ' || :v_records_updated ||
           ', Rejected: ' || :v_records_rejected;

EXCEPTION
    WHEN OTHER THEN
        UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
        SET batch_status = 'FAILED',
            batch_end_time = CURRENT_TIMESTAMP(),
            error_message = SQLERRM
        WHERE batch_id = :v_batch_id;
        RETURN 'FAILED: ' || SQLERRM;
END;

-- Run the incremental load
CALL ECOMMERCE_DW.WAREHOUSE.LOAD_DIM_CUSTOMER();

-- Check results
SELECT * FROM ECOMMERCE_DW.AUDIT.V_ETL_RUN_SUMMARY WHERE batch_name = 'LOAD_DIM_CUSTOMER';
SELECT COUNT(*) AS customer_count FROM ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER;


-- ============================================================
-- SECTION 6: INCREMENTAL LOAD USING SNOWFLAKE STREAMS (CDC)
-- ============================================================
/*
Snowflake STREAMS capture changes (INSERT, UPDATE, DELETE) automatically.
This is the most reliable incremental load method in Snowflake.

Advantages over timestamp watermark:
- Captures DELETES (timestamp approach cannot)
- No dependency on source having updated_at column
- Guaranteed no missed records
- Built into Snowflake (no external tools)
*/

-- Create target fact table
CREATE OR REPLACE TABLE WAREHOUSE.FACT_ORDERS (
    order_key INT AUTOINCREMENT,
    order_id INT,
    customer_id INT,
    order_date DATE,
    order_timestamp TIMESTAMP,
    status VARCHAR(20),
    total_amount NUMBER(12,2),
    discount_amount NUMBER(10,2),
    shipping_amount NUMBER(10,2),
    net_amount NUMBER(12,2),
    payment_method VARCHAR(30),
    etl_batch_id INT,
    etl_loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP(),
    etl_action VARCHAR(10)  -- INSERT, UPDATE, DELETE
);

-- Create a STREAM on the source table
CREATE OR REPLACE STREAM RAW.ORDERS_STREAM ON TABLE RAW.SRC_ORDERS
    APPEND_ONLY = FALSE;  -- Captures INSERT, UPDATE, DELETE

-- Check stream status
SHOW STREAMS IN SCHEMA RAW;

-- View stream contents (what changed since last consumption)
SELECT * FROM RAW.ORDERS_STREAM LIMIT 20;
/*
Stream adds metadata columns:
- METADATA$ACTION: 'INSERT' or 'DELETE'
- METADATA$ISUPDATE: TRUE if this is part of an UPDATE
- METADATA$ROW_ID: Unique row identifier

For UPDATES: Stream shows DELETE (old row) + INSERT (new row) with ISUPDATE=TRUE
*/

-- Procedure: Stream-based incremental load for orders
CREATE OR REPLACE PROCEDURE ECOMMERCE_DW.WAREHOUSE.LOAD_FACT_ORDERS_STREAM()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_batch_id INT;
    v_records_read INT DEFAULT 0;
    v_records_inserted INT DEFAULT 0;
    v_records_updated INT DEFAULT 0;
    v_records_deleted INT DEFAULT 0;
    v_has_data BOOLEAN DEFAULT FALSE;
BEGIN
    -- Check if stream has data
    SELECT SYSTEM$STREAM_HAS_DATA('ECOMMERCE_DW.RAW.ORDERS_STREAM') INTO :v_has_data;

    IF (NOT :v_has_data) THEN
        RETURN 'No new changes in stream';
    END IF;

    -- Create batch log
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG (batch_name, source_table, target_table)
    VALUES ('LOAD_FACT_ORDERS_STREAM', 'RAW.ORDERS_STREAM', 'WAREHOUSE.FACT_ORDERS');

    SELECT MAX(batch_id) INTO :v_batch_id FROM ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG;

    -- Count changes in stream
    SELECT COUNT(*) INTO :v_records_read FROM ECOMMERCE_DW.RAW.ORDERS_STREAM;

    -- Process stream using MERGE
    -- Handles inserts, updates, and deletes in one statement
    MERGE INTO ECOMMERCE_DW.WAREHOUSE.FACT_ORDERS tgt
    USING (
        SELECT
            order_id,
            customer_id,
            order_date::DATE AS order_date,
            order_date AS order_timestamp,
            status,
            total_amount,
            discount_amount,
            shipping_amount,
            total_amount - discount_amount + shipping_amount AS net_amount,
            payment_method,
            METADATA$ACTION AS stream_action,
            METADATA$ISUPDATE AS is_update
        FROM ECOMMERCE_DW.RAW.ORDERS_STREAM
    ) src
    ON tgt.order_id = src.order_id
    -- UPDATE existing records
    WHEN MATCHED AND src.stream_action = 'INSERT' AND src.is_update = TRUE THEN UPDATE SET
        tgt.customer_id = src.customer_id,
        tgt.order_date = src.order_date,
        tgt.order_timestamp = src.order_timestamp,
        tgt.status = src.status,
        tgt.total_amount = src.total_amount,
        tgt.discount_amount = src.discount_amount,
        tgt.shipping_amount = src.shipping_amount,
        tgt.net_amount = src.net_amount,
        tgt.payment_method = src.payment_method,
        tgt.etl_batch_id = :v_batch_id,
        tgt.etl_action = 'UPDATE'
    -- DELETE records
    WHEN MATCHED AND src.stream_action = 'DELETE' AND src.is_update = FALSE THEN DELETE
    -- INSERT new records
    WHEN NOT MATCHED AND src.stream_action = 'INSERT' THEN INSERT (
        order_id, customer_id, order_date, order_timestamp, status,
        total_amount, discount_amount, shipping_amount, net_amount,
        payment_method, etl_batch_id, etl_action
    ) VALUES (
        src.order_id, src.customer_id, src.order_date, src.order_timestamp,
        src.status, src.total_amount, src.discount_amount, src.shipping_amount,
        src.net_amount, src.payment_method, :v_batch_id, 'INSERT'
    );

    -- Get counts (approximate from target)
    SELECT COUNT(*) INTO :v_records_inserted
    FROM ECOMMERCE_DW.WAREHOUSE.FACT_ORDERS
    WHERE etl_batch_id = :v_batch_id AND etl_action = 'INSERT';

    SELECT COUNT(*) INTO :v_records_updated
    FROM ECOMMERCE_DW.WAREHOUSE.FACT_ORDERS
    WHERE etl_batch_id = :v_batch_id AND etl_action = 'UPDATE';

    -- Update batch log
    UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
    SET batch_status = 'SUCCESS',
        batch_end_time = CURRENT_TIMESTAMP(),
        records_read = :v_records_read,
        records_inserted = :v_records_inserted,
        records_updated = :v_records_updated,
        records_deleted = :v_records_deleted
    WHERE batch_id = :v_batch_id;

    RETURN 'Stream batch ' || :v_batch_id || ' completed. Read: ' || :v_records_read ||
           ', Inserted: ' || :v_records_inserted || ', Updated: ' || :v_records_updated;

EXCEPTION
    WHEN OTHER THEN
        UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
        SET batch_status = 'FAILED',
            batch_end_time = CURRENT_TIMESTAMP(),
            error_message = SQLERRM
        WHERE batch_id = :v_batch_id;
        RETURN 'FAILED: ' || SQLERRM;
END;

-- Run stream-based load
CALL ECOMMERCE_DW.WAREHOUSE.LOAD_FACT_ORDERS_STREAM();


-- ============================================================
-- SECTION 7: SLOWLY CHANGING DIMENSION TYPE 2 (SCD2)
-- ============================================================
/*
SCD Type 2 preserves HISTORY of changes.
Instead of overwriting, it creates a new row for each change.
Old rows are marked as expired.

Use case: Track customer address changes over time
- Customer moved from Mumbai to Delhi on March 1
- Reports for February should show Mumbai
- Reports for March should show Delhi
*/

CREATE OR REPLACE TABLE WAREHOUSE.DIM_CUSTOMER_SCD2 (
    customer_key INT AUTOINCREMENT,
    customer_id INT,
    first_name VARCHAR(50),
    last_name VARCHAR(50),
    email VARCHAR(100),
    city VARCHAR(50),
    state VARCHAR(30),
    country VARCHAR(30),
    -- SCD2 control columns
    effective_from TIMESTAMP,
    effective_to TIMESTAMP DEFAULT '9999-12-31 23:59:59',
    is_current BOOLEAN DEFAULT TRUE,
    row_hash VARCHAR(64),  -- Hash of trackable columns to detect changes
    etl_batch_id INT,
    etl_loaded_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- Stream for SCD2 processing
CREATE OR REPLACE STREAM RAW.CUSTOMERS_STREAM ON TABLE RAW.SRC_CUSTOMERS
    APPEND_ONLY = FALSE;

-- Procedure: SCD Type 2 load
CREATE OR REPLACE PROCEDURE ECOMMERCE_DW.WAREHOUSE.LOAD_DIM_CUSTOMER_SCD2()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_batch_id INT;
    v_records_read INT DEFAULT 0;
    v_records_inserted INT DEFAULT 0;
    v_records_updated INT DEFAULT 0;
BEGIN
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG (batch_name, source_table, target_table)
    VALUES ('LOAD_DIM_CUSTOMER_SCD2', 'RAW.SRC_CUSTOMERS', 'WAREHOUSE.DIM_CUSTOMER_SCD2');

    SELECT MAX(batch_id) INTO :v_batch_id FROM ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG;

    -- Step 1: Stage incoming changes with hash
    CREATE OR REPLACE TEMPORARY TABLE STAGING.STG_CUSTOMER_CHANGES AS
    SELECT
        customer_id,
        first_name,
        last_name,
        email,
        city,
        state,
        country,
        updated_at,
        MD5(COALESCE(first_name,'') || '|' || COALESCE(last_name,'') || '|' ||
            COALESCE(email,'') || '|' || COALESCE(city,'') || '|' ||
            COALESCE(state,'') || '|' || COALESCE(country,'')) AS row_hash
    FROM ECOMMERCE_DW.RAW.SRC_CUSTOMERS
    WHERE updated_at > (
        SELECT COALESCE(MAX(effective_from), '1900-01-01')
        FROM ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER_SCD2
    );

    SELECT COUNT(*) INTO :v_records_read FROM STAGING.STG_CUSTOMER_CHANGES;

    IF (:v_records_read = 0) THEN
        UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
        SET batch_status = 'SUCCESS', batch_end_time = CURRENT_TIMESTAMP(), records_read = 0
        WHERE batch_id = :v_batch_id;
        RETURN 'No changes detected';
    END IF;

    -- Step 2: Expire old records where hash has changed
    UPDATE ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER_SCD2 tgt
    SET tgt.effective_to = src.updated_at,
        tgt.is_current = FALSE
    FROM STAGING.STG_CUSTOMER_CHANGES src
    WHERE tgt.customer_id = src.customer_id
        AND tgt.is_current = TRUE
        AND tgt.row_hash != src.row_hash;

    -- Count expired (updated) records
    SELECT COUNT(*) INTO :v_records_updated
    FROM ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER_SCD2
    WHERE is_current = FALSE AND etl_batch_id != :v_batch_id
        AND effective_to > DATEADD('MINUTE', -5, CURRENT_TIMESTAMP());

    -- Step 3: Insert new current records (new customers + changed customers)
    INSERT INTO ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER_SCD2 (
        customer_id, first_name, last_name, email, city, state, country,
        effective_from, is_current, row_hash, etl_batch_id
    )
    SELECT
        src.customer_id,
        src.first_name,
        src.last_name,
        src.email,
        src.city,
        src.state,
        src.country,
        src.updated_at,
        TRUE,
        src.row_hash,
        :v_batch_id
    FROM STAGING.STG_CUSTOMER_CHANGES src
    WHERE NOT EXISTS (
        SELECT 1 FROM ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER_SCD2 existing
        WHERE existing.customer_id = src.customer_id
            AND existing.is_current = TRUE
            AND existing.row_hash = src.row_hash
    );

    SELECT COUNT(*) INTO :v_records_inserted
    FROM ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER_SCD2
    WHERE etl_batch_id = :v_batch_id;

    -- Update batch log
    UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
    SET batch_status = 'SUCCESS',
        batch_end_time = CURRENT_TIMESTAMP(),
        records_read = :v_records_read,
        records_inserted = :v_records_inserted,
        records_updated = :v_records_updated
    WHERE batch_id = :v_batch_id;

    RETURN 'SCD2 Batch ' || :v_batch_id || '. Read: ' || :v_records_read ||
           ', New versions: ' || :v_records_inserted || ', Expired: ' || :v_records_updated;

EXCEPTION
    WHEN OTHER THEN
        UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
        SET batch_status = 'FAILED', batch_end_time = CURRENT_TIMESTAMP(), error_message = SQLERRM
        WHERE batch_id = :v_batch_id;
        RETURN 'FAILED: ' || SQLERRM;
END;

-- Run SCD2 load
CALL ECOMMERCE_DW.WAREHOUSE.LOAD_DIM_CUSTOMER_SCD2();

-- Query: Get customer state at a specific point in time
SELECT * FROM ECOMMERCE_DW.WAREHOUSE.DIM_CUSTOMER_SCD2
WHERE customer_id = 1
ORDER BY effective_from;


-- ============================================================
-- SECTION 8: DATA QUALITY CHECKS (PRE-LOAD VALIDATION)
-- ============================================================
/*
In production ETL, validate data BEFORE loading into target.
Common checks:
- NULL checks on required fields
- Referential integrity (FK exists in parent)
- Range validation (amounts > 0, dates not in future)
- Duplicate detection
- Format validation (email, phone patterns)
*/

CREATE OR REPLACE PROCEDURE ECOMMERCE_DW.STAGING.VALIDATE_ORDERS(p_batch_id INT, p_watermark TIMESTAMP)
RETURNS INT  -- Returns count of ERROR-severity records
LANGUAGE SQL
AS
DECLARE
    v_error_count INT DEFAULT 0;
BEGIN
    -- Rule 1: Order amount must be positive
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
        (batch_id, source_table, record_id, column_name, rule_name, rule_description, actual_value, severity)
    SELECT :p_batch_id, 'SRC_ORDERS', order_id::VARCHAR, 'TOTAL_AMOUNT',
           'POSITIVE_AMOUNT', 'Order total must be > 0', total_amount::VARCHAR, 'ERROR'
    FROM ECOMMERCE_DW.RAW.SRC_ORDERS
    WHERE updated_at > :p_watermark AND total_amount <= 0;

    -- Rule 2: Customer must exist
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
        (batch_id, source_table, record_id, column_name, rule_name, rule_description, actual_value, severity)
    SELECT :p_batch_id, 'SRC_ORDERS', o.order_id::VARCHAR, 'CUSTOMER_ID',
           'FK_CUSTOMER_EXISTS', 'Customer ID must exist in customers table', o.customer_id::VARCHAR, 'ERROR'
    FROM ECOMMERCE_DW.RAW.SRC_ORDERS o
    LEFT JOIN ECOMMERCE_DW.RAW.SRC_CUSTOMERS c ON o.customer_id = c.customer_id
    WHERE o.updated_at > :p_watermark AND c.customer_id IS NULL;

    -- Rule 3: Order date not in future
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
        (batch_id, source_table, record_id, column_name, rule_name, rule_description, actual_value, severity)
    SELECT :p_batch_id, 'SRC_ORDERS', order_id::VARCHAR, 'ORDER_DATE',
           'NO_FUTURE_DATE', 'Order date cannot be in the future', order_date::VARCHAR, 'WARNING'
    FROM ECOMMERCE_DW.RAW.SRC_ORDERS
    WHERE updated_at > :p_watermark AND order_date > CURRENT_TIMESTAMP();

    -- Rule 4: Duplicate order detection
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
        (batch_id, source_table, record_id, column_name, rule_name, rule_description, actual_value, severity)
    SELECT :p_batch_id, 'SRC_ORDERS', order_id::VARCHAR, 'ORDER_ID',
           'DUPLICATE_ORDER', 'Duplicate order_id detected', COUNT(*)::VARCHAR, 'ERROR'
    FROM ECOMMERCE_DW.RAW.SRC_ORDERS
    WHERE updated_at > :p_watermark
    GROUP BY order_id
    HAVING COUNT(*) > 1;

    -- Rule 5: Valid status values
    INSERT INTO ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
        (batch_id, source_table, record_id, column_name, rule_name, rule_description, actual_value, severity)
    SELECT :p_batch_id, 'SRC_ORDERS', order_id::VARCHAR, 'STATUS',
           'VALID_STATUS', 'Status must be one of: PENDING,SHIPPED,DELIVERED,CANCELLED,RETURNED', status, 'ERROR'
    FROM ECOMMERCE_DW.RAW.SRC_ORDERS
    WHERE updated_at > :p_watermark
        AND status NOT IN ('PENDING', 'SHIPPED', 'DELIVERED', 'CANCELLED', 'RETURNED');

    -- Count errors (not warnings)
    SELECT COUNT(*) INTO :v_error_count
    FROM ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
    WHERE batch_id = :p_batch_id AND severity = 'ERROR';

    RETURN :v_error_count;
END;


-- ============================================================
-- SECTION 9: FULL ETL ORCHESTRATION (MASTER PIPELINE)
-- ============================================================
/*
In production, a master procedure orchestrates all loads in order:
1. Dimensions first (customers, products)
2. Facts second (orders, order_items)
3. Aggregates last (daily summaries)
*/

CREATE OR REPLACE PROCEDURE ECOMMERCE_DW.WAREHOUSE.RUN_ETL_PIPELINE()
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_result VARCHAR;
    v_pipeline_status VARCHAR DEFAULT 'SUCCESS';
    v_pipeline_log VARCHAR DEFAULT '';
BEGIN
    -- Load Dimension: Customers
    BEGIN
        CALL ECOMMERCE_DW.WAREHOUSE.LOAD_DIM_CUSTOMER();
        v_pipeline_log := 'DIM_CUSTOMER: OK';
    EXCEPTION
        WHEN OTHER THEN
            v_pipeline_status := 'PARTIAL_FAILURE';
            v_pipeline_log := 'DIM_CUSTOMER: FAILED - ' || SQLERRM;
    END;

    -- Load Dimension: SCD2 Customers
    BEGIN
        CALL ECOMMERCE_DW.WAREHOUSE.LOAD_DIM_CUSTOMER_SCD2();
        v_pipeline_log := :v_pipeline_log || ' | DIM_CUSTOMER_SCD2: OK';
    EXCEPTION
        WHEN OTHER THEN
            v_pipeline_status := 'PARTIAL_FAILURE';
            v_pipeline_log := :v_pipeline_log || ' | DIM_CUSTOMER_SCD2: FAILED - ' || SQLERRM;
    END;

    -- Load Fact: Orders (stream-based)
    BEGIN
        CALL ECOMMERCE_DW.WAREHOUSE.LOAD_FACT_ORDERS_STREAM();
        v_pipeline_log := :v_pipeline_log || ' | FACT_ORDERS: OK';
    EXCEPTION
        WHEN OTHER THEN
            v_pipeline_status := 'PARTIAL_FAILURE';
            v_pipeline_log := :v_pipeline_log || ' | FACT_ORDERS: FAILED - ' || SQLERRM;
    END;

    RETURN :v_pipeline_status || ' :: ' || :v_pipeline_log;
END;

-- Run the full pipeline
CALL ECOMMERCE_DW.WAREHOUSE.RUN_ETL_PIPELINE();


-- ============================================================
-- SECTION 10: SCHEDULING WITH TASKS (AUTOMATED ETL)
-- ============================================================

-- Run ETL pipeline every hour
CREATE OR REPLACE TASK ECOMMERCE_DW.WAREHOUSE.TASK_HOURLY_ETL
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 0 * * * * Asia/Kolkata'  -- Every hour
AS
    CALL ECOMMERCE_DW.WAREHOUSE.RUN_ETL_PIPELINE();

-- Run a daily aggregation after the hourly loads
CREATE OR REPLACE TASK ECOMMERCE_DW.WAREHOUSE.TASK_DAILY_SUMMARY
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = 'USING CRON 30 6 * * * Asia/Kolkata'  -- 6:30 AM daily
AS
    INSERT INTO ECOMMERCE_DW.WAREHOUSE.DAILY_SALES_SUMMARY
    SELECT
        order_date,
        COUNT(DISTINCT order_id) AS total_orders,
        COUNT(DISTINCT customer_id) AS unique_customers,
        SUM(total_amount) AS gross_amount,
        SUM(discount_amount) AS total_discounts,
        SUM(net_amount) AS net_revenue
    FROM ECOMMERCE_DW.WAREHOUSE.FACT_ORDERS
    WHERE order_date = CURRENT_DATE() - 1
    GROUP BY order_date;

-- Enable tasks
ALTER TASK ECOMMERCE_DW.WAREHOUSE.TASK_HOURLY_ETL RESUME;
ALTER TASK ECOMMERCE_DW.WAREHOUSE.TASK_DAILY_SUMMARY RESUME;

-- Monitor task runs
SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    TASK_NAME => 'TASK_HOURLY_ETL',
    SCHEDULED_TIME_RANGE_START => DATEADD('DAY', -1, CURRENT_TIMESTAMP())
))
ORDER BY scheduled_time DESC;


-- ============================================================
-- SECTION 11: ERROR RECOVERY & REPROCESSING
-- ============================================================
/*
When a batch fails, you need to:
1. Identify what failed
2. Fix the root cause
3. Reprocess ONLY the failed batch (not everything)
*/

-- Find failed batches
SELECT * FROM ECOMMERCE_DW.AUDIT.V_ETL_RUN_SUMMARY
WHERE batch_status = 'FAILED'
ORDER BY batch_start_time DESC;

-- Reprocess procedure: Reset watermark to failed batch's watermark
CREATE OR REPLACE PROCEDURE ECOMMERCE_DW.AUDIT.REPROCESS_BATCH(p_batch_id INT)
RETURNS VARCHAR
LANGUAGE SQL
AS
DECLARE
    v_table_name VARCHAR;
    v_watermark TIMESTAMP;
BEGIN
    -- Get the watermark that the failed batch started with
    SELECT source_table, watermark_value INTO :v_table_name, :v_watermark
    FROM ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
    WHERE batch_id = :p_batch_id;

    IF (:v_watermark IS NULL) THEN
        RETURN 'Batch ' || :p_batch_id || ' has no watermark to reset';
    END IF;

    -- Reset watermark to before the failed batch
    UPDATE ECOMMERCE_DW.AUDIT.ETL_WATERMARKS
    SET last_extracted_at = :v_watermark,
        updated_at = CURRENT_TIMESTAMP()
    WHERE table_name = REPLACE(:v_table_name, 'RAW.', '');

    -- Mark old batch as reprocessed
    UPDATE ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
    SET batch_status = 'REPROCESSING'
    WHERE batch_id = :p_batch_id;

    RETURN 'Watermark reset for ' || :v_table_name || ' to ' || :v_watermark ||
           '. Run the load procedure again to reprocess.';
END;

-- Example: Reprocess batch 5
-- CALL ECOMMERCE_DW.AUDIT.REPROCESS_BATCH(5);


-- ============================================================
-- SECTION 12: ETL AUDIT REPORTING QUERIES
-- ============================================================

-- 12A: Pipeline health dashboard
SELECT
    DATE_TRUNC('DAY', batch_start_time) AS run_date,
    batch_name,
    COUNT(*) AS total_runs,
    SUM(CASE WHEN batch_status = 'SUCCESS' THEN 1 ELSE 0 END) AS success_count,
    SUM(CASE WHEN batch_status = 'FAILED' THEN 1 ELSE 0 END) AS failure_count,
    ROUND(SUM(CASE WHEN batch_status = 'SUCCESS' THEN 1 ELSE 0 END)::FLOAT /
          NULLIF(COUNT(*), 0) * 100, 2) AS success_rate_pct,
    SUM(records_inserted) AS total_inserted,
    SUM(records_updated) AS total_updated,
    SUM(records_rejected) AS total_rejected,
    AVG(DATEDIFF('SECOND', batch_start_time, batch_end_time)) AS avg_duration_sec
FROM ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
WHERE batch_start_time >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY run_date, batch_name
ORDER BY run_date DESC, batch_name;

-- 12B: Data quality summary
SELECT
    source_table,
    rule_name,
    severity,
    COUNT(*) AS violation_count,
    MIN(logged_at) AS first_seen,
    MAX(logged_at) AS last_seen
FROM ECOMMERCE_DW.AUDIT.ETL_DATA_QUALITY_LOG
WHERE logged_at >= DATEADD('DAY', -7, CURRENT_TIMESTAMP())
GROUP BY source_table, rule_name, severity
ORDER BY severity DESC, violation_count DESC;

-- 12C: Data freshness check (is data up to date?)
SELECT
    w.table_name,
    w.last_extracted_at,
    DATEDIFF('MINUTE', w.last_extracted_at, CURRENT_TIMESTAMP()) AS minutes_since_last_load,
    w.last_batch_id,
    b.batch_status AS last_batch_status,
    CASE
        WHEN DATEDIFF('MINUTE', w.last_extracted_at, CURRENT_TIMESTAMP()) > 120 THEN 'STALE'
        WHEN DATEDIFF('MINUTE', w.last_extracted_at, CURRENT_TIMESTAMP()) > 60 THEN 'WARNING'
        ELSE 'FRESH'
    END AS freshness_status
FROM ECOMMERCE_DW.AUDIT.ETL_WATERMARKS w
LEFT JOIN ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG b ON w.last_batch_id = b.batch_id;

-- 12D: Volume trend (detect unexpected drops or spikes)
SELECT
    batch_name,
    DATE_TRUNC('DAY', batch_start_time) AS load_date,
    SUM(records_read) AS daily_volume,
    LAG(SUM(records_read)) OVER (PARTITION BY batch_name ORDER BY DATE_TRUNC('DAY', batch_start_time)) AS prev_day_volume,
    ROUND(
        (SUM(records_read) - LAG(SUM(records_read)) OVER (
            PARTITION BY batch_name ORDER BY DATE_TRUNC('DAY', batch_start_time)
        )) / NULLIF(LAG(SUM(records_read)) OVER (
            PARTITION BY batch_name ORDER BY DATE_TRUNC('DAY', batch_start_time)
        ), 0) * 100, 2
    ) AS volume_change_pct,
    CASE
        WHEN SUM(records_read) = 0 THEN 'NO_DATA'
        WHEN SUM(records_read) > LAG(SUM(records_read)) OVER (
            PARTITION BY batch_name ORDER BY DATE_TRUNC('DAY', batch_start_time)
        ) * 3 THEN 'SPIKE'
        WHEN SUM(records_read) < LAG(SUM(records_read)) OVER (
            PARTITION BY batch_name ORDER BY DATE_TRUNC('DAY', batch_start_time)
        ) * 0.3 THEN 'DROP'
        ELSE 'NORMAL'
    END AS volume_status
FROM ECOMMERCE_DW.AUDIT.ETL_BATCH_LOG
WHERE batch_status = 'SUCCESS'
    AND batch_start_time >= DATEADD('DAY', -14, CURRENT_TIMESTAMP())
GROUP BY batch_name, load_date
ORDER BY batch_name, load_date DESC;


-- ============================================================
-- SECTION 13: INCREMENTAL LOAD PATTERNS COMPARISON
-- ============================================================
/*
┌────────────────────────────────────────────────────────────────────────┐
│ PATTERN            │ PROS                      │ CONS                  │
├────────────────────────────────────────────────────────────────────────┤
│ Timestamp          │ Simple to implement       │ Can't detect deletes  │
│ Watermark          │ Works with any source     │ Needs reliable        │
│                    │ Low overhead              │ updated_at column     │
├────────────────────────────────────────────────────────────────────────┤
│ Snowflake          │ Captures all changes      │ Snowflake-specific    │
│ Streams (CDC)      │ Including deletes         │ Stream expires if     │
│                    │ No missed records         │ not consumed (14d)    │
│                    │ Built-in, no extra tools  │                       │
├────────────────────────────────────────────────────────────────────────┤
│ ID-based           │ Very simple               │ Only for append-only  │
│ (max ID)           │ No timestamp needed       │ Can't detect updates  │
├────────────────────────────────────────────────────────────────────────┤
│ Hash-based         │ Detects any change        │ Must scan all rows    │
│ (full compare)     │ No source requirements    │ Expensive for large   │
│                    │                           │ tables                │
├────────────────────────────────────────────────────────────────────────┤
│ Full Load +        │ Simplest logic            │ Expensive for large   │
│ MERGE              │ Always correct            │ tables (reads all)    │
│                    │ Handles all scenarios     │ High warehouse cost   │
└────────────────────────────────────────────────────────────────────────┘

RECOMMENDATION BY TABLE SIZE:
- Small (< 1M rows): Full load + MERGE (simplicity wins)
- Medium (1M - 100M): Timestamp watermark or Streams
- Large (100M+): Streams (most efficient, guaranteed complete)
- External sources: Timestamp watermark (streams not available)
*/


-- ============================================================
-- SECTION 14: PRODUCTION BEST PRACTICES
-- ============================================================
/*
1. ALWAYS LOG EVERYTHING
   - Every batch: start time, end time, record counts, status
   - Every error: which record, which column, what rule failed
   - Every watermark change: before and after values

2. IDEMPOTENT LOADS
   - Running the same batch twice should produce the same result
   - Use MERGE (not INSERT) so re-runs don't create duplicates
   - Store watermark AFTER successful commit, not before

3. FAIL FAST, RECOVER FAST
   - Validate data before loading (reject bad records early)
   - Keep failed batch info for reprocessing
   - Don't let one bad record kill the entire batch

4. MONITOR FRESHNESS
   - Alert if data is stale (hasn't loaded in expected window)
   - Track volume trends (sudden drops = broken source)

5. SEPARATE CONCERNS
   - Extract → Raw (copy as-is)
   - Transform → Staging (clean, validate)
   - Load → Warehouse (final, trusted)

6. HANDLE LATE-ARRIVING DATA
   - Use TIMESTAMP watermark with small overlap (e.g., -5 minutes)
   - Or use Streams (guaranteed no missed data)

7. CLUSTER TARGET TABLES
   - Cluster fact tables by date column
   - Enables pruning for downstream queries

8. TEST WITH PRODUCTION VOLUMES
   - What works for 1000 rows may fail at 100M rows
   - Test MERGE performance at scale
   - Monitor for spilling during ETL loads
*/
