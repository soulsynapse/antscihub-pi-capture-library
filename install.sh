#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="antscihub-capture-config.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
OLD_SERVICE_NAME="antscihub-capture.service"
CONFIG_SCRIPT="${SCRIPT_DIR}/1-capture_config/apply_camera_config.sh"

if [[ ! -f "${CONFIG_SCRIPT}" ]]; then
    echo "[antscihub-capture] Missing config script: ${CONFIG_SCRIPT}" >&2
    exit 1
fi

# Clean up old service if it exists
if systemctl list-unit-files | grep -q "^${OLD_SERVICE_NAME}"; then
    echo "[antscihub-capture] Removing old service: ${OLD_SERVICE_NAME}"
    systemctl disable "${OLD_SERVICE_NAME}" 2>/dev/null || true
    rm -f "/etc/systemd/system/${OLD_SERVICE_NAME}"
fi

chmod +x "${CONFIG_SCRIPT}"

cat > "${SERVICE_PATH}" <<EOF
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"

echo "[antscihub-capture] install complete"
echo "[antscihub-capture] service enabled: ${SERVICE_NAME}"