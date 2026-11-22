#!/bin/bash
# Reads the host engine config and the network engine policy. Sourced by hp-build.sh.
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose: the $ names are jq variables.

# Prints this network's engine block from definitions.json, saving a copy in the state file.
# Falls back to the saved copy when the download fails.
function load_network_policy() {
    local url network policy
    url=$(jq -er '.definitions_url' "$ENGINE_CONFIG")
    network=$(jq -er '.network' "$ENGINE_CONFIG")
    if policy=$(curl -fsSL --max-time 30 "$url" | jq -ce --arg n "$network" '.[$n].engine // {}'); then
        state_update '.policy = $p' --argjson p "$policy"
    else
        log_error "Could not download the network policy. Using the saved copy."
        policy=$(jq -c '.policy // {}' "$ENGINE_STATE_FILE")
    fi
    echo "$policy"
}

function policy_is_revoked() {
    local policy=$1 version=$2
    jq -e --arg v "$version" '(.revoked // []) | index($v) != null' <<<"$policy" >/dev/null
}

# Pre-releases need both the host's opt-in and the network's permission.
function policy_allows_prerelease() {
    local policy=$1
    [ "$(jq -r '.allow_prerelease' "$ENGINE_CONFIG")" == "true" ] &&
        jq -e '.allowPrerelease == true' <<<"$policy" >/dev/null
}

function policy_reputation_version() {
    jq -r '.reputationVersion // empty' <<<"$1"
}
