#!/usr/bin/env bash

VERSION=6.0.0
DRY_RUN=0 YES=0 QUIET=0 CHECK_ONLY=0 EXPLICIT=0
NO_ANIMATION=0 ELEVATED=0
CONFIG_FILE='' LOG_FILE=''
KERNELS_TO_KEEP=3 JOURNAL_VACUUM_TIME=14d JOURNAL_VACUUM_SIZE=1G MIN_DISK_SPACE_MB=2048
SELECTED=() ENABLED=() DISABLED=()
PRESET=''

usage() {
    cat <<'HELP'
Fedorable — a little upkeep for Fedora.

Usage: ./fedorable.sh [mode] [options]

With no arguments, opens a terminal menu. Nothing runs before confirmation.

Modes:
  --recommended         Fedora updates plus light upkeep: downloaded package
                        cache, expired temp files and TRIM; no package removal
  --cleanup             Basic cleanup: unused packages, caches, older kernels, logs, temp files,
                        unused Flatpak runtimes and TRIM; no updates
  --updates             Update Fedora packages and system Flatpak apps
  --full                Advanced: update + complete cleanup
  --tasks NAME,NAME     Run exactly these tasks (see --list-tasks)
  --none                Start with no tasks; add individual --task flags
  --check-only          Only check package updates; no maintenance tasks

Compatibility: --minimal updates Fedora packages only.

Options:
  --dry-run             Print commands; no writes, network calls or root needed
  -y, --yes             Confirm the displayed maintenance plan automatically
  -q, --quiet           Hide banner/progress; keep command output and errors
  --no-animation        Show the logo instantly
  --config FILE         Read a validated key=value configuration file
  --list-tasks          List task names
  -h, --help            Show help
  --version             Show version

Each task accepts --NAME and --no-NAME, for example --journal or --no-kernels.
Individual switches override presets regardless of their position.
If both enable and disable are supplied for a task, disable wins.

Examples:
  ./fedorable.sh --cleanup --dry-run
  sudo ./fedorable.sh --updates
  sudo ./fedorable.sh --tasks journal,temp --yes
  ./fedorable.sh --check-only
HELP
}

valid_task() {
    local item
    for item in "${TASKS[@]}"; do [[ $item == "$1" ]] && return 0; done
    return 1
}

normalize_selection() {
    local name
    local -A chosen=()
    for name in "${SELECTED[@]}" "${ENABLED[@]}"; do chosen[$name]=1; done
    for name in "${DISABLED[@]}"; do unset 'chosen[$name]'; done
    SELECTED=()
    for name in "${TASKS[@]}"; do [[ ${chosen[$name]:-0} == 1 ]] && SELECTED+=("$name"); done
    return 0
}

select_csv() {
    local input=$1 task
    local -a parsed
    [[ -n $input && $input != ,* && $input != *, && $input != *,,* ]] || {
        fail 'Provide task names separated by commas.'; return 1;
    }
    IFS=, read -r -a parsed <<< "$input"
    for task in "${parsed[@]}"; do
        valid_task "$task" || { fail "Unknown task: $task (see --list-tasks)"; return 1; }
    done
    SELECTED=("${parsed[@]}")
    normalize_selection
}

set_preset() {
    case "$1" in
        minimal) SELECTED=(update) ;;
        updates) SELECTED=(update flatpak) ;;
        cleanup) SELECTED=(clean-dnf autoremove kernels journal temp clean-flatpak thumbnails coredumps trim) ;;
        recommended) SELECTED=(update clean-dnf temp trim) ;;
        full) SELECTED=(update flatpak clean-dnf autoremove kernels journal temp clean-flatpak thumbnails coredumps trim) ;;
        none) SELECTED=() ;;
    esac
}

