---
title: "The Problem MCP Solves"
description: "Explore why context handling is a pain point in AI applications and how Model Context Protocol provides a standardized solution."
date: 2025-12-24
summary: "Overview of why context handling is problematic and how MCP addresses it."
tags: ["MCP", "GenAI", "Context Engineering"]
---

# Post 1 – The Problem MCP Solves

**TL;DR:**
AI applications struggle with fragmented context handling. MCP (Model Context Protocol) provides a standardized, secure way to transport rich context between models, tools, and users.

---

## 1. Why Context Handling is a Pain Point

- **Scattered State:** Modern AI pipelines stitch together LLMs, vector stores, external APIs, and custom logic. Each component often expects its own bespoke input format.
- **Copy‑Paste APIs:** Developers end up writing custom wrappers to pass context, leading to duplicated code and maintenance overhead.
- **Security & Permissions:** Sharing sensitive context (e.g., private documents) across services is error‑prone and insecure without a common contract.
- **User Experience Friction:** End‑users see inconsistent capabilities when switching between AI assistants (e.g., switching from a desktop UI like Claude Desktop to a web‑based chatbot), causing confusion and reduced trust.
- **Fragmentation of Knowledge:** Context is often trapped in silos—chat logs, GitHub issues, local files, Slack threads—making it difficult for AI systems to access the right information at the right time.

> *“The biggest bottleneck in AI workflows today is not the model itself, but how context is passed around.”* – Industry observation

## 2. Limitations of Current Approaches

| Approach | Drawbacks |
|----------|-----------|
| **Ad‑hoc string concatenation** | Hard to validate, no schema enforcement, insecure injection risks |
| **Custom RPC wrappers** | Inconsistent signatures, duplicate boilerplate, brittle to changes |
| **Static prompt engineering** | Fixed context limits, no extensibility for new tools |
| **Proprietary APIs (e.g., LangChain UI)** | Tied to a single framework, difficult to port to other stacks |

## 3. Introducing MCP

The **Model Context Protocol** defines a **lightweight, versioned JSON‑RPC contract** that standardizes:

1. **Transport** – STDIO, Server‑Sened Events, or HTTP‑based endpoints.
2. **Message Structure** – Capabilities, tool registration, resource URLs, and prompts.
3. **Core Primitives** – `initialize`, `connect`, `inspect`, `list_tools`, `call_tool`, and resource management.
4. **Lifecycle** – The sequence of interactions that enable an AI system to discover, securely invoke, and compose tools and resources.

With MCP, any AI system can:

- **Discover** what tools/resources a server offers.
- **Securely** request execution of those tools.
- **Exchange** rich, structured context without reinventing parsing logic.

{{< figure src="/images/mcp/before_vs_after_mcp.png" alt="Pain Points Diagram" >}}
## 4. How MCP Changes the Workflow

{{< mermaid >}}
flowchart LR
    P[User / LLM Prompt] --> A[AI Application]
    A -->|initialize| B(MCP Server)
    B -->|list_tools| C[Tool Catalog]
    C -->|call_tool| D[External Service]
    D -->|result| C
    C -->|evaluate| B
    B -->|final context| A
    A -->|final context| P
{{< /mermaid >}}

- **Step 1:** The application opens a connection (STDIO, SSE, or HTTP).
- **Step 2:** It asks the server what tools are available (`list_tools`).
- **Step 3:** It calls the desired tool (`call_tool`) and receives typed results.
- **Step 4:** The server updates its internal context, which the AI can then reason over.

{{< figure src="/images/mcp/mcp_workflow.png" alt="High‑Level MCP Flow" >}}
## 5. Benefits for Developers

- **Interoperability:** Swap out back‑ends without rewriting context‑passing code.
- **Security Model:** Servers can expose only a curated set of tools and enforce sandboxing.
- **Extensibility:** New tools can be added without breaking existing clients.
- **Testing Friendly:** Mock tool responses simplify unit testing.

---

## 6. **Hands‑On Mini‑Lab (Optional): Your First MCP Server**

1. **Install the SDK (if you haven't already)**

   {{< tabs >}}

       {{< tab label="pip" >}}
       ```bash
       pip install "mcp[fastmcp]"
       ```
       {{< /tab >}}

       {{< tab label="uv" >}}
       ```bash
       uv add "mcp[fastmcp]"
       ```
       {{< /tab >}}

   {{< /tabs >}}

2. **Create the server file**
   Create `weather_server.py` with the following content:
   ```python {linenos=inline style=emacs}
   import datetime
   from fastmcp import FastMCP

   # Initialize the FastMCP server
   mcp = FastMCP("WeatherService")

   @mcp.tool()
   async def get_weather(city: str) -> dict:
       """
       Get a randomized weather report for *city*.

       Returns a dictionary with:
       - city: the requested city name
       - condition: randomly chosen weather condition
       - temperature: random temperature in Celsius
       - timestamp: ISO‑8601 timestamp
       """
       import random
       conditions = ["Sunny", "Cloudy", "Rainy", "Snowy", "Windy"]
       temp = random.randint(-5, 35)
       return {
           "city": city,
           "condition": random.choice(conditions),
           "temperature": temp,
           "timestamp": datetime.datetime.utcnow().isoformat() + "Z"
       }

   @mcp.resource("memo://greeting")
   def get_greeting() -> str:
       """A static greeting resource."""
       return "Welcome to the Weather MCP service! Ask me about any city."

   if __name__ == "__main__":
       # Run the server using the built‑in dev command (auto‑reload & dev UI)
       mcp.run(transport="stdio")
   ```

   3. **Run the dev server**
   ```bash
   mcp dev weather_server.py
   cd test
   ```

This starts a live‑reload server and opens a small web UI (the **MCP Dev Inspector**) where you can click "Execute" on `get_weather` and see the raw JSON‑RPC request/response. This visual bridge is the easiest way to explore your tool without writing a client script.
{{< figure src="/images/mcp/mcp_inspector.png" alt="High‑Level MCP Flow" >}}
## 7. Next steps

If you’re curious, the next post (Post 2) dives deeper into the **protocol specification**, covering:

- Exact JSON‑RPC schema (methods, parameters, response format).
- Transport options and when to choose each.
- Versioning strategy and compliance checks.