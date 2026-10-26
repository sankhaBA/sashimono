#!/bin/bash
# Sashimono cluster management script.

# Usage examples:
# ./cluster.sh select contract
# ./cluster.sh create 1
# ./cluster.sh create
# ./cluster.sh createall 22861
# ./cluster.sh reconfig
# ./cluster.sh reconfig R
# ./cluster.sh reconfig 1 R
# ./cluster.sh lcl
# ./cluster.sh lcl 1

# Command modes:
# select - Sets the currently active contract from the list of contracts defined in config.json file.
# reconfig - Re configure the sashimono with given "max_instance_count" in all the hosts (Only update the sa.cfg, Reinstall the sashimono if "R" option is given).
# lcl - Get lcl of the hosts.
# peers - Get the cfg peer list of the hosts.
# logs - Get the log lines grep by a given keywords.
# replacebin - Replaces a given file to /usr/bin/sashimono dir and keep a backup of existing file.

# create - Create new sashimono hotpocket instance in each node.
# createall - Create sashimono hotpocket instances in all nodes parallely.
# get-unl - Construct the UNL of all the nodes (Useful when creating cfg for contract upload).
# docker-pull - Pull the latest docker image from docker hub.
# start - Start sashimono hotpocket instance.
# stop - Stop sashimono hotpocket instance.
# destroy - Destroy sashimono hotpocket instance.
# ssh - Login with ssh or execute command on all nodes via ssh.
# sshu - Login with ssh or execute command on all nodes via ssh under instance user.
# attach - Attach to the docker instance output.
# ip - Show ip address of nodes.
# updatecfg - Update the hp config using the local file hp.cfg.
# statefile - Send a local file to instance contract_fs/seed/state/
# umount - Unmount instance contract/ledger fuse mounts. (Used to cleanup orphan mounts)
# backup - Downloads contract and ledger files from the given node.
# restore - Uploads previously downloaded contract and ledger files.
# syncwith - Manually syncs the entire cluster with the given node.

LOCKFILE="/tmp/sashiclusercfg.lock"
trap "rm -f $LOCKFILE" EXIT

PRINTFORMAT="Node %2s: %s\n"
PRINTFORMATNL="Node %2s:\n%s\n"

mode=$1

if [ "$mode" == "select" ] || [ "$mode" == "reconfig" ] || [ "$mode" == "lcl" ] || [ "$mode" == "peers" ] || [ "$mode" == "logs" ] || [ "$mode" == "replacebin" ] || [ "$mode" == "get-unl" ] || [ "$mode" == "docker-pull" ] ||
    [ "$mode" == "create" ] || [ "$mode" == "createall" ] || [ "$mode" == "start" ] || [ "$mode" == "stop" ] || [ "$mode" == "destroy" ] || [ "$mode" == "destroy-all" ] ||
    [ "$mode" == "ssh" ] || [ "$mode" == "sshu" ] || [ "$mode" == "attach" ] || [ "$mode" == "ip" ] || [ "$mode" == "updatecfg" ] ||
    [ "$mode" == "statefile" ] || [ "$mode" == "umount" ] || [ "$mode" == "backup" ] || [ "$mode" == "restore" ] || [ "$mode" == "syncwith" ]; then
    echo "mode: $mode"
else
    echo "Invalid command."
    echo " Expected: select <contract name> | reconfig [N] [R] | lcl [N] | peers [N] | logs [N] [C] | replacebin [N] <filepath> | get-unl | docker-pull [N] | create [N] | createall <peerport> | start [N] | stop [N] |"
    echo " destroy [N] | destroy-all [N] | ssh <N>or<command> | sshu <N> | attach <N> | ip [N] | updatecfg [N] | statefile [N] <file> | umount [N] | backup <N> | restore [N] | syncwith <N>"
    echo " [N]: Optional node no.   <N>: Required node no.   [R]: 'R' If sashimono needed to reinstall.   [C]: Print line count."
    exit 1
fi

configfile=config.json
if [ ! -f $configfile ]; then
    # Create default config file.
    echo '{"selected":"contract","contracts":[{"name":"contract","sshuser":"root","sshpass":"<ssh password>","owner_pubkey":"ed.....","contract_id":"<uuid>","docker":{"repo":"<docker repository>","image":"<docker image key>","id":"","pass":""},"vultr_group":"","hosts":{"host1_ip":{}},"config":{},"sa_config":{"max_instance_count":-1}}],"vultr":{"api_key":"<vultr api key>"}}' | jq . >$configfile
fi

