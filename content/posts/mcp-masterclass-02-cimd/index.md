---
title: "MCP Security Master Class Part 2 - Stop Registering, Start Linking: The CIMD Paradigm Shift"
description: Dynamic Client Registration made sense for a fixed web of first-party apps. For an open ecosystem of AI agents it means credential sprawl and zero publisher verification. CIMD replaces registration with a URL you already own.
tags:
  - MCP
  - Security
  - OAuth
summary: 'Part 1 settled that the MCP server only verifies tokens and the enterprise IdP issues them. This post covers the question that remains: how does a client introduce itself to that IdP? Dynamic Client Registration - an OAuth 2.0 mechanism from 2015 - is now formally deprecated in the MCP spec, replaced by Client ID Metadata Documents, where the client_id is an HTTPS URL the client hosts itself. We walk through why DCR fails for agentic ecosystems, the exact validation rules an authorization server applies to a CIMD document, and the FastMCP provider matrix that wires it all up.'
draft: true
series:
  - MCP Security Master Class
series_order: 2
date: '2026-10-20'
---

## TL;DR

- **DCR is formally deprecated in the 2026-07-28 spec** (PR #2858). It still works for backward compatibility and will be removed in a future version; CIMD is the successor. Note that CIMD support is SHOULD-level and DCR is MAY - deprecated, not banned
- **DCR's agentic-era failures**: unbounded client-id sprawl from per-install registrations, no verification of who published the client, and authorization servers rejecting `localhost` redirect URIs for desktop and CLI apps (the pain SEP-837's `application_type` requirement patches, poorly)
- **CIMD makes the client_id an HTTPS URL.** The authorization server fetches `client.json` from the client's own domain over TLS, checks the document's `client_id` matches the fetch URL byte-for-byte, and validates the requested redirect URI against the document
- **Comparison is strict string matching** (RFC 3986 §6.2.1): `https://example.com/client` and `https://example.com:443/client` are *not* equivalent. No port elision, no case folding, no percent-decoding
- **FastMCP maps the decision for you**: `RemoteAuthProvider` for DCR-capable IdPs, `OAuthProxy` for everyone else, `MultiAuth` when you need both interactive and machine-to-machine paths

---

## 1. The question part 1 left open

[Part 1](/posts/mcp-masterclass-01-auth-delegation) ended with a clean division of labor: the MCP server verifies tokens, the authorization server issues them, and neither pretends to be the other. But look at the OAuth flow from the authorization server's point of view and there's an unanswered question sitting right at the front door. A client shows up and asks for tokens for your users. The server's first question is not "what do you want" but "**who are you?**"

In classic OAuth 2.0, the answer came from registration. Somebody - a developer, at a console, before launch - created a client record and got back a `client_id` and `client_secret`. That worked when the set of clients was small, known, and first-party. It works noticeably less well when the clients are thousands of AI agents, IDE extensions, CLI tools and ephemeral containers that nobody's administrator has ever heard of, appearing and disappearing on a Tuesday afternoon.

MCP went through all three answers in about sixteen months. The timeline is worth seeing in one place, because each step is a spec revision:

| Spec revision | DCR status | Notes |
|---|---|---|
| 2025-03-26 | SHOULD | First formal auth spec, alongside RFC 8414 [^1] |
| 2025-06-18 | SHOULD | Roles reframed: server = RS, IdP = AS [^2] |
| 2025-11-25 | **MAY** | CIMD introduced via SEP-991 with SHOULD support [^3] |
| 2026-07-28 | **Deprecated** | "Dynamic Client Registration itself is now formally deprecated in favor of CIMD. DCR continues to work for backward compatibility, but will be removed in a future version of the MCP spec." [^4] |

Read the last row carefully. Deprecated in favor of CIMD, yes - but the current spec still says authorization servers and clients "MAY support" DCR, and CIMD support is a SHOULD, not a MUST [^5]. There's also a minimum twelve-month deprecation window before anything gets removed [^6]. So if your authorization server doesn't do CIMD yet, you have a documented grace period. What you don't have is a reason to build anything new on DCR.

## 2. Why DCR breaks in an agentic ecosystem

