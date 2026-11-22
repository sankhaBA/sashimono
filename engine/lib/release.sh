#!/bin/bash
# Finds engine releases on GitHub and pins tags to commits. Sourced by hp-build.sh.
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose: the $ names are jq variables.

readonly GITHUB_API=https://api.github.com
readonly RELEASE_TAG_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'

function repo_of() {
    jq -er --arg c "$1" '.repos[$c]' "$ENGINE_CONFIG"
}

# Prints candidate release tags, newest first. Drafts are never included, pre-releases only when allowed.
function list_release_tags() {
    local policy=$1 include_pre=false
    policy_allows_prerelease "$policy" && include_pre=true
    curl -fsSL --max-time 30 "$GITHUB_API/repos/$(repo_of hpcore)/releases?per_page=30" |
        jq -r --argjson pre "$include_pre" '.[] | select((.draft | not) and ($pre or (.prerelease | not))) | .tag_name' |
        grep -E "$RELEASE_TAG_PATTERN" | sort -rV
}

# Prints the commit a tag points to. Annotated tags are peeled to their commit.
function resolve_tag_commit() {
    local repo=$1 tag=$2 refs
    refs=$(git ls-remote --tags "https://github.com/$repo.git" "refs/tags/$tag" "refs/tags/$tag^{}") || return 1
    # The peeled line (^{}) exists only for annotated tags and holds the commit, so it wins.
    { grep -F "refs/tags/$tag^{}" <<<"$refs" || grep -F "refs/tags/$tag" <<<"$refs"; } | head -n 1 | cut -f 1
}

# Remembers the first commit seen for each tag and refuses the tag if it ever moves.
function check_tag_not_moved() {
    local tag=$1 commit=$2 known
    known=$(state_get ".tags[\"$tag\"]")
    if [ -n "$known" ] && [ "$known" != "$commit" ]; then
        log_error "Tag $tag moved from $known to $commit. Refusing to build it."
        return 1
    fi
    [ -n "$known" ] || state_update '.tags[$t] = $c' --arg t "$tag" --arg c "$commit"
}

# A release can say it needs a newer Sashimono (design §4).
function meets_min_sashimono() {
    local engine_json=$1 required current
    required=$(jq -r '.min_sashimono // "0.0.0"' "$engine_json")
    current=$("$SASHIMONO_BIN/sagent" version)
    [ "$(version_cmp "$current" "$required")" != "-1" ]
}
