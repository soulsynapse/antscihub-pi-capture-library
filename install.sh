#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CAMERA_SERVICE_NAME="antscihub-capture-config.service"
CAMERA_SERVICE_PATH="/etc/systemd/system/${CAMERA_SERVICE_NAME}"

CAMERA_CLI_SOURCE="${SCRIPT_DIR}/1-capture_config/antcam"
CAMERA_CLI_TARGET="/usr/local/bin/antcam"
LEGACY_CAMERA_CLI_TARGET="/usr/local/bin/antscam"
ANTCAM_HELPER_SOURCE_DIR="${SCRIPT_DIR}/1-capture_config"
ANTCAM_UPLOAD_HELPER_SOURCE="${ANTCAM_HELPER_SOURCE_DIR}/antcam_upload_helpers.sh"
ANTCAM_DIAGNOSTIC_HELPER_SOURCE="${ANTCAM_HELPER_SOURCE_DIR}/antcam_diagnostic_helpers.sh"
ANTCAM_HELPER_TARGET_DIR="/etc/antscihub/antcam-lib"
CAMERA_PROFILE_SOURCE_DIR="${SCRIPT_DIR}/1-capture_config/profiles"
CAMERA_PROFILE_TARGET_DIR="/etc/antscihub/camera-profiles"
FOCUS_SCRIPT_SOURCE="${SCRIPT_DIR}/1-capture_config/antcam_focus_autofocus.sh"
FOCUS_SCRIPT_TARGET="/etc/antscihub/antcam_focus_autofocus.sh"
RECORDING_SCRIPT_SOURCE_DIR="${SCRIPT_DIR}/3-recording_scripts"
RECORDING_SCRIPT_TARGET_DIR="/etc/antscihub/recording-scripts"

UPLOAD_SERVICE_NAME="antscihub-upload.service"
UPLOAD_SERVICE_PATH="/etc/systemd/system/${UPLOAD_SERVICE_NAME}"
UPLOAD_SCRIPT="${SCRIPT_DIR}/4-upload/upload_worker.sh"
UPLOAD_PY_SCRIPT="${SCRIPT_DIR}/4-upload/upload_worker.py"

DEFAULT_REMOTE="gdrive_personal"
DEFAULT_REMOTE_PATH=""

LEGACY_UNITS=(
    "antscihub-capture.service"
    "${CAMERA_SERVICE_NAME}"
)

log_info() {
    echo "[antscihub-install] $*"
}

log_warn() {
    echo "[antscihub-install] WARN: $*" >&2
}

log_error() {
    echo "[antscihub-install] ERROR: $*" >&2
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Please run as root (example: sudo bash install.sh)"
        exit 1
    fi
}

require_inputs() {
    if [[ ! -f "$CAMERA_CLI_SOURCE" ]]; then
        log_error "Missing camera CLI: $CAMERA_CLI_SOURCE"
        exit 1
    fi

    if [[ ! -d "$CAMERA_PROFILE_SOURCE_DIR" ]]; then
        log_error "Missing camera profile directory: $CAMERA_PROFILE_SOURCE_DIR"
        exit 1
    fi

    if [[ ! -f "$UPLOAD_SCRIPT" ]]; then
        log_error "Missing upload worker script: $UPLOAD_SCRIPT"
        exit 1
    fi
    if [[ ! -f "$UPLOAD_PY_SCRIPT" ]]; then
        log_error "Missing upload worker script: $UPLOAD_PY_SCRIPT"
        exit 1
    fi

    if [[ ! -f "$FOCUS_SCRIPT_SOURCE" ]]; then
        log_error "Missing focus helper script: $FOCUS_SCRIPT_SOURCE"
        exit 1
    fi

    if [[ ! -f "$ANTCAM_UPLOAD_HELPER_SOURCE" ]]; then
        log_error "Missing antcam upload helper script: $ANTCAM_UPLOAD_HELPER_SOURCE"
        exit 1
    fi

    if [[ ! -f "$ANTCAM_DIAGNOSTIC_HELPER_SOURCE" ]]; then
        log_error "Missing antcam diagnostic helper script: $ANTCAM_DIAGNOSTIC_HELPER_SOURCE"
        exit 1
    fi

    if [[ ! -d "$RECORDING_SCRIPT_SOURCE_DIR" ]]; then
        log_error "Missing recording script directory: $RECORDING_SCRIPT_SOURCE_DIR"
        exit 1
    fi

    if ! find "$RECORDING_SCRIPT_SOURCE_DIR" -maxdepth 1 -type f -name '*.sh' | grep -q '.'; then
        log_error "No recording scripts found in: $RECORDING_SCRIPT_SOURCE_DIR"
        exit 1
    fi

    if [[ ! -f "${RECORDING_SCRIPT_SOURCE_DIR}/video.py" ]]; then
        log_error "Missing video python worker: ${RECORDING_SCRIPT_SOURCE_DIR}/video.py"
        exit 1
    fi

    if [[ ! -f "${RECORDING_SCRIPT_SOURCE_DIR}/photos.py" ]]; then
        log_error "Missing photos python worker: ${RECORDING_SCRIPT_SOURCE_DIR}/photos.py"
        exit 1
    fi
}

