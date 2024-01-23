#!/bin/bash
# shellcheck disable=SC2317

source ../rsync-tmsched.sh
source ./utils.sh

_OUT=1 # Debug
# exec {_OUT}<>/dev/null # No Debug

# Initializations -------------------------------------------------------------
setup_suite() {
    # Use tmpfs (ram) for faster test
    TEST_ROOT="$(mktemp -p /tmp -d)"
}

teardown_suite() {
    :
}

setup() {
    mkdir -p "${TEST_ROOT}"
}

teardown() {
    rm -rf "${TEST_ROOT:?}"
}

# Tests -----------------------------------------------------------------------
test_read_config_file() {
    local cmd=''

    cat >|"$TEST_ROOT/config" <<<""
    rscd.read_config_file "$TEST_ROOT/config" cmd
    assert_equals 0 $?
    assert_equals "" "$cmd"

    # Test non-existing config file
    rm "$TEST_ROOT/config"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*Config '${TEST_ROOT}/config' not found.*" "$stderr"

    # Test regular variables
    cat >|"$TEST_ROOT/config" <<<"RSCD_LOG_DIR=/a/b/c/d"
    rscd.read_config_file "$TEST_ROOT/config" cmd
    assert_equals 0 $?
    eval "$cmd"
    assert_equals '/a/b/c/d' "$RSCD_LOG_DIR"

    # test regular variables conf_*
    cat >|"$TEST_ROOT/config" <<<"declare -A conf_b=([src]='a' [dst]='b')"
    rscd.read_config_file "$TEST_ROOT/config" cmd
    assert_equals 0 $?
    eval "$cmd"
    # shellcheck disable=SC2154
    assert_equals 'a' "${__rscd_conf_b[src]}"
} >&"$_OUT"

test_readinvalid_config_file() {
    # Test fail in sourcing config file
    cat >|"$TEST_ROOT/config" <<<"false"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*Failed parsing config file.*" "$stderr"

    # Test invalid conf_*
    cat >|"$TEST_ROOT/config" <<<"declare -a conf_b=(a)"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*'conf_b' must be a dict.*" "$stderr"

    cat >|"$TEST_ROOT/config" <<<"declare -A conf_b=([dst]='b')"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*'conf_b\\[src\\]' not defined.*" "$stderr"

    cat >|"$TEST_ROOT/config" <<<"declare -A conf_b=([src]='a')"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*'conf_b\\[dst\\]' not defined.*" "$stderr"

    cat >|"$TEST_ROOT/config" <<<"declare -A conf_b=([src]='a' [dst]='b' [sched]=a)"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*'conf_b\\[sched\\]': 'sched_a' not defined.*" "$stderr"

    # Test invalid excl_*
    cat >|"$TEST_ROOT/config" <<<"declare -A excl_b=()"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*'excl_b' must be an array.*" "$stderr"

    cat >|"$TEST_ROOT/config" <<<"declare -a excl_b=('a')"
    local stderr=''
    stderr="$(rscd.read_config_file "$TEST_ROOT/config" cmd 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*'excl_b': 'conf_b' not defined.*" "$stderr"
} >&"$_OUT"

test_gen_rbkp_args() {
    # Test rbkp argument generation
    cat >|"$TEST_ROOT/config" <<EOF
declare -A conf_a=([src]='a' [dst]='b')
declare -A conf_b=([src]='c' [dst]='d')
declare -a excl_b=(
    "- /home/user"
    "- /home/user/log"
)
declare -A conf_c=([src]='e' [dst]='f' ['--log-file']='/home/user/log')
EOF

    local config_file=''
    rscd.read_config_file "$TEST_ROOT/config" cfg_cmds
    eval "$cfg_cmds"

    # Src and dst
    : >|"$TEST_ROOT/excl"
    local -a args=()
    rscd.gen_rbkp_args \
        "__rscd_conf_a" "__rscd_excl_a" "$TEST_ROOT/excl" args
    assert_equals 0 $?
    assert_equals 2 "${#args[@]}"
    assert_equals 'a' "${args[0]}"
    assert_equals 'b' "${args[1]}"

    # exclude-file
    : >|"$TEST_ROOT/excl"
    local -a args=()
    rscd.gen_rbkp_args \
        "__rscd_conf_b" "__rscd_excl_b" "$TEST_ROOT/excl" args
    assert_equals 0 $?
    assert_equals 3 "${#args[@]}"
    assert_equals 'c' "${args[0]}"
    assert_equals 'd' "${args[1]}"

    assert "[[ -f '${args[2]}' ]]"
    assert_no_diff <(printf '%s\n' "- /home/user" "- /home/user/log") "${args[2]}"

    # rbkp options
    : >|"$TEST_ROOT/excl"
    local -a args=()
    rscd.gen_rbkp_args \
        "__rscd_conf_c" "__rscd_excl_c" "$TEST_ROOT/excl" args
    assert_equals 0 $?
    assert_equals 4 "${#args[@]}"
    assert_equals '--log-file' "${args[0]}"
    assert_equals '/home/user/log' "${args[1]}"
    assert_equals 'e' "${args[2]}"
    assert_equals 'f' "${args[3]}"
} >&"$_OUT"

