# Review of the "gadget78" Commits

| | |
|---|---|
| **Repository** | `sashimono` |
| **Branch reviewed** | `main.evernode-install-system-quota-bug-fix` (at `29188bb`) |
| **Commits reviewed** | 14 commits by `gadget78`, merged in PR #434 (`79506de`), June to August 2025 |
| **Review date** | 2026-10-09 |

---

## 1. Summary

Gadget's commits added several useful features to Sashimono:

- **Port mapping and environment variables for tenants.** Tenants can set these through "settings" placed inside the docker image tag.
- **A domain and SSL system.** It uses an NPMplus proxy and a custom acme.sh DNS plugin (`dns_evernode.sh`).
- **A firewall (nftables) rule set.** It stops tenant containers from reaching the host's local network (LAN).
- **Docker image caching.** It aims to avoid Docker Hub rate limits.
- **A rewrite of the disk quota and CPU/memory limit setup.**

The ideas are good, but the code went in with little review. The author's own commit message says *"this needs testing more !"*. The merged PR did not compile either: a missing header field was fixed later in `2d346ce`.

Testing did not show problems because most of the risky code only runs in special situations:

- disk quota is reported as "off"
- the host has NPMplus installed
- the tenant uses custom image settings
- the host has IPv6 enabled

### Findings by severity

| Severity | Count | Meaning |
|---|---|---|
| 🔴 Critical | 4 | Can break the host or give away secrets. Fix before the next release. |
| 🟠 High | 6 | A security weakness, or a feature that silently does not do its job. |
| 🟡 Medium | 13 | Wrong behaviour in some cases, or a reliability problem. |
| 🔵 Low | 12 | Code quality and coding-standard issues. |

### The 5 things to fix first

1. **C1.** At runtime, the install script can **corrupt `/etc/fstab`**. This was reproduced, and the host may then fail to boot. ✅ **FIXED**, see the Fix log (section 8).
2. **C2.** At runtime, the install script can **delete the disk quotas of every running instance**.
3. **C3.** The host's **wildcard TLS private key can be copied into tenant containers**.
4. **C4.** The custom-domain "authorization" check can be bypassed. A tenant can then **take over other proxy hosts on the same NPMplus**.
5. **H3.** Using any custom image setting recreates the container **without seccomp and AppArmor protection**. ✅ **FIXED**, see the Fix log (section 8).

---

## 2. Scope and method

### Commits reviewed

| Commit | Date | Message (short) | Files |
|---|---|---|---|
| `10078bb` | 2025-06-14 | Port mapping, env vars, proxy/DNS system, LAN fix (**+900 lines**) | `user-install.sh`, `dns_evernode.sh` (new), `CMakeLists.txt`, `sashimono-install.sh`, `conf.cpp` |
| `d704108` | 2025-06-14 | ".sh duplication" | `conf.cpp` |
| `9706b24` | 2025-06-15 | New cgroup method, disk quota change ("needs testing more !") | `user-install.sh` |
| `1b649b7` | 2025-06-16 | Quota in env vars | `user-install.sh` |
| `696139f` | 2025-06-19 | Quota detection, `DISK_USED`, nft persistence | `user-install.sh` |
| `169ef9d` | 2025-06-20 | fstab tweak | `user-install.sh` |
| `f302703` | 2025-06-22 | Bug fixes, skip proxy for reputation contract | `user-install.sh` |
| `a937c28` | 2025-06-30 | "better fstab sed handling" | `user-install.sh` |
| `e472bd1` | 2025-07-12 | Bug fixes, image name correction, `prereq.sh` quota change | `user-install.sh`, `dns_evernode.sh`, `prereq.sh`, `hp_manager.cpp` |
| `172407b` | 2025-07-23 | DNS resolving bug | `dns_evernode.sh` |
| `13b84cc` | 2025-07-23 | DNS TXT removal | `dns_evernode.sh` |
| `66709f5` | 2025-08-09 | Use native `docker pull` and `docker save` | `user-install.sh` |
| `9da5ea9` | 2025-08-09 | Folder creation bug | `user-install.sh` |
| `b4e7824` | 2025-08-12 | DNS check in firewall | `user-install.sh` |

### How the review was done

- All of Gadget's changes were read, and the final state of each file was compared with the version before Gadget.
- `git blame` was used so that each finding below is tied to **Gadget's own lines**, not older code.
- Where possible, issues were **reproduced**. For example, the fstab `sed` was run on sample lines, and the generated systemd unit was loaded into systemd to see the real command it runs.
- Each finding is marked with how sure we are:
  - **Verified**: reproduced with a test.
  - **Confirmed**: clear from reading the code.
  - **Likely**: strong reasoning, but needs a test on a real host to prove.

### Feasibility scale

| Feasibility | Meaning |
|---|---|
| **Easy** | Small, local change. Less than 1 day, including a quick test. |
| **Medium** | 1 to 3 days. Needs testing on a real host (ext4, cgroup v1/v2, NPMplus). |
| **Hard** | Needs a design change across the script and the C++ agent. More than 3 days. |

---

## 3. All findings at a glance

| ID | Title | Severity | Category | Sure? | Feasibility | Status |
|---|---|---|---|---|---|---|
| C1 | Runtime fstab rewrite corrupts mount options | 🔴 Critical | System safety | Verified | Easy | ✅ Fixed |
| C2 | Runtime quota reset wipes all tenants' disk quotas | 🔴 Critical | System safety | Confirmed | Easy | ✅ Fixed |
| C3 | Host wildcard TLS private key given to tenants | 🔴 Critical | Security | Confirmed | Easy | Open |
| C4 | Domain authorization can be bypassed, so a tenant can hijack proxy hosts | 🔴 Critical | Security | Confirmed | Medium | Open |
| H1 | NPMplus admin token stored in tenant-owned files | 🟠 High | Security | Verified | Medium | Open |
| H2 | Disk quota changed from group to user, which likely leaves gaps | 🟠 High | Resource limits | Likely | Medium | ✅ Fixed |
| H3 | Recreated containers run without seccomp/AppArmor | 🟠 High | Security | Confirmed | Easy | ✅ Fixed |
| H4 | Root runs a tenant-owned cleanup script on uninstall | 🟠 High | Security | Confirmed | Medium | Open |
| H5 | Code downloaded at runtime from a personal GitHub branch | 🟠 High | Security / supply chain | Confirmed | Easy | Open |
| H6 | Packages (including a kernel) installed during instance creation | 🟠 High | Operations | Confirmed | Easy | ✅ Fixed |
| M1 | IPv6 LAN rules never applied (missing table) | 🟡 Medium | Security / bug | Confirmed | Easy | ✅ Fixed |
| M2 | LAN protection is a weak heuristic | 🟡 Medium | Security | Confirmed | Medium | ✅ Fixed |
| M3 | `nft list ruleset > /etc/nftables.conf` overwrites host config | 🟡 Medium | Operations | Confirmed | Medium | ✅ Fixed |
| M4 | `docker pull` has no timeout | 🟡 Medium | Reliability | Confirmed | Easy | ✅ Fixed |
| M5 | Image cache and digest check is inconsistent | 🟡 Medium | Bug | Confirmed | Easy | ✅ Fixed |
| M6 | Race conditions in the `docker_recreate` / `docker_vars` services | 🟡 Medium | Reliability | Likely | Hard | ✅ Fixed |
| M7 | Tenant-writable `env.vars` is sourced in the host user's `.bashrc` | 🟡 Medium | Security | Confirmed | Easy | ✅ Fixed |
| M8 | Custom image settings are not validated | 🟡 Medium | Input validation | Confirmed | Easy | ✅ Fixed |
| M9 | Wrong or misleading values in `env.vars` | 🟡 Medium | Bug | Verified | Easy | ✅ Fixed |
| M10 | Cron jobs have no random delay and a wrong schedule | 🟡 Medium | Bug | Verified | Easy | Open |
| M11 | Certificate expiry check ignores the year | 🟡 Medium | Bug | Confirmed | Easy | Open |
| M12 | `dns_evernode.sh` gives up after the first nameserver | 🟡 Medium | Bug | Confirmed | Easy | Open |
| M13 | NPMplus API called with TLS checks off (`curl -k`) | 🟡 Medium | Security | Confirmed | Easy | Open |
| L1 | Missing dependencies and undocumented config keys | 🔵 Low | Standards | Confirmed | Easy | Open |
| L2 | Leaks on rollback and uninstall | 🔵 Low | Reliability | Confirmed | Easy | ✅ Fixed |
| L3 | Open-file limit change may lower limits on big hosts | 🔵 Low | Behaviour change | Likely | Easy | Open |
| L4 | Dead code, unused variables, debug leftovers | 🔵 Low | Code quality | Confirmed | Easy | 🟡 Partly fixed (`dns_evernode_sh`, plus 2 items via M4/M5) |
| L5 | Copy-paste errors and typos in messages | 🔵 Low | Code quality | Confirmed | Easy | ✅ Fixed |
| L6 | Repeated code blocks | 🔵 Low | Code quality | Confirmed | Easy | ✅ Fixed |
| L7 | Scripts generated through 3 to 4 levels of escaping | 🔵 Low | Maintainability | Confirmed | Medium | Open |
| L8 | Weak error handling patterns | 🔵 Low | Code quality | Confirmed | Easy | Open |
| L9 | Hard-coded paths, URLs and DNS servers | 🔵 Low | Standards | Confirmed | Easy | ✅ Fixed |
| L10 | Unquoted variables and other shell style issues | 🔵 Low | Standards | Confirmed | Easy | Open |
| L11 | C++ `--` stripping is undocumented and loose | 🔵 Low | Code quality | Confirmed | Easy | ✅ Fixed |
| L12 | Process: huge mixed commits, no build check, no tests | 🔵 Low | Process | Confirmed | Easy | Open |

---

## 4. Detailed findings

### 🔴 Critical

#### C1. Runtime fstab rewrite corrupts mount options (Verified), ✅ FIXED

