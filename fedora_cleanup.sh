#!/bin/bash

print_message() {
    echo "===> $1"
}

if [ "$EUID" -ne 0 ]; then
    echo "Please run this script as root or using sudo."
    exit 1
fi

print_message "Updating package list"
dnf check-update

print_message "Removing unused packages and dependencies"
dnf autoremove -y

print_message "Cleaning DNF cache"
dnf clean all

print_message "Removing old kernels"
dnf remove $(dnf repoquery --installonly --latest-limit=-2 -q)

print_message "Cleaning user cache"
rm -rf /home/*/.cache/*

print_message "Cleaning system journal"
journalctl --vacuum-time=7d

print_message "Removing temporary files"
rm -rf /tmp/*

print_message "Removing orphaned packages"
dnf list leaf | xargs dnf remove -y

print_message "Cleanup completed!"
