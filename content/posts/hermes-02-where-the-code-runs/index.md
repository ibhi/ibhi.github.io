---
title: "Hermes Agent Part 2 - Where the Code Actually Runs: Docker Isolation and What It Breaks"
description: "Move Hermes Agent's shell into a Docker container and your folders vanish. Why the mount table — not the container — decides what the agent can see, what the isolation costs you, and why the sandbox outlives the session on purpose."
summary: "A hands-on look at Hermes Agent's terminal backends: how one config key moves the whole shell into a hardened Docker container, why your files and credentials stop showing up, and what that isolation actually buys."
date: '2026-10-14'
tags: ["Hermes Agent", "AI Agents", "GenAI"]
series: ["Hermes Agent Series"]
series_order: 2
draft: false
showHero: false
---

{{< figure src="featured_hermes-02-where-the-code-runs.png" alt="Hand-drawn diagram: one agent loop feeding a configurable terminal backend, which fans out to local, docker, ssh and cloud sandboxes; the docker container drawn as a dashed boundary full of hardening labels." >}}

**TL;DR:** Part 1 said every tool call runs "behind a sandbox." This post opens the box — and walks into the wall. Moving Hermes from the `local` backend to `docker` doesn't break anything loudly; it just moves the shell, and leaves your files on the other side. We'll look at the mount table that decides what the agent can see, the hardening that makes the container a boundary, the credentials that don't come along by default, and why a container that outlives the session is the design.

If you haven't read [Part 1]({{< ref "/posts/hermes-01-intro-basics" >}}) yet, start there — the "one loop, many doors" mental model is the thing this post pulls a wall down inside.

## 1. The Prompt That Stopped Working

For months I ran Hermes on the default `local` backend, which is exactly what it sounds like: the agent's shell, file, and code tools run as me, on my machine. Convenient, and the reason all those safety rails exist. Then I did the sensible thing and moved it into a container.

The whole change was one key in `~/.hermes/config.yaml`:

```yaml
terminal:
  backend: docker
```

The same prompt I'd run a hundred times — *list the files in this folder and summarise them* — came back as a refusal: the terminal file backend is running in a Docker container "where that path is not mounted", with a helpful suggestion to copy the folder into the mounted workspace instead [^1]. The agent hadn't gotten dumber. I'd moved the shell, and left the folder on the other side of the wall.

That's the bruise this post is about. Nothing errored, nothing warned me, and the container did exactly what it was built to do — it couldn't see a path nobody had told it about. It cost me a confused half-hour and a background job that had been quietly writing into a directory the sandbox had never been given.

It's also completely predictable, once you've seen the mount table. So let's open the box.

## 2. One Switch, Many Homes

Every `terminal`, `execute_code`, and file-tool call in Hermes routes through a single configurable component: the **terminal backend** [^2]. The agent loop doesn't know where the code lands; you pick the environment. Flip one key and the same brain runs somewhere else entirely.

The docs list seven backends — `local`, `docker`, `ssh`, `singularity`, `modal`, `daytona`, and `vercel_sandbox` — and frame each by where the boundary sits [^2]. `local` is your machine with no isolation, and the only backend where the dangerous-command approval gate still fires. `ssh` makes the network the boundary. `singularity` is the HPC answer for clusters where Docker isn't welcome. `modal`, `daytona`, and `vercel_sandbox` push execution into a cloud VM or container you don't own.

{{< mermaid >}}
graph LR
    Loop((AIAgent loop)) --> TB[Terminal backend]
    TB --> Local[local<br/>no isolation]
    TB --> Docker[docker<br/>namespaces + cap-drop]
    TB --> SSH[ssh<br/>the network is the boundary]
    TB --> Cloud[modal / daytona / vercel_sandbox<br/>cloud VM or container]
    TB --> Sing[singularity<br/>containall]

    style Docker fill:#f96,stroke:#333,stroke-width:4px
{{< /mermaid >}}

For orientation before we zoom in: the full system view, with the terminal and cloud backends this post is about on the execution side of the core.

