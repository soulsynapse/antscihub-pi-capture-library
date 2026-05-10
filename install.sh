#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONFIG_SERVICE_NAME="antscihub-capture-config.service"
CONFIG_SERVICE_PATH="/etc/systemd/system/${CONFIG_SERVICE_NAME}"
CONFIG_SCRIPT="${SCRIPT_DIR}/1-capture_config/apply_camera_config.sh"
CAPTURE_ENV_FILE="/etc/default/antscihub-capture-config"
DEFAULT_CAMERA_PROFILE_MODE="dynamic"

UPLOAD_SERVICE_NAME="antscihub-upload.service"
UPLOAD_SERVICE_PATH="/etc/systemd/system/${UPLOAD_SERVICE_NAME}"
UPLOAD_SCRIPT="${SCRIPT_DIR}/4-upload/upload_worker.sh"

DEFAULT_REMOTE="gdrive_personal"
DEFAULT_REMOTE_PATH=""

LEGACY_UNITS=(
    "antscihub-capture.service"
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

normalize_camera_profile_mode() {
    local raw="$1"
    raw="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$raw" in
        dynamic|auto|owlcam|imx708)
            printf '%s\n' "$raw"
            ;;
        *)
            printf '%s\n' ""
            ;;
    esac
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Please run as root (example: sudo bash install.sh)"
        exit 1
    fi
}

require_inputs() {
    if [[ ! -f "$CONFIG_SCRIPT" ]]; then
        log_error "Missing capture config script: $CONFIG_SCRIPT"
        exit 1
    fi

    if [[ ! -f "$UPLOAD_SCRIPT" ]]; then
        log_error "Missing upload worker script: $UPLOAD_SCRIPT"
        exit 1
    fi
}

ensure_i2c_tools() {
    if command -v i2ctransfer >/dev/null 2>&1; then
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        log_warn "apt-get not found; cannot auto-install i2c-tools (Owlcam fallback probe will be unavailable)"
        return 0
    fi

    log_info "Installing i2c-tools for Owlcam fallback detection"
    if ! apt-get update -qq >/dev/null 2>&1; then
        log_warn "apt-get update failed; skipping i2c-tools install"
        return 0
    fi
    if ! apt-get install -y -qq i2c-tools >/dev/null 2>&1; then
        log_warn "Failed to install i2c-tools; Owlcam fallback probe will be unavailable"
        return 0
    fi
}

