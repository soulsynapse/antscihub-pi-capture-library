#!/usr/bin/env python3
"""AntSciHub photo capture worker.

Python implementation of the former photos.sh logic.
Still uses rpicam-still/libcamera-still for actual capture.
"""

from __future__ import annotations

import datetime as _dt
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
from collections import deque
from pathlib import Path
from typing import Optional


def log(message: str) -> None:
    print(f"[photos] {message}", file=sys.stderr, flush=True)


def compact_detail(value: str, max_chars: int = 900) -> str:
    collapsed = " | ".join(re.sub(r"\s+", " ", line).strip() for line in value.splitlines() if line.strip())
    if len(collapsed) <= max_chars:
        return collapsed
    return f"{collapsed[: max_chars - 3].rstrip()}..."


def command_display(parts: list[str]) -> str:
    return " ".join(shlex.quote(part) for part in parts)


def setting_source(env_name: str, file_path: Path) -> str:
    if os.environ.get(env_name, ""):
        return f"env:{env_name}"
    if file_path.is_file():
        return f"file:{file_path}"
    return f"default(file_missing={file_path})"


def log_invalid_setting(name: str, value: str, source: str, expected: str, detail: str = "") -> None:
    suffix = f" detail={detail}" if detail else ""
    log(f"invalid {name}: value={value!r} source={source} expected={expected}{suffix}")


def ensure_directory(path: Path, label: str) -> bool:
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        log(f"failed to create {label}: path={path} error={type(exc).__name__}: {exc}")
        return False
    return True


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


def normalize_photo_every_setting_value(raw_value: str) -> str:
    normalized = normalize_duration_value(raw_value)
    if not normalized:
        raise ValueError("empty photo-every value")
    if normalized in {"none", "0"}:
        return "none"
    photo_every_ms = duration_to_milliseconds(normalized)
    if photo_every_ms <= 0:
        return "none"
    return normalized


def is_auto_focus_value(value: str) -> bool:
    return (value or "").strip().lower() == "auto"


def is_valid_lens_position_value(value: str) -> bool:
    return re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value or "") is not None


def is_valid_recording_name_value(value: str) -> bool:
    return re.fullmatch(r"[A-Za-z0-9._-]+", value or "") is not None


def sanitize_capture_tag_value(value: str, fallback: str) -> str:
    tag = re.sub(r"[^A-Za-z0-9._+-]", "-", (value or "").strip())
    tag = re.sub(r"-+", "-", tag).strip("-._")
    return tag or fallback


def build_photo_settings_tag(focus_value: str, photo_every_value: str, length_value: str) -> str:
    focus_tag = f"focus-{sanitize_capture_tag_value(focus_value, 'unknown')}"
    photo_every_tag = f"photo-every-{sanitize_capture_tag_value(photo_every_value, 'unknown')}"
    length_tag = f"len-{sanitize_capture_tag_value(length_value, 'unknown')}"
    return "-".join((focus_tag, photo_every_tag, length_tag))


def parse_positive_int(raw_value: str) -> Optional[int]:
    if re.fullmatch(r"[0-9]+", raw_value or "") is None:
        return None
    try:
        value = int(raw_value)
    except ValueError:
        return None
    if value <= 0:
        return None
    return value


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


def resolve_photo_every_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_PHOTO_EVERY_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-photo-every.txt"


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
    cmd = [command, *args]
    display = command_display(cmd)
    output_tail: deque[str] = deque(maxlen=25)

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
    except OSError as exc:
        log(f"capture command launch failed: command={display} cwd={Path.cwd()} error={type(exc).__name__}: {exc}")
        return 127 if isinstance(exc, FileNotFoundError) else 1

    if process.stdout is not None:
        for line in process.stdout:
            sys.stderr.write(line)
            sys.stderr.flush()
            output_tail.append(line.rstrip())

    return_code = int(process.wait() or 0)
    if return_code != 0:
        tail_text = compact_detail("\n".join(output_tail)) or "(empty)"
        log(f"capture command failed: exit_code={return_code} command={display} cwd={Path.cwd()} output_tail={tail_text}")
    return return_code


