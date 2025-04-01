#!/bin/bash

# Fedorable - Advanced Fedora System Maintenance Script
# Version: 3.0
# Author: AI Collaboration (Based on v2.0 + User Feedback)
# Usage: sudo ./fedorable.sh [OPTIONS]
#
# Performs system updates, cleanup, optimizations, backups, and checks.
# Requires root privileges. Use with caution. Review --help output.

# Strict error handling
set -euo pipefail

# --- Configuration (Defaults - Can be overridden by /etc/fedorable.conf) ---
readonly SCRIPT_NAME=$(basename "$0")
readonly LOG_DIR="/var/log/fedorable"
readonly LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}_$(date +%Y%m%d_%H%M%S).log"
readonly BACKUP_BASE_DIR="/root/system_backups"
readonly KERNELS_TO_KEEP=2
readonly JOURNAL_VACUUM_TIME="7d"
readonly JOURNAL_VACUUM_SIZE="500M"
readonly TEMP_FILE_AGE_DAYS=10
readonly MIN_DISK_SPACE_MB=1024
readonly TIMESHIFT_COMMENT_TAG="fedorable-auto" # Label/Comment prefix for snapshots
readonly TIMESHIFT_MAX_SNAPSHOTS=3           # Max auto snapshots to keep
readonly LOCK_FILE="/var/run/fedorable.lock" # Use /var/run standard location
readonly USER_CONFIG_FILE="/etc/fedorable.conf"
readonly DEFAULT_EMAIL_RECIPIENT="root@localhost"
readonly DEFAULT_EMAIL_SUBJECT="Fedorable System Maintenance Report ($(hostname))"

# --- Script Flags & Defaults (Can be changed by config or args) ---
declare -i PERFORM_TIMESHIFT=0           # Default OFF - Requires Timeshift setup
declare -i PERFORM_BACKUP=0              # Default OFF - User must enable explicit backup
declare -i PERFORM_UPDATE=1
declare -i PERFORM_UPDATE_FIRMWARE=0     # Default OFF - Can take time, user opt-in
declare -i PERFORM_AUTOREMOVE=1
declare -i PERFORM_CLEAN_DNF=1
declare -i PERFORM_CLEAN_KERNELS=1
declare -i PERFORM_CLEAN_USER_CACHE=1
declare -i PERFORM_CLEAN_JOURNAL=1
declare -i PERFORM_CLEAN_TEMP=1
declare -i PERFORM_CLEAN_COREDUMPS=1
declare -i PERFORM_UPDATE_GRUB=1
declare -i PERFORM_CLEAN_FLATPAK=1
declare -i PERFORM_OPTIMIZE_RPMDB=1
declare -i PERFORM_RESET_FAILED_UNITS=1
declare -i PERFORM_UPDATE_FONTS=1
declare -i PERFORM_CLEAR_HISTORY=0       # Default OFF - Safety
declare -i PERFORM_TRIM=1                # Manual trim run
declare -i PERFORM_OPTIMIZE_FSTRIM=1     # Check fstrim.timer
declare -i PERFORM_CLEAN_SNAP=1
declare -i PERFORM_UPDATE_MANDB=1
declare -i PERFORM_CHECK_SERVICES=1

# --- Control Flags ---
declare -i CHECK_ONLY=0 # Check for updates without applying
declare -i FORCE_YES=0  # Skip confirmations
declare -i SHOW_HELP=0
declare -i ERROR_COUNT=0
declare -i QUIET_MODE=0 # Suppress console output (still logs)
declare -i DRY_RUN=0    # Show what would be done
declare -i EMAIL_REPORT=0
declare EMAIL_RECIPIENT="$DEFAULT_EMAIL_RECIPIENT"
declare EMAIL_SUBJECT="$DEFAULT_EMAIL_SUBJECT"

