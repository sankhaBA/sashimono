# Disk Quota and Fstab in Sashimono: The Full Story

This document explains, in plain language, what Sashimono's disk quota system looked like before Gadget's changes, what Gadget changed and why he probably did it, what broke as a result, and exactly what we fixed. It covers only the quota and fstab part of the wider code review in `GADGET_COMMITS_REVIEW.md` (findings C1, C2, H2, and H6).

## 1. A few terms first

**Mounting** means attaching a disk's contents to a folder so Linux can use it. The main disk is mounted at `/`, the root of the whole filesystem.

**`/etc/fstab`** is a text file Linux reads at boot time. It lists every disk that should be mounted, where it should be mounted, and a set of options describing how to treat it. If this file has a typo or an option Linux does not recognize, the affected disk may fail to mount. If that disk is the root filesystem, the machine cannot boot normally and drops into a rescue shell instead.

**Disk quota** is a limit on how much disk space a specific user or group is allowed to use, enforced by the operating system on one shared disk. It works much like Windows lets an administrator put a storage limit on individual user accounts on a single shared drive. Nothing is physically separated. Everyone's files sit on the same disk, but the operating system keeps a running total for each user or group and refuses new writes once the limit is hit.

There are two ways to measure that running total:

- **User quota** counts files by who personally owns them (their user ID).
- **Group quota** counts files by which group owns them, adding up usage across everyone in that group.

## 2. The system before Gadget's changes

Each Evernode lease (an "instance") runs as its own dedicated Linux user on the host, for example `sashi1718039988123456789`. When that user account is created, Ubuntu automatically gives it its own private group with the exact same name. On top of the main process, each instance also runs a second, lower privileged identity called the "contract user", and this contract user is deliberately placed into that same private group.

So, for one tenant, there can be two different identities (two different user IDs) that both belong to the same one group.

Before Gadget's changes, the disk limit for a tenant was enforced as a **group quota**:

```
setquota -g -F vfsv0 "$user" "$disk" "$disk" 0 0 /
```

Because it was a group quota, it did not matter which of the tenant's two identities wrote a file. As long as the file belonged to that tenant's private group, it counted toward that one shared limit.

A simple way to picture this: imagine a lab with many computers, and each computer is shared by one project team. Each team member gets their own personal account on that computer, but the rule is that everyone on the team, combined, has to stay inside the computer's total storage. That was the original design. In reality, all tenants actually share one single disk on the host, not separate physical computers, but the accounting worked exactly like separate portions of a shared pool, measured per project team (per group), not per individual team member.

Setting up the disk itself to support quota at all (adding the right option to `/etc/fstab`, then turning quota tracking on) was the job of a separate script, `prereq.sh`. This is meant to run once, when the host is first prepared, long before any tenant instance exists.

## 3. What Gadget changed, and why he probably did it

Gadget was working on getting Sashimono to run properly on a newer version of Ubuntu, along with newer cgroup handling (a separate, unrelated system used for CPU and memory limits, not disk space). His own commit message for this change says, word for word, "also changed the diskquota system, to try fix bug, this needs testing more!" So this was an admitted, unfinished, in progress fix, not a deliberate redesign.

The most likely explanation, based on what the code actually shows: before this change, the fstab entry used an older "journaled" style of group quota (`grpjquota=aquota.group` together with `jqfmt=vfsv0`). This journaled format is pickier about what other mount options can coexist with it. It is quite likely that this journaled setup did not work correctly on whatever host Gadget was testing with, perhaps because of the newer Ubuntu version he was targeting.

Rather than diagnosing that underlying journaling problem, Gadget swapped the whole mechanism to a simpler, non-journaled `usrquota` option, and to **user quota** instead of group quota, because that combination happened to work on his test machine. He does not appear to have gone back to ask why group quota existed in the first place.

On top of switching the quota type, Gadget also added a safety net directly inside `user-install.sh`, the script that runs every time a brand new tenant instance is created. If this script noticed that quota tracking looked like it was off, it would try to fix the host there and then: rewrite `/etc/fstab` with a text substitution command, delete the quota tracking files, rebuild them from scratch, and even install a kernel package if the host appeared to be a virtual machine. The likely intention was good: make instance creation resilient, so that a host which had not been freshly prepared with the quota feature would not just fail outright. The execution of that intention turned out to be unsafe, for reasons explained next.

## 4. What actually broke

### The fstab corruption (C1)

The fstab rewriting code used a text search and replace command meant to clean up a stray comma in the mount options. Its exact pattern was `s/(\s+)([^,\s]+),/\1\2/`. The author almost certainly intended `\s` to mean "a whitespace character", the way it works in many modern programming languages. In the specific tool being used here (`sed`, in POSIX mode), `\s` does not mean whitespace at all. It is read literally as the two characters backslash and the letter s. Because of that mistake, the command did not do what was intended. Instead, it deleted the first comma found in the list of mount options, merging two unrelated words together.

For example, the option list `rw,relatime` became `rwrelatime,usrquota`, which is not a valid option Linux understands. The option list `discard,errors=remount-ro` happened to survive correctly, purely by luck, because the word `discard` contains the letter s and this changed how the pattern matched.

This is dangerous because `/etc/fstab` controls how the root disk mounts at boot. A broken option there can mean the server does not come back up cleanly after the next reboot. This code ran, unattended, on a live host that could already have other tenants' leases running on it, every single time a new instance was created if quota appeared to be off.

