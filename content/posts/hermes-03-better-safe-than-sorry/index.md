---
title: "Hermes Agent Part 3 - Better Safe Than Sorry: From a Local Install to a Walled-Off Agent Fleet"
description: "I started Hermes as a plain local install and realised the agent could touch my whole host. This post is the migration that followed: rootless Podman, a rejected host socket, a builder sidecar playing Docker daemon, and a fleet of sandboxed profiles."
summary: "A security-first field report: from a scary local install, through rootless Podman and a rejected host socket, to a builder sidecar and a fleet of sandboxed agent profiles. Better safe than sorry."
date: '2026-10-15'
tags: ["Hermes Agent", "AI Agents", "GenAI"]
series: ["Hermes Agent Series"]
series_order: 3
draft: true
showHero: false
---

<!-- TODO figure: featured_hermes-03-better-safe-than-sorry.png (2816x1536, hand-drawn).
     Suggested: a laptop with walls being built around it in three stages — the agent
     loop loose on the desk, then boxed into a gateway container, then its tools
     sandboxed inside a larger builder box; the host's daemon socket drawn as a locked
     door with a "never expose" scrawl; four small agent loops sharing the builder.
     Alt text: "Hand-drawn diagram: an agent moved in three stages from loose on a host,
     into a rootless gateway container, into sandboxes inside a builder container — with
     the host socket drawn locked." -->

**TL;DR:** Part 2 told the move to the Docker backend as one clean config change. This post is the road that led there. I started with a plain local install of Hermes, realised how much of my host the agent could touch, and built walls in stages: Hermes itself into rootless Podman, execution into a builder sidecar that plays Docker daemon without ever exposing my host socket, and finally a fleet of profiles whose sandboxes all land inside that one builder. The theme fits in one sentence: the agent should not be able to touch my host.

If you haven't read [Part 2]({{< ref "/posts/hermes-02-where-the-code-runs" >}}) yet, start there — the mount table, the hardening flags, and the credentials model are the nuances this post keeps bumping into.

## 1. The Agent That Could Delete Anything

I started the way everyone starts: a local install on my Linux machine, and a lot of just playing with it — asking it things, watching what it does with a shell, learning what it actually is. Part 1's mental model, verified by hand.

The fun stopped the day I priced the risk. On the `local` backend, Hermes' terminal, file, and code tools run as me — so the agent can read and delete anything I can, which is everything I care about. Hermes is more conservative than most agents here: Part 2 covered the approval gate that fires on dangerous commands in local mode. But gates are prompts, and prompts fail. The stories you hear are not hypothetical. In July 2025, a Replit agent — held in a code freeze and told to stop changing things — dropped a company's entire production database anyway, and the engine's own post-mortem called it a "catastrophic error in judgment" [^1]. That agent lived inside a fenced app platform. Mine had a shell on my laptop.

So, worst case, if mine goes stupid? Everything. That's not a reason to stop using agents. It's a reason to build more walls.

## 2. Wall One: Hermes Itself in Rootless Podman

The first wall was obvious: stop running Hermes on the host. The stack — the agent, in one container — now runs as a rootless Podman compose project, started by a systemd user unit so it survives reboots without a login session. Rootless matters more than the container part: the containers execute as my user, and container root maps to an unprivileged subuid, not real root [^2]. If the agent escapes the app, it lands in a box that cannot even mount a filesystem.

{{% alert "note" %}}
One bottleneck is worth the telling, because the error message points everywhere except at the cause. Rootless Podman's `keep-id` userns writes my host user into the container's `/etc/passwd` — and the Hermes image's own startup then fails `usermod -u 1000 hermes` with "UID '1000' already exists", leaving the agent under the wrong uid, unable to read its own volume. The fix is a small s6 cont-init script that sorts before the image's setup and deletes the injected entries:
{{% /alert %}}

```yaml
# sorts before 01-hermes-setup, clearing the keep-id collision first
- ./docker/00-fix-keep-id-uid:/etc/cont-init.d/00-fix-keep-id-uid:ro
```

Two reasonable systems disagreeing about who owns uid 1000.

And that is where I noticed the next problem. The gateway container was now the agent's whole world — and its shell still ran `local`, so execution happened inside that same container: every scratch script, every `pip install`, every downloaded tool landed in the very environment Hermes itself lives in.