if [ $mode == "select" ]; then
    selectedcont=$2
    if [ "$selectedcont" == "" ] || [ "$selectedcont" == "null" ]; then
        echo "Please specify contract name to select."
        exit 1
    fi
    continfo=$(jq -r ".contracts[] | select(.name == \"$selectedcont\")" $configfile)
    if [ "$continfo" == "" ] || [ "$continfo" == "null" ]; then
        echo "No configuration found for selected contract '"$selectedcont"'"
        exit 1
    fi

    # Set the 'selected' field value on cluster config file.
    jq ".selected = \"$selectedcont\"" $configfile >$configfile.tmp && mv $configfile.tmp $configfile
    echo "Selected '"$selectedcont"'"
    exit 0
fi

selectedcont=$(jq -r '.selected' $configfile)
if [ "$selectedcont" == "" ] || [ "$selectedcont" == "null" ]; then
    echo "No contract selected."
    exit 1
fi

continfo=$(jq -r ".contracts[] | select(.name == \"$selectedcont\")" $configfile)
if [ "$continfo" == "" ] || [ "$continfo" == "null" ]; then
    echo "No configuration found for selected contract '"$selectedcont"'"
    exit 1
fi

# Read ssh user and password and set contract directory based on username.
sshuser=$(echo $continfo | jq -r '.sshuser')
sshpass=$(echo $continfo | jq -r '.sshpass')
if [ "$sshuser" == "" ] || [ "$sshuser" == "null" ]; then
    echo "sshuser not specified."
    exit 1
fi

shopt -s expand_aliases
alias sshskp='ssh -o StrictHostKeychecking=no'
alias scpskp='scp -o StrictHostKeychecking=no'
if [ "$sshpass" != "" ] && [ "$sshpass" != "null" ]; then
    alias sshskp="sshpass -p $sshpass ssh -o StrictHostKeychecking=no"
    alias scpskp="sshpass -p $sshpass scp -o StrictHostKeychecking=no"
fi

function updateconfig() {
    # Update config using locking mechanism since update can be hapenned by multiple pocesses.
    cmd="$1 $configfile >$configfile.tmp && mv $configfile.tmp $configfile"
    flock -x $LOCKFILE -c "$cmd"
}

hosts=$(echo $continfo | jq -r '.hosts')

vultrgroup=$(echo $continfo | jq -r '.vultr_group')
# Read from vultr group only if group name is given and hosts are empty.
if [ "$vultrgroup" != "" ] && [ "$vultrgroup" != "null" ] && ([ "$hosts" = "" ] || [ "$hosts" = "{}" ]); then
    # Call Vultr rest api GET. (params: endpoint, apikey)
    function vultrget() {
        local _result=$(curl --silent "https://api.vultr.com/v2/$1" -X GET -H "Authorization: Bearer $2" -H "Content-Type: application/json" -w "\n%{http_code}")
        local _parts
        readarray -t _parts < <(printf '%s' "$_result")  # break parts by new line.
        if [[ ${_parts[1]} == 2* ]]; then                # Check for 2xx status code.
            [ ! -z "${_parts[0]}" ] && echo ${_parts[0]} # Return api output if there is any.
        else
            echo >&2 "Error on vultrget code:${_parts[1]} body:${_parts[0]}" && exit 1
        fi
    }

    vultrapikey=$(jq -r ".vultr.api_key" $configfile)
    [ -z $vultrapikey ] && echo >&2 "Vultr api key not found." && exit 1
    vultrvms=$(vultrget "instances?tag=${vultrgroup}" "$vultrapikey")
    [ -z "$vultrvms" ] && exit 1
    vultrips=$(echo $(echo $vultrvms | jq -r ".instances | sort_by(.label) | .[] | .main_ip"))
    readarray -d " " -t hostaddrs < <(printf '%s' "$vultrips") # Populate hostaddrs with ips retrieved from vultr.

    # Update json file's hosts section
    hosts=$(printf '%s\n' "${hostaddrs[@]}" | jq -R . | jq -s . | jq -r 'map({(.): {}}) | add')
    updateconfig "jq '(.contracts[] | select(.name == \"$selectedcont\") | .hosts) |= $hosts'"
    echo "Retrieved ${#hostaddrs[@]} host addresses from vultr group: '$vultrgroup'"
elif [ "$hosts" != "" ] && [ "$hosts" != "{}" ]; then
    hostaddrs=($(echo $hosts | jq -r 'keys_unsorted[]'))
else
    echo "Please provide a vultr_group or list of hosts"
    exit 1
fi

# Check if second arg (nodeid) is a number or not.
# If it's a number then reduce 1 from it to get zero-based node index.
if ! [[ $2 =~ ^[0-9]+$ ]]; then
    let nodeid=-1
else
    let nodeid=$2-1
fi

