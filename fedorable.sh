#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_message() {
    local level=$1
    local message=$2
    case $level in
        "info") echo -e "${GREEN}===> ${message}${NC}" ;;
        "warning") echo -e "${YELLOW}===> WARNING: ${message}${NC}" ;;
        "error") echo -e "${RED}===> ERROR: ${message}${NC}" ;;
    esac
}

ask_yes_no() {
    local question=$1
    local default=${2:-"yes"}
    while true; do
        prompt="[Y/n]"
        [ "$default" = "no" ] && prompt="[y/N]"
        read -p "$question $prompt " response
        [ -z "$response" ] && response=$default
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

show_menu() {
    clear
    echo -e "${GREEN}=== Fedorable System Maintenance Tool ===${NC}"
    echo "Available tasks:"
    echo "1. Backup System Configurations"
    echo "2. Update System"
    echo "3. System Cleanup"
    echo "4. User Data Cleanup"
    echo "5. System Optimization"
    echo "6. Run All Tasks"
    echo "0. Exit"
    echo
    echo "You can select multiple tasks using comma-separated numbers (e.g., 2,4,5)"
    echo
    read -p "Enter your choice(s): " choices
}

backup_system_config() {
    log_message "info" "Starting system backup..."
    BACKUP_DIR="/root/system_backup_$(date +%Y%m%d)"
    mkdir -p "$BACKUP_DIR"
    configs=(
        "/etc/dnf"
        "/etc/fstab"
        "/etc/default/grub"
        "/etc/hostname"
        "/etc/hosts"
    )
    echo "Select configurations to backup:"
    for i in "${!configs[@]}"; do
        if ask_yes_no "Backup ${configs[$i]}?"; then
            cp -r "${configs[$i]}" "$BACKUP_DIR" 2>/dev/null || log_message "warning" "Failed to backup ${configs[$i]}"
        fi
    done
}

update_system() {
    log_message "info" "Starting system update..."
    dnf check-upgrade
    if ask_yes_no "Proceed with system upgrade?"; then
        dnf upgrade -y
    fi
}

cleanup_system() {
    log_message "info" "Starting system cleanup..."
    if ask_yes_no "Remove unused packages and dependencies?"; then
        dnf autoremove -y
    fi
    if ask_yes_no "Clean DNF cache and metadata?"; then
        dnf clean all
        dnf clean dbcache
        dnf makecache
    fi
    if ask_yes_no "Remove old kernels (keep last 2)?"; then
        dnf remove $(dnf repoquery --installonly --latest-limit=-2 -q) -y || true
    fi
}

cleanup_user_data() {
    log_message "info" "Starting user data cleanup..."
    if ask_yes_no "Clean user cache directories?"; then
        find /home/ -type f -name '.thumbnails' -exec rm -rf {} +
        find /home/ -type f -name '.cache' -exec rm -rf {} +
    fi
    if ask_yes_no "Clear bash history?"; then
        > /root/.bash_history
        find /home -name ".bash_history" -exec sh -c '> {}' \;
    fi
}

optimize_system() {
    log_message "info" "Starting system optimization..."
    if ask_yes_no "Update GRUB configuration?"; then
        grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
    if ask_yes_no "Optimize SSD (if present)?"; then
        [ -x "$(command -v fstrim)" ] && fstrim -av || log_message "warning" "fstrim not found"
    fi
    if ask_yes_no "Optimize RPM database?"; then
        rpm --rebuilddb
    fi
}

run_task() {
    local task=$1
    case $task in
        1) backup_system_config ;;
        2) update_system ;;
        3) cleanup_system ;;
        4) cleanup_user_data ;;
        5) optimize_system ;;
        6) 
            backup_system_config
            update_system
            cleanup_system
            cleanup_user_data
            optimize_system
            ;;
        0) return 1 ;;
        *) log_message "error" "Invalid task number: $task" ;;
    esac
    return 0
}

main() {
    [ "$EUID" -ne 0 ] && { log_message "error" "Please run as root or using sudo."; exit 1; }
    set -euo pipefail

    show_menu
    
    if [[ $choices == "0" ]]; then
        log_message "info" "Exiting..."
        exit 0
    fi

    IFS=',' read -ra selected_tasks <<< "$choices"
    
    for task in "${selected_tasks[@]}"; do
        task=$(echo "$task" | tr -d ' ')
        if ! run_task "$task"; then
            break
        fi
        echo
    done

    log_message "info" "All selected tasks completed!"
    echo "Disk space usage:"
    df -h /
}

main