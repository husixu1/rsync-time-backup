#!/usr/bin/env bash
# shellcheck disable=SC2178

# Log functions: Info / Warning / Error / Critical
rbkp.__log() { local l='' && for l in "$@"; do echo "$l"$'\033[0m'; done; }
rbkp.inf() { rbkp.__log "${@/#/$'\033[92m'" [INF] "$'\033[0m'}"; }
rbkp.wrn() { rbkp.__log "${@/#/$'\033[93m'" [WRN] "}" 1>&2; }
rbkp.err() { rbkp.__log "${@/#/$'\033[91m'" [ERR] "}" 1>&2; }
rbkp.crt() { rbkp.err "$@" && exit 1; }

# $1: Config dict name
# $2: Exit code. Exit the script if non empty
rbkp.display_usage() {
    local -n _rc="$1"
    local -r H=$'\033[1m' U=$'\033[4m' N=$'\033[0m'
    cat <<EOF
${H}USAGE$N
    $H$(basename "$0")$N [OPTION]... [[USER@]HOST:]<SOURCE> [[USER@]HOST:]<DESTINATION> [exclude-pattern-file]

${H}OPTIONS$N
    $H-p$N <PORT>, $H--port$N <PORT>
        SSH port.

    $H-h$N, $H--help$N, $H-?$N
        Display this help message.

    $H-i$N <RSA_KEY>, $H--id-rsa$N <RSA_KEY>
        Specify the private ssh key to use.

    $H-rgf$N, $H--rsync-get-flags$N
        Display the default rsync flags that are used for backup. If using
        remote drive over SSH, --compress will be added.

    $H-rsf$N, $H--rsync-set-flags$N
        Set the rsync flags that are going to be used for backup.

    $H-raf$N, $H--rsync-append-flags$N
        Append the rsync flags that are going to be used for backup.

    $H-ld$N, $H--log-dir$N <DIR> (Default: ${_rc[LOG_DIR]})
        Set the log file directory. If this flag is set, generated files
        will not be managed by the script - in particular they will not be
        automatically deleted.

    $H-r$N, $H--retention$N "<M1:N1> <M2:N2> ..." (Default: ${_rc[RETENTION_POLICY]})
        Retention policy (overrides --strategy). Keeps the most recent Ni
        copies of per-Mi-days backup. The default means that keep 7 copies of
        most recent daily backup, keep 8 copies of most recent weekly backup,
        keep 12 copies of recent monthly backup and keep infinite yearly
        backups. Infinite sub-day backups are also kept, but they are subject
        to removal by the retention policy after one day of their creation.
        Mi and Ni must be positive integers. The option value must be quoted.

    $H-s$N, $H--strategy$N "<X1:Y1> <X2:Y2> ..." (Default: ${_rc[EXPIRATION_STRATEGY]})
        Use old retention policy. Keeps backup every Yi days before Xi
        days ago. The default means before one day ago, keep one backup per
        day. Before 30 days ago, keep one backup every 7 days. Before 365 days
        ago, keep one backup every 30 days. This option is kept to maintain
        compatibility with the original script. The option value must be
        quoted. See ${U}https://github.com/laurent22/rsync-time-backup$N

    $H-nae$N, $H--no-auto-expire$N
        Disable automatically deleting backups when out of space. Instead an
        error is logged, and the backup is aborted.

${H}SEE ALSO$N
    For detailed help, see the README file:
    ${U}https://github.com/husixu1/rsync-time-backup$N

    For exclude-pattern-file syntax, see:
    ${U}https://github.com/husixu1/rsync-time-backup/tree/master/docs/rsync_options.md$N
EOF
    [[ -z "$2" ]] || exit "$2"
}

# shellcheck disable=SC2003 disable=SC2307
# $1: Date in XXXX-XX-XX-XXXXXX format
# $2: Result variable name, will return time in seconds since epoch
# Return: 0 if conversion successful, 1 otherwise
rbkp.parse_date() {
    local -n _rs="$2"
    # Converts YYYY-MM-DD-HHMMSS to YYYY-MM-DD HH:MM:SS and then to Unix Epoch.
    case "$OSTYPE" in
    linux* | cygwin* | netbsd*)
        _rs="$( #
            date -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s 2>/dev/null
        )" || return 1
        ;;
    FreeBSD*)
        _rs="$( #
            date -j -f "%Y-%m-%d-%H%M%S" "$1" "+%s" 2>/dev/null
        )" || return 1
        ;;
    darwin*)
        # Under MacOS X Tiger
        # Or with GNU 'coreutils' installed (by homebrew)
        #   'date -j' doesn't work, so we do this:
        yy="$(expr "${1:0:4}")"
        mm="$(expr "${1:5:2}" - 1)"
        dd="$(expr "${1:8:2}")"
        hh="$(expr "${1:11:2}")"
        mi="$(expr "${1:13:2}")"
        ss="$(expr "${1:15:2}")"
        _rs="$( #
            perl -e "use Time::Local; print timelocal($ss,$mi,$hh,$dd,$mm,$yy),\"\n\";"
        )" || return 1
        ;;
    esac
}

