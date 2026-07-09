#!/usr/bin/env python3
"""AntSciHub video capture worker.

Python implementation of the former video.sh logic.
Still uses rpicam-vid/libcamera-vid for actual capture.
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import re
import signal
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


def normalize_ev_value(value: str) -> str:
    normalized = (value or "").strip().lower()
    if normalized in {"auto", "default", "none", "off"}:
        return "auto"
    if re.fullmatch(r"[+-]?[0-9]+(?:\.[0-9]+)?", normalized) is not None:
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
    ev_value: str,
    segment_value: str,
    intra_value: str,
    length_value: str,
    width_value: int,
    height_value: int,
) -> str:
    fps_tag = f"{sanitize_capture_tag_value(fps_value, 'unknown')}fps"
    focus_tag = f"foc-{sanitize_capture_tag_value(focus_value, 'unknown')}"
    ev_tag = f"ev-{sanitize_capture_tag_value(ev_value, 'auto')}"
    segment_tag = f"seg-{sanitize_capture_tag_value(segment_value, 'unknown')}"
    intra_tag = f"intra-{sanitize_capture_tag_value(intra_value, 'none')}"
    length_tag = f"len-{sanitize_capture_tag_value(length_value, 'unknown')}"
    resolution_tag = f"{width_value}x{height_value}"
    return "-".join((fps_tag, focus_tag, ev_tag, segment_tag, intra_tag, length_tag, resolution_tag))


def timestamp_iso_local() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def write_json_metadata(path: Path, metadata: dict[str, object]) -> None:
    tmp_path = path.with_name(f".{path.name}.tmp")
    tmp_path.write_text(json.dumps(metadata, indent=2, sort_keys=True, ensure_ascii=True) + "\n", encoding="utf-8")
    tmp_path.replace(path)


def safe_write_json_metadata(path: Path, metadata: dict[str, object], label: str) -> None:
    try:
        write_json_metadata(path, metadata)
    except Exception as exc:
        log(f"failed to write {label}: path={path} error={type(exc).__name__}: {exc}")


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


def resolve_ev_file_path(capture_dir: Path) -> Path:
    override = os.environ.get("ANTCAM_EV_VALUE_FILE", "")
    if override:
        return Path(override)
    return capture_dir / "config" / "recording-ev.txt"


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


class CaptureStopRequested(Exception):
    def __init__(self, signum: int):
        self.signum = signum
        super().__init__(signal_label(signum))


def signal_label(signum: int) -> str:
    try:
        return signal.Signals(signum).name
    except ValueError:
        return f"signal-{signum}"


def install_capture_signal_handlers() -> dict[int, object]:
    previous_handlers: dict[int, object] = {}

    def request_stop(signum: int, frame: object) -> None:
        raise CaptureStopRequested(signum)

    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.getsignal(signum)
        signal.signal(signum, request_stop)
    return previous_handlers


def restore_signal_handlers(previous_handlers: dict[int, object]) -> None:
    for signum, handler in previous_handlers.items():
        signal.signal(signum, handler)


def signal_capture_process(process: subprocess.Popen[str], signum: int) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name != "nt":
            os.killpg(process.pid, signum)
        else:
            process.send_signal(signum)
    except ProcessLookupError:
        return


def wait_for_capture_process(process: subprocess.Popen[str], timeout_seconds: float) -> bool:
    try:
        process.wait(timeout=timeout_seconds)
        return True
    except subprocess.TimeoutExpired:
        return False


def stop_capture_process(process: subprocess.Popen[str], signum: int, display: str, run_cwd: Path) -> None:
    if process.poll() is not None:
        return

    log(
        "capture command stop requested: "
        f"signal={signal_label(signum)} pid={process.pid} command={display} cwd={run_cwd}"
    )
    signal_capture_process(process, signum)
    if wait_for_capture_process(process, 10):
        return

    if signum != signal.SIGTERM:
        log(f"capture command still running after {signal_label(signum)}; sending SIGTERM: pid={process.pid}")
        signal_capture_process(process, signal.SIGTERM)
        if wait_for_capture_process(process, 5):
            return

    log(f"capture command still running after graceful stop; killing: pid={process.pid}")
    if os.name != "nt" and hasattr(signal, "SIGKILL"):
        signal_capture_process(process, signal.SIGKILL)
    else:
        process.kill()
    wait_for_capture_process(process, 5)


def run_capture(command: str, args: list[str], cwd: Optional[Path] = None) -> int:
    cmd = [command, *args]
    display = command_display(cmd)
    run_cwd = cwd or Path.cwd()
    output_tail: deque[str] = deque(maxlen=25)
    process: Optional[subprocess.Popen[str]] = None
    previous_handlers = install_capture_signal_handlers()

    try:
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            cwd=str(cwd) if cwd else None,
            start_new_session=os.name != "nt",
        )

        if process.stdout is not None:
            for line in process.stdout:
                sys.stderr.write(line)
                sys.stderr.flush()
                output_tail.append(line.rstrip())

        return_code = int(process.wait() or 0)
        if return_code != 0:
            tail_text = compact_detail("\n".join(output_tail)) or "(empty)"
            log(f"capture command failed: exit_code={return_code} command={display} cwd={run_cwd} output_tail={tail_text}")
        return return_code
    except OSError as exc:
        log(f"capture command launch failed: command={display} cwd={run_cwd} error={type(exc).__name__}: {exc}")
        return 127 if isinstance(exc, FileNotFoundError) else 1
    except CaptureStopRequested as exc:
        if process is not None:
            stop_capture_process(process, exc.signum, display, run_cwd)
        return 128 + exc.signum
    except KeyboardInterrupt:
        if process is not None:
            stop_capture_process(process, signal.SIGINT, display, run_cwd)
        return 130
    finally:
        restore_signal_handlers(previous_handlers)


def main() -> int:
    capture_dir_arg = os.environ.get("ANTCAM_CAPTURE_DIR") or (sys.argv[1] if len(sys.argv) > 1 else os.getcwd())
    capture_dir = Path(capture_dir_arg).expanduser()

    focus_file = resolve_focus_file_path(capture_dir)
    ev_file = resolve_ev_file_path(capture_dir)
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

    ev_raw_value = os.environ.get("ANTCAM_RECORDING_EV", "")
    if not ev_raw_value:
        ev_raw_value = read_value_with_default(ev_file, "auto")
    ev_value = normalize_ev_value(ev_raw_value)
    if not ev_value:
        log_invalid_setting(
            "recording ev value",
            ev_raw_value,
            setting_source("ANTCAM_RECORDING_EV", ev_file),
            "numeric EV compensation or auto",
        )
        log("set it with: antcam ev set <value|auto> (example: -1, 0, 0.5, auto)")
        return 14

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
        ev_value,
        segment_value,
        intra_value,
        length_value,
        width_value,
        height_value,
    )
    session_stem = f"{name_value}__{session_hostname}__{settings_tag}__{session_timestamp}"
    session_dir = upload_dir / session_stem
    video_output_leaf_pattern = f"{session_stem}-video-%05d.h264"
    video_output_pattern = session_dir / video_output_leaf_pattern
    if not ensure_directory(session_dir, "session directory"):
        return 13

    session_metadata: dict[str, object] = {
        "schema": "antscihub.capture.v1",
        "capture_type": "video",
        "created_at": timestamp_iso_local(),
        "session": {
            "name": name_value,
            "hostname": session_hostname,
            "settings_tag": settings_tag,
            "timestamp": session_timestamp,
            "stem": session_stem,
            "folder": str(session_dir),
            "output_pattern": video_output_leaf_pattern,
        },
        "settings": {
            "focus_lens_position": focus_value,
            "recording_ev": ev_value,
            "recording_fps": fps_value,
            "recording_length": length_value,
            "recording_length_ms": length_ms,
            "recording_segment": segment_value,
            "recording_segment_ms": segment_ms,
            "recording_intra": intra_value,
            "resolution": f"{width_value}x{height_value}",
            "video_width": width_value,
            "video_height": height_value,
        },
        "file_metadata": {
            "embedded_in_video": False,
            "reason": "raw_h264_segments_use_session_sidecar_metadata",
        },
    }
    safe_write_json_metadata(session_dir / "capture-metadata.json", session_metadata, "session metadata")

    log(f"Using video command: {video_cmd}")
    if is_auto_focus_value(focus_value):
        log("Focus mode: auto (no --lens-position override)")
    else:
        log(f"Focus lens-position: {focus_value}")
    if ev_value == "auto":
        log("EV compensation: auto (no --ev override)")
    else:
        log(f"EV compensation: {ev_value}")
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
    log(f"Camera command cwd: {session_dir}")
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
        video_output_leaf_pattern,
    ]
    if intra_value != "none":
        video_args.extend(["--intra", intra_value])
    if ev_value != "auto":
        video_args.extend(["--ev", ev_value])
    if not is_auto_focus_value(focus_value):
        video_args.extend(["--lens-position", focus_value])

    log(
        "Starting segmented capture: "
        f"timeout={capture_timeout_ms}ms segment={segment_ms}ms output={video_output_pattern}"
    )
    return run_capture(video_cmd, video_args, cwd=session_dir)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Preserve graceful SIGINT stop behavior from shell script flow.
        sys.exit(130)
