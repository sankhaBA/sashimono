# L5: Copy-Paste Errors and Typos in Messages

This note covers finding **L5** from `GADGET_COMMITS_REVIEW.md`. It explains what was wrong and what was changed. **Status: fixed on 2026-10-12.** See the Fix log in `GADGET_COMMITS_REVIEW.md`.

## Why start with L5

Of the Low findings (L1 to L12), L5 is the easiest and safest to fix first:

- It only changes **text**: log messages and comments. No logic, no commands, no config.
- Nothing about how an instance is created changes, so it can't break a host.
- It's easy to check: the script still parses (`bash -n`), and the typos are no longer found by `grep`.

All the changes are in one file, `dependencies/user-install.sh`. The line numbers below are from the current branch (`main.gadget-fixes.low-severity`). They differ from the review because code was removed when C1 and C2 were fixed.

## What to change

### 1. Env messages that all say "env1"

Each of the 4 env blocks prints `found env1`, even for env2 to env4. That makes the install log misleading when you debug the tenant's settings.

| Line | Now | Change to |
|---|---|---|
| 243 | `found env1, key>$internal_env1_key ...` | leave as is |
| 251 | `found env1, key>$internal_env2_key ...` | `found env2, ...` |
| 259 | `found env1, key>$internal_env3_key ...` | `found env3, ...` |
| 267 | `found env1, key>$internal_env4_key ...` | `found env4, ...` |

### 2. Typos

| Line | Now | Change to | Where it shows up |
|---|---|---|---|
| 355 | `unpriviledged` | `unprivileged` | comment |
| 1064 | `unpriviledged` | `unprivileged` | comment |
| 635, 638 | `contract pubic key` | `contract public key` | log line inside the generated `domain_ssl_update.sh` |
| 1002 | `domain-farwading` | `domain-forwarding` | install log |
| 1007 | `NPMplus NOT intalled on host` | `NPMplus NOT installed on host` | text inside a cron job string |

- **Lines 635 and 638** are inside a heredoc. Change only the word `pubic`; keep the escaped `\$contract_publickey` exactly as it is.
- **Line 1007** is inside a single-quoted string that gets written into the crontab. Again, change only the word.
- **`settig`**, which the review also lists, no longer appears anywhere in the repo, so there's nothing to change for it.

### 3. The misleading "File hash matches" message (line 535)

The `if` on line 527 re-pulls the image only when **all** of these are true:

- the digests differ
- the rate limit is a number
- the rate limit is above 60

The `else` branch therefore runs when **any one** of them is false. That includes the case where the digests differ but the rate limit is too low. Even so, it always prints:

```
File hash matches docker hub, AND the Rate limit result is above 60 (=...)
```

That's wrong in most of the cases where it appears. Change it to a message that's true in every case, for example:

```bash
echo "Using cached image (digest unchanged, or rate limit too low/unknown to re-pull: remaining=${RATE_LIMIT_REMAINING})"
```

The `local hash` and `docker hash` lines printed right after it already show which case it was.

Only change the message here. The digest-file mismatch in this same block (it writes one file and reads another) is a real bug, but it belongs to **M5**, not L5.

## How to check the change

```bash
bash -n dependencies/user-install.sh          # no output = still valid bash
grep -n -i -E "intalled|farwading|pubic key|unpriviledged" dependencies/user-install.sh   # should print nothing
grep -n "found env" dependencies/user-install.sh                                           # env1..env4, each once
git diff dependencies/user-install.sh         # only text inside echo/comment lines should differ
```

Because only text changes, no host test is needed. The next normal instance creation will just print the corrected messages.
