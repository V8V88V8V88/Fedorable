# 🧹 Fedorable: Fedora Cleaning Script

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Fedora Version](https://img.shields.io/badge/Fedora-41+-blue.svg)](https://getfedora.org/)

Fedorable is a command-line utility designed to maintain and optimize your Fedora Linux system. It automates common cleanup tasks to keep your Fedora installation efficient and well-maintained.

## ✨ Features

- **DNF5 Integration**: Utilizes the full capabilities of DNF5
- **Comprehensive Cleaning**: Manages package caches, old kernels, and more
- **System Safety**: Implements non-destructive operations with clear feedback
- **Performance Optimization**: Improves system efficiency through targeted cleanup tasks

## 🧼 Cleanup Tasks

Fedorable performs the following cleanup operations:

1. **Package List Update**: Refreshes the list of available packages.
2. **Unused Package Removal**: Removes packages that were automatically installed as dependencies but are no longer required.
3. **DNF Cache Cleaning**: Clears the DNF cache to free up disk space.
4. **Old Kernel Removal**: Removes old kernel versions, keeping only the current and one previous version.
5. **User Cache Cleaning**: Clears user-specific cache files from `/home/*/.cache/`.
6. **System Journal Cleanup**: Removes old systemd journal logs.
7. **Temporary File Removal**: Clears temporary files from `/tmp/`.
8. **Orphaned Package Removal**: Removes packages that are no longer part of any repository.

## 🛠 Installation

1. Clone this repository:
   ```
   git clone https://github.com/yourusername/fedorable.git
   cd fedorable
   ```

2. Make the script executable:
   ```
   chmod +x fedorable.sh
   ```

## 🚀 Usage

Execute the script with sudo privileges:

```
sudo ./fedorable.sh
```

The script will guide you through the cleaning process, providing feedback at each step.

## 🔧 Customization

To customize the cleanup process, edit `fedorable.sh` in your preferred text editor. You can modify, add, or remove cleaning tasks as needed.

## 🤝 Contributing

Contributions are welcome, including bug reports, feature requests, and pull requests. Please refer to our [contribution guidelines](CONTRIBUTING.md) for more information.

## 🔒 Security

This script performs system-wide operations. Always review scripts that require sudo privileges before execution. While we prioritize system safety, user discretion is advised.

## 📜 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙌 Acknowledgements

- The Fedora community
- The DNF team for their robust package management tool
- All users and contributors of this project

---

Enhance your Fedora system's performance with Fedorable. If you find this tool useful, please consider starring ⭐ the repository.