#!/usr/bin/env bash
set -euo pipefail

# Legacy script retained for backward compatibility.
# Active camera configuration flow is now manual via `antscam`.

STATE_DIR="/var/lib/antscihub-capture-config"
LOG_FILE="/var/log/antscihub-capture-config.log"
ATTEMPT_COUNT="${STATE_DIR}/attempt-count"
LOCK_FILE="${STATE_DIR}/apply.lock"
PROBE_STATE_FILE="${STATE_DIR}/dynamic-no-camera-probe-state"
LAST_DETECTED_FILE="${STATE_DIR}/last-detected-class"

MAX_ATTEMPTS=3
CAMERA_PROFILE_MODE_RAW="${CAMERA_PROFILE_MODE:-dynamic}"
CAMERA_PROFILE_MODE=""

BEGIN_MARKER="# antscihub-capture-config BEGIN"
END_MARKER="# antscihub-capture-config END"

CAMERA_LIST_OUTPUT=""
CAMERA_LIST_TOOL=""
CURRENT_BLOCK=""
CURRENT_PROFILE="unknown"
DESIRED_BLOCK=""
DESIRED_PROFILE="unknown"
MANUAL_CAMERA_OVERRIDE_PRESENT="false"

mkdir -p "$STATE_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

normalize_profile_mode() {
    local raw="$1"
    raw="$(echo "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    case "$raw" in
        dynamic|auto|owlcam|imx708)
            printf '%s\n' "$raw"
            ;;
        *)
            log "WARN" "Invalid CAMERA_PROFILE_MODE=${CAMERA_PROFILE_MODE_RAW}; defaulting to dynamic"
            printf '%s\n' "dynamic"
            ;;
    esac
}

set_desired_auto_profile() {
    DESIRED_PROFILE="auto"
    DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=1
EOF
)
}

set_desired_owlcam_profile() {
    DESIRED_PROFILE="owlcam"
    DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=0
dtoverlay=ov64a40,link-frequency=360000000
dtoverlay=cma,cma-256
EOF
)
}

set_desired_imx708_profile() {
    DESIRED_PROFILE="imx708"
    DESIRED_BLOCK=$(cat <<'EOF'
camera_auto_detect=0
dtoverlay=imx708
EOF
)
}

set_desired_passthrough_profile() {
    DESIRED_PROFILE="passthrough"
    DESIRED_BLOCK=""
}

get_current_managed_block() {
    awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        in_block { print }
    ' "${CONFIG_FILE}"
}

config_without_managed_block() {
    awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        !in_block { print }
    ' "${CONFIG_FILE}"
}

detect_manual_camera_override() {
    local manual_pattern
    manual_pattern='^[[:space:]]*dtoverlay=(ov5647|imx219|imx477|imx296|imx708|imx290|imx378|ov9281|imx327|imx519|arducam-64mp|ov64a40|tc358743|adv728x-m|irs1125)([[:space:]]|,|$)'

    if config_without_managed_block | grep -qiE '^[[:space:]]*camera_auto_detect[[:space:]]*=[[:space:]]*0([[:space:]]|$)'; then
        return 0
    fi
    if config_without_managed_block | grep -qiE "${manual_pattern}"; then
        return 0
    fi
    return 1
}

