# [M6, M7, M8, M9] Image Tag Settings and env.vars

This note covers findings **M6**, **M7**, **M8** and **M9** from `GADGET_COMMITS_REVIEW.md`, fixed on 2026-10-14. All four are parts of one feature, so they were fixed together.

## 1. Background

Gadget's commit `10078bb` lets a tenant add **settings to the image tag**, separated by `--`:

```
myapp:v1--user--8080--peer--9000--env1--API_KEY-abc123--domain--example.com
```

| Setting | Meaning |
|---|---|
| `peer`, `user`, `gptcp1`, `gptcp2`, `gpudp1`, `gpudp2` | the port **inside the container** that the instance's host port is mapped to |
| `env1` … `env4` | an environment variable, written as `KEY-value` (`__` becomes a space, `..` becomes `$`) |
| `domain`, `subdomain`, `ssl` | the NPMplus domain setup |
| `contract` | `true` to still run `run /contract` (HotPocket) when other settings are given |

Two terms:

- **Host port / container port.** Each mapping is `-p <host port>:<container port>`. The agent picks the host ports from its own pool. The settings only change the container side. Every container has its own network namespace, so container ports never clash with the host or with other tenants.
- **`env.vars`.** A file of variables for the tenant's app (ports, quota, domain). Docker's `--env-file` puts it in the container's environment, and a copy sits in `/contract/env.vars`.

## 2. How it worked before

The agent always created a plain HotPocket container. Gadget couldn't change that command, so `user-install.sh` set up a **watcher**:

1. It wrote `docker_recreate.sh` and a systemd user service that waited for the first `docker create` event (`docker_vars.service` when there were no settings).
2. The agent ran its normal `docker create`.
3. The watcher saw the event, then **stopped and deleted** the container and created it again with the tenant's ports and `--env-file`. It copied `env.vars` into the contract directory, installed the cron jobs and ran the domain setup.

## 3. What was wrong

### M6: race conditions

- `docker events` only sees events that happen **after** it connects. If the agent's `docker create` came first, the watcher waited forever, and the instance silently had no ports, no `env.vars`, no cron jobs and no domain.
- The watcher deleted the container while the agent might be starting it (`docker start` during `initiate`).
- It copied only `Mounts[0]`, and ran `docker ps` before setting `DOCKER_HOST`.

### M7: tenant code in the operator's shell

`.bashrc` ran `source <contract dir>/env.vars`. The contract directory is the tenant's `/contract`, so anyone opening a shell as that user (`sudo -u sashiXXX bash`) ran whatever the tenant had written there, **on the host**.

### M8: no validation

- Ports such as `abc`, `99999` or `08080` were accepted and then used in `$(( ))`, unquoted commands and generated scripts. Only an accidental `docker tag` call stopped the worst characters.
- `cut -d':' -f2` took the text after the **first** `:`, so `host:5000/img:v1--user--8080` and `img@sha256:…` were split wrongly, and the shell and C++ could disagree on the image name.
- Unknown or misspelled settings were silently ignored.

### M9: wrong values in `env.vars`

- `RAM_QUOTA="2GB"` reached the app with the quotes. `DISK_USED` was the literal text `$(( DISK_USED_BYTES / 1024 / 1024 ))GB`.
- `*_BYTES` held KiB. Under 1 GB showed as `0GB`.
- Over the quota limit, `quota` prints `51234*`, and that was stored as is.
- `INTERNAL_GPTCP2_PORT` ignored the tenant's `gptcp2` (same for UDP), so the app read the wrong port.
- Every container got `KEY1=1` … `KEY4=4`.

## 4. What we changed

### Parse and check first (M8)

All settings are read and checked at the top of `user-install.sh` (lines 146-263), **before** the user is created. Bad input stops with `INVALID_IMAGE_SETTINGS,INST_ERR` and a line giving the reason, so nothing has to be rolled back.

- The tag is split exactly like `strip_image_settings()` in `hp_manager.cpp`, so the image pulled is the one the container is created from.
- A tag with settings must be up to 128 of `[A-Za-z0-9_.-]`, the docker tag characters.
- Every setting needs a name and a value. Unknown or repeated names are rejected.
- Ports must be `1-65535` with no leading zero. Two settings can't use the same container port. The peer port is published on TCP **and** UDP, so it is checked against both groups.
- Domains and subdomains must be valid host names. `ssl` and `contract` must be `true` or `false`.
- Env keys must be valid variable names, and can't repeat or override a built-in variable.

Example:

```
Found image setting 'user' with value '9000'.
Found image setting 'peer' with value '9000'.
Invalid image tag settings in 'img:v1--user--9000--peer--9000'. The container port 9000 is used by more than one of peer, user, gptcp1 and gptcp2.
INVALID_IMAGE_SETTINGS,INST_ERR
```

### The agent creates the right container (M6)

