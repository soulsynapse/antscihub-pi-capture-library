#!/usr/bin/env bash
set -euo pipefail

resolve_desktop_dir() {
    local desktop_dir=""

    if command -v xdg-user-dir >/dev/null 2>&1; then
        desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi

    # xdg-user-dir may fall back to HOME. In that case, prefer explicit desktop paths.
    if [[ -z "$desktop_dir" || "$desktop_dir" == "$HOME" ]]; then
        local user_dirs_file="${XDG_CONFIG_HOME:-${HOME}/.config}/user-dirs.dirs"
        if [[ -f "$user_dirs_file" ]]; then
            # shellcheck disable=SC1090
            . "$user_dirs_file"
            desktop_dir="${XDG_DESKTOP_DIR:-}"
            desktop_dir="${desktop_dir/#\$HOME/$HOME}"
        fi
    fi

    if [[ -z "$desktop_dir" || "$desktop_dir" == "$HOME" ]]; then
        if [[ -d "${HOME}/Desktop" ]]; then
            desktop_dir="${HOME}/Desktop"
        elif [[ -d "${HOME}/desktop" ]]; then
            desktop_dir="${HOME}/desktop"
        else
            desktop_dir="${HOME}/Desktop"
        fi
    fi

    printf '%s' "$desktop_dir"
}

resolve_upload_dir() {
    if [[ -n "${UPLOAD_DIR:-}" ]]; then
        printf '%s' "${UPLOAD_DIR%/}"
        return 0
    fi

    local desktop_dir
    desktop_dir="$(resolve_desktop_dir)"
    printf '%s/5-UPLOAD' "${desktop_dir%/}"
}

# Source directory watched for newly recorded files.
UPLOAD_DIR="$(resolve_upload_dir)"

# Prefer systemd-provided directories when available; otherwise use user-writable defaults.
STATE_DIR="${STATE_DIRECTORY:-${XDG_STATE_HOME:-${HOME}/.local/state}/antscihub-upload}"
LOG_DIR="${LOGS_DIRECTORY:-${XDG_STATE_HOME:-${HOME}/.local/state}/antscihub-upload}"
RUNTIME_DIR="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/tmp}}"

# If a systemd directory env var contains multiple paths, use the first one.
STATE_DIR="${STATE_DIR%%:*}"
LOG_DIR="${LOG_DIR%%:*}"
RUNTIME_DIR="${RUNTIME_DIR%%:*}"

STATE_FILE="${STATE_DIR}/processed.txt"
FAILED_DIR="${STATE_DIR}/failed"
RETRY_SCHEDULE_DIR="${STATE_DIR}/next-retry"
LOG_FILE="${LOG_DIR}/antscihub-upload.log"
LOCK_FILE="${RUNTIME_DIR}/antscihub-upload.lock"

RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_PATH="${RCLONE_PATH:-}"
RCLONE_PATH="${RCLONE_PATH#/}"
RCLONE_PATH="${RCLONE_PATH%/}"
if [[ "${RCLONE_PATH}" == "." ]]; then
    RCLONE_PATH=""
fi

sanitize_machine_suffix() {
    local raw="$1"
    local normalized
    normalized="${raw//[^[:alnum:]._-]/_}"
    normalized="${normalized//__/_}"
    normalized="${normalized##_}"
    normalized="${normalized%%_}"
    if [[ -z "$normalized" ]]; then
        normalized="unknown-machine"
    fi
    printf '%s' "$normalized"
}

detect_machine_suffix() {
    if [[ -n "${MACHINE_SUFFIX:-}" ]]; then
        sanitize_machine_suffix "${MACHINE_SUFFIX}"
        return 0
    fi

    local raw=""
    raw="$(hostname 2>/dev/null || true)"
    if [[ -z "$raw" && -f /etc/hostname ]]; then
        raw="$(head -n 1 /etc/hostname 2>/dev/null || true)"
    fi
    if [[ -z "$raw" && -f /etc/machine-id ]]; then
        raw="$(head -n 1 /etc/machine-id 2>/dev/null || true)"
    fi
    sanitize_machine_suffix "$raw"
}

MACHINE_SUFFIX="$(detect_machine_suffix)"

