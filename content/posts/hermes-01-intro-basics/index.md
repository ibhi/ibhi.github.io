---
title: "Hermes Agent Part 1 - Not a Copilot, Not a Chatbot: A Mental Model"
description: "What is Hermes Agent? A concepts-first mental model of Nous Research's open-source autonomous agent: one agent loop behind many entry points, a persistent messaging gateway, curated memory and skills, sandboxed execution, and built-in cron."
date: 2026-10-13
summary: "A concepts-first mental model of Hermes Agent: one agent loop behind many entry points, a persistent gateway, curated memory and skills forming a closed learning loop, sandboxed execution, and built-in cron."
tags: ["Hermes Agent", "AI Agents", "GenAI"]
series: ["Hermes Agent Series"]
series_order: 1
draft: false
showHero: false
---

{{< figure src="featured_hermes-01-intro-basics.png" alt="Hand-drawn whiteboard overview of Hermes Agent: gateway, memory, skills, sandbox, connectors and cron clouds around a central learning loop — runs on your machine, self-hosted." >}}

**TL;DR:** Hermes Agent is Nous Research's open-source (MIT), provider-agnostic autonomous agent. This is a concepts post, not a setup guide. By the end you should hold a working mental model: one agent loop behind many entry points, a persistent gateway for messaging, curated memory and skills forming a closed learning loop, sandboxed execution, and built-in cron.

## 1. What It Is — and What It Isn't

The docs draw the line themselves: Hermes is "not a coding copilot tethered to an IDE or a chatbot wrapper around a single API" [^1]. It sits in the same category as tool-calling task agents, but with two differences worth caring about.

First, it is provider-agnostic. The same agent core can run on a bundled portal, an OpenAI-compatible endpoint, or models from Anthropic, Google, xAI, and friends — including local models. You are not marrying a model vendor [^2].

Second, it is meant to *live* somewhere. Not inside your editor, but on a cheap VPS, a GPU box, or a serverless platform — wherever it can run unattended and stay reachable. The tagline the docs use is "the agent that grows with you," and the growth part is the interesting bit, as we'll see.

## 2. One Loop, Many Doors

Here is the single most useful idea for understanding the whole system: there is exactly **one agent loop**, and everything else is a door into it.

The core is a component the architecture docs call the `AIAgent`. One pass of the loop does three things: build the prompt (system instructions, your memory, the conversation so far), resolve the model provider, and dispatch tool calls when the model asks for one. That's the entire engine [^3].

Then the doors:

{{< mermaid >}}
graph TD
    subgraph Doors
        CLI[CLI]
        TUI[Terminal UI]
        Desktop[Desktop app]
        Web[Web dashboard]
        GW[Messaging gateway]
        API[API / library]
    end

    Doors --> Loop((AIAgent loop))

    Loop --> Tools[Tool registry]
    Loop --> Mem[Memory + skills]

    Tools --> Sandbox[Sandboxed execution]

    style Loop fill:#f96,stroke:#333,stroke-width:4px
{{< /mermaid >}}

You can enter through a plain CLI, a terminal UI, a desktop app, a web dashboard, an OpenAI-compatible API endpoint, or the Python library. The loop doesn't know or care which one you used — same brain, different door. Sessions persist in SQLite with full-text search, so a conversation can outlive the window it started in.

{{< figure src="fig-1-one-loop-many-doors.png" alt="Hand-drawn diagram: six entry points (CLI, terminal UI, API/library, desktop app, web dashboard, messaging gateway) with arrows converging on one AIAgent loop circle." >}}

## 3. The Gateway: An Agent With a Phone Number

The most unusual door is the **gateway**: a single persistent background process that connects Hermes to messaging platforms — Telegram, Discord, Slack, WhatsApp, Signal, SMS, email, Matrix, LINE, and more. You talk to your agent where you already talk to people, and it answers in the same thread [^6].

Because the gateway is always on, the agent stops being something you *open* and becomes something you *message*. That shift sounds cosmetic until you combine it with the next two sections: an always-reachable agent that remembers things and runs on a schedule starts to behave less like a tool and more like a colleague.

{{< figure src="fig-2-gateway.png" alt="Hand-drawn diagram: you message the gateway, which stays always on, spawns agent sessions into a sandbox, and answers in the same thread on Telegram, Discord, Slack and more." >}}

## 4. Memory + Skills: A Closed Learning Loop

This is the part the project is proudest of. The README calls Hermes "the only agent with a built-in learning loop" [^2] — a vendor superlative, and rivals have their own takes on memory. But what's genuinely distinctive here is that the loop is **closed and curated by default**. Nothing about it depends on you remembering to maintain it.

**Memory** is two small, hand-sized files: one of curated facts about your world, one a profile of you. They are injected into the system prompt as a frozen snapshot at session start — which keeps the prompt prefix stable and cache-friendly — and here's the twist: *the agent edits them itself* via its memory tool. When the files hit their size cap, further writes are refused, which forces consolidation instead of endless accumulation. A periodic nudge prompts the same tidying. Memory is bounded by design, not a vector database that grows forever [^4].

