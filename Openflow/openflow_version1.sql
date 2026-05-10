-- ============================================================================
-- SNOWFLAKE OPENFLOW - COMPLETE GUIDE
-- From Basics to Implementation (Written for Non-Snowflake Users)
-- ============================================================================

-- ============================================================================
-- SECTION 1: WHAT IS OPENFLOW?
-- ============================================================================

/*
WHAT IS OPENFLOW?
=================
Openflow is Snowflake's fully managed data integration service.
Think of it as a "data pipeline builder" that moves data from any source
(databases, APIs, files, streaming systems) into Snowflake or between systems.

SIMPLE ANALOGY:
- Imagine a postal service that picks up packages (data) from any address (source)
  and delivers them to your house (Snowflake). Openflow IS that postal service.
  It knows how to pick up from hundreds of different places and deliver reliably.

WHAT DOES OPENFLOW DO?
======================
1. Connects to data sources (SQL Server, MySQL, Kafka, Google Drive, etc.)
2. Extracts data (structured tables, unstructured files, streaming events)
3. Transforms data if needed (filtering, routing, formatting)
4. Loads data into Snowflake (or other destinations)
5. Handles errors, retries, and monitoring automatically

WHY DO WE NEED OPENFLOW?
=========================
Problem without Openflow:
- You write custom scripts to move data
- Scripts break when sources change
- No monitoring, no retry logic
- Hard to scale, hard to maintain
- Security is your headache

With Openflow:
- Pre-built connectors for 25+ sources
- Automatic error handling and retries
- Built-in security (encryption, authentication)
- Scales from small to massive data volumes
- Visual interface to design data flows
- Snowflake manages the infrastructure

KEY FEATURES:
=============
1. 25+ Pre-built Connectors (SQL Server, MySQL, PostgreSQL, Kafka, Salesforce, etc.)
2. Visual Canvas (drag-and-drop pipeline design)
3. Both Batch and Streaming (handle any speed of data)
4. Structured + Unstructured data (tables, PDFs, images, audio, video)
5. CDC (Change Data Capture) - track and replicate data changes
6. Auto-scaling (1 to 50 nodes based on load)
7. Enterprise Security (TLS, private link, secrets management)
8. AI-ready (ingest data for Snowflake Cortex AI processing)

PROS:
=====
+ Fully managed - no infrastructure to maintain
+ Open-source based (Apache NiFi) - no vendor lock-in on logic
+ Hundreds of processors for any data transformation
+ Visual UI for non-coders
+ Handles structured AND unstructured data
+ Built-in CDC for database replication
+ Scales automatically
+ Native Snowflake security integration
+ Supports batch and real-time streaming

CONS:
=====
- Only available in AWS and Azure commercial regions currently
- BYOC only in AWS commercial regions
- Requires understanding of NiFi concepts for advanced use
- Connector-specific limitations (e.g., SQL Server needs primary keys)
- Cost depends on runtime uptime and compute usage
- Multi-node not supported for some connectors
*/


-- ============================================================================
-- SECTION 2: WHAT IS APACHE NIFI? HOW IS IT RELATED TO OPENFLOW?
-- ============================================================================

/*
WHAT IS APACHE NIFI?
====================
Apache NiFi is an open-source software project by the Apache Foundation.
It was originally built by the US National Security Agency (NSA) for
moving data between systems reliably.

SIMPLE ANALOGY:
- NiFi is like a factory assembly line for data.
  Data enters on one side, gets processed step by step, and exits the other side.
  Each "station" on the line does one specific job (read, filter, transform, write).

KEY NIFI CONCEPTS:
- FlowFile: A piece of data moving through the system (like a package on a conveyor belt)
- Processor: A worker that does one job (read from database, convert format, write to file)
- Connection: The conveyor belt between workers
- Process Group: A section of the factory doing related work

HOW IS NIFI RELATED TO OPENFLOW?
=================================
Openflow IS Apache NiFi, but managed by Snowflake.

Think of it this way:
- Apache NiFi = the engine (open source, anyone can use it)
- Openflow = a car built with that engine (Snowflake packages it, manages it, adds features)

What Snowflake adds on top of NiFi:
1. You don't install or maintain NiFi yourself
2. Snowflake handles upgrades, security patches
3. Native integration with Snowflake authentication
4. Pre-built connectors optimized for Snowflake
5. Auto-scaling and monitoring built in
6. Runs inside your VPC or Snowflake's infrastructure

So if you know Apache NiFi, you already know 90% of Openflow.
The processors, canvas, and flow concepts are identical.
*/


-- ============================================================================
-- SECTION 3: WHAT IS A DEPLOYMENT?
-- ============================================================================

/*
WHAT IS A DEPLOYMENT?
=====================
A deployment is the "environment" where your data pipelines run.
Think of it as a dedicated workspace/server that hosts your data flows.

SIMPLE ANALOGY:
- A deployment is like renting an office building.
  Inside that building, you have multiple rooms (runtimes) where
  different teams (data flows) work.

HOW MANY TYPES DOES SNOWFLAKE SUPPORT?
=======================================

TYPE 1: OPENFLOW - SNOWFLAKE DEPLOYMENT (SPCS)
-----------------------------------------------
- Runs INSIDE Snowflake's own infrastructure (Snowpark Container Services)
- Snowflake manages everything
- Easiest to set up and manage
- Native security integration
- Available in AWS and Azure commercial regions
- Cost: based on compute pool uptime and usage
- Best for: Teams that want simplicity and don't need data to stay in their VPC

TYPE 2: OPENFLOW - BYOC (Bring Your Own Cloud)
-----------------------------------------------
- Runs INSIDE YOUR OWN AWS account (your VPC)
- You own the infrastructure, Snowflake manages the software
- Data never leaves your network
- Available in AWS commercial regions only
- Cost: based on your AWS compute, storage, and infrastructure
- Best for: Teams with strict data residency or compliance requirements

KEY DIFFERENCE:
- Snowflake Deployment = Snowflake hosts it (simpler, less control)
- BYOC = You host it (more complex, full control over network and data)
*/


