#!/usr/bin/env bash

TASKS=(update flatpak clean-dnf autoremove kernels journal temp clean-flatpak thumbnails coredumps trim boot-report failed)

task_label() {
    case "$1" in
        update) printf 'Update Fedora packages' ;;
        autoremove) printf 'Remove packages DNF marks as unused' ;;
        clean-dnf) printf 'Clear downloaded DNF packages' ;;
        kernels) printf 'Remove older kernels' ;;
        journal) printf 'Rotate and trim system logs' ;;
        temp) printf 'Clean expired temporary files using system rules' ;;
        flatpak) printf 'Update system Flatpak apps' ;;
        clean-flatpak) printf 'Remove unused system Flatpak runtimes' ;;
        thumbnails) printf 'Clear the desktop thumbnail cache' ;;
        coredumps) printf 'Clean expired system coredumps' ;;
        trim) printf 'TRIM supported filesystems' ;;
        boot-report) printf 'Show boot time and the critical service chain' ;;
        failed) printf 'Clear failed systemd unit status (does not fix services)' ;;
    esac
}

list_tasks() {
    local task
    for task in "${TASKS[@]}"; do printf '  %-12s %s\n' "$task" "$(task_label "$task")"; done
}

run_command() {
    local shown rc=0
    printf -v shown '%q ' "$@"
    say "${DIM}\$ ${shown% }${RESET}"
    (( DRY_RUN )) && return 0
    if [[ -n $LOG_FILE ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE" || rc=$?
    else
        "$@" || rc=$?
    fi
    return "$rc"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || { fail "Required command not found: $1"; return 1; }
}

check_space() {
    local available
    available=$(available_mib) || { fail 'Could not read free disk space.'; return 1; }
    (( available >= MIN_DISK_SPACE_MB )) || {
        fail "Need ${MIN_DISK_SPACE_MB} MiB free on /; found ${available} MiB."
        return 1
    }
}

task_update() {
    check_space || return 1
    run_command dnf upgrade -y
}

task_autoremove() { run_command dnf autoremove -y; }
task_clean_dnf() { run_command dnf clean packages; }

task_kernels() {
    local installed running kver prefix i
    local -a versions=() packages=()
    require_command rpm || return 1
    running=$(uname -r) || return 1
    installed=$(rpm -q kernel-core --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}\n') || {
        fail 'Could not inventory kernel-core packages; leaving kernels alone.'
        return 1
    }
    mapfile -t versions < <(printf '%s\n' "$installed" | sort -Vu)
    for kver in "${versions[@]}"; do
        [[ $kver =~ ^[a-zA-Z0-9._+~-]+$ ]] || { fail 'Unexpected kernel version.'; return 1; }
    done
    for ((i=0; i < ${#versions[@]} - KERNELS_TO_KEEP; i++)); do
        kver=${versions[i]}
        [[ $kver == "$running" ]] && continue
        for prefix in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-modules-internal kernel-devel kernel-devel-matched kernel-uki-virt; do
            if rpm -q "$prefix-$kver" >/dev/null 2>&1; then packages+=("$prefix-$kver"); fi
        done
    done
    if (( ${#packages[@]} == 0 )); then TASK_NOTE='No old kernels needed removal.'; say "$TASK_NOTE"; return 0; fi
    run_command dnf remove -y "${packages[@]}" || return 1
    TASK_NOTE="Removed ${#packages[@]} selected old kernel packages; running kernel preserved."
}

task_journal() {
    run_command journalctl --rotate || return 1
    run_command journalctl "--vacuum-time=$JOURNAL_VACUUM_TIME" "--vacuum-size=$JOURNAL_VACUUM_SIZE"
}

task_temp() { run_command systemd-tmpfiles --clean --prefix=/tmp --prefix=/var/tmp; }

task_flatpak() { run_command flatpak --system update -y; }
task_clean_flatpak() { run_command flatpak --system uninstall --unused -y; }

task_thumbnails() {
    local target_user=${SUDO_USER:-} passwd_entry uid user_home
    if [[ -z $target_user ]]; then target_user=$(logname 2>/dev/null) || target_user=''; fi
    if [[ -z $target_user ]]; then TASK_NOTE='No desktop user found; thumbnails left alone.'; say "$TASK_NOTE"; return 0; fi
    [[ $target_user =~ ^[a-z_][a-z0-9_-]*$ ]] || { fail 'Could not identify the desktop user.'; return 1; }
    passwd_entry=$(getent passwd "$target_user") || { fail "Could not find user: $target_user"; return 1; }
    IFS=: read -r _ _ uid _ _ user_home _ <<< "$passwd_entry"
    if ! [[ $uid =~ ^[0-9]+$ && $uid -ge 1000 && $user_home == /* && $user_home != / ]]; then
        fail 'Refusing to clean thumbnails for a system account or unsafe home path.'; return 1
    fi
    if [[ ! -d $user_home/.cache/thumbnails ]]; then TASK_NOTE='No desktop thumbnail cache found.'; say "$TASK_NOTE"; return 0; fi
    run_command runuser -u "$target_user" -- find "$user_home/.cache/thumbnails" -type f -delete || return 1
    TASK_NOTE="Cleared thumbnail files for $target_user; thumbnails will regenerate when needed."
}

task_coredumps() {
    run_command systemd-tmpfiles --clean --prefix=/var/lib/systemd/coredump
}

task_trim() { run_command fstrim --all --verbose; }
task_boot_report() {
    run_command systemd-analyze time || return 1
    run_command systemd-analyze critical-chain --no-pager
}
task_failed() { run_command systemctl reset-failed; }

task_dependency() {
    case "$1" in
        update|autoremove|clean-dnf|kernels) printf dnf ;;
        journal) printf journalctl ;;
        temp|coredumps) printf systemd-tmpfiles ;;
        flatpak|clean-flatpak) printf flatpak ;;
        thumbnails) printf getent ;;
        trim) printf fstrim ;;
        boot-report) printf systemd-analyze ;;
        failed) printf systemctl ;;
    esac
}

task_outcome() {
    case "$1" in
        update) printf 'Package upgrade finished; already-current packages left unchanged.' ;;
        flatpak) printf 'System app update finished; already-current apps left unchanged.' ;;
        autoremove) printf 'DNF unused-package cleanup completed.' ;;
        clean-dnf) printf 'Downloaded package cache cleanup completed.' ;;
        kernels) printf 'Old-kernel cleanup completed; running kernel preserved.' ;;
        journal) printf 'Journal rotated; archive limits applied: %s / %s.' "$JOURNAL_VACUUM_TIME" "$JOURNAL_VACUUM_SIZE" ;;
        temp) printf 'Expiry rules applied to /tmp and /var/tmp.' ;;
        clean-flatpak) printf 'Unused system runtime cleanup completed.' ;;
        thumbnails) printf 'Desktop thumbnail cache cleared; previews regenerate when opened.' ;;
        coredumps) printf 'System expiry rules applied to stored coredumps.' ;;
        trim) printf 'Free blocks reported to the drive; TRIM does not free disk space.' ;;
        boot-report) printf 'Boot timing and critical service chain displayed; no settings changed.' ;;
        failed) printf 'Failed-unit status cleared; services were not repaired.' ;;
    esac
}

available_mib() {
    local available
    available=$(df --output=avail -BM / 2>/dev/null | tail -n 1) || return 1
    available=${available//[[:space:]M]/}
    [[ $available =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$available"
}

execute_tasks() {
    local task function_name rc done_count=0 failed_count=0 skipped_count=0 update_failed=0 index=0
    local started=$SECONDS elapsed before='' after='' delta TASK_NOTE=''
    local -A result_states=() result_details=()
    (( DRY_RUN )) || before=$(available_mib) || before=''
    for task in "${SELECTED[@]}"; do
        index=$((index + 1))
        heading "[$index/${#SELECTED[@]}] $(task_label "$task")"
        if (( update_failed )) && [[ $task == autoremove || $task == kernels ]]; then
            say "${YELLOW}Skipped: package update failed; keeping installed packages.${RESET}"
            skipped_count=$((skipped_count + 1))
            result_states[$task]=SKIPPED
            result_details[$task]='Package update failed; installed packages kept.'
            continue
        fi
        if ! command -v "$(task_dependency "$task")" >/dev/null 2>&1; then
            if [[ $task == flatpak || $task == clean-flatpak || $task == trim || $task == boot-report ]]; then
                say "${YELLOW}Skipped: $(task_dependency "$task") is not installed.${RESET}"
                skipped_count=$((skipped_count + 1))
                result_states[$task]=SKIPPED
                result_details[$task]="$(task_dependency "$task") is not installed."
                continue
            fi
            fail "Missing dependency: $(task_dependency "$task")"
            failed_count=$((failed_count + 1))
            result_states[$task]=FAILED
            result_details[$task]="Missing command: $(task_dependency "$task")."
            [[ $task == update ]] && update_failed=1
            continue
        fi
        function_name=task_${task//-/_}
        rc=0
        TASK_NOTE=''
        "$function_name" || rc=$?
        if (( rc == 0 )); then
            done_count=$((done_count + 1))
            if (( DRY_RUN )); then
                result_states[$task]=PREVIEW
                result_details[$task]="$(task_label "$task") — not executed."
            else
                result_states[$task]=DONE
                result_details[$task]=${TASK_NOTE:-$(task_outcome "$task")}
            fi
            if (( DRY_RUN )); then say "${CYAN}Previewed.${RESET}"; else say "${GREEN}Done.${RESET}"; fi
        else
            fail "$task failed (exit $rc)."
            failed_count=$((failed_count + 1))
            result_states[$task]=FAILED
            result_details[$task]="Exit $rc; may have partially completed. See output/log."
            [[ $task == update ]] && update_failed=1
        fi
    done
    (( DRY_RUN )) || after=$(available_mib) || after=''
    elapsed=$((SECONDS - started))
    heading 'Maintenance summary'
    for task in "${SELECTED[@]}"; do
        summary_row "$task" "${result_states[$task]}" "${result_details[$task]}"
    done
    say ''
    local verb=completed
    (( DRY_RUN )) && verb=previewed
    say "${GREEN}$done_count $verb${RESET} / ${YELLOW}$skipped_count skipped${RESET} / ${RED}$failed_count failed${RESET}"
    say "Time: $((elapsed / 60))m $((elapsed % 60))s"
    if (( DRY_RUN )); then
        say 'Preview only: no maintenance changes made.'
    elif [[ -n $before && -n $after ]]; then
        delta=$((after - before))
        if (( delta >= 0 )); then
            say "Disk /: +${delta} MiB available (${after} MiB free now)."
        else
            say "Disk /: $((-delta)) MiB more used (${after} MiB free now)."
        fi
        say "${DIM}Net filesystem change; includes updates and other activity. TRIM is not reclaimed space.${RESET}"
    else
        say 'Disk /: space change could not be measured.'
    fi
    [[ -z $LOG_FILE ]] || say "Log: $LOG_FILE"
    if (( failed_count > 0 )); then fail 'Some tasks failed. Review the output before retrying.'; return 1; fi
    return 0
}
