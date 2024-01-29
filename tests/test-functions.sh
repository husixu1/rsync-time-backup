#!/bin/bash
# shellcheck disable=SC2317

source ../rsync-tmbackup.sh
source ./utils.sh

# _OUT=1 # Debug
exec {_OUT}<>/dev/null # No Debug

# Initializations -------------------------------------------------------------
setup_suite() {
    # Use tmpfs (ram) for faster test
    TEST_ROOT="$(mktemp -p /tmp -d)"
    SRC_ROOT="$TEST_ROOT/SRC"
    DST_ROOT="$TEST_ROOT/DST"

    SSH_USER="$(whoami)"
    SSH_HOST=localhost
}

teardown_suite() {
    :
}

setup() {
    mkdir -p -- "$SRC_ROOT" "$DST_ROOT"
    touch "$DST_ROOT/backup.marker"
}

teardown() {
    rm -rf "${TEST_ROOT:?}"
}

# Tests -----------------------------------------------------------------------
test_parse_date() {
    local res=''

    rbkp.parse_date "1970-01-01-000000" res
    assert_equals 0 $?
    assert_equals "$(date -d "1970-01-01 00:00:00 +0" +%s)" "$res"

    rbkp.parse_date "1234-09-08-123456" res
    assert_equals 0 $?
    assert_equals "$(date -d "1234-09-08 12:34:56 +0" +%s)" "$res"

    assert_fail 'rbkp.parse_date "1234-99-01-123456" res'
    assert_fail 'rbkp.parse_date "1234-99-01-12345" res'
    assert_fail 'rbkp.parse_date "1234-99-01" res'
    assert_fail 'rbkp.parse_date "1234-99" res'
    assert_fail 'rbkp.parse_date "123499" res'
    assert_fail 'rbkp.parse_date "abcd-ab-ab-cdefgh" res'
} >&"$_OUT"

test_find_backups() {
    local -A cfg=()
    util.make_fake_cfg cfg "$SRC_ROOT" "$DST_ROOT"

    # 0 backup
    local -a res=()
    rbkp.find_backups cfg res
    assert_not_equals 0 $?
    assert_equals 0 "${#res[@]}"

    # 1 backup
    mkdir -p "$DST_ROOT/1970-01-01-000000"
    local -a res=()
    rbkp.find_backups cfg res
    assert_equals 0 $?
    assert_equals 1 "${#res[@]}"
    assert_equals "$DST_ROOT/1970-01-01-000000" "${res[0]}"

    # 2 backups
    mkdir -p "$DST_ROOT/1234-12-12-123456"
    local -a res=()
    rbkp.find_backups cfg res
    assert_equals 0 $?
    assert_equals 2 "${#res[@]}"
    assert_equals "$DST_ROOT/1234-12-12-123456" "${res[0]}"

    # 2 backups + 1 invalid
    mkdir -p "$DST_ROOT/1111-11-11-999999"
    local -a res=()
    rbkp.find_backups cfg res
    assert_equals 0 $?
    assert_equals 2 "${#res[@]}"
    assert_equals "$DST_ROOT/1234-12-12-123456" "${res[0]}"

    # 2 backups + 2 invalid
    mkdir -p "$DST_ROOT/abce-ef-gh-ijklmn"
    local -a res=()
    rbkp.find_backups cfg res
    assert_equals 0 $?
    assert_equals 2 "${#res[@]}"
    assert_equals "$DST_ROOT/1234-12-12-123456" "${res[0]}"

    # Sort in reverse
    local -a res=()
    rbkp.find_backups cfg res -r
    assert_equals 0 $?
    assert_equals 2 "${#res[@]}"
    assert_equals "$DST_ROOT/1970-01-01-000000" "${res[0]}"
} >&"$_OUT"

