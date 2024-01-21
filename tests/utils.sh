#!/bin/bash
# Test utils

# Include once guard
[[ -z $__TEST_UTILS_SH ]] || return
__TEST_UTILS_SH=1

# Create a fake config
# $1: cfg name
# ${@:2}: args passed to arg parser
util.make_fake_cfg() {
    rbkp.create_default_config "$1"
    rbkp.parse_args "$1" "${@:2}"
    rbkp.sanitize_cfg "$1"
}

util.make_fake_cfg_sess() {
    util.make_fake_cfg "$1" "${@:3}"
    rbkp.create_default_session "$1" "$2"
}

# $@: The command to call. Will be called as "$@" <year> <month> <date>
util.fake_1008_daily_cmds() {
    local year='' month='' day=''
    for year in {2000..2002}; do
        for month in {01..12}; do
            for day in {01..28}; do
                "$@" "$year" "$month" "$day"
            done
        done
    done
}

# Create total 1008 backups
# $1: Backup root
# shellcheck disable=SC2317
util.make_fake_1008_backups() {
    util.__fake_mkbackup() { mkdir -p "$1/$2-$3-$4-012345"; }
    util.fake_1008_daily_cmds util.__fake_mkbackup "$1"
}