if [ $mode == "reconfig" ]; then
    # If node if is specified take 3rd arg otherwise take 2nd.
    if [ $nodeid = -1 ]; then
        reinstall=$2
    else
        reinstall=$3
    fi

    # If reinstall specified, show warn and take confirmation.
    if [ ! -z $reinstall ] && [ $reinstall == "R" ]; then
        echo "Warning: you'll lose all the sashimono instances!"
        echo "Still are you sure you want to reinstall Sashimono?"
        read -p "Type 'yes' to confirm reinstall: " confirmation </dev/tty
        [ "$confirmation" != "yes" ] && echo "Reinstall cancelled." && exit 0
    fi

    max_instance_count=$(echo $continfo | jq -r '.sa_config.max_instance_count')
    if ! [[ $max_instance_count =~ ^[0-9]+$ ]]; then
        max_instance_count=-1
    fi

    cgrulesengd_service="cgrulesengd"
    sashimono_service="sashimono-agent"
    saconfig="/etc/sashimono/sa.cfg"

    uninstall="evernode uninstall -q"
    install="curl -fsSL https://stevernode.blob.core.windows.net/evernode-dev-bb7ec110-f72e-430e-b297-9210468a4cbb/setup.sh | cat  | SKIP_SYSREQ=1 bash -s install -q auto auto 1000000 1000000 2097152 3145728 3 Auto_\$HOSTNAME"

    # The cgroup rules engine only exists with cgroup v1.
    restartcgrs="([ \"\$(stat -fc %T /sys/fs/cgroup/)\" == \"cgroup2fs\" ] || systemctl restart $cgrulesengd_service.service)"
    restartsas="systemctl restart $sashimono_service.service"

    # Re configure sashimono for given host.
    function reconfig() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        changecfg="jq '.hp.host_address = \"$hostaddr\"' $saconfig >$saconfig.tmp && mv $saconfig.tmp $saconfig"
        if [ $max_instance_count != -1 ]; then
            changecfg+=" && jq '.system.max_instance_count = $max_instance_count' $saconfig >$saconfig.tmp && mv $saconfig.tmp $saconfig"
        fi

        # Reinstall sashimono only if reinstall specified.
        if [ ! -z $reinstall ] && [ $reinstall == "R" ]; then
            command="$uninstall &>/dev/null && echo 'Sashimono uninstalled.' && $install &>/dev/null && echo 'Sashimono installed.' && $changecfg && $restartcgrs && $restartsas"
        else
            command="$changecfg && $restartsas"
        fi

        if ! sshskp $sshuser@$hostaddr $command ; then
            printf "$PRINTFORMAT" "$nodeno" "Error occurred reconfiguring sashimono."
        else
            # Remove host info if reinstall.
            if [ ! -z $reinstall ] && [ $reinstall == "R" ]; then
                updateconfig "jq '(.contracts[] | select(.name == \"$selectedcont\") | .hosts.\"$hostaddr\") |= {}'"
            fi
            printf "$PRINTFORMAT" "$nodeno" "Successfully reconfigured sashimono."
        fi
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            reconfig $i &

            # In reinstall mode, leave a time gap between reinstall initiation to avoid host faucet wallet generation
            # overload on XRPL testnet.
            if [ ! -z $reinstall ] && [ $reinstall == "R" ]; then
                sleep 2
            fi
        done
        wait
    else
        reconfig $nodeid
    fi
    exit 0
fi

if [ $mode == "lcl" ]; then
    # Get lcl for given host.
    function getlcl() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

        if [ "$containername" == "" ] || [ "$containername" == "null" ]; then
            printf "$PRINTFORMAT" "$nodeno" "Host info is empty."
            exit 1
        fi

        cpath="contdir=\$(find / -type d -path '/home/sashi*/$containername' 2>/dev/null) || [ ! -z \$contdir ]"
        msno="max_shard_no=\$(ls -v \$contdir/ledger_fs/seed/primary/ | tail -2 | head -1)"
        lcl="[ ! -z \$max_shard_no ] && echo \"select seq_no || '-' || lower(hex(ledger_hash)) from ledger order by seq_no DESC limit 1;\" | sqlite3 file:\$contdir/ledger_fs/seed/primary/\$max_shard_no/ledger.sqlite?mode=ro"
        command="$cpath && $msno && $lcl"
        output=$(sshskp $sshuser@$hostaddr $command 2>&1 | tr '\0' '\n')
        printf "$PRINTFORMAT" "$nodeno" "$output"
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            getlcl $i &
        done
        wait
    else
        getlcl $nodeid
    fi
    exit 0
fi