test_expire_backup() {
    local -A cfg=()
    util.make_fake_cfg cfg "$SRC_ROOT" "$DST_ROOT"

    # Regular expire
    mkdir -p "$DST_ROOT/1970-01-01-000000"
    rbkp.expire_backup cfg "$DST_ROOT/1970-01-01-000000"
    assert_equals 0 $?
    assert_fail "[[ -d '$DST_ROOT/1970-01-01-000000' ]]"

    # Expire non-backup directories
    mkdir -p "$DST_ROOT/1970-01-01-000000"
    rm -f "${DST_ROOT:?}/backup.marker"
    local stderr=''
    stderr=$(rbkp.expire_backup cfg "$DST_ROOT/1970-01-01-000000" 2>&1 >/dev/null)
    assert_not_equals 0 $?
    assert_matches 'Abort:.*not on a backup destination' "$stderr"
    assert "[[ -d '$DST_ROOT/1970-01-01-000000' ]]"
} >&"$_OUT"

test_run() {
    local -A cfg=()
    # Run locally
    util.make_fake_cfg cfg "$SRC_ROOT" "$DST_ROOT"
    assert_fail "[[ -f '$SRC_ROOT/spam' ]]"
    rbkp.run cfg "touch" "$SRC_ROOT/spam"
    assert "[[ -f '$SRC_ROOT/spam' ]]"

    # Run with ssh
    util.make_fake_cfg cfg "$SRC_ROOT" "$SSH_USER@$SSH_HOST:$DST_ROOT"
    assert_fail "[[ -f '$SRC_ROOT/ham' ]]"
    rbkp.run cfg "touch" "$SRC_ROOT/ham"
    assert "[[ -f '$SRC_ROOT/ham' ]]"

    # Run with ssh without user@
    util.make_fake_cfg cfg "$SRC_ROOT" "$SSH_HOST:$DST_ROOT"
    assert_fail "[[ -f '$SRC_ROOT/sam' ]]"
    rbkp.run cfg "touch" "$SRC_ROOT/sam"
    assert "[[ -f '$SRC_ROOT/sam' ]]"

    # Make sure ssh is executed
    _echo() { echo "ssh ${FAKE_PARAMS[*]}"; }
    fake ssh _echo
    output="$(rbkp.run cfg "touch" "$SRC_ROOT/jam")"
    assert_matches "ssh .*" "$output"
} >&"$_OUT" 2>&1

# This one is not very interesting
test_parse_args() {
    local -A cfg=()
    rbkp.create_default_config cfg

    # Regular args
    rbkp.parse_args cfg -p 12345
    assert_equals 12345 "${cfg[SSH_PORT]}"

    rbkp.parse_args cfg --port 54321
    assert_equals 54321 "${cfg[SSH_PORT]}"

    assert_equals true "${cfg[AUTO_EXPIRE]}"
    rbkp.parse_args cfg -nae
    assert_equals false "${cfg[AUTO_EXPIRE]}"

    rbkp.parse_args cfg -ld /tmp
    assert_equals /tmp "${cfg[LOG_DIR]}"

    # Rsync flags
    local default_flags="${cfg[RSYNC_FLAGS]}"

    output="$(rbkp.parse_args cfg -rgf)"
    assert_equals "$default_flags" "$output"

    rbkp.parse_args cfg -raf --abc --rsync-append-flags def
    assert_equals "$default_flags --abc def" "${cfg[RSYNC_FLAGS]}"

    rbkp.parse_args cfg --rsync-append-flags '-a b --c-d e'
    assert_equals "$default_flags --abc def -a b --c-d e" "${cfg[RSYNC_FLAGS]}"

    rbkp.parse_args cfg -rsf --abc
    assert_equals "--abc" "${cfg[RSYNC_FLAGS]}"

    # Old and new retention policy
    rbkp.parse_args cfg -s abcdefg
    assert_equals 'abcdefg' "${cfg[EXPIRATION_STRATEGY]}"
    assert_equals false "${cfg[USE_RETENTION]}"

    rbkp.parse_args cfg -r gfedcba
    assert_equals 'gfedcba' "${cfg[RETENTION_POLICY]}"
    assert_equals true "${cfg[USE_RETENTION]}"

    # Src/dest folder and exclusion files
    rbkp.create_default_config cfg
    rbkp.parse_args cfg -- /tmp /tmp2 /tmp/tmp3.txt
    assert_equals /tmp "${cfg[SRC_DIR]}"
    assert_equals /tmp2 "${cfg[DEST_DIR]}"
    assert_equals /tmp/tmp3.txt "${cfg[EXCL_FILE]}"

    rbkp.create_default_config cfg
    rbkp.parse_args cfg /tmpA /tmpB -nae /tmp/C.txt
    assert_equals /tmpA "${cfg[SRC_DIR]}"
    assert_equals /tmpB "${cfg[DEST_DIR]}"
    assert_equals /tmp/C.txt "${cfg[EXCL_FILE]}"
} >&"$_OUT"

