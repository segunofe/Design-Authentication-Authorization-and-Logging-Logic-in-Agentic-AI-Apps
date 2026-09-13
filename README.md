# AnyCompany Retail AI Agent — Built on Amazon Bedrock AgentCore

## About This Project

<img width="1600" height="900" alt="image" src="https://github.com/user-attachments/assets/88617230-6b33-42e6-b1ce-eac053ec476a" />
https://catalog.us-east-1.prod.workshops.aws/event/dashboard/en-US/workshop

----
I built an AI agent for a fictional retail company ("AnyCompany Retail") using **Amazon Bedrock AgentCore**, based on the AWS Workshop Studio lab found [here](https://catalog.us-east-1.prod.workshops.aws/event/dashboard/en-US/workshop). Starting from a base agent, I progressively extended it with internal and external tools, wired up multiple authentication mechanisms, and finished with role-based dynamic tool filtering so different employee roles see different capabilities.

This README documents what I built at each stage, the architecture decisions involved, and an issues I ran into (and how I fixed it) along the way.

**Architectural Overview**
<img width="975" height="458" alt="image" src="https://github.com/user-attachments/assets/eeddf2e6-3091-4651-b58d-95169333716d" />


---

## Overview

I deployed a base AI agent and then incrementally connected it to a set of backend systems — Lambda, API Gateway, DynamoDB, and an external vendor's MCP server — each using a different inbound/outbound authentication pattern. The last piece I added was dynamic, role-based control over which tools each user can access.

### Initial Setup

1. I confirmed a required dependency in the `requirements.txt`.
2. I ran the deployment script, which:
   - Creates an ECR repository via a CodeBuild job
   - Deploys the AgentCore Runtime instance and configures an inbound JWT authorizer to protect it
   - Generates a `config.js` file for the frontend and uploads it to the corresponding S3 bucket

---

## Step 1 — Terms of Service Tool

**Goal:** Expose an existing AWS Lambda function (Terms of Service lookup — delivery, payment, and refund conditions) as an MCP-compliant tool.

**What I built:**
- An MCP-compliant tool via **Amazon Bedrock AgentCore Gateway**
- **Inbound auth:** AWS IAM (SigV4), using the IAM role attached to the AI agent — since ToS info should be available to any AnyCompany employee
- **Outbound auth:** An assumed AWS IAM role invoking the Lambda function
- A **Tool document** describing the tool's functions to the Gateway via MCP, so the agent knows what's available

**Automation:** I used the `activity2_gen.sh` script, which:
- Takes the Gateway URL as a parameter
- Inserts the MCP client configuration into `agent.py` between the Activity 2 markers
- Configures SigV4 authentication for the Gateway connection
- Backs up `agent.py` before making changes

### Issue I Ran Into
After deploying the tool, the agent didn't pick it up immediately. Here's how I debugged it:
1. Confirmed the AgentCore Runtime was `READY`:
   ```
   aws bedrock-agentcore-control list-agent-runtimes --region us-east-1
   ```
2. Checked the code in the **In-line schema editor** under the AgentCore Gateway.
3. Verified `config.js` had the correct `AGENTCORE_RUNTIME_ARN`.

**Possible Root cause:** my open browser tab was using a stale `config.js`. **Fix:** waited a few minutes and refreshed the frontend, which picked up the updated config.

---

## Step 2 — Sales, Products, and Reviews Tools

I deployed one AgentCore Gateway hosting multiple tools, each using a different outbound integration pattern.

### Sales Tool
- Talks to an **Amazon API Gateway** using an **API key**
- The API key is stored securely in Secrets Manager

### Products Tool
- Talks to an **Amazon API Gateway** using a **JWT-profiled OAuth token** (Client Credentials flow) as a bearer token
- **What I did:**
  1. Created an OAuth client secret for the Gateway, stored in the **AgentCore Identity vault**
  2. An additional secret was created in **Secrets Manager** for the OAuth token provider

### Customer Reviews Tool
- Connects natively to an **Amazon DynamoDB** table — no Lambda or custom API required
- Reuses the **same AgentCore Gateway** from the Sales/Products steps (still owned by the Sales team, so no new inbound policy was needed)
- **Outbound auth:** an assumed AWS IAM role

**What I did:**
1. Created a new **Target** on the existing Gateway.
   - ⚠️ Note: the workshop instructions show this as an **"Integrations"** target type, but in the current AWS Console it actually appears as **"Connectors"** — that mismatch tripped me up briefly.
   - Flow I followed: **Connector → Other integrations → Integration provider: Amazon → Tool template: DynamoDB template**
2. Created an IAM role with `DDBRead*` and `DDBList*` policies, allowing the Gateway to read/list data from the DynamoDB table.

---

## Step 3 — Inventory MCP Tool (External Vendor)

**Goal:** Extend the agent beyond AnyCompany's boundaries by connecting to a third-party inventory vendor's own MCP server.

**Scenario:** The (fictional) vendor already runs an MCP server and provides a remote MCP URL plus authorization credentials.

**What I built:**
- An **OAuth2 Identity Provider** configured with the vendor-supplied credentials
- A new **AgentCore Gateway** pointing at the vendor's MCP server
- Updated the agent's system prompt so it knows it has inventory capabilities

### Cross-Trust-Domain Architecture
- **Trust Domain 1 (AnyCompany):** corporate Gateway + agent
- **Trust Domain 2 (Inventory Vendor):** external MCP server with its own auth

**Flow:**
1. Agent requests inventory data through the corporate Gateway.
2. Gateway authenticates to the vendor's MCP server via the OAuth2 Identity Provider.
3. Vendor's MCP server validates the OAuth2 token and returns inventory data.
4. Agent uses the returned data to answer inventory questions.

**Setup:** I retrieved the vendor's MCP server URL and access credentials from the CloudFormation stack outputs.

---

## Step 4 — Dynamic, Role-Based Tool Filtering

**Goal:** Restrict which tools are visible/usable per employee role, as if requested by a security team.

**Access model I implemented:**

| Role | Accessible Tools |
|------|-------------------|
| Everyone | Terms of Service, Products |
| Managers | Sales, Customer Reviews |
| Suppliers | Inventory |
| Admins | Everything |

**What I built:**
- An integration in the agent that filters tools (and multi-agent capabilities) in/out per user
- Authorization policies written in **Cedar** to enforce role-based access

### How Tools Are Identified
Each tool is referenced by the agent as:
```
<AgentCore Gateway Target name>__<tool function name>
```
Examples:
- `ToS-Lambda___get-tos-lambda`
- `Customer-Reviews-Table___DescribeTable`
- `Products-API-Gateway___viewProductCatalog`
- `Sales-API-Gateway___viewSales`
- `Inventory-MCP-Target___Inventory___getInventory`

**Enforcement:** Access is filtered using **Amazon Verified Permissions** with Cedar policies evaluated against each request.

---

## Summary of Authentication Patterns Used

| Tool | Inbound Auth | Outbound Auth | Backend |
|------|-------------|----------------|---------|
| Terms of Service | IAM (SigV4) | Assumed IAM Role | Lambda |
| Sales | (Gateway default) | API Key | API Gateway |
| Products | (Gateway default) | OAuth2 (Client Credentials / JWT bearer) | API Gateway |
| Customer Reviews | (Gateway default) | Assumed IAM Role | DynamoDB |
| Inventory | (Gateway default) | OAuth2 Identity Provider | External Vendor MCP Server |

## What I Took Away From This

Building this project gave me hands-on experience with:
- Standing up an **Amazon Bedrock AgentCore Runtime** behind a JWT authorizer
- Wiring an **AgentCore Gateway** to multiple backend types (Lambda, API Gateway, DynamoDB) using distinct auth strategies (IAM/SigV4, API keys, OAuth2 client credentials)
- Establishing a **cross-trust-domain integration** with an external vendor's MCP server via OAuth2
- Enforcing **fine-grained, role-based tool access** with Cedar policies through Amazon Verified Permissions
- Debugging real deployment issues (stale frontend config, Console UI terminology drift from the workshop docs)

Overall, this project shows how a single AgentCore-powered agent can securely aggregate internal Lambda/API Gateway/DynamoDB resources alongside external third-party MCP servers, while layering role-based authorization on top.
