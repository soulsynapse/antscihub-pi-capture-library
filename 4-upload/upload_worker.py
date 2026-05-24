#!/usr/bin/env python3
"""AntSciHub upload worker (hybrid Python rewrite).

Store-and-forward spool shipper:
- Scans <desktop>/5-UPLOAD
- Tracks artifact lifecycle in SQLite
- Ships by copy (rclone/local)
- Applies protect/rolling retention policies
"""

from __future__ import annotations

import datetime as _dt
import fcntl
import fnmatch
import hashlib
import json
import os
import random
import re
import shlex as _shlex
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import time
from collections import deque
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Deque, Dict, List, Optional, Sequence, Tuple


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def _as_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except (TypeError, ValueError):
        return default


def _timestamp_local() -> str:
    return _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _timestamp_utc_iso() -> str:
    return _dt.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def _epoch_now() -> int:
    return int(time.time())


def _normalize_text(value: str) -> str:
    return value.replace("\r", "").replace("\n", "")


def _sanitize_machine_suffix(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", value)
    cleaned = re.sub(r"__+", "_", cleaned)
    cleaned = cleaned.strip("_")
    return cleaned or "unknown-machine"


def _is_truthy(value: str) -> Optional[bool]:
    lowered = value.strip().lower()
    if lowered in {"1", "true", "yes", "on"}:
        return True
    if lowered in {"0", "false", "no", "off"}:
        return False
    return None


def _first_path_entry(value: str) -> str:
    # systemd can provide colon-separated directory lists for managed dirs.
    return value.split(":", 1)[0]


def _cmd_exists(name: str) -> bool:
    return shutil.which(name) is not None


@dataclass
class RuntimeSettings:
    profile: str
    retention: str
    paused: bool
    local_target: str
    remote_name: str
    remote_path: str
    high_watermark: int
    low_watermark: int


class UploadWorker:
    STILL_IMAGE_PATTERNS = (
        "*.jpg",
        "*.jpeg",
        "*.png",
        "*.tif",
        "*.tiff",
        "*.bmp",
        "*.gif",
        "*.webp",
        "*.heic",
        "*.heif",
        "*.dng",
        "*.cr2",
        "*.cr3",
        "*.nef",
        "*.arw",
        "*.orf",
        "*.rw2",
        "*.raf",
    )
    VIDEO_PATTERNS = (
        "*.h264",
        "*.h265",
        "*.hevc",
        "*.mp4",
        "*.mov",
        "*.mkv",
        "*.avi",
        "*.mts",
        "*.m2ts",
        "*.ts",
        "*.webm",
        "*.mjpeg",
        "*.yuv",
    )
    RUNTIME_STATE_PATTERNS = (
        "*.env",
        "*.pid",
        "*.lock",
        "*.tmp",
        "*.temp",
        "*.part",
        "*.partial",
        "*.swp",
        "*.swo",
        "*.db",
        "*.db-*",
        "*.sqlite",
        "*.sqlite-*",
        "*.journal",
        "state.env",
        "capture.log",
    )

    def __init__(self) -> None:
        self.upload_dir = self._resolve_upload_dir()
        self.upload_config_dir = self._resolve_upload_config_dir(self.upload_dir)

        state_base = _env(
            "STATE_DIRECTORY",
            f"{_env('XDG_STATE_HOME', os.path.join(_env('HOME', ''), '.local', 'state'))}/antscihub-upload",
        )
        log_base = _env(
            "LOGS_DIRECTORY",
            f"{_env('XDG_STATE_HOME', os.path.join(_env('HOME', ''), '.local', 'state'))}/antscihub-upload",
        )
        runtime_base = _env("RUNTIME_DIRECTORY", _env("XDG_RUNTIME_DIR", "/tmp"))

        self.state_dir = _first_path_entry(state_base)
        self.log_dir = _first_path_entry(log_base)
        self.runtime_dir = _first_path_entry(runtime_base)

        self.db_file = os.path.join(self.state_dir, "queue.db")
        self.legacy_processed_file = os.path.join(self.state_dir, "processed.txt")
        self.log_file = os.path.join(self.log_dir, "antscihub-upload.log")
        self.lock_file = os.path.join(self.state_dir, "antscihub-upload.lock")
        self.protect_stop_stamp_file = os.path.join(self.state_dir, "last-protect-stop.epoch")

        self.upload_profile_file = os.path.join(self.upload_config_dir, "upload-profile.txt")
        self.upload_retention_file = os.path.join(self.upload_config_dir, "upload-retention.txt")
        self.upload_paused_file = os.path.join(self.upload_config_dir, "upload-paused.txt")
        self.upload_local_target_file = os.path.join(self.upload_config_dir, "upload-local-target.txt")
        self.upload_rclone_remote_file = os.path.join(self.upload_config_dir, "upload-rclone-remote.txt")
        self.upload_rclone_path_file = os.path.join(self.upload_config_dir, "upload-rclone-path.txt")
        self.upload_high_watermark_file = os.path.join(self.upload_config_dir, "upload-high-watermark-percent.txt")
        self.upload_low_watermark_file = os.path.join(self.upload_config_dir, "upload-low-watermark-percent.txt")

        self.upload_service_name = _env("UPLOAD_SERVICE_NAME", "antscihub-upload.service")
        self.upload_stop_command = _env("UPLOAD_STOP_COMMAND", "antcam stop")

        self.fleet_event_topic_template = _env("FLEET_EVENT_TOPIC_TEMPLATE", "fleet/report/{DEVICE_ID}")
        self.fleet_publish_bin = _env("FLEET_PUBLISH_BIN", "fleet-publish")
        self.mqtt_report_bin = _env("MQTT_REPORT_BIN", "mqtt_report.py")
        self.mqtt_event_enabled = _env("MQTT_EVENT_ENABLED", "true").lower() == "true"

        machine_suffix = _env("MACHINE_SUFFIX", "")
        if not machine_suffix:
            machine_suffix = socket.gethostname()
        self.machine_suffix = _sanitize_machine_suffix(machine_suffix)

        self.default_upload_profile = _env("UPLOAD_PROFILE", "field")
        self.default_upload_retention = _env("UPLOAD_RETENTION", "protect")
        self.default_upload_paused = _env("UPLOAD_PAUSED", "false")
        self.default_upload_local_target = _env("UPLOAD_LOCAL_TARGET_PATH", "")
        self.default_upload_rclone_remote = _env("RCLONE_REMOTE", "")
        self.default_upload_rclone_path = _env("RCLONE_PATH", "")
        self.default_upload_high_watermark = _env("UPLOAD_HIGH_WATERMARK_PERCENT", "80")
        self.default_upload_low_watermark = _env("UPLOAD_LOW_WATERMARK_PERCENT", "70")

        self.max_retries = _as_int("MAX_RETRIES", 5)
        self.scan_interval = _as_int("SCAN_INTERVAL", 10)
        self.min_file_age_default = _as_int("MIN_FILE_AGE_DEFAULT", 30)
        self.min_file_age_still_image = _as_int("MIN_FILE_AGE_STILL_IMAGE", 3)
        self.min_file_age_video = _as_int("MIN_FILE_AGE_VIDEO", 120)
        self.min_file_age_state_and_log = _as_int("MIN_FILE_AGE_STATE_AND_LOG", 300)
        self.file_stability_interval_default = _as_int("FILE_STABILITY_CHECK_INTERVAL_DEFAULT", 10)
        self.file_stability_interval_still_image = _as_int("FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE", 3)
        self.protect_stop_cooldown_seconds = _as_int("PROTECT_STOP_COOLDOWN_SECONDS", 300)
        self.retry_base_delay_seconds = _as_int("RETRY_BASE_DELAY_SECONDS", 2)
        self.retry_max_delay_seconds = _as_int("RETRY_MAX_DELAY_SECONDS", 600)
        self.retry_jitter_max_seconds = max(0, _as_int("RETRY_JITTER_MAX_SECONDS", 30))
        self.rclone_lsf_timeout_seconds = max(5, _as_int("RCLONE_LSF_TIMEOUT_SECONDS", 20))
        self.rclone_copy_timeout_seconds = max(30, _as_int("RCLONE_COPY_TIMEOUT_SECONDS", 1800))
        self.rclone_connect_timeout_seconds = max(5, _as_int("RCLONE_CONNECT_TIMEOUT_SECONDS", 15))
        self.rclone_io_timeout_seconds = max(10, _as_int("RCLONE_IO_TIMEOUT_SECONDS", 120))
        self.file_identity_sample_bytes = max(4096, _as_int("FILE_IDENTITY_SAMPLE_BYTES", 65536))
        self.seen_cache_max_entries = max(1000, _as_int("SEEN_CACHE_MAX_ENTRIES", 50000))
        self.stability_cache_max_entries = max(1000, _as_int("STABILITY_CACHE_MAX_ENTRIES", 50000))
        self.max_scan_files_per_loop = max(1, _as_int("MAX_SCAN_FILES_PER_LOOP", 500))
        self.max_due_attempts_per_loop = max(1, _as_int("MAX_DUE_ATTEMPTS_PER_LOOP", 50))
        self.min_due_attempts_per_loop = max(1, _as_int("MIN_DUE_ATTEMPTS_PER_LOOP", 5))
        if self.min_due_attempts_per_loop > self.max_due_attempts_per_loop:
            self.min_due_attempts_per_loop = self.max_due_attempts_per_loop
        self.attempt_log_max_rows = _as_int("ATTEMPT_LOG_MAX_ROWS", 100000)
        self.attempt_log_prune_interval_seconds = max(30, _as_int("ATTEMPT_LOG_PRUNE_INTERVAL_SECONDS", 300))
        self.initial_upload_jitter_max_seconds = max(0, _as_int("INITIAL_UPLOAD_JITTER_MAX_SECONDS", 30))
        if self.attempt_log_max_rows < 0:
            self.attempt_log_max_rows = 0

        self.device_id_cache: Optional[str] = None
        self.mqtt_publish_warning_emitted = False
        self.settings_warning_emitted = False
        self.pause_notice_emitted = False
        self.open_file_check_tool = "none"
        self.current_settings = RuntimeSettings(
            profile="field",
            retention="protect",
            paused=False,
            local_target="",
            remote_name="",
            remote_path="",
            high_watermark=80,
            low_watermark=70,
        )
        self.seen_file_detections: Dict[str, bool] = {}
        self.seen_file_exclusions: Dict[str, bool] = {}
        self.file_stability_observations: Dict[str, Tuple[int, int]] = {}
        self.scan_dir_queue: Deque[str] = deque()
        self.scan_file_queue: Deque[str] = deque()
        self.last_attempt_log_prune_epoch = 0
        self.global_retry_pause_until_epoch = 0
        self.last_global_retry_pause_notice_epoch = 0
        self.running = True

        self._lock_handle = None
        self.conn: Optional[sqlite3.Connection] = None
        self._db_tx_depth = 0

    def _resolve_desktop_dir(self) -> str:
        home = _env("HOME", "")
        desktop_dir = ""

        if _cmd_exists("xdg-user-dir"):
            try:
                result = subprocess.run(
                    ["xdg-user-dir", "DESKTOP"],
                    check=False,
                    capture_output=True,
                    text=True,
                )
                desktop_dir = result.stdout.strip()
            except Exception:
                desktop_dir = ""

        if not desktop_dir or desktop_dir == home:
            user_dirs_file = os.path.join(_env("XDG_CONFIG_HOME", os.path.join(home, ".config")), "user-dirs.dirs")
            if os.path.isfile(user_dirs_file):
                try:
                    with open(user_dirs_file, "r", encoding="utf-8", errors="replace") as handle:
                        for line in handle:
                            line = line.strip()
                            if line.startswith("XDG_DESKTOP_DIR="):
                                raw = line.split("=", 1)[1].strip().strip('"')
                                desktop_dir = raw.replace("$HOME", home)
                                break
                except Exception:
                    desktop_dir = ""

        if not desktop_dir or desktop_dir == home:
            if os.path.isdir(os.path.join(home, "Desktop")):
                desktop_dir = os.path.join(home, "Desktop")
            elif os.path.isdir(os.path.join(home, "desktop")):
                desktop_dir = os.path.join(home, "desktop")
            else:
                desktop_dir = os.path.join(home, "Desktop")

        return desktop_dir.rstrip("/\\")

    def _resolve_upload_dir(self) -> str:
        explicit = _env("UPLOAD_DIR", "")
        if explicit:
            return explicit.rstrip("/\\")
        return os.path.join(self._resolve_desktop_dir(), "5-UPLOAD")

    def _resolve_upload_config_dir(self, upload_dir: str) -> str:
        explicit = _env("UPLOAD_CONFIG_DIR", "")
        if explicit:
            return explicit.rstrip("/\\")
        upload_parent = os.path.dirname(upload_dir.rstrip("/\\"))
        return os.path.join(upload_parent, "4-CAPTURE", "config")

    def log(self, level: str, message: str) -> None:
        line = f"[{_timestamp_local()}] [{level}] {message}"
        print(line, flush=True)
        try:
            with open(self.log_file, "a", encoding="utf-8", errors="replace") as handle:
                handle.write(line + "\n")
        except Exception:
            pass

    def log_raw(self, text: str) -> None:
        print(text, flush=True)
        try:
            with open(self.log_file, "a", encoding="utf-8", errors="replace") as handle:
                handle.write(text + "\n")
        except Exception:
            pass

    def read_value_with_default(self, file_path: str, default: str) -> str:
        if not os.path.isfile(file_path):
            return default
        try:
            with open(file_path, "r", encoding="utf-8", errors="replace") as handle:
                first = handle.readline()
        except Exception:
            return default
        normalized = _normalize_text(first)
        return normalized if normalized else default

    @staticmethod
    def is_valid_profile(value: str) -> bool:
        return value in {"field", "cloud", "local"}

    @staticmethod
    def is_valid_retention(value: str) -> bool:
        return value in {"protect", "rolling"}

    @staticmethod
    def normalize_remote_path(value: str) -> str:
        normalized = _normalize_text(value).strip("/")
        return "" if normalized == "." else normalized

    @staticmethod
    def normalize_watermark(value: str) -> Optional[int]:
        if not re.fullmatch(r"\d+", value):
            return None
        parsed = int(value)
        if parsed < 1 or parsed > 99:
            return None
        return parsed

    def refresh_runtime_settings(self) -> None:
        profile = self.read_value_with_default(self.upload_profile_file, self.default_upload_profile).lower()
        if not self.is_valid_profile(profile):
            profile = "field"
            if not self.settings_warning_emitted:
                self.log("WARN", "Invalid upload profile setting; falling back to field")
                self.settings_warning_emitted = True

        retention = self.read_value_with_default(self.upload_retention_file, self.default_upload_retention).lower()
        if not self.is_valid_retention(retention):
            retention = "protect"
            if not self.settings_warning_emitted:
                self.log("WARN", "Invalid upload retention setting; falling back to protect")
                self.settings_warning_emitted = True

        paused_raw = self.read_value_with_default(self.upload_paused_file, self.default_upload_paused)
        paused = _is_truthy(paused_raw)
        paused = False if paused is None else paused

        local_target = self.read_value_with_default(self.upload_local_target_file, self.default_upload_local_target)
        if local_target.lower() == "none":
            local_target = ""

        remote_name = self.read_value_with_default(self.upload_rclone_remote_file, self.default_upload_rclone_remote)
        if remote_name.lower() == "none":
            remote_name = ""

        remote_path = self.read_value_with_default(self.upload_rclone_path_file, self.default_upload_rclone_path)
        if remote_path.lower() == "none":
            remote_path = ""
        remote_path = self.normalize_remote_path(remote_path)

        high_raw = self.read_value_with_default(self.upload_high_watermark_file, self.default_upload_high_watermark)
        low_raw = self.read_value_with_default(self.upload_low_watermark_file, self.default_upload_low_watermark)
        high = self.normalize_watermark(high_raw)
        low = self.normalize_watermark(low_raw)
        if high is None:
            high = 80
        if low is None:
            low = 70
        if low >= high:
            low = max(1, high - 10)

        self.current_settings = RuntimeSettings(
            profile=profile,
            retention=retention,
            paused=paused,
            local_target=local_target,
            remote_name=remote_name,
            remote_path=remote_path,
            high_watermark=high,
            low_watermark=low,
        )

    def resolve_device_id(self) -> str:
        if self.device_id_cache is not None:
            return self.device_id_cache

        candidate = ""
        if _env("DEVICE_ID", ""):
            candidate = _env("DEVICE_ID", "")
        elif _env("FLEET_DEVICE_ID", ""):
            candidate = _env("FLEET_DEVICE_ID", "")
        candidate = _normalize_text(candidate).replace("\t", "").replace(" ", "")
        if not candidate:
            candidate = self.machine_suffix

        self.device_id_cache = candidate
        return candidate

    def build_fleet_event_topic(self, device_id: str) -> str:
        topic = self.fleet_event_topic_template.replace("{DEVICE_ID}", device_id)
        return topic or f"fleet/report/{device_id}"

    @staticmethod
    def upload_status_to_report_name(status: str) -> str:
        return {
            "queued": "upload_queued",
            "in_flight": "upload_in_flight",
            "shipped": "upload_shipped",
            "failed": "upload_failed",
            "retry": "upload_retry_scheduled",
            "dead_letter": "upload_dead_letter",
            "pruned": "upload_pruned",
            "paused": "upload_paused",
            "protect_stop": "upload_protect_stop_requested",
        }.get(status, "upload_status")

    @staticmethod
    def upload_status_to_severity(status: str) -> str:
        return {
            "queued": "ROUTINE",
            "in_flight": "ATTENTION",
            "shipped": "INFO",
            "pruned": "INFO",
            "retry": "WARNING",
            "paused": "WARNING",
            "failed": "ERROR",
            "dead_letter": "ERROR",
            "protect_stop": "ERROR",
        }.get(status, "INFO")

    @staticmethod
    def upload_status_to_success(status: str) -> bool:
        return status in {"queued", "in_flight", "shipped", "pruned"}

    @staticmethod
    def format_size_for_report_message(size_bytes: str) -> str:
        raw = str(size_bytes or "").strip()
        if not raw:
            return "unknown"
        try:
            size_value = int(raw)
        except (TypeError, ValueError):
            return "unknown"
        if size_value < 0:
            return "unknown"

        units = ("B", "KB", "MB", "GB", "TB", "PB", "EB")
        scaled = float(size_value)
        unit = units[0]
        for unit in units:
            if scaled < 1024 or unit == units[-1]:
                break
            scaled /= 1024.0

        if unit == "B":
            return f"{int(scaled)}{unit}"

        text_value = f"{scaled:.1f}"
        if text_value.endswith(".0"):
            text_value = text_value[:-2]
        return f"{text_value}{unit}"

    def _run_quiet(self, args: Sequence[str]) -> bool:
        try:
            result = subprocess.run(args, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return result.returncode == 0
        except Exception:
            return False

    def publish_with_fleet_publish(self, topic: str, payload: str) -> bool:
        if not _cmd_exists(self.fleet_publish_bin):
            return False

        variants = [
            [self.fleet_publish_bin, "--topic", topic, "--json", payload],
            [self.fleet_publish_bin, "--topic", topic, "--payload", payload],
            [self.fleet_publish_bin, "--topic", topic, "--message", payload],
            [self.fleet_publish_bin, "-t", topic, "-m", payload],
        ]
        return any(self._run_quiet(args) for args in variants)

    def publish_with_mqtt_report_cli(self, topic: str, payload: str) -> bool:
        if not _cmd_exists(self.mqtt_report_bin):
            return False
        return self._run_quiet([self.mqtt_report_bin, "--topic", topic, "--json", payload])

    def publish_with_fleet_mqtt_python(self, topic: str, payload: str) -> bool:
        try:
            payload_obj = json.loads(payload)
        except Exception:
            payload_obj = payload

        try:
            from mqtt_client import FleetMQTT  # type: ignore
        except Exception:
            return False

        client = None
        for ctor in (lambda: FleetMQTT(), lambda: FleetMQTT("antscihub-upload")):
            try:
                client = ctor()
                break
            except Exception:
                continue
        if client is None:
            return False

        published = False
        try:
            for method_name in ("publish_json", "publish", "send"):
                method = getattr(client, method_name, None)
                if not callable(method):
                    continue
                try:
                    if method_name == "publish_json":
                        parsed = payload_obj
                        if isinstance(parsed, str):
                            parsed = json.loads(parsed)
                        try:
                            method(topic, parsed, encrypt=True)
                        except TypeError:
                            method(topic, parsed)
                    else:
                        try:
                            method(topic, payload_obj, encrypt=True)
                        except TypeError:
                            try:
                                method(topic, payload_obj)
                            except TypeError:
                                method(topic, payload)
                    published = True
                    break
                except Exception:
                    continue
        finally:
            for close_name in ("close", "disconnect", "stop"):
                close_method = getattr(client, close_name, None)
                if callable(close_method):
                    try:
                        close_method()
                    except Exception:
                        pass

        return published

    def publish_upload_mqtt_event(
        self,
        status: str,
        relative_path: str,
        destination: str,
        size_bytes: str,
        attempt: str,
        reason: str,
        exit_code: str,
    ) -> None:
        if not self.mqtt_event_enabled:
            return

        device_id = self.resolve_device_id()
        report_name = self.upload_status_to_report_name(status)
        severity = self.upload_status_to_severity(status)
        success = self.upload_status_to_success(status)
        size_label = self.format_size_for_report_message(size_bytes)
        message = f"upload status={status}"
        if relative_path:
            message += f" file={relative_path}"
        if reason:
            message += f" reason={reason}"
        if size_label != "unknown":
            message += f" (SIZE: {size_label})"

        payload = json.dumps(
            {
                "event": "report",
                "report": report_name,
                "device_id": device_id,
                "timestamp": _epoch_now(),
                "service": self.upload_service_name,
                "success": success,
                "severity": severity,
                "message": message,
                "file": relative_path,
                "destination": destination,
                "size_bytes": str(size_bytes),
                "attempt": str(attempt),
                "reason": str(reason),
                "exit_code": str(exit_code),
            },
            separators=(",", ":"),
        )

        topic = self.build_fleet_event_topic(device_id)
        if self.publish_with_fleet_publish(topic, payload):
            return
        if self.publish_with_mqtt_report_cli(topic, payload):
            return
        if self.publish_with_fleet_mqtt_python(topic, payload):
            return
        if not self.mqtt_publish_warning_emitted:
            self.log("WARN", "Unable to publish upload MQTT events")
            self.mqtt_publish_warning_emitted = True

    def emit_upload_event(
        self,
        status: str,
        relative_path: str = "",
        destination: str = "",
        size_bytes: str = "unknown",
        attempt: str = "",
        reason: str = "",
        exit_code: str = "",
    ) -> None:
        ts = _timestamp_utc_iso()
        safe_file = shlex_quote(relative_path)
        safe_dest = shlex_quote(destination)
        print(
            f"UPLOAD_EVENT status={status} ts={ts} file={safe_file} destination={safe_dest} size_bytes={size_bytes}",
            flush=True,
        )
        self.publish_upload_mqtt_event(status, relative_path, destination, size_bytes, attempt, reason, exit_code)

    def db_open(self) -> None:
        self.conn = sqlite3.connect(self.db_file, timeout=5)
        self.conn.execute("PRAGMA busy_timeout=5000;")
        self.conn.execute("PRAGMA journal_mode=WAL;")
        self.conn.execute("PRAGMA synchronous=FULL;")
        self.conn.execute("PRAGMA foreign_keys=ON;")

    def db_exec(self, sql: str, params: Sequence[object] = ()) -> None:
        assert self.conn is not None
        self.conn.execute(sql, tuple(params))
        if self._db_tx_depth == 0:
            self.conn.commit()

    def db_query_one(self, sql: str, params: Sequence[object] = ()) -> Optional[sqlite3.Row]:
        assert self.conn is not None
        self.conn.row_factory = sqlite3.Row
        cursor = self.conn.execute(sql, tuple(params))
        row = cursor.fetchone()
        return row

    @contextmanager
    def db_transaction(self):
        assert self.conn is not None
        if self._db_tx_depth == 0:
            self.conn.execute("BEGIN IMMEDIATE;")
        self._db_tx_depth += 1
        try:
            yield
        except Exception:
            self._db_tx_depth -= 1
            if self._db_tx_depth == 0:
                self.conn.rollback()
            raise
        else:
            self._db_tx_depth -= 1
            if self._db_tx_depth == 0:
                self.conn.commit()

    def init_db(self) -> None:
        schema = """
CREATE TABLE IF NOT EXISTS artifacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_key TEXT NOT NULL UNIQUE,
    relative_path TEXT NOT NULL,
    full_path TEXT NOT NULL,
    inode INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,
    mtime_epoch INTEGER NOT NULL,
    status TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0,
    next_retry_epoch INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    discovered_at_epoch INTEGER NOT NULL,
    updated_at_epoch INTEGER NOT NULL,
    last_seen_epoch INTEGER NOT NULL,
    last_attempt_epoch INTEGER NOT NULL DEFAULT 0,
    first_shipped_epoch INTEGER NOT NULL DEFAULT 0,
    shipped_target TEXT NOT NULL DEFAULT '',
    pruned_at_epoch INTEGER NOT NULL DEFAULT 0,
    profile_at_ship TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_artifacts_status ON artifacts(status);
CREATE INDEX IF NOT EXISTS idx_artifacts_next_retry ON artifacts(next_retry_epoch);
CREATE INDEX IF NOT EXISTS idx_artifacts_first_shipped ON artifacts(first_shipped_epoch);
CREATE INDEX IF NOT EXISTS idx_artifacts_relative_path ON artifacts(relative_path);
CREATE TABLE IF NOT EXISTS artifact_targets (
    artifact_id INTEGER NOT NULL,
    target_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_epoch INTEGER NOT NULL DEFAULT 0,
    last_success_epoch INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (artifact_id, target_name),
    FOREIGN KEY (artifact_id) REFERENCES artifacts(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS attempt_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    artifact_id INTEGER NOT NULL,
    target_name TEXT NOT NULL,
    attempt_epoch INTEGER NOT NULL,
    action TEXT NOT NULL,
    exit_code INTEGER NOT NULL DEFAULT 0,
    message TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (artifact_id) REFERENCES artifacts(id) ON DELETE CASCADE
);
"""
        assert self.conn is not None
        self.conn.executescript(schema)
        self.conn.commit()

    def normalize_artifact_status_values(self) -> None:
        # Normalize legacy lowercase/mixed-case status values into canonical uppercase.
        self.db_exec("UPDATE artifacts SET status=UPPER(status) WHERE status<>UPPER(status);")

    def archive_legacy_state(self) -> None:
        if os.path.isfile(self.legacy_processed_file):
            archive_name = f"{self.legacy_processed_file}.legacy.{_epoch_now()}"
            try:
                os.replace(self.legacy_processed_file, archive_name)
                self.log("INFO", "Archived legacy processed.txt state")
            except Exception:
                pass

    def recover_inflight_after_unclean_shutdown(self) -> None:
        assert self.conn is not None
        self.conn.row_factory = sqlite3.Row
        rows = self.conn.execute(
            "SELECT id, relative_path, IFNULL(size_bytes, 0) AS size_bytes FROM artifacts WHERE status='IN_FLIGHT';"
        ).fetchall()
        if not rows:
            return

        now = _epoch_now()
        for row in rows:
            artifact_id = int(row["id"])
            relative_path = str(row["relative_path"] or "")
            size_bytes = str(row["size_bytes"] or 0)
            self.schedule_retry_or_dead_letter(
                artifact_id=artifact_id,
                relative_path=relative_path,
                size_bytes=size_bytes,
                current_epoch=now,
                final_error="recovered_after_unclean_shutdown",
            )
        self.log("WARN", f"Recovered {len(rows)} in-flight artifact(s) after unclean shutdown")

    def acquire_lock(self) -> None:
        os.makedirs(os.path.dirname(self.lock_file), exist_ok=True)
        self._lock_handle = open(self.lock_file, "w+", encoding="utf-8")
        try:
            fcntl.flock(self._lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.log("ERROR", "Another upload worker instance is running. Exiting.")
            raise SystemExit(1)
        self._lock_handle.seek(0)
        self._lock_handle.truncate(0)
        self._lock_handle.write(str(os.getpid()))
        self._lock_handle.flush()

    def release_lock(self) -> None:
        if self._lock_handle is None:
            return
        try:
            fcntl.flock(self._lock_handle.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        try:
            self._lock_handle.close()
        except Exception:
            pass
        self._lock_handle = None
        try:
            os.remove(self.lock_file)
        except OSError:
            pass

    @staticmethod
    def hash_text(value: str) -> str:
        return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()

    @staticmethod
    def _trim_seen_cache(cache: Dict[str, bool], max_entries: int) -> None:
        while len(cache) > max_entries:
            cache.pop(next(iter(cache)))

    def _sample_file_hash(self, file_path: str, size_bytes: int) -> str:
        sample_bytes = self.file_identity_sample_bytes
        try:
            with open(file_path, "rb") as handle:
                if size_bytes <= (sample_bytes * 2):
                    data = handle.read()
                else:
                    head = handle.read(sample_bytes)
                    handle.seek(max(size_bytes - sample_bytes, 0))
                    tail = handle.read(sample_bytes)
                    data = head + b"\x00" + tail
        except Exception:
            return "unreadable"
        return hashlib.sha256(data).hexdigest()

    def make_file_identity(self, file_path: str, relative_path: str) -> str:
        try:
            st = os.stat(file_path, follow_symlinks=False)
            size_bytes = int(st.st_size)
            mtime_ns = int(getattr(st, "st_mtime_ns", int(st.st_mtime * 1_000_000_000)))
            stat_fields = f"{st.st_dev}:{size_bytes}:{mtime_ns}"
        except OSError:
            size_bytes = 0
            stat_fields = "0:0:0"
        sample_hash = self._sample_file_hash(file_path, size_bytes)
        return f"{relative_path}|{stat_fields}|{sample_hash}"

    @staticmethod
    def make_file_detection_key(file_path: str, relative_path: str) -> str:
        try:
            inode = os.stat(file_path, follow_symlinks=False).st_ino
        except OSError:
            inode = 0
        return f"{relative_path}|{inode}"

    def log_file_detected_once(self, file_path: str, relative_path: str) -> None:
        key = self.make_file_detection_key(file_path, relative_path)
        if key in self.seen_file_detections:
            return
        size = self._file_size(file_path)
        self.log("INFO", f"Detected file candidate: {relative_path} (size={size} bytes)")
        self.seen_file_detections[key] = True
        self._trim_seen_cache(self.seen_file_detections, self.seen_cache_max_entries)

    @staticmethod
    def is_uploadable(basename: str) -> bool:
        if basename.startswith("."):
            return False
        if basename.startswith("~"):
            return False
        if basename.endswith(".MOVED"):
            return False
        return True

    @staticmethod
    def path_has_config_segment(relative_path: str) -> bool:
        lower = relative_path.replace("\\", "/").lower()
        return lower.startswith("config/") or "/config/" in lower

    @staticmethod
    def path_is_diagnostics_tree(relative_path: str) -> bool:
        lower = relative_path.replace("\\", "/").lower()
        return lower.startswith("diagnostics/") or "/diagnostics/" in lower

    @staticmethod
    def is_log_file(basename: str) -> bool:
        lower = basename.lower()
        return (
            lower.endswith(".log")
            or re.search(r"\.log\.\d+$", lower) is not None
            or lower.endswith(".out")
            or lower.endswith(".err")
        )

    @classmethod
    def is_runtime_state_file(cls, basename: str) -> bool:
        lower = basename.lower()
        return any(fnmatch.fnmatch(lower, pattern) for pattern in cls.RUNTIME_STATE_PATTERNS)

    def excluded_reason_for_path(self, relative_path: str, basename: str) -> str:
        if self.path_has_config_segment(relative_path):
            return "config_tree_runtime_excluded"
        if self.is_runtime_state_file(basename) and not self.path_is_diagnostics_tree(relative_path):
            return "runtime_state_excluded"
        if self.is_log_file(basename) and not self.path_is_diagnostics_tree(relative_path):
            return "log_outside_diagnostics_excluded"
        return ""

    def log_file_excluded_once(self, file_path: str, relative_path: str, reason: str) -> None:
        key = f"{self.make_file_detection_key(file_path, relative_path)}|{reason}"
        if key in self.seen_file_exclusions:
            return
        self.log("DEBUG", f"Skipping excluded file: {relative_path} reason={reason}")
        self.seen_file_exclusions[key] = True
        self._trim_seen_cache(self.seen_file_exclusions, self.seen_cache_max_entries)

    @classmethod
    def is_still_image(cls, basename: str) -> bool:
        lower = basename.lower()
        return any(fnmatch.fnmatch(lower, p) for p in cls.STILL_IMAGE_PATTERNS)

    @classmethod
    def is_video_file(cls, basename: str) -> bool:
        lower = basename.lower()
        return any(fnmatch.fnmatch(lower, p) for p in cls.VIDEO_PATTERNS)

    @staticmethod
    def is_slow_maturity_file(basename: str) -> bool:
        lower = basename.lower()
        return lower == "state.env" or lower.endswith(".log")

    def required_min_age_for_file(self, basename: str) -> int:
        if self.is_slow_maturity_file(basename):
            return self.min_file_age_state_and_log
        if self.is_still_image(basename):
            return self.min_file_age_still_image
        if self.is_video_file(basename):
            return self.min_file_age_video
        return self.min_file_age_default

    def stability_interval_for_file(self, basename: str) -> int:
        if self.is_still_image(basename):
            return self.file_stability_interval_still_image
        return self.file_stability_interval_default

    def is_file_stable(self, file_path: str, interval_seconds: int) -> bool:
        current_size = self._file_size(file_path)
        now = _epoch_now()
        prior = self.file_stability_observations.get(file_path)
        if prior is None:
            self.file_stability_observations[file_path] = (current_size, now)
            while len(self.file_stability_observations) > self.stability_cache_max_entries:
                self.file_stability_observations.pop(next(iter(self.file_stability_observations)))
            return False

        prior_size, first_seen_epoch = prior
        if current_size != prior_size:
            # Size changed: restart stability window from now.
            self.file_stability_observations[file_path] = (current_size, now)
            while len(self.file_stability_observations) > self.stability_cache_max_entries:
                self.file_stability_observations.pop(next(iter(self.file_stability_observations)))
            return False

        # Size unchanged: keep the original first-seen timestamp so stability can mature.
        self.file_stability_observations[file_path] = (current_size, first_seen_epoch)
        while len(self.file_stability_observations) > self.stability_cache_max_entries:
            self.file_stability_observations.pop(next(iter(self.file_stability_observations)))
        return (now - first_seen_epoch) >= max(interval_seconds, 0)

    def init_open_file_check_tool(self) -> None:
        if _cmd_exists("lsof"):
            self.open_file_check_tool = "lsof"
        elif _cmd_exists("fuser"):
            self.open_file_check_tool = "fuser"
        else:
            self.open_file_check_tool = "none"
            self.log("WARN", "No lsof/fuser found; open-file detection is disabled")

    def is_file_currently_open(self, file_path: str) -> bool:
        if self.open_file_check_tool == "lsof":
            result = subprocess.run(["lsof", "-t", "--", file_path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return result.returncode == 0
        if self.open_file_check_tool == "fuser":
            result = subprocess.run(["fuser", file_path], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return result.returncode == 0
        return False

    @staticmethod
    def profile_targets_for_attempt(profile: str) -> Tuple[str, ...]:
        if profile == "field":
            return ("local", "cloud")
        if profile == "cloud":
            return ("cloud",)
        if profile == "local":
            return ("local",)
        return ("local", "cloud")

    def build_remote_target(self, relative_path: str) -> str:
        if self.current_settings.remote_path:
            return f"{self.current_settings.remote_name}:{self.current_settings.remote_path}/{relative_path}"
        return f"{self.current_settings.remote_name}:{relative_path}"

    def calculate_backoff(self, attempt: int) -> int:
        delay = self.retry_base_delay_seconds * (2 ** max(attempt - 1, 0))
        return min(delay, self.retry_max_delay_seconds)

    def schedule_retry_or_dead_letter(
        self,
        artifact_id: int,
        relative_path: str,
        size_bytes: str,
        current_epoch: int,
        final_error: str,
    ) -> None:
        event_status = ""
        event_attempt = ""
        event_reason = ""

        with self.db_transaction():
            state_row = self.db_query_one("SELECT status, retry_count FROM artifacts WHERE id=?;", (artifact_id,))
            if state_row is None:
                return

            current_status = str(state_row["status"] or "").upper()
            if current_status in {"SHIPPED", "PRUNED", "DEAD_LETTER"}:
                return

            retry_count = int(state_row["retry_count"] or 0)
            new_retry_count = retry_count + 1
            if new_retry_count >= self.max_retries:
                self.db_exec(
                    "UPDATE artifacts SET status='DEAD_LETTER', retry_count=?, next_retry_epoch=0, last_error=?, updated_at_epoch=? WHERE id=?;",
                    (new_retry_count, final_error, current_epoch, artifact_id),
                )
                event_status = "dead_letter"
                event_attempt = str(new_retry_count)
                event_reason = final_error
            else:
                backoff = self.calculate_backoff(new_retry_count)
                retry_jitter_seconds = random.randint(0, self.retry_jitter_max_seconds)
                retry_delay_seconds = backoff + retry_jitter_seconds
                if self._is_rate_limited_error(final_error):
                    self.global_retry_pause_until_epoch = max(
                        self.global_retry_pause_until_epoch,
                        current_epoch + retry_delay_seconds,
                    )
                next_retry_epoch = current_epoch + retry_delay_seconds
                self.db_exec(
                    "UPDATE artifacts SET status='RETRY_WAIT', retry_count=?, next_retry_epoch=?, last_error=?, updated_at_epoch=? WHERE id=?;",
                    (new_retry_count, next_retry_epoch, final_error, current_epoch, artifact_id),
                )
                event_status = "retry"
                event_attempt = str(new_retry_count)
                event_reason = f"retry_backoff_{backoff}s"
                if retry_jitter_seconds > 0:
                    event_reason = f"{event_reason}_jitter_{retry_jitter_seconds}s"

        if event_status:
            self.emit_upload_event(event_status, relative_path, "", size_bytes, event_attempt, event_reason, "")

    def set_artifact_target_status(
        self,
        artifact_id: int,
        target_name: str,
        status: str,
        error_message: str,
        current_epoch: int,
        success_epoch: int,
    ) -> None:
        sql = """
INSERT INTO artifact_targets (artifact_id, target_name, status, attempt_count, last_attempt_epoch, last_success_epoch, last_error)
VALUES (?, ?, ?, 1, ?, ?, ?)
ON CONFLICT(artifact_id, target_name) DO UPDATE SET
    status=excluded.status,
    attempt_count=artifact_targets.attempt_count + 1,
    last_attempt_epoch=excluded.last_attempt_epoch,
    last_success_epoch=excluded.last_success_epoch,
    last_error=excluded.last_error;
"""
        self.db_exec(sql, (artifact_id, target_name, status, current_epoch, success_epoch, error_message))

    def insert_attempt_log(
        self,
        artifact_id: int,
        target_name: str,
        action: str,
        exit_code: int,
        message: str,
        current_epoch: int,
    ) -> None:
        sql = """
INSERT INTO attempt_log (artifact_id, target_name, attempt_epoch, action, exit_code, message)
VALUES (?, ?, ?, ?, ?, ?);
"""
        self.db_exec(sql, (artifact_id, target_name, current_epoch, action, exit_code, message))

    def register_artifact_if_needed(self, file_path: str, relative_path: str, file_key: str) -> Tuple[int, bool, bool]:
        st = os.stat(file_path, follow_symlinks=False)
        inode = int(st.st_ino)
        size_bytes = int(st.st_size)
        mtime_epoch = int(st.st_mtime)
        current_epoch = _epoch_now()

        existing = self.db_query_one("SELECT id FROM artifacts WHERE file_key=? LIMIT 1;", (file_key,))

        if existing is None:
            pending_same_path = self.db_query_one(
                """
SELECT id
FROM artifacts
WHERE relative_path=? AND status IN ('QUEUED', 'RETRY_WAIT')
ORDER BY id DESC
LIMIT 1;
""",
                (relative_path,),
            )
            if pending_same_path is not None:
                artifact_id = int(pending_same_path["id"])
                with self.db_transaction():
                    self.db_exec(
                        """
UPDATE artifacts
SET file_key=?,
    relative_path=?,
    full_path=?,
    inode=?,
    size_bytes=?,
    mtime_epoch=?,
    status='QUEUED',
    retry_count=0,
    next_retry_epoch=0,
    last_error='',
    discovered_at_epoch=?,
    last_seen_epoch=?,
    updated_at_epoch=?
WHERE id=?;
""",
                        (
                            file_key,
                            relative_path,
                            file_path,
                            inode,
                            size_bytes,
                            mtime_epoch,
                            current_epoch,
                            current_epoch,
                            current_epoch,
                            artifact_id,
                        ),
                    )
                    # If multiple pending rows exist for this same source path,
                    # keep the newest one and retire older duplicates.
                    self.db_exec(
                        """
UPDATE artifacts
SET status='DEAD_LETTER',
    next_retry_epoch=0,
    last_error='superseded_by_newer_file_state',
    updated_at_epoch=?
WHERE relative_path=?
  AND id<>?
  AND status IN ('QUEUED', 'RETRY_WAIT');
""",
                        (current_epoch, relative_path, artifact_id),
                    )
                    self.db_exec("DELETE FROM artifact_targets WHERE artifact_id=?;", (artifact_id,))
                return artifact_id, True, True

            self.db_exec(
                """
INSERT OR IGNORE INTO artifacts (
    file_key, relative_path, full_path, inode, size_bytes, mtime_epoch, status,
    retry_count, next_retry_epoch, last_error, discovered_at_epoch, updated_at_epoch, last_seen_epoch
) VALUES (?, ?, ?, ?, ?, ?, 'QUEUED', 0, ?, '', ?, ?, ?);
""",
                (
                    file_key,
                    relative_path,
                    file_path,
                    inode,
                    size_bytes,
                    mtime_epoch,
                    0,
                    current_epoch,
                    current_epoch,
                    current_epoch,
                ),
            )
            row = self.db_query_one("SELECT id FROM artifacts WHERE file_key=? LIMIT 1;", (file_key,))
            if row is None:
                raise RuntimeError(f"unable to register artifact for {relative_path}")
            return int(row["id"]), True, False

        artifact_id = int(existing["id"])
        self.db_exec(
            """
UPDATE artifacts
SET file_key=?,
    relative_path=?,
    full_path=?,
    inode=?,
    size_bytes=?,
    mtime_epoch=?,
    last_seen_epoch=?,
    updated_at_epoch=?
WHERE id=?;
""",
            (file_key, relative_path, file_path, inode, size_bytes, mtime_epoch, current_epoch, current_epoch, artifact_id),
        )
        return artifact_id, False, False

    def can_attempt_artifact_now(self, artifact_id: int, current_epoch: int) -> bool:
        row = self.db_query_one("SELECT status, next_retry_epoch FROM artifacts WHERE id=?;", (artifact_id,))
        if row is None:
            return False
        status = str(row["status"] or "").upper()
        if status in {"SHIPPED", "PRUNED", "DEAD_LETTER", "IN_FLIGHT"}:
            return False
        next_retry = int(row["next_retry_epoch"] or 0)
        if status in {"RETRY_WAIT", "QUEUED"} and next_retry > current_epoch:
            return False
        return True

    def _run_command_with_log(self, args: Sequence[str], timeout_seconds: int) -> Tuple[int, bool, str]:
        try:
            result = subprocess.run(
                list(args),
                check=False,
                capture_output=True,
                text=True,
                timeout=max(timeout_seconds, 1),
            )
        except subprocess.TimeoutExpired as exc:
            stdout_text = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout.decode("utf-8", errors="replace") if exc.stdout else "")
            stderr_text = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr.decode("utf-8", errors="replace") if exc.stderr else "")
            merged = "\n".join(part for part in (stdout_text, stderr_text) if part)
            for line in merged.splitlines():
                self.log_raw(line)
            return 124, True, merged
        except Exception as exc:
            return 1, False, str(exc)

        stdout_text = result.stdout or ""
        stderr_text = result.stderr or ""
        if stdout_text:
            for line in stdout_text.splitlines():
                self.log_raw(line)
        if stderr_text:
            for line in stderr_text.splitlines():
                self.log_raw(line)
        merged = "\n".join(part for part in (stdout_text, stderr_text) if part)
        return int(result.returncode or 0), False, merged

    @staticmethod
    def _looks_like_rclone_existing_destination(output_text: str) -> bool:
        lowered = output_text.lower()
        hints = (
            "immutable",
            "already exists",
            "source and destination exist",
            "destination exists",
            "duplicate object found",
            "cannot overwrite existing",
        )
        return any(hint in lowered for hint in hints)

    @staticmethod
    def _looks_like_rate_limited(output_text: str) -> bool:
        lowered = output_text.lower()
        hints = (
            "rate limit",
            "rate-limit",
            "too many requests",
            "http error 429",
            "status code 429",
            "quota exceeded",
            "userratelimitexceeded",
            "throttl",
            "slow down",
            "retry later",
        )
        return any(hint in lowered for hint in hints)

    @staticmethod
    def _is_rate_limited_error(reason: str) -> bool:
        return reason in {
            "rclone_rate_limited",
            "remote_rate_limited",
        }

    @staticmethod
    def _file_size(file_path: str) -> int:
        try:
            return int(os.path.getsize(file_path))
        except OSError:
            return 0

    def ship_to_cloud_target(self, file_path: str, relative_path: str) -> Tuple[bool, str, str, str, int, bool]:
        if not self.current_settings.remote_name:
            return False, "cloud_remote_unset", "", "", self._file_size(file_path), False
        if not _cmd_exists("rclone"):
            return False, "rclone_not_installed", "", "", self._file_size(file_path), False

        remote_target = self.build_remote_target(relative_path)
        file_size = self._file_size(file_path)
        destination_label = f"{self.current_settings.remote_name}:{self.current_settings.remote_path}"
        if not self.current_settings.remote_path:
            destination_label = f"{self.current_settings.remote_name}:"

        def cloud_exists_and_matches_size() -> Tuple[bool, str]:
            size_rc, _timed_out, output_text = self._run_command_with_log(
                [
                    "rclone",
                    "lsjson",
                    "--stat",
                    "--files-only",
                    "--no-mimetype",
                    "--no-modtime",
                    "--contimeout",
                    f"{self.rclone_connect_timeout_seconds}s",
                    "--timeout",
                    f"{self.rclone_io_timeout_seconds}s",
                    remote_target,
                ],
                timeout_seconds=self.rclone_lsf_timeout_seconds,
            )
            if size_rc != 0:
                if self._looks_like_rate_limited(output_text):
                    return False, "rclone_rate_limited"
                return False, "rclone_lsjson_failed"
            try:
                parsed = json.loads(output_text or "{}")
            except Exception:
                return False, "rclone_lsjson_parse_failed"
            item = parsed[0] if isinstance(parsed, list) and parsed else parsed
            if not isinstance(item, dict) or item.get("IsDir"):
                return False, "rclone_lsjson_not_file"
            remote_size = item.get("Size")
            if not isinstance(remote_size, int):
                return False, "rclone_lsjson_no_size"
            if remote_size != file_size:
                return False, "remote_destination_conflict"
            return True, ""

        rc, timed_out, output_text = self._run_command_with_log(
            [
                "rclone",
                "copyto",
                file_path,
                remote_target,
                "--immutable",
                "--stats=0",
                "--contimeout",
                f"{self.rclone_connect_timeout_seconds}s",
                "--timeout",
                f"{self.rclone_io_timeout_seconds}s",
                "--retries",
                "1",
                "--low-level-retries",
                "1",
            ],
            timeout_seconds=self.rclone_copy_timeout_seconds,
        )
        if timed_out:
            return False, "rclone_timeout", "", "", file_size, False
        if rc != 0:
            if self._looks_like_rclone_existing_destination(output_text):
                exists_ok, exists_reason = cloud_exists_and_matches_size()
                if exists_ok:
                    return True, "target_cloud_exists", destination_label, remote_target, file_size, True
                return False, exists_reason, "", "", file_size, False
            if self._looks_like_rate_limited(output_text):
                return False, "rclone_rate_limited", "", "", file_size, False
            return False, "rclone_copy_failed", "", "", file_size, False

        return True, "target_cloud", destination_label, remote_target, file_size, False

    def ship_to_local_target(self, file_path: str, relative_path: str) -> Tuple[bool, str, str, str, int, bool]:
        local_target = self.current_settings.local_target
        if not local_target:
            return False, "local_target_unset", "", "", self._file_size(file_path), False
        if self.is_path_within_upload_dir(local_target):
            return False, "local_target_inside_upload_dir", "", "", self._file_size(file_path), False
        if not os.path.isdir(local_target):
            return False, "local_target_missing", "", "", self._file_size(file_path), False
        if not os.access(local_target, os.W_OK):
            return False, "local_target_not_writable", "", "", self._file_size(file_path), False

        target_path = os.path.join(local_target, relative_path)
        target_dir = os.path.dirname(target_path)
        try:
            os.makedirs(target_dir, exist_ok=True)
        except Exception:
            return False, "local_target_mkdir_failed", "", "", self._file_size(file_path), False
        source_size = self._file_size(file_path)

        if os.path.isfile(target_path):
            target_size = self._file_size(target_path)
            if source_size == target_size:
                source_hash = self._sample_file_hash(file_path, source_size)
                target_hash = self._sample_file_hash(target_path, target_size)
                if source_hash == target_hash and source_hash != "unreadable":
                    destination_label = f"local:{local_target}"
                    return True, "target_local_exists", destination_label, target_path, source_size, True
                return False, "local_destination_conflict", "", "", source_size, False
            return False, "local_destination_conflict", "", "", source_size, False

        tmp_path = f"{target_path}.tmp.{os.getpid()}.{random.randint(1000, 999999)}"
        try:
            shutil.copy2(file_path, tmp_path)
        except Exception:
            try:
                os.remove(tmp_path)
            except OSError:
                pass
            return False, "local_copy_failed", "", "", source_size, False
        try:
            os.replace(tmp_path, target_path)
        except Exception:
            try:
                os.remove(tmp_path)
            except OSError:
                pass
            return False, "local_move_failed", "", "", source_size, False

        destination_label = f"local:{local_target}"
        return True, "target_local", destination_label, target_path, source_size, False

    def attempt_ship_artifact(
        self,
        artifact_id: int,
        file_path: str,
        relative_path: str,
        current_epoch: int,
    ) -> bool:
        size_bytes = str(self._file_size(file_path))
        self.db_exec(
            "UPDATE artifacts SET status='IN_FLIGHT', updated_at_epoch=?, last_attempt_epoch=? WHERE id=?;",
            (current_epoch, current_epoch, artifact_id),
        )
        self.emit_upload_event("in_flight", relative_path, "", size_bytes, "", "attempt_started", "")

        final_error = "all_targets_failed"
        for target in self.profile_targets_for_attempt(self.current_settings.profile):
            if target == "local":
                ok, reason, dest_label, dest_path, file_size, already_present = self.ship_to_local_target(file_path, relative_path)
                if ok:
                    with self.db_transaction():
                        self.set_artifact_target_status(artifact_id, "local", "SUCCESS", "", current_epoch, current_epoch)
                        self.insert_attempt_log(artifact_id, "local", "success", 0, dest_path, current_epoch)
                        self.db_exec(
                            """
UPDATE artifacts
SET status='SHIPPED',
    retry_count=0,
    next_retry_epoch=0,
    last_error='',
    updated_at_epoch=?,
    first_shipped_epoch=CASE WHEN first_shipped_epoch=0 THEN ? ELSE first_shipped_epoch END,
    shipped_target='local',
    profile_at_ship=?
WHERE id=?;
""",
                            (current_epoch, current_epoch, self.current_settings.profile, artifact_id),
                        )
                    self.emit_upload_event("shipped", relative_path, dest_path, str(file_size), "", reason, "")
                    if already_present:
                        self.log("INFO", f"Local destination already had file; treated as shipped: {relative_path}")
                    return True

                with self.db_transaction():
                    self.set_artifact_target_status(artifact_id, "local", "FAILED", reason, current_epoch, 0)
                    self.insert_attempt_log(artifact_id, "local", "failed", 1, reason, current_epoch)
                self.emit_upload_event("failed", relative_path, f"local:{self.current_settings.local_target}", size_bytes, "", reason, "1")
                final_error = reason
                continue

            ok, reason, dest_label, dest_path, file_size, already_present = self.ship_to_cloud_target(file_path, relative_path)
            if ok:
                with self.db_transaction():
                    self.set_artifact_target_status(artifact_id, "cloud", "SUCCESS", "", current_epoch, current_epoch)
                    self.insert_attempt_log(artifact_id, "cloud", "success", 0, dest_path, current_epoch)
                    self.db_exec(
                        """
UPDATE artifacts
SET status='SHIPPED',
    retry_count=0,
    next_retry_epoch=0,
    last_error='',
    updated_at_epoch=?,
    first_shipped_epoch=CASE WHEN first_shipped_epoch=0 THEN ? ELSE first_shipped_epoch END,
    shipped_target='cloud',
    profile_at_ship=?
WHERE id=?;
""",
                        (current_epoch, current_epoch, self.current_settings.profile, artifact_id),
                    )
                self.emit_upload_event("shipped", relative_path, dest_path, str(file_size), "", reason, "")
                if already_present:
                    self.log("INFO", f"Cloud destination already had file; treated as shipped: {relative_path}")
                return True

            with self.db_transaction():
                self.set_artifact_target_status(artifact_id, "cloud", "FAILED", reason, current_epoch, 0)
                self.insert_attempt_log(artifact_id, "cloud", "failed", 1, reason, current_epoch)
            self.emit_upload_event(
                "failed",
                relative_path,
                f"{self.current_settings.remote_name}:{self.current_settings.remote_path}",
                size_bytes,
                "",
                reason,
                "1",
            )
            final_error = reason

        self.schedule_retry_or_dead_letter(
            artifact_id=artifact_id,
            relative_path=relative_path,
            size_bytes=size_bytes,
            current_epoch=current_epoch,
            final_error=final_error,
        )
        return False

    def is_path_within_upload_dir(self, path_value: str) -> bool:
        file_real = os.path.realpath(path_value)
        upload_real = os.path.realpath(self.upload_dir)
        return file_real == upload_real or file_real.startswith(upload_real + os.sep)

    def is_path_within_local_target(self, path_value: str) -> bool:
        local_target = self.current_settings.local_target
        if not local_target:
            return False
        local_real = os.path.realpath(local_target)
        path_real = os.path.realpath(path_value)
        return path_real == local_real or path_real.startswith(local_real + os.sep)

    def spool_usage_percent(self) -> int:
        try:
            usage = shutil.disk_usage(self.upload_dir)
            if usage.total <= 0:
                return 0
            return int((usage.used * 100) / usage.total)
        except Exception:
            return 0

    def due_attempt_limit_for_current_pressure(self) -> int:
        min_limit = max(1, self.min_due_attempts_per_loop)
        max_limit = max(1, self.max_due_attempts_per_loop)
        if min_limit >= max_limit:
            return max_limit

        usage_percent = self.spool_usage_percent()
        low_mark = max(0, min(99, int(self.current_settings.low_watermark)))
        high_mark = max(low_mark + 1, min(100, int(self.current_settings.high_watermark)))

        if usage_percent <= low_mark:
            return min_limit
        if usage_percent >= high_mark:
            return max_limit

        pressure_window = max(high_mark - low_mark, 1)
        pressure_fraction = (usage_percent - low_mark) / pressure_window
        scaled = min_limit + int(round((max_limit - min_limit) * pressure_fraction))
        return max(min_limit, min(max_limit, scaled))

    def request_protect_stop_if_needed(self, current_epoch: int) -> None:
        last_epoch = 0
        if os.path.isfile(self.protect_stop_stamp_file):
            try:
                with open(self.protect_stop_stamp_file, "r", encoding="utf-8", errors="replace") as handle:
                    last_epoch = int((handle.readline() or "0").strip() or "0")
            except Exception:
                last_epoch = 0

        if (current_epoch - last_epoch) < self.protect_stop_cooldown_seconds:
            return

        self.emit_upload_event("protect_stop", "", "", "unknown", "", "disk_threshold_reached", "")
        try:
            stop_args = _shlex.split(self.upload_stop_command)
        except ValueError:
            stop_args = []
        try:
            if not stop_args:
                rc = 1
            else:
                rc = subprocess.run(stop_args, shell=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        except Exception:
            rc = 1

        if rc == 0:
            self.log("WARN", "Protect retention requested recording stop")
        else:
            self.log("WARN", f"Protect retention could not execute stop command: {self.upload_stop_command}")
        try:
            with open(self.protect_stop_stamp_file, "w", encoding="utf-8") as handle:
                handle.write(str(current_epoch) + "\n")
        except Exception:
            pass

    def prune_oldest_shipped_until_low_watermark(self) -> None:
        current_usage = self.spool_usage_percent()
        while current_usage > self.current_settings.low_watermark:
            row = self.db_query_one(
                "SELECT id, full_path, relative_path, IFNULL(size_bytes,0) AS size_bytes FROM artifacts WHERE status='SHIPPED' ORDER BY first_shipped_epoch ASC LIMIT 1;"
            )
            if row is None:
                self.log("WARN", "Rolling retention reached watermark, but no shipped files remain to prune")
                break

            artifact_id = int(row["id"])
            full_path = str(row["full_path"] or "")
            relative_path = str(row["relative_path"] or "")
            size_bytes = str(row["size_bytes"] or 0)

            now = _epoch_now()
            if not full_path:
                self.db_exec(
                    "UPDATE artifacts SET status='PRUNED', pruned_at_epoch=?, updated_at_epoch=?, last_error='empty_full_path' WHERE id=?;",
                    (now, now, artifact_id),
                )
                continue

            if not self.is_path_within_upload_dir(full_path):
                self.log("WARN", f"Skipping unsafe prune candidate outside upload dir: {full_path}")
                self.db_exec(
                    "UPDATE artifacts SET status='DEAD_LETTER', last_error='unsafe_prune_path', updated_at_epoch=? WHERE id=?;",
                    (now, artifact_id),
                )
                continue

            if os.path.isfile(full_path):
                try:
                    os.remove(full_path)
                except OSError:
                    pass

            self.db_exec(
                "UPDATE artifacts SET status='PRUNED', pruned_at_epoch=?, updated_at_epoch=?, last_error='' WHERE id=?;",
                (now, now, artifact_id),
            )
            self.emit_upload_event("pruned", relative_path, "", size_bytes, "", "rolling_retention", "")
            current_usage = self.spool_usage_percent()

    def enforce_retention_policy(self) -> None:
        usage = self.spool_usage_percent()
        current_epoch = _epoch_now()

        if self.current_settings.retention == "protect":
            if usage >= self.current_settings.high_watermark:
                self.request_protect_stop_if_needed(current_epoch)
            return

        if self.current_settings.retention == "rolling" and usage >= self.current_settings.high_watermark:
            self.prune_oldest_shipped_until_low_watermark()

    def prune_attempt_log_if_needed(self, current_epoch: int) -> None:
        if self.attempt_log_max_rows <= 0:
            return
        if self.last_attempt_log_prune_epoch > 0:
            elapsed = current_epoch - self.last_attempt_log_prune_epoch
            if elapsed < self.attempt_log_prune_interval_seconds:
                return
        self.last_attempt_log_prune_epoch = current_epoch

        count_row = self.db_query_one("SELECT COUNT(*) AS row_count FROM attempt_log;")
        if count_row is None:
            return
        row_count = int(count_row["row_count"] or 0)
        if row_count <= self.attempt_log_max_rows:
            return

        delete_count = row_count - self.attempt_log_max_rows
        with self.db_transaction():
            self.db_exec(
                """
DELETE FROM attempt_log
WHERE id IN (
    SELECT id
    FROM attempt_log
    ORDER BY id ASC
    LIMIT ?
);
""",
                (delete_count,),
            )
        self.log("DEBUG", f"Pruned {delete_count} row(s) from attempt_log")

    def _seed_scan_queue_if_needed(self) -> None:
        if self.scan_dir_queue or self.scan_file_queue:
            return
        if os.path.isdir(self.upload_dir):
            self.scan_dir_queue.append(self.upload_dir)

    def _scan_next_file_batch(self) -> List[str]:
        if not os.path.isdir(self.upload_dir):
            self.scan_dir_queue.clear()
            self.scan_file_queue.clear()
            return []

        self._seed_scan_queue_if_needed()

        while self.scan_dir_queue and len(self.scan_file_queue) < self.max_scan_files_per_loop:
            root = self.scan_dir_queue.popleft()
            try:
                with os.scandir(root) as entries:
                    child_dirs: List[str] = []
                    child_files: List[str] = []
                    for entry in entries:
                        try:
                            if entry.is_dir(follow_symlinks=False):
                                child_dirs.append(entry.path)
                            elif entry.is_file(follow_symlinks=False):
                                child_files.append(entry.path)
                        except OSError:
                            continue
            except OSError:
                continue

            child_dirs.sort()
            child_files.sort()
            self.scan_dir_queue.extend(child_dirs)
            self.scan_file_queue.extend(child_files)

        batch: List[str] = []
        while self.scan_file_queue and len(batch) < self.max_scan_files_per_loop:
            batch.append(self.scan_file_queue.popleft())
        return batch

    def process_scan_candidate(self, file_path: str) -> None:
        if not os.path.isfile(file_path):
            return

        relative_path = self._artifact_relative_path(file_path)
        basename = os.path.basename(file_path)

        if not self.is_uploadable(basename):
            return

        if self.is_path_within_local_target(file_path):
            self.log_file_excluded_once(file_path, relative_path, "local_target_tree_excluded")
            return

        reason = self.excluded_reason_for_path(relative_path, basename)
        if reason:
            self.log_file_excluded_once(file_path, relative_path, reason)
            return

        self.log_file_detected_once(file_path, relative_path)

        try:
            st = os.stat(file_path, follow_symlinks=False)
            mtime = int(st.st_mtime)
        except OSError:
            return
        now = _epoch_now()
        age = now - mtime
        required_min_age = self.required_min_age_for_file(basename)
        if age < required_min_age:
            return

        if self.is_file_currently_open(file_path):
            return

        stability_interval = self.stability_interval_for_file(basename)
        if not self.is_file_stable(file_path, stability_interval):
            return

        file_identity = self.make_file_identity(file_path, relative_path)
        file_key = self.hash_text(file_identity)
        artifact_id, should_emit_queue_event, was_rearmed = self.register_artifact_if_needed(
            file_path, relative_path, file_key
        )
        if not should_emit_queue_event:
            return

        size = self._file_size(file_path)
        if was_rearmed:
            self.log("INFO", f"Re-queued artifact after write activity: {relative_path} (id={artifact_id})")
            queue_reason = "artifact_requeued_after_write_activity"
        else:
            self.log("INFO", f"Queued artifact: {relative_path} (id={artifact_id})")
            queue_reason = "artifact_registered"
        self.emit_upload_event(
            "queued",
            relative_path,
            "",
            str(size),
            "",
            queue_reason,
            "",
        )

    def get_due_artifacts(self, current_epoch: int, limit: int) -> List[sqlite3.Row]:
        assert self.conn is not None
        self.conn.row_factory = sqlite3.Row
        effective_limit = max(1, int(limit))
        cursor = self.conn.execute(
            """
SELECT id, full_path, relative_path, size_bytes, status, next_retry_epoch
FROM artifacts
WHERE (status='QUEUED' AND next_retry_epoch <= ?) OR (status='RETRY_WAIT' AND next_retry_epoch <= ?)
ORDER BY
    mtime_epoch ASC,
    discovered_at_epoch ASC,
    id ASC
LIMIT ?;
""",
            (current_epoch, current_epoch, effective_limit),
        )
        return list(cursor.fetchall())

    def is_artifact_ready_for_upload(self, file_path: str, relative_path: str, current_epoch: int) -> bool:
        if not os.path.isfile(file_path):
            return False

        basename = os.path.basename(file_path)
        if not self.is_uploadable(basename):
            return False
        if self.is_path_within_local_target(file_path):
            return False
        if self.excluded_reason_for_path(relative_path, basename):
            return False

        try:
            st = os.stat(file_path, follow_symlinks=False)
            mtime = int(st.st_mtime)
        except OSError:
            return False

        age = current_epoch - mtime
        if age < self.required_min_age_for_file(basename):
            return False
        if self.is_file_currently_open(file_path):
            return False
        stability_interval = self.stability_interval_for_file(basename)
        if not self.is_file_stable(file_path, stability_interval):
            return False
        return True

    def resolve_due_artifact_path(self, full_path: str, relative_path: str) -> str:
        if full_path and os.path.isfile(full_path):
            return full_path
        if not relative_path:
            return ""
        relative_os = relative_path.replace("/", os.sep)
        candidate_path = os.path.normpath(os.path.join(self.upload_dir, relative_os))
        if not self.is_path_within_upload_dir(candidate_path):
            return ""
        if os.path.isfile(candidate_path):
            return candidate_path
        return ""

    def process_due_artifacts(self, current_epoch: int) -> None:
        due_attempt_limit = self.due_attempt_limit_for_current_pressure()
        if self.global_retry_pause_until_epoch > current_epoch:
            remaining = self.global_retry_pause_until_epoch - current_epoch
            if current_epoch - self.last_global_retry_pause_notice_epoch >= 60:
                self.log("WARN", f"Global retry pause active for {remaining}s due to rate limiting")
                self.last_global_retry_pause_notice_epoch = current_epoch
            return

        attempts = 0
        while self.running:
            if self.global_retry_pause_until_epoch > current_epoch:
                remaining = self.global_retry_pause_until_epoch - current_epoch
                if current_epoch - self.last_global_retry_pause_notice_epoch >= 60:
                    self.log("WARN", f"Global retry pause active for {remaining}s due to rate limiting")
                    self.last_global_retry_pause_notice_epoch = current_epoch
                return

            rows = self.get_due_artifacts(current_epoch, due_attempt_limit)
            if not rows:
                return

            made_progress = False
            for row in rows:
                artifact_id = int(row["id"])
                full_path = str(row["full_path"] or "")
                relative_path = str(row["relative_path"] or "")
                size_bytes = str(row["size_bytes"] or 0)
                status = str(row["status"] or "").upper()
                next_retry_epoch = int(row["next_retry_epoch"] or 0)

                file_path = self.resolve_due_artifact_path(full_path, relative_path)
                if not file_path:
                    self.schedule_retry_or_dead_letter(
                        artifact_id=artifact_id,
                        relative_path=relative_path,
                        size_bytes=size_bytes,
                        current_epoch=current_epoch,
                        final_error="source_file_missing",
                    )
                    made_progress = True
                    continue

                if not relative_path:
                    relative_path = self._artifact_relative_path(file_path)
                    self.db_exec(
                        "UPDATE artifacts SET relative_path=?, updated_at_epoch=? WHERE id=?;",
                        (relative_path, current_epoch, artifact_id),
                    )
                if file_path != full_path:
                    self.db_exec(
                        "UPDATE artifacts SET full_path=?, updated_at_epoch=? WHERE id=?;",
                        (file_path, current_epoch, artifact_id),
                    )

                if not self.can_attempt_artifact_now(artifact_id, current_epoch):
                    continue
                if not self.is_artifact_ready_for_upload(file_path, relative_path, current_epoch):
                    # Oldest candidate may still be writing. Keep searching for the oldest ready candidate.
                    continue

                if status == "QUEUED" and next_retry_epoch <= 0:
                    jitter_seconds = random.randint(0, self.initial_upload_jitter_max_seconds)
                    if jitter_seconds > 0:
                        next_attempt_epoch = current_epoch + jitter_seconds
                        self.db_exec(
                            "UPDATE artifacts SET next_retry_epoch=?, updated_at_epoch=? WHERE id=? AND status='QUEUED';",
                            (next_attempt_epoch, current_epoch, artifact_id),
                        )
                        self.emit_upload_event(
                            "queued",
                            relative_path,
                            "",
                            size_bytes,
                            "",
                            f"ready_jitter_{jitter_seconds}s",
                            "",
                        )
                        made_progress = True
                        continue

                try:
                    self.attempt_ship_artifact(artifact_id, file_path, relative_path, current_epoch)
                except Exception as exc:
                    self.log("ERROR", f"Unhandled upload attempt exception for {relative_path}: {exc}")
                    self.schedule_retry_or_dead_letter(
                        artifact_id=artifact_id,
                        relative_path=relative_path,
                        size_bytes=str(self._file_size(file_path)),
                        current_epoch=current_epoch,
                        final_error=f"unexpected_exception_{type(exc).__name__}",
                    )
                made_progress = True
                attempts += 1
                break

            if attempts >= due_attempt_limit:
                return
            if not made_progress:
                return
            current_epoch = _epoch_now()

    def _artifact_relative_path(self, file_path: str) -> str:
        try:
            rel = os.path.relpath(file_path, self.upload_dir)
        except ValueError:
            rel = os.path.basename(file_path)
        if rel.startswith(".."):
            rel = os.path.basename(file_path)
        return rel.replace("\\", "/")

    def _handle_signal(self, _signum: int, _frame: object) -> None:
        self.running = False

    def setup(self) -> None:
        os.makedirs(self.state_dir, exist_ok=True)
        os.makedirs(self.log_dir, exist_ok=True)
        os.makedirs(self.runtime_dir, exist_ok=True)
        os.makedirs(self.upload_dir, exist_ok=True)
        os.makedirs(self.upload_config_dir, exist_ok=True)

        self.acquire_lock()
        self.db_open()
        self.init_db()
        self.normalize_artifact_status_values()
        self.recover_inflight_after_unclean_shutdown()
        self.archive_legacy_state()
        self.refresh_runtime_settings()
        self.init_open_file_check_tool()

        self.log("INFO", "Upload worker starting")
        self.log("INFO", f"Spool dir: {self.upload_dir}")
        self.log("INFO", f"Config dir: {self.upload_config_dir}")
        self.log("INFO", f"Queue DB: {self.db_file}")
        self.log(
            "INFO",
            f"Upload profile={self.current_settings.profile} retention={self.current_settings.retention}",
        )
        self.log(
            "INFO",
            (
                "Rclone timeouts: "
                f"stat={self.rclone_lsf_timeout_seconds}s "
                f"copy={self.rclone_copy_timeout_seconds}s "
                f"connect={self.rclone_connect_timeout_seconds}s "
                f"io={self.rclone_io_timeout_seconds}s"
            ),
        )
        self.log(
            "INFO",
            f"Initial upload jitter: 0-{self.initial_upload_jitter_max_seconds}s before first attempt",
        )
        self.log(
            "INFO",
            f"Retry jitter: 0-{self.retry_jitter_max_seconds}s added to retry backoff delays",
        )
        self.log(
            "INFO",
            (
                "Due attempt burst scaling by storage pressure: "
                f"min={self.min_due_attempts_per_loop} "
                f"max={self.max_due_attempts_per_loop} "
                f"between low={self.current_settings.low_watermark}% and high={self.current_settings.high_watermark}%"
            ),
        )

    def run(self) -> int:
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)

        try:
            self.setup()
        except SystemExit as exc:
            return int(exc.code)
        except Exception as exc:
            self.log("ERROR", f"Failed to initialize upload worker: {exc}")
            return 1

        try:
            while self.running:
                try:
                    self.refresh_runtime_settings()
                    self.enforce_retention_policy()
                except Exception as exc:
                    self.log("ERROR", f"Runtime settings/retention error: {exc}")

                loop_epoch = _epoch_now()
                try:
                    self.prune_attempt_log_if_needed(loop_epoch)
                except Exception as exc:
                    self.log("ERROR", f"attempt_log pruning error: {exc}")

                if not os.path.isdir(self.upload_dir):
                    self.scan_dir_queue.clear()
                    self.scan_file_queue.clear()
                    time.sleep(max(self.scan_interval, 1))
                    continue

                try:
                    files = self._scan_next_file_batch()
                except Exception as exc:
                    self.log("ERROR", f"Failed to scan upload directory: {exc}")
                    files = []

                for file_path in files:
                    if not self.running:
                        break
                    try:
                        self.process_scan_candidate(file_path)
                    except Exception as exc:
                        self.log("ERROR", f"Failed to process scanned candidate {file_path}: {exc}")

                if self.current_settings.paused:
                    if not self.pause_notice_emitted:
                        self.emit_upload_event("paused", "", "", "unknown", "", "upload_paused", "")
                        self.pause_notice_emitted = True
                else:
                    self.pause_notice_emitted = False
                    attempt_epoch = _epoch_now()
                    try:
                        self.process_due_artifacts(attempt_epoch)
                    except Exception as exc:
                        self.log("ERROR", f"Due artifact attempt cycle error: {exc}")

                time.sleep(max(self.scan_interval, 1))
        finally:
            if self.conn is not None:
                try:
                    self.conn.close()
                except Exception:
                    pass
            self.release_lock()
        return 0


def shlex_quote(value: str) -> str:
    if not value:
        return "''"
    # Keep compatibility with shell-ish logs.
    return "'" + value.replace("'", "'\"'\"'") + "'"


def main() -> int:
    worker = UploadWorker()
    return worker.run()


if __name__ == "__main__":
    sys.exit(main())
