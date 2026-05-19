#!/usr/bin/env python3
"""AntSciHub photo capture worker.

Python implementation of the former photos.sh logic.
Still uses rpicam-still/libcamera-still for actual capture.
"""

from __future__ import annotations

import datetime as _dt
import os
import re
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional


def log(message: str) -> None:
    print(f"[photos] {message}", file=sys.stderr, flush=True)


def normalize_duration_value(value: str) -> str:
    return "".join((value or "").split()).lower()


def duration_to_milliseconds(raw_value: str) -> int:
    value = normalize_duration_value(raw_value)
    if not value:
        raise ValueError("empty duration")

    pattern = re.compile(r"(\d+)([hms])")
    pos = 0
    total_ms = 0
    for match in pattern.finditer(value):
        if match.start() != pos:
            raise ValueError(f"invalid duration token near {value[pos:]!r}")
        amount = int(match.group(1))
        unit = match.group(2)
        if unit == "h":
            total_ms += amount * 3_600_000
        elif unit == "m":
            total_ms += amount * 60_000
        elif unit == "s":
            total_ms += amount * 1_000
        else:
            raise ValueError(f"invalid duration unit {unit!r}")
        pos = match.end()

    if pos != len(value):
        raise ValueError(f"invalid duration token near {value[pos:]!r}")
    return total_ms


def normalize_loop_setting_value(raw_value: str) -> str:
    normalized = normalize_duration_value(raw_value)
    if not normalized:
        raise ValueError("empty loop value")
    if normalized in {"none", "0"}:
        return "none"
    loop_ms = duration_to_milliseconds(normalized)
    if loop_ms <= 0:
        return "none"
    return normalized


def is_auto_focus_value(value: str) -> bool:
    return (value or "").strip().lower() == "auto"


def is_valid_lens_position_value(value: str) -> bool:
    return re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value or "") is not None


def is_valid_recording_name_value(value: str) -> bool:
    return re.fullmatch(r"[A-Za-z0-9._-]+", value or "") is not None


def now_epoch_milliseconds() -> int:
    return int(time.time() * 1000)


def sleep_milliseconds(sleep_ms: int) -> None:
    if sleep_ms <= 0:
        return
    time.sleep(sleep_ms / 1000.0)


def sleep_until_epoch_milliseconds(target_ms: int) -> None:
    remaining_ms = target_ms - now_epoch_milliseconds()
    sleep_milliseconds(remaining_ms)


def read_value_with_default(file_path: Path, default: str) -> str:
    if file_path.is_file():
        try:
            return file_path.read_text(encoding="utf-8", errors="replace").splitlines()[0].strip()
        except Exception:
            return default
    return default


def read_raw_value_with_default(file_path: Path, default: str) -> str:
    if file_path.is_file():
        try:
            lines = file_path.read_text(encoding="utf-8", errors="replace").splitlines()
            if not lines:
                return default
            return lines[0]
        except Exception:
            return default
    return default


def resolve_focus_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_FOCUS_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "focus-lens-position.txt"


def resolve_length_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_LENGTH_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-length.txt"


def resolve_loop_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_LOOP_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-loop.txt"


def resolve_name_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_NAME_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-name.txt"


def resolve_upload_dir_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_UPLOAD_DIR", "")
    if override:
        return Path(override)
    return capture_dir.parent / "5-UPLOAD"


def resolve_session_hostname() -> str:
    host = socket.gethostname().strip()
    host = re.sub(r"[^A-Za-z0-9._-]", "_", host)
    host = re.sub(r"__+", "_", host).strip("_")
    return host or "unknown-host"


def choose_still_command() -> Optional[str]:
    for name in ("rpicam-still", "libcamera-still"):
        if shutil.which(name):
            return name
    return None


def run_capture(command: str, args: list[str]) -> int:
    result = subprocess.run([command, *args], check=False)
    return int(result.returncode or 0)


