#!/bin/bash
# Builds the HotPocket engine on this host from tagged public source.
# Run hourly by sashimono-engine-update.timer, once during install, and by `evernode engine`.
# Usage: hp-build.sh update | build <version> | status | gc
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose: the $ names are jq variables.

set -euo pipefail

script_dir=$(dirname "$(realpath "$0")")
for lib in common policy release fetch builder publish retain; do
    # shellcheck source=/dev/null
    source "$script_dir/lib/$lib.sh"
done

function record_build() {
    local version=$1 tag=$2 commit=$3 os=$4 build_id=$5
    state_update '.releases[$v].tag = $t | .releases[$v].commit = $c | .releases[$v].builds[$os] = $id' \
        --arg v "$version" --arg t "$tag" --arg c "$commit" --arg os "$os" --arg id "$build_id"
}

function record_failure() {
    state_update '.failures[$k] = {count: ((.failures[$k].count // 0) + 1), last: $now}' \
        --arg k "$1" --argjson now "$(date +%s)"
}

function clear_failure() {
    state_update 'del(.failures[$k])' --arg k "$1"
}

# Retries every run until three failures in a row, then at most every FAILURE_BACKOFF_SECONDS.
function retry_allowed() {
    local count last
    count=$(state_get ".failures[\"$1\"].count")
    last=$(state_get ".failures[\"$1\"].last")
    [ -z "$count" ] || ((count < 3)) || (($(date +%s) - last >= FAILURE_BACKOFF_SECONDS))
}

function release_complete() {
    local version=$1 os id
    for os in "${SUPPORTED_OS[@]}"; do
        id=$(state_get ".releases[\"$version\"].builds[\"$os\"]")
        [ -n "$id" ] && [ -d "$HP_BUILDS_DIR/$id" ] || return 1
    done
}

# Compiles, tests and publishes one OS build of a fetched release.
function build_one_os() {
    local version=$1 os=$2 build_id=$3 commit=$4 src_dir=$5 deps_dir=$6
    local recipe=$src_dir/hpcore/builder
    local out_dir=$ENGINE_WORK_DIR/out/$build_id
    local jobs builder_image smoke_image manifest
    jobs=$(jq -er '.builder.jobs // 1' "$ENGINE_CONFIG")

    log "Building $build_id"
    builder_image=$(ensure_image "$recipe" "$os" build) || return 1
    smoke_image=$(ensure_image "$recipe" "$os" runtime) || return 1
    run_compile "$builder_image" "$src_dir" "$deps_dir" "$out_dir" "$jobs" || return 1
    smoke_test "$smoke_image" "$out_dir" "$recipe/engine.json" || return 1

    # set -e is off inside functions called from if or &&, so every step checks its own result.
    manifest=$(mktemp)
    if ! write_build_manifest "$build_id" "$version" "$os" "$commit" "$src_dir" "$out_dir" "$manifest" ||
        ! publish_build "$build_id" "$out_dir" "$manifest"; then
        rm -f "$manifest"
        return 1
    fi
    rm -f "$manifest"
    as_builder rm -rf "$out_dir"

    # The host-OS build's hpfs runs on this machine, so check it here too.
    if [ "$os" == "$(jq -er '.host_os' "$ENGINE_CONFIG")" ]; then
        "$HP_BUILDS_DIR/$build_id/hpfs" version >/dev/null || return 1
    fi
    log "Published $build_id"
}