FLEET_SCHEMA="fleet.service-manager.v1"
UPLOAD_SERVICE_NAME="${UPLOAD_SERVICE_NAME:-antscihub-upload.service}"
FLEET_PUBLISH_BIN="${FLEET_PUBLISH_BIN:-fleet-publish}"
MQTT_REPORT_BIN="${MQTT_REPORT_BIN:-mqtt_report.py}"
MQTT_EVENT_ENABLED="${MQTT_EVENT_ENABLED:-true}"
DEVICE_ID_CACHE=""
DEVICE_ID_CACHE_READY="false"
FLEET_PUBLISH_MODE=""
FLEET_PUBLISH_SHORT_PAYLOAD_FLAG="-m"
DEVICE_ID_WARNING_EMITTED="false"
MQTT_PUBLISH_WARNING_EMITTED="false"
declare -A SEEN_FILE_DETECTIONS=()

# Tuning
MIN_FILE_AGE_DEFAULT=30                      # Default wait before upload (seconds)
MIN_FILE_AGE_STILL_IMAGE=3                   # Faster path for still images (seconds)
FILE_STABILITY_CHECK_INTERVAL_DEFAULT=10     # Default size-stability window (seconds)
FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE=3  # Faster stability window for still images
MAX_RETRIES=5                                # Max retry attempts per file
SCAN_INTERVAL=10                             # Scan for new files every 10 seconds

if [[ -z "${RCLONE_REMOTE}" ]]; then
    echo "[upload-worker] Error: RCLONE_REMOTE must be set" >&2
    exit 1
fi

log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

json_escape() {
    local input="${1:-}"
    input="${input//\\/\\\\}"
    input="${input//\"/\\\"}"
    input="${input//$'\n'/\\n}"
    input="${input//$'\r'/\\r}"
    input="${input//$'\t'/\\t}"
    printf '%s' "${input}"
}

normalize_device_id() {
    local input="${1:-}"
    input="${input//$'\r'/}"
    input="${input//$'\n'/}"
    input="${input//$'\t'/}"
    input="${input// /}"
    printf '%s' "${input}"
}

detect_fleet_publish_mode() {
    if [[ -n "${FLEET_PUBLISH_MODE}" ]]; then
        return 0
    fi

    if ! command -v "${FLEET_PUBLISH_BIN}" >/dev/null 2>&1; then
        FLEET_PUBLISH_MODE="unavailable"
        return 1
    fi

    local help_output=""
    help_output="$("${FLEET_PUBLISH_BIN}" --help 2>&1 || true)"

    if grep -q -- '--topic' <<<"${help_output}" && grep -q -- '--payload' <<<"${help_output}"; then
        FLEET_PUBLISH_MODE="long_topic_payload"
    elif grep -q -- '--topic' <<<"${help_output}" && grep -q -- '--message' <<<"${help_output}"; then
        FLEET_PUBLISH_MODE="long_topic_message"
    elif grep -Eq -- '(^|[[:space:],])-t([[:space:],]|$)' <<<"${help_output}" && grep -Eq -- '(^|[[:space:],])-(m|p)([[:space:],]|$)' <<<"${help_output}"; then
        if grep -Eq -- '(^|[[:space:],])-m([[:space:],]|$)' <<<"${help_output}"; then
            FLEET_PUBLISH_SHORT_PAYLOAD_FLAG="-m"
        else
            FLEET_PUBLISH_SHORT_PAYLOAD_FLAG="-p"
        fi
        FLEET_PUBLISH_MODE="short_topic_message"
    else
        FLEET_PUBLISH_MODE="positional"
    fi
}