parse_args() {
    local arg name csv='' mode_count=0
    while (( $# )); do
        arg=$1
        case "$arg" in
            -h|--help) usage; return 10 ;;
            --version) printf '%s\n' "$VERSION"; return 10 ;;
            --list-tasks) list_tasks; return 10 ;;
            --cleanup|--updates|--full|--minimal|--recommended|--none)
                PRESET=${arg#--}; mode_count=$((mode_count + 1)); EXPLICIT=1 ;;
            --tasks)
                (( $# >= 2 )) || { fail '--tasks needs a value.'; return 1; }
                csv=$2; shift; mode_count=$((mode_count + 1)); EXPLICIT=1
                [[ -n $csv ]] || { fail '--tasks cannot be empty.'; return 1; } ;;
            --all) fail '--all has been retired. Use --full or --tasks.'; return 1 ;;
            --check-only) CHECK_ONLY=1 ;;
            --dry-run) DRY_RUN=1 ;;
            -y|--yes) YES=1 ;;
            -q|--quiet) QUIET=1 ;;
            --no-animation) NO_ANIMATION=1 ;;
            --elevated) ELEVATED=1 ;;
            --config)
                (( $# >= 2 )) || { fail '--config needs a file.'; return 1; }
                CONFIG_FILE=$2; shift
                [[ -n $CONFIG_FILE ]] || { fail '--config cannot be empty.'; return 1; } ;;
            --*)
                name=${arg#--}; name=${name#no-}
                valid_task "$name" || { fail "Unknown option: $arg (see --help)"; return 1; }
                EXPLICIT=1
                if [[ $arg == --no-* ]]; then DISABLED+=("$name"); else ENABLED+=("$name"); fi ;;
            *) fail "Unexpected argument: $arg"; return 1 ;;
        esac
        shift
    done
    (( mode_count <= 1 )) || { fail 'Choose one mode: --cleanup, --updates, --full, --none or --tasks.'; return 1; }
    if (( CHECK_ONLY && EXPLICIT )); then
        fail '--check-only cannot be combined with maintenance task selection.'; return 1
    fi
    if [[ -n $csv ]]; then select_csv "$csv" || return 1
    elif [[ -n $PRESET ]]; then set_preset "$PRESET"
    elif (( ${#DISABLED[@]} > 0 && ${#ENABLED[@]} == 0 )); then
        fail 'Skip flags need a preset or enabled tasks, e.g. --cleanup --no-kernels.'; return 1
    fi
    normalize_selection
}

load_config() {
    local line key value number=0
    [[ -n $CONFIG_FILE ]] || return 0
    [[ -f $CONFIG_FILE && -r $CONFIG_FILE ]] || { fail "Cannot read config: $CONFIG_FILE"; return 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        [[ $line =~ ^[[:space:]]*(#.*)?$ ]] && continue
        if [[ ! $line =~ ^([A-Z_]+)=([^[:space:]]+)$ ]]; then
            fail "Config line $number: expected KEY=value without spaces or quotes."; return 1
        fi
        key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        case "$key" in
            KERNELS_TO_KEEP)
                [[ $value =~ ^([2-9]|[1-9][0-9])$ ]] || { fail 'KERNELS_TO_KEEP must be 2–99.'; return 1; } ;;
            MIN_DISK_SPACE_MB)
                [[ $value =~ ^[1-9][0-9]{2,6}$ ]] || { fail 'MIN_DISK_SPACE_MB must be 100–9999999.'; return 1; } ;;
            JOURNAL_VACUUM_TIME)
                [[ $value =~ ^[1-9][0-9]{0,3}[dw]$ ]] || { fail 'Journal age needs a positive day/week value, e.g. 14d.'; return 1; } ;;
            JOURNAL_VACUUM_SIZE)
                [[ $value =~ ^[1-9][0-9]{0,3}[MG]$ ]] || { fail 'Journal size needs a positive M/G value, e.g. 1G.'; return 1; } ;;
            *) fail "Unknown config key: $key"; return 1 ;;
        esac
        printf -v "$key" '%s' "$value"
    done < "$CONFIG_FILE"
}

check_platform() {
    local ID='' VARIANT_ID=''
    [[ -r /etc/os-release ]] || { fail 'Cannot identify this operating system.'; return 1; }
    read -r ID VARIANT_ID < <(source /etc/os-release && printf '%s %s\n' "${ID:-}" "${VARIANT_ID:-}")
    [[ $ID == fedora ]] || { fail 'Fedorable supports Fedora Linux.'; return 1; }
    if [[ -e /run/ostree-booted || $VARIANT_ID == coreos ]]; then
        fail 'Atomic/OSTree Fedora needs its own update workflow; this tool targets DNF-based Fedora.'
        return 1
    fi
}

check_updates() {
    local rc=0
    require_command dnf || return 1
    heading 'Checking Fedora package updates'
    run_command dnf check-update || rc=$?
    case "$rc" in
        0) (( DRY_RUN )) || say 'Your packages are up to date.' ;;
        100) say 'Updates are available. Run --minimal to install them.' ;;
        *) fail "Update check failed (exit $rc)."; return 1 ;;
    esac
    return 0
}

