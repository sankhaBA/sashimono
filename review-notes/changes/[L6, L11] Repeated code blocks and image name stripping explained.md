# L6 and L11: Repeated Code Blocks, and How the Image Name Is Cleaned

This note covers two Low findings from `GADGET_COMMITS_REVIEW.md`, fixed together on 2026-10-12:

- **L6.** The same code is copied several times in `dependencies/user-install.sh`.
- **L11.** The C++ agent removes the tenant's settings from the docker image name in a loose and undocumented way (`src/hp_manager.cpp`).

They are fixed together because both come from the same feature: **tenant settings in the image name**.

## 1. Background: settings inside the image name

Gadget's feature lets a tenant pass settings to the host by adding them to the docker image tag. Each setting starts with `--`:

```
evernode/sashimono:hp.latest--peer--1234--user--8080--env1--API_KEY-abc
                   └─ tag ─┘ └────────────── settings ──────────────────┘
```

Two parts of Sashimono handle this name:

1. **`user-install.sh`** reads the settings (ports, domain, SSL, env vars) and sets up the instance.
2. **`hp_manager.cpp`** (the C++ agent) runs `docker create`. Docker can't use a name full of settings, so the agent has to remove them first.

## 2. L6: repeated code blocks

### How and when it was created

All the duplicated blocks come from Gadget's large first commit `10078bb` (2025-06-14, more than 900 lines in one commit), plus `696139f` (2025-06-19) for the quota cron strings.

Each new setting or branch was added by copying the block above it and changing a name. That works, but every later fix has to be repeated in every copy, and the copies drift apart. L5 showed this already: all four env blocks printed `found env1`, because the message was copied without being updated.

### What was copied

| Block | Copies | Why it was copied |
|---|---|---|
| Settings parsing (`if [[ name == "peer" ]] ...`) | 14 near-identical `if` blocks | one per setting name |
| Env var parsing (`env1` to `env4`) | 4 identical blocks | one per env slot |
| Quota cron strings (`quota_crontab_*`) | 2 | one in each branch (custom settings / no custom settings) |
| Certificate download, unzip and rename (inside the generated `domain_ssl_update.sh`) | 2 | "new certificate" path and "existing certificate" path |
| Start the watcher service and register its cleanup lines | 2 | one in each branch; only the service name differs |

### Why Gadget probably did it this way

Copy-and-edit is the fastest way to add one more case to a shell script, especially when the code generates other scripts through heredocs and multiple levels of escaping (see L7). A function or loop in that setting takes more thought about escaping. Copying avoided that, at the cost of maintainability.

### What we changed (`dependencies/user-install.sh`)

1. **Settings parsing became one `case` statement** (line 193).
   - `peer | user | gptcp1 | gpudp1 | gptcp2 | gpudp2` share one branch. It sets `internal_<name>_port` with `printf -v`.
   - `env[1-4]` share one branch. It sets `internal_env<N>_key` and `internal_env<N>_value` the same way.
   - `printf -v` only ever receives names that matched a `case` pattern, so tenant input can't choose which variable gets set.
2. **The quota cron strings are defined once** (line 850), before the branch, and both watcher services use them.
3. **The certificate download is one function** in the generated script: `download_npm_cert()` (line 581).
   - It returns 1 on failure.
   - Each caller keeps its own failure handling, because those were different on purpose. The "new certificate" path also deletes the broken certificate from NPMplus.
4. **Starting the service and writing the cleanup lines happens once**, after the branch (line 983). Each branch now only sets `watcher_service` to `docker_recreate.service` or `docker_vars.service`.

The output is unchanged: every generated file, command and cleanup line is the same as before. Behaviour fixes for this code (for example M9 and M10) were deliberately left for their own findings.

## 3. L11: loose `--` stripping in C++

### How and when it was created

Gadget added this in `e472bd1` (2025-07-12), described in the commit message as "image_name correction":

```cpp
auto pos = image_name.find("--");
if (pos != std::string::npos) {
    image_name = image_name.substr(0, pos);
}
```

