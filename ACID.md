# ACID Properties in Data Engineering

> The 4 guarantees every Data Engineer must understand — with real-world examples using **Snowflake Hybrid Tables** and **Iceberg Tables**

---

## Why ACID Matters

When your data pipeline fails mid-run — a crash, timeout, or bad record — **ACID** determines whether your data ends up **correct, corrupt, or missing**. Master these 4 properties and you'll design patterns that are bulletproof.

| Property | One-Liner |
|---|---|
| **A**tomicity | All or Nothing |
| **C**onsistency | Always Valid State |
| **I**solation | No Dirty Reads |
| **D**urability | Survives Any Crash |

---

## Table Types We'll Use

### Hybrid Tables (Snowflake)
- Row-oriented storage with **row-level locking**
- **Enforced** PRIMARY KEY, FOREIGN KEY, UNIQUE constraints
- Designed for transactional (OLTP) workloads inside Snowflake
- Supports up to ~16,000 ops/sec per database

### Iceberg Tables (Snowflake-managed)
- Open table format (Apache Iceberg) managed by Snowflake
- ACID-compliant writes via **snapshot isolation**
- Columnar storage (Parquet) with metadata-driven transactions
- Best for analytical/lakehouse workloads

---

## Setup: Create Database and Schema

```sql
-- Create a dedicated database and schema for our ACID demos
CREATE OR REPLACE DATABASE ACID_DEMO_DB;
CREATE OR REPLACE SCHEMA ACID_DEMO_DB.ACID_SCHEMA;
USE DATABASE ACID_DEMO_DB;
USE SCHEMA ACID_SCHEMA;
```

---

# A — ATOMICITY (All or Nothing)

> A transaction is treated as a single unit. Either ALL operations succeed, or NONE of them apply. No half-done work.

### Real-World: UPI Bank Transfer
You transfer ₹10,000 from Account A to Account B. If the system crashes after debiting A but before crediting B — atomicity ensures the **entire transaction rolls back**. Your ₹10,000 is safe.

---

### Hybrid Table Demo: Bank Transfer

```sql
-- Step 1: Create accounts table (Hybrid = enforced constraints + row-level locking)
CREATE OR REPLACE HYBRID TABLE bank_accounts (
    account_id INT PRIMARY KEY,
    account_holder VARCHAR(100) NOT NULL,
    balance DECIMAL(15,2) NOT NULL,
    last_updated TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- Step 2: Insert initial data
INSERT INTO bank_accounts VALUES
    (1, 'Rohit Sharma', 50000.00, CURRENT_TIMESTAMP()),
    (2, 'Virat Kohli', 30000.00, CURRENT_TIMESTAMP());

-- Step 3: Check balances before transfer
SELECT * FROM bank_accounts;
-- account_id | account_holder | balance   |
-- 1          | Rohit Sharma   | 50000.00  |
-- 2          | Virat Kohli    | 30000.00  |
```

#### Successful Atomic Transaction

```sql
-- Both operations succeed = both are committed
BEGIN TRANSACTION;

    UPDATE bank_accounts
    SET balance = balance - 10000, last_updated = CURRENT_TIMESTAMP()
    WHERE account_id = 1;

    UPDATE bank_accounts
    SET balance = balance + 10000, last_updated = CURRENT_TIMESTAMP()
    WHERE account_id = 2;

COMMIT;

-- Verify: Total money in system is still 80,000
SELECT * FROM bank_accounts;
-- account_id | account_holder | balance   |
-- 1          | Rohit Sharma   | 40000.00  |
-- 2          | Virat Kohli    | 40000.00  |

SELECT SUM(balance) AS total_money FROM bank_accounts;
-- total_money = 80000.00 (unchanged — atomicity preserved)
```

#### Failed Transaction = Full Rollback

```sql
-- Simulate a failure: debit succeeds, but we rollback before credit
BEGIN TRANSACTION;

    UPDATE bank_accounts
    SET balance = balance - 5000, last_updated = CURRENT_TIMESTAMP()
    WHERE account_id = 1;

    -- Something goes wrong... rollback everything
    ROLLBACK;

-- Verify: Nothing changed
SELECT * FROM bank_accounts;
-- account_id | account_holder | balance   |
-- 1          | Rohit Sharma   | 40000.00  | (unchanged!)
-- 2          | Virat Kohli    | 40000.00  | (unchanged!)
```

**Key Point:** Hybrid tables give you real transactional atomicity with row-level locking — just like PostgreSQL or MySQL.

---

### Iceberg Table Demo: Data Pipeline Atomicity