resolve_device_id() {
    if [[ "${DEVICE_ID_CACHE_READY}" == "true" ]]; then
        printf '%s' "${DEVICE_ID_CACHE}"
        return 0
    fi

    local candidate=""
    if [[ -n "${DEVICE_ID:-}" ]]; then
        candidate="$(normalize_device_id "${DEVICE_ID}")"
    elif [[ -n "${FLEET_DEVICE_ID:-}" ]]; then
        candidate="$(normalize_device_id "${FLEET_DEVICE_ID}")"
    fi

    if [[ -z "${candidate}" ]] && command -v "${FLEET_PUBLISH_BIN}" >/dev/null 2>&1; then
        candidate="$("${FLEET_PUBLISH_BIN}" --device-id 2>/dev/null | head -n 1 || true)"
        candidate="$(normalize_device_id "${candidate}")"
        if [[ "${candidate}" == *=* ]]; then
            candidate="${candidate##*=}"
            candidate="$(normalize_device_id "${candidate}")"
        fi

        if [[ -z "${candidate}" ]]; then
            candidate="$("${FLEET_PUBLISH_BIN}" device-id 2>/dev/null | head -n 1 || true)"
            candidate="$(normalize_device_id "${candidate}")"
            if [[ "${candidate}" == *=* ]]; then
                candidate="${candidate##*=}"
                candidate="$(normalize_device_id "${candidate}")"
            fi
        fi
    fi

    if [[ -z "${candidate}" ]]; then
        local file_candidate
        for file_candidate in \
            "/etc/fleet/device_id" \
            "/var/lib/fleet/device_id" \
            "${XDG_CONFIG_HOME:-${HOME}/.config}/fleet/device_id" \
            "/etc/antscihub/device_id"; do
            if [[ -f "${file_candidate}" ]]; then
                candidate="$(head -n 1 "${file_candidate}" 2>/dev/null || true)"
                candidate="$(normalize_device_id "${candidate}")"
                [[ -n "${candidate}" ]] && break
            fi
        done
    fi

    if [[ -z "${candidate}" ]]; then
        candidate="${MACHINE_SUFFIX}"
        if [[ "${DEVICE_ID_WARNING_EMITTED}" != "true" ]]; then
            log "WARN" "Device ID not found from fleet client; falling back to MACHINE_SUFFIX=${MACHINE_SUFFIX}"
            DEVICE_ID_WARNING_EMITTED="true"
        fi
    fi

    DEVICE_ID_CACHE="${candidate}"
    DEVICE_ID_CACHE_READY="true"
    printf '%s' "${DEVICE_ID_CACHE}"
}

publish_with_fleet_publish() {
    local topic="$1"
    local payload="$2"

    detect_fleet_publish_mode || return 1
    case "${FLEET_PUBLISH_MODE}" in
        long_topic_payload)
            "${FLEET_PUBLISH_BIN}" --topic "${topic}" --payload "${payload}" >/dev/null 2>&1
            ;;
        long_topic_message)
            "${FLEET_PUBLISH_BIN}" --topic "${topic}" --message "${payload}" >/dev/null 2>&1
            ;;
        short_topic_message)
            "${FLEET_PUBLISH_BIN}" -t "${topic}" "${FLEET_PUBLISH_SHORT_PAYLOAD_FLAG}" "${payload}" >/dev/null 2>&1
            ;;
        positional)
            "${FLEET_PUBLISH_BIN}" "${topic}" "${payload}" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

publish_with_fleet_mqtt_python() {
    local topic="$1"
    local payload="$2"

    command -v python3 >/dev/null 2>&1 || return 1

    python3 - "${topic}" "${payload}" >/dev/null 2>&1 <<'PY'
import json
import sys

topic = sys.argv[1]
payload_raw = sys.argv[2]

try:
    payload_obj = json.loads(payload_raw)
except Exception:
    payload_obj = payload_raw

try:
    from mqtt_client import FleetMQTT
except Exception:
    sys.exit(2)

client = None
for ctor in (lambda: FleetMQTT(), lambda: FleetMQTT("antscihub-upload")):
    try:
        client = ctor()
        break
    except Exception:
        continue

if client is None:
    sys.exit(3)

published = False
for method_name in ("publish_json", "publish", "send"):
    method = getattr(client, method_name, None)
    if not callable(method):
        continue
    try:
        if method_name == "publish_json":
            if isinstance(payload_obj, str):
                method(topic, json.loads(payload_obj))
            else:
                method(topic, payload_obj)
        else:
            try:
                method(topic, payload_obj)
            except TypeError:
                method(topic, payload_raw)
        published = True
        break
    except Exception:
        continue

for close_name in ("close", "disconnect", "stop"):
    close_method = getattr(client, close_name, None)
    if callable(close_method):
        try:
            close_method()
        except Exception:
            pass

sys.exit(0 if published else 4)
PY
}

