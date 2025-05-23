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
# !! IMPORTANT: Adjust this path to where your fedorable.sh script is located !!
FEDORABLE_SCRIPT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fedorable.sh")
# Used for pkexec policy
FEDORABLE_HELPER_ID = "io.github.yourusername.fedorablehelper" # Change 'yourusername'

class FedorableGtkApp(Adw.Application):
    def __init__(self, **kwargs):
        super().__init__(application_id="io.github.yourusername.fedorablegtk", # Change 'yourusername'
                         flags=Gio.ApplicationFlags.FLAGS_NONE,
                         **kwargs)
        self.window = None

    def do_activate(self):
        # Create a new window if none exists
        if not self.window:
            self.window = FedorableMainWindow(application=self)
            # Check if script exists on activation
            if not os.path.exists(FEDORABLE_SCRIPT_PATH):
                 self.window.show_error_dialog(
                    f"Error: Fedorable script not found!",
                    f"Please ensure '{FEDORABLE_SCRIPT_PATH}' exists and is executable.\n"
                    "You might need to adjust the FEDORABLE_SCRIPT_PATH variable in the Python script."
                 )
                 # Optionally disable run button here or exit
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
        self.set_content(self.main_box)

        # Header Bar
        header = Adw.HeaderBar()
        self.set_titlebar(header)
        # Add About button later if needed

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
        # Define tasks (key: internal name, value: display label, default state)
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
            if col > 1: # Adjust number of columns
                col = 0
                row += 1

        # --- Checkboxes/Switches for Options ---
        options_frame = Gtk.Frame(label=" Options ")
        options_grid = Gtk.Grid(column_spacing=10, row_spacing=5, margin_top=5, margin_bottom=5, margin_start=5, margin_end=5)
        options_frame.set_child(options_grid)
        controls_box.append(options_frame)

        self.option_switches = {}
         # Define options (key: internal name, value: display label, default state)
        options = {
            # --- Actions (use CheckButton) ---
            "perform_timeshift": ("Perform Timeshift Snapshot", False),
            "perform_backup": ("Perform Config Backup", False),
            "perform_update_firmware": ("Update Firmware (fwupdmgr)", False),
            "perform_clear_history": ("Clear Shell History (Caution!)", False),
             # --- Modifiers (use Switch for on/off style) ---
            "yes": ("Assume 'Yes' to prompts (--yes)", False),
            "dry_run": ("Dry Run (No changes made)", False),
            "email_report": ("Send Email Report (Configure /etc/fedorable.conf)", False),
             # quiet mode doesn't make sense for GUI
             "check_only" : ("Check for Updates Only (--check-only)", False),
        }
        row, col = 0, 0
        for key, (label, default) in options.items():
            # Use Switch for modifiers, CheckButton for actions
            if key in ["yes", "dry_run", "email_report", "check_only"]:
                widget = Gtk.Switch()
                widget.set_active(default)
                # Align switch with label better
                hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
                hbox.append(Gtk.Label(label=label, xalign=0))
                hbox.append(widget)
                options_grid.attach(hbox, col, row, 1, 1)

            else: # Actions
                widget = Gtk.CheckButton(label=label)
                widget.set_active(default)
                options_grid.attach(widget, col, row, 1, 1)

            self.option_switches[key] = widget
            col += 1
            if col > 1: # Adjust columns
                col = 0
                row += 1

        # --- Run Button ---
        run_button_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, halign=Gtk.Align.CENTER, spacing=10, margin_top=15)
        controls_box.append(run_button_box)

        self.run_button = Gtk.Button(label="Run Maintenance")
        self.run_button.get_style_context().add_class("suggested-action")
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
        # Pango tag for stderr (red color)
        self.stderr_tag = self.output_view.get_buffer().create_tag("stderr", foreground="red")
        self.stdout_tag = self.output_view.get_buffer().create_tag("stdout", foreground="black") # Default color
        output_scrolled_window.set_child(self.output_view)

        # --- Status Bar ---
        self.statusbar = Gtk.Statusbar()
        self.statusbar_context_id = self.statusbar.get_context_id("FedorableStatus")
        self.main_box.append(self.statusbar)
        self.update_statusbar("Ready.")

    def update_statusbar(self, text):
        self.statusbar.push(self.statusbar_context_id, text)

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
        """Enable or disable checkboxes and run button."""
        self.run_button.set_sensitive(sensitive)
        for cb in self.task_checkboxes.values():
            cb.set_sensitive(sensitive)
        for sw in self.option_switches.values():
            sw.set_sensitive(sensitive)
        # Clear button should always be enabled maybe? Or only when not running?
        self.clear_button.set_sensitive(sensitive)


    def build_command(self):
        """Builds the shell command based on checkbox states."""
        # Use pkexec to request privileges for the specific script
        command = ["pkexec", FEDORABLE_SCRIPT_PATH]

        # Add task flags (use --no-* if checkbox is *unchecked*)
        for key, cb in self.task_checkboxes.items():
            if not cb.get_active():
                command.append(f"--no-{key.replace('_', '-')}") # e.g., --no-clean-dnf

        # Add option flags (use --* if checkbox/switch is *checked*)
        for key, sw in self.option_switches.items():
             # Check if it's a switch or checkbox - switches have get_state() in some GTK versions, get_active() is safer
            is_active = sw.get_active()

            if is_active:
                if key == "yes":
                    command.append("--yes")
                elif key == "dry_run":
                    command.append("--dry-run")
                elif key == "email_report":
                    command.append("--email-report")
                elif key == "check_only":
                     command.append("--check-only")
                # Handle actions (--perform-*)
                elif key.startswith("perform_"):
                     command.append(f"--{key.replace('_', '-')}")


        return command

    def append_output(self, text, tag):
        """Appends text to the output view with a specific tag (runs on main thread)."""
        buffer = self.output_view.get_buffer()
        buffer.insert_with_tags(buffer.get_end_iter(), text, tag)
        # Auto-scroll
        adj = self.output_view.get_parent().get_vadjustment() # ScrolledWindow adjustment
        adj.set_value(adj.get_upper() - adj.get_page_size())
        return False # Important for GLib.idle_add

    def handle_stream(self, channel, condition, tag):
        """Reads from stdout or stderr channel."""
        if condition == GLib.IOCondition.HUP:
            return False # Stop watching if channel closed

        try:
            line = channel.readline() # Read available data
            if line:
                # Schedule GUI update on the main thread
                GLib.idle_add(self.append_output, line, tag)
            else:
                # End of stream
                return False
        except Exception as e:
            print(f"Error reading stream: {e}") # Log to console
            GLib.idle_add(self.append_output, f"\n[GUI Error reading stream: {e}]\n", self.stderr_tag)
            return False # Stop watching on error

        return True # Continue watching

    def process_finished(self, pid, status):
        """Callback when the subprocess finishes."""
        success = os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
        GLib.idle_add(self._finalize_run, success, os.WEXITSTATUS(status))
        self.process = None # Reset process variable


    def _finalize_run(self, success, exit_status):
        """Update UI after process finishes (runs on main thread)."""
        if success:
            self.update_statusbar("Maintenance finished successfully.")
            self.append_output("\n--- Maintenance Finished Successfully ---\n", self.stdout_tag)
        else:
             self.update_statusbar(f"Maintenance failed (Exit Code: {exit_status}). Check output.")
             self.append_output(f"\n--- Maintenance Failed (Exit Code: {exit_status}) ---\n", self.stderr_tag)

        self.set_controls_sensitive(True) # Re-enable controls
        # Clean up IO watches maybe? Should happen automatically on HUP/error.
        return False # For GLib.idle_add

    def on_run_clicked(self, button):
        """Starts the maintenance script."""
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
        self.on_clear_clicked(None) # Clear previous output
        self.update_statusbar("Starting maintenance...")
        self.append_output(f"Running command: {' '.join(shlex.quote(c) for c in command)}\n\n", self.stdout_tag)
        self.set_controls_sensitive(False) # Disable controls

        try:
            # Use Popen for non-blocking execution and stream redirection
            self.process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,  # Decode streams as text
                bufsize=1,  # Line buffered
                universal_newlines=True # Consistent line endings
            )

            # Watch stdout
            stdout_channel = GLib.IOChannel(self.process.stdout.fileno())
            GLib.io_add_watch(stdout_channel, GLib.IOCondition.IN | GLib.IOCondition.HUP,
                              self.handle_stream, self.stdout_tag)

            # Watch stderr
            stderr_channel = GLib.IOChannel(self.process.stderr.fileno())
            GLib.io_add_watch(stderr_channel, GLib.IOCondition.IN | GLib.IOCondition.HUP,
                              self.handle_stream, self.stderr_tag)

             # Watch for process completion using GLib.child_watch_add
             # PID, callback function, user_data (optional)
            GLib.child_watch_add(GLib.PRIORITY_DEFAULT, self.process.pid, self.process_finished)


        except FileNotFoundError:
             self.show_error_dialog("Error: pkexec not found", "Ensure 'pkexec' (part of Polkit) is installed.")
             self._finalize_run(False, -1) # Simulate failure
        except Exception as e:
            error_msg = f"Failed to start process: {e}"
            print(error_msg) # Log raw error to console
            self.show_error_dialog("Error Starting Process", f"Could not launch the maintenance script.\nDetails: {e}")
            self._finalize_run(False, -1) # Simulate failure

# --- Main Execution ---
if __name__ == "__main__":
    app = FedorableGtkApp()
    exit_status = app.run(sys.argv)
    sys.exit(exit_status)