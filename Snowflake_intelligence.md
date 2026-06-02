# Cortex Agents & Snowflake Intelligence - Complete Guide
## From Beginner to Pro

### Topics Covered:
1. What is Snowflake Intelligence?
2. What are Cortex Agents?
3. How Agents Work (Architecture & Flow)
4. Tools (Cortex Analyst, Cortex Search, Custom Tools)
5. Skills
6. MCP Connectors
7. Orchestration
8. Access & Security
9. Artifacts in Snowflake Intelligence
10. Practical Examples

---

## Section 1: What is Snowflake Intelligence?

Snowflake Intelligence is a ready-to-use agentic application with a conversational interface that helps business users discover and act on deep insights from their data using natural language.

### Key Capabilities:
- **Natural Language Interaction** - Ask questions in plain English
- **Unified Data Access** - Works with both structured and unstructured data
- **Deep Trustworthy Insights** - Breaks down questions, chooses best tools
- **Built-in Visualization** - Auto-generates charts (bar, line, pie, scatter, area, heatmaps, box plots, dual-axis, faceted charts, etc.)
- **Artifacts** - Save, share, and revisit charts/tables persistently
- **Seamless Governance** - Inherits all Snowflake RBAC, row-access policies, and column-level security automatically
- **Mobile App** - Available on iOS for on-the-go insights

### Example User Interaction:

```
User: "How are Q4 sales trending compared to last year?"

Snowflake Intelligence will:
1. Understand the intent
2. Select appropriate tools (Cortex Analyst for SQL generation)
3. Query the data using semantic views
4. Generate a visualization (likely a line chart)
5. Provide a natural language summary
```

---

## Section 2: What are Cortex Agents?

Cortex Agents are AI-powered reasoning engines that power Snowflake Intelligence. They are the "brains" behind the conversational interface.

### Definition:
An Agent is an AI model that can be connected to:
- Semantic Views (structured data definitions)
- Cortex Search Services (unstructured data search)
- Custom Tools (UDFs, stored procedures)

### Agents can:
- Reason through complex multi-step tasks
- Choose the right tools for each question
- Chain multiple tools together in sequence
- Deliver results in natural language
- Take actions on behalf of users
- Provide citations and traceability

### Agent vs Traditional BI:

| Traditional BI | Cortex Agent |
|----------------|--------------|
| Static dashboards | Dynamic, conversational |
| Pre-defined queries | Ad-hoc natural language |
| Requires SQL knowledge | No SQL needed for end users |
| Fixed visualizations | Auto-generated charts |
| Manual refresh | Real-time data access |
| One data source type | Structured + Unstructured |

---

## Section 3: How Agents Work - Architecture & Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        SNOWFLAKE INTELLIGENCE                            │
│                                                                          │
│  ┌──────────┐    ┌────────────────┐    ┌──────────────────────────┐     │
│  │  USER    │───▶│  CORTEX AGENT  │───▶│     ORCHESTRATOR (LLM)   │     │
│  │  INPUT   │    │     API        │    │  (Interprets intent,     │     │
│  └──────────┘    └────────────────┘    │   selects tools, plans)  │     │
│                                         └────────────┬─────────────┘     │
│                                                      │                   │
│                          ┌────────────────────────────┼──────────┐       │
│                          ▼                            ▼          ▼       │
│                  ┌──────────────┐  ┌──────────────┐  ┌────────────┐     │
│                  │   CORTEX     │  │   CORTEX     │  │  CUSTOM    │     │
│                  │   ANALYST    │  │   SEARCH     │  │  TOOLS     │     │
│                  │(Structured)  │  │(Unstructured)│  │(UDFs/SPs)  │     │
│                  └──────────────┘  └──────────────┘  └────────────┘     │
│                          │                  │               │            │
│                          ▼                  ▼               ▼            │
│                  ┌─────────────────────────────────────────────────┐     │
│                  │         REFLECTION & RESPONSE                    │     │
│                  │  (Reviews results, generates final answer,       │     │
│                  │   summaries, tables, charts)                     │     │
│                  └─────────────────────────────────────────────────┘     │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