-- ============================================================================
-- SECTION 4: WHAT ARE CONNECTORS?
-- ============================================================================

/*
WHAT ARE CONNECTORS?
====================
A connector is a pre-built, ready-to-use data pipeline template.
Instead of building a pipeline from scratch, you pick a connector,
configure it with your credentials, and it starts moving data.

SIMPLE ANALOGY:
- A connector is like a USB cable.
  One end plugs into your data source (SQL Server, Kafka, Google Drive).
  The other end plugs into Snowflake.
  The cable (connector) handles all the complexity of moving data between them.

WHAT IS INSIDE A CONNECTOR?
============================
A connector is actually a pre-built NiFi "flow definition" containing:

1. PROCESS GROUP - A container holding all the pieces
2. PROCESSORS - Individual workers that do specific jobs:
   - Source Processor: Reads data from the source system
   - Transformation Processors: Converts, filters, formats data
   - Destination Processor: Writes data to Snowflake
3. CONTROLLER SERVICES - Shared configurations (database connections, credentials)
4. CONNECTIONS - Wires linking processors together
5. PARAMETERS - Configurable settings (URLs, usernames, table names)

HOW ARE CONNECTORS BUILT?
==========================
Connectors are built by Snowflake engineers using:
1. Open-source NiFi processors (community-built components)
2. Proprietary NiFi processors (Snowflake-built components)
3. Strict design patterns for:
   - Performance (parallel processing, batching)
   - Fault-tolerance (retry logic, checkpointing)
   - Ease of configuration (simple parameter inputs)

Each connector is:
- Versioned (updates are tracked)
- Tested (validated against source systems)
- Documented (setup guides provided)
- Curated (follows Snowflake's quality standards)

AVAILABLE CONNECTORS (25+):
============================
| Source               | Type                        |
|---------------------|-----------------------------|
| SQL Server          | CDC Database Replication     |
| MySQL               | CDC Database Replication     |
| PostgreSQL          | CDC Database Replication     |
| Oracle              | CDC Database Replication     |
| Google BigQuery     | Incremental Replication      |
| Apache Kafka        | Streaming Events             |
| Kinesis             | Streaming Events             |
| Salesforce          | SaaS API Ingestion           |
| HubSpot             | SaaS API Ingestion           |
| Google Drive        | Unstructured File Ingestion  |
| SharePoint          | Unstructured File Ingestion  |
| Box                 | Unstructured File Ingestion  |
| Google Sheets       | Spreadsheet Ingestion        |
| LinkedIn Ads        | Marketing Analytics          |
| Google Ads          | Marketing Analytics          |
| Meta Ads            | Marketing Analytics          |
| Amazon Ads          | Marketing Analytics          |
| Jira Cloud          | Project Management           |
| Slack               | Communication Data           |
| Microsoft Dataverse | Dynamics 365 / Power Platform|
| Workday             | HR / Finance                 |
| Veeva Vault         | Life Sciences                |
| Snowflake to Kafka  | Reverse CDC (outbound)       |
*/


-- ============================================================================
-- SECTION 5: WHAT IS A RUNTIME?
-- ============================================================================

/*
WHAT IS A RUNTIME?
==================
A runtime is the actual compute instance that runs your data flows.
It is a containerized Apache NiFi server.

SIMPLE ANALOGY:
- If a deployment is an office building, a runtime is one office room.
  Each room has its own computer (NiFi instance) running specific pipelines.
  You can have multiple rooms (runtimes) in one building (deployment).

WHY MULTIPLE RUNTIMES?
- Isolate different projects (HR data vs Sales data)
- Isolate different teams (Team A vs Team B)
- Isolate environments (Dev vs Prod)
- Different scaling needs (small runtime for low-volume, large for high-volume)

RUNTIME CONFIGURATION:
- Node Type: Size of compute (Small, Medium, Large)
- Min/Max Nodes: Auto-scaling range (1 to 50 nodes)
- Snowflake Role: Security permissions the runtime uses
- External Access: Network access to external systems

IMPORTANT NOTES:
- Some connectors require Medium or Large (e.g., SQL Server needs Medium+)
- Some connectors don't support multi-node (e.g., SQL Server max 1 node)
- Runtimes use Snowflake Managed Token for authentication (recommended)
*/


-- ============================================================================
-- SECTION 6: WHAT IS THE CANVAS?
-- ============================================================================

/*
WHAT IS THE CANVAS?
===================
The canvas is the visual web interface where you design and monitor data flows.
It is the "whiteboard" where you drag, drop, and connect components.

SIMPLE ANALOGY:
- The canvas is like a digital whiteboard.
  You draw boxes (processors), connect them with arrows (connections),
  and watch data flow through them in real-time.

WHAT CAN YOU DO ON THE CANVAS?
- Drag and drop processors
- Connect processors with wires
- Group processors into process groups
- Start/stop individual processors or entire flows
- Monitor data volume, errors, and performance
- Configure processor settings
- View queued data between processors

THE CANVAS SHOWS:
- Data flow direction (arrows)
- Queue sizes (how much data is waiting)
- Processing rates (how fast data moves)
- Error counts (what failed)
- Processor status (running, stopped, invalid)
*/