Iceberg tables achieve atomicity through **snapshot-based commits**. Each write creates a new snapshot — either the entire snapshot is committed or nothing changes.

```sql
-- Step 1: Create an Iceberg table (Snowflake-managed)
CREATE OR REPLACE ICEBERG TABLE pipeline_events (
    event_id INT,
    event_type VARCHAR(50),
    payload VARCHAR(500),
    event_timestamp TIMESTAMP_NTZ,
    batch_id VARCHAR(50)
)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'my_external_volume'       -- replace with your external volume
    BASE_LOCATION = 'acid_demo/pipeline_events';

-- Step 2: Atomic batch insert — all rows land or none do
BEGIN TRANSACTION;

    INSERT INTO pipeline_events VALUES
        (1, 'page_view',  '{"page": "/home"}',     '2026-05-01 10:00:00', 'batch_001'),
        (2, 'click',      '{"button": "signup"}',   '2026-05-01 10:01:00', 'batch_001'),
        (3, 'purchase',   '{"item": "laptop"}',     '2026-05-01 10:02:00', 'batch_001'),
        (4, 'page_view',  '{"page": "/checkout"}',  '2026-05-01 10:03:00', 'batch_001');

COMMIT;

-- Step 3: Verify all 4 events landed atomically
SELECT * FROM pipeline_events WHERE batch_id = 'batch_001';
-- All 4 rows present — the snapshot was committed as one unit

-- Step 4: Failed batch = no partial data
BEGIN TRANSACTION;

    INSERT INTO pipeline_events VALUES
        (5, 'page_view', '{"page": "/about"}', '2026-05-01 11:00:00', 'batch_002');

    -- Simulating pipeline failure
    ROLLBACK;

-- Verify: batch_002 never appeared
SELECT * FROM pipeline_events WHERE batch_id = 'batch_002';
-- 0 rows returned — atomicity preserved via snapshot isolation
```

**Key Point:** Iceberg achieves atomicity by writing new data files and only committing a new metadata snapshot pointer if all writes succeed. Failed writes leave zero trace.

---

# C — CONSISTENCY (Always Valid State)

> Before and after every transaction, data must follow ALL defined rules and constraints. A transaction that violates rules is simply rejected.

### Real-World: Flight Booking
A flight has 200 seats. 199 people book successfully. The 201st request is **rejected** — the system never allows overbooking beyond the defined limit.

---

### Hybrid Table Demo: Enforced Constraints

Hybrid tables **enforce** PRIMARY KEY, UNIQUE, FOREIGN KEY, and NOT NULL constraints — unlike standard Snowflake tables where these are informational only.

```sql
-- Step 1: Create a customers table with enforced constraints
CREATE OR REPLACE HYBRID TABLE customers (
    customer_id INT PRIMARY KEY,
    email VARCHAR(255) UNIQUE,
    full_name VARCHAR(200) NOT NULL,
    credit_limit DECIMAL(10,2) NOT NULL,
    INDEX idx_email (email)
);

-- Step 2: Insert valid data
INSERT INTO customers VALUES (1, 'rohit@example.com', 'Rohit Sharma', 100000.00);
INSERT INTO customers VALUES (2, 'virat@example.com', 'Virat Kohli', 150000.00);
```

#### PRIMARY KEY Violation (Enforced!)

```sql
-- Try inserting duplicate primary key
INSERT INTO customers VALUES (1, 'new@example.com', 'Duplicate', 50000.00);
-- ERROR: Primary key already exists
-- Consistency maintained: no duplicate customer IDs
```

#### UNIQUE Constraint Violation (Enforced!)

```sql
-- Try inserting duplicate email
INSERT INTO customers VALUES (3, 'rohit@example.com', 'Another Rohit', 75000.00);
-- ERROR: Duplicate key value violates unique constraint "SYS_INDEX_CUSTOMERS_UNIQUE_EMAIL"
-- Consistency maintained: no duplicate emails
```

#### FOREIGN KEY Enforcement (Referential Integrity)

```sql
-- Create orders table with FK to customers
CREATE OR REPLACE HYBRID TABLE orders (
    order_id INT PRIMARY KEY AUTOINCREMENT,
    customer_id INT NOT NULL,
    product_name VARCHAR(200),
    amount DECIMAL(10,2),
    order_date TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Valid order (customer_id=1 exists)
INSERT INTO orders (customer_id, product_name, amount)
VALUES (1, 'MacBook Pro', 199999.00);
-- Success!

-- Invalid order (customer_id=999 does NOT exist)
INSERT INTO orders (customer_id, product_name, amount)
VALUES (999, 'Ghost Order', 50000.00);
-- ERROR: Foreign key constraint violated
-- Consistency maintained: no orphan orders

-- Try inserting NULL into FK column
INSERT INTO orders (customer_id, product_name, amount)
VALUES (NULL, 'Null Order', 10000.00);
-- ERROR: Foreign key constraint violated (NULLs not allowed in FK)
```

