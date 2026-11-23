#!/bin/bash
# Installs the toolchain and libraries required to build Sashimono on Ubuntu 20.04. Must run as root.

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
NODE_MAJOR=20
NCC_VERSION=0.45.0
WASIENV_VERSION=0.5.4
WASI_SDK_VERSION=8
HOOK_CLEANER_COMMIT=b856a3614c00361f108d07379f5892e7347bb994

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"

function fetch() {
    local url=$1
    local sha256=$2
    local file
    file=$(basename "$url")

    curl -fsSL "$url" -o "$file"
    echo "$sha256  $file" | sha256sum -c -
    tar -xzf "$file"
}

apt-get update
apt-get install -y --no-install-recommends \
    binaryen \
    build-essential \
    ca-certificates \
    curl \
    git \
    gnupg \
    jq \
    libboost-stacktrace-dev \
    libsodium-dev \
    libsqlite3-dev \
    libssl-dev \
    python3-pip

fetch https://github.com/Kitware/CMake/releases/download/v3.16.0-rc3/cmake-3.16.0-rc3-Linux-x86_64.tar.gz \
    b59df384fc377962ccd05aa8cc1b99b130de8d7b6a58e3e39e58ad0fd9b1e2fc
cp -r cmake-3.16.0-rc3-Linux-x86_64/bin/* /usr/local/bin/
cp -r cmake-3.16.0-rc3-Linux-x86_64/share/* /usr/local/share/

fetch https://github.com/danielaparker/jsoncons/archive/v0.153.3.tar.gz \
    f1cb2baf8e76aa22eb5ae513cbb63b0583a23444f6c89a8a1ee818ded79acb90
cp -r jsoncons-0.153.3/include/jsoncons /usr/local/include/
mkdir -p /usr/local/include/jsoncons_ext/
cp -r jsoncons-0.153.3/include/jsoncons_ext/bson /usr/local/include/jsoncons_ext/

fetch https://github.com/SergiusTheBest/plog/archive/1.1.5.tar.gz \
    6c80b4701183d2415bec927e1f5ca9b1761b3b5c65d3e09fb29c743e016d5609
cp -r plog-1.1.5/include/plog /usr/local/include/

fetch https://github.com/cameron314/readerwriterqueue/archive/v1.0.3.tar.gz \
    1937b6e5e386de879865c33c7e46219b9d26bc8ff19737d480bc376a947654e4
cmake -S readerwriterqueue-1.0.3 -B readerwriterqueue-1.0.3/build
make -C readerwriterqueue-1.0.3/build install

fetch https://github.com/cameron314/concurrentqueue/archive/1.0.2.tar.gz \
    c3aeb97c97169f743a53ca33812ea2ab61dd06dfd28319ca3f0a0771372fc7fc
cp concurrentqueue-1.0.2/concurrentqueue.h /usr/local/include/

fetch https://github.com/CLIUtils/CLI11/archive/refs/tags/v2.0.0.tar.gz \
    2c672f17bf56e8e6223a3bfb74055a946fa7b1ff376510371902adb9cb0ab6a3
cmake -S CLI11-2.0.0 -B CLI11-2.0.0/build
make -C CLI11-2.0.0/build install/fast

fetch "https://github.com/XRPLF/hook-cleaner-c/archive/$HOOK_CLEANER_COMMIT.tar.gz" \
    01ab0d2a421fa48f4f266d5b9545bd67ffb20fda80699e1a0f50ebd4846f947b
make -C "hook-cleaner-c-$HOOK_CLEANER_COMMIT" install

pip3 install --no-cache-dir "wasienv==$WASIENV_VERSION"
wasienv install-sdk "$WASI_SDK_VERSION"
wasienv default-sdk "$WASI_SDK_VERSION"

mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" >/etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y --no-install-recommends nodejs
npm install -g "@vercel/ncc@$NCC_VERSION"

ldconfig
