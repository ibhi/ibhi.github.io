---
title: "Rootless Containers Part 2 - Podman Without a Daemon: A Rootless Deep Dive"
description: "How Podman runs containers without root and without a daemon: fork-exec and conmon, subuid and subgid setup, overlay storage in your home directory, pasta's no-NAT networking, and Quadlet under systemd."
date: '2026-10-17'
summary: "Podman rootless internals: the daemonless fork-exec model, subuid/subgid setup, overlay storage in the home directory, pasta networking and its no-NAT quirks, ports below 1024, and Quadlet systemd units."
tags: ["Podman", "Containers", "Linux"]
series: ["Rootless Containers Series"]
series_order: 2
draft: true
showHero: false
---

{{< figure src="featured_rootless-02-podman-deep-dive.png" alt="Hand-drawn diagram: podman run at the center — a client that forks and exits — surrounded by the no-daemon fork-exec model, the conmon per-container monitor, subuid and subgid ranges, pasta userspace networking, and Quadlet systemd units." >}}

**TL;DR:** Part 1 built the kernel machinery: user namespaces, ID mappings, scoped capabilities, cgroup delegation. This post walks the engine that puts it to work. Podman runs containers without root *and* without a daemon — each command forks, does its work under a per-container monitor, and exits. We'll set up the 65,536 spare identities rootless mode needs, see where the storage lands in your home directory, untangle pasta's no-NAT networking, price in the ports-below-1024 limit, and meet Quadlet, the current answer to "run my container under systemd."

This post is part of a series. If you haven't read [Part 1]({{< ref "/posts/rootless-01-namespaces" >}}) yet, start there — everything below leans on the user-namespace machinery it builds.

## 1. No Daemon, No Drama

Podman describes itself as "a fully featured container engine that is a simple **daemonless** tool" — with a Docker-CLI-compatible command line, so much so that `alias docker=podman` is a supported lifestyle [^1]. The architectural difference is in that word. There is no privileged background process owning container state: each Podman command is a client that does its work and exits [^1]. The kernel-level work of creating the container is done by an OCI runtime — the same standard Docker uses — so images and command semantics carry over [^1].

Something still has to watch the running container after the CLI exits, and that job belongs to **conmon**, a per-container monitor process Podman attaches for the container's lifetime [^1]. The lifecycle is fork-exec, not client-server: `podman run` starts the container plus a conmon, then the CLI process goes away. With no daemon to supervise containers, systemd can supervise them directly — a point Quadlet cashes in later in this post.

{{< figure src="fig-1-daemonless.png" alt="Hand-drawn diagram: on the left, Docker rootful — CLI to an always-on root daemon that owns state, and when the daemon dies the management plane goes with it; on the right, Podman — run forks the container plus conmon and exits, with systemd owning state." >}}

One more Podman-ism: **pods** are a first-class concept — a group of containers sharing namespaces, with a pod infrastructure container holding the shared mount, PID, network, UTS, and IPC namespaces that the members join [^1]. Docker has no such concept; you'd emulate it with shared-network containers. It's a nice feature, and irrelevant to rootlessness — worth saying out loud, because the two often get conflated in Podman marketing.

## 2. The One-Time Setup: 65,536 Spare Identities

Part 1 showed the magic: container-UID 1 through 65536 mapping into host UIDs 100000-plus. Those ranges don't appear by accident. An administrator adds one line per user to `/etc/subuid` and `/etc/subgid` — lines of the form `user:start:count`, typically 65,536 IDs each [^2][^3]:

```text
youruser:100000:65536
```

After that, Podman unshares a user namespace whose map puts container-UID 0 at your UID and the rest into the subordinate range — the exact walkthrough from Part 1 [^2]. If the files aren't set up for your user, rootless Podman commands simply fail [^4]; some identity providers like FreeIPA can supply the ranges centrally, though most setups still manage the files by hand [^4]. Docker rootless needs the same lines in the same files, which should prime you for the comparison post: the kernel contract is shared, not vendor-specific [^3].

Everything else lives in your own XDG directories. Podman reads `containers.conf` from `/usr/share`, `/etc`, and `${XDG_CONFIG_HOME}` in increasing precedence; rootless storage defaults to `graphroot = ~/.local/share/containers/storage` with `runroot` under `/run/user/$UID` — and the `graphroot`/`runroot` fields in `/etc/containers/storage.conf` are ignored in rootless mode [^2]. Your containers, your home directory, your disk quota.

