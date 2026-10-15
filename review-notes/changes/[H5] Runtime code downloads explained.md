# H5: Code Downloaded at Runtime from a Personal GitHub Branch

This note explains finding **H5** from `GADGET_COMMITS_REVIEW.md`: what the code did, who added it, what could go wrong, how it was fixed, and what changes for hosts. **Status: fixed on 2026-10-15.** See the Fix log in `GADGET_COMMITS_REVIEW.md`.

## 1. A few terms first

**acme.sh.** A widely used open-source shell script that gets TLS certificates from Let's Encrypt. Upstream is `github.com/acmesh-official/acme.sh`.

**DNS-01 challenge and `dns_evernode.sh`.** To issue a certificate, Let's Encrypt asks for proof that you control the domain. With DNS-01, acme.sh puts a TXT record into the domain's DNS. acme.sh does that through a "DNS plugin". `dns_evernode.sh` is Gadget's plugin, which writes the TXT record through Evernode's DNS API.

**Custom-domain feature.** On a host with NPMplus (`proxy.tls_type = NPMplus` in `mb-xrpl.cfg`), a tenant can add `--domain--shop.example.com` to the image tag. The generated `~/.docker/domain_ssl_update.sh` then uses acme.sh and the plugin to get a certificate for that domain. It runs when the instance is set up and weekly from the tenant's cron, **as the tenant's host user**.

**Pinning.** Using one exact version of a file, and checking its SHA-256 hash, so every host runs the same code and a changed file is noticed.

## 2. What the code did

**Who and when:** `gadget78`, commit `10078bb` (2025-06-14), merged in PR #434. The L9 fix later replaced the hard-coded paths with `$script_dir` but kept the downloads.

When a tenant set a domain on an NPMplus host, `user-install.sh` (run as root) did this:

```bash
ACME_SH_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
ACME_DNS_PLUGIN_URL="https://raw.githubusercontent.com/gadget78/sashimono/main/dependencies/dns_evernode.sh"
...
if [[ ! -f "$script_dir/acme.sh" ]]; then
    wget -O "$script_dir"/acme.sh "$ACME_SH_URL"
    chmod +x "$script_dir"/acme.sh
fi
if [[ ! -f "$script_dir/dns_evernode.sh" ]]; then
    wget -O "$script_dir"/dns_evernode.sh "$ACME_DNS_PLUGIN_URL"
    chmod +x "$script_dir"/dns_evernode.sh
    mkdir -p /root/.acme.sh
    cp "$script_dir"/dns_evernode.sh /root/.acme.sh/dns_evernode.sh
fi
```

Then both files were copied into the tenant's `~/.acme.sh/`.

The two downloads were not equally common:

| File | Shipped by the installer? | When the download ran |
|---|---|---|
| `dns_evernode.sh` | Yes, into `$SASHIMONO_BIN` | Only if someone deleted it. The code was useless but risky. |
| `acme.sh` | **No** | **Always**, on the first custom-domain instance after each install or upgrade (an upgrade empties `$SASHIMONO_BIN`) |

## 3. What could go wrong

- **One person's GitHub account decided what code ran.** `gadget78/sashimono` is a personal fork, and `main` is a branch that moves. Upstream `master` is a development branch. Whoever controlled either one at the moment of a download chose the code that custom-domain hosts ran.
- **That code runs with real access.** Root wrote it into `/usr/bin/sashimono`. It then runs as the tenant's host user, which can read the NPMplus admin token (H1). A bad script could take over every proxy host and certificate on that NPMplus.
- **Nothing was checked.** There was no version and no hash. Two hosts on the same Sashimono release could run different acme.sh code, depending on the day each one first downloaded it.
- **A failed download broke the host until someone noticed.** `wget -O` creates the output file before it downloads anything. When the download failed, an empty file was left behind. The `-f` check then passed on every later instance, so certificate issuing stayed broken.
- **A network download inside lease creation**, with no timeout.
- **An unused root copy.** `/root/.acme.sh/dns_evernode.sh` was never read, because acme.sh uses the copy next to its own script in `~/.acme.sh/` (L4).

## 4. The fix

### `installer/sashimono-install.sh`

Two settings sit next to `desired_slirp4netns_version`:

```bash
desired_acme_sh_version="3.1.6"
desired_acme_sh_sha256="c7d68b021cfd6380ea83a82962abde5b484779fee0b97d38681dfa1396bbc8d7"
```

`check_dependencies()`, which runs on fresh installs and on `evernode update`, now also installs acme.sh:

1. It downloads `acme.sh` from the `3.1.6` tag with `curl --fail -m 60`.
2. It keeps the file only if the hash matches. If the download fails or the hash is wrong, it deletes the file, writes an error to the install log and shows a warning on the console. The install or upgrade continues.

`$SASHIMONO_BIN` is always empty at this point: a fresh install starts with a new folder, and an upgrade first runs the uninstaller, which deletes the binaries. So there is no older copy to compare against.

