---
title: "MCP Security Master Class Part 1 - You're Doing MCP Auth Wrong: OAuth 2.1 Delegation and the Stateless Core"
description: "The 2026-07-28 MCP spec retires the session handshake and settles the auth question: your MCP server is a pure OAuth 2.1 Resource Server, your IdP is the Authorization Server, and every request carries its own identity."
tags:
  - MCP
  - Security
  - OAuth
summary: 'Early MCP servers shipped their own authorization logic - the 2025-03-26 spec even let a server mint tokens itself. The 2026-07-28 revision closes that door for good: MCP is now a stateless protocol where the server is a plain OAuth 2.1 Resource Server, the identity provider you already run is the Authorization Server, and every request carries its protocol version, client identity and capabilities in `_meta`. This post shows the full arc, and how to implement the pure-verification pattern in FastMCP.'
draft: true
series:
  - MCP Security Master Class
series_order: 1
date: '2026-10-20'
---

## TL;DR

- The **2026-07-28 spec retires the `initialize`/`initialized` handshake and removes `Mcp-Session-Id`** - every request now carries its protocol version, client info and capabilities in `_meta`, so any request can land on any server instance behind a dumb round-robin load balancer
- The **"built-in auth server" era is over**: the 2025-03-26 spec let an MCP server act as its own authorization server and mint tokens; today's spec casts the MCP server as a pure **OAuth 2.1 Resource Server** that only verifies
- The **Authorization Server is your existing enterprise IdP** - Keycloak, Entra ID, Okta, Auth0 - not something you build into the MCP server
- **OAuth 2.1 is still an IETF draft**, not an RFC. MCP pins `draft-ietf-oauth-v2-1-13`; the working-group draft has since moved to -16. Say "draft" or be wrong
- In FastMCP, the whole pattern is a **`JWTVerifier`** pointed at your IdP's JWKS endpoint, plus **`get_access_token()`** inside tools when you need the claims

---

## 1. Where we came from: the built-in auth server era

I wrote a [seven-part MCP Security series](/posts/part-01-mcp-auth-trust-boundary) earlier this year. Part 1 mapped the trust boundaries, part 6 walked through OAuth 2.1 with Keycloak as your own authorization server. Both were written against a protocol that still existed in a specific historical form: an MCP server that, in the 2025-03-26 spec revision, was allowed to do something genuinely strange.

That revision introduced MCP's first formal authorization spec, and it defined a "third-party authorization" flow in which the MCP server acted as **both** an OAuth client (toward some upstream identity provider) **and** an authorization server (toward the MCP client). The server would accept an upstream session and then generate its own access token bound to it. Your MCP server wasn't just a tool server - it was issuing tokens. It had become a miniature identity provider whether you wanted one or not.

If you ever wondered why so many early MCP auth implementations felt hand-rolled and inconsistent, this is a big part of the answer. The spec didn't just permit custom auth servers; it sketched the blueprint for them. Everyone built slightly different ones, and every one of them was a new piece of security-critical code with token signing, consent handling, and revocation logic to get right.

The transport side had a matching problem. Since the [2025-03-26 spec](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports), a Streamable HTTP server **could** assign a session at initialization time and hand back a `Mcp-Session-Id` header; clients had to echo it on every subsequent request. Note the wording - the server *MAY* assign one. Sessions weren't strictly mandatory, but the protocol's shape assumed state: a handshake first (`initialize`, then the `initialized` notification), then a conversation pinned to one server instance. If you read my [introduction to the spec](/posts/mcp-series-02-the-spec), that stateful handshake was presented as simply how MCP works. I also flagged the "statefulness tax" back then - servers holding connection state in memory, sticky sessions, complications with horizontal scaling [^1]. That tax bill just came due, and the protocol paid it off.

## 2. The 2026-07-28 revision: a stateless protocol core

The current spec revision, released 2026-07-28, is the biggest structural change MCP has had. The release announcement is blunt about it:

> "The highlight of this release is a stateless protocol core - MCP is transforming from a bidirectional stateful protocol into a request/response stateless protocol." [^2]