# Builds one release for every supported OS. Returns 0 when nothing was left to do or everything built.
function build_release() {
    local tag=$1
    local version=$tag repo commit os id pending=()
    repo=$(repo_of hpcore)
    commit=$(resolve_tag_commit "$repo" "$tag") || true
    [ -n "$commit" ] || { log_error "Could not resolve tag $tag."; return 1; }
    check_tag_not_moved "$tag" "$commit" || return 1

    for os in "${SUPPORTED_OS[@]}"; do
        id=$(make_build_id "$version" "$os" "$commit")
        if [ -d "$HP_BUILDS_DIR/$id" ]; then
            record_build "$version" "$tag" "$commit" "$os" "$id" || return 1
        elif retry_allowed "$version/$os"; then
            pending+=("$os")
        fi
    done
    [ ${#pending[@]} -gt 0 ] || return 0

    local src_dir=$ENGINE_WORK_DIR/src/$commit
    local deps_dir=$ENGINE_WORK_DIR/deps/$commit
    fetch_release_sources "$commit" "$src_dir" || return 1
    if ! meets_min_sashimono "$src_dir/hpcore/builder/engine.json"; then
        log "Release $version needs a newer Sashimono. Skipping it."
        return 1
    fi
    fetch_deps "$src_dir/hpcore/builder/deps.lock" "$deps_dir" || return 1

    local failed=0
    for os in "${pending[@]}"; do
        id=$(make_build_id "$version" "$os" "$commit")
        if build_one_os "$version" "$os" "$id" "$commit" "$src_dir" "$deps_dir"; then
            record_build "$version" "$tag" "$commit" "$os" "$id" || return 1
            clear_failure "$version/$os"
        else
            log_error "Build $id failed."
            record_failure "$version/$os"
            failed=1
        fi
    done
    return $failed
}

function refresh_outputs() {
    local policy=$1 reputation_version=$2 os id
    recompute_latest_previous "$policy"
    local latest
    latest=$(state_get '.latest')
    if [ -n "$latest" ]; then
        for os in "${SUPPORTED_OS[@]}"; do
            id=$(state_get ".releases[\"$latest\"].builds[\"$os\"]")
            point_latest "$os" "$id"
        done
    fi
    # Retire first, then publish readiness, so ready.json never offers a build that is on its way out.
    collect_garbage "$reputation_version"
    write_ready_file "$policy"
    update_shared_hpfs_link
}

function cmd_update() {
    acquire_run_lock
    init_state
    local policy reputation_version tag
    policy=$(load_network_policy)
    reputation_version=$(policy_reputation_version "$policy")

    # Newest eligible release first. If it can't be built, the next one down keeps the host ready.
    while read -r tag; do
        [ -n "$tag" ] || continue
        policy_is_revoked "$policy" "$tag" && continue
        if build_release "$tag" && release_complete "$tag"; then
            break
        fi
    done < <(list_release_tags "$policy" || true)

    # Every host serves the network's reputation version, whatever its latest is.
    if [ -n "$reputation_version" ] && ! policy_is_revoked "$policy" "$reputation_version"; then
        build_release "$reputation_version" || log_error "Reputation engine $reputation_version is not built yet."
    fi

    refresh_outputs "$policy" "$reputation_version"
    log "Ready: $(jq -c '{ready, advertised}' "$ENGINE_READY_FILE")"
}

function cmd_build() {
    local version=$1
    [[ "$version" =~ $RELEASE_TAG_PATTERN ]] || die "Not a release version: $version"
    acquire_run_lock
    init_state
    local policy
    policy=$(load_network_policy)
    policy_is_revoked "$policy" "$version" && die "Release $version is revoked on this network."
    build_release "$version" || log_error "Release $version did not build completely."
    refresh_outputs "$policy" "$(policy_reputation_version "$policy")"
}

function cmd_status() {
    [ -f "$ENGINE_READY_FILE" ] || die "No engine state yet. Run: hp-build.sh update"
    jq '{ready, host_os, advertised, versions, legacy_images_allowed, updated_at}' "$ENGINE_READY_FILE"
    jq '{latest, previous, failures, retired}' "$ENGINE_STATE_FILE"
}

function cmd_gc() {
    acquire_run_lock
    init_state
    local policy
    policy=$(jq -c '.policy // {}' "$ENGINE_STATE_FILE")
    collect_garbage "$(policy_reputation_version "$policy")"
    write_ready_file "$policy"
}

[ "$(id -u)" -eq 0 ] || die "Run as root."
case "${1:-}" in
update) cmd_update ;;
build) cmd_build "${2:?Usage: hp-build.sh build <version>}" ;;
status) cmd_status ;;
gc) cmd_gc ;;
*) die "Usage: hp-build.sh update | build <version> | status | gc" ;;
esac
