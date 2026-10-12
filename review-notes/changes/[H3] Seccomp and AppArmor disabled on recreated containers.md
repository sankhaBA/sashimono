# Seccomp and AppArmor Disabled on Recreated Containers

This document explains, in plain language, finding H3 from `GADGET_COMMITS_REVIEW.md`: what the problem was, how it got into the code, what it affected, how it was fixed, and why the fix was done this way.

## 1. A few terms first

**Container.** A tenant's instance runs inside a Docker container. A container is not a virtual machine. The code inside it runs directly on the **host's Linux kernel**, the same kernel every other tenant and the host itself use. If a tenant can exploit a bug in that kernel, they can break out of the container (a "container escape") and reach the host or other tenants.

**System call (syscall).** The way a program asks the kernel to do something: open a file, create a network socket, mount a filesystem, load a kernel feature, and so on. Linux has a few hundred of them.

**seccomp.** A filter on system calls. Docker applies a default seccomp profile to every container. It blocks roughly 40 to 50 risky syscalls that normal applications never need, for example `keyctl`, `add_key`, `bpf`, `mount`, `kexec_load` and `userfaultfd`. Many public kernel exploits and container escapes rely on one of these. With seccomp on, the call is refused, and the exploit fails before it starts.

**AppArmor.** A policy on what a process may touch, such as blocking writes to sensitive `/proc` and `/sys` files or blocking mounts. Docker applies a default AppArmor profile (`docker-default`) where AppArmor is available.

**`--security-opt seccomp=unconfined --security-opt apparmor=unconfined`.** Options to `docker create` that turn both of these protections **off** for that container.

**Rootless Docker.** Sashimono runs a separate Docker daemon per tenant, as that tenant's own unprivileged Linux user. "root" inside the container is not real root on the host. This limits the damage of an escape, but it does not protect the shared kernel itself. That is seccomp's job.

## 2. How a tenant's container is normally created

1. `dependencies/user-install.sh` prepares the host side: Linux user, disk quota, rootless Docker, firewall rules.
2. The Sashimono agent (`src/hp_manager.cpp`) runs `docker create` using its `DOCKER_CREATE` template (`src/hp_manager.cpp:34`). That command does **not** pass any `--security-opt`, so Docker's default seccomp and AppArmor profiles apply.

This has been the behaviour since before Gadget's changes, and it is still the behaviour for every instance that does not use custom image settings.

## 3. Where the problem came from

**Who and when:** `gadget78`, commit `10078bb` (2025-06-14), merged in PR #434. This is the large commit that added port mapping, environment variables, the domain/proxy system and the LAN firewall.

**The feature it was part of: custom image settings.** A tenant can put extra settings inside the image tag, separated by `--`, for example:

```
evernode/sashimono:hp.latest-ubt.20.04--peer--1234--env1--FOO=bar
```

`user-install.sh` parses these `name--value` pairs. If any setting is found, it sets `custom_docker_settings="true"`.

The agent has no support for these settings, so the commit added a workaround:

1. The agent creates the container normally (protections on).
2. A user systemd service, `docker_recreate.service`, watches `docker events` for that "container created" event.
3. It runs a generated script, `~/.docker/docker_recreate.sh`, which **stops and deletes the agent's container** and creates a new one with the custom ports and env file.

While building the new `docker create` command, the generated script added:

```bash
# Add security options
docker_create_command="$docker_create_command --security-opt seccomp=unconfined --security-opt apparmor=unconfined"
```

So every recreated container came up with both protections off, whichever setting the tenant actually used.

## 4. Why the author might have added it

The commit message gives no reason, and the author is not available to ask, so this is an informed guess:

- **A debugging shortcut.** During testing, something in the recreated container probably failed with an "operation not permitted" or AppArmor denial. Turning both protections off is the quickest way to make such errors go away, and it is a very common snippet in online answers.
- **Newer Ubuntu.** The author was targeting newer Ubuntu releases. Ubuntu 24.04 tightened AppArmor rules around unprivileged user namespaces, which rootless Docker depends on (`user-install.sh` already has a separate, older AppArmor profile for `rootlesskit` for this reason). AppArmor errors on such a host could easily lead someone to add `apparmor=unconfined` to the container as well.
- **Copied from a general-purpose run command.** Some workloads (Docker-in-Docker, systemd in a container, some browsers) are documented with these flags, and the line may have been carried over from such an example.

None of these reasons apply to Sashimono's own HotPocket images, which run with the default profiles on every non-custom instance.

## 5. What it affected

**Trigger:** any custom image setting at all.

| Tenant uses image... | Container they end up with |
|---|---|
| `evernode/sashimono:hp.latest-ubt.20.04` | Agent's container, **seccomp and AppArmor on** |
| `evernode/sashimono:hp.latest-ubt.20.04--peer--1234` | Recreated container, **both off** |

