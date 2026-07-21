#!/usr/bin/env python3
"""Log Adafruit SHT4x Trinkey readings for one AntSciHub capture session.

The factory Trinkey firmware exposes a USB CDC ACM serial port which emits
``temperature_c,relative_humidity_percent`` lines at 115200 baud.  This
process deliberately has no third-party dependency: it uses Linux's standard
serial APIs, so it can run on an installed Pi without adding pyserial.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import fcntl
import glob
import os
import select
import signal
import struct
import sys
import termios
import time
from pathlib import Path
from typing import Iterator, Optional


DEFAULT_INTERVAL_SECONDS = 60
BAUD_RATE = termios.B115200
STOP_REQUESTED = False


def log(message: str) -> None:
    print(f"[sht45] {message}", file=sys.stderr, flush=True)


def timestamp_iso_local() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def request_stop(_signum: int, _frame: object) -> None:
    global STOP_REQUESTED
    STOP_REQUESTED = True


def parse_reading(line: str) -> Optional[tuple[float, float]]:
    parts = [part.strip() for part in line.split(",")]
    if len(parts) != 2:
        return None
    try:
        temperature_c = float(parts[0])
        relative_humidity_percent = float(parts[1])
    except ValueError:
        return None
    if not (-40.0 <= temperature_c <= 125.0 and 0.0 <= relative_humidity_percent <= 100.0):
        return None
    return temperature_c, relative_humidity_percent


def serial_port_candidates(explicit_port: str) -> Iterator[Path]:
    if explicit_port:
        yield Path(explicit_port)
        return

    seen: set[Path] = set()
    for pattern in ("/dev/serial/by-id/*", "/dev/ttyACM*"):
        for raw_path in sorted(glob.glob(pattern)):
            path = Path(raw_path)
            name = path.name.lower()
            if pattern.endswith("by-id/*") and not any(token in name for token in ("adafruit", "sht4", "trinkey")):
                continue
            resolved = path.resolve()
            if resolved not in seen:
                seen.add(resolved)
                yield resolved


def open_serial_port(path: Path) -> int:
    fd = os.open(str(path), os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    settings = termios.tcgetattr(fd)
    settings[0] = termios.IGNPAR
    settings[1] = 0
    settings[2] = termios.CREAD | termios.CLOCAL | termios.CS8
    settings[3] = 0
    settings[4] = BAUD_RATE
    settings[5] = BAUD_RATE
    settings[6][termios.VMIN] = 0
    settings[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, settings)
    # CircuitPython starts its serial output only after a host opens the CDC
    # port.  Match pyserial's normal DTR/RTS behaviour without needing it.
    modem_bits = termios.TIOCM_DTR | termios.TIOCM_RTS
    fcntl.ioctl(fd, termios.TIOCMBIS, struct.pack("I", modem_bits))
    return fd


def readings_from_port(path: Path) -> Iterator[tuple[float, float]]:
    fd = open_serial_port(path)
    buffer = b""
    try:
        while not STOP_REQUESTED:
            readable, _, _ = select.select([fd], [], [], 1.0)
            if not readable:
                continue
            chunk = os.read(fd, 1024)
            if not chunk:
                raise OSError("serial device disconnected")
            buffer += chunk
            while b"\n" in buffer:
                raw_line, buffer = buffer.split(b"\n", 1)
                reading = parse_reading(raw_line.decode("utf-8", errors="replace").strip())
                if reading is not None:
                    yield reading
    finally:
        os.close(fd)


def append_reading(writer: csv.writer, output_file: object, temperature_c: float, humidity_percent: float) -> None:
    writer.writerow((timestamp_iso_local(), f"{temperature_c:.3f}", f"{humidity_percent:.3f}"))
    output_file.flush()
    os.fsync(output_file.fileno())


def run(output_path: Path, interval_seconds: int, explicit_port: str) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    next_sample_monotonic = 0.0
    logged_missing_port = False
    write_header = not output_path.is_file() or output_path.stat().st_size == 0

    with output_path.open("a", newline="", encoding="utf-8") as output_file:
        writer = csv.writer(output_file)
        if write_header:
            writer.writerow(("timestamp", "temperature_c", "relative_humidity_percent"))
            output_file.flush()

        while not STOP_REQUESTED:
            candidates = list(serial_port_candidates(explicit_port))
            if not candidates:
                if not logged_missing_port:
                    log("no SHT45 serial device found; continuing without environmental readings")
                    logged_missing_port = True
                time.sleep(5)
                continue

            for port in candidates:
                if STOP_REQUESTED:
                    break
                try:
                    log(f"reading SHT45 serial data from {port}")
                    for temperature_c, humidity_percent in readings_from_port(port):
                        now_monotonic = time.monotonic()
                        if now_monotonic < next_sample_monotonic:
                            continue
                        append_reading(writer, output_file, temperature_c, humidity_percent)
                        next_sample_monotonic = now_monotonic + interval_seconds
                        logged_missing_port = False
                except (OSError, termios.error) as exc:
                    log(f"SHT45 serial port unavailable: path={port} error={type(exc).__name__}: {exc}")
                if explicit_port:
                    break
            if not STOP_REQUESTED:
                time.sleep(5)

    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Log Adafruit SHT45 Trinkey readings as capture-session CSV.")
    parser.add_argument("--output", required=True, type=Path, help="CSV path in the recording session folder")
    parser.add_argument("--interval-seconds", type=int, default=DEFAULT_INTERVAL_SECONDS, help="sample interval (default: 60)")
    parser.add_argument(
        "--serial-port",
        default=os.environ.get("ANTCAM_SHT45_SERIAL_PORT", ""),
        help="optional SHT45 serial device override (defaults to ANTCAM_SHT45_SERIAL_PORT)",
    )
    args = parser.parse_args()
    if args.interval_seconds <= 0:
        parser.error("--interval-seconds must be a positive integer")

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    return run(args.output, args.interval_seconds, args.serial_port)


if __name__ == "__main__":
    sys.exit(main())
