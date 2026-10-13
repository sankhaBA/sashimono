#!/bin/bash
# Sashimono contract instance user installation script.
# This is intended to be called by Sashimono agent.
version=1.9

# Check for user cpu and memory quotas.
cpu=$1
memory=$2
swapmem=$3
disk=$4
contract_dir=$5
contract_uid=$6
contract_gid=$7
peer_port=$8
user_port=$9
gp_tcp_port_start=${10}
gp_udp_port_start=${11}
docker_image=${12}
docker_registry=${13}
outbound_ipv6=${14}
outbound_net_interface=${15}


if [ -z "$cpu" ] || [ -z "$memory" ] || [ -z "$swapmem" ] || [ -z "$disk" ] || [ -z "$contract_dir" ] ||
    [ -z "$contract_uid" ] || [ -z "$contract_gid" ] || [ -z "$peer_port" ] || [ -z "$user_port" ] || [ -z "$gp_udp_port_start" ] || [ -z "$gp_tcp_port_start" ] ||
    [ -z "$docker_image" ] || [ -z "$docker_registry" ] || [ -z "$outbound_ipv6" ] || [ -z "$outbound_net_interface" ]; then
    echo "INVALID_PARAMS,INST_ERR" && exit 1
fi

prefix="sashi"
suffix=$(date +%s%N) # Epoch nanoseconds
user="$prefix$suffix"
contract_user="$user-secuser"
group="sashiuser"
cgroupsuffix="-cg"
user_dir=/home/$user
script_dir=$(dirname "$(realpath "$0")")
docker_bin=$script_dir/dockerbin
docker_img_dir=$docker_bin/images
docker_service="docker.service"
docker_pull_timeout_secs=120
cleanup_script=$user_dir/uninstall_cleanup.sh
gp_udp_port_count=2
gp_tcp_port_count=2
osversion=$(grep -ioP '^VERSION_ID=\K.+' /etc/os-release)


SA_CONFIG="/etc/sashimono/sa.cfg"
MBXRPL_CONFIG="/etc/sashimono/mb-xrpl/mb-xrpl.cfg"
TLS_TYPE=$(jq -r ".proxy.tls_type | select( . != null )" "$MBXRPL_CONFIG")
EVERNODE_HOSTNAME="$(jq -r ".hp.host_address | select( . != null )" "$SA_CONFIG")"
# NPMplus server address (proxy.ip, or the npm_url host), used for the proxy target in domain_ssl_update.sh.
proxy_ip=$(jq -r ".proxy.ip | select( . != null )" "$MBXRPL_CONFIG")
if [ -z "$proxy_ip" ]; then proxy_ip=$(jq -r ".proxy.npm_url | select( . != null )" "$MBXRPL_CONFIG" | awk -F[/:] '{print $4}'); fi
# DNS server for the custom-domain checks: the TXT authorization check and the acme.sh DNS plugin (dns_evernode.sh).
DNS_RESOLVER=$(jq -r ".proxy.dns_resolver | select( . != null )" "$MBXRPL_CONFIG")
if [[ -n "$DNS_RESOLVER" ]] && [[ ! "$DNS_RESOLVER" =~ ^[A-Za-z0-9.:-]+$ ]]; then
    echo "Ignoring invalid proxy.dns_resolver value '$DNS_RESOLVER', using the default."
    DNS_RESOLVER=""
fi
DNS_RESOLVER=${DNS_RESOLVER:-8.8.8.8}

# configured urls
DOCKER_AUTH_URL="https://auth.docker.io/token?service=registry.docker.io&scope=repository:"
DOCKER_REGISTRY_URL="https://registry-1.docker.io/v2/"
ACME_SH_URL="https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh"
ACME_DNS_PLUGIN_URL="https://raw.githubusercontent.com/gadget78/sashimono/main/dependencies/dns_evernode.sh"

# Check if users already exists.
[ "$(id -u "$user" 2>/dev/null || echo -1)" -ge 0 ] && echo "HAS_USER,INST_ERR" && exit 1
! command -v nft &>/dev/null && echo "NO_NFTABLES,INST_ERR" && exit 1

function rollback() {
    echo "Rolling back user installation. $1"
    "$script_dir"/user-uninstall.sh "$user"
    echo "Rolled back the installation."
    echo "$1,INST_ERR" && exit 1
}

