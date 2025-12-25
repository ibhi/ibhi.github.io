---
title: "Model Context Protocol – Protocol Specification"
description: "A technical deep-dive into MCP's JSON-RPC contract, lifecycle handshake, core methods, and transport mechanisms."
date: 2025-12-26
summary: "Understanding the technical specification of MCP: JSON-RPC message schemas, the initialization handshake, and core capabilities."
tags: ["MCP", "Protocol", "JSON-RPC", "Specs"]
---

# Part 2 – Protocol Specification

> **Note:** This is the second post in my series on the Model Context Protocol. 
> * **Previous:** [Part 1: The Problem MCP Solves](https://blog.noobish.in/posts/mcp-series-01-problem/)
> * **Next:** Part 3: High-Level Architecture (Coming Soon)
---

**TL;DR:**
At its core, MCP is a defined set of JSON‑RPC 2.0 messages exchanged over a transport like STDIO or SSE. This post details the message schema, the mandatory initialization handshake, and the structure of tool discovery and execution.

---

## 1. The Message Contract

MCP relies on standard **JSON‑RPC 2.0**. Every message exchanged between a Host (client) and a Server must adhere to this structure.

### Requests & Responses
Messages that expect an answer must include an ID.

| Field | Description |
|-------|-------------|
| `jsonrpc` | Fixed string `"2.0"`. |
| `id` | A unique ID (string or integer) used to match responses to requests. |
| `method` | The MCP capability being invoked (e.g., `initialize`, `tools/call`). |
| `params` | An object containing arguments specific to the method. |

### Notifications
Messages that do *not* expect a response have `id: null`. These are used for events like logging or reporting progress.

---

## 2. The Lifecycle Handshake

Before any tools or resources can be exchanged, the Host and Server must complete a handshake to negotiate capabilities and protocol versions.



{{< mermaid >}}
sequenceDiagram
    participant Host (AI App)
    participant Server (MCP)

    note over Host, Server: 1. Transport Connection Opened

    Host->>Server: {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {...}}
    note right of Server: Server checks Host capabilities<br/>and determines its own.
    Server-->>Host: {"jsonrpc": "2.0", "id": 1, "result": {"capabilities": {...}}}

    note right of Host: Host accepts capabilities.

    Host->>Server: {"jsonrpc": "2.0", "method": "notifications/initialized"}

    note over Host, Server: 2. Session Active. Ready for requests.
{{</mermaid>}}

Step 1: The initialize Request (Host → Server)
The host announces its own capabilities and requested protocol version.
Step 2: The initialize Result (Server → Host)
The server responds with its own info. The session is not yet active here.
Step 3: The initialized Notification (Host → Server)
The host sends this to acknowledge receipt. The server will not accept other requests (like tool calls) until this notification is received.

## 3. Core Capabilities & Methods
Once initialized, interactions fall into standard methods grouped by capability. Note the namespace/method naming convention.


| Capability | Common Methods | Purpose |
|------------|----------------|---------|
| Tools | tools/list tools/call | Expose executable functions for actions or dynamic data. |
| Resources | resources/list resources/read | Expose read-only data sources (files, DBs) via URIs. |
| Prompts | prompts/list prompts/get | Provide standardized prompt templates to the host. |
| Logging | notifications/message | Server sends logs (info, debug, error) to the host. |

Example: Calling a Tool (tools/call)
Request:
```JSON
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "get_stock_price",
    "arguments": { "ticker": "AAPL" }
  }
}
```
Response:MCP results are wrapped in a content array. This allows for multi-modal data (e.g., text alongside a chart image).
```JSON
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "AAPL is currently trading at $220.50"
      }
    ]
  }
}
```

## 4. Transport Options
| Transport | Description | Ideal Use Case |
|-----------|-------------|----------------|
| STDIO | Host spawns the Server as a subprocess and pipes stdin/stdout. | Local Tools. Connecting scripts to Claude Desktop or IDEs. | 
| SSE | HTTP endpoint for requests; SSE stream for server responses. | Remote Services. Cloud-hosted AI agents. | 

## 5. Security Considerations
### 5.1 Human in the Loop
The protocol assumes the Host application (e.g., the chat UI) acts as a gatekeeper. Sensitive tool calls should require explicit user approval.
### 5.2 Prompt Injection
A malicious user might try to trick the LLM into calling a tool with dangerous arguments (e.g., rm -rf / via a file tool).Defense: The MCP server must treat all arguments as untrusted. Always validate inputs against your JSON schema and sanitize paths/commands.
### 5.3 Transport Security
For SSE, always use TLS (HTTPS) to prevent eavesdropping on sensitive context data as it travels over the network.Spec Timeline & Governance
{{< timeline >}}
  {{< timelineItem header="2024" >}}
    Initial release by Anthropic.
  {{< /timelineItem >}}

  {{< timelineItem header="Today" >}}
    Spec version 2024-11-05 is current. SDKs for Python, TypeScript, and Java are available.
  {{< /timelineItem >}}

  {{< timelineItem header="Future" >}}
    The spec is slated to move to the Linux Foundation for vendor-neutral stewardship.
  {{< /timelineItem >}}
{{< /timeline >}}

In the next post (Post 3), we’ll zoom out from the raw JSON and look at the high‑level architecture of an MCP-enabled application.