#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture config service
CONFIG_SERVICE_NAME="antscihub-capture-config.service"
CONFIG_SERVICE_PATH="/etc/systemd/system/${CONFIG_SERVICE_NAME}"
OLD_SERVICE_NAME="antscihub-capture.service"
CONFIG_SCRIPT="${SCRIPT_DIR}/1-capture_config/apply_camera_config.sh"

# Upload service
UPLOAD_SERVICE_NAME="antscihub-upload.service"
UPLOAD_SERVICE_PATH="/etc/systemd/system/${UPLOAD_SERVICE_NAME}"
UPLOAD_SCRIPT="${SCRIPT_DIR}/4-upload/upload_worker.sh"

determine_upload_user() {
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        echo "${SUDO_USER}"
        return 0
    fi

    if id -u 1000 >/dev/null 2>&1; then
        id -un 1000
        return 0
    fi

    echo "pi"
}

log_info() {
    echo "[antscihub-install] $*"
}

log_error() {
    echo "[antscihub-install] ERROR: $*" >&2
}

if [[ "$(id -u)" -ne 0 ]]; then
    log_error "Please run as root (for example: sudo bash install.sh)"
    exit 1
fi

# Validate scripts exist
if [[ ! -f "$CONFIG_SCRIPT" ]]; then
    log_error "Missing config script: $CONFIG_SCRIPT"
    exit 1
fi

if [[ ! -f "$UPLOAD_SCRIPT" ]]; then
    log_error "Missing upload script: $UPLOAD_SCRIPT"
    exit 1
fi

UPLOAD_SERVICE_USER="$(determine_upload_user)"
if ! id "${UPLOAD_SERVICE_USER}" >/dev/null 2>&1; then
    log_error "Upload service user does not exist: ${UPLOAD_SERVICE_USER}"
    exit 1
fi

log_info "Starting installation"

# Make scripts executable
chmod +x "$CONFIG_SCRIPT"
chmod +x "$UPLOAD_SCRIPT"

# Clean up old service if it exists
if systemctl list-unit-files 2>/dev/null | grep -q "^${OLD_SERVICE_NAME}"; then
    log_info "Removing old service: ${OLD_SERVICE_NAME}"
    systemctl stop "${OLD_SERVICE_NAME}" 2>/dev/null || true
    systemctl disable "${OLD_SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${OLD_SERVICE_NAME}"
fi

# Install capture config service
log_info "Installing camera config service: ${CONFIG_SERVICE_NAME}"
cat > "${CONFIG_SERVICE_PATH}" <<EOF
[Unit]
Description=AntSciHub Camera Auto-Config
After=local-fs.target
ConditionPathExists=${CONFIG_SCRIPT}

[Service]
Type=oneshot
ExecStart=${CONFIG_SCRIPT}
WorkingDirectory=${SCRIPT_DIR}
User=root
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Install upload service
log_info "Installing upload service: ${UPLOAD_SERVICE_NAME}"
cat > "${UPLOAD_SERVICE_PATH}" <<EOF
[Unit]
Description=AntSciHub Upload Worker
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${UPLOAD_SCRIPT}
WorkingDirectory=${SCRIPT_DIR}
User=${UPLOAD_SERVICE_USER}
Environment="RCLONE_REMOTE=gdrive_personal"
Environment="RCLONE_PATH=5-UPLOAD"
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

# Override in a drop-in if needed:
# sudo systemctl edit ${UPLOAD_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd
log_info "Reloading systemd daemon"
systemctl daemon-reload

# Enable and start capture config service
log_info "Enabling ${CONFIG_SERVICE_NAME}"
systemctl enable "${CONFIG_SERVICE_NAME}"

# Enable upload service for boot-time monitoring
log_info "Enabling ${UPLOAD_SERVICE_NAME}"
systemctl enable "${UPLOAD_SERVICE_NAME}"

# Start capture config service (runs immediately, may reboot)
log_info "Starting ${CONFIG_SERVICE_NAME}"
systemctl start "${CONFIG_SERVICE_NAME}"

# Wait a moment for service to start, then check status
sleep 2
if systemctl is-active "${CONFIG_SERVICE_NAME}" >/dev/null 2>&1; then
    log_info "${CONFIG_SERVICE_NAME} is running"
elif systemctl show "${CONFIG_SERVICE_NAME}" -p Result | grep -q "Result=success"; then
    log_info "${CONFIG_SERVICE_NAME} completed successfully"
else
    log_error "Failed to start ${CONFIG_SERVICE_NAME}. Check logs with: journalctl -u ${CONFIG_SERVICE_NAME}"
    exit 1
fi

log_info ""
log_info "Installation complete!"
log_info ""
log_info "Services installed:"
log_info "  - ${CONFIG_SERVICE_NAME} - Camera auto-detection and config (enabled, running)"
log_info "  - ${UPLOAD_SERVICE_NAME} - Upload worker (enabled, user=${UPLOAD_SERVICE_USER}, destination=gdrive_personal:5-UPLOAD)"
log_info ""
log_info "Upload destination is preset to:"
log_info "  gdrive_personal:5-UPLOAD"
log_info "Start upload service with:"
log_info "  sudo systemctl start ${UPLOAD_SERVICE_NAME}"
log_info ""
log_info "To override destination, edit: ${UPLOAD_SERVICE_PATH}"
log_info ""
log_info "Check service status:"
log_info "  systemctl status ${CONFIG_SERVICE_NAME}"
log_info "  systemctl status ${UPLOAD_SERVICE_NAME}"
log_info ""
log_info "View logs:"
log_info "  journalctl -u ${CONFIG_SERVICE_NAME} -f"
log_info "  journalctl -u ${UPLOAD_SERVICE_NAME} -f"