publish_with_mqtt_report_cli() {
    local topic="$1"
    local payload="$2"

    if ! command -v "${MQTT_REPORT_BIN}" >/dev/null 2>&1; then
        return 1
    fi

    "${MQTT_REPORT_BIN}" --topic "${topic}" --json "${payload}" >/dev/null 2>&1
}

upload_status_to_event_name() {
    local status="$1"
    case "${status}" in
        start)
            printf '%s' "upload_start"
            ;;
        success)
            printf '%s' "upload_success"
            ;;
        failed)
            printf '%s' "upload_failed"
            ;;
        retry)
            printf '%s' "upload_retry_scheduled"
            ;;
        gave_up)
            printf '%s' "upload_gave_up"
            ;;
        *)
            printf '%s' "upload_status"
            ;;
    esac
}

upload_status_to_severity() {
    local status="$1"
    case "${status}" in
        start)
            printf '%s' "ROUTINE"
            ;;
        success)
            printf '%s' "INFO"
            ;;
        retry)
            printf '%s' "WARNING"
            ;;
        failed|gave_up)
            printf '%s' "ERROR"
            ;;
        *)
            printf '%s' "INFO"
            ;;
    esac
}

upload_status_to_success() {
    local status="$1"
    case "${status}" in
        success|start)
            printf '%s' "true"
            ;;
        *)
            printf '%s' "false"
            ;;
    esac
}