if [ $mode == "peers" ]; then
    # Get peers for given host.
    function getpeers() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

        if [ "$containername" == "" ] || [ "$containername" == "null" ]; then
            printf "$PRINTFORMAT" "$nodeno" "Host info is empty."
            exit 1
        fi

        cpath="contdir=\$(find / -type d -path '/home/sashi*/$containername' 2>/dev/null) || [ ! -z \$contdir ]"
        peers="jq -r '.mesh.known_peers' \$contdir/cfg/hp.cfg"
        command="$cpath && $peers"
        output=$(sshskp $sshuser@$hostaddr $command 2>&1 | tr '\0' '\n')
        printf "$PRINTFORMAT" "$nodeno" "$output"
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            getpeers $i &
        done
        wait
    else
        getpeers $nodeid
    fi
    exit 0
fi

if [ $mode == "logs" ]; then
    # Get logs for given host.
    function getlogs() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

        if [ "$containername" == "" ] || [ "$containername" == "null" ]; then
            printf "$PRINTFORMAT" "$nodeno" "Host info is empty."
            exit 1
        fi

        linec=5
        [ ! -z $3 ] && linec=$3
        cpath="contdir=\$(find / -type d -path '/home/sashi*/$containername' 2>/dev/null) || [ ! -z \$contdir ]"
        logs="cat \$contdir/log/hp.log | grep $2 | head -n $linec"
        command="$cpath && $logs"
        output=$(sshskp $sshuser@$hostaddr $command 2>&1 | tr '\0' '\n')
        printf "$PRINTFORMATNL" "$nodeno" "$output"
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            getlogs $i $2 $3 &
        done
        wait
    else
        getlogs $nodeid $3 $4
    fi
    exit 0
fi

if [ $mode == "replacebin" ]; then
    function replacebin() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        replace=$2
        filename=$(basename $replace)
        original="/usr/bin/sashimono/$filename"
        backup="/usr/bin/sashimono/$filename.bk"
        sshskp $sshuser@$hostaddr "mv $original $backup" && scpskp -q $replace $sshuser@$hostaddr:$original
        echo "node$nodeno: Updated $original, Kept backup $backup"
    }

    if [ $nodeid = -1 ]; then
        [ -z $2 ] && echo "Replace file path is not specified." && exit 1
        for i in "${!hostaddrs[@]}"; do
            replacebin $i $2 &
        done
        wait
    else
        [ -z $3 ] && echo "Replace file path is not specified." && exit 1
        replacebin $nodeid $3
    fi
    exit 0
fi

if [ $mode == "docker-pull" ]; then
    dockerbin=/usr/bin/sashimono/dockerbin/docker
    repo=$(echo $continfo | jq -r '.docker.repo')
    if [ "$repo" == "" ] || [ "$repo" == "null" ]; then
        echo "repo not specified."
        exit 1
    fi

    # Read the image.
    image=$(echo $continfo | jq -r '.docker.image')
    if [ "$image" == "" ] || [ "$image" == "null" ]; then
        echo "image not specified."
        exit 1
    fi

    image="$repo:$image"

    # Read docker credentials.
    dockerid=$(echo $continfo | jq -r '.docker.id')
    dockerpass=$(echo $continfo | jq -r '.docker.pass')
    dockerpull="$dockerbin pull $image"
    # If credentials given.
    if [ "$dockerid" != "" ] && [ "$dockerid" != "null" ] && [ "$dockerpass" != "" ] && [ "$dockerpass" != "null" ]; then
        dockerpull="(echo $dockerpass | $dockerbin login -u $dockerid --password-stdin &>/dev/null) && $dockerpull && $dockerbin logout"
    fi

    # Docker pull for given host.
    function dockerpull() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
        userport=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".user_port")
        peerport=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".peer_port")

        if [ "$containername" == "" ] || [ "$containername" == "null" ]; then
            printf "$PRINTFORMAT" "$nodeno" "Host info is empty."
            exit 1
        fi

        contractpath="contractpath=\$(find / -type d -path '/home/sashi*/$containername' 2>/dev/null) || [ ! -z \$contractpath ]"
        user="user=\$(echo \$contractpath | cut -d/ -f3) || [ ! -z \$user ]"

        dockerstop="$dockerbin stop $containername"
        dockerrm="$dockerbin rm $containername"
        dockercreate="$dockerbin create -t -i --stop-signal=SIGINT --name=$containername -p $userport:$userport -p $peerport:$peerport --restart unless-stopped --mount type=bind,source=\$contractpath,target=/contract $image run /contract"
        dpull="sudo -H -u \$user DOCKER_HOST=\"unix:///run/user/\$(id -u \$user)/docker.sock\" bash -c \"$dockerpull && $dockerstop && $dockerrm && $dockercreate\""

        command="$contractpath && $user && $dpull"
        if ! sshskp $sshuser@$hostaddr $command 1>/dev/null; then
            printf "$PRINTFORMAT" "$nodeno" "Error occurred pulling $image."
        else
            printf "$PRINTFORMAT" "$nodeno" "Successfully pulled $image."
        fi
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            dockerpull $i &
        done
        wait
    else
        dockerpull $nodeid
    fi
    exit 0
