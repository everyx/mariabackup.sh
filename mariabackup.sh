#!/bin/bash

#
# /backup/
# ├── <full_1>/
# │   ├── backup.mb.xz
# │   ├── xtrabackup_checkpoints
# │   ├── xtrabackup_info
# │   ├── <incr_1>/
# │   │   └── backup.mb.xz
# │   .
# │   └── <incr_n>/
# │       └── backup.mb.xz
# .
# └── <full_n>/

__version=v0.1.0

ProgName=$(basename "$0")

DEBUG=0
INFO=1
WARN=2
ERROR=3

__log_level=${MYSQL_BACKUP_LOG_LEVEL:-${INFO}}

function set_log_level() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    case $1 in
    "$DEBUG" | "debug")
        __log_level=$DEBUG
        ;;
    "$INFO" | "info")
        __log_level=$INFO
        ;;
    "$WARN" | "warn")
        __log_level=$WARN
        ;;
    "$ERROR" | "error")
        __log_level=$ERROR
        ;;
    esac
}

function log_level_name() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    case $1 in
    "$DEBUG")
        echo "DEBUG"
        ;;
    "$INFO")
        echo "INFO"
        ;;
    "$WARN")
        echo "WARN"
        ;;
    "$ERROR")
        echo "ERROR"
        ;;
    esac
}

function log() {
    local level=$1
    shift
    local message=$*

    if [[ "$level" -ge "$__log_level" ]]; then
        local datetime
        datetime=$(date +"%Y-%m-%d %H:%M:%S")
        level_name=$(log_level_name "$level")
        if [[ "$level" -ge $WARN ]]; then
            echo -e "[$datetime] [$level_name] $message" >&2
        else
            echo -e "[$datetime] [$level_name] $message" >&1
        fi
    fi
}

function show_help_general_options() {
    echo ""
    echo "options:"
    echo "  -h, --help              show this help message and exit"
    echo "  -v, --version           show program's version number and exit"
    echo "  -d, --debug             show debug messages"
    echo "  --loglevel LOGLEVEL, -l LOGLEVEL"
    echo "                          level of log messages to capture (one of debug, info, warn, error). Default:"
    echo "                          info"
    echo "  mariadb connection options"
    echo "  --host                  mysql hostname. Default:"
    echo "                              'MYSQL_HOST' env variable used by default, 'localhost' used if not set"
    echo "  --port                  mysql port. Default:"
    echo "                              'MYSQL_PORT' env variable used by default, '3306' used if not set"
    echo "  --user                  mysql user. Default:"
    echo "                              'MYSQL_USER' env variable used by default, 'root' used if not set"
    echo "  --password              mysql password. Default: 'MYSQL_PASSWORD' env variable"
}

function show_help() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: $ProgName [options] <command> [<args>]"
        echo ""
        echo "Create full/incremental backups or restore them with mariabackup"
        echo ""
        echo "command:"
        echo "  backup                  create a new backup"
        echo "  restore                 restore from a backup"
        show_help_general_options
    else
        subcommand=$1
        shift
        eval "show_help_${subcommand}" 2>/dev/null
        if [ $? = 127 ]; then
            echo "Unkow command: '$subcommand' or it's help message not avaiable." >&2
            exit 1
        fi
    fi
}

function exit_unknow_optarg() {
    echo "Unknown option or argument: '$1'" >&2
    echo "Use -h or --help for help" >&2
    exit 1
}

__mysql_host=${MYSQL_HOST:-localhost}
__mysql_port=${MYSQL_PORT:-3306}
__mysql_user=${MYSQL_USER:-root}
__mysql_password=${MYSQL_PASSWORD}

function __mysql_conn_opt() {
    cmd="--host=${__mysql_host} --port=${__mysql_port} --user=${__mysql_user}"
    if [[ $__mysql_password != "" ]]; then
        cmd="$cmd --password=${__mysql_password}"
    fi
    echo "$cmd"
    return 0
}

# Checks if the daemon is listening
function check_daemon() {
    log $DEBUG "Checking daemon..."
    eval "mariadb --execute=quit $(__mysql_conn_opt)" &>/dev/null
    return $?
}

function show_help_backup() {
    echo "Usage: $ProgName [options] backup [<args>]"
    echo ""
    echo "Create full/incremental backups with mariabackup"
    echo ""
    echo "args:"
    echo "  --full                  full backup"
    echo "  --incr                  incremental backup (on top of most recent full backup)"
    show_help_general_options
}

__backup_root_dir=$(realpath -m "${MYSQL_BACKUP_ROOT:-/backup}")
__backup_threads=${MYSQL_BACKUP_THREADS:-1}
__backup_name_format="%Y-%m-%d_%H-%M-%S"
__backup_name_pattern=".*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$"

# enable compress or not, default enable
__compress=${MYSQL_BACKUP_COMPRESS:-1}
__compress_target_file=backup.mb.xz

