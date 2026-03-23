#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

chmod +x "${SCRIPT_DIR}"/*.sh 2>/dev/null || true

echo "[antscihub-capture] Installing dependencies..."

apt-get update -qq
apt-get install -y -qq python3-pip python3-venv libcap-dev 2>/dev/null || true

if [ ! -d "${SCRIPT_DIR}/venv" ]; then
    python3 -m venv "${SCRIPT_DIR}/venv" --system-site-packages
fi

"${SCRIPT_DIR}/venv/bin/pip" install --quiet --upgrade pip
"${SCRIPT_DIR}/venv/bin/pip" install --quiet -r "${SCRIPT_DIR}/requirements.txt"

mkdir -p "${SCRIPT_DIR}/output"

cat > "${SCRIPT_DIR}/capture.sh" << WRAPPER
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="${SCRIPT_DIR}"
exec "\${SCRIPT_DIR}/venv/bin/python" "\${SCRIPT_DIR}/run.py" "\$@"
WRAPPER
chmod +x "${SCRIPT_DIR}/capture.sh"

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
User=root
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable antscihub-capture.service

echo "[antscihub-capture] install complete"
echo "[antscihub-capture] invoke with: ${SCRIPT_DIR}/capture.sh --profile <profile.yaml>"