-- ============================================================================
-- SECTION 7: WHAT ARE PROCESS GROUPS AND PROCESSORS?
-- ============================================================================

/*
WHAT IS A PROCESS GROUP?
========================
A process group is a container that holds related processors together.
It is like a folder for organizing your pipeline components.

SIMPLE ANALOGY:
- A process group is like a department in a company.
  The "Shipping Department" (process group) has multiple workers (processors):
  one packs boxes, one labels them, one loads the truck.
  They all work together on one task.

WHY USE PROCESS GROUPS?
- Organize complex flows (group by function or source)
- Reusability (copy a process group to another runtime)
- Access control (set permissions per group)
- Monitoring (see stats for the whole group)
- Nesting (groups inside groups for complex architectures)

When you install a connector, it creates a process group automatically.
That group contains all the processors needed for that connector.

WHAT IS A PROCESSOR?
====================
A processor is a single unit of work in your data pipeline.
Each processor does exactly ONE thing.

SIMPLE ANALOGY:
- A processor is like a worker on an assembly line.
  One worker only cuts metal. Another only welds. Another only paints.
  Each has one job and does it well.

TYPES OF PROCESSORS:
- Source Processors: Read data from somewhere (database, API, file system)
- Transformation Processors: Change data format, filter, route, enrich
- Destination Processors: Write data to somewhere (Snowflake, Kafka, files)
- Control Processors: Manage flow (wait, merge, split, retry)

INTERNAL LOGIC OF A PROCESSOR:
==============================
Every processor follows this cycle:

1. TRIGGER: Scheduler wakes the processor (timer-based or event-based)
2. INPUT: Processor reads FlowFiles from its input queue
3. PROCESS: Processor executes its specific logic:
   - For a "QueryDatabase" processor: runs SQL, gets rows
   - For a "ConvertRecord" processor: changes format (CSV to JSON)
   - For a "PutSnowflake" processor: writes data to Snowflake table
4. OUTPUT: Processor creates new FlowFiles and routes them:
   - "success" relationship: processing worked
   - "failure" relationship: processing failed
   - "retry" relationship: temporary error, try again
5. COMMIT: Changes are committed atomically (all or nothing)

FLOWFILE STRUCTURE:
- Content: The actual data (a row, a file, a message)
- Attributes: Metadata about the data (filename, size, source, timestamp)

CONTROLLER SERVICES:
====================
Shared resources used by multiple processors.
Examples:
- Database Connection Pool (one connection shared by many processors)
- Record Reader/Writer (defines data format like JSON, CSV, Avro)
- SSL Context (security certificates)

Think of controller services as shared tools in a workshop that
any worker (processor) can use.
*/


-- ============================================================================
-- SECTION 8: IMPLEMENTATION - LOADING DATA FROM SQL SERVER USING OPENFLOW
-- ============================================================================

/*
==========================================================================
LOADING SNAPSHOT AND INCREMENTAL DATA FROM MICROSOFT SQL SERVER
USING SNOWFLAKE OPENFLOW - STEP BY STEP
==========================================================================

This guide walks you through loading a FULL SNAPSHOT (all existing data)
followed by INCREMENTAL (ongoing changes) from SQL Server to Snowflake.

==========================================================================
STEP 1: PREPARE YOUR SQL SERVER (Done by SQL Server DBA)
==========================================================================

1a. Enable Change Tracking on the Database:
*/

-- Run this ON YOUR SQL SERVER (not Snowflake):
-- ALTER DATABASE YourDatabase
--   SET CHANGE_TRACKING = ON
--   (CHANGE_RETENTION = 2 DAYS, AUTO_CLEANUP = ON);

/*
1b. Enable Change Tracking on each table you want to replicate:
*/

-- Run this ON YOUR SQL SERVER for each table:
-- ALTER TABLE dbo.YourTable ENABLE CHANGE_TRACKING;

/*
1c. Create a login for the Openflow connector:
*/

-- Run this ON YOUR SQL SERVER:
-- CREATE LOGIN openflow_user WITH PASSWORD = 'StrongPassword123!';

/*
1d. Create a user in each database you want to replicate:
*/

-- Run this ON YOUR SQL SERVER in each database:
-- USE YourDatabase;
-- CREATE USER openflow_user FOR LOGIN openflow_user;

/*
1e. Grant permissions to the user:
*/

-- Run this ON YOUR SQL SERVER for each table:
-- GRANT SELECT ON dbo.YourTable TO openflow_user;
-- GRANT VIEW CHANGE TRACKING ON dbo.YourTable TO openflow_user;

/*
1f. (Optional but Recommended) Enable Read Committed Snapshot Isolation
    to prevent deadlocks between the connector and other applications:
*/

-- Run this ON YOUR SQL SERVER:
-- ALTER DATABASE YourDatabase SET READ_COMMITTED_SNAPSHOT ON;

/*
==========================================================================
STEP 2: PREPARE YOUR SNOWFLAKE ENVIRONMENT (Done by Snowflake Admin)
==========================================================================

2a. Create a destination database:
*/

CREATE DATABASE IF NOT EXISTS OPENFLOW_DESTINATION;

/*
2b. Create a service user for the connector:
*/

CREATE USER IF NOT EXISTS OPENFLOW_SQL_SERVER_USER
  TYPE = SERVICE
  COMMENT = 'Service user for Openflow SQL Server connector';

/*
2c. Create a role for the connector:
*/

