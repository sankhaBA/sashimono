#!/bin/bash
# Sashimono Ubuntu prerequisites installation script.
# This must be executed with root privileges.

# Adding user disk quota limitation capability
# Enable user quota in fstab for root mount.
# Enable cgroup memory and swapaccount capability.
# Setup cgroups rules engine service.

echo "---Sashimono prerequisites installer---"

tmp=$(mktemp -d)
tmpfstab=$tmp.tmp
originalfstab=/etc/fstab
cp $originalfstab "$tmpfstab"
backup=$originalfstab.sashi.bk
cgrulesengd_service=$1 # cgroups rules engine service name

[ -z "$cgrulesengd_service" ] && cgrulesengd_service="cgrulesengd"

function stage() {
    echo "STAGE $1" # This is picked up by the setup console output filter.
}

stage "Installing dependencies"

# Added --allow-releaseinfo-change
# To fix - Repository 'https://apprepo.vultr.com/ubuntu universal InRelease' changed its 'Codename' value from 'buster' to 'universal'
apt-get update --allow-releaseinfo-change
apt-get install -y uidmap fuse3 cgroup-tools quota curl openssl

# uidmap        # Required for rootless docker.
# slirp4netns   # Required for high performance rootless networking.
# fuse3         # Required for hpfs.
# cgroup-tools  # Required to setup contract instances resource limits.
# quota         # Required for disk space group quota.
# curl          # Required to download installation artifacts.
# openssl       # Required by Sashimono agent to create contract tls certs.
# jq            # Used for json config file manipulation.

# Install nodejs if not exists.
if ! command -v node &>/dev/null; then
    stage "Installing nodejs"
    apt-get install -y ca-certificates curl gnupg
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

    NODE_MAJOR=20
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get -y install nodejs
else
    version=$(node -v | cut -d '.' -f1)
    version=${version:1}
    if [[ $version -lt 20 ]]; then
        echo "Found node $version, recommended node v20.x.x or later"
    fi
fi

# Install iptables
if ! command -v iptables &>/dev/null; then
    stage "Installing iptables"
    apt-get install -y iptables
fi

# Load br_netfilter kernel module on startup (if not loaded already).
if [[ -z "$(lsmod | grep br_netfilter)" ]]; then
    echo "Adding br_netfilter"
    modprobe br_netfilter
    echo "br_netfilter" >/etc/modules-load.d/br_netfilter.conf
fi

# Install ufw
if ! command -v ufw &>/dev/null; then
    stage "Installing ufw"
    apt-get install -y ufw
fi

# Install snap (required for letsencrypt certbot install)
if ! command -v snap &>/dev/null; then
    stage "Installing snapd"
    apt-get install -y snapd
fi

# -------------------------------
# fstab changes
# We do not edit original file, instead we create a temp file with original and edit it.
# Replace temp file with original only if success.

# Root entry pattern: <Not starting with a comment><Not whitespace(Device)><Whitespace></><Whitespace><Not whitespace(FS type)><Whitespace><No whitespace(Options)><Whitespace><Number(Dump)><Whitespace><Number(Pass)>
# Options must contain usrquota. ext4 refuses to mount when usrquota is mixed with journaled quota options
# (usrjquota, grpjquota, jqfmt), so those and other quota options are removed from the options.
# Options are rewritten only if they differ from the expected ones.
stage "Configuring fstab"
root_entry="^[^#]\S+\s+\/\s+\S+\s+\S+\s+[0-9]+\s+[0-9]+\s*"
root_opts=$(sed -n -r -e "/$root_entry/{ s/^\S+\s+\/\s+\S+\s+(\S+).*/\1/p; q }" "$tmpfstab")
[ -z "$root_opts" ] && echo "Root (/) mount entry not found in fstab." && exit 1

IFS=',' read -r -a opts <<<"$root_opts"
new_opts=()
has_usrquota=0
for opt in "${opts[@]}"; do
    case "$opt" in
    usrquota)
        new_opts+=("$opt")
        has_usrquota=1
        ;;
    usrjquota=* | grpjquota=* | jqfmt=* | grpquota | quota | noquota) ;; # Cannot be mixed with usrquota.
    *) new_opts+=("$opt") ;;
    esac