fi

if [ $mode == "create" ] || [ $mode == "createall" ]; then
    # Read owner pubkey, contract id and image
    ownerpubkey=$(echo $continfo | jq -r '.owner_pubkey')
    if [ "$ownerpubkey" = "" ] || [ "$ownerpubkey" = "null" ]; then
        echo "owner_pubkey not specified."
        exit 1
    fi

    contractid=$(echo $continfo | jq -r '.contract_id')
    if [ "$contractid" == "" ] || [ "$contractid" == "null" ]; then
        echo "contract_id not specified."
        exit 1
    fi

    image=$(echo $continfo | jq -r '.docker.image')
    if [ "$image" == "" ] || [ "$image" == "null" ]; then
        echo "image not specified."
        exit 1
    fi

    # Create an instance for given host.
    function createinstance() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        # If host info is already populated, skip instance creation.
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
        if [ "$containername" == "" ] || [ "$containername" == "null" ]; then
            if [ "$1" != 0 ]; then
                hostinfo=$(echo $continfo | jq -r ".hosts.\"${hostaddrs[0]}\"")
                pubkey=$(echo $hostinfo | jq -r '.pubkey')
            fi

            config=$(echo $continfo | jq -c -r ".config")
            if [ "$1" != 0 ]; then
                peers=""
                for ((i = 0; i < $1; i++)); do
                    if [ -z "$2" ]; then
                        hostinfo=$(echo $continfo | jq -r ".hosts.\"${hostaddrs[$i]}\"")
                        peerport=$(echo $hostinfo | jq -r '.peer_port')

                        if [ "$hostinfo" == "" ] || [ "$hostinfo" == "null" ] ||
                            [ "$peerport" == "" ] || [ "$peerport" == "null" ]; then
                            echo "Host info is empty for ${hostaddrs[$i]}"
                            exit 1
                        fi
                    else
                        peerport=$2
                    fi
                    peers+="\"${hostaddrs[$i]}:$peerport\","
                done
                peers=${peers%?}
                config=$(echo "$config" | jq -c ".mesh.known_peers = [$peers]" | jq -c ".contract.unl = [\"$pubkey\"]")
            fi

            command="DEV_MODE=1 sashi json -m '{\"type\":\"create\",\"owner_pubkey\":\"$ownerpubkey\",\"contract_id\":\"$contractid\",\"image\":\"$image\",\"config\":$config}'"
            output=$(sshskp $sshuser@$hostaddr $command | tr '\0' '\n')
            # If an output received consider updating the json file.
            if [ ! "$output" = "" ]; then
                content=$(echo $output | jq -r '.content')
                printf "$PRINTFORMAT" "$nodeno" "$output"
                # Update the json if no error.
                if [ ! "$content" == "" ] && [ ! "$content" == "null" ] && [[ ! "$content" =~ ^[a-zA-Z]+_error$ ]]; then
                    updateconfig "jq '(.contracts[] | select(.name == \"$selectedcont\") | .hosts.\"$hostaddr\") |= $content'"
                    # Refresh the in-memory config to include latest node creation details.
                    continfo=$(jq -r ".contracts[] | select(.name == \"$selectedcont\")" $configfile)
                    hosts=$(echo $continfo | jq -r '.hosts')
                    hostaddrs=($(echo $hosts | jq -r 'keys_unsorted[]'))
                fi
            else
                printf "$PRINTFORMAT" "$nodeno" "Instance creation error."
            fi
        else
            printf "$PRINTFORMAT" "$nodeno" "Instance is already created."
        fi
    }

    if [ $mode == "create" ]; then
        if [ $nodeid = -1 ]; then
            for i in "${!hostaddrs[@]}"; do
                createinstance $i
            done
        else
            createinstance $nodeid $peerport
        fi
    else
        # Create all instances parallely with specified peer port.
        peerport=$2
        [ -z "$peerport" ] && echo "Peer port is required." && exit 1
        for i in "${!hostaddrs[@]}"; do
            if [ $i == "0" ]; then
                # Create first instance sequentially so others can get its public key for their unl.
                echo "Creating first instance..."
                createinstance $i $peerport
            else
                createinstance $i $peerport &
            fi
        done
        wait
    fi
    exit 0
fi