ensure_capture_env_file() {
    local mode_line mode_value normalized

    if [[ ! -f "${CAPTURE_ENV_FILE}" ]]; then
        cat > "${CAPTURE_ENV_FILE}" <<EOF
# AntSciHub capture profile mode
# dynamic: auto mode for official sensors + Owlcam fallback logic
# auto:    always force camera_auto_detect=1
# owlcam:  always force OV64A40 manual profile
# imx708:  always force manual IMX708 profile
CAMERA_PROFILE_MODE="${DEFAULT_CAMERA_PROFILE_MODE}"
EOF
        chmod 0644 "${CAPTURE_ENV_FILE}"
        log_info "Created ${CAPTURE_ENV_FILE} with CAMERA_PROFILE_MODE=${DEFAULT_CAMERA_PROFILE_MODE}"
        return 0
    fi

    mode_line="$(grep -E '^[[:space:]]*CAMERA_PROFILE_MODE=' "${CAPTURE_ENV_FILE}" | tail -n 1 || true)"
    if [[ -z "${mode_line}" ]]; then
        {
            echo ""
            echo "CAMERA_PROFILE_MODE=\"${DEFAULT_CAMERA_PROFILE_MODE}\""
        } >> "${CAPTURE_ENV_FILE}"
        log_info "Added missing CAMERA_PROFILE_MODE to ${CAPTURE_ENV_FILE}"
        return 0
    fi

    mode_value="${mode_line#*=}"
    mode_value="${mode_value%\"}"
    mode_value="${mode_value#\"}"
    mode_value="${mode_value%\'}"
    mode_value="${mode_value#\'}"
    normalized="$(normalize_camera_profile_mode "${mode_value}")"

    if [[ -z "${normalized}" ]]; then
        sed -i -E 's|^[[:space:]]*CAMERA_PROFILE_MODE=.*$|CAMERA_PROFILE_MODE="dynamic"|' "${CAPTURE_ENV_FILE}"
        log_warn "Invalid CAMERA_PROFILE_MODE in ${CAPTURE_ENV_FILE}; reset to dynamic"
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

ensure_units_unmasked() {
    local unit
    for unit in "${CONFIG_SERVICE_NAME}" "${UPLOAD_SERVICE_NAME}"; do
        if systemctl is-enabled "$unit" 2>/dev/null | grep -qi '^masked'; then
            log_info "Unmasking ${unit}"
            if ! systemctl unmask "$unit" >/dev/null 2>&1; then
                log_warn "Failed to unmask ${unit}; continuing"
            fi
        fi
    done
}

write_capture_unit() {
    cat > "${CONFIG_SERVICE_PATH}" <<EOF
[Unit]
Description=AntSciHub Camera Auto-Config
After=local-fs.target
ConditionPathExists=${CONFIG_SCRIPT}

[Service]
Type=oneshot
EnvironmentFile=-${CAPTURE_ENV_FILE}
ExecStart=${CONFIG_SCRIPT}
WorkingDirectory=${SCRIPT_DIR}
User=root
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

write_upload_unit() {
    local upload_user="$1"
    local upload_home="$2"
    local upload_dir="$3"

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

start_capture_service() {
    log_info "Starting ${CONFIG_SERVICE_NAME}"
    systemctl start "${CONFIG_SERVICE_NAME}"

    sleep 2
    if systemctl is-active "${CONFIG_SERVICE_NAME}" >/dev/null 2>&1; then
        log_info "${CONFIG_SERVICE_NAME} is active"
        return 0
    fi
    if systemctl show "${CONFIG_SERVICE_NAME}" -p Result 2>/dev/null | grep -q "Result=success"; then
        log_info "${CONFIG_SERVICE_NAME} completed successfully"
        return 0
    fi

    log_error "Failed to start ${CONFIG_SERVICE_NAME}. Check: journalctl -u ${CONFIG_SERVICE_NAME} -n 100"
    return 1
}

sync_upload_service() {
    local was_enabled="$1"
    local was_active="$2"

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

main() {
    require_root
    require_inputs
    ensure_i2c_tools
    ensure_capture_env_file

    log_info "Starting installation/update"

    chmod +x "$CONFIG_SCRIPT" "$UPLOAD_SCRIPT"

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
    ensure_units_unmasked

    # Clear old manager-level overrides from older install flows.
    systemctl unset-environment RCLONE_REMOTE RCLONE_PATH UPLOAD_DIR >/dev/null 2>&1 || true

    log_info "Writing ${CONFIG_SERVICE_NAME}"
    write_capture_unit

    log_info "Writing ${UPLOAD_SERVICE_NAME}"
    write_upload_unit "$upload_user" "$upload_home" "$upload_dir"

    log_info "Reloading systemd daemon"
    systemctl daemon-reload

    log_info "Enabling ${CONFIG_SERVICE_NAME}"
    systemctl enable "${CONFIG_SERVICE_NAME}" >/dev/null

    log_info "Enabling ${UPLOAD_SERVICE_NAME}"
    systemctl enable "${UPLOAD_SERVICE_NAME}" >/dev/null

    start_capture_service
    sync_upload_service "$upload_was_enabled" "$upload_was_active"

    local upload_destination="${DEFAULT_REMOTE}:"
    if [[ -n "${DEFAULT_REMOTE_PATH}" ]]; then
        upload_destination="${DEFAULT_REMOTE}:${DEFAULT_REMOTE_PATH}"
    fi

    log_info "Installation/update complete"
    log_info "Capture mode file: ${CAPTURE_ENV_FILE}"
    log_info "Upload service user: ${upload_user}"
    log_info "Upload source dir: ${upload_dir}"
    log_info "Upload destination: ${upload_destination}"
    log_info "Status checks:"
    log_info "  systemctl status ${CONFIG_SERVICE_NAME}"
    log_info "  systemctl status ${UPLOAD_SERVICE_NAME}"
    log_info "Logs:"
    log_info "  journalctl -u ${CONFIG_SERVICE_NAME} -n 100"
    log_info "  journalctl -u ${UPLOAD_SERVICE_NAME} -n 100"
}

main "$@"
