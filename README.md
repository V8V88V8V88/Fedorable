# Fedora Cleanup Script

This script automates the process of cleaning up and maintaining a Fedora Linux system. It removes unnecessary packages, cleans caches, and performs other system maintenance tasks.

## Features

- Updates package list
- Removes unused packages and dependencies
- Cleans DNF cache
- Removes old kernels (keeps current and one previous version)
- Cleans user cache
- Cleans system journal
- Removes temporary files
- Removes orphaned packages

## Requirements

- Fedora Linux (tested on Fedora 40 with GNOME 46)
- Root or sudo access

## Usage

1. Save the script to a file (e.g., `fedora_cleanup.sh`)
2. Make the script executable:
   ```
   chmod +x fedora_cleanup.sh
   ```
3. Run the script with sudo:
   ```
   sudo ./fedora_cleanup.sh
   ```

## Warning

This script removes files and packages from your system. While it's designed to be safe, it's recommended to review the script and understand its actions before running it. Consider backing up important data before executing system-wide cleanup operations.

## Customization

You can modify the script to add or remove cleanup tasks according to your needs. Each task is clearly labeled with a descriptive message.

## Contributing

Feel free to fork this script and submit pull requests for any improvements or additional features you think would be beneficial.

## License

This script is released under the MIT License. See the LICENSE file for details.