# $1: Config dict name
# $2: Result array name holding a list of backups found.
#   Results are in full path. Array will be cleared first.
# $3: Sort cmd args ('' / '-r' / '-n', ...). Default '' means oldest first
# Returns: 0 if at least one backup found, 1 if none found or error occurs.
# shellcheck disable=SC2317 disable=SC2064
rbkp.find_backups() {
    local -n _rc="$1" _ra="$2"
    local sort_args="$3"
    rbkp.__find_backup() {
        trap "$(shopt -p nullglob dotglob failglob); trap - RETURN" RETURN
        shopt -s nullglob dotglob
        shopt -u failglob
        # Only putput directory names with valid date format
        for d in "$1"/*; do
            local r='r'
            [[ ! -d "$d" ]] || ! rbkp.parse_date "$(basename "$d")" "$r" || echo "$d"
        done | sort "${@:2}"
    }

    local output=''
    output="$( #
        rbkp.run "$1" \
            " $(typeset -fp rbkp.parse_date);" \
            " $(typeset -fp rbkp.__find_backup);" \
            " rbkp.__find_backup ${_rc[DEST_DIR]@Q} $sort_args;"
    )" || {
        rbkp.err "${FUNCNAME[0]}: Failed to run script to find backups."
        return 1
    }

    _ra=() && mapfile -t _ra < <(printf %s "$output")
    [[ "${#_ra[@]}" -gt 0 ]]
}

# $1: Config dict name
# $2: Backup dir path
rbkp.expire_backup() {
    local -n _rc="$1"
    local backup="$2"

    # Double-check that we're on a backup destination to be completely
    # sure we're deleting the right folder
    rbkp.test_f "$1" "$(dirname -- "$backup")/${_rc[MARKER_NAME]}" ||
        rbkp.crt "Abort: ${2@Q} is not on a backup destination."

    rbkp.inf "Expiring ${backup@Q}"
    rbkp.rm_dir "$1" "${backup:?}"
}

# Get the applicable cutoff interval (in days)
# $1: Config dict name
# $2: Backup dir
# $3: result variable name. Empty string if this backup should be kept.
# DEPRECATED. Use rbkp.expire_backups_new instead.
rbkp.__get_cutoff_interval() {
    local -n _rc="$1" _ref_cutoff_interval="$3"
    local backup_dir="$2" backup_ts=''
    local strategy_token backup_ts
    rbkp.parse_date "$(basename "$backup_dir")" backup_ts

    while read -r strategy_token; do
        [[ $strategy_token ]] || continue
        local -a t=() && IFS=':' read -ra t <<<"$strategy_token"
        # t[1]: Every how many days should a backup be kept before (today - t[0]).
        [[ "$backup_ts" -gt "$((_ss[NOW] - t[0] * 86400))" ]] || {
            _ref_cutoff_interval="$((t[1]))"
            return
        }
    done < <(echo "${_rc[EXPIRATION_STRATEGY]}" | tr " " "\n" | sort -r -n)
}

# Try to expire backups before the date of the backup to keep
#
# Clarify: The definition of "before" and "after":
#
#              before today       after today
#   <Jurassic> ------------ TODAY ----------- <Human Extinction>
#
# $1: Config dict name
# $2: Session variables dict name
# $3: Backup folder to keep
# DEPRECATED. Use rbkp.expire_backups_new instead.
rbkp.expire_backups_old() {
    local -n _rc="$1" _ss="$2"
    local backup_to_keep="$3" last_kept_ts="9999999999" cutoff_interval_days=''
    local backup_dir='' oldest_backup_to_keep='' backup_ts=''
    local -a expired=()

    local -a backups=()
    rbkp.find_backups "$1" backups

    # we will also keep the oldest backup
    oldest_backup_to_keep="${backups[0]}"

    # Process each backup dir from the oldest to the most recent
    for backup_dir in "${backups[@]}"; do
        local backup_ts=''
        rbkp.parse_date "$(basename "$backup_dir")" backup_ts || {
            rbkp.wrn "Could not parse date: $backup_dir"
            continue
        }

        # Finish pruning this if this is the latest backup requsted to be kept.
        [[ "$backup_dir" != "$backup_to_keep" ]] || break

        # We dont't want to delete the oldest backup.
        [[ "$backup_dir" != "$oldest_backup_to_keep" ]] || {
            last_kept_ts=$backup_ts
            continue
        }

        # Find which strategy token applies to this particular backup
        rbkp.__get_cutoff_interval "$1" "$backup_dir" cutoff_interval_days
        [[ "$cutoff_interval_days" ]] || continue

        # Special case: delete every time when backup interval is 0
        [[ "$cutoff_interval_days" -ne 0 ]] || {
            expired+=("$backup_dir")
            continue
        }
        # We calculate days number since last kept backup # Delete this backup if inside [last_backup, last_backup + interval)
        [[ "$((backup_ts / 86400 - last_kept_ts / 86400))" -ge "$cutoff_interval_days" ]] || {
            expired+=("$backup_dir")
            continue
        }

        # Otherwise keep it and assign this backup as the last kept backup
        last_kept_ts=$backup_ts
    done

    for backup_dir in "${expired[@]}"; do
        rbkp.expire_backup "$1" "$backup_dir"
    done
}

# $1: Config dict name
# $2: Session variables dict name
# $3: Backup to keep (Backups younger than this (or equals) will be kept).
rbkp.expire_backups_new() {
    local -n _rc="$1" _ss="$2"
    local backup_to_keep_ts=''
    rbkp.parse_date "$(basename "$3")" backup_to_keep_ts

    # Iterate backups: newest first
    local -a backups=() expired=()
    rbkp.find_backups "$1" backups -r

    # Get oldest backup timestamp to accelerate processing
    local oldest_backup_ts=''
    rbkp.parse_date "$(basename "${backups[-1]}")" oldest_backup_ts

    # ${retention[Mi]} == Ni. Generate a list of keep ranges from retention.
    local -A retention="${_rc[RETENTION_POLICY]}" kept=()
    local pol='' copies='' i=''
    for pol in "${!retention[@]}"; do
        copies="${retention["$pol"]}"
        for ((i = 1; i < copies + 1; ++i)); do
            local time="$((_ss[NOW] - i * pol * 86400))"
            # No need to consider if time < min(NOW - 2 * pol, oldest_backup)
            ((i <= 2)) || ((time >= oldest_backup_ts - pol * 86400)) || break
            kept["$time:$((time + pol * 86400))"]=1
        done
    done

    # Generate a list of backups to expire
    local backup_ts='' backup_dir=''
    for backup_dir in "${backups[@]}"; do
        rbkp.parse_date "$(basename "$backup_dir")" backup_ts
        # Keep all backups with the same date boundary and future backups
        ((_ss[NOW] - backup_ts >= 86400)) || continue

        # Find all range that applies
        local found=() range=''
        for range in "${!kept[@]}"; do
            [[ "${range%:*}" -le "$backup_ts" &&
                "$backup_ts" -lt "${range#*:}" ]] || continue
            found+=("$range")
        done
        # Mark all found ranges as kept.
        for range in "${found[@]}"; do unset "kept[$range]"; done

        # If newer than backup_to_keep, keep unconditionally.
        ((backup_ts < backup_to_keep_ts)) || continue

        # Expire if no applicable ranges found.
        [[ ${#found[@]} -eq 0 ]] || continue
        expired+=("$backup_ts:$backup_dir")
    done

    # Then for each non-satisfied range keep one nearest backup after it,
    # so that the kept backup can later expire and and satisfy the range.
    local -A expire_later=()
    mapfile -t expired < <(for e in "${expired[@]}"; do echo "$e"; done | tac)
    for range in "${!kept[@]}"; do
        for backup_dir in "${expired[@]}"; do
            [[ ${range#*:} -gt "${backup_dir%%:*}" ]] || {
                expire_later["${backup_dir#*:}"]=1
                break
            }
        done
    done

    # Expire those backups
    for backup_dir in "${expired[@]}"; do
        [[ ${expire_later["${backup_dir#*:}"]} ]] ||
            rbkp.expire_backup "$1" "${backup_dir#*:}"
    done
}

# Chose one of rbkp.expire_backups_old and rbkp.expire_backups_new
rbkp.expire_backups() {
    local -n _rc="$1"
    ${_rc[USE_RETENTION]} || rbkp.expire_backups_old "$@"
    rbkp.expire_backups_new "$@"
}

# Run command either locally or in the remote host
rbkp.__run() {
    local -n _rc="$1"
    # If non prefix set, run locally (in a subshell, to prevent var pollution)
    [[ ${_rc[$2]} ]] || { (eval "$3") && return $? || return $?; }
    # For ssh, we need to pipe in the commands non-bash login shell
    ${_rc[SSH_CMD]} "bash --noprofile --norc" <<<"$3"
}
# $1: Config dict name
# ${*:2}: Command to run
rbkp.run() { local _rc="$1" && rbkp.__run "$1" SSH_DEST_DIR_PREFIX "${*:2}"; }
# $1: Config dict name
# ${*:2}: Command to run
rbkp.run_src() { local _rc="$1" && rbkp.__run "$1" SSH_SRC_DIR_PREFIX "${*:2}"; }

rbkp.abs_path() { rbkp.run "$1" "cd ${2@Q}; pwd"; }
rbkp.mkdir() { rbkp.run "$1" "mkdir -p -- ${2@Q}"; }
rbkp.rm_file() { rbkp.run "$1" "rm -f -- ${2@Q}"; }
rbkp.rm_dir() { rbkp.run "$1" "rm -rf -- ${2@Q}"; }
rbkp.ln() { rbkp.run "$1" "ln -s -- ${2@Q} ${3@Q}"; }
rbkp.test_d() { rbkp.run "$1" "test -d ${2@Q}"; }
rbkp.test_f() { rbkp.run "$1" "test -f ${2@Q}"; }
rbkp.df_t() { rbkp.run "$1" "df --output=fstype ${2@Q} | head -n 2 | tail -n 1"; }

rbkp.src_test_e() { rbkp.run_src "$1" "test -e ${2@Q}"; }
rbkp.src_df_t() { rbkp.run_src "$1" "df --output=fstype ${2@Q} | head -n 2 | tail -n 1"; }

#1: Config dict name
rbkp.create_default_config() {
    [[ "${!1@a}" == A ]] || rbkp.crt "${FUNCNAME[0]}: Internal error."
    local -n _rc="$1"

    # Parse and read configs
    local -ra default_rsync_flags=(
        '-D' '--numeric-ids' '--links' '--hard-links' '--one-file-system'
        '--itemize-changes' '--times' '--recursive' '--perms'
        '--owner' '--group' '--stats' '--human-readable')

    _rc=(
        [PROG_NAME]=''
        [RSYNC_CMD]='rsync'
        # Backup configs
        [SRC_DIR]=''
        [DEST_DIR]=''
        [EXCL_FILE]=''
        [LOG_DIR]=''
        [AUTO_DELETE_LOG]=true
        [EXPIRATION_STRATEGY]='1:1 30:7 365:30'
        [RETENTION_POLICY]='1:7 7:8 30:12 365:999999'
        [USE_RETENTION]=''
        [AUTO_EXPIRE]=true
        [RSYNC_FLAGS]="${default_rsync_flags[*]}"
        [MARKER_NAME]='backup.marker'
        # Ssh configs
        [SSH_USER]=''
        [SSH_HOST]=''
        [SSH_DEST_DIR]=''
        [SSH_SRC_DIR]=''
        [SSH_CMD]=''
        [SSH_DEST_DIR_PREFIX]=''
        [SSH_SRC_DIR_PREFIX]=''
        [SSH_PORT]=''
        [ID_RSA]=''
    )

    _rc[PROG_NAME]=$(basename "$(realpath "${BASH_SOURCE[0]}")")
    _rc[PROG_NAME]="${_rc[PROG_NAME]%.sh}"
    _rc[LOG_DIR]="$HOME/.cache/${_rc[PROG_NAME]}"
}

# Parse arguments
# $1: Config dict name
# ${@:2}: Arguments to parse
# shellcheck disable=SC2178
rbkp.parse_args() {
    local -n _rc="$1" && shift
    local parsing_options=true
    while [[ "$#" -gt 0 ]]; do
        case $1 in
        -*) $parsing_options || rbkp.crt "No options allowed after '--'" ;;&
        -h | -\? | --help) rbkp.display_usage "$1" 0 ;;
        -p | --port) shift && _rc[SSH_PORT]="$1" ;;
        -i | --id-rsa) shift && _rc[ID_RSA]="$1" ;;
        -rgf | --rsync-get-flags) shift && echo "${_rc[RSYNC_FLAGS]}" && exit ;;
        -rsf | --rsync-set-flags) shift && _rc[RSYNC_FLAGS]="$1" ;;
        -raf | --rsync-append-flags) shift && _rc[RSYNC_FLAGS]="${_rc[RSYNC_FLAGS]} $1" ;;
        -nae | --no-auto-expire) _rc[AUTO_EXPIRE]=false ;;
        -s | --strategy)
            shift
            _rc[EXPIRATION_STRATEGY]="$1"
            _rc[USE_RETENTION]="${_RC[USE_RETENTION]:-false}"
            ;;
        -r | --retention)
            shift
            _rc[RETENTION_POLICY]="$1"
            _rc[USE_RETENTION]=true
            ;;
        -ld | --log-dir)
            shift
            _rc[LOG_DIR]="$1"
            _rc[AUTO_DELETE_LOG]=false
            ;;
        --) parsing_options=false ;;
        -*)
            rbkp.err "Unknown option: \"$1\""
            rbkp.display_usage "$1" 1
            ;;
        *) case "${_rc[SRC_DIR]:+.}${_rc[DEST_DIR]:+.}${_rc[EXCL_FILE]:+.}" in
            '') _rc[SRC_DIR]="$1" ;;
            '.') _rc[DEST_DIR]="$1" ;;
            '..') _rc[EXCL_FILE]="$1" ;;
            '...') rbkp.crt "Redundant argument '$1' not recognized." ;;
            esac ;;
        esac
        shift
    done
}

# Sanitize arguments
# $1: Config dict name
# shellcheck disable=SC2178
rbkp.sanitize_cfg() {
    local -n _rc="$1"
    # Source and dest folder must be provided
    [[ "${_rc[SRC_DIR]}" && "${_rc[DEST_DIR]}" ]] || rbkp.display_usage "$1" 1

    # Strips off last slash from dest. Note that it means the root folder "/"
    # will be represented as an empty string "", which is fine
    # with the current script (since a "/" is added when needed)
    # but still something to keep in mind.
    # However, due to this behavior we delay stripping the last slash for
    # the source folder until after parsing for ssh usage.
    _rc[DEST_DIR]="${_rc[DEST_DIR]%/}"

    # Parse ssh options
    local -r RE_USER='[A-Za-z0-9\._%\+\-]+' RE_ADDR='[A-Za-z0-9.\-]+'
    local loc=''
    for loc in SRC_DIR DEST_DIR; do
        [[ "${_rc["$loc"]}" =~ ^(($RE_USER)@)?($RE_ADDR):(.+)$ ]] || continue
        _rc[SSH_USER]="${BASH_REMATCH[2]}"
        _rc[SSH_HOST]="${BASH_REMATCH[3]}"
        _rc[SSH_"$loc"]="${BASH_REMATCH[4]}"
        _rc[SSH_CMD]="ssh ${_rc[SSH_PORT]:+"-p ${_rc[SSH_PORT]} "}"
        _rc[SSH_CMD]+="${_rc[ID_RSA]:+"-i ${_rc[ID_RSA]@Q} "}"
        _rc[SSH_CMD]+="${BASH_REMATCH[1]}${_rc[SSH_HOST]}"
        _rc[SSH_"$loc"_PREFIX]="${BASH_REMATCH[1]}${_rc[SSH_HOST]}:"
    done

    [[ -z "${_rc[SSH_DEST_DIR]}" ]] || _rc[DEST_DIR]="${_rc[SSH_DEST_DIR]}"
    [[ -z "${_rc[SSH_SRC_DIR]}" ]] || _rc[SRC_DIR]="${_rc[SSH_SRC_DIR]}"

    # Exit if source folder does not exist.
    rbkp.src_test_e "$1" "${_rc[SRC_DIR]}" ||
        rbkp.crt "Abort: Source folder ${_rc[SRC_DIR]@Q} does not exist."

    # Now strip off last slash from source folder.
    _rc[SRC_DIR]="${_rc[SRC_DIR]%/}"

    # Use retention policy by default
    _rc[USE_RETENTION]="${_rc[USE_RETENTION]:-true}"

    case "${_rc[USE_RETENTION]}" in
    false) # Sanitize expiration strategy (the old retention policy)
        while read -r pol; do
            [[ $pol ]] || continue
            [[ $pol =~ ^([1-9][[:digit:]]*):([1-9][[:digit:]]*)$ ]] ||
                rbkp.crt "Retention policy '$pol' not recognized."
        done < <(echo "${_rc[EXPIRATION_STRATEGY]}" | tr ' ' '\n')
        ;;
    true) # Sanitize retention policy
        local pol='' retention_cmd=''
        local -A retention=()
        while read -r pol; do
            [[ $pol ]] || continue
            [[ $pol =~ ^([1-9][[:digit:]]*):([1-9][[:digit:]]*)$ ]] ||
                rbkp.crt "Retention policy '$pol' not recognized."
            retention["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
        done < <(echo "${_rc[RETENTION_POLICY]}" | tr ' ' '\n')
        retention_cmd="$(typeset -p retention)"
        _rc[RETENTION_POLICY]="${retention_cmd#*retention=}"
        ;;
    esac
}

#1: Config variables dict name
#1: Session variables dict name
rbkp.create_default_session() {
    [[ "${!1@a}" == A ]] || rbkp.crt "${FUNCNAME[0]}: Internal error."

    local -n _rc="$1" _ss="$2"
    _ss=(
        [NOW]=''
        [DEST]=''
        [PREV_DEST]=''
        [INPROGRESS_FILE]="${_rc[DEST_DIR]}/backup.inprogress"
        [MYPID]="$$"
        [LINK_DEST]=''
        [LOG_FILE]=''
    )

    local -a backups=()
    rbkp.find_backups "$1" backups -r
    _ss[PREV_DEST]="${backups[0]}"

    local dest_stem=''
    sess[NOW]=$(date "+%s") || rbkp.crt "Failed to get current time."
    dest_stem=$(date +"%Y-%m-%d-%H%M%S" --date="@${sess[NOW]}")
    sess[DEST]="${_rc[DEST_DIR]}/$dest_stem"
    sess[LOG_FILE]="${_rc[LOG_DIR]}/$dest_stem.log"
}

# Check filesystems validity for backups
# $1: Config dict name
# $2: Session variable dict name
# shellcheck disable=SC2178
rbkp.check_filesystems() {
    local -n _rc="$1" _ss="$2"

    rbkp.test_f "$1" "${_rc[DEST_DIR]}/${_rc[MARKER_NAME]}" || {
        local info_cmd="${_rc[SSH_DEST_DIR_PREFIX]:+${_rc[SSH_CMD]} bash <<< }"
        info_cmd+="mkdir -p -- ${_rc[DEST_DIR]@Q}; "
        info_cmd+="touch ${_rc[DEST_DIR]@Q}/${_rc[MARKER_NAME]@Q};"
        rbkp.inf \
            "If it is intended as a backup folder, create the marker with:" \
            "$info_cmd"
        rbkp.crt "Abort: marker file not found."
    }

    # Check that the destination supports hard links
    rbkp.run "$1" "ln ${_rc[DEST_DIR]@Q}/${_rc[MARKER_NAME]@Q}{,_copy}" ||
        rbkp.crt "Destination folder ${_rc[SSH_DEST_DIR_PREFIX]}${_rc[DEST_DIR]@Q} doesn't support hard links."
    rbkp.rm_file "$1" "${_rc[DEST_DIR]}/${_rc[MARKER_NAME]}_copy"

    # Check source and destination file-system (df -T /dest).
    # If one of them is FAT, use the --modify-window rsync parameter
    # (see man rsync) with a value of 1 or 2.
    local src_fs_type='' dst_fs_type=''
    src_fs_type="$(rbkp.src_df_t "$1" "${_rc[SRC_DIR]}")"
    [[ ${src_fs_type,,} == *fat* ]] ||
        dst_fs_type="$(rbkp.df_t "$1" "${_rc[DEST_DIR]}")"
    [[ ${src_fs_type,,}${dst_fs_type,,} != *fat* ]] || {
        rbkp.inf "Source or destination file-system is a version of FAT."
        rbkp.inf "Using the --modify-window rsync parameter with value 2."
        _rc[RSYNC_FLAGS]+=" --modify-window 2"
    }
}

# Handle case where a previous backup failed or was interrupted.
# $1: Config dict name
# $2: Session variables dict name
rbkp.handle_previous_backup_failure() {
    local -n _rc="$1" _ss="$2"
    local pid='' grepcode=''

    rbkp.test_f "$1" "${_ss[INPROGRESS_FILE]}" || return

    # 1. Grab the PID of previous run from the PID file
    # 2. Get the command for the process currently running under that PID
    # 3. Grab the exit code from grep (0=found, 1=not found)
    # 4. if found, assume backup is still running
    case "$OSTYPE" in
    'cygwin')
        pid="$(rbkp.run "$1" "cat ${_ss[INPROGRESS_FILE]@Q}")"
        grepcode=$?
        [[ "$grepcode" -ne 0 ]] ||
            rbkp.crt "Abort: Previous backup task is still active."
        ;;
    *) # AFAIK both Linux and BSD implements procfs
        pid="$(rbkp.run "$1" "cat ${_ss[INPROGRESS_FILE]@Q}")"
        [[ ! -f "/proc/$pid/cmdline" ||
            "$(tr -d '\0' <"/proc/$pid/cmdline")" != *"${_rc[PROG_NAME]}"* ]] ||
            rbkp.crt "Abort: Previous backup task (PID=$pid) is still active."
        ;;
    esac

    # If no previous backup, just continue the current
    [[ "${_ss[PREV_DEST]}" ]] || return

    # Last backup is moved to current backup folder so that it can be resumed.
    rbkp.inf "${_rc[SSH_DEST_DIR_PREFIX]}${_ss[INPROGRESS_FILE]@Q} exists." \
        "The previous backup failed or was interrupted." \
        "Backup will resume from there."
    rbkp.run "$1" "mv -- ${_ss[PREV_DEST]@Q} ${_ss[DEST]@Q}"

    # 2nd to last backup becomes last backup.
    _ss[PREV_DEST]=''
    local -a backups=()
    rbkp.find_backups "$1" backups
    [ "${#backups[@]}" -le 1 ] || _ss[PREV_DEST]="${backups[-2]}"

    # Update PID to current process to avoid multiple concurrent resumes
    rbkp.run "$1" "echo ${_ss[MYPID]} >| ${_ss[INPROGRESS_FILE]@Q}"
}

# Parse the log file detect for rsync issues
# $1: The log file
# $2: Result dict name
rbkp.parse_rsync_log_file() {
    local -n _rr="$2"
    local line=''
    while read -r line; do
        case "$line" in
        *'No space left on device (28)'*) _rr[NO_SPACE]=true && break ;;
        *'Result too large (34)'*) _rr[NO_SPACE]=true && break ;;
        *'rsync error:'*) _rr[ISSUES]='error' && break ;;
        *'rsync:'*) _rr[ISSUES]='warning' && break ;;
        esac
    done <"$1"
}

# $1: Config dict name
# $2: Session variables dict name
rbkp.pre_backup() {
    local -n _rc="$1" _ss="$2"

    # Check if we are doing an incremental backup (if previous backup exists).
    _ss[LINK_DEST]=''
    [[ -n "${_ss[PREV_DEST]}" ]] || rbkp.inf "No previous backup - creating new one."
    [[ -z "${_ss[PREV_DEST]}" ]] || {
        # If the path is relative, it needs to be relative to the destination.
        # To keep it simple, just use an absolute path.
        # See http://serverfault.com/a/210058/118679
        _ss[PREV_DEST]="$(rbkp.abs_path "$1" "${_ss[PREV_DEST]}")"
        rbkp.inf "Previous backup found."
        rbkp.inf "Making incremental backup from ${_rc[SSH_DEST_DIR_PREFIX]}${_ss[PREV_DEST]@Q}"
        _ss[LINK_DEST]="${_ss[PREV_DEST]}"
    }

    # Create destination folder if it doesn't already exists
    rbkp.test_d "$1" "${_ss[DEST]}" || {
        rbkp.inf "Creating destination ${_rc[SSH_DEST_DIR_PREFIX]}${_ss[DEST]@Q}"
        rbkp.mkdir "$1" "${_ss[DEST]}"
    }

    # Purge certain old backups before beginning new backup.
    # But regardless of expiry strategy we keep backup used for --link-dest
    case "${_ss[PREV_DEST]}" in
    '') rbkp.expire_backups "$1" "$2" "${_ss[DEST]}" ;;
    *) rbkp.expire_backups "$1" "$2" "${_ss[PREV_DEST]}" ;;
    esac
}

# Start backup
# $1: Config dict name
# $2: Session variables dict name
# $3: Rsync result name
rbkp.do_backup() {
    local -n _rc="$1" _ss="$2"

    rbkp.inf "Starting backup..."
    rbkp.inf "  From: ${_rc[SSH_SRC_DIR_PREFIX]}${_rc[SRC_DIR]@Q}"
    rbkp.inf "  To:   ${_rc[SSH_DEST_DIR_PREFIX]}${_ss[DEST]@Q}"

    # local cmd="rsync"
    local -a args=()
    read -ra args < <(echo "${_rc[RSYNC_FLAGS]}")
    [[ -z "${_rc[SSH_CMD]}" ]] || {
        local ssh="ssh ${_rc[SSH_PORT]:+"-p ${_rc[SSH_PORT]} "}"
        ssh+="${_rc[ID_RSA]:+"-i ${_rc[ID_RSA]@Q} "}"
        ssh+="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
        args+=('--compress' '-e' "$ssh")
    }

    args+=('--log-file' "${_ss[LOG_FILE]}")

    [[ -z "${_rc[EXCL_FILE]}" ]] || args+=("--exclude-from" "${_rc[EXCL_FILE]}")
    [[ -z "${_ss[LINK_DEST]}" ]] || args+=('--link-dest' "${_ss[LINK_DEST]}")

    args+=("--" "${_rc[SSH_SRC_DIR_PREFIX]}${_rc[SRC_DIR]}/")
    args+=("${_rc[SSH_DEST_DIR_PREFIX]}${_ss[DEST]}")

    rbkp.inf "Running command:"
    rbkp.inf "${_rc[RSYNC_CMD]} ${args[*]@Q}"

    rbkp.run "$1" "echo ${_ss[MYPID]} >| ${_ss[INPROGRESS_FILE]@Q}"
    "${_rc[RSYNC_CMD]}" "${args[@]}"

    rbkp.parse_rsync_log_file "${_ss[LOG_FILE]}" "$3"
}

# Perform post-backup oeprations based on backup result
# $1: Config dict name
# $2: Session variables dict name
# $2: error|warning|none: rsync result status
rbkp.post_backup() {
    local -n _rc="$1" _ss="$2"

    case "$3" in
    error)
        rbkp.err "Rsync reported an error. " \
            "Run this command for more details: " \
            "grep -E 'rsync:|rsync error:' '${_ss[LOG_FILE]}'"
        return 1
        ;;
    warning)
        rbkp.wrn "Rsync reported a warning. " \
            "Run this command for more details: " \
            "grep -E 'rsync:|rsync error:' '${_ss[LOG_FILE]}'"
        return 1
        ;;
    none)
        rbkp.inf "Backup completed without errors."
        "${_rc[AUTO_DELETE_LOG]}" || rm -f -- "${_ss[LOG_FILE]:?}"
        # Create "last backup" symlink and remove .inprogress only on success
        rbkp.rm_file "$1" "${_rc[DEST_DIR]:?}/latest"
        rbkp.ln "$1" "$(basename -- "${_ss[DEST]}")" "${_rc[DEST_DIR]}/latest"
        rbkp.rm_file "$1" "${_ss[INPROGRESS_FILE]:?}"
        return 0
        ;;
    esac
}

# shellcheck disable=SC2034
rbkp.main() {
    # Check bash version
    [[ ${BASH_VERSINFO[0]}${BASH_VERSINFO[1]} -gt 50 ]] ||
        rbkp.crt "Requires bash>=5.0 to run this script."

    # Setup exit (Ctrl-C) Traps
    trap 'rbkp.inf "SIGINT caught."; exit 1' SIGINT

    local -A cfg=()
    rbkp.create_default_config cfg
    rbkp.parse_args cfg "$@"
    rbkp.sanitize_cfg cfg

    # Current backup session variables
    local -A sess=()
    rbkp.create_default_session cfg sess

    # Check that the destination drive is a backup drive
    rbkp.check_filesystems cfg sess

    # Create log folder
    [[ -d "${cfg[LOG_DIR]}" ]] ||
        rbkp.inf "Creating log folder '${cfg[LOG_DIR]}'..."
    mkdir -p -- "${cfg[LOG_DIR]}" ||
        rbkp.crt "Failed creating log dir '${cfg[LOG_DIR]}'"

    # Resume from failed backups
    rbkp.handle_previous_backup_failure cfg sess

    local -A rsync_result=([NO_SPACE]=false [ISSUES]='none')
    rbkp.pre_backup cfg sess
    rbkp.do_backup cfg sess rsync_result

    # Remove old backup and retry if no space left
    while ${rsync_result[NO_SPACE]}; do
        ${cfg[AUTO_EXPIRE]} ||
            rbkp.crt "Abort: No space left on device, auto purging is disabled."

        local -a backups=()
        rbkp.find_backups cfg backups
        [[ "${#backups[@]}" -ge 2 ]] ||
            rbkp.crt "Abort: No space left on device, and no backup to delete."

        rbkp.wrn "No space left on device - removing oldest backup ..."
        rbkp.expire_backup cfg "${backups[0]}"

        rbkp.pre_backup cfg sess
        rbkp.do_backup cfg sess rsync_result
    done
    rbkp.post_backup cfg sess "${rsync_result[ISSUES]}"
}

# Return 0 ensure that main function is not executed when script is sourced.
# shellcheck disable=SC2317
return 0 2>/dev/null || rbkp.main "$@"
