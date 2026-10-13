# L2: Leaks on Rollback and Uninstall

This note covers finding **L2** from `GADGET_COMMITS_REVIEW.md`, fixed on 2026-10-12. "Leak" here means something Sashimono creates on the host and then never removes.

## 1. Background: how an instance is cleaned up

Each instance has a cleanup script, `/home/<user>/uninstall_cleanup.sh`. While `user-install.sh` sets up the instance, it appends one line to this script for every host-level change that needs undoing later.

`user-uninstall.sh` runs the cleanup script. It runs in two situations:

- **Normal removal.** The lease ends, or the host is uninstalled.
- **Rollback.** `user-install.sh` fails partway (for example `DOCKER_PULL`). Its `rollback` function calls `user-uninstall.sh` straight away.

So a cleanup line only helps if it is **written before the point where the install can fail**.

The order inside `user-uninstall.sh` also matters:

1. Stop the hpfs services.
2. Uninstall the instance's dockerd.
3. Kill **all** of the user's processes, including the user's own systemd.
4. ... (cgroups, quota, firewall ports) ...
5. **Run the cleanup script.**
6. Delete the user and their home folder.

## 2. The three leaks

All three come from Gadget's commits `10078bb` (2025-06-14) and `696139f` (2025-06-19).

### Leak 1: the nft table survives a rollback

- **What Gadget changed.** `10078bb` added a per-instance firewall table, `docker_filter_<uid>`, to stop the tenant's container reaching the host's LAN. `696139f` added saving it to `/etc/nftables.conf`. The table is created at around line 355, but its cleanup lines were only written at the **very end** of the script, in the same block as all the other cleanup lines.
- **The bug.** Six rollback points sit between those two places: `NO_DOCKERSVC`, `NO_DOCKERD`, and four `DOCKER_PULL`. If any of them fires, the cleanup script has no nft line yet, so the table is never deleted. It stays in the live firewall, and on the next boot `nftables.service` reloads it from `/etc/nftables.conf`.
- **Why he probably did it.** Writing all the cleanup in one block at the end is tidy and easy to read. The catch is that `rollback` runs the same cleanup script, so anything created before a rollback point must be registered straight away. The existing IPv6 code already did that (`ip addr add` is followed immediately by its `ip addr del` cleanup line), and the new code didn't follow that pattern.

### Leak 2: stopping the watcher service in the cleanup script never works

- **What Gadget changed.** `10078bb` added a per-user systemd service (`docker_recreate.service` or `docker_vars.service`) that waits for the first `docker create`. The `systemctl --user stop` / `disable` lines for it went into the cleanup script.
- **The bug.** The cleanup script runs in step 5, after step 3 has killed the user's systemd. So `systemctl --user` has nothing to talk to, and these lines always fail silently. The service is never stopped properly. It only dies because its processes are killed.
- **Why he probably did it.** The cleanup script looks like "the place for uninstall steps". Seeing that it runs too late for user services means reading `user-uninstall.sh`, which Gadget never changed. The existing hpfs services were already handled the right way, directly in `user-uninstall.sh` (step 1).

### Leak 3: the full uninstall leaves files on the host

`sashimono-uninstall.sh` removes Sashimono from the whole host, but it was never updated for Gadget's features. These stayed behind:

| Left behind | Created by | Why it stays |
|---|---|---|
| `docker_filter_*` tables in `/etc/nftables.conf` and in the live ruleset | `696139f` (save), `10078bb` (table) | Each instance's cleanup normally removes its own table, but tables leaked by Leak 1 are never removed. Nothing checks for them at uninstall. |
| `/root/.acme.sh/dns_evernode.sh` | `10078bb` | Copied there by the download fallback in `user-install.sh`. Nothing removes it. |
| `/root/domain_ssl_update.log` | `10078bb` | Every instance's cleanup appends its log to this file, so it only ever grows. Nothing removes it. |

**Why he probably did it:** Gadget's changes stayed in the install side (`user-install.sh`, and adding a file to `sashimono-install.sh`). The uninstaller lives in a different file and was never looked at.

## 3. What we changed

### `dependencies/user-install.sh`