elevate() {
    local tasks
    local -a args
    require_command sudo || { fail 'Root access is needed. Run this command again as root, or add --dry-run.'; return 1; }
    printf -v tasks '%s,' "${SELECTED[@]}"
    args=(--elevated --yes --tasks "${tasks%,}")
    (( QUIET )) && args+=(--quiet)
    [[ -z $CONFIG_FILE ]] || args+=(--config "$(readlink -f -- "$CONFIG_FILE")")
    say ''
    say "${YELLOW}These tasks need root access. sudo will ask for your password.${RESET}"
    exec sudo -- "$FEDORABLE_ROOT/fedorable.sh" "${args[@]}"
}

prepare_run() {
    (( EUID == 0 )) || elevate || return 1
    require_command flock || return 1
    umask 077
    exec 9>/run/fedorable.lock || return 1
    flock -n 9 || { fail 'Another Fedorable run is active.'; return 1; }
    mkdir -p /var/log/fedorable || return 1
    LOG_FILE=$(mktemp /var/log/fedorable/run-XXXXXXXX.log) || return 1
    printf 'Fedorable %s | %s\nTasks: %s\n' "$VERSION" "$(date -Is)" "${SELECTED[*]}" >> "$LOG_FILE"
    trap 'printf "\nInterrupted. Review the log before retrying: %s\n" "$LOG_FILE" >&2; exit 130' INT
    trap 'printf "\nStopped. Log: %s\n" "$LOG_FILE" >&2; exit 143' TERM
}

main() {
    local rc=0 answer
    parse_args "$@" || rc=$?
    (( rc == 10 )) && return 0
    (( rc == 0 )) || return "$rc"
    setup_ui
    load_config || return 1
    (( ELEVATED )) || banner
    if (( ! EXPLICIT && ! CHECK_ONLY )); then
        [[ -t 0 && -t 1 ]] || { fail 'Choose --cleanup, --updates, --full, --tasks or --check-only for non-interactive use.'; return 1; }
        menu || rc=$?
        (( rc == 2 )) && return 0
        (( rc == 0 )) || return "$rc"
    fi
    check_platform || return 1
    if (( CHECK_ONLY )); then check_updates; return $?; fi
    if (( ${#SELECTED[@]} == 0 )); then say 'No tasks selected. Nothing to do.'; return 0; fi
    (( ELEVATED )) || show_plan
    if (( ! DRY_RUN )); then
        if (( ! YES )); then
            [[ -t 0 ]] || { fail 'Non-interactive maintenance requires --yes. Preview with --dry-run first.'; return 1; }
            read -r -p "  ${CYAN}Run this plan? [y/N]:${RESET} " answer || return 1
            case "$answer" in y|Y|yes|YES) ;; *) say 'All right, nothing changed.'; return 0 ;; esac
        fi
        prepare_run || return 1
    fi
    execute_tasks
}
