#!/bin/bash

# Fedorable - Enhanced Fedora System Maintenance Script
# Version: 2.0 (10/10 aspiration)
#
# Performs system updates, cleanup, and optimizations for Fedora Linux.
# Requires root privileges. Use with caution.

# --- Configuration ---
readonly SCRIPT_NAME=$(basename "$0")
readonly LOG_DIR="/var/log/fedorable"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"
readonly BACKUP_BASE_DIR="/root/system_backups" # Base directory for backups
readonly KERNELS_TO_KEEP=2                     # Number of latest kernels to retain
readonly JOURNAL_VACUUM_TIME="7d"              # Max age for journal entries
readonly JOURNAL_VACUUM_SIZE="500M"            # Max size for journal
readonly TEMP_FILE_AGE_DAYS=10                 # Delete temp files older than this
readonly MIN_DISK_SPACE_MB=1024                # Minimum free space (MB) needed for updates

# --- Script Flags & Defaults ---
declare -i PERFORM_BACKUP=0
declare -i PERFORM_UPDATE=1
declare -i PERFORM_AUTOREMOVE=1
declare -i PERFORM_CLEAN_DNF=1
declare -i PERFORM_CLEAN_KERNELS=1
declare -i PERFORM_CLEAN_USER_CACHE=1
declare -i PERFORM_CLEAN_JOURNAL=1
declare -i PERFORM_CLEAN_TEMP=1
declare -i PERFORM_UPDATE_GRUB=1
declare -i PERFORM_CLEAN_FLATPAK=1
declare -i PERFORM_OPTIMIZE_RPMDB=1
declare -i PERFORM_RESET_FAILED_UNITS=1
declare -i PERFORM_UPDATE_FONTS=1
declare -i PERFORM_CLEAR_HISTORY=0 # Default OFF for safety
declare -i PERFORM_TRIM=1
declare -i PERFORM_CLEAN_SNAP=1
declare -i PERFORM_UPDATE_MANDB=1
declare -i FORCE_YES=0 # Skip confirmations
declare -i SHOW_HELP=0
declare -i ERROR_COUNT=0

# --- Helper Functions ---

# Function to print messages to console and log
log_msg() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] $1" | tee -a "$LOG_FILE"
}

# Function to print error messages
log_error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] $1" | tee -a "$LOG_FILE" >&2
    ((ERROR_COUNT++))
}

# Function to print warning messages
log_warn() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] $1" | tee -a "$LOG_FILE" >&2
}

# Print header message
print_header() {
    log_msg "=== $1 ==="
}

# Check if a command exists
check_command() {
    command -v "$1" &>/dev/null
}

# Confirm action with user
confirm_action() {
    local prompt="$1"
    if [[ $FORCE_YES -eq 1 ]]; then
        log_msg "Confirmation skipped for '$prompt' due to --yes flag."
        return 0 # Yes
    fi
    while true; do
        read -p "[CONFIRM] $prompt [y/N]: " yn
        case $yn in
            [Yy]* ) log_msg "User confirmed action: $prompt"; return 0;; # Yes
            [Nn]*|"" ) log_warn "User skipped action: $prompt"; return 1;; # No
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}

# Check exit status and log appropriately
check_status() {
    local exit_code=$?
    local task_name="$1"
    if [[ $exit_code -ne 0 ]]; then
        log_error "Task '$task_name' failed with exit code $exit_code."
        return 1
    else
        log_msg "Task '$task_name' completed successfully."
        return 0
    fi
}

# Check for sufficient disk space
check_disk_space() {
    local path="$1"
    local required_mb="$2"
    local available_kb=$(df --output=avail -B 1K "$path" | tail -n 1)
    local available_mb=$((available_kb / 1024))

    if [[ $available_mb -lt $required_mb ]]; then
        log_error "Insufficient disk space on '$path'. Need ${required_mb}MB, have ${available_mb}MB."
        return 1
    fi
    log_msg "Disk space check passed for '$path' (${available_mb}MB available)."
    return 0
}

# --- Task Functions ---

