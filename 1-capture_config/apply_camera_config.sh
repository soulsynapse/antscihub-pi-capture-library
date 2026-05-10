#!/usr/bin/env bash
set -euo pipefail

# State and logging directories
STATE_DIR="/var/lib/antscihub-capture-config"
LOG_FILE="/var/log/antscihub-capture-config.log"
ATTEMPT_COUNT="${STATE_DIR}/attempt-count"
LOCK_FILE="${STATE_DIR}/apply.lock"

# Reboot guards
MAX_ATTEMPTS=3

# Ensure directories exist
mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# Logging function
log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# Acquire lock to prevent concurrent runs
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "WARN" "Another instance is running. Exiting."
    exit 0
fi

log "INFO" "Camera config script started"

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
    log "ERROR" "No Raspberry Pi config.txt found"
    exit 1
fi

# Detect camera with robust fallback strategy
detect_camera() {
    # Try libcamera-hello first (more stable)
    if command -v libcamera-hello >/dev/null 2>&1; then
        log "DEBUG" "Trying libcamera-hello for camera detection"
        local output
        output=$(libcamera-hello --list-cameras 2>&1 || true)
        log "DEBUG" "libcamera-hello output: $output"
        
        if [[ -n "$output" ]]; then
            CAMERA_LIST_OUTPUT="$output"
        fi
    fi
    
    # If libcamera-hello didn't work, try rpicam-hello
    if [[ -z "$CAMERA_LIST_OUTPUT" ]] && command -v rpicam-hello >/dev/null 2>&1; then
        log "DEBUG" "Trying rpicam-hello for camera detection"
        local output
        output=$(rpicam-hello --list-cameras 2>&1 || true)
        log "DEBUG" "rpicam-hello output: $output"
        
        if [[ -n "$output" ]]; then
            CAMERA_LIST_OUTPUT="$output"
        fi
    fi
    
    # No camera attached is a valid runtime state: skip config writes/reboots.
    if [[ -z "$CAMERA_LIST_OUTPUT" ]] || echo "$CAMERA_LIST_OUTPUT" | grep -qiE 'no cameras? available|no cameras? detected|camera not found|cannot find camera'; then
        log "WARN" "No camera detected. Leaving existing camera config unchanged."
        return 2
    fi

    # Pattern matching for supported cameras
    if echo "$CAMERA_LIST_OUTPUT" | grep -qiE 'ov64a40|owlcam'; then
        log "INFO" "Detected: OV64A40 (Owlcam)"
        CAMERA_NAME="owlcam"
        DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=0
dtoverlay=ov64a40,link-frequency=360000000
dtoverlay=cma,cma-256
EOF
)
    elif echo "$CAMERA_LIST_OUTPUT" | grep -qiE 'imx708|arducam'; then
        log "INFO" "Detected: IMX708 (Arducam V3)"
        CAMERA_NAME="arducam_v3"
        DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=0
dtoverlay=imx708
EOF
)
    else
        log "ERROR" "Unsupported or undetected camera"
        log "ERROR" "Camera detection output: $CAMERA_LIST_OUTPUT"
        return 1
    fi
    
    return 0
}

# Call detection function
CAMERA_LIST_OUTPUT=""
if detect_camera; then
    :
else
    detection_result=$?
    if [[ $detection_result -eq 2 ]]; then
        rm -f "$ATTEMPT_COUNT"
        exit 0
    fi
    exit 1
fi

# Extract current managed block from config
BEGIN_MARKER="# antscihub-capture-config BEGIN"
END_MARKER="# antscihub-capture-config END"
CURRENT_BLOCK=$(awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
    $0 == begin { in_block = 1; next }
    $0 == end { in_block = 0; next }
    in_block { print }
' "${CONFIG_FILE}")

# Check if config is already correct
if [[ "${CURRENT_BLOCK}" == "${DESIRED_BLOCK}" ]]; then
    log "INFO" "Already configured for ${CAMERA_NAME}. No changes needed."
    rm -f "$ATTEMPT_COUNT"
    exit 0
fi

# Reboot guard: check if we're in a reboot loop
attempt_count=0
if [[ -f "$ATTEMPT_COUNT" ]]; then
    attempt_count=$(cat "$ATTEMPT_COUNT" 2>/dev/null || echo 0)
fi

attempt_count=$((attempt_count + 1))

if [[ $attempt_count -gt $MAX_ATTEMPTS ]]; then
    log "ERROR" "Max reboot attempts ($MAX_ATTEMPTS) exceeded for ${CAMERA_NAME}. Halting."
    log "ERROR" "Manual intervention required. Check camera and config.txt."
    exit 1
fi

log "INFO" "Attempt $attempt_count/$MAX_ATTEMPTS to apply ${CAMERA_NAME} config"

# Apply the new config
BACKUP_FILE="${CONFIG_FILE}.antscihub.bak.$(date +%Y%m%d-%H%M%S)"
cp "${CONFIG_FILE}" "${BACKUP_FILE}"
log "INFO" "Backup saved to $BACKUP_FILE"

TMP_FILE=$(mktemp)
trap 'rm -f "${TMP_FILE}"' EXIT

# Remove old managed block and write new one
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

log "INFO" "Applied ${CAMERA_NAME} settings to ${CONFIG_FILE}"

# Save attempt count
echo "$attempt_count" > "$ATTEMPT_COUNT"

log "INFO" "Rebooting to apply firmware changes (attempt $attempt_count/$MAX_ATTEMPTS)"
systemctl reboot --no-block