# Prints the Docker Hub repository of an image, for example "ubuntu:22.04" -> "library/ubuntu" and
# "evernode/sashimono:hp.latest" -> "evernode/sashimono". Prints nothing if the image comes from another
# registry (its first part is a host, such as "ghcr.io/..." or "myhost:5000/..."), because the Docker Hub
# URLs (DOCKER_AUTH_URL, DOCKER_REGISTRY_URL) don't apply to it.
function docker_hub_repo() {
    local repo="${1%@*}" # Drop a digest.
    # Drop the tag: the part after the last ':', but only if that ':' is after the last '/'.
    [[ "${repo##*/}" == *:* ]] && repo="${repo%:*}"
    local first="${repo%%/*}"
    if [[ "$repo" == */* ]]; then
        case "$first" in
        docker.io | index.docker.io | registry-1.docker.io) repo="${repo#*/}" ;;
        *.* | *:* | localhost) return 0 ;;
        esac
    fi
    [[ "$repo" == */* ]] && echo "$repo" || echo "library/$repo"
}

# Prints the current digest of a Docker Hub repository tag, for example "sha256:f659...". It is the same digest
# docker records in RepoDigests on pull. Prints nothing if Docker Hub can't be reached or has no such tag.
function docker_hub_digest() {
    local token
    token=$(curl -s -m 10 "${DOCKER_AUTH_URL}$1:pull" | jq -r '.token // empty')
    [[ -n "$token" ]] || return 0
    curl -s -m 10 --head -H "Authorization: Bearer $token" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "${DOCKER_REGISTRY_URL}$1/manifests/$2" | sed -n 's/.*[Dd]ocker-[Cc]ontent-[Dd]igest: \(sha256:[a-f0-9]\{64\}\).*/\1/p'
}

# Pulls the image into the instance's docker daemon. Rolls back if the pull fails or takes longer than docker_pull_timeout_secs.
function pull_docker_image() {
    echo "Pulling the docker image $docker_pull_image."
    DOCKER_HOST="$dockerd_socket" timeout --foreground -v -s SIGINT "$docker_pull_timeout_secs"s "$docker_bin"/docker pull "$docker_pull_image" || rollback "DOCKER_PULL"
    echo "Docker image $docker_pull_image pull complete."
}

# Waits until a service becomes ready up to 3 seconds.
function service_ready() {
    local svcstat=""
    for ((i = 0; i < 30; i++)); do
        sleep 0.1
        svcstat=$(sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user is-active $1)
        if [ "$svcstat" == "active" ]; then
            return 0 # Success
        fi
    done
    return 1 # Error
}

# Wait until daemon ready
function wait_for_dockerd() {
    # Retry for 5 times until dockerd is available.
    local i=0
    while true; do
        DOCKER_HOST=$dockerd_socket $docker_bin/docker version >/dev/null && return 0 # Success
        ((i++))
        echo "Docker daemon isn't available. Retrying $i..."
        [[ $i -ge 5 ]] && return 1 # Error
        sleep 1
    done
}

nofile_soft_limit=$(ulimit -n -S)
if [ $nofile_soft_limit -lt 250000 ]; then 
    ulimit -n 250000
    nofile_soft_limit=250000    
fi
max_instance_count=$(jq -r ".system.max_instance_count | select( . != null )" "$SA_CONFIG")
if [ -n "$max_instance_count" ] && [ "$max_instance_count" -gt 0 ]; then
    nofile_soft_limit=$((nofile_soft_limit / ( max_instance_count + 1 )))
    echo "setting ulimit -n to $nofile_soft_limit"
else
    echo "Error: max_instance_count is not valid or not found in $SA_CONFIG, defaulting ulimit to 55000"
    nofile_soft_limit=55000
fi
nproc_soft_limit=$(ulimit -u -S)

# Adding process and file descriptor limitations for the user before user creation
echo "$user hard nofile $nofile_soft_limit" | tee -a /etc/security/limits.conf
echo "$user soft nofile $nofile_soft_limit" | tee -a /etc/security/limits.conf
echo "$user hard nproc $nproc_soft_limit" | tee -a /etc/security/limits.conf

# Setup user and dockerd service.
useradd --shell /usr/sbin/nologin -m $user
usermod --lock $user
usermod -a -G $group $user
loginctl enable-linger $user # Enable lingering to support rootless dockerd service installation.
chmod o-rwx "$user_dir"
echo "Created '$user' user."

# Creating a secondary user for the contract.
# This is the respective host user for the child user of the sashimono user inside docker container.
# Taking the uid and gid offsets.
uoffset=$(grep "^$user:[0-9]\+:[0-9]\+$" /etc/subuid | cut -d: -f2)
[ -z $uoffset ] && rollback "SUBUID_ERR"
contract_host_uid=$(expr $uoffset + $contract_uid - 1)

# If contract gid is not 0, get the calculated host gid and create the contract user group
# and create user inside both contract user group and sashimono user group.
# Otherwise get sashimono user's gid and create contract user inside that group.
# Even though there's this "if not 0" condition, contract_gid will always be 0 since we are setting hp config's gid to 0 in instance creation.
if [ ! $contract_gid -eq 0 ]; then
    goffset=$(grep "^$user:[0-9]\+:[0-9]\+$" /etc/subgid | cut -d: -f2)
    [ -z $goffset ] && rollback "SUBGID_ERR"
    contract_host_gid=$(expr $goffset + $contract_gid - 1)
    groupadd -g "$contract_host_gid" "$contract_user"
    useradd --shell /usr/sbin/nologin -M -g "$contract_host_gid" -G "$user" -u "$contract_host_uid" "$contract_user"
else
    contract_host_gid=$(id -g "$user")
    useradd --shell /usr/sbin/nologin -M -g "$contract_host_gid" -u "$contract_host_uid" "$contract_user"
fi

usermod --lock "$contract_user"
echo "Created '$contract_user' contract user."

user_id=$(id -u "$user")
user_runtime_dir="/run/user/$user_id"
dockerd_socket="unix://$user_runtime_dir/docker.sock"

echo "checking quota system, and adding disk quota of $disk to the user $user"
if [[ "$(quotaon -p / | grep group | awk '{print $7}')" == "off" ]]; then
    rollback "QUOTA_OFF"
fi
setquota -g -F vfsv0 "$user" "$disk" "$disk" 0 0 / && echo "Configured disk quota of $disk for the user $user" || echo "Configuring disk quota failed"

# Extract additional port settings if present, 1st it splits everything after :, then replaces all -- with  |, and uses that to create an array
echo
echo "# checking for any additional port config within image name $docker_image"
IFS='|' read -r -a image_array <<< "$( echo $docker_image | cut -d':' -f2 | sed 's/--/|/g' )"
echo "captured additional docker settings, ${image_array[@]}"
if [[ "$docker_image" == *":"* ]]; then
    docker_image_version="${image_array[0]:-latest}"
else
    docker_image_version="latest"
fi
custom_docker_settings=false
custom_docker_domain=""
custom_docker_subdomain=""
custom_docker_domain_ssl="true"
internal_peer_port="$peer_port"
internal_user_port="$user_port"
internal_gptcp1_port="$gp_tcp_port_start"
internal_gpudp1_port="$gp_udp_port_start"
internal_gptcp2_port=$((gp_tcp_port_start + 1))
internal_gpudp2_port=$((gp_udp_port_start + 1))
internal_run_contract=""
internal_env1_key="KEY1"
internal_env1_value="1"
internal_env2_key="KEY2"
internal_env2_value="2"
internal_env3_key="KEY3"
internal_env3_value="3"
internal_env4_key="KEY4"
internal_env4_value="4"

# Loop through the array to extract pairs
for ((i = 1; i < ${#image_array[@]}; i += 2)); do
    image_array_name="${image_array[i]}"
    image_array_value="${image_array[i + 1]}"
    echo "found additional setting, name: \"$image_array_name\"    value: \"$image_array_value\""
    case "$image_array_name" in
        domain)
            custom_docker_settings="true"
            custom_docker_domain=$image_array_value
            ;;
        subdomain)
            custom_docker_settings="true"
            custom_docker_subdomain=$image_array_value
            ;;
        ssl)
            custom_docker_settings="true"
            if [[ "$image_array_value" == "false" ]]; then custom_docker_domain_ssl="false"; fi
            ;;
        peer | user | gptcp1 | gpudp1 | gptcp2 | gpudp2)
            # Sets internal_peer_port, internal_user_port, internal_gptcp1_port, etc.
            custom_docker_settings="true"
            printf -v "internal_${image_array_name}_port" '%s' "$image_array_value"
            ;;
        contract)
            if [[ "$image_array_value" == "true" ]]; then
                custom_docker_settings="true"
                internal_run_contract="run /contract"
                echo "found contract command, enabling \"run /contract\""
            fi
            ;;
        env[1-4])
            # Value format is KEY-value. "__" becomes a space and ".." becomes "$".
            # Sets internal_env<N>_key and internal_env<N>_value.
            custom_docker_settings="true"
            env_key=$(echo "$image_array_value" | cut -d'-' -f1)
            env_value=${image_array_value#*-}
            env_value=${env_value//__/ }
            env_value=${env_value//../$}
            printf -v "internal_${image_array_name}_key" '%s' "$env_key"
            printf -v "internal_${image_array_name}_value" '%s' "$env_value"
            echo "found $image_array_name, key>$env_key value>$env_value"
            ;;
    esac
done

# adjust docker_pull_image, and set a "default" custom_docker_image, only if custom settings have been detected
if [[ "$custom_docker_settings" == "true" ]]; then
    docker_pull_image="$(echo "$docker_image" | cut -d':' -f1):${docker_image_version}"
    echo "all additional port/custom settings found and saved, will be using a pull image of $docker_pull_image"
    echo
else
    docker_pull_image="$docker_image"
    echo "no additional port/custom settings found in image tag"
    echo
fi

# Setup env variables for the user.
echo "
export XDG_RUNTIME_DIR=$user_runtime_dir
export PATH=$docker_bin:\$PATH
export DOCKER_HOST=$dockerd_socket
[ -f \"/contract/env.vars\" ] && source /contract/env.vars
[ -f \"$user_dir/$contract_dir/env.vars\" ] && source $user_dir/$contract_dir/env.vars"  >>"$user_dir"/.bashrc
echo "Updated user .bashrc."

# Wait until user systemd is functioning.
user_systemd=""
for ((i = 0; i < 30; i++)); do
    sleep 0.1
    user_systemd=$(sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user is-system-running 2>/dev/null)
    [ "$user_systemd" == "running" ] && break
done
[ "$user_systemd" != "running" ] && rollback "NO_SYSTEMD"

echo "Allowing user and peer ports in firewall"
rule_list=$(sudo ufw status)
comment=$prefix-$contract_dir

# Add rules for user port.
sed -n -r -e "/${user_port}\/tcp\s*ALLOW\s*Anywhere/{q100}" <<<"$rule_list"
res=$?
if [ ! $res -eq 100 ]; then
    user_port_comment=$comment-user
    echo "Adding new rule to allow user port for new instance from firewall."
    sudo ufw allow "$user_port"/tcp comment "$user_port_comment"
else
    echo "User port rule already exists. Skipping."
fi

# Add rules for peer port.
sed -n -r -e "/${peer_port}\s*ALLOW\s*Anywhere/{q100}" <<<"$rule_list"
res=$?
if [ ! $res -eq 100 ]; then
    peer_port_comment=$comment-peer
    echo "Adding new rule to allow peer port for new instance from firewall."
    sudo ufw allow "$peer_port" comment "$peer_port_comment"
else
    echo "Peer port rule already exists. Skipping."
fi

# Add rules for general purpose udp ports.
for ((i = 0; i < $gp_udp_port_count; i++)); do
    gp_udp_port=$(expr $gp_udp_port_start + $i)
    sed -n -r -e "/${gp_udp_port}\s*ALLOW\s*Anywhere/{q100}" <<<"$rule_list"
    res=$?
    if [ ! $res -eq 100 ]; then
        gp_udp_port_comment=$comment-gp-udp-$i
        echo "Adding new rule to allow general purpose udp port for new instance from firewall."
        sudo ufw allow "$gp_udp_port" comment "$gp_udp_port_comment"
    else
        echo "General purpose udp port rule already exists. Skipping."
    fi
done

# Add rules for general purpose tcp ports.
for ((i = 0; i < $gp_tcp_port_count; i++)); do
    gp_tcp_port=$(expr $gp_tcp_port_start + $i)
    sed -n -r -e "/${gp_tcp_port}\s*ALLOW\s*Anywhere/{q100}" <<<"$rule_list"
    res=$?
    if [ ! $res -eq 100 ]; then
        gp_tcp_port_comment=$comment-gp-tcp-$i
        echo "Adding new rule to allow general purpose tcp port for new instance from firewall."
        sudo ufw allow "$gp_tcp_port" comment "$gp_tcp_port_comment"
    else
        echo "General purpose tcp rule already exists. Skipping."
    fi
done

# Creating AppArmor Profile for unprivileged user on Ubuntu 24.04
if [ "$osversion" == "24.04" ]; then
    filename=$(echo /home/$user/bin/rootlesskit | sed -e s@^/@@ -e s@/@.@g)
    cat <<EOF > /etc/apparmor.d/$filename
abi <abi/4.0>,
include <tunables/global>

"/home/$user/bin/rootlesskit" flags=(unconfined) {
  userns,

  include if exists <local/$filename>
}
EOF
    chown $user:$user /etc/apparmor.d/$filename
    systemctl restart apparmor.service
fi

echo "Installing rootless dockerd for user."
sudo -H -u "$user" PATH="$docker_bin":"$PATH" XDG_RUNTIME_DIR="$user_runtime_dir" "$docker_bin"/dockerd-rootless-setuptool.sh install

# Add environment variables as an override to docker service unit file.
echo "Applying $docker_service env overrides."
docker_service_override_conf="$user_dir/.config/systemd/user/$docker_service.d/override.conf"
sudo -H -u "$user" mkdir $user_dir/.config/systemd/user/$docker_service.d
sudo -H -u "$user" touch $docker_service_override_conf
echo "[Service]
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=slirp4netns
" >"$docker_service_override_conf"

# We need to enable ipv6 configurations if outbound ipv6 address is specified.
if [ "$outbound_ipv6" != "-" ] && [ "$outbound_net_interface" != "-" ]; then

    # Pass the relevant ipv6 parameters to rootlesskit flags. rootlesskit will in turn pass these to slirp4nets.
    # Also apply ipv6 route configuration patch in the dockerd process namespace (credits: https://github.com/containers/podman/issues/15850#issuecomment-1320028298)
    echo "
    Environment=\"DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS=--ipv6 --outbound-addr6=$outbound_ipv6\"
    ExecStartPost=/bin/bash -c 'nsenter -U --preserve-credentials -n -t $""(pgrep -u $user dockerd) /bin/bash -c \"ip addr add fd00::100/64 dev tap0 && ip route add default via fd00::2 dev tap0\"'
    " >>$docker_service_override_conf

    # Set the predefined ipv6 parameters to docker daemon config.
    mkdir -p $user_dir/.config/docker
    echo "{
        \"experimental\": true,
        \"ipv6\": true,
        \"fixed-cidr-v6\": \"2001:db8:1::/64\",
        \"ip6tables\": true,
        \"mtu\": 65520
    }" >$user_dir/.config/docker/daemon.json

    # Add the outbound ipv6 address to the specified network interface.
    ip addr add $outbound_ipv6 dev $outbound_net_interface

    # Add instructions to the cleanup script so the outbound ip assignment will be removed upon user uninstall.
    echo "ip addr del $outbound_ipv6 dev $outbound_net_interface" >>$cleanup_script
fi

# Apply the nftables firewall rules of the instance (blocks its access to the host and local networks).
echo "Applying nftables firewall rules."
"$script_dir"/user-firewall.sh "$(dirname "$SA_CONFIG")" "$user" || rollback "NFT_ERR"
# Refresh the rules of the other instances as well, since the host addresses may have changed (eg. outbound ipv6 address).
"$script_dir"/user-firewall.sh "$(dirname "$SA_CONFIG")" || echo "Warning: Refreshing the nftables firewall rules of other instances failed."

# Overwrite docker-rootless cli args on the docker service unit file (ExecStart is not supported by override.conf).
echo "Applying $docker_service extra args."
exec_original="ExecStart=$docker_bin/dockerd-rootless.sh"
exec_replace="$exec_original --max-concurrent-downloads 1"
# Add private docker registry information.
[ "$docker_registry" != "-" ] && exec_replace="$exec_replace --registry-mirror http://$docker_registry --insecure-registry $docker_registry"
sed -i "s%$exec_original%$exec_replace%" $user_dir/.config/systemd/user/$docker_service

# Reload the docker service.
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user daemon-reload
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user restart $docker_service
service_ready $docker_service || rollback "NO_DOCKERSVC"
# Wait until docker daemon ready, If failed rollback.
! wait_for_dockerd && rollback "NO_DOCKERD"
echo "finished Installing rootless dockerd."


hub_repo=$(docker_hub_repo "$docker_pull_image")
# Only Docker Hub images referenced by tag are cached, because only their current digest can be checked before loading
# a cached copy. The name checks also keep the cache paths inside docker_img_dir.
if [[ "$docker_pull_image" == *@* ]] || [[ ! "$hub_repo" =~ ^[a-z0-9]+([._-]+[a-z0-9]+)*(/[a-z0-9]+([._-]+[a-z0-9]+)*)*$ ]] || [[ ! "$docker_image_version" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    pull_docker_image
else
    img_local_tar_path="$docker_img_dir/$hub_repo/$docker_image_version.tar"
    img_local_digest_path="$img_local_tar_path.image_digest"
    mkdir -p "$docker_img_dir/$hub_repo"

    # Concurrent installs of the same image wait here, so they reuse one cached tarball instead of writing it together.
    exec {img_lock_fd}>"$img_local_tar_path.lock"
    flock "$img_lock_fd"

    hub_digest=$(docker_hub_digest "$hub_repo" "$docker_image_version")
    cached_digest=$(cat "$img_local_digest_path" 2>/dev/null)
    echo "Docker Hub digest: ${hub_digest:-unknown}, cached digest: ${cached_digest:-none}."

    if [[ -n "$hub_digest" ]] && [[ "$hub_digest" == "$cached_digest" ]] && [[ -f "$img_local_tar_path" ]]; then
        echo "Loading the cached docker image $img_local_tar_path."
        DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker load -i "$img_local_tar_path" || rollback "DOCKER_PULL"
        echo "Docker image $docker_pull_image load complete."
    else
        pull_docker_image

        echo "Saving the docker image to the cache $img_local_tar_path."
        rm -f "$img_local_digest_path"
        if pulled_digest=$(DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker image inspect --format '{{index .RepoDigests 0}}' "$docker_pull_image") &&
            [[ "$pulled_digest" == *@sha256:* ]] &&
            DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker save -o "$img_local_tar_path.tmp" "$docker_pull_image" &&
            mv "$img_local_tar_path.tmp" "$img_local_tar_path"; then
            echo "${pulled_digest#*@}" >"$img_local_digest_path"
        else
            rm -f "$img_local_tar_path.tmp"
            echo "Warning: Saving the docker image to the cache failed. The next instance will pull it again."
        fi
    fi
    exec {img_lock_fd}>&-
fi

echo "making sure pulled image has both the original "version" tag, and the tag with any custom settings"
DOCKER_HOST="$dockerd_socket" "$docker_bin"/docker tag ${docker_pull_image} ${docker_image} || rollback "DOCKER_PULL"
echo "Docker tag update complete, full image >$docker_image, original pulled image >$docker_pull_image"
echo


echo "Adding hpfs mounts, and depending on instance options, docker_recreate or docker_vars services."

echo "[Unit]
Description=Running and monitoring contract fs.
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=/bin/bash -c '( ! /bin/grep -qs $user_dir/$contract_dir/contract_fs/mnt /proc/mounts ) || /bin/fusermount -u $user_dir/$contract_dir/contract_fs/mnt'
EnvironmentFile=-$user_dir/.serviceconf
ExecStart=/bin/bash -c '$script_dir/hpfs fs -f $user_dir/$contract_dir/contract_fs -m $user_dir/$contract_dir/contract_fs/mnt -u $contract_host_uid:$contract_host_gid -t \${HPFS_TRACE}\$([ \$HPFS_MERGE = \"true\" ] && echo \" -g\")'
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target" >"$user_dir"/.config/systemd/user/contract_fs.service

echo "[Unit]
Description=Running and monitoring ledger fs.
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStartPre=/bin/bash -c '( ! /bin/grep -qs $user_dir/$contract_dir/ledger_fs/mnt /proc/mounts ) || /bin/fusermount -u $user_dir/$contract_dir/ledger_fs/mnt'
EnvironmentFile=-$user_dir/.serviceconf
ExecStart=$script_dir/hpfs fs -f $user_dir/$contract_dir/ledger_fs -m $user_dir/$contract_dir/ledger_fs/mnt -t \${HPFS_TRACE} -g
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target" >"$user_dir"/.config/systemd/user/ledger_fs.service


## setup NPM+ if host has NPMplus installed
if [[ "$TLS_TYPE" == "NPMplus" ]]; then
    echo "NPMplus install detected"

    if [[ -n "$custom_docker_domain" ]]; then
        if [[ ! -f "$script_dir/acme.sh" ]]; then
            echo "base acme.sh missing, re-installing"
            wget -O "$script_dir"/acme.sh "$ACME_SH_URL"
            chmod +x "$script_dir"/acme.sh
        fi
        if [[ ! -f "$script_dir/dns_evernode.sh" ]]; then
            echo "base evernode dns plugin for acme.sh missing, re-installing"
            wget -O "$script_dir"/dns_evernode.sh "$ACME_DNS_PLUGIN_URL"
            chmod +x "$script_dir"/dns_evernode.sh
            mkdir -p /root/.acme.sh
            cp "$script_dir"/dns_evernode.sh /root/.acme.sh/dns_evernode.sh
        fi

        mkdir -p $user_dir/.acme.sh/
        cp "$script_dir"/acme.sh $user_dir/.acme.sh/acme.sh
        cp "$script_dir"/dns_evernode.sh $user_dir/.acme.sh/dns_evernode.sh
        chown -R $user:$user $user_dir/.acme.sh/
    fi

cat > "$user_dir"/.docker/domain_ssl_update.sh <<EOF 
#!/bin/bash
# setup/update domain SSL and proxy host...
echo "##########################################################" && echo "#" && echo "## script running date... > \$(date)" && echo
version=$version
custom_docker_domain="$custom_docker_domain"
custom_docker_subdomain="$custom_docker_subdomain"
tls_type="$TLS_TYPE"
instance_slot=${user_port: -1}
web_port="$gp_tcp_port_start"
EVERNODE_HOSTNAME="$EVERNODE_HOSTNAME"
dns_resolver="$DNS_RESOLVER"
# Read by the acme.sh DNS plugin (dns_evernode.sh), so it queries the same DNS server as the checks below.
export EVERNODE_DNS_RESOLVER="\$dns_resolver"

# Downloads certificate \$NPM_CERT_ID from NPMplus into the contract's tls folder, and sets NPM_CERT_ID_STRING to use it.
# Returns 1 if the download or unzip fails, so the caller can fall back to no SSL.
download_npm_cert() {
    mkdir -p $user_dir/$contract_dir/tls
    if { 
        curl -k --output $user_dir/$contract_dir/tls/tls_files.zip -m 10 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID/download &&
        unzip $user_dir/$contract_dir/tls/tls_files.zip -d $user_dir/$contract_dir/tls &&
        echo "downloaded certificate ID \$NPM_CERT_ID for evernode"
    }; then
        for tls_file in $user_dir/$contract_dir/tls/*.pem; do
            tls_newname=\$(echo \$(basename \$tls_file) | sed 's/[0-9]*//g')
            mv "\$tls_file" "$user_dir/$contract_dir/tls/\$tls_newname"
        done
        chown -R $user:$user $user_dir/$contract_dir/tls
        if [[ "\$NPM_CERT_ID_WILD" == "false" ]]; then echo "curl -k -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID" >>$cleanup_script; fi
        NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
    else
        return 1
    fi
}

# 1st check for blacklisted domain, and null if present.
if [[ -n "\$custom_docker_domain" ]]; then
    blacklist_domains=\$(jq -r ".proxy.blacklist[] | select( . != null )" "$MBXRPL_CONFIG")
    for blacklist_domain_check in \$blacklist_domains; do
        if [[ "\$custom_docker_domain" == *"\$blacklist_domain_check"* ]]; then
            echo "blacklisted domain used in domain request :\$blacklist_domain_check NOT adding domain!."
            tls_type="failed"
            break
        fi
    done
fi

# 2nd check if domain has authorization to be used in this instance.
if [[ -n "\$custom_docker_domain" ]]; then
    contract_publickey=\$(jq -r ".contract.bin_args | select( . != null )" "$user_dir/$contract_dir/cfg/hp.cfg") || true
    domain_txtrecord=\$(dig +short +time=10 +tries=3 TXT "\$custom_docker_domain" @"\$dns_resolver")
    if echo "\$domain_txtrecord" | grep -q "\$contract_publickey"; then
        echo "contract public key, '\$contract_publickey'"
        echo "domain authorized, as found in the TXT records of \$custom_docker_domain, :\$domain_txtrecord"
    else
        echo "contract public key, '\$contract_publickey'"
        echo "domain NOT authorized as NOT found in the TXT records of \$custom_docker_domain, :\$domain_txtrecord"
        echo "not adding domain !"
        tls_type="failed"
    fi
fi

# setup domain on NPM+ (if requested. passed checks above, and host has NPMplus installed)
if [[ "\$tls_type" == "NPMplus" ]]; then
    echo "custom domain initial checks passed, continuing..."
    echo

    NPM_URL="$(jq -r ".proxy.npm_url | select( . != null )" "$MBXRPL_CONFIG")"
    NPM_TOKEN="$(jq -r ".npm.token | select( . != null )" "$(jq -r ".proxy.npm_tokenPath | select( . != null )" "$MBXRPL_CONFIG")")"
    NPM_CERT_ID_WILD="false"
    NPM_CERT_UPDATE="false"


    if [[ -z "\$NPM_URL" || -z "\$NPM_TOKEN" ]]; then
        echo "NPMplus  URL, or Token not set...  url=\"\$NPM_URL\" token=\"\$NPM_TOKEN\""
    else

        if [[ -n "\$custom_docker_subdomain" ]]; then
            custom_docker_domain="\$custom_docker_subdomain.\${EVERNODE_HOSTNAME#*.}"
            echo "subdomain request detected, assigning domain as \$custom_docker_domain"
        fi
        if [[ -z "\$custom_docker_domain" ]]; then
            custom_docker_domain="\${EVERNODE_HOSTNAME%%.*}-\${instance_slot}.\${EVERNODE_HOSTNAME#*.}"
            custom_docker_subdomain="\${custom_docker_domain%%.*}"
            echo "no custom domain settings found, setting up a default route of, \$custom_docker_domain"
        fi

        # Names for the proxy host and its certificate. A tenant's own domain also gets its "www." twin (or the bare
        # domain, if it was given with "www."), but only when that name resolves. Generated subdomains get no twin.
        # The proxy and the certificate use this same list, so the certificate covers every name the proxy serves.
        alias_domain=""
        if [[ -z "\$custom_docker_subdomain" ]]; then
            if [[ "\$custom_docker_domain" == www.* ]]; then alias_candidate="\${custom_docker_domain#www.}"; else alias_candidate="www.\$custom_docker_domain"; fi
            if [[ -n "\$(dig +short "\$alias_candidate" @"\$dns_resolver")" ]]; then alias_domain="\$alias_candidate"; fi
        fi
        proxy_domain_names="\"\$custom_docker_domain\""
        acme_alias_args=()
        if [[ -n "\$alias_domain" ]]; then
            proxy_domain_names="\$proxy_domain_names,\"\$alias_domain\""
            acme_alias_args=(--domain "\$alias_domain")
        fi
        echo "proxy and certificate names: \$proxy_domain_names"

        # Address NPMplus forwards to: this host's address on the route to the NPMplus server (proxy.ip, or the
        # npm_url host). Falls back to the first "hostname -I" address, as before, if NPMplus is on this host or no route is found.
        proxy_ip="$proxy_ip"
        forward_host=""
        if [[ -n "\$proxy_ip" ]]; then
            proxy_addr=\$(getent ahostsv4 "\$proxy_ip" | awk 'NR == 1 {print \$1}')
            if [[ -n "\$proxy_addr" ]]; then forward_host=\$(ip -o route get "\$proxy_addr" 2>/dev/null | awk '{for (i = 1; i < NF; i++) if (\$i == "src") {print \$(i + 1); exit}}'); fi
        fi
        if [[ -z "\$forward_host" || "\$forward_host" == 127.* ]]; then forward_host=\$(hostname -I | xargs | cut -d' ' -f1); fi
        echo "proxy will forward to \$forward_host:\$web_port"

        # get SSL files if needed
        if [[ "$custom_docker_domain_ssl" == "true" ]]; then
            echo "SSL request detected... "
            NPM_CERT_EMAIL=\$(jq -r ".host.emailAddress | select( . != null )" "$MBXRPL_CONFIG")
            NPM_CERT_LIST=\$(curl -k -s -m 100 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" \$NPM_URL/api/nginx/certificates || echo "" )
            NPM_CERT_ID=\$(echo "\$NPM_CERT_LIST" | jq -r '[.[] | select(.nice_name? == "'"\$custom_docker_domain"'") | .id // empty] | if length == 0 then "" else .[] end' || echo "" )
            # check for wildcard domain too (mainly needed for subdomain/defaulted domain)
            if [ "\$NPM_CERT_ID" == "" ]; then
                NPM_CERT_ID=\$(echo "\$NPM_CERT_LIST" | jq -r '[.[] | select(.nice_name? == "*.'"\${custom_docker_domain#*.}"'") | .id // empty] | if length == 0 then "" else .[] end' || echo "" )
                if [ -n "\$NPM_CERT_ID" ]; then 
                    echo "wildcard SSL file detected"
                    NPM_CERT_ID_WILD="true"
                    NPM_CERT_PROVIDER="\$(echo "\$NPM_CERT_LIST" | jq -r '[.[] | select(.nice_name? == "*.'"\${custom_docker_domain#*.}"'") | .provider // empty] | if length == 0 then "" else .[] end' || echo "" )"
                    NPM_CERT_EXPIRE="\$(echo "\$NPM_CERT_LIST" | jq -r '[.[] | select(.nice_name? == "*.'"\${custom_docker_domain#*.}"'") | .expires_on // empty] | if length == 0 then "" else .[] end' || echo "" )"
                    NPM_CERT_EXPIRE_MONTH="\$(echo "\$NPM_CERT_EXPIRE" | cut -d'-' -f2)"
                    if [ "\$NPM_CERT_PROVIDER" == "other" ]; then
                        if [ "\$NPM_CERT_EXPIRE_MONTH" -le "\$(date +%m)" ]; then
                            NPM_CERT_UPDATE="true"
                        fi
                    fi
                fi
            else
                NPM_CERT_ID_WILD="false"
                NPM_CERT_PROVIDER="\$(echo "\$NPM_CERT_LIST" | jq -r '[.[] | select(.nice_name? == "'"\${custom_docker_domain}"'") | .provider // empty] | if length == 0 then "" else .[] end' || echo "" )"
                NPM_CERT_EXPIRE="\$(echo "\$NPM_CERT_LIST" | jq -r '[.[] | select(.nice_name? == "'"\${custom_docker_domain}"'") | .expires_on // empty] | if length == 0 then "" else .[] end' || echo "" )"
                NPM_CERT_EXPIRE_MONTH="\$(echo "\$NPM_CERT_EXPIRE" | cut -d'-' -f2)"
                if [ "\$NPM_CERT_PROVIDER" == "other" ]; then
                    if [ "\$NPM_CERT_EXPIRE_MONTH" -le "\$(date +%m)" ]; then
                        NPM_CERT_UPDATE="true"
                    fi
                fi
            fi
            #echo "ID check point NPM_CERT_ID:>\$NPM_CERT_ID<"

            if [[ "\$NPM_CERT_ID" == "" || "\$NPM_CERT_UPDATE" == "true" ]]; then
                echo "files for domain \$custom_docker_domain now being created (updating=\${NPM_CERT_UPDATE} provider=\${NPM_CERT_PROVIDER} expiry=\${NPM_CERT_EXPIRE} expiry month=\${NPM_CERT_EXPIRE_MONTH})... "
                if [ -z "\$custom_docker_subdomain" ]; then 
                    echo "true custom tenant domain detected, using acme.sh DNS-01 and evernodes DNS API to create SSL files, and upload to NPM+..."
                    mkdir -p $user_dir/$contract_dir/tls
                    $user_dir/.acme.sh/acme.sh --issue \\
                        --server letsencrypt \\
                        --dns dns_evernode \\
                        --domain "\$custom_docker_domain" --force \\
                        "\${acme_alias_args[@]}" \\
                        --accountemail "\$NPM_CERT_EMAIL" \\
                        --nocron \\
                        --noprofile \\
                        --useragent  "evernode-domain-system" \\
                        --cert-file $user_dir/$contract_dir/tls/cert.pem \\
                        --key-file $user_dir/$contract_dir/tls/privkey.pem \\
                        --ca-file $user_dir/$contract_dir/tls/chain.pem \\
                        --fullchain-file $user_dir/$contract_dir/tls/fullchain.pem && 
                        chown -R $user:$user $user_dir/$contract_dir/tls &&
                        if [ "\$NPM_CERT_UPDATE" == "false" ]; then
                        NPM_CERT_ADD=\$(curl -k -sS -m 100 -X POST -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -d '{"provider":"other","nice_name":"'"\$custom_docker_domain"'","domain_names":['"\$proxy_domain_names"'],"meta":{ }}' \$NPM_URL/api/nginx/certificates ) &&
                        NPM_CERT_ID=\$(jq -r '.id' <<< "\$NPM_CERT_ADD") &&
                        echo "created new certificate, and entry for host domain \$custom_docker_domain, ID is \$NPM_CERT_ID, now uploading to NPM+..." 
                        else echo "created new certificate, for host domain \$custom_docker_domain, updating existing NPM+ ID \$NPM_CERT_ID, now uploading to..."
                        fi && \\
                        NPM_CERT_UPLOAD=\$(curl -k -X POST "\$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID/upload" -H "Authorization: Bearer \$NPM_TOKEN" -F "certificate=@$user_dir/$contract_dir/tls/cert.pem" -F "certificate_key=@$user_dir/$contract_dir/tls/privkey.pem") \\
                            || { \\
                                echo "failed to create, add certificate ID, or Upload file, this WILL cause issues. ERROR; debug_ADD:\$NPM_CERT_ADD  debug_ID:\$NPM_CERT_ID  debug_UPLOAD:\$NPM_CERT_UPLOAD"; \\
                                echo "flushing any entries from NPMplus for domain \$custom_docker_domain..."; \\
                                curl -k -m 100 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID; \\
                                NPM_CERT_ID="";
                                }
                fi
                if [[ -z "\$NPM_CERT_ID" || "\$NPM_CERT_ID" == "null" ]]; then
                    if [ -z "\$custom_docker_subdomain" ]; then echo "certificate creation via DNS-01 method failed or was skipped."; fi
                    echo
                    echo "trying via NPM+ with a more standard HTTP-01 method..."
                    NPM_CERT_ADD=\$(curl -k -s -m 100 -X POST -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -d '{"provider":"letsencrypt","nice_name":"'"\$custom_docker_domain"'","domain_names":['"\$proxy_domain_names"'],"meta":{"letsencrypt_email":"'"\$NPM_CERT_EMAIL"'","letsencrypt_agree":true,"dns_challenge":false}}' \$NPM_URL/api/nginx/certificates ) || echo "failed to create certificate for this evernode, this WILL cause issues. ERROR; debug: \$NPM_CERT_ADD"
                    NPM_CERT_ID=\$(jq -r '.id' <<< "\$NPM_CERT_ADD") && echo "created new certificate for host domain \$custom_docker_domain, ID is \$NPM_CERT_ID" || echo "failed to find certificate ID, this WILL cause issues. ERROR; debug1: \$NPM_CERT_ADD debug2: \$NPM_CERT_ID"
                    if [[ -z "\$NPM_CERT_ID" || "\$NPM_CERT_ID" == "null" ]]; then
                        echo "certificate add failed via http-01 method, setting up domain with no SSL. debug_ADD:\$NPM_CERT_ADD   debug_ID:\$NPM_CERT_ID"
                        echo "flushing any broken ssl entries in NPMplus for domain \$custom_docker_domain"
                        NPM_CERT_LIST=\$(curl -k -s -m 100 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" \$NPM_URL/api/nginx/certificates || echo "" )
                        NPM_CERT_ID=\$(echo "\$NPM_CERT_LIST" | jq -r '[.[] | select(.nice_name? == "'"\$custom_docker_domain"'") | .id // empty] | if length == 0 then "" else .[] end' || echo "" )
                        NPM_CERT_DELETE=\$(curl -k -m 100 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID)
                        echo "flushed? debug_ID:\$NPM_CERT_ID debug_DELETE:\$NPM_CERT_DELETE"
                        NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                    else
                        echo "certificate added, for host domain \$custom_docker_domain, with ID:\$NPM_CERT_ID  WILDCARD:\$NPM_CERT_ID_WILD"
                        if ! download_npm_cert; then
                            echo "failed to download and unzip certificate ID \$NPM_CERT_ID, setting up domain with no SSL."
                            echo "flushing broken ssl certificate with ID \$NPM_CERT_ID from NPMplus."
                            curl -k -m 100 -X DELETE -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID
                            NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                        fi
                    fi
                else
                    echo "certificate added, for host domain \$custom_docker_domain, with ID:\$NPM_CERT_ID   WILDCARD:\$NPM_CERT_ID_WILD"
                    if [[ "\$NPM_CERT_ID_WILD" == "false" ]]; then echo "curl -k -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" \$NPM_URL/api/nginx/certificates/\$NPM_CERT_ID" >>$cleanup_script; fi
                    NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
                fi
            elif [ "\$NPM_CERT_PROVIDER" != "other" ]; then
                echo "found existing certificate for host domain \$custom_docker_domain, with ID:\$NPM_CERT_ID   WILDCARD:\$NPM_CERT_ID_WILD"
                if ! download_npm_cert; then
                    echo "failed to download and unzip certificate ID \$NPM_CERT_ID, setting up domain with no SSL."
                    NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
                fi
            elif [ "\$NPM_CERT_PROVIDER" == "other" ]; then
                echo "found custom certificate for host domain \$custom_docker_domain, its already in date, with ID=\$NPM_CERT_ID, expiry=\$NPM_CERT_EXPIRE expiry month=\$NPM_CERT_EXPIRE_MONTH, WILDCARD=\$NPM_CERT_ID_WILD"
                NPM_CERT_ID_STRING=",\"certificate_id\":\$NPM_CERT_ID,\"ssl_forced\":1"
            fi
        else
        echo "SSL not requested. "
        NPM_CERT_ID_STRING=",\"certificate_id\":0,\"ssl_forced\":0"
        fi
        echo

        # ADD the domain to proxy_host list
        NPM_PROXYHOSTS_LIST=\$( { curl -k -s -m 100 -X GET -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" \$NPM_URL/api/nginx/proxy-hosts || { msg_error "something went wrong getting NPM list of proxy hosts"; NPM_PROXYHOSTS_LIST={}; }; } )
        NPM_PROXYHOSTS_ID=\$( { echo "\$NPM_PROXYHOSTS_LIST" | jq -r '.[] | select(.domain_names[] == "'"\$custom_docker_domain"'") | .id' || echo ""; } )
        if [ "\$NPM_PROXYHOSTS_ID" == "" ]; then
            echo "adding new proxy host domain \$custom_docker_domain using NPM_CERT_ID_STRING: \$NPM_CERT_ID_STRING"
            NPM_ADD_RESPONSE=\$( { curl -k -s -m 100 -X POST -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -d '{"domain_names":['"\$proxy_domain_names"'],"forward_host":"'"\$forward_host"'","forward_port":'"\$web_port"',"access_list_id":0'"\$NPM_CERT_ID_STRING"',"caching_enabled":0,"block_exploits":1,"advanced_config":"add_header X-Served-By '"\$EVERNODE_HOSTNAME"';","meta":{"letsencrypt_agree":true,"nginx_online":true},"allow_websocket_upgrade":1,"http2_support":0,"forward_scheme":"https","locations":[],"hsts_enabled":0,"hsts_subdomains":0}' \$NPM_URL/api/nginx/proxy-hosts || { echo "something went wrong when adding \$custom_docker_domain proxy host"; NPM_ADD_RESPONSE="error"; }; } ) 
            NPM_ADD_RESPONSE_CHECK=\$(jq -r '.enabled // "no enabled entry"' <<< "\$NPM_ADD_RESPONSE" || echo "jq error, no json output?")
            if [[ "\$NPM_ADD_RESPONSE_CHECK" == "1" || "\$NPM_ADD_RESPONSE_CHECK" == "true" ]]; then
                echo "added new proxy host to NPM with domain \$custom_docker_domain"
                NPM_PROXYHOSTS_ID=\$( echo "\$NPM_ADD_RESPONSE" | jq -r '.id')
                echo "curl -k -s -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" \$NPM_URL/api/nginx/proxy-hosts/\$NPM_PROXYHOSTS_ID >/dev/null 2>&1" >>$cleanup_script
            else
                echo "failed to add new proxy host domain on NPM+ \$custom_docker_domain, this will cause issues connecting via this domain. (debug_check:\$NPM_ADD_RESPONSE_CHECK   debug_response:\$NPM_ADD_RESPONSE )"
            fi
        elif [[ -z "\$custom_docker_subdomain" ]]; then
            echo "proxy host already on NPM domain \$custom_docker_domain, updating (using a NPM_CERT_ID_STRING: \$NPM_CERT_ID_STRING)..."
            NPM_EDIT_RESPONSE=\$( { curl -k -s -m 100 -X PUT -H "Content-Type: application/json; charset=UTF-8" -H "Authorization: Bearer \$NPM_TOKEN" -d '{"domain_names":['"\$proxy_domain_names"'],"forward_host":"'"\$forward_host"'","forward_port":'"\$web_port"',"access_list_id":0'"\$NPM_CERT_ID_STRING"',"caching_enabled":0,"block_exploits":1,"advanced_config":"add_header X-Served-By '"\$EVERNODE_HOSTNAME"';","meta":{"letsencrypt_agree":true,"nginx_online":true},"allow_websocket_upgrade":1,"http2_support":0,"forward_scheme":"https","locations":[],"hsts_enabled":0,"hsts_subdomains":0}' \$NPM_URL/api/nginx/proxy-hosts/\$NPM_PROXYHOSTS_ID || { echo "something went wrong when updating \$custom_docker_domain proxy host"; NPM_EDIT_RESPONSE="error"; }; })
            NPM_EDIT_RESPONSE_CHECK=\$(jq -r '.enabled // "no enabled entry"' <<< "\$NPM_EDIT_RESPONSE" || echo "jq error, no json output?")
            if [[ "\$NPM_EDIT_RESPONSE_CHECK" == "1" || "\$NPM_EDIT_RESPONSE_CHECK" == "true" ]]; then
                echo "updated proxy host with domain \$custom_docker_domain"
                echo "curl -k -s -m 100 -X DELETE -H \"Content-Type: application/json; charset=UTF-8\" -H \"Authorization: Bearer \$NPM_TOKEN\" \$NPM_URL/api/nginx/proxy-hosts/\$NPM_PROXYHOSTS_ID >/dev/null 2>&1" >>$cleanup_script
            else
                echo "failed to edit proxy host domain on NPM+, this will cause issues connecting via this domain. ( debug_check:\$NPM_EDIT_RESPONSE_CHECK    debug_response:\$NPM_EDIT_RESPONSE )"
            fi
        fi
    fi
elif [[ "\$tls_type" == "letsencrypt" ]]; then
    echo "todo: add support for stand alone evernodes via direct nginx"
    # this can be utilized by adding nginx directly on the host, and then using the etc/nginx/site-enabled or sites-available, as well as changing how cert bot gets utilized. but its VERY possible.
    echo
elif [[ "\$tls_type" == "" ]]; then
    echo "no supporting proxy settings to handle domain management config."
    echo
elif [[ "\$tls_type" == "failed" ]]; then
    echo "custom domain checks failed."
    echo  
else
    echo "no custom domain setup triggered... "
    echo
fi
cp $user_dir/.docker/domain_ssl_update.log $user_dir/$contract_dir/tls/domain_ssl_update.log

echo "............."
EOF
chmod +x $user_dir/.docker/domain_ssl_update.sh
chown $user:$user $user_dir/.docker/domain_ssl_update.sh
fi



if [[ -n "$custom_docker_subdomain" ]]; then
    custom_docker_domain="$custom_docker_subdomain.${EVERNODE_HOSTNAME#*.}"
    echo "subdomain request detected, assigning domain as $custom_docker_domain"
fi
if [[ -z "$custom_docker_domain" ]]; then
    instance_slot=${user_port: -1}
    custom_docker_domain="${EVERNODE_HOSTNAME%%.*}-${instance_slot}.${EVERNODE_HOSTNAME#*.}"
    custom_docker_subdomain="${custom_docker_domain%%.*}"
    echo "no custom domain settings found, setting up a default route of, $custom_docker_domain"
fi

cat > $user_dir/.docker/env.vars <<EOF 
HOST_DOMAIN_ADDRESS=$(jq -r ".hp.host_address | select( . != null )" "$SA_CONFIG")
CUSTOM_DOMAIN_ADDRESS=$custom_docker_domain
RAM_QUOTA="$(( memory / 1024 / 1024 ))GB"
DISK_QUOTA="$(( disk / 1024 / 1024 ))GB"
DISK_QUOTA_BYTES=$disk
DISK_USED_BYTES=""
DISK_USED="\$(( DISK_USED_BYTES / 1024 / 1024 ))GB"
DISK_FREE="\$(( ( DISK_QUOTA_BYTES - DISK_USED_BYTES ) / 1024 / 1024 ))GB"
EXTERNAL_PEER_PORT=$peer_port
INTERNAL_PEER_PORT=$internal_peer_port
EXTERNAL_USER_PORT=$user_port
INTERNAL_USER_PORT=$internal_user_port
EXTERNAL_GPTCP1_PORT=$gp_tcp_port_start
INTERNAL_GPTCP1_PORT=$internal_gptcp1_port
EXTERNAL_GPUDP1_PORT=$gp_udp_port_start
INTERNAL_GPUDP1_PORT=$internal_gpudp1_port
EXTERNAL_GPTCP2_PORT=$((gp_tcp_port_start + 1))
INTERNAL_GPTCP2_PORT=$((internal_gptcp1_port + 1))
EXTERNAL_GPUDP2_PORT=$((gp_udp_port_start + 1))
INTERNAL_GPUDP2_PORT=$((internal_gpudp1_port + 1))
$internal_env1_key=$internal_env1_value
$internal_env2_key=$internal_env2_value
$internal_env3_key=$internal_env3_value
$internal_env4_key=$internal_env4_value
EOF

# Cron job that writes the instance's current disk usage into env.vars every 5 minutes. Used by both watcher services below.
quota_crontab_awk_cmd="awk ''\'NR==3 {print \\\\\$2}''\'"
quota_crontab_sed_cmd='sed \\"s/^DISK_USED_BYTES=.*/DISK_USED_BYTES=\\$USED_BYTES/\\"'
quota_crontab_entry='echo "*/5 * * * * USED_BYTES=\\$(quota -g '${user}' 2>/dev/null | '${quota_crontab_awk_cmd}' || echo \\"0\\") && '${quota_crontab_sed_cmd}' \\"'${user_dir}'/'${contract_dir}'/env.vars\\" > \\"'${user_dir}'/'${contract_dir}'/env.vars.tmp\\" && [ -s '${user_dir}'/'${contract_dir}'/env.vars.tmp ] && mv \\"'${user_dir}'/'${contract_dir}'/env.vars.tmp\\" \\"'${user_dir}'/'${contract_dir}'/env.vars\\"" | crontab -'

# if there is any extra docker setting requested, build and setup re-create script and a service to start it.
if [[ "$custom_docker_settings" == "true" ]]; then
    echo "user custom docker settings detected, building docker re-create script and service"
    watcher_service="docker_recreate.service"

cat > "$user_dir"/.docker/docker_recreate.sh <<EOF
#!/bin/bash
CONTAINER_NAME=\$(${docker_bin}/docker ps -a --format "{{.Names}}" | head -n 1)
if [[ -z "\$CONTAINER_NAME" ]]; then echo "unable to obtain the container name >\$CONTAINER_NAME"; exit 1;fi

TIMEOUT_SECONDS=180
INSPECT_DATA=\$(${docker_bin}/docker inspect \$CONTAINER_NAME)
PORTS=\$(echo \$INSPECT_DATA | jq -r '.[0].HostConfig.PortBindings')
MOUNT_SOURCE=\$(echo \$INSPECT_DATA | jq -r '.[0].HostConfig.Mounts[0].Source')
MOUNT_TARGET=\$(echo \$INSPECT_DATA | jq -r '.[0].HostConfig.Mounts[0].Target')
IMAGE=\$(echo \$INSPECT_DATA | jq -r '.[0].Config.Image')

# Set Docker configs
export DOCKER_HOST="unix://${user_runtime_dir}/docker.sock"

# Build the docker create command
docker_create_command="timeout --foreground -v -s SIGINT \${TIMEOUT_SECONDS}s ${docker_bin}/docker create -t -i --stop-signal=SIGINT --log-driver local --log-opt max-size=5m --log-opt max-file=2 --name=\${CONTAINER_NAME}"

# Set the ports
for port in \$(echo \$PORTS | jq -r 'to_entries | .[] | .key'); do
    external_port=\$(echo \$PORTS | jq -r ".\\"\$port\\"[0].HostPort")
    internal_port=\$port
    if [[ "${peer_port}" == "\$external_port" ]]; then internal_port="${internal_peer_port}/\${port#*/}"; fi
    if [[ "${user_port}" == "\$external_port" ]]; then internal_port="${internal_user_port}/\${port#*/}"; fi
    if [[ "${gp_tcp_port_start}" == "\$external_port" ]]; then internal_port="${internal_gptcp1_port}/\${port#*/}"; fi
    if [[ "${gp_udp_port_start}" == "\$external_port" ]]; then internal_port="${internal_gpudp1_port}/\${port#*/}"; fi
    if [[ "$((gp_tcp_port_start + 1))" == "\$external_port" ]]; then internal_port="${internal_gptcp2_port}/\${port#*/}"; fi
    if [[ "$((gp_udp_port_start + 1))" == "\$external_port" ]]; then internal_port="${internal_gpudp2_port}/\${port#*/}"; fi
    echo "EXTERNAL \$external_port     INTERNAL \$internal_port"
    docker_create_command="\$docker_create_command -p \$external_port:\$internal_port"
done

# Add Environment variables
docker_create_command="\$docker_create_command --env-file $user_dir/.docker/env.vars"

# Add restart policy
docker_create_command="\$docker_create_command --restart unless-stopped"

# Add volume binding
docker_create_command="\$docker_create_command --mount type=bind,source=\${MOUNT_SOURCE},target=\${MOUNT_TARGET}"

# handle original container, and service
${docker_bin}/docker stop \$CONTAINER_NAME
${docker_bin}/docker rm \$CONTAINER_NAME

# Execute the docker create command
echo "docker_create_command built lets run >\$docker_create_command "
\$docker_create_command \${IMAGE} $internal_run_contract
${docker_bin}/docker start \$CONTAINER_NAME
EOF
chmod +x "$user_dir"/.docker/docker_recreate.sh

domain_ssl_update_1='(crontab -l 2>/dev/null; echo "0 0 */7 * * sleep \\$((RANDOM*3540/32768)) && /usr/bin/bash '${user_dir}'/.docker/domain_ssl_update.sh 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log") | crontab -'
domain_ssl_update_2='bash "'${user_dir}'/.docker/domain_ssl_update.sh" 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log'

cat > "$user_dir"/.config/systemd/user/docker_recreate.service <<EOF
[Unit]
Description=Docker Create Event Watcher
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
ExecStart=/bin/bash -c ' \\
  ${docker_bin}/docker events --filter event=create | \\
  while read -r create_event; do \\
    echo "Handling event: \${create_event}" >> "${user_dir}/.docker/docker_recreate.log"; \\
    bash "${user_dir}/.docker/docker_recreate.sh" 2>&1 | tee -a ${user_dir}/.docker/docker_recreate.log; \\
    cp ${user_dir}/.docker/env.vars ${user_dir}/${contract_dir}/env.vars; \\
    ${quota_crontab_entry}; \\
    ${domain_ssl_update_1}; \\
    ${domain_ssl_update_2}; \\
    break; \\
  done'
SuccessExitStatus=0 143

[Install]
WantedBy=default.target
EOF

else
    echo "no user custom docker settings detected, only adding env.vars file and quota system."
    watcher_service="docker_vars.service"
    echo "no custom port or other user settings found. setting up recreate service to copy .vars file and default domain-forwarding/proxy-host"
    if [[ "$TLS_TYPE" == "NPMplus" ]] && [[ "$docker_pull_image" != *"reputation"* ]]; then
        domain_ssl_update_1='(crontab -l 2>/dev/null; echo "0 0 */7 * * sleep \\$((RANDOM*3540/32768)) && /usr/bin/bash '${user_dir}'/.docker/domain_ssl_update.sh 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log") | crontab -'
        domain_ssl_update_2='bash "'${user_dir}'/.docker/domain_ssl_update.sh" 2>&1 | tee -a '${user_dir}'/.docker/domain_ssl_update.log'
    else
        domain_ssl_update_1='echo "NPMplus NOT installed on host,"'
        domain_ssl_update_2='echo "or reputation contract detected."'
    fi

# set up a service to copy in the .vars file AFTER docker has created the original container. (as container/image needs to be created, before we can copy it in)
cat > "$user_dir"/.config/systemd/user/docker_vars.service <<EOF
[Unit]
Description=Docker env.vars file setup, and proxy support.
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
ExecStart=/bin/bash -c ' \\
  ${docker_bin}/docker events --filter event=create | \\
  while read -r create_event; do \\
    cp "${user_dir}/.docker/env.vars" "${user_dir}/${contract_dir}/env.vars"; \\
    ${quota_crontab_entry}; \\
    ${domain_ssl_update_1}; \\
    ${domain_ssl_update_2}; \\
    break; \\
  done'
SuccessExitStatus=0 143

[Install]
WantedBy=default.target
EOF

fi

# Start the watcher service, and register its cleanup for uninstall.
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user daemon-reload
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user enable "$watcher_service"
sudo -u "$user" XDG_RUNTIME_DIR="$user_runtime_dir" systemctl --user start "$watcher_service"
echo "crontab -u $user -r" >>$cleanup_script
echo "cat $user_dir/.docker/domain_ssl_update.log >> /root/domain_ssl_update.log" >>$cleanup_script
chown -R $user:$user $cleanup_script

# In the Sashimono configuration, CPU time is 1000000us Sashimono is given max_cpu_us out of it.
# Instance allocation is multiplied by number of cores to determined the number of cores per instance and devided by 10 since cfs_period_us is set to 100000us

echo "Setting up user slice resources."

cores=$(grep -c ^processor /proc/cpuinfo)
cpu_period=1000000
cpu_quota=$(expr $(expr $cores \* $cpu \* 100 \/ $cpu_period))
[ $cpu_quota -lt 1 ] && cpu_quota=1 # CPUQuota should be at least 1%.

# Received swap memory quota includes the memory quota (memory.memsw.limit_in_bytes semantics in cgroup v1).
# MemorySwapMax (memory.swap.max in cgroup v2) excludes the memory, so take only the swap portion.
swap_only_mem=$((swapmem - memory))
[ $swap_only_mem -lt 0 ] && swap_only_mem=0

# Resource limiting for the unprivileged user
# This is the resource limiting mechanism with cgroup v2. With cgroup v1, the cgroup rules engine moves
# user processes into the cgroups created by user-cgcreate.sh.
mkdir -p /etc/systemd/system/user-$user_id.slice.d
echo "[Slice]
MemoryAccounting=true
CPUAccounting=true
MemoryMax=${memory}K
CPUQuota=${cpu_quota}%
MemorySwapMax=${swap_only_mem}K" | sudo tee /etc/systemd/system/user-$user_id.slice.d/override.conf

systemctl daemon-reload

echo "$user_id,$user,$dockerd_socket,INST_SUC"
exit 0