test_sanitize_cfg() {
    local -A cfg=()
    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$SRC_ROOT"
    assert_fail 'rbkp.sanitize_cfg cfg'

    # Test invalid policies
    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$SRC_ROOT" "$DST_ROOT" -s '87:65 43:21'
    rbkp.sanitize_cfg cfg
    assert_equals 0 $?

    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$SRC_ROOT" "$DST_ROOT" -s '87:65 as:df'
    assert_fail 'rbkp.sanitize_cfg cfg'

    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$SRC_ROOT" "$DST_ROOT" -r '12:34 56:78'
    rbkp.sanitize_cfg cfg
    assert_equals 0 $?

    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$SRC_ROOT" "$DST_ROOT" -r '12:34 as:df'
    assert_fail 'rbkp.sanitize_cfg cfg'
} >&"$_OUT"

# Test configs with ssh
test_sanitize_cfg_ssh() {
    local -A cfg=()

    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$SSH_USER@$SSH_HOST:$SRC_ROOT" "$DST_ROOT"
    rbkp.sanitize_cfg cfg
    assert_equals 0 $?
    assert_equals "$SSH_USER" "${cfg[SSH_USER]}"
    assert_equals "$SSH_HOST" "${cfg[SSH_HOST]}"
    assert_equals "$SSH_USER@$SSH_HOST:" "${cfg[SSH_SRC_DIR_PREFIX]}"
    assert_equals "ssh $SSH_USER@$SSH_HOST" "${cfg[SSH_CMD]}"

    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$SRC_ROOT" "$SSH_USER@$SSH_HOST:$DST_ROOT"
    rbkp.sanitize_cfg cfg
    assert_equals 0 $?
    assert_equals "$SSH_USER" "${cfg[SSH_USER]}"
    assert_equals "$SSH_HOST" "${cfg[SSH_HOST]}"
    assert_equals "$DST_ROOT" "${cfg[SSH_DEST_DIR]}"
    assert_equals "$SSH_USER@$SSH_HOST:" "${cfg[SSH_DEST_DIR_PREFIX]}"
    assert_equals "ssh $SSH_USER@$SSH_HOST" "${cfg[SSH_CMD]}"
} >&"$_OUT"

test_check_filesystems_marker_file() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"

    # Regular execution should succeed
    rbkp.check_filesystems cfg sess
    assert_equals 0 $?

    # Fail if no marker file
    rm -f "$DST_ROOT/backup.marker"
    stderr="$(rbkp.check_filesystems cfg sess 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches '.*marker file not found.*' "$stderr"
} >&"$_OUT"

test_check_filesystems_hardlinks() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"

    # Error if no hard linking not suportted
    fake ln false
    stderr="$(rbkp.check_filesystems cfg sess 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches ".*doesn't support hard links.*" "$stderr"
} >&"$_OUT"

test_check_filesystems_root_dir() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "/" "$DST_ROOT"

    # Regular execution should succeed
    rbkp.check_filesystems cfg sess
    assert_equals 0 $?

    # There shouldn't be any error messages
    stderr="$(rbkp.check_filesystems cfg sess 2>&1 >/dev/null)"
    assert_equals 0 $?
    assert_equals '' "$stderr"
} >&"$_OUT"