{{< figure src="images/hermes/hermes-agent-system.svg" alt="Architecture diagram of Hermes Agent: users reach one agent core either through direct surfaces (CLI, TUI, desktop app, web dashboard, IDE) or through the messaging gateway (Telegram, Discord, Slack and more, with the cron scheduler); the agent core runs the AIAgent loop and dispatches tool calls to terminal backends (local, Docker, SSH) and cloud backends (Daytona, Modal, Singularity); memory, skills and sessions live in ~/.hermes (MEMORY.md, state.db, curator); model calls fan out to hosted providers (Nous, OpenRouter, Anthropic, OpenAI, Google, xAI and more) or local and custom endpoints (Ollama, any OpenAI-compatible endpoint)." caption="The full architecture from Part 1 — this post zooms into the terminal and cloud backends on the right of the agent core." >}}

I'm not going to tour all seven. The one that matters for the rest of this post is `docker` — its boundary is the concrete, checkable one, and it's the one that broke my morning. Two framing notes: those names cover the terminal, file, and code path only — browser and web tooling run on their own backend sets [^3] — and everything past this point is the Docker backend.

## 3. Why Your Files Aren't In There

Here's the mental model that fixes everything: when you switch to Docker, **the tools that read and write your files move into the container with the shell**. The container starts from its own image plus exactly two host-backed directories. Everything else on your host is simply gone.

In persistent mode — the default — those two are:

| Inside the container | Comes from the host |
|---|---|
| `/root` | `~/.hermes/sandboxes/docker/<task-id>/home` |
| `/workspace` | `~/.hermes/sandboxes/docker/<task-id>/workspace` |

That's the whole list [^4]. And note where those host paths actually land: `~/.hermes/sandboxes/docker/<task-id>/…`, not `~/.hermes/sandboxes/default` — that path doesn't exist, because the backend tucks the task directory under a `docker/` subfolder even for the default task id [^4]. Not your home directory, not `~/projects`, not the repo you launched Hermes from. If you want a folder inside, you have to say so — and saying so means `docker_volumes`:

```yaml
terminal:
  backend: docker
  cwd: /workspace
  docker_volumes:
    - "/home/me/projects/api:/workspace/api:ro"   # read-only project
    - "/home/me/scratch:/workspace/scratch"       # writable scratch
```

Each entry is a plain `host:container[:ro]` string, handed to `docker run` as a `-v` argument [^4]. Two gotchas worth knowing before you file a bug. First, the sandbox home lands at `/root`, not `/home` — `/home` only exists as a 1 GB tmpfs in ephemeral mode, which trips up everyone carrying an older mental model [^4]. Second, mount changes are *not* retrofitted into a running container: the reuse fingerprint hashes the image and the mount arguments, so a new volume takes effect only in a fresh container [^4]. If you edited the config and nothing changed, that's why — delete the container, restart Hermes, and watch the folder appear.

## 4. The Container Is the Boundary

In `local` mode Hermes guards dangerous commands with an approval prompt. Run the same command inside `docker`, `singularity`, `modal`, `daytona`, or `vercel_sandbox` and that check is **skipped**, deliberately — the container is the boundary, not the prompt [^5].

That's a trade, not a gap: the safety you gave up at the prompt, you bought back at the namespace. The namespace isn't decorative: each container starts with every capability dropped and a few added back, plus hardening flags (`SETUID`/`SETGID` join only when the container drops root) [^5]:

| Flag | Why it's there |
|---|---|
| `--cap-drop ALL` | Start from zero, so nothing is inherited by accident — the standard hardening move [^6]. |
| add back `DAC_OVERRIDE`, `CHOWN`, `FOWNER` | Package managers have to `chown` files, and that mundanity is the point [^7]. |
| `--security-opt no-new-privileges` | No privilege escalation inside the container [^8]. |
| `--pids-limit 2048` | A ceiling that blunts fork bombs [^9]. |
| tmpfs `/tmp` 512 MB, `/var/tmp` 256 MB (`noexec`), `/run` | Scratch space is bounded and mostly non-executable [^9]. |

One escape hatch. `docker_extra_args` appends raw `docker run` flags **after** the hardening, so anything that conflicts with them silently weakens isolation — the docs' own warning [^5]. The last word on your container's security is the one you type yourself.

## 5. Credentials Don't Walk In By Themselves

Files weren't the only thing that stayed behind. So did my credentials. A skill that had been happily reading a Google token on `local` reported missing credentials the moment the shell moved into the container.

The reason is the same wall, with two doors through it. If the credential is an **environment variable**, name it in `docker_forward_env`, and Hermes resolves the value from your shell or `~/.hermes/.env` and injects it — the values travel in the Docker client's own environment, never on the world-readable command line [^5]. If the credential is a **file**, register it and Hermes bind-mounts it read-only:

```yaml
terminal:
  credential_files:
    - twilio_credentials.json    # mounted read-only at /root/.hermes/twilio_credentials.json
```

The read-only part is the design, not a limitation: the container can authenticate with the credential but can't rewrite your host credential state [^5]. And read the warning next to `docker_forward_env` before you tip your whole environment into it — those variables are injected on purpose, which means anything running in the container can read and exfiltrate them [^5]. A forwarded credential is a deliberate hole in the wall you just built.

## 6. A Container That Outlives the Agent

The last surprise is the one that bit hardest, because it looked like a bug and was a feature. Isolation would reset on every call if the container were disposable — but it isn't. By default Hermes keeps **one long-lived container per profile**, labels it (`hermes-agent=1`, `hermes-task-id`, `hermes-profile`), and a new process finds it by probing `docker ps` for those labels and attaching, rather than starting fresh [^4].

The consequence is strange the first time you notice it: on process exit, the documented cleanup is a **no-op**. That's the design — it's what lets a background job survive the session that started it, which is exactly why my earlier job kept writing into a directory the container had never been told about. Containers go away only when something asks: `docker_persist_across_processes: false`, an idle reaper (default five minutes), a startup sweep of orphans, or you [^4]. Set `container_persistent: false` and you get the opposite — one fresh container per session.

{{< mermaid >}}
stateDiagram-v2
    [*] --> Probe: new process starts
    Probe --> Attach: docker ps finds a labeled container
    Probe --> Create: none found
    Attach --> Running
    Create --> Running
    Running --> Running: process exit is a no-op
    Running --> Gone: docker_persist_across_processes false
    Running --> Gone: idle or orphan reaper sweeps it
    Running --> Gone: user removes it
    Gone --> [*]
{{< /mermaid >}}

## 7. What I'd Do Differently

If I were setting this up again, in order: pick the backend, then the mounts, then the credentials, then let the agent near anything real. The migration wasn't hard. It was just invisible until it wasn't — nothing broke loudly, the folder simply wasn't there, and the sandbox that couldn't see it was working exactly as designed.

We've covered the ground from five angles: 1. one switch moves the whole shell, 2. files appear only if you mount them, 3. the container — not the prompt — is the boundary, 4. credentials cross by name or by file, never by accident, and 5. the container outlives the agent on purpose. None of it is exotic; all of it is invisible until you hit it.

**What's Next:** Part 3 is the field report. Since writing this, I've moved the whole thing into production — rootless Podman behind a systemd user unit, a builder container that speaks the Docker API, and four cooperating agent profiles on top of it. Part 3 tells that deployment as it actually happened, everything that broke included. Same series, same loop — this time with receipts.

---

## References

[^1]: Wanderloots (Callum). "[Restricting Agentic AI? Full Docker Tutorial + Hermes Agent Workflow](https://www.youtube.com/watch?v=v_E42FkgH2I)." YouTube, 16:19.

[^2]: Nous Research. "[Tools & Toolsets](https://hermes-agent.nousresearch.com/docs/user-guide/features/tools)." Hermes Agent User Guide.

[^3]: Nous Research. "[Architecture](https://hermes-agent.nousresearch.com/docs/developer-guide/architecture)." Hermes Agent Developer Guide.

[^4]: Nous Research. "[Configuration](https://hermes-agent.nousresearch.com/docs/user-guide/configuration)." Hermes Agent User Guide, Docker Backend.

[^5]: Nous Research. "[Security](https://hermes-agent.nousresearch.com/docs/user-guide/security)." Hermes Agent User Guide.

[^6]: Aaron Grattafiori. "[Understanding and Hardening Linux Containers](https://www.nccgroup.com/research/understanding-and-hardening-linux-containers/)." NCC Group whitepaper.

[^7]: Michael Kerrisk. "[capabilities(7)](https://man7.org/linux/man-pages/man7/capabilities.7.html)." Linux man-pages project.

[^8]: OCI contributors. "[OCI Runtime Specification](https://github.com/opencontainers/runtime-spec/blob/main/config.md)." Open Container Initiative.

[^9]: Docker, Inc. "[docker container run](https://docs.docker.com/reference/cli/docker/container/run/)." Docker CLI reference.