# --- Helper Functions ---
log_msg() {
    local timestamp="[$(date +'%Y-%m-%d %H:%M:%S')]"
    local level="[INFO]"
    local message="$1"
    [[ $QUIET_MODE -ne 1 ]] && echo "$timestamp $level $message"
    echo "$timestamp $level $message" >> "$LOG_FILE"
}
log_error() {
    local timestamp="[$(date +'%Y-%m-%d %H:%M:%S')]"
    local level="[ERROR]"
    local message="$1"
    # Always output errors to stderr, even in quiet mode
    echo "$timestamp $level $message" >&2
    echo "$timestamp $level $message" >> "$LOG_FILE"
    ((ERROR_COUNT++))
}
log_warn() {
    local timestamp="[$(date +'%Y-%m-%d %H:%M:%S')]"
    local level="[WARN]"
    local message="$1"
    [[ $QUIET_MODE -ne 1 ]] && echo "$timestamp $level $message" >&2
    echo "$timestamp $level $message" >> "$LOG_FILE"
}
log_success() {
    local timestamp="[$(date +'%Y-%m-%d %H:%M:%S')]"
    local level="[SUCCESS]"
    local message="$1"
    [[ $QUIET_MODE -ne 1 ]] && echo -e "$timestamp $level \e[32m$message\e[0m" # Green color
    echo "$timestamp $level $message" >> "$LOG_FILE"
}
print_header() {
    [[ $QUIET_MODE -ne 1 ]] && echo -e "\n\e[1;34m=== $1 ===\e[0m" # Bold Blue
    log_msg "=== $1 ==="
}
check_command() {
    command -v "$1" &>/dev/null
}
confirm_action() {
    local prompt="$1"
    if [[ $FORCE_YES -eq 1 || $DRY_RUN -eq 1 ]]; then
        log_msg "[DRY RUN/FORCED] Confirmation skipped for: $prompt"
        return 0 # Yes
    fi
    while true; do
        read -rp "[CONFIRM] $prompt [y/N]: " yn
        case $yn in
            [Yy]* ) log_msg "User confirmed action: $prompt"; return 0;; # Yes
            [Nn]*|"" ) log_warn "User skipped action: $prompt"; return 1;; # No
            * ) echo "Please answer yes (y) or no (n).";;
        esac
    done
}
execute_if_not_dry_run() {
    local cmd_string="$1"
    local description="$2" # Optional description for logging

    if [[ -n "$description" ]]; then
        log_msg "Preparing to execute ($description): $cmd_string"
    else
        log_msg "Preparing to execute: $cmd_string"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log_msg "[DRY RUN] Skipped execution."
        return 0 # Simulate success in dry run
    else
        # Use eval carefully, ensure commands are properly quoted if complex
        eval "$cmd_string"
        local status=$?
        if [[ $status -ne 0 ]]; then
            log_error "Execution failed ($description) with status $status: $cmd_string"
        fi
        return $status
    fi
}
check_status() {
    # Note: Use this *after* execute_if_not_dry_run or direct commands
    # The status is captured by the caller or execute_if_not_dry_run logs errors
    local exit_code=$?
    local task_name="$1"
    if [[ $exit_code -eq 0 ]]; then
        log_success "Task '$task_name' completed successfully."
        return 0
    else
        # Error logged by execute_if_not_dry_run or needs manual logging before calling check_status
        log_error "Task '$task_name' reported failure (Exit Code: $exit_code)."
        return 1
    fi
}
check_disk_space() {
    local path="$1"
    local required_mb="$2"
    local available_kb avail_kb_exit_code
    available_kb=$(df --output=avail -B 1K "$path" | tail -n 1)
    avail_kb_exit_code=$?
    if [[ $avail_kb_exit_code -ne 0 || -z "$available_kb" ]]; then
        log_error "Could not determine available disk space for '$path'."
        return 1
    fi
    local available_mb=$((available_kb / 1024))
    if [[ $available_mb -lt $required_mb ]]; then
        log_error "Insufficient disk space on '$path'. Need ${required_mb}MB, Have ${available_mb}MB."
        return 1
    fi
    log_msg "Disk space check passed for '$path' (${available_mb}MB available >= ${required_mb}MB required)."
    return 0
}
create_lock() {
    if [[ -e "$LOCK_FILE" ]]; then
        local pid=$(cat "$LOCK_FILE")
        # Check if PID exists and is this script
        if ps -p "$pid" -o comm= | grep -q "$(basename "$0")"; then
            log_error "Another instance of $SCRIPT_NAME is already running (PID: $pid). Lock file: $LOCK_FILE"
            exit 1
        else
            log_warn "Stale lock file found (PID: $pid does not exist or is not $SCRIPT_NAME). Removing lock."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    log_msg "Lock file created: $LOCK_FILE (PID: $$)"
}
remove_lock() {
    if [[ -e "$LOCK_FILE" ]] && [[ "$(cat "$LOCK_FILE")" == "$$" ]]; then
        rm -f "$LOCK_FILE"
        log_msg "Lock file removed."
    elif [[ -e "$LOCK_FILE" ]]; then
        log_warn "Lock file exists but PID does not match current process. Not removing."
    fi
}
load_user_config() {
    if [[ -f "$USER_CONFIG_FILE" ]]; then
        log_msg "Loading configuration from $USER_CONFIG_FILE"
        # Use source within a subshell for safety? No, need to modify current shell vars.
        # Be cautious about what the config file contains.
        # shellcheck source=/dev/null
        if source "$USER_CONFIG_FILE"; then
            log_msg "User configuration loaded successfully."
            # Re-apply defaults if email vars are empty after sourcing
            EMAIL_RECIPIENT=${EMAIL_RECIPIENT:-$DEFAULT_EMAIL_RECIPIENT}
            EMAIL_SUBJECT=${EMAIL_SUBJECT:-$DEFAULT_EMAIL_SUBJECT}
            return 0
        else
            log_error "Failed to load user configuration from $USER_CONFIG_FILE. Check syntax."
            return 1
        fi
    else
        log_msg "User config file $USER_CONFIG_FILE not found, using defaults."
        return 1 # Indicate config was not loaded
    fi
}
send_email_report() {
    if [[ $EMAIL_REPORT -eq 0 ]]; then
        return 0
    fi
    if ! check_command mail && ! check_command sendmail; then
        log_error "Cannot send email report: 'mail' or 'sendmail' command not found."
        return 1
    fi

    log_msg "Sending email report to $EMAIL_RECIPIENT..."
    local mail_cmd
    if check_command mail; then
        mail_cmd="mail -s \"$EMAIL_SUBJECT\" \"$EMAIL_RECIPIENT\""
    else
        # Basic sendmail usage
        mail_cmd="sendmail \"$EMAIL_RECIPIENT\""
        # Add Subject header for sendmail
        (echo "Subject: $EMAIL_SUBJECT"; echo; cat "$LOG_FILE") | $mail_cmd
        check_status "Send email report via sendmail"
        return $? # Return here as sendmail needs different piping
    fi

    # Execute mail command
    if cat "$LOG_FILE" | $mail_cmd; then
        check_status "Send email report via mail"
        return 0
    else
        log_error "Failed to send email report via mail."
        return 1
    fi
}

# --- Task Functions ---

task_timeshift_snapshot() {
    print_header "Timeshift Snapshot Management"
    if ! check_command timeshift; then
        log_msg "Timeshift command not found. Skipping snapshot tasks."
        return 0
    fi

    # Delete old snapshots first
    log_msg "Checking for old '$TIMESHIFT_COMMENT_TAG' snapshots to prune (Limit: $TIMESHIFT_MAX_SNAPSHOTS)..."
    local snapshots_deleted=0
    # Get snapshots sorted oldest first, filter by comment tag
    local snapshot_list=$(timeshift --list --scripted | grep "$TIMESHIFT_COMMENT_TAG" | sort -k1)
    local snapshot_count=$(echo "$snapshot_list" | wc -l)

    if [[ $snapshot_count -ge $TIMESHIFT_MAX_SNAPSHOTS ]]; then
        local snapshots_to_delete_count=$((snapshot_count - TIMESHIFT_MAX_SNAPSHOTS + 1)) # Keep max-1, delete rest
        log_msg "Found $snapshot_count snapshots. Need to delete $snapshots_to_delete_count oldest snapshots."
        echo "$snapshot_list" | head -n "$snapshots_to_delete_count" | while IFS=$'\t' read -r device uuid mountpoint comment _; do
             log_msg "Deleting old snapshot: $uuid ($comment)"
             execute_if_not_dry_run "timeshift --delete --snapshot '$uuid' --yes" "Delete old Timeshift snapshot $uuid" || log_warn "Failed to delete snapshot $uuid" && snapshots_deleted=1
        done
    else
         log_msg "Found $snapshot_count snapshots. No pruning needed."
    fi

    # Create new snapshot
    log_msg "Creating new Timeshift snapshot with tag '$TIMESHIFT_COMMENT_TAG'..."
    local comment="$TIMESHIFT_COMMENT_TAG created by $SCRIPT_NAME on $(date +%Y-%m-%d_%H:%M:%S)"
    execute_if_not_dry_run "timeshift --create --comments \"$comment\" --yes" "Create Timeshift snapshot"
    check_status "Create Timeshift snapshot"
}

