---
title: "MCP Security Master Class Part 3 - Step-Up Authorization: WWW-Authenticate Challenges and the Scope Union"
description: Don't ask for every scope up front. MCP's 2026-07-28 spec standardizes discovery, audience binding, issuer validation, and a scope-union re-authorization flow that lets tools request elevation at runtime without losing what was already granted.
tags:
  - MCP
  - Security
  - OAuth
summary: 'Parts 1 and 2 settled identity: the server verifies, the IdP issues, and clients identify themselves with URLs. This post is about permission. The 2026-07-28 spec adds a complete runtime elevation story: 401 challenges that carry Protected Resource Metadata discovery, RFC 8707 audience binding, RFC 9207 issuer validation against mix-up attacks, 403 insufficient_scope shortfalls that name exactly what is missing, and a normative scope-union calculation so re-authorization never revokes what was already granted. Plus the FastMCP enforcement layer: require_scopes, require_roles, restrict_tag, and AuthMiddleware.'
draft: true
series:
  - MCP Security Master Class
series_order: 3
date: '2026-10-20'
---

## TL;DR

- **Start small.** The spec's priority order for a client's initial scopes: whatever the initial 401 challenge suggests, else `scopes_supported` from the PRM document - which "is intended to represent the minimal set of scopes necessary for basic functionality" - else nothing [^1]
- **Discovery rides on the 401.** The challenge header `WWW-Authenticate: Bearer resource_metadata="..."` (RFC 9728 §5.1) tells the client where to find the Protected Resource Metadata document; MCP servers MUST publish one, and it MUST list `authorization_servers` [^2]
- **Tokens are audience-bound** via RFC 8707: clients MUST include `resource` set to the server's canonical URI in *both* the authorization and token requests, so the resulting token only works at that one server [^3]
- **Issuer validation is now client-mandatory**: when the AS advertises RFC 9207 support, a response missing `iss` gets rejected outright (SEP-2468) - and comparisons are exact string matches, no normalization [^4]
- **Runtime elevation uses 403 + `insufficient_scope`**, and the re-authorization scope set is the **union** of previously granted and newly challenged scopes - the spec's own words - so stepping up never silently drops permissions [^5]
- In FastMCP: **`require_scopes`** produces the shortfall challenge, **`require_roles`** deliberately does not (OAuth has no way to request a role), and **`AuthMiddleware` + `restrict_tag`** enforces policy server-wide by tag

---

## 1. Discovery: the 401 that tells you everything

The last two posts built up the cast: an MCP server that only verifies ([part 1](/posts/mcp-masterclass-01-auth-delegation)), and a client that identifies itself with a URL instead of a registration record ([part 2](/posts/mcp-masterclass-02-cimd)). This post is about what happens after hello - what the token permits, and how a client asks for more without starting over.

It starts with the least glamorous HTTP status code in existence. An unauthenticated client hits the MCP endpoint and gets a 401 back. In MCP, that 401 is not a dead end; it's a directory:

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"
```

That `resource_metadata` parameter is RFC 9728 - Protected Resource Metadata, published April 2025 [^2] - and MCP servers MUST implement it. The PRM document at that URL names the resource's canonical URI and lists its `authorization_servers`, and that list is mandatory, not optional. There's also a well-known path form (`/.well-known/oauth-protected-resource/<path>`) for clients that prefer to probe rather than wait for a challenge [^6]. Either way, the client learns *who issues tokens for this server* by asking *the server itself* - no hardcoded IdP URLs in client configs.

With the authorization server located, the client requests a token, and this is where two RFCs that most web developers have never needed become load-bearing.

**RFC 8707, Resource Indicators (February 2020 - not 2022, which is the date I had wrong in my notes for a year [^7]).** The client MUST include a `resource` parameter equal to the MCP server's canonical URI in both the authorization request and the token request. The authorization server bakes that URI into the token's `aud` claim. The consequence: a token minted for the calendar server is garbage at the database server. Audience binding is the property that keeps one compromised MCP server from becoming a universal transit pass across your whole MCP fleet [^3].

**RFC 9207, Issuer Identification (March 2022).** After the user authorizes, the AS includes an `iss` parameter in the authorization response naming itself. Why care? Because of *authorization server mix-up* attacks: a client that talks to two authorization servers can be tricked into submitting an authorization code to the wrong one, and a naive client can't tell the difference. The 2026-07-28 spec makes the client-side check mandatory: if the AS advertises `authorization_response_iss_parameter_supported: true` and the response arrives without `iss`, the client MUST reject it; otherwise it MUST validate `iss` against the issuer it recorded when it created the PKCE verifier [^4]. And once again the spec demands **simple string comparison per RFC 3986 §6.2.1** - no case folding, no port elision. Same rule as CIMD in part 2. When a spec repeats "exact string match, no normalization" this many times, it's telling you where implementations historically cheat.

## 2. Start with less than you need

Here's the behavioral half, and it's the part I'd put on a poster in the office: the spec wants clients to ask for *less* than they need on first connect.

The priority order is spelled out [^1]: use the `scope` the initial 401 challenge suggests; if there isn't one, request everything in the PRM's `scopes_supported` - which "is intended to represent the minimal set of scopes necessary for basic functionality"; if even that's undefined, omit scope entirely. The [security best practices tutorial](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices) goes further and names the anti-patterns: wildcard scopes, bundling unrelated privileges into one scope, returning the entire scope catalog to every client [^8].

If you've read my earlier [post on scopes and least privilege](/posts/part-02-mcp-auth-authz), this is the same principle with enforcement teeth. The reason it matters more for agents than for apps: an agent's scope request happens once, at a moment the user may not be paying attention, and the agent will happily reuse those permissions later in contexts nobody reviewed. A client that connects with `mcp:tools-basic` and elevation at runtime is auditable line by line. A client that connects with `admin:* because we might need it` is an incident waiting for a date.

## 3. Step-up at runtime: 403, challenge, union

So the agent is connected with its modest baseline and everything is fine - until it calls a tool that writes instead of reads. The server doesn't need to fall back to "reconnect with bigger scopes." The 2026-07-28 spec defines the runtime shortfall signal, and the example below is verbatim from the authorization spec [^5]:

```
HTTP/1.1 403 Forbidden
WWW-Authenticate: Bearer error="insufficient_scope",
                         scope="files:write",
                         resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource",
                         error_description="File write permission required for this operation"