if [ $mode == "get-unl" ]; then
    unl=""
    for hostaddr in "${hostaddrs[@]}"; do
        hostinfo=$(echo $continfo | jq -r ".hosts.\"$hostaddr\"")
        pubkey=$(echo $hostinfo | jq -r '.pubkey')

        if [ "$hostinfo" == "" ] || [ "$hostinfo" == "null" ] ||
            [ "$pubkey" == "" ] || [ "$pubkey" == "null" ]; then
            echo "Host pubkey is empty for $hostaddr"
            exit 1
        fi
        unl+="\"$pubkey\","
    done

    # Remove trainling comma(,) and add square brackets for the lists.
    unl=${unl%?}
    echo "{\"unl\":[$unl]}" | jq .
    exit 0
fi

# if [ $mode == "initiate" ]; then
#     # Initiate the instance of given host.
#     function initiateinstance() {
#         hostaddr=${hostaddrs[$1]}
#         nodeno=$(expr $1 + 1)
#         peers=$2
#         unl=$3
#         config=$(echo $continfo | jq -r ".config")
#         containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
#         peerport=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".peer_port")
#         selfpeer="\"$hostaddr:$peerport\""
#         # Remove self peer from the peers.
#         updatedpeers=$(echo $peers | sed "s/\($selfpeer,\|,$selfpeer\|$selfpeer\)//g")
#         # Update the in memory config with received peers and unl.
#         updatedconfig=$(echo $config | jq ".mesh.known_peers = [$updatedpeers]" | jq ".contract.unl = [$unl]")
#         command="sashi json -m '{\"type\":\"initiate\",\"container_name\":\"$containername\",\"config\":$updatedconfig}'"
#         output=$(sshskp $sshuser@$hostaddr $command 2>&1 | tr '\0' '\n')
#         printf "$PRINTFORMAT" "$nodeno" "$output"
#     }

#     # Read each hosts config and construct cluster unl and peers.
#     peers=""
#     unl=""
#     for hostaddr in "${hostaddrs[@]}"; do
#         hostinfo=$(echo $continfo | jq -r ".hosts.\"$hostaddr\"")
#         pubkey=$(echo $hostinfo | jq -r '.pubkey')
#         ip=$(echo $hostinfo | jq -r '.ip')
#         peerport=$(echo $hostinfo | jq -r '.peer_port')

#         if [ "$hostinfo" == "" ] || [ "$hostinfo" == "null" ] ||
#             [ "$pubkey" == "" ] || [ "$pubkey" == "null" ] ||
#             [ "$ip" == "" ] || [ "$ip" == "null" ] ||
#             [ "$peerport" == "" ] || [ "$peerport" == "null" ]; then
#             echo "Host info is empty for $hostaddr"
#             exit 1
#         fi
#         peers+="\"$hostaddr:$peerport\","
#         unl+="\"$pubkey\","
#     done

#     # Remove trainling comma(,) and add square brackets for the lists.
#     peers=${peers%?}
#     unl=${unl%?}

#     if [ $nodeid = -1 ]; then
#         for i in "${!hostaddrs[@]}"; do
#             initiateinstance $i $peers $unl &
#         done
#         wait
#     else
#         initiateinstance $nodeid $peers $unl
#     fi
#     exit 0
# fi

if [ $mode == "start" ]; then
    # Start instance of given host.
    function startinstance() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
        command="sashi json -m '{\"type\":\"start\",\"container_name\":\"$containername\"}'"
        output=$(sshskp $sshuser@$hostaddr $command 2>&1 | tr '\0' '\n')
        printf "$PRINTFORMAT" "$nodeno" "$output"
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            startinstance $i &
        done
        wait
    else
        startinstance $nodeid
    fi
    exit 0
fi

if [ $mode == "stop" ]; then
    # Stop instance of given host.
    function stopinstance() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
        command="sashi json -m '{\"type\":\"stop\",\"container_name\":\"$containername\"}'"
        output=$(sshskp $sshuser@$hostaddr $command 2>&1 | tr '\0' '\n')
        printf "$PRINTFORMAT" "$nodeno" "$output"
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            stopinstance $i &
        done
        wait
    else
        stopinstance $nodeid
    fi
    exit 0
fi

