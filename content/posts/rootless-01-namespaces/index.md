---
title: "Rootless Containers Part 1 - One Kernel, Eight Walls: How Namespaces Build a Container"
description: "What actually separates a container from the host? A from-zero tour of Linux namespaces: the eight types, clone/unshare/setns, user namespaces and uid_map, scoped capabilities, and cgroup v2 delegation."
date: 2026-10-16
summary: "A from-zero tour of the kernel machinery under rootless containers: the eight namespace types, the three syscalls that drive them, user namespaces and uid_map, scoped capabilities, and cgroup v2 delegation."
tags: ["Podman", "Containers", "Linux"]
series: ["Rootless Containers Series"]
series_order: 1
draft: true
showHero: false
---

{{< figure src="featured_rootless-01-namespaces.png" alt="Hand-drawn diagram: a container box above the shared Linux kernel holding eight namespace boxes — mount, UTS, IPC, PID, net, user, cgroup, time — with the user namespace underlined." >}}

**TL;DR:** Before Podman, Docker, or any rootless mode can make sense, one question needs an answer: what *is* a container, at the kernel level? Not a virtual machine, and not a kernel object — a pile of namespaces, a cgroup, and a root filesystem, all hosted by the kernel you are already running. This post builds that machinery from zero: the eight namespace types, the three syscalls that create them, how an unprivileged process becomes "root" somewhere, and where the resource limits come from. No container engine required yet.

## 1. A Container Is Not a Thing

Here is the first surprise, and everything else in this series falls out of it: the Linux kernel has no "container" object. Nothing in the kernel is called a container. What the kernel has is namespaces, and a namespace "wraps a global system resource in an abstraction that makes it appear to the processes within the namespace that they have their own isolated instance of the global resource" [^1]. One of the primary uses of namespaces is implementing containers — which is a way of saying that "container" is a recipe, not a thing [^1].

The recipe: a set of namespaces, a cgroup, and a root filesystem, assembled by tools running on the shared kernel [^3]. That last word is the one to dwell on. Containers share one kernel with the host; they do not get their own the way a VM does [^3]. A VM isolates you from the kernel. A container merely arranges which parts of the same kernel you can see.

That distinction sounds academic until the day it isn't: every kernel vulnerability reachable from an unprivileged process is, in principle, reachable from a container too. Keep it in mind — we'll price it properly in Part 3.

## 2. The Eight Walls

The kernel currently implements eight namespace types, each isolating a different global resource [^1]:

| Namespace | Clone flag | Isolates | First usable |
|---|---|---|---|
| Mount | `CLONE_NEWNS` | Mount points, filesystem hierarchy | 2.4.19 (2002) [^1] |
| UTS | `CLONE_NEWUTS` | Hostname and NIS domain name | 2.6.19 [^1] |
| IPC | `CLONE_NEWIPC` | SysV IPC objects, POSIX message queues | 2.6.19 [^1] |
| PID | `CLONE_NEWPID` | Process IDs, the process tree | 2.6.24 [^3] |
| Network | `CLONE_NEWNET` | Devices, IP stacks, routing, ports | 2.6.29 [^1] |
| User | `CLONE_NEWUSER` | UIDs, GIDs, root dir, keyrings, capabilities | 3.8 [^1] |
| Cgroup | `CLONE_NEWCGROUP` | The cgroup root directory *view* | 4.6 [^1] |
| Time | `CLONE_NEWTIME` | Monotonic and boot clocks | 5.6 [^1] |

Three of these deserve a second look. **UTS** is why a container can have its own hostname — `sethostname` affects only the namespace [^3]. **Network** is why a container gets its own loopback interface, its own IP, and its own port space, which is exactly why publishing ports as an unprivileged user becomes interesting later [^1]. And **cgroup** namespaces are easy to misread: they virtualize the *view* of the hierarchy a process sees in `/proc/self/cgroup`, not the resource limits themselves — limits are cgroups' job, and they are not a namespace at all [^1].

## 3. Three Syscalls and a Magic Directory

The whole namespaces API is three system calls plus some introspection [^1]:

- `clone(2)` creates a new process; passing `CLONE_NEW*` flags makes the *child* a member of brand-new namespaces, one per flag.
- `unshare(2)` moves the *calling process* into new namespaces — this is what the `unshare(1)` command-line tool exposes.
- `setns(2)` joins an *existing* namespace via a file descriptor — this is what `nsenter(1)` uses, and how debugging tools reach into a running container.

The file descriptors come from a directory worth knowing: every process has `/proc/<pid>/ns/`, with one magic symlink per namespace type, like `mnt -> mnt:[4026531840]` [^1]. The number in brackets is the namespace's inode number — two processes share a namespace if and only if those numbers match, which is how every tool compares namespaces [^1]. Opening one of those files yields a handle that keeps the namespace alive even if its last process exits, and bind-mounting one pins it for later re-entry — the trick `nsenter` and the container runtimes both rely on [^1].

