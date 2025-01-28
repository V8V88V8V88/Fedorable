# src/main.py
import sys
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('Adw', '1')
from gi.repository import Gtk, Adw, Gio

from .window import FedorableWindow

class FedorableApplication(Adw.Application):
    def __init__(self):
        super().__init__(application_id='com.github.fedorable.gui',
                        flags=Gio.ApplicationFlags.FLAGS_NONE)
        
    def do_activate(self):
        win = self.props.active_window
        if not win:
            win = FedorableWindow(application=self)
        win.present()

def main(version):
    app = FedorableApplication()
    return app.run(sys.argv)