done
[ $has_usrquota -eq 0 ] && new_opts+=("usrquota")
new_root_opts=$(IFS=','; echo "${new_opts[*]}")

if [ "$new_root_opts" != "$root_opts" ]; then
    echo "Updating root mount options from '$root_opts' to '$new_root_opts'."
    escaped_opts=$(printf '%s' "$new_root_opts" | sed -e 's/[\/&]/\\&/g')
    ! sed -i -r -e "/$root_entry/{ s/^(\S+\s+\/\s+\S+\s+)\S+/\1$escaped_opts/ }" "$tmpfstab" && echo "fstab update failed." && exit 1

    # Create a backup of original, if remount failed replace updated with backup.
    cp $originalfstab $backup
    mv "$tmpfstab" $originalfstab
    # Quota options cannot be changed while quota is on.
    quotaoff -ug / >/dev/null 2>&1
    if ! mount -o remount / 2>&1; then
        # Journaled quota options of the current mount persist across remounts, so they can only be cleared with a reboot.
        if findmnt -no OPTIONS / | grep -qE "usrjquota=|grpjquota=|jqfmt="; then
            echo "Updated fstab, but the root filesystem is currently mounted with journaled quota options."
            echo "Please reboot the machine and run the installation again." && exit 1
        fi
        mv $backup $originalfstab
        echo "Re mounting error."
        dmesg | grep "EXT4-fs" | tail -n 3
        exit 1
    fi
    echo "Updated fstab."
else
    echo "fstab already configured."
fi

# Check and turn on user quota if not enabled.
[ ! -f /aquota.user ] && quotacheck -cum /
if ! quotaon -pu / 2>/dev/null | grep -q "is on"; then
    ! quotaon -u / && echo "Enabling user quota failed." && exit 1
fi

# -------------------------------
stage "Configuring fuse"

# Check fuse config exists.
[ ! -f /etc/fuse.conf ] && echo "Fuse config does not exist, Make sure you've installed fuse." && exit 1

# Set user_allow_other if not already configured
# We create a temp of the config file and replace with original file only if success.
tmp=$(mktemp -d)
tmpconf=$tmp.tmp
cp /etc/fuse.conf "$tmpconf"

updated=0
# Check user_allow_other exists, create new if not exists.
# If exists do nothing otherwise set value.
sed -n -r -e "/^user_allow_other\s*\$/{q100}" "$tmpconf"
res=$?
if [ $res -eq 0 ]; then
    # Check user_allow_other commented, create new if not commented otherwise uncomment.
    # Add as new line if not exist.
    sed -n -r -e "/^#\s*user_allow_other\s*\$/{q100}" "$tmpconf"
    res=$?
    if [ $res -eq 100 ]; then
        sed -i -r -e "s/^#\s*user_allow_other\s*\$/user_allow_other/" "$tmpconf"
        res=$?
        updated=1
    elif [ $res -eq 0 ]; then
        echo "user_allow_other" >>"$tmpconf"
        res=$?
        updated=1
    fi
fi

# If the res is not success(0) or alredy exist(100).
[ ! $res -eq 0 ] && [ ! $res -eq 100 ] && echo "Fuse config update failed." && exit 1

# If updated we do replacing.
if [ $updated -eq 1 ]; then
    # Create a backup of original config.
    conf_backup=/etc/fuse.conf.sashi.bk
    cp /etc/fuse.conf $conf_backup
    mv "$tmpconf" /etc/fuse.conf
    rm -r "$tmp"
    echo "Updated fuse config."
else
    rm -r "$tmp"
    echo "Fuse config already updated."
fi

# -------------------------------
stage "Configuring cgroup rules engine"

# Copy cgred.conf from examples if not exists to setup control groups.
[ ! -f /etc/cgred.conf ] && cp /usr/share/doc/cgroup-tools/examples/cgred.conf /etc/

# Create new cgconfig.conf if not exists to setup control groups.
[ ! -f /etc/cgconfig.conf ] && : >/etc/cgconfig.conf

# Create new cgrules.conf if not exists to setup control groups.
[ ! -f /etc/cgrules.conf ] && : >/etc/cgrules.conf