One catch: creating a namespace with `clone` or `unshare` normally requires `CAP_SYS_ADMIN`, because the creator gains power over a global resource other processes can see [^1]. Normally.

## 4. The Exception: User Namespaces

Since Linux 3.8, creating a user namespace requires no privilege at all [^1]. No root, no capabilities, no setuid helper — any process may call `unshare(CLONE_NEWUSER)` and get one. That single sentence is the technical foundation of every rootless container runtime, Podman and Docker alike.

The kernel makes it safe by changing what "privileged" means inside. A process that creates — or joins — a user namespace starts with a *full set of capabilities inside that namespace*, even though it has none outside [^2]. The catch is scope: capabilities inside a user namespace permit privileged operations only on resources governed by namespaces that user namespace owns [^2]. Since the new user namespace owns any mount, PID, or network namespace its creator makes, being "root" there unlocks the namespace-flavored privileged operations: mounting `/proc`, `/sys`, `devpts`, `tmpfs` — and overlayfs, since Linux 5.11 [^2]. Mounting a block-device filesystem, changing the system clock, loading a kernel module, creating device nodes — those need privileges in the *initial* namespace and stay out of reach no matter how "root" you feel [^2].

So an unprivileged user legitimately becomes root — root *of somewhere small*. The kernel re-issues its ancient privilege checks scoped to the namespace, and that re-scoping is the entire trick.

## 5. Root Is a Mapping

A fresh user namespace starts with no mapping to its parent: IDs inside mean nothing outside until you install one [^2]. The mapping lives in `/proc/<pid>/uid_map` and `gid_map`, it can be read at any time and **written exactly once**, and each line is three numbers: `ID-inside-ns  ID-outside-ns  range-length` — a linear translation of a contiguous ID range [^2].

Here is the canonical example, from Dan Walsh's rootless Podman walkthrough. On a machine where your UID is 3267, run `podman unshare cat /proc/self/uid_map` and you get [^7]:

```text
0     3267    1
1   100000  65536
```

Read it as a translation table. Container-UID 0 — the container's "root" — is *you*. Container-UIDs 1 through 65536 map to host UIDs 100000 through 165535, the subordinate range handed to your user in `/etc/subuid` (more on that in Part 2) [^7]. So a process running as `postgres`, UID 26 inside the container, is really host UID 100025 [^7]. An escape delivers the attacker your identity, not root's — the security upgrade is a mapping change, and we'll lean on that fact for the rest of the series.

{{< figure src="fig-1-uid-map.png" alt="Hand-drawn diagram: two boxes side by side translating container UIDs to host UIDs — inside the container, UID 0 root maps to you, UID 3267 on the host, in red; UID 26 postgres maps to host UID 100025; UIDs 1 to 65536 map to the subordinate range 100000 to 165535; everything else has no mapping and is invisible. The uid_map lines 0 3267 1 and 1 100000 65536 sit underneath, captioned container-root is you, not host-root." >}}

Two loose ends for completeness: user namespaces can nest up to 32 levels deep, each owned by its creator's namespace [^2]; and the maps carry a 5-line limit for unprivileged writers — mappings beyond that go through the `newuidmap` helper — and indeed rootless mode uses no setuid binaries except the `newuidmap`/`newgidmap` pair [^2][^8].

## 6. What "Root" In There Can Actually Do

Traditional UNIX has two privilege levels: UID 0 bypasses every check, everyone else passes through them. Since Linux 2.2 that monopoly is divided into **capabilities** — `CAP_NET_BIND_SERVICE` for binding ports below 1024, `CAP_SYS_ADMIN` for mounts and namespace administration, `CAP_MKNOD` for device nodes, and a few dozen more — granted and withdrawn independently per thread [^4].

The user-namespace rules from the last two sections compose into a clean answer to "what can the container's root do?" Inside, it can do everything a root cares about daily: mount tmpfs and proc, manage its own network namespace, chown files — because those resources are governed by namespaces its user namespace owns [^2]. Outside, it can do nothing at all: no clock changes (`CAP_SYS_TIME`), no module loading (`CAP_SYS_MODULE`), no real device nodes (`CAP_MKNOD`), no binding to the host's privileged ports [^2][^9].

This is also the honest answer to a common worry — "if the container has root, hasn't rootless mode given away the game?" No: inside the namespace the process genuinely has UID 0 and a full capability set, and the kernel simply scopes every check to resources that namespace owns [^2]. Root of somewhere small is still somewhere small.

## 7. cgroups: What You May Use

Namespaces answer *what can the container see*. cgroups answer *what can it use*. cgroup v2 is a single unified hierarchy that organizes processes into a tree and distributes CPU, memory, I/O, and PIDs along it; limits set closer to the root cannot be overridden deeper in the tree [^5].

