# [M4, M5] Image Pull Timeout and Image Cache

This note covers findings **M4** and **M5** from `GADGET_COMMITS_REVIEW.md`, fixed on 2026-10-13. One part of M5, the hard-coded Docker Hub URLs, was already fixed with L9.

## 1. Background

Every Sashimono instance runs its own rootless docker daemon, and a new daemon has no images. So every new instance must get the tenant's image again: the agent passes the image name to `user-install.sh`, and the script puts the image into that instance's daemon.

Getting it from Docker Hub every time is slow, and Docker Hub only allows a limited number of anonymous pulls per IP address. So the idea is a **host-wide cache**: save the image once as a `.tar` in `dockerbin/images/`, and `docker load` it for later instances, as long as Docker Hub still has the same version. "Same version" is decided with the image's **digest**, a fingerprint (`sha256:...`) of one exact version. A tag like `latest` can move, but a digest never changes.

How this code got here:

| When | Change | Result |
|---|---|---|
| Up to July 2024 | `timeout 120s docker pull` | Had a timeout, but no cache. |
| PR #415 (`140e742`, 2024-07-22) | Image downloaded by `download-frozen-image-v2.sh` (fetched from moby `master`), packed into a `.tar`, then `docker load`ed | No cache: the `.tar` was rewritten for every instance and never reused. **The timeout was dropped here** (the `docker pull` line was commented out). The script only knows Docker Hub, and it bypassed the operator's registry mirror. |
| Gadget `10078bb` (2025-06-14) | Keeps the `.tar` and a digest, checks Docker Hub's current digest and the remaining rate limit, and reuses the `.tar` when they match | The right idea, with the bugs below. |
| Gadget `66709f5` (2025-08-09) | Back to `docker pull` + `docker save` instead of the downloader script | Works for every registry and uses the mirror again, but still no timeout. |
| Gadget `9da5ea9` (2025-08-09) | `mkdir -p $img_local_path` | Fixed "`docker save` can't write the file, because its parent folder doesn't exist", but created the wrong folder. |

## 2. What was wrong

### M4: no timeout

`docker_pull_timeout_secs=180` was defined but never used. If the network stalled during a pull, `docker pull` waited forever, so `user-install.sh` never finished, and the agent waiting on it never answered. `mb-xrpl` handles one lease at a time (`sashiCli.wait()`), so **every later lease waited too**, and each one timed out. The half-created instance was never rolled back, because a hang is not a failure.

### M5: the cache

1. **Two digest files.** The first pull wrote `<name>.tar.image_digest`, but the comparison read `<name>/image_digest`. So the second instance of an image always pulled again.
2. **`mkdir -p $img_local_path`** created an empty folder next to every `.tar`. It also made the "is it cached?" check `[[ ! -d "$img_local_path" ]]` always false. Only the parent folder was needed.
3. **Old images used silently.** The image was pulled again only if the digest changed **and** Docker Hub reported more than 60 pulls left. With fewer left, or when the Docker Hub check failed, the old `.tar` was loaded and the tenant got an outdated image without knowing.
4. **No lock.** Two instances of the same image at once could both `docker save` into the same `.tar`, and a third could `docker load` a half-written file.
5. **Digest written before the save.** If `docker save` failed halfway (disk full, killed), the digest file already said "this version", so later instances kept loading a broken `.tar`.
6. **Names mapped with `tr : -`.** `foo:bar-baz` and `foo-bar:baz` both became `foo-bar-baz.tar`. And the name comes from the tenant, so `a/../../x` created folders and files outside `images/`, before docker ever checked the name.

## 3. What we changed

All in `dependencies/user-install.sh`, plus `installer/docker-install.sh`.

1. **Pull with a timeout.** `pull_docker_image()` (line 113) runs `docker pull` under `timeout` with `docker_pull_timeout_secs`, and rolls back with `DOCKER_PULL` on failure or timeout. The timeout was lowered from 180 s to 120 s, the value used before PR #415. `mb-xrpl` destroys a lease anyway once creating it takes more than 80% of the network's `leaseAcquireWindow`, which is 160 s on mainnet (128 s). A pull still running after 120 s can't produce a usable lease, and waiting longer only holds up the next leases.
2. **One digest check.** `docker_hub_digest()` (line 100) asks Docker Hub for the tag's current digest, with a 10 s limit per request. It replaces the two copied blocks, and the rate-limit request is gone.
3. **One decision** (from line 445):
   - **Load the cache** only if Docker Hub's digest is known, equals the stored one, and the `.tar` exists.
   - **Otherwise pull**, whatever the remaining rate limit is.