publish_upload_mqtt_event() {
    local status="$1"
    local relative_path="$2"
    local remote_target="$3"
    local size_bytes="$4"
    local attempt="${5:-}"
    local reason="${6:-}"
    local exit_code="${7:-}"

    if [[ "${MQTT_EVENT_ENABLED,,}" != "true" ]]; then
        return 0
    fi

    local device_id
    device_id="$(resolve_device_id)"
    if [[ -z "${device_id}" ]]; then
        if [[ "${MQTT_PUBLISH_WARNING_EMITTED}" != "true" ]]; then
            log "WARN" "Skipping MQTT upload event publish: no device_id available"
            MQTT_PUBLISH_WARNING_EMITTED="true"
        fi
        return 1
    fi

    local event_name severity success_bool
    event_name="$(upload_status_to_event_name "${status}")"
    severity="$(upload_status_to_severity "${status}")"
    success_bool="$(upload_status_to_success "${status}")"

    local message="Upload event: ${status}"
    case "${status}" in
        start)
            message="Upload started"
            ;;
        success)
            message="Upload completed"
            ;;
        failed)
            message="Upload failed"
            ;;
        retry)
            message="Upload retry scheduled"
            ;;
        gave_up)
            message="Upload retries exhausted"
            ;;
    esac

    local timestamp topic folder
    timestamp="$(date +%s)"
    topic="fleet/response/${device_id}"
    folder="."
    if [[ "${relative_path}" == */* ]]; then
        folder="${relative_path%/*}"
    fi

    local -a pairs=()
    pairs+=("\"schema\":\"$(json_escape "${FLEET_SCHEMA}")\"")
    pairs+=("\"event\":\"$(json_escape "${event_name}")\"")
    pairs+=("\"device_id\":\"$(json_escape "${device_id}")\"")
    pairs+=("\"timestamp\":${timestamp}")
    pairs+=("\"service\":\"$(json_escape "${UPLOAD_SERVICE_NAME}")\"")
    pairs+=("\"success\":${success_bool}")
    pairs+=("\"severity\":\"$(json_escape "${severity}")\"")
    pairs+=("\"message\":\"$(json_escape "${message}")\"")
    pairs+=("\"folder\":\"$(json_escape "${folder}")\"")
    pairs+=("\"file\":\"$(json_escape "${relative_path}")\"")
    pairs+=("\"cmd\":\"$(json_escape "rclone moveto")\"")
    if [[ -n "${remote_target}" ]]; then
        pairs+=("\"remote\":\"$(json_escape "${remote_target}")\"")
    fi
    if [[ -n "${size_bytes}" ]]; then
        pairs+=("\"size_bytes\":\"$(json_escape "${size_bytes}")\"")
    fi
    if [[ -n "${attempt}" ]]; then
        pairs+=("\"attempt\":\"$(json_escape "${attempt}")\"")
    fi
    if [[ -n "${reason}" ]]; then
        pairs+=("\"reason\":\"$(json_escape "${reason}")\"")
    fi
    if [[ -n "${exit_code}" ]]; then
        pairs+=("\"exit_code\":\"$(json_escape "${exit_code}")\"")
    fi

    local payload="{"
    local pair
    local first="true"
    for pair in "${pairs[@]}"; do
        if [[ "${first}" == "true" ]]; then
            payload+="${pair}"
            first="false"
        else
            payload+=",${pair}"
        fi
    done
    payload+="}"

    if publish_with_fleet_publish "${topic}" "${payload}"; then
        return 0
    fi

    if publish_with_mqtt_report_cli "${topic}" "${payload}"; then
        return 0
    fi

    if publish_with_fleet_mqtt_python "${topic}" "${payload}"; then
        return 0
    fi

    if [[ "${MQTT_PUBLISH_WARNING_EMITTED}" != "true" ]]; then
        log "WARN" "Unable to publish upload events to MQTT. Tried ${FLEET_PUBLISH_BIN}, ${MQTT_REPORT_BIN}, and python mqtt_client.FleetMQTT."
        MQTT_PUBLISH_WARNING_EMITTED="true"
    fi
    return 1
}

emit_upload_event() {
    local status="$1"
    local relative_path="$2"
    local remote_target="$3"
    local size_bytes="${4:-unknown}"
    local attempt="${5:-}"
    local reason="${6:-}"
    local exit_code="${7:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Explicit stdout event line for orchestrators that tail process output.
    printf 'UPLOAD_EVENT status=%s ts=%s file=%q remote=%q size_bytes=%s\n' \
        "$status" "$ts" "$relative_path" "$remote_target" "$size_bytes"
    publish_upload_mqtt_event "${status}" "${relative_path}" "${remote_target}" "${size_bytes}" "${attempt}" "${reason}" "${exit_code}" || true
}

# Ensure directories exist
mkdir -p "$STATE_DIR"
mkdir -p "$FAILED_DIR"
mkdir -p "$RETRY_SCHEDULE_DIR"
mkdir -p "$LOG_DIR"
mkdir -p "$RUNTIME_DIR"
mkdir -p "${UPLOAD_DIR}"

# Acquire process lock
acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log "ERROR" "Another upload worker instance is running. Exiting."
        exit 1
    fi
    trap 'rm -f "$LOCK_FILE"' EXIT
    echo $$ > "$LOCK_FILE"
}

hash_text() {
    local input="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$input" | shasum -a 256 | awk '{print $1}'
    else
        printf '%s' "$input" | cksum | awk '{print $1}'
    fi
}

# Build a stable identity for the current file instance.
make_file_identity() {
    local file="$1"
    local relative_path="$2"
    local stat_fields
    stat_fields=$(stat -c '%i:%s:%Y' "$file" 2>/dev/null || echo "0:0:0")
    printf '%s|%s' "$relative_path" "$stat_fields"
}

# Build a per-file-instance detection key (stable while file is being written).
make_file_detection_key() {
    local file="$1"
    local relative_path="$2"
    local inode
    inode=$(stat -c %i "$file" 2>/dev/null || echo 0)
    printf '%s|%s' "$relative_path" "$inode"
}

log_file_detected_once() {
    local file="$1"
    local relative_path="$2"
    local detection_key
    local file_size

    detection_key="$(make_file_detection_key "$file" "$relative_path")"
    if [[ -n "${SEEN_FILE_DETECTIONS["$detection_key"]+x}" ]]; then
        return 0
    fi

    file_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    log "INFO" "Detected file: ${relative_path} (size=${file_size} bytes)"
    SEEN_FILE_DETECTIONS["$detection_key"]="1"
}

retry_count_file() {
    local file_key="$1"
    printf '%s/%s.retries' "$FAILED_DIR" "$file_key"
}

next_retry_file() {
    local file_key="$1"
    printf '%s/%s.next' "$RETRY_SCHEDULE_DIR" "$file_key"
}

# Atomic state write
add_processed_file() {
    local file_identity="$1"
    local tmpfile
    tmpfile=$(mktemp)
    {
        cat "$STATE_FILE" 2>/dev/null || true
        echo "$file_identity"
    } | sort -u > "$tmpfile"
    mv "$tmpfile" "$STATE_FILE"
}

# Check if file is already processed
is_processed() {
    local file_identity="$1"
    [[ -f "$STATE_FILE" ]] && grep -Fxq "$file_identity" "$STATE_FILE" && return 0
    return 1
}

# Check if file has exceeded max retries
exceeds_retry_limit() {
    local file_key="$1"
    local retry_file
    retry_file=$(retry_count_file "$file_key")
    if [[ ! -f "$retry_file" ]]; then
        return 1
    fi
    local count
    count=$(cat "$retry_file" 2>/dev/null || echo 0)
    [[ $count -ge $MAX_RETRIES ]]
}

# Increment retry count and return the new count
increment_retry_count() {
    local file_key="$1"
    local retry_file
    retry_file=$(retry_count_file "$file_key")
    local count
    count=$(cat "$retry_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    echo "$count" > "$retry_file"
    echo "$count"
}

schedule_next_retry() {
    local file_key="$1"
    local delay_seconds="$2"
    local next_file
    next_file=$(next_retry_file "$file_key")
    echo $(( $(date +%s) + delay_seconds )) > "$next_file"
}

is_in_backoff_window() {
    local file_key="$1"
    local next_file
    next_file=$(next_retry_file "$file_key")
    [[ ! -f "$next_file" ]] && return 1

    local next_retry_epoch
    local now
    next_retry_epoch=$(cat "$next_file" 2>/dev/null || echo 0)
    now=$(date +%s)

    if [[ "$next_retry_epoch" -le "$now" ]]; then
        rm -f "$next_file"
        return 1
    fi

    return 0
}

clear_retry_state() {
    local file_key="$1"
    rm -f "$(retry_count_file "$file_key")" "$(next_retry_file "$file_key")"
}

# Validation: uploadable file (not reference/hidden/temp)
is_uploadable() {
    local basename="$1"
    # Skip .MOVED reference files (from previous successful uploads)
    [[ "${basename}" =~ \.MOVED$ ]] && return 1
    # Skip hidden files (. prefix)
    [[ "${basename}" =~ ^\. ]] && return 1
    # Skip temp files (~ prefix)
    [[ "${basename}" =~ ^~ ]] && return 1
    # Accept everything else (videos, text files, documents, etc.)
    return 0
}

is_still_image() {
    local basename="$1"
    local lower_basename="${basename,,}"
    case "${lower_basename}" in
        *.jpg|*.jpeg|*.png|*.tif|*.tiff|*.bmp|*.gif|*.webp|*.heic|*.heif|*.dng|*.cr2|*.cr3|*.nef|*.arw|*.orf|*.rw2|*.raf)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

required_min_age_for_file() {
    local basename="$1"
    if is_still_image "${basename}"; then
        echo "$MIN_FILE_AGE_STILL_IMAGE"
    else
        echo "$MIN_FILE_AGE_DEFAULT"
    fi
}

stability_interval_for_file() {
    local basename="$1"
    if is_still_image "${basename}"; then
        echo "$FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE"
    else
        echo "$FILE_STABILITY_CHECK_INTERVAL_DEFAULT"
    fi
}

# Validation: file stability (size hasn't changed)
is_file_stable() {
    local file="$1"
    local stability_interval="$2"
    local initial_size
    local final_size

    initial_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    sleep "$stability_interval"

    if [[ ! -f "$file" ]]; then
        return 1  # File was deleted
    fi

    final_size=$(stat -c %s "$file" 2>/dev/null || echo 0)

    [[ "$initial_size" -eq "$final_size" ]]
}

build_remote_target() {
    local relative_path="$1"
    if [[ -n "${RCLONE_PATH}" ]]; then
        printf '%s:%s/%s' "${RCLONE_REMOTE}" "${RCLONE_PATH}" "${relative_path}"
    else
        printf '%s:%s' "${RCLONE_REMOTE}" "${relative_path}"
    fi
}

remote_path_exists() {
    local remote_target="$1"
    local listing
    listing="$(rclone lsf --files-only --max-depth 1 "$remote_target" 2>/dev/null || true)"
    [[ -n "${listing//[[:space:]]/}" ]]
}

build_conflict_relative_path() {
    local relative_path="$1"
    local attempt="$2"
    local dir_part=""
    local file_part="$relative_path"
    local stem="$file_part"
    local ext=""
    local suffix="__${MACHINE_SUFFIX}"

    if (( attempt > 1 )); then
        suffix="${suffix}-${attempt}"
    fi

    if [[ "$relative_path" == */* ]]; then
        dir_part="${relative_path%/*}"
        file_part="${relative_path##*/}"
    fi

    stem="$file_part"
    if [[ "$file_part" == *.* && "$file_part" != .* ]]; then
        stem="${file_part%.*}"
        ext=".${file_part##*.}"
    fi

    if [[ -n "$dir_part" ]]; then
        printf '%s/%s%s%s' "$dir_part" "$stem" "$suffix" "$ext"
    else
        printf '%s%s%s' "$stem" "$suffix" "$ext"
    fi
}