determine_upload_user() {
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]] && id "${SUDO_USER}" >/dev/null 2>&1; then
        printf '%s\n' "${SUDO_USER}"
        return 0
    fi

    if id -u 1000 >/dev/null 2>&1; then
        id -un 1000
        return 0
    fi

    local first_regular_user
    if command -v getent >/dev/null 2>&1; then
        first_regular_user="$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }')"
    else
        first_regular_user="$(awk -F: '$3 >= 1000 && $3 < 60000 { print $1; exit }' /etc/passwd 2>/dev/null || true)"
    fi
    if [[ -n "$first_regular_user" ]]; then
        printf '%s\n' "$first_regular_user"
        return 0
    fi

    if id pi >/dev/null 2>&1; then
        printf '%s\n' "pi"
        return 0
    fi

    return 1
}

home_for_user() {
    local username="$1"
    local user_home
    if command -v getent >/dev/null 2>&1; then
        user_home="$(getent passwd "$username" 2>/dev/null | cut -d: -f6 || true)"
    else
        user_home="$(awk -F: -v user="$username" '$1 == user { print $6; exit }' /etc/passwd 2>/dev/null || true)"
    fi
    if [[ -z "$user_home" ]]; then
        return 1
    fi
    printf '%s\n' "$user_home"
}