task_backup() {
    print_header "System Configuration Backup"
    local backup_dir="${BACKUP_BASE_DIR}/backup_$(date +%Y%m%d_%H%M%S)"
    log_msg "Backup target directory: $backup_dir"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_msg "[DRY RUN] Would create backup in $backup_dir"
        log_msg "[DRY RUN] Would back up system config files, package lists."
        return 0
    fi

    mkdir -p "$backup_dir" || { log_error "Failed to create backup directory $backup_dir"; return 1; }
    check_status "Create backup directory"

    local files_to_backup=(
        "/etc/dnf" "/etc/fstab" "/etc/default/grub" "/etc/sysconfig/grub"
        "/etc/crypttab" "/etc/dracut.conf.d" "/etc/modprobe.d" "/etc/modules-load.d"
        "/etc/sysctl.conf" "/etc/sysctl.d" "/boot/loader/entries" # systemd-boot
        "/etc/X11/xorg.conf.d" "/etc/environment" "/etc/profile.d"
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
            log_msg "Backup source '$item' does not exist, skipping." # Info, not warning
        fi
    done

    # Backup package lists
    execute_if_not_dry_run "rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > \"$backup_dir/rpm-package-list.txt\"" "Create RPM package list" || success=0
    if check_command flatpak; then
        execute_if_not_dry_run "flatpak list --columns=application,origin,ref > \"$backup_dir/flatpak-list.txt\"" "Create Flatpak package list" || success=0
    fi
    if check_command snap; then
         execute_if_not_dry_run "snap list > \"$backup_dir/snap-list.txt\"" "Create Snap package list" || success=0
    fi

    [[ $success -eq 1 ]] && log_success "Backup completed: $backup_dir" || log_warn "Backup completed with some issues: $backup_dir"
    return $success
}

task_update_system() {
    print_header "System Package Update"
    check_disk_space "/" "$MIN_DISK_SPACE_MB" || return 1

    if [[ $CHECK_ONLY -eq 1 ]]; then
        log_msg "Checking for available system updates..."
        dnf check-update
        local update_status=$?
        if [[ $update_status -eq 0 ]]; then
            log_msg "No package updates available."
        elif [[ $update_status -eq 100 ]]; then
            log_msg "Package updates are available."
        else
            log_error "Error checking for package updates (dnf check-update exit code: $update_status)."
            return 1
        fi
        return 0 # Finished check-only mode
    fi

    log_msg "Performing system package upgrade (dnf upgrade -y)..."
    execute_if_not_dry_run "dnf upgrade -y" "System package upgrade"
    check_status "System package upgrade"
}

task_update_firmware() {
    print_header "System Firmware Update Check"
    if ! check_command fwupdmgr; then
        log_msg "fwupdmgr command not found. Skipping firmware update check."
        return 0
    fi

    log_msg "Refreshing firmware metadata..."
    execute_if_not_dry_run "fwupdmgr refresh --force" "Refresh fwupdmgr metadata"
    check_status "Refresh fwupdmgr metadata" || { log_warn "Failed to refresh firmware metadata, continuing..."; }

    log_msg "Checking for firmware updates..."
    if [[ $DRY_RUN -eq 1 ]]; then
         log_msg "[DRY RUN] Would check for firmware updates using 'fwupdmgr get-updates'"
         return 0
    fi

    # Check if updates are available
    if fwupdmgr get-updates | grep -q "No upgrades"; then
         log_msg "No firmware updates available."
         return 0
    else
         log_warn "Firmware updates are available!"
         fwupdmgr get-updates | tee -a "$LOG_FILE"
         confirm_action "Proceed with applying firmware updates (fwupdmgr update)? THIS MAY REQUIRE A REBOOT." || return 0
         execute_if_not_dry_run "fwupdmgr update -y" "Apply firmware updates"
         check_status "Apply firmware updates" || log_error "Firmware update failed. Check 'fwupdmgr' output."
    fi
}

task_autoremove() {
    print_header "Removing Unused Packages (Autoremove)"
    local packages_to_remove
    packages_to_remove=$(dnf autoremove --assumeno 2>/dev/null | grep -E '^[[:space:]]+Removing:' -A 1000 || true)

    if [[ -z "$packages_to_remove" ]]; then
        log_msg "No unused packages found to remove."
        return 0
    fi

    log_msg "The following packages are identified as unused:"
    echo "$packages_to_remove" | tee -a "$LOG_FILE"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_msg "[DRY RUN] Would remove the above unused packages."
        return 0
    fi

    confirm_action "Proceed with removing unused packages?" || return 0
    execute_if_not_dry_run "dnf autoremove -y" "Remove unused packages"
    check_status "Remove unused packages"
}

task_clean_dnf_cache() {
    print_header "DNF Cache Management"
    log_msg "Cleaning DNF cache (dnf clean all)..."
    execute_if_not_dry_run "dnf clean all" "Clean DNF cache"
    check_status "Clean DNF cache" || return 1 # Fail if cleaning fails

    log_msg "Rebuilding DNF metadata cache (dnf makecache)..."
    execute_if_not_dry_run "dnf makecache" "Rebuild DNF metadata cache"
    check_status "Rebuild DNF metadata cache"
}

task_remove_old_kernels() {
    print_header "Old Kernel Removal (Keep: $KERNELS_TO_KEEP)"
    local installed_kernels_count
    installed_kernels_count=$(rpm -q kernel-core | wc -l)

    if [[ $installed_kernels_count -le $KERNELS_TO_KEEP ]]; then
        log_msg "Found $installed_kernels_count kernel(s). No old kernels to remove (Limit: $KERNELS_TO_KEEP)."
        return 0
    fi

    log_msg "Current installed kernels ($installed_kernels_count):"
    rpm -q kernel-core | tee -a "$LOG_FILE"

    local kernels_to_remove
    kernels_to_remove=$(dnf repoquery --installonly --latest-limit=-${KERNELS_TO_KEEP} -q | tr '\n' ' ' || true)

    if [[ -z "$kernels_to_remove" ]]; then
        log_msg "Could not identify specific old kernels to remove via repoquery, but count ($installed_kernels_count) exceeds limit ($KERNELS_TO_KEEP). Relying on dnf remove."
    else
        log_msg "Kernels identified for potential removal:"
        echo "$kernels_to_remove" | tee -a "$LOG_FILE"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log_msg "[DRY RUN] Would remove old kernels using 'dnf remove --oldinstallonly ...'"
        return 0
    fi

    confirm_action "Proceed with removing old kernels?" || return 0
    execute_if_not_dry_run "dnf remove --oldinstallonly --setopt installonly_limit=$KERNELS_TO_KEEP -y" "Remove old kernels"
    check_status "Remove old kernels"
}

task_clean_user_cache() {
    print_header "User Cache Cleaning (Thumbnails)"
    local cleaned_items=0
    log_msg "Cleaning thumbnail caches for system users..."

    if [[ $DRY_RUN -eq 1 ]]; then
        log_msg "[DRY RUN] Would search for and remove thumbnail caches in /home/*/.cache/thumbnails and /root/.cache/thumbnails"
        return 0
    fi

    shopt -s nullglob # Avoid errors if no matches
    for user_home in /home/* /root; do
        if [[ -d "$user_home" ]]; then
            local thumb_cache_dir="$user_home/.cache/thumbnails"
            local old_thumb_dir="$user_home/.thumbnails" # Legacy

            for cache_dir in "$thumb_cache_dir" "$old_thumb_dir"; do
                 if [[ -d "$cache_dir" ]]; then
                    log_msg "Removing cache: $cache_dir"
                    rm -rf "$cache_dir"
                    if [[ $? -eq 0 ]]; then
                        ((cleaned_items++))
                        log_msg "Successfully removed $cache_dir"
                    else
                        log_error "Failed to remove $cache_dir"
                    fi
                fi
            done
        fi
    done
    shopt -u nullglob # Reset option

    log_msg "Finished cleaning user caches. Removed $cleaned_items directories."
    # Note: Avoided cleaning browser caches as it's intrusive. User can do manually.
}

task_clean_journal() {
    print_header "System Journal Cleanup"
    log_msg "Applying journal vacuum policy (Time: $JOURNAL_VACUUM_TIME, Size: $JOURNAL_VACUUM_SIZE)..."

    execute_if_not_dry_run "journalctl --vacuum-time=$JOURNAL_VACUUM_TIME" "Journal vacuum by time"
    check_status "Journal vacuum by time" || true # Don't stop script if vacuum fails

    execute_if_not_dry_run "journalctl --rotate" "Journal rotate"
    check_status "Journal rotate" || true

    execute_if_not_dry_run "journalctl --vacuum-size=$JOURNAL_VACUUM_SIZE" "Journal vacuum by size"
    check_status "Journal vacuum by size" || true
}

task_clean_temp_files() {
    print_header "Temporary File Cleanup (Age > $TEMP_FILE_AGE_DAYS days)"
    log_msg "Searching for old temporary files in /tmp and /var/tmp..."

    local found_tmp=0 found_var_tmp=0
    if [[ $DRY_RUN -eq 1 ]]; then
        found_tmp=$(find /tmp -type f -atime +"$TEMP_FILE_AGE_DAYS" -print 2>/dev/null | wc -l)
        found_var_tmp=$(find /var/tmp -type f -atime +"$TEMP_FILE_AGE_DAYS" -print 2>/dev/null | wc -l)
        log_msg "[DRY RUN] Would delete $found_tmp file(s) from /tmp."
        log_msg "[DRY RUN] Would delete $found_var_tmp file(s) from /var/tmp."
        return 0
    fi

    # Use -delete for efficiency, capture count separately if needed, but logging is primary
    find /tmp -type f -atime +"$TEMP_FILE_AGE_DAYS" -print -delete -exec log_msg "Deleted temp file: {}" \; 2>/dev/null
    check_status "Delete old files from /tmp" || log_warn "Some errors occurred deleting from /tmp (permissions?)."

    find /var/tmp -type f -atime +"$TEMP_FILE_AGE_DAYS" -print -delete -exec log_msg "Deleted temp file: {}" \; 2>/dev/null
    check_status "Delete old files from /var/tmp" || log_warn "Some errors occurred deleting from /var/tmp (permissions?)."
}

task_clean_coredumps() {
    print_header "System Coredump Cleanup"
    local coredump_dir="/var/lib/systemd/coredump"

    if [[ $DRY_RUN -eq 1 ]]; then
        local coredump_count=0
        if [[ -d "$coredump_dir" ]]; then
            coredump_count=$(find "$coredump_dir" -type f 2>/dev/null | wc -l)
        fi
        log_msg "[DRY RUN] Would remove $coredump_count files from $coredump_dir"
        if check_command coredumpctl; then
             log_msg "[DRY RUN] Would run 'coredumpctl clean'"
        fi
        return 0
    fi

    if [[ -d "$coredump_dir" ]]; then
        log_msg "Removing coredump files from $coredump_dir..."
        find "$coredump_dir" -type f -print -delete -exec log_msg "Deleted coredump: {}" \;
        check_status "Remove coredump files" || log_warn "Failed to remove some coredump files."
    else
        log_msg "Coredump directory $coredump_dir not found."
    fi

    if check_command coredumpctl; then
        log_msg "Cleaning core dumps via coredumpctl..."
        execute_if_not_dry_run "coredumpctl clean" "Clean coredumps via coredumpctl"
        check_status "Clean coredumps via coredumpctl" || log_warn "coredumpctl clean reported issues."
    fi
}

task_update_grub() {
    print_header "GRUB Configuration Update"
    local grub_cfg=""
    local grub_updated=0

    # Try grubby first, as it's often preferred/safer on Fedora
    if check_command grubby; then
        log_msg "Attempting GRUB update using grubby..."
        execute_if_not_dry_run "grubby --update-kernel=ALL" "Update kernel entries via grubby"
        if check_status "Update kernel entries via grubby"; then
            grub_updated=1
            # Check if default kernel was updated
             local default_kernel=$(grubby --default-kernel)
             log_msg "Default kernel set to: $default_kernel"
        else
             log_warn "grubby update failed. Will attempt fallback using grub2-mkconfig."
        fi
    else
        log_msg "grubby command not found. Will use grub2-mkconfig."
    fi

    # Fallback or primary method if grubby failed or wasn't used
    if [[ $grub_updated -eq 0 ]]; then
        if [[ -d /sys/firmware/efi/efivars ]]; then
            log_msg "UEFI system detected."
            if [[ -f /boot/efi/EFI/fedora/grub.cfg ]]; then grub_cfg="/boot/efi/EFI/fedora/grub.cfg";
            elif [[ -f /boot/grub2/grub.cfg ]]; then grub_cfg="/boot/grub2/grub.cfg";
            else log_error "Could not find standard GRUB config path for UEFI."; return 1; fi
        else
            log_msg "BIOS system detected."
            if [[ -f /boot/grub2/grub.cfg ]]; then grub_cfg="/boot/grub2/grub.cfg";
            else log_error "Could not find standard GRUB config path for BIOS."; return 1; fi
        fi
        log_msg "Generating GRUB config to $grub_cfg using grub2-mkconfig..."
        execute_if_not_dry_run "grub2-mkconfig -o \"$grub_cfg\"" "GRUB config generation (grub2-mkconfig)"
        check_status "GRUB config generation (grub2-mkconfig)"
    fi
}

task_clean_flatpak() {
    print_header "Flatpak Management"
    if ! check_command flatpak; then
        log_msg "Flatpak command not found. Skipping."
        return 0
    fi

    log_msg "Uninstalling unused Flatpak runtimes/apps..."
    execute_if_not_dry_run "flatpak uninstall --unused -y" "Flatpak uninstall unused"
    check_status "Flatpak uninstall unused" || true # OK if nothing to remove

    log_msg "Repairing Flatpak installations (user)..."
    execute_if_not_dry_run "flatpak repair --user" "Flatpak repair user"
    check_status "Flatpak repair user" || true

    log_msg "Repairing Flatpak installations (system)..."
    execute_if_not_dry_run "flatpak repair" "Flatpak repair system"
    check_status "Flatpak repair system" || true

    log_msg "Updating Flatpak applications..."
    execute_if_not_dry_run "flatpak update -y" "Flatpak update"
    check_status "Flatpak update" || true # OK if nothing to update
}

task_optimize_rpmdb() {
    print_header "RPM Database Optimization"
    log_msg "Rebuilding RPM database..."
    execute_if_not_dry_run "rpm --rebuilddb" "RPM database rebuild"
    check_status "RPM database rebuild"
}

task_reset_failed_units() {
    print_header "Systemd Failed Units Reset"
    local failed_units
    failed_units=$(systemctl --failed --no-legend | wc -l)

    if [[ $failed_units -eq 0 ]]; then
        log_msg "No failed systemd units found to reset."
        return 0
    fi

    log_warn "Found $failed_units failed systemd units. Resetting..."
    systemctl --failed --no-legend | tee -a "$LOG_FILE"

    execute_if_not_dry_run "systemctl reset-failed" "Reset failed systemd units"
    check_status "Reset failed systemd units"
}

task_update_font_cache() {
    print_header "Font Cache Update"
    log_msg "Updating font cache..."
    local fc_cmd="fc-cache -f"
    [[ $QUIET_MODE -eq 0 ]] && fc_cmd+=" -v" # Add verbose only if not quiet

    execute_if_not_dry_run "$fc_cmd" "Font cache update"
    check_status "Font cache update"
}

task_clear_bash_history() {
    print_header "Shell History Cleanup"

    if [[ $DRY_RUN -eq 1 ]]; then
        log_msg "[DRY RUN] Would clear shell history files (.bash_history, .zsh_history, etc.) for root and users in /home."
        return 0
    fi

    confirm_action "Clear shell history files (bash, zsh, python, mysql) for root and all users in /home? THIS IS PERMANENT" || return 0

    local history_files_patterns=(".bash_history" ".zsh_history" ".python_history" ".mysql_history" ".psql_history")

    # Root user
    for pattern in "${history_files_patterns[@]}"; do
        if [[ -f "/root/$pattern" ]]; then
            log_msg "Clearing /root/$pattern"
            > "/root/$pattern"
            check_status "Clear /root/$pattern" || true
        fi
    done

    # Home users
    shopt -s nullglob
    for user_home in /home/*; do
        if [[ -d "$user_home" ]]; then
            local user=$(basename "$user_home")
            for pattern in "${history_files_patterns[@]}"; do
                 if [[ -f "$user_home/$pattern" ]]; then
                    log_msg "Clearing $user_home/$pattern"
                    # Ensure user owns the file before clearing? Maybe overkill for root script.
                    > "$user_home/$pattern"
                    check_status "Clear $user_home/$pattern" || true
                fi
            done
        fi
    done
    shopt -u nullglob
}

task_ssd_trim() {
    print_header "SSD TRIM Execution"
    if ! check_command fstrim; then
        log_msg "fstrim command not found. Skipping TRIM execution."
        return 0
    fi

    log_msg "Performing TRIM on all mounted filesystems supporting it..."
    execute_if_not_dry_run "fstrim -av" "SSD TRIM operation"
    check_status "SSD TRIM operation" || log_warn "TRIM command reported errors (might be harmless on non-SSD/unsupported filesystems)."
}

task_optimize_fstrim() {
    print_header "fstrim Timer Service Optimization"
    local timer_unit="fstrim.timer"

    if ! systemctl list-unit-files | grep -q "^${timer_unit}"; then
        log_warn "$timer_unit not found. Cannot optimize."
        return 0
    fi

    log_msg "Checking $timer_unit status..."
    if ! systemctl is-enabled --quiet "$timer_unit"; then
        log_msg "$timer_unit is not enabled. Enabling..."
        execute_if_not_dry_run "systemctl enable $timer_unit" "Enable $timer_unit"
        check_status "Enable $timer_unit" || return 1
    else
        log_msg "$timer_unit is already enabled."
    fi

    if ! systemctl is-active --quiet "$timer_unit"; then
        log_msg "$timer_unit is not active. Starting..."
        execute_if_not_dry_run "systemctl start $timer_unit" "Start $timer_unit"
        check_status "Start $timer_unit" || return 1 # Might fail if service file broken
    else
        log_msg "$timer_unit is already active."
    fi

    log_msg "$timer_unit is configured and active."
}

task_clean_snap() {
    print_header "Snap Package Management"
     if ! check_command snap; then
        log_msg "Snap command not found. Skipping."
        return 0
    fi

    log_msg "Setting snap refresh retention to 2..."
    execute_if_not_dry_run "snap set system refresh.retain=2" "Set snap refresh.retain=2"
    check_status "Set snap refresh.retain=2" || true # Non-critical

    log_msg "Removing disabled snap revisions..."
    local snaps_to_remove
    snaps_to_remove=$(snap list --all | awk '/disabled/{print $1 " --revision=" $3}' || true)
    if [[ -n "$snaps_to_remove" ]]; then
        echo "$snaps_to_remove" | while read -r snap_cmd; do
            execute_if_not_dry_run "snap remove $snap_cmd" "Remove disabled snap: $snap_cmd"
            check_status "Remove disabled snap: $snap_cmd" || log_warn "Failed to remove snap: $snap_cmd"
        done
    else
        log_msg "No disabled snap revisions found."
    fi
    log_msg "Finished cleaning snap packages."
}

task_update_mandb() {
    print_header "Man Database Update"
    log_msg "Updating man database index..."
    local mandb_cmd="mandb"
    [[ $QUIET_MODE -eq 1 ]] && mandb_cmd+=" -q" # Quiet mode

    execute_if_not_dry_run "$mandb_cmd" "Man database update"
    check_status "Man database update"
}

task_check_services() {
    print_header "System Services Health Check"
    log_msg "Checking for failed systemd units..."

    local failed_units_list
    failed_units_list=$(systemctl --failed --no-legend || true)
    if [[ -n "$failed_units_list" ]]; then
        log_warn "Found failed systemd units:"
        echo "$failed_units_list" | tee -a "$LOG_FILE"
    else
        log_success "No failed systemd units found."
    fi

    log_msg "Top 10 CPU consuming CGroups:"
    systemd-cgtop -n 1 -b --cpu=auto | head -n 11 | tee -a "$LOG_FILE" || log_warn "Could not get CPU stats via systemd-cgtop."

    log_msg "Top 10 Memory consuming CGroups:"
     systemd-cgtop -n 1 -b --memory=auto | head -n 11 | tee -a "$LOG_FILE" || log_warn "Could not get Memory stats via systemd-cgtop."
}


# --- Argument Parsing ---
usage() {
  echo "Usage: $SCRIPT_NAME [OPTIONS]"
  echo "  Performs advanced system maintenance tasks on Fedora."
  echo
  echo "General Options:"
  echo "  -h, --help            Display this help message and exit."
  echo "  --config FILE         Specify alternative configuration file."
  echo "  -y, --yes             Assume yes to all confirmation prompts."
  echo "  --dry-run             Show what would be done without making changes."
  echo "  -q, --quiet           Suppress normal console output (errors still shown)."
  echo "  --email-report        Send summary log to configured email address."
  echo "  --email-recipient ADDR Override configured email recipient."
  echo "  --email-subject SUBJ  Override configured email subject."
  echo
  echo "Task Selection (Default: Most tasks ON, except Backup, Timeshift, FirmwareUpdate, ClearHistory):"
  echo "  --all                 Enable all standard tasks (does not enable Backup, Timeshift, Firmware, History by default)."
  echo "  --none                Disable all standard tasks (useful with specific --perform-* flags)."
  echo
  echo "  --perform-timeshift   Create a Timeshift snapshot (Requires Timeshift installed)."
  echo "  --perform-backup      Create a system configuration backup."
  echo "  --perform-update-firmware Check for and optionally apply firmware updates (fwupdmgr)."
  echo "  --perform-clear-history Clear shell history files (Use with extreme caution!)."
  echo
  echo "  --no-update           Skip system package update (dnf upgrade)."
  echo "  --check-only          Only check for updates, do not install."
  echo "  --no-autoremove       Skip removing unused packages (dnf autoremove)."
  echo "  --no-clean-dnf        Skip cleaning DNF cache."
  echo "  --no-clean-kernels    Skip removing old kernels."
  echo "  --no-clean-user-cache Skip cleaning user thumbnail caches."
  echo "  --no-clean-journal    Skip cleaning system journal."
  echo "  --no-clean-temp       Skip cleaning temporary files."
  echo "  --no-clean-coredumps  Skip cleaning system coredumps."
  echo "  --no-update-grub      Skip updating GRUB configuration."
  echo "  --no-clean-flatpak    Skip cleaning/updating Flatpak."
  echo "  --no-optimize-rpmdb   Skip optimizing RPM database."
  echo "  --no-reset-failed     Skip resetting failed systemd units."
  echo "  --no-update-fonts     Skip updating font cache."
  echo "  --no-trim             Skip manual SSD TRIM run."
  echo "  --no-optimize-fstrim  Skip checking/enabling fstrim.timer service."
  echo "  --no-clean-snap       Skip cleaning Snap packages."
  echo "  --no-update-mandb     Skip updating man database."
  echo "  --no-check-services   Skip checking service health."
  exit 0
}

# Use getopt for robust parsing
declare -a TEMP_ARGS

# Define long options first, then short options with corresponding long options
# Use temporary array to handle potential quoting issues
TEMP_ARGS=$(getopt -o hyq --long help,config:,yes,dry-run,quiet,email-report,email-recipient:,email-subject:,all,none,perform-timeshift,perform-backup,perform-update-firmware,perform-clear-history,no-update,check-only,no-autoremove,no-clean-dnf,no-clean-kernels,no-clean-user-cache,no-clean-journal,no-clean-temp,no-clean-coredumps,no-update-grub,no-clean-flatpak,no-optimize-rpmdb,no-reset-failed,no-update-fonts,no-trim,no-optimize-fstrim,no-clean-snap,no-update-mandb,no-check-services -n "$SCRIPT_NAME" -- "$@")

if [[ $? -ne 0 ]]; then
  echo "Error parsing options. Use --help for usage." >&2
  exit 1
fi

eval set -- "$TEMP_ARGS"
unset TEMP_ARGS # Clean up temporary args array

# Flag to track if any specific task flag was set
declare -i specific_task_flag_set=0

while true; do
  case "$1" in
    -h | --help) SHOW_HELP=1; shift ;;
    --config) USER_CONFIG_FILE="$2"; shift 2 ;; # Override config file path
    -y | --yes) FORCE_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -q | --quiet) QUIET_MODE=1; shift ;;
    --email-report) EMAIL_REPORT=1; shift ;;
    --email-recipient) EMAIL_RECIPIENT="$2"; shift 2 ;;
    --email-subject) EMAIL_SUBJECT="$2"; shift 2 ;;

    --all) # Reset standard tasks to ON (but not the dangerous/optional ones)
        PERFORM_UPDATE=1; PERFORM_AUTOREMOVE=1; PERFORM_CLEAN_DNF=1;
        PERFORM_CLEAN_KERNELS=1; PERFORM_CLEAN_USER_CACHE=1; PERFORM_CLEAN_JOURNAL=1;
        PERFORM_CLEAN_TEMP=1; PERFORM_CLEAN_COREDUMPS=1; PERFORM_UPDATE_GRUB=1;
        PERFORM_CLEAN_FLATPAK=1; PERFORM_OPTIMIZE_RPMDB=1; PERFORM_RESET_FAILED_UNITS=1;
        PERFORM_UPDATE_FONTS=1; PERFORM_TRIM=1; PERFORM_OPTIMIZE_FSTRIM=1;
        PERFORM_CLEAN_SNAP=1; PERFORM_UPDATE_MANDB=1; PERFORM_CHECK_SERVICES=1;
        specific_task_flag_set=1; shift ;; # Indicate a selection was made
    --none) # Disable all standard tasks
        PERFORM_UPDATE=0; PERFORM_AUTOREMOVE=0; PERFORM_CLEAN_DNF=0;
        PERFORM_CLEAN_KERNELS=0; PERFORM_CLEAN_USER_CACHE=0; PERFORM_CLEAN_JOURNAL=0;
        PERFORM_CLEAN_TEMP=0; PERFORM_CLEAN_COREDUMPS=0; PERFORM_UPDATE_GRUB=0;
        PERFORM_CLEAN_FLATPAK=0; PERFORM_OPTIMIZE_RPMDB=0; PERFORM_RESET_FAILED_UNITS=0;
        PERFORM_UPDATE_FONTS=0; PERFORM_TRIM=0; PERFORM_OPTIMIZE_FSTRIM=0;
        PERFORM_CLEAN_SNAP=0; PERFORM_UPDATE_MANDB=0; PERFORM_CHECK_SERVICES=0;
        specific_task_flag_set=1; shift ;; # Indicate a selection was made

    # Explicitly enabling tasks
    --perform-timeshift) PERFORM_TIMESHIFT=1; specific_task_flag_set=1; shift ;;
    --perform-backup) PERFORM_BACKUP=1; specific_task_flag_set=1; shift ;;
    --perform-update-firmware) PERFORM_UPDATE_FIRMWARE=1; specific_task_flag_set=1; shift ;;
    --perform-clear-history) PERFORM_CLEAR_HISTORY=1; specific_task_flag_set=1; shift ;;

    # Disabling standard tasks
    --no-update) PERFORM_UPDATE=0; specific_task_flag_set=1; shift ;;
    --check-only) CHECK_ONLY=1; PERFORM_UPDATE=1; specific_task_flag_set=1; shift ;; # Enable update task for check
    --no-autoremove) PERFORM_AUTOREMOVE=0; specific_task_flag_set=1; shift ;;
    --no-clean-dnf) PERFORM_CLEAN_DNF=0; specific_task_flag_set=1; shift ;;
    --no-clean-kernels) PERFORM_CLEAN_KERNELS=0; specific_task_flag_set=1; shift ;;
    --no-clean-user-cache) PERFORM_CLEAN_USER_CACHE=0; specific_task_flag_set=1; shift ;;
    --no-clean-journal) PERFORM_CLEAN_JOURNAL=0; specific_task_flag_set=1; shift ;;
    --no-clean-temp) PERFORM_CLEAN_TEMP=0; specific_task_flag_set=1; shift ;;
    --no-clean-coredumps) PERFORM_CLEAN_COREDUMPS=0; specific_task_flag_set=1; shift ;;
    --no-update-grub) PERFORM_UPDATE_GRUB=0; specific_task_flag_set=1; shift ;;
    --no-clean-flatpak) PERFORM_CLEAN_FLATPAK=0; specific_task_flag_set=1; shift ;;
    --no-optimize-rpmdb) PERFORM_OPTIMIZE_RPMDB=0; specific_task_flag_set=1; shift ;;
    --no-reset-failed) PERFORM_RESET_FAILED_UNITS=0; specific_task_flag_set=1; shift ;;
    --no-update-fonts) PERFORM_UPDATE_FONTS=0; specific_task_flag_set=1; shift ;;
    --no-trim) PERFORM_TRIM=0; specific_task_flag_set=1; shift ;;
    --no-optimize-fstrim) PERFORM_OPTIMIZE_FSTRIM=0; specific_task_flag_set=1; shift ;;
    --no-clean-snap) PERFORM_CLEAN_SNAP=0; specific_task_flag_set=1; shift ;;
    --no-update-mandb) PERFORM_UPDATE_MANDB=0; specific_task_flag_set=1; shift ;;
    --no-check-services) PERFORM_CHECK_SERVICES=0; specific_task_flag_set=1; shift ;;

    --) shift; break ;;
    *) echo "Internal error processing options!" >&2 ; exit 1 ;;
  esac
done

# --- Main Execution ---

# Show help if requested
if [[ $SHOW_HELP -eq 1 ]]; then
    usage
fi

# Check for root privileges early
if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root or using sudo." >&2
    exit 1
fi

# Setup Logging directory and file
mkdir -p "$LOG_DIR" || { echo "ERROR: Could not create log directory: $LOG_DIR" >&2; exit 1; }
touch "$LOG_FILE" || { echo "ERROR: Could not create log file: $LOG_FILE" >&2; exit 1; }
chmod 600 "$LOG_FILE" # Restrict log file access

# Create lock file and set trap for cleanup
create_lock
trap remove_lock EXIT INT TERM # Ensure lock is removed on exit/interrupt

log_msg "--- Fedorable System Maintenance Script (v3.0) Started ---"
log_msg "PID: $$"
log_msg "Log File: $LOG_FILE"
[[ $DRY_RUN -eq 1 ]] && log_warn "*** DRY RUN MODE ENABLED - NO CHANGES WILL BE MADE ***"

# Load user config if it exists
load_user_config

log_msg "Effective Task Flags:"
printf "  Timeshift: %d, Backup: %d, Update: %d, CheckOnly: %d, FirmwareUpdate: %d, Autoremove: %d, CleanDNF: %d, CleanKernels: %d\n" \
       "$PERFORM_TIMESHIFT" "$PERFORM_BACKUP" "$PERFORM_UPDATE" "$CHECK_ONLY" "$PERFORM_UPDATE_FIRMWARE" "$PERFORM_AUTOREMOVE" "$PERFORM_CLEAN_DNF" "$PERFORM_CLEAN_KERNELS" | tee -a "$LOG_FILE"
printf "  CleanUserCache: %d, CleanJournal: %d, CleanTemp: %d, CleanCoredumps: %d, UpdateGRUB: %d, CleanFlatpak: %d, OptimizeRPMDB: %d\n" \
       "$PERFORM_CLEAN_USER_CACHE" "$PERFORM_CLEAN_JOURNAL" "$PERFORM_CLEAN_TEMP" "$PERFORM_CLEAN_COREDUMPS" "$PERFORM_UPDATE_GRUB" "$PERFORM_CLEAN_FLATPAK" "$PERFORM_OPTIMIZE_RPMDB" | tee -a "$LOG_FILE"
printf "  ResetFailedUnits: %d, UpdateFonts: %d, ClearHistory: %d, Trim: %d, OptimizeFstrim: %d, CleanSnap: %d, UpdateManDB: %d, CheckServices: %d\n" \
       "$PERFORM_RESET_FAILED_UNITS" "$PERFORM_UPDATE_FONTS" "$PERFORM_CLEAR_HISTORY" "$PERFORM_TRIM" "$PERFORM_OPTIMIZE_FSTRIM" "$PERFORM_CLEAN_SNAP" "$PERFORM_UPDATE_MANDB" "$PERFORM_CHECK_SERVICES" | tee -a "$LOG_FILE"
log_msg "Control Flags: ForceYes=$FORCE_YES, Quiet=$QUIET_MODE, DryRun=$DRY_RUN, EmailReport=$EMAIL_REPORT"
[[ $EMAIL_REPORT -eq 1 ]] && log_msg "Email Recipient: $EMAIL_RECIPIENT, Subject: $EMAIL_SUBJECT"


initial_disk_usage=$(df -h /)

# --- Execute Tasks ---
# Safety First: Snapshots and Backups
[[ $PERFORM_TIMESHIFT -eq 1 ]] && task_timeshift_snapshot
[[ $PERFORM_BACKUP -eq 1 ]] && task_backup

# Updates
[[ $PERFORM_UPDATE -eq 1 ]] && task_update_system
[[ $PERFORM_UPDATE_FIRMWARE -eq 1 ]] && task_update_firmware

# Package Cleanup
[[ $PERFORM_AUTOREMOVE -eq 1 ]] && task_autoremove
[[ $PERFORM_CLEAN_DNF -eq 1 ]] && task_clean_dnf_cache
[[ $PERFORM_CLEAN_KERNELS -eq 1 ]] && task_remove_old_kernels
[[ $PERFORM_CLEAN_FLATPAK -eq 1 ]] && task_clean_flatpak
[[ $PERFORM_CLEAN_SNAP -eq 1 ]] && task_clean_snap

# System File/Cache Cleanup
[[ $PERFORM_CLEAN_USER_CACHE -eq 1 ]] && task_clean_user_cache
[[ $PERFORM_CLEAN_JOURNAL -eq 1 ]] && task_clean_journal
[[ $PERFORM_CLEAN_TEMP -eq 1 ]] && task_clean_temp_files
[[ $PERFORM_CLEAN_COREDUMPS -eq 1 ]] && task_clean_coredumps
[[ $PERFORM_CLEAR_HISTORY -eq 1 ]] && task_clear_bash_history # Risky, keep later

# System Configuration & Optimization
[[ $PERFORM_UPDATE_GRUB -eq 1 ]] && task_update_grub
[[ $PERFORM_OPTIMIZE_RPMDB -eq 1 ]] && task_optimize_rpmdb
[[ $PERFORM_RESET_FAILED_UNITS -eq 1 ]] && task_reset_failed_units
[[ $PERFORM_UPDATE_FONTS -eq 1 ]] && task_update_font_cache
[[ $PERFORM_TRIM -eq 1 ]] && task_ssd_trim
[[ $PERFORM_OPTIMIZE_FSTRIM -eq 1 ]] && task_optimize_fstrim
[[ $PERFORM_UPDATE_MANDB -eq 1 ]] && task_update_mandb

# Checks
[[ $PERFORM_CHECK_SERVICES -eq 1 ]] && task_check_services

# --- Final Summary ---
print_header "Maintenance Summary"
final_disk_usage=$(df -h /)
log_msg "Initial Disk Usage (/):"
log_msg "$initial_disk_usage"
log_msg "Final Disk Usage (/):"
log_msg "$final_disk_usage"

[[ $DRY_RUN -eq 1 ]] && log_warn "*** DRY RUN COMPLETED - NO CHANGES WERE MADE ***"

if [[ $ERROR_COUNT -gt 0 ]]; then
    log_error "Script finished with $ERROR_COUNT error(s). Review log: $LOG_FILE"
    send_email_report # Send report even on errors
    # Lock removed by trap
    exit 1
else
    log_success "System maintenance completed successfully!"
    send_email_report
    # Lock removed by trap
    exit 0
fi