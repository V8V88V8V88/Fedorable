#!/usr/bin/env bash

setup_ui() {
    IDLE_LOGO=()
    STAR_X=() STAR_PHASE=()
    STAR_LEFT_A=1 STAR_LEFT_B=4 SPARKLE_FRAME=0
    LOGO_WIDTH=0 LOGO_HEIGHT=0
    BLUE='' CYAN='' GREEN='' YELLOW='' RED='' BOLD='' DIM='' RESET=''
    if [[ -t 1 && ${TERM:-dumb} != dumb && ! -v NO_COLOR ]]; then
        BLUE=$'\033[38;5;33m' CYAN=$'\033[38;5;117m'
        GREEN=$'\033[38;5;114m' YELLOW=$'\033[38;5;221m' RED=$'\033[38;5;203m'
        BOLD=$'\033[1m' DIM=$'\033[2m' RESET=$'\033[0m'
    fi
}

banner() {
    (( QUIET )) && return 0
    local width=${COLUMNS:-80} height=24 frame
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        width=$(tput cols 2>/dev/null) || width=80
        height=$(tput lines 2>/dev/null) || height=24
    fi
    local -a logo=(
        '█████ █████ ████   ███  ████   ███  ████  █     █████'
        '█     █     █   █ █   █ █   █ █   █ █   █ █     █'
        '████  ████  █   █ █   █ ████  █████ ████  █     ████'
        '█     █     █   █ █   █ █  █  █   █ █   █ █     █'
        '█     █████ ████   ███  █   █ █   █ ████  █████ █████'
    )
    IDLE_LOGO=("${logo[@]}")
    STAR_X=() STAR_PHASE=()
    for ((frame=0; frame<8; frame++)); do
        STAR_X+=("$((RANDOM % 14 + 1))")
        STAR_PHASE+=("$((RANDOM % 48))")
    done
    STAR_LEFT_A=$((RANDOM % 3))
    STAR_LEFT_B=$((RANDOM % 3 + 3))
    LOGO_WIDTH=$width LOGO_HEIGHT=$height
    printf '\n'
    if [[ $width =~ ^[0-9]+$ ]] && (( width < 80 )); then
        printf '  %s%sFEDORABLE%s\n' "$BOLD" "$CYAN" "$RESET"
    else
        draw_logo -1 1 "${logo[@]}"
        if [[ -t 1 && -n $BLUE && $height =~ ^[0-9]+$ ]] && (( ! NO_ANIMATION && height >= 12 )); then
            for frame in 0 10 20 30 40 50; do
                printf '\033[6A'
                draw_logo "$frame" 0 "${logo[@]}"
                sleep 0.045
            done
            printf '\033[6A'
            draw_logo -1 0 "${logo[@]}"
        fi
    fi
    printf '\n  %sAn adorable Fedora maintenance script.%s  %sv%s%s\n' "$CYAN" "$RESET" "$DIM" "$VERSION" "$RESET"
    divider
    printf '\n'
}

draw_logo() {
    local highlight=$1 reveal=$2 y x offset character color line front shadow sparkle
    shift 2
    local -a art=("$@")
    local -a shades=(33 39 75 117 153)
    for ((y=0; y<6; y++)); do
        line='  '
        if (( y == STAR_LEFT_A )); then
            line="$(star_glyph 6) "
        elif (( y == STAR_LEFT_B )); then
            line="$(star_glyph 7) "
        fi
        for ((x=0; x<55; x++)); do
            front=' ' shadow=0
            if (( y < 5 )); then front=${art[y]:x:1}; fi
            if (( y > 0 )); then
                for offset in 1 2; do
                    if (( x >= offset )) && [[ ${art[y-1]:x-offset:1} == '█' ]]; then shadow=1; fi
                done
            fi
            character=' ' color=''
            if [[ $front == '█' ]]; then
                character='█'
                if [[ -n $BLUE ]]; then
                    printf -v color '\033[38;5;%sm' "${shades[y]}"
                    if (( highlight >= 0 && x >= highlight && x < highlight + 7 )); then color=$'\033[97m'; fi
                fi
            elif (( shadow )); then
                character='▓'
                [[ -z $BLUE ]] || color=$'\033[38;5;24m'
            fi
            line+="$color$character"
        done
        printf -v sparkle '%*s' "${STAR_X[y]:-1}" ''
        line+="$RESET$sparkle$(star_glyph "$y")"
        printf -v sparkle '%*s' "$((16 - ${STAR_X[y]:-1}))" ''
        printf '%s%s%s\n' "$line" "$sparkle" "$RESET"
        if [[ -t 1 && -n $BLUE ]] && (( reveal && ! NO_ANIMATION )); then sleep 0.055; fi
    done
}