**Example of abuse.** A malicious tenant wants to try a kernel exploit that needs, for example, `keyctl` or `bpf`. On a normal instance, seccomp refuses the syscall and the exploit fails. By adding a harmless setting such as `--env1--X=1` to the image name, the tenant gets an unfiltered container and can run the exploit. A successful escape lands them on the host as that instance's Linux user. From there, another kernel bug could give them root, and with it every other tenant on the host.

**How serious, in context:**

- Rootless Docker limits the damage of an escape, but it does not stop kernel exploits. Seccomp is what reduces the kernel attack surface, so losing it is the important part of this bug.
- Docker's rootless documentation lists AppArmor as not supported in rootless mode, so `apparmor=unconfined` may have had little real effect on these hosts. It is removed anyway, because it states an intent the platform does not want.
- It was silent. The instance worked normally and nothing was logged, which is why testing did not catch it.

### Pros and cons of the original code

| Pros | Cons |
|---|---|
| Images that rely on syscalls blocked by Docker's default profile would run, but only when the tenant also used a custom setting. | Any tenant could switch off the main kernel sandbox just by adding a setting to the image name. |
| Fewer "operation not permitted" errors while the author was testing. | Containers on the same host had different security levels, with no operator setting or log to show it. |
| | Made container-escape exploits much easier, putting the host and all other tenants at risk. |
| | Did not match the agent's own `DOCKER_CREATE` command, which is the reference for how containers should be created. |

## 6. The fix

**File changed:** `dependencies/user-install.sh`, inside the generated `docker_recreate.sh`.

**What changed:** the `# Add security options` comment and the `--security-opt seccomp=unconfined --security-opt apparmor=unconfined` line were deleted. Nothing was added in their place.

```diff
 # Add Environment variables
 docker_create_command="\$docker_create_command --env-file $user_dir/.docker/env.vars"

-# Add security options
-docker_create_command="\$docker_create_command --security-opt seccomp=unconfined --security-opt apparmor=unconfined"
-
 # Add restart policy
 docker_create_command="\$docker_create_command --restart unless-stopped"
```

With no `--security-opt`, Docker applies its default seccomp profile (and its default AppArmor profile where supported), exactly as it does for the agent's own `docker create`.

### Why this fix

- **It removes the cause, not a symptom.** The recreated container now has the same security as every other container.
- **No detection or blocking logic is needed.** An image cannot ask for seccomp or AppArmor to be turned off. These are `docker create` options chosen by whoever runs the command, which is the host. The tenant never requested `unconfined`. The script added it unconditionally. Removing the line takes the choice away completely.
- **Images that need those syscalls are not "malicious", but they are not allowed.** Legitimate software can use syscalls the default profile blocks: Docker-in-Docker, browser sandboxes such as headless Chrome, `bpf`-based tools. On a shared host the risk is the same whatever the tenant's intent, so the platform rule is "default profile for everyone".
- **Smallest possible change.** It is a deletion only, with no new code paths to test or maintain.

### Pros and cons of the fix

| Pros | Cons |
|---|---|
| All containers get Docker's default kernel protections, whatever the image tag says. | A tenant image that only worked because seccomp was off, **and** that also used a custom setting, will now fail to start. |
| Recreated containers now match the agent's `DOCKER_CREATE` security behaviour. | It does not fix instances that already exist (see below). |
| Pure deletion: nothing new to review, test or maintain. | |
| If an image does break, it fails loudly at startup with "operation not permitted", which is easy to diagnose. | |

**Why the "image may now fail" con is not a critical risk:**

- Default seccomp has always been the setting for every non-custom instance, and Sashimono's HotPocket images run fine with it.
- Only tenants who use custom settings **and** depend on a blocked syscall are affected. The custom-settings feature has not been released yet, so this group is likely very small or empty.
- Most workloads that need those syscalls (mounting, Docker-in-Docker, loading kernel features) also need real root, which rootless Docker does not give them. They would mostly fail even with seccomp off.

## 7. What the fix does not cover

- **Existing instances.** `docker_recreate.sh` runs once, when the instance is created. Instances that were already created with custom settings keep running unconfined until they are redeployed or their lease ends. If any exist on production hosts, they should be checked.
- **Other differences between the recreated container and the agent's container.** These belong to M6 (race conditions, only `Mounts[0]` copied). The proper long-term fix is to build the port and env mapping into the agent's `DOCKER_CREATE` and remove the recreate service entirely. That is part of the image-tag settings design review.

## 8. Suggested release note

> Containers that use custom image settings now run with Docker's default seccomp and AppArmor profiles, like all other instances. Images that depend on syscalls blocked by the default profile are not supported.
