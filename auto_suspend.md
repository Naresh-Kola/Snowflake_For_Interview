# Auto-Suspend: Explained with Simple Example

## What is Auto-Suspend?

Auto-suspend is the number of **SECONDS** a warehouse stays running **AFTER** the last query finishes.

Once this idle time passes with no new queries, Snowflake automatically **SUSPENDS** the warehouse (shuts it down). Suspended warehouse = $0 cost (no credits consumed).

---

## Simple Example

- **Warehouse:** ANALYTICS_WH (MEDIUM = 4 credits/hour)
- **Auto-Suspend:** 300 seconds (5 minutes) — DEFAULT

### Timeline:

| Time | Event |
|------|-------|
| 9:00:00 AM | User runs query (warehouse resumes, starts billing) |
| 9:00:15 AM | Query finishes |
| 9:00:15 AM | Idle timer starts... 300 seconds countdown |
| 9:00:30 AM | Still idle... (4:45 remaining) |
| 9:01:00 AM | Still idle... (4:15 remaining) |
| 9:05:15 AM | 300 seconds passed, NO new query → SUSPENDED (billing stops) |

**COST:** Billed for 5 min 15 sec of idle time after query finished
- Query took 15 sec + 5 min idle = 5.25 min total
- That's 4 credits/hr × (5.25/60) = **0.35 credits WASTED on idle**

---

## Same Example with AUTO_SUSPEND = 60 Seconds

| Time | Event |
|------|-------|
| 9:00:00 AM | User runs query (warehouse resumes) |
| 9:00:15 AM | Query finishes |
| 9:00:15 AM | Idle timer starts... 60 seconds countdown |
| 9:01:15 AM | 60 seconds passed, NO new query → SUSPENDED |

**COST:** Billed for only 1 min 15 sec idle
- 4 credits/hr × (1.25/60) = 0.083 credits wasted

**SAVINGS:** 0.35 - 0.083 = **0.267 credits saved PER IDLE PERIOD**

---

## Visual Comparison

**AUTO_SUSPEND = 300 (default):**
```
|--query--|--------idle (paying!)--------|SUSPEND|
0s       15s                           315s
          ← 5 min wasted credits →
```

**AUTO_SUSPEND = 60:**
```
|--query--|--idle--|SUSPEND|
0s       15s     75s
          ← 1 min wasted →
```

AUTO_SUSPEND = 60 saves ~4 minutes of billing every time the warehouse goes idle.

---

## Real Cost Impact (Over a Day)

**Scenario:** Analysts run queries 20 times/day with gaps between  
**Warehouse:** MEDIUM (4 credits/hour), idle 20 times

| Setting | Idle Time | Daily Cost Wasted |
|---------|-----------|-------------------|
| AUTO_SUSPEND = 300 (5 min) | 20 × 5 min = 100 min | 4 × (100/60) = 6.67 credits/day |
| AUTO_SUSPEND = 60 (1 min) | 20 × 1 min = 20 min | 4 × (20/60) = 1.33 credits/day |

- **DAILY SAVINGS:** 6.67 - 1.33 = 5.34 credits/day
- **MONTHLY SAVINGS:** 5.34 × 30 = ~160 credits/month
- At $3/credit = **~$480/month saved** just by changing one number!

---

## SQL to Set Auto-Suspend

```sql
ALTER WAREHOUSE COMPUTE_WH SET AUTO_SUSPEND = 60;

-- Or when creating a new warehouse:
CREATE WAREHOUSE MY_WH
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND = 60
    AUTO_RESUME = TRUE;

-- Check current setting:
SHOW WAREHOUSES LIKE 'COMPUTE_WH';
```

---

## Important: Minimum Billing = 60 Seconds

Snowflake bills a **MINIMUM of 60 seconds** every time a warehouse resumes. Even if your query takes 2 seconds, you pay for 60 seconds.

