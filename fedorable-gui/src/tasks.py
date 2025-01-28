# src/tasks.py
import subprocess
import os
from pathlib import Path
import datetime

class SystemTasks:
def __init__(self):
if os.geteuid() != 0:
    raise PermissionError("This application must be run as root")
    
    def backup_system_config(self):
    backup_dir = Path(f"/root/system_backup_{datetime.date.today().strftime('%Y%m%d')}")
    backup_dir.mkdir(parents=True, exist_ok=True)
    
    configs = [
    "/etc/dnf",
    "/etc/fstab",
    "/etc/default/grub",
    "/etc/hostname",
    "/etc/hosts"
    ]
    
    for config in configs:
        try:
        if Path(config).exists():
            if Path(config).is_dir():
                subprocess.run(['cp', '-r', config, str(backup_dir)], check=True)
                else:
                subprocess.run(['cp', config, str(backup_dir)], check=True)
                except subprocess.CalledProcessError:
                print(f"Failed to backup {config}")
                
                def update_system(self):
                subprocess.run(['dnf', 'check-upgrade'], check=True)
                subprocess.run(['dnf', 'upgrade', '-y'], check=True)
                
                def cleanup_system(self):
                subprocess.run(['dnf', 'autoremove', '-y'], check=True)
                subprocess.run(['dnf', 'clean', 'all'], check=True)
                subprocess.run(['dnf', 'clean', 'dbcache'], check=True)
                subprocess.run(['dnf', 'makecache'], check=True)
                try:
                subprocess.run(
                    ['dnf', 'remove', '$(dnf repoquery --installonly --latest-limit=-2 -q)', '-y'],
                    shell=True
                )
                except subprocess.CalledProcessError:
                pass
                
                def cleanup_user_data(self):
                subprocess.run(['find', '/home/', '-type', 'f', '-name', '.thumbnails', '-exec', 'rm', '-rf', '{}', '+'])
                subprocess.run(['find', '/home/', '-type', 'f', '-name', '.cache', '-exec', 'rm', '-rf', '{}', '+'])
                subprocess.run(['>', '/root/.bash_history'], shell=True)
                subprocess.run(['find', '/home', '-name', '.bash_history', '-exec', 'sh', '-c', '> {}', ';'])
                
                def optimize_system(self):
                subprocess.run(['grub2-mkconfig', '-o', '/boot/grub2/grub.cfg'], check=True)
