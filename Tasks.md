# Snowflake Tasks — Complete Guide

> Definition | Internal Architecture | Task Graphs | Streams + Tasks | From Scratch to Architect Level

---

## Table of Contents

- [Part 0: Complete CREATE TASK Syntax](#part-0-complete-create-task-syntax--every-feature-explained)
- [Part 1: What is a Task?](#part-1-what-is-a-task)
- [Part 2: Internal Architecture](#part-2-internal-architecture--how-tasks-work)
- [Part 3: Compute Models](#part-3-compute-models)
- [Part 4: Scheduling — Fixed Schedule vs Triggered Tasks](#part-4-scheduling--fixed-schedule-vs-triggered-tasks)
- [Part 5: Task Graphs (DAGs)](#part-5-task-graphs-dags--multi-step-pipelines)
- [Part 6: Streams + Tasks — The CDC Pipeline Pattern](#part-6-streams--tasks--the-cdc-pipeline-pattern)
- [Part 7: Error Handling, Retries & Suspension](#part-7-error-handling-retries--suspension)
- [Part 8: Access Privileges](#part-8-access-privileges)
- [Part 9: Task Management Commands (SQL Reference)](#part-9-task-management-commands-sql-reference)
- [Part 10: SQL Examples — From Basic to Advanced](#part-10-sql-examples--from-basic-to-advanced)
- [Part 11: Billing & Cost Model](#part-11-billing--cost-model)
- [Part 12: Tricky Scenarios & Gotchas](#part-12-tricky-scenarios--gotchas)
- [Part 13: Interview Questions — Level 1: Beginner](#part-13-interview-questions--level-1-beginner)
- [Part 14: Interview Questions — Level 2: Intermediate](#part-14-interview-questions--level-2-intermediate)
- [Part 15: Interview Questions — Level 3: Advanced](#part-15-interview-questions--level-3-advanced)
- [Part 16: Interview Questions — Level 4: Architect](#part-16-interview-questions--level-4-architect)
- [Part 17: Quick Reference Cheat Sheet](#part-17-quick-reference-cheat-sheet)
- [Part 18: Overlap Scenario — Deep Dive](#part-18-overlap-scenario--deep-dive-with-real-example)
- [Part 19: Minimum Schedule Interval — Deep Dive](#part-19-minimum-schedule-interval--deep-dive-with-examples)

---

## Part 0: Complete CREATE TASK Syntax — Every Feature Explained

### Full Syntax

```sql
CREATE [ OR REPLACE ] TASK [ IF NOT EXISTS ] <name>
    [ WITH TAG ( <tag_name> = '<tag_value>' [, ...] ) ]
    [ WITH CONTACT ( <purpose> = <contact_name> [, ...] ) ]
    [ { WAREHOUSE = '<string>' }
      | { USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = '<string>' } ]
    [ SCHEDULE = { '<num> { HOURS | MINUTES | SECONDS }'
      | 'USING CRON <expr> <time_zone>' } ]
    [ CONFIG = '<json_string>' ]
    [ OVERLAP_POLICY = { NO_OVERLAP | ALLOW_CHILD_OVERLAP | ALLOW_ALL_OVERLAP } ]
    [ <session_parameter> = <value> [, ...] ]
    [ USER_TASK_TIMEOUT_MS = <num> ]
    [ SUSPEND_TASK_AFTER_NUM_FAILURES = <num> ]
    [ ERROR_INTEGRATION = <integration_name> ]
    [ SUCCESS_INTEGRATION = <integration_name> ]
    [ LOG_LEVEL = '<log_level>' ]
    [ COMMENT = '<string>' ]
    [ FINALIZE = <root_task_name> ]
    [ TASK_AUTO_RETRY_ATTEMPTS = <num> ]
    [ USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = <num> ]
    [ TARGET_COMPLETION_INTERVAL = '<num> { HOURS | MINUTES | SECONDS }' ]
    [ SERVERLESS_TASK_MIN_STATEMENT_SIZE = '{ XSMALL | SMALL | MEDIUM | LARGE | XLARGE | XXLARGE }' ]
    [ SERVERLESS_TASK_MAX_STATEMENT_SIZE = '{ XSMALL | SMALL | MEDIUM | LARGE | XLARGE | XXLARGE }' ]
    [ AFTER <task> [, <task>, ...] ]
    [ EXECUTE AS USER <user_name> ]
    [ WHEN <boolean_expr> ]
AS
    <sql>
```

Also supports:
- `CREATE OR ALTER TASK <name> ...` — create if not exists OR alter in-place
- `CREATE TASK <name> CLONE <source>` — clone an existing task

---

### 0.1 Compute Model — WAREHOUSE vs SERVERLESS

You must choose ONE: user-managed warehouse OR serverless. Never both.

**OPTION A: USER-MANAGED WAREHOUSE**
- You specify a warehouse. Standard warehouse billing applies.
- Max size: up to 6XL.

```sql
CREATE TASK wh_task
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '5 MINUTES'
AS SELECT 1;
```

**OPTION B: SERVERLESS (omit WAREHOUSE)**
- Snowflake auto-provisions and scales compute. Per-second billing.
- Max size: XXLARGE equivalent.
- Requires EXECUTE MANAGED TASK privilege.

```sql
CREATE TASK serverless_task
    SCHEDULE = '5 MINUTES'
AS SELECT 1;
```

**USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE** (serverless only):
- Sets the starting warehouse size for the FIRST run.
- After a few runs, Snowflake auto-sizes based on history.
- Default: MEDIUM. Range: XSMALL to XXLARGE.
- ERROR if you set this AND WAREHOUSE together.

```sql
CREATE TASK serverless_with_initial_size
    SCHEDULE = '5 MINUTES'
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'XSMALL'
AS SELECT 1;
```

---

### 0.2 Schedule — INTERVAL vs CRON

Only set on standalone tasks or root tasks. Children inherit from root.

**INTERVAL: Run every N seconds/minutes/hours**
- Range: 10 SECONDS to 8 DAYS (691200 seconds / 11520 minutes / 192 hours)
- Timer starts when task is RESUMED.

```sql
CREATE TASK every_10_seconds   SCHEDULE = '10 SECONDS'  AS SELECT 1;
CREATE TASK every_5_minutes    SCHEDULE = '5 MINUTES'   AS SELECT 1;
CREATE TASK every_2_hours      SCHEDULE = '2 HOURS'     AS SELECT 1;
```

**CRON: Run at specific times using cron expression + timezone**
- Format: `'USING CRON <min> <hour> <day-of-month> <month> <day-of-week> <timezone>'`
- Supports: `*` (wildcard), `L` (last), `/n` (every nth)

```
┌───────────── minute (0-59)
│ ┌───────────── hour (0-23)
│ │ ┌───────────── day of month (1-31, or L for last)
│ │ │ ┌───────────── month (1-12 or JAN-DEC)
│ │ │ │ ┌───────────── day of week (0-6 or SUN-SAT, or L)
│ │ │ │ │
* * * * *
```

```sql
-- Every minute:
CREATE TASK every_minute
    SCHEDULE = 'USING CRON * * * * * UTC'
AS SELECT 1;

-- Every 5 minutes:
CREATE TASK every_5_min_cron
    SCHEDULE = 'USING CRON 0/5 * * * * UTC'
AS SELECT 1;

-- Weekdays at 9 AM Eastern:
CREATE TASK weekday_9am
    SCHEDULE = 'USING CRON 0 9 * * MON-FRI America/New_York'
AS SELECT 1;

-- Twice daily (6 AM and 6 PM UTC):
CREATE TASK twice_daily
    SCHEDULE = 'USING CRON 0 6,18 * * * UTC'
AS SELECT 1;

-- First day of every month at midnight:
CREATE TASK monthly_first
    SCHEDULE = 'USING CRON 0 0 1 * * UTC'
AS SELECT 1;

-- Last day of every month at midnight:
CREATE TASK monthly_last
    SCHEDULE = 'USING CRON 0 0 L * * UTC'
AS SELECT 1;

-- Every Sunday at 3 AM Pacific:
CREATE TASK sunday_3am
    SCHEDULE = 'USING CRON 0 3 * * SUN America/Los_Angeles'
AS SELECT 1;
```

---

### 0.3 WHEN — Conditional Execution (Trigger / Guard)

The WHEN clause defines a boolean condition evaluated BEFORE the task runs.
- If FALSE → task is SKIPPED (no compute cost, only minimal cloud services).
- Supports: `SYSTEM$STREAM_HAS_DATA`, `SYSTEM$GET_PREDECESSOR_RETURN_VALUE`, AND, OR, NOT, comparison operators, type casts.
- **IMPORTANT:** WHEN evaluation runs in cloud services (no warehouse needed).

```sql
-- Triggered task (no schedule, fires when stream has data):
CREATE TASK triggered_by_stream
    WAREHOUSE = 'COMPUTE_WH'
    WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS MERGE INTO target USING my_stream ON target.id = my_stream.id
   WHEN NOT MATCHED THEN INSERT VALUES (my_stream.id, my_stream.val);

-- Scheduled + guarded (runs every hour ONLY IF stream has data):
CREATE TASK scheduled_with_guard
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '1 HOUR'
    WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS INSERT INTO target SELECT * FROM my_stream;

-- Multiple streams (OR — run if EITHER stream has data):
CREATE TASK multi_stream_or
    WAREHOUSE = 'COMPUTE_WH'
    WHEN SYSTEM$STREAM_HAS_DATA('orders_stream')
      OR SYSTEM$STREAM_HAS_DATA('returns_stream')
AS SELECT 1;

-- Multiple streams (AND — run only if BOTH have data):
CREATE TASK multi_stream_and
    WAREHOUSE = 'COMPUTE_WH'
    WHEN SYSTEM$STREAM_HAS_DATA('orders_stream')
     AND SYSTEM$STREAM_HAS_DATA('inventory_stream')
AS SELECT 1;

-- Using predecessor return value as condition:
CREATE TASK conditional_child
    WAREHOUSE = 'COMPUTE_WH'
    AFTER parent_task
    WHEN SYSTEM$GET_PREDECESSOR_RETURN_VALUE('PARENT_TASK')::FLOAT < 0.2
AS SELECT 1;

-- Boolean NOT:
CREATE TASK skip_if_flagged
    WAREHOUSE = 'COMPUTE_WH'
    AFTER parent_task
    WHEN NOT SYSTEM$GET_PREDECESSOR_RETURN_VALUE('PARENT_TASK')::BOOLEAN
AS SELECT 1;
```

---

### 0.4 AFTER — Child Task Dependencies (Task Graph / DAG)

Creates parent-child relationships. Children run AFTER parents complete.
- Multiple parents = child waits for ALL resumed parents to succeed.
- Multiple children of same parent = children run in PARALLEL.
- Max: 100 parents per child, 100 children per parent, 1000 tasks per graph.
- All tasks must share same owner role and same schema.

```sql
-- Single parent:
CREATE TASK child_a AFTER root_task AS SELECT 1;

-- Multiple parents (converging — waits for ALL):
CREATE TASK converging_child
    WAREHOUSE = 'COMPUTE_WH'
    AFTER task_b, task_c, task_d
AS SELECT 1;
```

---

### 0.5 FINALIZE — Finalizer Task

- Runs AFTER all tasks in the graph complete (success, failure, or cancel).
- One finalizer per root task. Cannot have children.
- Does NOT run if root task was SKIPPED (overlap policy).
- Use for: cleanup, notifications, error correction.

```sql
CREATE TASK my_finalizer
    WAREHOUSE = 'COMPUTE_WH'
    FINALIZE = root_task
AS
    CALL SYSTEM$SEND_EMAIL(
        'my_email_int',
        'admin@company.com',
        'Pipeline Complete',
        'The task graph has finished.'
    );
```

---

### 0.6 CONFIG — Pass Configuration to Task Graph

JSON config set on root task. All tasks in the graph can read it.
Override per-run: `EXECUTE TASK root USING CONFIG = '{"key":"val"}'`

```sql
CREATE TASK root_with_config
    SCHEDULE = '10 MINUTES'
    CONFIG = $${"environment": "production", "path": "/data/", "batch_size": 5000}$$
AS
    BEGIN
        LET env := (SELECT SYSTEM$GET_TASK_GRAPH_CONFIG('environment'));
        LET path := (SELECT SYSTEM$GET_TASK_GRAPH_CONFIG('path'));
        CALL SYSTEM$SET_RETURN_VALUE(:env || ':' || :path);
    END;

-- Child reads config:
CREATE TASK child_reads_config
    WAREHOUSE = 'COMPUTE_WH'
    AFTER root_with_config
AS
    BEGIN
        LET batch := (SELECT SYSTEM$GET_TASK_GRAPH_CONFIG('batch_size')::INT);
        INSERT INTO log_table VALUES ('batch_size', :batch, CURRENT_TIMESTAMP());
    END;
```

---

### 0.7 OVERLAP_POLICY — What Happens on Schedule Conflict

Set on ROOT TASK only. Applies to entire graph.

```sql
-- NO_OVERLAP (default):
CREATE TASK no_overlap_task
    SCHEDULE = '1 MINUTE'
    OVERLAP_POLICY = NO_OVERLAP
AS SELECT 1;

-- ALLOW_CHILD_OVERLAP:
CREATE TASK child_overlap_task
    SCHEDULE = '1 MINUTE'
    OVERLAP_POLICY = ALLOW_CHILD_OVERLAP
AS SELECT 1;

-- ALLOW_ALL_OVERLAP (DANGEROUS with streams):
CREATE TASK full_overlap_task
    SCHEDULE = '1 MINUTE'
    OVERLAP_POLICY = ALLOW_ALL_OVERLAP
AS SELECT 1;
```

---

### 0.8 Error Handling — Retry, Suspend, Timeout

```sql
-- TASK_AUTO_RETRY_ATTEMPTS (root task only, range 0-30, default 0):
CREATE TASK with_retry
    SCHEDULE = '5 MINUTES'
    TASK_AUTO_RETRY_ATTEMPTS = 2
AS SELECT 1;

-- SUSPEND_TASK_AFTER_NUM_FAILURES (default 10, set 0 to disable):
CREATE TASK with_auto_suspend
    SCHEDULE = '5 MINUTES'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
AS SELECT 1;

-- USER_TASK_TIMEOUT_MS (default 3600000 = 1 hour, max 604800000 = 7 days):
CREATE TASK with_timeout
    SCHEDULE = '5 MINUTES'
    USER_TASK_TIMEOUT_MS = 300000   -- 5 minutes
AS SELECT 1;

-- Combined:
CREATE TASK production_task
    SCHEDULE = '5 MINUTES'
    TASK_AUTO_RETRY_ATTEMPTS = 2
    SUSPEND_TASK_AFTER_NUM_FAILURES = 5
    USER_TASK_TIMEOUT_MS = 600000
AS SELECT 1;
```

---

### 0.9 Notifications — ERROR_INTEGRATION & SUCCESS_INTEGRATION

Send notifications to Amazon SNS, Azure Event Grid, or Google Pub/Sub when a task fails or succeeds.

```sql
CREATE TASK with_notifications
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '1 HOUR'
    ERROR_INTEGRATION = 'my_sns_error_integration'
    SUCCESS_INTEGRATION = 'my_sns_success_integration'
AS SELECT 1;
```

---

### 0.10 Serverless Scaling Controls

- **SERVERLESS_TASK_MIN_STATEMENT_SIZE**: Floor. Default: XSMALL.
- **SERVERLESS_TASK_MAX_STATEMENT_SIZE**: Ceiling. Default: XXLARGE.

```sql
CREATE TASK bounded_serverless
    SCHEDULE = '30 SECONDS'
    SERVERLESS_TASK_MIN_STATEMENT_SIZE = 'SMALL'
    SERVERLESS_TASK_MAX_STATEMENT_SIZE = 'LARGE'
AS SELECT 1;
```

**TARGET_COMPLETION_INTERVAL** (serverless only):
- Required for serverless triggered tasks. Range: 10 SECONDS to 24 HOURS.

```sql
CREATE TASK fast_serverless_triggered
    TARGET_COMPLETION_INTERVAL = '5 MINUTES'
    SERVERLESS_TASK_MIN_STATEMENT_SIZE = 'SMALL'
    SERVERLESS_TASK_MAX_STATEMENT_SIZE = 'XLARGE'
    WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS INSERT INTO target SELECT * FROM my_stream;
```

---

### 0.11 Trigger Polling Interval

**USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS:** Default: 30. Min: 10. Max: 604800.

```sql
CREATE TASK low_latency_triggered
    WAREHOUSE = 'COMPUTE_WH'
    USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 10
    WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS INSERT INTO target SELECT * FROM my_stream;
```

---

### 0.12 EXECUTE AS USER — Run As a Specific User

```sql
CREATE TASK as_service_user
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '1 HOUR'
    EXECUTE AS USER my_service_user
AS INSERT INTO audit VALUES (CURRENT_USER(), CURRENT_TIMESTAMP());
```

---

### 0.13 Session Parameters

```sql
CREATE TASK with_session_params
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '1 HOUR'
    TIMEZONE = 'America/New_York'
    TIMESTAMP_INPUT_FORMAT = 'YYYY-MM-DD HH24'
    QUERY_TAG = 'etl_pipeline_daily'
AS INSERT INTO target VALUES (CURRENT_TIMESTAMP());
```

---

### 0.14 LOG_LEVEL, COMMENT, TAGS, CONTACTS

```sql
CREATE TASK with_logging  SCHEDULE = '1 HOUR' LOG_LEVEL = 'WARN' AS SELECT 1;
CREATE TASK with_comment  SCHEDULE = '1 HOUR' COMMENT = 'Nightly aggregation' AS SELECT 1;
CREATE TASK with_tags     WITH TAG (cost_center = 'finance', env = 'production') SCHEDULE = '1 HOUR' AS SELECT 1;
CREATE TASK with_contact  WITH CONTACT (data_steward = contact_alice) SCHEDULE = '1 HOUR' AS SELECT 1;
```

---

### 0.15 SQL Body — What the Task Executes

```sql
-- Single SQL:
CREATE TASK single_sql SCHEDULE = '5 MINUTES'
AS INSERT INTO log VALUES (CURRENT_TIMESTAMP());

-- Stored procedure call:
CREATE TASK proc_call SCHEDULE = '1 HOUR'
AS CALL my_etl_procedure();

-- Snowflake Scripting (multi-statement):
CREATE TASK scripting_task SCHEDULE = '5 MINUTES'
AS
    BEGIN
        LET count := (SELECT COUNT(*) FROM staging);
        IF (count > 0) THEN
            INSERT INTO target SELECT * FROM staging;
            TRUNCATE TABLE staging;
        END IF;
        CALL SYSTEM$SET_RETURN_VALUE(:count::STRING || ' rows processed');
    END;
```

---

### 0.16 CREATE OR ALTER TASK

```sql
CREATE OR ALTER TASK my_task
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '10 MINUTES'
AS SELECT 1;
```

### 0.17 CLONE TASK

```sql
CREATE TASK my_task_clone CLONE my_task;
```

---

### 0.18 Complete Real-World Example — All Features Combined

```sql
CREATE OR REPLACE TASK production_cdc_pipeline
    WITH TAG (team = 'data-engineering', env = 'production')
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'SMALL'
    TARGET_COMPLETION_INTERVAL = '5 MINUTES'
    SERVERLESS_TASK_MIN_STATEMENT_SIZE = 'XSMALL'
    SERVERLESS_TASK_MAX_STATEMENT_SIZE = 'LARGE'
    USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 10
    TASK_AUTO_RETRY_ATTEMPTS = 2
    SUSPEND_TASK_AFTER_NUM_FAILURES = 5
    USER_TASK_TIMEOUT_MS = 600000
    ERROR_INTEGRATION = 'sns_error_notifications'
    LOG_LEVEL = 'WARN'
    COMMENT = 'Real-time CDC from raw_orders to processed_orders'
    CONFIG = $${"source": "raw_orders", "target": "processed_orders"}$$
    WHEN SYSTEM$STREAM_HAS_DATA('raw_orders_stream')
AS
    MERGE INTO processed_orders AS t
    USING (
        SELECT order_id, customer_id, amount,
               METADATA$ACTION, METADATA$ISUPDATE
        FROM raw_orders_stream
    ) AS s
    ON t.order_id = s.order_id
    WHEN MATCHED AND s.METADATA$ACTION = 'DELETE' AND s.METADATA$ISUPDATE = FALSE
        THEN DELETE
    WHEN MATCHED AND s.METADATA$ISUPDATE = TRUE
        THEN UPDATE SET t.customer_id = s.customer_id, t.amount = s.amount
    WHEN NOT MATCHED AND s.METADATA$ACTION = 'INSERT'
        THEN INSERT VALUES (s.order_id, s.customer_id, s.amount);
```

---

### 0.19 Quick Reference: All CREATE TASK Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| WAREHOUSE | (none) | User-managed compute |
| USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE | MEDIUM | Serverless initial WH size |
| SCHEDULE | (none) | Fixed interval or CRON |
| WHEN | (none) | Boolean guard / trigger condition |
| AFTER | (none) | Parent task dependency |
| FINALIZE | (none) | Finalizer for root task |
| CONFIG | (none) | JSON config for graph |
| OVERLAP_POLICY | NO_OVERLAP | Overlap behavior |
| TASK_AUTO_RETRY_ATTEMPTS | 0 | Auto-retry on failure (0-30) |
| SUSPEND_TASK_AFTER_NUM_FAILURES | 10 | Auto-suspend after N failures |
| USER_TASK_TIMEOUT_MS | 3600000 (1 hr) | Max runtime (0-604800000) |
| USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS | 30 | Trigger poll frequency (10-604800) |
| TARGET_COMPLETION_INTERVAL | (auto) | Desired completion time |
| SERVERLESS_TASK_MIN_STATEMENT_SIZE | XSMALL | Min auto-scale size |
| SERVERLESS_TASK_MAX_STATEMENT_SIZE | XXLARGE | Max auto-scale size |
| ERROR_INTEGRATION | (none) | SNS/EventGrid/PubSub on failure |
| SUCCESS_INTEGRATION | (none) | SNS/EventGrid/PubSub on success |
| LOG_LEVEL | (inherited) | Event table log severity |
| COMMENT | (none) | Free-text description |
| WITH TAG | (none) | Governance tags |
| WITH CONTACT | (none) | Contact association |
| EXECUTE AS USER | (system service) | Run as specific user |
| Session parameters | (account defaults) | TIMEZONE, QUERY_TAG, etc. |

---

## Part 1: What is a Task?

### 1.1 Definition

A **TASK** is a Snowflake object that automates the execution of SQL statements, stored procedures, or procedural logic on a defined **SCHEDULE** or in response to an **EVENT** (triggered task).

Think of a task as a **CRON JOB** that lives inside Snowflake.

**Key Facts:**
- A task runs a SINGLE SQL statement or stored procedure call
- Tasks can be SCHEDULED (fixed interval / CRON) or TRIGGERED (event-based)
- Tasks start in a SUSPENDED state — you must RESUME them
- Tasks can use a USER-MANAGED warehouse or SERVERLESS compute
- Tasks can be chained into TASK GRAPHS (DAGs) for complex pipelines
- Tasks run as a SYSTEM SERVICE by default (decoupled from any user)
- Only ONE instance of a scheduled task runs at a time (no overlap by default)
- Tasks support SQL, JavaScript, Python, Java, Scala, and Snowflake Scripting

**Analogy:** Imagine an alarm clock (task) in a factory (Snowflake). The alarm (schedule) rings every hour. When it rings, a worker (warehouse) performs a specific job (SQL). If the job isn't done when the next alarm rings, that ring is skipped. You can also set the alarm to ring only when a delivery arrives (stream trigger).

### 1.2 What Problems Do Tasks Solve?

**WITHOUT tasks:** External schedulers, manual execution, polling loops, complex orchestration, idle warehouses.

**WITH tasks:** Native scheduling, event-driven execution, serverless compute, task graphs, built-in retry/suspend/monitoring, tight stream integration.

---

## Part 2: Internal Architecture — How Tasks Work

### 2.1 High-Level Execution Model

```
┌────────────────────────────────────────────────────────────────────┐
│                    SNOWFLAKE CLOUD SERVICES LAYER                   │
│                                                                    │
│   ┌──────────────────────────────────────────────────────────┐    │
│   │              TASK SCHEDULER (Global Service)              │    │
│   │  • Maintains queue of all active (resumed) tasks         │    │
│   │  • Evaluates SCHEDULE intervals and CRON expressions     │    │
│   │  • For triggered tasks: polls SYSTEM$STREAM_HAS_DATA()   │    │
│   │  • Ensures single-instance execution (no overlap)        │    │
│   │  • Manages task graph dependency ordering                │    │
│   └──────────────────────┬───────────────────────────────────┘    │
│                          │ "Time to run task X"                   │
│                          ▼                                        │
│   ┌──────────────────────────────────────────────────────────┐    │
│   │              TASK EXECUTION ENGINE                        │    │
│   │  • Acquires compute (serverless auto or user WH queue)   │    │
│   │  • Creates new SESSION with task owner's privileges      │    │
│   │  • Executes SQL / stored procedure                       │    │
│   │  • Records result: SUCCEEDED, FAILED, SKIPPED, CANCELLED│    │
│   │  • Advances stream offset if consumed in DML             │    │
│   │  • Triggers child tasks in the task graph                │    │
│   └──────────────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────────────┘
```

**Key Points:**
1. The SCHEDULER lives in the Cloud Services Layer (always on, no warehouse)
2. The EXECUTION happens in the Compute Layer (warehouse or serverless)
3. The scheduler and execution engine are DECOUPLED
4. Task metadata is in the Metadata Layer

### 2.2 Task Lifecycle — State Machine

```
┌──────────┐   ALTER TASK RESUME   ┌──────────┐
│ SUSPENDED │ ──────────────────→  │  STARTED  │
│ (created) │ ←──────────────────  │ (active)  │
└──────────┘   ALTER TASK SUSPEND  └─────┬─────┘
                                         │
                               Schedule fires / Stream has data
                                         │
                                         ▼
                                  ┌────────────┐
                                  │  EXECUTING  │
                                  └──────┬─────┘
                                         │
                           ┌──────────┬──┴──────────┐
                           ▼          ▼              ▼
                     ┌──────────┐ ┌────────┐  ┌──────────┐
                     │ SUCCEEDED│ │ FAILED │  │ SKIPPED  │
                     └──────────┘ └────────┘  └──────────┘
                                      │
                           TASK_AUTO_RETRY_ATTEMPTS > 0?
                                      │
                                 ┌────▼────┐
                                 │  RETRY  │
                                 └─────────┘
```

| State | Description |
|-------|-------------|
| SUSPENDED | Created but not running. No scheduled runs. |
| STARTED | Active, following schedule/trigger. |
| EXECUTING | SQL currently running on compute. |
| SUCCEEDED | Completed successfully. |
| FAILED | Encountered an error. |
| SKIPPED | WHEN was FALSE, or overlap. |
| CANCELLED | Timeout or manual cancel. |

### 2.3 Task Duration Breakdown

- **Queuing Time** = QUERY_START_TIME - SCHEDULED_TIME
- **Execution Time** = COMPLETED_TIME - QUERY_START_TIME
- Serverless: auto-scales to minimize queuing
- User-managed: depends on warehouse availability

### 2.4 Versioning

When resumed or executed: Snowflake captures a VERSION. All runs use this version until suspended, modified, and resumed again. Running tasks are NOT affected by mid-flight modifications.

### 2.5 System Service Execution

By default, tasks run as a **SYSTEM SERVICE** (decoupled from any user, uses owner role's privileges). Alternative: `EXECUTE AS USER` for row access policies, masking policies, audit trails.

---

## Part 3: Compute Models

### 3.1 Serverless Tasks

Auto-managed compute. No WAREHOUSE parameter. Per-second billing. Auto-scales XS to XXLARGE. Requires EXECUTE MANAGED TASK. Best for frequent, short, bursty workloads.

### 3.2 User-Managed Warehouse Tasks

You specify WAREHOUSE. Standard billing with 60s minimum on resume. Best for heavy, long-running tasks or workloads exceeding XXLARGE.

### 3.3 Comparison

| Factor | Serverless | User-Managed WH |
|--------|-----------|-----------------|
| Warehouse parameter | Omitted | Required |
| Max compute size | XXLARGE | 6XL |
| Billing | Per-second actual | WH size + min 60s |
| Idle cost | None | If WH stays running |
| Auto-scaling | Yes | Manual sizing |
| Required privilege | EXECUTE MANAGED TASK | USAGE on warehouse |
| Best for | Frequent, short | Heavy, concurrent |

---

## Part 4: Scheduling — Fixed Schedule vs Triggered Tasks

### 4.1 Fixed Schedule

INTERVAL (`'N MINUTES'`) or CRON (`'USING CRON ...'`). If still running at next scheduled time → SKIPPED (default).

### 4.2 Triggered Tasks (Event-Driven)

Run ONLY when stream has data. No fixed schedule. Polls every 30s (default, configurable to 10s). Can combine SCHEDULE + WHEN.

### 4.3 Triggered Task Flow

```
Source Table → INSERT → Stream captures change → SYSTEM$STREAM_HAS_DATA = TRUE
→ Scheduler fires task → Task executes MERGE → Stream consumed → Offset advances
```

---

## Part 5: Task Graphs (DAGs) — Multi-Step Pipelines

### 5.1 What is a Task Graph?

A DAG of tasks with parent-child dependencies. Max 1000 tasks, 100 parents/children per task. Same owner role and schema.

```
        ┌────────────┐
        │  ROOT TASK │  ← SCHEDULE or WHEN
        └──────┬─────┘
          ┌────┴────┐
          ▼         ▼
    ┌──────────┐ ┌──────────┐
    │ CHILD B  │ │ CHILD C  │  ← PARALLEL
    └────┬─────┘ └────┬─────┘
         └──────┬─────┘
                ▼
         ┌──────────┐
         │ CHILD D  │  ← Waits for BOTH B and C
         └──────────┘
                │
         ┌──────────────┐
         │  FINALIZER   │  ← Runs after ALL complete/fail
         └──────────────┘
```

### 5.2 Execution Rules

- Same parent → children run in PARALLEL
- Multiple parents → child waits for ALL
- Suspended parents treated as succeeded (skipped)

### 5.3 Finalizer Task

Runs after entire graph completes. Used for cleanup, notifications, error correction. Does NOT run if root was skipped.

### 5.4 Overlap Policies

| Policy | Behavior |
|--------|----------|
| NO_OVERLAP (default) | Run skipped if previous still running |
| ALLOW_CHILD_OVERLAP | Root never overlaps; children can |
| ALLOW_ALL_OVERLAP | Full parallelism (dangerous with streams) |

### 5.5 Task Graph Communication

1. **Return values:** `SYSTEM$SET_RETURN_VALUE()` / `SYSTEM$GET_PREDECESSOR_RETURN_VALUE()`
2. **Config:** `CONFIG = '{...}'` / `SYSTEM$GET_TASK_GRAPH_CONFIG('key')`
3. **Runtime info:** `SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_NAME')`

### 5.6 Complete DAG Example — E-Commerce Order Processing

Full runnable example with 7 tasks: ingest_orders (root, triggered) → validate_orders + enrich_customers (parallel) → generate_invoices (converging) → update_inventory + send_notifications (parallel) → pipeline_finalizer.

```sql
-- Create tables, stream, all tasks, resume order, test data
-- See full SQL in the source guide
ALTER TASK pipeline_finalizer RESUME;
ALTER TASK send_notifications RESUME;
ALTER TASK update_inventory RESUME;
ALTER TASK generate_invoices RESUME;
ALTER TASK enrich_customers RESUME;
ALTER TASK validate_orders RESUME;
ALTER TASK ingest_orders RESUME;

-- OR:
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('ingest_orders');

-- Test:
INSERT INTO raw_orders VALUES
    (1001, 1, 101, 2, 49.99, '2026-04-29'),
    (1002, 2, 102, 1, 199.99, '2026-04-29'),
    (1003, 3, 103, 5, 9.99, '2026-04-29'),
    (1004, 1, 101, -1, 49.99, '2026-04-29');  -- invalid

-- Monitor:
SELECT * FROM TABLE(INFORMATION_SCHEMA.COMPLETE_TASK_GRAPHS())
ORDER BY SCHEDULED_TIME DESC;
```

---

## Part 6: Streams + Tasks — The CDC Pipeline Pattern

### 6.1 Why Streams + Tasks?

Streams capture WHAT changed. Tasks automate WHEN to process. Together = native CDC pipeline.

### 6.2 Basic Pattern

```sql
CREATE OR REPLACE STREAM raw_orders_stream ON TABLE raw_orders;

CREATE OR REPLACE TASK process_orders_task
    WAREHOUSE = 'COMPUTE_WH'
    WHEN SYSTEM$STREAM_HAS_DATA('raw_orders_stream')
AS
    MERGE INTO processed_orders AS t
    USING (SELECT *, METADATA$ACTION, METADATA$ISUPDATE FROM raw_orders_stream) AS s
    ON t.order_id = s.order_id
    WHEN MATCHED AND s.METADATA$ACTION = 'DELETE' AND s.METADATA$ISUPDATE = FALSE THEN DELETE
    WHEN MATCHED AND s.METADATA$ISUPDATE = TRUE THEN UPDATE SET ...
    WHEN NOT MATCHED AND s.METADATA$ACTION = 'INSERT' THEN INSERT ...;
```

### 6.3 Serverless Triggered Task + Stream

```sql
CREATE OR REPLACE TASK process_orders_serverless
    TARGET_COMPLETION_INTERVAL = '5 MINUTES'
    WHEN SYSTEM$STREAM_HAS_DATA('raw_orders_stream')
AS INSERT INTO processed_orders SELECT ... FROM raw_orders_stream;
```

### 6.4 Multi-Layer CDC (Bronze → Silver → Gold)

Separate streams at each layer. Root task: Bronze → Silver. Child task: Silver → Gold. Finalizer: audit log.

---

## Part 7: Error Handling, Retries & Suspension

### 7.1 Automatic Retry

`TASK_AUTO_RETRY_ATTEMPTS` (root, 0-30). Retries entire graph from failed task.

### 7.2 Auto-Suspend

`SUSPEND_TASK_AFTER_NUM_FAILURES` (default 10). Set 0 to disable.

### 7.3 Manual Retry

```sql
EXECUTE TASK my_root_task RETRY LAST;
-- Available up to 14 days after failure.
```

### 7.4 Timeouts

`USER_TASK_TIMEOUT_MS` on root = entire graph. On child = that child only. Lowest non-zero value wins when combined with `STATEMENT_TIMEOUT_IN_SECONDS`.

---

## Part 8: Access Privileges

| Action | Required Privileges |
|--------|-------------------|
| Create task | CREATE TASK on schema + EXECUTE MANAGED TASK (serverless) |
| Run task | EXECUTE TASK + EXECUTE MANAGED TASK (serverless) + USAGE on db/schema/wh |
| Resume/Suspend | OPERATE on task |
| View history | OWNERSHIP, MONITOR, OPERATE, or ACCOUNTADMIN |

```sql
CREATE ROLE taskadmin;
GRANT EXECUTE TASK ON ACCOUNT TO ROLE taskadmin;
GRANT EXECUTE MANAGED TASK ON ACCOUNT TO ROLE taskadmin;
GRANT CREATE TASK ON SCHEMA my_db.my_schema TO ROLE taskadmin;
GRANT USAGE ON DATABASE my_db TO ROLE taskadmin;
GRANT USAGE ON SCHEMA my_db.my_schema TO ROLE taskadmin;
GRANT USAGE ON WAREHOUSE compute_wh TO ROLE taskadmin;
```

---

## Part 9: Task Management Commands (SQL Reference)

### 9.1 CREATE TASK

```sql
CREATE TASK t WAREHOUSE = 'WH' SCHEDULE = '5 MINUTES' AS ...;
CREATE TASK t SCHEDULE = '5 MINUTES' AS ...;  -- serverless
CREATE TASK t WAREHOUSE = 'WH' WHEN SYSTEM$STREAM_HAS_DATA('s') AS ...;
CREATE TASK t TARGET_COMPLETION_INTERVAL = '10 MIN' WHEN ... AS ...;
CREATE TASK t WAREHOUSE = 'WH' AFTER parent_task AS ...;
CREATE TASK t WAREHOUSE = 'WH' FINALIZE = root_task AS ...;
```

### 9.2 ALTER, SHOW, DESCRIBE, EXECUTE, DROP

```sql
ALTER TASK t RESUME;
ALTER TASK t SUSPEND;
ALTER TASK t SET SCHEDULE = '10 MINUTES';
ALTER TASK t SET WAREHOUSE = 'LARGE_WH';
ALTER TASK t MODIFY WHEN SYSTEM$STREAM_HAS_DATA('new_stream');
ALTER TASK t REMOVE AFTER parent_task;
SHOW TASKS;
SHOW TASKS IN SCHEMA my_db.my_schema;
DESCRIBE TASK t;
EXECUTE TASK t;
EXECUTE TASK t RETRY LAST;
DROP TASK t;
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('root_task');
```

### 9.3 Monitoring

```sql
SELECT SYSTEM$STREAM_HAS_DATA('my_stream');
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'T'));
SELECT * FROM TABLE(INFORMATION_SCHEMA.CURRENT_TASK_GRAPHS());
SELECT * FROM TABLE(INFORMATION_SCHEMA.COMPLETE_TASK_GRAPHS());
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_DEPENDENTS(TASK_NAME => 'root', RECURSIVE => TRUE));
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY;
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY;
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_VERSIONS WHERE TASK_NAME = 'T';
```

---

## Part 10: SQL Examples — From Basic to Advanced

### 10.1 Simplest Task

```sql
CREATE OR REPLACE TASK hello_task
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '1 MINUTE'
AS INSERT INTO task_log VALUES (CURRENT_TIMESTAMP(), 'Hello from task!');

ALTER TASK hello_task RESUME;
```

### 10.2 Serverless with CRON

```sql
CREATE OR REPLACE TASK daily_cleanup
    SCHEDULE = 'USING CRON 0 2 * * * UTC'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
AS DELETE FROM staging_table WHERE loaded_at < DATEADD('day', -30, CURRENT_TIMESTAMP());
```

### 10.3 Multiple Streams (OR)

```sql
CREATE OR REPLACE TASK process_any_change
    WAREHOUSE = 'COMPUTE_WH'
    WHEN SYSTEM$STREAM_HAS_DATA('orders_stream')
      OR SYSTEM$STREAM_HAS_DATA('returns_stream')
AS
    BEGIN
        INSERT INTO customer_activity SELECT ... FROM orders_stream WHERE METADATA$ACTION = 'INSERT';
        INSERT INTO customer_activity SELECT ... FROM returns_stream WHERE METADATA$ACTION = 'INSERT';
    END;
```

### 10.4 Multiple Streams (AND)

```sql
CREATE OR REPLACE TASK process_both_ready
    WAREHOUSE = 'COMPUTE_WH'
    WHEN SYSTEM$STREAM_HAS_DATA('orders_stream')
     AND SYSTEM$STREAM_HAS_DATA('inventory_stream')
AS INSERT INTO fulfillment_queue SELECT ... FROM orders_stream o JOIN inventory_stream i ON ...;
```

### 10.5 Scheduled + WHEN Guard

```sql
CREATE OR REPLACE TASK hourly_if_data
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '60 MINUTES'
    WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS INSERT INTO target SELECT * FROM my_stream WHERE METADATA$ACTION = 'INSERT';
-- Runs hourly, but ONLY if data exists. Saves compute.
```

### 10.6 Task Graph with Return Values

```sql
CREATE OR REPLACE TASK graph_root
    SCHEDULE = '5 MINUTES'
    CONFIG = '{"batch_id": "auto"}'
    TASK_AUTO_RETRY_ATTEMPTS = 1
AS BEGIN LET batch_id := (SELECT UUID_STRING()); CALL SYSTEM$SET_RETURN_VALUE(:batch_id); END;

CREATE OR REPLACE TASK graph_extract
    WAREHOUSE = 'COMPUTE_WH' AFTER graph_root
AS BEGIN
    LET batch_id := (SELECT SYSTEM$GET_PREDECESSOR_RETURN_VALUE('GRAPH_ROOT'));
    INSERT INTO extract_log VALUES (:batch_id, CURRENT_TIMESTAMP(), 'DONE');
    CALL SYSTEM$SET_RETURN_VALUE('extracted 1000 rows');
END;

CREATE OR REPLACE TASK graph_transform
    WAREHOUSE = 'COMPUTE_WH' AFTER graph_extract
AS BEGIN
    LET result := (SELECT SYSTEM$GET_PREDECESSOR_RETURN_VALUE('GRAPH_EXTRACT'));
    INSERT INTO transform_log VALUES (CURRENT_TIMESTAMP(), :result);
END;

CREATE OR REPLACE TASK graph_finalizer
    WAREHOUSE = 'COMPUTE_WH' FINALIZE = graph_root
AS INSERT INTO pipeline_status VALUES ('ETL_PIPELINE', CURRENT_TIMESTAMP(), 'DONE');
```

### 10.7 Stored Procedure Task

```sql
CREATE OR REPLACE TASK daily_etl_task
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = 'USING CRON 0 6 * * * America/New_York'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
AS CALL process_daily_etl();
```

### 10.8 EXECUTE AS USER

```sql
CREATE OR REPLACE TASK user_context_task
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '30 MINUTES'
    EXECUTE AS USER my_service_user
AS INSERT INTO audit_log VALUES (CURRENT_USER(), CURRENT_ROLE(), CURRENT_TIMESTAMP());
```

---

## Part 11: Billing & Cost Model

### 11.1 Cost Overview

| Type | Billing | Idle Cost |
|------|---------|-----------|
| Serverless | Per-second actual usage | None |
| User-managed WH | Standard WH billing (60s min) | If WH stays running |
| Scheduler | Cloud services (minimal) | None |
| Skipped tasks | No compute charge | None |

### 11.2 Monitoring Costs

```sql
SELECT TASK_NAME, SUM(CREDITS_USED) AS total_credits,
       COUNT(*) AS run_count, AVG(CREDITS_USED) AS avg_per_run
FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY
WHERE START_TIME > DATEADD('day', -30, CURRENT_TIMESTAMP())
GROUP BY TASK_NAME ORDER BY total_credits DESC;
```

### 11.3 Cost Optimization

1. Use triggered tasks (avoid empty runs)
2. Use serverless (no idle costs)
3. Set SUSPEND_TASK_AFTER_NUM_FAILURES
4. Right-size warehouse
5. Combine SCHEDULE + WHEN
6. Set USER_TASK_TIMEOUT_MS
7. Monitor regularly

---

## Part 12: Tricky Scenarios & Gotchas

| Scenario | Cause | Fix |
|----------|-------|-----|
| Can't see task in TASK_HISTORY | Lack privileges | GRANT MONITOR ON TASK |
| Task resumed but never fires | No stream data / missing EXECUTE TASK | Check SYSTEM$STREAM_HAS_DATA; check grants |
| Child runs after suspension | Already queued | Wait for current run |
| Two tasks, second gets no data | Shared stream consumed | One stream per task |
| Graph longer than schedule | NO_OVERLAP skips | Bigger WH, wider schedule, or triggered |
| Ownership transfer stops task | Auto-pauses | New owner must RESUME |
| Modified child runs old code | Versioning | Suspend root → modify → resume root |
| Serverless oversized WH | Auto-scaling considers interval | Cap with MAX_STATEMENT_SIZE |

---

## Part 13: Interview Questions — Level 1: Beginner

**Q1: What is a Snowflake task?**
> A task automates execution of a single SQL statement or stored procedure on a schedule or in response to an event. It's Snowflake's native job scheduler.

**Q2: What state does a task start in?**
> SUSPENDED. You must `ALTER TASK ... RESUME`.

**Q3: Two compute models?**
> Serverless (auto-managed, no WAREHOUSE) and User-managed (specify WAREHOUSE).

**Q4: What is WHEN for?**
> Triggered tasks — runs only when condition is true (e.g., `SYSTEM$STREAM_HAS_DATA`).

**Q5: Manually run a task?**
> `EXECUTE TASK my_task;`

**Q6: Schedule overlap behavior?**
> Default NO_OVERLAP: scheduled run is SKIPPED.

**Q7: Check task history?**
> `SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'T'));`

**Q8: Minimum schedule interval?**
> 10 seconds (scheduled). 30 seconds default trigger polling (configurable to 10s).

---

## Part 14: Interview Questions — Level 2: Intermediate

**Q9: Scheduled vs triggered?**
> Scheduled = fixed intervals. Triggered = only when stream has data. Can combine both.

**Q10: What is a task graph?**
> DAG with ROOT (schedule/trigger) → CHILD (AFTER) → optional FINALIZER. Same parent children run parallel.

**Q11: Resume all at once?**
> `SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('root');`

**Q12: Finalizer?**
> Runs after ALL tasks complete (success/failure). One per root. Does NOT run if root skipped.

**Q13: Suspend a child?**
> Graph continues as if child succeeded. Downstream tasks still run.

**Q14: Timeouts?**
> USER_TASK_TIMEOUT_MS (graph/task level). STATEMENT_TIMEOUT_IN_SECONDS (per-statement). Lowest wins.

**Q15: Versioning?**
> Set when root resumed. All tasks use that version until suspended+modified+resumed.

**Q16: Serverless privileges?**
> CREATE TASK + EXECUTE MANAGED TASK. OPERATE to resume/suspend.

---

## Part 15: Interview Questions — Level 3: Advanced

**Q17: Task communication?**
> Return values (SET/GET_RETURN_VALUE), Config (GET_TASK_GRAPH_CONFIG), Runtime info (TASK_RUNTIME_INFO).

**Q18: Three overlap policies?**
> NO_OVERLAP (skip), ALLOW_CHILD_OVERLAP (root safe, children can overlap), ALLOW_ALL_OVERLAP (full parallel, dangerous with streams).

**Q19: Serverless auto-scaling?**
> Considers schedule interval + history. Scales up at ~90% of interval. Bounded by MIN/MAX_STATEMENT_SIZE.

**Q20: Stream consumption in transactions?**
> Repeatable read. Offset advances on COMMIT only. Failure = no advance = at-least-once. MERGE = effectively exactly-once.

**Q21: Owner role dropped?**
> Ownership transfers, task auto-pauses. New owner must resume.

**Q22: Stream consumed by wrong task?**
> One stream per task. Streams are cheap (just an offset).

**Q23: Limitations?**
> Single SQL/procedure. Max 1000 tasks/graph. Same owner+schema. Serverless max XXLARGE. No hybrid table triggers.

---

## Part 16: Interview Questions — Level 4: Architect

**Q24: Production CDC pipeline design?**
> Snowpipe → raw table → stream → triggered serverless task → MERGE → curated → stream → child → reporting. Finalizer for audit. Retry=2, suspend after 5.

**Q25: Streams+Tasks vs Dynamic Tables?**
> S+T: Full CDC (I/U/D), custom logic, complex error handling. DT: Declarative, no delete propagation. Use S+T for Bronze→Silver, DT for Silver→Gold.

**Q26: Fault-tolerant multi-hop?**
> Separate stream+task per hop. Independent hops. MERGE for idempotency. Retry + auto-suspend. Finalizers. Dead letter tables.

**Q27: Monitor task health?**
> Task failures, duration trends, stream staleness, backlog, cost monitoring, freshness SLA, reconciliation.

**Q28: Tasks during failover?**
> Definitions/state replicated. In-flight NOT transferred. Resumed tasks pick up from last committed offset.

**Q29: Late-arriving data?**
> Stream captures normally. Task processes next run. Use event_timestamp + conditional MERGE for ordering.

**Q30: E-commerce pipeline?**
> Root (ingest) → parallel (validate, enrich, fraud) → converging (process) → parallel (inventory, notifications) → finalizer.

**Q31: Exactly-once semantics?**
> Exactly-once ingestion + at-least-once consumption + idempotent MERGE = effectively exactly-once.

**Q32: Migrate from Airflow?**
> DAG → Task Graph. Schedule → SCHEDULE. Sensors → WHEN. XCom → RETURN_VALUE. on_failure → Finalizer.

---

## Part 17: Quick Reference Cheat Sheet

### CREATE TASK

| Type | Syntax |
|------|--------|
| Scheduled WH | `CREATE TASK t WAREHOUSE='WH' SCHEDULE='5 MIN' AS ...;` |
| Scheduled SL | `CREATE TASK t SCHEDULE='5 MIN' AS ...;` |
| CRON | `CREATE TASK t SCHEDULE='USING CRON 0 9 * * * UTC' AS ...;` |
| Triggered WH | `CREATE TASK t WAREHOUSE='WH' WHEN SYSTEM$STREAM_HAS_DATA('s') AS ...;` |
| Triggered SL | `CREATE TASK t TARGET_COMPLETION_INTERVAL='5 MIN' WHEN ... AS ...;` |
| Child | `CREATE TASK t AFTER parent_task AS ...;` |
| Finalizer | `CREATE TASK t FINALIZE = root_task AS ...;` |

### MANAGE

```sql
ALTER TASK t RESUME;
ALTER TASK t SUSPEND;
EXECUTE TASK t;
EXECUTE TASK t RETRY LAST;
DROP TASK t;
SELECT SYSTEM$TASK_DEPENDENTS_ENABLE('root');
```

### MONITOR

```sql
SHOW TASKS;
DESCRIBE TASK t;
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'T'));
SELECT * FROM TABLE(INFORMATION_SCHEMA.CURRENT_TASK_GRAPHS());
SELECT * FROM TABLE(INFORMATION_SCHEMA.COMPLETE_TASK_GRAPHS());
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.TASK_HISTORY;
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.SERVERLESS_TASK_HISTORY;
```

### GRAPH COMMUNICATION

```sql
CALL SYSTEM$SET_RETURN_VALUE('value');
SELECT SYSTEM$GET_PREDECESSOR_RETURN_VALUE('PARENT_TASK');
SELECT SYSTEM$GET_TASK_GRAPH_CONFIG('key');
SELECT SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_NAME');
```

### KEY PARAMETERS

| Parameter | Purpose |
|-----------|---------|
| SCHEDULE | Fixed interval or CRON |
| WAREHOUSE | User-managed compute |
| TARGET_COMPLETION_INTERVAL | Serverless triggered tasks |
| WHEN | Trigger condition |
| AFTER | Parent dependency |
| FINALIZE | Finalizer for root |
| CONFIG | JSON config for graph |
| TASK_AUTO_RETRY_ATTEMPTS | Auto-retry (default 0) |
| SUSPEND_TASK_AFTER_NUM_FAILURES | Auto-suspend (default 10) |
| USER_TASK_TIMEOUT_MS | Max runtime (default 1 hour) |
| OVERLAP_POLICY | NO_OVERLAP / ALLOW_CHILD / ALLOW_ALL |
| SERVERLESS_TASK_MIN_STATEMENT_SIZE | Min WH (default XS) |
| SERVERLESS_TASK_MAX_STATEMENT_SIZE | Max WH (default XXLARGE) |
| EXECUTE AS USER | Run as specific user |

### TASK STATES

```
SUSPENDED → STARTED (resume) → EXECUTING → SUCCEEDED / FAILED / SKIPPED
```

---

## Part 18: Overlap Scenario — Deep Dive with Real Example

### The Problem

Task runs every 5 minutes but sometimes takes 7 minutes. NO_OVERLAP skips next run → data piles up → snowball effect.

```
T=0min   Run #1 starts (3 min data) → completes T=3min
T=5min   Run #2 starts (2 min data) → takes 7 min...
T=10min  Run #3 SCHEDULED but #2 still running → SKIPPED!
T=12min  Run #2 completes
T=15min  Run #4 starts (8 min combined data) → even longer → more skips
```

No data loss (stream accumulates), but latency increases.

### Solution 1: Triggered Tasks (BEST for Streams)

```sql
CREATE OR REPLACE TASK sensor_agg_triggered
    WAREHOUSE = 'COMPUTE_WH'
    WHEN SYSTEM$STREAM_HAS_DATA('sensor_stream')
AS INSERT INTO sensor_summary SELECT ... FROM sensor_stream GROUP BY sensor_id;
```

No fixed schedule = no skips. Continuous processing.

### Solution 2: Wider Schedule Interval

Set to 2x worst-case. Trade-off: higher latency.

### Solution 3: Bigger Warehouse

Faster execution. Trade-off: higher cost.

### Solution 4: Serverless

```sql
CREATE OR REPLACE TASK sensor_agg_serverless
    TARGET_COMPLETION_INTERVAL = '5 MINUTES'
    WHEN SYSTEM$STREAM_HAS_DATA('sensor_stream')
AS INSERT INTO sensor_summary SELECT ... FROM sensor_stream GROUP BY sensor_id;
```

### Solution 5: Allow Overlap (CAUTION)

Only for idempotent non-stream tasks. DANGEROUS with streams.

### Solution 6: Task Graph (Parallel Children)

Split work across parallel children processing subsets.

### Monitoring Overlaps

```sql
-- Skipped runs:
SELECT NAME, STATE, SCHEDULED_TIME FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
)) WHERE STATE = 'SKIPPED' ORDER BY SCHEDULED_TIME DESC;

-- Duration alerts (>80% of 5-min schedule = 240s):
SELECT NAME, DATEDIFF('second', SCHEDULED_TIME, COMPLETED_TIME) AS duration_sec
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD('day', -1, CURRENT_TIMESTAMP())
)) WHERE STATE = 'SUCCEEDED' AND DATEDIFF('second', SCHEDULED_TIME, COMPLETED_TIME) > 240;
```

### Which Solution?

| Situation | Best Solution |
|-----------|---------------|
| Stream-based CDC (most common) | Triggered tasks |
| Occasional slow runs | Wider schedule |
| Consistent high volume | Bigger warehouse |
| Variable/bursty volume | Serverless |
| Parallelizable heavy task | Task graph |
| Idempotent non-stream | ALLOW_OVERLAP (caution) |

**GOLDEN RULE:** For stream-based pipelines, use TRIGGERED TASKS.

---

## Part 19: Minimum Schedule Interval — Deep Dive with Examples

### Two Types of Intervals

1. **Scheduled tasks:** Minimum = **10 seconds**
2. **Triggered tasks:** Default poll = **30 seconds**, configurable to **10 seconds**

### 19.1 Scheduled — Minimum 10 Seconds

```sql
CREATE OR REPLACE TASK heartbeat_10s
    WAREHOUSE = 'COMPUTE_WH'
    SCHEDULE = '10 SECONDS'
AS INSERT INTO heartbeat_log (message) VALUES ('heartbeat');
-- Less than 10s: ERROR "Schedule interval must be at least 10 seconds"
```

### 19.3 Triggered — Default 30-Second Polling

Up to 30 seconds latency between data arriving and task starting (polling gap).

### 19.4 Lower to 10 Seconds

```sql
CREATE OR REPLACE TASK trigger_fast_10s
    WAREHOUSE = 'COMPUTE_WH'
    USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 10
    WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS INSERT INTO target SELECT * FROM my_stream WHERE METADATA$ACTION = 'INSERT';

-- Or account-level:
-- ALTER ACCOUNT SET USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 10;
```

### 19.5 Serverless + TARGET_COMPLETION_INTERVAL

```sql
CREATE OR REPLACE TASK trigger_serverless_fast
    TARGET_COMPLETION_INTERVAL = '1 MINUTE'
    USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 10
    WHEN SYSTEM$STREAM_HAS_DATA('my_stream')
AS INSERT INTO target SELECT * FROM my_stream WHERE METADATA$ACTION = 'INSERT';
-- End-to-end: 10s poll + up to 60s processing = ~70s max
```

### 19.6 Latency Comparison

| Configuration | Poll Interval | End-to-End Latency |
|---------------|--------------|-------------------|
| SCHEDULE = '10 SECONDS' (always runs) | 10s fixed | 10-12s |
| SCHEDULE = '1 MINUTE' (always runs) | 60s fixed | 60-62s |
| WHEN (default 30s poll) | 30s | 30-60s |
| WHEN (10s poll) | 10s | 10-20s |
| SCHEDULE + WHEN (combined) | 10s fixed | 10-12s (skips empty) |

**Recommendations:**
- **Lowest latency + cost efficient** → Triggered + 10s poll
- **Lowest latency + simple** → SCHEDULE = '10 SECONDS' + WHEN
- **Lowest cost** → Triggered + default 30s

### 19.7 Practical Latency Test

```sql
CREATE OR REPLACE TABLE latency_test_source (test_id INT, inserted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP());
CREATE OR REPLACE TABLE latency_test_result (test_id INT, inserted_at TIMESTAMP, processed_at TIMESTAMP, latency_sec DECIMAL(10,2), task_type STRING);
CREATE OR REPLACE STREAM latency_stream ON TABLE latency_test_source;

CREATE OR REPLACE TASK latency_test_task
    WAREHOUSE = 'COMPUTE_WH'
    USER_TASK_MINIMUM_TRIGGER_INTERVAL_IN_SECONDS = 10
    WHEN SYSTEM$STREAM_HAS_DATA('latency_stream')
AS INSERT INTO latency_test_result
    SELECT test_id, inserted_at, CURRENT_TIMESTAMP(),
        DATEDIFF('millisecond', inserted_at, CURRENT_TIMESTAMP()) / 1000.0,
        'triggered_10s_poll'
    FROM latency_stream WHERE METADATA$ACTION = 'INSERT';

ALTER TASK latency_test_task RESUME;

-- Test: INSERT INTO latency_test_source VALUES (1, CURRENT_TIMESTAMP());
-- Check: SELECT * FROM latency_test_result ORDER BY test_id;
-- Expected latency: ~10-20 seconds
```

---

*End of Snowflake Tasks Complete Guide*
