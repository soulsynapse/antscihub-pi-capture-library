#!/usr/bin/env python3
"""AntSciHub video capture worker.

Python implementation of the former video.sh logic.
Still uses rpicam-vid/libcamera-vid for actual capture.
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
from collections import deque
from pathlib import Path
from typing import Optional


def log(message: str) -> None:
    print(f"[video] {message}", file=sys.stderr, flush=True)


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


def is_auto_focus_value(value: str) -> bool:
    return (value or "").strip().lower() == "auto"


def is_valid_lens_position_value(value: str) -> bool:
    return re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value or "") is not None


def is_valid_fps_value(value: str) -> bool:
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value or "") is None:
        return False
    try:
        return float(value) > 0
    except ValueError:
        return False


def normalize_intra_value(value: str) -> str:
    normalized = (value or "").strip().lower()
    if normalized in {"none", "off", "default", "auto", "0"}:
        return "none"
    if re.fullmatch(r"[0-9]+", normalized) is not None and re.fullmatch(r"0+", normalized) is None:
        return normalized
    return ""


def is_valid_recording_name_value(value: str) -> bool:
    return re.fullmatch(r"[A-Za-z0-9._-]+", value or "") is not None


def sanitize_capture_tag_value(value: str, fallback: str) -> str:
    tag = re.sub(r"[^A-Za-z0-9._+-]", "-", (value or "").strip())
    tag = re.sub(r"-+", "-", tag).strip("-._")
    return tag or fallback


def build_video_settings_tag(
    fps_value: str,
    focus_value: str,
    segment_value: str,
    intra_value: str,
    length_value: str,
    width_value: int,
    height_value: int,
) -> str:
    fps_tag = f"{sanitize_capture_tag_value(fps_value, 'unknown')}fps"
    focus_tag = f"focus-{sanitize_capture_tag_value(focus_value, 'unknown')}"
    segment_tag = f"seg-{sanitize_capture_tag_value(segment_value, 'unknown')}"
    intra_tag = f"intra-{sanitize_capture_tag_value(intra_value, 'none')}"
    length_tag = f"len-{sanitize_capture_tag_value(length_value, 'unknown')}"
    resolution_tag = f"{width_value}x{height_value}"
    return "-".join((fps_tag, focus_tag, segment_tag, intra_tag, length_tag, resolution_tag))


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


def resolve_fps_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_FPS_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-fps.txt"


def resolve_length_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_LENGTH_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-length.txt"


def resolve_segment_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_SEGMENT_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-segment.txt"


def resolve_intra_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_INTRA_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-intra.txt"


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


def choose_video_command() -> Optional[str]:
    for name in ("rpicam-vid", "libcamera-vid"):
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
    fps_file = resolve_fps_file_path(capture_dir)
    length_file = resolve_length_file_path(capture_dir)
    segment_file = resolve_segment_file_path(capture_dir)
    intra_file = resolve_intra_file_path(capture_dir)
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

    fps_value = os.environ.get("ANTCAM_RECORDING_FPS", "")
    if not fps_value:
        fps_value = read_value_with_default(fps_file, "1")
    if not is_valid_fps_value(fps_value):
        log_invalid_setting(
            "recording fps value",
            fps_value,
            setting_source("ANTCAM_RECORDING_FPS", fps_file),
            "numeric value greater than zero",
        )
        log("set it with: antcam fps set <value>")
        return 4

    width_value_raw = os.environ.get("ANTCAM_VIDEO_WIDTH", "1920")
    height_value_raw = os.environ.get("ANTCAM_VIDEO_HEIGHT", "1080")
    width_value = parse_positive_int(width_value_raw)
    height_value = parse_positive_int(height_value_raw)
    if width_value is None or height_value is None:
        log_invalid_setting(
            "video resolution",
            f"{width_value_raw}x{height_value_raw}",
            "env:ANTCAM_VIDEO_WIDTH/env:ANTCAM_VIDEO_HEIGHT",
            "positive integer width and height",
        )
        log("set ANTCAM_VIDEO_WIDTH and ANTCAM_VIDEO_HEIGHT to positive integers")
        return 9

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
        return 5

    segment_value = os.environ.get("ANTCAM_RECORDING_SEGMENT", "")
    if not segment_value:
        segment_value = read_value_with_default(segment_file, "1m")
    segment_value = normalize_duration_value(segment_value)
    segment_error = ""
    try:
        segment_ms = duration_to_milliseconds(segment_value)
    except ValueError as exc:
        segment_ms = 0
        segment_error = str(exc)
    if segment_ms <= 0:
        log_invalid_setting(
            "recording segment value",
            segment_value,
            setting_source("ANTCAM_RECORDING_SEGMENT", segment_file),
            "duration greater than zero, like 10m, 30s, or 1h",
            segment_error,
        )
        log("set it with: antcam segment set <duration> (example: 10m, 30s, 1h)")
        return 6

    intra_raw_value = os.environ.get("ANTCAM_RECORDING_INTRA", "")
    if not intra_raw_value:
        intra_raw_value = read_value_with_default(intra_file, "none")
    intra_value = normalize_intra_value(intra_raw_value)
    if not intra_value:
        log_invalid_setting(
            "recording intra value",
            intra_raw_value,
            setting_source("ANTCAM_RECORDING_INTRA", intra_file),
            "positive integer frame period, none, or 0",
        )
        log("set it with: antcam intra set <frames|none|0>")
        return 11

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
        return 10

    video_cmd = choose_video_command()
    if not video_cmd:
        log(f"rpicam-vid or libcamera-vid not found: tried=rpicam-vid,libcamera-vid PATH={os.environ.get('PATH', '')}")
        return 1

    if not ensure_directory(capture_dir, "capture directory"):
        return 12
    upload_dir = resolve_upload_dir_path(capture_dir)
    session_timestamp = _dt.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    session_hostname = resolve_session_hostname()
    settings_tag = build_video_settings_tag(
        fps_value,
        focus_value,
        segment_value,
        intra_value,
        length_value,
        width_value,
        height_value,
    )
    session_stem = f"{name_value}__{session_hostname}__{settings_tag}__{session_timestamp}"
    session_dir = upload_dir / session_stem
    video_output_pattern = session_dir / f"{session_stem}__video-%05d.h264"
    if not ensure_directory(session_dir, "session directory"):
        return 13

    log(f"Using video command: {video_cmd}")
    if is_auto_focus_value(focus_value):
        log("Focus mode: auto (no --lens-position override)")
    else:
        log(f"Focus lens-position: {focus_value}")
    log(f"Recording length: {length_value} ({length_ms} ms)")
    log(f"Chunk length: {segment_value} ({segment_ms} ms)")
    log("Scheduling mode: contiguous segment capture (no interval scheduling)")
    log(f"Frame rate: {fps_value} fps")
    log(f"Resolution: {width_value}x{height_value}")
    if intra_value == "none":
        log("Intra period: camera default (no --intra override)")
    else:
        log(f"Intra period: {intra_value} frames")
    log(f"Recording name component: {name_value}")
    log(f"Capture settings tag: {settings_tag}")
    log(f"Session folder: {session_dir}")
    log(f"Output pattern: {video_output_pattern}")
    log("Recording mode: single rpicam process with --segment (avoids per-clip startup loss)")

    capture_timeout_ms = length_ms if length_ms > 0 else 0
    video_args = [
        "--nopreview",
        "--timeout",
        str(capture_timeout_ms),
        "--framerate",
        fps_value,
        "--codec",
        "h264",
        "--inline",
        "--width",
        str(width_value),
        "--height",
        str(height_value),
        "--segment",
        str(segment_ms),
        "--output",
        str(video_output_pattern),
    ]
    if intra_value != "none":
        video_args.extend(["--intra", intra_value])
    if not is_auto_focus_value(focus_value):
        video_args.extend(["--lens-position", focus_value])

    log(
        "Starting segmented capture: "
        f"timeout={capture_timeout_ms}ms segment={segment_ms}ms output={video_output_pattern}"
    )
    return run_capture(video_cmd, video_args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Preserve graceful SIGINT stop behavior from shell script flow.
        sys.exit(130)