resolve_remote_target() {
    local relative_path="$1"
    local selected_relative="$relative_path"
    local selected_target
    selected_target="$(build_remote_target "$selected_relative")"

    if ! remote_path_exists "$selected_target"; then
        printf '%s|%s' "$selected_relative" "$selected_target"
        return 0
    fi

    local attempt=1
    while true; do
        selected_relative="$(build_conflict_relative_path "$relative_path" "$attempt")"
        selected_target="$(build_remote_target "$selected_relative")"
        if ! remote_path_exists "$selected_target"; then
            printf '%s|%s' "$selected_relative" "$selected_target"
            return 0
        fi
        attempt=$((attempt + 1))
        if (( attempt > 50 )); then
            # Extremely unlikely fallback
            selected_relative="$(build_conflict_relative_path "${relative_path}" "${attempt}")"
            selected_relative="${selected_relative}.$(date +%s)"
            selected_target="$(build_remote_target "$selected_relative")"
            printf '%s|%s' "$selected_relative" "$selected_target"
            return 0
        fi
    done
}

# Exponential backoff for retries
calculate_backoff() {
    local attempt="$1"
    local base_delay=30
    local max_delay=600  # 10 minutes

    local delay=$((base_delay * (2 ** (attempt - 1))))
    if [[ $delay -gt $max_delay ]]; then
        delay=$max_delay
    fi
    echo $delay
}

