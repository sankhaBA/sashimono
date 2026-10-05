#!/bin/bash
# Sashimono agent installation script. This supports fresh installations as well as upgrades.
# This must be executed with root privileges.

[ "$UPGRADE" == "0" ] && echo "---Sashimono installer---" || echo "---Sashimono installer (upgrade)---"

inetaddr=${1}
init_peer_port=${2}
init_user_port=${3}
init_gp_tcp_port=${4}
init_gp_udp_port=${5}
country_code=${6}
total_instance_count=${7}
cpu_micro_sec=${8}
ram_kb=${9}
swap_kb=${10}
disk_kb=${11}
lease_amount=${12}
rippled_server=${13}
xrpl_account_address=${14}
xrpl_account_secret_path=${15}
email_address=${16}
tls_key_file=${17}
tls_cert_file=${18}
tls_cabundle_file=${19}
description=${20}
ipv6_subnet=${21}
ipv6_net_interface=${22}
extra_txn_fee=${23}
fallback_rippled_servers=${24}

script_dir=$(dirname "$(realpath "$0")")
desired_slirp4netns_version="1.2.1"

mb_cli_exit_success="MB_CLI_SUCCESS"
mb_cli_out_prefix="CLI_OUT"
multi_choice_result=""

noroot_user=${SUDO_USER:-$(whoami)}

function wait_call() {
    local command_to_execute="$1"
    local output_template="$2"

    echomult "\nWaiting for the process to complete..."
    spin &
    local spin_pid=$!

    $command_to_execute
    return_code=$?

    kill $spin_pid
    wait $spin_pid
    echo -ne "\r"

    return $return_code
}

function spin() {
    while [ 1 ]; do
        for i in ${spinner[@]}; do
            echo -ne "\r$i"
            sleep 0.2
        done
    done
}

# Helper to print multi line text.
# (When passed as a parameter, bash auto strips spaces and indentation which is what we want)
function echomult() {
    echo -e $1 | awk '{print "[INFO] " $0}'
}

function rollback() {
    info "Rolling back the installation..."
    if [ "$UPGRADE" == "0" ]; then
        "$script_dir"/sashimono-uninstall.sh -f ROLLBACK
    fi

    exit 1
}

function abort() {
    info "Aborting the installation.."
    exit 1
}

function stage() {
    echo "[STAGE]" "$1" # This is picked up by the setup console output filter.
}

function info() {
    echo "[INFO]" "$1" # This is picked up by the setup console output filter.
}

function confirm() {
    local prompt="$1"
    local defaultChoice=${2:-y} #Default choice is set to 'y' if $2 parameter is not provided.

    local choiceDisplay="[Y/n]"
    if [ "$defaultChoice" == "n" ]; then
        choiceDisplay="[y/N]"
    fi

    info "$prompt $choiceDisplay "
    local yn=""
    read yn </dev/tty

    # Default choice is 'y'
    [ -z $yn ] && yn="$defaultChoice"
    while ! [[ $yn =~ ^[Yy|Nn]$ ]]; do
        read -ep "'y' or 'n' expected: " yn </dev/tty
    done

    info ""                                     # Insert new line after answering.
    [[ $yn =~ ^[Yy]$ ]] && return 0 || return 1 # 0 means success.
}