CREATE ROLE IF NOT EXISTS OPENFLOW_SQL_SERVER_ROLE;
GRANT ROLE OPENFLOW_SQL_SERVER_ROLE TO USER OPENFLOW_SQL_SERVER_USER;
GRANT USAGE ON DATABASE OPENFLOW_DESTINATION TO ROLE OPENFLOW_SQL_SERVER_ROLE;
GRANT CREATE SCHEMA ON DATABASE OPENFLOW_DESTINATION TO ROLE OPENFLOW_SQL_SERVER_ROLE;

/*
2d. Create a warehouse for the connector:
*/

CREATE WAREHOUSE IF NOT EXISTS OPENFLOW_WH WITH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 300
  AUTO_RESUME = TRUE;

GRANT USAGE, OPERATE ON WAREHOUSE OPENFLOW_WH TO ROLE OPENFLOW_SQL_SERVER_ROLE;

/*
2e. Set up key-pair authentication (if using BYOC with KEY_PAIR):
     - Generate RSA key pair
     - Assign public key to the service user
*/

-- ALTER USER OPENFLOW_SQL_SERVER_USER SET RSA_PUBLIC_KEY = '<your_public_key>';

/*
==========================================================================
STEP 3: CREATE AN OPENFLOW DEPLOYMENT (Done in Snowsight UI)
==========================================================================

3a. Navigate to Snowsight > Ingestion > Openflow
3b. Click "Create Deployment"
3c. Choose deployment type:
    - "Snowflake Deployment" (recommended for simplicity)
    - "BYOC" (if data must stay in your VPC)
3d. For Snowflake Deployment:
    - Provide a name (e.g., "SQLSERVER_DEPLOYMENT")
    - Select a compute pool or create one
    - Configure network access (allow SQL Server IP/hostname)
3e. Click "Create"

==========================================================================
STEP 4: CREATE A RUNTIME (Done in Openflow UI)
==========================================================================

4a. Open the Openflow canvas (Ingestion > Openflow > Launch Openflow)
4b. Click "Create a Runtime"
4c. Configure:
    - Runtime Name: "SQLSERVER_RUNTIME"
    - Deployment: Select your deployment from Step 3
    - Node Type: MEDIUM (minimum required for SQL Server connector)
    - Min Nodes: 1
    - Max Nodes: 1 (SQL Server connector requires single node)
    - Snowflake Role: OPENFLOW_SQL_SERVER_ROLE
4d. Click "Create"
4e. Wait 2-3 minutes for the runtime to start

==========================================================================
STEP 5: CONFIGURE ALLOWED DOMAINS (For Snowflake Deployments)
==========================================================================

5a. In Snowflake, create an External Access Integration that allows
    network access to your SQL Server hostname/IP
5b. Associate the integration with your runtime

==========================================================================
STEP 6: INSTALL THE SQL SERVER CONNECTOR (Done in Openflow UI)
==========================================================================

6a. Navigate to Openflow overview page
6b. Click "View more connectors" in the Featured connectors section
6c. Find "Openflow Connector for SQL Server"
6d. Click "Add to runtime"
6e. Select your runtime ("SQLSERVER_RUNTIME")
6f. Click "Add"
6g. Authenticate when prompted
6h. Wait for installation to complete (a few minutes)
6i. The connector process group appears on the canvas

==========================================================================
STEP 7: CONFIGURE THE CONNECTOR PARAMETERS
==========================================================================

7a. Right-click the connector process group on the canvas
7b. Select "Parameters"
7c. Configure SOURCE PARAMETERS:
    - SQLServer Connection URL:
      jdbc:sqlserver://your-server.com:1433;encrypt=false
    - SQLServer JDBC Driver: Upload the JDBC driver file
    - SQLServer Username: openflow_user
    - SQLServer Password: StrongPassword123!

7d. Configure DESTINATION PARAMETERS:
    - Destination Database: OPENFLOW_DESTINATION
    - Destination Schema Pattern: ${source.database.name}_${source.schema.name}
    - Snowflake Authentication Strategy: SNOWFLAKE_MANAGED_TOKEN
    - Snowflake Role: OPENFLOW_SQL_SERVER_ROLE
    - Snowflake Warehouse: OPENFLOW_WH
    - Snowflake Object Identifier Resolution: Default (case-insensitive)

7e. Configure INGESTION PARAMETERS:
    - Included Table Names: YourDatabase.dbo.Table1, YourDatabase.dbo.Table2
      (OR use regex pattern)
    - Included Table Regex: YourDatabase\.dbo\..*
      (replicates ALL tables in dbo schema)
    - Ingestion Type: full (this does snapshot THEN incremental)
    - Merge Task Schedule CRON: * * * * * ?
      (continuous merge - or schedule specific times)

==========================================================================
STEP 8: START THE CONNECTOR (SNAPSHOT + INCREMENTAL)
==========================================================================

8a. Right-click on the canvas > "Enable all Controller Services"
8b. Right-click on the connector process group > "Start"

WHAT HAPPENS NOW (AUTOMATICALLY):
----------------------------------
PHASE 1 - SNAPSHOT (Full Load):
  1. Connector discovers table schemas from SQL Server
  2. Creates destination tables in Snowflake (matching structure)
  3. Reads ALL existing rows from each source table
  4. Writes all rows to Snowflake destination tables
  5. Table state changes: NEW -> SNAPSHOT_REPLICATION

PHASE 2 - INCREMENTAL (Ongoing CDC):
  1. After snapshot completes, connector switches to change tracking
  2. Polls SQL Server for changes since last check
  3. Captures INSERTs, UPDATEs, DELETEs
  4. Writes changes to journal tables in Snowflake
  5. Merges journal data into destination tables on schedule
  6. Table state changes: SNAPSHOT_REPLICATION -> INCREMENTAL_REPLICATION
  7. This continues forever until you stop the connector

==========================================================================
STEP 8B: UNDERSTANDING JOURNAL TABLES AND DATA MOVEMENT TO DESTINATION
==========================================================================

HOW CDC DATA FLOWS: Source -> Journal Table -> Destination Table
-----------------------------------------------------------------

WHAT ARE JOURNAL TABLES?
- Journal tables are INTERMEDIATE staging tables created by Openflow
- They sit BETWEEN the source CDC data and the final destination table
- Think of them as a "holding area" or "inbox" for incoming changes
- Named as: <TABLE_NAME>_JOURNAL_<timestamp>_<schema_generation>
- Example: ORDERS_JOURNAL_1705320000_1

WHAT GOES INTO JOURNAL TABLES?
- Every change detected by Change Tracking is written here FIRST
- Each row in the journal represents ONE change event:
  - INSERT: full row data with operation type = INSERT
  - UPDATE: full row data (new values) with operation type = UPDATE
  - DELETE: primary key + operation type = DELETE
- Journal tables are APPEND-ONLY (new changes keep adding, never overwritten)

HOW DOES DATA MOVE FROM JOURNAL TO DESTINATION TABLE?
------------------------------------------------------
The movement is controlled by the "Merge Task Schedule CRON" parameter.

TRIGGER CONDITION:
- The MergeSnowflakeJournalTable processor checks the CRON schedule
- When the CRON fires, it checks: "Are there new records in the journal?"
- If YES -> it runs a MERGE INTO statement on the destination table
- If NO new records -> nothing happens, warehouse stays suspended

THE MERGE LOGIC (what actually runs):
--------------------------------------
Openflow uses a Snowflake STREAM on top of the journal table.
The stream tracks which journal rows have NOT yet been merged.

Internally it executes something like:

  MERGE INTO destination_table AS target
  USING (SELECT * FROM journal_stream) AS source
  ON target.primary_key = source.primary_key
  WHEN MATCHED AND source.operation = 'DELETE' THEN
    UPDATE SET _SNOWFLAKE_DELETED = TRUE, _SNOWFLAKE_UPDATED_AT = CURRENT_TIMESTAMP()
  WHEN MATCHED AND source.operation = 'UPDATE' THEN
    UPDATE SET col1 = source.col1, col2 = source.col2, ...,
              _SNOWFLAKE_UPDATED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED AND source.operation = 'INSERT' THEN
    INSERT (col1, col2, ..., _SNOWFLAKE_INSERTED_AT, _SNOWFLAKE_UPDATED_AT, _SNOWFLAKE_DELETED)
    VALUES (source.col1, source.col2, ..., CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(), FALSE);

DOES IT GO TO A RAW LAYER OR DIRECTLY TO TARGET?
--------------------------------------------------
ANSWER: It goes DIRECTLY to the DESTINATION TABLE (which acts as a RAW layer).

There is NO separate raw/staging/curated layer built by Openflow.
The architecture is:

  SQL Server (Source)
       |
       v
  Journal Table (intermediate CDC log - append-only)
       |
       v  [MERGE on CRON schedule]
       |
  Destination Table (final table in Snowflake - THIS IS YOUR RAW LAYER)

You are responsible for building any additional layers on top:
  - Bronze/Raw = Destination table (Openflow manages this)
  - Silver/Cleaned = Your transformation (dbt, Tasks, Dynamic Tables)
  - Gold/Business = Your aggregation layer

DOES OPENFLOW IMPLEMENT SCD TYPE 1 OR SCD TYPE 2?
---------------------------------------------------
ANSWER: Openflow implements SCD TYPE 1 (overwrite) by default.
        It does NOT implement SCD Type 2 out of the box.

SCD TYPE 1 BEHAVIOR (what Openflow does):
- When a row is UPDATED in source, the destination row is OVERWRITTEN
- Old values are LOST in the destination table
- Only the current/latest state is kept
- _SNOWFLAKE_UPDATED_AT tells you WHEN it last changed, but NOT what it was before

SCD TYPE 2 BEHAVIOR (what Openflow does NOT do):
- Openflow does NOT create history rows with effective_from/effective_to dates
- It does NOT maintain version numbers or current_flag columns
- If you need full history of every change, Openflow alone won't do it

HOWEVER - YOU CAN BUILD SCD TYPE 2 USING JOURNAL TABLES!
----------------------------------------------------------
The journal tables DO contain every change event (append-only).
So you can build SCD Type 2 downstream:

OPTION 1: Use Journal Tables as Your History Source
  - Journal tables keep every change (INSERT, UPDATE, DELETE)
  - Build a downstream process that reads journal data
  - Create SCD Type 2 dimension tables from journal history
  - Use Snowflake Streams + Tasks or Dynamic Tables

OPTION 2: Build SCD Type 2 on top of Destination Table using Streams
  - Create a Snowflake STREAM on the destination table
  - Create a TASK that processes stream changes into an SCD2 table
  - Each change creates a new row with effective dates

EXAMPLE - Building SCD Type 2 from Openflow destination:

  -- Your SCD Type 2 table (you create this)
  -- CREATE TABLE CUSTOMER_DIM_SCD2 (
  --   CUSTOMER_SK        NUMBER AUTOINCREMENT,
  --   CUSTOMER_ID        NUMBER,       -- business key
  --   CUSTOMER_NAME      VARCHAR,
  --   EMAIL              VARCHAR,
  --   EFFECTIVE_FROM     TIMESTAMP,
  --   EFFECTIVE_TO       TIMESTAMP,
  --   IS_CURRENT         BOOLEAN,
  --   RECORD_SOURCE      VARCHAR DEFAULT 'OPENFLOW'
  -- );

  -- Stream on Openflow destination table
  -- CREATE STREAM CUSTOMER_CDC_STREAM ON TABLE OPENFLOW_DESTINATION.DB_DBO.CUSTOMERS;

  -- Task to process changes into SCD2
  -- CREATE TASK PROCESS_CUSTOMER_SCD2
  --   WAREHOUSE = COMPUTE_WH
  --   SCHEDULE = '5 MINUTE'
  -- WHEN SYSTEM$STREAM_HAS_DATA('CUSTOMER_CDC_STREAM')
  -- AS
  --   -- Close old record (set effective_to, is_current = false)
  --   -- Insert new record (set effective_from = now, is_current = true)
  --   ...;

SUMMARY TABLE:
--------------
| Layer              | Who Manages    | SCD Type | Purpose                    |
|-------------------|----------------|----------|----------------------------|
| Journal Table     | Openflow       | N/A      | CDC event log (append-only)|
| Destination Table | Openflow       | Type 1   | Current state (raw layer)  |
| SCD2 Dim Table   | YOU (downstream)| Type 2  | Full history with dates    |

KEY TAKEAWAYS:
- Journal = every change event (your audit trail)
- Destination = current state only (SCD Type 1 / overwrite)
- For SCD Type 2, build it yourself using Streams + Tasks on the destination
- The CRON schedule controls WHEN merges happen (cost vs freshness trade-off)
- If CRON = "* * * * * ?" -> continuous merge (freshest data, highest cost)
- If CRON = "0 */1 * * * ?" -> every hour (less fresh, lower cost) """