Concretely, what changed:

| Old world (2025-03-26 → 2025-11-25) | New world (2026-07-28) |
|---|---|
| `initialize` / `initialized` handshake | Retired entirely [^3] |
| Optional `Mcp-Session-Id` header on Streamable HTTP | Header removed from the transport [^3] |
| Server remembers capabilities and client identity between requests | "Servers MUST NOT rely on prior requests over the same connection to establish context" [^4] |
| SSE resumability via `Last-Event-ID`, GET endpoint for notifications | Both removed; server-initiated messages move to `subscriptions/listen` [^3] |
| Gateways must parse JSON bodies to route requests | `Mcp-Method` and `Mcp-Name` HTTP headers are required on every Streamable HTTP POST (SEP-2243) [^5] |

In place of the handshake, every request describes itself. The `_meta` object on each JSON-RPC message carries `io.modelcontextprotocol/protocolVersion`, and clients identify themselves per request via `io.modelcontextprotocol/clientInfo` and declare features via `io.modelcontextprotocol/clientCapabilities`. Version mismatch gets you an `UnsupportedProtocolVersionError` instead of a broken half-negotiated session. A new `server/discover` RPC lets a client ask a server what it speaks - servers MUST implement it, clients MAY call it, and the release blog is explicit that calling it "is not required" [^2]. Don't write that discovery is mandatory for clients; it isn't.

The operational payoff is the sentence I keep coming back to:

> "Any request can now land on any server instance behind a plain round-robin load balancer without needing shared storage." [^2]

No sticky sessions. No session store to replicate or lose. Your MCP server is now a pure request/response service that you can deploy on serverless infrastructure, autoscale to zero, or put behind the same boring load balancer as everything else. For anyone who ran a stateful MCP deployment in production and watched a rolling update break half the active sessions, this is the fix.

The routing headers deserve a security note of their own. Because `Mcp-Method` and `Mcp-Name` travel as plain HTTP headers, your gateway, WAF, or rate limiter can route, meter, and filter on *which protocol method* is being invoked - before the request ever reaches your application or gets deserialized. The blog's framing: "Your gateway, rate limiter, or WAF can route and meter on those headers instead of parsing JSON bodies." [^2] List responses (`tools/list`, `resources/list`, and friends) now carry explicit `ttlMs` and `cacheScope` (`public`/`private`) directives too. Watch that second one: a multi-tenant server that marks tenant-specific tool lists `public` is handing one tenant's metadata to the shared cache. Scope your caches like you scope your tokens.

{{< figure src="images/mcp-masterclass/mcp-oauth-delegation.svg" alt="Architecture diagram of the 2026 MCP authorization model: an MCP client behind a user talks OAuth 2.1 to an enterprise identity provider acting as Authorization Server, and sends stateless HTTP requests - each carrying _meta with protocol version, client info and capabilities, plus an Authorization bearer token - through a load balancer and WAF that route on the Mcp-Method and Mcp-Name headers to any MCP server instance acting as a pure OAuth 2.1 Resource Server, which verifies the token against the IdP's JWKS endpoint." caption="One identity provider issues, the MCP server only verifies, and every request carries its own context - nothing is pinned to an instance." >}}

## 3. The delegation model: three roles, one job each

The stateless core is half of the 2026-07-28 story. The other half is that the authorization model finally settled into a textbook OAuth deployment. From the current authorization spec:

> "A protected MCP server acts as an OAuth 2.1 resource server, capable of accepting and responding to protected resource requests using access tokens. An MCP client acts as an OAuth 2.1 client… The authorization server is responsible for interacting with the user (if necessary) and issuing access tokens for use at the MCP server." [^6]

Three roles, and the mapping could not be cleaner:

- **MCP server = OAuth 2.1 Resource Server (RS).** It holds a resource worth protecting, verifies presented tokens, and does *nothing else* auth-wise. It never signs a token. It never shows a consent screen. It never stores a client credential.
- **MCP client = OAuth 2.1 Client.** It obtains tokens from the authorization server and presents them. (How it proves its own identity to that server is the subject of [the next post](/posts/mcp-masterclass-02-cimd) - and the answer changed in the same spec revision.)
- **Your enterprise IdP = OAuth 2.1 Authorization Server (AS).** Keycloak, Entra ID, Okta, Auth0, WorkOS - whatever already holds your users, your policies, your MFA, and your revocation story.

That last line is the whole point of delegation. In the old model, every MCP server inventor had to rebuild login flows, consent UIs, token signing keys, and revocation - badly, and separately. In the new model, the MCP server delegates every one of those decisions to infrastructure that already exists in the enterprise and has already been audited to death. Your MCP server's security posture collapses down to one question: *can it verify a token correctly?*

One precision item, because I see this get garbled constantly: the [trust boundaries from part 1 of the old series](/posts/part-01-mcp-auth-trust-boundary) still apply, and the first hop is still the only hop MCP governs [^7]. Token *audience* binding - the `resource` parameter and the `aud` claim that keep a token minted for one server from being replayed at another - is part of this same delegation story, but it has enough moving parts (RFC 8707, `WWW-Authenticate` discovery, issuer validation) that it gets its own post. [Part 3](/posts/mcp-masterclass-03-step-up-authz) covers it.

Also, for the pedants (I count myself among them): OAuth 2.1 remains an Internet-Draft. The MCP spec pins `draft-ietf-oauth-v2-1-13` and has pinned that same draft across the 2025-06-18, 2025-11-25 and 2026-07-28 revisions [^8]. The IETF working group draft has since advanced to -16 and is still, as of this writing, not an RFC. When you cite OAuth 2.1 in docs or code comments, cite the draft. Otherwise someone will eventually repo-issue you, and they'll be right.

## 4. Implementing pure token verification in FastMCP

The FastMCP implementation of "be a Resource Server, nothing more" fits on one screen. You describe your IdP; FastMCP handles verification on every request:

```python
from fastmcp import FastMCP
from fastmcp.server.auth.providers.jwt import JWTVerifier
from fastmcp.server.dependencies import get_access_token

# Pure token verification against the enterprise IdP's JWKS
auth = JWTVerifier(
    jwks_uri="https://auth.enterprise.com/.well-known/jwks.json",
    issuer="https://auth.enterprise.com",
    audience="https://mcp.enterprise.com/v1",
)

mcp = FastMCP("Stateless-Secure-Server", auth=auth)

@mcp.tool
def get_user_profile() -> dict:
    """Read the verified identity of the caller."""
    token = get_access_token()
    if not token:
        return {"error": "Unauthenticated"}
    return {"user_id": token.claims.get("sub"), "scopes": token.scopes}
```

Three things worth knowing about this setup:

**The verifier fetches and rotates keys on its own.** `JWTVerifier` pulls the JWKS from your IdP, caches the keys (an hour by default) and refreshes them on a short interval (30 seconds by default), so key rotation at the IdP doesn't require a redeploy on your side [^9]. Signature verification covers RSA, ECDSA, and Ed25519 families.

**`get_access_token()` is your per-request identity.** It returns an `AccessToken` with the client id, scopes, and the raw token claims - or `None` if there's no authenticated caller. There's also a dependency-injection flavor, `CurrentAccessToken()`, which raises instead of returning `None` when you'd rather fail loudly [^10]. Inside the tool you're reading *verified* claims - the signature check already happened upstream of your code.

**The three constructor parameters are the security model.** `jwks_uri` says whose keys to trust, `issuer` pins who minted the token, and `audience` demands the token was issued *for this server*. Drop the audience check and you've rebuilt the token-passthrough hole with extra steps - which is exactly where [part 4](/posts/mcp-masterclass-04-threat-topology) picks up the story.