```

Note what the challenge carries: the error code, the *specific* missing scope, and the discovery pointer again so the client can find its way back to the right authorization server. The spec adds a rule with real consequences for client implementers: "Clients MUST treat the scopes provided in the challenge as authoritative for the current operation" [^5]. The challenge isn't a hint. It's the server telling the client exactly what this operation needs, right now.

The client's job then is to re-authorize without losing anything it already had. Here's the spec's actual normative sentence, because this is the part I most often see paraphrased into wrongness:

> "Determine required scopes by computing the union of the client's previously requested scope set and the scopes from the current challenge." [^5]

As a formula - the research brief's notation, not the spec's - it's this:

```
S_union = S_granted ∪ S_challenged
```

The union is the whole trick. A naive client would request *only* `files:write` during the re-authorization round trip and get back a token that can write but can't read, silently downgrading itself mid-conversation. Computing the union means the new token carries `files:read ∪ files:write`, and the elevated session is a strict superset of the old one. This is spec text in the 2026-07-28 revision and its draft successors - it is *not* in the 2025-06-18 authorization spec, so don't backdate it in your own docs [^9].

Two guardrails ride along in the same section: clients should cap retries (the spec suggests retrying "no more than a few times" and treating repeated failure as permanent) and track scope-upgrade attempts; servers MUST honor scope hierarchies so `admin:files` genuinely covers `files:write` [^5]. The whole flow, end to end:

{{< mermaid >}}
sequenceDiagram
    participant A as Agent (MCP Client)
    participant S as MCP Server (RS)
    participant I as IdP (AS)

    A->>S: tool call: read_files (scope: files:read)
    S-->>A: results
    A->>S: tool call: write_files
    S-->>A: 403 + WWW-Authenticate insufficient_scope scope="files:write"
    Note over A: S_union = {files:read} ∪ {files:write}
    A->>I: re-authorize (PKCE, resource=canonical URI, scope=S_union)
    I-->>A: new token (aud=MCP server, files:read + files:write)
    A->>S: tool call: write_files (retry)
    S-->>A: results
{{< /mermaid >}}

## 4. Enforcing it server-side with FastMCP

All of that client choreography only means something if the server actually draws the lines. FastMCP ships three built-in auth checks - `require_scopes`, `require_roles`, and `restrict_tag` [^10] - and the differences between them are more interesting than the API surface suggests.

**Scope checks produce challenges. Role checks produce dead ends.** This is the nuance I got wrong on the first draft of this post, so here it is spelled out. `require_scopes("files:write")` on a tool produces exactly the `insufficient_scope` shortfall we walked through: a structured denial that names the missing scopes and tells the client what to request. `require_roles("admin")` cannot do that, because - as the docs put it - "OAuth has no way to request a role. A role denial surfaces as a plain `AuthorizationError`" and it suppresses any scope shortfall raised alongside it [^10]. There is no OAuth dance that grants a role. Roles live in claims, and claims are whatever your IdP put in the token - which is why `require_roles` takes an `extract` callable for each provider's claim layout:

```python
from fastmcp import FastMCP
from fastmcp.server.auth import require_scopes, require_roles, restrict_tag
from fastmcp.server.middleware import AuthMiddleware

mcp = FastMCP(
    "Enterprise-RBAC-Server",
    middleware=[
        # Server-wide: any tool tagged "sensitive" needs admin:write
        AuthMiddleware(auth=restrict_tag("sensitive", scopes=["admin:write"]))
    ],
)

def extract_keycloak_roles(claims: dict) -> list[str]:
    return claims.get("realm_access", {}).get("roles", [])

@mcp.tool(auth=require_scopes("db:read"))
def read_records(query: str) -> str:
    return f"Results for {query}"