### Step-by-Step Flow:

1. **USER INPUT**: User submits a natural language question
   - Example: "What were our top 5 products by revenue last month?"

2. **CORTEX AGENT API**: Routes the question to the agent engine

3. **ORCHESTRATION**: The LLM orchestrator:
   - Interprets the user's intent
   - Selects appropriate tools
   - Plans the sequence of actions
   - May use one tool, chain several, or decide question is out of scope

4. **TOOL EXECUTION**: Runs selected tools and returns results
   - Cortex Analyst generates and runs SQL
   - Cortex Search finds relevant documents
   - Custom tools execute specific functions

5. **REFLECTION & RESPONSE**: The orchestrator:
   - Reviews and refines results
   - Generates the final answer
   - Includes summaries, tables, or charts
   - Provides citations for traceability

---

## Section 4: Tools - The Agent's Capabilities

Tools are the functional components that give agents their capabilities. Think of tools as the "hands" of the agent - they perform actual work.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          AGENT TOOLS                                     │
├─────────────────┬───────────────────┬───────────────────────────────────┤
│  CORTEX ANALYST │  CORTEX SEARCH    │  CUSTOM TOOLS                     │
│  (Structured)   │  (Unstructured)   │  (Actions)                        │
├─────────────────┼───────────────────┼───────────────────────────────────┤
│ • Text-to-SQL   │ • Document search │ • UDFs (User Defined Functions)   │
│ • Semantic Views│ • RAG retrieval   │ • Stored Procedures               │
│ • Metrics calc  │ • Hybrid search   │ • External API calls              │
│ • Business logic│ • Vector search   │ • Data transformations            │
└─────────────────┴───────────────────┴───────────────────────────────────┘
```

### Tool 1: Cortex Analyst (Structured Data)

**Purpose**: Converts natural language to SQL, then executes queries

**How it works:**
- Uses Semantic Views to understand business terminology
- Translates questions into optimized SQL
- Executes SQL and returns structured results
- Supports metrics, dimensions, relationships, and business logic

Semantic Views bridge the gap between:
- How business users DESCRIBE data ("revenue", "churn rate")
- How data is STORED in schemas (table.column names)

```sql
-- Example: Creating a Semantic View for Cortex Analyst
CREATE OR REPLACE SEMANTIC VIEW sales_analytics_view
  COMMENT = 'Sales analytics semantic layer for Snowflake Intelligence'
AS SELECT * FROM sales_database.analytics.fact_sales;

-- Note: The full semantic view definition requires YAML-based configuration
-- defining metrics, dimensions, relationships, and business terminology
```

### Tool 2: Cortex Search (Unstructured Data)

**Purpose**: Search through documents, PDFs, support tickets, etc.

**How it works:**
- Indexes unstructured text data
- Performs hybrid search (semantic + keyword)
- Returns relevant document chunks with citations
- Enables RAG (Retrieval Augmented Generation) patterns

**Use Cases:**
- "What does our return policy say about electronics?"
- "Find all support tickets related to login issues"
- "What did the Q3 earnings report mention about APAC?"

```sql
-- Example: Creating a Cortex Search Service
CREATE OR REPLACE CORTEX SEARCH SERVICE support_search_service
  ON support_tickets
  WAREHOUSE = compute_wh
  TARGET_LAG = '1 hour'
  AS (
    SELECT
        ticket_id,
        ticket_text,
        category,
        created_date
    FROM support_database.public.tickets
  );
