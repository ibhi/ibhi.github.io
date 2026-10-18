---
title: "Inside My Home Network: One Router, Five Zones, and a Fence Between Them"
description: "How one homeowner split a home network into five VLANs with a default-deny firewall, filtered DNS in two tiers, and remote access with zero open ports — plus the five holes an audit of the config turned up."
date: '2026-10-18'
summary: "Five zones on one router, nothing trusted by default, DNS that can't be quietly bypassed, and remote access without a single open door — plus the five mistakes my own audit found."
tags: ["Home Network", "Security", "Networking"]
draft: true
showHero: false
---

{{< figure src="featured_inside-my-home-network.png" alt="Hand-drawn style diagram of a house divided into five labeled rooms — trusted wired, home Wi-Fi, kids Wi-Fi, smart gadgets, guest Wi-Fi — separated by fence lines, with one router standing at the gate to the internet and a side tunnel labelled Tailscale entering past the gate." >}}

**TL;DR:** My home network used to be one flat space where every device could talk to every other device. It's now five isolated zones behind one router, with a firewall that denies everything by default and opens narrow, deliberate paths where life actually requires them. This post walks through why that's worth doing, what the map looks like, how the DNS chain works, and — the part I'd most like you to take away — the five real holes I found when I audited my own configuration. No commands, no config dumps; just the architecture and the reasoning.

## 1. Why Segment a Home at All?

A typical home network is an apartment building where every door stands open. Your laptop, the kids' tablets, the TV, a smart plug, a light bulb, and your guest's phone all live on the same network — and by default, any of them can knock on any other's door. The TV doesn't need to talk to the laptop with the tax returns. The internet-connected doorbell has no business reaching the backup drive. But on a flat network, nobody told them that.

This is not a hypothetical worry. In 2016, the Mirai botnet infected over 600,000 vulnerable internet-of-things devices — home routers, air-quality monitors, surveillance cameras — and used them to knock major websites offline [^1]. That wasn't a one-off: researchers tracking IoT threats in 2023 found malware families descended from Mirai still active, with weak device passwords still the primary way in [^2]. The gadgets are the softest target in the house, and a flat network hands them the run of the place.

Security agencies have been saying the quiet part loudly for years: the US cybersecurity agency CISA recommends dividing a network into segments, each acting as its own sub-network, precisely so a problem in one segment can't simply walk into the next [^3].

So that's the project this post describes: put fences inside the house. Not because anything happened — because on today's internet, "nothing weird has happened yet" is not a security strategy.

## 2. The Map: One Router, Five Zones