#### NOT NULL Enforcement

```sql
-- Try inserting a customer without a name
INSERT INTO customers VALUES (4, 'noname@example.com', NULL, 50000.00);
-- ERROR: NULL result in a non-nullable column
-- Consistency maintained: every customer must have a name
```

---

### Iceberg Table Demo: Schema Enforcement

Iceberg tables enforce consistency through **schema enforcement** — the schema is embedded in metadata, so malformed data is rejected at write time.

```sql
-- Step 1: Create a strongly-typed Iceberg table
CREATE OR REPLACE ICEBERG TABLE product_inventory (
    product_id INT NOT NULL,
    product_name VARCHAR(200) NOT NULL,
    quantity INT NOT NULL,
    price DECIMAL(10,2) NOT NULL,
    warehouse_code VARCHAR(10) NOT NULL,
    last_restocked TIMESTAMP_NTZ
)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'my_external_volume'
    BASE_LOCATION = 'acid_demo/product_inventory';

-- Step 2: Valid insert
INSERT INTO product_inventory VALUES
    (101, 'Wireless Mouse', 500, 1299.00, 'WH-MUM', '2026-04-01 08:00:00'),
    (102, 'USB-C Hub', 300, 2499.00, 'WH-DEL', '2026-04-15 10:00:00');

-- Step 3: Schema enforcement
-- Try inserting a string where INT is expected
-- INSERT INTO product_inventory VALUES ('abc', 'Bad Product', 100, 999.00, 'WH-BLR', NULL);
-- ERROR: Numeric value 'abc' is not recognized
-- The Iceberg schema rejects type mismatches at write time

-- Step 4: NOT NULL enforcement
-- INSERT INTO product_inventory VALUES (103, NULL, 100, 999.00, 'WH-BLR', NULL);
-- ERROR: NULL result in a non-nullable column
```

**Key Point:** Hybrid tables enforce constraints at the database engine level (PK, FK, UNIQUE, NOT NULL). Iceberg tables enforce consistency through schema validation on every write. Both ensure your data is **always in a valid state**.

---

# I — ISOLATION (No Dirty Reads)

> Concurrent transactions don't see each other's uncommitted work. One transaction's intermediate data is invisible to others until fully committed.

### Real-World: Shared Excel File
Person A updates Q2 figures. Person B queries the spreadsheet at the same time. With isolation, B sees either the **old complete data** or the **new complete data** — never a half-updated mix.

---

### Hybrid Table Demo: Row-Level Locking

Hybrid tables use **row-level locking**, meaning two transactions can modify different rows simultaneously without blocking each other.

```sql
-- Setup: Reset balances
UPDATE bank_accounts SET balance = 50000.00 WHERE account_id = 1;
UPDATE bank_accounts SET balance = 30000.00 WHERE account_id = 2;

-- SESSION 1: Start a transaction (but don't commit yet)
-- BEGIN TRANSACTION;
-- UPDATE bank_accounts SET balance = balance - 20000 WHERE account_id = 1;
-- (Transaction is still open — not committed)

-- SESSION 2: Query the same table at the same time
-- SELECT * FROM bank_accounts WHERE account_id = 1;
-- Result: balance = 50000.00 (sees the OLD value, not the uncommitted -20000)

-- SESSION 1: Now commit
-- COMMIT;

-- SESSION 2: Query again
-- SELECT * FROM bank_accounts WHERE account_id = 1;
-- Result: balance = 30000.00 (now sees the committed change)
```

#### Demonstrating Non-Blocking Concurrent Writes

```sql
-- Hybrid tables allow concurrent writes to DIFFERENT rows without blocking
-- Session 1: UPDATE bank_accounts SET balance = 45000 WHERE account_id = 1;
-- Session 2: UPDATE bank_accounts SET balance = 35000 WHERE account_id = 2;
-- Both succeed simultaneously — row-level locking means no contention

-- Standard Snowflake tables would use partition/table-level locking
-- which blocks the entire table during writes
```

---

### Iceberg Table Demo: Snapshot Isolation

Iceberg provides isolation through **snapshots**. Each reader sees a consistent point-in-time snapshot, even while writers are adding new data.

