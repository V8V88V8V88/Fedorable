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
    echo "1. Backup System Configurations"
    echo "2. Update System"
    echo "3. System Cleanup"
    echo "4. User Data Cleanup"
    echo "5. System Optimization"
    echo "6. Run All Tasks"
    echo "0. Exit"
    echo
    read -p "Choose an option [0-6]: " choice
}

backup_system_config() {
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
    log_message "info" "Checking for updates"
    dnf check-upgrade
    if ask_yes_no "Proceed with system upgrade?"; then
        dnf upgrade -y
    fi
}

cleanup_system() {
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

run_all_tasks() {
    log_message "info" "Running all maintenance tasks..."
    backup_system_config
    update_system
    cleanup_system
    cleanup_user_data
    optimize_system
}

main() {
    [ "$EUID" -ne 0 ] && { log_message "error" "Please run as root or using sudo."; exit 1; }
    set -euo pipefail

    while true; do
        show_menu
        case $choice in
            1) backup_system_config ;;
            2) update_system ;;
            3) cleanup_system ;;
            4) cleanup_user_data ;;
            5) optimize_system ;;
            6) run_all_tasks ;;
            0) log_message "info" "Exiting..."; exit 0 ;;
            *) log_message "error" "Invalid option" ;;
        esac
        echo
        read -p "Press Enter to continue..."
    done
}

main