### The quota wipe (C2)

Right after the fstab edit, the same block deleted the files that hold every user's or group's quota limits on the entire host (`rm -f /quota.* /aquota.*`), then rebuilt them from scratch. Those files are shared across the whole host. Deleting them did not just reset the new tenant being created. It erased the configured disk limits for every other tenant already running on that host, until each of their limits happened to be reapplied some other way.

### The surprise kernel install (H6)

The same block, if the host looked like it was running inside a virtual machine, could trigger `apt-get install` for a kernel related package in the middle of creating an ordinary tenant lease. A newly installed kernel package does nothing until the machine reboots, so this did not even solve the original problem right away. It just added risk, delay, and an unannounced system change to what should have been a routine, quick operation.

### The group to user quota gap (H2)

This is the subtler one. After Gadget's change, the script only ever set a **user** quota for the tenant's main identity:

```
setquota -u "$user" "$disk" "$disk" 0 0 /
```

Nobody ever set a quota entry for the tenant's second identity, the contract user. An identity with no quota entry at all is treated as unlimited by Linux, not as "blocked".

Going back to the lab analogy, but corrected to reflect that everyone actually shares one disk, not separate computers: imagine the shared disk as one large pool of cloud storage, where each project team is supposed to get a fixed portion. Before this change, the rule was that the whole team's combined usage, no matter which member's account the files sat under, had to fit inside that one portion. After the change, only one specific team member's account was being measured against that portion. The other member was never given any boundary at all, so that member could keep writing files into the shared pool without any limit of their own. This does not mean that member was reaching into another team's specific portion on purpose. It means nothing was stopping them from using as much of the shared pool as they wanted, which, since the pool is finite and shared, still reduces what is actually left for everyone.

On top of this, the matching uninstall script was never updated to match. It kept clearing a **group** quota, even though install was now setting a **user** quota, so the two scripts disagreed with each other about which kind of quota entry belonged to a tenant at all.

## 5. What we fixed, and exactly what changed

### Fix for C1, C2, and H6: stop trying to repair the host live

We removed the entire "try to fix quota right now" block from `user-install.sh`. If the script notices that quota tracking is off when a new instance is being created, it now simply fails that one instance creation with a clear error (`QUOTA_OFF`) and stops. It no longer touches `/etc/fstab`, no longer deletes any quota files, and no longer installs any packages.

Getting a host ready for quota in the first place remains the job of `prereq.sh`, the one time setup script, which already does this safely: it backs up `/etc/fstab` before changing it, checks whether the new settings actually mounted correctly, and if they did not (for example because journaled quota settings from before are still active and can only be cleared by a reboot), it tells the operator to reboot and try again, rather than forcing anything through.

Because C2's quota file deletion and H6's kernel package install both lived inside that same removed block, fixing C1 this way closed all three issues at once. We did not have to make separate changes for C2 and H6 specifically.

### Fix for H2: bring back group quota everywhere

We switched the whole mechanism back to group quota, end to end:

- `prereq.sh` now adds plain `grpquota` to the root filesystem's `/etc/fstab` entry, instead of Gadget's plain `usrquota`. It checks and turns on group quota tracking (`quotacheck` and `quotaon`, using the group flag) instead of the user equivalents.
- `user-install.sh` now checks whether **group** quota is off, not user quota, before deciding whether to proceed. The actual limit for a new tenant is set with `setquota -g -F vfsv0`, restoring both the group flag and the quota format flag that the original, pre-Gadget code used.
- Each tenant's container runs a small background job every five minutes that reports the tenant's current disk usage back into a file the container can read, so the tenant can see how much space they have used and how much is left. This job was quietly running `quota -u`, the command that reports on user quota. Since user quota is no longer tracked at all, this would have silently stopped reporting anything meaningful. We changed it to `quota -g`, so it reports the figure that is actually being enforced. This change was a simple one word swap, because the tenant's private group always has the exact same name as the tenant's own username, so no new value needed to be looked up.
- We did not add a second, parallel user quota limit on top of the group quota, even though that would have been an easy thing to bolt on. Running two separate quota mechanisms that both have to be kept in sync between the script that creates a tenant and the script that removes a tenant is exactly the condition that caused this whole problem. Keeping only one mechanism removes that risk entirely rather than adding a second place for the same mistake to happen again later.
- Two other scripts, `user-uninstall.sh` and a separate upgrade path in `installer/setup.sh`, needed no changes at all. Both of them had always used group quota and had never been touched by Gadget's commits. This was one of the clearest clues that group quota, not user quota, was always the correct and originally intended design. Our fix simply brought `user-install.sh` back in line with scripts that were never broken in the first place.

## 6. The system today

Disk quota enforcement for Evernode instances is group based again, using the plain (non journaled) `grpquota` option, consistently across every script that touches it: creating a tenant, removing a tenant, updating a tenant's limit later, and the tenant's own self reported usage figures.

Nothing in the day to day instance creation flow edits `/etc/fstab` anymore. That remains the responsibility of `prereq.sh`, run once by the operator when a host is first set up, with proper backups and clear instructions if a reboot turns out to be necessary. If a host somehow still has quota turned off when someone tries to create a new instance, that instance creation now fails immediately with a clear, specific error, instead of the script attempting to repair the host by itself in the middle of handling that request.
