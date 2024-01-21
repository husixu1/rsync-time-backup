#!/bin/bash
# shellcheck disable=SC2317
# Retention policy tests.

source ../rsync-tmbackup.sh
source ./utils.sh

_OUT=1 # Debug
# exec {_OUT}<>/dev/null # No Debug

# Initializations -------------------------------------------------------------
setup_suite() {
    # Use tmpfs (ram) for faster test
    TEST_ROOT="$(mktemp -p /tmp -d)"
    SRC_ROOT="$TEST_ROOT/SRC"
    DST_ROOT="$TEST_ROOT/DST"
}

teardown_suite() {
    rm -rf "${TEST_ROOT:?}"
}

setup() {
    mkdir -p -- "$SRC_ROOT" "$DST_ROOT"
    touch "$DST_ROOT/backup.marker"
}

teardown() {
    rm -rf -- "${SRC_ROOT:?}" "${DST_ROOT:?}"
}

# Tests -----------------------------------------------------------------------
# siumlate 1008 daily backup and retentions and see what remains
test_expire_backups_old_simulated() {
    __daily_routine() {
        local year="$1" month="$2" day="$3"
        echo "Faking $year-$month-$day"

        _fakedate() {
            [[ ${#FAKE_PARAMS[@]} -eq 1 && "${FAKE_PARAMS[0]}" == "+%s" ]] || {
                command date "${FAKE_PARAMS[@]}"
                return
            }
            # Pretend that current time is <date> 11:23:45
            command date -d "$year-$month-$day 01:23:45" +%s
        }
        fake date _fakedate

        # Create fake daily backup
        mkdir -p "$DST_ROOT/$year-$month-$day-012345"

        # Create config and session
        local -A cfg=() sess=()
        util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"
        rbkp.expire_backups_old cfg sess "$DST_ROOT/$year-$month-$day-012345"
        assert_equals 0 $?
    }

    # The number of backups kept are the same as test_expire_backups_old,
    # but what remains are different.
    util.fake_1008_daily_cmds __daily_routine
    local -a expected=(
        2000-01-01 2000-02-01 2000-03-08 2000-04-08
        2000-05-08 2000-06-08 2000-07-08 2000-08-08
        2000-09-08 2000-10-08 2000-11-08 2000-12-08
        2001-01-08 2001-02-08 2001-03-15 2001-04-15
        2001-05-15 2001-06-15 2001-07-15 2001-08-15
        2001-09-15 2001-10-15 2001-11-15 2001-12-15
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
    assert_equals "${#expected[@]}" "${#remaining[@]}"
    assert_equals "${expected[*]/#/"$DST_ROOT/"}" "${remaining[*]/%-012345/}"
} >&"$_OUT"

# siumlate 1008 daily backup and retentions and see what remains
test_expire_backups_new_simulated() {
    __daily_routine() {
        local year="$1" month="$2" day="$3"
        echo "Faking $year-$month-$day"

        _fakedate() {
            [[ ${#FAKE_PARAMS[@]} -eq 1 && "${FAKE_PARAMS[0]}" == "+%s" ]] || {
                command date "${FAKE_PARAMS[@]}"
                return
            }
            # Pretend that current time is <date> 11:23:45
            command date -d "$year-$month-$day 01:23:45" +%s
        }
        fake date _fakedate

        # Create fake daily backup
        mkdir -p "$DST_ROOT/$year-$month-$day-012345"

        # Create config and session
        local -A cfg=() sess=()
        util.make_fake_cfg_sess cfg sess "$SRC_ROOT" "$DST_ROOT"
        rbkp.expire_backups_new cfg sess "$DST_ROOT/$year-$month-$day-012345"
        assert_equals 0 $?
    }

    # The number of backups kept are the same as test_expire_backups_new,
    # but what remains are different.k
    util.fake_1008_daily_cmds __daily_routine
    local -a expected=(
        #  DATE       daily  weekly  monthly  yearly
        2000-01-01 #      '       '        '       3
        2001-01-07 #      '       '        '       2
        2002-01-13 #      '       '       10       '
        2002-02-26 #      '       '        9       '
        2002-04-24 #      '       '        8       '
        2002-05-25 #      '       '        7       '
        2002-07-18 #      '       '        6       '
        2002-08-24 #      '       '        5       '
        2002-09-03 #      '       '        4       '
        2002-10-04 #      '       '        '       '
        2002-10-28 #      '       '        3       '
        2002-11-05 #      '       8        '       '
        2002-11-12 #      '       7        '       '
        2002-11-18 #      '       6        '       '
        2002-11-27 #      '       5        2       '
        2002-12-04 #      '       4        '       '
        2002-12-14 #      '       3        '       '
        2002-12-20 #      '       2        '       '
        2002-12-21 #      7       '        '       '
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
} >&"$_OUT"
