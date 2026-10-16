# [L9] Hard-coded Paths, URLs and DNS Servers

This note covers finding **L9** from `GADGET_COMMITS_REVIEW.md`, fixed on 2026-10-13. It also fixes one part of **M5** (the Docker Hub URLs), which shares the same code.

## 1. Background

L9 is about values written straight into the code, where they should come from something that knows the real answer: the install location, the image's own registry, the operator's network, or the tenant's domain. Each value works on the host Gadget tested on, and quietly does the wrong thing on a host set up differently.

All five problems come from Gadget's first, large commit **`10078bb` (2025-06-14)**, which added the domain/SSL feature and the Docker image cache.

## 2. What was wrong, and why Gadget probably did it

| # | Hard-coded value | What goes wrong | Likely reason |
|---|---|---|---|
| 1 | `/usr/bin/sashimono/acme.sh` and `/dns_evernode.sh` (9 places) | The script already knows its own folder (`$script_dir`, line 37), and the rest of the script uses it. On an install anywhere else, this code thinks the files are missing and downloads them from GitHub instead. | `/usr/bin/sashimono` is where the files are on a normal host, so it worked in testing. |
| 2 | Docker Hub URLs in the image-cache check | Every image was checked against Docker Hub, using the name as written. Official images like `ubuntu:22.04` are really `library/ubuntu` on Docker Hub, so the check asked for a repository that doesn't exist. Images from other registries (`ghcr.io/...`, `host:5000/...`) were also sent to Docker Hub, which has never heard of them. | The feature was built to avoid Docker Hub's rate limit for Evernode's own images (`evernode/...`), which happen to work. |
| 3 | DNS servers: `@8.8.8.8` in the acme.sh plugin, `@1.1.1.1` in the domain TXT check | Two different servers for checks belonging to one feature, so they can disagree, for example while a new TXT record is still spreading. On networks that block outside DNS, every lookup times out, and there's no way to change it. | Public resolvers avoid a local or internal DNS hiding what the internet sees. That's a good reason, but it's hard-coded and inconsistent. |
| 4 | Proxy target `$(hostname -I \| cut -f1)` | NPMplus is told to forward to the host's **first** address. `hostname -I` has no fixed order, so the first address can be a docker bridge (`172.17.0.1`), a VPN or IPv6. When NPMplus runs on another machine, it often can't reach that address, so the proxy is created but leads nowhere. | On a single-machine setup, the first address is usually the right one. |
| 5 | A `www.` alias on every proxy host | The alias was added even for generated subdomains (`host-3.example.com` → `www.host-3.example.com`). No certificate covered `www.`, so it always showed a certificate error. Also, `${domain//www./}` removed `www.` **anywhere** in the name, so `shop.awww.io` became `shop.aio` and the proxy was created for the wrong domain. | A common "add www too" habit from ordinary websites. `//` (replace all) was probably meant as `#` (remove from the start). |

## 3. What we changed

All in `dependencies/user-install.sh` (and the `domain_ssl_update.sh` it generates), plus `dependencies/dns_evernode.sh`.

1. **Paths.** The 9 hard-coded paths now use `$script_dir`. The download fallback itself is still there; removing it is **H5**.
2. **Docker Hub URLs.**
   - A new helper, `docker_hub_repo()` (line 82), works out an image's Docker Hub repository: `ubuntu:22.04` → `library/ubuntu`, `docker.io/x/y` → `x/y`. It prints nothing for images from another registry.
   - The cache check (line 485) only asks Docker Hub about Docker Hub images, using the correct name. Images from other registries skip the Docker Hub check and use the plain "cached copy, or pull" path. That's what effectively happened before as well, only now without the failing requests to Docker Hub.
3. **One DNS server.**
   - A new optional `mb-xrpl.cfg` key, `proxy.dns_resolver` (line 55), sets the server. It defaults to `8.8.8.8` and must be an IP address or host name.
   - The TXT check uses it, and so does the acme.sh plugin: the generated script exports it as `EVERNODE_DNS_RESOLVER`, and `dns_evernode.sh` reads it.