- `user-install.sh` writes `~/.docker/container.cfg`:

  ```json
  {
      "peer_port": 22861,
      "user_port": 8080,
      "gp_tcp_port_1": 36525,
      "gp_tcp_port_2": 36526,
      "gp_udp_port_1": 39064,
      "gp_udp_port_2": 39065,
      "run_contract": false
  }
  ```

- `create_container()` reads it (`read_container_settings()`), checks every value again (whole numbers 1-65535, a real boolean), and runs one `docker create` with `host:container` ports, `--env-file ~/.docker/env.vars`, and `run /contract` only when `run_contract` is true. With no settings, the file holds the host ports and `true`, so the command is the same as before Gadget's change apart from `--env-file`.
- There is no watcher, no recreate and no `docker tag` alias any more.
- Some work still has to wait for the contract directory, which the agent creates just before the container. That moved into a oneshot user unit, `instance_setup.service`. It writes `/contract/env.vars` and, on NPMplus hosts, runs the first domain setup. The agent starts it right after `docker create` without waiting (`--no-block`), because the domain setup can take minutes. It is not enabled, so it doesn't run again at boot.
- The cron jobs are installed directly by `user-install.sh` (`crontab -u`), and `user-uninstall.sh` removes them and stops the setup unit. Nothing relies on the tenant-owned cleanup script for this.
- `container.cfg`, `env.vars` and the generated scripts live in the user's home, so rollback and lease destroy remove them with it.

### Clean `env.vars` (M9)

```
HOST_DOMAIN_ADDRESS=node1.example.com
CUSTOM_DOMAIN_ADDRESS=node1-1.example.com
RAM_QUOTA_BYTES=2147483648
DISK_QUOTA_BYTES=10737418240
EXTERNAL_PEER_PORT=22861
INTERNAL_PEER_PORT=9000
...
INTERNAL_GPTCP2_PORT=7000
API_KEY=a b$c
```

- Plain `KEY=value`, real bytes, the tenant's `gptcp2`/`gpudp2`, and only the env keys the tenant set.
- `DISK_USED_BYTES` and `DISK_FREE_BYTES` change over time, and an environment variable can't change after the container starts. So they are only in `/contract/env.vars`, which `~/.docker/env_vars_update.sh` rebuilds every 5 minutes (stripping `quota`'s `*`).
- That file is built in `~/.docker` and **renamed** into the contract directory. Writing a temp file inside `/contract`, as Gadget's cron did, would let the tenant plant `env.vars.tmp` as a symlink to `../.bashrc` and bring M7 back.

### No more `source` (M7)

The two lines are removed, and the `.bashrc` block is the same as before Gadget's change.

## 5. Behaviour changes to know about

- Every container now gets `--env-file`, not only those with settings.
- Variables renamed or removed: `RAM_QUOTA` → `RAM_QUOTA_BYTES`, `DISK_QUOTA` → `DISK_QUOTA_BYTES` (both in bytes). `DISK_USED`, `DISK_FREE` and `KEY1..4` are gone. `DISK_USED_BYTES` and `DISK_FREE_BYTES` are only in `/contract/env.vars`.
- Settings that used to be ignored or half-applied now fail the install. The tenant sees `user_install_error`. The reason is in the sagent log.
- `--contract--false` on its own now runs the image's own command (it used to be ignored).

## 6. How it was verified

- `sagent` builds. The rendered `docker create` fits its buffer, with and without `run /contract`.
- The C++ settings reader rejects out-of-range, negative, string, float, boolean, null, missing and zero ports.
- The parsing block, run on its own: 15 valid and 26 invalid tags, each with the expected result.
- Generated files rendered with stubs. `instance_setup.service` passes `systemd-analyze verify`, and the weekly cron line is the same text as before.
- `env_vars_update.sh` with a stubbed `quota` (normal, over the limit with `*`, no quota). A symlink or directory planted by the tenant can't redirect the write.
- Real docker (28.1.1): the rendered `docker create` gives all 7 bindings, the env values unchanged (`a b$c`), and the expected command.
- `bash -n` passes. `shellcheck`: `user-install.sh` 71 → 60, nothing new.

**Not yet done:** real instances on a test host (plain HotPocket, custom ports and env, `contract=true`, an NPMplus domain), a lease destroy, and a rollback.

## 7. Not changed here

- Any tag setting without `contract=true` still drops `run /contract` (Gadget's rule). The HotPocket image has no default command (its entrypoint is `hpcore`), so a HotPocket tenant who adds only `--env1--FOO-bar` gets an instance that doesn't run its contract. With `contract=true`, remapping `user` or `peer` still points at ports HotPocket doesn't listen on. Both are for the domain/image-settings design review.
- `domain_ssl_update.sh` also writes into the contract directory (`tls/`), so the symlink concern applies there too (domain review: C3, C4, H1).
- The weekly cron schedule (M10).
