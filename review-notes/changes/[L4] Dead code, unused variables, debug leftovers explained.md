# L4: Dead Code, Unused Variables, Debug Leftovers

This note covers finding **L4** from `GADGET_COMMITS_REVIEW.md`. **Status: partly fixed on 2026-10-14.** See the Fix log in `GADGET_COMMITS_REVIEW.md`.

## 1. What L4 is

L4 groups six leftovers from Gadget's commits. Most are only clutter. One of them (the extra `docker tag`) is not needed, but it is the only thing blocking a root command injection, so it has to stay until M8 is fixed.

| # | Leftover | Where | Status |
|---|---|---|---|
| 1 | `ctx.dns_evernode_sh` | `src/conf.hpp`, `src/conf.cpp` | ✅ Removed in this fix |
| 2 | `docker_pull_timeout_secs` never used | `user-install.sh` | ✅ Fixed by M4: `pull_docker_image()` uses it |
| 3 | Commented-out pull / downloader / `tar` code | `user-install.sh` | ✅ Removed by the M4/M5 fix |
| 4 | Copy of `dns_evernode.sh` into `/root/.acme.sh` | `user-install.sh`, acme.sh setup | ✅ Removed by the H5 fix |
| 5 | `docker tag ${docker_pull_image} ${docker_image}` | `user-install.sh`, after the image block | Open: must stay until M8 |
| 6 | Hand-bumped `version=1.9` | `user-install.sh` and the generated `domain_ssl_update.sh` | Open |

Items 4 and 6, and the `echo` lines around item 5, were removed at first, then reverted at the team's request. They are described in section 3 for whoever picks them up. Item 4 was later removed by the H5 fix, together with the download around it.

## 2. What was changed

### `ctx.dns_evernode_sh`

Gadget added a field to the agent's context that holds the path of `dns_evernode.sh`. No code in `src/` ever reads it: the agent never runs or copies that file, and only `user-install.sh` uses it (through `$script_dir`). The field had already caused trouble twice. It was added without its header declaration, so the merged PR did not compile until `2d346ce`, and `d704108` fixed a `.sh.sh` typo in it.

The field and its assignment are removed. The `dns_evernode.sh` file itself is still built and installed, because acme.sh needs it.

**What hosts see:** nothing. The agent only stops building a string it never used.

## 3. What is still open

### The `/root/.acme.sh/dns_evernode.sh` copy

**Status: ✅ removed by the H5 fix (2026-10-15).**

When the plugin is missing from `$script_dir`, the script downloads it and also copies it into `/root/.acme.sh`. But every custom-domain instance gets its own copies:

```bash
cp "$script_dir"/acme.sh $user_dir/.acme.sh/acme.sh
cp "$script_dir"/dns_evernode.sh $user_dir/.acme.sh/dns_evernode.sh
```

and the generated script runs `$user_dir/.acme.sh/acme.sh --dns dns_evernode`. acme.sh looks for a DNS plugin next to its own script first, so it always uses the per-user copy. The root copy is never read.

**Fix:** remove the `mkdir -p /root/.acme.sh` and `cp` lines. The download fallback around them (`wget` from Gadget's GitHub branch) belongs to **H5**, which removes it completely, so this item can also be done as part of H5. The full uninstaller already deletes `/root/.acme.sh/dns_evernode.sh` (added in L2).

### The extra `docker tag`

A tenant's image name can carry settings in its tag, for example:

```
myimg:v1--domain--shop.example.com--gptcp1--443--env1--API_KEY-abc...
```

`user-install.sh` pulls the plain image (`myimg:v1`, `$docker_pull_image`). It then tags it with the full name (`$docker_image`), because the agent used to run `docker create` with the full name.

That stopped being needed with **L11**: `strip_image_settings()` in `hp_manager.cpp` now removes the settings before `docker create`, so the container uses `myimg:v1`. `docker_recreate` reads the image back from the container's `Config.Image`, which is also `myimg:v1`. Nothing uses the full-name tag.

It is also a failure path. Docker allows at most 128 characters in a tag, and a domain plus a few env settings goes over that easily:

```
$ docker tag hello-world:latest "hello-world:<131-character settings tag>"
Error parsing reference: "..." is not a valid repository/tag: invalid reference format
```

The script then runs `rollback "DOCKER_PULL"`. The instance is not created, and the error points at the pull, not at the tag.

#### Why the line has to stay for now

The same check protects the host. The agent passes the image name to `user-install.sh`, which runs as root, without checking it, and the settings are never validated (finding **M8**). Two places after the tag line treat them as code:

- **Bash arithmetic.** The `env.vars` heredoc has `$((internal_gptcp1_port + 1))`. Bash evaluates the variable's contents as an expression, and runs `$(...)` found in an array index. A port setting of `x[$(cmd)]` would therefore run `cmd` **as root**.
- **The generated `domain_ssl_update.sh`.** It contains `custom_docker_domain="<domain setting>"`, so a domain such as `a$(cmd)` would run as the instance user when the script runs (NPMplus hosts).

This was tested: the parser copied from `user-install.sh`, given `myimg:v1--gptcp1--x[$(echo INJECTED...)]` and then that arithmetic, printed the marker. `docker tag` rejects the same name with "invalid reference format", and it runs before both places, so the install rolls back first.

**Fix:** remove the line as part of M8, once M8 validates the settings (ports 1-65535, a domain regex, an env key regex). Whether mb-xrpl or evernode-js already filters image names before they reach the agent was not checked.

### `version=1.9`

Upstream's `user-install.sh` had no `version` variable. Gadget added `version=0.99` in `10078bb` and changed it by hand to `1.9` in `b4e7824`. Its only use is to write `version=1.9` into each generated `domain_ssl_update.sh`, where nothing reads it. It has no link to `version::AGENT_VERSION` (`src/version.hpp`) or to releases, so it can only drift.

**Fix:** remove `version=1.9` at the top of `user-install.sh` and the `version=$version` line in the `domain_ssl_update.sh` heredoc. Existing instances would keep the line in their generated script, which is harmless.

## 4. How it was checked

```bash
grep -rn dns_evernode_sh src/                                   # nothing
for f in $(find src -name '*.cpp'); do g++ -std=c++17 -fsyntax-only -Isrc "$f"; done   # all 12 pass
git diff --quiet HEAD -- dependencies/user-install.sh           # unchanged
```

Plus the real `docker tag` failures shown above (docker 28.1.1), and the injection test in section 3.

**Not yet done:** a full `make` build.
