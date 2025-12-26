---
title: "Part 2 – The Secret Language - Decoding the MCP Specification"
description: "MCP Specification: The electrical blueprint behind the 'USB-C for AI'. This post details MCP's technical core, covering its message formats, lifecycle, and primitives."
date: 2025-12-25
summary: "A deep dive into the MCP protocol specification, including message formats, lifecycle, and core primitives"
tags: ["MCP", "GenAI", "AI Agents"]
---

**TL;DR:** If the Model Context Protocol (MCP) is the "USB-C for AI" the MCP Specification is the electrical blueprint that makes the connection possible. While architectural overviews give us the "what" the specification provides the authoritative "how".
This post breaks down the technical core of MCP, following the structure of the official specification docs so you can cross-reference as you build.

This post is part of a MCP series. If you haven't read Part 1 yet, [start there]({{< ref "/posts/mcp-series-01-context-crisis" >}}) to understand the "N x M" problem MCP solves.

## 1. Base Protocol: The JSON-RPC Backbone
At its lowest level, MCP is a stateful session protocol built on JSON-RPC 2.0. It uses a request-response model for most actions, while using "Notifications" for one-way updates where no response is required (like logging or tool list changes).

Every message follows the JSON-RPC 2.0 standard. For example:

Request:
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
Response:
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
### Why JSON-RPC?
Why didn't they use REST or gRPC?
- **Simplicity**: You can debug MCP by looking at the raw text logs.
- **Bidirectional**: Unlike REST, the Server can send messages to the Host (like "Log message" or "Resource Updated") at any time.
- **Transport Agnostic**: JSON-RPC works equally well over a local command line pipe (Stdio) and a WebSocket.

## 2. The Lifecycle: The Handshake Sequence
Every connection follows a strict lifecycle to ensure both parties are "speaking the same dialect".
1. Initialize: The client sends an initialize request containing its Protocol Version (e.g., "2025-06-18") and Capabilities.
2. Negotiate: The server responds with its own capabilities, declaring if it supports tools, resources, or prompts.
3. Ready: The client sends an initialized notification to finalize the stateful session.

{{< mermaid >}}
sequenceDiagram
    participant Client
    participant Server
    Note over Client,Server: Phase 1: Handshake
    Client->>Server: initialize (protocolVersion, capabilities)
    Server-->>Client: initializeResult (capabilities, serverInfo)
    Client->>Server: notifications/initialized
    Note over Client,Server: Phase 2: Operational
    Client->>Server: tools/list
    Server-->>Client: list of tools
{{< /mermaid >}}

This negotiation is critical. A Host might say, "I support sampling (human-in-the-loop)," and the Server might reply, "I support logging and hot-reloading resources."

## 3. Transports: How Messages Travel
MCP separates the Data Layer (JSON messages) from the Transport Layer (how messages move).
- Stdio Transport: Used for local servers. The host launches the server as a child process and communicates via stdin and stdout.
- Streamable HTTP Transport: The modern standard for remote servers. It uses HTTP POST for client-to-server messages and chunked HTTP streaming (replacing legacy SSE) for server-to-client updates.
- Resumability (SEP-1699): Remote servers can now "disconnect at will" to save resources. Clients use a Last-Event-ID header to reconnect and replay missed events without losing context.

## 4. Server Features: The Three Primitives
The core of an MCP server's utility lies in three primitives that provide context and action to the LLM.
| Primitive | REST Analogy | Description |
|-----------|--------------|-------------|
| Resources | GET          | Read-only context like files, DB records, or logs. Identified by unique URIs. |
| Tools     | POST         | Executable functions with side effects. Defined by JSON Schema 2020-12 for parameter validation. |
| Prompts   | Template     | Reusable instruction sets (e.g., "Review this code") that standardize model behavior. |

Notes:
- **Structured Tool Output:** Tools now support [Structured Tool Output](https://modelcontextprotocol.io/specification/2025-06-18/server/tools#structured-content), allowing them to return machine-parseable JSON instead of just raw text.
- ***Security:*** Tools are the dangerous part. The spec requires that tools be distinct from resources so *Hosts* can enforce "Human-in-the-loop" approval for sensitive actions.

## 5. Client Features: Empowering the Server
Unique to MCP, servers can also request actions *from* the client.
- **Sampling:** A server can ask the host's LLM to generate text. This allows servers to remain "model agnostic" while still using AI reasoning.
- **Elicitation:** If a tool needs more info (e.g., "Which date should I book?"), the server can pause execution and ask the user directly via the client.
- **Roots:** Allows the server to understand the filesystem boundaries it is allowed to operate in.

## 6. Authorization: Secure Identity at Scale
MCP follows OAuth 2.1 conventions to protect sensitive data.
- **PKCE (Proof Key for Code Exchange):** Required for all clients to prevent authorization code interception, especially for "public" clients like desktop apps that can't store secrets.
- **ARM (OAuth 2.0 Authorization Server Metadata):** Provides metadata about the authorization server, helping clients discover endpoints and capabilities.
- **PRM (Protected Resource Metadata):** When a server returns a 401 Unauthorized, it includes a link to a PRM document telling the client which Authorization Server to trust and which scopes are needed.
- **CIMD (Client ID Metadata Documents):** Introduced in the 2025-11-25 update, this replaces messy manual registration. A client’s identity is now a URL pointing to a JSON file it controls, anchoring trust in DNS and HTTPS.

Notes:
- The specification doesn't mandate OAuth flow for local Stdio servers, instead retrieve credentials from the environment.
- Since Authorization is an evolving area, always refer to the latest spec for updates. At the time of writing [2025-11-25](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization) is the latest.

## 7. The Future Spec: Year Two Infrastructure
The latest spec revision (2025-11-25) moved MCP from a developer tool to production infrastructure.
- **Tasks (SEP-1686):** An experimental primitive for asynchronous workflows. Instead of blocking a connection for an hour, the server returns a taskId immediately, and the client polls for the result later.
- **Extensions:** A formal way to add optional features (like custom UI elements or industry-specific logic) without bloating the core protocol.
- **Stateless Scaling:** A new proposal to make stateless requests the default, removing the mandatory initialization handshake to improve cloud load balancing

## 8. What's Next?
**The Cliffhanger**: We have the theory. We have the grammar. But how do we actually put the pieces together? What connects to what?

In the next [post]({{< ref "/posts/mcp-series-03-architecture" >}}), we will map out the MCP Architecture, explaining the difference between a Host, a Client, and a Server, and how to deploy them in the real world.

## 9. References
- [MCP Specification (2025-11-25)](https://modelcontextprotocol.io/specification/2025-11-25/basic)
