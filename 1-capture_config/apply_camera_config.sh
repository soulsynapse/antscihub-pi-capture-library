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

DESIRED_BLOCK=""
CAMERA_NAME="unknown"

set_desired_auto_profile() {
    CAMERA_NAME="auto_detect"
    DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=1
EOF
)
}

set_desired_owlcam_profile() {
    CAMERA_NAME="owlcam"
    DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=0
dtoverlay=ov64a40,link-frequency=360000000
dtoverlay=cma,cma-256
EOF
)
}

list_i2c_buses() {
    local dev bus
    for dev in /dev/i2c-*; do
        [[ -e "$dev" ]] || continue
        bus="${dev##*/i2c-}"
        [[ "$bus" =~ ^[0-9]+$ ]] || continue
        printf '%s\n' "$bus"
    done | sort -n | uniq
}

# Best-effort Owlcam hardware probe for cases where camera_auto_detect=1
# cannot enumerate third-party sensors.
detect_owlcam_via_i2c() {
    local bus raw normalized

    if ! command -v i2ctransfer >/dev/null 2>&1; then
        return 1
    fi

    while IFS= read -r bus; do
        [[ -n "$bus" ]] || continue
        raw="$(i2ctransfer -f -y "$bus" w2@0x36 0x30 0x0A r3 2>/dev/null || true)"
        [[ -n "$raw" ]] || continue

        normalized="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
        if [[ "$normalized" == "0x560x640x41" ]]; then
            log "INFO" "Detected Owlcam via I2C probe on bus ${bus} (chip ID 0x566441)"
            return 0
        fi
    done < <(list_i2c_buses)

    return 1
}

# Detect camera with robust fallback strategy
detect_camera() {
    local no_camera_patterns='no cameras? available|no cameras? detected|camera not found|cannot find camera|failed to register camera'
    local output=""

    # Try libcamera-hello first (more stable)
    if command -v libcamera-hello >/dev/null 2>&1; then
        log "DEBUG" "Trying libcamera-hello for camera detection"
        output=$(libcamera-hello --list-cameras 2>&1 || true)
        log "DEBUG" "libcamera-hello output: $output"
        if [[ -n "$output" ]]; then
            CAMERA_LIST_OUTPUT="$output"
        fi
    fi

    # If libcamera-hello didn't work, try rpicam-hello
    if [[ -z "${CAMERA_LIST_OUTPUT:-}" ]] && command -v rpicam-hello >/dev/null 2>&1; then
        log "DEBUG" "Trying rpicam-hello for camera detection"
        output=$(rpicam-hello --list-cameras 2>&1 || true)
        log "DEBUG" "rpicam-hello output: $output"
        if [[ -n "$output" ]]; then
            CAMERA_LIST_OUTPUT="$output"
        fi
    fi

    if [[ -z "${CAMERA_LIST_OUTPUT:-}" ]]; then
        log "ERROR" "No camera tools found or no camera list output returned"
        return 1
    fi

    # If no camera is detected, default to the auto-detect profile.
    if echo "$CAMERA_LIST_OUTPUT" | grep -qiE "$no_camera_patterns"; then
        if detect_owlcam_via_i2c; then
            log "INFO" "Switching to Owlcam manual profile (camera_auto_detect=0)."
            set_desired_owlcam_profile
            return 0
        fi

        log "WARN" "No camera detected. Falling back to auto-detect profile."
        set_desired_auto_profile
        return 0
    fi

    # Pattern matching for camera profiles
    if echo "$CAMERA_LIST_OUTPUT" | grep -qiE 'ov64a40|owlcam'; then
        log "INFO" "Detected: OV64A40 (Owlcam)"
        set_desired_owlcam_profile
    elif echo "$CAMERA_LIST_OUTPUT" | grep -qiE '^[[:space:]]*[0-9]+[[:space:]]*:'; then
        log "INFO" "Detected: camera enumerated by libcamera/rpicam; using auto-detect profile"
        set_desired_auto_profile
    elif echo "$CAMERA_LIST_OUTPUT" | grep -qiE 'imx708|imx708_noir|imx219|imx477|imx296|ov5647|ov9281|imx500|imx519|imx327|imx290|imx378|ov7251|ov9281|arducam|camera[[:space:]]*module[[:space:]]*3|module[[:space:]]*3[[:space:]]*noir'; then
        log "INFO" "Detected: supported non-Owlcam sensor; using auto-detect profile"
        set_desired_auto_profile
    else
        log "ERROR" "Unsupported or undetected camera"
        log "ERROR" "Camera detection output: $CAMERA_LIST_OUTPUT"
        return 1
    fi
    
    return 0
}

# Call detection function
CAMERA_LIST_OUTPUT=""
if ! detect_camera; then
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

# Seed defaults only if detection did not choose a profile.
if [[ -z "${DESIRED_BLOCK}" ]]; then
    set_desired_auto_profile
fi

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
    # Strip old camera directives so stale manual/legacy config cannot override managed output.
    /^[[:space:]]*camera_auto_detect[[:space:]]*=/ { next }
    /^[[:space:]]*dtoverlay=ov64a40([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=imx708([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=imx219([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=imx477([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=imx296([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=ov5647([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=ov9281([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=imx290([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=imx378([[:space:]]|,|$)/ { next }
    /^[[:space:]]*dtoverlay=cma([[:space:]]|,|$)/ { next }

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
