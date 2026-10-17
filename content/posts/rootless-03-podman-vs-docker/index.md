---
title: "Rootless Containers Part 3 - Three Ways to Trust a Daemon: Podman Rootless vs Docker Rootless vs Docker Rootful"
description: "Docker rootful, Docker rootless, Podman rootless — the daemon trust axis, the kernel primitives both rootless stacks share, a full comparison table, and an honest look at what rootless does not protect against."
date: '2026-10-18'
summary: "The three-way comparison: privileged daemon, de-privileged daemon, no daemon — the kernel primitives both rootless stacks converge on, six misconception corrections, and what rootless containers do not protect against."
tags: ["Podman", "Containers", "Linux"]
series: ["Rootless Containers Series"]
series_order: 3
draft: true
showHero: false
---

{{< figure src="featured_rootless-03-podman-vs-docker.png" alt="Hand-drawn diagram: three boxes on a privilege axis — Docker rootful with a root daemon where bugs land as host root, Docker rootless with an unprivileged daemon in a user namespace, and Podman rootless with no daemon at all — under an arrow labelled privilege held by the management plane." >}}

**TL;DR:** Parts 1 and 2 built the machinery and walked Podman's implementation. This post puts the three real-world configurations on one axis — Docker rootful, Docker rootless, Podman rootless — and judges them on what actually differs: how much privilege the management plane holds, what a container escape buys an attacker, and which rough edges are vendor choices versus kernel law. The punchline, gently spoiled: the rootless halves of the two ecosystems have converged on the same kernel contract, and the UX gaps you'll curse are the kernel's, not theirs.

This post is part of a series. [Part 1]({{< ref "/posts/rootless-01-namespaces" >}}) builds the namespace machinery and [Part 2]({{< ref "/posts/rootless-02-podman-deep-dive" >}}) walks Podman's rootless internals — this one assumes both.

## 1. The Daemon Trust Axis

Strip the features away and the three configurations differ on exactly one axis: **how much privilege does the management plane hold?**

{{< mermaid >}}
graph TD
    A[docker CLI] --> B[dockerd as root - rootful]
    A2[docker CLI] --> B2[dockerd unprivileged in a user namespace - rootless]
    A3[podman command] --> C3[conmon + container - no daemon]
    B --> D[containers]
    B2 --> D2[containers]
    style B fill:#f96,stroke:#333,stroke-width:4px
    style B2 fill:#f96,stroke:#333,stroke-width:4px
{{< /mermaid >}}

Docker rootful concentrates privilege in one long-lived root daemon. Docker rootless keeps the daemon but de-privileges it. Podman removes the daemon from the trust equation entirely — and all three converge on the same OCI runtime layer for the kernel work [^1][^2][^5]. That's the whole comparison. Everything below is consequence.

## 2. Docker Rootful: The Privileged Middleman

Docker's architecture is client-server: the `docker` CLI talks to `dockerd`, "which does the heavy lifting of building, running, and distributing your Docker containers," over a REST API on a UNIX socket or network interface — and Compose is just another client of the same API [^1]. The daemon "listens for Docker API requests and manages Docker objects such as images, containers, networks, and volumes" [^1].

Three properties of that design shape everything downstream. The daemon is the *single owner of state* — if it dies, the management plane goes with it. It is the *API surface* — whoever controls the socket controls root-level container management on the host. And in rootful mode it *runs as root* — which is precisely the attack surface rootless mode was built to shrink: Docker's docs say rootless mode exists "to mitigate potential vulnerabilities in the daemon and the container runtime" [^2]. Read that sentence again — it's Docker's own admission that the daemon is part of the threat model.

## 3. Docker Rootless: The Same Daemon, De-Privileged

Rootless mode "executes the Docker daemon and containers inside a user namespace" — and the docs are careful to distinguish it from the older `userns-remap`, where the daemon *still runs as root* and only container UIDs are remapped; in rootless mode, "both the daemon and the container are running without root privileges" [^2]. The engine doing the wrapping is RootlessKit — "Linux-native fakeroot using user namespaces" — whose stated purpose is to protect "the real root on the host from potential container-breakout attacks" [^4].

RootlessKit's README includes a demonstration worth stealing. Inside `rootlesskit bash`, your UID shows as 0 — but it is not the real root: `/etc/shadow` appears owned by `nobody:nogroup` and is unreadable [^4]. That's Part 1's uid_map made flesh: full "root" inside, an ordinary user outside.

