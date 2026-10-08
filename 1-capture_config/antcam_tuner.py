#!/usr/bin/env python3
"""
Antcam tuner: adjust antcam capture settings against a live preview.

The preview is the same rpicam-vid/libcamera-vid invocation video.py records
with (same size, framerate and image flags), encoded as MJPEG to stdout instead
of H.264 segments. Nothing is saved: the tuned values leave the tool as
`antcam <setting> set <value>` commands copied to the clipboard.
"""

from __future__ import annotations

import collections
import io
import math
import os
import re
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import tkinter as tk
from pathlib import Path
from tkinter import ttk

try:
    from PIL import Image, ImageTk
except ImportError:  # reported in the preview pane instead of failing at launch
    Image = None
    ImageTk = None


NUMBER = r"[0-9]+(?:\.[0-9]+)?"
DEBOUNCE_MS = 500
POLL_MS = 60
FAST_PREVIEW_FPS = "30"


def log(message: str) -> None:
    print(f"[antcam-tuner] {message}", file=sys.stderr, flush=True)


def resolve_antcam_command() -> list[str]:
    installed = shutil.which("antcam")
    if installed:
        return [installed]
    sibling = Path(__file__).resolve().parent / "antcam"
    if sibling.is_file():
        return ["bash", str(sibling)]
    return []


def resolve_camera_command() -> list[str]:
    override = os.environ.get("ANTCAM_TUNER_CAMERA_CMD", "")
    if override:
        return shlex.split(override)
    for name in ("rpicam-vid", "libcamera-vid"):
        found = shutil.which(name)
        if found:
            return [found]
    return []


def read_saved_setting(antcam_cmd: list[str], key: str) -> str:
    if not antcam_cmd:
        return ""
    try:
        result = subprocess.run(
            antcam_cmd + [key, "report"],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"could not read saved {key}: {exc}")
        return ""
    if result.returncode != 0:
        log(f"antcam {key} report failed (exit={result.returncode}): {result.stderr.strip()}")
        return ""
    lines = result.stdout.strip().splitlines()
    return lines[-1].strip() if lines else ""


def format_number(value: float, decimals: int) -> str:
    text = f"{value:.{decimals}f}"
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text