@mcp.tool(
    auth=[require_scopes("db:write"), require_roles("admin", extract=extract_keycloak_roles)],
    tags={"sensitive"},
)
def purge_records(table: str) -> str:
    """Fails closed unless the caller has db:write AND the admin role."""
    return f"Purged {table}"
```

Read that example as three layers stacked: per-tool scopes, per-tool roles against a Keycloak claim path, and a tag-based server-wide policy through `AuthMiddleware` (the middleware framework dates to FastMCP 2.9.0; the auth checks to 3.0.0/4.0.0 [^10]). `InsufficientScopeError` - the subclass `AuthMiddleware` raises for missing-scope denials - carries the exact `required_scopes` list, which is what lets a well-behaved client compute its union and step up instead of dying [^10].

One design decision to make deliberately: component-level `auth=` arguments control both **visibility and access**. A tool the caller can't use is filtered out of `tools/list` entirely, and a direct lookup comes back not-found. That's usually what you want - why advertise a purge tool to callers who can never run it? - but if you'd rather have execution attempts answered with an explicit error instead of silent absence, that's precisely what `AuthMiddleware` at the server level is for [^10]. Silent filtering for browsing, explicit errors for doing.

## Key takeaways

- **The 401 challenge is a discovery document pointer** (RFC 9728 §5.1), the PRM names the authorization servers, and none of it needs to be configured into the client by hand.
- **Audience binding (RFC 8707) and issuer validation (RFC 9207) are client obligations now**, both with exact string comparison, and both exist to kill replay and mix-up attack classes that were theoretical in 2024 and normal by 2026.
- **Ask for less at connect time, elevate at tool-call time.** The spec's own priority order starts from the challenge's `scope` hint, and `scopes_supported` is defined as the *minimal* set for basic functionality.
- **The scope union is normative**: on a `403 insufficient_scope`, re-authorize for previously-granted ∪ challenged, retry a bounded number of times, and treat repeated failure as permanent.
- **In FastMCP, scopes challenge and roles deny.** `require_scopes` produces an actionable shortfall; `require_roles` produces a flat `AuthorizationError`, because OAuth cannot request a role - design your elevation UX around scopes.

Everything in this post assumes the counterparty is honest: that the server's challenges are real, its discovery documents point where they claim, and its tool descriptions mean what they say. Part 4 drops that assumption entirely - token passthrough, confused-deputy proxies, SSRF in discovery, and tool descriptions that lie to the model.

---

## References

[^1]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)." Official MCP Specification, 2026-07-28 revision. Accessed October 20, 2026. Scope selection priority; `scopes_supported` as minimal set.

[^2]: M. Jones, A. Hunt and A. Parecki. "[OAuth 2.0 Protected Resource Metadata](https://www.rfc-editor.org/info/rfc9728)." RFC 9728. IETF. April 2025.

[^3]: R. Campbell, J. Bradley and H. Tschofenig. "[Resource Indicators for OAuth 2.0](https://www.rfc-editor.org/info/rfc8707)." RFC 8707. IETF. February 2020.

[^4]: L. Meyer zu Selhausen and P. Fett. "[OAuth 2.0 Authorization Server Issuer Identification](https://www.rfc-editor.org/info/rfc9207)." RFC 9207. IETF. March 2022. Client-side validation semantics per MCP SEP-2468 in the 2026-07-28 spec.

[^5]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)." Official MCP Specification, 2026-07-28 revision. Accessed October 20, 2026. Step-up authorization flow; scope-union wording; `403 insufficient_scope` example, quoted verbatim.

[^6]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)." Official MCP Specification, 2025-11-25 revision. Accessed October 20, 2026. PRM well-known discovery paths.

[^7]: R. Campbell, J. Bradley and H. Tschofenig. "[Resource Indicators for OAuth 2.0](https://www.rfc-editor.org/info/rfc8707)." RFC 8707. IETF. February 2020. Publication date per the RFC Editor record.

[^8]: Model Context Protocol. "[Security Best Practices](https://modelcontextprotocol.io/docs/2025-11-25/tutorials/security/security_best_practices)." Official MCP Documentation, 2025-11-25. Accessed October 20, 2026. Scope minimization section: minimal initial scope sets and common mistakes.

[^9]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)." Official MCP Specification, 2026-07-28 revision. Accessed October 20, 2026. The scope-union guidance first appears in this revision; the 2025-06-18 authorization spec contains no step-up flow.

[^10]: FastMCP. "[Authorization](https://gofastmcp.com/servers/authorization.md)." FastMCP Documentation (v4.x). Accessed October 20, 2026. `require_scopes` (3.0.0), `require_roles` with `extract` (4.0.0), `restrict_tag` + `AuthMiddleware`, `InsufficientScopeError`, and visibility-vs-access semantics. Role-denial behavior quoted verbatim.

[^11]: FastMCP. "[Middleware](https://gofastmcp.com/servers/middleware.md)." FastMCP Documentation (v4.x). Accessed October 20, 2026. Middleware framework (2.9.0) and `AuthMiddleware` behavior.
