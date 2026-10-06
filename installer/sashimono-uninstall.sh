#!/bin/bash
# Sashimono agent uninstall script.
# This must be executed with root privileges.

export TRANSFER=${TRANSFER:-0}

mb_cli_exit_success="MB_CLI_SUCCESS"
mb_cli_out_prefix="CLI_OUT"
multi_choice_result=""

[ "$UPGRADE" == "0" ] && echo "---Sashimono uninstaller---" || echo "---Sashimono uninstaller (for upgrade)---"

force=$1
dereg_reason=$2

function confirm() {
    echo -en $1" [Y/n] "
    local yn=""
    read yn </dev/tty

    # Default choice is 'y'
    [ -z $yn ] && yn="y"
    while ! [[ $yn =~ ^[Yy|Nn]$ ]]; do
        read -p "'y' or 'n' expected: " yn </dev/tty
    done

    echo ""                                     # Insert new line after answering.
    [[ $yn =~ ^[Yy]$ ]] && return 0 || return 1 # 0 means success.
}

function abort() {
    echo "Aborting the uninstallation.."
    exit 1
}

function multi_choice() {
    local prompt=$1
    local choice_display=${2:-y/n}

    IFS='/'
    read -ra ADDR <<<"$choice_display"

    local default_choice=${3:-1} #Default choice is set to first.

    # Fallback to 1 if invalid.
    ([[ ! $default_choice =~ ^[0-9]+$ ]] || [[ $default_choice -lt 0 ]] || [[ $default_choice -gt ${#ADDR[@]} ]]) && default_choice=1

    echo -en "$prompt?\n"
    local i=1
    for choice in "${ADDR[@]}"; do
        [[ $default_choice -eq $i ]] && echo "($i) ${choice^^} " || echo "($i) $choice "
        i=$((i + 1))
    done

    local choice=""
    read choice </dev/tty

    [ -z $choice ] && choice="$default_choice"
    while ! ([[ $choice =~ ^[0-9]+$ ]] && [[ $choice -gt 0 ]] && [[ $choice -lt $i ]]); do
        read -ep "[1-$i] expected: " choice </dev/tty
        [ -z $choice ] && choice="$default_choice"
    done

    multi_choice_result="${ADDR[$((choice - 1))]}"
}

function multi_choice_output() {
    echo $multi_choice_result
}

function exec_mb() {
    local res=$(sudo -u $MB_XRPL_USER MB_DATA_DIR="$MB_XRPL_DATA" node "$MB_XRPL_BIN" "$@" | tee /dev/fd/2)

    local return_code=0
    [[ "$res" != *"$mb_cli_exit_success"* ]] && return_code=1

    res=$(echo "$res" | sed -n -e "/^$mb_cli_out_prefix: /p")
    echo "${res#"$mb_cli_out_prefix: "}"
    return $return_code
}

function cgrulesengd_servicename() {
    # Find the cgroups rules engine service.
    local cgrulesengd_filepath=$(grep "ExecStart.*=.*/cgrulesengd$" /etc/systemd/system/*.service | head -1 | awk -F : ' { print $1 } ')
    if [ -n "$cgrulesengd_filepath" ]; then
        local cgrulesengd_filename=$(basename $cgrulesengd_filepath)
        echo "${cgrulesengd_filename%.*}"
    fi
}

function cleanup_certbot_ssl() {
    # revoke/delete certs if certbot is used.
    if command -v certbot &>/dev/null && [ -f "$SASHIMONO_DATA/sa.cfg" ]; then
        local inet_addr=$(jq -r '.hp.host_address' $SASHIMONO_DATA/sa.cfg)
        local deploy_hook_script="/etc/letsencrypt/renewal-hooks/deploy/sashimono-$inet_addr.sh"
        if [ -f $deploy_hook_script ]; then
            echo "Cleaning up letsencrypt ssl certs for '$inet_addr'"
            rm $deploy_hook_script
            certbot -n revoke --cert-name $inet_addr

            # cleaning up firewall rule for domain validation
            echo "Cleaning up firewall rule for SSL validation"
            ufw delete allow 80/tcp
        fi

        # If there are no certificates unregister.
        local count=$(certbot certificates 2>/dev/null | grep -c "Certificate Name")
        [ $count -eq 0 ] && certbot unregister -n
    fi
}

function burn_leases() {
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

function deregister() {
    if ! res=$(exec_mb deregister $1); then
        multi_choice "An error occurred while de-registering! What do you want to do" "Retry/Abort" && local input=$(multi_choice_output)
        if [ "$input" == "Retry" ]; then
            deregister "$@" && return 0
        else
            abort
        fi
        return 1
    fi
    return 0
}

function accept_reg_token() {
    if ! res=$(exec_mb accept-reg-token); then
        multi_choice "An error occurred while accepting the reg token! What do you want to do" "Retry/Abort" && local input=$(multi_choice_output)
        if [ "$input" == "Retry" ]; then
            accept_reg_token "$@" && return 0
        else
            abort
        fi
        return 1
    fi
    return 0
}

function check_and_deregister() {
    if ! res=$(exec_mb check-reg); then
        if [[ "$res" == "NOT_REGISTERED" ]]; then
            echo "This host is de-registered"
            return 0
        elif [[ "$res" == "ACC_NOT_FOUND" ]]; then
            echo "Account not found, Please check your account and try again." && abort
            return 1
        elif [[ "$res" == "INVALID_REG" ]]; then
            echo "Invalid registration please transfer and try again" && abort
            return 1
        elif [[ "$res" == "PENDING_SELL_OFFER" ]]; then
            accept_reg_token && burn_leases && deregister $1 && return 0
            return 1
        elif [[ "$res" == "PENDING_TRANSFER" ]]; then
            echo "There a pending transfer, Please re-install and try again." && abort
            return 1
        fi
    elif [[ "$res" == "REGISTERED" ]]; then
        burn_leases && deregister $1
        return 0
    fi

    echo "Invalid registration please transfer and try again" && abort
    return 1
}

[ ! -d $SASHIMONO_BIN ] && echo "$SASHIMONO_BIN does not exist. Aborting uninstall." && exit 1

# Message board---------------------
# Check whether mb user exists. If so stop the message board service.
# We do this at the begining so redeem requests won't be accepted while uninstallation.
if grep -q "^$MB_XRPL_USER:" /etc/passwd; then

    mb_user_dir=/home/"$MB_XRPL_USER"
    mb_user_id=$(id -u "$MB_XRPL_USER")
    mb_user_runtime_dir="/run/user/$mb_user_id"
    mb_service_path="$mb_user_dir"/.config/systemd/user/$MB_XRPL_SERVICE.service
    # Remove Xahau message board service if exists.
    if [ -f $mb_service_path ]; then
        sudo -u "$MB_XRPL_USER" XDG_RUNTIME_DIR="$mb_user_runtime_dir" systemctl --user stop $MB_XRPL_SERVICE
        sudo -u "$MB_XRPL_USER" XDG_RUNTIME_DIR="$mb_user_runtime_dir" systemctl --user disable $MB_XRPL_SERVICE
    fi

fi

# Reputatind---------------------
# Check whether reputationd user exists. If so stop the reputationd service.
if grep -q "^$REPUTATIOND_USER:" /etc/passwd; then

    reputationd_user_dir=/home/"$REPUTATIOND_USER"
    reputationd_user_id=$(id -u "$REPUTATIOND_USER")
    reputationd_user_runtime_dir="/run/user/$reputationd_user_id"
    reputationd_service_path="$reputationd_user_dir"/.config/systemd/user/$REPUTATIOND_SERVICE.service
    # Remove reputationd service if exists.
    if [ -f $reputationd_service_path ]; then
        sudo -u "$REPUTATIOND_USER" XDG_RUNTIME_DIR="$reputationd_user_runtime_dir" systemctl --user stop $REPUTATIOND_SERVICE
        sudo -u "$REPUTATIOND_USER" XDG_RUNTIME_DIR="$reputationd_user_runtime_dir" systemctl --user disable $REPUTATIOND_SERVICE
    fi

fi

# Uninstall all contract instance users---------------------------
if [ "$UPGRADE" == "0" ]; then
    users=$(cut -d: -f1 /etc/passwd | grep "^$SASHIUSER_PREFIX" | sort)
    readarray -t userarr <<<"$users"
    sashiusers=()
    for user in "${userarr[@]}"; do
        [ ${#user} -lt 24 ] || [ ${#user} -gt 32 ] || [[ ! "$user" =~ ^$SASHIUSER_PREFIX[0-9]+$ ]] && continue
        sashiusers+=("$user")
    done

    ucount=${#sashiusers[@]}
    if [ $ucount -gt 0 ]; then

        echo "Detected $ucount contract instances."
        for user in "${sashiusers[@]}"; do
            echo "$user"
        done

        echo "Deleting $ucount contract instances..."
        for user in "${sashiusers[@]}"; do
            homedir=$(eval echo ~$user)
            cfgpath=$(find $homedir/ -type f -regex ^$homedir/[^/]+/cfg/hp.cfg$ 2>/dev/null | head -n 1)
            instancename=$(echo $cfgpath | rev | cut -d '/' -f 3 | rev)
            peerport=$(jq .mesh.port $cfgpath)
            userport=$(jq .user.port $cfgpath)
            output=$($SASHIMONO_BIN/user-uninstall.sh $user $peerport $userport $instancename | tee /dev/stderr)
            [ "${output: -10}" != "UNINST_SUC" ] && echo "Uninstall user '$user' failed. Aborting." && exit 1
        done
    fi

    # Find if there are any garbage rules that are created by sashimono and remove them.
    prefix="sashi"
    ufw status | grep -E ^[0-9]+,[0-9]+/tcp\\s+ALLOW\\s+Anywhere\\s+\#\\s$prefix-.+$ | while read -r line; do
        ports=$(echo $line | cut -d ' ' -f 1)
        echo "Removing found garbage ufw $ports rule..."
        p1=$(echo $ports | cut -d ',' -f 1)
        p2=$(echo $ports | cut -d ',' -f 2 | cut -d '/' -f 1)
        ufw delete allow "$p1","$p2"/tcp
    done
fi

echo "Removing Sashimono cgroup creation service..."
systemctl stop $CGCREATE_SERVICE
systemctl disable $CGCREATE_SERVICE
rm /etc/systemd/system/$CGCREATE_SERVICE.service

echo "Removing Sashimono service..."
systemctl stop $SASHIMONO_SERVICE
systemctl disable $SASHIMONO_SERVICE
service_path="/etc/systemd/system/$SASHIMONO_SERVICE.service"
rm $service_path

# Reload the systemd daemon after removing the service
systemctl daemon-reload

if [ -f $SASHIMONO_BIN/docker-registry-uninstall.sh ]; then
    echo "Removing Sashimono private docker registry..."
    $SASHIMONO_BIN/docker-registry-uninstall.sh
fi

# Delete binaries except message board and sashimnono uninstall script.
# We keep uninstall script so user can uninstall again if error occurred at later steps.
# We'll remove these after deregistration.
echo "Deleting binaries..."
find $SASHIMONO_BIN -mindepth 1 ! \( -regex "^$MB_XRPL_BIN\(/.*\)?" -o -path $SASHIMONO_BIN/sashimono-uninstall.sh \) -delete

echo "Deleting Sashimono CLI..."
rm $USER_BIN/sashi

if [ "$UPGRADE" == "0" ]; then
    # When removing the cgrules service, we first edit the config and restart the service to apply the config.
    # Then we remove the attached group.
    # cgroup rules only exist if Sashimono was installed with cgroup v1.
    if [ -f /etc/cgrules.conf ]; then
        echo "Deleting cgroup rules..."
        sed -i -r "/^@$SASHIUSER_GROUP\s+cpu,memory\s+%u$CG_SUFFIX/d" /etc/cgrules.conf

        cgrulesengd_service=$(cgrulesengd_servicename)
        if [ -z "$cgrulesengd_service" ]; then
            echo "Warning: cgroups rules engine service does not exist."
        else
            echo "Restarting the '$cgrulesengd_service' service..."
            systemctl restart $cgrulesengd_service
        fi
    fi
    groupdel $SASHIUSER_GROUP
fi

# Deregistration---------------------
# Check whether mb user exists. If so deregister and remove the user.
# If the deregistration came from rollback, stop doing the deregistration
if grep -q "^$MB_XRPL_USER:" /etc/passwd; then

    if { [ -z "$dereg_reason" ] || [ "$dereg_reason" != "ROLLBACK" ]; } && [ "$UPGRADE" == "0" ] && [ "$TRANSFER" == "0" ] && grep -q "^$MB_XRPL_USER:" /etc/passwd; then
        # Deregister evernode message board host registration.
        echo "Attempting Evernode host deregistration..."
        # Message board service is created at the end of the installation. So, if this exists previous installation is a successfull one.
        # If not force or quiet mode and deregistration failed and if the previous installation a successful one,
        # Exit the uninstallation, So user can try uninstall again with deregistration.
        if ! check_and_deregister $dereg_reason &&
            [ "$force" != "-f" ] && [ -f $mb_service_path ]; then
            ! confirm "Evernode host deregistration failed. Still do you want to continue uninstallation?" && echo "Aborting uninstallation. Try again later." && exit 1
            echo "Continuing uninstallation..."
        fi
    fi

    echo "Deleting message board user..."
    # Killall command is not found in every linux systems, therefore pkill command is used.
    # A small timeout(0.5 second) is applied before deleting the user because it takes some time to kill all the processes
    loginctl disable-linger $MB_XRPL_USER
    pkill -u $MB_XRPL_USER # Kill any running processes.
    sleep 0.5
    userdel -f "$MB_XRPL_USER"

    echo "Deleting reputationd user..."
    # Killall command is not found in every linux systems, therefore pkill command is used.
    # A small timeout(0.5 second) is applied before deleting the user because it takes some time to kill all the processes
    loginctl disable-linger $REPUTATIOND_USER
    pkill -u $REPUTATIOND_USER # Kill any running processes.
    sleep 0.5
    userdel -f "$REPUTATIOND_USER"

fi

# Delete all the data and bin directories.
echo "Deleting binaries..."
rm -r $SASHIMONO_BIN

if [ "$UPGRADE" == "0" ]; then

    cleanup_certbot_ssl

    echo "Deleting data directory..."
    rm -r $SASHIMONO_DATA
fi

groupdel $SASHIADMIN_GROUP

[ "$UPGRADE" == "0" ] && echo "Sashimono uninstalled successfully." || echo "Sashimono uninstalled successfully. Your data has been preserved."

exit 0