class Preview:
    """Owns the camera process; publishes the newest JPEG frame and metadata."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._generation = 0
        self._proc: subprocess.Popen | None = None
        self.frame: bytes | None = None
        self.frame_seq = 0
        self.metadata: dict[str, str] = {}
        self.stderr_tail: collections.deque[str] = collections.deque(maxlen=30)
        self.state = "stopped"
        self.exit_code: int | None = None
        self._metadata_dir = ""
        self.metadata_fifo = ""
        if hasattr(os, "mkfifo"):
            try:
                self._metadata_dir = tempfile.mkdtemp(prefix="antcam-tuner-")
                self.metadata_fifo = os.path.join(self._metadata_dir, "metadata.txt")
                os.mkfifo(self.metadata_fifo)
            except OSError as exc:
                log(f"live metadata unavailable: {exc}")
                self.metadata_fifo = ""

    def restart(self, command: list[str]) -> None:
        self._generation += 1
        generation = self._generation
        self.state = "starting"
        threading.Thread(target=self._restart, args=(generation, command), daemon=True).start()

    def stop(self) -> None:
        self._generation += 1
        with self._lock:
            self._stop_locked()
        self.state = "stopped"

    def close(self) -> None:
        self.stop()
        if self._metadata_dir:
            shutil.rmtree(self._metadata_dir, ignore_errors=True)

    def _stop_locked(self) -> None:
        proc = self._proc
        self._proc = None
        if proc is None or proc.poll() is not None:
            return
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()

    def _restart(self, generation: int, command: list[str]) -> None:
        with self._lock:
            if generation != self._generation:
                return
            self._stop_locked()
            self.stderr_tail.clear()
            self.metadata = {}
            try:
                proc = subprocess.Popen(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            except OSError as exc:
                self.stderr_tail.append(str(exc))
                self.exit_code = 127
                self.state = "failed"
                return
            self._proc = proc
            threading.Thread(target=self._read_frames, args=(proc,), daemon=True).start()
            threading.Thread(target=self._read_stderr, args=(proc,), daemon=True).start()
            if self.metadata_fifo:
                threading.Thread(target=self._read_metadata, args=(proc,), daemon=True).start()

    def _read_frames(self, proc: subprocess.Popen) -> None:
        buffer = b""
        while True:
            chunk = proc.stdout.read1(1 << 16)
            if not chunk:
                break
            buffer += chunk
            while True:
                start = buffer.find(b"\xff\xd8")
                if start < 0:
                    buffer = buffer[-1:]
                    break
                end = buffer.find(b"\xff\xd9", start + 2)
                if end < 0:
                    buffer = buffer[start:]
                    break
                frame = buffer[start : end + 2]
                buffer = buffer[end + 2 :]
                if proc is self._proc:
                    self.frame = frame
                    self.frame_seq += 1
                    self.state = "running"
        exit_code = proc.wait()
        if proc is self._proc:
            self.exit_code = exit_code
            self.state = "failed"

    def _read_stderr(self, proc: subprocess.Popen) -> None:
        for raw_line in proc.stderr:
            line = raw_line.decode("utf-8", errors="replace").rstrip()
            if line and proc is self._proc:
                self.stderr_tail.append(line)

    def _read_metadata(self, proc: subprocess.Popen) -> None:
        # Non-blocking open: the camera process may die before it opens the FIFO.
        try:
            fd = os.open(self.metadata_fifo, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            return
        pending = b""
        try:
            while proc is self._proc:
                ready, _, _ = select.select([fd], [], [], 0.25)
                if not ready:
                    continue
                try:
                    chunk = os.read(fd, 1 << 16)
                except BlockingIOError:
                    continue
                if not chunk:
                    if proc.poll() is not None:
                        break
                    threading.Event().wait(0.1)
                    continue
                pending += chunk
                *lines, pending = pending.split(b"\n")
                for raw_line in lines:
                    key, separator, value = raw_line.decode("utf-8", errors="replace").partition("=")
                    if separator and proc is self._proc:
                        self.metadata[key.strip()] = value.strip()
        finally:
            os.close(fd)


class SettingRow:
    """One antcam setting: optional auto toggle, entry, and slider(s)."""

    def __init__(
        self,
        parent: tk.Widget,
        on_change,
        *,
        key: str,
        label: str,
        flag: str,
        pattern: str,
        fallback: str,
        sliders: list[tuple[float, float, float]],
        auto_word: str = "",
        log_scale: bool = False,
        positive: bool = False,
        live_key: str = "",
    ) -> None:
        self.key = key
        self.flag = flag
        self.auto_word = auto_word
        self.fallback = fallback
        self.live_key = live_key
        self._pattern = re.compile(pattern)
        self._positive = positive
        self._log_scale = log_scale
        self._decimals = [max(0, -int(math.floor(math.log10(step)))) if step < 1 else 0 for _, _, step in sliders]
        self._on_change = on_change

        frame = ttk.Frame(parent)
        frame.pack(fill="x", pady=(0, 6))
        header = ttk.Frame(frame)
        header.pack(fill="x")
        ttk.Label(header, text=label, width=11).pack(side="left")
        self.auto_var = tk.BooleanVar(value=False)
        if auto_word:
            ttk.Checkbutton(header, text=auto_word, variable=self.auto_var).pack(side="left")
        self.entry_var = tk.StringVar(value=fallback)
        self.entry = tk.Entry(header, textvariable=self.entry_var, width=10)
        self.entry.pack(side="left", padx=(6, 0))
        self._entry_foreground = self.entry.cget("foreground")
        self.live_button = None
        if live_key:
            self.live_button = ttk.Button(header, text="use live", width=8, command=self.use_live)
            self.live_button.pack(side="right")
        self.live_value = ""

        self.scales: list[tk.Scale] = []
        for low, high, step in sliders:
            scale = tk.Scale(
                frame,
                from_=low,
                to=high,
                resolution=step,
                orient="horizontal",
                showvalue=False,
                command=self._on_scale,
            )
            scale.pack(fill="x")
            self.scales.append(scale)

        self.auto_var.trace_add("write", self._on_var)
        self.entry_var.trace_add("write", self._on_var)
        self._sync()

    def set(self, value: str) -> None:
        value = (value or "").strip().lower()
        if not self._is_valid(value):
            # Unreadable or unset: antcam's own default, which is auto where one exists.
            if self.auto_word:
                self.auto_var.set(True)
                return
            value = self.fallback
        self.entry_var.set(value)
        self.auto_var.set(False)

    def value(self) -> str | None:
        """Canonical antcam value, or None while the entry is invalid."""
        if self.auto_word and self.auto_var.get():
            return self.auto_word
        text = self.entry_var.get().strip()
        return text if self._is_valid(text) else None

    def use_live(self) -> None:
        if self.live_value:
            self.set(self.live_value)

    def _is_valid(self, text: str) -> bool:
        if self._pattern.fullmatch(text) is None:
            return False
        if self._positive:
            return all(float(part) > 0 for part in text.split(","))
        return True

    def _scale_positions(self, text: str) -> list[float] | None:
        if not self._is_valid(text):
            return None
        positions = []
        for scale, part in zip(self.scales, text.split(",")):
            number = float(part)
            if self._log_scale:
                number = math.log10(number)
            low, high = float(scale.cget("from")), float(scale.cget("to"))
            step = float(scale.cget("resolution"))
            positions.append(round(min(max(number, low), high) / step) * step)
        return positions

    def _on_scale(self, _value: str) -> None:
        current = [scale.get() for scale in self.scales]
        implied = self._scale_positions(self.entry_var.get().strip())
        if implied is not None and all(abs(a - b) < 1e-9 for a, b in zip(current, implied)):
            return
        parts = []
        for position, decimals in zip(current, self._decimals):
            if self._log_scale:
                number = 10**position
                magnitude = 10 ** max(0, int(math.floor(math.log10(number))) - 1)
                parts.append(str(int(round(number / magnitude) * magnitude)))
            else:
                parts.append(format_number(position, decimals))
        self.entry_var.set(",".join(parts))

    def _on_var(self, *_args) -> None:
        self._sync()
        self._on_change()

    def _sync(self) -> None:
        is_auto = bool(self.auto_word) and self.auto_var.get()
        text = self.entry_var.get().strip()
        positions = self._scale_positions(text)
        self.entry.configure(
            state="disabled" if is_auto else "normal",
            foreground=self._entry_foreground if positions is not None else "red",
        )
        for index, scale in enumerate(self.scales):
            scale.configure(state="normal")
            if positions is not None:
                scale.set(positions[index])
            scale.configure(state="disabled" if is_auto else "normal")


class TunerApp(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Antcam Tuner")
        self.geometry("1240x740")
        self.minsize(900, 560)

        self.antcam_cmd = resolve_antcam_command()
        self.camera_cmd = resolve_camera_command()
        self.preview = Preview()
        self._refresh_job = None
        self._loading = False
        self._shown_frame_seq = -1
        self._photo = None
        self._width = os.environ.get("ANTCAM_VIDEO_WIDTH", "1920")
        self._height = os.environ.get("ANTCAM_VIDEO_HEIGHT", "1080")

        left = ttk.Frame(self, padding=8, width=350)
        left.pack(side="left", fill="y")
        left.pack_propagate(False)
        right = ttk.Frame(self, padding=(0, 8, 8, 8))
        right.pack(side="left", fill="both", expand=True)

        row_specs = [
            dict(key="focus", label="Focus", flag="--lens-position", auto_word="auto", pattern=NUMBER,
                 fallback="5", sliders=[(0, 15, 0.05)], live_key="LensPosition"),
            dict(key="ev", label="EV", flag="--ev", auto_word="auto", pattern=r"[+-]?" + NUMBER,
                 fallback="0", sliders=[(-4, 4, 0.1)]),
            dict(key="saturation", label="Saturation", flag="--saturation", auto_word="default", pattern=NUMBER,
                 fallback="1", sliders=[(0, 3, 0.05)]),
            dict(key="awbgains", label="AWB r,b", flag="--awbgains", auto_word="auto",
                 pattern=NUMBER + "," + NUMBER, fallback="1.5,1.5", positive=True,
                 sliders=[(0.1, 8, 0.05), (0.1, 8, 0.05)], live_key="ColourGains"),
            dict(key="gain", label="Gain", flag="--gain", auto_word="auto", pattern=NUMBER,
                 fallback="1", positive=True, sliders=[(1, 16, 0.1)], live_key="AnalogueGain"),
            dict(key="shutter", label="Shutter us", flag="--shutter", auto_word="auto", pattern=r"[0-9]+",
                 fallback="10000", positive=True, sliders=[(2, 6, 0.01)], log_scale=True,
                 live_key="ExposureTime"),
            dict(key="fps", label="FPS", flag="--framerate", pattern=NUMBER,
                 fallback="1", positive=True, sliders=[(1, 60, 1)]),
        ]
        self.rows = [SettingRow(left, self.schedule_refresh, **spec) for spec in row_specs]

        self.fast_preview_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            left,
            text=f"Fast preview ({FAST_PREVIEW_FPS} fps, exposure may differ)",
            variable=self.fast_preview_var,
            command=self.schedule_refresh,
        ).pack(anchor="w", pady=(0, 6))

        buttons = ttk.Frame(left)
        buttons.pack(fill="x", side="bottom")
        ttk.Button(buttons, text="Copy commands", command=self.copy_commands).pack(side="left")
        ttk.Button(buttons, text="Reload saved", command=self.load_saved).pack(side="left", padx=6)
        self.copy_status_var = tk.StringVar()
        ttk.Label(left, textvariable=self.copy_status_var).pack(side="bottom", anchor="w")
        self.commands_box = tk.Text(left, height=8, width=40, wrap="none")
        self.commands_box.pack(side="bottom", fill="x", pady=(0, 4))

        self.image_frame = tk.Frame(right, background="black")
        self.image_frame.pack(fill="both", expand=True)
        self.image_frame.pack_propagate(False)
        self.image_label = tk.Label(
            self.image_frame, background="black", foreground="white", justify="left", wraplength=700
        )
        self.image_label.pack(fill="both", expand=True)
        self.live_var = tk.StringVar()
        ttk.Label(right, textvariable=self.live_var).pack(anchor="w", pady=(4, 0))
        self.status_var = tk.StringVar()
        ttk.Label(right, textvariable=self.status_var, wraplength=820, justify="left").pack(anchor="w")

        self.protocol("WM_DELETE_WINDOW", self.on_close)
        self.load_saved()
        self.after(POLL_MS, self.poll)

    def load_saved(self) -> None:
        self._loading = True
        for row in self.rows:
            row.set(read_saved_setting(self.antcam_cmd, row.key))
        self._loading = False
        self.copy_status_var.set("" if self.antcam_cmd else "antcam not found; showing defaults")
        self.schedule_refresh()

    def schedule_refresh(self) -> None:
        if self._loading:
            return
        if self._refresh_job is not None:
            self.after_cancel(self._refresh_job)
        self._refresh_job = self.after(DEBOUNCE_MS, self.refresh)

    def commands_text(self) -> str | None:
        lines = []
        for row in self.rows:
            value = row.value()
            if value is None:
                return None
            lines.append(f"antcam {row.key} set {value}")
        return "\n".join(lines)

    def preview_command(self) -> list[str] | None:
        values = {row.key: row.value() for row in self.rows}
        if None in values.values():
            return None
        framerate = FAST_PREVIEW_FPS if self.fast_preview_var.get() else values["fps"]
        command = self.camera_cmd + [
            "--nopreview",
            "--timeout",
            "0",
            "--framerate",
            framerate,
            "--codec",
            "mjpeg",
            "--width",
            self._width,
            "--height",
            self._height,
            "--flush",
            "--output",
            "-",
        ]
        for row in self.rows:
            if row.key != "fps" and values[row.key] != row.auto_word:
                command.extend([row.flag, values[row.key]])
        if self.preview.metadata_fifo:
            command.extend(["--metadata", self.preview.metadata_fifo, "--metadata-format", "txt"])
        return command

    def refresh(self) -> None:
        self._refresh_job = None
        commands = self.commands_text()
        self.commands_box.configure(state="normal")
        self.commands_box.delete("1.0", "end")
        self.commands_box.insert("1.0", commands if commands is not None else "# fix the values shown in red")
        self.commands_box.configure(state="disabled")
        self.copy_status_var.set("")

        if Image is None:
            self.show_message(
                "Preview needs Pillow with Tk support:\n  sudo apt install python3-pil python3-pil.imagetk"
            )
            return
        if not self.camera_cmd:
            self.show_message("rpicam-vid or libcamera-vid not found. Install Raspberry Pi camera apps.")
            return
        command = self.preview_command()
        if command is None:
            return
        self.status_var.set(" ".join(shlex.quote(part) for part in command))
        self.preview.restart(command)

    def show_message(self, message: str) -> None:
        self._photo = None
        self.image_label.configure(image="", text=message)

    def copy_commands(self) -> None:
        commands = self.commands_text()
        if commands is None:
            self.copy_status_var.set("Fix the values shown in red first")
            return
        self.clipboard_clear()
        self.clipboard_append(commands)
        self.update()
        # Tk only reaches the X11 clipboard; wl-copy also covers native Wayland clients.
        if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-copy"):
            try:
                subprocess.run(["wl-copy"], input=commands.encode("utf-8"), timeout=3, check=False)
            except (OSError, subprocess.SubprocessError) as exc:
                log(f"wl-copy failed: {exc}")
        self.copy_status_var.set("Copied (clipboard is kept while this window stays open)")

    def poll(self) -> None:
        preview = self.preview
        if preview.state == "running" and preview.frame_seq != self._shown_frame_seq and Image is not None:
            self._shown_frame_seq = preview.frame_seq
            self.show_frame(preview.frame)
        elif preview.state == "starting" and self._photo is None:
            self.image_label.configure(text="Starting camera...")
        elif preview.state == "failed":
            tail = "\n".join(list(preview.stderr_tail)[-8:])
            hint = ""
            if re.search(r"busy|acquire|in use", tail, re.IGNORECASE):
                hint = "\n\nThe camera looks busy. If a recording is running, stop it first: antcam stop"
            self.show_message(f"Camera preview exited (exit={preview.exit_code}).\n\n{tail}{hint}")
        self.update_live_metadata()
        self.after(POLL_MS, self.poll)

    def show_frame(self, frame: bytes) -> None:
        box = (max(self.image_frame.winfo_width(), 64), max(self.image_frame.winfo_height(), 64))
        try:
            image = Image.open(io.BytesIO(frame))
            image.draft("RGB", box)
            image.thumbnail(box)
            self._photo = ImageTk.PhotoImage(image)
        except Exception as exc:  # a torn frame should not end the preview
            log(f"could not decode preview frame: {exc}")
            return
        self.image_label.configure(image=self._photo, text="")

    def update_live_metadata(self) -> None:
        metadata = dict(self.preview.metadata)
        for row in self.rows:
            if not row.live_key:
                continue
            numbers = re.findall(NUMBER, metadata.get(row.live_key, ""))
            if row.key == "shutter":
                numbers = [str(int(float(number))) for number in numbers]
            else:
                numbers = [format_number(float(number), 2) for number in numbers]
            row.live_value = ",".join(numbers[: len(row.scales)]) if len(numbers) >= len(row.scales) else ""
            row.live_button.configure(state="normal" if row.live_value else "disabled")
        parts = []
        for label, key, unit in (
            ("exposure", "ExposureTime", " us"),
            ("gain", "AnalogueGain", ""),
            ("digital gain", "DigitalGain", ""),
            ("awb", "ColourGains", ""),
            ("lens", "LensPosition", ""),
            ("colour temp", "ColourTemperature", " K"),
            ("lux", "Lux", ""),
        ):
            if metadata.get(key):
                parts.append(f"{label} {metadata[key]}{unit}")
        self.live_var.set("Live: " + "  |  ".join(parts) if parts else "")

    def on_close(self) -> None:
        self.preview.close()
        self.destroy()


def main() -> int:
    try:
        app = TunerApp()
    except tk.TclError as exc:
        log(f"could not open a window (run this from the Pi desktop session): {exc}")
        return 1
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