```sql
-- Step 1: Insert initial data
INSERT INTO pipeline_events VALUES
    (10, 'login', '{"user": "alice"}', '2026-05-02 09:00:00', 'batch_010');

-- Step 2: Understand snapshot isolation
-- At this point, a snapshot S1 exists with all current data.

-- Writer starts adding new batch (creates new data files)
INSERT INTO pipeline_events VALUES
    (11, 'search', '{"query": "laptop"}', '2026-05-02 09:05:00', 'batch_011'),
    (12, 'add_to_cart', '{"item": "laptop"}', '2026-05-02 09:06:00', 'batch_011');

-- After commit, a new snapshot S2 is created.
-- Any reader who started before the commit still sees S1 (old data).
-- Any reader who starts after the commit sees S2 (new data).
-- No reader ever sees partially written batch_011.

-- Step 3: Verify snapshot history (Iceberg metadata)
SELECT *
FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS('pipeline_events'))
ORDER BY committed_at DESC
LIMIT 5;
```

#### Why Snapshot Isolation Matters for Pipelines

```sql
-- Scenario: Dashboard query runs while ETL is loading new data
--
-- Traditional tables: Dashboard might see partial ETL results (dirty read)
-- Iceberg tables: Dashboard sees the last COMPLETE snapshot
--                  ETL's new data only appears after full commit
--
-- This is why Iceberg is the standard for lakehouse architectures:
-- Readers NEVER see incomplete writes.
```

**Key Point:** Hybrid tables isolate via row-level locking (great for concurrent OLTP). Iceberg tables isolate via snapshot versioning (great for concurrent analytics + ETL).

---

# D — DURABILITY (Survives Any Crash)

> Once a transaction is committed, the data is permanently saved. Power failure, server crash, network outage — nothing can undo a committed transaction.

### Real-World: ATM Withdrawal
You withdraw ₹5,000 from an ATM. The receipt prints. Even if the ATM crashes 1 second later — your bank's ledger **permanently** reflects the withdrawal. COMMIT = permanent.

---

### Hybrid Table Demo: Write-Ahead Logging

Hybrid tables achieve durability through the underlying row-store engine which uses **write-ahead logging (WAL)** — data is written to a durable log before being acknowledged.

```sql
-- Step 1: Create an audit log table
CREATE OR REPLACE HYBRID TABLE audit_log (
    log_id INT PRIMARY KEY AUTOINCREMENT,
    action VARCHAR(50) NOT NULL,
    entity VARCHAR(100),
    details VARCHAR(500),
    performed_by VARCHAR(100),
    performed_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    INDEX idx_performed_at (performed_at)
);

-- Step 2: Insert critical audit records
BEGIN TRANSACTION;

    INSERT INTO audit_log (action, entity, details, performed_by)
    VALUES ('DELETE', 'customer:1001', 'GDPR data deletion request', 'system_admin');

    INSERT INTO audit_log (action, entity, details, performed_by)
    VALUES ('EXPORT', 'report:quarterly', 'Q1 2026 financial report exported', 'cfo_user');

COMMIT;
-- At this point, these records are PERMANENTLY stored.
-- Even if the warehouse crashes right now, the data survives.

-- Step 3: Verify durability
SELECT * FROM audit_log ORDER BY performed_at DESC;
-- Both records are guaranteed to be present after COMMIT
```

#### Hybrid Table Dual Storage = Extra Durability

```sql
-- Hybrid tables store data in TWO places:
-- 1. Row store (primary) — for fast transactional access
-- 2. Object storage (async copy) — for analytical queries and backup
--
-- This dual-write architecture means:
-- - Row store handles immediate reads/writes
-- - Object storage provides an additional durability layer
-- - Even if one layer has issues, data is recoverable

-- You can see this in action:
SHOW HYBRID TABLES LIKE 'audit_log';
-- The 'bytes' column shows the object storage footprint
```

---

### Iceberg Table Demo: Immutable File Architecture

Iceberg achieves durability through **immutable data files + metadata snapshots** stored in cloud object storage (S3/Azure Blob/GCS). Once written, files are never modified — only new files are added.

