#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCRIPTS=(
    "${REPO_ROOT}/install.sh"
    "${REPO_ROOT}/1-capture_config/apply_camera_config.sh"
    "${REPO_ROOT}/1-capture_config/antcam"
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

echo "[static-checks] Checking antcam command surface"
grep -q 'sudo antcam list' "${REPO_ROOT}/1-capture_config/antcam"
grep -q 'sudo antcam current' "${REPO_ROOT}/1-capture_config/antcam"
grep -q 'sudo antcam show <profile>' "${REPO_ROOT}/1-capture_config/antcam"
grep -q 'sudo antcam apply <profile>' "${REPO_ROOT}/1-capture_config/antcam"
grep -q 'antcam start' "${REPO_ROOT}/1-capture_config/antcam"
grep -q 'remove_conflicting_camera_lines' "${REPO_ROOT}/1-capture_config/antcam"
echo "[static-checks] OK antcam checks"

echo "[static-checks] Checking recording trigger docs"
test -f "${REPO_ROOT}/3-recording_scripts/README.md"
grep -q 'record.sh' "${REPO_ROOT}/3-recording_scripts/README.md"
grep -q 'experiment.txt' "${REPO_ROOT}/3-recording_scripts/README.md"
echo "[static-checks] OK recording trigger docs"

echo "[static-checks] Checking upload worker safety features"
grep -q 'is_in_backoff_window' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'make_file_identity' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'clear_retry_state' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'resolve_upload_dir' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'is_still_image' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'MIN_FILE_AGE_STILL_IMAGE=3' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE=3' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'emit_upload_event' "${REPO_ROOT}/4-upload/upload_worker.sh"
grep -q 'UPLOAD_EVENT status=' "${REPO_ROOT}/4-upload/upload_worker.sh"
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
grep -q 'sudo antcam apply imx708' "${REPO_ROOT}/install.sh"
echo "[static-checks] OK install defaults"

echo "[static-checks] All checks passed"
