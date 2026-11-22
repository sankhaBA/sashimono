#!/bin/bash
# Verifies build outputs and publishes them as read-only build folders. Sourced by hp-build.sh.
# shellcheck disable=SC2016  # The smoke test script and jq programs are single-quoted on purpose: they run in the container and in jq.

# Build ID: hp-<version>-<os>-<8 hex>. The hash covers the hpcore commit (which fixes engine.json,
# deps.lock and the recipe), the target OS and the host script schema.
function make_build_id() {
    local version=$1 os=$2 commit=$3
    local digest
    digest=$(printf 'schema=%s\nos=%s\nhpcore=%s\n' "$BUILD_SCHEMA" "$os" "$commit" | sha256sum | cut -c 1-8)
    echo "hp-$version-$os-$digest"
}

# Runs the outputs in a clean runtime container. Checks libraries, static BLAKE3 and versions.
function smoke_test() {
    local smoke_image=$1 out_dir=$2 engine_json=$3
    local expected actual
    expected=$(jq -r '[.version, .components.hpfs.version, .components.hpws.version] | join(" ")' "$engine_json")
    actual=$(as_builder docker run --rm --network=none \
        --mount "type=bind,source=$out_dir,target=/usr/local/bin/hotpocket,readonly" \
        --entrypoint /bin/bash "$smoke_image" -c '
            set -e
            cd /usr/local/bin/hotpocket
            for bin in hpcore hpfs hpws; do
                if ldd "$bin" | grep -q "not found"; then echo "missing library in $bin" >&2; exit 1; fi
            done
            if ldd hpcore | grep -q blake3; then echo "BLAKE3 is not static" >&2; exit 1; fi
            echo "$(./hpcore version | head -n 1 | sed "s/ *$//") $(./hpfs version) $(./hpws -v)"') || return 1
    [ "$actual" == "$expected" ] || { log_error "Smoke test versions '$actual', expected '$expected'."; return 1; }
}

# Writes the build's manifest.json: every input and the hash of every output.
function write_build_manifest() {
    local build_id=$1 version=$2 os=$3 commit=$4 src_dir=$5 out_dir=$6 target=$7
    local manifest=$src_dir/hpcore/builder/engine.json
    jq -n \
        --arg id "$build_id" --arg version "$version" --arg os "$os" --arg commit "$commit" \
        --arg built_at "$(now_utc)" --argjson schema "$BUILD_SCHEMA" \
        --argjson engine "$(jq -c . "$manifest")" \
        --arg deps_sha256 "$(sha256sum <"$src_dir/hpcore/builder/deps.lock" | cut -c 1-64)" \
        --arg hpcore "$(sha256sum <"$out_dir/hpcore" | cut -c 1-64)" \
        --arg hpfs "$(sha256sum <"$out_dir/hpfs" | cut -c 1-64)" \
        --arg hpws "$(sha256sum <"$out_dir/hpws" | cut -c 1-64)" \
        --rawfile toolchain "$out_dir/build-info.txt" \
        '{build_id: $id, version: $version, os: $os, built_at: $built_at, build_schema: $schema,
          inputs: {hpcore_commit: $commit, components: $engine.components, platform: $engine.platforms[$os], deps_lock_sha256: $deps_sha256},
          outputs: {hpcore: $hpcore, hpfs: $hpfs, hpws: $hpws},
          toolchain: ($toolchain | split("\n") | map(select(length > 0)))}' >"$target"
}

# Copies verified outputs into a new root-owned, read-only folder, then renames it into place.
function publish_build() {
    local build_id=$1 out_dir=$2 manifest_file=$3
    local final=$HP_BUILDS_DIR/$build_id
    local incoming=$HP_BUILDS_DIR/.incoming-$build_id
    [ -d "$final" ] && return 0
    rm -rf "$incoming"
    mkdir -m 0755 "$incoming"
    install -m 0555 -o root -g root "$out_dir/hpcore" "$out_dir/hpfs" "$out_dir/hpws" "$incoming/"
    install -m 0444 -o root -g root "$manifest_file" "$incoming/manifest.json"
    chmod 0555 "$incoming"
    mv -T "$incoming" "$final"
}

# Points latest-<os> at a build. The link is replaced by a rename, so it never goes missing.
function point_latest() {
    local os=$1 build_id=$2
    ln -sfn "$build_id" "$HP_BUILDS_DIR/.latest-$os.tmp"
    mv -T "$HP_BUILDS_DIR/.latest-$os.tmp" "$HP_BUILDS_DIR/latest-$os"
}