def main() -> int:
    capture_dir_arg = os.environ.get("ANTCAM_CAPTURE_DIR") or (sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
    capture_dir = Path(capture_dir_arg).expanduser()

    focus_file = resolve_focus_file_path(capture_dir)
    length_file = resolve_length_file_path(capture_dir)
    loop_file = resolve_loop_file_path(capture_dir)
    name_file = resolve_name_file_path(capture_dir)

    focus_value = os.environ.get("ANTCAM_FOCUS_LENS_POSITION", "")
    if not focus_value:
        focus_value = read_value_with_default(focus_file, "auto")
    if is_auto_focus_value(focus_value):
        focus_value = "auto"
    elif not is_valid_lens_position_value(focus_value):
        log(f"invalid focus lens-position value: {focus_value}")
        log("set it with: antcam focus set <lens-position|auto>")
        return 3

    length_value = os.environ.get("ANTCAM_RECORDING_LENGTH", "")
    if not length_value:
        length_value = read_value_with_default(length_file, "0s")
    length_value = normalize_duration_value(length_value)
    try:
        length_ms = duration_to_milliseconds(length_value)
    except ValueError:
        log(f"invalid recording length value: {length_value}")
        log("set it with: antcam length set <duration> (example: 30h, 10m, 45s)")
        return 4

    loop_raw_value = os.environ.get("ANTCAM_RECORDING_LOOP", "")
    if not loop_raw_value:
        loop_raw_value = read_value_with_default(loop_file, "1m")
    try:
        loop_value = normalize_loop_setting_value(loop_raw_value)
    except ValueError:
        log(f"invalid recording loop value: {loop_raw_value}")
        log("set it with: antcam loop set <duration|none|0> (example: 1m, 30s, 2h, none)")
        return 5

    loop_enabled = loop_value != "none"
    loop_ms = 0
    if loop_enabled:
        try:
            loop_ms = duration_to_milliseconds(loop_value)
        except ValueError:
            loop_ms = 0
        if loop_ms <= 0:
            log(f"invalid recording loop value: {loop_raw_value}")
            log("set it with: antcam loop set <duration|none|0> (example: 1m, 30s, 2h, none)")
            return 5
        if loop_ms < 10_000:
            log(f"recording loop value is too small for photos: {loop_value}")
            log("set loop >= 10s for photos")
            return 6

    name_value = os.environ.get("ANTCAM_RECORDING_NAME", "")
    if not name_value:
        name_value = read_raw_value_with_default(name_file, "BLANK")
    if not is_valid_recording_name_value(name_value):
        log(f"invalid recording name value: {name_value}")
        log("set it with: antcam name set <suffix> (allowed: A-Z a-z 0-9 . _ -)")
        return 7

    still_cmd = choose_still_command()
    if not still_cmd:
        log("rpicam-still or libcamera-still not found. Install Raspberry Pi camera apps.")
        return 1

    capture_dir.mkdir(parents=True, exist_ok=True)
    upload_dir = resolve_upload_dir_path(capture_dir)
    session_timestamp = _dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    session_hostname = resolve_session_hostname()
    session_dir = upload_dir / f"{session_timestamp}__{session_hostname}__{name_value}"
    session_dir.mkdir(parents=True, exist_ok=True)

    log(f"Using still command: {still_cmd}")
    if is_auto_focus_value(focus_value):
        log("Focus mode: auto (no --lens-position override)")
    else:
        log(f"Focus lens-position: {focus_value}")
    log(f"Recording length: {length_value} ({length_ms} ms)")
    if loop_enabled:
        log(f"Loop interval: {loop_value} ({loop_ms} ms)")
    else:
        log("Loop interval: none (loop scheduling disabled; one-shot capture)")
        if length_ms > 0:
            log("Loop is disabled; recording length is ignored for photos one-shot mode")
    log(f"Recording name suffix: {name_value}")
    log(f"Session folder: {session_dir}")
    log(f"Output pattern: {session_dir}/photos-{name_value}-%05d.jpg")

    still_args = [
        "--nopreview",
        "--immediate",
        "--encoding",
        "jpg",
    ]
    if not is_auto_focus_value(focus_value):
        still_args.extend(["--lens-position", focus_value])

    if not loop_enabled:
        # Hard one-shot path: when loop scheduling is disabled, capture exactly one image and exit.
        output_file = session_dir / f"photos-{name_value}-00000.jpg"
        log(f"Starting photo index=0 output={output_file}")
        rc = run_capture(still_cmd, [*still_args, "--output", str(output_file)])
        return rc

    start_epoch_ms = now_epoch_milliseconds()
    end_epoch_ms = start_epoch_ms + length_ms if length_ms > 0 else 0

    capture_index = 0
    while True:
        now_ms = now_epoch_milliseconds()
        expected_index = (now_ms - start_epoch_ms + loop_ms - 1) // loop_ms
        if expected_index > capture_index:
            skipped_slots = expected_index - capture_index
            log(f"scheduler behind by {skipped_slots} slot(s); skipping ahead to preserve start-time alignment")
            capture_index = expected_index

        target_epoch_ms = start_epoch_ms + (capture_index * loop_ms)
        sleep_until_epoch_milliseconds(target_epoch_ms)

        now_ms = now_epoch_milliseconds()
        if end_epoch_ms > 0 and now_ms >= end_epoch_ms:
            break

        output_file = session_dir / f"photos-{name_value}-{capture_index:05d}.jpg"
        log(f"Starting photo index={capture_index} output={output_file}")
        rc = run_capture(still_cmd, [*still_args, "--output", str(output_file)])
        if rc != 0:
            return rc
        capture_index += 1

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Preserve graceful SIGINT stop behavior from shell script flow.
        sys.exit(130)
