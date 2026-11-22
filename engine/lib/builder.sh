#!/bin/bash
# Builds the builder and smoke images, and runs the offline compile. Sourced by hp-build.sh.

# Short hash of everything that defines one image: its Dockerfile, its package list and the OS pins.
function recipe_hash() {
    local recipe_dir=$1 os=$2 dockerfile=$3 packages=$4
    {
        cat "$recipe_dir/$dockerfile" "$recipe_dir/packages/$packages"
        jq -cS --arg os "$os" '.platforms[$os]' "$recipe_dir/engine.json"
    } | sha256sum | cut -c 1-12
}

# Builds an image from the recipe unless the host already has it, and prints its tag.
# kind is "build" (compiler image) or "runtime" (clean smoke-test image).
# Network is allowed here, to pull the pinned base image and install from the dated snapshot.
function ensure_image() {
    local recipe_dir=$1 os=$2 kind=$3
    local dockerfile=Dockerfile name=hp-builder
    local packages="$kind-$os.txt"
    if [ "$kind" == "runtime" ]; then
        dockerfile=Dockerfile.smoke
        name=hp-smoke
    fi
    local tag
    tag="$name:$os-$(recipe_hash "$recipe_dir" "$os" "$dockerfile" "$packages")"
    if ! as_builder docker image inspect "$tag" >/dev/null 2>&1; then
        log "Building image $tag"
        as_builder docker build --quiet -t "$tag" -f "$recipe_dir/$dockerfile" \
            --build-arg BASE_IMAGE="$(jq -er --arg os "$os" '.platforms[$os].base_image' "$recipe_dir/engine.json")" \
            --build-arg UBUNTU_CODENAME="$(jq -er --arg os "$os" '.platforms[$os].codename' "$recipe_dir/engine.json")" \
            --build-arg APT_SNAPSHOT="$(jq -er --arg os "$os" '.platforms[$os].apt_snapshot' "$recipe_dir/engine.json")" \
            --build-arg PACKAGES_FILE="packages/$packages" \
            "$recipe_dir" >/dev/null || return 1
    fi
    echo "$tag"
}

# Compiles one OS build with no network. Inputs are mounted read-only. Only the output folder is writable.
function run_compile() {
    local image=$1 src_dir=$2 deps_dir=$3 out_dir=$4 jobs=$5
    as_builder rm -rf "$out_dir"
    as_builder mkdir -p "$out_dir"
    as_builder docker run --rm --network=none \
        --mount "type=bind,source=$src_dir/hpcore,target=/src/hpcore,readonly" \
        --mount "type=bind,source=$src_dir/hpfs,target=/src/hpfs,readonly" \
        --mount "type=bind,source=$src_dir/hpws,target=/src/hpws,readonly" \
        --mount "type=bind,source=$deps_dir,target=/deps,readonly" \
        --mount "type=bind,source=$out_dir,target=/out" \
        --env BUILD_JOBS="$jobs" \
        "$image" bash /src/hpcore/builder/build-engine.sh
}