The whole setup runs on a single small router — a GL.iNet Beryl — running OpenWrt, an open-source router operating system. (The software a router runs is called its *firmware*; replacing the manufacturer's default with something like OpenWrt is like replacing a locked-down appliance with a general-purpose computer.) You don't need this specific hardware for the ideas; you need firmware that supports the one feature everything else builds on: **VLANs**.

A VLAN — virtual local area network — is an invisible wall drawn inside the network wiring. The standard that defines them (IEEE 802.1Q) is the same technology businesses use to slice one physical office network into many logical ones [^4]. To the devices, each VLAN looks like its own private network; they can't see the others exist. One physical cable from the router carries all of them, tagged like mail sorted into different bins.

Every zone gets an address range from the private space (192.168.x.x) that never leaves the house — these addresses are deliberately not routable on the public internet, which is also why showing them in a diagram reveals nothing about my actual network [^5]. Here's the whole map:

| Zone | VLAN | Addresses | Who lives there |
|---|---|---|---|
| Trusted wired | 1 | 192.168.1.0/24 | The desktop, the server, the stuff I administer |
| Home Wi-Fi | 8 | 192.168.8.0/24 | Our phones and laptops, the TV |
| Kids Wi-Fi | 10 | 192.168.10.0/24 | The children's devices, on a leash (more below) |
| Smart home (IoT) | 20 | 192.168.20.0/24 | Lights, plugs, sensors, the solar inverter, the automation hub |
| Guest Wi-Fi | 30 | 192.168.30.0/24 | Visitors — polite but distrusted |

The fiber line from the internet provider arrives on its own tagged VLAN, separate from all of the above. Wi-Fi security is WPA2/WPA3 — WPA3 being the newest Wi-Fi protection standard, which resists password-guessing attempts far better than its predecessor [^6] — with a fast-roaming feature so phones switch between access points without dropping calls [^7].

{{< figure src="fig-1-network-map.png" alt="Diagram of the home network: a fiber internet line and a Tailscale tunnel enter a GL.iNet Beryl router running OpenWrt; from the router, one cable fans out into five labeled zones — trusted wired (VLAN 1, 192.168.1.0/24), home Wi-Fi (VLAN 8, 192.168.8.0/24), kids Wi-Fi (VLAN 10, 192.168.10.0/24), smart home IoT (VLAN 20, 192.168.20.0/24), and guest Wi-Fi (VLAN 30, 192.168.30.0/24) — each zone sending its DNS lookups through one of two AdGuard Home filters before reaching the unbound resolver on the router, with a narrow pinhole path from the Home Assistant hub to the TV and the solar inverter." >}}

## 3. Who Can Talk to Whom: Default-Deny, With Pinholes

The firewall policy underneath the map is one sentence long: **nothing crosses a zone boundary unless a specific rule allows it.** This is "default-deny," and it's the home-scale version of what NIST's zero-trust guidance formalizes: don't grant trust based on where a device sits [^8]. Being plugged into my wall does not make you family.

Concretely:

- The kids', smart-home, and guest zones cannot reach the router's own settings, and cannot reach any other zone. Their traffic to anywhere internal is rejected outright — not stealthily dropped, just told "no."
- Each zone *can* reach the internet, because that's what the devices are for. But connections from the internet cannot start anything inward (more on that in section 6).
- Where life genuinely requires a path, there's a **pinhole** — a rule allowing one specific thing, not a corridor. The automation hub (Home Assistant, the open-source brain of the smart home) lives in the smart-home zone and is the only device there with any cross-zone privileges at all: it may reach the admin screens of the two DNS filters, one solar inverter gateway, and the TV. That's the entire list. Everything else in the smart-home zone sees only the internet.
- Discovery traffic — mDNS, the mechanism devices use to shout "anyone here called 'printer'?" on the local network [^9] — is allowed only in the zones where casting and printing actually need it. That shouting doesn't cross VLAN walls by design, which is exactly the point: your guest's phone announcing itself can't be heard in the kids' zone.
- And one rule the kids would happily delete: their zone loses internet access on a schedule, 21:30 to 06:00. The fence does parenting duty too.

## 4. The DNS Chain: Every Name Lookup Passes Two Checkpoints

Whenever any device visits `example.com`, it first asks a **DNS resolver** — the internet's phonebook — to translate that name into an address. That makes the resolver a natural checkpoint: control the phonebook and you filter the whole network at once, with no software on any device.

My chain has two tiers:

1. **AdGuard Home**, a network-wide filtering resolver [^10]. There are two instances: the trusted zones (wired and home Wi-Fi) get one with standard ad-and-tracker blocking; the kids, smart-home, and guest zones get a stricter one. Local devices also get friendly names here — the media server answers at `plex.home.example`, the photo backup at `immich.home.example` — so nothing at home depends on remembering raw addresses.
2. **Unbound**, a resolver running on the router itself, which does the actual recursive lookups on the filters' behalf [^11]. It validates every answer with **DNSSEC** — cryptographic tamper-seals that prove an answer really came from the domain's owner and wasn't forged in transit [^12] — and applies *rebind protection*, dropping the classic trick where a public website resolves to a private address to reach into the home network from a browser [^13].

The tiered part matters for the fence. The restricted zones may send DNS traffic — port 53, the standard doorway for it — **only** to the two AdGuard addresses. Point a device at Google's 8.8.8.8 instead, and the firewall rejects it. Without that, every filter above is decorative: the phonebook only governs people who use it.

## 5. What I Found Auditing My Own Config

Here's the humbling part. I built this setup deliberately, over time, and I assumed it was tight. Then I exported the router's configuration and read it like a stranger — the way an attacker would. Five findings, each of which looked tidy in the interface and was a real hole:

1. **The DNS rules were wider than I thought.** The kids', guest, and smart-home zones had rules allowing DNS to *any* address — a leftover from an earlier setup stage. Any device in those zones could bypass both filters by pointing at 8.8.8.8, silently skipping ad blocking, tracker blocking, and the stricter kids' filter. The fence had a gate I'd forgotten I installed. *Fix:* deleted the wide rules; only the two AdGuard addresses may answer.
2. **The router's admin login accepted a password over SSH** — SSH being the terminal you use to configure a router remotely — from the trusted networks. A password can be guessed or captured; slowly, indefinitely, from any device I'd trusted that day. *Fix:* password login off entirely; access only via cryptographic keys stored on a hardware key — a YubiKey — where OpenSSH's FIDO2 support means the secret never leaves the physical device, and each login needs a physical touch [^14][^15]. Malware on my laptop can copy my files; it cannot copy a key that refuses to leave a piece of hardware.
3. **Leftover doorways from the internet faced inward.** Two firewall rules forwarded VPN-handshake traffic (IPsec, a VPN technology I don't use — they'd shipped in a setup template) from the internet straight into the home network. Pure legacy attack surface; on an IPv6 connection, where every device can have a public address, they'd have been directly reachable. *Fix:* disabled both. A door to a room that doesn't exist is still a door.
4. **The trusted zone could start connections into the guest and kids zones.** My own laptop could reach the children's devices — convenient, and unnecessary; casting and automation needs were already covered by the pinholes. *Fix:* removed. Least privilege applies to me too.
5. **Guest devices could talk to each other.** They couldn't reach anything of mine, but one infected visitor laptop could attack the other visitor devices on the same Wi-Fi — an awkward conversation either way. The fix is *AP isolation*, an access-point setting that makes wireless clients on the same network invisible to each other [^16]. (Note what it does *not* do: it separates guests from each other, not from your network — the VLAN wall is what does that.)

None of these were exotic. That's the takeaway: the config *looked* clean, the dashboard showed green, and five specific rules were quietly undermining the design. Audits find what intentions forget.

## 6. Remote Access Without Opening Doors

The last structural decision: reaching home devices from away — checking the automation, grabbing a file — without the classic "port forwarding" setup, where you hold a door on your router open to the entire internet and trust a login to defend it. Scanners find those doors within hours and knock constantly.

Instead, the network uses **Tailscale**, a mesh VPN — VPN meaning virtual private network, an encrypted tunnel that makes a far-away device behave as if it were home. Under the hood it's built on WireGuard, a modern, audited tunnel protocol [^17]. The difference that matters here is directional: Tailscale devices connect *outward* and find each other through a coordination service, so the router holds **zero open ports**. There is no door for the internet to knock on, because from the internet's point of view, there is no door.

A single always-on device at home acts as a *subnet router* — Tailscale's term for a gateway that advertises the home address ranges to my other devices [^18]. My phone, anywhere, reaches anything at home as if it were on the couch; nothing at home had to have extra software installed to allow it. On the map in section 2, it's the tunnel entering past the gate, not through it.

## 7. Honest Trade-offs and Remaining Gaps

This setup is good, not perfect. The gaps, stated plainly:

- **Each zone depends on exactly one DNS filter.** If the strict AdGuard instance dies, the kids, smart-home, and guest zones lose name lookups — or worse, devices quietly fall back to whatever resolver they can find. The robust design hands out both filter addresses everywhere and keeps their rules identical. It's on the list.
- **Encrypted DNS can still slip past.** Browsers increasingly support DNS-over-HTTPS — name lookups smuggled inside normal encrypted web traffic — which port-53 rules can't see. The practical mitigation is already in place: the filters block the known encrypted-DNS providers, and they answer the *canary domain* — a special name browsers check to detect exactly this filtering — with a failure, which tells well-behaved browsers to use the local resolver [^19]. A determined user with a manual setting still wins. In my house, "determined" is currently age-limited.
- **The discovery rule is broader than it needs to be.** mDNS is allowed by source zone less strictly than it could be — information leakage rather than access, but easy to tighten.
- **Remote access is currently all-or-nothing.** Any device signed into my Tailscale account can reach the home zones. Fine while it's three devices I own; the proper hardening is access rules on the Tailscale side, so the phone gets the media server and nothing else.
- **WPA3 mixed mode occasionally confuses old gadgets.** The newest Wi-Fi security, offered in a compatibility mode, still makes some aging smart devices sulk. Comfort versus security, decided device by device.

## 8. Takeaways for Your Own Home

You don't need five zones to benefit from the thinking. In ascending order of effort:

1. **Turn on the guest Wi-Fi.** Nearly every router has one; it's a fence between your visitors and your life, and it takes two minutes.
2. **Give the smart gadgets their own network** if your equipment supports it — a second SSID on a separate VLAN, or even a cheap second router. The things you can't update are the things that don't share your network.
3. **Lock the router's admin interface.** Strong unique password, admin unavailable over Wi-Fi, and remote administration off unless you truly need it.
4. **Filter DNS network-wide** if you're comfortable running one small service — one resolver covers every device, including the ones that can't install apps.
5. **Prefer remote access without open ports.** If your current setup involves port forwarding to reach home, that's the single highest-value thing on this list to change.

And borrow the habit that produced section 5: every few months, read your own router's rule list like a stranger. The architecture sets the fence; the audit is what notices the gate someone left open. Mine had five.

---

[^1]: "[Inside Mirai: The Infamous IoT Botnet — A Retrospective Analysis](https://blog.cloudflare.com/inside-mirai-the-infamous-iot-botnet-a-retrospective-analysis/)." Cloudflare Blog.
[^2]: "[Kaspersky Unveils an Overview of IoT-Related Threats in 2023](https://www.kaspersky.com/about/press-releases/kaspersky-unveils-an-overview-of-iot-related-threats-in-2023)." Kaspersky, September 2023.
[^3]: "[Layering Network Security Through Segmentation](https://www.cisa.gov/resources-tools/resources/layering-network-security-through-segmentation-infographic)." CISA.
[^4]: "[IEEE 802.1Q-2022 — Bridges and Bridged Networks](https://standards.ieee.org/ieee/802.1Q/10323/)." IEEE Standards Association.
[^5]: "[RFC 1918: Address Allocation for Private Internets](https://www.rfc-editor.org/rfc/rfc1918)." IETF / RFC Editor.
[^6]: "[Wi-Fi Security](https://www.wi-fi.org/security)." Wi-Fi Alliance.
[^7]: "[802.11r Fast Transition Deployment Guide](https://www.cisco.com/c/en/us/td/docs/wireless/controller/technotes/80211r-ft/b-80211r-dg.html)." Cisco.
[^8]: "[NIST SP 800-207: Zero Trust Architecture](https://csrc.nist.gov/pubs/sp/800/207/final)." NIST, August 2020.
[^9]: "[RFC 6762: Multicast DNS](https://www.rfc-editor.org/rfc/rfc6762)." IETF / RFC Editor.
[^10]: "[AdGuard Home Overview](https://adguard-dns.io/kb/adguard-home/overview/)." AdGuard Knowledge Base.
[^11]: "[Unbound Documentation](https://unbound.docs.nlnetlabs.nl/)." NLnet Labs.
[^12]: "[RFC 4033: DNS Security Introduction and Requirements](https://www.rfc-editor.org/rfc/rfc4033)." IETF / RFC Editor.
[^13]: Jackson, C., Barth, A., Bortz, A., Shao, W., Boneh, D. "[DNS Rebinding Attacks](https://crypto.stanford.edu/dns/)." ACM CCS 2007 / Stanford Crypto Group.
[^14]: "[OpenSSH 8.2 Release Notes](https://www.openssh.com/txt/release-8.2)." OpenSSH, 2020.
[^15]: "[Securing SSH with FIDO2](https://developers.yubico.com/SSH/Securing_SSH_with_FIDO2.html)." Yubico Developers.
[^16]: "[What Does the AP Isolation Setting on Routers Do?](https://www.microcenter.com/tech_center/article/6778/what-does-the-ap-isolation-setting-on-routers-do)." Micro Center Tech Center.
[^17]: "[How Tailscale Works](https://tailscale.com/blog/how-tailscale-works)." Tailscale.
[^18]: "[Subnet Routers](https://tailscale.com/kb/1019/subnets)." Tailscale Knowledge Base.
[^19]: "[Configuring Networks to Disable DNS Over HTTPS](https://support.mozilla.org/en-US/kb/configuring-networks-disable-dns-over-https)." Mozilla Support.