Dynamic Client Registration (RFC 7591, published July 2015 [^7]) lets a client POST a JSON metadata blob to a registration endpoint and receive a `client_id` on the spot. For the web of 2015, fine. For agents, three specific failures compound:

**Registration sprawl.** Every fresh install of a desktop app, every container restart that re-registers, creates another client record on the authorization server. The CIMD draft itself names this as a motivation: DCR "can create additional challenges around management of the registration data and cleanup of inactive clients" [^8]. Thousands of orphaned client IDs later, nobody can tell which registrations are legitimate, which are stale, and which are an attacker's.

**Zero publisher verification.** An open registration endpoint accepts whatever display name the submitter typed. A client can register as "Claude Desktop" or "Acme Enterprise Connector" without controlling any domain associated with those names. Users make trust decisions based on names on consent screens; DCR gives attackers a way to forge the name while the actual requester is unverified.

**Loopback rejection.** Desktop and CLI agents receive their OAuth callback on `http://127.0.0.1:<port>`. Plenty of enterprise authorization servers reject loopback redirect URIs during dynamic registration because the registration didn't declare what kind of application it is. MCP's stopgap is SEP-837 - a specification enhancement proposal, I'll note, not an IETF document - which requires clients to send an appropriate `application_type` during registration so that OpenID Connect's redirect URI validation rules don't reject `localhost` callbacks [^9]. The release blog puts the pain plainly: "If you've ever wondered why your CLI client's OAuth flow got a `redirect_uri` error, this is likely why." [^4] It's a patch on the symptom. CIMD removes the disease.

## 3. How CIMD actually works

The idea is almost embarrassingly simple once you've lived with DCR: **the client_id is an HTTPS URL**, and the client serves its own metadata document at that URL. Instead of the authorization server holding a record about the client, it reads what the client publishes, at an address the client has proven it controls - because that's what TLS and a domain name mean.

When an authorization request arrives with a URL-shaped `client_id` like `https://app.example.com/oauth/client-metadata.json`, the server fetches the document over TLS and validates it [^10]:

1. **Identity match.** The `client_id` field inside the document must equal the URL it was fetched from - compared as a **simple string comparison per RFC 3986 §6.2.1**. No default-port normalization, no case folding, no percent-decoding. The draft is explicit: "https://example.com/client and https://example.com:443/client are not equivalent" [^11]. This is stricter than most developers' intuition, and that's deliberate - every normalization rule is a place for confusion attacks to hide.
2. **URL shape.** The client identifier URL must use https, must not contain userinfo, must contain a path, and must not use dot-segments or a fragment; a port is allowed, a query component should not be there [^11].
3. **Redirect URI match.** The `redirect_uri` the client is asking to use must be listed, verbatim, in the document's `redirect_uris` [^10]. This kills the DCR-era trick of registering one redirect and requesting another.
4. **Fetch discipline.** The fetch-and-cache behavior is normative in the draft: a 200 response with the metadata, cached according to the document's caching headers [^12]. No client secret is provisioned at all - public clients just are.

That third-party trust anchor is the deep point. Domain ownership is verifiable through the existing web PKI, without any new infrastructure. If the document at `app.example.com` says the redirect URI is `https://app.example.com/callback`, you're not trusting the client's self-description - you're trusting whoever controls that DNS name, which is the same trust you already extend to their website.

And yes, loopback callbacks are allowed. A published document can list `http://127.0.0.1:8765/callback` in its `redirect_uris`, so desktop and CLI tools get their callback flow without custom URI schemes and without an `application_type` fight at registration time [^5].

One dating note so you cite this correctly in your own docs: the current IETF draft is **draft-ietf-oauth-client-id-metadata-document-02**, by Aaron Parecki (Okta) and Emelia Smith, updated 2026-07-06 [^8]. The MCP spec's standards list still cites the -00 version [^5] - cite -02 for the current document content, and don't call it an RFC yet either.

If you want a full annotated `client.json` with every field explained, my [part 6 appendix in the earlier series](/posts/part-06-mcp-oauth) already does that job and I won't repeat it. The one pattern worth internalizing here is the shape: identity is a location, and possession of the location is the proof.

## 4. The FastMCP provider matrix

