#!/bin/bash
# Keep rule, cleanup, readiness file and the shared hpfs link. Sourced by hp-build.sh.
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose: the $ names are jq variables.

# latest = newest complete, non-revoked release; previous = the next one down.
function recompute_latest_previous() {
    local policy=$1
    state_update "$JQ_DEFS"'
        complete_versions($os; ($policy.revoked // [])) as $v
        | .latest = ($v[0] // null) | .previous = ($v[1] // null)' \
        --argjson policy "$policy" --argjson os "$(supported_os_json)"
}

# Writes ready.json, the only engine file sagent, mb-xrpl and reputationd read.
function write_ready_file() {
    local policy=$1 host_os
    host_os=$(jq -er '.host_os' "$ENGINE_CONFIG")
    jq "$JQ_DEFS"'
        complete_versions($os; ($policy.revoked // [])) as $complete
        | (.retired // {}) as $retired
        # A version with a retired build is no longer offered, so no new lease can pick it during the grace period.
        | (.releases
           | with_entries(select((.key as $k | $complete | index($k)) and ([.value.builds[] | $retired[.]] | all(. == null))))
           | map_values(.builds)) as $versions
        | {
            schema: 1,
            updated_at: $now,
            host_os: $host_os,
            ready: (.latest != null and $versions[.latest] != null),
            advertised: ([.latest, .previous] | map(select(. != null and $versions[.] != null))),
            versions: $versions,
            legacy_images_allowed: (($policy.legacyImageCutoff // null) == null or $now < $policy.legacyImageCutoff)
          }' \
        --argjson policy "$policy" --argjson os "$(supported_os_json)" \
        --arg now "$(now_utc)" --arg host_os "$host_os" \
        "$ENGINE_STATE_FILE" | write_json_atomic "$ENGINE_READY_FILE"
}

# Build IDs that running instances use, one per line. Fails unless the agent returned a valid list,
# because an unreadable answer must never look like "no instances".
function in_use_build_ids() {
    local response
    response=$("$SASHI_CLI" json -m '{"type":"list"}') || return 1
    jq -e '.content | type == "array"' <<<"$response" >/dev/null || return 1
    jq -r '.content[] | (.build_id, .hpfs_build_id) | select(. != null and . != "")' <<<"$response"
}

function keep_build_ids() {
    local reputation_version=$1 in_use
    in_use=$(in_use_build_ids) || return 1
    {
        echo "$in_use"
        jq -r --arg rep "$reputation_version" \
            '[.latest, .previous, $rep] as $keep
             | .releases | to_entries[] | select(.key as $v | $keep | index($v)) | .value.builds[]' "$ENGINE_STATE_FILE"
    } | { grep -v '^$' || true; } | sort -u
}

function collect_garbage() {
    local reputation_version=$1 keep now dir id retired
    if ! keep=$(keep_build_ids "$reputation_version"); then
        log_error "Could not list instances. Skipping cleanup."
        return 0
    fi
    now=$(date +%s)
    for dir in "$HP_BUILDS_DIR"/hp-*; do
        [ -d "$dir" ] || continue
        id=$(basename "$dir")
        if grep -qxF "$id" <<<"$keep"; then
            state_update 'del(.retired[$id])' --arg id "$id"
            continue
        fi
        retired=$(state_get ".retired[\"$id\"]")
        if [ -z "$retired" ]; then
            state_update '.retired[$id] = $t' --arg id "$id" --argjson t "$now"
        elif ((now - retired >= RETIRE_GRACE_SECONDS)); then
            log "Deleting unused build $id"
            chmod -R u+w "$dir" && rm -rf "$dir"
            state_update 'del(.retired[$id]) | .releases |= map_values(.builds |= with_entries(select(.value != $id)))' --arg id "$id"
        fi
    done
}

# /usr/bin/sashimono/hpfs serves instances created before host builds (their units name that path).
# It points at the hpfs those hosts already had, or at the latest host-OS build on hosts that never had one.
function update_shared_hpfs_link() {
    local host_os target
    host_os=$(jq -er '.host_os' "$ENGINE_CONFIG")
    if [ -x "$LEGACY_HPFS" ]; then
        target=$LEGACY_HPFS
    elif [ -x "$HP_BUILDS_DIR/latest-$host_os/hpfs" ]; then
        target=$HP_BUILDS_DIR/latest-$host_os/hpfs
    else
        return 0
    fi
    ln -sfn "$target" "$SHARED_HPFS_LINK.tmp"
    mv -T "$SHARED_HPFS_LINK.tmp" "$SHARED_HPFS_LINK"
}
