#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_WORKER="${SCRIPT_DIR}/video.py"

if [[ ! -f "${PYTHON_WORKER}" ]]; then
    echo "[video] missing python worker: ${PYTHON_WORKER}" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[video] python3 not found. install python3 to run video capture worker." >&2
    exit 1
fi

exec python3 "${PYTHON_WORKER}" "$@"