star_glyph() {
    local phase=$(((SPARKLE_FRAME + ${STAR_PHASE[$1]:-0}) % 48)) strength=0
    if (( phase < 12 )); then strength=$phase
    elif (( phase < 24 )); then strength=$((23 - phase)); fi
    if [[ -n $BLUE ]]; then
        printf '\033[38;2;%s;%s;%sm✦%s' "$((16 + strength * 14))" "$((38 + strength * 17))" "$((55 + strength * 18))" "$RESET"
    else
        printf '✦'
    fi
}

divider() { printf '  %s──────────────────────────────────────────────────────%s\n' "$BLUE" "$RESET"; }

log_line() {
    local plain=$* pattern=$'\033''\[[0-9;]*m'
    while [[ $plain =~ $pattern ]]; do plain=${plain//"${BASH_REMATCH[0]}"/}; done
    [[ -z $LOG_FILE ]] || printf '%s\n' "$plain" >> "$LOG_FILE"
    return 0
}

say() {
    (( QUIET )) || printf '  %s\n' "$*"
    log_line "$*"
    return 0
}

fail() {
    printf '  %sError:%s %s\n' "${RED:-}" "${RESET:-}" "$*" >&2
    log_line "Error: $*"
    return 0
}

heading() { say ''; say "$BOLD$BLUE$*$RESET"; }

show_plan() {
    heading 'Your maintenance plan'
    local task flatpak_note=0
    for task in "${SELECTED[@]}"; do say "  ${CYAN}+${RESET} $(task_label "$task")"; done
    say ''
    for task in "${SELECTED[@]}"; do
        case "$task" in
            kernels) say "Kernels: keep newest $KERNELS_TO_KEEP plus the running kernel." ;;
            journal) say "Journal: retain $JOURNAL_VACUUM_TIME, up to $JOURNAL_VACUUM_SIZE of archived logs." ;;
            flatpak|clean-flatpak)
                if (( ! flatpak_note )); then say 'Flatpak: system installation only.'; flatpak_note=1; fi ;;
        esac
    done
    (( DRY_RUN )) && say "${YELLOW}Preview only. No maintenance commands will be executed.${RESET}"
    return 0
}

menu() {
    local choice rc redraw=0
    while true; do
    if (( redraw )); then banner; fi
    redraw=1
    menu_option 1 'Recommended' 'Fedora update + safe routine upkeep'
    menu_option 2 'Basic cleanup' 'Caches, unused packages, old kernels, logs, temp files + TRIM'
    menu_option 3 'Updates only' 'Fedora packages + system Flatpak apps'
    menu_option 4 'Choose tasks' 'Custom maintenance: pick individual tasks'
    menu_option 5 'Check updates' 'List available Fedora updates; install nothing'
    printf '  %s0%s  Exit\n\n' "$DIM" "$RESET"
    read_menu_choice choice || return 1
    case "$choice" in
        ''|1) set_preset recommended; return 0 ;;
        2) set_preset cleanup; return 0 ;;
        3) set_preset updates; return 0 ;;
        4)
            rc=0
            choose_tasks || rc=$?
            (( rc == 3 )) && continue
            return "$rc" ;;
        5) CHECK_ONLY=1; return 0 ;;
        0) return 2 ;;
        *) fail 'Choose a number from 0 to 5.'; printf '\n' ;;
    esac
    done
}

