---
title: "Part 2 – The Spec: The Grammar of Agents"
description: "If MCP is the 'USB Cable,' JSON-RPC is the electricity flowing through it. This post dissects the wire protocol, the mandatory initialization handshake, and the three core primitives that power every MCP interaction: Resources, Tools, and Prompts."
date: 2025-12-25
summary: "A deep dive into the MCP protocol specification, including message formats, lifecycle, and core primitives"
tags: ["MCP", "GenAI", "AI Agents", "Integration"]
---

# Part 2 – The Spec: The Grammar of Agents
**TL;DR:** If MCP is the "USB Cable," JSON-RPC is the electricity flowing through it. This post dissects the wire protocol, the mandatory initialization handshake, and the three core primitives that power every MCP interaction: Resources, Tools, and Prompts.

1. The Wire Protocol
At its core, MCP is incredibly simple. It is just JSON messages sent back and forth. It is stateless (mostly) and transport-agnostic. You can run it over stdio (pipes) locally, or SSE (Server-Sent Events) over HTTP for the web.

Every message follows the JSON-RPC 2.0 standard.

The Request
The AI (Host) asks the Server to do something.
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/call",
  "params": {
    "name": "get_weather",
    "arguments": { "city": "Berlin" }
  }
}
```
The Response
The Server replies. Note the content array—MCP is multi-modal by design (text, images, binaries).
```json 
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "content": [
      {
        "type": "text",
        "text": "It is currently 14°C and cloudy in Berlin."
      }
    ]
  }
}
```
2. The Handshake (Lifecycle)
You cannot just start shouting commands. An MCP session must start with a handshake. This is where the Host and Server negotiate what they can do (Capabilities).

{{< mermaid >}}
sequenceDiagram
    participant Host
    participant Server

    Note over Host, Server: Connection Established
    Host->>Server: initialize (Client Capabilities)
    Note right of Server: Server decides which<br/>features to enable
    Server-->>Host: Result (Server Capabilities + Info)
    Host->>Server: notifications/initialized
    Note over Host, Server: Session Active
{{< /mermaid >}}

This negotiation is critical. A Host might say, "I support sampling (human-in-the-loop)," and the Server might reply, "I support logging and hot-reloading resources."

3. The Three Primitives
The spec defines three main ways an AI interacts with the world.

A. Resources (`resources/*`)
**"Read-Only Context."** Think of these as files. They are data sources the AI can read but not change.

- *Example*: `file:///logs/error.txt` or `postgres://schema/users`.

- *Power*: Servers can notify the Host when a resource changes, allowing the AI to react to real-time data updates.

B. Tools (`tools/*`)
**"Model-Controlled Actions."** Think of these as functions. The Model requests to run them, but the Server executes them.

- *Example*: `create_jira_ticket(title, description)` or `run_sql_query(query)`.

**Security:** This is the dangerous part. The spec requires that tools be distinct from resources so Hosts can enforce "Human-in-the-loop" approval for sensitive actions.

C. Prompts (`prompts/*`)
**"Reusable Instructions."** Think of these as templates. Instead of users typing a long prompt every time, the Server provides pre-baked workflows.

- *Example*: A "Debug Error" prompt that automatically loads the last 50 lines of logs and asks the LLM to find the root cause.

4. Why JSON-RPC?
Why didn't they use REST or gRPC?
- **Simplicity**: You can debug MCP by looking at the raw text logs.
- **Bidirectional**: Unlike REST, the Server can send messages to the Host (like "Log message" or "Resource Updated") at any time.
- **Transport Agnostic**: JSON-RPC works equally well over a local command line pipe (Stdio) and a WebSocket.

5. What's Next?
**The Cliffhanger**: We have the theory. We have the grammar. But how do we actually put the pieces together? What connects to what?

In the next post, we will map out the MCP Architecture, explaining the difference between a Host, a Client, and a Server, and how to deploy them in the real world.