#!/bin/bash
# Apply the nftables firewall rules for the given Sashimono user, or for all Sashimono users if no user is given.
# Blocks the instance's traffic to the host, the LAN, private networks, cloud metadata and multicast (for IPv4 and IPv6).
# Replies to inbound connections, DNS, the instance and web ports on the host's own addresses and the NPMplus API are allowed.

datadir=$1
user=$2
if [ -z "$datadir" ]; then
    echo "Invalid arguments."
    echo "Expected: user-firewall.sh <sashimono data dir> [user]"
    exit 1
fi

saconfig="$datadir/sa.cfg"
if [ ! -f "$saconfig" ]; then
    echo "Config file does not exist."
    echo "Run \"sagent new $datadir\" command."
    exit 1
fi
mbxrplconfig="$datadir/mb-xrpl/mb-xrpl.cfg"

# Read config values
max_instance_count=$(jq '.system.max_instance_count' $saconfig)
init_peer_port=$(jq '.hp.init_peer_port' $saconfig)
init_user_port=$(jq '.hp.init_user_port' $saconfig)
init_gp_tcp_port=$(jq '.hp.init_gp_tcp_port' $saconfig)
init_gp_udp_port=$(jq '.hp.init_gp_udp_port' $saconfig)
gp_tcp_port_count=2
gp_udp_port_count=2

([ "$max_instance_count" == "" ] || [ ${#max_instance_count} -eq 0 ] || [ "$max_instance_count" -le 0 ]) && echo "max_instance_count cannot be empty." && exit 1

prefix="sashi"
users=${user:-$(cut -d: -f1 /etc/passwd | grep "^$prefix" | sort)}
readarray -t userarr <<<"$users"
validusers=()
for user in "${userarr[@]}"; do
    [ ${#user} -lt 24 ] || [ ${#user} -gt 32 ] || [[ ! "$user" =~ ^$prefix[0-9]+$ ]] && continue
    validusers+=("$user")
done
[ -n "$2" ] && [ ${#validusers[@]} -eq 0 ] && echo "Invalid user '$2'." && exit 1

# Prints a port range of the given start port and port count.
function port_range() {
    [ "$2" -gt 1 ] && echo "$1-$(($1 + $2 - 1))" || echo "$1"
}

# Prints the nft set elements statement of the given comma separated elements (nothing if empty).
function nft_set_elements() {
    [ -n "$1" ] && echo "elements = { $1 };"
}

host_ipv4s=$(ip -o -4 addr show scope global | awk '{sub(/\/.*/, "", $4); print $4}' | sort -u | paste -sd, -)
host_ipv6s=$(ip -o -6 addr show scope global | awk '{sub(/\/.*/, "", $4); print $4}' | sort -u | paste -sd, -)
onlink_ipv6_subnets=$(ip -6 route show | awk '$1 ~ /\// && $1 !~ /^fe80:/ && $2 == "dev" {print $1}' | sort -u | paste -sd, -)
dns_ips=$(cat /etc/resolv.conf /run/systemd/resolve/resolv.conf 2>/dev/null | awk '$1 == "nameserver" {sub(/%.*/, "", $2); print $2}' | sort -u)
dns_ipv4s=$(echo "$dns_ips" | grep -v ':' | paste -sd, -)
dns_ipv6s=$(echo "$dns_ips" | grep ':' | paste -sd, -)

host_tcp_ports="80, 443, $(port_range $init_user_port $max_instance_count), $(port_range $init_peer_port $max_instance_count), $(port_range $init_gp_tcp_port $((max_instance_count * gp_tcp_port_count)))"
host_udp_ports="$(port_range $init_peer_port $max_instance_count), $(port_range $init_gp_udp_port $((max_instance_count * gp_udp_port_count)))"

npm_url=$(jq -r ".proxy.npm_url | select( . != null )" "$mbxrplconfig" 2>/dev/null)
if [ -n "$npm_url" ]; then
    npm_host=$(echo "$npm_url" | awk -F[/:] '{print $4}')
    npm_port=$(echo "$npm_url" | awk -F[/:] '{print $5}')
    [ -z "$npm_port" ] && npm_port=$([[ "$npm_url" == https://* ]] && echo 443 || echo 80)
    npm_ipv4s=$(getent ahostsv4 "$npm_host" | awk -v port="$npm_port" '{print $1 " . " port}' | sort -u | paste -sd, -)
    npm_ipv6s=$(getent ahostsv6 "$npm_host" | awk -v port="$npm_port" '$1 !~ /^::ffff:/ {print $1 " . " port}' | sort -u | paste -sd, -)
    [ -z "$npm_ipv4s" ] && [ -z "$npm_ipv6s" ] && echo "Warning: Could not resolve NPMplus host $npm_host."
fi

# Replace the nftables table of the given user in a single transaction.
function setup_user_firewall() {
    local user_id=$(id -u "$1")
    [ -z "$user_id" ] && return 1

    nft -f - <<EOF
table inet docker_filter_$user_id
delete table inet docker_filter_$user_id
table inet docker_filter_$user_id {
    set host_ipv4 { type ipv4_addr; $(nft_set_elements "$host_ipv4s") }
    set host_ipv6 { type ipv6_addr; $(nft_set_elements "$host_ipv6s") }
    set onlink_ipv6 { type ipv6_addr; flags interval; auto-merge; $(nft_set_elements "$onlink_ipv6_subnets") }
    set dns_ipv4 { type ipv4_addr; $(nft_set_elements "$dns_ipv4s") }
    set dns_ipv6 { type ipv6_addr; $(nft_set_elements "$dns_ipv6s") }
    set npm_ipv4 { type ipv4_addr . inet_service; $(nft_set_elements "$npm_ipv4s") }
    set npm_ipv6 { type ipv6_addr . inet_service; $(nft_set_elements "$npm_ipv6s") }

    chain OUTPUT {
        type filter hook output priority 0; policy accept;
        meta skuid $user_id jump instance
    }

    chain instance {
        ct state established,related accept
        ip daddr @dns_ipv4 udp dport 53 accept
        ip daddr @dns_ipv4 tcp dport 53 accept
        ip6 daddr @dns_ipv6 udp dport 53 accept
        ip6 daddr @dns_ipv6 tcp dport 53 accept
        ip daddr @host_ipv4 tcp dport { $host_tcp_ports } accept
        ip daddr @host_ipv4 udp dport { $host_udp_ports } accept
        ip6 daddr @host_ipv6 tcp dport { $host_tcp_ports } accept
        ip6 daddr @host_ipv6 udp dport { $host_udp_ports } accept
        ip daddr . tcp dport @npm_ipv4 accept
        ip6 daddr . tcp dport @npm_ipv6 accept
        ip daddr @host_ipv4 counter reject with icmpx type admin-prohibited
        ip6 daddr @host_ipv6 counter reject with icmpx type admin-prohibited
        ip daddr { 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255 } counter reject with icmpx type admin-prohibited
        ip6 daddr { fc00::/7, fe80::/10, ff00::/8 } counter reject with icmpx type admin-prohibited
        ip6 daddr @onlink_ipv6 counter reject with icmpx type admin-prohibited
    }
}
EOF
}

has_err=0
for user in "${validusers[@]}"; do
    if ! setup_user_firewall "$user"; then
        echo "Firewall configuration for $user failed."
        has_err=1
    fi
done

[ $has_err -eq 1 ] && exit 1
exit 0
