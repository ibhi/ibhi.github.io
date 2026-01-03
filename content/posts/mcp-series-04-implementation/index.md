---
title: "Part 4 – Building a Real-World MCP Server (The \"Crypto-Tracker\")"
description: "Step-by-step guide to building a functional Crypto Tracker MCP Server using FastMCP. Connects to CoinGecko API and exposes tools, resources, and prompts."
date: 2025-12-26
summary: "Build a fully functional Crypto Tracker MCP Server with FastMCP that connects to real CoinGecko API data"
tags: ["MCP", "FastMCP", "AI Agents"]
series: ["MCP Introduction Series"]
series_order: 4
---

**TL;DR:** In this part, we stop talking theory and write code. We will build a fully functional Crypto Tracker MCP Server using FastMCP. It connects to the real CoinGecko API, exposes live market data as Resources, lets the AI fetch prices via Tools, and includes a "Financial Analyst" Prompt.

This post is part of a MCP series. If you haven't read Part 3 yet, [start there]({{< ref "/posts/mcp-series-03-architecture" >}}) to understand the architecture.

## 1. The Setup
We are using fastmcp because it handles the heavy lifting (JSON-RPC handshake, error handling, typing).

Prerequisites:
- Create and activate a virtual environment (optional but recommended)
- Install FastMCP and dependencies
{{< tabs >}}
    {{< tab label="pip" >}}
```bash
pip install "mcp[fastmcp]" httpx uvicorn
```
    {{< /tab >}}
    {{< tab label="uv" >}}
```bash
uv add "mcp[fastmcp]" httpx uvicorn
```
    {{< /tab >}}
{{< /tabs >}}

## 2. The Code (crypto_server.py)
Create a file named crypto_server.py.
```python { lineNos = true }
from fastmcp import FastMCP, Context
import httpx

# 1. Initialize the Server
mcp = FastMCP("CryptoTracker")

# Constants
API_BASE = "https://api.coingecko.com/api/v3"

# ==============================================================================
# 1. TOOLS: Executable functions for the AI to call
# ==============================================================================

@mcp.tool()
async def get_crypto_price(coin_id: str, currency: str = "usd") -> str:
    """
    Fetch the current price of a cryptocurrency.
    Args:
        coin_id: The ID of the coin (e.g., 'bitcoin', 'ethereum', 'dogecoin')
        currency: The target currency (default: 'usd')
    """
    url = f"{API_BASE}/simple/price"
    params = {"ids": coin_id, "vs_currencies": currency}
    
    async with httpx.AsyncClient() as client:
        try:
            response = await client.get(url, params=params)
            response.raise_for_status()
            data = response.json()
            
            if coin_id not in data:
                return f"Error: Coin '{coin_id}' not found."
            
            price = data[coin_id][currency]
            return f"The current price of {coin_id} is {price} {currency.upper()}."
        except Exception as e:
            return f"API Error: {str(e)}"

# ==============================================================================
# 2. RESOURCES: Read-only data sources (like files or dynamic state)
# ==============================================================================

@mcp.resource("crypto://trending")
async def get_trending_coins() -> str:
    """A dynamic resource that lists the top 7 trending coins on CoinGecko."""
    url = f"{API_BASE}/search/trending"
    
    async with httpx.AsyncClient() as client:
        response = await client.get(url)
        data = response.json()
        
        coins = [c['item']['name'] for c in data['coins']]
        return "Top Trending Coins:\n" + "\n".join(f"- {c}" for c in coins)

# ==============================================================================
# 3. PROMPTS: Pre-written templates to guide the AI
# ==============================================================================

@mcp.prompt()
def analyze_portfolio(coins: str) -> str:
    """
    Create a prompt for the AI to analyze a comma-separated list of coins.
    """
    return f"""
    I am holding the following cryptocurrencies: {coins}.
    
    Please perform the following actions:
    1. Use the 'get_crypto_price' tool to fetch the current price for each.
    2. Read the 'crypto://trending' resource to see if any of them are trending.
    3. Give me a brief risk analysis based on market sentiment.
    """

# ==============================================================================
# 4. ENTRY POINT
# ==============================================================================

if __name__ == "__main__":
    # This handles the STDIO connection by default
    mcp.run()
```
## 3. How to Run It
One of the best features of FastMCP is flexibility. You can run the same code in two completely different ways depending on your architecture.

### 3.1 Mode A: Local STDIO (The "Desktop" Way)
This is how you connect the server to Claude Desktop or Cursor. The host application spawns your Python script directly and talks over standard input/output pipes.

Run in Terminal (to test):

```bash
# This starts the server in "Inspector" mode (a web UI for debugging)
mcp dev crypto_server.py
```
*Action*: Click the get_crypto_price tool in the UI, type "bitcoin", and hit Run. You'll see the real live price

{{< figure src="/images/mcp/mcp_inspector.png" alt="MCP Inspector UI" >}}

Configure in Claude Desktop: Edit your claude_desktop_config.json:
```json
{
  "mcpServers": {
    "crypto": {
      "command": "python",
      "args": ["/absolute/path/to/crypto_server.py"]
    }
  }
}
```

### 3.2 Mode B: HTTP / SSE (The "Remote" Way)
If you want to deploy this server to the cloud (e.g., AWS, Render) so a remote agent can access it, you can't use pipes. You need HTTP.

FastMCP supports this natively. You don't need to change your code, just how you launch it. We can use uvicorn (a standard Python web server) to serve the MCP application.

1. Run with Uvicorn:
```bash
# This exposes the server on port 8000
# Format: uvicorn filename:mcp_instance_name ...
uvicorn crypto_server:mcp --port 8000
```
2. How the Client Connects: An MCP Client (like a cloud agent) would now connect to:
- **SSE Endpoint**: http://localhost:8000/mcp (For receiving events)

This is the exact same functionality, just transported over the web instead of a local pipe.

### 4. Seeing it in Action
Once connected, you can ask your AI Agent (Eg: Claude):

`"Analyze my portfolio: bitcoin, solana, and peipei."`

What happens under the hood?

1. **Prompt Loading:** The AI loads your `analyze_portfolio` template.
2. **Tool Execution:** It sees the instruction to fetch prices and automatically calls `get_crypto_price("bitcoin")`, `get_crypto_price("solana")`, etc.
3. **Resource Reading:** It reads `crypto://trending` to check momentum.
4. **Final Answer:** It combines the live data into a coherent financial summary.

## 5. Next Steps
Congratulations! You have built a fully functional MCP server that connects to a real-world API, exposes Tools, Resources, and Prompts, and can run both locally and remotely.

**Ready to secure your MCP server?** In the final post of this series, we'll discuss some of security challenges and best practices.

## 6. References
- [Build a MCP server](https://modelcontextprotocol.io/docs/develop/build-server)
- [Python MCP SDK](https://github.com/modelcontextprotocol/python-sdk)