==========================================================================
STEP 9: VERIFY AND MONITOR
==========================================================================

9a. Check table states in Openflow UI:
    - Right-click process group > Controller Services
    - Find "Table State Store" > View State
    - Tables should show INCREMENTAL_REPLICATION status

9b. Query your data in Snowflake:
*/

-- Check the replicated data (adjust names to match your schema pattern)
-- SELECT * FROM OPENFLOW_DESTINATION.YOURDATABASE_DBO.YOURTABLE LIMIT 10;

-- Check metadata columns added by the connector
-- SELECT
--   *,
--   _SNOWFLAKE_INSERTED_AT,
--   _SNOWFLAKE_UPDATED_AT,
--   _SNOWFLAKE_DELETED
-- FROM OPENFLOW_DESTINATION.YOURDATABASE_DBO.YOURTABLE
-- LIMIT 10;

-- Query only active (non-deleted) rows
-- SELECT * FROM OPENFLOW_DESTINATION.YOURDATABASE_DBO.YOURTABLE
-- WHERE _SNOWFLAKE_DELETED = FALSE;

-- Query deleted rows (soft-deleted, still available)
-- SELECT * FROM OPENFLOW_DESTINATION.YOURDATABASE_DBO.YOURTABLE
-- WHERE _SNOWFLAKE_DELETED = TRUE;