task_backup() {
    print_header "Creating System Configuration Backup"
    local backup_dir="${BACKUP_BASE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir" && check_status "Create backup directory $backup_dir" || return 1

    local files_to_backup=(
        "/etc/dnf"
        "/etc/fstab"
        "/etc/default/grub"
        "/etc/sysconfig/grub" # Also back up this common location
    )
    local success=1
    for item in "${files_to_backup[@]}"; do
        if [[ -e "$item" ]]; then
            cp -rp "$item" "$backup_dir/"
            if [[ $? -ne 0 ]]; then
                log_warn "Failed to backup '$item'."
                success=0
            else
                 log_msg "Backed up '$item'."
            fi
        else
            log_warn "Backup source '$item' does not exist, skipping."
        fi
    done
    [[ $success -eq 1 ]] && log_msg "Backup completed to $backup_dir" || log_warn "Backup completed with some warnings."
    return $success
}

task_update_system() {
    print_header "Updating Package List and System"
    check_disk_space "/" "$MIN_DISK_SPACE_MB" || return 1
    dnf upgrade -y
    check_status "System package upgrade (dnf upgrade -y)"
}

task_autoremove() {
    print_header "Removing Unused Packages and Dependencies"
    # List packages first if not forced
    if [[ $FORCE_YES -eq 0 ]]; then
        log_msg "The following packages will be removed by autoremove:"
        dnf autoremove --assumeno | grep Removing: -A 1000 | tee -a "$LOG_FILE" || true # Show potential removals
    fi
    confirm_action "Proceed with removing unused packages (dnf autoremove)?" || return 0 # Return 0 to continue script even if user says no
    dnf autoremove -y
    check_status "Remove unused packages (dnf autoremove -y)"
}

task_clean_dnf_cache() {
    print_header "Cleaning DNF Cache and Metadata"
    dnf clean all
    check_status "Clean DNF cache (dnf clean all)" || return 1
    dnf makecache
    check_status "Rebuild DNF metadata cache (dnf makecache)"
}

task_remove_old_kernels() {
    print_header "Removing Old Kernels (keeping last $KERNELS_TO_KEEP)"
    # Check current kernel count
    local installed_kernels=$(rpm -q kernel-core | wc -l)
    if [[ $installed_kernels -le $KERNELS_TO_KEEP ]]; then
        log_msg "Found $installed_kernels kernel(s) installed. No old kernels to remove (keeping $KERNELS_TO_KEEP)."
        return 0
    fi

    log_msg "Current installed kernels:"
    rpm -q kernel-core | tee -a "$LOG_FILE"

    log_msg "Kernels identified for potential removal (excluding the latest $KERNELS_TO_KEEP):"
    # Use dnf repoquery for a safer preview, though dnf remove handles the logic
    dnf repoquery --installonly --latest-limit=-${KERNELS_TO_KEEP} -q | tee -a "$LOG_FILE"

    confirm_action "Proceed with removing old kernels?" || return 0
    dnf remove --oldinstallonly --setopt installonly_limit=$KERNELS_TO_KEEP -y
    check_status "Remove old kernels"
}

