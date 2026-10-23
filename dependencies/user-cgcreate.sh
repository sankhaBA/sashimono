#!/bin/bash
# Apply resource restrictions for all Sashimono users.
# cgroup v1: Call 'cgcreate' for each user (processes are assigned by the cgroup rules engine).
# cgroup v2: Configure the systemd user slice of each user.

datadir=$1
if [ -z "$datadir" ]; then
    echo "Invalid arguments."
    echo "Expected: user-cgcreate.sh <sashimino data dir>"
    exit 1
fi

saconfig="$1/sa.cfg"
if [ ! -f "$saconfig" ]; then
    echo "Config file does not exist."
    echo "Run \"sagent new $datadir\" command."
    exit 1
fi

# Calculate resources

# Read config values
max_mem_kbytes=$(jq '.system.max_mem_kbytes' $saconfig)
max_swap_kbytes=$(jq '.system.max_swap_kbytes' $saconfig)
max_cpu_us=$(jq '.system.max_cpu_us' $saconfig)
max_instance_count=$(jq '.system.max_instance_count' $saconfig)

([ "$max_instance_count" == "" ] || [ ${#max_instance_count} -eq 0 ] || [ "$max_instance_count" -le 0 ]) && echo "max_instance_count cannot be empty." && exit 1

instance_mem_kbytes=0
if [ "$max_mem_kbytes" != "" ] && [ ! ${#max_mem_kbytes} -eq 0 ] && [ "$max_mem_kbytes" -gt 0 ]; then
    ! instance_mem_kbytes=$(expr $max_mem_kbytes / $max_instance_count) && echo "Max memory limit calculation error." && exit 1
fi

instance_swap_kbytes=0
if [ "$max_swap_kbytes" != "" ] && [ ! ${#max_swap_kbytes} -eq 0 ] && [ "$max_swap_kbytes" -gt 0 ]; then
    ! instance_swap_kbytes=$(expr $instance_mem_kbytes + $max_swap_kbytes / $max_instance_count) && echo "Max swap memory limit calculation error." && exit 1
fi

instance_cpu_quota=0
# In the Sashimono configuration, CPU time is 1000000us Sashimono is given max_cpu_us out of it.
# Instance allocation is multiplied by number of cores to determined the number of cores per instance and devided by 10 since cfs_period_us is set to 100000us
if [ "$max_cpu_us" != "" ] && [ ! ${#max_cpu_us} -eq 0 ] && [ "$max_cpu_us" -gt 0 ]; then
    cores=$(grep -c ^processor /proc/cpuinfo)
    ! instance_cpu_quota=$(expr $(expr $cores \* $max_cpu_us) / $(expr $max_instance_count \* 10)) && echo "Max cpu limit calculation error." && exit 1
fi

prefix="sashi"
cgroupsuffix="-cg"
users=$(cut -d: -f1 /etc/passwd | grep "^$prefix" | sort)
readarray -t userarr <<<"$users"
validusers=()
for user in "${userarr[@]}"; do
    [ ${#user} -lt 24 ] || [ ${#user} -gt 32 ] || [[ ! "$user" =~ ^$prefix[0-9]+$ ]] && continue
    validusers+=("$user")
done

# Configure the systemd user slice of the given user with the calculated resource limits (cgroup v2).
function setup_user_slice() {
    local user_id=$(id -u "$1")
    [ -z "$user_id" ] && return 1

    local slice_conf_dir="/etc/systemd/system/user-$user_id.slice.d"
    local slice_conf="[Slice]
MemoryAccounting=true
CPUAccounting=true"

    # CPU quota is given as a percentage of a single core (100% = cfs_period_us of 100000us).
    if [ $instance_cpu_quota -gt 0 ]; then
        local cpu_quota_percent=$((instance_cpu_quota / 1000))
        [ $cpu_quota_percent -lt 1 ] && cpu_quota_percent=1
        slice_conf="$slice_conf
CPUQuota=${cpu_quota_percent}%"
    fi

    # In cgroup v2 swap limit excludes the memory, unlike memory.memsw.limit_in_bytes in cgroup v1.
    if [ $instance_mem_kbytes -gt 0 ]; then
        local swap_only_kbytes=$((instance_swap_kbytes - instance_mem_kbytes))
        [ $swap_only_kbytes -lt 0 ] && swap_only_kbytes=0
        slice_conf="$slice_conf
MemoryMax=${instance_mem_kbytes}K
MemorySwapMax=${swap_only_kbytes}K"
    fi

    mkdir -p "$slice_conf_dir" && echo "$slice_conf" >"$slice_conf_dir/override.conf"
}

has_err=0

if [ "$(stat -fc %T /sys/fs/cgroup/)" == "cgroup2fs" ]; then
    for user in "${validusers[@]}"; do
        if ! setup_user_slice "$user"; then
            echo "User slice configuration for $user failed."
            has_err=1
        fi
    done

    # Reload systemd to apply the slice configurations.
    ! systemctl daemon-reload && echo "Systemd daemon reload failed." && exit 1

    [ $has_err -eq 1 ] && exit 1
    exit 0
fi

for user in "${validusers[@]}"; do
    # Setup user cgroup.
    if [ $instance_cpu_quota -gt 0 ] &&
        ! (cgcreate -g cpu:$user$cgroupsuffix &&
            echo "100000" >/sys/fs/cgroup/cpu/$user$cgroupsuffix/cpu.cfs_period_us &&
            echo "$instance_cpu_quota" >/sys/fs/cgroup/cpu/$user$cgroupsuffix/cpu.cfs_quota_us); then
        echo "CPU cgroup creation for $user failed."
        has_err=1
    fi

    if [ $instance_mem_kbytes -gt 0 ] &&
        ! (cgcreate -g memory:$user$cgroupsuffix &&
            echo "${instance_mem_kbytes}K" >/sys/fs/cgroup/memory/$user$cgroupsuffix/memory.limit_in_bytes &&
            echo "${instance_swap_kbytes}K" >/sys/fs/cgroup/memory/$user$cgroupsuffix/memory.memsw.limit_in_bytes); then
        echo "Memory cgroup creation for $user failed."
        has_err=1
    fi
done

[ $has_err -eq 1 ] && exit 1
exit 0