function most_recent_backup() {
    base_dir="${__backup_root_dir}"
    if [[ $# -gt 0 ]]; then
        base_dir=$(realpath -m "/$1")
    fi

    find "$base_dir" \
        -mindepth 1 -maxdepth 1 -type d ! -empty \
        -regextype posix-extended -regex "$__backup_name_pattern" \
        -printf '%T@ %p\n' | sort -n | tail -1 | awk '{print $2}'

    return 0
}

function new_backup() {
    base_dir="${__backup_root_dir}"
    if [[ $# -gt 0 ]]; then
        base_dir=$(realpath -m "/$1")
    fi

    backup_dir="$base_dir/$(date +${__backup_name_format})"

    echo "$backup_dir"
}

function purge() {
    i=0

    # Purge old backups.
    days=${MYSQL_BACKUP_KEEP_DAYS:-0}
    if [[ $days -gt 0 ]]; then
        log $DEBUG "- Retention policy (days): $days"

        cmd="find \"$__backup_root_dir\" -mindepth 1 -maxdepth 1 -type d -ctime +$days"

        days_count=$(eval "$cmd | wc -l") && i=$((i + days_count))

        eval "$cmd -exec rm -rf {} \;"
    fi

    # Purge extra backups.
    n=${MYSQL_BACKUP_KEEP_N:-0}
    if [[ $n -gt 0 ]]; then
        log $DEBUG "- Retention policy (n): $n"

        cmd="get_backups '$__backup_root_dir' | head -n-$n"

        n_count=$(eval "$cmd | wc -l") && i=$((i + n_count))

        eval "$cmd | xargs rm -rf"
    fi

    log $INFO "Purged $i full backups"
}

function run_backup() {
    if ! check_daemon; then
        log $WARN "Daemon is NOT listening, skipping backup."
        exit 1
    fi

    log $DEBUG "Starting backup..."

    cmd="mariabackup --backup --parallel=${__backup_threads} $(__mysql_conn_opt)"

    full_backup=1

    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in
        --full)
            full_backup=1
            shift
            ;;
        --incr)
            full_backup=0
            shift
            ;;
        *)
            full_backup=1
            ;;
        esac
    done

    if [[ $full_backup = 1 ]]; then
        log $DEBUG '- Mode: "FULL"'

        target_dir=$(new_backup)
        cmd="$cmd --target-dir=$target_dir"
    else
        log $DEBUG '- Mode: "INCR"'

        incr_root_dir=$(most_recent_backup)
        target_dir=$(new_backup "$incr_root_dir")

        incremental_basedir=$(most_recent_backup "$incr_root_dir")
        if [[ -z "$incremental_basedir" ]]; then
            incremental_basedir=$incr_root_dir
        fi

        cmd="$cmd --target-dir=$target_dir --incremental-basedir=$incremental_basedir"
    fi

    log $DEBUG "- Target: \"$target_dir\""

    # compress
    if [[ $__compress -eq 1 ]]; then
        target_file="$target_dir/$__compress_target_file"
        cmd="$cmd --extra-lsndir=$target_dir --stream=mbstream | xz >$target_file"
    fi

    log $DEBUG "- CMD: \"$cmd\""
    mkdir -p "$target_dir" && output=$(eval "$cmd" 2>&1)

    # If file xtrabackup_checkpoints not exist, backup command run failed, remove this backup
    if [[ ! -f "$target_dir/xtrabackup_checkpoints" ]]; then
        # shellcheck disable=SC2001
        log $ERROR "- Error:\n$(echo "$output" | sed 's/^/\t\t\t\t/')"
        rm -rf "$target_dir"
        exit 1
    fi

    if [[ $full_backup = 1 ]]; then
        log $INFO "full backup $target_dir completed."
    else
        log $INFO "incr backup $target_dir completed."
    fi

    purge

    return 0
}

function show_help_restore() {
    echo "Usage: $ProgName [options] restore [<args>] [path]"
    echo ""
    echo "Restore a backup with mariabackup"
    echo ""
    echo "path:                     data restore path. Default:"
    echo "                              'MYSQL_RESTORE_DIR' env variable used by default, '/data' used if not set"
    echo "args:"
    echo "  --name                  backup name. Default: the most recent one if not specified"
    show_help_general_options
}

function get_backups() {
    backup=$(realpath -m "/$1")

    find "$backup" \
        -mindepth 1 -maxdepth 1 -type d ! -empty \
        -regextype posix-extended -regex "$__backup_name_pattern" \
        -printf '%T@ %p\n' | sort -n | awk '{print $2}'

    return 0
}

function prepare() {
    target_dir=$1
    backup_dir=$2
    incremental_dir=$3

    debug_msg="- preparing: $(basename "$backup_dir")"
    if [[ "$incremental_dir" != "" ]]; then
        debug_msg="$debug_msg > $(basename "$incremental_dir")(incr)"
    fi
    log $DEBUG "$debug_msg"

    cmd="mariabackup --prepare --target-dir='$target_dir'"

    compress_file="$backup_dir/$__compress_target_file"
    if [[ -f $compress_file ]] && [[ -z $(ls -A "$target_dir") ]]; then
        xz -d "${compress_file}" -c | mbstream -x -C "$target_dir"
    fi

    if [[ "$incremental_dir" != "" ]]; then
        compress_file="$incremental_dir/$__compress_target_file"
        incr_target_dir=$target_dir/$(basename "$incremental_dir") && mkdir -p "$incr_target_dir"
        if [[ -f $compress_file ]] && [[ -z $(ls -A "$incr_target_dir") ]]; then
            xz -d "${compress_file}" -c | mbstream -x -C "$incr_target_dir"
        fi
        cmd="$cmd --incremental-dir='$incr_target_dir'"
    fi

    if ! output=$(eval "$cmd" 2>&1); then
        # shellcheck disable=SC2001
        log $ERROR "- Error:\n$(echo "$output" | sed 's/^/\t\t\t\t/')"
        exit 1
    fi

    if [[ "$incremental_dir" != "" ]]; then
        rm -rf "$incr_target_dir"
    fi

    return 0
}

__mysql_restore_dir=${MYSQL_RESTORE_DIR:-"/data"}

function run_restore() {
    if check_daemon; then
        log $WARN "Daemon is listening, please stop it before attempting a restore."
        exit 1
    fi

    log $DEBUG "Preparing backup..."

    backup_dir=$(most_recent_backup)

    while [[ $# -gt 0 ]]; do
        key="$1"

        case $key in
        --name)
            backup_dir="$__backup_root_dir/$2"
            shift 2
            ;;
        --name=*)
            backup_dir="$__backup_root_dir/${1#*=}"
            shift
            ;;
        *)
            __mysql_restore_dir=$1
            shift
            ;;
        esac
    done

    target_dir="$(mktemp -d)"

    prepare "$target_dir" "$backup_dir"

    readarray incrs < <(get_backups "$backup_dir")
    for incremental_dir in "${incrs[@]}"; do
        incremental_dir=$(echo "$incremental_dir" | tr -d '\n')
        prepare "$target_dir" "$backup_dir" "$incremental_dir"
    done

    log $DEBUG "Starting restore..."

    if [[ -d "${__mysql_restore_dir}" ]]; then
        local restore_backup_dir
        restore_backup_dir=${__mysql_restore_dir}.bak.$(date +"%Y%m%d%H:%M:%S")
        log $INFO "restore dir ${__mysql_restore_dir} exist, backup to ${restore_backup_dir} ..."
        rsync -a --delete "${__mysql_restore_dir}" "${restore_backup_dir}"
        rm -rf "${__mysql_restore_dir:?}/"*
    fi

    cmd="mariabackup --copy-back --target-dir=\"$target_dir\" --datadir=\"$__mysql_restore_dir\""

    log $DEBUG "- CMD: \"$cmd\""
    if ! output=$(eval "$cmd" 2>&1); then
        # shellcheck disable=SC2001
        log $ERROR "- Error:\n$(echo "$output" | sed 's/^/\t\t\t\t/')"
        exit 1
    fi

    log $INFO "restore $backup_dir completed."

    return 0
}