On the server side, FastMCP's auth providers map one-to-one onto the registration capabilities of your upstream IdP [^13]:

**Providers with DCR** - modern OIDC platforms like WorkOS AuthKit or Descope - use `RemoteAuthProvider`, which composes a token verifier with the provider's discovery metadata. The specialized `AuthKitProvider` is the WorkOS flavor:

```python
from fastmcp.server.auth.providers.workos import AuthKitProvider

auth = AuthKitProvider(
    authkit_domain="https://project.authkit.app",
    base_url="https://mcp.example.com",
)
```

**Providers without DCR** - GitHub, Google, Azure AD, most legacy enterprise IdPs - can't accept new clients dynamically, so `OAuthProxy` bridges them: it presents the DCR-facing flow MCP clients expect on one side and translates to fixed, pre-registered credentials on the other, with a consent step in the middle. `GitHubProvider` is the packaged version [^14]. (That consent step is not a formality - it's attack surface, which is exactly where [part 4](/posts/mcp-masterclass-04-threat-topology) is going.)

**Both kinds of traffic** - interactive humans through the proxy, machine-to-machine agents presenting JWTs directly - compose with `MultiAuth`, which tries each source in order and accepts the first successful verification [^15]:

```python
from fastmcp.server.auth import MultiAuth, OAuthProxy
from fastmcp.server.auth.providers.jwt import JWTVerifier

m2m_verifier = JWTVerifier(
    jwks_uri="https://idp.enterprise.com/.well-known/jwks.json",
    issuer="https://idp.enterprise.com",
    audience="https://mcp.enterprise.com",
)

interactive = OAuthProxy(
    upstream_authorization_endpoint="https://idp.enterprise.com/oauth/authorize",
    upstream_token_endpoint="https://idp.enterprise.com/oauth/token",
    upstream_client_id="...",
    upstream_client_secret="...",
    token_verifier=m2m_verifier,
    base_url="https://mcp.enterprise.com",
)

# The proxy is tried first; the raw JWT verifier is the fallback.
auth = MultiAuth(server=interactive, verifiers=[m2m_verifier])
```

On the client side, FastMCP can speak CIMD natively, and the `fastmcp cli auth` utility can create and validate CIMD documents - which makes "publish your client.json" a one-command step rather than a static file you hand-edit and hope is well-formed [^13].

A short aside for enterprise architects, because the research I did for this series turned it up and it doesn't belong to any single post: registration is only half of the enterprise-friction problem. The other half is consent fatigue - users in a corporation authorizing fifty internal MCP servers through fifty browser redirects. The MCP ecosystem's answer there is the stable **Enterprise-Managed Authorization (EMA)** extension, an application of the IETF identity-chaining work (the ID-JAG family of drafts, still drafts, not an RFC) that lets the client present an enterprise IdP-issued assertion to the server's authorization endpoint without any browser redirect at all [^16]. If that describes your org chart, read the ext-auth specification before designing anything custom; the machinery is further along than most people assume.

## Key takeaways

- **The registration war is over, and DCR lost.** Deprecated in 2026-07-28, retained for backward compatibility, scheduled for removal. New builds target CIMD.
- **DCR's failure modes are structural, not cosmetic**: per-install record sprawl, forgeable display names, and loopback redirect rejections that SEP-837 could only patch.
- **CIMD's trust anchor is DNS plus TLS**, both of which you already operate. The authorization server fetches the client's metadata from the client's own domain and holds it to exact string matching - including refusing to normalize ports.
- **FastMCP gives you a provider for every point on the DCR spectrum**: `RemoteAuthProvider`/`AuthKitProvider` for DCR-native platforms, `OAuthProxy` for GitHub-style IdPs, `MultiAuth` for hybrid interactive + M2M deployments.
- **CIMD is a draft (-02) and EMA/ID-JAG are drafts** - cite them as such.

So now the client can prove to the IdP what it is, and the server knows how to verify what comes back. What's left is the question users actually care about: what is the token *allowed to do*, and what happens when a tool needs more than the client was granted at login? That's step-up authorization - `WWW-Authenticate` challenges, the 403 `insufficient_scope` dance, and one piece of set theory. Next post.