Setup mirrors Part 2's: the `uidmap` package providing `newuidmap`/`newgidmap`, and at least 65,536 subordinate IDs in `/etc/subuid`/`/etc/subgid` [^2]. Then `dockerd-rootless-setuptool.sh install`, run as the non-root user, creates `~/.config/systemd/user/docker.service` — the daemon runs under *your* systemd instance — needs `sudo loginctl enable-linger` to survive logout, and registers a CLI context that points `DOCKER_HOST` at `unix:///run/user/<uid>/docker.sock` [^2]. `docker info` then lists `rootless` among the security options [^2]. The data directory lands under your home as well — `~/.local/share/docker` per the official tips page [^3].

## 4. Two Engines, One Kernel Contract

Line up the prerequisites and the overlap is exact: same subuid/subgid lines, same `newuidmap`/`newgidmap` helpers, user namespaces doing the same mapping, cgroup v2 delegation through the same `systemd --user`, userspace networking of the slirp/pasta family [^2][^4][^6]. These are siblings built on the same kernel primitives — the ecosystems converged on the kernel contract, independently.

{{< figure src="fig-1-shared-primitives.png" alt="Hand-drawn diagram: Podman rootless and Docker rootless both pointing into one dashed box of shared kernel primitives — user namespaces with a written-once uid_map, subuid and subgid ranges with newuidmap and newgidmap, cgroup v2 delegation via systemd --user, userspace networking with slirp4netns or pasta, and ports below 1024 blocked by CAP_NET_BIND_SERVICE." >}}

The practical consequence is the liberating one: the rootless *limitations* — ports below 1024, conditional resource limits, per-user image storage — are kernel-imposed, not vendor-imposed [^6][^2]. Switching engines doesn't remove them, because nobody's engine wrote them.

## 5. The Scoreboard

| Dimension | Docker rootful | Docker rootless | Podman rootless |
|---|---|---|---|
| Management plane | dockerd as root, REST API over its socket [^1] | dockerd unprivileged, wrapped by RootlessKit in a userns, via `systemctl --user` [^2][^4] | No daemon; commands fork-exec and exit; conmon supervises [^5] |
| Container root maps to | host root — no remap | your UID via the userns [^2][^4] | your UID via the userns + subuid ranges [^6] |
| Daemon exposure | daemon + runtime bugs expose root [^2] | daemon unprivileged; breakout yields your identity [^2][^4] | no daemon to attack; breakout yields your identity [^4][^5] |
| Ports below 1024 | native | setcap on rootlesskit, or the sysctl [^2] | sysctl, a redirect, or pasta's forwarding [^7] |
| Resource limits | always available | cgroup v2 + systemd required; memory + pids delegated by default; silently ignored otherwise [^2] | no support on cgroups v1; v2 delegation via `systemd --user` [^7] |
| Networking rootless | n/a — bridge and veth | RootlessKit / slirp4netns userspace net [^4] | pasta by default since 5.0, or slirp4netns [^7][^8] |
| systemd integration | system services; containers supervised via dockerd [^1] | user service for dockerd itself, with linger [^2] | Quadlet units directly under system or user systemd [^9] |
| Data location | root-owned storage | user-owned, `~/.local/share/docker` [^3] | `~/.local/share/containers/storage` [^7] |

Read the middle columns row by row and a pattern emerges: Docker rootless looks like rootful Docker with the privilege drained, while Podman looks like a different architecture that happens to share the sandbox. Whether the daemonless difference matters to you is a workflow question — scripted fleet management loves an API daemon; per-user scientific computing loves not having one.

## 6. Six Misconceptions, Corrected

The comparison post is where the folklore collects, so let's settle accounts:

**"Rootless containers are less secure because nothing runs as root."** Backwards. Rootless is a security upgrade *for the host* — container-root maps to an unprivileged UID, and a breakout lands as a mortal user instead of root [^4]. What rootless reduces is convenience for the operator, not safety.

**"Docker can't do rootless."** It can, and has for years: documented core functionality, daemon itself unprivileged in a user namespace via RootlessKit, installable from the standard packages with the setuptool, and distinct from the older daemon-still-root `userns-remap` [^2][^4].

**"Rootless containers are sandboxed like VMs."** No — containers share the host kernel, and namespaces only virtualize *views* of global resources; kernel bugs reachable from unprivileged processes stay in scope [^10]. Only a real VM boundary changes that calculus.

**"Inside a rootless container there's no root and no capabilities."** Inside the namespace the process genuinely has UID 0 and a *full* capability set — the kernel just scopes every check to resources that namespace owns [^11]. That's why rootless containers can mount proc and tmpfs internally but can't load modules or set the clock.

