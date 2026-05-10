#!/usr/bin/env bash
set -euo pipefail

CONFIG_CANDIDATES=(
    /boot/firmware/config.txt
    /boot/config.txt
)

CONFIG_FILE=""
for candidate in "${CONFIG_CANDIDATES[@]}"; do
    if [[ -f "${candidate}" ]]; then
        CONFIG_FILE="${candidate}"
        break
    fi
done

if [[ -z "${CONFIG_FILE}" ]]; then
    echo "[capture-config] No Raspberry Pi config.txt found" >&2
    exit 1
fi

if command -v rpicam-hello >/dev/null 2>&1; then
    LIST_CAMERA_CMD=(rpicam-hello --list-cameras)
elif command -v libcamera-hello >/dev/null 2>&1; then
    LIST_CAMERA_CMD=(libcamera-hello --list-cameras)
else
    echo "[capture-config] Neither rpicam-hello nor libcamera-hello is installed" >&2
    exit 1
fi

CAMERA_LIST_OUTPUT="$(${LIST_CAMERA_CMD[@]} 2>&1 || true)"

CAMERA_NAME=""
DESIRED_BLOCK=""

if echo "${CAMERA_LIST_OUTPUT}" | grep -qiE 'ov64a40'; then
    CAMERA_NAME="owlcam"
    DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=0
dtoverlay=ov64a40,link-frequency=360000000
dtoverlay=cma,cma-256
EOF
)
elif echo "${CAMERA_LIST_OUTPUT}" | grep -qiE 'imx708'; then
    CAMERA_NAME="arducam_v3"
    DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=0
dtoverlay=imx708
EOF
)
else
    echo "[capture-config] Unsupported or undetected camera" >&2
    echo "[capture-config] Camera output was:" >&2
    echo "${CAMERA_LIST_OUTPUT}" >&2
    exit 1
fi

BEGIN_MARKER="# antscihub-capture-config BEGIN"
END_MARKER="# antscihub-capture-config END"
CURRENT_BLOCK=$(awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block { print }
' "${CONFIG_FILE}")

if [[ "${CURRENT_BLOCK}" == "${DESIRED_BLOCK}" ]]; then
    echo "[capture-config] Already configured for ${CAMERA_NAME}"
    exit 0
fi

BACKUP_FILE="${CONFIG_FILE}.antscihub.bak.$(date +%Y%m%d-%H%M%S)"
cp "${CONFIG_FILE}" "${BACKUP_FILE}"

TMP_FILE=$(mktemp)
trap 'rm -f "${TMP_FILE}"' EXIT

awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    !in_block { print }
' "${CONFIG_FILE}" > "${TMP_FILE}"

{
    printf '%s\n' "${BEGIN_MARKER}"
    printf '%s\n' "${DESIRED_BLOCK}"
    printf '%s\n' "${END_MARKER}"
} >> "${TMP_FILE}"

install -m 0644 "${TMP_FILE}" "${CONFIG_FILE}"
sync

echo "[capture-config] Applied ${CAMERA_NAME} settings to ${CONFIG_FILE}"
echo "[capture-config] Backup saved to ${BACKUP_FILE}"
echo "[capture-config] Rebooting to apply firmware changes"
systemctl reboot --no-block