**Skills** are the procedural half: on-demand knowledge documents that live in a skills directory. Their names and descriptions are always visible to the model, but the body is only loaded when relevant — progressive disclosure, so a fat skill library doesn't eat your context. The agent can author new skills from its own experience and improve existing ones while using them, and a background curator keeps the library maintained. Skills follow an open agent-skills standard, so they're portable and shareable [^5].

Facts and procedures, curated across sessions — that's the loop. (There's also an optional third-party plugin for user modeling; it's a plugin, not built-in.)

{{< figure src="fig-3-memory-skills.png" alt="Hand-drawn diagram: memory (facts and a user profile frozen into the system prompt, edited by the agent itself, capped) and skills (loaded on demand, self-authored, portable) connected by a closed curation loop." >}}

## 5. Sandboxed Execution: The Loop Needs Hands

An agent that can only talk is a chatbot. Hermes closes the gap with a terminal abstraction: every terminal, file, and code-execution call is routed through a configurable backend — a plain local shell, a persistent Docker container, an SSH remote, a Singularity container, or a serverless sandbox on Daytona, Modal, or Vercel Sandbox — seven backends spanning a laptop to the cloud [^3]. The same prompt-driven loop ends with real execution, in an environment you chose.

Security is layered, defense-in-depth, and the security docs enumerate eight layers: user authorization with allowlists and DM pairing, approval gates for dangerous commands (denied by default in unattended contexts), file-write safety, container isolation, credential filtering, prompt-injection scanning of context files, cross-session isolation, and input sanitization. The design assumption is that your agent *will* eventually meet a malicious webpage or a poisoned document — the layers exist so that's an incident, not a breach [^7].

{{< figure src="fig-4-sandbox.png" alt="Hand-drawn diagram: the agent loop calling into a sandbox boundary holding seven backends — local shell, Docker, SSH remote, Singularity, Daytona, Modal, Vercel Sandbox." >}}

## 6. Cron: The Loop That Runs While You Sleep

Because the gateway never sleeps, Hermes ships a scheduler. You create jobs in natural language — "every weekday at seven, summarize my repos and message me" — and when a job comes due, the system starts a *fresh* agent session, optionally injecting a skill written for exactly that task, runs the prompt to completion, and delivers the result to any connected platform, including a fan-out to all of them at once. Jobs can even chain, pulling context from earlier runs [^8].

This is where the mental model clicks: one loop, entered through messaging, equipped with curated memory and skills, running behind a sandbox, on a schedule. Each piece is modest. Stacked, they describe something you don't currently have.

{{< figure src="fig-5-cron.png" alt="Hand-drawn diagram: a clock at 07:00 fires a cron job, which starts a fresh agent session with an injected skill, delivers the result to your messaging platforms, and later jobs can chain context from earlier runs." >}}

{{< figure src="images/hermes/hermes-agent-system.svg" alt="Architecture diagram of Hermes Agent: users reach one agent core either through direct surfaces (CLI, TUI, desktop app, web dashboard, IDE) or through the messaging gateway (Telegram, Discord, Slack and more, with the cron scheduler); the agent core runs the AIAgent loop and dispatches tool calls to terminal backends (local, Docker, SSH) and cloud backends (Daytona, Modal, Singularity); memory, skills and sessions live in ~/.hermes (MEMORY.md, state.db, curator); model calls fan out to hosted providers (Nous, OpenRouter, Anthropic, OpenAI, Google, xAI and more) or local and custom endpoints (Ollama, any OpenAI-compatible endpoint)." caption="The whole system on one page — one agent core, reached through direct surfaces or the messaging gateway, executing via terminal and cloud backends, with memory, skills and sessions in `~/.hermes` and model calls fanning out to hosted or local providers." >}}

## 7. What's Next

One honest caveat for this whole series: everything above is drawn from Hermes' own documentation and repository — it's what the project documents itself to be, not an independent review. Part 2 opens the box: where the code actually runs, and what keeps it off your host — a close look at the terminal backends and the Docker container that acts as the isolation boundary. Stay tuned.

---

## References

[^1]: Nous Research. "[What is Hermes Agent?](https://hermes-agent.nousresearch.com/docs)." Official documentation, landing page.

[^2]: Nous Research. "[hermes-agent](https://github.com/NousResearch/hermes-agent)." GitHub repository, README.

[^3]: Nous Research. "[Architecture](https://hermes-agent.nousresearch.com/docs/developer-guide/architecture)." Hermes Agent Developer Guide.

[^4]: Nous Research. "[Memory](https://hermes-agent.nousresearch.com/docs/user-guide/features/memory)." Hermes Agent User Guide.

[^5]: Nous Research. "[Skills](https://hermes-agent.nousresearch.com/docs/user-guide/features/skills)." Hermes Agent User Guide.

[^6]: Nous Research. "[Messaging platforms](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)." Hermes Agent User Guide.

[^7]: Nous Research. "[Security](https://hermes-agent.nousresearch.com/docs/user-guide/security)." Hermes Agent User Guide.

[^8]: Nous Research. "[Cron](https://hermes-agent.nousresearch.com/docs/user-guide/features/cron)." Hermes Agent User Guide.
