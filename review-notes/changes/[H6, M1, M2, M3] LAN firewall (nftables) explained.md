# H6, M1, M2, M3: The LAN Firewall (nftables) Explained

This note covers findings **M1**, **M2**, **M3** and the rest of **H6** from `GADGET_COMMITS_REVIEW.md`, fixed on 2026-10-13. All four are about one feature: the firewall that stops a tenant's container from reaching the host's local network.

## 1. A few terms first

**LAN / private network.** The network the host machine sits on. On a home host it's the router and the operator's own devices (`192.168.x.x`). In a cloud it's the provider's private network (`10.x.x.x`) and the **metadata service at `169.254.169.254`**, which can hand out machine details or credentials to anything on the host that asks.

**Why tenants must be kept out.** Tenants are strangers who rent a container and run any code they like. Without a firewall, their code can reach everything the host can: the router's admin page, the operator's NAS, the cloud metadata service, and services on the host itself (SSH, databases) that ufw hides from the internet.

**nftables / `nft`.** The Linux kernel's firewall, and its command-line tool. Rules live in **tables**. An `ip` table only sees IPv4, an `ip6` table only sees IPv6, and an `inet` table sees both.

**`meta skuid`.** A rule match meaning "packets sent by this Linux user". Sashimono uses rootless Docker, so each tenant's container traffic leaves the host through a `slirp4netns` process running as that tenant's own user (`sashiXXXX`). `meta skuid <uid>` therefore catches exactly that tenant's traffic, and nothing else on the host.

**`ct state established,related`.** "This packet is a reply on a connection that already exists." It lets a tenant answer connections that someone else opened (a website visitor, the NPMplus proxy, another node) without letting it open new ones.

## 2. What Gadget built

Commit `10078bb` (2025-06-14) added a per-instance table, `ip docker_filter_<uid>`, in `user-install.sh`. Later commits added IPv6 rules, saving the rules (`696139f`) and a DNS check (`b4e7824`). In short, it:

1. Installed `nftables` with `apt-get` if `nft` was missing, **during instance creation**.
2. Skipped the firewall completely if the host's first IP equalled the IP its domain resolves to ("a standalone node").
3. Otherwise allowed the host's own LAN IP, the gateway, the proxy and the first DNS server, **on all ports**.
4. Dropped the **first** `x.x.x.x/nn` found in `ip route`.
5. Added two IPv6 rules to an `ip6` table.
6. Saved everything with `nft list ruleset > /etc/nftables.conf` and `systemctl enable nftables`, at install and again in every instance's cleanup script.

## 3. What was wrong

| Finding | Problem | Example |
|---|---|---|
| **H6** | Installing a package while a lease is being created is slow, can fail on the dpkg lock, and changes the host without the operator knowing. If it failed, nothing checked, and the instance was created with **no firewall**. | `unattended-upgrades` holds the dpkg lock, so the install fails, every `nft` command fails silently, and the tenant runs unprotected. |
| **M1** | The IPv6 rules went into an `ip6` table that was never created, so every command failed silently: **no IPv6 protection at all**. The rules also had no `meta skuid`, so if they had worked, they would have blocked the IPv6 LAN for **every process on the host**. | On a home host, the NAS at `2001:db8:1::50` stays reachable from any container. |
| **M2** | The "standalone" check is true on most VPS hosts (Vultr, Hetzner, DigitalOcean put the public IP on the network card), so the firewall was **skipped exactly where cloud metadata is exposed**. The "first CIDR" was often the docker bridge, not the LAN. The gateway and proxy were open on every port. | `ip route` lists `172.17.0.0/16 dev docker0` before `192.168.1.0/24 dev eth0`, so the real LAN is never blocked. The tenant can still open `http://192.168.1.1`. |
| **M3** | Dumping the whole ruleset replaced the operator's `/etc/nftables.conf` with no backup. The dump could include ufw's and Docker's tables, which get re-added at boot, so rules were duplicated. The file was rewritten on every install and uninstall. | Our test VM had a 0-byte `/etc/nftables.conf`. The last old instance's cleanup had dumped an empty ruleset over the package's default file. |

**Why he probably did it this way.** The heuristics ("local IP different from public IP means it's behind a router") fit a **home-hosted node**, the one setup where this partly works. nftables rules disappear on reboot, and dumping the whole ruleset into the system file is the quickest way to keep them.

## 4. What we changed

### The rules now live in their own script

`dependencies/user-firewall.sh <sashimono data dir> [user]` holds all the firewall logic. It follows the existing `user-cgcreate.sh` pattern, the script that re-applies per-user resource limits:

- **With a user**, it builds that user's table. `user-install.sh` calls it this way for the new instance.
- **With no user**, it builds the table for every Sashimono instance user. The boot service and the install-time refresh call it this way.

Each table is replaced in **one transaction**: either the whole new rule set is in place, or nothing changed.

### The rule set

One `inet docker_filter_<uid>` table per instance covers IPv4 and IPv6. Only packets sent by that instance's user enter its `instance` chain:

```
replies to existing connections          -> allow
DNS (53) to the host's resolvers          -> allow
host's own IPs: TCP 80, 443, instance ports; UDP instance ports -> allow
NPMplus API host:port (if configured)     -> allow
host's own IPs, any other port            -> reject
10/8, 100.64/10, 169.254/16, 172.16/12, 192.168/16, multicast, broadcast -> reject
fc00::/7, fe80::/10, ff00::/8, on-link IPv6 prefixes                     -> reject
everything else (the internet)            -> allow
```

