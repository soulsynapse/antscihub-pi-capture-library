#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCRIPTS=(
    "${REPO_ROOT}/install.sh"
    "${REPO_ROOT}/1-capture_config/antscam"
    "${REPO_ROOT}/4-upload/upload_worker.sh"
)

echo "[static-checks] Running bash syntax checks"
for script in "${SCRIPTS[@]}"; do
    bash -n "$script"
    echo "[static-checks] OK syntax: ${script}"
done

echo "[static-checks] Checking camera profile assets"
test -f "${REPO_ROOT}/1-capture_config/profiles/auto.conf"
test -f "${REPO_ROOT}/1-capture_config/profiles/imx708.conf"
test -f "${REPO_ROOT}/1-capture_config/profiles/owlcam.conf"
grep -q 'camera_auto_detect=1' "${REPO_ROOT}/1-capture_config/profiles/auto.conf"
grep -q 'dtoverlay=imx708' "${REPO_ROOT}/1-capture_config/profiles/imx708.conf"
grep -q 'dtoverlay=ov64a40' "${REPO_ROOT}/1-capture_config/profiles/owlcam.conf"
echo "[static-checks] OK camera profiles"

echo "[static-checks] Checking antscam command surface"
grep -q 'sudo antscam list' "${REPO_ROOT}/1-capture_config/antscam"
grep -q 'sudo antscam current' "${REPO_ROOT}/1-capture_config/antscam"
grep -q 'sudo antscam show <profile>' "${REPO_ROOT}/1-capture_config/antscam"
grep -q 'sudo antscam apply <profile>' "${REPO_ROOT}/1-capture_config/antscam"
grep -q 'remove_conflicting_camera_lines' "${REPO_ROOT}/1-capture_config/antscam"
echo "[static-checks] OK antscam checks"

echo "[static-checks] Checking upload worker safety features"
grep -q 'is_in_backoff_window' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'make_file_identity' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'clear_retry_state' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'resolve_upload_dir' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'rclone moveto' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q -- '--immutable' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'build_conflict_relative_path' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'MACHINE_SUFFIX' "${REPO_ROOT}/4-upload/upload_worker.sh"
echo "[static-checks] OK upload worker checks"

echo "[static-checks] Checking install defaults"
grep -q 'Environment="RCLONE_REMOTE=gdrive_personal"' "${REPO_ROOT}/install.sh"
grep -q 'Environment="RCLONE_PATH="' "${REPO_ROOT}/install.sh"
grep -q 'Environment="UPLOAD_DIR=${upload_dir}"' "${REPO_ROOT}/install.sh"
grep -q 'disable_dynamic_camera_service' "${REPO_ROOT}/install.sh"
grep -q 'install_camera_cli' "${REPO_ROOT}/install.sh"
grep -q 'sudo antscam apply imx708' "${REPO_ROOT}/install.sh"
echo "[static-checks] OK install defaults"

echo "[static-checks] All checks passed"
