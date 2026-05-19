#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_WORKER="${SCRIPT_DIR}/upload_worker.py"

if [[ ! -f "${PYTHON_WORKER}" ]]; then
    echo "[upload_worker.sh] ERROR: Missing Python worker: ${PYTHON_WORKER}" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[upload_worker.sh] ERROR: python3 is required for upload_worker.py" >&2
    exit 1
fi

exec python3 "${PYTHON_WORKER}" "$@"
