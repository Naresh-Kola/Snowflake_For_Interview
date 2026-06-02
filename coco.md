# Snowflake Cortex Code: Complete Guide

## Table of Contents
1. [What is Cortex Code?](#1-what-is-cortex-code)
2. [Types of Cortex Code](#2-types-of-cortex-code)
3. [Cortex Code in Snowsight](#3-cortex-code-in-snowsight)
4. [Cortex Code CLI](#4-cortex-code-cli)
5. [Cortex Code Agent SDK](#5-cortex-code-agent-sdk)
6. [Model Context Protocol (MCP)](#6-model-context-protocol-mcp)
7. [Agent Client Protocol (ACP)](#7-agent-client-protocol-acp)
8. [Plugins](#8-plugins)
9. [Supported Models](#9-supported-models)
10. [Feature Comparison](#10-feature-comparison)
11. [Pros and Cons](#11-pros-and-cons)
12. [Access Control & Security](#12-access-control--security)
13. [Billing & Costs](#13-billing--costs)
14. [Cortex Code vs Snowflake Intelligence vs Legacy Copilot](#14-cortex-code-vs-snowflake-intelligence-vs-legacy-copilot)
15. [Use Cases & Example Prompts](#15-use-cases--example-prompts)
16. [Extensibility & Customization](#16-extensibility--customization)

---

## 1. What is Cortex Code?

Cortex Code is Snowflake's **AI-driven intelligent coding agent** integrated into the Snowflake platform. It's an autonomous agent framework that:

- Understands your Snowflake environment (RBAC, schemas, best practices)
- Generates, explains, and optimizes code (SQL, Python, dbt)
- Performs multi-step tasks autonomously
- Operates within your existing security context

```
┌──────────────────────────────────────────────────────────────────────┐
│                        CORTEX CODE ECOSYSTEM                          │
│                                                                      │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐ │
│  │  IN SNOWSIGHT   │  │      CLI        │  │     AGENT SDK       │ │
│  │  (Web-based)    │  │  (Terminal)      │  │  (Python/TypeScript)│ │
│  │                 │  │                  │  │                     │ │
│  │  • Workspaces   │  │  • Local shell   │  │  • Build your own   │ │
│  │  • Admin pages  │  │  • VS Code/Cursor│  │    AI applications  │ │
│  │  • Notebooks    │  │  • Local files   │  │  • Multi-turn       │ │
│  │  • dbt projects │  │  • Git repos     │  │  • Built-in tools   │ │
│  └─────────────────┘  └─────────────────┘  └─────────────────────┘ │
│                                                                      │
│  Supported Protocols:                                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                          │
│  │   MCP    │  │   ACP    │  │ Plugins  │                          │
│  │ External │  │ IDE      │  │ Bundled  │                          │
│  │ Tools    │  │ Embed    │  │ Packages │                          │
│  └──────────┘  └──────────┘  └──────────┘                          │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Types of Cortex Code

Cortex Code is delivered through **three main interfaces** plus **three extension protocols**:

| Type | Status | Where | Primary User |
|------|--------|-------|--------------|
| **Cortex Code in Snowsight** | GA | Snowsight web UI | All Snowflake users |
| **Cortex Code CLI** | GA | Local terminal | Power users, developers |
| **Cortex Code Agent SDK** | Preview | Python/TypeScript apps | Developers building AI apps |
| **MCP (Model Context Protocol)** | Preview | CLI extension | Integrators |
| **ACP (Agent Client Protocol)** | Preview | IDE integration | IDE users (VS Code, Zed, etc.) |
| **Plugins** | Preview | CLI extension | Teams sharing tools |

---

## 3. Cortex Code in Snowsight

### What It Is
The persistent, web-based AI assistant integrated directly into Snowflake's UI. Appears as a panel on the right side of Snowsight.

### How to Access
1. Click the Cortex Code icon in the lower-right corner of Snowsight
2. Type your question or instruction in natural language
3. Review and apply suggestions

### Key Capabilities

| Capability | Description |
|-----------|-------------|
| SQL Authoring | Generate, modify, and optimize SQL from natural language |
| Python/Notebook | Create and edit Python notebooks with cells |
| Code Review (Diff View) | Visual comparison of AI-suggested changes before applying |
| Code Explanation | Ask "what does this do?" for any SQL/Python code |
| Error Fix | Click "Fix" button on failed SQL to get suggested corrections |
| AI Code Suggestions | Inline autocomplete as you type (Shift+Enter to accept) |
| Catalog Context (@) | Type @ to search and reference tables/views/schemas inline |
| Quick Actions | Highlight SQL → Quick Edit, Format, Add to Chat, Explain |
| Account Administration | Credit consumption, query performance, governance questions |
| dbt Projects | Scaffold, author, test, run, and document dbt models |
| Marketplace Search | Discover public and internal marketplace listings |
| Documentation Q&A | Answer questions about Snowflake features/syntax |

### Context Awareness
Cortex Code in Snowsight knows:
- Which file you're currently viewing
- Your active role and warehouse
- Your account's schema/tables/views
- Snowflake RBAC and privileges

### Skills System
- **Built-in Skills**: Type `/` to see available specialized workflows
- **Personal Skills**: Create custom skills in `.snowflake/cortex/skills/` directory
- Skills are workspace-specific

### AGENTS.md
Create an `AGENTS.md` file at your workspace root to provide persistent instructions that Cortex Code automatically follows in every conversation.

---

## 4. Cortex Code CLI

### What It Is
A command-line agentic shell for Snowflake that bridges your local development environment and your Snowflake account.

### Installation
```bash
curl -LsS https://ai.snowflake.com/static/cc-scripts/install.sh | sh
```

### Key Features

| Feature | Description |
|---------|-------------|
| Snowflake Integration | Execute SQL, view tables, validate semantic models, manage connections |
| Local File Access | Read/write to local repos (dbt projects, Streamlit apps, etc.) |
| Tool Orchestration | Run bash commands, git operations, execute SQL against warehouse |
| Agent Customization | AGENTS.md, Agent Skills, custom behaviors per project |
| Security | OS-level sandboxing, three-tier approval system, risk assessment |
| Built-in Skills | Agent creation, ML, data engineering, data governance |
| Extensibility | Custom tools, skills, subagents, hooks, profiles |
| Session Persistence | Resume conversations, maintain context |
| Git Worktree Support | Work across multiple branches |
| Developer UX | Vim navigation, color themes, compact/expanded modes |
| Web Search | Configurable web search for research tasks |

### Billing Models

| Model | Who | How |
|-------|-----|-----|
| **Subscription** | Individual developers (signup.snowflake.com/cortex-code) | Free 30-day trial → paid monthly subscription |
| **Pay-as-you-go** | Existing Snowflake accounts (on-demand/capacity) | Token-based consumption |

---

## 5. Cortex Code Agent SDK

### What It Is
A Python/TypeScript SDK to build your own agentic AI applications using the same tools and agent loop that power Cortex Code.

### Status: Preview

### Installation
```bash
# TypeScript
npm install cortex-code-agent-sdk

# Python
pip install cortex-code-agent-sdk
```

### Built-in Tools

| Tool | Description |
|------|-------------|
| Read | Read any file in working directory |
| Write | Create new files |
| Edit | Make precise edits to existing files |
| Bash | Run terminal commands, scripts, git |
| Glob | Find files by pattern |
| Grep | Search file contents with regex |
| SQL | Execute SQL against Snowflake |

### Key Capabilities

| Feature | Description |
|---------|-------------|
| Multi-turn Sessions | Maintain context across multiple exchanges |
| MCP Servers | Connect to external systems |
| Hooks | Run custom code at key lifecycle points (PreToolUse, PostToolUse, Stop, etc.) |
| Structured Output | Force responses to match a JSON Schema |
| Session Control | maxTurns, effort level, abort, environment variables |
| Model Selection | Choose from supported models or use "auto" |

### Code Example (Python)
```python
import asyncio
from cortex_code_agent_sdk import query, AssistantMessage, CortexCodeAgentOptions

async def main():
    async for message in query(
        prompt="What does this codebase do?",
        options=CortexCodeAgentOptions(cwd="."),
    ):
        if isinstance(message, AssistantMessage):
            for block in message.content:
                if hasattr(block, "text"):
                    print(block.text, end="")

asyncio.run(main())
```

### Code Example (TypeScript)
```typescript
import { query } from "cortex-code-agent-sdk";

for await (const message of query({
  prompt: "What does this codebase do?",
  options: { cwd: process.cwd() },
})) {
  if (message.type === "assistant") {
    for (const block of message.content) {
      if (block.type === "text") process.stdout.write(block.text);
    }
  }
}
```

---

## 6. Model Context Protocol (MCP)

### What It Is
An open standard for connecting AI agents to external tools and data sources (GitHub, Jira, internal APIs, databases).

### Status: Preview

### How It Works
```
┌──────────────┐     MCP     ┌──────────────────┐
│  Cortex Code │ ◄──────────► │  MCP Server      │
│  CLI         │              │  (GitHub, Jira,  │
│              │              │   Custom APIs)   │
└──────────────┘              └──────────────────┘
```

Add an MCP server once → its tools become available in every Cortex Code session.

### Configuration Example
```python
options = CortexCodeAgentOptions(
    mcp_servers={
        "my-tools": {
            "command": "node",
            "args": ["my-mcp-server.js"],
        },
    },
)
```

---

## 7. Agent Client Protocol (ACP)

### What It Is
An open standard that lets editors/IDEs (Zed, JetBrains, VS Code, Neovim) embed Cortex Code as a local agent backend.

### Status: Preview

### How It Works
```
┌──────────────┐     ACP     ┌──────────────────┐
│  IDE/Editor  │ ◄──────────► │  Cortex Code CLI │
│  (VS Code,   │  Responses,  │  (Agent Backend) │
│   Zed, etc.) │  Tool Calls, │                  │
│              │  File Diffs   │                  │
└──────────────┘              └──────────────────┘
```

The editor drives the session while Cortex Code streams responses, tool calls, and file diffs back.

---

## 8. Plugins

### What It Is
Self-contained packages that bundle skills, subagents, slash commands, hooks, and MCP servers under a single manifest.

### Status: Preview

### Distribution
- Share across teams from a Git repository
- Install from official marketplace
- Ship as part of a Snowflake connection profile

---

## 9. Supported Models

| Model | Identifier | Quality | Best For |
|-------|-----------|---------|----------|
| Claude Opus 4.6 | claude-opus-4-6 | Highest (Recommended) | Complex reasoning, agentic workflows |
| Claude Opus 4.5 | claude-opus-4-5 | Very High | Advanced reasoning |
| Claude Sonnet 4.5 | claude-sonnet-4-5 | High | General reasoning, multimodal |
| OpenAI GPT 5.4 | openai-gpt-5.4 | High | Azure regions |
| OpenAI GPT 5.2 | openai-gpt-5.2 | High | Azure regions |
| Auto (Recommended for SDK) | auto | Selects best available | Default choice |

### Enabling Cross-Region Inference
```sql
-- Required when model isn't available in your region
ALTER ACCOUNT SET CORTEX_ENABLED_CROSS_REGION = 'AWS_US';
-- Options: AWS_GLOBAL, AWS_US, AWS_EU, AWS_APJ, AWS_AU, AZURE_GLOBAL, AZURE_US, ANY_REGION
```

---

## 10. Feature Comparison

| Feature | Snowsight | CLI | Agent SDK |
|---------|-----------|-----|-----------|
| **Status** | GA | GA | Preview |
| **Access** | Browser (Snowsight) | Terminal | Python/TypeScript code |
| **Authentication** | Snowsight session | connections.toml | connections.toml via CLI |
| **Local File Access** | No (workspace files only) | Yes | Yes |
| **SQL Execution** | Yes | Yes | Yes |
| **Code Generation** | Yes | Yes | Yes |
| **Diff View** | Yes | Yes (terminal) | No (programmatic) |
| **Inline Autocomplete** | Yes (AI Code Suggestions) | No | No |
| **dbt Support** | Yes | Yes | Yes |
| **Notebook Support** | Yes | Yes | Yes |
| **Git Integration** | Limited | Full | Full |
| **MCP Support** | No | Yes | Yes |
| **ACP Support** | No | Yes (server) | No |
| **Plugins** | No | Yes | No |
| **AGENTS.md** | Yes | Yes | Yes |
| **Custom Skills** | Yes (Personal Skills) | Yes | Yes |
| **Multi-turn** | Yes | Yes | Yes |
| **Hooks** | No | Yes | Yes |
| **Structured Output** | No | No | Yes |
| **Web Search** | No | Yes (configurable) | No |
| **Session Persistence** | Within conversation | Resume/Fork sessions | Resume/Fork sessions |
| **Admin Tasks** | Yes | Limited | No |
| **Marketplace Discovery** | Yes | No | No |
| **Model Selection** | Yes (settings) | Yes (per session) | Yes (per query) |

---

## 11. Pros and Cons

### Cortex Code in Snowsight

| Pros | Cons |
|------|------|
| Zero setup — just click and use | No local file access |
| Visual diff view for code review | Cannot run bash commands |
| Context-aware (knows your open file) | Limited to workspace files |
| Integrated with admin pages | No MCP/Plugin support |
| AI Code Suggestions (autocomplete) | Must use browser |
| @ mention for catalog objects | Default role only (must ask to switch) |
| Built-in skills with `/` | Personal skills are workspace-scoped only |
| dbt + Notebook native support | No git operations |
| Fix button on SQL errors | Cannot access external tools |

### Cortex Code CLI

| Pros | Cons |
|------|------|
| Full local file system access | Requires installation |
| Git integration (commit, push, branch) | Terminal-only interface |
| Bash command execution | Learning curve for non-CLI users |
| MCP for external tool integration | Subscription model for individuals |
| ACP for IDE embedding | Needs connections.toml setup |
| Plugins for team sharing | Not available for Gov/VPS/Sovereign (CLI) |
| AGENTS.md + Skills customization | No visual diff (text-based) |
| Web search capability | Security sandbox may block some commands |
| Session persistence & resume | |
| Multiple color themes, vim mode | |
| OS-level sandboxing (security) | |
| Three-tier approval system | |

### Cortex Code Agent SDK

| Pros | Cons |
|------|------|
| Build custom AI applications | Preview — not production-ready |
| Programmatic control over agent | Requires development effort |
| Structured JSON output | Requires Cortex Code CLI installed |
| Multi-turn sessions | Limited documentation (new) |
| Hooks for lifecycle events | Python 3.10+ or Node.js 18+ required |
| Full tool access (Read, Write, Edit, Bash, SQL) | No visual interface |
| MCP server integration | |
| Model selection per query | |
| Abort/timeout controls | |

---

## 12. Access Control & Security

### Required Database Roles (Snowsight)

```sql
-- Both required:
GRANT DATABASE ROLE SNOWFLAKE.COPILOT_USER TO ROLE my_role;

-- At least one of these:
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE my_role;
-- OR
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER TO ROLE my_role;
```

### Security Model

| Aspect | Behavior |
|--------|----------|
| Authentication | Uses existing Snowflake auth (no separate credentials) |
| RBAC | Operates within your active role's permissions |
| Default Role | Snowsight always starts with your default role |
| Data Access | Only queries/modifies what your role allows |
| Credential Storage | Never stores or modifies your credentials |
| CLI Sandboxing | OS-level sandboxing, three-tier approval |
| Risk Assessment | Automatic risk assessment for CLI commands |

### CLI Security Features
1. **Sandbox**: Commands run in an isolated OS-level sandbox
2. **Three-tier approval**: Low risk (auto), Medium risk (prompt), High risk (block)
3. **Risk assessment**: Each action evaluated before execution

---

## 13. Billing & Costs

### Token-Based Consumption

Both Snowsight and CLI are billed based on **token consumption**:
- Input tokens (your prompts + context)
- Output tokens (AI responses + generated code)

### Credit Usage Limits

```sql
-- Set daily credit limit for Cortex Code users
ALTER ACCOUNT SET CORTEX_CODE_DAILY_CREDIT_LIMIT = 10;
```

### Cost Factors

| Factor | Impact |
|--------|--------|
| Model choice | Larger models (Opus) cost more per token than smaller (Sonnet) |
| Context size | More context = more input tokens = higher cost |
| Multi-turn conversations | Each turn includes full history = cumulative cost |
| Tool usage | Each tool call adds tokens |
| Frequency of use | More sessions = more tokens |

### CLI Billing Options

| Option | Details |
|--------|---------|
| Subscription (Individual) | Free 30-day trial → paid monthly. Fixed usage included. Overages block until next cycle. |
| Pay-as-you-go (Enterprise) | Existing Snowflake accounts. Billed per token on compute consumption table. |

---

## 14. Cortex Code vs Snowflake Intelligence vs Legacy Copilot

| Feature | Cortex Code | Snowflake Intelligence | Copilot (Legacy) |
|---------|------------|----------------------|-----------------|
| **Status** | Active (GA) | Active (GA) | **Deprecated** |
| **Purpose** | Development + operational workflows | Natural language data Q&A | Basic SQL + UI help |
| **Integration** | Snowsight + Workspaces + CLI | Intelligence UI + Cortex Agents API | Separate copilot panel |
| **Scope** | SQL authoring, data exploration, admin, dbt, notebooks, ML | Question answering, data insights, recommendations | Limited SQL suggestions |
| **Key Capability** | Generates/modifies code, diff view, explains code, multi-step agent | Analyzes data, generates summaries, conversational insights | Contextual SQL help |
| **Agentic** | Yes (autonomous multi-step) | Yes (agent-based) | No |
| **Underlying Tech** | Large LLMs (Claude, GPT) + tool orchestration | Cortex Analyst + semantic models | Simpler model |
| **Context** | Workspace files, catalog, RBAC | Semantic models, tables | Current worksheet |
| **Best For** | Builders (engineers, analysts, admins) | Business users asking data questions | (Replaced by Cortex Code) |

### Migration Note
If your account previously disabled Snowflake Copilot (legacy), Cortex Code is also disabled. Contact your account team to re-enable.

---

## 15. Use Cases & Example Prompts

### SQL Development

| Use Case | Example Prompt |
|----------|---------------|
| Generation | "Write a query for top 10 customers by revenue with a 7-day moving average" |
| Optimization | "Explain why this query is slow and optimize it" |
| Explanation | "What does this SQL script do?" |
| Refinement | "Update the query to show top 100 instead of 10" |
| Synthetic Data | "Generate synthetic data for 30 days of sales" |

### dbt Projects

| Use Case | Example Prompt |
|----------|---------------|
| Explore | "List all source tables in the bronze layer" |
| Scaffold | "Create staging models for each source" |
| Test | "Add not_null and uniqueness tests to key columns" |
| Incremental | "Convert the fact model to incremental with merge behavior" |
| Document | "Generate docs for the project" |

### Machine Learning

| Use Case | Example Prompt |
|----------|---------------|
| EDA + ML | "Build a notebook for customer churn prediction using scikit-learn" |
| Deep Learning | "Create a CNN for the MNIST dataset" |
| Pipeline | "Create a dbt project to transform raw sales data" |

### Administration

| Use Case | Example Prompt |
|----------|---------------|
| Cost | "Which service types use the most credits?" |
| Access | "What databases do I have access to?" |
| Security | "Find all tables that have PII in them" |
| Governance | "Show lineage from RAW_DB.ORDERS to downstream dashboards" |

### Data Discovery

| Use Case | Example Prompt |
|----------|---------------|
| Catalog | "Where can I find tables related to customer churn?" |
| Marketplace | "Find listings on Snowflake Marketplace for weather data" |
| Internal | "Show organizational listings from Internal Marketplace for sales data" |

---

## 16. Extensibility & Customization

### AGENTS.md (Both Snowsight & CLI)

A markdown file at your workspace/project root that provides persistent instructions:
```markdown
# Project Guidelines
- Always use fully qualified table names
- Follow our naming convention: stg_, int_, fct_, dim_
- Use incremental models for fact tables
- Run dbt test after every model change
```

### Personal Skills (Snowsight)

Create in `.snowflake/cortex/skills/` directory:
```
.snowflake/cortex/skills/
├── my-skill/
│   ├── SKILL.md        # Instructions + metadata
│   └── scripts/        # Supporting scripts
```

SKILL.md format:
```markdown
---
name: data-quality-check
description: Run data quality checks on specified tables
---
# Instructions
1. Query the table for null counts...
2. Check for duplicates...
```

### Plugins (CLI Only, Preview)

Bundle skills, subagents, hooks, and MCP servers together:
- Install from Git repos
- Install from official marketplace
- Include in Snowflake connection profiles

### Hooks (CLI & SDK)

Run custom code at lifecycle points:
- `PreToolUse`: Before a tool executes
- `PostToolUse`: After a tool completes
- `Stop`: When agent stops
- `UserPromptSubmit`: When user sends a message

---

## Summary: Which Should You Use?

```
Are you working in Snowsight (browser)?
  → Cortex Code in Snowsight
  → Best for: SQL worksheets, notebooks, dbt projects, admin tasks

Are you working locally (terminal, VS Code, etc.)?
  → Cortex Code CLI
  → Best for: Local repos, git workflows, full bash access, MCP integrations

Are you building an AI application?
  → Cortex Code Agent SDK
  → Best for: Custom agents, automation pipelines, programmatic AI tasks

Want IDE integration (VS Code, Zed, Neovim)?
  → CLI with ACP
  → Best for: Keeping your editor while using Cortex Code

Need external tools (GitHub, Jira, APIs)?
  → CLI with MCP
  → Best for: Connecting to services outside Snowflake
```