classify_block_profile() {
    local block="$1"
    if [[ -z "${block//[[:space:]]/}" ]]; then
        printf '%s\n' "passthrough"
        return
    fi
    if echo "$block" | grep -qE '^[[:space:]]*camera_auto_detect=0([[:space:]]|$)'; then
        printf '%s\n' "owlcam"
        return
    fi
    if echo "$block" | grep -qE '^[[:space:]]*camera_auto_detect=1([[:space:]]|$)'; then
        printf '%s\n' "auto"
        return
    fi
    printf '%s\n' "unknown"
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

detect_owlcam_via_i2c() {
    local bus raw normalized

    if ! command -v i2ctransfer >/dev/null 2>&1; then
        log "DEBUG" "i2ctransfer unavailable; skipping Owlcam I2C probe"
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

detect_camera_list_output() {
    local cmd output
    for cmd in rpicam-hello libcamera-hello rpicam-still libcamera-still; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            continue
        fi
        log "DEBUG" "Trying ${cmd} --list-cameras"
        output="$("$cmd" --list-cameras 2>&1 || true)"
        if [[ -n "$output" ]]; then
            CAMERA_LIST_OUTPUT="$output"
            CAMERA_LIST_TOOL="$cmd"
            log "DEBUG" "${cmd} output: ${output}"
            return 0
        fi
    done
    return 1
}

camera_list_class() {
    local output="$1"
    local no_camera_patterns='no cameras? available|no cameras? detected|camera not found|cannot find camera|failed to register camera'
    local owl_patterns='ov64a40|owlcam|owlsight|arducam[_ -]?64mp|64mp[^[:alnum:]]*(arducam|owl|ov64a40)|hawkeye'
    local enumerated_line_pattern='^[[:space:]]*[0-9]+[[:space:]]*:'

    if [[ -z "$output" ]]; then
        printf '%s\n' "none"
        return
    fi
    if echo "$output" | grep -qiE "$owl_patterns"; then
        printf '%s\n' "owlcam"
        return
    fi
    if echo "$output" | grep -qiE "$no_camera_patterns"; then
        printf '%s\n' "no_camera"
        return
    fi
    if echo "$output" | grep -qiE "$enumerated_line_pattern"; then
        printf '%s\n' "camera_present"
        return
    fi
    printf '%s\n' "unknown"
}

read_probe_state() {
    if [[ -f "$PROBE_STATE_FILE" ]]; then
        cat "$PROBE_STATE_FILE" 2>/dev/null || true
    fi
}

write_probe_state() {
    local state="$1"
    printf '%s\n' "$state" > "$PROBE_STATE_FILE"
}

clear_probe_state() {
    rm -f "$PROBE_STATE_FILE"
}

write_last_detected() {
    local classification="$1"
    printf '%s\n' "$classification" > "$LAST_DETECTED_FILE"
}

select_dynamic_profile() {
    local classification="$1"
    local probe_state
    probe_state="$(read_probe_state)"

    case "$classification" in
        owlcam)
            log "INFO" "Detected Owlcam from ${CAMERA_LIST_TOOL}; using manual Owlcam profile"
            clear_probe_state
            write_last_detected "owlcam"
            set_desired_owlcam_profile
            return 0
            ;;
        camera_present|unknown)
            if [[ "${MANUAL_CAMERA_OVERRIDE_PRESENT}" == "true" ]]; then
                log "INFO" "Detected camera with manual camera overrides present; preserving base config"
                clear_probe_state
                write_last_detected "camera_present_manual_override"
                set_desired_passthrough_profile
                return 0
            fi

            log "INFO" "Detected non-Owl camera from ${CAMERA_LIST_TOOL}; using auto-detect profile"
            clear_probe_state
            write_last_detected "camera_present"
            set_desired_auto_profile
            return 0
            ;;
        no_camera|none)
            if detect_owlcam_via_i2c; then
                log "INFO" "No camera enumerated, but Owlcam probe succeeded; using manual Owlcam profile"
                clear_probe_state
                write_last_detected "owlcam"
                set_desired_owlcam_profile
                return 0
            fi

            if [[ "${MANUAL_CAMERA_OVERRIDE_PRESENT}" == "true" ]]; then
                log "WARN" "No camera detected, but manual camera overrides exist; preserving base config"
                clear_probe_state
                write_last_detected "no_camera_manual_override"
                set_desired_passthrough_profile
                return 0
            fi

            # Dynamic no-camera fallback:
            # 1) If currently auto, probe Owlcam profile once.
            # 2) If that probe still yields no camera next boot, settle on auto profile.
            if [[ "$CURRENT_PROFILE" == "auto" ]]; then
                if [[ "$probe_state" == "no_camera_settled_auto" ]]; then
                    log "WARN" "No camera detected; staying on settled auto-detect profile"
                    write_last_detected "no_camera"
                    set_desired_auto_profile
                elif [[ "$probe_state" == "auto_to_owl_probe" ]]; then
                    log "WARN" "No camera detected with stale probe marker; settling on auto-detect profile"
                    write_probe_state "no_camera_settled_auto"
                    write_last_detected "no_camera"
                    set_desired_auto_profile
                else
                    log "WARN" "No camera detected in auto mode; probing Owlcam profile once"
                    write_probe_state "auto_to_owl_probe"
                    write_last_detected "no_camera"
                    set_desired_owlcam_profile
                fi
                return 0
            fi

            if [[ "$CURRENT_PROFILE" == "owlcam" ]]; then
                if [[ "$probe_state" == "auto_to_owl_probe" ]]; then
                    log "WARN" "No camera detected in Owlcam probe boot; switching back to auto-detect profile"
                    write_probe_state "no_camera_settled_auto"
                    write_last_detected "no_camera"
                    set_desired_auto_profile
                else
                    log "WARN" "No camera detected while in Owlcam profile; switching to auto-detect profile"
                    write_probe_state "no_camera_settled_auto"
                    write_last_detected "no_camera"
                    set_desired_auto_profile
                fi
                return 0
            fi

            log "WARN" "No camera detected; using auto-detect profile"
            clear_probe_state
            write_last_detected "no_camera"
            set_desired_auto_profile
            return 0
            ;;
    esac

    log "WARN" "Unhandled detection classification (${classification}); using auto-detect profile"
    clear_probe_state
    write_last_detected "unknown"
    set_desired_auto_profile
    return 0
}