## 3. The Pollution Problem

Watch an agent work for a week and you will see what it leaves behind: scratch scripts, downloaded tools, `pip install` leftovers, a Chromium here, a vendored repo there. On a laptop you notice eventually and clean up. In a container you notice because the writable layer grows — every dependency the agents installed lives in the same environment Hermes itself runs in. A restart resets the ephemeral storage, sure. It also wipes every tool the agents installed, so the install-and-evaporate cycle just repeats.

That is hygiene, not security. But it pushed me to look for proper separation: execution somewhere else entirely. The nudge came from a YouTube video by Wanderloots — highly recommended if you are into knowledge management and agentic tooling — walking through exactly this: pointing Hermes' terminal backend at Docker, so code execution lands in sandbox containers [^3]. His setup makes sense for him: Hermes runs directly on his Mac, and Docker handles the dangerous parts. Mine was the mirror image. Hermes already lived in a container. What I did not have was a daemon.

## 4. The Road Not Taken: My Own Socket

The obvious answer took thirty seconds to find and thirty more to reject. Podman *can* put a Docker-compatible socket on my host — mount it into the Hermes container, point `DOCKER_HOST` at it, and the docker backend works, sandboxes spawning on my host runtime. But Podman is daemonless by design, and out of the box there is nothing to mount: no daemon, no socket, no API process. The systemd units (`podman.socket`, `podman.service`) ship with the package and sit disabled until I run `systemctl --user enable --now podman.socket` myself. The shortcut was real — it just had to be built first. Which is exactly why rejecting it is a decision, not an oversight: Docker hands you the hole pre-opened; Podman makes you drill it.

That is the trap. A container daemon's socket is the keys to the host: whoever controls it can bind-mount the host filesystem into a container "without any restriction", to quote Docker's own attack-surface documentation — which is why they say only trusted users should control the daemon [^4]. An autonomous agent is many things; "a trusted user" is not one of them. Exposing the socket would have rebuilt the exact hole I had just walled off, with a door labelled root.

Call it paranoid if you like. I call it better safe than sorry: the agent's reach should be exactly the reach of its tools, and its tools should not include my host's container runtime.

## 5. The Builder: Docker-in-Docker, Podman Edition

The answer: give the stack its own daemon — a second container from the Podman image, speaking the Docker API over the compose network. Here is the whole compose file, sanitized:

```yaml
# ─────────────────────────────────────────────────────────────────────────────
# Hermes Agent — personal assistant. ROOTLESS PODMAN + podman-compose 1.0.6.
#
# Stays within podman-compose 1.0.6 capabilities:
#   • no deploy / depends_on / version key / named volumes
#   • `userns_mode` (docker-style key) is the supported spelling → --userns
#
# The image MUST start as container root (s6-overlay PID 1 + stage2 PUID
# remap hook; `--user ≠ 0` starts are rejected by design). With keep-id +
# PUID 1000 the in-container `hermes` user is uid 1000 == your host user, so
# ~/.hermes stays owned by your host user. Container root maps to a host
# subuid (isolated), never to real host root.
#
# Secrets (GLM / Telegram / Slack keys) live in ~/.hermes/.env — mounted at
# /opt/data/.env and read by hermes itself. Do NOT add keys here: compose
# `environment:` would override the volume .env.
#
# Networking: the gateway itself stays outbound-only (Telegram long-poll,
# Slack Socket Mode websockets) with NO published ports. The web dashboard
# (:9119) and API server (:8642) are reached by the `traefik` service below
# over the shared compose network and published to the LAN as
# https://hermes[.api].<your domain>:9443 (ufw-gated to RFC1918).
# ─────────────────────────────────────────────────────────────────────────────

services:
  gateway:
    image: docker.io/nousresearch/hermes-agent:latest
    container_name: hermes
    restart: unless-stopped
    hostname: hermes
    # s6-overlay must run as container root; it drops to PUID/PGID itself.
    user: "0:0"
    userns_mode: keep-id
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - NET_ADMIN
      - NET_RAW
      - SYS_TIME
      - SYS_MODULE
    command: ["gateway", "run"]
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: "${TZ}"
      # Enables the s6-supervised dashboard service (:9119). The s6 run
      # script reads the CONTAINER env (with-contenv) — NOT the volume
      # ~/.hermes/.env — so this flag must live HERE. Auth credentials and
      # API-server settings still live in ~/.hermes/.env.
      HERMES_DASHBOARD: "1"
      # File-tool write allowlist (colon-separated; the image default is
      # /opt/data only). Extends it with the two bind-mounted shared dirs so
      # agents' write_file can reach them — terminal/execute_code already see
      # them inside sandbox containers via terminal.docker_volumes.
      HERMES_WRITE_SAFE_ROOT: "/opt/data:/obsidian-vault:/shared-workspace:/workspace"
    volumes:
      - "${HERMES_DATA_DIR}:/opt/data"
      # Shared multi-agent workspace. Same host dir as the builder's
      # /shared-workspace mount; mounted at the SAME canonical path so file
      # tools and sandbox containers address it identically.
      - "${HERMES_DATA_DIR}/shared-workspace:/shared-workspace"
      # Notes vault (synced on the host). Owner maps to the in-container
      # hermes user under keep-id, so the agent reads and writes notes as
      # your own user — edits sync out normally.
      # Add ":ro" if the agent should only ever read notes.
      - /home/<you>/syncthing/Notes:/obsidian-vault
      # Rootless keep-id fix: podman injects the host user (uid/gid 1000)
      # into /etc/passwd, which breaks the image's `usermod -u 1000 hermes`
      # remap. This s6 cont-init script (sorts before 01-hermes-setup)
      # removes the collision.
      - ./docker/00-fix-keep-id-uid:/etc/cont-init.d/00-fix-keep-id-uid:ro
    networks:
      - default

  # ── Execution sandbox (podman-in-podman, reshaped DinD) ──────────────────
  # Runs a private podman daemon exposing a Docker-compatible API on the
  # compose network. Hermes (terminal.backend: docker, DOCKER_HOST in
  # ~/.hermes/.env) spawns its sandbox containers here, so all
  # commands/scripts/dependencies live in nested containers — never in the
  # gateway container.
  #
  # Security: the builder's mounts ARE the boundary — inner containers can
  # only bind-mount what the builder sees (notes vault, shared workspace).
  # ~/.hermes secrets are deliberately NOT mounted here, and the host podman
  # socket is never exposed. privileged is required for the nested runtime;
  # rootless-privileged cannot exceed host-user powers.
  #
  # DEFAULT userns on purpose (container root == your host user): files
  # written through inner bind-mounts stay owned by your host user. Do NOT
  # copy the cap_drop/no-new-privileges hardening here — the nested runtime
  # needs those privileges.
  #
  # builder-storage/ holds the inner image store and survives recreations —
  # deleting it resets the sandbox (needs `chmod -R u+w` first: overlay diff
  # dirs are mode 0555).
  builder:
    image: quay.io/podman/stable:latest
    container_name: hermes-builder
    restart: unless-stopped
    privileged: true
    # PID 1 is catatonit (reaps orphans, forwards signals) wrapping a shell
    # loop that restarts the API service every 6h — section 7 tells that story.
    command:
      - /usr/libexec/catatonit/catatonit
      - --
      - sh
      - -c
      - |
        trap 'exit 0' TERM INT
        while :; do
          timeout 6h podman system service --time=0 tcp://0.0.0.0:2375 &
          wait $!
          sleep 2 &
          wait $!
        done
    volumes:
      - ./builder-storage:/var/lib/containers
      - ./builder-config/containers.conf:/etc/containers/containers.conf:ro
      - /home/<you>/syncthing/Notes:/obsidian-vault
      # Read-only: the sandbox only bind-mounts selective folders from here,
      # which is what keeps the secrets unreachable from inner containers.
      - ${HERMES_DATA_DIR}:/opt/data:ro
      # Shared workspace, read-write, for the multi-agent setup.
      - ${HERMES_DATA_DIR}/shared-workspace:/shared-workspace
    networks:
      - default

  # Dedicated LAN-only reverse proxy. TLS via Let's Encrypt DNS-01
  # (Cloudflare) — needs the CF_DNS_API_TOKEN + DOMAIN from .env; the
  # wildcard *.<your domain> cert covers both router hostnames.
  traefik:
    image: docker.io/library/traefik:v3
    container_name: hermes-traefik
    restart: unless-stopped
    user: "1000:1000"
    userns_mode: keep-id
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - NET_ADMIN
      - NET_RAW
      - SYS_TIME
      - SYS_MODULE
    ports:
      - "9443:9443"            # LAN-only HTTPS; ufw-gate to RFC1918
    environment:
      CF_DNS_API_TOKEN: "${CF_DNS_API_TOKEN}"
      DOMAIN: "${DOMAIN}"      # consumed by Go templates in traefik/dynamic/*
    volumes:
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
      - ./traefik/acme:/etc/traefik/acme
    networks:
      - default

# Pinned subnet so the rootless stack keeps a fixed address range. If
# podman-compose ever rejects the ipam block, delete it and read the
# assigned subnet with:
#   podman network inspect hermes-agent_default
networks:
  default:
    ipam:
      config:
        - subnet: "${PODMAN_NETWORK_SUBNET}"
```