test_schedule() {
    mkdir -p "$TEST_ROOT"/{a,b}
    touch "$TEST_ROOT"/b/backup.marker

    # Test sched_* functions in config file
    cat >|"$TEST_ROOT/config" <<EOF
sched_weekly(){ [[ \$(date +%u) == 1 ]]; }
declare -A conf_a=([src]='$TEST_ROOT/a' [dst]='$TEST_ROOT/b' [sched]='weekly')
EOF

    # Pretend that today is Monday
    _date() {
        [[ "${#FAKE_PARAMS[@]}" -eq 1 && "${FAKE_PARAMS[0]}" == +%u ]] || {
            command date "${FAKE_PARAMS[@]}"
            return
        }
        echo 1
    }
    fake date _date
    export -f _date
    set -x
    rscd.main -c "$TEST_ROOT/config"
    assert_equals 0 $?
    set +x
    # 3 files: backup.marker, latest and the backup folder
    # shellcheck disable=SC2012
    assert_equals 3 "$(ls -d "$TEST_ROOT/b"/* | wc -l)"
} >&"$_OUT"

test_schedule_skipped() {
    mkdir -p "$TEST_ROOT"/{a,b}
    touch "$TEST_ROOT"/b/backup.marker

    # Test sched_* functions in config file
    cat >|"$TEST_ROOT/config" <<EOF
sched_weekly(){ [[ \$(date +%u) == 1 ]]; }
declare -A conf_a=([src]='$TEST_ROOT/a' [dst]='$TEST_ROOT/b' [sched]='weekly')
EOF

    # Pretend that today is Tuesday
    _date() {
        [[ "${#FAKE_PARAMS[@]}" -eq 1 && "${FAKE_PARAMS[0]}" == +%u ]] || {
            command date "${FAKE_PARAMS[@]}"
            return
        }
        echo 2
    }
    fake date _date
    export -f _date
    local stdout=''
    stdout=$(rscd.main -c "$TEST_ROOT/config")
    assert_equals 0 $?
    # No backup will be performed
    assert_fail "$(ls -d "$TEST_ROOT/b"/*)"
    assert_matches '.*Not today.*' "$stdout"
} >&"$_OUT"

test_notification() {
    mkdir -p "$TEST_ROOT"/{a,b}
    touch "$TEST_ROOT"/b/backup.marker

    # Test sched_* functions in config file
    cat >|"$TEST_ROOT/config" <<EOF
notify() { echo ">>> NOTIFICATION-ABCDEFG <<<"; }
declare -A conf_a=([src]='$TEST_ROOT/a' [dst]='$TEST_ROOT/b')
EOF

    stdout="$(rscd.main -c "$TEST_ROOT/config")"
    assert_equals 0 $?
    # 3 files: backup.marker, latest and the backup folder
    # shellcheck disable=SC2012
    assert_equals 3 "$(ls -d "$TEST_ROOT/b"/* | wc -l)"
    assert_matches '.*>>> NOTIFICATION-ABCDEFG <<<.*' "$stdout"
} >&"$_OUT"

test_log_file() {
    mkdir -p "$TEST_ROOT"/{a,b}
    touch "$TEST_ROOT"/b/backup.marker

    # Test sched_* functions in config file
    cat >|"$TEST_ROOT/config" <<EOF
RSCD_LOG_DIR="$TEST_ROOT/log"
declare -A conf_a=([src]='$TEST_ROOT/a' [dst]='$TEST_ROOT/b')
EOF

    stdout="$(rscd.main -c "$TEST_ROOT/config")"
    assert_equals 0 $?
    # 3 files: backup.marker, latest and the backup folder
    # shellcheck disable=SC2012
    assert_equals 3 "$(ls -d "$TEST_ROOT/b"/* | wc -l)"
    assert "[[ -f '$TEST_ROOT/log/rsync-tmsched.log' ]]"
    assert "[[ -f '$TEST_ROOT/log/rsync-tmsched.err' ]]"
    # Output should be the same as log file
    assert_no_diff <(echo "$stdout") "$TEST_ROOT/log/rsync-tmsched.log"
} >&"$_OUT"
