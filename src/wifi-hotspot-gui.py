#!/usr/bin/env python3
"""GTK UI for Linux_Mint_Wifi_Hotspot (experimental)."""

from __future__ import annotations

import json
import subprocess
import threading
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gdk, Gtk, Pango

APP_DIR = Path(__file__).resolve().parent
SCRIPT = APP_DIR / "wifi-hotspot.sh"
CONF = APP_DIR / "wifi-hotspot.conf"

# How often to refresh status (seconds). Keep high — shared WiFi radio is busy.
STATUS_INTERVAL_SEC = 10


def run_script(*args: str, timeout: float | None = 8) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            [str(SCRIPT), *args],
            cwd=str(APP_DIR),
            capture_output=True,
            text=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args=[str(SCRIPT), *args], returncode=124, stdout="", stderr="Timed out")


def recent_log(lines: int = 8) -> str:
    log_path = Path.home() / ".local/share/linux-mint-wifi-hotspot/hotspot.log"
    if not log_path.exists():
        return ""
    try:
        content = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(content[-lines:])


def load_conf_values() -> dict[str, str]:
    values: dict[str, str] = {}
    if not CONF.exists():
        return values
    for line in CONF.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


class HotspotApp(Gtk.Window):
    def __init__(self) -> None:
        super().__init__(title="Linux Mint Wifi Hotspot")
        self.set_default_size(420, 520)
        self.set_border_width(18)
        self.set_position(Gtk.WindowPosition.CENTER)

        conf = load_conf_values()
        self.busy = False
        self.hotspot_active = False
        self._refresh_lock = threading.Lock()
        self._refreshing = False

        css = Gtk.CssProvider()
        css.load_from_data(
            b"""
            .status-ok { color: #2ecc71; font-weight: 600; }
            .status-bad { color: #e74c3c; font-weight: 600; }
            .status-warn { color: #f39c12; font-weight: 600; }
            .card {
                background-color: alpha(currentColor, 0.04);
                border-radius: 10px;
                padding: 12px;
            }
            .hero-title { font-size: 18px; font-weight: 700; }
            .hero-sub { opacity: 0.75; }
            """
        )
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.add(root)

        header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        icon = Gtk.Image.new_from_icon_name("network-wireless-hotspot", Gtk.IconSize.DIALOG)
        title_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        title = Gtk.Label(label="Linux Mint Wifi Hotspot", xalign=0)
        title.get_style_context().add_class("hero-title")
        subtitle = Gtk.Label(
            label="Temporary: shares WiFi only while Start is on — Stop or WiFi drop restores normal WiFi",
            xalign=0,
            wrap=True,
        )
        subtitle.get_style_context().add_class("hero-sub")
        title_box.pack_start(title, False, False, 0)
        title_box.pack_start(subtitle, False, False, 0)
        header.pack_start(icon, False, False, 0)
        header.pack_start(title_box, True, True, 0)
        root.pack_start(header, False, False, 0)

        status_card = Gtk.Grid(column_spacing=12, row_spacing=8)
        status_card.get_style_context().add_class("card")
        labels = ["WiFi", "Internet", "Hotspot", "Connected to"]
        self.status_values = []
        for row, name in enumerate(labels):
            left = Gtk.Label(label=name, xalign=0)
            left.set_markup(f"<b>{name}</b>")
            right = Gtk.Label(label="…", xalign=0)
            right.set_halign(Gtk.Align.START)
            self.status_values.append(right)
            status_card.attach(left, 0, row, 1, 1)
            status_card.attach(right, 1, row, 1, 1)
        root.pack_start(status_card, False, False, 0)

        form = Gtk.Grid(column_spacing=10, row_spacing=10)
        form.get_style_context().add_class("card")
        ssid_label = Gtk.Label(label="Network name (SSID)", xalign=0)
        self.ssid_entry = Gtk.Entry(text=conf.get("HOTSPOT_SSID", "LinuxMint-Hotspot"))
        self.ssid_entry.set_hexpand(True)
        password_label = Gtk.Label(label="Password", xalign=0)
        self.password_entry = Gtk.Entry(text=conf.get("HOTSPOT_PASSWORD", ""))
        self.password_entry.set_visibility(False)
        self.password_entry.set_hexpand(True)
        show_btn = Gtk.ToggleButton(label="Show")
        show_btn.connect("toggled", self._toggle_password_visibility)
        password_row = Gtk.Box(spacing=6)
        password_row.pack_start(self.password_entry, True, True, 0)
        password_row.pack_start(show_btn, False, False, 0)
        form.attach(ssid_label, 0, 0, 1, 1)
        form.attach(self.ssid_entry, 1, 0, 1, 1)
        form.attach(password_label, 0, 1, 1, 1)
        form.attach(password_row, 1, 1, 1, 1)
        root.pack_start(form, False, False, 0)

        self.message = Gtk.Label(label="", wrap=True, xalign=0)
        self.message.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        root.pack_start(self.message, False, False, 0)

        self.spinner = Gtk.Spinner()
        self.spinner.set_no_show_all(True)
        root.pack_start(self.spinner, False, False, 0)

        actions = Gtk.Box(spacing=8)
        self.primary_btn = Gtk.Button(label="Start Hotspot")
        self.primary_btn.get_style_context().add_class("suggested-action")
        self.primary_btn.connect("clicked", self._on_primary_clicked)
        restore_btn = Gtk.Button(label="Restore WiFi")
        restore_btn.connect("clicked", lambda *_: self._run_action("restore"))
        save_btn = Gtk.Button(label="Save settings")
        save_btn.connect("clicked", self._save_settings)
        actions.pack_start(self.primary_btn, True, True, 0)
        actions.pack_start(restore_btn, False, False, 0)
        actions.pack_start(save_btn, False, False, 0)
        root.pack_start(actions, False, False, 0)

        hint = Gtk.Label(
            label="Does nothing until you Start. Stop restores WiFi exactly as it was. If WiFi disconnects, the hotspot shuts itself off.",
            wrap=True,
            xalign=0,
        )
        hint.get_style_context().add_class("hero-sub")
        root.pack_start(hint, False, False, 0)

        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        scrolled = Gtk.ScrolledWindow()
        scrolled.set_min_content_height(120)
        scrolled.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scrolled.add(self.log_view)
        root.pack_start(scrolled, True, True, 0)

        GLib.timeout_add_seconds(STATUS_INTERVAL_SEC, self._schedule_refresh)
        self._schedule_refresh()

    def _toggle_password_visibility(self, button: Gtk.ToggleButton) -> None:
        self.password_entry.set_visibility(button.get_active())

    def _set_busy(self, busy: bool, message: str = "") -> None:
        self.busy = busy
        self.spinner.set_visible(busy)
        if busy:
            self.spinner.start()
        else:
            self.spinner.stop()
        self.primary_btn.set_sensitive(not busy)
        if message:
            self.message.set_text(message)

    def _set_status_label(self, widget: Gtk.Label, ok: bool | None, text: str) -> None:
        ctx = widget.get_style_context()
        for cls in ("status-ok", "status-bad", "status-warn"):
            ctx.remove_class(cls)
        if ok is True:
            ctx.add_class("status-ok")
        elif ok is False:
            ctx.add_class("status-bad")
        else:
            ctx.add_class("status-warn")
        widget.set_text(text)

    def _schedule_refresh(self) -> bool:
        """Timer callback: never block the GTK main loop."""
        if self.busy:
            return True
        if self._refreshing:
            return True
        self._refreshing = True

        def worker() -> None:
            result = run_script("status-json", timeout=5)
            log_text = recent_log(12)
            GLib.idle_add(self._apply_status, result, log_text)

        threading.Thread(target=worker, daemon=True).start()
        return True

    def _apply_status(self, result: subprocess.CompletedProcess[str], log_text: str) -> bool:
        self._refreshing = False
        if self.busy:
            return False
        if result.returncode != 0:
            self._set_status_label(self.status_values[0], False, "Unavailable")
            return False
        try:
            data = json.loads((result.stdout or "").strip().splitlines()[-1])
        except (json.JSONDecodeError, IndexError):
            return False

        wifi_ok = "connected" in data.get("wifi_state", "").lower()
        internet_ok = bool(data.get("internet"))
        self.hotspot_active = bool(data.get("hotspot_active"))

        self._set_status_label(
            self.status_values[0],
            wifi_ok,
            "Connected" if wifi_ok else "Not connected",
        )
        self._set_status_label(
            self.status_values[1],
            internet_ok,
            "Online" if internet_ok else "Offline",
        )
        self._set_status_label(
            self.status_values[2],
            self.hotspot_active,
            "Sharing" if self.hotspot_active else "Off",
        )
        self._set_status_label(
            self.status_values[3],
            None,
            data.get("connection") or "None",
        )

        if self.hotspot_active:
            self.primary_btn.set_label("Stop Hotspot")
            self.primary_btn.get_style_context().remove_class("suggested-action")
            self.primary_btn.get_style_context().add_class("destructive-action")
        else:
            self.primary_btn.set_label("Start Hotspot")
            self.primary_btn.get_style_context().remove_class("destructive-action")
            self.primary_btn.get_style_context().add_class("suggested-action")

        self.log_view.get_buffer().set_text(log_text or "No activity yet.")
        return False

    def _save_settings(self, *_args) -> None:
        ssid = self.ssid_entry.get_text().strip()
        password = self.password_entry.get_text()
        if len(password) < 8:
            self.message.set_text("Password must be at least 8 characters.")
            return

        def worker() -> None:
            result = run_script("save-config", ssid, password, timeout=5)
            msg = (
                "Settings saved."
                if result.returncode == 0
                else (result.stderr.strip() or "Could not save settings.")
            )
            GLib.idle_add(self.message.set_text, msg)

        threading.Thread(target=worker, daemon=True).start()

    def _on_primary_clicked(self, *_args) -> None:
        action = "stop" if self.hotspot_active else "start"
        if action == "start":
            ssid = self.ssid_entry.get_text().strip()
            password = self.password_entry.get_text()
            if len(password) < 8:
                self.message.set_text("Set a password of at least 8 characters first.")
                return
            run_script("save-config", ssid, password, timeout=5)
        self._run_action(action)

    def _run_action(self, action: str) -> None:
        if self.busy:
            return

        labels = {
            "start": "Starting virtual hotspot…",
            "stop": "Stopping hotspot…",
            "restore": "Restoring WiFi settings…",
        }
        self._set_busy(True, labels.get(action, "Working…"))

        def worker() -> None:
            # start/stop can take a while (hostapd / iface setup)
            result = run_script(action, timeout=120)
            GLib.idle_add(self._action_finished, action, result.returncode, result.stdout, result.stderr)

        threading.Thread(target=worker, daemon=True).start()

    def _action_finished(
        self,
        action: str,
        code: int,
        stdout: str,
        stderr: str,
    ) -> None:
        self._set_busy(False)
        self._schedule_refresh()
        if code == 0:
            if action == "start":
                self.message.set_text(
                    "Hotspot is on. You can close this window — sharing keeps running."
                )
            elif action == "stop":
                self.message.set_text("Hotspot stopped.")
            else:
                self.message.set_text("WiFi settings restored.")
        else:
            detail = (stderr or stdout).strip()
            if "Lost WiFi" in detail or "Lost WiFi" in recent_log(20):
                detail = (
                    "Could not keep WiFi while creating the hotspot. "
                    "Your connection was restored automatically."
                )
            elif not detail:
                detail = "Operation failed. See the log below."
            self.message.set_text(detail)


def main() -> None:
    if not SCRIPT.exists():
        raise SystemExit(f"Missing backend script: {SCRIPT}")
    app = HotspotApp()
    app.connect("destroy", Gtk.main_quit)
    app.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