# Main upload function
do_upload() {
    local file="$1"
    local relative_path="$2"
    local file_identity="$3"
    local file_key="$4"
    local basename
    local selected_relative_path
    local selection
    local remote_target
    local file_size
    local file_mtime
    basename=$(basename "$file")
    selection="$(resolve_remote_target "$relative_path")"
    selected_relative_path="${selection%%|*}"
    remote_target="${selection#*|}"
    file_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    file_mtime=$(stat -c %y "$file" 2>/dev/null || echo "unknown")

    if [[ "$selected_relative_path" != "$relative_path" ]]; then
        log "WARN" "Remote conflict detected for ${relative_path}"
        log "INFO" "Renaming remote upload target: ${relative_path} -> ${selected_relative_path}"
    fi

    log "INFO" "Starting upload: ${relative_path}"
    emit_upload_event "start" "${relative_path}" "${remote_target}" "${file_size}"

    # Move this single file to its exact remote path to preserve folder structure.
    local rclone_exit_code=0
    if rclone moveto "$file" "$remote_target" \
        --immutable \
        --progress --stats=0 2>&1 | tee -a "$LOG_FILE"; then

        log "INFO" "Upload successful: ${relative_path}"
        emit_upload_event "success" "${relative_path}" "${remote_target}" "${file_size}"

        # Create reference file (atomically)
        local remote_link="${file}.MOVED"
        local tmpref
        tmpref=$(mktemp)
        cat > "$tmpref" <<EOF
# File moved to remote storage
# Original file: ${relative_path}
# Final remote relative path: ${selected_relative_path}
# Moved to: ${remote_target}
# Size bytes: ${file_size}
# Source mtime: ${file_mtime}
# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
        mv "$tmpref" "$remote_link"
        log "INFO" "Created reference: $remote_link"

        # Mark as processed and clear retry metadata
        add_processed_file "$file_identity"
        clear_retry_state "$file_key"

        return 0
    else
        rclone_exit_code="${PIPESTATUS[0]:-1}"
        log "ERROR" "Upload failed: ${relative_path}"
        emit_upload_event "failed" "${relative_path}" "${remote_target}" "${file_size}" "" "rclone_failed" "${rclone_exit_code}"
        return 1
    fi
}

