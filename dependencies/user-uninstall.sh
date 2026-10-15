#!/bin/bash
# Sashimono contract instance user uninstall script.
# This is intended to be called by Sashimono agent or via the user-install script for rollback.

user=$1
peer_port=$2
user_port=$3
gp_tcp_port_start=$4
gp_udp_port_start=$5
instance_name=$6
prefix="sashi"
max_kill_attempts=5

# Check whether this is a valid sashimono username.
[ ${#user} -lt 24 ] || [ ${#user} -gt 32 ] || [[ ! "$user" =~ ^$prefix[0-9]+$ ]] && echo "ARGS,UNINST_ERR" && exit 1

# Check if users exists.
if [[ $(id -u "$user" 2>/dev/null || echo -1) -ge 0 ]]; then
    :
else
    echo "NO_USER,UNINST_ERR"
    exit 1
fi

contract_user="$user-secuser"
cgroupsuffix="-cg"
user_dir=/home/$user
user_id=$(id -u "$user")
user_runtime_dir="/run/user/$user_id"
script_dir=$(dirname "$(realpath "$0")")
docker_bin=$script_dir/dockerbin
cleanup_script=/etc/sashimono/cleanup/$user.sh
npm_resources=$user_dir/.docker/npm_resources
MBXRPL_CONFIG="/etc/sashimono/mb-xrpl/mb-xrpl.cfg"
gp_udp_port_count=2
gp_tcp_port_count=2

function is_cgroup_v2() {
    # cgroup v2 (unified hierarchy) is mounted as cgroup2fs. Hybrid setups are treated as cgroup v1.
    [ "$(stat -fc %T /sys/fs/cgroup/)" == "cgroup2fs" ]
}

function cgrulesengd_servicename() {
    # Find the cgroups rules engine service.
    local cgrulesengd_filepath=$(grep "ExecStart.*=.*/cgrulesengd$" /etc/systemd/system/*.service | head -1 | awk -F : ' { print $1 } ')
    if [ -n "$cgrulesengd_filepath" ]; then
        local cgrulesengd_filename=$(basename $cgrulesengd_filepath)
        echo "${cgrulesengd_filename%.*}"
    fi
}

echo "Uninstalling user '$user'."

echo "Stopping and cleaning hpfs systemd services."
contract_fs_service="contract_fs"
ledger_fs_service="ledger_fs"
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user stop "$contract_fs_service"
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user stop "$ledger_fs_service"
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user disable "$contract_fs_service"
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user disable "$ledger_fs_service"

if [ -f "$user_dir/.config/systemd/user/instance_setup.service" ]; then
    echo "Stopping the instance setup service."
    sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user stop instance_setup.service
fi

echo "Removing the cron jobs of the user."
crontab -u "$user" -r 2>/dev/null

# Uninstall rootless dockerd.
echo "Uninstalling rootless dockerd."
sudo -H -u "$user" PATH="$docker_bin":"$PATH" XDG_RUNTIME_DIR="$user_runtime_dir" "$docker_bin"/dockerd-rootless-setuptool.sh uninstall

# Gracefully terminate user processes.
echo "Terminating user processes."
loginctl disable-linger $user
pkill -SIGINT -u $user
sleep 0.5
echo "Unmounting user filesystems."
fsmounts=$(cat /proc/mounts | cut -d ' ' -f 2 | grep "/home/$user")
readarray -t mntarr <<<"$fsmounts"
for mnt in "${mntarr[@]}"; do
    [ -z "$mnt" ] || umount "$mnt"
done

# Force kill user processes.
i=0
while true; do
    sleep 1
    procs=$(ps -U $user 2>/dev/null | wc -l)
    [ "$procs" == "1" ] && echo "All user processes terminated." && break
    [[ $i -ge $max_kill_attempts ]] && echo "Max force user process kill attempts $max_kill_attempts reached. Abondaning." && break
    ((i++))
    echo "Force killing user processes. Retrying $i..."
    pkill -SIGKILL -u "$user"
done

echo "Removing cgroups"
# Delete config values.
if ! is_cgroup_v2; then
    cgdelete -g cpu:$user$cgroupsuffix
    cgdelete -g memory:$user$cgroupsuffix
fi
# Remove the user slice resource limits.
rm -rf "/etc/systemd/system/user-$user_id.slice.d"
systemctl daemon-reload

# Removing applied disk quota of the user before deleting.
setquota -g -F vfsv0 "$user" 0 0 0 0 /

echo "Removing firewall rule allowing hp ports"
rule_list=$(sudo ufw status)
comment=$prefix-$instance_name

# Remove rules for user port.
user_port_comment=$comment-user
sed -n -r -e "/${user_port_comment}/{q100}" <<<"$rule_list"
res=$?
if [ $res -eq 100 ]; then
    echo "Deleting user port rule for instance from firewall."
    sudo ufw delete allow "$user_port"/tcp
else
    echo "User port rule not added by Sashimono. Skipping.."
fi

# Remove rules for peer port.
peer_port_comment=$comment-peer
sed -n -r -e "/${peer_port_comment}/{q100}" <<<"$rule_list"
res=$?
if [ $res -eq 100 ]; then
    echo "Deleting peer port rule for instance from firewall."
    sudo ufw delete allow "$peer_port"
else
    echo "Peer port rule not added by Sashimono. Skipping.."
fi

# Remove rules for general purpose udp port.
for ((i = 0; i < $gp_udp_port_count; i++)); do
    gp_udp_port=$(expr $gp_udp_port_start + $i)
    gp_udp_port_comment=$comment-gp-udp-$i
    sed -n -r -e "/${gp_udp_port_comment}/{q100}" <<<"$rule_list"
    res=$?
    if [ $res -eq 100 ]; then
        echo "Deleting general purpose udp port rule for instance from firewall."
        sudo ufw delete allow "$gp_udp_port"
    else
        echo "General purpose tcp port rule not added by Sashimono. Skipping.."
    fi
done

# Remove rules for general purpose tcp port.
for ((i = 0; i < $gp_tcp_port_count; i++)); do
    gp_tcp_port=$(expr $gp_tcp_port_start + $i)
    gp_tcp_port_comment=$comment-gp-tcp-$i
    sed -n -r -e "/${gp_tcp_port_comment}/{q100}" <<<"$rule_list"
    res=$?
    if [ $res -eq 100 ]; then
        echo "Deleting general purpose tcp port rule for instance from firewall."
        sudo ufw delete allow "$gp_tcp_port"
    else
        echo "General purpose tcp port rule not added by Sashimono. Skipping.."
    fi
done

echo "Removing nftables firewall rules of the instance."
nft delete table inet docker_filter_$user_id 2>/dev/null

echo "Deleting contract user '$contract_user'"
userdel "$contract_user"

if [ -f $cleanup_script ]; then
    echo "Executing cleanup script..."
    chmod +x $cleanup_script
    /bin/bash -c $cleanup_script
    rm "$cleanup_script"
fi

# The instance's NPMplus entries are read as data, because the file is written by the instance user.
if [ -f "$npm_resources" ] && [ ! -L "$npm_resources" ]; then
    npm_url=$(jq -r ".proxy.npm_url | select( . != null )" "$MBXRPL_CONFIG" 2>/dev/null)
    npm_token_path=$(jq -r ".proxy.npm_tokenPath | select( . != null )" "$MBXRPL_CONFIG" 2>/dev/null)
    [ -n "$npm_token_path" ] && npm_token=$(jq -r ".npm.token | select( . != null )" "$npm_token_path" 2>/dev/null)
    if [ -n "$npm_url" ] && [ -n "$npm_token" ]; then
        echo "Removing the NPMplus proxy hosts and certificates of the instance."
        # Reverse order removes proxy hosts before the certificates they use.
        head -c 65536 "$npm_resources" | grep -xE '(proxy-hosts|certificates) [0-9]{1,10}' | sort -ur | head -n 100 | while read -r npm_type npm_id; do
            curl -k -s -m 10 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer $npm_token" "$npm_url/api/nginx/$npm_type/$npm_id" >/dev/null 2>&1
        done
    fi
fi

echo "Deleting user '$user'"
userdel "$user"
rm -r /home/"${user:?}"
# Even though we are creating a group specifically,
# It'll be automatically deleted when we delete the user.

cgrulesengd_service=$(cgrulesengd_servicename)
if ! is_cgroup_v2 && [ ! -z "$cgrulesengd_service" ]; then
    echo "Restarting the '$cgrulesengd_service' service..."
    systemctl restart $cgrulesengd_service
fi

# Removing process and file desctiptor limitations for the user after user deletion.
sudo sed -i "/^$user/d" /etc/security/limits.conf

[ -d /home/"$user" ] && echo "NOT_CLEAN,UNINST_ERR" && exit 1

echo "UNINST_SUC"
exit 0