---

## References

[^1]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization)." Official MCP Specification, 2025-03-26 revision. Accessed October 20, 2026. DCR SHOULD with fallbacks; first formal authorization spec.

[^2]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization)." Official MCP Specification, 2025-06-18 revision. Accessed October 20, 2026.

[^3]: Model Context Protocol. "[One Year of MCP: November 2025 Spec Release](https://blog.modelcontextprotocol.io/posts/2025-11-25-first-mcp-anniversary/)." Official MCP Blog. November 25, 2025. SEP-991 introduces CIMD; DCR demoted to MAY.

[^4]: Model Context Protocol. "[The 2026-07-28 Specification](https://blog.modelcontextprotocol.io/posts/2026-07-28/)." Official MCP Blog. July 28, 2026. DCR deprecation (PR #2858), SEP-837 rationale, quoted passages verbatim.

[^5]: Model Context Protocol. "[Authorization](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization)." Official MCP Specification, 2026-07-28 revision. Accessed October 20, 2026. CIMD SHOULD / DCR MAY; loopback redirect URIs; CIMD-00 in the standards list.

[^6]: Model Context Protocol. "[Key Changes in the 2026-07-28 Specification](https://modelcontextprotocol.io/specification/2026-07-28/changelog)." Official MCP Specification. July 28, 2026. Deprecation policy with minimum twelve-month window; SEP-2352 credential binding to issuers.

[^7]: J. Richer and M. Jones. "[OAuth 2.0 Dynamic Client Registration Protocol](https://www.rfc-editor.org/info/rfc7591)." RFC 7591. IETF. July 2015.

[^8]: A. Parecki and E. Smith. "[OAuth Client ID Metadata Document](https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/)." draft-ietf-oauth-client-id-metadata-document-02. IETF OAuth Working Group. Updated July 6, 2026.

[^9]: Model Context Protocol. "[Key Changes in the 2026-07-28 Specification](https://modelcontextprotocol.io/specification/2026-07-28/changelog)." Official MCP Specification. July 28, 2026. SEP-837: required `application_type` during DCR.

[^10]: Model Context Protocol. "[Client Registration](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/client-registration)." Official MCP Specification, 2026-07-28 revision. Accessed October 20, 2026. AS-side validation flow for URL client identifiers.

[^11]: A. Parecki and E. Smith. "[OAuth Client ID Metadata Document](https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/)." draft-ietf-oauth-client-id-metadata-document-02, §3. IETF OAuth Working Group. Updated July 6, 2026. Client Identifier URL rules and simple string comparison.

[^12]: A. Parecki and E. Smith. "[OAuth Client ID Metadata Document](https://datatracker.ietf.org/doc/draft-ietf-oauth-client-id-metadata-document/)." draft-ietf-oauth-client-id-metadata-document-02, §5. IETF OAuth Working Group. Updated July 6, 2026. Fetch and caching behavior.

[^13]: FastMCP. "[Remote OAuth](https://gofastmcp.com/servers/auth/remote-oauth.md)." FastMCP Documentation (v4.x). Accessed October 20, 2026. `RemoteAuthProvider` vs `OAuthProxy` decision table; client-side CIMD support and `fastmcp cli auth`.

[^14]: FastMCP. "[OAuth Proxy](https://gofastmcp.com/servers/auth/oauth-proxy.md)." FastMCP Documentation (v4.x). Accessed October 20, 2026. `OAuthProxy`, `GitHubProvider`, consent and storage options.

[^15]: FastMCP. "[Multiple Auth Sources](https://gofastmcp.com/servers/auth/multi-auth.md)." FastMCP Documentation (v4.x). Accessed October 20, 2026. `MultiAuth(server=..., verifiers=[...])` ordering semantics.

[^16]: Model Context Protocol. "[Enterprise-Managed Authorization](https://github.com/modelcontextprotocol/ext-auth/blob/main/specification/stable/enterprise-managed-authorization.mdx)." MCP Authorization Extensions (stable). Accessed October 20, 2026. EMA as an application of the IETF ID-JAG draft family (draft-ietf-oauth-identity-chaining-17 et al.).
