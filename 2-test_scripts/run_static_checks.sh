#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCRIPTS=(
    "${REPO_ROOT}/install.sh"
    "${REPO_ROOT}/1-capture_config/apply_camera_config.sh"
    "${REPO_ROOT}/4-upload/upload_worker.sh"
)

echo "[static-checks] Running bash syntax checks"
for script in "${SCRIPTS[@]}"; do
    bash -n "$script"
    echo "[static-checks] OK syntax: ${script}"
done

echo "[static-checks] Checking upload worker safety features"
grep -q 'is_in_backoff_window' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'make_file_identity' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'clear_retry_state' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'resolve_upload_dir' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'rclone moveto' "${REPO_ROOT}/4-upload/upload_worker.sh"
echo "[static-checks] OK upload worker checks"

echo "[static-checks] Checking install defaults"
grep -q 'Environment="RCLONE_REMOTE=gdrive_personal"' "${REPO_ROOT}/install.sh"
grep -q 'Environment="RCLONE_PATH="' "${REPO_ROOT}/install.sh"
grep -q 'Environment="UPLOAD_DIR=${upload_dir}"' "${REPO_ROOT}/install.sh"
echo "[static-checks] OK install defaults"

echo "[static-checks] All checks passed"
