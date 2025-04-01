#!/usr/bin/env python3

import sys
import os
import subprocess
import gi
import threading
import shlex

gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Gtk, Adw, GLib, Gio, Pango

# --- Configuration ---
FEDORABLE_SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fedorable.sh")
FEDORABLE_HELPER_ID = "io.github.v8v88v8v88.fedorablehelper" # Example - Use your unique ID

class FedorableGtkApp(Adw.Application):
    def __init__(self, **kwargs):
        super().__init__(application_id="io.github.v8v88v8v88.fedorablegtk", # Example - Use your unique ID
                         flags=Gio.ApplicationFlags.FLAGS_NONE,
                         **kwargs)
        self.window = None

    def do_activate(self):
        if not self.window:
            self.window = FedorableMainWindow(application=self)
            if not os.path.exists(FEDORABLE_SCRIPT_PATH):
                 self.window.show_error_dialog(
                    f"Error: Fedorable script not found!",
                    f"Please ensure '{FEDORABLE_SCRIPT_PATH}' exists and is executable.\n"
                    "You might need to adjust the FEDORABLE_SCRIPT_PATH variable in the Python script."
                 )
            elif not os.access(FEDORABLE_SCRIPT_PATH, os.X_OK):
                 self.window.show_error_dialog(
                    f"Error: Fedorable script not executable!",
                    f"Please make '{FEDORABLE_SCRIPT_PATH}' executable (chmod +x)."
                 )
        self.window.present()

