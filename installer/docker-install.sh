#!/bin/bash
# Rootless docker installation script.

docker_bin=$(realpath $1)

# Silently exit if docker_bin is not empty.
if [ -z "$(ls -A $docker_bin 2>/dev/null)" ]; then

    mkdir -p $docker_bin

    # Download docker packages into a tmp dir and extract into docker bin.
    echo "Installing rootless docker packages into $docker_bin"

    tmp=$(mktemp -d)
    cd $tmp
    curl -s https://download.docker.com/linux/static/stable/x86_64/docker-24.0.5.tgz --output docker.tgz
    curl -s https://download.docker.com/linux/static/stable/x86_64/docker-rootless-extras-24.0.5.tgz --output rootless.tgz

    cd $docker_bin
    tar zxf $tmp/docker.tgz --strip-components=1
    tar zxf $tmp/rootless.tgz --strip-components=1
    rm -r $tmp

    # Override rootlesskit with our own version based on original rootlesskit v1.1.1
    # We need this custom version to have outbound ipv6 address support (https://github.com/EvernodeXRPL/rootlesskit/tree/outbound-addr-support)
    curl -fsSL https://github.com/EvernodeXRPL/rootlesskit/releases/download/v1.1.1-evernode-patch1/rootlesskit --output $docker_bin/rootlesskit
    chmod +x $docker_bin/rootlesskit

    chown -R $(id -u):$(id -g) $docker_bin/*

fi

# Clear the image cache, so an upgrade also drops cache files in older layouts. Instances pull an image again when it isn't cached.
[ -d "$docker_bin" ] && rm -rf "$docker_bin/images" "$docker_bin/download-frozen-image-v2.sh"

exit 0
