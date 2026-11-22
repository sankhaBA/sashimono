#!/bin/bash
# Shared paths and helpers for the HotPocket engine build scripts. Sourced by hp-build.sh, never run directly.
# shellcheck disable=SC2034  # The constants are used by the other engine libs.

readonly SASHIMONO_BIN=/usr/bin/sashimono
readonly SASHI_CLI=/usr/bin/sashi
readonly DOCKER_BIN=$SASHIMONO_BIN/dockerbin
readonly ENGINE_CONFIG=/etc/sashimono/engine.cfg
readonly HP_BUILDS_DIR=/var/lib/sashimono/hp-builds
readonly ENGINE_DATA_DIR=/var/lib/sashimono/engine
readonly ENGINE_WORK_DIR=$ENGINE_DATA_DIR/work
readonly ENGINE_STATE_FILE=$ENGINE_DATA_DIR/state.json
readonly ENGINE_READY_FILE=$ENGINE_DATA_DIR/ready.json
readonly ENGINE_LOCK_FILE=$ENGINE_DATA_DIR/hp-build.lock
readonly LEGACY_HPFS=$ENGINE_DATA_DIR/legacy/hpfs
readonly SHARED_HPFS_LINK=$SASHIMONO_BIN/hpfs
readonly BUILDER_USER=sashibuilder
readonly SUPPORTED_OS=(ubt20 ubt24)

# Bump when a change in these scripts changes what goes into a build, so every host rebuilds.
readonly BUILD_SCHEMA=1
# After three failures in a row, the same release and OS is retried at most this often.
readonly FAILURE_BACKOFF_SECONDS=21600
# A build that leaves the keep set is deleted only after this long, so no lease in flight can lose it.
readonly RETIRE_GRACE_SECONDS=${HP_BUILD_RETIRE_GRACE_SECONDS:-3600}

# jq helpers shared by the state and ready files. A version is complete when every supported OS has a build.
# shellcheck disable=SC2016  # A jq program: the $ names are jq variables.
readonly JQ_DEFS='
def complete_versions($os; $revoked):
    [.releases | to_entries[]
     | select(.key as $v | ($revoked | index($v)) | not)
     | select([.value.builds[$os[]]] | all(. != null))
     | .key]
    | sort_by(split(".") | map(tonumber)) | reverse;
'

function log() {
    echo "[hp-build] $*" >&2
}

function log_error() {
    echo "[hp-build] ERROR: $*" >&2
}

function die() {
    log_error "$*"
    exit 1
}

function now_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

function supported_os_json() {
    printf '%s\n' "${SUPPORTED_OS[@]}" | jq -R . | jq -sc .
}

# Takes the single run lock, or exits quietly when another run holds it.
function acquire_run_lock() {
    exec 9>"$ENGINE_LOCK_FILE"
    if ! flock -n 9; then
        log "Another engine run is in progress. Skipping this one."
        exit 0
    fi
}

# Writes stdin to a JSON file atomically: a temp file in the same folder, then a rename.
function write_json_atomic() {
    local target=$1
    local tmp
    tmp=$(mktemp "$target.XXXXXX")
    if ! jq . >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

function init_state() {
    [ -f "$ENGINE_STATE_FILE" ] && return 0
    jq -n --arg os "$(jq -er '.host_os' "$ENGINE_CONFIG")" \
        '{schema: 1, host_os: $os, releases: {}, tags: {}, failures: {}, retired: {}, policy: {}, latest: null, previous: null}' |
        write_json_atomic "$ENGINE_STATE_FILE"
}

# Reads one value from the state file. Prints nothing for null.
function state_get() {
    jq -r "$1 // empty" "$ENGINE_STATE_FILE"
}

# Applies a jq program to the state file atomically. Extra arguments go to jq, for example --arg v 0.6.6.
function state_update() {
    local program=$1
    shift
    jq "$@" "$program" "$ENGINE_STATE_FILE" | write_json_atomic "$ENGINE_STATE_FILE"
}

# Compares two x.y.z versions. Prints -1, 0 or 1.
function version_cmp() {
    if [ "$1" == "$2" ]; then
        echo 0
    elif [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" == "$1" ]; then
        echo -1
    else
        echo 1
    fi
}

# Runs a command as the builder user, against that user's rootless Docker daemon.
function as_builder() {
    local uid
    uid=$(id -u "$BUILDER_USER")
    sudo -H -u "$BUILDER_USER" env \
        PATH="$DOCKER_BIN:/usr/local/bin:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DOCKER_HOST="unix:///run/user/$uid/docker.sock" \
        "$@"
}