**BAD scenario with AUTO_SUSPEND = 60:**
| Time | Event | Billed |
|------|-------|--------|
| 9:00 | query (2 sec), idle 60s → suspend | 62s |
| 9:05 | query (2 sec), idle 60s → suspend | 62s |
| 9:10 | query (2 sec), idle 60s → suspend | 62s |
| **Total** | 3 queries | ~186 seconds |

**BETTER with AUTO_SUSPEND = 300 if queries come every 5 min:**
| Time | Event |
|------|-------|
| 9:00 | query (2 sec) |
| 9:05 | query (2 sec) — warehouse never suspended! still running |
| 9:10 | query (2 sec) — still running |
| 9:15 | idle 5 min → suspend |
| **Total** | 3 queries, billed for ~15 min continuous (never re-resumed) = CHEAPER |

---

## Decision Guide

| Query Pattern | Best AUTO_SUSPEND | Why |
|---------------|-------------------|-----|
| Sporadic (hours between queries) | 60 seconds | Don't pay for long idle gaps |
| Regular (every 2-5 minutes) | 300 seconds | Avoid repeated 60-sec resume charges |
| Continuous (always busy) | 300-600 seconds | Rarely suspends anyway |
| Overnight batch (runs once) | 60 seconds | Suspend immediately after batch |
| Dashboards (bursts every 30 min) | 60 seconds | Long gaps, suspend quickly |

---

## AUTO_SUSPEND + AUTO_RESUME Together

**AUTO_RESUME = TRUE** means: When a query arrives at a suspended warehouse → Snowflake automatically resumes it (takes ~30-60 seconds)

### The Full Cycle:

```
┌──────────────────────────────────────────────────────────┐
│ SUSPENDED (no cost)                                      │
│     │                                                    │
│     │ ← Query arrives (AUTO_RESUME = TRUE)               │
│     ▼                                                    │
│ RESUMING (~30-60 sec provisioning)                       │
│     │                                                    │
│     ▼                                                    │
│ RUNNING (billing starts, query executes)                 │
│     │                                                    │
│     │ ← Last query finishes                              │
│     ▼                                                    │
│ IDLE (still billing, countdown starts)                   │
│     │                                                    │
│     │ ← AUTO_SUSPEND seconds pass with no queries        │
│     ▼                                                    │
│ SUSPENDED (billing stops)                                │
└──────────────────────────────────────────────────────────┘
```

**TRADE-OFF:**
- Lower AUTO_SUSPEND = saves money but users wait for resume more often
- Higher AUTO_SUSPEND = costs more but users never wait

---

## When to Use AUTO_SUSPEND = 60 Seconds (Use It)

### Scenario 1: ETL/Batch Warehouse (runs once, then done)

**Pattern:** Nightly batch job runs at 2 AM, takes 30 min, then nothing until next night

| Setting | Suspend Time | Idle Wasted |
|---------|-------------|-------------|
| AUTO_SUSPEND = 300 | 2:35 AM | 5 min wasted |
| AUTO_SUSPEND = 60 | 2:31 AM | 1 min wasted |

**SAVINGS:** 4 min × 4 credits/hr = 0.27 credits/night × 30 = 8 credits/month  
For XLARGE (16 credits/hr): 32 credits/month = ~$96/month

**Why 60 works:** No user is waiting. Next query is 22 hours away. Resume delay doesn't matter.

### Scenario 2: Sporadic Ad-hoc Analyst (hours between queries)

**Pattern:** Analyst runs a query, thinks for 30+ min, runs another

| Setting | Idle Cost (3 suspends) |
|---------|----------------------|
| AUTO_SUSPEND = 300 | 3 × 5 min × 4 credits/hr = 1.0 credits wasted |
| AUTO_SUSPEND = 60 | 3 × 1 min × 4 credits/hr = 0.2 credits wasted |

**Why 60 works:** Long gaps between queries mean the warehouse would suspend anyway. The 30-sec resume wait is acceptable because the analyst is thinking for 30+ min anyway.

### Scenario 3: Dashboard Warehouse (bursts every 15-30 min)

**Pattern:** Dashboard auto-refreshes every 30 min, burst of 10 queries in 5 sec