The run-time knobs map one-to-one onto Part 1's machinery: `--userns keep-id` maps your host UID to the *same* UID inside the container — so bind-mounted files stay owned by you instead of showing up as container-root; `--uidmap`/`--gidmap` take explicit three-field mapping lines, exactly the `uid_map` format; and `--subuidname`/`--subgidname` use a named range from those files [^5].

## 3. Storage: Overlay on Your Home Directory

Rootless Podman keeps everything under your home, so the union filesystem that layers images needs to work without root. It has two implementations. The fast path is the kernel's native overlayfs, mountable inside a user namespace since Linux 5.11 — mounting overlayfs made it onto the CAP_SYS_ADMIN-in-user-namespace allowlist [^6]; Podman has enabled it for rootless mode since Podman 3.1, on kernels 5.12 and up [^4]. On older kernels, the fallback is **fuse-overlayfs**, "an implementation of overlay+shiftfs in FUSE for rootless containers" [^7] — a userspace filesystem, requiring kernel 4.18-plus when used from a user namespace [^7].

The trade-off is structural, not magical: the FUSE version puts a userspace daemon into every filesystem operation, an extra hop the in-kernel path doesn't have [^6][^7]. One honest caveat before you benchmark anything: the projects document the designs, not comparative throughput numbers — treat any "fuse-overlayfs is slower" claim as directional, not audited.

## 4. The Networking Problem

Now the part that actually required inventing new software. Part 1 established that a network namespace — own interfaces, own IP, own ports — is creatable by an unprivileged user. But a namespace full of interfaces is a boat with no rudder: *connecting* it to the outside normally means creating host interfaces, veth pairs, and that needs `CAP_NET_ADMIN`, which you don't have [^8].

The two answers both replace the veth with userspace packet plumbing [^8]. **slirp4netns** — "user-mode networking for unprivileged network namespaces" — is the long-standing option, implementing a full TCP/IP stack that replays the container's traffic onto host sockets [^9]. Since **Podman 5.0, the default is pasta** [^4], which takes a thinner approach: it gives the namespace a tap interface and maps traffic onto native host sockets *without creating any host interface and without requiring any capabilities* — and for local connections, it moves data directly between sockets using `splice(2)` [^8].

{{< figure src="fig-2-pasta.png" alt="Hand-drawn diagram: the container network namespace with a tap interface and an IP copied from the host, connected through pasta — pure userspace, no capabilities, no host interface — to the host's native TCP and UDP sockets." >}}

Sit with what just happened: your container talks to the internet through a program running as you, with no special privileges anywhere in the path. That's either deeply reassuring or deeply alarming, depending on how much you trusted veth.

## 5. Pasta, and the Price of No NAT

Pasta's design has one famous user-visible quirk: by default it does **no NAT**. It copies the host interface's IP address into the container, so container and host share the same address — which means a container connecting to "the host IP" reaches *itself* [^4][^10]. The first time an app inside a rootless container tries to talk to a service on its own host by IP, this quirk eats an afternoon.

The escape hatches are documented, not folk wisdom. `host.containers.internal` exists as a stable name for reaching the host; and because single-IP hosts left no usable address for it, Podman 5.3 enables pasta's `--map-guest-addr` by default, mapping the link-local address 169.254.1.2 inside the container to the host [^10]. The same 5.3 release fixed a boot-order annoyance: rootless Quadlet units used to fail at boot with "External interface not usable," because the systemd *user* session can't order against the system's `network-online.target` — Podman 5.3 ships `podman-user-wait-network-online.service` to bridge that gap [^10]. Rootless networking in 2026 is good; it got good by shipping fixes for exactly these two rough edges.

## 6. Ports Below 1024

The kernel refuses to bind ports below 1024 without `CAP_NET_BIND_SERVICE` [^11], and a rootless container's user namespace has no capabilities over host-level socket policy — so, in Podman's own words, it "can not create containers that bind to ports < 1024" [^4]. Not a Podman bug, not a missing flag: kernel policy, and Part 1 told you which capability it was.

The documented workarounds [^4]:

- raise the floor with the sysctl, e.g. `net.ipv4.ip_unprivileged_port_start=443`;
- redirect from a privileged port with a firewall rule or a tool like `redir`.

Podman's default rootless port forwarder is **rootlessport**, a userspace proxy with one caveat worth reading twice: it does **not preserve client source IPs** — every connection looks like it came from localhost, which wrecks IP-based access control [^4]. Setting `rootless_port_forwarder="pasta"` in containers.conf switches to pasta's kernel-level forwarding, which keeps the original client IP — marked experimental, and needing a passt version that ships the `pesto` binary [^4]. If you run a web app behind one of those "allow-list by IP" middlewares, this is the setting that decides whether your logs are useful.