It cuts the name at the **first `--` anywhere**. Its brace style was later fixed in `2d346ce`, but the logic stayed the same.

### Why Gadget probably did it

Before this, the full name (with all its settings) went to `docker create`, and `user-install.sh` ran `docker tag` to make that long name exist locally. That breaks easily: a docker tag can be at most 128 characters, and every setting makes it longer.

Cutting at the first `--` was the quickest way to give docker the real image name. It worked on everything Gadget tested, because none of those images had `--` before the tag.

### What was wrong with it

- **It cut in the wrong place.** Docker allows `--` in repository names (for example `my--org/my--img:v2`). The old code cut that to `my`, a different image.
- **A tag holding only settings produced an invalid name.** `img:--peer--1234` became `img:`. Meanwhile `user-install.sh` treats that case as `latest` and pulls `img:latest`, so the two sides disagreed.
- **A name starting with `--` produced an empty name.** That was only discovered at `docker create`, after the Linux user had already been created and had to be rolled back.
- **There was no comment** explaining what `--` means here.

### What we changed (`src/hp_manager.cpp`, `src/hp_manager.hpp`)

There's a new function, `strip_image_settings()` (line 250), with a doc comment explaining the convention:

- **It only searches the tag.** The tag is what follows the last `:`, but only if that `:` comes after the last `/`. Any `:` before that is a registry port, as in `host:5000/img`.
- **A tag that only holds settings becomes `latest`,** which matches what `user-install.sh` pulls.
- **It rejects a result that is empty or starts with `-` or `:`.** A name starting with `-` could also be read by docker as a command-line option.

`create_new_instance()` now calls it **before** `install_user()` (line 176). An invalid name now fails straight away with the existing, previously unused error code `docker_image_invalid`, and no Linux user is created and then removed.

The full name is still passed to `install_user()`, because `user-install.sh` needs the settings.

| Image given by the tenant | Old result | New result |
|---|---|---|
| `evernode/sashimono:hp.latest--peer--1234` | `evernode/sashimono:hp.latest` | same |
| `my--org/my--img:v2--peer--1` | `my` ❌ | `my--org/my--img:v2` |
| `img:--peer--1234` | `img:` ❌ | `img:latest` |
| `registry.local:5000/team/img:1.0--peer--1` | `registry.local:5000/team/img:1.0` | same |
| `--peer--1234` | empty, fails late ❌ | rejected early (`docker_image_invalid`) |

Images without settings are never changed.

### Still open (other findings)

- **The shell side splits the name at the first `:`** (`cut -d':' -f2`), so it still mishandles registries with a port. That's part of M8 (validating settings).
- **The `docker tag ... ${docker_image}` line in `user-install.sh` is now unneeded,** and can still fail when the tag is over 128 characters. That's part of L4 (dead code).

## 4. How it was verified

All the tests ran in a scratch folder. Nothing ran on a real host.

- **Settings parser.** The old and new parsing code were run on the same 16 image names: normal tags, every setting, unknown settings, a repeated `env3`, a tag holding only settings, and wrong-case names. Every variable came out identical.
- **Generated files and cleanup lines.** The old and new service sections were run with `sudo`, `chown` and `jq` replaced by stubs, for both branches and with NPMplus on and off. All generated files (`env.vars`, `docker_recreate.sh`, the systemd units), every `systemctl` call and every cleanup line were byte-for-byte identical.
- **Generated `domain_ssl_update.sh`.** Rendered from both versions and checked with `bash -n`. The diff shows only the new function and the two calls to it. The function was also run with stubbed `curl` and `unzip`:
  - **Success:** the files are renamed, `NPM_CERT_ID_STRING` is set, and the cleanup line is added.
  - **Failure:** it returns 1.
- **C++.** `hp_manager.cpp` compiles with `g++ -std=c++17 -fsyntax-only`. `strip_image_settings()` was copied from the source file into a small test program and passed all 12 cases, including those in the table above.
- **`bash -n dependencies/user-install.sh`** passes.

**Not yet done:** a full `make` build, and creating a real instance with and without custom settings on a test host.