**With AUTO_SUSPEND = 60:**
- 10:00:00 → 10 dashboard queries fire (done in 5 sec)
- 10:01:00 → SUSPEND
- 10:30:00 → resume + 10 queries (done in 5 sec)
- 10:31:00 → SUSPEND
- Billed: 2 × (60 sec minimum + 5 sec) = ~2 min total

**Why 60 works:** 30-min gap is way longer than any suspend setting. 60s minimizes idle burn between bursts.

---

## When NOT to Use AUTO_SUSPEND = 60 Seconds (Avoid It)

### Scenario 4: Frequent Queries Every 2-5 Minutes

**Pattern:** Multiple analysts sending queries every 2-3 minutes

**With AUTO_SUSPEND = 60:**
- Constant suspend/resume cycles
- Each resume pays 60-sec MINIMUM even if query is 2 sec
- Users wait 30 sec each time (bad experience!)
- In 30 min: 10 resume cycles × 90 sec billed = 15 min billed

**With AUTO_SUSPEND = 300:**
- Warehouse never suspends, always ready, no wait
- Same or lower cost because no repeated minimums

**Why 60 fails:**
1. 60-sec minimum billing on EVERY resume adds up
2. Users wait 30 sec for resume EVERY time (frustrated)
3. Local SSD cache is lost on suspend → first query after resume is slower

### Scenario 5: Production Application (constant user traffic)

**Pattern:** Web app sends queries every 10-30 seconds

**Why 60 fails:** Risk of unnecessary suspend during a brief 90-sec gap → user hits cold resume → bad experience → SSD cache lost → next queries slower

### Scenario 6: Data Science / ML Training (iterative workflow)

**Pattern:** Run query, review results 3-4 min, tweak, run again

**With AUTO_SUSPEND = 60:**
- Heavy query fills SSD cache → SUSPEND → cache DESTROYED
- Next query must re-fetch everything from cloud (slow!)

**With AUTO_SUSPEND = 300:**
- Cache stays warm → modified query uses cached data → finishes in 5 sec!

**Why 60 fails:** The LOCAL DISK CACHE (SSD) is destroyed on suspend. Iterative workloads benefit massively from warm cache.

---

## The Hidden Cost: Cache Loss on Suspend

This is the #1 reason NOT to use 60-sec aggressively:

```
┌─────────────────────────────────────────────────────────────┐
│ Warehouse RUNNING → SSD has 800GB of cached partitions      │
│                                                             │
│ AUTO_SUSPEND fires → warehouse suspends                     │
│                                                             │
│ ALL 800GB of cache = GONE                                   │
│                                                             │
│ Next resume → SSD is empty (cold start)                     │
│ First queries must re-fetch everything from cloud (slow!)   │
└─────────────────────────────────────────────────────────────┘
```

**Cost of cache loss:**
- Queries run 2-5x slower until cache warms up
- More bytes scanned from remote = more I/O time
- Users perceive slowness even after warehouse resumes

---

## Final Decision Framework

Ask yourself these 3 questions:

| Question | Answer | Recommended Setting |
|----------|--------|-------------------|
| Q1: How long is the gap between queries? | > 10 minutes | 60 |
| | 2-10 minutes | 300 |
| | < 2 minutes | 300-600 |
| Q2: Do users care about 30-sec resume wait? | No (batch/scheduled) | 60 |
| | Yes (interactive) | 300 |
| Q3: Does workload benefit from SSD cache? | No (always different tables) | 60 |
| | Yes (same tables repeatedly) | 300+ |

---

## Summary

| USE 60 SECONDS | AVOID 60 SECONDS |
|----------------|------------------|
| ETL/batch jobs | Interactive analysts |
| Sporadic queries (30+ min gap) | Queries every 2-5 min |
| Dashboard refresh (long gaps) | Iterative data science |
| Dev/test environments | Production apps |
| Scheduled tasks | Cache-dependent queries |
| One-off data loads | User-facing systems |
