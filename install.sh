#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the real user — not root
REAL_USER="${SUDO_USER:-$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

chmod +x "${SCRIPT_DIR}"/*.sh 2>/dev/null || true

echo "[antscihub-capture] Installing dependencies..."

apt-get update -qq
apt-get install -y -qq python3-pip python3-venv libcap-dev 2>/dev/null || true

# Create venv as user so it's owned correctly
if [ ! -d "${SCRIPT_DIR}/venv" ]; then
    sudo -u "$REAL_USER" python3 -m venv "${SCRIPT_DIR}/venv" --system-site-packages
fi

sudo -u "$REAL_USER" "${SCRIPT_DIR}/venv/bin/pip" install --quiet --upgrade pip
sudo -u "$REAL_USER" "${SCRIPT_DIR}/venv/bin/pip" install --quiet -r "${SCRIPT_DIR}/requirements.txt"

# Create output dir as user
sudo -u "$REAL_USER" mkdir -p "${SCRIPT_DIR}/output"

cat > "${SCRIPT_DIR}/capture.sh" << WRAPPER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="${SCRIPT_DIR}"
exec "\${SCRIPT_DIR}/venv/bin/python" "\${SCRIPT_DIR}/run.py" "\$@"
WRAPPER
chmod +x "${SCRIPT_DIR}/capture.sh"

# Service runs as the real user, not root
cat > /etc/systemd/system/antscihub-capture.service << EOF
[Unit]
Description=AntSciHub Capture Library - Boot Health Check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/capture.sh --verify
WorkingDirectory=${SCRIPT_DIR}
RemainAfterExit=yes
User=${REAL_USER}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable antscihub-capture.service

# Fix ownership of everything
chown -R "${REAL_USER}:${REAL_USER}" "${SCRIPT_DIR}"

echo "[antscihub-capture] install complete"
echo "[antscihub-capture] invoke with: ${SCRIPT_DIR}/capture.sh --profile <profile.yaml>"