test_check_filesystems_fs_type() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"

    # Pretend that filesystem is exfat
    fake df <<<'exFat'
    rbkp.check_filesystems cfg sess
    assert_equals 0 $?
    assert_matches '.*--modify-window 2' "${cfg[RSYNC_FLAGS]}"
} >&"$_OUT"

test_handle_previous_backup_running() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"

    # Pretend that the current process is the backup process
    cfg[PROG_NAME]="$(basename "$0")"
    echo $$ >"${sess[INPROGRESS_FILE]}"
    local stderr=''
    stderr="$(rbkp.handle_previous_backup_failure cfg sess 2>&1 >/dev/null)"
    assert_not_equals 0 $?
    assert_matches "Abort:.*$$.*active.*" "$stderr"
} >&"$_OUT"

test_handle_previous_backup_failure() {
    # Fake two 'previous backups'
    mkdir -p "$DST_ROOT/1970-01-01-111111"
    touch "$DST_ROOT/1970-01-01-111111/file1"
    mkdir -p "$DST_ROOT/1970-01-01-222222"
    touch "$DST_ROOT/1970-01-01-222222/file2"

    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"

    # Previous backup failed and not running
    echo $$ >"${sess[INPROGRESS_FILE]}"
    sess[MYPID]=123456

    rbkp.handle_previous_backup_failure cfg sess
    assert_equals 0 $?

    assert "[[ -f '${sess[INPROGRESS_FILE]}' ]]"
    assert "[[ -f '${sess[DEST]}/file2' ]]"

    assert_equals "$DST_ROOT/1970-01-01-111111" "${sess[PREV_DEST]}"
    assert_equals "123456" "$(cat "${sess[INPROGRESS_FILE]}")"
} >&"$_OUT"

