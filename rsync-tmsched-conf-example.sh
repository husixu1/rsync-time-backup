#!/bin/bash
# shellcheck disable=SC2034

# Define your own schedule with sched_xxx and use it with [sched]=xxx
sched_daily() { true; }
sched_weekly() { [[ "$(date +%u)" == "1" ]]; }
sched_monthly() { [[ "$(date +%d)" == "01" ]]; }

# Coustom your notification command on backup finish
# $1: rsync-tmbackup return code
# $2: backup config name (the xxx part of conf_xxx)
notify() {
    [[ "$1" -eq 0 ]] ||
        gotify-cli push -t "Backup Failed" "$2 (ret=$1)"
}

# Note that this log dir is the different from rsync-tmbackup's --log-file
# option, which only saves the output of rsync. This log dir saves all output
# to rsync-tmsched.{log,err} files (in append mode).
#
# Logs won't automatically rotate. Remember to use logrotate or similar
# utilities log rotation to prevent disk fillup. Set to empty to diable logging.
RSCD_LOG_DIR="/var/log/rsync-backup"

# Custom variables
BR_DST1="/mnt/BACKUP1"
BR_DST2="/mnt/BACKUP2"

# Backup System1 root ---------------------------------------------------------
declare -A conf_System1_DST1=(
    [src]="/"
    [dst]="$BR_DST1/Sys1-root"
)
declare -a excl_System1_DST1=(
    "- /swapfile"
    "- /dev"
    "- /proc"
    "- /sys"
    "- /tmp"
    "- /run"
    "- /mnt"
    "- /media"
    "- /lost+found"
    "- /var/lib/dhcpcd/*"
    "- /var/cache"
    "- /home/*/.gvfs"
    "- /home/*/.cache"
)
declare -A conf_System1_DST2=(
    [src]="/"
    [dst]="$BR_DST2/Sys1-root"
    # Perform this backup weekly
    [sched]='weekly'
)
declare -a excl_System1_DST2=(
    "${excl_System1_DST1[@]}"
    # Also exclude status files for archival backups
    "- /var/log/"
    "- /var/lib/"
    "- /home/*/.local/share/fish/fish_history"
    "- /home/*/.pyenv/shims/"
)

# Backup data directory -------------------------------------------------------
# Note that rsync-tmsched always add a slash '/' to source directory, so
# '/xxx' in the filter list means matching '<source>/xxx'. There's no need
# to specify '/<source>/xxx' in the filter list.
declare -A conf_Data_DST1=(
    [src]="/Data"
    [dst]="$BR_DST1/Data"
)
declare -a excl_Data_DST1=(
    # Backup only these directories under /Data
    "+ /Documents/***"
    "+ /Games/***"
    "+ /Music/***"
    "+ /Pictures/***"
    "+ /Software/***"
    "+ /Videos/***"
    # Everything else is excluded
    "- **"
)

# Backup remote server root ---------------------------------------------------
declare -A conf_Server_DST1=(
    # Make sure proper ssh key is added and permissions configured
    [src]="user@server:/"
    [dst]="$BR_DST1/Server-root"
    # Specify other options like this
    ['--id-rsa']="$HOME/.ssh/id_rsa"
)
declare -a excl_Server_DST1=(
    # Home directories
    "+ /home/*"
    "- /home/*/.gvfs"
    "- /home/*/.cache"
    "+ /home/*/***"
    # Nextcloud data
    "+ /var/"
    "+ /var/lib/"
    "- /var/lib/nextcloud/sessions"
    "+ /var/lib/nextcloud/***"
    # Everything else is excluded
    "- **"
)
declare -A conf_Server_DST2=(
    [src]="user@server:/"
    [dst]="$BR_DST2/Server-root"
    # Perform this backup monthly
    [sched]='monthly'
)
declare -a excl_Server_DST2=(
    "${excl_Server_DST1[@]}"
)
