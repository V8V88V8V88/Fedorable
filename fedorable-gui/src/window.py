# src/window.py
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Gtk, Adw, GLib, Gio
from .tasks import SystemTasks

@Gtk.Template(resource_path='/com/github/fedorable/window.ui')
class FedorableWindow(Adw.ApplicationWindow):
    __gtype_name__ = 'FedorableWindow'

    # Template widgets
    main_stack = Gtk.Template.Child()
    tasks_list = Gtk.Template.Child()
    progress_bar = Gtk.Template.Child()
    status_label = Gtk.Template.Child()
    run_button = Gtk.Template.Child()

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.tasks = SystemTasks()
        self.setup_tasks()
        
    def setup_tasks(self):
        task_names = [
            "Backup System Configurations",
            "Update System",
            "System Cleanup",
            "User Data Cleanup",
            "System Optimization"
        ]
        
        for i, name in enumerate(task_names, 1):
            row = Adw.ActionRow(title=name)
            switch = Gtk.Switch(valign=Gtk.Align.CENTER)
            row.add_suffix(switch)
            self.tasks_list.append(row)
    
    @Gtk.Template.Callback()
    def on_run_clicked(self, button):
        selected_tasks = []
        for i, row in enumerate(self.tasks_list):
            switch = row.get_last_child()
            if switch.get_active():
                selected_tasks.append(i + 1)
        
        if not selected_tasks:
            dialog = Adw.MessageDialog(
                transient_for=self,
                heading="No Tasks Selected",
                body="Please select at least one task to run.",
                buttons=["OK"]
            )
            dialog.show()
            return
            
        self.run_tasks(selected_tasks)
    
    def run_tasks(self, task_numbers):
        self.run_button.set_sensitive(False)
        self.main_stack.set_visible_child_name('progress')
        total_tasks = len(task_numbers)
        
        for i, task_num in enumerate(task_numbers):
            progress = (i / total_tasks)
            self.progress_bar.set_fraction(progress)
            GLib.idle_add(
                self.status_label.set_text,
                f"Running task {task_num}..."
            )
            self.tasks.run_task(task_num)
        
        self.progress_bar.set_fraction(1.0)
        self.status_label.set_text("Tasks completed!")
        self.run_button.set_sensitive(True)
        self.main_stack.set_visible_child_name('tasks')
