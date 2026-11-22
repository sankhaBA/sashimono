#!/bin/bash
# Downloads engine sources and pinned dependencies as the builder user, and verifies them. Sourced by hp-build.sh.
# shellcheck disable=SC2016  # The sh -c script is single-quoted on purpose: $1 and $2 are its own arguments.

function builder_checksum_ok() {
    local sha256=$1 file=$2
    as_builder sh -c 'echo "$1  $2" | sha256sum -c --status -' _ "$sha256" "$file" 2>/dev/null
}

# Fetches exactly one commit of a repo into a fresh folder and checks the result.
function fetch_source() {
    local repo=$1 commit=$2 dest=$3
    if [ -d "$dest/.git" ] && [ "$(as_builder git -C "$dest" rev-parse HEAD 2>/dev/null)" == "$commit" ]; then
        return 0
    fi
    as_builder rm -rf "$dest"
    as_builder git init -q "$dest"
    as_builder git -C "$dest" fetch -q --depth 1 "https://github.com/$repo.git" "$commit" || return 1
    as_builder git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD || return 1
    [ "$(as_builder git -C "$dest" rev-parse HEAD)" == "$commit" ] ||
        { log_error "$repo: fetched commit does not match $commit."; return 1; }
}

# Fetches hpcore at the release commit, then the hpfs and hpws commits its manifest names.
function fetch_release_sources() {
    local commit=$1 src_dir=$2 manifest
    fetch_source "$(repo_of hpcore)" "$commit" "$src_dir/hpcore" || return 1
    manifest=$src_dir/hpcore/builder/engine.json
    fetch_source "$(repo_of hpfs)" "$(jq -er '.components.hpfs.commit' "$manifest")" "$src_dir/hpfs" || return 1
    fetch_source "$(repo_of hpws)" "$(jq -er '.components.hpws.commit' "$manifest")" "$src_dir/hpws"
}

# Places every deps.lock entry in dest as <name>.tar.gz, downloading only what the cache lacks.
function fetch_deps() {
    local lock_file=$1 dest=$2
    local cache=$ENGINE_WORK_DIR/deps-cache
    local name version sha256 url cached
    as_builder mkdir -p "$cache" "$dest"
    while read -r name version sha256 url; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        cached=$cache/$sha256.tar.gz
        if ! builder_checksum_ok "$sha256" "$cached"; then
            log "Downloading $name $version"
            as_builder curl -fsSL --max-time 300 -o "$cached.part" "$url" || return 1
            if ! builder_checksum_ok "$sha256" "$cached.part"; then
                log_error "$name $version: checksum does not match deps.lock."
                as_builder rm -f "$cached.part"
                return 1
            fi
            as_builder mv -f "$cached.part" "$cached"
        fi
        as_builder cp "$cached" "$dest/$name.tar.gz"
    done <"$lock_file"
}
