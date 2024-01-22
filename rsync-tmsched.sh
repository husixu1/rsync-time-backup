#!/bin/bash
# shellcheck disable=SC2034
# vim: set foldlevel=0 foldmethod=marker:
# Note: This script must be put in the same directory aside rsync-tmbackup.sh

# CONFIGS =====================================================================
# Some random variables
BR_DST1="/mnt/BACKUP1"
BR_DST2="/mnt/BACKUP2"

# Define your own schedule with sched_xxx and use it with [sched]=xxx
sched_daily() { true; }
sched_weekly() { [[ "$(date +%u)" == "1" ]]; }
sched_monthly() { [[ "$(date +%d)" == "01" ]]; }

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

# Backup remove server root ---------------------------------------------------
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
    # Nextcloud data
    "+ /var/lib/nextcloud"
    # Exclude useless files
    "- /home/*/.gvfs"
    "- /home/*/.cache"
    # Everything else is excluded
    "- /*"
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

# RSYNC-TMBACKUP WRAPPER ======================================================
# Don't use conf_*/excl_* as variable names here to avoid naming conflict.
rscd.main() { # {{{
    local HERE='' RBKP=''
    HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)" || exit 1
    RBKP="$HERE/rsync-tmbackup.sh"
    [[ -e "$RBKP" ]] || { echo "$RBKP not found." >&2 && return 1; }
    [[ -x "$RBKP" ]] || { echo "$RBKP not executable." && return 1; }

    local c_name='' src='' dst='' e_file=''
    for c_name in "${!conf_@}"; do
        echo ">> Processing "$'\033[1m'"$c_name"$'\033[0m'
        local -n c_dict="$c_name"
        [[ "${c_dict@a}" == A ]] || {
            echo "$c_name must be an associative array." >&2
            return 1
        }

        # Test if backup should be exeucted today
        [[ -z "${c_dict[sched]}" ]] || {
            typeset -fp "sched_${c_dict[sched]}" >/dev/null 2>&1 || {
                echo ">> Warning: sched_${c_dict[sched]} is not a function." >&2
                echo ">> Warning: skipping ${c_name}." >&2
                continue
            }
            "sched_${c_dict[sched]}" || {
                echo ">> Not today: skipping ${c_name}." >&2
                continue
            }
        }

        # Generate prerequisites and params
        local -a args=()

        # 1. Generate options
        local option=''
        for option in "${!c_dict[@]}"; do
            [[ ! $option =~ ^(src|dst|sched)$ ]] || continue
            args+=("$option" "${c_dict["$option"]}")
        done

        # 2. Generate src, dst
        args+=("${c_dict[src]}" "${c_dict[dst]}")

        # 3. Genrate exclude-file (if provided)
        [[ ! -v "excl_${c_name#conf_}" ]] || {
            local -n e_list="excl_${c_name#conf_}"
            [[ "${e_list@a}" == a ]] || {
                echo ">> Warning: excl_${c_name#conf_} must be an array." >&2
                echo ">> Warning: skipping ${c_name}." >&2
                continue
            }

            e_file=$(mktemp) || exit 1
            trap 'rm "${e_file:?}"; trap - RETURN;' RETURN
            (IFS=$'\n' && echo "${e_list[*]}" >|"$e_file")
            args+=("$e_file")
        }

        # Perform backup
        echo ">> Running $RBKP ${args[*]@Q}"
        "$RBKP" "${args[@]}"
    done
} # }}}

# Don't execute backup if sourced
# shellcheck disable=SC2317
return 0 2>/dev/null || rscd.main "$@"
