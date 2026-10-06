# Sashimono Agent

## What's here?

A C++ version of sashimono agent

## Libraries

- Crypto - Libsodium https://github.com/jedisct1/libsodium
- jsoncons (for JSON and BSON) - https://github.com/danielaparker/jsoncons
- Reader Writer Queue - https://github.com/cameron314/readerwriterqueue
- Concurrent Queue - https://github.com/cameron314/concurrentqueue
- Boost Stacktrace - https://www.boost.org

## Setting up Sashimono Agent development environment

Tested on Ubuntu 20.04

1. Run `sudo ./installer/prereq.sh`
1. Reboot the machine.
1. Run `./dev-setup.sh`

### Contract instance resource limits (cgroups)

Both cgroup v1 and cgroup v2 hosts are supported. The cgroup version is detected at runtime (`stat -fc %T /sys/fs/cgroup/` returns `cgroup2fs` on cgroup v2, hybrid setups are treated as cgroup v1).

- **cgroup v1** - The cgroup rules engine (`cgrulesengd`) moves processes of the `sashiuser` group into per-user `<user>-cg` cgroups created by `user-cgcreate.sh`.
- **cgroup v2** - Per-instance limits are applied on the systemd user slice of each instance user (`/etc/systemd/system/user-<uid>.slice.d/override.conf`). The cgroup rules engine is not used.

In both cases the `sashimono-cgcreate` service re-applies the limits at system startup.

## Build Sashimono Agent

1. Run `git submodule update --init --recursive` to clone the bootstrap contract for first time.
1. Run `cmake .` (You only have to do this once)
1. Run `make` (Sashimono agent binary 'sagent' and dependencies will be placed in build directory)

## Build Sashimono installer

Run `make installer` ('installer.tar.gz' will be placed in build directory)

## Run Sashimono

1. `./build/sagent new <data_dir> <ip> <init_peer_port> <init_user_port> <docker_registry_port(optional[0])> <instant_count> <cpu_us> <ram_kbytes> <swap_kbytes> <disk_kbytes>` (This will create the Sashimono config in build directory. You only have to do this once)
   1. Example: `sudo ./build/sagent new ./build 127.0.0.1 22861 26201 36525 39064 0 3 900000 1048576 3145728 5242880`
1. `sudo ./build/sagent run`

## Sashimono Client

- Replace the sashimono-client.key file created inside dataDir in the first run by the key file found on this [link](https://geveoau.sharepoint.com/:u:/g/EX5U8SxYyM5Anyq2rAcMXtkBEOO_XWT7hCo30SGIsDAyLg?e=LycwQx). This is because we have hardcoded the pubkey in message board. This will generate the same pubkey we have hardcoded.
- A sample **bundle.zip** bundle can be found [here](https://geveoau.sharepoint.com/:u:/g/EdurCbuttzdCnuQCyIb0SKEBWq4j9LKdgAIjJvt3zwueew?e=lPYfMG).

## XRPL message board

1. Node app which is listening to the host xrpl account.
1. `cd mb-xrpl && npm install` (You only have to do this once)
1. `node app.js new [address] [secretPath] [governorAddress] [domain or ip] [leaseAmount] [rippledServer] [ipv6Subnet] [ipv6Interface] [network]` will create new config files called `mb-xrpl.cfg` and `secret.cfg`
1. `node app.js betagen [governerAddress] [domain or ip] [leaseAmount]` will generate beta host account and populate the configs.
1. `node app.js register [countryCode] [cpuMicroSec] [ramKb] [swapKb] [diskKb] [totalInstanceCount] [cpuModel] [cpuCount] [cpuSpeed] [emailAddress] [description(optional)]` will register the host on Evernode.
1. `node app.js deregister` will deregister the host from Evernode.
1. `node app.js upgrade` will upgrade message board data.
1. `node app.js` will start the message board with ixrpl account data.
1. Optional environment `MB_DEV=1` for dev mode, if not given it'll be prod mode.
1. Optional environment `MB_FILE_LOG=1` will keep logging in a log file inside log directory (used for debugging).
1. Optional environment `MB_DATA_DIR=. node app.js` will read the config files(both 'mb-xrpl.cfg' and 'secret.cfg') from same level of hierarchy.
1. This will listen to redeems on the configured host xrpl account.
1. If sashimono agent and sashi CLI is up, this will issue instance management commands to the CLI.
1. Responses data will be encrypted with redeem transaction account's pubkey and sent back to it as a transaction.

## Code structure

Code is divided into subsystems via namespaces.

**comm::** Handles socket related functionality.

**conf::** Handles configuration. Loads and holds the central configuration object. Used by most of the subsystems.

**crypto::** Handles cryptographic activities. Wraps libsodium and offers convenience functions.

**hp::** Contains hotpocket instance management related helper functions.

**hpfs::** Contains hpfs instance management related helper functions.

**msg::** Extract message data from received raw messages.

**salog::** Handles logging. Creates and prints the logs according to the configured log section in the json config.

**sqlite::** Contains sqlite database management related helper functions.

**util::** Contains shared data structures/helper functions used by multiple subsystems.