test_expire_backups_old() {
    local -A cfg=() sess=()

    # Pretend that current time is 2002-12-31 01:23:45
    _fakedate() {
        [[ ${#FAKE_PARAMS[@]} -eq 1 && "${FAKE_PARAMS[0]}" == "+%s" ]] || {
            command date "${FAKE_PARAMS[@]}"
            return
        }
        command date -d "2002-12-31 01:23:45" +%s
    }
    fake date _fakedate

    # Create config and session
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"

    # Create 1008 backups
    util.make_fake_1008_backups "$DST_ROOT"

    # The oldest one is always kept
    rbkp.expire_backups_old cfg sess "$DST_ROOT/2000-01-01-012345"
    local -a remaining=("$DST_ROOT"/????-??-??-??????)
    assert_equals 1008 "${#remaining[@]}"

    # Prune everything with default strtegy and see what remains
    rbkp.expire_backups_old cfg sess "$DST_ROOT/2002-12-28-012345"
    local -a expected=(
        # Before 1 year, keep every month
        2000-01-01 2000-02-01 2000-03-02 2000-04-01
        2000-05-01 2000-06-01 2000-07-01 2000-08-01
        2000-09-01 2000-10-01 2000-11-01 2000-12-01
        2001-01-01 2001-02-01 2001-03-03 2001-04-02
        2001-05-02 2001-06-01 2001-07-01 2001-08-01
        2001-09-01 2001-10-01 2001-11-01 2001-12-01
        # Before 1 month, keep every week
        2002-01-01 2002-01-08 2002-01-15 2002-01-22
        2002-02-01 2002-02-08 2002-02-15 2002-02-22
        2002-03-01 2002-03-08 2002-03-15 2002-03-22
        2002-04-01 2002-04-08 2002-04-15 2002-04-22
        2002-05-01 2002-05-08 2002-05-15 2002-05-22
        2002-06-01 2002-06-08 2002-06-15 2002-06-22
        2002-07-01 2002-07-08 2002-07-15 2002-07-22
        2002-08-01 2002-08-08 2002-08-15 2002-08-22
        2002-09-01 2002-09-08 2002-09-15 2002-09-22
        2002-10-01 2002-10-08 2002-10-15 2002-10-22
        2002-11-01 2002-11-08 2002-11-15 2002-11-22
        # Before 1 day, keep every day
        2002-12-01 2002-12-02 2002-12-03 2002-12-04
        2002-12-05 2002-12-06 2002-12-07 2002-12-08
        2002-12-09 2002-12-10 2002-12-11 2002-12-12
        2002-12-13 2002-12-14 2002-12-15 2002-12-16
        2002-12-17 2002-12-18 2002-12-19 2002-12-20
        2002-12-21 2002-12-22 2002-12-23 2002-12-24
        2002-12-25 2002-12-26 2002-12-27 2002-12-28
    )
    local -a remaining=()
    mapfile -t remaining < <(printf '%s\n' "$DST_ROOT"/????-??-??-?????? | sort)
    assert_equals 96 "${#remaining[@]}"
    assert_equals "${expected[*]/#/"$DST_ROOT/"}" "${remaining[*]/%-012345/}"

    # Today and future backups should be kept
    mkdir -p "$DST_ROOT/2002-12-31-111111"
    mkdir -p "$DST_ROOT/2002-12-31-222222"
    mkdir -p "$DST_ROOT/2002-12-31-333333"
    mkdir -p "$DST_ROOT/2002-12-31-444444"
    rbkp.expire_backups_old cfg sess "$DST_ROOT/2002-12-28-012345"
    local -a remaining=("$DST_ROOT"/????-??-??-??????)
    assert_equals 100 "${#remaining[@]}"
} >&"$_OUT"

test_expire_backups_new() {
    local -A cfg=() sess=()

    # Pretend that current time is 2002-12-28 11:23:45
    _fakedate() {
        [[ ${#FAKE_PARAMS[@]} -eq 1 && "${FAKE_PARAMS[0]}" == "+%s" ]] || {
            command date "${FAKE_PARAMS[@]}"
            return
        }
        command date -d "2002-12-28 11:23:45" +%s
    }
    fake date _fakedate

    # Create config and session
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"

    # Create 1008 backups
    util.make_fake_1008_backups "$DST_ROOT"

    rbkp.expire_backups_old cfg sess "$DST_ROOT/2000-01-01-012345"
    local -a remaining=("$DST_ROOT"/????-??-??-??????)
    assert_equals 1008 "${#remaining[@]}"

    rbkp.expire_backups_new cfg sess "$DST_ROOT/2002-12-28-012345"
    local -a expected=(
        #  DATE       daily  weekly  monthly  yearly
        2000-12-28 #      '       '        '       3
        2001-12-28 #      '       '        '       2
        2002-02-01 #      '       '       12       '
        2002-03-03 #      '       '       11       '
        2002-04-02 #      '       '       10       '
        2002-05-02 #      '       '        9       '
        2002-06-01 #      '       '        8       '
        2002-07-01 #      '       '        7       '
        2002-07-28 #      '       '        6       '
        2002-08-28 #      '       '        5       '
        2002-09-28 #      '       '        4       '
        2002-10-28 #      '       '        3       '
        2002-11-09 #      '       8        '       '
        2002-11-16 #      '       7        '       '
        2002-11-23 #      '       6        '       '
        2002-11-28 #      '       5        2       '
        2002-12-07 #      '       4        '       '
        2002-12-14 #      '       3        '       '
        2002-12-21 #      7       2        '       '
        2002-12-22 #      6       '        '       '
        2002-12-23 #      5       '        '       '
        2002-12-24 #      4       '        '       '
        2002-12-25 #      3       '        '       '
        2002-12-26 #      2       '        '       '
        2002-12-27 #      1       1        1       1
        2002-12-28 # ------------ TODAY ------------
    )
    local -a remaining=()
    mapfile -t remaining < <(printf '%s\n' "$DST_ROOT"/????-??-??-?????? | sort)
    assert_equals "${#expected[@]}" "${#remaining[@]}"
    assert_equals "${expected[*]/#/"$DST_ROOT/"}" "${remaining[*]/%-012345/}"

    # Today and future backups should be kept
    mkdir -p "$DST_ROOT/2002-12-28-111111"
    mkdir -p "$DST_ROOT/2002-12-28-222222"
    mkdir -p "$DST_ROOT/2002-12-28-333333"
    mkdir -p "$DST_ROOT/2002-12-28-444444"
    rbkp.expire_backups_new cfg sess "$DST_ROOT/2002-12-28-012345"
    local -a remaining=("$DST_ROOT"/????-??-??-??????)
    assert_equals 30 "${#remaining[@]}"
} >&"$_OUT"

test_pre_backup() {
    # Fake two 'previous backups'
    mkdir -p "$DST_ROOT/1970-01-01-111111"
    touch "$DST_ROOT/1970-01-01-111111/file1"
    mkdir -p "$DST_ROOT/1970-01-01-222222"
    touch "$DST_ROOT/1970-01-01-222222/file2"

    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"
    rbkp.pre_backup cfg sess
    assert_equals 0 $?

    # Should use incremental flag
    assert_matches "$DST_ROOT/1970-01-01-222222" "${sess[LINK_DEST]}"

    # Create destinations
    assert "[[ -d '${sess[DEST]}' ]]"

    # Expire old backups
    assert_fail "[[ -d '$DST_ROOT/1970-01-01-111111' ]]"
} >&"$_OUT"

test_pre_backup_hook() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SSH_HOST:$SRC_ROOT" "$DST_ROOT" \
        --pre-sync-hook 'echo "pre-sync-hook"'
    local stdout=''
    stdout="$(rbkp.pre_backup_hook cfg sess)"
    assert_equals 0 $?
    assert_matches '.*Running pre-sync hook.*pre-sync-hook.*' "$stdout"
} >&"$_OUT"

test_pre_backup_hook_failed() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SSH_HOST:$SRC_ROOT" "$DST_ROOT" \
        --pre-sync-hook 'false'
    local stderr=''
    stderr="$(rbkp.pre_backup_hook cfg sess 2>&1 >/dev/null)"
    assert_not_equals 0 $?
} >&"$_OUT"

test_post_backup_hook() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SSH_HOST:$SRC_ROOT" "$DST_ROOT" \
        --post-sync-hook 'echo "post-sync-hook"'
    local stdout=''
    stdout="$(rbkp.post_backup_hook cfg sess)"
    assert_equals 0 $?
    assert_matches '.*Running post-sync hook.*post-sync-hook.*' "$stdout"
} >&"$_OUT"

test_post_backup_hook_failed() {
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess "$SSH_HOST:$SRC_ROOT" "$DST_ROOT" \
        --post-sync-hook 'false'
    local stderr=''
    stderr="$(rbkp.post_backup_hook cfg sess 2>&1 >/dev/null)"
    assert_not_equals 0 $?
} >&"$_OUT"

test_do_backup() {
    # Create files in source directory
    touch "$SRC_ROOT"/{file1,file2,file3}

    # Fake two 'previous backups'
    mkdir -p "$DST_ROOT/1970-01-01-111111"
    touch "$DST_ROOT/1970-01-01-111111/file1"
    touch "$DST_ROOT/1970-01-01-111111/fileX"
    mkdir -p "$DST_ROOT/1970-01-01-222222"
    touch "$DST_ROOT/1970-01-01-222222/file2"
    touch "$DST_ROOT/1970-01-01-222222/fileY"

    # Peparations
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess -ld "$TEST_ROOT/log" "$SRC_ROOT" "$DST_ROOT"
    rbkp.pre_backup cfg sess
    mkdir -p -- "${cfg[LOG_DIR]}"

    # Do backup
    local -A rsync_result=([NO_SPACE]=false [ISSUES]='none')
    rbkp.do_backup cfg sess rsync_result
    assert_equals 0 $?

    # Test backup status
    assert "[[ -f '${sess[DEST]}/file1' ]]"
    assert "[[ -f '${sess[DEST]}/file2' ]]"
    assert "[[ -f '${sess[DEST]}/file3' ]]"
    assert_fail "[[ -f '${sess[DEST]}/fileX' ]]"
    assert_fail "[[ -f '${sess[DEST]}/fileY' ]]"
    assert_fail "[[ '$SRC_ROOT/file1' -ef '${sess[DEST]}/file1' ]]"
    assert_fail "[[ '$SRC_ROOT/file2' -ef '${sess[DEST]}/file2' ]]"
    assert "[[ '$DST_ROOT/1970-01-01-222222/file2' -ef '${sess[DEST]}/file2' ]]"

    # Inprogress file should be created
    assert "[[ -f '${sess[INPROGRESS_FILE]}' ]]"

    # There should be no rsync issues
    assert_equals 'none' "${rsync_result[ISSUES]}"
} >&"$_OUT"

# like do_backup but with remote src
test_do_backup_ssh() {
    # Create files in source directory
    touch "$SRC_ROOT"/{file1,file2,file3}

    # Fake two 'previous backups'
    mkdir -p "$DST_ROOT/1970-01-01-111111"
    touch "$DST_ROOT/1970-01-01-111111/file1"
    touch "$DST_ROOT/1970-01-01-111111/fileX"
    mkdir -p "$DST_ROOT/1970-01-01-222222"
    touch "$DST_ROOT/1970-01-01-222222/file2"
    touch "$DST_ROOT/1970-01-01-222222/fileY"

    # Peparations
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess \
        -ld "$TEST_ROOT/log" "$SSH_USER@$SSH_HOST:$SRC_ROOT" "$DST_ROOT"
    rbkp.pre_backup cfg sess
    mkdir -p -- "${cfg[LOG_DIR]}"

    # Do backup
    local -A rsync_result=([NO_SPACE]=false [ISSUES]='none')
    rbkp.do_backup cfg sess rsync_result
    assert_equals 0 $?

    # Test backup status
    assert "[[ -f '${sess[DEST]}/file1' ]]"
    assert "[[ -f '${sess[DEST]}/file2' ]]"
    assert "[[ -f '${sess[DEST]}/file3' ]]"
    assert_fail "[[ -f '${sess[DEST]}/fileX' ]]"
    assert_fail "[[ -f '${sess[DEST]}/fileY' ]]"
    assert_fail "[[ '$SRC_ROOT/file1' -ef '${sess[DEST]}/file1' ]]"
    assert_fail "[[ '$SRC_ROOT/file2' -ef '${sess[DEST]}/file2' ]]"
    assert "[[ '$DST_ROOT/1970-01-01-222222/file2' -ef '${sess[DEST]}/file2' ]]"

    # Inprogress file should be created
    assert "[[ -f '${sess[INPROGRESS_FILE]}' ]]"

    # There should be no rsync issues
    assert_equals 'none' "${rsync_result[ISSUES]}"
} >&"$_OUT"

test_backup_special_characters() {
    # Test special characters, such as single quotes, spaces, and CJK chars.
    local src="$TEST_ROOT/Naïve '♡' Café" dst="$TEST_ROOT/I'm 一只猫猫"
    local excl="$TEST_ROOT/Here's an exclusion-ファイル"
    echo "- exc-*" >|"$excl"

    # Create files in source directory
    mkdir "$src" "$dst"
    touch "$dst/backup.marker"
    touch "$src/"{file1,file2,file3,exc-file1,exc-file2}

    # Fake two 'previous backups'
    mkdir -p "$dst/1970-01-01-111111"
    touch "$dst/1970-01-01-111111/file1"
    touch "$dst/1970-01-01-111111/fileX"
    mkdir -p "$dst/1970-01-01-222222"
    touch "$dst/1970-01-01-222222/file2"
    touch "$dst/1970-01-01-222222/fileY"

    # Peparations
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess \
        -ld "$TEST_ROOT/log" "$src" "$dst" "$excl"
    rbkp.pre_backup cfg sess
    mkdir -p -- "${cfg[LOG_DIR]}"

    rbkp.pre_backup cfg sess
    mkdir -p -- "${cfg[LOG_DIR]}"

    # Do backup
    local -A rsync_result=([NO_SPACE]=false [ISSUES]='none')
    rbkp.do_backup cfg sess rsync_result
    assert_equals 0 $?

    # Test backup status
    assert "[[ -f ${sess[DEST]@Q}/file1 ]]"
    assert "[[ -f ${sess[DEST]@Q}/file2 ]]"
    assert "[[ -f ${sess[DEST]@Q}/file3 ]]"
    assert_fail "[[ -f ${sess[DEST]@Q}/fileX ]]"
    assert_fail "[[ -f ${sess[DEST]@Q}/fileY ]]"

    # Test exclude list validity
    assert_fail "[[ -f ${sess[DEST]@Q}/exc-file1 ]]"
    assert_fail "[[ -f ${sess[DEST]@Q}/exc-file2 ]]"

    # Test hard links
    assert_fail "[[ ${src@Q}/file1 -ef ${sess[DEST]@Q}/file1 ]]"
    assert_fail "[[ ${src@Q}/file2 -ef ${sess[DEST]@Q}/file2 ]]"
    assert "[[ ${dst@Q}/1970-01-01-222222/file2 -ef ${sess[DEST]@Q}/file2 ]]"

    # Inprogress file should be created
    assert "[[ -f ${sess[INPROGRESS_FILE]@Q} ]]"

    # There should be no rsync issues
    assert_equals 'none' "${rsync_result[ISSUES]}"
} >&"$_OUT"

test_post_backup() {
    # Create files in source directory
    touch "$SRC_ROOT"/{file1,file2,file3}

    # Fake two 'previous backups'
    mkdir -p "$DST_ROOT/1970-01-01-111111"
    touch "$DST_ROOT/1970-01-01-111111/file1"
    touch "$DST_ROOT/1970-01-01-111111/fileX"
    mkdir -p "$DST_ROOT/1970-01-01-222222"
    touch "$DST_ROOT/1970-01-01-222222/file2"
    touch "$DST_ROOT/1970-01-01-222222/fileY"

    # Peparations
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess -ld "$TEST_ROOT/log" "$SRC_ROOT" "$DST_ROOT"
    rbkp.pre_backup cfg sess
    mkdir -p -- "${cfg[LOG_DIR]}"
    local -A rsync_result=([NO_SPACE]=false [ISSUES]='none')
    rbkp.do_backup cfg sess rsync_result
    rbkp.post_backup cfg sess rsync_result
    assert_equals 0 $?

    assert "[[ -L '${cfg[DEST_DIR]}/latest' ]]"
    assert "[[ '${cfg[DEST_DIR]}/latest' -ef '${sess[DEST]}' ]]"
    assert_fail "[[ -f '${sess[INPROGRESS_FILE]}' ]]"
} >&"$_OUT"

test_post_backup_failed() {
    # Create files in source directory
    touch "$SRC_ROOT"/{file1,file2,file3}

    _rsync() { return 123; }
    fake rsync _rsync

    # Peparations
    local -A cfg=() sess=()
    util.make_fake_cfg_sess cfg sess -ld "$TEST_ROOT/log" "$SRC_ROOT" "$DST_ROOT"
    rbkp.pre_backup cfg sess
    mkdir -p -- "${cfg[LOG_DIR]}"
    local -A rsync_result=([NO_SPACE]=false [ISSUES]='none')
    rbkp.do_backup cfg sess rsync_result
    local stderr=
    stderr="$(rbkp.post_backup cfg sess rsync_result 2>&1 >/dev/null)"
    assert_equals 123 $?
    assert_matches '.*Rsync returns nonzero return code \(123\).*' "$stderr"

    # Inprogress file should not be removed on error
    assert "[[ -f '${sess[INPROGRESS_FILE]}' ]]"
} >&"$_OUT"