It runs on every host, not only NPMplus hosts, because `proxy.tls_type` is set by outside tooling and may be added after the install.

### `dependencies/user-install.sh`

- The two URLs and both `wget` blocks are removed, and with them the `/root/.acme.sh` copy.
- New early check, after the image settings are parsed and **before the Linux user is created**:

  ```bash
  if [[ "$TLS_TYPE" == "NPMplus" ]] && [[ -n "$custom_docker_domain" ]] && [[ ! -f "$script_dir/acme.sh" || ! -f "$script_dir/dns_evernode.sh" ]]; then
      echo "NO_ACME,INST_ERR" && exit 1
  fi
  ```

  It uses the same condition as the copy into `~/.acme.sh/`. Nothing has been created yet, so there is nothing to roll back.

### Uninstall

Nothing changed. `sashimono-uninstall.sh` already deletes everything in `$SASHIMONO_BIN` except mb-xrpl and itself, which includes `acme.sh`. The same step runs before every upgrade, so a copy that older code downloaded from `master` is removed before the pinned one is installed. Its lines that remove `/root/.acme.sh/dns_evernode.sh` (added in L2) stay, for hosts that got the copy from older code.

## 5. Why this way

- **No code fetched while an instance is created.** The installer is the one place that sets up host files, the same as for slirp4netns, rootlesskit and nftables.
- **The hash is the real protection.** A Git tag can be moved, but a changed file won't match the hash, so it is never installed.
- **Warn instead of abort (team decision).** The custom-domain feature is optional and not released. Stopping every host's install or upgrade during a GitHub outage would hurt hosts that never use it. A file that fails the check is never installed, so a warning is safe: the only effect is that custom-domain instances fail with `NO_ACME` until the next successful install or upgrade.
- **Fail early in `user-install.sh`.** A missing file used to mean "download it". Now it is a clear error before anything is created.

### Pros and cons

| Pros | Cons |
|---|---|
| Every host on a release runs the same, checked acme.sh. | Updating acme.sh now needs a Sashimono release that changes the version and the hash. |
| No code from a personal account, and no download during lease creation. | A failed setup does not stop the install. The operator has to act on the console warning, or notices it when a custom-domain instance fails with `NO_ACME`. |
| An empty or wrong file is never kept. | The installer still needs to reach GitHub once, at install or upgrade time. |
| The fix is small: about 10 lines removed, about 15 added. | |

## 6. What hosts see

| Situation | Before | After |
|---|---|---|
| Install or upgrade | No acme.sh | acme.sh 3.1.6, checked against its hash |
| Install or upgrade while GitHub is down | (nothing) | A warning on the console and an error in the install log, and the install continues |
| First custom-domain instance | acme.sh downloaded from `master` | Uses the installed copy |
| acme.sh or the plugin missing | Downloaded again from GitHub | `NO_ACME,INST_ERR`, before anything is created |
| An earlier download failed | Empty file kept, issuing broken | Not possible: a failed setup leaves no file |
| `/root/.acme.sh/dns_evernode.sh` | Created by the plugin fallback | Never created |

## 7. What the fix does not cover

- **Existing instances.** A tenant's `~/.acme.sh/acme.sh` is copied when the instance is created. Instances created before this fix keep the copy from `master` until they are redeployed.
- **The rest of the custom-domain feature.** Certificates and keys in tenant folders (C3), domain authorization (C4), the NPMplus token in tenant files (H1), the cleanup script (H4), the weekly cron (M10), the certificate expiry check (M11), the plugin's nameserver loop (M12) and `curl -k` (M13) are unchanged.

## 8. How it was checked

- Two separate downloads of `acme.sh` at tag `3.1.6` gave the same SHA-256. The file reports `v3.1.6`, and it still looks for DNS plugins in `~/.acme.sh/`.
- `check_dependencies()` with stubbed `curl`, in three cases: a good download (file kept, executable), a failed download and a wrong hash (both: no file left, error in the log, warning on the console, install continues).
- `check_dependencies()` with the real `curl`: downloaded, hash matched, file executable.
- The `NO_ACME` check in five cases: it stops when either file is missing on an NPMplus host with a domain, and continues when both files are present, when no domain is set, and on non-NPMplus hosts.
- `bash -n` passes for both scripts. `shellcheck` 0.10.0 shows no new findings (`user-install.sh` 60, `sashimono-install.sh` 218).
- `grep`: no `ACME_SH_URL`, `ACME_DNS_PLUGIN_URL`, `gadget78/sashimono` or `wget` left in `dependencies/`, `installer/` or `src/`.

**Not yet done:** an install and an upgrade on a real host, and a custom-domain instance on an NPMplus host.

## 9. Suggested release note

> The installer now sets up a pinned, hash-checked acme.sh (3.1.6). Instance creation no longer downloads any code. On NPMplus hosts, an instance with a custom domain fails with `NO_ACME` if acme.sh or its DNS plugin is missing.