```

### Tool 3: Custom Tools (UDFs & Stored Procedures)

**Purpose**: Execute custom logic, call APIs, perform actions

**How it works:**
- Agent can invoke any UDF or stored procedure registered as a tool
- Enables agents to TAKE ACTIONS, not just answer questions
- Can call external APIs via external access integrations

**Use Cases:**
- Send notifications or emails
- Update records in external systems
- Run complex calculations
- Trigger workflows

```sql
-- Example: Creating a Custom Tool (UDF) for an Agent
CREATE OR REPLACE FUNCTION calculate_customer_health_score(
    customer_id VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
HANDLER = 'compute_score'
AS
$$
def compute_score(customer_id):
    # Custom logic to calculate customer health score
    # This could include churn risk, engagement metrics, etc.
    return {"customer_id": customer_id, "health_score": 85, "risk_level": "low"}
$$;
```

---

## Section 5: Skills

Skills are pre-built or custom capabilities that enhance what an agent can do. They represent higher-level competencies composed of multiple tool interactions.

### What Are Skills?

Skills are specialized workflows or knowledge areas that an agent can leverage to handle specific types of questions or tasks.

Think of it this way:
- **TOOLS** = Individual capabilities (search, query, calculate)
- **SKILLS** = Composed workflows using multiple tools for specific domains

### Types of Skills:

| Built-in Skills | Custom Skills |
|----------------|---------------|
| Data analysis | Domain-specific workflows |
| Visualization | Industry terminology handling |
| Summarization | Company-specific business logic |
| Trend detection | Custom reporting templates |
| Anomaly identification | Multi-step analysis pipelines |

### How Skills Differ From Tools:

**Tool**: "Execute this SQL query"

**Skill**: "Perform a complete cohort analysis including:
1. Identify cohort groups
2. Calculate retention rates
3. Compare across time periods
4. Generate visualization
5. Summarize key findings"

Skills allow agents to handle complex, multi-step analytical tasks that would otherwise require multiple back-and-forth interactions.

---

## Section 6: MCP Connectors (Model Context Protocol)

MCP (Model Context Protocol) Connectors allow Cortex Agents to connect to external systems and tools using an open standard protocol.

### What is MCP?

MCP is an open protocol that standardizes how AI models connect to external data sources and tools. It provides a universal interface for agents to interact with external systems.

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MCP ARCHITECTURE                                   │
│                                                                       │
│  ┌──────────────┐         ┌───────────────┐         ┌────────────┐  │
│  │ CORTEX AGENT │◀──MCP──▶│ MCP CONNECTOR │◀───────▶│ EXTERNAL   │  │
│  │              │         │  (Bridge)      │         │ SYSTEM     │  │
│  └──────────────┘         └───────────────┘         └────────────┘  │
│                                                                       │
│  External Systems can include:                                        │
│  • GitHub, Jira, Slack                                               │
│  • Salesforce, HubSpot                                               │
│  • Custom APIs                                                        │
│  • Databases outside Snowflake                                        │
│  • SaaS applications                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Why MCP Connectors?

1. **STANDARDIZATION**: One protocol to connect to many systems
2. **SECURITY**: Controlled access with proper authentication
3. **EXTENSIBILITY**: Add new integrations without changing agent code
4. **INTEROPERABILITY**: Works across different AI platforms

### How MCP Connectors Work:

1. Define the MCP connector (endpoint, auth, available tools)
2. Register it with your Cortex Agent
3. Agent can now discover and invoke tools from the external system
4. Results flow back through the MCP protocol

### Use Cases:
- "Create a Jira ticket for this data quality issue" (Jira MCP)
- "What's the status of PR #1234?" (GitHub MCP)
- "Send this report to the #analytics Slack channel" (Slack MCP)
- "Update the customer record in Salesforce" (Salesforce MCP)

### Example Flow:

```
User: "Create a Jira ticket for the data pipeline failure"

Agent Process:
1. Orchestrator recognizes need for external action
2. Selects Jira MCP connector tool
3. MCP connector formats the request per Jira's API
4. Ticket is created in Jira
5. Agent confirms with ticket ID and link
```

---

## Section 7: Orchestration

Orchestration is the "brain" of the agent - the LLM-powered decision engine that coordinates everything.

### What is Orchestration?

The orchestrator is the LLM model that:
- Interprets user intent from natural language
- Decides WHICH tools to use
- Plans the SEQUENCE of actions
- Handles MULTI-STEP reasoning
- Manages CONTEXT across conversation turns
- Performs REFLECTION on results before responding

### Orchestration Flow:

```
┌────────────────────────────────────────────────────────────────────┐
│                    ORCHESTRATION ENGINE                              │
│                                                                      │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌───────────────┐   │
│  │ INTENT  │──▶│   PLAN   │──▶│ EXECUTE  │──▶│   REFLECT &   │   │
│  │ PARSING │   │ CREATION │   │  TOOLS   │   │   RESPOND     │   │
│  └─────────┘   └──────────┘   └──────────┘   └───────────────┘   │
│       │              │              │                │              │
│       ▼              ▼              ▼                ▼              │
│  "What does   "I need to:    Execute SQL,     "Based on the       │
│   the user     1. Query      search docs,     results, here       │
│   want?"       2. Analyze    or call tools    is the answer..."   │
│                3. Visualize"                                       │
└────────────────────────────────────────────────────────────────────┘
```

### Orchestration Capabilities:

**1. SINGLE-TOOL EXECUTION**
```
User: "What's our total revenue?"
→ Orchestrator uses Cortex Analyst only
```

**2. MULTI-TOOL CHAINING**
```
User: "Compare our revenue trends with what customers are saying"
→ Orchestrator chains: Cortex Analyst (revenue data) +
                       Cortex Search (customer feedback)
```

**3. ITERATIVE REFINEMENT**

If first query results are unclear, the orchestrator may:
- Re-query with different parameters
- Ask clarifying questions
- Try alternative approaches

**4. OUT-OF-SCOPE DETECTION**
```
User: "What's the weather tomorrow?"
→ Orchestrator recognizes this is outside available data
→ Responds appropriately without hallucinating
```

### Extended Thinking:

Users can enable "Extended Thinking" mode for complex questions. This makes the orchestrator:
- More thorough in exploration
- Consider more alternative approaches
- Take more time but produce deeper analysis
- Use more tokens for reasoning

### Multi-Turn Conversations:

The orchestrator maintains context across conversation turns:

```
Turn 1: "Show me sales by region"
Turn 2: "Now filter that to just Q4"        ← Understands "that" = previous query
Turn 3: "Which region grew the fastest?"    ← Builds on accumulated context
```

---

## Section 8: Access & Security

Access control in Cortex Agents follows Snowflake's robust security model.

### Security Layers:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SECURITY LAYERS                                    │
│                                                                       │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  LAYER 1: AGENT ACCESS                                         │  │
│  │  • Who can USE the agent (role-based)                          │  │
│  │  • Who can CREATE/MODIFY agents (admin roles)                  │  │
│  │  • Agent-level permissions                                      │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  LAYER 2: DATA ACCESS (CALLER'S RIGHTS)                        │  │
│  │  • Every query runs under the USER'S credentials               │  │
│  │  • RBAC is enforced at runtime                                  │  │
│  │  • Row-access policies apply                                    │  │
│  │  • Column masking policies apply                                │  │
│  │  • Two users asking same question may see different results     │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                       │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  LAYER 3: TOOL ACCESS                                          │  │
│  │  • Each tool has its own permission requirements               │  │
│  │  • Custom tools inherit execution privileges                   │  │
│  │  • External access requires explicit integrations              │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Security Principles:

**1. CALLER'S RIGHTS MODEL**
- Every data interaction validates the CURRENT USER's permissions
- The agent never sees data the user can't see
- Consistent with Snowflake's security-first architecture

**2. RBAC ENFORCEMENT**
- Role-Based Access Control is enforced on every query
- Users only access data their role permits
- Same agent, different roles = different data visibility

**3. DATA GOVERNANCE INHERITANCE**
- All existing governance policies automatically apply:
  - Row-access policies
  - Column-level masking
  - Data classification
  - Audit logging

**4. ADMINISTRATIVE CONTROL**
- Admins control which agents users can access
- Can use existing identity providers
- Granular control over agent capabilities

### Example: Same Agent, Different Users

```
User A (Sales Manager - US Region):
  Question: "Show me customer revenue"
  Result: Sees only US customer data (row-access policy)

User B (VP Sales - All Regions):
  Question: "Show me customer revenue"
  Result: Sees all regions' customer data

Both use the SAME agent, but security filters data automatically.
```

---

## Section 9: Artifacts in Snowflake Intelligence

Artifacts are persistent representations of insights (charts & tables) that you can save, share, and revisit without regenerating them.

### What Are Artifacts?

When Snowflake Intelligence generates a chart or table in response to a question, you can SAVE it as an artifact. The artifact preserves:
- The underlying SQL query
- Visualization settings (chart type, colors, etc.)
- A data snapshot for instant loading
- Conversation context

### Artifact Lifecycle:

```
┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
│  ASK A   │───▶│  VIEW    │───▶│   SAVE   │───▶│  SHARE/  │
│ QUESTION │    │  RESULT  │    │ ARTIFACT │    │  REVISIT │
└──────────┘    └──────────┘    └──────────┘    └──────────┘
                      │                               │
                      ▼                               ▼
                Interactive:                    • Auto-refresh (>12hrs)
                • Sort                         • Manual refresh anytime
                • Filter                       • Follow-up questions
                • Search                       • Link-based sharing
                • Resize
```

### Artifact Features:

**1. SAVING**
- Select "Save" on any chart/table to create an artifact
- Preserves query + visualization + data snapshot
- Loads instantly from cache when viewed later

**2. MANAGING (Artifacts Hub)**
- "Saved" tab: All your saved artifacts
- "Shared with me" tab: Artifacts shared via link
- Search by name within the hub
- Tile previews for fast browsing

**3. REFRESHING**
- Auto-refresh: When viewed >12 hours after last view
- Manual refresh: Available at any time
- Re-runs original SQL with current credentials
- Updates both data and snapshot

**4. SHARING**
- Copy a link and send through any channel
- Link = pointer to single artifact (not a copy)
- Recipient sees data filtered by THEIR permissions (RBAC)
- Appears in recipient's "Shared with me" tab
- Recipients can re-share or save to their own tab
- You can unshare (revoke) at any time

**5. FOLLOW-UP CONVERSATIONS**
- Ask follow-up questions on any saved artifact
- Each follow-up starts a new private thread
- Includes: visualization spec + data snapshot + original context
- Original conversation stays unchanged

### Security for Artifacts:

- Saved artifacts are USER-SCOPED (private by default)
- RBAC enforced on every refresh/share
- Two users may see different data from same artifact
- Ownership persists even if you lose agent access
- Losing data access → cached snapshot visible but no refresh

### What Happens When Conditions Change:

| Condition | What Happens |
|-----------|-------------|
| You lose agent access | Can still view/refresh artifact. Follow-ups unavailable. |
| You lose data access | Last cached snapshot visible. Refresh unavailable. |
| Agent is deleted/modified | Artifact and query unaffected. Follow-ups use current agent if available. |

### Current Limitations:

- Single tile per artifact (no collections)
- Link-based sharing only (no user-level permissions)
- No folders or labels for organization
- Chart editor limited to bar, line, pie, scatter charts

---

## Section 10: Putting It All Together - Practical Examples

### Example 1: Simple Query Flow

```
User: "What were our top 5 products by revenue last quarter?"

Flow:
1. Orchestrator → identifies structured data question
2. Selects Tool → Cortex Analyst
3. Cortex Analyst → uses semantic view to generate SQL
4. SQL executes → returns top 5 products with revenue
5. Reflection → generates bar chart + summary
6. User sees → interactive chart with drill-down capability
7. User saves → creates artifact for future reference
```

### Example 2: Multi-Tool Chaining

```
User: "Why did customer satisfaction drop in March?
       Show me the numbers and relevant support tickets."

Flow:
1. Orchestrator → recognizes need for BOTH structured + unstructured data
2. Tool 1 → Cortex Analyst queries satisfaction scores (structured)
3. Tool 2 → Cortex Search finds March support tickets (unstructured)
4. Reflection → combines insights from both sources
5. Response → "Satisfaction dropped 12% due to shipping delays.
               Here are the top complaint themes..." + chart + citations
```

### Example 3: Custom Tool + Action

```
User: "If any customer's health score is below 50,
       create a Jira ticket for the account team."

Flow:
1. Orchestrator → identifies multi-step action requirement
2. Tool 1 → Custom UDF calculates health scores
3. Tool 2 → Cortex Analyst identifies at-risk customers
4. Tool 3 → MCP Connector (Jira) creates tickets
5. Response → "Found 3 customers below 50. Created tickets:
               ACCT-1234, ACCT-1235, ACCT-1236"
```

---

## Section 11: Creating an Agent - Step by Step

### Beginner Level: Setting up your first agent

**Prerequisites:**
1. Data in Snowflake tables
2. A semantic view or semantic model defined
3. Appropriate roles and permissions
4. A warehouse for compute

**Steps:**
1. Create your Semantic View (defines business terminology)
2. Create a Cortex Search Service (if unstructured data needed)
3. Create the Agent with tools attached
4. Deploy to Snowflake Intelligence
5. Grant access to users/roles

```sql
-- Step 1: Ensure you have a semantic view
-- (Semantic views are typically created via YAML configuration)
-- They define metrics, dimensions, and business terminology

-- Step 2: Optionally create a search service for documents
CREATE OR REPLACE CORTEX SEARCH SERVICE company_docs_search
  ON company_documents
  WAREHOUSE = compute_wh
  TARGET_LAG = '1 hour'
  AS (
    SELECT
        doc_id,
        doc_content,
        doc_title,
        department,
        last_updated
    FROM knowledge_base.public.documents
  );

-- Step 3: Create a custom tool (optional)
CREATE OR REPLACE FUNCTION get_forecast(
    metric_name VARCHAR,
    periods_ahead INT
)
RETURNS TABLE(period DATE, forecasted_value FLOAT)
LANGUAGE SQL
AS
$$
    SELECT
        DATEADD('month', SEQ4(), CURRENT_DATE()) AS period,
        0.0 AS forecasted_value
    FROM TABLE(GENERATOR(ROWCOUNT => periods_ahead))
$$;
```

---

## Section 12: MCP Use Case Flow (End-to-End)

### USE CASE: Auto-create Jira tickets when data pipelines fail

```
┌─────────────────────────────────────────────────────────────────────────┐
│  FLOW: User → Agent → Tools → External System → Response                │
└─────────────────────────────────────────────────────────────────────────┘
```

**USER ASKS:** "Check if any pipelines failed today and create Jira tickets for them"

**STEP 1: ORCHESTRATOR INTERPRETS INTENT**
- Identifies: needs data query + external action
- Plans: Query failures → Filter → Create Jira tickets

**STEP 2: TOOL CALL → Cortex Analyst (Structured Data)**
- Agent generates SQL via semantic view
- Queries pipeline_runs table for today's failures
- Returns: 3 pipelines failed (customer_etl, inventory_sync, finance_recon)

**STEP 3: ORCHESTRATOR DECIDES NEXT ACTION**
- Reviews results: 2 are HIGH severity, 1 is MEDIUM
- Decides to create Jira tickets for HIGH severity ones

**STEP 4: TOOL CALL → MCP Connector (Jira)**
- Agent invokes Jira MCP server's "create_issue" tool
- Creates Ticket #1: `[HIGH] customer_etl - Connection timeout`
- Creates Ticket #2: `[HIGH] finance_recon - Duplicate key violation`

**STEP 5: REFLECTION & RESPONSE**

Agent responds:
> "Found 3 failures today. Created Jira tickets for 2 HIGH severity issues:
> - DATA-OPS-1234: customer_etl (connection timeout)
> - DATA-OPS-1235: finance_recon (duplicate key)
> The MEDIUM severity issue (inventory_sync) was not escalated."

### Visual Flow:

```
┌────────┐     ┌──────────────────┐     ┌─────────────────┐
│  User  │────▶│   Orchestrator   │────▶│  Cortex Analyst  │
│  asks  │     │ (interprets,     │     │  (queries data)  │
└────────┘     │  plans, decides) │     └────────┬────────┘
               └────────┬─────────┘              │
                        │◀───────────────────────┘
                        │  "3 failures found"
                        ▼
               ┌─────────────────┐     ┌─────────────────┐
               │  MCP Connector  │────▶│    Jira Cloud    │
               │  (Atlassian)    │     │  (tickets made)  │
               └────────┬────────┘     └─────────────────┘
                        │
                        ▼
               ┌─────────────────┐
               │  Final Answer   │
               │  to user with   │
               │  ticket IDs     │
               └─────────────────┘
```

### MCP Setup Requirements (High Level):

1. **API INTEGRATION** → OAuth connection to external provider
2. **EXTERNAL MCP SERVER** → Snowflake object pointing to MCP endpoint
3. **AGENT CONFIG** → Attach MCP server to agent's tool list
4. **USER AUTH** → Each user authenticates once via OAuth
5. **RBAC GRANTS** → USAGE on MCP server + API integration

### Other MCP Use Cases:

| Scenario | MCP Provider | Tool Used |
|----------|-------------|-----------|
| "Post this report to #analytics" | Slack | send_message |
| "What PRs are open for data-pipeline?" | GitHub | search_issues |
| "Update lead status in CRM" | Salesforce | update_record |
| "Find docs about our ETL standards" | Confluence | search_content |
| "Create a bug for this data issue" | Linear | create_issue |

---

## Summary: The Complete Agent Ecosystem

```
SNOWFLAKE INTELLIGENCE (User Interface)
└── CORTEX AGENTS (AI Reasoning Engine)
     └── ORCHESTRATION (Decision Making - LLM)
          ├── TOOLS (Execution Layer)
          │    ├── Cortex Analyst (Structured Data → SQL)
          │    ├── Cortex Search (Unstructured Data → RAG)
          │    └── Custom Tools (UDFs/SPs → Actions)
          ├── SKILLS (Composed Workflows)
          │    ├── Built-in (analysis, visualization, trends)
          │    └── Custom (domain-specific workflows)
          ├── MCP CONNECTORS (External Systems)
          │    ├── GitHub, Jira, Slack
          │    ├── Salesforce, HubSpot
          │    └── Any MCP-compatible system
          └── ACCESS & SECURITY
               ├── Caller's Rights Model
               ├── RBAC Enforcement
               ├── Row-Access & Column Masking
               └── Audit Logging

ARTIFACTS (Persistent Outputs)
└── Saved Charts & Tables
     ├── Auto-refresh
     ├── Link-based Sharing
     ├── Follow-up Conversations
     └── RBAC-filtered Views
```

### Learning Path:

**BEGINNER:**
- Understand what Snowflake Intelligence is
- Know the difference between tools (Analyst, Search, Custom)
- Use agents to ask natural language questions
- Save and share artifacts

**INTERMEDIATE:**
- Create semantic views for your data
- Set up Cortex Search services
- Build custom tools (UDFs/SPs)
- Understand orchestration and multi-tool chaining
- Configure access control for agents

**ADVANCED/PRO:**
- Design complex multi-tool agents
- Implement MCP connectors for external systems
- Create custom skills for domain-specific workflows
- Optimize semantic views for better accuracy
- Build agentic workflows with action-taking capabilities
- Implement verified answers for trusted responses
- Design enterprise-wide agent architectures
