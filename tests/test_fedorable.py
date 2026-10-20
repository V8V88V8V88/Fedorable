import os
import fcntl
import pty
import select
import struct
import termios
import time
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PRELUDE = '''
set -euo pipefail
source lib/ui.sh
source lib/tasks.sh
source lib/cli.sh
setup_ui
'''


def shell(code, *args):
    return subprocess.run(
        ['bash', '-c', PRELUDE + code, 'test', *args],
        cwd=ROOT, capture_output=True, text=True, timeout=10,
        env={**os.environ, 'NO_COLOR': '1'},
    )


class FedorableTests(unittest.TestCase):
    def test_logo_keeps_animating_until_menu_submission(self):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 40, 100, 0, 0))
        env = {**os.environ, 'TERM': 'xterm-256color'}
        env.pop('NO_COLOR', None)
        process = subprocess.Popen(['bash', 'fedorable.sh', '--dry-run'], cwd=ROOT,
                                   stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        output = b''
        submitted = False
        deadline = time.monotonic() + 10
        try:
            while time.monotonic() < deadline:
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output += os.read(master, 65536)
                    except OSError:
                        break
                if not submitted and output.count(b'\x1b[17A') >= 3:
                    os.write(master, b'2\x7f0\n')
                    submitted = True
                if process.poll() is not None:
                    break
            self.assertTrue(submitted, 'Logo did not keep animating while waiting for input')
            self.assertEqual(process.wait(timeout=2), 0)
            self.assertNotIn(b'Your maintenance plan', output)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)

    def test_shell_syntax(self):
        for path in [ROOT / 'fedorable.sh', *ROOT.glob('lib/*.sh')]:
            with self.subTest(path=path.name):
                result = subprocess.run(['bash', '-n', str(path)], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_public_help(self):
        result = subprocess.run(['bash', 'fedorable.sh', '--help'], cwd=ROOT,
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--recommended', result.stdout)

    def test_no_mode_noninteractive(self):
        result = shell('main')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Choose --cleanup', result.stderr)

    def test_check_only_rejects_maintenance(self):
        for args in [('--recommended', '--check-only'), ('--check-only', '--temp')]:
            result = shell('parse_args "$@"', *args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('cannot be combined', result.stderr)

    def test_task_overrides_are_order_independent(self):
        for args in [('--no-kernels', '--full'), ('--full', '--no-kernels')]:
            result = shell('parse_args "$@"; printf "%s\\n" "${SELECTED[@]}"', *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn('kernels', result.stdout)
            self.assertIn('update', result.stdout)

    def test_exact_selection_is_deduplicated_and_ordered(self):
        result = shell('parse_args --tasks temp,update,temp; printf "%s\\n" "${SELECTED[@]}"')
        self.assertEqual(result.stdout, 'update\ntemp\n')

    def test_none_with_individual_enable(self):
        result = shell('parse_args --none --journal; printf "%s\\n" "${SELECTED[@]}"')
        self.assertEqual(result.stdout, 'journal\n')

    def test_invalid_arguments(self):
        for args in [('--tasks',), ('--config',), ('--minimal', '--recommended'),
                     ('--tasks', 'temp,'), ('--tasks', 'wat'), ('--all',), ('--no-temp',)]:
            with self.subTest(args=args):
                self.assertNotEqual(shell('parse_args "$@"', *args).returncode, 0)

    def test_config_is_data_not_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / 'config'
            marker = Path(directory) / 'executed'
            config.write_text(f'KERNELS_TO_KEEP=$(touch {marker})\n')
            result = shell('CONFIG_FILE=$1; load_config', str(config))
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())

    def test_config_validation(self):
        for text in ['KERNELS_TO_KEEP=0', 'KERNELS_TO_KEEP=-1', 'DRY_RUN=0',
                     'JOURNAL_VACUUM_TIME=0d', 'MIN_DISK_SPACE_MB=0010']:
            with self.subTest(text=text), tempfile.TemporaryDirectory() as directory:
                config = Path(directory) / 'config'
                config.write_text(text + '\n')
                self.assertNotEqual(shell('CONFIG_FILE=$1; load_config', str(config)).returncode, 0)
        result = shell('CONFIG_FILE=config/fedorable.conf.example; load_config; echo "$KERNELS_TO_KEEP"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '3\n')

    def test_dry_run_never_executes_commands(self):
        result = shell('''
DRY_RUN=1
danger() { echo EXECUTED; return 9; }
run_command danger '$(touch should-not-exist)'
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('EXECUTED', result.stdout)

    def test_check_update_status_codes(self):
        for code in [0, 100, 1]:
            result = shell('dnf() { return ' + str(code) + '; }; check_updates')
            self.assertEqual(result.returncode, 0 if code in (0, 100) else 1)

    def test_check_only_dispatches_no_tasks(self):
        result = shell('''
check_platform() { :; }
dnf() { printf 'CHECK %s\\n' "$*"; return 100; }
prepare_run() { echo BAD_PREPARE; return 9; }
execute_tasks() { echo BAD_TASKS; return 9; }
main --check-only
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('CHECK check-update', result.stdout)
        self.assertNotIn('BAD_', result.stdout)

    def test_journal_failure_stops_vacuum(self):
        result = shell('''
journalctl() { echo "CALL $*"; return 7; }
task_journal
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('--vacuum', result.stdout)

    def test_failure_summary_and_skip_after_failed_update(self):
        result = shell('''
SELECTED=(update autoremove kernels journal)
dnf() { :; }
journalctl() { :; }
task_update() { return 1; }
task_autoremove() { echo BAD_REMOVE; }
task_kernels() { echo BAD_KERNELS; }
task_journal() { return 1; }
execute_tasks
''')
        self.assertEqual(result.returncode, 1)
        self.assertIn('0 completed / 2 skipped / 2 failed', result.stdout)
        self.assertNotIn('BAD_', result.stdout)

    def test_kernel_retention_preserves_running_and_newest(self):
        result = shell('''
KERNELS_TO_KEEP=2
uname() { echo 1.0-1.x86_64; }
rpm() {
    if [[ $* == *--queryformat* ]]; then
        printf '%s\\n' 1.0-1.x86_64 2.0-1.x86_64 3.0-1.x86_64 4.0-1.x86_64
    else return 0; fi
}
run_command() { printf '%s\\n' "$@"; }
task_kernels
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('kernel-core-2.0-1.x86_64', result.stdout)
        for version in ['1.0-1', '3.0-1', '4.0-1']:
            self.assertNotIn(version, result.stdout)
        self.assertNotIn('kernel-headers', result.stdout)

    def test_kernel_inventory_failure_blocks_removal(self):
        result = shell('rpm() { return 1; }; task_kernels')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('dnf remove', result.stdout)

    def test_command_arguments_are_not_evaluated(self):
        result = shell('''
capture() { printf '<%s>\\n' "$@"; }
run_command capture 'hello world' '$(echo INJECTED)' 'a;b'
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('<hello world>\n<$(echo INJECTED)>\n<a;b>', result.stdout)

    def test_logged_command_failure_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'run.log'
            result = shell('LOG_FILE=$1; broken() { echo oops; return 7; }; run_command broken', str(log))
            self.assertEqual(result.returncode, 7)
            self.assertIn('oops', log.read_text())

    def test_preview_main_does_not_prepare_run(self):
        result = shell('''
check_platform() { :; }
journalctl() { echo BAD_COMMAND; return 9; }
prepare_run() { echo BAD_PREPARE; return 9; }
main --tasks journal --dry-run
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 previewed / 0 skipped / 0 failed', result.stdout)
        self.assertNotIn('BAD_', result.stdout)

    def test_unattended_apply_requires_yes(self):
        result = shell('''
check_platform() { :; }
prepare_run() { echo BAD_PREPARE; return 9; }
main --tasks journal
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires --yes', result.stderr)
        self.assertNotIn('BAD_', result.stdout)

    def test_temp_cleanup_uses_system_policy(self):
        result = shell('DRY_RUN=1; task_temp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('systemd-tmpfiles --clean --prefix=/tmp --prefix=/var/tmp', result.stdout)
        self.assertNotIn('--remove', result.stdout)

    def test_thumbnail_cleanup_is_scoped_to_desktop_user(self):
        with tempfile.TemporaryDirectory() as directory:
            thumbnail_dir = Path(directory) / '.cache' / 'thumbnails'
            thumbnail_dir.mkdir(parents=True)
            result = shell('''
TEST_USER_HOME=$1
SUDO_USER=alice
getent() { echo "alice:x:1000:1000:Alice:$TEST_USER_HOME:/bin/bash"; }
run_command() { printf '<%s>\\n' "$@"; }
task_thumbnails
''', directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('<runuser>\n<-u>\n<alice>\n<-->\n<find>', result.stdout)
        self.assertIn(f'<{thumbnail_dir}>', result.stdout)
        self.assertIn('<-type>\n<f>\n<-delete>', result.stdout)
        self.assertNotIn('/home>', result.stdout)

    def test_thumbnail_cleanup_rejects_system_account(self):
        result = shell('''
SUDO_USER=root
getent() { echo 'root:x:0:0:root:/root:/bin/bash'; }
task_thumbnails
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('system account', result.stderr)

    def test_coredumps_follow_system_expiry_policy(self):
        result = shell('DRY_RUN=1; task_coredumps')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('systemd-tmpfiles --clean --prefix=/var/lib/systemd/coredump', result.stdout)

    def test_trim_skips_when_weekly_timer_is_enabled(self):
        result = shell('''
systemctl() { echo enabled; }
fstrim() { echo BAD_TRIM; }
task_trim
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('fstrim.timer', result.stdout)
        self.assertNotIn('BAD_TRIM', result.stdout)

    def test_boot_report_is_read_only(self):
        result = shell('DRY_RUN=1; task_boot_report')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('systemd-analyze time', result.stdout)
        self.assertIn('systemd-analyze critical-chain --no-pager', result.stdout)

    def test_flatpak_explicitly_targets_system(self):
        result = shell('DRY_RUN=1; task_flatpak; task_clean_flatpak')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('flatpak --system update -y', result.stdout)
        self.assertIn('flatpak --system uninstall --unused -y', result.stdout)

    def test_cleanup_never_updates_packages_or_flatpaks(self):
        result = shell('''
parse_args --cleanup
rpm() { printf '1.0-1.x86_64\\n'; }
dnf() { :; }
flatpak() { :; }
DRY_RUN=1
execute_tasks
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('dnf upgrade', result.stdout)
        self.assertNotIn('flatpak --system update', result.stdout)
        self.assertIn('flatpak --system uninstall --unused', result.stdout)

    def test_update_preset_has_no_cleanup(self):
        result = shell('parse_args --updates; printf "%s\\n" "${SELECTED[@]}"')
        self.assertEqual(result.stdout, 'update\nflatpak\n')

    def test_summary_records_task_results_and_net_disk_change(self):
        result = shell('''
SELECTED=(journal temp trim)
journalctl() { :; }
systemd-tmpfiles() { :; }
fstrim() { :; }
task_journal() { :; }
task_temp() { return 2; }
task_trim() { :; }
available_mib() { if (( index == 0 )); then echo 1000; else echo 1200; fi; }
execute_tasks
''')
        self.assertEqual(result.returncode, 1)
        summary = result.stdout.split('Maintenance summary')[1]
        self.assertIn('archive limits applied: 14d / 1G', summary)
        self.assertIn('Exit 2; may have partially completed', summary)
        self.assertIn('TRIM does not free disk space', summary)
        self.assertIn('+200 MiB available', summary)
        self.assertIn('Time:', summary)

    def test_preview_summary_claims_no_changes(self):
        result = shell('''
DRY_RUN=1
SELECTED=(journal)
journalctl() { :; }
available_mib() { echo BAD_MEASUREMENT; }
execute_tasks
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        summary = result.stdout.split('Maintenance summary')[1]
        self.assertIn('PREVIEW', summary)
        self.assertIn('not executed', summary)
        self.assertNotIn('MiB', summary)

    def test_summary_handles_unavailable_disk_measurement(self):
        result = shell('''
SELECTED=(temp)
systemd-tmpfiles() { :; }
available_mib() { return 1; }
execute_tasks
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('space change could not be measured', result.stdout)

    def test_menu_default_is_recommended(self):
        result = shell('menu <<< ""; printf "TASK:%s\\n" "${SELECTED[@]}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('TASK:clean-dnf', result.stdout)
        self.assertIn('TASK:update', result.stdout)
        self.assertNotIn('TASK:clean-flatpak', result.stdout)
        self.assertNotIn('TASK:flatpak\n', result.stdout)

    def test_recommended_only_runs_light_upkeep(self):
        result = shell('parse_args --recommended; printf "%s\\n" "${SELECTED[@]}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'update\nclean-dnf\ntemp\ntrim\n')

    def test_numbered_task_selection_accepts_names_and_deduplicates(self):
        result = shell('select_task_input "6, temp, 6"; printf "%s\\n" "${SELECTED[@]}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'journal\ntemp\n')

    def test_numbered_task_selection_rejects_invalid_values(self):
        for value in ['0', '99', '1,,2', '', 'unknown', '01']:
            with self.subTest(value=value):
                self.assertNotEqual(shell('select_task_input "$1"', value).returncode, 0)

    def test_task_picker_can_go_back_and_quit(self):
        result = shell('menu <<< $\'4\\nb\\n0\'')
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn('Choose your tasks', result.stdout)

    def test_invalid_menu_choice_can_be_corrected(self):
        result = shell('menu <<< $\'z\\n3\'; printf "TASK:%s\\n" "${SELECTED[@]}"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('TASK:update', result.stdout)
        self.assertIn('TASK:flatpak', result.stdout)

    def test_color_codes_are_stripped_from_log_messages(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / 'run.log'
            result = shell('LOG_FILE=$1; say $\'\\033[32mDone.\\033[0m\'', str(log))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(log.read_text(), 'Done.\n')

    def test_animation_disabled_for_redirected_output(self):
        result = shell('sleep() { echo BAD_ANIMATION; }; banner')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('BAD_ANIMATION', result.stdout)
        self.assertNotIn('\x1b', result.stdout)

    def test_no_animation_keeps_colors_without_sleeping(self):
        result = shell('parse_args --no-animation; BLUE=$\'\\033[34m\'; sleep() { echo BAD_ANIMATION; }; banner')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('BAD_ANIMATION', result.stdout)
        self.assertIn('\x1b[34m', result.stdout)

    def test_low_space_blocks_update(self):
        result = shell('''
df() { printf 'Avail\\n100M\\n'; }
dnf() { echo BAD_UPDATE; }
task_update
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('BAD_UPDATE', result.stdout)

    def test_quiet_preview_and_empty_plan(self):
        for args in ['--tasks journal --dry-run --quiet', '--none --quiet']:
            result = shell('check_platform() { :; }; journalctl() { :; }; main ' + args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, '')

    @unittest.skipUnless(shutil.which('script'), 'util-linux script is required for the terminal smoke test')
    def test_terminal_menu_quit(self):
        result = subprocess.run(
            ['script', '-qec', 'bash fedorable.sh --dry-run', '/dev/null'],
            cwd=ROOT, input='0\n', capture_output=True, text=True, timeout=10,
            env={**os.environ, 'NO_COLOR': '1'},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Pick one [1]', result.stdout)
        self.assertNotIn('Your maintenance plan', result.stdout)


if __name__ == '__main__':
    unittest.main()
