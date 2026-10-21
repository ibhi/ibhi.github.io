---
title: "My Home Lab: The Tour"
description: "A walk through the whole setup: two OpenWrt routers, a VLAN-capable switch, a Proxmox mini PC running AdGuard Home, Home Assistant and a rootless Podman stack — plus a broken-screen MacBook that refused to retire."
date: '2026-10-19'
summary: "Two routers, one switch, a Proxmox mini PC, and a broken-screen MacBook running Linux: the full tour of my home lab, what each piece does, and the trade-offs I've accepted to keep it that way."
tags: ["Home Lab", "Self-Hosting", "Proxmox"]
showHero: false
---

**TL;DR:** A walk through my home lab — the collection of small, quiet machines that runs my network filtering, smart home, photo library, file sync, and even an AI agent. This post is the tour: what's plugged in where, what each box actually does, and why it's arranged this way. In short: two OpenWrt routers, a managed switch, a Proxmox server on a mini PC, and the newest (and most unlikely) member — a 2019 MacBook Pro with a broken screen, running Linux headless. No commands, no config dumps; just the architecture and the reasoning. The network *segmentation* — the five zones and the firewall rules between them — is a separate, earlier post, [Inside My Home Network](/posts/inside-my-home-network/), so I'll link to it rather than repeat it here.

## 1. Two Routers, One Switch, Five Wi-Fi Names

The network itself is deliberately boring, which is a compliment in this context.

The main router is a small box running OpenWrt — the open-source router operating system — and it does four jobs at once. It routes. It filters: the router is also the firewall, restricting access between the network segments and whitelisting specific pinholes where needed. It hands out addresses over DHCP, using `odhcpd`, OpenWrt's own DHCP server. And it answers every DNS question in the house, because I replaced the default `dnsmasq` resolver with **Unbound**, a validating recursive resolver. Two packages swapped for two others, and the router became the house's phonebook operator. (Why that matters, and how two layers of DNS filtering sit on top of it, is the subject of [the network post](/posts/inside-my-home-network/).)

The router is also the ground floor's Wi-Fi access point. Upstairs, coverage comes from a second OpenWrt router that has been demoted to a *dumb access point*: no routing, no firewall, no DHCP — just radios. Between them sits a small managed switch that carries the VLANs. Every VLAN in the house gets exactly one Wi-Fi network name, so "which network am I on?" and "which zone am I in?" are the same question — with one exception: the trusted wired LAN has no Wi-Fi at all. If you want into the most trusted zone, bring a cable.

I like this layer because it's almost embarrassingly simple. Two consumer-priced routers and a switch cover the whole house, and the managed switch leaves room to add more access points later without redesigning anything.

## 2. The Server: Proxmox on a Mini PC

In the wired LAN sits the lab's workhorse: a mini PC — the size of a hardcover book, and drawing very little power — running **Proxmox Virtual Environment**, an open-source virtualization platform that combines full virtual machines (KVM) with lightweight Linux containers (LXC) under one web interface [^1][^2]. Being Debian-based under the hood, it feels less like an appliance and more like a proper little Linux server, which is exactly what I wanted.

One machine, several tenants. Here's who lives there.

**Storage first, because everything else depends on it.** ZFS is Proxmox's filesystem of choice, and it lets you bundle disks into named *pools*. My layout is intentionally modest: the main `data-pool` is a single USB portable drive, and the `backup-pool` spans four disks attached through a USB-C hub, bundled into a single **RAIDZ2** pool — so unlike the lone data drive, it can lose any two disks and keep going. Nothing here is a storage-server showcase; it's a right-sized answer to "where do the photos and backups go?" The trade-offs of that answer are honest ones, and they're in section 6.