# Setup a service if not exists to run cgroup rules generator.
cgrulesengd_file="/etc/systemd/system/$cgrulesengd_service.service"
if ! [ -f "$cgrulesengd_file" ]; then
    echo "[Unit]
    Description=cgroups rules generator
    After=network.target

    [Service]
    User=root
    Group=root
    Type=forking
    EnvironmentFile=-/etc/cgred.conf
    ExecStart=/usr/sbin/cgrulesengd
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target" >$cgrulesengd_file
    systemctl daemon-reload
fi
systemctl enable $cgrulesengd_service
systemctl start $cgrulesengd_service

# -------------------------------
stage "Configuring grub"

# Enable cgroup memory and swapaccount if not already configured
# We create a temp of the grub file and replace with original file only if success.
tmp=$(mktemp -d)
tmpgrub=$tmp.tmp
cp /etc/default/grub "$tmpgrub"

updated=0
# Check GRUB_CMDLINE_LINUX exists, create new if not exists.
# If exists check for cgroup_enable=memory and swapaccount=1 and configure them if not already configured.
sed -n -r -e "/^GRUB_CMDLINE_LINUX=/{q100}" "$tmpgrub"
res=$?
if [ $res -eq 100 ]; then
    # Check cgroup_enable=memory exists, create new if not exists otherwise skip.
    sed -n -r -e "/^GRUB_CMDLINE_LINUX=/{ /cgroup_enable=memory/{q100}; }" "$tmpgrub"
    res=$?
    if [ $res -eq 0 ]; then
        sed -i -r -e "/^GRUB_CMDLINE_LINUX=/{ s/\"\s*\$/ cgroup_enable=memory\"/ }" "$tmpgrub"
        res=$?
        updated=1
    fi

    # If there's no error.
    if [ $res -eq 0 ] || [ $res -eq 100 ]; then
        # Check swapaccount=1 exists, create new if not exists otherwise skip.
        sed -n -r -e "/^GRUB_CMDLINE_LINUX=/{ /swapaccount=1/{q100}; }" "$tmpgrub"
        res=$?
        if [ $res -eq 0 ]; then
            # Check whether there's swapaccount value other than 1, If so replace value with 1.
            # Otherwise add swapaccount=1 after cgroup_enable=memory.
            sed -n -r -e "/^GRUB_CMDLINE_LINUX=/{ /swapaccount=/{q100}; }" "$tmpgrub"
            res=$?
            if [ $res -eq 100 ]; then
                sed -i -r -e "/^GRUB_CMDLINE_LINUX=/{ s/swapaccount=[0-9]*/swapaccount=1/ }" "$tmpgrub"
                res=$?
                updated=1
            elif [ $res -eq 0 ]; then
                sed -i -r -e "/^GRUB_CMDLINE_LINUX=/{ s/cgroup_enable=memory/cgroup_enable=memory swapaccount=1/ }" "$tmpgrub"
                res=$?
                updated=1
            fi
        fi
    fi
elif [ $res -eq 0 ]; then
    echo "GRUB_CMDLINE_LINUX=\"cgroup_enable=memory swapaccount=1\"" >>"$tmpgrub"
    res=$?
    updated=1
fi

# If the res is not success(0) or alredy exist(100).
[ ! $res -eq 0 ] && [ ! $res -eq 100 ] && echo "Grub GRUB_CMDLINE_LINUX update failed." && exit 1

# If updated we do update-grub and reboot.
if [ $updated -eq 1 ]; then
    # Create a backup of original grub, So we can replace the backup with original if update-grub failed.
    grub_backup=/etc/default/grub.sashi.bk
    cp /etc/default/grub $grub_backup
    mv "$tmpgrub" /etc/default/grub
    rm -r "$tmp"
    if ! update-grub >/dev/null 2>&1; then
        mv $grub_backup /etc/default/grub
        echo "Grub update failed."
        exit 1
    fi

    # Indicate pending reboot in the standard reboot required file.
    touch /run/reboot-required
    rebootpkgs=/run/reboot-required.pkgs
    (! [ -f $rebootpkgs ] || [ -z "$(grep sashimono $rebootpkgs)" ]) && echo "sashimono" >>$rebootpkgs

    echo "Updated grub. System needs to be rebooted to apply grub changes."
else
    rm -r "$tmp"
    echo "Grub already configured."
fi

exit 0