while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    -h | --help)
        show_help
        exit 0
        ;;
    -d | --debug)
        set_log_level $DEBUG
        shift
        ;;
    -v | --version)
        echo $__version
        shift
        ;;
    -l | --loglevel)
        set_log_level "$2"
        shift 2
        ;;
    -l=* | --loglevel=*)
        set_log_level "${1#*=}"
        shift
        ;;
    --host)
        __mysql_host="$2"
        shift 2
        ;;
    --host=*)
        __mysql_host="${1#*=}"
        shift
        ;;
    --port)
        __mysql_port="$2"
        shift 2
        ;;
    --port=*)
        __mysql_port="${1#*=}"
        shift
        ;;
    --user)
        __mysql_user="$2"
        shift 2
        ;;
    --user=*)
        __mysql_user="${1#*=}"
        shift
        ;;
    --password)
        __mysql_password="$2"
        shift 2
        ;;
    --password=*)
        __mysql_password="${1#*=}"
        shift
        ;;
    --*)
        exit_unknow_optarg "$1"
        ;;
    *)
        command=$1
        shift
        while [[ $# -gt 0 ]]; do
            case $1 in
            -h | --help)
                show_help "$command"
                shift
                exit 0
                ;;
            *)
                break
                ;;
            esac
        done
        "run_${command}" "$@"
        if [ $? = 127 ]; then
            echo "Unknown command: '$1'" >&2
            echo "Use -h or --help for a list of known commands." >&2
            exit 1
        fi
        exit $?
        ;;
    esac
done