**"Rootless means fuse-overlayfs."** Only on older kernels — overlayfs has been mountable from within a user namespace since Linux 5.11, with fuse-overlayfs as the fallback [^11].

**"Rootless makes SELinux, AppArmor, and seccomp unnecessary."** They remain complementary: user namespaces solve the UID-mapping problem; MAC systems and seccomp constrain what the workload can do inside and against the kernel — orthogonal layers [^11][^2].

## 7. What Rootless Does Not Buy You

The section most coverage skips, stated as plainly as the wins. Rootless is a mapping change, not a wall — and the walls it doesn't build matter:

- **One shared kernel.** A kernel vulnerability reachable from an unprivileged process is reachable from a rootless container — rootless reduces the *privilege* an attacker gains, not the *attack surface* of the kernel exposed to unprivileged code [^10][^11].
- **Escapes still break out.** A runtime bug that executes code outside the sandbox delivers the invoking user's identity and their home directory, keys, and files. Rootless converts "game over, host root" into "game over for your user" — categorically less bad, still bad [^4].

{{< figure src="fig-2-blast-radius.png" alt="Hand-drawn diagram: a container with a runtime or kernel bug, with two arrows out — rootful escape landing as host root with every file and key, rootless escape landing as your user with your home directory and keys — captioned that the kernel is still shared and kernel bugs stay in scope." >}}

- **Your own containers can attack each other.** Nothing in the user-namespace model isolates two containers of the *same* user from each other beyond ordinary namespace boundaries [^11].
- **Resource limits need delegation.** Without the cgroup v2 `user@.service` delegation configured, limits may not apply at all — Docker rootless silently ignores `--cpus`/`--memory`/`--pids-limit` without it [^2], and Podman documents no limit support on cgroups v1 [^7].
- **Regular hardening still applies.** Seccomp profiles, capability trimming, and SELinux/AppArmor remain meaningful layers in rootless setups [^11][^2].

## 8. Which One, Then?

If you want the honest verdict instead of a shim: the security properties of the two rootless modes are the same, because the kernel grants them, not the vendor. Choose on architecture and workflow. Rootful Docker is still the reference implementation of the Docker API, and fleets built on Compose and the socket live there [^1]. Docker rootless exists to keep exactly that workflow while draining the daemon's privilege — setuptool, linger, `systemctl --user` [^2]. Podman rootless removes the long-lived privileged component entirely, supervises through plain systemd units, and adds pods — at the cost of an API that's opt-in rather than always-on [^5][^9]. Pick the trust posture you actually want; don't pick one for a feature the kernel already gave the other.

One honest caveat for the whole series: everything in these three posts is drawn from the kernel man pages, systemd's documentation, and the projects' own docs and repositories — it's what Podman, Docker, and the kernel document themselves to be, sourced inline throughout, not an independent security review. And the deepest claim in the series is worth repeating as the closing line: rootless containers buy you a smaller blast radius, not a smaller kernel — the last word on your container's security is the one you type yourself.

---

## References

[^1]: "[What is Docker? — Docker overview](https://docs.docker.com/engine/docker-overview/)." Docker Docs.

[^2]: "[Rootless mode](https://docs.docker.com/engine/security/rootless/)." Docker Docs.

[^3]: "[Rootless mode: Tips](https://docs.docker.com/engine/security/rootless/tips/)." Docker Docs.

[^4]: "[RootlessKit — Linux-native fakeroot using user namespaces](https://github.com/rootless-containers/rootlesskit)." rootless-containers/rootlesskit, GitHub README.

[^5]: "[podman(1) — Podman manual](https://docs.podman.io/en/latest/markdown/podman.1.html)." Podman documentation, docs.podman.io.

[^6]: Walsh, D. "[Running rootless Podman as a non-root user](https://www.redhat.com/sysadmin/rootless-podman-makes-sense)." Red Hat Enable Sysadmin, October 2019.

[^7]: "[Shortcomings of Rootless Podman](https://github.com/containers/podman/blob/main/rootless.md)." containers/podman, rootless.md.

[^8]: "[passt: Plug A Simple Socket Transport](https://passt.top/passt/about/)." passt.top project page.

[^9]: "[podman-systemd.unit(5) — systemd units using Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)." Podman documentation, docs.podman.io.

[^10]: Kerrisk, M. "[Namespaces in operation, part 1: namespaces overview](https://lwn.net/Articles/531114/)." LWN.net, January 2014.

[^11]: Kerrisk, M. "[user_namespaces(7) — overview of Linux user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)." Linux man-pages project, man-pages 6.19.