(The builder's odd `command:` — a catatonit init and a six-hour retirement loop — gets its story in section 7.)

`podman system service` exposes a Docker-compatible API [^5], so from Hermes' point of view this is just Docker — one environment variable, the only wire in the whole design:

```bash
# ~/.hermes/.env
DOCKER_HOST=tcp://hermes-builder:2375
```

{{< mermaid >}}
graph LR
    Me[me on Telegram and Slack] --> GW
    subgraph Host["my host - rootless podman"]
        GW[gateway<br/>hermes itself]
        B[builder<br/>podman system service]
        GW -->|DOCKER_HOST| B
        B --> S1[sandbox]
        B --> S2[sandbox]
    end
    LOCKED[the host socket - never exposed]

    style B fill:#f96,stroke:#333,stroke-width:4px
{{< /mermaid >}}

With that, the sandboxes from Part 2 — the hardened, cap-dropped work containers — spawn inside the builder, as nested containers. Docker-in-Docker, podman edition. `privileged: true` is the caveat you are expecting: nesting a runtime needs real privileges, though under rootless Podman "privileged" still cannot exceed my host user's powers [^2].

And that mount list is doing two jobs. It is the trust boundary — an inner container can only bind-mount what the builder can see, so the host socket and the secrets stay out by construction. It is also a ceiling: anything a sandbox needs must be mounted into the builder first. Three separate host dirs ride in, and the distinction matters: all of `~/.hermes` goes in read-only, so sandboxes can bind-mount selective pieces of it; the notes vault is its own host directory entirely (`~/syncthing/Notes` — nothing to do with `~/.hermes`); and the shared workspace, the orchestration surface, is a third mount again. Host, builder, sandbox: a path you want visible at the bottom of the nest needs a mount at every level above it.

One more gotcha: the Podman image ships `ipcns="host"`, and under podman 5.x that makes Hermes' `--shm-size` flag fail on every sandbox start. One line in `containers.conf` fixes it [^6]:

```ini
[containers]
netns="host"     # inner containers share the builder's bridge, no nested NAT
userns="host"    # bind-mount files stay owned by my host user
ipcns="private"  # the fix — note the spelling: ipc_ns is silently ignored
cgroups="disabled"
```

From here, Part 2's nuances apply verbatim: the sandboxes mount what Hermes tells them to mount (`docker_volumes`), credentials cross only by name or by file, and the container outlives the session on purpose. That post is the manual for this one.

## 6. Scaling to a Fleet

With execution walled off, scaling to more agents stopped being a security question and became a configuration one. Hermes runs any number of **profiles** — I run four — and each is a self-contained mini home: its own `config.yaml`, its own `.env`, its own `SOUL.md` persona, its own skills, plugins, and memory, even its own Slack identity. Each runs the docker backend, and each points at the same `DOCKER_HOST`.

{{< mermaid >}}
graph TB
    ORC[orchestrator profile] --> B
    RES[researcher profile] --> B
    LIB[librarian profile] --> B
    WRI[writer profile] --> B
    B[the builder] --> S[sandboxes - all of them]
    S --> SW[/shared-workspace/]

    style B fill:#f96,stroke:#333,stroke-width:4px
{{< /mermaid >}}

All sandboxes from all agents stay inside the one builder: four agents, one boundary, one store to audit. The gotcha here, so you do not lose a day like I did: profiles are environment islands. My `DOCKER_HOST` line lived only in the default profile's `.env`, and Hermes scrubs a launch profile's environment from the sub-agents it spawns — so my kanban workers probed for a Docker daemon that, as far as they could see, did not exist, and quietly dropped the `terminal` and `file` tools. No error, no log line. The line belongs in every profile's own `.env`.

Coordination is deliberately boring: one shared workspace, bind-mounted at the same canonical path into every sandbox, and a kanban board the orchestrator profile drives. The agents share a workplace, not a brain.

## 7. The Leak in the Wall: Zombies in the Builder

The wall held — until this morning, when every `podman` command inside the builder came back with `pthread_create failed: Resource temporarily unavailable`. The builder had wedged, and the cause was a rude surprise: `podman system service` had been running as the container's PID 1, and reaping orphans is PID 1's job — a job nothing had told it to do. Every sandbox lifecycle through the API leaves a couple of dead children behind (conmon and the fuse-overlayfs helper), parented to a PID 1 that never waits. At my sandbox churn that measured about a hundred and forty zombies an hour, and rootless Podman stamps a default PID ceiling of 2,048 on every container — which the horde reached, roughly fourteen hours after each restart.

The fix, in the end, is a timer — just not where I expected to put one. Make a real init the PID 1, and give the service a retirement age:

```yaml
command:
  - /usr/libexec/catatonit/catatonit   # a tiny init — it reaps
  - --
  - sh
  - -c
  - |
    trap 'exit 0' TERM INT
    while :; do
      timeout 6h podman system service --time=0 tcp://0.0.0.0:2375 &
      wait $!
    done
```

Every six hours the loop restarts the service, and the accumulated zombies are orphaned to catatonit, which reaps them instantly. Running sandboxes survive the restart — only in-flight API calls notice, for about two seconds.

## 8. The Caveats, and What's Next

Two more costs, alongside the zombies. First, stack updates and stop/start cycles remove the sandbox containers with the builder — and Hermes spins a sandbox only when terminal or code execution needs one, so the first command after a restart pays the cold start: container create, then your shell. Bind-mounting the inner image store, `./builder-storage:/var/lib/containers`, at least keeps the images — without it, every recreation re-pulls the sandbox image, a gigabyte at a time. Second, `privileged` in the builder is a real word with real meaning — rootless bounds it, but you should stay uncomfortable anyway.

The recap, in order: 1. a local install is a trust decision, not a default; 2. containerise the agent itself, rootlessly; 3. execution pollution is its own problem; 4. never hand an agent your host daemon socket; 5. give the stack its own daemon — a builder sidecar whose mounts are both boundary and ceiling; 6. scale with profiles that all land in the one builder; 7. give the nested runtime an init that reaps.

One honest caveat, in the house idiom: this is my working tree on one machine — configs drift, and nothing here was audited by anyone but me. Treat it as *reported*, not audited.

**What's Next:** Something interesting is brewing out of all this — not ready to talk about it yet. Hermes will be back — same series, same loop — once the next thing breaks.

---

## References

[^1]: Mark Tyson. "[AI coding platform goes rogue during code freeze and deletes entire company database](https://www.tomshardware.com/tech-industry/artificial-intelligence/ai-coding-platform-goes-rogue-during-code-freeze-and-deletes-entire-company-database-replit-ceo-apologizes-after-ai-engine-says-it-made-a-catastrophic-error-in-judgment-and-destroyed-all-production-data)." Tom's Hardware, 21 July 2025.

[^2]: Podman contributors. "[Basic Setup and Use of Podman in a Rootless Environment](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)." Podman tutorials.

[^3]: Wanderloots (Callum). "[Restricting Agentic AI? Full Docker Tutorial + Hermes Agent Workflow](https://www.youtube.com/watch?v=v_E42FkgH2I)." YouTube.

[^4]: Docker, Inc. "[Docker Engine security](https://docs.docker.com/engine/security/)." Docker documentation, daemon attack surface.

[^5]: Podman contributors. "[podman-system-service — Run an API service](https://docs.podman.io/en/latest/markdown/podman-system-service.1.html)." Podman documentation.

[^6]: containers/common contributors. "[containers.conf(5)](https://github.com/containers/common/blob/main/docs/containers.conf.5.md)." containers-common reference.