4. **Proxy target (kept simple).**
   - The generated script now asks the kernel which of this host's addresses is used to reach the NPMplus server (`ip route get`, line 717), and tells NPMplus to forward there.
   - If NPMplus is on the same host (`127.x`), or no route is found, it falls back to the old "first `hostname -I` address", so single-machine setups behave exactly as before.
   - The `proxy_ip` lookup was moved out of the firewall `if`, so it's also set on standalone hosts. Its firewall rules are unchanged.
   - **Not changed, on purpose:** the forward scheme (`https`) and port (`gptcp1`). Making them tenant settings needs M8's validation first.
5. **`www.` alias.**
   - A tenant's own domain gets its `www.` twin (or the bare domain, if they gave `www.…`) **only if that name resolves**. Generated subdomains never get one.
   - That one name list is used for the proxy host, the NPMplus certificate entries (DNS-01 upload and HTTP-01 request) and the acme.sh call (an extra `--domain`), so the certificate always covers every proxy name.
   - The faulty "remove `www.` anywhere" replacement is gone.

## 4. How it was verified

All the tests ran in a scratch folder with stubbed commands. Nothing ran on a real host.

- **`docker_hub_repo()`:** 15 unit cases pass, covering official, user, `docker.io/`, `ghcr.io`, `quay.io`, `host:5000`, `localhost` and digest references.
- **Image cache:** the old and new versions were run with stubbed `curl` and `docker`.
  - Docker Hub images make the same requests and docker calls as before.
  - `ubuntu:22.04` now asks for `library/ubuntu`.
  - `ghcr.io` images no longer send any request to Docker Hub.
- **Proxy names and forward host:** run with stubbed `dig`, `getent`, `ip` and `hostname`, and all four NPMplus JSON payloads checked with `jq`:
  - **`www.` twin resolves:** names are `[example.com, www.example.com]`, and acme gets `--domain www.example.com`.
  - **Twin doesn't resolve:** names are just `[example.com]`.
  - **Domain given with `www.`:** names are `[www.example.com, example.com]`.
  - **Generated subdomain:** no twin.
  - **`shop.awww.io`:** stays `shop.awww.io`.
  - **NPMplus on another machine:** the proxy forwards to `192.168.1.50`, the address on the route to it, where the old code would have picked the docker bridge `172.17.0.1`.
  - **NPMplus local, no proxy address, no route, or a name that doesn't resolve:** falls back to the old address.
- **Firewall:** the old and new `nft` calls are identical in all four test setups. On a standalone host, `proxy_ip` is now also set.
- **Generated `domain_ssl_update.sh`:** rendered from both versions, the diff shows only the intended changes, and both pass `bash -n`.
- **`shellcheck`:**
  - `user-install.sh`: 109 → 103 findings (warning level 8 → 5), with nothing new.
  - The generated script: unchanged at 12.
  - `dns_evernode.sh`: still only its existing `$response` false positive. The now-variable `$nameserver_override` was quoted.

**Not yet done:** a real instance with a custom domain on an NPMplus host (local and remote), and an image from a non-Docker-Hub registry.

## 5. Not changed here

- **M5 (rest):** the digest is still written to one file and read from another, the `mkdir -p` still defeats the "not cached" check, there's no lock around save/load, and the private registry mirror setting is still not used by the check. Only the Docker Hub URL part of M5 is fixed.
- **H5:** the download fallback for `acme.sh` and `dns_evernode.sh` is still there (now with the correct path).
- **L1:** `proxy.dns_resolver` joins the other `proxy.*` keys that no installer creates. It's explained in a comment where it's read, but full documentation of all the keys is L1's job.
- **Certificates that already exist** are not reissued just to add the new `www.` twin:
  - **DNS-01 certificates** (made by this script) include the twin the next time the script reissues them.
  - **NPMplus's own HTTP-01 certificates** keep their original name list when NPMplus renews them. Deleting the certificate in NPMplus makes the next run request a new one with both names.
- **Proxy scheme and port:** see part 4 above.