function multi_choice() {
    local prompt=$1
    local choice_display=${2:-y/n}

    IFS='/'
    read -ra ADDR <<<"$choice_display"

    local default_choice=${3:-1} #Default choice is set to first.

    # Fallback to 1 if invalid.
    ([[ ! $default_choice =~ ^[0-9]+$ ]] || [[ $default_choice -lt 0 ]] || [[ $default_choice -gt ${#ADDR[@]} ]]) && default_choice=1

    info $(echo -en "$prompt?\n")
    local i=1
    for choice in "${ADDR[@]}"; do
        [[ $default_choice -eq $i ]] && info "($i) ${choice^^}" || info "($i) $choice"
        i=$((i + 1))
    done

    local choice=""
    read choice </dev/tty

    [ -z $choice ] && choice="$default_choice"
    while ! ([[ $choice =~ ^[0-9]+$ ]] && [[ $choice -gt 0 ]] && [[ $choice -lt $i ]]); do
        info $(echo -en "[1-$i] expected: ")
        read choice </dev/tty
        [ -z $choice ] && choice="$default_choice"
    done

    multi_choice_result="${ADDR[$((choice - 1))]}"
}

function multi_choice_output() {
    echo $multi_choice_result
}

function call_third_party() {
    local command="$1"
    local operation="$2"
    local max_retries=3
    local retry_delay=5
    local attempt=1
    local command_output=""
    while [ $attempt -le $max_retries ]; do
        echo "Attempting command [$command] (attempt $attempt/$max_retries)"
        command_output=$($command)
        if [ $? -eq 0 ]; then
            echo -e "$command_output"
            return 0
        else
            echo "Command failed, retrying in $retry_delay seconds..."
            sleep $retry_delay
            ((attempt++))
        fi
    done
    echo "Max retries reached, failed $operation"
    return 1
}

function cgrulesengd_servicename() {
    # Find the cgroups rules engine service.
    local cgrulesengd_filepath=$(grep "ExecStart.*=.*/cgrulesengd$" /etc/systemd/system/*.service | head -1 | awk -F : ' { print $1 } ')
    if [ -n "$cgrulesengd_filepath" ]; then
        local cgrulesengd_filename=$(basename $cgrulesengd_filepath)
        echo "${cgrulesengd_filename%.*}"
    fi
}

function set_cpu_info() {
    [ -z $cpu_model_name ] && cpu_model_name=$(lscpu | grep -i "^Model name:" | sed 's/Model name://g; s/[#$%*@;]//g' | xargs | tr ' ' '_')
    [ -z $cpu_count ] && cpu_count=$(lscpu | grep -i "^CPU(s):" | sed 's/CPU(s)://g' | xargs)
    [ -z $cpu_mhz ] && cpu_mhz=$(lscpu | grep -i "^CPU MHz:" | sed 's/CPU MHz://g' | sed 's/\.[0-9]*//g' | xargs)
}

function setup_certbot_renewal() {
    # We need to place our script in certbook deploy hooks dir.
    local deploy_hooks_dir="/etc/letsencrypt/renewal-hooks/deploy"
    [ "$UPGRADE" == "0" ] && ! [ -d $deploy_hooks_dir ] && echo "$deploy_hooks_dir not found" && return 1

    # Setup deploy hook (update contract certs on certbot SSL auto-renewal)
    local deploy_hook="/etc/letsencrypt/renewal-hooks/deploy/sashimono-$inetaddr.sh"

    if [ "$UPGRADE" == "0" ] || [ -f $deploy_hook ]; then
        echo "Setting up certbot deploy hook $deploy_hook"
        echo "#!/bin/sh
# This script is placed by Sashimono for automatic updataing of contract SSL certs.
# Domain name: $inetaddr
certname=\$(basename \$RENEWED_LINEAGE)
[ \"\$certname\" = \"$inetaddr\" ] && evernode applyssl \$RENEWED_LINEAGE/privkey.pem \$RENEWED_LINEAGE/cert.pem \$RENEWED_LINEAGE/fullchain.pem" >$deploy_hook
        chmod +x $deploy_hook
    fi

    return 0
}

function setup_certbot() {
    stage "Setting up letsencrypt certbot"

    # Check weather there's an existing certbot installation
    if command -v certbot &>/dev/null; then
        # Get the current registration email if there's any.
        local lenc_acc_email=$(call_third_party "certbot show_account" "get current certbot account" 2>/dev/null | grep "Email contact:" | cut -d ':' -f2 | sed 's/ *//g')

        # If there's an existing registration with a different email and it has certificates, complain and return.
        # Registrations without an email show "none", those can be updated safely.
        if [[ ! -z $lenc_acc_email ]] && [[ $lenc_acc_email != $email_address ]]; then
            # If there are certificates complain and return. Otherwise update email.
            local count=$(call_third_party "certbot certificates" "check letsencrypt certificates" 2>/dev/null | grep -c "Certificate Name")
            [ $count -gt 0 ] && [[ $lenc_acc_email != "none" ]] &&
                echo "There's an existing letsencrypt registration with $lenc_acc_email, Please use the same email or update the letsencrypt email with certbot." &&
                return 1

            ! call_third_party "certbot -n update_account -m $email_address" "update certbot account details" && echo "Error when updating the existing letsencrypt account email." && return 1
        fi
    else
        # Install certbot via snap (https://certbot.eff.org/instructions?ws=other&os=ubuntufocal)
        snap install core && snap refresh core && snap install --classic certbot
    fi

    ! [ -f /snap/bin/certbot ] && echo "certbot not found" && return 1
    [ -f /usr/bin/certbot ] || ln -s /snap/bin/certbot /usr/bin/certbot || return 1

    # allow http (port 80) in firewall for certbot domain validation
    ufw allow http comment sashimono-certbot

    # Setup the certificates. If there're already certificates skip this.
    if [ ! -f /etc/letsencrypt/live/$inetaddr/privkey.pem ] || [ ! -f /etc/letsencrypt/live/$inetaddr/fullchain.pem ] || [ ! -f /etc/letsencrypt/live/$inetaddr/cert.pem ]; then
        echo "Running certbot certonly"
        call_third_party "certbot certonly -n -d $inetaddr --agree-tos --email $email_address --standalone" "setup certificates" || return 1
    fi

    setup_certbot_renewal || return 1

    return 0
}

function setup_tls_certs() {
    mkdir -p $SASHIMONO_DATA/tls

    if [ "$tls_key_file" == "letsencrypt" ]; then

        ! setup_certbot && echo "Error when setting up letsencrypt SSL certificate." && abort
        cp /etc/letsencrypt/live/$inetaddr/privkey.pem $SASHIMONO_DATA/contract_template/cfg/tlskey.pem
        cp /etc/letsencrypt/live/$inetaddr/cert.pem $SASHIMONO_DATA/contract_template/cfg/tlscert.pem
        cat /etc/letsencrypt/live/$inetaddr/fullchain.pem >>$SASHIMONO_DATA/contract_template/cfg/tlscert.pem

    elif [ "$tls_key_file" == "self" ]; then
        # If user has not provided certs we generate self-signed ones.
        stage "Generating self-signed certificates"
        ! openssl req -newkey rsa:2048 -new -nodes -x509 -days 365 -keyout $SASHIMONO_DATA/contract_template/cfg/tlskey.pem \
            -out $SASHIMONO_DATA/contract_template/cfg/tlscert.pem -subj "/C=$country_code/CN=$inetaddr" &&
            echo "Error when generating self-signed certificate." && abort

    elif [ -f "$tls_key_file" ] && [ -f "$tls_cert_file" ] && [ -f "$tls_cabundle_file" ]; then

        stage "Transferring certificate files"

        cp $tls_key_file $SASHIMONO_DATA/contract_template/cfg/tlskey.pem
        cp $tls_cert_file $SASHIMONO_DATA/contract_template/cfg/tlscert.pem
        # ca bundle is also required.
        cat $tls_cabundle_file >>$SASHIMONO_DATA/contract_template/cfg/tlscert.pem

    else
        echo "Error when setting up SSL certificate." && abort
    fi
}

function check_dependencies() {
    local setup_slirp4netns=0

    if command -v slirp4netns &>/dev/null; then
        installed_version=$(slirp4netns --version | awk 'NR==1 {print $3}')
        if [ "$installed_version" != "$desired_slirp4netns_version" ]; then
            apt-get -y remove slirp4netns >/dev/null
            setup_slirp4netns=1
        fi
    else
        setup_slirp4netns=1
    fi

    if [ $setup_slirp4netns -gt 0 ]; then
        # Setting up slirp4netns from github (ubuntu package is outdated. We need newer binary for ipv6 outbound address support)
        stage "Setting up slirp4netns"
        curl -o /tmp/slirp4netns --fail -sL https://github.com/rootless-containers/slirp4netns/releases/download/v$desired_slirp4netns_version/slirp4netns-$(uname -m)
        chmod +x /tmp/slirp4netns
        mv /tmp/slirp4netns /usr/bin/
    fi
}

function exec_mb() {
    local res=$(sudo -u $MB_XRPL_USER MB_DATA_DIR="$MB_XRPL_DATA" node "$MB_XRPL_BIN" "$@" | tee >(stdbuf --output=L sed -E '/^Minted lease/s/^/[STAGE] -p /;/^Burnt unsold hosting URIToken/s/^/[STAGE] -p /' >/dev/fd/2))

    local return_code=0
    [[ "$res" != *"$mb_cli_exit_success"* ]] && return_code=1

    res=$(echo "$res" | sed -n -e "/^$mb_cli_out_prefix: /p")
    echo "${res#"$mb_cli_out_prefix: "}"
    return $return_code
}

function burn_leases() {
    stage "Burning lease tokens..."
    if ! res=$(exec_mb burn-leases); then
        multi_choice "An error occurred while burning! What do you want to do" "Retry/Abort/Rollback" && local input=$(multi_choice_output)
        if [ "$input" == "Retry" ]; then
            burn_leases "$@" && return 0
        elif [ "$input" == "Rollback" ]; then
            rollback
        else
            abort
        fi
        return 1
    fi
    return 0
}

function mint_leases() {
    stage "Minting lease tokens..."
    if ! res=$(exec_mb mint-leases $total_instance_count); then
        if [[ "$res" == "LEASE_AMT_ERR" ]] || [[ "$res" == "LEASE_IP_ERR" ]]; then
            local err_msg="EVR valuations"
            [[ "$res" == "LEASE_IP_ERR" ]] && err_msg="outbound IPs"
            if confirm "Existing lease $err_msg are inconsistent with the configuration! Do you want to burn minted tokens? (N will abort the installation)" "n"; then
                burn_leases && mint_leases "$@" && return 0
            else
                abort
            fi
        else
            multi_choice "An error occurred while minting! What do you want to do" "Retry/Abort/Rollback" && local input=$(multi_choice_output)
            if [ "$input" == "Retry" ]; then
                mint_leases "$@" && return 0
            elif [ "$input" == "Rollback" ]; then
                rollback
            else
                abort
            fi
        fi
        return 1
    fi
    return 0
}

function deregister() {
    if ! res=$(exec_mb deregister $1); then
        multi_choice "An error occurred while registering! What do you want to do" "Retry/Abort/Rollback" && local input=$(multi_choice_output)
        if [ "$input" == "Retry" ]; then
            deregister "$@" && return 0
        elif [ "$input" == "Rollback" ]; then
            rollback
        else
            abort
        fi
        return 1
    fi
    return 0
}

function register() {
    if ! res=$(exec_mb register $country_code $cpu_micro_sec $ram_kb $swap_kb $disk_kb $total_instance_count $cpu_model_name $cpu_count $cpu_mhz $email_address $description); then
        multi_choice "An error occurred while registering! What do you want to do" "Retry/Abort/Rollback" && local input=$(multi_choice_output)
        if [ "$input" == "Retry" ]; then
            register "$@" && return 0
        elif [ "$input" == "Rollback" ]; then
            rollback
        else
            abort
        fi
        return 1
    fi
    return 0
}

function check_balance() {
    if ! res=$(exec_mb check-balance); then
        multi_choice "Do you want to re-check the balance" "Retry/Abort/Rollback" && local input=$(multi_choice_output)
        if [ "$input" == "Retry" ]; then
            check_balance "$@" && return 0
        elif [ "$input" == "Rollback" ]; then
            rollback
        else
            abort
        fi
        return 1
    fi

    return 0
}

function check_and_register() {
    if ! res=$(exec_mb check-reg $country_code $cpu_micro_sec $ram_kb $swap_kb $disk_kb $total_instance_count $cpu_model_name $cpu_count $cpu_mhz $email_address $description); then
        if [[ "$res" == "ACC_NOT_FOUND" ]]; then
            info "Account not found, Please check your account and try again." && abort
            return 1
        elif [[ "$res" == "INVALID_REG" ]]; then
            info "Invalid registration please transfer or deregister and try again" && abort
            return 1
        elif [[ "$res" == "PENDING_SELL_OFFER" ]]; then
            register && return 0
            return 1
        elif [[ "$res" == "PENDING_TRANSFER" ]] || [[ "$res" == "NOT_REGISTERED" ]]; then
            check_balance && register && return 0
            return 1
        fi
    elif [[ "$res" == "REGISTERED" ]]; then
        echo "This host is registered"
        return 0
    fi

    info "Invalid registration please transfer or deregister and try again" && abort
    return 1
}

# Function to generate QR code in the terminal
function generate_qrcode() {
    if [ -z "$1" ]; then
        echo "Argument error > Usage: generate_qrcode <string>"
        return 1
    fi
    local input_string="$1"
    qrencode -s 1 -l L -t UTF8 "$input_string"
}

function upgrade() {
    if ! res=$(exec_mb upgrade); then
        multi_choice "An error occurred while upgrading! What do you want to do" "Retry/Abort/Rollback" && local input=$(multi_choice_output)
        if [ "$input" == "Retry" ]; then
            upgrade "$@" && return 0
        elif [ "$input" == "Rollback" ]; then
            rollback
        else
            abort
        fi
        return 1
    fi

    return 0
}

# Check cgroup rule config exists.
[ ! -f /etc/cgred.conf ] && echo "cgroups is not configured. Make sure you've installed and configured cgroup-tools." && exit 1

# Stop services before start upgrade.
if [[ "$UPGRADE" == "1" ]]; then
    systemctl stop $SASHIMONO_SERVICE
    systemctl stop $CGCREATE_SERVICE
    sudo -u "$MB_XRPL_USER" XDG_RUNTIME_DIR="$mb_user_runtime_dir" systemctl --user stop $MB_XRPL_SERVICE
fi

# Create bin and data directories if not exist.
mkdir -p $SASHIMONO_BIN
mkdir -p $SASHIMONO_DATA

# Put Sashimono uninstallation into sashimono bin dir.
# We do this at the begining because then if message board registration failed user can uninstall sashimono with evernode command.
cp "$script_dir"/sashimono-uninstall.sh $SASHIMONO_BIN
chmod +x $SASHIMONO_BIN/sashimono-uninstall.sh

! set_cpu_info && echo "Fetching CPU info failed" && abort

# Copy contract template and licence file (delete existing)
# Backup the ssl cert files if exists
tmp=$(mktemp -d)
[ "$UPGRADE" != "0" ] && cp $SASHIMONO_DATA/contract_template/cfg/{tlskey.pem,tlscert.pem} "$tmp"/
rm -r "$SASHIMONO_DATA"/{contract_template,evernode-license.pdf} >/dev/null 2>&1
cp -r "$script_dir"/{contract_template,evernode-license.pdf} $SASHIMONO_DATA
[ "$UPGRADE" != "0" ] && cp "$tmp"/{tlskey.pem,tlscert.pem} $SASHIMONO_DATA/contract_template/cfg/
rm -r "$tmp"

# Create self signed tls certs on update if not exists
# This is added to auto fix the hosts which got their ssl certificates removed in v0.5.20
[ "$UPGRADE" != "0" ] && ([ ! -f "$SASHIMONO_DATA/contract_template/cfg/tlskey.pem" ] || [ ! -f "$SASHIMONO_DATA/contract_template/cfg/tlscert.pem" ]) &&
    openssl req -newkey rsa:2048 -new -nodes -x509 -days 365 -keyout $SASHIMONO_DATA/contract_template/cfg/tlskey.pem \
        -out $SASHIMONO_DATA/contract_template/cfg/tlscert.pem -subj "/C=HP/CN=$(jq -r '.hp.host_address' $SASHIMONO_DATA/sa.cfg)"

# Install Sashimono agent binaries into sashimono bin dir.
cp "$script_dir"/{sagent,hpfs,user-cgcreate.sh,user-install.sh,dns_evernode.sh,user-uninstall.sh,docker-registry-uninstall.sh} $SASHIMONO_BIN
chmod -R +x $SASHIMONO_BIN

# Setup tls certs used for contract instance websockets.
[ "$UPGRADE" == "0" ] && setup_tls_certs

# Update renewal of tls certs used for contract instance websockets.
[ "$UPGRADE" == "1" ] && setup_certbot_renewal

# Copy Blake3 and update linker library cache.
[ ! -f /usr/local/lib/libblake3.so ] && cp "$script_dir"/libblake3.so /usr/local/lib/ && ldconfig

# Install Sashimono CLI binaries into user bin dir.
cp "$script_dir"/sashi $USER_BIN

# Check whether denedencies are installed or not. (slirp4netns)
check_dependencies

# Download and install rootless dockerd.
stage "Installing docker packages"
# Create docker bin directory.
mkdir -p $DOCKER_BIN
! "$script_dir"/docker-install.sh $DOCKER_BIN && echo "DOCKER_INSTALL_FAILURE" && abort

# Check whether docker installation dir is still empty.
[ -z "$(ls -A $DOCKER_BIN 2>/dev/null)" ] && echo "Rootless Docker installation failed." && abort

# Install private docker registry.
if [ "$DOCKER_REGISTRY_PORT" != "0" ]; then
    stage "Installing private docker registry"
    # TODO: secure registry configuration
    "$script_dir"/docker-registry-install.sh
    [ "$?" == "1" ] && echo "Private docker registry installation failed." && abort
else
    echo "Private docker registry installation skipped"
fi

# If installing with sudo, add current logged-in user to Sashimono admin group.
[ -n "$SUDO_USER" ] && usermod -a -G $SASHIADMIN_GROUP $SUDO_USER

# First create the folder from root and then transfer ownership to the user
# since the folder is created in /etc/sashimono directory.
! mkdir -p $REPUTATIOND_DATA && echo "Could not create '$REPUTATIOND_DATA'. Make sure you are running as sudo." && exit 1
# Change ownership to reputationd user.
chown -R "$REPUTATIOND_USER":"$REPUTATIOND_USER" $REPUTATIOND_DATA

# Configure message board users and register host.
echo "configuring host setup on Evernode..."

cp -r "$script_dir"/mb-xrpl $SASHIMONO_BIN
cp -r "$script_dir"/reputationd $SASHIMONO_BIN

# Create MB_XRPL_USER if does not exists..
if ! grep -q "^$MB_XRPL_USER:" /etc/passwd; then
    useradd --shell /usr/sbin/nologin -m $MB_XRPL_USER

    # Setting the ownership of the MB_XRPL_USER's home to MB_XRPL_USER expilcity.
    # NOTE : There can be user id mismatch, as we do not delete MB_XRPL_USER's home in the uninstallation even though the user is removed.
    chown -R "$MB_XRPL_USER":"$SASHIADMIN_GROUP" /home/$MB_XRPL_USER

    secret_path=$(jq -r '.xrpl.secretPath' "$MB_XRPL_CONFIG")
    chown "$MB_XRPL_USER":"$SASHIADMIN_GROUP" $secret_path
fi

# Assign message board user priviledges.
if ! id -nG "$MB_XRPL_USER" | grep -qw "$SASHIADMIN_GROUP"; then
    usermod --lock $MB_XRPL_USER
    usermod -a -G $SASHIADMIN_GROUP $MB_XRPL_USER
    loginctl enable-linger $MB_XRPL_USER # Enable lingering to support service installation.
fi

# First create the folder from root and then transfer ownership to the user
# since the folder is created in /etc/sashimono directory.
! mkdir -p $MB_XRPL_DATA && echo "Could not create '$MB_XRPL_DATA'. Make sure you are running as sudo." && exit 1
# Change ownership to message board user.
chown -R "$MB_XRPL_USER":"$MB_XRPL_USER" $MB_XRPL_DATA

# Register if not upgrade mode.
if [[ "$UPGRADE" == "0" ]] && [ ! -f "$MB_XRPL_CONFIG" ]; then
    # Setup and register the account.
    stage "Configuring host Xahau account"
    echo "Using registry: $EVERNODE_REGISTRY_ADDRESS"

    ! sudo -u $MB_XRPL_USER MB_DATA_DIR=$MB_XRPL_DATA node $MB_XRPL_BIN new $xrpl_account_address $xrpl_account_secret_path $EVERNODE_GOVERNOR_ADDRESS $inetaddr $lease_amount $rippled_server $email_address $extra_txn_fee $ipv6_subnet $ipv6_net_interface $NETWORK $fallback_rippled_servers && echo "CONFIG_SAVING_FAILURE" && abort
fi

stage "Configuring Sashimono services"

cgrulesengd_service=$(cgrulesengd_servicename)
[ -z "$cgrulesengd_service" ] && echo "cgroups rules engine service does not exist." && abort

# Setting up cgroup rules with sashiusers group (if not already setup).
echo "Creating cgroup rules..."
! grep -q $SASHIUSER_GROUP /etc/group && ! groupadd $SASHIUSER_GROUP && echo "$SASHIUSER_GROUP group creation failed." && abort
if ! grep -q $SASHIUSER_GROUP /etc/cgrules.conf; then
    ! echo "@$SASHIUSER_GROUP       cpu,memory              %u$CG_SUFFIX" >>/etc/cgrules.conf && echo "Cgroup rule creation failed." && abort
    # Restart the service to apply the cgrules config.
    echo "Restarting the '$cgrulesengd_service' service."
    systemctl restart $cgrulesengd_service || abort
fi

# Install Sashimono Agent cgcreate service.
# This is a oneshot service which runs once at system startup. The intention is to run 'cgcreate' for
# all sashimono users every time the system boots up.
echo "[Unit]
Description=Sashimono cgroup creation service.
After=network.target
[Service]
User=root
Group=root
Type=oneshot
ExecStart=$SASHIMONO_BIN/user-cgcreate.sh $SASHIMONO_DATA
[Install]
WantedBy=multi-user.target" >/etc/systemd/system/$CGCREATE_SERVICE.service

echo "Configuring sashimono agent service..."

# Since gp ports are added as new feature we manually configure the default on upgrade mode if not exists.
# TODO: Added because v0.8.4 does not have gp ports.
if [[ "$UPGRADE" == "1" ]] && [ -f "$SASHIMONO_CONFIG" ]; then
    cfg_init_gp_tcp_port=$(jq ".hp.init_gp_tcp_port | select( . != null )" "$SASHIMONO_CONFIG")
    cfg_init_gp_udp_port=$(jq ".hp.init_gp_udp_port | select( . != null )" "$SASHIMONO_CONFIG")
    if [ -z $cfg_init_gp_tcp_port ] || [ -z $cfg_init_gp_udp_port ]; then
        if [ -z $cfg_init_gp_tcp_port ]; then
            cfg_init_gp_tcp_port=36525
            tmp=$(mktemp)
            jq ".hp.init_gp_tcp_port = $cfg_init_gp_tcp_port" "$SASHIMONO_CONFIG" >"$tmp" && mv "$tmp" "$SASHIMONO_CONFIG"
        fi
        if [ -z $cfg_init_gp_udp_port ]; then
            cfg_init_gp_udp_port=39064
            tmp=$(mktemp)
            jq ".hp.init_gp_udp_port = $cfg_init_gp_udp_port" "$SASHIMONO_CONFIG" >"$tmp" && mv "$tmp" "$SASHIMONO_CONFIG"
        fi
        chmod 644 "$SASHIMONO_CONFIG"
    fi
fi

# Create sashimono agent config (if not exists).
if [ -f $SASHIMONO_DATA/sa.cfg ]; then
    echo "Existing Sashimono data directory found. Updating..."
    ! $SASHIMONO_BIN/sagent upgrade $SASHIMONO_DATA && abort
elif [ ! -f "$SASHIMONO_CONFIG" ]; then
    ! $SASHIMONO_BIN/sagent new $SASHIMONO_DATA $inetaddr $init_peer_port $init_user_port $init_gp_tcp_port $init_gp_udp_port $DOCKER_REGISTRY_PORT \
        $total_instance_count $cpu_micro_sec $ram_kb $swap_kb $disk_kb && abort
fi

if [[ -f "$MB_XRPL_CONFIG" ]]; then
    upgrade || abort
fi

# Install Sashimono Agent systemd service.
# StartLimitIntervalSec=0 to make unlimited retries. RestartSec=5 is to keep 5 second gap between restarts.
echo "[Unit]
Description=Running and monitoring sashimono agent.
After=network.target
StartLimitIntervalSec=0
[Service]
User=root
Group=root
Type=simple
WorkingDirectory=$SASHIMONO_BIN
ExecStart=$SASHIMONO_BIN/sagent run $SASHIMONO_DATA
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target" >/etc/systemd/system/$SASHIMONO_SERVICE.service

systemctl daemon-reload
systemctl enable $CGCREATE_SERVICE
systemctl start $CGCREATE_SERVICE
systemctl enable $SASHIMONO_SERVICE
# Here, $SASHIMONO_SERVICE is only enabled. Not started. It'll be started after pending reboot checks at
# the bottom of this script.
# Both of these services needed to be restarted if sa.cfg max instance resources are manually changed.

# Install Xahau message board systemd service.
echo "Installing Evernode Xahau message board..."

mb_user_dir=/home/"$MB_XRPL_USER"
mb_user_id=$(id -u "$MB_XRPL_USER")
mb_user_runtime_dir="/run/user/$mb_user_id"

# Setting the ownership of the MB_XRPL_USER's home to MB_XRPL_USER expilcity.
# NOTE : There can be user id mismatch, as we do not delete MB_XRPL_USER's home in the uninstallation even though the user is removed.
chown -R "$MB_XRPL_USER":"$SASHIADMIN_GROUP" $mb_user_dir

# Setup env variable for the message board user.
echo "
    export XDG_RUNTIME_DIR=$mb_user_runtime_dir" >>"$mb_user_dir"/.bashrc
echo "Updated mb user .bashrc."

user_systemd=""
for ((i = 0; i < 30; i++)); do
    sleep 0.1
    user_systemd=$(sudo -u "$MB_XRPL_USER" XDG_RUNTIME_DIR="$mb_user_runtime_dir" systemctl --user is-system-running 2>/dev/null)
    [ "$user_systemd" == "running" ] && break
done
[ "$user_systemd" != "running" ] && echo "NO_MB_USER_SYSTEMD" && abort

stage "Configuring Xahau message board service"
! (sudo -u $MB_XRPL_USER mkdir -p "$mb_user_dir"/.config/systemd/user/) && echo "Message board user systemd folder creation failed" && abort
# StartLimitIntervalSec=0 to make unlimited retries. RestartSec=5 is to keep 5 second gap between restarts.
echo "[Unit]
    Description=Running and monitoring evernode Xahau transactions.
    After=network.target
    StartLimitIntervalSec=0
    [Service]
    Type=simple
    WorkingDirectory=$MB_XRPL_BIN
    Environment=\"MB_DATA_DIR=$MB_XRPL_DATA\"
    ExecStart=/usr/bin/node $MB_XRPL_BIN
    Restart=on-failure
    RestartSec=5
    [Install]
    WantedBy=default.target" | sudo -u $MB_XRPL_USER tee "$mb_user_dir"/.config/systemd/user/$MB_XRPL_SERVICE.service >/dev/null

# This service needs to be restarted whenever mb-xrpl.cfg or secret.cfg is changed.
sudo -u "$MB_XRPL_USER" XDG_RUNTIME_DIR="$mb_user_runtime_dir" systemctl --user enable $MB_XRPL_SERVICE
# We only enable this service. It'll be started after pending reboot checks at the bottom of this script.
echo "Installed Evernode Xahau message board."

if [ "$UPGRADE" == "0" ]; then
    stage "Registering host on Evernode registry $EVERNODE_REGISTRY_ADDRESS"
    echo "Executing register with params: $country_code $cpu_micro_sec $ram_kb $swap_kb $disk_kb $total_instance_count \
                $cpu_model_name $cpu_count $cpu_mhz $email_address $description"
    check_and_register || abort
    mint_leases || abort
    echo "Registered host on Evernode."
fi

# If there's no pending reboot, start the sashimono and message board services now. Otherwise
# they'll get started at next startup.
if [ ! -f /run/reboot-required.pkgs ] || [ ! -n "$(grep sashimono /run/reboot-required.pkgs)" ]; then
    echo "Starting the sashimono and message board services."
    systemctl restart $SASHIMONO_SERVICE

    sudo -u "$MB_XRPL_USER" XDG_RUNTIME_DIR="$mb_user_runtime_dir" systemctl --user restart $MB_XRPL_SERVICE
fi

echo "Sashimono installed successfully."

exit 0