Why each part is there:

- **No guessing.** Every private, link-local, CGNAT and multicast range is blocked on every host, whatever the routes look like. Blocking multicast also stops a tenant using UPnP to ask the router to open ports.
- **On-link IPv6 prefixes.** Home IPv6 LANs use global addresses, not private ones, so the host's own on-link prefixes are blocked too. IPv4 on-link subnets are not, because on a VPS those are public provider ranges that can hold real peers.
- **Replies instead of open IPs.** `ct state established,related` keeps inbound traffic working (NPMplus forwarding, LAN clients, router hairpin NAT) without opening the gateway or proxy to new connections.
- **The host's own addresses.** Instances on the same host reach each other through the host's address, so the instance port ranges are allowed. 80/443 are allowed for same-host websites. Everything else on the host (SSH, databases, admin ports) is rejected. This also closes a gap Gadget's version never covered: on a VPS, a tenant could reach host services that ufw hides from the internet, because local traffic bypasses ufw.
- **DNS.** Port 53 to every resolver in both `resolv.conf` files, so DNS still works when the resolver is the router.
- **NPMplus.** Only the API host and port from `proxy.npm_url`. This stays until the domain/SSL design review decides that feature's future.
- **`reject` instead of `drop`.** A blocked app fails at once instead of hanging until it times out.

### Packages (H6)

`check_dependencies()` in `sashimono-install.sh` now installs `nftables` if needed. It runs on both a fresh install and `evernode update`, so upgraded hosts get it too. `prereq.sh` only runs on fresh installs. `user-install.sh` just checks that `nft` exists, and fails with `NO_NFTABLES,INST_ERR` before creating anything if it doesn't.

### Surviving reboots (M3)

Nothing writes `/etc/nftables.conf` or enables `nftables.service` any more. Instead, a root oneshot service, `sashimono-firewall`, runs `user-firewall.sh` for all instances:

- **At boot**, after the network is online (so addresses and resolvers are known), and **before `systemd-user-sessions.service`**. Each tenant's `user@<uid>` service starts after that, so no container runs before its rules exist.
- **Whenever `nftables.service` is restarted or reloaded.** Ubuntu's default `/etc/nftables.conf` starts with `flush ruleset`, which would otherwise wipe every tenant's table.

The installer creates, upgrades and removes this service the same way as `sashimono-cgcreate`. If an update is started from an older `setup.sh` that doesn't know the service name yet, the installer scripts fall back to `sashimono-firewall`.

### Install and uninstall

- `user-install.sh` applies the new instance's table after its outbound IPv6 address is added, and rolls back with `NFT_ERR` if that fails. It then refreshes every instance's table (best-effort), so all tables know the host's current addresses.
- `user-uninstall.sh` deletes the instance's table itself. Before, this was a line in the instance's cleanup script, added by the L2 fix. That script is owned by the tenant (H4), so it shouldn't be trusted with this.
- The full uninstall's leftover sweep (from the L2 fix) now also matches `inet` tables.

## 5. How it was verified

**In isolated network namespaces** (no root, nothing on the real host touched), with the nft 0.9.3 package from Ubuntu 20.04:

- The script's single-user, all-users, invalid-user, no-argument and nft-failure paths.
- A fake LAN with IPv4 and IPv6: LAN devices, cloud metadata, the host's other ports and on-link IPv6 were rejected. Instance ports, the internet and loopback were allowed.
- Inbound TCP and UDP from a "LAN client" to the instance got their replies.
- Another user's traffic was not filtered.
- A dump, flush and reload of the ruleset gave back an identical ruleset.

**On a real Vultr VPS** (Ubuntu 20.04, ufw on iptables-legacy) running a 5-node contract:

- `nft -c` accepted the ruleset built from the host's real data: public IP, an on-link IPv6 `/64`, the systemd-resolved upstream resolvers, and 6 instance slots.
- All 5 nodes reached each other through the host's public IP and stayed in consensus, with **0 rejected packets** from normal traffic.
- Probing as a tenant's user, with root as the control:

  | Destination | Tenant | Root |
  |---|---|---|
  | Cloud metadata `169.254.169.254` | rejected | reachable |
  | Host SSH (IPv4 and IPv6) | rejected | reachable |
  | On-link IPv6 neighbour, `10.x` | rejected | (no host there) |
  | Instance peer port, internet (IPv4 and IPv6), DNS | allowed | allowed |

- `evernode delete` removed exactly that instance's table and left the others.
- `systemctl reload nftables` rebuilt every table with no gap.
- `systemctl restart nftables` flushed every table, and the service rebuilt them about 0.6 s later. ufw's rules and the contract were not affected.

**Not yet done:** a reboot, and a forced `NFT_ERR` rollback during install.

## 6. Not changed here

- **Network changes between rebuilds.** The rules are built from the host's addresses and resolvers at boot, install and nftables reload. If DHCP changes them in between, the tables catch up at the next of those.
- **`systemctl restart nftables`.** It leaves about 0.6 s without tenant rules, because nftables' own stop step flushes everything and our service can only run after it. `reload` has no gap.
- **Hosts that ran Gadget's code.** It was never released, so only dev and test hosts can still have its dumped `/etc/nftables.conf` and an enabled `nftables.service`. Both are harmless now. The full uninstall still removes Sashimono tables from that file.
- **Split DNS between hosts.** Two different Evernode hosts on the same LAN that reach each other through split DNS are still blocked. Gadget's version blocked that too.
- **The NPMplus allow.** It stays until the domain/SSL design review (C3, C4, H1).