- **The nft cleanup lines are written immediately after the table is created** (line 359), inside the same `if`. A rollback at any later point now removes the table.
  - When the host is a standalone node and no table is created, no nft cleanup line is written. That's correct, because there's nothing to remove.
- **The watcher service stop/disable lines are no longer written to the cleanup script** (line 987, with a comment explaining why).

### `dependencies/user-uninstall.sh`

- **The watcher service is now stopped and disabled in step 1**, next to the hpfs services (line 62). This is while the user's systemd is still running.
- **It only acts on the service that exists.** An instance has `docker_recreate.service` or `docker_vars.service` (or neither, for instances from before Gadget's change), so it checks which unit file is present.

### `installer/sashimono-uninstall.sh`

These steps run only on a full uninstall, not an upgrade, after all the instances have been removed (line 255):

- **Leftover live tables.** It deletes any `docker_filter_*` tables still in the live ruleset (both `ip` and `ip6`).
- **Leftover tables in `/etc/nftables.conf`.** It removes `docker_filter_*` table blocks from the file. A backup is saved as `/etc/nftables.conf.sashimono-bak` first. Every other table in the file (ufw's, the operator's own) is left as it is.
- **The acme plugin.** It removes `/root/.acme.sh/dns_evernode.sh`. The `/root/.acme.sh` folder is only removed if it's then empty, because an operator may use acme.sh for other things.
- **The log file.** It removes `/root/domain_ssl_update.log`.

## 4. How it was verified

All the tests ran in a scratch folder with stubbed commands. Nothing ran on a real host.

- **Rollback.** The firewall section of the old and new `user-install.sh` was run, then the cleanup script was checked at the point a rollback would run it. The old version had 0 lines, so the table leaked. The new version has the nft delete line and the `nftables.conf` save line.
- **Full uninstall.** The new block was run against a sample `nftables.conf` holding a ufw table, an operator table, and three `docker_filter_*` tables (`ip` and `ip6`). Only the `docker_filter_*` tables were removed, from the live list and from the file, and a backup was written. `/root/.acme.sh` was removed when it held only our plugin, and kept when it held another file.
- **Watcher stop.** The new loop was run for an instance with `docker_recreate.service`, one with `docker_vars.service`, and one with neither. It stopped and disabled only the service that exists.
- **Agent output.** `user-uninstall.sh` now prints one extra line. The agent and `sashimono-uninstall.sh` only check the **last** output line (`UNINST_SUC` / `UNINST_ERR`), so this is safe.
- **Syntax.** `bash -n` passes for all three scripts.

**Not yet done:** a real rollback, a lease removal and a full uninstall on a test host.

## 5. Not changed here

- **Existing instances.** Their cleanup scripts were written by the old code, so they still contain the old stop/disable lines. Those lines were always harmless no-ops and stay that way. Their watcher services are now stopped properly by the new step in `user-uninstall.sh`.
- **The `nft list ruleset > /etc/nftables.conf` save.** It still overwrites the operator's whole file. That's **M3**, and the proper fix (a separate Sashimono-only file) belongs there.
- **`systemctl enable nftables`.** This still runs at install and isn't undone at uninstall, because an operator may rely on it themselves. This should be decided together with M3.
- **The `/root/.acme.sh` copy and the download fallback.** They're still made at install. Removing them is part of **H5** and **L4**. This fix only makes sure the uninstall cleans them up.
- **H6 is not fully fixed.** While checking this code, we noticed `user-install.sh` still installs `nftables` with `apt-get` during instance creation (line 348). That's part of **H6**, which is marked as fixed, but its fix only removed the kernel package install.

## 6. Update (2026-10-13)

The firewall fix (H6, M1, M2, M3) changed two parts of this fix:

- **The nft table cleanup is no longer a cleanup-script line.** `user-uninstall.sh` now deletes the instance's `inet docker_filter_<uid>` table itself. It runs on both rollback and normal removal, so a rollback still removes the table, and the tenant-owned cleanup script (H4) is no longer trusted with it.
- **Nothing writes `/etc/nftables.conf` any more,** so the cleanup script no longer re-saves it. The full-uninstall sweep added here now also matches `inet` tables. Its `/etc/nftables.conf` cleanup only matters on hosts that ran Gadget's code.

See `[H6, M1, M2, M3] LAN firewall (nftables) explained.md`.