resolve_desktop_dir_for_home() {
    local user_home="$1"
    local desktop=""
    local user_dirs_file="${user_home}/.config/user-dirs.dirs"

    if [[ -f "$user_dirs_file" ]]; then
        local desktop_line
        desktop_line="$(grep -E '^XDG_DESKTOP_DIR=' "$user_dirs_file" | tail -n 1 || true)"
        if [[ -n "$desktop_line" ]]; then
            desktop="${desktop_line#XDG_DESKTOP_DIR=}"
            desktop="${desktop%\"}"
            desktop="${desktop#\"}"
            desktop="${desktop//\$HOME/$user_home}"
            if [[ "$desktop" != /* ]]; then
                desktop="${user_home}/${desktop#./}"
            fi
        fi
    fi

    if [[ -z "$desktop" ]]; then
        if [[ -d "${user_home}/Desktop" ]]; then
            desktop="${user_home}/Desktop"
        elif [[ -d "${user_home}/desktop" ]]; then
            desktop="${user_home}/desktop"
        else
            desktop="${user_home}/Desktop"
        fi
    fi

    printf '%s\n' "${desktop%/}"
}

remove_legacy_units() {
    local unit
    for unit in "${LEGACY_UNITS[@]}"; do
        if [[ -f "/etc/systemd/system/${unit}" ]] || systemctl list-unit-files --no-legend "$unit" 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
            log_info "Removing legacy unit: ${unit}"
            systemctl stop "$unit" >/dev/null 2>&1 || true
            systemctl disable "$unit" >/dev/null 2>&1 || true
            rm -f "/etc/systemd/system/${unit}"
            rm -f "/etc/systemd/system/multi-user.target.wants/${unit}"
        fi
    done
}

disable_dynamic_camera_service() {
    log_info "Disabling boot-time dynamic camera service"
    systemctl stop "${CAMERA_SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl disable "${CAMERA_SERVICE_NAME}" >/dev/null 2>&1 || true
    if systemctl is-enabled "${CAMERA_SERVICE_NAME}" 2>/dev/null | grep -qi '^masked'; then
        systemctl unmask "${CAMERA_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi
    rm -f "${CAMERA_SERVICE_PATH}"
    rm -f "/etc/systemd/system/multi-user.target.wants/${CAMERA_SERVICE_NAME}"
}

install_camera_cli() {
    log_info "Installing camera profiles to ${CAMERA_PROFILE_TARGET_DIR}"
    mkdir -p "${CAMERA_PROFILE_TARGET_DIR}"
    rm -f "${CAMERA_PROFILE_TARGET_DIR}"/*.conf
    cp -a "${CAMERA_PROFILE_SOURCE_DIR}/." "${CAMERA_PROFILE_TARGET_DIR}/"
    find "${CAMERA_PROFILE_TARGET_DIR}" -type f -name '*.conf' -exec chmod 0644 {} +

    log_info "Installing antcam CLI to ${CAMERA_CLI_TARGET}"
    install -m 0755 "${CAMERA_CLI_SOURCE}" "${CAMERA_CLI_TARGET}"

    log_info "Installing antcam helper libraries to ${ANTCAM_HELPER_TARGET_DIR}"
    mkdir -p "${ANTCAM_HELPER_TARGET_DIR}"
    rm -f "${ANTCAM_HELPER_TARGET_DIR}"/antcam_*_helpers.sh
    install -m 0644 "${ANTCAM_UPLOAD_HELPER_SOURCE}" "${ANTCAM_HELPER_TARGET_DIR}/antcam_upload_helpers.sh"
    install -m 0644 "${ANTCAM_DIAGNOSTIC_HELPER_SOURCE}" "${ANTCAM_HELPER_TARGET_DIR}/antcam_diagnostic_helpers.sh"

    log_info "Installing focus helper script to ${FOCUS_SCRIPT_TARGET}"
    mkdir -p "/etc/antscihub"
    install -m 0755 "${FOCUS_SCRIPT_SOURCE}" "${FOCUS_SCRIPT_TARGET}"

    log_info "Installing recording scripts to ${RECORDING_SCRIPT_TARGET_DIR}"
    mkdir -p "${RECORDING_SCRIPT_TARGET_DIR}"
    rm -f "${RECORDING_SCRIPT_TARGET_DIR}"/*.sh
    rm -f "${RECORDING_SCRIPT_TARGET_DIR}"/*.py
    cp -a "${RECORDING_SCRIPT_SOURCE_DIR}/." "${RECORDING_SCRIPT_TARGET_DIR}/"
    find "${RECORDING_SCRIPT_TARGET_DIR}" -type f -name '*.sh' -exec chmod 0755 {} +
    find "${RECORDING_SCRIPT_TARGET_DIR}" -type f -name '*.py' -exec chmod 0755 {} +

    if [[ -f "${LEGACY_CAMERA_CLI_TARGET}" ]]; then
        log_info "Removing legacy camera CLI at ${LEGACY_CAMERA_CLI_TARGET}"
        rm -f "${LEGACY_CAMERA_CLI_TARGET}"
    fi
}

write_upload_unit() {
    local upload_user="$1"
    local upload_home="$2"
    local upload_dir="$3"
    local upload_parent upload_config_dir
    upload_parent="$(dirname "${upload_dir}")"
    upload_config_dir="${upload_parent}/4-CAPTURE/config"

    cat > "${UPLOAD_SERVICE_PATH}" <<EOF
[Unit]
Description=AntSciHub Upload Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${UPLOAD_SCRIPT}
WorkingDirectory=${SCRIPT_DIR}
User=${upload_user}
Environment="HOME=${upload_home}"
Environment="RCLONE_REMOTE=${DEFAULT_REMOTE}"
Environment="RCLONE_PATH=${DEFAULT_REMOTE_PATH}"
Environment="UPLOAD_DIR=${upload_dir}"
Environment="UPLOAD_CONFIG_DIR=${upload_config_dir}"
Environment="UPLOAD_PROFILE=field"
Environment="UPLOAD_RETENTION=protect"
Environment="UPLOAD_HIGH_WATERMARK_PERCENT=80"
Environment="UPLOAD_LOW_WATERMARK_PERCENT=70"
# Optional overrides for orchestrator event publishing:
# Environment="DEVICE_ID=pi-0123"
# Environment="FLEET_DEVICE_ID=pi-0123"
# Environment="FLEET_EVENT_TOPIC_TEMPLATE=fleet/report/{DEVICE_ID}"
# Environment="FLEET_PUBLISH_BIN=fleet-publish"
# Environment="MQTT_REPORT_BIN=mqtt_report.py"
# Environment="MQTT_EVENT_ENABLED=true"
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Override in a drop-in if needed:
# sudo systemctl edit ${UPLOAD_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF
}

sync_upload_service() {
    local was_enabled="$1"
    local was_active="$2"

    if systemctl is-enabled "${UPLOAD_SERVICE_NAME}" 2>/dev/null | grep -qi '^masked'; then
        log_info "Unmasking ${UPLOAD_SERVICE_NAME}"
        systemctl unmask "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1 || true
    fi

    systemctl reset-failed "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1 || true

    if [[ "$was_enabled" == "true" ]]; then
        log_info "Restarting ${UPLOAD_SERVICE_NAME} (was enabled before install)"
        if ! systemctl restart "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1; then
            log_warn "Could not restart ${UPLOAD_SERVICE_NAME}. Check logs after install."
        fi
        return 0
    fi

    if [[ "$was_active" == "true" ]]; then
        log_info "Restarting ${UPLOAD_SERVICE_NAME} (was active before install)"
        if ! systemctl restart "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1; then
            log_warn "Could not restart ${UPLOAD_SERVICE_NAME}. Check logs after install."
        fi
        return 0
    fi

    log_info "Starting ${UPLOAD_SERVICE_NAME}"
    if ! systemctl start "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1; then
        log_warn "Could not start ${UPLOAD_SERVICE_NAME}. This is usually rclone-config related."
    fi
}

reconcile_single_upload_worker() {
    local upload_user="$1"
    local upload_home="$2"
    local upload_uid
    upload_uid="$(id -u "${upload_user}" 2>/dev/null || true)"

    log_info "Reconciling upload worker to a single instance"
    systemctl stop "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1 || true
    systemctl reset-failed "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1 || true

    local upload_pids
    upload_pids="$(pgrep -f 'upload_worker\.(sh|py)' 2>/dev/null || true)"
    if [[ -n "${upload_pids}" ]]; then
        log_warn "Stopping residual upload worker process(es): $(echo "${upload_pids}" | tr '\n' ' ')"
        while IFS= read -r pid; do
            [[ -n "${pid}" ]] || continue
            kill -TERM "${pid}" >/dev/null 2>&1 || true
        done <<< "${upload_pids}"
        sleep 1

        upload_pids="$(pgrep -f 'upload_worker\.(sh|py)' 2>/dev/null || true)"
        if [[ -n "${upload_pids}" ]]; then
            log_warn "Force-stopping stuck upload worker process(es): $(echo "${upload_pids}" | tr '\n' ' ')"
            while IFS= read -r pid; do
                [[ -n "${pid}" ]] || continue
                kill -KILL "${pid}" >/dev/null 2>&1 || true
            done <<< "${upload_pids}"
        fi
    fi

    rm -f "/tmp/antscihub-upload.lock" >/dev/null 2>&1 || true
    if [[ -n "${upload_uid}" ]]; then
        rm -f "/run/user/${upload_uid}/antscihub-upload.lock" >/dev/null 2>&1 || true
    fi
    rm -f "${upload_home}/.local/state/antscihub-upload/antscihub-upload.lock" >/dev/null 2>&1 || true
}

main() {
    require_root
    require_inputs

    log_info "Starting installation/update"

    chmod +x "${UPLOAD_SCRIPT}" "${UPLOAD_PY_SCRIPT}" "${CAMERA_CLI_SOURCE}"

    local upload_user
    if ! upload_user="$(determine_upload_user)"; then
        log_error "Unable to determine a non-root upload service user"
        exit 1
    fi
    if ! id "$upload_user" >/dev/null 2>&1; then
        log_error "Resolved upload user does not exist: $upload_user"
        exit 1
    fi

    local upload_home
    if ! upload_home="$(home_for_user "$upload_user")"; then
        log_error "Unable to resolve home directory for user: $upload_user"
        exit 1
    fi

    local desktop_dir upload_dir
    desktop_dir="$(resolve_desktop_dir_for_home "$upload_home")"
    upload_dir="${desktop_dir}/5-UPLOAD"

    local upload_was_enabled="false"
    local upload_was_active="false"
    if systemctl is-enabled --quiet "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1; then
        upload_was_enabled="true"
    fi
    if systemctl is-active --quiet "${UPLOAD_SERVICE_NAME}" >/dev/null 2>&1; then
        upload_was_active="true"
    fi

    remove_legacy_units
    disable_dynamic_camera_service
    install_camera_cli

    # Clear old manager-level overrides from older install flows.
    systemctl unset-environment RCLONE_REMOTE RCLONE_PATH UPLOAD_DIR >/dev/null 2>&1 || true

    log_info "Writing ${UPLOAD_SERVICE_NAME}"
    write_upload_unit "$upload_user" "$upload_home" "$upload_dir"

    log_info "Reloading systemd daemon"
    systemctl daemon-reload

    log_info "Enabling ${UPLOAD_SERVICE_NAME}"
    systemctl enable "${UPLOAD_SERVICE_NAME}" >/dev/null

    reconcile_single_upload_worker "$upload_user" "$upload_home"
    sync_upload_service "$upload_was_enabled" "$upload_was_active"

    local upload_destination="${DEFAULT_REMOTE}:"
    if [[ -n "${DEFAULT_REMOTE_PATH}" ]]; then
        upload_destination="${DEFAULT_REMOTE}:${DEFAULT_REMOTE_PATH}"
    fi

    log_info "Installation/update complete"
    log_info "Camera profiles dir: ${CAMERA_PROFILE_TARGET_DIR}"
    log_info "Camera CLI: ${CAMERA_CLI_TARGET}"
    log_info "Antcam helper libs dir: ${ANTCAM_HELPER_TARGET_DIR}"
    log_info "Focus helper script: ${FOCUS_SCRIPT_TARGET}"
    log_info "Recording scripts dir: ${RECORDING_SCRIPT_TARGET_DIR}"
    log_info "Dynamic camera service disabled: ${CAMERA_SERVICE_NAME}"
    log_info "Upload service user: ${upload_user}"
    log_info "Upload source dir: ${upload_dir}"
    log_info "Upload destination: ${upload_destination}"
    log_info "Camera commands:"
    log_info "  sudo antcam list"
    log_info "  sudo antcam cam report"
    log_info "  sudo antcam apply imx708"
    log_info "  antcam focus set 7.5"
    log_info "  antcam focus set auto"
    log_info "  antcam fps set 1"
    log_info "  antcam length set 30h"
    log_info "  antcam segment set 10m"
    log_info "  antcam photo-every set 1m"
    log_info "  antcam focus report"
    log_info "  antcam fps report"
    log_info "  antcam length report"
    log_info "  antcam segment report"
    log_info "  antcam photo-every report"
    log_info "  antcam capture report"
    log_info "  antcam start video"
    log_info "  antcam start photos"
    log_info "  antcam stop"
    log_info "  antcam focus check"
    log_info "  antcam upload set profile field"
    log_info "  antcam upload set retention protect"
    log_info "  antcam upload report"
    log_info "  antcam upload report queue"
    log_info "  antcam upload report targets"
    log_info "  antcam upload pause"
    log_info "  antcam upload resume"
    log_info "  antcam upload prune --older-than 72h --dry-run"
    log_info "Upload checks:"
    log_info "  systemctl status ${UPLOAD_SERVICE_NAME}"
    log_info "  journalctl -u ${UPLOAD_SERVICE_NAME} -n 100"
}

main "$@"