- **Where:** [user-install.sh:170-194](dependencies/user-install.sh#L170-L194). Commits `696139f`, `a937c28`, `169ef9d`.
- **What happens:** If user quota is reported as "off", the install script edits `/etc/fstab` itself. Its last `sed` rule, `s/(\s+)([^,\s]+),/\1\2/`, is meant to clean up a stray comma. Instead it **deletes the first comma in the mount options**. Inside `[...]`, `\s` does not mean "whitespace"; it means the characters `\` and `s`.
- **Proof** (running the exact `sed` on sample lines):

  | Original options | After the script |
  |---|---|
  | `rw,relatime` | `rwrelatime,usrquota` ❌ |
  | `noatime,errors=remount-ro` | `noatimeerrors=remount-ro,usrquota` ❌ |
  | `discard,errors=remount-ro` | `discard,errors=remount-ro,usrquota` ✅ (lucky: `discard` contains an `s`) |

- **Why it matters:** An invalid option makes `mount -o remount /` fail. At the next reboot the root filesystem may not mount, and the host goes to emergency mode. This is done to a live production host during a tenant lease.
- **Fix:** Remove all fstab editing from `user-install.sh`. Configuring fstab is the job of `prereq.sh`, which was already rewritten safely on this branch (`3e493a4`). If quota is off at instance creation, the script should **fail with a clear error** (for example `QUOTA_ERR,INST_ERR`) and not try to repair the host.
- **Feasibility:** Easy. This mostly deletes code.

#### C2. Runtime quota reset wipes all tenants' disk quotas (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:195-204](dependencies/user-install.sh#L195-L204). Commits `9706b24`, `1b649b7`.
- **What happens:** In the same "quota is off" path, the script runs `rm -f /quota.* /aquota.*` and then `quotacheck -cum /`. The `aquota.user` file holds the **limits of every user on the host**. Deleting it removes the disk limits of every running instance. Only the new instance gets a limit again (line 206).
- **Extra problems:**
  - `quotacheck` scans the whole live root filesystem, which can take minutes on big disks while instance creation waits.
  - Every failure is ignored (`|| echo "something failed..."`).
- **When it triggers:** After a reboot where quota did not turn on, for example when a kernel module is missing. In that case it runs on **every** new instance.
- **Fix:** Same as C1. Never delete quota files from `user-install.sh`. At most, try `quotaon -u /`, and if that fails, stop with an error.
- **Feasibility:** Easy.

#### C3. Host wildcard TLS private key given to tenants (Confirmed)

- **Where:** The generated `domain_ssl_update.sh`, written by [user-install.sh:726-740](dependencies/user-install.sh#L726-L740) and [user-install.sh:827-841](dependencies/user-install.sh#L827-L841). Commit `10078bb`.
- **What happens:** For the default domain (`<host>-<slot>.<parent-domain>`), the script looks in NPMplus for a certificate. If it finds none for that exact name, it uses the **wildcard certificate `*.<parent-domain>`**. It downloads the certificate zip, which includes the private key, and unzips it into `<contract_dir>/tls/`. The contract directory is mounted into the tenant's container as `/contract`.
- **Why it matters:** On hosts where NPMplus holds a wildcard certificate, **every tenant gets the private key for the operator's whole domain**. They can use it to pretend to be any subdomain, including other tenants and the host's own services.
- **Fix:**
  - Never download wildcard certificates into tenant folders.
  - Better: tenants do not need the key at all. Let NPMplus end TLS and forward plain HTTP to the container, or only hand out certificates issued for that one instance's domain.
- **Feasibility:** Easy to stop the leak (skip the wildcard case). Medium to redesign properly.

#### C4. Domain authorization can be bypassed, so a tenant can hijack proxy hosts (Confirmed)

- **Where:** [user-install.sh:680-693](dependencies/user-install.sh#L680-L693) (check), [user-install.sh:870-880](dependencies/user-install.sh#L870-L880) (update). Commit `10078bb`.
- **What happens:**
  1. The "authorization" reads the expected key from `contract.bin_args` in `<contract_dir>/cfg/hp.cfg`. **The tenant can write to that file**, because it is inside the mounted `/contract` folder. The check also runs again weekly from cron, so later changes count too.
  2. The check is `grep -q "$contract_publickey"`. If `bin_args` is empty, the pattern matches everything. If it is `.`, it also matches everything.
  3. If a proxy host for that domain **already exists** in NPMplus, the script **updates it** to forward to this tenant's port. It does not check who created it.
- **Why it matters:** A tenant can point another tenant's domain, or the operator's own site on the same NPMplus, to their own container. This is a domain hijack.
- **Fix:**
  - Take the owner public key from a trusted source: the Sashimono agent passes it in, or it is read from the agent's database. Never read it from a tenant-writable file.
  - Compare whole TXT values exactly (`grep -qxF`), not as a regex substring.
  - Only update proxy hosts this instance created. Save the NPMplus IDs at creation time in a root-owned file.
- **Feasibility:** Medium.

### 🟠 High

#### H1. NPMplus admin token stored in tenant-owned files (Verified)

- **Where:** [user-install.sh:700-701](dependencies/user-install.sh#L700-L701), plus the `echo "curl ... Bearer \$NPM_TOKEN ..." >> $cleanup_script` lines (813, 824, 840, 866, 876).
- **What happens:** `NPM_URL` and `NPM_TOKEN` use `$(...)` without escaping inside an unquoted heredoc. So they are filled in **at install time by root**, and the **real token is written in plain text** into `/home/<user>/.docker/domain_ssl_update.sh`, which is `chown`ed to the tenant user. Rendering the template with a fake token confirmed this: line 45 of the output is `NPM_TOKEN="SECRET_TOKEN_123"`. The same token is also written into `uninstall_cleanup.sh`.
- **Why it matters:** This token can manage every proxy host and certificate on the NPMplus server. Any code running as the tenant's host user can read it.
- **Fix:** Do not run the NPMplus logic as the tenant user. Move it to a root-owned service, or to the agent or `mb-xrpl`, that reads the token from a root-only file when needed.
- **Feasibility:** Medium.

#### H2. Disk quota changed from group to user, which likely leaves gaps (Likely), ✅ FIXED

- **Where:** [user-install.sh:206](dependencies/user-install.sh#L206) (`setquota -u`), `prereq.sh` (commit `e472bd1`), and [user-uninstall.sh:99](dependencies/user-uninstall.sh#L99), which still runs `setquota -g`.
- **What happens:**
  - Before Gadget, the quota was a **group** quota on the instance user's group. The original code says the contract gid is always 0. Inside the rootless container, gid 0 maps to that user's group, so files written by **any** process in the container counted toward the limit. That includes the contract user (`<user>-secuser`) and non-root container users.
  - Gadget switched to a **user** quota. That only counts files owned by the main user's uid. Files owned by the contract user or other mapped uids are **likely no longer counted**, so a tenant could fill the host disk.
- **Other problems:**
  - Uninstall still clears the **group** quota, so the user quota entry is never removed.
  - A failed `setquota` is only printed (`|| echo "Configuring disk quota failed"`), so the instance is created **with no disk limit**.
- **How to confirm:** Inside a test instance, write a large file as a non-root container user (or as the contract). Then check `repquota -u /` and `repquota -g /`.
- **Fix:**
  - `usrquota` and `grpquota` (the non-journaled forms) can be used together. Enable both in `prereq.sh`. Note that this branch's `prereq.sh` currently removes `grpquota`, so revisit that.
  - Set the **group** quota as before (optionally the user quota as well).
  - Make a `setquota` failure stop the install with an error.
  - Make uninstall clear the same quota type that install set.
- **Feasibility:** Medium (needs testing on ext4 and XFS hosts).

#### H3. Recreated containers run without seccomp/AppArmor (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:983-984](dependencies/user-install.sh#L983-L984), inside the generated `docker_recreate.sh`.
- **What happens:** If the image tag has **any** custom setting (for example `--peer--1234`), the container that Sashimono created is deleted. A new one is created with `--security-opt seccomp=unconfined --security-opt apparmor=unconfined`. The agent's own `DOCKER_CREATE` command ([hp_manager.cpp:34](src/hp_manager.cpp#L34)) does **not** use these options.
- **Why it matters:** Any tenant can turn off two kernel-level sandboxes just by adding a setting to the image name. This makes container-escape exploits much easier.
- **Fix:** Remove both options and copy the agent's create options exactly.
- **Feasibility:** Easy.

#### H4. Root runs a tenant-owned cleanup script on uninstall (Confirmed)

- **Where:** [user-install.sh:1045](dependencies/user-install.sh#L1045) and [user-install.sh:1095](dependencies/user-install.sh#L1095) (`chown -R $user:$user $cleanup_script`), and [user-uninstall.sh:158-162](dependencies/user-uninstall.sh#L158-L162) (root runs it).
- **What happens:** `uninstall_cleanup.sh` is now owned by the tenant user, because their cron job adds lines to it. Root runs it during uninstall. Any code running as that host user can add commands, and **those commands then run as root**. (The script was already inside the user's home before Gadget, which was a weakness already. Making the user its owner, and making tenant-run scripts write to it, makes it worse.)
- **Fix:** Keep cleanup scripts outside the user's home, for example in `/var/lib/sashimono/cleanup/<user>.sh`, owned by root, with mode 600. Tenant-run scripts must not write to them. Save the NPMplus IDs as data, not as commands.
- **Feasibility:** Medium.

#### H5. Code downloaded at runtime from a personal GitHub branch (Confirmed)

- **Where:** [user-install.sh:56-57](dependencies/user-install.sh#L56-L57) and [user-install.sh:637-648](dependencies/user-install.sh#L637-L648).
- **What happens:**
  - If missing, `dns_evernode.sh` is downloaded from `raw.githubusercontent.com/gadget78/sashimono/main/...`, a **personal fork and a moving branch**. It is copied into `/usr/bin/sashimono` and `/root/.acme.sh`.
  - `acme.sh` is downloaded from the **`master` branch**.
  - There is no checksum and no fixed version.
- **Why it matters:** Whoever controls that GitHub account or branch can run code on every Evernode host that uses this feature. Also, `dns_evernode.sh` is already shipped by the installer ([sashimono-install.sh:499](installer/sashimono-install.sh#L499)), so the download is not needed.
- **Fix:** Remove the download fallback for `dns_evernode.sh`. Ship a fixed `acme.sh` version with the installer and check its SHA-256. Use `$script_dir` instead of hard-coded paths.
- **Feasibility:** Easy.

#### H6. Packages (including a kernel) installed during instance creation (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:157-168](dependencies/user-install.sh#L157-L168) (`linux-image-extra-virtual`) and [user-install.sh:434-438](dependencies/user-install.sh#L434-L438) (`nftables`).
- **What happens:** While a lease is being created, the script may run `apt-get update` and install a **kernel package**. A kernel needs a reboot before it takes effect, so it does not help this install. It also slows creation down, can fail on the dpkg lock (unattended-upgrades), and changes production hosts without the operator knowing. A leftover debug line prints `"do we need to reboot ?"`.
- **Fix:** Move all package installs to `prereq.sh`. In `user-install.sh`, only check that the needed tools exist, and fail clearly if they do not.
- **Feasibility:** Easy.

### 🟡 Medium

#### M1. IPv6 LAN rules never applied (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:514-520](dependencies/user-install.sh#L514-L520).
- **What happens:** The rules are added to `ip6 docker_filter_<uid>`, but only the `ip` (IPv4) table is ever created (line 446). The commands fail and the error is ignored, so **no IPv6 protection exists**. Also:
  - These rules have no `meta skuid` match. If they did work, they would block the whole host's IPv6 subnet for every process.
  - Cleanup only removes the IPv4 table.
- **Fix:** Create an `ip6` table and chain, add `meta skuid $user_id` to the rules, and clean both tables. (Or use one `inet` table for both IPv4 and IPv6.)
- **Feasibility:** Easy.

#### M2. LAN protection is a weak heuristic (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:440-489](dependencies/user-install.sh#L440-L489).
- **Problems:**
  - It is **skipped completely** when the first local IP equals the public DNS IP. That is the normal cloud VPS case, where private VPC networks and the cloud **metadata service `169.254.169.254`** stay reachable.
  - It blocks only **the first CIDR** from `ip route`, which might be `docker0` or a VPN route rather than the LAN.
  - It allows the **gateway**, the **proxy host** and the **host's own LAN IP** on **all ports**. That includes router admin pages and the NPMplus admin port.
  - If there are several default routes, a list of IPs goes into one `nft` command, and that command fails.
  - The DNS check (`b4e7824`) compares only the first two octets of the IP.
- **Fix:** By default, block all private and link-local ranges: `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `fc00::/7`, `fe80::/10`. Then allow only what is needed, for example port 53 to the configured resolver.
- **Feasibility:** Medium.

#### M3. `nft list ruleset > /etc/nftables.conf` overwrites host config (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:1125-1127](dependencies/user-install.sh#L1125-L1127) and the cleanup lines 1043 and 1093.
- **What happens:**
  - It replaces the operator's `/etc/nftables.conf` with no backup.
  - On Ubuntu, `ufw` uses the iptables-nft backend, so the dump also contains **ufw's own tables**. At boot, `nftables.service` loads them, then ufw adds its rules again, giving duplicate or conflicting rules.
  - The dump has no `flush ruleset` line at the top.
- **Fix:** Save only Sashimono's tables, in their own file (for example `/etc/nftables.d/sashimono-<uid>.nft`), and include that file. Or rebuild the rules at boot from the agent's database.
- **Feasibility:** Medium.

#### M4. `docker pull` has no timeout (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:556](dependencies/user-install.sh#L556) and [user-install.sh:579](dependencies/user-install.sh#L579).
- **What happens:** `docker_pull_timeout_secs=180` is defined but never used. A stuck pull, the same "frozen download" problem commit `66709f5` tried to fix, blocks `user-install.sh` forever. The agent reads its output with `popen`, so the agent waits too.
- **Fix:** `timeout --foreground -s SIGINT "${docker_pull_timeout_secs}s" docker pull ... || rollback "DOCKER_PULL"`.
- **Feasibility:** Easy.

#### M5. Image cache and digest check is inconsistent (Confirmed), ✅ FIXED (Docker Hub URLs in L9, the rest in M4/M5)

- **Where:** [user-install.sh:543-595](dependencies/user-install.sh#L543-L595).
- **Problems:**
  - The first pull writes the digest to `<image>.tar.image_digest`, but the later check reads `<image>/image_digest`, a **different file**. So the second instance always pulls again.
  - `mkdir -p $img_local_path` (commit `9da5ea9`) means `[[ ! -d $img_local_path ]]` is never true. It also leaves empty folders behind. Only the parent folder was needed.
  - If the digests differ but the rate limit is low, the **old image is loaded**, and the log wrongly says "File hash matches docker hub".
  - The Docker Hub URLs are hard-coded:
    - Official images (`ubuntu:22.04`, which is `library/ubuntu` on Docker Hub) get the wrong token scope.
    - Images from other registries are checked against Docker Hub.
    - The configured private registry mirror is ignored.
  - If two instances use the same image at the same time, both `docker save` to the same `.tar`.
- **Fix:** Use one digest file. Compare digests with `docker manifest inspect` or the local `RepoDigests`. Respect the registry setting. Use a lock (`flock`) around save and load.
- **Feasibility:** Easy to Medium.

#### M6. Race conditions in the `docker_recreate` / `docker_vars` services (Likely), ✅ FIXED

- **Where:** [user-install.sh:1009-1038](dependencies/user-install.sh#L1009-L1038) and [user-install.sh:1062-1088](dependencies/user-install.sh#L1062-L1088).
- **What happens:**
  - The ports, env file, cron jobs and domain setup only happen when these services catch the **first `docker create` event**. The service starts just before `user-install.sh` exits. If `docker events` is not connected yet when the agent runs `docker create`, the event is missed and **nothing is set up**, with no error.
  - `docker_recreate.sh` stops and removes the agent's container while the agent may be calling `docker start` on it ([hp_manager.cpp:291](src/hp_manager.cpp#L291)), so the start can fail.
  - It only copies `Mounts[0]`.
  - It runs `docker ps` before it sets `DOCKER_HOST`, so it depends on the docker context.
- **Fix (proper):** Build the port mapping and `--env-file` into the agent's own `DOCKER_CREATE` command in C++. `user-install.sh` can write the parsed settings to a file that `hp_manager.cpp` reads. Then no "watch and recreate" service is needed.
- **Feasibility:** Hard (design change), but it removes a lot of fragile code.

#### M7. Tenant-writable `env.vars` is sourced in the host user's `.bashrc` (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:338-339](dependencies/user-install.sh#L338-L339).
- **What happens:** `.bashrc` runs `source <contract_dir>/env.vars`. That file is inside `/contract`, which the tenant can write to from the container. Anyone who opens an interactive shell as that user, such as an operator debugging with `sudo -u sashiXXX bash`, runs the **tenant's code on the host**. The `/contract/env.vars` line does nothing on the host, because that path only exists inside the container.
- **Fix:** Remove both `source` lines.
- **Feasibility:** Easy.

#### M8. Custom image settings are not validated (Confirmed), ✅ FIXED

- **Where:** [user-install.sh:208-320](dependencies/user-install.sh#L208-L320) and [hp_manager.cpp:205-208](src/hp_manager.cpp#L205-L208).
- **What happens:**
  - Port values, domains and env keys come from the tenant and are **never checked**. A port like `abc` or `99999` is accepted.
  - The values are later used in `$(( ))` arithmetic, unquoted commands, heredocs and JSON built by string joins. Today this is safe **only by accident**: `docker tag` (line 598) fails on characters that are not valid in a tag.
  - Without that line, this is a root command injection: a port setting such as `x[$(cmd)]` runs `cmd` as root at `$((internal_gptcp1_port + 1))` in the `env.vars` heredoc (verified with a harmless payload on 2026-10-14). So the tag line must stay until this fix adds real validation (see the L4 fix log entry). **Remove it as part of this fix.**
  - `cut -d':' -f2` breaks for registries with a port (`host:5000/img:tag`) and for digest references (`img@sha256:...`).
- **Fix:** Validate early and stop with `INVALID_PARAMS,INST_ERR`:
  - ports must be in 1-65535
  - domains must match a domain regex
  - env keys must match `^[A-Za-z_][A-Za-z0-9_]*$`

  Split on the **last** `:` only.
- **Feasibility:** Easy.

#### M9. Wrong or misleading values in `env.vars` (Verified), ✅ FIXED

- **Where:** [user-install.sh:917-942](dependencies/user-install.sh#L917-L942) and the quota cron at line 1005.
- **Problems:**
  - `INTERNAL_GPTCP2_PORT=$((internal_gptcp1_port + 1))` ignores a `gptcp2` value the tenant set. The same is true for `GPUDP2`.
  - `docker --env-file` **does not remove quotes or expand anything**. Inside the container:
    - `RAM_QUOTA` is `"2GB"`, with the quote characters.
    - `DISK_USED` is the literal text `$(( DISK_USED_BYTES / 1024 / 1024 ))GB`.
  - The `*_BYTES` values are really **KiB** (both `setquota` and `quota` use 1K blocks).
  - Over the soft limit, `quota` prints `51234*`. The cron job stores that value (verified), and shell arithmetic on it then fails.
  - Whole-GB rounding shows `0GB` for anything under 1 GB.
  - The dummy `KEY1=1` … `KEY4=4` are added to every container.
- **Fix:**
  - Use `internal_gptcp2_port` and `internal_gpudp2_port`.
  - Write plain `KEY=value` lines with no quotes and no shell expressions.
  - Rename to `*_KB`, or multiply by 1024.
  - Strip `*`.
  - Only write the env keys the tenant actually set.
- **Feasibility:** Easy.

#### M10. Cron jobs have no random delay and a wrong schedule (Verified)

- **Where:** [user-install.sh:1006](dependencies/user-install.sh#L1006) and [user-install.sh:1054](dependencies/user-install.sh#L1054).
- **Problems:**
  - Cron runs commands with `/bin/sh` (dash), which has **no `$RANDOM`**. `sleep $((RANDOM*3540/32768))` always becomes `sleep 0` (verified). So every instance on every host runs at exactly 00:00, all calling Let's Encrypt and NPMplus at once.
  - `*/7` in the day-of-month field means days 1, 8, 15, 22 and 29, not "every 7 days".
  - In the custom-settings path, the cron job is added even when NPMplus is not installed. It then runs a script that does not exist.
- **Fix:** Choose the random minute and hour at install time and write fixed numbers into the crontab. Use a day-of-week field (for example `M H * * 3`). Only add the job when the script exists.
- **Feasibility:** Easy.

#### M11. Certificate expiry check ignores the year (Confirmed)

- **Where:** [user-install.sh:734-750](dependencies/user-install.sh#L734-L750).
- **What happens:** It compares only the **month** of `expires_on` with the current month. In October, a certificate that expires next January (`01 ≤ 10`) is treated as "expiring", so it is reissued every week with `--force`. In other cases, a renewal may happen too late.
- **Fix:** Compare full dates. For example, renew if `$(date -d "$NPM_CERT_EXPIRE" +%s)` is less than now plus 30 days.
- **Feasibility:** Easy.

#### M12. `dns_evernode.sh` gives up after the first nameserver (Confirmed)

- **Where:** [dns_evernode.sh:88-96](dependencies/dns_evernode.sh#L88-L96) and [dns_evernode.sh:186-194](dependencies/dns_evernode.sh#L186-L194).
- **What happens:** The comment says *"as long as one works the script will continue"*. But after the **first** nameserver that answers, the function returns 1 if its API calls failed, without trying the other nameservers. Also:
  - Zone detection uses `dig +trace | ... | tail -n1`, which is fragile. Looking up the SOA record is the standard method.
  - About 95 lines are copied between `_add` and `_rm`.
  - `_rm` prints the wrong message ("setting any TXT records").
- **Fix:** Replace the `else return 1` with `continue`. Move the shared logic into one helper with an `addtxt`/`rmtxt` argument. Use a SOA lookup to find the zone.
- **Feasibility:** Easy.

#### M13. NPMplus API called with TLS checks off (Confirmed)

- **Where:** Every `curl -k` call in the generated `domain_ssl_update.sh`.
- **What happens:** The admin token is sent without checking the server certificate. If NPMplus runs on another machine (`proxy.ip`), anyone on the network path can steal the token.
- **Fix:** Use a proper certificate or a pinned CA (`--cacert`). Allow `-k` only for `localhost`.
- **Feasibility:** Easy.

### 🔵 Low (code quality and standards)

#### L1. Missing dependencies and undocumented config keys

- The new code needs `dig`, `unzip`, `wget`, `cron`, `nftables` and `jq`, but `prereq.sh` does not install them. (`jq` is listed only in a comment.)
- It reads `mb-xrpl.cfg` keys that **nothing in this repo creates or documents**:
  - `proxy.tls_type`
  - `proxy.npm_url`
  - `proxy.npm_tokenPath`
  - `proxy.blacklist`
  - `proxy.ip`
- They come from outside tooling, so the feature is hidden and untested on standard installs.
- **Fix:** Add the packages to `prereq.sh`, and document the config keys (or add them to the installer). **Easy.**

#### L2. Leaks on rollback and uninstall, ✅ FIXED

- The nft table is created at line 446, but its cleanup commands are only registered at the end (lines 1042 and 1092). A rollback in between (for example `DOCKER_PULL`) leaves the table behind.
- The cleanup script tries to stop user systemd services after `user-uninstall.sh` has already killed the user's processes, so those lines do nothing.
- `sashimono-uninstall.sh` never removes:
  - Sashimono's lines in `/etc/nftables.conf`
  - `/root/.acme.sh/dns_evernode.sh`
  - `/root/domain_ssl_update.log` (this log only grows)
- **Fix:** Register cleanup steps right after each resource is created, and extend the full uninstall. **Easy.**

#### L3. Open-file limit change may lower limits on big hosts

- [user-install.sh:95-112](dependencies/user-install.sh#L95-L112) now sets the per-instance `nofile` limit to `250000 / (max_instance_count + 1)`. With 100 instances that is about 2,475 open files per instance, which may be too low for HotPocket plus dockerd.
- **Fix:** Set a sensible minimum (for example `max(computed, 65536)`) and test. **Easy.**

#### L4. Dead code, unused variables, debug leftovers, 🟡 PARTLY FIXED (see the L4 fix log entry)

- `ctx.dns_evernode_sh` ([conf.cpp:119](src/conf.cpp#L119)) is **never used**. Adding it without the header broke the build until `2d346ce`, and commit `d704108` was a typo fix (`.sh.sh`) for it. ✅ Removed.
- `docker_pull_timeout_secs` is unused (see M4). ✅ Now used by the M4 fix.
- Old pull code is left commented out (lines 550-555, 565, 578). ✅ Removed by the M4/M5 fix.
- The `/root/.acme.sh/dns_evernode.sh` copy is never used. Open.
- `docker tag ${docker_pull_image} ${docker_image}` (line 598) is no longer needed, because `hp_manager.cpp` now strips the settings before `docker create`. It can also cause a rollback if the full tag is over 128 characters. **Must stay until M8 is fixed:** it is the only check that stops unsafe characters in the settings (see M8).
- The `version=` variable was bumped by hand (`0.99` → `1.9`) and has no link to releases. Open.
- **Easy.**

#### L5. Copy-paste errors and typos in messages, ✅ FIXED

- `env2`, `env3` and `env4` all print "found env1".
- Typos: "intalled", "farwading", "pubic key", "settig", "unpriviledged".
- Misleading log text: "File hash matches docker hub, AND the Rate limit result is above 60", printed when either condition is false.
- **Easy.**

#### L6. Repeated code blocks, ✅ FIXED

- 14 nearly identical `if` blocks parse the settings. One `case` statement would do.
- The 4 env parsing blocks are copies of each other.
- The quota cron strings are defined twice (lines 1003-1005 and 1049-1051).
- The certificate download, unzip and rename block appears twice (803-820 and 830-845).
- The cleanup lines are repeated in both branches.
- **Easy** to turn into small functions.

#### L7. Scripts generated through 3 to 4 levels of escaping

- `domain_ssl_update.sh`, `docker_recreate.sh` and the systemd units are built with unquoted heredocs that contain cron lines inside `bash -c` inside `ExecStart` (for example `awk ''\'NR==3 {print \\\\\$2}''\'`).
- Testing showed the final output is currently correct, but almost nobody can safely review or change it.
- **Fix:** Ship these as **static template files** with the installer, and pass values through an env file or arguments. **Medium.**

#### L8. Weak error handling patterns

- `{ ... } || { rollback }` only reacts to the **last** command in the group (lines 170-204). If the backup `cp` or the first `sed` fails, this goes unnoticed. The fallback may also use `$BACKUP` before it has been set.
- Many `|| true`, `2>/dev/null` and `|| echo "..."` hide real failures (quota, nft, apt).
- **Fix:** Check each critical command, and roll back or stop on failure. **Easy.**

#### L9. Hard-coded paths, URLs and DNS servers, ✅ FIXED

- `/usr/bin/sashimono/...` is used instead of `$script_dir`.
- Docker Hub URLs are hard-coded.
- DNS servers `@8.8.8.8` (dns plugin) and `@1.1.1.1` (TXT check) are hard-coded and differ from each other. Networks that block outside DNS will fail.
- The proxy forwards to the first `hostname -I` address, with `https`, always on `gptcp1`.
- A `www.` alias is added even to generated subdomains, but the certificate does not cover it.
- **Easy.**

#### L10. Unquoted variables and other shell style issues

- Examples: `echo $docker_image` (line 211), `$docker_create_command ${IMAGE}` run by word splitting, unquoted paths in `mkdir`, `chown`, `cp`, and mixed `[ ]` and `[[ ]]`.
- There was no `shellcheck` run, and none is set up in the repo.
- **Fix:** Add `shellcheck` to CI and fix the warnings. **Easy.**

#### L11. C++ `--` stripping is undocumented and loose, ✅ FIXED

- [hp_manager.cpp:205-208](src/hp_manager.cpp#L205-L208) cuts the image name at the **first `--` anywhere**, including in the repository part.
- There is no comment explaining the `--` convention, and no check for an empty result (for example an image name that starts with `--`).
- **Fix:** Strip only inside the tag (after the last `:`), add a comment, and reject an empty result. **Easy.**

#### L12. Process: huge mixed commits, no build check, no tests

- `10078bb` mixes 5 features in more than 900 lines.
- Messages like "couple more bugs found and fixed" do not explain the changes.
- The merged PR did not compile.
- There are no tests for any of the new behaviour.
- **Fix:** Require CI (build + shellcheck), smaller PRs, and a test checklist for script changes (ext4/XFS, cgroup v1/v2, IPv6, NPMplus on/off). **Easy** to adopt.

---

## 5. Already fixed on this branch

These problems came from Gadget's commits and are **already fixed** by the recent commits on `main.evernode-install-system-quota-bug-fix`:

| Problem (from Gadget's commit) | Fixed in |
|---|---|
| `prereq.sh` checked for `/aquota.group` but created `aquota.user`, so the check never matched; dead commented-out `jqfmt` block (`e472bd1`) | `3e493a4` |
| `prereq.sh` fstab edit could leave journaled and normal quota options mixed, so ext4 refuses to mount | `3e493a4` |
| The cgroup v1 `cgcreate` limits were replaced by a systemd slice that has no effect on cgroup v1 hosts (`9706b24`) | `855ecc4`, `29188bb` |
| `MemorySwapMax` was given "memory + swap" (cgroup v1 meaning) instead of swap only; `CPUQuota` could be 0%; `mkdir` without `-p` | `855ecc4` |
| Missing `dns_evernode_sh` in `conf.hpp` broke the build; C++ brace style | `2d346ce` (#436) |

Still open from the same area: uninstall clears the **group** quota while install sets a **user** quota (part of H2). _(Now resolved, see the Fix log, section 8.)_

---

## 6. Recommended plan

| Phase | Goal | Items | Feasibility |
|---|---|---|---|
| **1. Stop the bleeding** (1-2 days) | Remove host-breaking and sandbox-weakening code | C1, C2, H3, H5, H6, M4, M7, M1 | All Easy |
| **2. Secure or switch off the domain/SSL feature** | No secrets or keys reach tenants; no domain hijack | C3, C4, H1, H4, M13. Until this is done, put the NPMplus path behind a config flag that is **off by default**. | Easy (flag) / Medium (fix) |
| **3. Make resource limits and the firewall correct** | Quota covers everything; firewall is predictable | H2, M2, M3, L2 | Medium |
| **4. Simplify the design** | Remove fragile "watch and recreate" logic | M6 (move port and env mapping into `hp_manager.cpp`), M5, M8, L7 | Hard |
| **5. Clean up** | Code standards | M9-M12, L1, L3-L6, L8-L12, plus `shellcheck` in CI | Easy |

---

## 7. Open questions for the team

1. **Is the custom-domain / NPMplus feature officially supported?** Its config keys are not created by this repo's installer. If it is not supported, putting it behind a flag (or removing it) is the fastest and safest choice.
2. **H2 needs a short test on a real host** to confirm how big the quota gap is. See "How to confirm" under H2.
3. **Should tenants get TLS keys at all?** Ending TLS at NPMplus and forwarding HTTP would remove C3 and most of H1.

---

## 8. Fix log

This section records fixes applied after the review above was written. The findings themselves (sections 3 and 4) are left as originally written and only marked with a Status; this log is the source of truth for what actually changed, where, and why.

### 2026-10-09: C1, C2, H6 fixed (fstab/quota runtime repair removed)

- **Findings closed:** C1, C2, H6.
- **Files changed:** `dependencies/user-install.sh`.
- **What changed:** The entire "quota is off" runtime-repair block (the buggy fstab `sed` edit, the `rm -f /quota.* /aquota.*` wipe, and the `linux-image-extra-virtual` kernel package install) was deleted and replaced with a single `rollback "QUOTA_OFF"` call. If quota is off when an instance is being created, the script now fails that one instance creation cleanly instead of attempting to repair the host live.
- **Why:** C1's `sed` command corrupted mount options (confirmed by reproducing it on sample fstab lines) and could leave the host unable to boot. C2 and H6 were only reachable through this same block, so removing it closes all three at once. Fixing fstab/quota at the host level remains `installer/prereq.sh`'s job, which already does this safely (backs up fstab, checks the remount result, and tells the operator to reboot if journaled quota options are still active).
- **Not changed:** the `setquota` failure handling on the line right after this block (it still only logs a failure instead of stopping the install); that is part of H2's scope and is covered below.

### 2026-10-09: H2 fixed (quota mechanism switched back to group quota)

- **Findings closed:** H2, and the "install sets user quota, uninstall clears group quota" mismatch noted in section 5.
- **Files changed:** `installer/prereq.sh`, `dependencies/user-install.sh`.
- **What changed:**
  - `installer/prereq.sh` now configures the root filesystem with `grpquota` (plain, non-journaled) instead of `usrquota`, and checks/enables group quota (`quotacheck -cgm`, `quotaon -g`) instead of user quota.
  - `dependencies/user-install.sh` now checks `quotaon -p / | grep group` (was `grep user`) to decide if quota is off, and sets the tenant's limit with `setquota -g -F vfsv0 "$user" ...` (was `setquota -u "$user" ...`).
  - The per-tenant cron job that reports live disk usage back into the container (`DISK_USED_BYTES` in `env.vars`) was changed from `quota -u '${user}'` to `quota -g '${user}'`, so it reports the same quota type that is actually being enforced. This works as a direct substitution because each tenant's private Linux group has the same name as the tenant's own username.
  - `dependencies/user-uninstall.sh` and `installer/setup.sh` were not changed. Both already used `setquota -g -F vfsv0` and had never been touched by Gadget's commits; they were the reference for what the install side should have kept matching all along.
- **Why:** a tenant's container can run more than one internal identity (the main process and a separate "contract user" process), and both map onto the same private Linux group on the host. Group quota counts every identity in that group against one shared limit. User quota only counts the one identity it is set for, so a tenant could exceed their real disk allowance through the identity that was never being measured.
- **Deliberately not done:** keeping a second `setquota -u` limit alongside the group limit, as a "belt and suspenders" measure, was considered and rejected. Two quota mechanisms that both need to be kept in sync between install and uninstall is exactly the condition that caused this bug in the first place.

A fuller explanation of this whole area, written for someone with no quota/fstab background, is in `changes/[C1, C2, H2, H6] Disk quota and fstab history explained.md`.

### 2026-10-12: H3 fixed (seccomp/AppArmor no longer disabled on recreated containers)

- **Findings closed:** H3.
- **Files changed:** `dependencies/user-install.sh`.
- **What changed:** In the generated `docker_recreate.sh`, the `--security-opt seccomp=unconfined --security-opt apparmor=unconfined` line (and its comment) was deleted. Recreated containers now get Docker's default seccomp and AppArmor profiles, the same as the agent's own `DOCKER_CREATE` in `src/hp_manager.cpp`.
- **Why:** Any custom image setting caused the container to be recreated with both protections off, so any tenant could switch off the kernel syscall filter just by adding a setting to the image name. An image cannot request these options itself, so removing the line is enough; no detection or blocking logic is needed.
- **Not changed:** Instances created before this fix with custom settings keep running unconfined until they are redeployed. Other differences between the recreated and the agent's container belong to M6.

A fuller explanation is in `changes/[H3] Seccomp and AppArmor disabled on recreated containers.md`.
A fuller explanation of this whole area, written for someone with no quota/fstab background, is in `quota-and-fstab-history-explained.md` in this same folder.

### 2026-10-12: L5 fixed (copy-paste errors and typos in messages)

- **Findings closed:** L5.
- **Files changed:** `dependencies/user-install.sh` (10 lines, text only).
- **What changed:**
  - The env2, env3 and env4 parsing blocks now print `found env2`, `found env3` and `found env4`. Before, all of them printed `found env1`.
  - Typos fixed:
    - `unpriviledged` → `unprivileged` (2 comments)
    - `pubic key` → `public key` (2 log lines in the generated `domain_ssl_update.sh`)
    - `farwading` → `forwarding` (install log)
    - `intalled` → `installed` (text in the cron job string)
  - The image-cache `else` branch printed "File hash matches docker hub, AND the Rate limit result is above 60" even though it also runs when the digest differs but the rate limit is too low or unknown. It now prints `Using cached image (digest unchanged, or rate limit too low/unknown to re-pull: remaining=...)`, which is true in every case that reaches that branch.
- **Why:** These messages are what an operator reads when debugging a failed or odd instance creation. Wrong env numbers and a false "hash matches" line point them at the wrong cause.
- **Not changed:**
  - `settig`, listed in the original finding, no longer exists anywhere in the repo, so there was nothing to fix.
  - The digest-file mismatch in the same image-cache block (one file is written and a different one is read) is a logic bug and belongs to M5. It was deliberately left for that fix.
  - Escaping inside the heredoc (`\$contract_publickey`) and the quoted cron string was left exactly as it was. Only the misspelled words changed.
- **Verified:** `bash -n dependencies/user-install.sh` passes. A `grep` for the old typos finds nothing. `git diff` shows only text inside `echo` and comment lines.

Explanation: `changes/[L5] Copy-paste errors and typos in messages explained.md`.

### 2026-10-12: L6 and L11 fixed (repeated code blocks, image name stripping)

- **Findings closed:** L6, L11.
- **Files changed:** `dependencies/user-install.sh`, `src/hp_manager.cpp`, `src/hp_manager.hpp`.
- **What changed (L6, `user-install.sh`):**
  - The 14 `if` blocks that parse the image-tag settings are now one `case` statement. The port settings share one branch, and `env1` to `env4` share one branch. Both use `printf -v`, and only with names that matched a `case` pattern.
  - The quota cron strings (`quota_crontab_*`) are defined once, before the custom / no-custom branch, instead of once in each branch.
  - The certificate download, unzip and rename block, which appeared twice in the generated `domain_ssl_update.sh`, is now one function, `download_npm_cert()`, in that generated script. Each caller keeps its own failure handling, because the two were different on purpose.
  - Starting the watcher service and writing its cleanup lines is done once, after the branch. Each branch now only sets `watcher_service` (`docker_recreate.service` or `docker_vars.service`).
- **What changed (L11, `hp_manager.cpp`):**
  - The inline "cut at the first `--`" code is replaced by `strip_image_settings()`, which has a doc comment explaining the `--` convention.
  - It only strips inside the tag: after the last `:`, and only when that `:` is after the last `/`, so registry ports are left alone. A tag that holds only settings becomes `latest`, which matches what `user-install.sh` pulls.
  - It rejects a result that is empty or starts with `-` or `:`.
  - `create_new_instance()` now calls it **before** `install_user()`. An invalid image therefore fails straight away with the existing, previously unused `docker_image_invalid` error, instead of failing at `docker create` after a Linux user was already created. `install_user()` still gets the full name, because `user-install.sh` needs the settings.
- **Why:**
  - L6: every copy had to be fixed separately, and copies drift. The `found env1` bug fixed in L5 came from exactly this.
  - L11: the old code cut `my--org/my--img:v2` down to `my`, a different image. It turned `img:--peer--1234` into the invalid name `img:`, and an image starting with `--` into an empty name.
- **Not changed:**
  - L6 kept the output identical. Behaviour fixes for this same code (M9 env values, M10 cron schedule, and the cron job being added without NPMplus in the custom branch) are left for those findings.
  - The shell side still splits the image name at the **first** `:`, so registries with a port are still mishandled there (M8).
  - The now-unneeded `docker tag ... ${docker_image}` line is left for L4.
- **Verified:**
  - The old and new settings parsers gave identical variables for 16 image names.
  - The old and new service sections, run with stubbed `sudo`, `chown` and `jq` for both branches and NPMplus on/off, produced byte-identical generated files, `systemctl` calls and cleanup lines.
  - The rendered `domain_ssl_update.sh` passes `bash -n`, and its diff shows only the new function and its two calls. The function was tested with stubbed `curl`/`unzip` on the success and failure paths.
  - `hp_manager.cpp` compiles with `g++ -std=c++17 -fsyntax-only`, and `strip_image_settings()` passes 12 unit cases.
  - `bash -n dependencies/user-install.sh` passes.
  - **Not yet done:** a full `make` build, and creating a real instance on a test host.

Explanation: `changes/[L6, L11] Repeated code blocks and image name stripping explained.md`.

### 2026-10-12: L2 fixed (leaks on rollback and uninstall)

- **Findings closed:** L2.
- **Files changed:** `dependencies/user-install.sh`, `dependencies/user-uninstall.sh`, `installer/sashimono-uninstall.sh`.
- **What changed:**
  - **Rollback leak.** `user-install.sh` now writes the nft table's cleanup lines (delete the `docker_filter_<uid>` table, re-save `/etc/nftables.conf`) right after creating the table, instead of at the end of the script. A rollback at any of the six later rollback points (`NO_DOCKERSVC`, `NO_DOCKERD`, `DOCKER_PULL`) now removes the table.
  - **Watcher service stop.** The `docker_recreate.service` / `docker_vars.service` stop and disable lines were removed from the cleanup script, because it runs after `user-uninstall.sh` has already killed the user's systemd, so they never worked. `user-uninstall.sh` now stops and disables whichever of the two exists, next to the hpfs services, while the user's systemd is still running.
  - **Full uninstall.** `sashimono-uninstall.sh` (full uninstall only, not upgrade, after all instances are removed) now:
    - deletes any `docker_filter_*` tables left in the live ruleset (`ip` and `ip6`);
    - removes `docker_filter_*` table blocks from `/etc/nftables.conf`, after saving `/etc/nftables.conf.sashimono-bak`, and keeps every other table;
    - removes `/root/.acme.sh/dns_evernode.sh`, and the `/root/.acme.sh` folder only if it is then empty;
    - removes `/root/domain_ssl_update.log`.
- **Why:**
  - Cleanup must be registered before the next point where the install can roll back. The IPv6 code in the same script already did this.
  - Steps that need the user's systemd must run before `user-uninstall.sh` kills the user's processes. The hpfs services were already handled that way.
  - The full uninstaller had never been updated for the host-level files Gadget's features create.
- **Not changed:**
  - Cleanup scripts of instances that already exist still contain the old, harmless no-op stop/disable lines. Their watcher services are now stopped by the new `user-uninstall.sh` step.
  - `nft list ruleset > /etc/nftables.conf` still overwrites the operator's whole file. That's M3.
  - `systemctl enable nftables` is not undone at uninstall, because the operator may rely on it. Decide this with M3.
  - The `/root/.acme.sh` copy itself is still made at install (H5, L4).
- **Noticed while fixing:** `user-install.sh` still runs `apt-get install nftables` during instance creation (around line 348). That's part of H6's original finding, but the H6 fix above only removed the kernel package install, so H6 is not fully fixed.
- **Verified:**
  - Old vs new firewall section with stubbed commands: at rollback time, the old cleanup script had 0 lines and the new one has the nft delete and save lines.
  - The full-uninstall block was run on a sample `nftables.conf` holding a ufw table, an operator table and 3 `docker_filter_*` tables. Only the Sashimono tables were removed (live and in the file), and a backup was written.
  - `/root/.acme.sh` was kept when it held another file and removed when it held only our plugin.
  - The watcher stop acted only on the unit that exists (tested for each of the two, and for neither).
  - The agent and `sashimono-uninstall.sh` only read the last output line of `user-uninstall.sh`, so the new log line is safe.
  - `bash -n` passes for all three scripts.
  - **Not yet done:** a real rollback, a lease removal and a full uninstall on a test host.

Explanation: `changes/[L2] Leaks on rollback and uninstall explained.md`.

### 2026-10-13: H6 (rest), M1, M2, M3 fixed (LAN firewall moved to user-firewall.sh)

- **Findings closed:** M1, M2, M3, and the rest of H6 (the runtime `apt-get install nftables` noted in the L2 entry above).
- **Files changed:** `dependencies/user-firewall.sh` (new), `dependencies/user-install.sh`, `dependencies/user-uninstall.sh`, `installer/sashimono-install.sh`, `installer/sashimono-uninstall.sh`, `installer/setup.sh`, `CMakeLists.txt`, `README.md`.
- **What changed:**
  - **H6.** `check_dependencies()` in `sashimono-install.sh` installs `nftables` if `nft` is missing, and aborts if that fails. It runs on both a fresh install and `evernode update`. `user-install.sh` no longer installs packages: if `nft` is missing it stops with `NO_NFTABLES,INST_ERR` before anything is created.
  - **M1, M2.** The firewall code moved out of `user-install.sh` into `user-firewall.sh <data dir> [user]`, modelled on `user-cgcreate.sh`. Each instance gets one `inet docker_filter_<uid>` table (IPv4 and IPv6), loaded in one `nft -f` transaction. Only packets sent by the instance user (`meta skuid`) are checked:
    - **Allowed:** replies to inbound connections (`ct state established,related`); DNS (port 53) to every resolver in `/etc/resolv.conf` and `/run/systemd/resolve/resolv.conf`; TCP 80/443 and the instance port ranges (from `sa.cfg`) on the host's own addresses; the NPMplus API host and port from `proxy.npm_url`.
    - **Rejected:** everything else on the host's own addresses, `10/8`, `100.64/10`, `169.254/16`, `172.16/12`, `192.168/16`, `224/4`, `255.255.255.255`, `fc00::/7`, `fe80::/10`, `ff00::/8`, and every on-link IPv6 prefix.
    - It applies on every host. The VPS skip, the gateway / local IP / proxy allows on all ports, the "first CIDR" detection and the 2-octet DNS check are gone. `proxy.ip` is no longer read.
  - **M3.** Nothing writes `/etc/nftables.conf` or enables `nftables.service` any more. A new root oneshot service, `sashimono-firewall` (installed, upgraded and removed like `sashimono-cgcreate`), re-applies every instance's table:
    - at boot, after `network-online.target` and before `systemd-user-sessions.service`, so before any tenant's `user@<uid>` services start;
    - whenever `nftables.service` is restarted or reloaded (`PartOf=`, `ReloadPropagatedFrom=`), because that flushes the ruleset.
  - **Install and uninstall.** `user-install.sh` applies the new instance's table after the outbound IPv6 address is added (`rollback "NFT_ERR"` on failure), then refreshes every instance's table best-effort, so all tables know the host's current addresses. `user-uninstall.sh` now deletes the table itself. This replaces the cleanup-script lines added by the L2 fix, because that script is tenant-owned (H4). The full-uninstall sweep from the L2 fix now also matches `inet` tables.
- **Why:** Gadget's firewall was skipped on most VPS hosts (cloud metadata and the VPC stayed open), blocked only the first subnet it found, opened the gateway and proxy on every port, had no working IPv6 rules, and kept itself across reboots by overwriting the operator's whole `/etc/nftables.conf`. A fixed "block private, allow what's needed" rule set needs no LAN guessing. Rebuilding it at boot, as cgcreate does for resource limits, needs no saved copy.
- **Not changed:**
  - The rules use the host's addresses and resolvers at boot, install or nftables reload time. If DHCP changes them in between, the tables catch up at the next of those.
  - `systemctl restart nftables` leaves about 0.6 s without tenant rules, because nftables' own stop step flushes everything and our service can only run after it. `reload` has no gap.
  - Gadget's code was never released, so only dev/test hosts can still have its dumped `/etc/nftables.conf` and an enabled `nftables.service`. The full-uninstall cleanup from the L2 fix still covers them.
  - The NPMplus allow stays until the domain/SSL design review (C3, C4, H1).
  - Two different hosts on the same LAN that reach each other through split DNS are still blocked. Gadget's version blocked that too.
- **Verified:**
  - In isolated network namespaces with Ubuntu 20.04's nft 0.9.3: the script and its single-user, all-users, invalid-user and failure paths; LAN, metadata, host-port and IPv6 rejects; instance-port, internet and loopback allows; inbound TCP/UDP replies; other users not affected; and a dump/flush/reload round trip.
  - On a real Vultr host with a 5-node contract: `nft -c` accepted the ruleset built from the host's real data; all 5 nodes peered through the host's public IP and stayed in consensus with 0 rejected packets. As a tenant uid, metadata, host SSH (IPv4 and IPv6) and the on-link IPv6 LAN were rejected, while root could reach them; the peer port, internet and DNS worked. `evernode delete` removed exactly that instance's table. `systemctl reload nftables` and `systemctl restart nftables` both rebuilt every table, leaving ufw's rules and the contract unaffected.
  - **Not yet done:** a reboot, and a forced `NFT_ERR` rollback.

Explanation: `changes/[H6, M1, M2, M3] LAN firewall (nftables) explained.md`.
### 2026-10-13: L9 fixed, M5 partly fixed (hard-coded paths, URLs and DNS servers)

- **Findings closed:** L9. **Partly:** M5, only its "Docker Hub URLs are hard-coded" part.
- **Files changed:** `dependencies/user-install.sh` (and the `domain_ssl_update.sh` it generates), `dependencies/dns_evernode.sh`.
- **What changed:**
  - **Paths.** The 9 hard-coded `/usr/bin/sashimono/...` paths in the acme.sh setup now use `$script_dir`.
  - **Docker Hub URLs.**
    - A new helper, `docker_hub_repo()`, maps an image to its Docker Hub repository (`ubuntu:22.04` → `library/ubuntu`, `docker.io/x/y` → `x/y`). It returns nothing for other registries.
    - The image-cache check only queries Docker Hub for Docker Hub images, using the correct repository name. Other registries skip the Docker Hub check and use the cached copy, or pull.
  - **DNS server.**
    - A new optional `mb-xrpl.cfg` key, `proxy.dns_resolver` (default `8.8.8.8`; must be an IP or host name), is used by both the TXT authorization check (was `@1.1.1.1`) and the acme.sh plugin (was a hard-coded `@8.8.8.8`).
    - The generated script exports it as `EVERNODE_DNS_RESOLVER`, and `dns_evernode.sh` reads it.
  - **Proxy target (kept simple).**
    - NPMplus now forwards to this host's address on the route to the NPMplus server (`ip route get`).
    - It falls back to the old first `hostname -I` address when NPMplus is local or no route is found.
    - The `proxy_ip` lookup was moved out of the firewall `if`, so standalone hosts have it too. The firewall rules are unchanged.
    - The forward scheme (`https`) and port (`gptcp1`) were deliberately left as they were.
  - **`www.` alias.**
    - A tenant's own domain gets its `www.` twin (or bare twin) only when that name resolves. Generated subdomains never get one.
    - The same name list goes into the proxy host, both NPMplus certificate requests and the acme.sh call (extra `--domain`), so the certificate covers every proxy name.
    - The `${domain//www./}` replacement, which turned `shop.awww.io` into `shop.aio`, is gone.
- **Why:**
  - Each value only worked on a host set up like Gadget's.
  - Other install paths triggered GitHub downloads.
  - The cache check sent official and non-Docker-Hub images to the wrong place.
  - The two DNS servers could disagree and couldn't be changed.
  - With a remote NPMplus, the proxy could point at a docker bridge address.
  - The `www.` alias always had a certificate error.
- **Not changed:**
  - The rest of M5: digest file written/read mismatch, the `mkdir -p` defeating the cache check, no lock, and the private registry mirror not used by the check.
  - The download fallback itself (H5).
  - Documenting all `proxy.*` keys (L1). The new key is described in a comment where it's read.
  - Existing certificates are not reissued to add the twin.
  - The proxy scheme and port (they would need M8's validation first).
- **Verified:**
  - `docker_hub_repo()` passes 15 unit cases.
  - With stubbed `curl`/`docker`, Docker Hub images make the same requests as before, `ubuntu` now uses `library/ubuntu`, and `ghcr.io` images no longer query Docker Hub.
  - With stubbed `dig`/`getent`/`ip`/`hostname`, the proxy name list, acme args and forward host are correct in 9 cases (including `shop.awww.io`, a generated subdomain, a remote NPMplus and every fallback), and all four NPMplus JSON payloads are valid (`jq`).
  - The firewall `nft` calls are identical to before in 4 setups.
  - The rendered `domain_ssl_update.sh` diff shows only the intended changes, and both versions pass `bash -n`.
  - `shellcheck`: `user-install.sh` 109 → 103 findings with nothing new; the generated script unchanged at 12; `dns_evernode.sh` unchanged at its 1 existing false positive (the now-variable `$nameserver_override` is quoted).
  - **Not yet done:** a real custom-domain instance on a local and a remote NPMplus host, and a non-Docker-Hub image on a real host.

Explanation: `changes/[L9] Hard-coded paths, URLs and DNS servers explained.md`.


### 2026-10-13: M4, M5 fixed (image pull timeout and image cache)

- **Findings closed:** M4, and the rest of M5 (its Docker Hub URL part was fixed with L9).
- **Files changed:** `dependencies/user-install.sh`, `installer/docker-install.sh`.
- **What changed:**
  - **M4.** `docker pull` now runs through a new `pull_docker_image()`, under `timeout` with `docker_pull_timeout_secs`, lowered from 180 s to 120 s (the value used before PR #415), and rolls back with `DOCKER_PULL` when it fails or times out. The Docker Hub digest requests use `curl -m 10`.
  - **One decision path.** The two branches (each with its own digest file) are replaced by one flow:
    - A new `docker_hub_digest()` asks Docker Hub for the tag's current digest. It replaces the two copies of the token/`HEAD` code.
    - The cached tarball is loaded only when that digest is known **and** equals the stored one. Otherwise the image is pulled.
    - The rate-limit gate (`ratelimit-remaining > 60`) is removed. A changed digest always means a fresh pull, so a tenant never gets an old image because the host's pull budget is low.
  - **What is stored.** After a pull, the stored digest is the one docker itself recorded (`RepoDigests`), not the earlier `HEAD` answer. So an image pushed between the check and the pull, or a registry mirror that is behind Docker Hub, can't record a false match.
  - **Safe save.** The old digest is removed first, the tarball is saved to `<tar>.tmp` and moved into place, and only then is the new digest written. A failed save removes the temp file, prints a warning and **continues**: the image is already in the instance's docker, so the instance doesn't need the cache. It used to roll back.
  - **Lock.** `flock` on `<tar>.lock` (in the main shell, so `rollback`'s `exit` releases it) covers the check, pull, save and load. A second install of the same image waits, then loads the first one's tarball.
  - **Cache layout.** Files are now `images/<docker hub repo>/<tag>.tar` (+ `.image_digest`, `.lock`):
    - `ubuntu:22.04` and `docker.io/library/ubuntu:22.04` share one entry.
    - `foo:bar-baz` and `foo-bar:baz` no longer map to the same file (they did with `tr : -`).
    - Names that don't match Docker's repository/tag format skip the cache, so a tenant-supplied name like `a/../../x` can't create files outside `images/`.
    - The empty `$img_local_path` folder and the dead `-d` check are gone.
  - **Other registries.** Images that aren't on Docker Hub are always pulled and never cached, because their current digest can't be checked. This replaces the L9 entry's "use the cached copy, or pull". In practice nothing changes, because no tarball was ever reused for them.
  - **Leftovers.** The commented-out pull, frozen-downloader and `tar` lines are removed. `docker-install.sh` no longer downloads `download-frozen-image-v2.sh` (unpinned, from moby `master`, unused since `66709f5`). On install and upgrade (the agent is already stopped by then) it now deletes that file and empties `dockerbin/images`, which removes the cache files of the PR #415 and Gadget layouts.
- **Why:** the cache wrote its digest to one file and read another, could load an outdated image (low rate limit, failed check), let concurrent installs write one tarball together, and could write a digest for a tarball whose save had failed. A stuck pull froze instance creation forever. `mb-xrpl` gives up on a lease after 80% of `leaseAcquireWindow` anyway, and `mb-xrpl` handles one lease at a time (`sashiCli.wait()`), so a hang also blocked every later lease. Mainnet's `leaseAcquireWindow` is 160 s (read from the governor hook on 2026-10-13), so a lease is destroyed once creating it takes more than 128 s. A pull that is still running after 120 s can't produce a usable lease, which is why the timeout was lowered.
- **Not changed:**
  - The registry mirror (`docker_registry`) still isn't asked for the digest. That's safe now, because the stored digest is what was actually pulled. With a lagging mirror, the effect is a re-pull, not a stale image.
  - Digest references (`img@sha256:...`) and registry ports in the shell's image parsing (M8). These images skip the cache.
  - The `docker tag ${docker_pull_image} ${docker_image}` line (L4).
- **Verified:**
  - With stubbed `docker`/`curl`: first pull; cache hit; digest changed; Docker Hub unreachable (10 s, then pull, and the cache is refreshed with the pulled digest); save failure (warning, no temp file, no digest, the next install pulls); pull timeout (`DOCKER_PULL` rollback, lock released); mirror lag (pulled digest stored, no false match); non-Docker-Hub image and digest reference `img@sha256:...` (pull only, no files); traversal names in the repository and the tag (pull only, nothing outside `images/`); official image (`library/ubuntu/22.04.tar`); the `foo:bar-baz` / `foo-bar:baz` pair (two files).
  - Two installs of one image at the same time: one pull and save, then the second loaded the tarball.
  - Live Docker Hub: `docker_hub_digest()` returned the same digest docker records in `RepoDigests` for a multi-arch OCI index (`busybox:1.36`) and Evernode's single-arch image (`evernode/sashimono:hp.latest-ubt.20.04-njs.20`). It returns nothing for a missing tag.
  - Real local docker (28.1.1): pull, `RepoDigests` read, save, then on a second run `docker load` of the cached tarball.
  - `docker-install.sh` on a fake `dockerbin`: the cache folder and the downloader are removed, other files are kept.
  - Pull timeout with the real docker CLI (`node:20`, timeout set to 2 s): cut off after 2 s, then `DOCKER_PULL` rollback.
  - The agent is stopped before `docker-install.sh` runs on upgrade (`sashimono-install.sh:473-478`, then `:530`).
  - `bash -n` passes for both scripts.
  - `shellcheck` 0.10.0: `user-install.sh` 91 → 71 findings (warnings 4 → 3), `docker-install.sh` 17 → 15 (warnings 6 → 4). Nothing new: the only findings in the changed area are on the untouched `docker tag` lines (L4).
  - **Not yet done:** an instance created on a real host with rootless docker 24.0.5, and a real `rollback` while the lock is held (the harness stubs `rollback`).

Explanation: `changes/[M4, M5] Image pull timeout and image cache explained.md`.

### 2026-10-14: M6, M7, M8, M9 fixed (image tag settings, container creation and env.vars)

- **Findings closed:** M6, M7, M8, M9.
- **Files changed:** `dependencies/user-install.sh`, `dependencies/user-uninstall.sh`, `src/hp_manager.cpp`, `src/hp_manager.hpp`.
- **What changed:**
  - **M7.** The two `source …env.vars` lines are removed from the user's `.bashrc`. The block is now the same as before Gadget's change.
  - **M8. Parsing.** The tag settings are read and checked at the top of `user-install.sh` (lines 146-263), before the user is created. Bad input stops with `INVALID_IMAGE_SETTINGS,INST_ERR` and a log line giving the reason, with nothing to roll back.
    - The tag is split the same way as `strip_image_settings()` in C++: after the last `:`, but only if that `:` comes after the last `/`; settings start at the first `--`; an empty version means `latest`. Registry ports (`host:5000/img`) and digest references now work, and the image pulled is always the one the agent creates the container from.
    - Rejected: a tag with settings that is not up to 128 of `[A-Za-z0-9_.-]` (the check `docker tag` used to make by accident); a name without a value or an empty value; unknown or repeated setting names; ports that are not `1-65535` or have a leading zero; two settings using the same container port (TCP: peer, user, gptcp1, gptcp2; UDP: peer, gpudp1, gpudp2, because peer is published on both); invalid `domain` or `subdomain`; `ssl` or `contract` other than `true`/`false`; `envN` values that are not `KEY-value` with a valid key; env keys that repeat or clash with a built-in variable.
  - **M9. `env.vars`.**
    - Plain `KEY=value` lines, no quotes and no `$(( ))`. `RAM_QUOTA` and `DISK_QUOTA` (rounded `"…GB"` strings) are replaced by `RAM_QUOTA_BYTES` and `DISK_QUOTA_BYTES` in real bytes (KiB × 1024). `DISK_USED` and `DISK_FREE` are gone.
    - `INTERNAL_GPTCP2_PORT` and `INTERNAL_GPUDP2_PORT` use the tenant's `gptcp2`/`gpudp2` values.
    - The dummy `KEY1=1` … `KEY4=4` are gone. Only env keys the tenant set are added.
    - The container gets the static variables through `--env-file`. `DISK_USED_BYTES` and `DISK_FREE_BYTES` change over time, so they are only in the contract's copy, `/contract/env.vars`. A generated `~/.docker/env_vars_update.sh` rebuilds that copy every 5 minutes. It uses `quota -w` so a long device name doesn't wrap the line, and it strips the `*` that `quota` adds over the limit.
    - The copy is built in `~/.docker` and renamed into the contract directory with `mv -fT`. Gadget's version wrote `env.vars.tmp` inside `/contract`, where the tenant could place a symlink to `../.bashrc` and have the cron job write into it, which would have brought M7 back.
  - **M6. The agent creates the container directly.**
    - `user-install.sh` writes `~/.docker/container.cfg` (JSON: the six container ports and `run_contract`). `create_container()` reads it with the new `read_container_settings()`, which rejects missing, non-integer, out-of-range or zero ports and a non-boolean `run_contract`. It then runs `DOCKER_CREATE` with `external:internal` ports, `--env-file ~/.docker/env.vars`, and `run /contract` only when `run_contract` is true. The buffer length was recalculated for the new format.
    - `docker_recreate.sh`, `docker_recreate.service`, `docker_vars.service` and the `docker tag ${docker_pull_image} ${docker_image}` alias are removed. The container is no longer stopped, removed and recreated after the agent creates it, and it is no longer started before `initiate`, as before Gadget's change.
    - The remaining work of the old watchers needs the contract directory, which only exists after `create_contract()`. It moved into a oneshot user unit, `instance_setup.service` (oneshot units have no start timeout by default, checked on systemd 245): it runs `env_vars_update.sh` and, on NPMplus hosts, the first `domain_ssl_update.sh`. The agent starts it with `systemctl --user start --no-block` right after `docker create` (`start_instance_setup()`), because the domain setup can take minutes. The unit is not enabled, so it doesn't run again at boot.
    - Both cron jobs (env.vars every 5 minutes, and the weekly `domain_ssl_update.sh` line, unchanged) are installed directly by `user-install.sh` with `crontab -u`. A failure prints a warning, as before.
    - `user-uninstall.sh` stops `instance_setup.service` and removes the user's crontab itself, instead of the `crontab -u <user> -r` line in the tenant-owned cleanup script (H4).
  - **Behaviour changes.**
    - Every container gets `--env-file`, not only containers with tag settings.
    - Settings that used to be ignored or half-applied now fail the install. The tenant only sees `user_install_error`; the reason is in the sagent log.
    - `--contract--false` on its own now runs the image's own command. Before, it was ignored, so `run /contract` was kept.
    - The domain setup runs under the same conditions as before (NPMplus host, and tag settings or a non-`reputation` image). The custom-settings path no longer installs a weekly cron for a `domain_ssl_update.sh` that doesn't exist on non-NPMplus hosts.
- **Why:** the old watchers only did their work if they caught the first `docker create` event, so a slow start silently left an instance without ports, env.vars, cron jobs or a domain. They also stopped and removed the container while the agent might be starting it. Tenant values went unchecked into arithmetic, generated scripts and commands. `env.vars` gave the container quoted, unexpanded and wrongly-named values, and the operator's shell ran tenant code.
- **Not changed:**
  - Gadget's code was never released, so only dev/test hosts can have the old `.bashrc` lines, watcher units or crontab entries. On those, uninstall still deletes the user's home and kills its processes. The old watcher units are no longer stopped by name.
  - Any tag setting without `contract=true` still makes the container run the image's own command (Gadget's rule). The HotPocket image has entrypoint `hpcore` and no default command (checked with `docker inspect` on `evernode/sashimono:hp.latest-ubt.20.04-njs.20`), so a HotPocket tenant who adds only, say, `--env1--FOO-bar` gets an instance that doesn't run its contract. With `contract=true`, a remapped `user` or `peer` port still points at a port HotPocket doesn't listen on, because `hp.cfg` uses the host ports. Both are left for the domain/image-settings design review.
  - `domain_ssl_update.sh` also writes into the contract directory (`tls/`, the copied log), so the same symlink concern applies there. Left for the domain review (C3, C4, H1).
  - The weekly cron schedule and its random delay (M10).
  - This closes the M5 entry's open items: the registry port and digest parsing (M8), and the `docker tag` line (part of L4).
- **Verified:**
  - `sagent` builds. Rendered with the real format string: the `docker create` command with and without `run /contract`, and the buffer length with 5-digit ports (721 bytes for 678 needed).
  - jsoncons: `is<uint16_t>()` rejects 70000, -1, `"8080"`, 1.5, `true`, `null` and a missing key; 0 is rejected by the extra check.
  - The parsing block, run on its own: 15 valid tags (with and without tag, registry port, digest, `image:--subdomain--x` → `latest`, every setting type, the same port on TCP and UDP) and 26 invalid ones, each with the expected message.
  - With stubs: rendered `env.vars`, `env_vars_update.sh`, `container.cfg` (valid JSON), `instance_setup.service` (passes `systemd-analyze verify`) and the crontab. The weekly line is the same text the old service produced. Domain on/off for 4 host and image combinations matches the old conditions.
  - `env_vars_update.sh` with a stubbed `quota`: normal usage, `51234*` over the limit, no quota line. A symlink planted at `env.vars` or `env.vars.tmp` leaves `.bashrc` untouched, and a directory planted at `env.vars` fails without leaving a temp file.
  - Real local docker (28.1.1): `docker create` with the rendered arguments and generated env file. All 7 bindings (peer on TCP and UDP, `26201→8080`), `API_KEY=a b$c` unchanged in `Config.Env`, and `Cmd` empty or `run /contract` as set. The test containers were removed.
  - `bash -n` passes. `shellcheck` 0.10.0: `user-install.sh` 71 → 60 findings (warnings 4 → 2), `user-uninstall.sh` unchanged at 22, the generated `env_vars_update.sh` 0. Nothing new.
  - **Not yet done:** real instances on a test host (plain HotPocket, custom ports and env, `contract=true`, an NPMplus domain), a lease destroy, and a rollback.

Explanation: `changes/[M6, M7, M8, M9] Image tag settings and env.vars explained.md`.

### 2026-10-14: L4 partly fixed (unused `ctx.dns_evernode_sh` removed)

- **Findings closed:** none. L4 is **partly fixed**.
- **Files changed:** `src/conf.hpp`, `src/conf.cpp`.
- **What changed:**
  - **`ctx.dns_evernode_sh`.** Removed from `sa_context` and from `conf::init`. Nothing in the agent read it. `dns_evernode.sh` itself is still shipped (installer, CMake), because acme.sh uses it, and `user-install.sh` finds it through `$script_dir`.
  - **Already done by the M4/M5 fix:** `docker_pull_timeout_secs` is now used by `pull_docker_image()`, and the commented-out pull, frozen-downloader and `tar` lines are gone.
- **Why:** Unused code still has to be read, kept compiling and kept consistent. `dns_evernode_sh` had already broken the build once (`2d346ce`) and needed a typo fix (`d704108`).
- **Not changed (still open):**
  - The `user-install.sh` part of this fix (removing the `/root/.acme.sh` copy, the `version=1.9` variable, and the `echo` lines around `docker tag`) was made and then reverted at the team's request. These items are still open. The changes note describes them.
  - The `docker tag ${docker_pull_image} ${docker_image}` line. Nothing uses the tag, but it must stay until M8 (see **Found while fixing**).
- **Found while fixing:**
  - The `docker tag` line is the only thing that rejects unsafe characters in the tenant's image settings:
    - The agent passes the image name to `user-install.sh` (run as root) without checking it.
    - A port setting goes into bash arithmetic (`$((internal_gptcp1_port + 1))` in the `env.vars` heredoc), and bash runs `$(...)` found inside an array index there. A domain setting is pasted into the generated `domain_ssl_update.sh` as code.
    - `docker tag` runs before both, rejects `$ ( [ ;` and similar characters with "invalid reference format", and rolls back. Without it, `myimg:v1--gptcp1--x[$(cmd)]` would run `cmd` as root.
  - The settings parser copied from `user-install.sh`, given that name and then the arithmetic, ran a harmless payload. Real docker 28.1.1 rejects the same name in `docker tag`.
  - This doesn't check whether mb-xrpl or evernode-js already filters image names before they reach the agent. Recorded under M8.
- **Verified:**
  - `grep`: no remaining references to `dns_evernode_sh` in `src/`.
  - All 12 `src/*.cpp` files compile with `g++ -std=c++17 -fsyntax-only`.
  - `dependencies/user-install.sh` is unchanged from the last commit.
  - **Not yet done:** a full `make` build.

Explanation: `changes/[L4] Dead code, unused variables, debug leftovers explained.md`.
