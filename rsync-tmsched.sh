#!/bin/bash
# shellcheck disable=SC2034
# Note: This script must be put in the same directory aside rsync-tmbackup.sh

# Log functions: Info / Warning / Error / Critical
rscd.__log() { local l='' && for l in "$@"; do echo "$l"$'\033[0m'; done; }
rscd.inf() { rscd.__log "${@/#/$'\033[92m'"II "$'\033[0m'}"; }
rscd.wrn() { rscd.__log "${@/#/$'\033[93m'"WW "}" 1>&2; }
rscd.err() { rscd.__log "${@/#/$'\033[91m'"EE "}" 1>&2; }
rscd.crt() { rscd.err "$@" && exit 1; }

# $1: log dir
# $2: log file stem
rscd.redirect_output_to_logs() {
    local log_dir="$1" log_stem="$2"
    # Don't create logs if log dir is not specified
    [[ "$log_dir" ]] || return 0

    # Create log directory
    [[ -d "$log_dir" ]] || mkdir -p -- "$log_dir" ||
        rscd.crt "Failed to create logging directory ${log_stem@Q}"

    # Create log files (append)
    : >>"$log_dir/$log_stem.log" ||
        rscd.crt "Failed to create ${log_dir@Q}/${log_stem@Q}.log"
    : >>"$log_dir/$log_stem.err" ||
        rscd.crt "Failed to create ${log_dir@Q}/${log_stem@Q}.err"

    # Redirect outputs
    exec \
        1> >(tee -a "$log_dir/$log_stem.log") \
        2> >(tee -a "$log_dir/$log_stem.err")
}

# $1: Config file variable name
# ${@:2}: Arguments
rscd.parse_args() {
    local -n _rr="$1" && shift
    case "$1" in
    -c | --config) shift && _rr="$1" ;;
    *) rscd.crt "Usage: $PROG_NAME -c <config-file>" && return 1 ;;
    esac
}

# $1: Config file name
# $2: Variable name to store the command to locally define configs variables
rscd.read_config_file() {
    local config_file="$1"
    local -n _rr="$2"
    [[ -f "$config_file" ]] || rscd.crt "Config ${config_file@Q} not found"

    # Run in subshell to prevent pollution
    _rr="$( # shellcheck source=rsync-tmsched-conf-example.sh
        source "$config_file" 1>&2 || exit 1

        # Define variables
        [[ ! -v RSCD_LOG_DIR ]] || {
            __cmd="$(typeset -p RSCD_LOG_DIR)"
            echo "local RSCD_LOG_DIR=${__cmd#*"RSCD_LOG_DIR="}"
        }

        # Define sched_* and notify function
        while read -r _ _ c_name; do
            [[ "$c_name" == sched_* || "$c_name" == notify ]] || continue
            typeset -fp "$c_name" >/dev/null 2>&1 ||
                rscd.crt "'${c_name}' is not a function."
            __cmd="$(typeset -fp "$c_name")"
            echo "__rscd_${c_name}${__cmd#*"${c_name}"}"
        done < <(typeset -F)

        # Define conf_*
        for c_name in "${!conf_@}"; do
            declare -n __c_dict="$c_name"
            [[ "${__c_dict@a}" == A ]] || rscd.crt "'$c_name' must be a dict."
            [[ "${__c_dict[src]}" ]] || rscd.crt "'${c_name}[src]' not defined."
            [[ "${__c_dict[dst]}" ]] || rscd.crt "'${c_name}[dst]' not defined."
            [[ -z "${__c_dict[sched]}" ]] ||
                typeset -fp "sched_${__c_dict[sched]}" >/dev/null 2>&1 ||
                rscd.crt "'${c_name}[sched]': 'sched_${__c_dict[sched]}' not defined."
            __cmd="$(typeset -p "$c_name")"
            echo "local -A __rscd_${c_name}${__cmd#*"${c_name}"}"
        done

        # Define excl_*
        for c_name in "${!excl_@}"; do
            declare -n __c_arr="$c_name"
            [[ "${__c_arr@a}" == a ]] || rscd.crt "'$c_name' must be an array."
            [[ -v "conf_${c_name#excl_}[src]" ]] ||
                rscd.crt "'${c_name}': 'conf_${c_name#excl_}' not defined."
            __cmd="$(typeset -p "$c_name")"
            echo "local -a __rscd_${c_name}${__cmd#*"${c_name}"}"
        done
    )" || {
        rscd.crt "Failed parsing config file ${config_file@Q}."
        return 1
    }
}