## 7. Quadlet: systemd Without Root

The legacy answer to "run my container as a service" was `podman generate systemd` — and it's **deprecated**: the man page recommends Quadlet, promising only "urgent bug fixes but no new features" [^12]. Any tutorial from the last few years still teaching `generate systemd` is teaching the previous generation.

Quadlet is the current mechanism, and it's a better shape: you write unit files with extensions like `.container`, `.pod`, `.volume`, `.network`, or `.kube` into systemd's search paths, and a systemd generator turns each into a regular `.service` at boot or `daemon-reload` — after which you manage it with plain `systemctl` [^13].

{{< mermaid >}}
graph LR
    Q[web.container file] --> G[systemd generator at boot or daemon-reload]
    G --> S[web.service - a regular unit]
    S --> M[systemctl --user status / restart]
    style S fill:#f96,stroke:#333,stroke-width:4px
{{< /mermaid >}}

Rootless works because the units live in *your* systemd session: `~/.config/containers/systemd/` or `$XDG_RUNTIME_DIR/containers/systemd/`, enabled for boot with `[Install] WantedBy=default.target` [^13]. Container units default to `Type=notify`, so systemd actually waits for the container to be healthy instead of guessing [^13]. The fine print: Quadlet requires cgroup v2 [^13], and you can't smuggle rootlessness through systemd's `User=` or `DynamicUser=` — run the container as the actual user, with the unit in their path [^13]. The container's cgroup limits come from the delegation we saw in Part 1: your `user@.service` slice, typically with `memory` and `pids` [^3].

## 8. What Podman Rootless Still Can't Do

The honest section. Rootless Podman's own docs list the constraints without flinching [^4]: container images cannot easily be shared with other users — your storage is in your home directory, so it's yours; rootless doesn't work on NFS or GPFS home directories, which rules out some corporate setups entirely; resource limits need cgroup v2, as Part 1 covered; and the ports-below-1024 ceiling stands unless you reach for the sysctl or a redirect.

None of these are bugs, and none of them are unique to Podman — they are the price of the unprivileged operation itself, which is exactly why the next post can compare Podman rootless against Docker rootless on something fairer than vibes. That comparison — privileged daemon, de-privileged daemon, no daemon — plus what a container escape actually buys an attacker in each model, is Part 3. Stay tuned.

---

## References

[^1]: "[podman(1) — Podman manual](https://docs.podman.io/en/latest/markdown/podman.1.html)." Podman documentation, docs.podman.io.

[^2]: "[Basic Setup and Use of Podman in a Rootless environment](https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md)." containers/podman, rootless tutorial.

[^3]: "[Rootless mode](https://docs.docker.com/engine/security/rootless/)." Docker Docs.

[^4]: "[Shortcomings of Rootless Podman](https://github.com/containers/podman/blob/main/rootless.md)." containers/podman, rootless.md.

[^5]: "[podman-run(1) — Run a command in a new container](https://docs.podman.io/en/latest/markdown/podman-run.1.html)." Podman documentation, docs.podman.io.

[^6]: Kerrisk, M. "[user_namespaces(7) — overview of Linux user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)." Linux man-pages project, man-pages 6.19.

[^7]: "[fuse-overlayfs — FUSE implementation for overlayfs for rootless containers](https://github.com/containers/fuse-overlayfs)." containers/fuse-overlayfs, GitHub README.

[^8]: "[passt: Plug A Simple Socket Transport](https://passt.top/passt/about/)." passt.top project page.

[^9]: "[slirp4netns — user-mode networking for unprivileged network namespaces](https://github.com/rootless-containers/slirp4netns)." rootless-containers/slirp4netns, GitHub README.

[^10]: "[Podman 5.3 changes for improved networking experience with pasta](https://blog.podman.io/2024/10/podman-5-3-changes-for-improved-networking-experience-with-pasta/)." Podman blog, October 2024.

[^11]: "[capabilities(7) — overview of Linux capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)." Linux man-pages project, man-pages 6.19.

[^12]: "[podman-generate-systemd(1) — [DEPRECATED] Generate systemd unit file(s)](https://docs.podman.io/en/latest/markdown/podman-generate-systemd.1.html)." Podman documentation, docs.podman.io.

[^13]: "[podman-systemd.unit(5) — systemd units using Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)." Podman documentation, docs.podman.io.