**Two AdGuard Home containers.** [AdGuard Home](/posts/inside-my-home-network/) is my network-wide DNS filter, and it runs twice on the Proxmox box as LXC containers: one serves the main wired LAN and home Wi-Fi with standard ad-and-tracker blocking, and a second — with stricter rules — serves the kids', smart-home, and guest zones. Both forward their unresolved questions upstream to the Unbound resolver on the router. Two small containers, one per trust level, is cheaper and clearer than teaching one instance to behave differently depending on who's asking.

**The smart-home brain.** Home Assistant runs as a **Home Assistant OS** virtual machine. HAOS is a purpose-built, minimal appliance image — you don't install it like a normal OS, you boot it like one, and it's the recommended installation type for most users [^3]. It runs as a VM rather than a container for one practical reason: the Zigbee coordinator, the little USB radio that talks to the smart-home sensors, plugs into the Proxmox host and is passed through to the VM, which then talks to it as if it were plugged in directly. That's the standard pattern — a USB Zigbee coordinator attached to the machine running Home Assistant [^4] — and the hypervisor makes the hand-off invisible.

**The app shelf.** The rest of the services — Immich for photos, Syncthing for file sync, the UniFi controller, Traefik as the reverse proxy, and Homarr as the dashboard — share a single *privileged* LXC container. Inside it, though, they don't run as root or as plain processes: they run as **rootless Podman** containers. Podman is a daemonless container engine that can run containers entirely as an unprivileged user [^5] — it gains no privileges when it runs, and the user-namespace mapping keeps everything inside its own lane [^6]. Autostart is handled by Quadlet, which turns small unit files into ordinary systemd user services so everything comes back after a reboot [^7].

If the "privileged LXC running rootless containers" sentence made you squint — good, it deserves its own explanation. I'm planning a series of blog posts on exactly that — rootless containers, from namespaces up through how Podman compares to Docker — and I'll link them here once they're published.

## 3. The New Arrival: A Broken MacBook That Refused to Retire

The newest machine in the lab is also the least likely: a 2019 Intel MacBook Pro whose screen gave up. Retiring it felt wasteful — the keyboard, the ports, the silicon, all fine; only the display dead. So it now lives on a shelf, lid closed forever, running Linux Mint headless as a server.

The trick is the T2 chip. Macs of that generation have Apple's T2 security chip, which stock Linux kernels don't fully support — keyboard, trackpad, and audio all need drivers that aren't upstream [^8]. The **t2linux** project exists precisely to close that gap: a community wiki and a patched kernel that makes Linux usable on all T2 models [^9], with a documented installation path for Ubuntu and Linux Mint [^10] (and a Mint-specific repo with the patches built into the installer [^11]). Headless, the parts the T2 kernel works hardest on — the keyboard, trackpad, and audio — matter least, which makes a screen-dead MacBook a strangely ideal t2linux candidate.

Two things run on it:

**My Hermes Agent.** [Hermes](https://hermes-agent.nousresearch.com/docs) is the self-improving AI agent built by Nous Research, and it's built to live wherever you put it — it supports running inside Docker or using Docker as its terminal backend [^12]. Mine runs in a rootless Podman container on the MacBook, which means the agent that writes these posts literally lives in the lab it writes about. I've written a whole series about that setup: start with [Hermes, Part 1: intro and basics](/posts/hermes-01-intro-basics/), then [where the code runs](/posts/hermes-02-where-the-code-runs/) and [the safety story](/posts/hermes-03-better-safe-than-sorry/).

**Music Assistant.** The MacBook also runs [Music Assistant](https://music-assistant.io/), a free, open-source music library manager that connects to streaming services and plays on a wide range of connected speakers [^13]. It plugs into Home Assistant through its official integration, so players show up as media entities there and every speaker in the house becomes controllable and automatable [^14]. It's platform-agnostic by design — which is why it doesn't care that its host is a Mac wearing a Linux kernel.

## 4. Honest Trade-offs and Remaining Gaps

No lab post is complete without the part where the owner admits what's wobbly. Mine, stated plainly:

- **The storage is USB all the way down.** Both ZFS pools hang off USB — one portable drive for data, four hub-attached disks for backup. USB drives are the least reliable link in any home server, and the `data-pool` has no redundancy at all: one drive, nothing mirrored — losing it would hurt. The `backup-pool` is the one place with redundancy: as a RAIDZ2 pool it can lose any two disks and keep going, so a single failed backup drive would merely be a reminder to swap it. The next serious upgrade is real internal disks — but I won't pretend the current setup has stopped me sleeping.
- **The privileged LXC is a deliberate compromise.** A privileged container has more access to the host than I'd grant a plain one; that's the price of the USB- and network-visible features the stack needs, and rootless Podman inside it keeps the individual services unprivileged. Defense in depth would prefer no privileged container at all. A planned series on rootless containers will cover exactly this tension.
- **t2linux is a community effort, not a vendor product.** The patched kernel works, but it's perpetually chasing Apple hardware, and some T2 features remain limited even when Linux is "usable" [^8]. For a headless box this is acceptable. I would not make the MacBook the home's single point of failure — which is also why the important services live on the Proxmox machine, not on it.
- **DNS still has single points.** Both AdGuard containers depend on the one Unbound instance on the router, and the router itself is one box. The network post lists the same weak spots; the lab inherits them.
- **Everything here is one power strip deep.** No UPS yet. A lab that filters, automates, photographs, and syncs the household should probably survive a flicker. It's on the list, under the disks.

## 5. What's Next

That's the tour: two routers, one switch, a mini PC wearing four hats, and a screenless Mac doing two jobs. From here I'll zoom in on individual pieces as I write about them — the storage layout, the Home Assistant setup, and how the pieces watch each other's backs — and a series on rootless containers is also on the drawing board. The two topics people ask about most already have posts of their own: [the network](/posts/inside-my-home-network/) and [my Hermes agent](/posts/hermes-01-intro-basics/).

If you're building something similar: start smaller than I did. One router with filtered DNS covers ninety percent of the benefit for ten percent of the effort. The second router, the second filter, the second machine — add each when something specific hurts, not because a diagram looked empty.

---

[^1]: "[Proxmox Virtual Environment: Overview](https://www.proxmox.com/en/products/proxmox-virtual-environment/overview)." Proxmox Server Solutions.
[^2]: "[Proxmox VE Wiki](https://pve.proxmox.com/wiki/Main_Page)." Proxmox.
[^3]: "[Home Assistant Operating System Installation: Generic x86-64](https://www.home-assistant.io/installation/generic-x86-64/)." Home Assistant.
[^4]: "[ZHA Integration](https://www.home-assistant.io/integrations/zha/)." Home Assistant.
[^5]: "[What is Podman?](https://docs.podman.io/en/latest/)." Podman Documentation.
[^6]: "[Rootless Podman Tutorial](https://github.com/podman-container-tools/podman/blob/main/docs/tutorials/rootless_tutorial.md)." Podman Documentation.
[^7]: "[podman-systemd.unit: Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)." Podman Documentation.
[^8]: "[Known Limitations / State of T2 Support](https://wiki.t2linux.org/state/)." t2linux Wiki.
[^9]: "[t2linux Wiki](https://wiki.t2linux.org/)." t2linux.
[^10]: "[Ubuntu and Linux Mint Installation Guide](https://wiki.t2linux.org/)." t2linux Wiki.
[^11]: "[t2linux/T2-Mint: Linux Mint for T2 Macs](https://github.com/t2linux/T2-Mint)." GitHub.
[^12]: "[Hermes Agent Documentation: Docker](https://hermes-agent.nousresearch.com/docs/user-guide/docker)." Nous Research.
[^13]: "[Music Assistant](https://music-assistant.io/)." Music Assistant.
[^14]: "[Music Assistant Integration](https://www.home-assistant.io/integrations/music_assistant/)." Home Assistant.