# $1: Config dict name
# $2: Exclude array name
# $3: exclude file
# $4: Result args array name
rscd.gen_rbkp_args() {
    local -n _rc="$1" _rr="$4"
    local e_file="$3"
    # Generate prerequisites and params

    # 1. Generate options
    local option=''
    for option in "${!_rc[@]}"; do
        [[ ! $option =~ ^(src|dst|sched)$ ]] || continue
        _rr+=("$option" "${_rc["$option"]}")
    done

    # 2. Generate src, dst
    _rr+=("${_rc[src]}" "${_rc[dst]}")

    # 3. Genrate exclude-file (if provided)
    [[ -v "$2" ]] || return 0
    local -n e_list="$2"
    # shellcheck disable=SC2064
    (IFS=$'\n' && echo "${e_list[*]}" >|"$e_file")
    _rr+=("$e_file")
}

rscd.main() {
    local HERE='' RBKP='' PROG_NAME='' EXCL_FILE=''
    PROG_NAME="$(basename "$(realpath "${BASH_SOURCE[0]}")")" || return 1
    HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)" || return 1
    RBKP="$HERE/rsync-tmbackup.sh"

    # Parse arguments and read config file
    local config_file=''
    rscd.parse_args config_file "$@" || return
    local cfg_cmds=''
    rscd.read_config_file "$config_file" cfg_cmds || return
    # Define configs in this shell
    local RSCD_LOG_DIR=''
    eval "$cfg_cmds"
    # Redirect outputs
    rscd.redirect_output_to_logs "$RSCD_LOG_DIR" "${PROG_NAME%.sh}"

    # Nodify the start of this script
    local start_time="${EPOCHSECONDS:-0}"
    rscd.inf $'\033[92m'"[$(date -d "@$start_time" '+%F %T')] >>> $PROG_NAME started"$'\033[0m'
    # Create temporary exclusion list file
    EXCL_FILE="$(mktemp)" || rscd.crt "Failed to create temporary file."
    trap 'rm -f ${EXCL_FILE@Q}; trap - RETURN;' RETURN

    [[ -e "$RBKP" ]] || rscd.crt "$RBKP not found."
    [[ -x "$RBKP" ]] || rscd.crt "$RBKP is not executable."

    local success=true
    local -a configs=()
    mapfile -t configs < <(
        for c_name in "${!__rscd_conf_@}"; do
            printf "%s\n" "$c_name"
        done | sort
    )
    for c_name in "${configs[@]}"; do
        rscd.inf "Processing "$'\033[1m'"${c_name#__rscd_conf_}"$'\033[0m'

        # Test whether backup today
        local -n c_dict="$c_name"
        [[ -z "${c_dict[sched]}" ]] || ("__rscd_sched_${c_dict[sched]}") || {
            rscd.inf "Not today: skipping '$c_name'"
            continue
        }

        # Generate arguments
        local -a args=()
        rscd.gen_rbkp_args \
            "$c_name" "__rscd_excl_${c_name#__rscd_conf_}" "$EXCL_FILE" args

        # Perform backup
        rscd.inf "Running $RBKP ${args[*]@Q}"
        "$RBKP" "${args[@]}"
        local ret_code="$?"
        [[ "$ret_code" -eq 0 ]] || success=false

        # Notification
        ! typeset -fp __rscd_notify >/dev/null 2>&1 || {
            rscd.inf "Notify \$1=${ret_code}, \$2=${c_name#__rscd_conf_}"
            (__rscd_notify "$ret_code" "${c_name#__rscd_conf_}")
        } || rscd.err "Notification command failed."
    done
    local COLOR=$'\033[92m' && "$success" || COLOR=$'\033[93m'
    local end_time="${EPOCHSECONDS:-0}" total_time=''
    total_time="$(date -d "@$((end_time - start_time))" -u '+%Hh %Mm %Ss')"
    rscd.inf "$COLOR""[$(date -d "@$end_time" '+%F %T')] <<< $PROG_NAME finished (total $total_time)"$'\033[0m'
    "$success"
}

# Debug and bashcov compatibility
[[ $- != *x* ]] || set +e
# Don't execute backup if sourced
# shellcheck disable=SC2317
return 0 2>/dev/null || rscd.main "$@"