4. **Store what was really pulled.** After a pull, the digest docker itself recorded (`RepoDigests`) is stored, not the answer Docker Hub gave a moment earlier. If the image was pushed in between, or a registry mirror is behind Docker Hub, the next install sees a difference and pulls, instead of trusting a wrong match.
5. **Save safely.** Remove the old digest → save to `<tar>.tmp` → move it into place → write the new digest. If the save fails, the temp file is removed and the install **continues with a warning**. The image is already in the instance's docker; only the cache is skipped.
6. **Lock.** `flock` on `<tar>.lock` (line 456) covers the check, pull, save and load. A second install of the same image waits, then loads the first one's `.tar` instead of pulling again. The lock is taken in the main shell, so a `rollback` (which calls `exit`) releases it too.
7. **New layout: `images/<docker hub repo>/<tag>.tar`.**
   - For example: `images/evernode/sashimono/hp.latest-ubt.20.04.tar`, `images/library/ubuntu/22.04.tar`.
   - Repository names can't contain `:` and tags can't contain `/`, so two different images can't share a file.
   - Only names in Docker's repository/tag format are cached. Anything else (including `..` tricks) is just pulled, and docker rejects invalid names.
8. **Other registries** (`ghcr.io/...`, `host:5000/...`) are always pulled and never cached, because there is no way to check their current digest before loading an old copy.
9. **Cleanup.**
   - The commented-out pull, downloader and `tar` lines are removed.
   - `docker-install.sh` no longer downloads `download-frozen-image-v2.sh`.
   - On every install and upgrade (after the agent has been stopped), `docker-install.sh` deletes that script and empties `dockerbin/images`. This removes the cache files left on existing hosts by PR #415 (an extracted folder plus a `.tar` per image name) and by Gadget's layout. The first lease of each image after an upgrade pulls it again.

## 4. Example: what an operator sees

First lease of `evernode/sashimono:hp.latest-ubt.20.04` on a host:

```
Docker Hub digest: sha256:f659..., cached digest: none.
Pulling the docker image evernode/sashimono:hp.latest-ubt.20.04.
Docker image evernode/sashimono:hp.latest-ubt.20.04 pull complete.
Saving the docker image to the cache .../images/evernode/sashimono/hp.latest-ubt.20.04.tar.
```

Second lease, with the image unchanged on Docker Hub:

```
Docker Hub digest: sha256:f659..., cached digest: sha256:f659....
Loading the cached docker image .../images/evernode/sashimono/hp.latest-ubt.20.04.tar.
Docker image evernode/sashimono:hp.latest-ubt.20.04 load complete.
```

After Evernode pushes a new build under the same tag, the digests differ, so the image is pulled again and the cache is replaced.

## 5. How it was verified

- **Stubbed `docker` and `curl`**, running the real block from the script:
  - first pull
  - cache hit
  - digest changed
  - Docker Hub unreachable
  - save failure
  - the install after a failed save
  - pull timeout
  - mirror lag
  - non-Docker-Hub image
  - digest reference (`img@sha256:...`)
  - `..` in the repository and in the tag
  - official image
  - the `foo:bar-baz` / `foo-bar:baz` pair

  Each case made the expected calls and left the expected files (details in the fix log).
- **Two installs at the same time:** one pull and save, then the second waited and loaded the `.tar`.
- **Live Docker Hub:** `docker_hub_digest()` gave the same digest that docker stores in `RepoDigests` after a pull. This was checked for a multi-arch image (`busybox:1.36`) and Evernode's single-arch image.
- **Real local docker (28.1.1):** pull, save, then `docker load` from the cache on the second run.
- **`docker-install.sh`:** on a fake `dockerbin`, the cache folder and the downloader were removed and the other files kept.
- **Pull timeout, real docker:** pulling `node:20` with the timeout set to 2 s was cut off after 2 s and rolled back.
- `bash -n` passes for both scripts, and `shellcheck` finds nothing new (`user-install.sh` 91 → 71 findings, `docker-install.sh` 17 → 15).

**Not yet done:** creating real instances on a host with rootless docker 24.0.5, and a real `rollback` while the lock is held.

## 6. Not changed here

- **The registry mirror** (`docker_registry`) is still not asked for the digest. That is safe now, because the stored digest is what was really pulled. A lagging mirror leads to a re-pull, never to an old image.
- **Digest references** (`image@sha256:...`) and **registry ports** in the shell's image-name parsing belong to **M8**. Such images skip the cache.
- **`docker tag ${docker_pull_image} ${docker_image}`** stays for **L4**.