If your IdP can't hand out signed JWTs at all, `JWTVerifier` isn't your only option: the same provider family includes an RFC 7662 introspection verifier, a static verifier for tests, and others [^9]. But for the common case - an enterprise IdP that speaks JWT - the pattern above is the entire server-side auth implementation. Compare that to what the 2025-03-26 spec asked you to build, and the direction of the protocol is obvious.

## Key takeaways

- **Statelessness is now the protocol's law, not a deployment preference.** No handshake, no session header; `_meta` on every request carries protocol version, client info and capabilities, and `server/discover` is server-MUST but client-MAY.
- **The MCP server is a Resource Server, full stop.** It verifies tokens against the IdP's JWKS. It doesn't mint, consent, or register anything. The 2025-03-26 server-as-authorization-server flow is history, and good riddance.
- **Your enterprise IdP is the Authorization Server.** You inherit its MFA, policies, and revocation instead of rebuilding them badly inside a tool server.
- **OAuth 2.1 is a draft.** MCP pins -13; the WG is at -16. Precision here is free credibility.
- **`JWTVerifier` + `get_access_token()` is the whole pattern** in FastMCP - and the `audience` parameter is not optional hygiene, it's the fence line we'll see attacked in part 4.

Authentication delegation is now settled: the server verifies, the IdP vouches. What's *not* settled - until you look closely - is how the client proves to the IdP what it is. For thirty years the answer was "register first." MCP just deprecated that answer. Next post: Client ID Metadata Documents, and why the client's ID is about to become a URL you can read out loud.

---

## References

[^1]: My own earlier write-up: "[MCP Security Part 5 - The Statefulness Tax and Other Hard Trade-offs](/posts/mcp-series-05-challenges)." MCP Introduction Series. December 2025.

[^2]: Model Context Protocol. "[The 2026-07-28 Specification](https://blog.modelcontextprotocol.io/posts/2026-07-28/)." Official MCP Blog. July 28, 2026.

[^3]: Model Context Protocol. "[Key Changes in the 2026-07-28 Specification](https://modelcontextprotocol.io/specification/2026-07-28/changelog)." Official MCP Specification. July 28, 2026. Covers SEP-2567 (session removal), SEP-2575 (handshake retirement), SEP-2549 (cacheable lists), the MRTR pattern, and the deprecation policy.

[^4]: Model Context Protocol. "[Protocol Overview](https://modelcontextprotocol.io/specification/2026-07-28/basic)." Official MCP Specification, 2026-07-28 revision. Accessed October 20, 2026.

[^5]: Model Context Protocol. "[Key Changes in the 2026-07-28 Specification](https://modelcontextprotocol.io/specification/2026-07-28/changelog)." Official MCP Specification. July 28, 2026. SEP-2243: required `Mcp-Method` / `Mcp-Name` headers on Streamable HTTP POSTs.

[^6]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)." Official MCP Specification, 2026-07-28 revision. Accessed October 20, 2026. Roles section, quoted verbatim.

[^7]: Paul Carleton. "[Why is MCP Auth Hard and What Are We Planning to Do About It](https://www.youtube.com/watch?v=wvtGlur2SdI)." MCP Developers Summit EU 2025. London, UK. October 2, 2025. The two-hop framing in my earlier [trust boundary post](/posts/part-01-mcp-auth-trust-boundary) draws on this talk.

[^8]: IETF OAuth Working Group. "[The OAuth 2.1 Authorization Framework](https://datatracker.ietf.org/doc/draft-ietf-oauth-v2-1/)." draft-ietf-oauth-v2-1-16, September 2026 (active Internet-Draft). The MCP spec cites draft-ietf-oauth-v2-1-13.

[^9]: FastMCP. "[Token Verification](https://gofastmcp.com/servers/auth/token-verification.md)." FastMCP Documentation (v4.x). Accessed October 20, 2026. `JWTVerifier` constructor parameters, JWKS caching and rotation behavior, and the verifier family.

[^10]: FastMCP. "[Dependency Injection](https://gofastmcp.com/servers/dependency-injection.md)." FastMCP Documentation (v4.x). Accessed October 20, 2026. `get_access_token()` and `CurrentAccessToken()`.
