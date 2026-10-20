<div align="center">

# Fedorable

**An adorable Fedora maintenance script.**

[![Fedora 44 | 45](https://img.shields.io/badge/Fedora-44%20%7C%2045-51A2DA?style=for-the-badge&logo=fedora&logoColor=white)](https://fedoraproject.org)
[![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnubash&logoColor=white)](https://www.gnu.org/software/bash/)
[![DNF5](https://img.shields.io/badge/DNF5-294172?style=for-the-badge&logo=fedora&logoColor=white)](https://github.com/rpm-software-management/dnf5)
[![Flatpak](https://img.shields.io/badge/Flatpak-4A90D9?style=for-the-badge&logo=flatpak&logoColor=white)](https://flatpak.org)
[![systemd](https://img.shields.io/badge/systemd-30D475?style=for-the-badge&logo=linux&logoColor=black)](https://systemd.io)

[![Version](https://img.shields.io/badge/version-6.0.0-blue?style=flat-square)](https://github.com/V8V88V8V88/Fedorable/releases)
[![Checks](https://img.shields.io/github/actions/workflow/status/V8V88V8V88/Fedorable/check.yml?branch=main&style=flat-square&label=checks)](https://github.com/V8V88V8V88/Fedorable/actions/workflows/check.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Stars](https://img.shields.io/github/stars/V8V88V8V88/Fedorable?style=flat-square)](https://github.com/V8V88V8V88/Fedorable/stargazers)

<img src="docs/menu.png" alt="Fedorable main menu" width="720">

</div>

Fedorable gathers the usual Fedora upkeep into one small terminal menu. You pick a plan, see exactly what it will do, and only then let it run. It handles package updates, old kernels, logs, temporary files and Flatpaks.

<p align="center">
  <img src="docs/task.png" alt="Fedorable running the recommended plan" width="560">
</p>

## Install

Copy and paste this into a terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/V8V88V8V88/Fedorable/main/install.sh | sudo bash
```

That's it. Fedorable is installed to `/opt/fedorable`, and you can start it from anywhere:

```bash
fedorable
```

You don't need to start it with `sudo`. Once you confirm a plan, Fedorable asks for your password only if the tasks need it.

Running the same command again updates it to the latest version. To remove it:

```bash
curl -fsSL https://raw.githubusercontent.com/V8V88V8V88/Fedorable/main/install.sh | sudo bash -s -- --uninstall
```

## Try it without installing

```bash
git clone https://github.com/V8V88V8V88/Fedorable.git
cd Fedorable
./fedorable.sh --recommended --dry-run
```

A dry run doesn't need root. It shows you the commands it would run and reads a little local information, like free disk space and installed kernels. It won't change anything, contact any repositories or write logs.

When you're happy with what you see, open the menu:

```bash
./fedorable.sh
```

Keep the folder together, because `fedorable.sh` loads its pieces from `lib/`. You don't need Python, pip or anything graphical to use it.

## Plans

**Recommended** (`--recommended`, or just press Enter in the menu) updates your Fedora packages, clears the DNF download cache, removes expired temporary files and runs TRIM. It leaves installed packages, kernels, logs and Flatpaks alone. It's a careful default, but it still changes things: updates install new software, expired temp files are deleted, and cleared packages may have to be downloaded again later.

**Basic cleanup** (`--cleanup`, menu option 2) removes unused packages, the DNF download cache, older kernels, archived logs, expired temp files, unused Flatpak runtimes, desktop thumbnails and expired coredumps, then runs TRIM. It doesn't install any updates.

**Updates only** (`--updates`, menu option 3) updates Fedora packages and system Flatpak apps, and does no cleanup.

**Choose tasks** (menu option 4) lets you build your own plan from the full task list. Type numbers like `3,4,6`, names like `journal,temp`, or mix the two. Type `b` to go back. If you make a typo, just try again. On the command line, use task names:

```bash
sudo ./fedorable.sh --tasks journal,temp
sudo ./fedorable.sh --cleanup --no-kernels
sudo ./fedorable.sh --none --update --flatpak
```

If you want every update and every cleanup task at once, use `--full`. `--minimal` only updates Fedora packages.

### Tasks

| Task | What it does |
| --- | --- |
| `update` | Updates Fedora packages |
| `flatpak` | Updates system Flatpak apps |
| `clean-dnf` | Clears downloaded DNF packages |
| `autoremove` | Removes packages DNF marks as unused |
| `kernels` | Removes older kernels |
| `journal` | Rotates and trims system logs |
| `temp` | Cleans expired temporary files |
| `clean-flatpak` | Removes unused Flatpak runtimes |
| `thumbnails` | Clears the desktop thumbnail cache |
| `coredumps` | Cleans expired coredumps |
| `trim` | Runs TRIM on supported filesystems |
| `boot-report` | Shows boot time and the slowest service chain |
| `failed` | Clears the failed status of systemd units |

Every task can be turned on with `--NAME` or off with `--no-NAME`, and these switches always override the plan, wherever you put them. If you turn a task both on and off, off wins. Each task runs once, in a sensible order.

`failed` only clears systemd's failed status. It doesn't fix the broken service, which is why no plan includes it.

## Scripts and automation

```bash
./fedorable.sh --check-only
sudo ./fedorable.sh --full --yes
sudo ./fedorable.sh --tasks journal,temp --yes --quiet
```

`--check-only` asks DNF whether updates are available and does nothing else. It can't be combined with a plan or tasks. DNF may still refresh its metadata and write its own logs, so add `--dry-run` if you don't want DNF to run at all.

When there's no terminal to type in, you have to name a plan or tasks and add `--yes`. `--quiet` hides the banner and progress messages, but command output and errors still show.

In a normal terminal you get the animated blue logo while the menu waits for you. The animation needs a window of at least 80×22 and stops if you resize it. Use `--no-animation` for a still logo, or set `NO_COLOR=1` for plain text. If you redirect the output, colors and animation are turned off automatically, and log files never contain color codes.

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success, a dry run, or you said no at the prompt |
| `1` | A task failed or the command was wrong |
| `130` | Interrupted with Ctrl+C |
| `143` | Stopped by the system |

`--check-only` returns `0` whether or not updates are available. The output tells you which.

## What it touches

- **Kernels:** keeps the newest three by default and never removes the one you're running. If the kernel list can't be read, nothing is removed. If the package update fails, autoremove and kernel cleanup are skipped.
- **Logs:** rotates the system journal, then deletes archived logs older than 14 days or beyond 1 GB. The current log files aren't counted toward that limit.
- **Temporary files:** follows Fedora's own `systemd-tmpfiles` rules for `/tmp` and `/var/tmp`.
- **Flatpaks:** only touches system-wide installs. Per-user apps can be updated by that user with `flatpak --user update`.
- **Thumbnails:** only deletes files inside your own `~/.cache/thumbnails`, and runs as you rather than as root. Thumbnails are recreated as you browse. System accounts and unsafe home folders are refused.
- **Coredumps:** follows systemd's expiry rules for `/var/lib/systemd/coredump`.
- **Boot report:** only shows information and changes nothing.
- **Missing tools:** if Flatpak, `fstrim` or `systemd-analyze` isn't installed, that task is skipped. Any other missing tool counts as a failure.

Real runs take a lock so two copies can't run at once, and they write a private log to `/var/log/fedorable/`. Any failure shows up in the summary and gives a nonzero exit code. Cleanup deletes data and there's no undo, so read the plan first, especially on a machine you rely on.

At the end you get a summary showing how each task went, why anything was skipped or failed, how long the run took, and how much free space `/` gained or lost. A task can succeed with nothing to remove; the command output will show that. The space figure includes updates and anything else happening on the system, so treat it as a rough number. TRIM doesn't free up space, it only tells the drive which blocks are unused.

Fedorable doesn't touch GRUB, rebuild the RPM database, update firmware, clear your shell history or empty other caches in your home folder.

Clearing caches frees space, but it won't make your system faster. Things may even load a little slower the first time while the cache refills. TRIM is the one task that actually helps drive performance, and `boot-report` helps you find what's slowing down startup before you start disabling services.

## Configuration

The defaults work fine without a config file. If you want to change them:

```bash
cp config/fedorable.conf.example my-fedorable.conf
sudo ./fedorable.sh --cleanup --config my-fedorable.conf
```

```ini
KERNELS_TO_KEEP=3
JOURNAL_VACUUM_TIME=14d
JOURNAL_VACUUM_SIZE=1G
MIN_DISK_SPACE_MB=2048
```

Write one `KEY=value` per line, with no quotes or shell code. Blank lines and `#` comments are fine. An unknown key or a bad value stops the run before anything happens. `KERNELS_TO_KEEP` can be 2 to 99, journal ages end in `d` or `w`, and sizes end in `M` or `G`. A config file is only read when you pass it with `--config`.

## Supported Fedora versions

| Fedora | Package manager | Status |
| --- | --- | --- |
| **45** | DNF5 | ✅ Supported and tested |
| **44** | DNF5 | ✅ Supported and tested |
| 43 | DNF5 | Should work, not tested |
| 41–42 | DNF5 | End of life; should work, but not supported |
| 40 and older | DNF4 | End of life; not supported |
| Atomic desktops (Silverblue, Kinoite…) and CoreOS | rpm-ostree | ❌ Refused, they update differently |

Fedorable runs on regular, DNF-based Fedora Workstation, Server and Spins. It needs Bash 4.4 or newer, coreutils, util-linux, RPM and systemd, which every Fedora install already has. Flatpak and `fstrim` are optional.

Tests use fake versions of the system commands, so a full real run on a spare Fedora machine is still worth doing before a release.

Version 6 replaces the old GUI and Python wrapper with this Bash script. `--all` and the GRUB, firmware, RPM database and user cache tasks are gone, and `--minimal` now only updates packages. Old config files need to be rewritten in the format above.

## Development

```text
install.sh     one-line installer
fedorable.sh   entry point
lib/cli.sh     options, config and run flow
lib/tasks.sh   maintenance tasks
lib/ui.sh      menu and output
config/        example settings
tests/         regression tests
```

Python 3 is only needed for the tests. Install ShellCheck for linting, then run:

```bash
make check
```

When reporting a bug, please include your Fedora version, the exact command you ran and the relevant part of the log. Remove private repository URLs and other personal details first.

## License

[MIT](LICENSE)
