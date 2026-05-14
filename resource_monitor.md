# Snowflake Resource Monitors — Complete Guide

**Control Costs, Set Credit Limits & Get Alerts**

---

## Table of Contents

- [Part 1: Fundamentals](#part-1-fundamentals)
  - [1. What is a Resource Monitor?](#1-what-is-a-resource-monitor)
  - [2. Why Do You Need One?](#2-why-do-you-need-one)
  - [3. Key Properties](#3-key-properties)
  - [4. Account-Level vs Warehouse-Level Monitors](#4-account-level-vs-warehouse-level-monitors)
- [Part 2: Creating Resource Monitors](#part-2-creating-resource-monitors)
  - [5. Basic Monitor](#5-basic-monitor-default-schedule)
  - [6. Custom Schedule](#6-monitor-with-custom-schedule)
  - [7. Multiple Triggers](#7-monitor-with-multiple-triggers)
  - [8. User Notifications](#8-monitor-with-user-notifications)
  - [9. Account-Level Monitor](#9-account-level-monitor)
- [Part 3: Trigger Actions Deep Dive](#part-3-trigger-actions-deep-dive)
  - [10. NOTIFY](#10-notify--alert-without-stopping)
  - [11. SUSPEND](#11-suspend--graceful-shutdown)
  - [12. SUSPEND_IMMEDIATE](#12-suspend_immediate--emergency-kill)
  - [13. Combining Triggers](#13-combining-triggers-the-layered-approach)
  - [14. Thresholds Greater Than 100%](#14-thresholds-greater-than-100)
- [Part 4: Assigning & Managing](#part-4-assigning--managing)
  - [15. Assign to Warehouse](#15-assign-monitor-to-a-warehouse)
  - [16. Assign to Account](#16-assign-monitor-to-account)
  - [17. Unassign / Remove](#17-unassign--remove-a-monitor)
  - [18. Modify (ALTER)](#18-modify-an-existing-monitor-alter)
  - [19. Drop](#19-drop-a-resource-monitor)
- [Part 5: Real-World Scenarios](#part-5-real-world-scenarios)
  - [20. Dev/Test Cost Cap](#20-devtest-warehouse-cost-cap)
  - [21. Production Early Warnings](#21-production-warehouse-with-early-warnings)
  - [22. Account-Wide Budget](#22-account-wide-monthly-budget)
  - [23. Time-Boxed Project](#23-time-boxed-project-end_timestamp)
  - [24. Weekly Reset](#24-weekly-reset-for-data-engineering-team)
  - [25. One-Time Budget](#25-one-time-budget-frequency--never)
- [Part 6: Gotchas & Edge Cases](#part-6-gotchas--edge-cases)
  - [26. ALTER Replaces ALL Triggers](#26-alter-triggers-replaces-all-triggers-critical)
  - [27. Suspended WH Won't Resume](#27-suspended-warehouse-wont-resume)
  - [28. Cloud Services Still Accumulate](#28-cloud-services-credits-still-accumulate)
  - [29. Serverless Not Covered](#29-serverless-features-not-covered)
  - [30. Reset at Midnight UTC](#30-reset-time-is-always-1200-am-utc)
  - [31. Not Real-Time](#31-resource-monitor-is-not-real-time)
- [Part 7: Monitoring & Metadata](#part-7-monitoring--metadata)
- [Part 8: Access Control & Privileges](#part-8-access-control--privileges)
- [Part 9: Best Practices Summary](#part-9-best-practices-summary)

---

## Part 1: Fundamentals

### 1. What is a Resource Monitor?

A resource monitor is a Snowflake object that tracks **credit usage** by virtual warehouses and triggers actions (alerts, suspension) when usage reaches defined thresholds.

Think of it as a **credit card limit** for your warehouses:

> "You can spend up to 1000 credits this month. Warn me at 75%. Suspend the warehouse at 100%. Kill it immediately at 110%."

---

### 2. Why Do You Need One?

**Without resource monitors:**
- A runaway query on an XL warehouse burns credits for hours
- A developer accidentally leaves a 4XL warehouse running all weekend
- A misconfigured pipeline auto-resumes a warehouse in an infinite loop
- Month-end bill is 3x what you expected with no warning

**With resource monitors:**
- You get email alerts BEFORE the budget is exceeded
- Warehouses auto-suspend when limits are reached
- Each team/warehouse has its own credit cap
- No more surprise bills

---

### 3. Key Properties

| Property | Description |
|----------|-------------|
| **CREDIT_QUOTA** | Number of credits allowed per interval. When usage hits this, the monitor is at 100%. |
| **FREQUENCY** | How often used credits reset to 0. `DAILY` \| `WEEKLY` \| `MONTHLY` \| `YEARLY` \| `NEVER`. Default: start of each calendar month. |
| **START_TIMESTAMP** | When monitoring begins. `IMMEDIATELY` or a specific timestamp. Required if FREQUENCY is set. |
| **END_TIMESTAMP** | When monitoring ends (optional). All assigned warehouses are suspended at this time regardless of credit usage. |
| **TRIGGERS** | Actions at specific % thresholds: `NOTIFY` \| `SUSPEND` \| `SUSPEND_IMMEDIATE` |
| **NOTIFY_USERS** | List of users to receive email notifications. Each must have a verified email. |

---

### 4. Account-Level vs Warehouse-Level Monitors

| Feature | Account-Level | Warehouse-Level |
|---------|--------------|-----------------|
| Count | ONE per account | Multiple per account |
| Scope | Monitors ALL warehouses | Monitors assigned warehouse(s) only |
| Assigned via | `ALTER ACCOUNT` | `ALTER WAREHOUSE` |
| NOTIFY_USERS | Not allowed | Allowed (up to 5) |
| Serverless | Does NOT cover | Does NOT cover |

Both can be active simultaneously. If **either** reaches its threshold, the warehouse is suspended.

> **Example:** Account monitor: 5000 credits/month. WH monitor: 1000 credits/month for ETL. The ETL warehouse is suspended when EITHER limit is hit.

---

## Part 2: Creating Resource Monitors

### 5. Basic Monitor (Default Schedule)

Default: Starts immediately, resets at the start of each calendar month.

```sql
USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE RESOURCE MONITOR basic_monitor
    WITH CREDIT_QUOTA = 1000
    TRIGGERS ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = basic_monitor;
```

- Credits reset to 0 on the 1st of each month
- When COMPUTE_WH uses 1000 credits, it is suspended
- Running queries finish, but no new queries are accepted

---

### 6. Monitor with Custom Schedule

```sql
CREATE OR REPLACE RESOURCE MONITOR weekly_monitor
    WITH CREDIT_QUOTA = 500
    FREQUENCY = WEEKLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 80 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;

ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = weekly_monitor;
```

- Credits reset to 0 every week
- At 400 credits (80%), email notification sent
- At 500 credits (100%), warehouse suspended

---

### 7. Monitor with Multiple Triggers

The layered approach — warn early, suspend gracefully, kill if still running:

```sql
CREATE OR REPLACE RESOURCE MONITOR layered_monitor
    WITH CREDIT_QUOTA = 2000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 50 PERCENT DO NOTIFY            -- early warning at 1000 credits
             ON 75 PERCENT DO NOTIFY            -- second warning at 1500 credits
             ON 90 PERCENT DO NOTIFY            -- urgent warning at 1800 credits
             ON 100 PERCENT DO SUSPEND          -- graceful suspend at 2000 credits
             ON 110 PERCENT DO SUSPEND_IMMEDIATE; -- kill at 2200 credits

ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = layered_monitor;
```

---

### 8. Monitor with User Notifications

Send notifications to specific non-admin users (up to 5). Each user **must** have a verified email.

```sql
CREATE OR REPLACE RESOURCE MONITOR team_monitor
    WITH CREDIT_QUOTA = 1500
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    NOTIFY_USERS = (JDOE, "Jane Smith")
    TRIGGERS ON 75 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND
             ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE ANALYTICS_WH SET RESOURCE_MONITOR = team_monitor;
```

---

### 9. Account-Level Monitor

Monitors ALL warehouses across the entire account. Only **one** account-level monitor allowed.

```sql
CREATE OR REPLACE RESOURCE MONITOR account_guard
    WITH CREDIT_QUOTA = 10000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 75 PERCENT DO NOTIFY
             ON 90 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND
             ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER ACCOUNT SET RESOURCE_MONITOR = account_guard;
```

---

## Part 3: Trigger Actions Deep Dive

### 10. NOTIFY — Alert Without Stopping

- Sends email to account admins + users in NOTIFY_USERS
- Warehouse **keeps running**. No impact on queries.
- Up to **5 NOTIFY triggers** per monitor.

---

### 11. SUSPEND — Graceful Shutdown

At the threshold:
1. Currently running queries **finish normally**
2. No NEW queries are accepted
3. Warehouse transitions to SUSPENDED state
4. Email notification sent

Only **one** SUSPEND trigger per monitor.

---

### 12. SUSPEND_IMMEDIATE — Emergency Kill

At the threshold:
1. ALL running queries are **CANCELLED immediately**
2. Warehouse transitions to SUSPENDED state
3. Email notification sent

Use as a safety net **above** the SUSPEND threshold. Only **one** per monitor.

---

### 13. Combining Triggers (The Layered Approach)

```
 50% ──> NOTIFY       "Heads up, halfway through the budget"
 75% ──> NOTIFY       "Warning: 3/4 of budget consumed"
 90% ──> NOTIFY       "Urgent: approaching limit"
100% ──> SUSPEND      "Budget reached. Waiting for running queries to finish."
110% ──> SUSPEND_IMM  "Emergency stop. All queries cancelled."
```

**Limits per monitor:**
- Up to 5 NOTIFY triggers
- Exactly 1 SUSPEND trigger
- Exactly 1 SUSPEND_IMMEDIATE trigger

---

### 14. Thresholds Greater Than 100%

Thresholds > 100% are allowed and useful. Between SUSPEND (100%) and SUSPEND_IMMEDIATE (110%):

- Running queries continue to consume credits
- The warehouse is "suspended" but not yet killed
- If those queries push usage past 110%, they are cancelled

> **Example:** CREDIT_QUOTA = 1000. SUSPEND at 100% = 1000 credits. SUSPEND_IMMEDIATE at 110% = 1100 credits.

---

## Part 4: Assigning & Managing

### 15. Assign Monitor to a Warehouse

A warehouse can only have **one** resource monitor at a time.

```sql
ALTER WAREHOUSE COMPUTE_WH SET RESOURCE_MONITOR = layered_monitor;

-- Or during creation:
CREATE WAREHOUSE new_wh
    WAREHOUSE_SIZE = 'SMALL'
    RESOURCE_MONITOR = layered_monitor;
```

---

### 16. Assign Monitor to Account

```sql
ALTER ACCOUNT SET RESOURCE_MONITOR = account_guard;
```

---

### 17. Unassign / Remove a Monitor

```sql
-- Remove from warehouse
ALTER WAREHOUSE COMPUTE_WH UNSET RESOURCE_MONITOR;

-- Remove from account
ALTER ACCOUNT UNSET RESOURCE_MONITOR;
```

---

### 18. Modify an Existing Monitor (ALTER)

```sql
-- Increase quota
ALTER RESOURCE MONITOR layered_monitor SET CREDIT_QUOTA = 3000;

-- Change schedule
ALTER RESOURCE MONITOR layered_monitor
    SET FREQUENCY = WEEKLY
        START_TIMESTAMP = IMMEDIATELY;
```

> **CRITICAL GOTCHA: TRIGGERS ARE NOT ADDITIVE!**
> `ALTER ... TRIGGERS` replaces **ALL** existing triggers. You must re-specify the old triggers along with the new ones.

```sql
-- WRONG: This removes the SUSPEND and SUSPEND_IMMEDIATE triggers!
ALTER RESOURCE MONITOR layered_monitor
    TRIGGERS ON 80 PERCENT DO NOTIFY;

-- RIGHT: Include ALL triggers you want
ALTER RESOURCE MONITOR layered_monitor
    SET CREDIT_QUOTA = 3000
    TRIGGERS ON 50 PERCENT DO NOTIFY
             ON 75 PERCENT DO NOTIFY
             ON 80 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND
             ON 110 PERCENT DO SUSPEND_IMMEDIATE;
```

---

### 19. Drop a Resource Monitor

```sql
-- First unassign from all warehouses, then drop
ALTER WAREHOUSE COMPUTE_WH UNSET RESOURCE_MONITOR;
DROP RESOURCE MONITOR layered_monitor;
```

---

## Part 5: Real-World Scenarios

### 20. Dev/Test Warehouse Cost Cap

Developers shouldn't burn more than 200 credits/month. Aggressive limits.

```sql
CREATE OR REPLACE RESOURCE MONITOR dev_cap
    WITH CREDIT_QUOTA = 200
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 75 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND_IMMEDIATE;
```

---

### 21. Production Warehouse with Early Warnings

Production can't be killed mid-query. Graduated approach with generous buffer.

```sql
CREATE OR REPLACE RESOURCE MONITOR prod_monitor
    WITH CREDIT_QUOTA = 5000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 50 PERCENT DO NOTIFY
             ON 75 PERCENT DO NOTIFY
             ON 90 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND
             ON 120 PERCENT DO SUSPEND_IMMEDIATE;
```

---

### 22. Account-Wide Monthly Budget

Total budget for ALL warehouses across the account.

```sql
CREATE OR REPLACE RESOURCE MONITOR monthly_budget
    WITH CREDIT_QUOTA = 15000
    FREQUENCY = MONTHLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 80 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;

ALTER ACCOUNT SET RESOURCE_MONITOR = monthly_budget;
```

---

### 23. Time-Boxed Project (END_TIMESTAMP)

A project gets 3000 credits between Jan 1 and Mar 31. At the end date, warehouses are suspended regardless of usage.

```sql
CREATE OR REPLACE RESOURCE MONITOR project_x
    WITH CREDIT_QUOTA = 3000
    FREQUENCY = NEVER
    START_TIMESTAMP = '2026-01-01 00:00'
    END_TIMESTAMP = '2026-03-31 23:59'
    TRIGGERS ON 75 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;
```

---

### 24. Weekly Reset for Data Engineering Team

```sql
CREATE OR REPLACE RESOURCE MONITOR de_weekly
    WITH CREDIT_QUOTA = 800
    FREQUENCY = WEEKLY
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 50 PERCENT DO NOTIFY
             ON 90 PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND;
```

---

### 25. One-Time Budget (FREQUENCY = NEVER)

Give a team a fixed pool of credits. Once spent, warehouse is suspended. Credits **never** reset.

```sql
CREATE OR REPLACE RESOURCE MONITOR one_time_budget
    WITH CREDIT_QUOTA = 500
    FREQUENCY = NEVER
    START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 100 PERCENT DO SUSPEND_IMMEDIATE;
```

---

## Part 6: Gotchas & Edge Cases

### 26. ALTER TRIGGERS Replaces ALL Triggers (Critical!)

The TRIGGERS parameter is **NOT additive**. Running ALTER with TRIGGERS removes ALL existing triggers and replaces them.

| Action | Original Triggers | ALTER Command | Result |
|--------|------------------|---------------|--------|
| Bug | 50% NOTIFY, 100% SUSPEND | `TRIGGERS ON 80% NOTIFY` | **80% NOTIFY only** (SUSPEND gone!) |
| Correct | 50% NOTIFY, 100% SUSPEND | Include ALL triggers | All preserved |

> Always include **ALL** triggers when using ALTER ... TRIGGERS.

---

### 27. Suspended Warehouse Won't Resume

A warehouse suspended by a resource monitor CANNOT be resumed until:

1. The next interval starts (credits reset to 0)
2. The credit quota is increased
3. The trigger threshold is increased
4. The warehouse is unassigned from the monitor
5. The monitor is dropped

**Common fix:**

```sql
ALTER RESOURCE MONITOR layered_monitor SET CREDIT_QUOTA = 5000;
```

---

### 28. Cloud Services Credits Still Accumulate

Resource monitors track both warehouse AND cloud services credits, but they can only **SUSPEND warehouses** — not cloud services.

After suspension, metadata operations can still incur cloud services costs. The 10% daily cloud services adjustment is **NOT** factored into threshold calculations.

---

### 29. Serverless Features Not Covered

Resource monitors do **NOT** track or control:
- Snowpipe
- Auto-clustering
- Materialized view maintenance
- Search Optimization Service
- Serverless tasks
- Cortex AI functions

> For these, use **Snowflake Budgets** instead.

---

### 30. Reset Time is Always 12:00 AM UTC

Regardless of the time in START_TIMESTAMP, credits reset at **midnight UTC**.

- START = July 15 (Monday), FREQUENCY = MONTHLY → resets on the 15th each month
- START = July 15 (Monday), FREQUENCY = WEEKLY → resets every Monday

---

### 31. Resource Monitor is Not Real-Time

There can be a delay between when usage hits a threshold and when the action fires. Warehouses may consume a few extra credits before being suspended.

> **Best practice:** Set thresholds with a buffer. If your real limit is 1000 credits, set SUSPEND at 90% (900 credits).

---

## Part 7: Monitoring & Metadata

### 32. SHOW RESOURCE MONITORS

```sql
USE ROLE ACCOUNTADMIN;
SHOW RESOURCE MONITORS;
```

**Key columns:**

| Column | Description |
|--------|-------------|
| `NAME` | Monitor name |
| `CREDIT_QUOTA` | Total credits allocated |
| `USED_CREDITS` | Credits consumed so far this interval |
| `REMAINING_CREDITS` | Quota minus used |
| `LEVEL` | ACCOUNT or WAREHOUSE (or NULL if unassigned) |
| `FREQUENCY` | Reset interval |
| `NOTIFY_AT` | Comma-separated NOTIFY thresholds |
| `SUSPEND_AT` | SUSPEND threshold |
| `SUSPEND_IMMEDIATELY_AT` | SUSPEND_IMMEDIATE threshold |

### 33. Check Warehouse Assignments

```sql
SHOW WAREHOUSES;
-- Check the RESOURCE_MONITOR column. NULL = no monitor assigned.
```

### 34. Account Usage View

```sql
SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.RESOURCE_MONITORS;
```

---

## Part 8: Access Control & Privileges

| Action | Required Role/Privilege |
|--------|----------------------|
| Create resource monitor | ACCOUNTADMIN only |
| Assign to account | ACCOUNTADMIN only |
| Assign to warehouse | ACCOUNTADMIN only |
| View in Snowsight | ACCOUNTADMIN only |
| View via SQL (SHOW) | ACCOUNTADMIN, or MONITOR privilege |
| Modify (ALTER) | ACCOUNTADMIN, or MODIFY privilege |
| Drop | ACCOUNTADMIN only |

```sql
-- Grant view access
GRANT MONITOR ON RESOURCE MONITOR layered_monitor TO ROLE SYSADMIN;

-- Grant modify access
GRANT MODIFY ON RESOURCE MONITOR layered_monitor TO ROLE SYSADMIN;
```

---

## Part 9: Best Practices Summary

| Practice | Why |
|----------|-----|
| **Always set an account-level monitor** | Safety net for all warehouses |
| **Use graduated triggers (50/75/100/110%)** | Early warning before kill |
| **Set SUSPEND at 90-95%, not 100%** | Buffer for monitoring lag |
| **One warehouse per monitor** | Precise per-WH control |
| **Re-specify ALL triggers on ALTER** | Prevents losing triggers |
| **Use NOTIFY_USERS for WH monitors** | Alert the team, not just account admins |
| **Enable notifications in Snowsight** | Alerts are OFF by default |
| **Use FREQUENCY = NEVER for fixed budgets** | Credits don't reset |
| **Verify user emails before NOTIFY_USERS** | CREATE fails otherwise |
| **Use Budgets for serverless costs** | Resource monitors don't cover Snowpipe/AI/etc. |

> **Enable notifications:** Snowsight → Profile → Notifications → "Enable notifications from resource monitors". Users must also verify their email address.

---

*Built with Snowflake Resource Monitors — from cost control to production safety.*