apply_desired_by_mode() {
    local detected_class="$1"
    case "$CAMERA_PROFILE_MODE" in
        auto)
            log "INFO" "CAMERA_PROFILE_MODE=auto; forcing auto-detect profile"
            clear_probe_state
            write_last_detected "forced_auto"
            set_desired_auto_profile
            ;;
        owlcam)
            log "INFO" "CAMERA_PROFILE_MODE=owlcam; forcing manual Owlcam profile"
            clear_probe_state
            write_last_detected "forced_owlcam"
            set_desired_owlcam_profile
            ;;
        imx708)
            log "INFO" "CAMERA_PROFILE_MODE=imx708; forcing manual IMX708 profile"
            clear_probe_state
            write_last_detected "forced_imx708"
            set_desired_imx708_profile
            ;;
        dynamic)
            select_dynamic_profile "$detected_class"
            ;;
        *)
            log "WARN" "Unexpected profile mode ${CAMERA_PROFILE_MODE}; defaulting to auto profile"
            clear_probe_state
            write_last_detected "invalid_mode_fallback"
            set_desired_auto_profile
            ;;
    esac
}

remove_managed_block_only() {
    local src="$1"
    local dst="$2"
    awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
        $0 == begin { in_block = 1; next }
        $0 == end { in_block = 0; next }
        !in_block { print }
    ' "$src" > "$dst"
}

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "WARN" "Another instance is running. Exiting."
    exit 0
fi

log "INFO" "Camera config script started"

CAMERA_PROFILE_MODE="$(normalize_profile_mode "$CAMERA_PROFILE_MODE_RAW")"
log "INFO" "Camera profile mode: ${CAMERA_PROFILE_MODE}"

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

CURRENT_BLOCK="$(get_current_managed_block)"
CURRENT_PROFILE="$(classify_block_profile "$CURRENT_BLOCK")"
log "INFO" "Current managed profile: ${CURRENT_PROFILE}"

if detect_manual_camera_override; then
    MANUAL_CAMERA_OVERRIDE_PRESENT="true"
fi
log "INFO" "Manual camera override present: ${MANUAL_CAMERA_OVERRIDE_PRESENT}"

if detect_camera_list_output; then
    DETECTED_CLASS="$(camera_list_class "$CAMERA_LIST_OUTPUT")"
else
    DETECTED_CLASS="none"
    log "WARN" "No camera list tool output available; classification=none"
fi
log "INFO" "Detected class: ${DETECTED_CLASS}"

apply_desired_by_mode "$DETECTED_CLASS"

if [[ "${DESIRED_PROFILE}" == "unknown" ]]; then
    set_desired_auto_profile
fi

if [[ "${CURRENT_BLOCK}" == "${DESIRED_BLOCK}" ]]; then
    log "INFO" "Already configured for ${DESIRED_PROFILE}. No changes needed."
    rm -f "$ATTEMPT_COUNT"
    exit 0
fi

attempt_count=0
if [[ -f "$ATTEMPT_COUNT" ]]; then
    attempt_count="$(cat "$ATTEMPT_COUNT" 2>/dev/null || echo 0)"
fi
attempt_count=$((attempt_count + 1))

if [[ $attempt_count -gt $MAX_ATTEMPTS ]]; then
    log "ERROR" "Max reboot attempts (${MAX_ATTEMPTS}) exceeded while applying ${DESIRED_PROFILE} profile"
    log "ERROR" "Manual intervention required. Check camera wiring and ${CONFIG_FILE}."
    exit 1
fi

log "INFO" "Attempt ${attempt_count}/${MAX_ATTEMPTS} to apply ${DESIRED_PROFILE} profile"

BACKUP_FILE="${CONFIG_FILE}.antscihub.bak.$(date +%Y%m%d-%H%M%S)"
cp "${CONFIG_FILE}" "${BACKUP_FILE}"
log "INFO" "Backup saved to ${BACKUP_FILE}"

TMP_FILE="$(mktemp)"
trap 'rm -f "${TMP_FILE}"' EXIT

remove_managed_block_only "${CONFIG_FILE}" "${TMP_FILE}"

if [[ -n "${DESIRED_BLOCK}" ]]; then
    {
        printf '%s\n' "${BEGIN_MARKER}"
        printf '%s\n' "${DESIRED_BLOCK}"
        printf '%s\n' "${END_MARKER}"
    } >> "${TMP_FILE}"
fi

install -m 0644 "${TMP_FILE}" "${CONFIG_FILE}"
sync

echo "${attempt_count}" > "$ATTEMPT_COUNT"

log "INFO" "Applied ${DESIRED_PROFILE} settings to ${CONFIG_FILE}"
log "INFO" "Rebooting to apply firmware changes (attempt ${attempt_count}/${MAX_ATTEMPTS})"
systemctl reboot --no-block
