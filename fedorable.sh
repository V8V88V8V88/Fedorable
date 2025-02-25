#!/bin/bash

print_message() {
    echo "===> $1"
}

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or using sudo."
    exit 1
fi

# Enable error handling
set -euo pipefail

# Create a backup of important configuration files
print_message "Creating backup of important system configurations"
BACKUP_DIR="/root/system_backup_$(date +%Y%m%d)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/dnf "$BACKUP_DIR"
cp /etc/fstab "$BACKUP_DIR"
cp /etc/default/grub "$BACKUP_DIR"

# System updates
print_message "Updating package list and system"
dnf check-upgrade
dnf upgrade -y

# Remove unused packages and dependencies
print_message "Removing unused packages and dependencies"
dnf autoremove -y

# Clean DNF cache and metadata
print_message "Cleaning DNF cache and metadata"
dnf clean all
dnf clean dbcache
dnf makecache

# Remove old kernels (keep last 2)
print_message "Removing old kernels"
dnf remove $(dnf repoquery --installonly --latest-limit=-2 -q) -y || true

# Clean user cache
print_message "Cleaning user cache"
find /home/ -type f -name '.thumbnails' -exec rm -rf {} +
find /home/ -type f -name '.cache' -exec rm -rf {} +

# Clean system journal
print_message "Cleaning system journal"
journalctl --vacuum-time=7d
journalctl --rotate
journalctl --vacuum-size=500M

# Remove temporary files
print_message "Removing temporary files"
find /tmp -type f -atime +10 -delete
find /var/tmp -type f -atime +10 -delete

# Clean package manager cache
print_message "Cleaning package manager cache"
dnf remove $(dnf leaves) -y || true

# Update GRUB configuration
print_message "Updating GRUB configuration"
grub2-mkconfig -o /boot/grub2/grub.cfg

# Clean and optimize flatpak
print_message "Cleaning Flatpak"
flatpak uninstall --unused -y
flatpak repair
flatpak update -y

# Clean and optimize RPM database
print_message "Optimizing RPM database"
rpm --rebuilddb

# Clear systemd failed units
print_message "Clearing failed systemd units"
systemctl reset-failed

# Update font cache
print_message "Updating font cache"
fc-cache -f -v

# Clear bash history
print_message "Clearing bash history"
> /root/.bash_history
find /home -name ".bash_history" -exec sh -c '> {}' \;

# Optimize SSD if present
print_message "Checking and optimizing SSD if present"
if [ -x "$(command -v fstrim)" ]; then
    fstrim -av
fi

# Cleanup snap if installed
if command -v snap &> /dev/null; then
    print_message "Cleaning snap packages"
    snap set system refresh.retain=2
    snap list --all | awk '/disabled/{print $1, $3}' | while read snapname revision; do
        snap remove "$snapname" --revision="$revision"
    done
fi

# Clear thumbnail cache
print_message "Clearing thumbnail cache"
find /home -type d -name ".thumbnails" -exec rm -rf {} +

# Update man database
print_message "Updating man database"
mandb

print_message "System cleanup completed successfully!"

# Print system space freed
df -h /