if [ $mode == "destroy" ]; then
    # Destroy instance of given host.
    function destroyinstance() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
        command="sashi json -m '{\"type\":\"destroy\",\"container_name\":\"$containername\"}'"
        output=$(sshskp $sshuser@$hostaddr $command | tr '\0' '\n')
        # If an output received consider updating the json file.
        if [ ! "$output" = "" ]; then
            content=$(echo $output | jq -r '.content')
            printf "$PRINTFORMAT" "$nodeno" "$output"
            # Update the json if no error.
            if [ ! "$content" == "" ] && [ ! "$content" == "null" ] && [[ ! "$content" =~ ^[a-zA-Z]+_error$ ]]; then
                # If a vultr group is defined remove self ip from the hosts.
                if [ "$vultrgroup" != "" ] && [ "$vultrgroup" != "null" ]; then
                    updateconfig "jq '(.contracts[] | select(.name == \"$selectedcont\") | .hosts) |= del(.\"$hostaddr\")'"
                else
                    updateconfig "jq '(.contracts[] | select(.name == \"$selectedcont\") | .hosts.\"$hostaddr\") |= {}'"
                fi
            fi
        else
            printf "$PRINTFORMAT" "$nodeno" "Instance destroy error."
        fi
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            destroyinstance $i &
        done
        wait
    else
        destroyinstance $nodeid
    fi
    exit 0
fi

if [ $mode == "destroy-all" ]; then
    # Destroy all instances of given host.
    function destroyallinstances() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)

        while :; do
            containername=$(sshskp $sshuser@$hostaddr sashi list | tail +3 | head -1 | awk '{ print $1 }')
            if [ "$containername" != "" ]; then
                echo "Node$nodeno. Destroying $containername..."
                result=$(sshskp $sshuser@$hostaddr sashi destroy -n $containername)
                echo "Node$nodeno. $containername: $result"
            else
                break
            fi
        done
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            destroyallinstances $i &
        done
        wait
    else
        destroyallinstances $nodeid
    fi
    exit 0
fi

if [ $mode = "ssh" ]; then
    if [ $nodeid = -1 ]; then
        if [ -n "$2" ]; then
            # Interpret second arg as a command to execute on all nodes.
            command=${*:2}
            echo "Executing '$command' on all nodes..."
            for i in "${!hostaddrs[@]}"; do
                hostaddr=${hostaddrs[i]}
                let n=$i+1
                echo "node"$n":" $(sshskp $sshuser@$hostaddr $command) &
            done
            wait
            exit 0
        else
            echo "Please specify node no. or command to execute on all nodes."
            exit 1
        fi
    else
        hostaddr=${hostaddrs[$nodeid]}
        sshskp -t $sshuser@$hostaddr
        exit 0
    fi
fi

if [ $mode == "sshu" ]; then

    function sshwithuser() {
        hostaddr=${hostaddrs[$1]}
        execute_command=$2
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
        username=$(sshskp $sshuser@$hostaddr "sashi list | grep $containername | awk '{ print \$2 }'")

        user_shell="cd /home/$username/$containername ; sudo -u $username bash"

        if [ "$execute_command" == "" ]; then
            sshskp -t $sshuser@$hostaddr $user_shell
        else
            echo "node"$n":" $(sshskp $sshuser@$hostaddr $user_shell -c "'$execute_command'")
        fi
    }

    if [ $nodeid = -1 ]; then
        if [ -n "$2" ]; then
            # Interpret second arg as a command to execute on all nodes.
            command=${*:2}
            echo "Executing '$command' on user shell in all nodes..."
            for i in "${!hostaddrs[@]}"; do
                hostaddr=${hostaddrs[i]}
                let n=$i+1
                sshwithuser $n $command &
            done
            wait
            exit 0
        else
            echo "Please specify node no. or command to execute on all nodes."
            exit 1
        fi
    else
        sshwithuser $nodeid
    fi
    exit 0
fi

if [ $mode == "attach" ]; then

    function attachdocker() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")
        username=$(sshskp $sshuser@$hostaddr "sashi list | grep $containername | awk '{ print \$2 }'")

        echo "Press ctrl+P,Q to detach."
        ssh_command="sudo -u $username bash -i -c 'docker attach $containername'"
        sshskp -t $sshuser@$hostaddr $ssh_command
    }

    if [ $nodeid = -1 ]; then
        echo "Must specify node no."
        exit 1
    else
        attachdocker $nodeid
    fi
    exit 0
fi

if [ $mode = "ip" ]; then
    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            let n=$i+1
            echo "node"$n": ${hostaddrs[i]}"
        done
    else
        echo "${hostaddrs[$nodeid]}"
    fi
    exit 0
fi

if [ $mode == "updatecfg" ]; then

    function sendcfg() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

        username=$(sshskp $sshuser@$hostaddr "sashi list | grep $containername | awk '{ print \$2 }'")
        originalcfg="/home/$username/$containername/cfg/hp.cfg"

        scpskp -q hp.cfg $sshuser@$hostaddr:~/
        sshskp $sshuser@$hostaddr "jq -s '.[0] * .[1]' $originalcfg ~/hp.cfg > ~/merged.cfg && mv ~/merged.cfg $originalcfg && chown $username:$username $originalcfg && rm ~/hp.cfg"
        echo "node$nodeno: Updated $originalcfg"
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            sendcfg $i &
        done
        wait
    else
        sendcfg $nodeid
    fi
    exit 0