read_menu_choice() {
    local destination=$1 prompt="  ${CYAN}Pick one [1]:${RESET} "
    if [[ ! -t 0 || ! -t 1 || -z $BLUE ]] || (( NO_ANIMATION || QUIET || LOGO_WIDTH < 80 || LOGO_HEIGHT < 22 )); then
        read -r -p "$prompt" "${destination?}"
        return $?
    fi
    local input='' key rc frame=0 current_size animate=1 sweep SPARKLE_FRAME
    local -a frames=()
    for ((SPARKLE_FRAME=0; SPARKLE_FRAME<48; SPARKLE_FRAME++)); do
        sweep=$((SPARKLE_FRAME * 2 - 7))
        (( sweep <= 55 )) || sweep=-1
        frames+=("$(draw_logo "$sweep" 0 "${IDLE_LOGO[@]}")")
    done
    printf '%s' "$prompt"
    while true; do
        key='' rc=0
        IFS= read -r -s -n 1 -t 0.07 key || rc=$?
        if (( rc == 0 )); then
            case "$key" in
                ''|$'\r') printf '\n'; printf -v "$destination" '%s' "$input"; return 0 ;;
                $'\177'|$'\b')
                    if [[ -n $input ]]; then input=${input%?}; printf '\b \b'; fi ;;
                $'\025')
                    while [[ -n $input ]]; do input=${input%?}; printf '\b \b'; done ;;
                *)
                    if [[ $key == [[:print:]] ]] && (( ${#input} < 32 )); then input+=$key; printf '%s' "$key"; fi ;;
            esac
        elif (( rc <= 128 )); then
            printf '\n'
            return 1
        fi
        if (( animate )); then
            current_size=$(stty size 2>/dev/null) || current_size=''
            if [[ $current_size != "$LOGO_HEIGHT $LOGO_WIDTH" ]]; then
                animate=0
                continue
            fi
            printf '\r\033[17A%s\n\033[11B\r%s%s' "${frames[frame]}" "$prompt" "$input"
            frame=$(((frame + 1) % ${#frames[@]}))
        fi
    done
}

choose_tasks() {
    local task index=0 input
    heading 'Choose your tasks'
    for task in "${TASKS[@]}"; do
        index=$((index + 1))
        case "$index" in
            1) printf '  %s%sUPDATES%s\n' "$BOLD" "$BLUE" "$RESET" ;;
            3) printf '\n  %s%sCLEANUP & CACHE%s\n' "$BOLD" "$BLUE" "$RESET" ;;
            11) printf '\n  %s%sSTORAGE%s\n' "$BOLD" "$BLUE" "$RESET" ;;
            12) printf '\n  %s%sDIAGNOSTICS%s\n' "$BOLD" "$BLUE" "$RESET" ;;
        esac
        printf '  %s%2s%s  %-14s %s\n' "$CYAN" "$index" "$RESET" "$task" "$(task_label "$task")"
    done
    printf '\n  %sUse numbers or names, separated by commas: 3,4,6 or journal,temp\n  Review your selection before anything runs.\n  b  Back to the menu%s\n\n' "$DIM" "$RESET"
    while true; do
        read -r -p "  ${CYAN}Select tasks:${RESET} " input || return 1
        [[ $input == b || $input == B ]] && return 3
        if select_task_input "$input"; then return 0; fi
    done
}

select_task_input() {
    local input=${1//[[:space:]]/} item csv=''
    local -a items=()
    [[ -n $input && $input != ,* && $input != *, && $input != *,,* ]] || {
        fail 'Select at least one task, separated by commas.'; return 1;
    }
    IFS=, read -r -a items <<< "$input"
    for item in "${items[@]}"; do
        if [[ $item =~ ^[1-9][0-9]?$ ]]; then
            (( item <= ${#TASKS[@]} )) || { fail "Unknown task number: $item"; return 1; }
            item=${TASKS[item-1]}
        fi
        csv+=${csv:+,}$item
    done
    select_csv "$csv"
}

menu_option() {
    printf '  %s%s%s  %s%-16s%s %s%s%s\n' "$CYAN" "$1" "$RESET" "$BOLD" "$2" "$RESET" "$DIM" "$3" "$RESET"
}

summary_row() {
    local task=$1 state=$2 detail=$3 color=$GREEN label
    case "$state" in
        FAILED) color=$RED ;;
        SKIPPED) color=$YELLOW ;;
        PREVIEW) color=$CYAN ;;
    esac
    printf -v label '%-8s %-14s' "$state" "$task"
    say "${color}${label}${RESET} $detail"
}