task_clean_user_cache() {
    print_header "Cleaning User Thumbnail Caches"
    local cleaned_count=0
    shopt -s nullglob # Prevent loop from running if /home/* matches nothing
    for user_home in /home/* /root; do
        if [[ -d "$user_home" ]]; then
            local thumb_cache_dir="$user_home/.cache/thumbnails"
            local old_thumb_dir="$user_home/.thumbnails" # Less common legacy location
            if [[ -d "$thumb_cache_dir" ]]; then
                rm -rf "$thumb_cache_dir"
                if check_status "Remove thumbnail cache for $user_home ($thumb_cache_dir)"; then
                    ((cleaned_count++))
                fi
            fi
             if [[ -d "$old_thumb_dir" ]]; then
                rm -rf "$old_thumb_dir"
                if check_status "Remove legacy thumbnail cache for $user_home ($old_thumb_dir)"; then
                    ((cleaned_count++))
                fi
            fi
        fi
    done
    shopt -u nullglob
    log_msg "Cleaned thumbnail caches for $cleaned_count users/root."
}

task_clean_journal() {
    print_header "Cleaning System Journal"
    log_msg "Vacuuming journal older than $JOURNAL_VACUUM_TIME..."
    journalctl --vacuum-time="$JOURNAL_VACUUM_TIME"
    check_status "Journal vacuum by time" || true # Don't stop script if vacuum fails

    log_msg "Rotating journal files..."
    journalctl --rotate
    check_status "Journal rotate" || true

    log_msg "Vacuuming journal to retain max size $JOURNAL_VACUUM_SIZE..."
    journalctl --vacuum-size="$JOURNAL_VACUUM_SIZE"
    check_status "Journal vacuum by size" || true
}

task_clean_temp_files() {
    print_header "Removing Old Temporary Files (older than $TEMP_FILE_AGE_DAYS days)"
    local found_tmp=$(find /tmp -type f -atime +"$TEMP_FILE_AGE_DAYS" -print -delete | wc -l)
    check_status "Delete old files from /tmp"
    log_msg "Removed $found_tmp old file(s) from /tmp."

    local found_var_tmp=$(find /var/tmp -type f -atime +"$TEMP_FILE_AGE_DAYS" -print -delete | wc -l)
    check_status "Delete old files from /var/tmp"
    log_msg "Removed $found_var_tmp old file(s) from /var/tmp."
}

task_update_grub() {
    print_header "Updating GRUB Configuration"
    local grub_cfg=""
    # Check for UEFI vs BIOS more reliably
    if [[ -d /sys/firmware/efi/efivars ]]; then
        log_msg "UEFI system detected."
        # Common Fedora UEFI paths
        if [[ -f /boot/efi/EFI/fedora/grub.cfg ]]; then
            grub_cfg="/boot/efi/EFI/fedora/grub.cfg"
        elif [[ -f /boot/grub2/grub.cfg ]]; then # Fallback or different setups
            grub_cfg="/boot/grub2/grub.cfg"
        else
             log_error "Could not find standard GRUB config path for UEFI. Searched /boot/efi/EFI/fedora/grub.cfg and /boot/grub2/grub.cfg."
             return 1
        fi
    else
        log_msg "BIOS system detected."
         if [[ -f /boot/grub2/grub.cfg ]]; then
            grub_cfg="/boot/grub2/grub.cfg"
         else
            log_error "Could not find standard GRUB config path for BIOS (/boot/grub2/grub.cfg)."
            return 1
         fi
    fi

    log_msg "Generating GRUB config to $grub_cfg..."
    grub2-mkconfig -o "$grub_cfg"
    check_status "GRUB configuration update (grub2-mkconfig)"
}

task_clean_flatpak() {
    print_header "Cleaning and Optimizing Flatpak"
    if ! check_command flatpak; then
        log_msg "Flatpak command not found. Skipping Flatpak tasks."
        return 0
    fi

    log_msg "Uninstalling unused Flatpak runtimes/apps..."
    flatpak uninstall --unused -y
    check_status "Flatpak uninstall unused" || true # Continue if nothing unused

    log_msg "Repairing Flatpak installations (user)..."
    flatpak repair --user
    check_status "Flatpak repair user" || true

    log_msg "Repairing Flatpak installations (system)..."
    flatpak repair
    check_status "Flatpak repair system" || true

    log_msg "Updating Flatpak applications..."
    flatpak update -y
    check_status "Flatpak update" || true # Continue if nothing to update
}

task_optimize_rpmdb() {
    print_header "Optimizing RPM Database"
    rpm --rebuilddb
    check_status "RPM database rebuild (rpm --rebuilddb)"
}

task_reset_failed_units() {
    print_header "Clearing Failed Systemd Units"
    systemctl reset-failed
    check_status "Reset failed systemd units (systemctl reset-failed)"
}

task_update_font_cache() {
    print_header "Updating Font Cache"
    fc-cache -f -v
    check_status "Font cache update (fc-cache -f -v)"
}

task_clear_bash_history() {
    print_header "Clearing Shell History"
    confirm_action "Clear shell history for root and all users in /home? (THIS IS PERMANENT)" || return 0

    if [[ -f /root/.bash_history ]]; then
        > /root/.bash_history
        check_status "Clear root .bash_history"
    fi
    if [[ -f /root/.zsh_history ]]; then
        > /root/.zsh_history
        check_status "Clear root .zsh_history"
    fi

    shopt -s nullglob
    for user_home in /home/*; do
        if [[ -d "$user_home" ]]; then
            local user=$(basename "$user_home")
             if [[ -f "$user_home/.bash_history" ]]; then
                 > "$user_home/.bash_history"
                 check_status "Clear $user .bash_history"
             fi
             if [[ -f "$user_home/.zsh_history" ]]; then
                 > "$user_home/.zsh_history"
                 check_status "Clear $user .zsh_history"
             fi
        fi
    done
     shopt -u nullglob
}

task_ssd_trim() {
    print_header "Checking and Optimizing SSD (TRIM)"
    if ! check_command fstrim; then
        log_msg "fstrim command not found. Skipping SSD TRIM."
        return 0
    fi
    # Check if root fs is on SSD (heuristic: check rotational status)
    local root_dev=$(findmnt -n -o SOURCE /)
    local root_disk=$(lsblk -n -o PKNAME "$root_dev" | head -n 1)
    local is_ssd=0
    if [[ -n "$root_disk" && -e "/sys/block/$root_disk/queue/rotational" ]]; then
        if [[ $(cat "/sys/block/$root_disk/queue/rotational") -eq 0 ]]; then
             is_ssd=1
             log_msg "Detected potential SSD for root filesystem (/dev/$root_disk)."
        else
             log_msg "Root filesystem (/dev/$root_disk) does not appear to be on an SSD (rotational=1). Skipping TRIM."
             return 0
        fi
    else
         log_warn "Could not determine if root filesystem is on SSD. Skipping TRIM."
         return 0
    fi

    if [[ $is_ssd -eq 1 ]]; then
        fstrim -av
        check_status "SSD TRIM operation (fstrim -av)"
    fi
}

task_clean_snap() {
    print_header "Cleaning Snap Packages"
     if ! check_command snap; then
        log_msg "Snap command not found. Skipping Snap tasks."
        return 0
    fi

    log_msg "Setting snap refresh retention to 2..."
    snap set system refresh.retain=2
    check_status "Set snap refresh.retain=2" || true # Non-critical if fails

    log_msg "Removing disabled snap revisions..."
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
        log_msg "Removing $snapname revision $revision..."
        snap remove "$snapname" --revision="$revision"
        check_status "Remove $snapname revision $revision" || log_warn "Failed to remove $snapname revision $revision (might be active or already gone)"
    done
    log_msg "Finished checking for disabled snap revisions."
}

task_update_mandb() {
    print_header "Updating Man Database"
    mandb -q # Use -q for quieter output unless errors occur
    check_status "Man database update (mandb -q)"
}

# --- Argument Parsing ---
usage() {
  echo "Usage: $SCRIPT_NAME [OPTIONS]"
  echo "  Performs system maintenance tasks on Fedora."
  echo
  echo "Options:"
  echo "  --all                 Run all tasks (default behavior if no flags are specified)"
  echo "  --no-update           Skip system update (dnf upgrade)"
  echo "  --no-autoremove       Skip removing unused packages (dnf autoremove)"
  echo "  --no-clean-dnf        Skip cleaning DNF cache"
  echo "  --no-clean-kernels    Skip removing old kernels"
  echo "  --no-clean-user-cache Skip cleaning user thumbnail caches"
  echo "  --no-clean-journal    Skip cleaning system journal"
  echo "  --no-clean-temp       Skip cleaning temporary files"
  echo "  --no-update-grub      Skip updating GRUB config"
  echo "  --no-clean-flatpak    Skip cleaning/updating Flatpak"
  echo "  --no-optimize-rpmdb   Skip optimizing RPM database"
  echo "  --no-reset-failed     Skip resetting failed systemd units"
  echo "  --no-update-fonts     Skip updating font cache"
  echo "  --no-trim             Skip SSD TRIM"
  echo "  --no-clean-snap       Skip cleaning Snap packages"
  echo "  --no-update-mandb     Skip updating man database"
  echo
  echo "  --perform-backup      Perform configuration backup (Default: off)"
  echo "  --clear-history       Clear shell history (Default: off - Use with caution!)"
  echo "  -y, --yes             Assume yes to all confirmation prompts"
  echo "  -h, --help            Display this help message and exit"
  exit 0
}

# Use getopt for robust parsing
ARGS=$(getopt -o yh --long all,no-update,no-autoremove,no-clean-dnf,no-clean-kernels,no-clean-user-cache,no-clean-journal,no-clean-temp,no-update-grub,no-clean-flatpak,no-optimize-rpmdb,no-reset-failed,no-update-fonts,no-trim,no-clean-snap,no-update-mandb,perform-backup,clear-history,yes,help -n "$SCRIPT_NAME" -- "$@")

if [[ $? -ne 0 ]]; then
  echo "Error parsing options. Use --help for usage." >&2
  exit 1
fi

eval set -- "$ARGS"

# Process options
run_all_default=1 # Assume run all unless specific --no-* flags are given
while true; do
  case "$1" in
    --all) run_all_default=1; shift ;; # Explicitly run all
    --no-update) PERFORM_UPDATE=0; run_all_default=0; shift ;;
    --no-autoremove) PERFORM_AUTOREMOVE=0; run_all_default=0; shift ;;
    --no-clean-dnf) PERFORM_CLEAN_DNF=0; run_all_default=0; shift ;;
    --no-clean-kernels) PERFORM_CLEAN_KERNELS=0; run_all_default=0; shift ;;
    --no-clean-user-cache) PERFORM_CLEAN_USER_CACHE=0; run_all_default=0; shift ;;
    --no-clean-journal) PERFORM_CLEAN_JOURNAL=0; run_all_default=0; shift ;;
    --no-clean-temp) PERFORM_CLEAN_TEMP=0; run_all_default=0; shift ;;
    --no-update-grub) PERFORM_UPDATE_GRUB=0; run_all_default=0; shift ;;
    --no-clean-flatpak) PERFORM_CLEAN_FLATPAK=0; run_all_default=0; shift ;;
    --no-optimize-rpmdb) PERFORM_OPTIMIZE_RPMDB=0; run_all_default=0; shift ;;
    --no-reset-failed) PERFORM_RESET_FAILED_UNITS=0; run_all_default=0; shift ;;
    --no-update-fonts) PERFORM_UPDATE_FONTS=0; run_all_default=0; shift ;;
    --no-trim) PERFORM_TRIM=0; run_all_default=0; shift ;;
    --no-clean-snap) PERFORM_CLEAN_SNAP=0; run_all_default=0; shift ;;
    --no-update-mandb) PERFORM_UPDATE_MANDB=0; run_all_default=0; shift ;;
    --perform-backup) PERFORM_BACKUP=1; run_all_default=0; shift ;;
    --clear-history) PERFORM_CLEAR_HISTORY=1; run_all_default=0; shift ;;
    -y | --yes) FORCE_YES=1; shift ;;
    -h | --help) SHOW_HELP=1; shift ;;
    --) shift; break ;;
    *) echo "Internal error!" ; exit 1 ;;
  esac
done

# If no specific flags were given, ensure all standard tasks run
if [[ $run_all_default -eq 1 && $PERFORM_BACKUP -eq 0 && $PERFORM_CLEAR_HISTORY -eq 0 ]]; then
    PERFORM_UPDATE=1
    PERFORM_AUTOREMOVE=1
    PERFORM_CLEAN_DNF=1
    PERFORM_CLEAN_KERNELS=1
    PERFORM_CLEAN_USER_CACHE=1
    PERFORM_CLEAN_JOURNAL=1
    PERFORM_CLEAN_TEMP=1
    PERFORM_UPDATE_GRUB=1
    PERFORM_CLEAN_FLATPAK=1
    PERFORM_OPTIMIZE_RPMDB=1
    PERFORM_RESET_FAILED_UNITS=1
    PERFORM_UPDATE_FONTS=1
    PERFORM_TRIM=1
    PERFORM_CLEAN_SNAP=1
    PERFORM_UPDATE_MANDB=1
    # Keep backup and history clear off by default even with --all
fi


# --- Main Execution ---

if [[ $SHOW_HELP -eq 1 ]]; then
    usage
fi

# Check for root privileges
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Please run this script as root or using sudo." >&2
    exit 1
fi

# Setup Logging
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
if [[ $? -ne 0 ]]; then
    echo "ERROR: Could not create log directory or file: $LOG_FILE" >&2
    exit 1
fi
chmod 600 "$LOG_FILE" # Restrict log file access

log_msg "Starting Fedorable System Maintenance Script (v2.0)"
log_msg "Log file: $LOG_FILE"
log_msg "Run flags: Backup=$PERFORM_BACKUP Update=$PERFORM_UPDATE Autoremove=$PERFORM_AUTOREMOVE CleanDNF=$PERFORM_CLEAN_DNF CleanKernels=$PERFORM_CLEAN_KERNELS CleanUserCache=$PERFORM_CLEAN_USER_CACHE CleanJournal=$PERFORM_CLEAN_JOURNAL CleanTemp=$PERFORM_CLEAN_TEMP UpdateGRUB=$PERFORM_UPDATE_GRUB CleanFlatpak=$PERFORM_CLEAN_FLATPAK OptimizeRPMDB=$PERFORM_OPTIMIZE_RPMDB ResetFailed=$PERFORM_RESET_FAILED_UNITS UpdateFonts=$PERFORM_UPDATE_FONTS ClearHistory=$PERFORM_CLEAR_HISTORY Trim=$PERFORM_TRIM CleanSnap=$PERFORM_CLEAN_SNAP UpdateManDB=$PERFORM_UPDATE_MANDB ForceYes=$FORCE_YES"

initial_disk_usage=$(df -h /)

# Execute tasks based on flags
[[ $PERFORM_BACKUP -eq 1 ]] && task_backup
[[ $PERFORM_UPDATE -eq 1 ]] && task_update_system
[[ $PERFORM_AUTOREMOVE -eq 1 ]] && task_autoremove
[[ $PERFORM_CLEAN_DNF -eq 1 ]] && task_clean_dnf_cache
[[ $PERFORM_CLEAN_KERNELS -eq 1 ]] && task_remove_old_kernels
[[ $PERFORM_CLEAN_USER_CACHE -eq 1 ]] && task_clean_user_cache
[[ $PERFORM_CLEAN_JOURNAL -eq 1 ]] && task_clean_journal
[[ $PERFORM_CLEAN_TEMP -eq 1 ]] && task_clean_temp_files
[[ $PERFORM_UPDATE_GRUB -eq 1 ]] && task_update_grub
[[ $PERFORM_CLEAN_FLATPAK -eq 1 ]] && task_clean_flatpak
[[ $PERFORM_OPTIMIZE_RPMDB -eq 1 ]] && task_optimize_rpmdb
[[ $PERFORM_RESET_FAILED_UNITS -eq 1 ]] && task_reset_failed_units
[[ $PERFORM_UPDATE_FONTS -eq 1 ]] && task_update_font_cache
[[ $PERFORM_CLEAR_HISTORY -eq 1 ]] && task_clear_bash_history
[[ $PERFORM_TRIM -eq 1 ]] && task_ssd_trim
[[ $PERFORM_CLEAN_SNAP -eq 1 ]] && task_clean_snap
[[ $PERFORM_UPDATE_MANDB -eq 1 ]] && task_update_mandb

# Final Summary
print_header "Cleanup Summary"
final_disk_usage=$(df -h /)
log_msg "Initial Disk Usage:"
log_msg "$initial_disk_usage"
log_msg "Final Disk Usage:"
log_msg "$final_disk_usage"

if [[ $ERROR_COUNT -gt 0 ]]; then
    log_error "Script finished with $ERROR_COUNT error(s). Please review the log: $LOG_FILE"
    exit 1
else
    log_msg "System cleanup completed successfully!"
    exit 0
fi