acquire_lock

log "INFO" "Upload worker starting"
log "INFO" "Watching: $UPLOAD_DIR"
if [[ -n "${RCLONE_PATH}" ]]; then
    log "INFO" "Remote: ${RCLONE_REMOTE}:${RCLONE_PATH}"
else
    log "INFO" "Remote: ${RCLONE_REMOTE}: (root)"
fi
log "INFO" "Machine suffix for conflict handling: ${MACHINE_SUFFIX}"
log "INFO" "State dir: $STATE_DIR"
log "INFO" "Log file: $LOG_FILE"

while true; do
    # Scan for new files
    if [[ ! -d "${UPLOAD_DIR}" ]]; then
        sleep "$SCAN_INTERVAL"
        continue
    fi

    while IFS= read -r -d '' file; do
        relative_path="${file#${UPLOAD_DIR}/}"
        if [[ "$relative_path" == "$file" ]]; then
            relative_path="$(basename "$file")"
        fi

        basename=$(basename "$file")

        # Validation: uploadable (not .MOVED reference file, not hidden, not temp)
        if ! is_uploadable "$basename"; then
            log "DEBUG" "Skipping (reference file or temp): $basename"
            continue
        fi

        log_file_detected_once "$file" "$relative_path"

        # Validation: file age (avoid uploading files still being written)
        mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - mtime))

        required_min_age=$(required_min_age_for_file "$basename")
        if [[ $age -lt $required_min_age ]]; then
            log "DEBUG" "File too new ($age < $required_min_age): $basename"
            continue
        fi

        # Validation: file stability
        stability_interval=$(stability_interval_for_file "$basename")
        log "DEBUG" "Checking stability (${stability_interval}s): $basename"
        if ! is_file_stable "$file" "$stability_interval"; then
            log "DEBUG" "File not stable (still being written): $basename"
            continue
        fi

        file_identity=$(make_file_identity "$file" "$relative_path")
        file_key=$(hash_text "$file_identity")

        # Skip if this specific file instance is already processed
        if is_processed "$file_identity"; then
            continue
        fi

        # Skip if exceeds retry limit
        if exceeds_retry_limit "$file_key"; then
            log "WARN" "Exceeded max retries ($MAX_RETRIES) for: $basename"
            emit_upload_event "gave_up" "${relative_path}" "" "unknown" "${MAX_RETRIES}" "max_retries_exceeded" ""
            continue
        fi

        # Skip until retry backoff window expires
        if is_in_backoff_window "$file_key"; then
            continue
        fi

        # File is ready to upload
        if do_upload "$file" "$relative_path" "$file_identity" "$file_key"; then
            :
        else
            current_retries=$(increment_retry_count "$file_key")

            if [[ $current_retries -lt $MAX_RETRIES ]]; then
                backoff=$(calculate_backoff "$current_retries")
                schedule_next_retry "$file_key" "$backoff"
                log "WARN" "Retry scheduled for ${relative_path}: attempt ${current_retries}/${MAX_RETRIES} (backoff: ${backoff}s)"
                emit_upload_event "retry" "${relative_path}" "" "unknown" "${current_retries}" "retry_backoff_${backoff}s" ""
            fi
        fi
    done < <(find "$UPLOAD_DIR" -type f -print0 2>/dev/null)

    sleep "$SCAN_INTERVAL"
done