For rootless containers the interesting part is the formal **delegation model**, designed for exactly this use case: a subtree can be handed to a less-privileged user, who can build sub-hierarchies and distribute the resources received — but cannot move processes into or out of the subtree, and nothing inside it can escape the restrictions imposed above it [^5]. Delegation with walls, in other words.

systemd is the practical delegator, and it hands out subtrees through its own machinery: `.service` units for processes it starts, `.scope` units for processes forked by someone else — like a container runtime — and `.slice` units as the tree's inner nodes, with `Delegate=` handing a unit's subtree to its payload [^6]. Two design rules govern everything: no processes in inner nodes, and one writer per cgroup — daemons must not carve up the root, they must get their own delegated subtree [^6]. The legacy cgroup v1 hierarchies were deprecated in systemd v256 and removed in v258; the new features exist only in v2 [^6].

The rootless consequence: your containers run under *your own* systemd instance, `user@<uid>.service`, and by default that typically gets only the `memory` and `pids` controllers delegated — an admin can widen it with a `Delegate=cpu cpuset io memory pids` drop-in [^8]. Podman states plainly that there is no support for resource limits on cgroups v1 [^9], and Docker's rootless mode silently ignores `--cpus`, `--memory`, and `--pids-limit` unless cgroup v2 and systemd are in place [^8]. "My container ignored its memory limit" is usually a delegation story, not a bug.

## 8. The Whole Stack, One Picture

Put the pieces together and the rootless stack reads as one chain:

{{< mermaid >}}
graph TD
    U[unprivileged user] --> UN[user namespace - zero privileges needed]
    UN --> NS[full capabilities - valid inside only]
    NS --> OWN[mount / pid / net namespaces owned by it]
    OWN --> CG[cgroup subtree delegated by systemd --user]
    CG --> RT[OCI runtime runs the container]
    style UN fill:#f96,stroke:#333,stroke-width:4px
{{< /mermaid >}}

Every arrow is something you now know by name: the user namespace created for free, the capabilities re-scoped to it, the other namespaces owned by it, the resources delegated by your own systemd. An OCI runtime — the same standard Docker uses — fills in the root filesystem and process setup inside that sandbox.

{{< figure src="fig-2-rootless-stack.png" alt="Hand-drawn diagram: the full rootless stack bottom to top — an unprivileged user like you, flowing into a dashed blue user-namespace box created with zero privileges since Linux 3.8, holding a full capability set valid inside only with CAP_SYS_ADMIN re-scoped to the namespace; below it, mount, pid and net namespaces owned by the user namespace, then a cgroup v2 subtree delegated by systemd --user with the memory and pids controllers, and finally the OCI runtime where the container runs, captioned that every privilege below the wall stops at the wall." >}}

One honest caveat before we build on it: this stack is machinery, not a wall. The container still executes against the host kernel, and a kernel bug reachable from an unprivileged process remains reachable from inside a rootless container — rootless shrinks the *privilege* an attacker gains, not the kernel attack surface exposed to unprivileged code [^2][^3]. That's the price of the whole design, and Part 3 weighs it against the alternatives.

Next up: Part 2 opens up Podman itself — the daemonless fork-exec model, the 65,536 spare identities in `/etc/subuid`, overlay storage in your home directory, pasta's no-NAT networking, and Quadlet, the current answer to running containers under systemd without root. Stay tuned.

---

## References

[^1]: Kerrisk, M. "[namespaces(7) — overview of Linux namespaces](https://man7.org/linux/man-pages/man7/namespaces.7.html)." Linux man-pages project, man-pages 6.19.

[^2]: Kerrisk, M. "[user_namespaces(7) — overview of Linux user namespaces](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)." Linux man-pages project, man-pages 6.19.

[^3]: Kerrisk, M. "[Namespaces in operation, part 1: namespaces overview](https://lwn.net/Articles/531114/)." LWN.net, January 2014.

[^4]: "[capabilities(7) — overview of Linux capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)." Linux man-pages project, man-pages 6.19.

[^5]: Heo, T. "[Control Group v2](https://docs.kernel.org/admin-guide/cgroup-v2.html)." The Linux Kernel documentation.

[^6]: Poettering, L. et al. "[Control Group APIs and Delegation](https://systemd.io/CGROUP_DELEGATION/)." systemd.io.

[^7]: Walsh, D. "[Running rootless Podman as a non-root user](https://www.redhat.com/sysadmin/rootless-podman-makes-sense)." Red Hat Enable Sysadmin, October 2019.

[^8]: "[Rootless mode](https://docs.docker.com/engine/security/rootless/)." Docker Docs.

[^9]: "[Shortcomings of Rootless Podman](https://github.com/containers/podman/blob/main/rootless.md)." containers/podman, rootless.md.