/*
==========================================================================
STEP 10: SWITCHING TO INCREMENTAL-ONLY MODE (Skip Snapshot for New Tables)
==========================================================================

If you need to add new tables WITHOUT doing a full snapshot
(e.g., after reinstalling the connector over existing data):

10a. In Ingestion Parameters, set: Ingestion Type = incremental
10b. Add the new tables to Included Table Names
10c. The connector immediately starts capturing changes (no snapshot)
10d. Remember to switch back to "full" mode when done

IMPORTANT: Only use incremental mode temporarily. Tables added in this
mode will NOT have historical data - only changes from that point forward.
*/


-- ============================================================================
-- SECTION 9: INTERVIEW QUESTIONS - BEGINNER TO ARCHITECT LEVEL
-- ============================================================================

/*
==========================================================================
OPENFLOW INTERVIEW QUESTIONS
==========================================================================

--- BEGINNER LEVEL (0-1 years) ---

Q1: What is Snowflake Openflow?
A: Openflow is Snowflake's fully managed data integration service built on
   Apache NiFi. It connects any data source to Snowflake using pre-built
   connectors and visual flow design.

Q2: What is the relationship between Apache NiFi and Openflow?
A: Openflow is built on top of Apache NiFi. NiFi is the open-source engine;
   Openflow is Snowflake's managed version that adds security, scaling,
   and native Snowflake integration.

Q3: What are the two deployment types in Openflow?
A: Snowflake Deployment (runs in Snowflake's infrastructure using SPCS) and
   BYOC (runs in your own AWS VPC with Snowflake managing the software).

Q4: What is a connector in Openflow?
A: A connector is a pre-built, versioned NiFi flow definition that handles
   moving data from a specific source (like SQL Server) to Snowflake. It
   includes all necessary processors, configurations, and error handling.

Q5: What is the difference between snapshot and incremental replication?
A: Snapshot copies ALL existing data from source to destination (full load).
   Incremental only captures and applies changes (inserts, updates, deletes)
   that happen after the snapshot completes.

Q6: What is a FlowFile in Openflow/NiFi?
A: A FlowFile is a unit of data moving through the pipeline. It has two parts:
   content (the actual data) and attributes (metadata like filename, size).

Q7: What is a processor?
A: A processor is a single unit of work that performs one specific action,
   like reading from a database, converting data format, or writing to Snowflake.

Q8: What is the canvas?
A: The canvas is the visual web interface where you design, monitor, and
   manage data flows by dragging, dropping, and connecting processors.

Q9: Name 5 data sources that Openflow connectors support.
A: SQL Server, MySQL, PostgreSQL, Oracle, Apache Kafka, Salesforce,
   Google Drive, SharePoint, HubSpot, LinkedIn Ads (any 5).

Q10: What happens to deleted rows in the destination table?
A: They are soft-deleted. The _SNOWFLAKE_DELETED column is set to TRUE,
    but the row remains in the table for auditing purposes.


--- INTERMEDIATE LEVEL (1-3 years) ---

Q11: What is a runtime and how does it relate to a deployment?
A: A runtime is a containerized NiFi instance that executes data flows.
    A deployment is the parent environment that can host multiple runtimes.
    One deployment = many runtimes (like one building = many offices).

Q12: What is Change Tracking in the context of the SQL Server connector?
A: SQL Server Change Tracking is a feature that records which rows changed
    (insert/update/delete) in tracked tables. The connector uses it to
    detect incremental changes without scanning entire tables.

Q13: What are journal tables and why do they exist?
A: Journal tables store intermediate CDC data before it's merged into
    destination tables. They exist to provide fault tolerance, auditing,
    and controlled merge scheduling.

Q14: Explain the Merge Task Schedule CRON parameter.
A: It controls WHEN changes from journal tables are merged into destination
    tables. "* * * * * ?" means continuous merge. You can schedule specific
    times to control warehouse costs (warehouse only runs during merges).

Q15: What is Snowflake Managed Token authentication?
A: It's the recommended auth method where Snowflake automatically manages
    short-lived tokens for the runtime. No manual key rotation needed.
    Uses SPCS session tokens or workload identity federation (BYOC).

Q16: What are the metadata columns added to destination tables?
A: _SNOWFLAKE_INSERTED_AT (when row was inserted), _SNOWFLAKE_UPDATED_AT
    (when row was last updated), _SNOWFLAKE_DELETED (soft-delete flag).

Q17: What happens when a column is dropped from the source table?
A: The connector doesn't drop it in Snowflake. Instead, it renames it
    with __SNOWFLAKE_DELETED suffix to preserve historical data.

Q18: Can you replicate tables without primary keys using the SQL Server connector?
A: No. The SQL Server connector only replicates tables that have primary keys.
    Tables without primary keys are not supported.

Q19: What is the Oversized Value Strategy parameter?
A: It determines what happens when a value exceeds 16 MB. Options:
    "Fail Table" (stops replication for that table) or
    "Set Null" (replaces the value with NULL and continues).

Q20: How do you restart replication for a failed table?
A: Remove the table from replication config, wait for state to clear,
    DROP the destination table in Snowflake, then re-add the table.
    The connector will re-snapshot it.


--- ADVANCED LEVEL (3-5 years) ---

Q21: Explain the complete data flow inside the SQL Server connector.
A: Source -> Change Tracking polls -> FlowFiles created with changes ->
    Journal table write -> Stream on journal table -> Merge processor
    reads stream -> MERGE INTO destination table -> Updates metadata columns
    -> Acknowledges processed changes.

Q22: How does auto-scaling work in Openflow runtimes?
A: Runtimes have Min/Max node settings. Based on data volume and CPU load,
    the runtime automatically scales between these bounds. However, some
    connectors (like SQL Server) require single-node only.

Q23: Compare Snowflake Deployment vs BYOC for a financial services company.
A: BYOC is better because: data stays in the company's VPC (regulatory
    compliance), supports AWS Secrets Manager/Hashicorp Vault integration,
    allows private link connectivity, and provides full network isolation.
    Trade-off: more complex setup and infrastructure management.

Q24: How would you handle replicating 500+ tables with varying schemas?
A: Use Included Table Regex to match patterns. Use Destination Schema Pattern
    with variables to organize tables. Start with XSMALL warehouse and scale
    up. Consider multi-cluster warehouse for parallel merges. Monitor
    journal table growth and implement cleanup tasks.

Q25: What happens if SQL Server Change Tracking retention expires?
A: If the connector can't poll within the retention period (default 2 days),
    it loses track of changes. The table enters FAILED state and needs
    to be re-snapshotted. Solution: increase CHANGE_RETENTION or ensure
    connector polling is more frequent than retention.

Q26: Explain the Column Filter JSON feature and its implications.
A: It allows replicating only specific columns per table using include/exclude
    patterns. Important: excluding then re-including a column causes soft-delete
    naming conflicts. Primary key columns are always included regardless.

Q27: How does the connector handle schema evolution?
A: Supports adding columns (adds to destination, doesn't backfill) and
    dropping columns (soft-deletes with suffix). Does NOT support:
    changing primary keys, changing numeric precision/scale, or TRUNCATE.

Q28: Design a high-availability Openflow architecture for a global company.
A: Multiple deployments across regions. BYOC in each region's VPC.
    Separate runtimes per business domain. Monitoring role for ops team.
    Private Link for all Snowflake connections. AWS Secrets Manager for
    credentials. CRON-scheduled merges to control costs. Alerting on
    table FAILED states.

Q29: How do you migrate a connector to a new runtime without re-snapshotting?
A: Set Ingestion Type = incremental on the new connector instance.
    Point it at the same destination database. Add the tables - they'll
    skip snapshot and immediately begin incremental replication from the
    current change tracking version.

Q30: What is the difference between Change Tracking and Change Data Capture in SQL Server,
     and why does Openflow use Change Tracking?
A: Change Tracking records net changes (final state). CDC records every
    intermediate change. Openflow uses CT because: simpler setup, lower overhead,
    adequate for sync use cases. Trade-off: can't capture intermediate states.


--- ARCHITECT LEVEL (5+ years) ---

Q31: Design an end-to-end data platform using Openflow for a company
     migrating from on-premises SQL Server to Snowflake.
A: Architecture layers:
    1. Source: Enable CT on all SQL Server databases. RCSI for no-lock reads.
    2. Network: VPN/Direct Connect from on-prem to AWS. Private Link to Snowflake.
    3. Openflow: BYOC deployment in AWS VPC. Multiple runtimes per domain.
    4. Destination: Database-per-domain in Snowflake. Schema pattern for org.
    5. Security: Snowflake Managed Token. Secrets Manager. TLS everywhere.
    6. Operations: Monitoring role. CRON merges during off-peak. Alerting.
    7. Governance: Tag replicated tables. Column filtering for PII.
    8. Cost: XSMALL warehouse, auto-suspend. Schedule merges to control uptime.

Q32: How would you implement a multi-tenant Openflow architecture?
A: Separate runtimes per tenant (isolation). Shared deployment (cost efficiency).
    Destination Schema Pattern: ${source.database.name}_TENANT_${source.schema.name}.
    Per-tenant Snowflake roles. Column Filter JSON to exclude tenant-specific PII.
    Separate monitoring per tenant. Usage-based chargeback via warehouse tags.

Q33: Compare Openflow with other integration tools (Fivetran, Airbyte, Matillion)
     from an architect's perspective.
A: Openflow advantages: Native Snowflake security, open-source NiFi base,
    runs in your VPC, handles unstructured data, streaming + batch, extensible.
    Openflow disadvantages: Newer, fewer connectors than Fivetran, requires
    NiFi knowledge for custom flows. Fivetran: more connectors, simpler, SaaS-only.
    Airbyte: open-source, more connectors, but self-managed. Matillion: transformation-focused.

Q34: How would you handle disaster recovery for Openflow?
A: DR strategy:
    1. Connector state: Export flow definitions regularly (NiFi templates)
    2. Data: Snowflake handles destination DR (replication/failover)
    3. Runtime: Document all parameters. Automate runtime creation.
    4. Source: SQL Server AlwaysOn/replica for source redundancy
    5. RTO: New runtime + incremental mode = resume without re-snapshot
    6. RPO: Depends on merge schedule and CT retention period

Q35: Design an Openflow solution that ingests both structured (SQL Server CDC)
     and unstructured (SharePoint documents) data for an AI chatbot.
A: Two runtimes in one deployment:
    Runtime 1: SQL Server connector -> structured tables for Cortex Analyst
    Runtime 2: SharePoint connector -> documents to Snowflake stage ->
    Cortex AI parsing -> searchable vector embeddings
    Shared: Same Snowflake database, separate schemas.
    AI layer: Cortex Search over embeddings + Cortex Analyst over tables.
    Near real-time: Continuous merge for CDC, polling interval for SharePoint.

Q36: What are the key cost optimization strategies for Openflow at scale?
A: 1. Merge scheduling: CRON to specific windows (warehouse idle = no cost)
    2. Runtime sizing: Start XSMALL, scale based on actual throughput
    3. Multi-cluster warehouse: Better than large warehouse for many tables
    4. Journal cleanup: Automated tasks to truncate/drop old journals
    5. Column filtering: Don't replicate unnecessary columns (reduces storage + compute)
    6. Table regex: Only replicate needed tables
    7. Auto-suspend: Short suspend time on warehouse (300s)
    8. Monitor: Track FAILED tables early to avoid wasted re-snapshots

Q37: How do you ensure data consistency between SQL Server and Snowflake
     when using Openflow?
A: Consistency model:
    - Eventual consistency (not real-time sync)
    - CT reports net changes (multiple updates = one merge)
    - Soft deletes mean row counts differ (Snowflake > source)
    - Validation: Compare COUNT, MAX(updated_at), checksum of PKs
    - Lag = polling interval + merge schedule + Snowflake processing
    - For strict consistency: reduce polling interval, continuous merge

Q38: Design a testing strategy for Openflow pipelines before production.
A: Testing layers:
    1. Dev runtime: Small subset of tables, separate destination DB
    2. Schema validation: Compare source vs destination DDL
    3. Data validation: Row counts, PK uniqueness, NULL checks
    4. CDC testing: Insert/Update/Delete in source, verify in destination
    5. Failure testing: Stop connector mid-snapshot, verify resume
    6. Performance testing: High-volume inserts, measure lag
    7. Security testing: Verify role permissions, network access
    8. Promotion: Export flow definition, import to prod runtime

Q39: How would you integrate Openflow with Snowflake's broader ecosystem
     (Streams, Tasks, Dynamic Tables, Cortex)?
A: Integration patterns:
    - Streams on destination tables -> Tasks for downstream transformations
    - Dynamic Tables consuming Openflow destinations for real-time views
    - Cortex AI functions on unstructured data landed by file connectors
    - Cortex Search over documents ingested via SharePoint/Drive connectors
    - Data Quality DMFs on destination tables for monitoring
    - Snowflake Alerts on _SNOWFLAKE_DELETED patterns for anomaly detection

Q40: As a solutions architect, when would you NOT recommend Openflow?
A: Don't use Openflow when:
    - Source has no connector AND custom NiFi development is not feasible
    - Sub-second latency is required (Openflow is near-real-time, not real-time)
    - Simple one-time data migration (use COPY INTO or Snowpipe instead)
    - Source is already in cloud storage (use external tables or auto-ingest)
    - Organization has no NiFi expertise and needs 100+ custom transformations
    - Budget is extremely limited and Snowpipe + scripts would suffice
    - Audit/compliance requires EVERY intermediate row change (CT only gives net)
*/

-- ============================================================================
-- END OF GUIDE
-- ============================================================================