def main() -> int:
    capture_dir_arg = os.environ.get("ANTCAM_CAPTURE_DIR") or (sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
    capture_dir = Path(capture_dir_arg).expanduser()

    focus_file = resolve_focus_file_path(capture_dir)
    length_file = resolve_length_file_path(capture_dir)
    photo_every_file = resolve_photo_every_file_path(capture_dir)
    name_file = resolve_name_file_path(capture_dir)

    focus_value = os.environ.get("ANTCAM_FOCUS_LENS_POSITION", "")
    if not focus_value:
        focus_value = read_value_with_default(focus_file, "auto")
    if is_auto_focus_value(focus_value):
        focus_value = "auto"
    elif not is_valid_lens_position_value(focus_value):
        log_invalid_setting(
            "focus lens-position value",
            focus_value,
            setting_source("ANTCAM_FOCUS_LENS_POSITION", focus_file),
            "numeric lens-position or auto",
        )
        log("set it with: antcam focus set <lens-position|auto>")
        return 3

    length_value = os.environ.get("ANTCAM_RECORDING_LENGTH", "")
    if not length_value:
        length_value = read_value_with_default(length_file, "0s")
    length_value = normalize_duration_value(length_value)
    try:
        length_ms = duration_to_milliseconds(length_value)
    except ValueError as exc:
        log_invalid_setting(
            "recording length value",
            length_value,
            setting_source("ANTCAM_RECORDING_LENGTH", length_file),
            "duration like 30h, 10m, 45s, or 1h30m",
            str(exc),
        )
        log("set it with: antcam length set <duration> (example: 30h, 10m, 45s)")
        return 4

    photo_every_raw_value = os.environ.get("ANTCAM_RECORDING_PHOTO_EVERY", "")
    if not photo_every_raw_value:
        photo_every_raw_value = read_value_with_default(photo_every_file, "1m")
    try:
        photo_every_value = normalize_photo_every_setting_value(photo_every_raw_value)
    except ValueError as exc:
        log_invalid_setting(
            "recording photo-every value",
            photo_every_raw_value,
            setting_source("ANTCAM_RECORDING_PHOTO_EVERY", photo_every_file),
            "duration, none, or 0",
            str(exc),
        )
        log("set it with: antcam photo-every set <duration|none|0> (example: 1m, 30s, 2h, none)")
        return 5

    photo_every_enabled = photo_every_value != "none"
    photo_every_ms = 0
    if photo_every_enabled:
        try:
            photo_every_ms = duration_to_milliseconds(photo_every_value)
        except ValueError:
            photo_every_ms = 0
        if photo_every_ms <= 0:
            log_invalid_setting(
                "recording photo-every value",
                photo_every_raw_value,
                setting_source("ANTCAM_RECORDING_PHOTO_EVERY", photo_every_file),
                "duration greater than zero, none, or 0",
            )
            log("set it with: antcam photo-every set <duration|none|0> (example: 1m, 30s, 2h, none)")
            return 5
        if photo_every_ms < 10_000:
            log_invalid_setting(
                "recording photo-every value",
                photo_every_value,
                setting_source("ANTCAM_RECORDING_PHOTO_EVERY", photo_every_file),
                "at least 10s for interval photos",
            )
            log("set photo-every >= 10s for photos")
            return 6

    name_value = os.environ.get("ANTCAM_RECORDING_NAME", "")
    if not name_value:
        name_value = read_raw_value_with_default(name_file, "BLANK")
    if not is_valid_recording_name_value(name_value):
        log_invalid_setting(
            "recording name value",
            name_value,
            setting_source("ANTCAM_RECORDING_NAME", name_file),
            "A-Z a-z 0-9 . _ -",
        )
        log("set it with: antcam name set <name> (allowed: A-Z a-z 0-9 . _ -)")
        return 7

    still_cmd = choose_still_command()
    if not still_cmd:
        log(f"rpicam-still or libcamera-still not found: tried=rpicam-still,libcamera-still PATH={os.environ.get('PATH', '')}")
        return 1

    if not ensure_directory(capture_dir, "capture directory"):
        return 12
    upload_dir = resolve_upload_dir_path(capture_dir)
    session_timestamp = _dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    session_hostname = resolve_session_hostname()
    settings_tag = build_photo_settings_tag(focus_value, photo_every_value, length_value)
    session_stem = f"{name_value}__{session_hostname}__{settings_tag}__{session_timestamp}"
    session_dir = upload_dir / session_stem
    photo_output_pattern = session_dir / f"{session_stem}__photo-%05d.jpg"
    if not ensure_directory(session_dir, "session directory"):
        return 13

    log(f"Using still command: {still_cmd}")
    if is_auto_focus_value(focus_value):
        log("Focus mode: auto (no --lens-position override)")
    else:
        log(f"Focus lens-position: {focus_value}")
    log(f"Recording length: {length_value} ({length_ms} ms)")
    if photo_every_enabled:
        log(f"Photo-every interval: {photo_every_value} ({photo_every_ms} ms)")
        if length_ms <= 0:
            log("Recording length is 0s; photo scheduling resolves to one-shot capture")
    else:
        log("Photo-every interval: none (one-shot capture)")
        if length_ms > 0:
            log("Photo-every is disabled; recording length is ignored for photos one-shot mode")
    log(f"Recording name component: {name_value}")
    log(f"Capture settings tag: {settings_tag}")
    log(f"Session folder: {session_dir}")
    log(f"Output pattern: {photo_output_pattern}")

    still_args = [
        "--nopreview",
        "--immediate",
        "--encoding",
        "jpg",
    ]
    if not is_auto_focus_value(focus_value):
        still_args.extend(["--lens-position", focus_value])

    if (not photo_every_enabled) or length_ms <= 0:
        # One-shot path: disabled scheduling, or non-positive length.
        output_file = session_dir / f"{session_stem}__photo-00000.jpg"
        log(f"Starting photo index=0 output={output_file}")
        rc = run_capture(still_cmd, [*still_args, "--output", str(output_file)])
        return rc

    start_epoch_ms = now_epoch_milliseconds()
    start_epoch_override_raw = os.environ.get("ANTCAM_RECORDING_START_EPOCH_MS", "").strip()
    if start_epoch_override_raw:
        start_epoch_override = parse_positive_int(start_epoch_override_raw)
        if start_epoch_override is None:
            log_invalid_setting(
                "recording start epoch override",
                start_epoch_override_raw,
                "env:ANTCAM_RECORDING_START_EPOCH_MS",
                "positive integer epoch milliseconds",
            )
            return 8
        if start_epoch_override > start_epoch_ms:
            log(
                "recording start epoch override is in the future; "
                f"falling back to current epoch {start_epoch_ms}"
            )
        else:
            start_epoch_ms = start_epoch_override
            log(f"Recording schedule anchor epoch override: {start_epoch_ms}")

    total_captures = (length_ms // photo_every_ms) + 1

    capture_index = 0
    while capture_index < total_captures:
        now_ms = now_epoch_milliseconds()
        expected_index = (now_ms - start_epoch_ms + photo_every_ms - 1) // photo_every_ms
        if expected_index > capture_index:
            skipped_slots = expected_index - capture_index
            log(f"scheduler behind by {skipped_slots} slot(s); skipping ahead to preserve start-time alignment")
            capture_index = expected_index
            if capture_index >= total_captures:
                break

        target_epoch_ms = start_epoch_ms + (capture_index * photo_every_ms)
        sleep_until_epoch_milliseconds(target_epoch_ms)

        output_file = session_dir / f"{session_stem}__photo-{capture_index:05d}.jpg"
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