class FedorableMainWindow(Adw.ApplicationWindow):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)

        self.process = None
        self.stdout_tag = None
        self.stderr_tag = None

        self.set_title("Fedorable Maintenance GUI")
        self.set_default_size(800, 700)

        # --- UI Elements ---
        self.main_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.set_content(self.main_box) # This is correct for AdwApplicationWindow

        # AdwApplicationWindow provides its own HeaderBar.
        # Do NOT set your own titlebar using self.set_titlebar()
        # header = Adw.HeaderBar() # REMOVE
        # self.set_titlebar(header) # REMOVE THIS LINE - Causes the Adwaita-ERROR

        # --- Task Panes ---
        paned = Gtk.Paned(orientation=Gtk.Orientation.VERTICAL, wide_handle=True, position=350)
        self.main_box.append(paned)

        # Top Pane: Controls
        controls_scrolled_window = Gtk.ScrolledWindow()
        controls_scrolled_window.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        controls_scrolled_window.set_vexpand(False)
        paned.set_start_child(controls_scrolled_window)

        controls_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=15, margin_top=10, margin_bottom=10, margin_start=10, margin_end=10)
        controls_scrolled_window.set_child(controls_box)

        # --- Checkboxes for Tasks ---
        tasks_frame = Gtk.Frame(label=" Maintenance Tasks ")
        tasks_grid = Gtk.Grid(column_spacing=10, row_spacing=5, margin_top=5, margin_bottom=5, margin_start=5, margin_end=5)
        tasks_frame.set_child(tasks_grid)
        controls_box.append(tasks_frame)

        self.task_checkboxes = {}
        tasks = {
            "update": ("Update System Packages", True),
            "autoremove": ("Autoremove Unused Packages", True),
            "clean_dnf": ("Clean DNF Cache", True),
            "clean_kernels": ("Remove Old Kernels", True),
            "clean_user_cache": ("Clean User Caches (Thumbnails)", True),
            "clean_journal": ("Clean System Journal", True),
            "clean_temp": ("Clean Temp Files", True),
            "clean_coredumps": ("Clean Coredumps", True),
            "update_grub": ("Update GRUB/Bootloader", True),
            "clean_flatpak": ("Clean/Update Flatpak", True),
            "optimize_rpmdb": ("Optimize RPM Database", True),
            "reset_failed_units": ("Reset Failed Systemd Units", True),
            "update_fonts": ("Update Font Cache", True),
            "trim": ("Run SSD TRIM", True),
            "optimize_fstrim": ("Optimize fstrim Timer", True),
            "clean_snap": ("Clean Snap Packages", True),
            "update_mandb": ("Update Man Database", True),
            "check_services": ("Check Service Health", True),
        }
        row, col = 0, 0
        for key, (label, default) in tasks.items():
            cb = Gtk.CheckButton(label=label)
            cb.set_active(default)
            self.task_checkboxes[key] = cb
            tasks_grid.attach(cb, col, row, 1, 1)
            col += 1
            if col > 1:
                col = 0
                row += 1

        # --- Checkboxes/Switches for Options ---
        options_frame = Gtk.Frame(label=" Options ")
        options_grid = Gtk.Grid(column_spacing=10, row_spacing=5, margin_top=5, margin_bottom=5, margin_start=5, margin_end=5)
        options_frame.set_child(options_grid)
        controls_box.append(options_frame)

        self.option_switches = {}
        options = {
            "perform_timeshift": ("Perform Timeshift Snapshot", False),
            "perform_backup": ("Perform Config Backup", False),
            "perform_update_firmware": ("Update Firmware (fwupdmgr)", False),
            "perform_clear_history": ("Clear Shell History (Caution!)", False),
            "yes": ("Assume 'Yes' to prompts (--yes)", False),
            "dry_run": ("Dry Run (No changes made)", False),
            "email_report": ("Send Email Report (Configure /etc/fedorable.conf)", False),
            "check_only" : ("Check for Updates Only (--check-only)", False),
        }
        row, col = 0, 0
        for key, (label, default) in options.items():
            if key in ["yes", "dry_run", "email_report", "check_only"]:
                widget = Gtk.Switch()
                widget.set_active(default)
                hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
                hbox.append(Gtk.Label(label=label, xalign=0))
                hbox.append(widget)
                options_grid.attach(hbox, col, row, 1, 1)
            else:
                widget = Gtk.CheckButton(label=label)
                widget.set_active(default)
                options_grid.attach(widget, col, row, 1, 1)

            self.option_switches[key] = widget
            col += 1
            if col > 1:
                col = 0
                row += 1

        # --- Run Button ---
        run_button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, halign=Gtk.Align.CENTER, spacing=10, margin_top=15)
        controls_box.append(run_button_box)

        self.run_button = Gtk.Button(label="Run Maintenance")
        # Use add_css_class instead of deprecated get_style_context().add_class()
        self.run_button.add_css_class("suggested-action")
        self.run_button.connect("clicked", self.on_run_clicked)
        run_button_box.append(self.run_button)

        self.clear_button = Gtk.Button(label="Clear Output")
        self.clear_button.connect("clicked", self.on_clear_clicked)
        run_button_box.append(self.clear_button)

        # --- Bottom Pane: Output ---
        output_scrolled_window = Gtk.ScrolledWindow()
        output_scrolled_window.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        output_scrolled_window.set_vexpand(True)
        paned.set_end_child(output_scrolled_window)

        self.output_view = Gtk.TextView()
        self.output_view.set_editable(False)
        self.output_view.set_cursor_visible(False)
        self.output_view.set_monospace(True)
        self.stderr_tag = self.output_view.get_buffer().create_tag("stderr", foreground="red")
        self.stdout_tag = self.output_view.get_buffer().create_tag("stdout", foreground="black")
        output_scrolled_window.set_child(self.output_view)

        # --- Status Bar ---
        self.statusbar = Gtk.Statusbar()
        # Statusbar methods are deprecated, but let's keep it functional for now
        # No easy direct replacement without using Toasts etc.
        self.statusbar_context_id = self.statusbar.get_context_id("FedorableStatus") # DEPRECATED
        self.main_box.append(self.statusbar)
        self.update_statusbar("Ready.")

    def update_statusbar(self, text):
        # Still use the deprecated method for now
        self.statusbar.push(self.statusbar_context_id, text) # DEPRECATED

    def show_error_dialog(self, primary_text, secondary_text):
        dialog = Adw.MessageDialog(transient_for=self, modal=True)
        dialog.set_heading("Error")
        dialog.set_body(primary_text)
        if secondary_text:
             dialog.set_extra_info(secondary_text)
        dialog.add_response("ok", "OK")
        dialog.connect("response", lambda d, r: d.close())
        dialog.present()

    def on_clear_clicked(self, button):
        buffer = self.output_view.get_buffer()
        buffer.set_text("")
        self.update_statusbar("Output cleared.")

    def set_controls_sensitive(self, sensitive):
        self.run_button.set_sensitive(sensitive)
        for cb in self.task_checkboxes.values():
            cb.set_sensitive(sensitive)
        for sw in self.option_switches.values():
            sw.set_sensitive(sensitive)
        self.clear_button.set_sensitive(sensitive) # Enable/disable clear button too

    def build_command(self):
        command = ["pkexec", FEDORABLE_SCRIPT_PATH]
        for key, cb in self.task_checkboxes.items():
            if not cb.get_active():
                command.append(f"--no-{key.replace('_', '-')}")
        for key, sw in self.option_switches.items():
            is_active = sw.get_active()
            if is_active:
                if key == "yes": command.append("--yes")
                elif key == "dry_run": command.append("--dry-run")
                elif key == "email_report": command.append("--email-report")
                elif key == "check_only": command.append("--check-only")
                elif key.startswith("perform_"): command.append(f"--{key.replace('_', '-')}")
        return command

    def append_output(self, text, tag):
        buffer = self.output_view.get_buffer()
        buffer.insert_with_tags(buffer.get_end_iter(), text, tag)
        adj = self.output_view.get_parent().get_vadjustment()
        # Check if near the bottom before auto-scrolling
        if adj.get_value() >= adj.get_upper() - adj.get_page_size() - 50: # Add tolerance
             adj.set_value(adj.get_upper() - adj.get_page_size())
        return False # For GLib.idle_add

    def handle_stream(self, channel, condition, tag):
        """Reads from stdout or stderr channel."""
        if condition & GLib.IOCondition.HUP:
            return False # Stop watching if channel closed

        try:
            # Read all available data non-blockingly
            # size, data = channel.read_chars() # Might be better for binary
            # Use readline for text mode
            status, line, length = channel.read_line()
            if status == GLib.IOStatus.NORMAL and line:
                 GLib.idle_add(self.append_output, line, tag)
            elif status == GLib.IOStatus.EOF:
                 return False # End of file
            elif status == GLib.IOStatus.AGAIN:
                 pass # No data right now, try again
            else: # Error
                 GLib.idle_add(self.append_output, f"\n[GUI Error reading stream: {status}]\n", self.stderr_tag)
                 return False
        except GLib.Error as e:
            print(f"Error reading stream: {e}")
            GLib.idle_add(self.append_output, f"\n[GUI Error reading stream: {e}]\n", self.stderr_tag)
            return False
        except Exception as e: # Catch other potential errors
            print(f"Unexpected error reading stream: {e}")
            GLib.idle_add(self.append_output, f"\n[GUI Unexpected error reading stream: {e}]\n", self.stderr_tag)
            return False

        return True # Continue watching


    def process_finished(self, pid, status, user_data=None): # Added user_data for clarity
        """Callback when the subprocess finishes."""
        success = os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
        exit_status_val = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1 # Get exit code or -1 if signaled
        GLib.idle_add(self._finalize_run, success, exit_status_val)
        self.process = None


    def _finalize_run(self, success, exit_status):
        """Update UI after process finishes (runs on main thread)."""
        if success:
            self.update_statusbar("Maintenance finished successfully.")
            self.append_output("\n--- Maintenance Finished Successfully ---\n", self.stdout_tag)
        else:
             self.update_statusbar(f"Maintenance failed (Exit Code: {exit_status}). Check output.")
             self.append_output(f"\n--- Maintenance Failed (Exit Code: {exit_status}) ---\n", self.stderr_tag)
        self.set_controls_sensitive(True)
        return False

    def on_run_clicked(self, button):
        if self.process:
            self.update_statusbar("Maintenance is already running.")
            return
        if not os.path.exists(FEDORABLE_SCRIPT_PATH):
             self.show_error_dialog("Error: Script not found", f"Cannot run: {FEDORABLE_SCRIPT_PATH}")
             return
        if not os.access(FEDORABLE_SCRIPT_PATH, os.X_OK):
             self.show_error_dialog("Error: Script not executable", f"Cannot run: {FEDORABLE_SCRIPT_PATH}")
             return

        command = self.build_command()
        self.on_clear_clicked(None)
        self.update_statusbar("Starting maintenance...")
        self.append_output(f"Running command: {' '.join(shlex.quote(c) for c in command)}\n\n", self.stdout_tag)
        self.set_controls_sensitive(False)

        try:
            # Spawn async process using GSubprocess
            self.process = Gio.Subprocess.new(
                 command,
                 flags=Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            )

            # Communicate asynchronously to get streams
            self.process.communicate_utf8_async(None, None, self._on_process_communication_finished)


        except GLib.Error as e: # Catch GLib errors during spawn
             error_msg = f"Failed to start process: {e.message}"
             print(error_msg)
             self.show_error_dialog("Error Starting Process", f"Could not launch the maintenance script.\nDetails: {e.message}")
             self._finalize_run(False, -1)
        except Exception as e:
            error_msg = f"Unexpected error starting process: {e}"
            print(error_msg)
            self.show_error_dialog("Error Starting Process", f"Could not launch the maintenance script.\nUnexpected Error: {e}")
            self._finalize_run(False, -1)


    def _on_process_communication_finished(self, process, result):
        """Callback after Gio.Subprocess.communicate_utf8_async finishes."""
        try:
            success, stdout_data, stderr_data = process.communicate_utf8_finish(result)

            if stdout_data:
                 self.append_output(stdout_data, self.stdout_tag)
            if stderr_data:
                 self.append_output(stderr_data, self.stderr_tag)

            # Use get_exit_status() after communication finishes
            exit_status = process.get_exit_status()
            self._finalize_run(exit_status == 0, exit_status)

        except GLib.Error as e:
            error_msg = f"Error during process communication: {e.message}"
            print(error_msg)
            self.append_output(f"\n[GUI Communication Error: {e.message}]\n", self.stderr_tag)
            self._finalize_run(False, process.get_exit_status() if process.get_if_exited() else -1)
        except Exception as e:
             error_msg = f"Unexpected error during process communication: {e}"
             print(error_msg)
             self.append_output(f"\n[GUI Unexpected Communication Error: {e}]\n", self.stderr_tag)
             self._finalize_run(False, process.get_if_exited() if process.get_if_exited() else -1)
        finally:
             self.process = None # Clear process reference



# --- Main Execution ---
if __name__ == "__main__":
    # Best practice: Set application ID from variable if needed elsewhere
    app_id = "io.github.v8v88v8v88.fedorablegtk" # Ensure this matches your setup needs
    app = FedorableGtkApp(application_id=app_id)
    exit_status = app.run(sys.argv)
    sys.exit(exit_status)