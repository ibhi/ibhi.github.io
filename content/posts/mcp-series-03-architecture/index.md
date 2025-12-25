---
title: "Part 3 – Architecture & Core Components"
description: "MCP isn't just a pipe; it's a specific architectural pattern consisting of Hosts, Clients, and Servers. This post unpacks the 'Sandwich Architecture' that allows AI agents to safely connect to local and remote resources."
date: 2025-12-25
summary: "Understanding the MCP 'Sandwich Architecture' with Hosts, Clients, and Servers, plus transport mechanisms and data flow"
tags: ["MCP", "GenAI", "AI Agents", "Integration"]
feature_image: "feature_mcp_protocol.png"
---

## TL;DR:
MCP isn't just a pipe; it's a specific architectural pattern consisting of Hosts, Clients, and Servers. This post unpacks the "Sandwich Architecture" that allows AI agents to safely connect to local and remote resources.

If you haven't read Part 2 yet, [start there]({{< ref "/posts/mcp-series-02-the-spec" >}}) to understand the protocol specification.

## 1. The "Sandwich" Architecture
At a high level, MCP follows a client-host-server model, often described as a "sandwich" where the Host controls the Client, which connects to the Server.

{{< mermaid >}}
graph TD
    subgraph "The Host Application"
        H["Host Process (e.g. Claude Desktop, IDE)"]
        C["MCP Client"]
    end

    subgraph "The External World"
        S["MCP Server"]
        D["Data Source (SQLite, Slack, GitHub)"]
    end

    H --"Controls"--> C
    C --"Transport (Stdio/SSE)"--> S
    S --"Queries"--> D
{{< /mermaid >}}

## 2. The Three Pillars
**The Host:** The container application (like Claude Desktop, Cursor, or your custom AI app). It manages the lifecycle of the connection and decides how to present tools to the user. It is the "User Agent" of the MCP world.

**The Client:** The protocol implementation that lives inside the Host. It handles the JSON-RPC handshake, capabilities negotiation, and message routing. It maintains a 1:1 stateful session with a server.

**The Server:** The bridge to your data. It exposes three primary primitives:

- **Resources:** Read-only data (like files or logs).

- **Tools:** Executable functions (like "create_jira_ticket").

- **Prompts:** Pre-written templates to guide the LLM.

## 3. Transports: The Nervous System
MCP defines how these components talk. Currently, there are two official standard transports:

| Transport | Best For         | Mechanism                                                                                          |
|-----------|------------------|--------------------------------------------------------------------------------------------------|
| Stdio     | Local Integration| The Host spawns the Server as a subprocess. Communication happens over standard input/output pipes. Fast, secure by default (local only), and easy to debug. |
| SSE (Server-Sent Events) | Remote/Cloud     | Uses HTTP Post for client-to-server messages and an SSE stream for server-to-client updates. Essential for "Remote MCP" where the agent and the tool are on different machines. |

## 4. The Data Flow
When a user asks, *"What's the weather in Tokyo?"*, the flow is specific:

1. **Discovery**: The Client calls `tools/list` on the Server.
2. **Reasoning**: The Host sends the tool definitions to the LLM. The LLM decides to call `get_weather(city="Tokyo")`.
3. **Execution**: The Client sends a `tools/call` request to the Server.
4. **Result**: The Server executes the code and returns the result (e.g., "18°C, Cloudy").
5. **Context**: The Host feeds this result back to the LLM to generate the final answer.

{{< mermaid >}}
graph TD
      subgraph "User Request"
          U["User: 'What's the weather in Tokyo?'"]
      end
      subgraph "Host Application"
          H["Host Process"]
          C["MCP Client"]
          LLM["LLM"]
      end
      subgraph "External World"
          S["MCP Server"]
          D["Data Source (Weather API)"]
      end

      U -->|1. Initiates Request| H
      H -->|2. Sends Tool Definitions| LLM
      LLM -->|3. Decides to call get_weather| H
      H -->|4. Client calls tools/list| C
      C -->|5. Client sends tools/call| S
      S -->|6. Server executes code| D
      D -->|"7. Returns Result (e.g., '18°C, Cloudy')"| S
      S -->|8. Server returns result| C
      C -->|9. Host feeds result back| H
      H -->|10. LLM generates final answer| LLM
{{< /mermaid >}}

## 5. What's Next?
**Coming Up Next**: Theory is great, but code is better. In the next post, we will write two servers: one using the "hard" way (Official SDK) and one using the "easy" way (FastMCP) that gets you running in 6 lines of code.