fi

if [ $mode == "statefile" ]; then

    function sendstatefile() {
        localfilepath=$2
        filename=$(basename $2)
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

        username=$(sshskp $sshuser@$hostaddr "sashi list | grep $containername | awk '{ print \$2 }'")
        fspath="/home/$username/$containername/contract_fs"
        seedpath="$fspath/seed/state"

        scpskp -q $localfilepath $sshuser@$hostaddr:$seedpath/
        sshskp $sshuser@$hostaddr "chown $username:$username $seedpath/$filename && rm -r $fspath/hmap && rm $fspath/log.hpfs"
        echo "node$nodeno: Transferred to $seedpath/$filename"
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            sendstatefile $i $2 &
        done
        wait
    else
        sendstatefile $nodeid $3
    fi
    exit 0
fi

if [ $mode == "umount" ]; then

    function unmountfuse() {
        hostaddr=${hostaddrs[$1]}
        nodeno=$(expr $1 + 1)
        containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

        username=$(sshskp $sshuser@$hostaddr "sashi list | grep $containername | awk '{ print \$2 }'")
        contractmnt="/home/$username/$containername/contract_fs/mnt"
        ledgermnt="/home/$username/$containername/ledger_fs/mnt"

        sshskp $sshuser@$hostaddr "fusermount -u $contractmnt ; fusermount -u $ledgermnt"
        echo "node$nodeno: Unmount complete."
    }

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            unmountfuse $i &
        done
        wait
    else
        unmountfuse $nodeid
    fi
    exit 0
fi

function downloadNode() {
    hostaddr=${hostaddrs[$1]}
    nodeno=$(expr $1 + 1)
    containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

    username=$(sshskp $sshuser@$hostaddr "sashi list | grep $containername | awk '{ print \$2 }'")
    contractfs="/home/$username/$containername/contract_fs"
    ledgerfs="/home/$username/$containername/ledger_fs"

    echo "Downloading from node$nodeno"
    rm -r contract_fs >/dev/null 2>&1
    mkdir contract_fs
    scpskp -r -q $sshuser@$hostaddr:$contractfs/seed contract_fs/

    rm -r ledger_fs >/dev/null 2>&1
    mkdir ledger_fs
    scpskp -r -q $sshuser@$hostaddr:$ledgerfs/seed ledger_fs/
    echo "Download complete."
}

function uploadNode() {
    hostaddr=${hostaddrs[$1]}
    nodeno=$(expr $1 + 1)
    containername=$(echo $continfo | jq -r ".hosts.\"$hostaddr\".name")

    username=$(sshskp $sshuser@$hostaddr "sashi list | grep $containername | awk '{ print \$2 }'")
    contractfs="/home/$username/$containername/contract_fs"
    ledgerfs="/home/$username/$containername/ledger_fs"

    sshskp $sshuser@$hostaddr "rm -r $contractfs/{seed,hmap,log.hpfs} ; rm -r $ledgerfs/{seed,hmap,log.hpfs}"
    echo "node$nodeno: Uploading to $contractfs/"
    scpskp -r -q contract_fs/seed $sshuser@$hostaddr:$contractfs/
    echo "node$nodeno: Uploading to $ledgerfs/"
    scpskp -r -q ledger_fs/seed $sshuser@$hostaddr:$ledgerfs/

    sshskp $sshuser@$hostaddr "chown -R $username:$username $contractfs/seed ; chown -R $username:$username $ledgerfs/seed"

    echo "node$nodeno: Upload complete."
}

if [ $mode == "backup" ]; then

    if [ $nodeid = -1 ]; then
        echo "Must specify node no."
        exit 1
    else
        downloadNode $nodeid
    fi
    exit 0
fi

if [ $mode == "restore" ]; then

    if [ $nodeid = -1 ]; then
        for i in "${!hostaddrs[@]}"; do
            uploadNode $i &
        done
        wait
    else
        uploadNode $nodeid
    fi
    exit 0
fi

if [ $mode == "syncwith" ]; then

    if [ $nodeid = -1 ]; then
        echo "Must specify node no."
        exit 1
    else
        downloadNode $nodeid
        for i in "${!hostaddrs[@]}"; do
            if [ "$i" != $nodeid ]; then
                uploadNode $i &
            fi
        done
        wait
        rm -r ledger_fs
        rm -r contract_fs
    fi
    exit 0
fi