```sql
-- Step 1: Create a durable event store
CREATE OR REPLACE ICEBERG TABLE payment_transactions (
    txn_id VARCHAR(50) NOT NULL,
    customer_id INT NOT NULL,
    amount DECIMAL(12,2) NOT NULL,
    currency VARCHAR(3) NOT NULL,
    status VARCHAR(20) NOT NULL,
    created_at TIMESTAMP_NTZ NOT NULL
)
    CATALOG = 'SNOWFLAKE'
    EXTERNAL_VOLUME = 'my_external_volume'
    BASE_LOCATION = 'acid_demo/payment_transactions';

-- Step 2: Commit payment records
INSERT INTO payment_transactions VALUES
    ('TXN-001', 1, 15000.00, 'INR', 'COMPLETED', '2026-05-01 14:30:00'),
    ('TXN-002', 2, 25000.00, 'INR', 'COMPLETED', '2026-05-01 14:35:00'),
    ('TXN-003', 1,  5000.00, 'INR', 'COMPLETED', '2026-05-01 14:40:00');

-- After COMMIT, Iceberg has written:
-- 1. New Parquet data files (immutable, never modified)
-- 2. New manifest files (list of data files in this snapshot)
-- 3. New metadata file (points to current snapshot)
-- 4. Updated metadata pointer (atomic swap)

-- Step 3: Verify the durability chain
-- Each snapshot is a permanent, immutable record
SELECT *
FROM TABLE(INFORMATION_SCHEMA.ICEBERG_TABLE_SNAPSHOTS('payment_transactions'))
ORDER BY committed_at DESC;
```

#### Time Travel = Proof of Durability

```sql
-- Iceberg's immutable architecture enables time travel
-- Even after new writes, old snapshots still exist on disk

-- Add more transactions
INSERT INTO payment_transactions VALUES
    ('TXN-004', 2, 100000.00, 'INR', 'COMPLETED', '2026-05-02 10:00:00');

-- Query the table as of yesterday (before TXN-004)
SELECT * FROM payment_transactions
AT(TIMESTAMP => '2026-05-01 23:59:59'::TIMESTAMP_NTZ);
-- Returns only TXN-001, TXN-002, TXN-003
-- TXN-004 doesn't exist in that snapshot — but the old data is STILL THERE

-- Current state includes all 4
SELECT * FROM payment_transactions;
-- Returns TXN-001 through TXN-004

-- This is durability in action:
-- Old data files are NEVER deleted (until explicitly expired)
-- Every committed snapshot is permanently accessible
```

**Key Point:** Hybrid tables achieve durability via WAL + dual storage (row store + object storage). Iceberg achieves durability via immutable Parquet files + metadata snapshots in cloud object storage. Both guarantee: **COMMIT = permanent**.

---

# Side-by-Side Comparison

| ACID Property | Hybrid Table Mechanism | Iceberg Table Mechanism |
|---|---|---|
| **Atomicity** | Transaction with BEGIN/COMMIT/ROLLBACK, row-level | Snapshot-based atomic commits |
| **Consistency** | Enforced PK, FK, UNIQUE, NOT NULL constraints | Schema enforcement on write |
| **Isolation** | Row-level locking, high concurrency | Snapshot isolation (MVCC-style) |
| **Durability** | WAL + row store + async object storage copy | Immutable Parquet files + metadata snapshots |

---

# When to Use Which?

| Scenario | Use Hybrid Table | Use Iceberg Table |
|---|---|---|
| Low-latency point lookups (by ID) | Yes | No |
| High-concurrency single-row updates | Yes | No |
| Enforced referential integrity (FK) | Yes | No |
| Large analytical scans/aggregations | No | Yes |
| Data lake / open format interop | No | Yes |
| Concurrent ETL + analytics reads | No | Yes |
| Time travel over large datasets | Limited | Excellent |
| Cross-engine compatibility (Spark, etc.) | No | Yes |

---

# Cleanup

```sql
-- Drop all demo objects
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;
DROP TABLE IF EXISTS bank_accounts;
DROP TABLE IF EXISTS audit_log;
DROP TABLE IF EXISTS pipeline_events;
DROP TABLE IF EXISTS product_inventory;
DROP TABLE IF EXISTS payment_transactions;
DROP DATABASE IF EXISTS ACID_DEMO_DB;
```

---

# Summary

| Property | Guarantee | If Violated |
|---|---|---|
| **Atomicity** | All or nothing | Partial writes corrupt data |
| **Consistency** | Rules always hold | Invalid data enters the system |
| **Isolation** | No interference | Dirty reads, phantom reads |
| **Durability** | Committed = permanent | Data loss after crash |

> **Bottom Line:** Standard Snowflake tables don't enforce PK/FK/UNIQUE constraints — they're informational only. If you need **real ACID guarantees** in Snowflake, use **Hybrid Tables** (for OLTP) or **Iceberg Tables** (for lakehouse analytics). Both give you true ACID compliance with different performance tradeoffs.
