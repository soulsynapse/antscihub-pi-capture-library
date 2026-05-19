#!/usr/bin/env bash
set -euo pipefail

resolve_desktop_dir() {
    local desktop_dir=""

    if command -v xdg-user-dir >/dev/null 2>&1; then
        desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    fi

    if [[ -z "${desktop_dir}" || "${desktop_dir}" == "${HOME}" ]]; then
        local user_dirs_file="${XDG_CONFIG_HOME:-${HOME}/.config}/user-dirs.dirs"
        if [[ -f "${user_dirs_file}" ]]; then
            # shellcheck disable=SC1090
            . "${user_dirs_file}"
            desktop_dir="${XDG_DESKTOP_DIR:-}"
            desktop_dir="${desktop_dir/#\$HOME/${HOME}}"
        fi
    fi

    if [[ -z "${desktop_dir}" || "${desktop_dir}" == "${HOME}" ]]; then
        if [[ -d "${HOME}/Desktop" ]]; then
            desktop_dir="${HOME}/Desktop"
        elif [[ -d "${HOME}/desktop" ]]; then
            desktop_dir="${HOME}/desktop"
        else
            desktop_dir="${HOME}/Desktop"
        fi
    fi

    printf '%s' "${desktop_dir}"
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

resolve_upload_config_dir() {
    if [[ -n "${UPLOAD_CONFIG_DIR:-}" ]]; then
        printf '%s' "${UPLOAD_CONFIG_DIR%/}"
        return 0
    fi

    local upload_parent
    upload_parent="$(dirname "${UPLOAD_DIR}")"
    printf '%s/4-CAPTURE/config' "${upload_parent%/}"
}

UPLOAD_DIR="$(resolve_upload_dir)"
UPLOAD_CONFIG_DIR="$(resolve_upload_config_dir)"

STATE_DIR="${STATE_DIRECTORY:-${XDG_STATE_HOME:-${HOME}/.local/state}/antscihub-upload}"
LOG_DIR="${LOGS_DIRECTORY:-${XDG_STATE_HOME:-${HOME}/.local/state}/antscihub-upload}"
RUNTIME_DIR="${RUNTIME_DIRECTORY:-${XDG_RUNTIME_DIR:-/tmp}}"

STATE_DIR="${STATE_DIR%%:*}"
LOG_DIR="${LOG_DIR%%:*}"
RUNTIME_DIR="${RUNTIME_DIR%%:*}"

DB_FILE="${STATE_DIR}/queue.db"
LEGACY_PROCESSED_FILE="${STATE_DIR}/processed.txt"
LOG_FILE="${LOG_DIR}/antscihub-upload.log"
LOCK_FILE="${RUNTIME_DIR}/antscihub-upload.lock"
PROTECT_STOP_STAMP_FILE="${STATE_DIR}/last-protect-stop.epoch"

UPLOAD_PROFILE_FILE="${UPLOAD_CONFIG_DIR}/upload-profile.txt"
UPLOAD_RETENTION_FILE="${UPLOAD_CONFIG_DIR}/upload-retention.txt"
UPLOAD_PAUSED_FILE="${UPLOAD_CONFIG_DIR}/upload-paused.txt"
UPLOAD_LOCAL_TARGET_FILE="${UPLOAD_CONFIG_DIR}/upload-local-target.txt"
UPLOAD_RCLONE_REMOTE_FILE="${UPLOAD_CONFIG_DIR}/upload-rclone-remote.txt"
UPLOAD_RCLONE_PATH_FILE="${UPLOAD_CONFIG_DIR}/upload-rclone-path.txt"
UPLOAD_HIGH_WATERMARK_FILE="${UPLOAD_CONFIG_DIR}/upload-high-watermark-percent.txt"
UPLOAD_LOW_WATERMARK_FILE="${UPLOAD_CONFIG_DIR}/upload-low-watermark-percent.txt"

UPLOAD_SERVICE_NAME="${UPLOAD_SERVICE_NAME:-antscihub-upload.service}"
UPLOAD_STOP_COMMAND="${UPLOAD_STOP_COMMAND:-antcam stop}"

FLEET_EVENT_TOPIC_TEMPLATE="${FLEET_EVENT_TOPIC_TEMPLATE:-fleet/report/{DEVICE_ID}}"
FLEET_PUBLISH_BIN="${FLEET_PUBLISH_BIN:-fleet-publish}"
MQTT_REPORT_BIN="${MQTT_REPORT_BIN:-mqtt_report.py}"
MQTT_EVENT_ENABLED="${MQTT_EVENT_ENABLED:-true}"

MACHINE_SUFFIX="${MACHINE_SUFFIX:-}"
if [[ -z "${MACHINE_SUFFIX}" ]]; then
    MACHINE_SUFFIX="$(hostname 2>/dev/null || true)"
fi
MACHINE_SUFFIX="${MACHINE_SUFFIX//[^[:alnum:]._-]/_}"
MACHINE_SUFFIX="${MACHINE_SUFFIX//__/_}"
MACHINE_SUFFIX="${MACHINE_SUFFIX##_}"
MACHINE_SUFFIX="${MACHINE_SUFFIX%%_}"
[[ -n "${MACHINE_SUFFIX}" ]] || MACHINE_SUFFIX="unknown-machine"

DEFAULT_UPLOAD_PROFILE="${UPLOAD_PROFILE:-field}"
DEFAULT_UPLOAD_RETENTION="${UPLOAD_RETENTION:-protect}"
DEFAULT_UPLOAD_PAUSED="${UPLOAD_PAUSED:-false}"
DEFAULT_UPLOAD_LOCAL_TARGET="${UPLOAD_LOCAL_TARGET_PATH:-}"
DEFAULT_UPLOAD_RCLONE_REMOTE="${RCLONE_REMOTE:-}"
DEFAULT_UPLOAD_RCLONE_PATH="${RCLONE_PATH:-}"
DEFAULT_UPLOAD_HIGH_WATERMARK="${UPLOAD_HIGH_WATERMARK_PERCENT:-80}"
DEFAULT_UPLOAD_LOW_WATERMARK="${UPLOAD_LOW_WATERMARK_PERCENT:-70}"

MAX_RETRIES="${MAX_RETRIES:-5}"
SCAN_INTERVAL="${SCAN_INTERVAL:-10}"
MIN_FILE_AGE_DEFAULT="${MIN_FILE_AGE_DEFAULT:-30}"
MIN_FILE_AGE_STILL_IMAGE="${MIN_FILE_AGE_STILL_IMAGE:-3}"
MIN_FILE_AGE_VIDEO="${MIN_FILE_AGE_VIDEO:-120}"
MIN_FILE_AGE_STATE_AND_LOG="${MIN_FILE_AGE_STATE_AND_LOG:-300}"
FILE_STABILITY_CHECK_INTERVAL_DEFAULT="${FILE_STABILITY_CHECK_INTERVAL_DEFAULT:-10}"
FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE="${FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE:-3}"
PROTECT_STOP_COOLDOWN_SECONDS="${PROTECT_STOP_COOLDOWN_SECONDS:-300}"
RETRY_BASE_DELAY_SECONDS="${RETRY_BASE_DELAY_SECONDS:-30}"
RETRY_MAX_DELAY_SECONDS="${RETRY_MAX_DELAY_SECONDS:-600}"

DEVICE_ID_CACHE=""
DEVICE_ID_CACHE_READY="false"
MQTT_PUBLISH_WARNING_EMITTED="false"
SETTINGS_WARNING_EMITTED="false"
PAUSE_NOTICE_EMITTED="false"
OPEN_FILE_CHECK_TOOL=""
EXCLUSION_REASON=""

CURRENT_UPLOAD_PROFILE=""
CURRENT_UPLOAD_RETENTION=""
CURRENT_UPLOAD_PAUSED="false"
CURRENT_UPLOAD_LOCAL_TARGET=""
CURRENT_UPLOAD_RCLONE_REMOTE=""
CURRENT_UPLOAD_RCLONE_PATH=""
CURRENT_HIGH_WATERMARK=80
CURRENT_LOW_WATERMARK=70

declare -A SEEN_FILE_DETECTIONS=()
declare -A SEEN_FILE_EXCLUSIONS=()

log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "${LOG_FILE}"
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

normalize_text_value() {
    local value="${1:-}"
    value="${value//$'\r'/}"
    value="${value//$'\n'/}"
    printf '%s' "${value}"
}

read_value_with_default() {
    local file_path="$1"
    local default_value="$2"
    local raw_value normalized_value

    if [[ ! -f "${file_path}" ]]; then
        printf '%s' "${default_value}"
        return 0
    fi

    raw_value="$(head -n 1 "${file_path}" 2>/dev/null || true)"
    normalized_value="$(normalize_text_value "${raw_value}")"
    if [[ -z "${normalized_value}" ]]; then
        printf '%s' "${default_value}"
    else
        printf '%s' "${normalized_value}"
    fi
}

is_valid_profile() {
    case "$1" in
        field|cloud|local)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_valid_retention() {
    case "$1" in
        protect|rolling)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

normalize_bool_value() {
    local value="${1:-}"
    value="${value,,}"
    case "${value}" in
        1|true|yes|on)
            printf '%s' "true"
            ;;
        0|false|no|off)
            printf '%s' "false"
            ;;
        *)
            return 1
            ;;
    esac
}

normalize_watermark() {
    local value="${1:-}"
    [[ "${value}" =~ ^[0-9]+$ ]] || return 1
    if [[ "${value}" -lt 1 || "${value}" -gt 99 ]]; then
        return 1
    fi
    printf '%s' "${value}"
}

normalize_remote_path() {
    local value="${1:-}"
    value="$(normalize_text_value "${value}")"
    value="${value#/}"
    value="${value%/}"
    if [[ "${value}" == "." ]]; then
        value=""
    fi
    printf '%s' "${value}"
}

refresh_runtime_settings() {
    local profile retention paused local_target remote_name remote_path
    local high low

    profile="$(read_value_with_default "${UPLOAD_PROFILE_FILE}" "${DEFAULT_UPLOAD_PROFILE}")"
    profile="${profile,,}"
    if ! is_valid_profile "${profile}"; then
        profile="field"
        if [[ "${SETTINGS_WARNING_EMITTED}" != "true" ]]; then
            log "WARN" "Invalid upload profile setting; falling back to field"
            SETTINGS_WARNING_EMITTED="true"
        fi
    fi

    retention="$(read_value_with_default "${UPLOAD_RETENTION_FILE}" "${DEFAULT_UPLOAD_RETENTION}")"
    retention="${retention,,}"
    if ! is_valid_retention "${retention}"; then
        retention="protect"
        if [[ "${SETTINGS_WARNING_EMITTED}" != "true" ]]; then
            log "WARN" "Invalid upload retention setting; falling back to protect"
            SETTINGS_WARNING_EMITTED="true"
        fi
    fi

    paused="$(read_value_with_default "${UPLOAD_PAUSED_FILE}" "${DEFAULT_UPLOAD_PAUSED}")"
    paused="$(normalize_bool_value "${paused}" 2>/dev/null || printf '%s' "false")"

    local_target="$(read_value_with_default "${UPLOAD_LOCAL_TARGET_FILE}" "${DEFAULT_UPLOAD_LOCAL_TARGET}")"
    if [[ "${local_target,,}" == "none" ]]; then
        local_target=""
    fi

    remote_name="$(read_value_with_default "${UPLOAD_RCLONE_REMOTE_FILE}" "${DEFAULT_UPLOAD_RCLONE_REMOTE}")"
    if [[ "${remote_name,,}" == "none" ]]; then
        remote_name=""
    fi

    remote_path="$(read_value_with_default "${UPLOAD_RCLONE_PATH_FILE}" "${DEFAULT_UPLOAD_RCLONE_PATH}")"
    if [[ "${remote_path,,}" == "none" ]]; then
        remote_path=""
    fi
    remote_path="$(normalize_remote_path "${remote_path}")"

    high="$(read_value_with_default "${UPLOAD_HIGH_WATERMARK_FILE}" "${DEFAULT_UPLOAD_HIGH_WATERMARK}")"
    high="$(normalize_watermark "${high}" 2>/dev/null || printf '%s' "80")"

    low="$(read_value_with_default "${UPLOAD_LOW_WATERMARK_FILE}" "${DEFAULT_UPLOAD_LOW_WATERMARK}")"
    low="$(normalize_watermark "${low}" 2>/dev/null || printf '%s' "70")"

    if [[ "${low}" -ge "${high}" ]]; then
        low=$((high - 10))
        if [[ "${low}" -lt 1 ]]; then
            low=1
        fi
    fi

    CURRENT_UPLOAD_PROFILE="${profile}"
    CURRENT_UPLOAD_RETENTION="${retention}"
    CURRENT_UPLOAD_PAUSED="${paused}"
    CURRENT_UPLOAD_LOCAL_TARGET="${local_target}"
    CURRENT_UPLOAD_RCLONE_REMOTE="${remote_name}"
    CURRENT_UPLOAD_RCLONE_PATH="${remote_path}"
    CURRENT_HIGH_WATERMARK="${high}"
    CURRENT_LOW_WATERMARK="${low}"
}

normalize_device_id() {
    local input="${1:-}"
    input="${input//$'\r'/}"
    input="${input//$'\n'/}"
    input="${input//$'\t'/}"
    input="${input// /}"
    printf '%s' "${input}"
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

    if [[ -z "${candidate}" ]]; then
        candidate="${MACHINE_SUFFIX}"
    fi

    DEVICE_ID_CACHE="${candidate}"
    DEVICE_ID_CACHE_READY="true"
    printf '%s' "${candidate}"
}
publish_with_fleet_publish() {
    local topic="$1"
    local payload="$2"

    command -v "${FLEET_PUBLISH_BIN}" >/dev/null 2>&1 || return 1
    "${FLEET_PUBLISH_BIN}" --topic "${topic}" --json "${payload}" >/dev/null 2>&1 && return 0
    "${FLEET_PUBLISH_BIN}" --topic "${topic}" --payload "${payload}" >/dev/null 2>&1 && return 0
    "${FLEET_PUBLISH_BIN}" --topic "${topic}" --message "${payload}" >/dev/null 2>&1 && return 0
    "${FLEET_PUBLISH_BIN}" -t "${topic}" -m "${payload}" >/dev/null 2>&1 && return 0
    return 1
}

publish_with_mqtt_report_cli() {
    local topic="$1"
    local payload="$2"

    command -v "${MQTT_REPORT_BIN}" >/dev/null 2>&1 || return 1
    "${MQTT_REPORT_BIN}" --topic "${topic}" --json "${payload}" >/dev/null 2>&1
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
                payload_obj = json.loads(payload_obj)
            try:
                method(topic, payload_obj, encrypt=True)
            except TypeError:
                method(topic, payload_obj)
        else:
            try:
                method(topic, payload_obj, encrypt=True)
            except TypeError:
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

build_fleet_event_topic() {
    local device_id="$1"
    local template="${FLEET_EVENT_TOPIC_TEMPLATE}"
    local topic
    topic="${template//\{DEVICE_ID\}/${device_id}}"
    if [[ -z "${topic}" ]]; then
        topic="fleet/report/${device_id}"
    fi
    printf '%s' "${topic}"
}

upload_status_to_report_name() {
    local status="$1"
    case "${status}" in
        queued)
            printf '%s' "upload_queued"
            ;;
        in_flight)
            printf '%s' "upload_in_flight"
            ;;
        shipped)
            printf '%s' "upload_shipped"
            ;;
        failed)
            printf '%s' "upload_failed"
            ;;
        retry)
            printf '%s' "upload_retry_scheduled"
            ;;
        dead_letter)
            printf '%s' "upload_dead_letter"
            ;;
        pruned)
            printf '%s' "upload_pruned"
            ;;
        paused)
            printf '%s' "upload_paused"
            ;;
        protect_stop)
            printf '%s' "upload_protect_stop_requested"
            ;;
        *)
            printf '%s' "upload_status"
            ;;
    esac
}

upload_status_to_severity() {
    local status="$1"
    case "${status}" in
        queued)
            printf '%s' "ROUTINE"
            ;;
        in_flight)
            printf '%s' "ATTENTION"
            ;;
        shipped|pruned)
            printf '%s' "INFO"
            ;;
        retry|paused)
            printf '%s' "WARNING"
            ;;
        failed|dead_letter|protect_stop)
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
        queued|in_flight|shipped|pruned)
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
    local destination="$3"
    local size_bytes="$4"
    local attempt="${5:-}"
    local reason="${6:-}"
    local exit_code="${7:-}"

    if [[ "${MQTT_EVENT_ENABLED,,}" != "true" ]]; then
        return 0
    fi

    local device_id report_name severity success_bool message timestamp topic
    device_id="$(resolve_device_id)"
    report_name="$(upload_status_to_report_name "${status}")"
    severity="$(upload_status_to_severity "${status}")"
    success_bool="$(upload_status_to_success "${status}")"

    message="upload status=${status}"
    if [[ -n "${relative_path}" ]]; then
        message="${message} file=${relative_path}"
    fi
    if [[ -n "${reason}" ]]; then
        message="${message} reason=${reason}"
    fi

    timestamp="$(date +%s)"
    topic="$(build_fleet_event_topic "${device_id}")"

    local payload
    payload="{\"event\":\"report\",\"report\":\"$(json_escape "${report_name}")\",\"device_id\":\"$(json_escape "${device_id}")\",\"timestamp\":${timestamp},\"service\":\"$(json_escape "${UPLOAD_SERVICE_NAME}")\",\"success\":${success_bool},\"severity\":\"$(json_escape "${severity}")\",\"message\":\"$(json_escape "${message}")\",\"file\":\"$(json_escape "${relative_path}")\",\"destination\":\"$(json_escape "${destination}")\",\"size_bytes\":\"$(json_escape "${size_bytes}")\",\"attempt\":\"$(json_escape "${attempt}")\",\"reason\":\"$(json_escape "${reason}")\",\"exit_code\":\"$(json_escape "${exit_code}")\"}"

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
        log "WARN" "Unable to publish upload MQTT events"
        MQTT_PUBLISH_WARNING_EMITTED="true"
    fi

    return 1
}

emit_upload_event() {
    local status="$1"
    local relative_path="$2"
    local destination="$3"
    local size_bytes="${4:-unknown}"
    local attempt="${5:-}"
    local reason="${6:-}"
    local exit_code="${7:-}"
    local ts

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'UPLOAD_EVENT status=%s ts=%s file=%q destination=%q size_bytes=%s\n' \
        "${status}" "${ts}" "${relative_path}" "${destination}" "${size_bytes}"

    publish_upload_mqtt_event "${status}" "${relative_path}" "${destination}" "${size_bytes}" "${attempt}" "${reason}" "${exit_code}" || true
}

require_sqlite3() {
    command -v sqlite3 >/dev/null 2>&1 || {
        log "ERROR" "sqlite3 is required for spool-and-ship queue state"
        exit 1
    }
}

sql_escape() {
    local value="${1:-}"
    value="${value//\'/\'\'}"
    printf "%s" "${value}"
}

db_exec() {
    local sql="$1"
    sqlite3 "${DB_FILE}" "PRAGMA busy_timeout=5000; ${sql}" >/dev/null
}

db_query_single() {
    local sql="$1"
    sqlite3 -noheader "${DB_FILE}" "PRAGMA busy_timeout=5000; ${sql}" 2>/dev/null | head -n 1
}

init_db() {
    db_exec "
CREATE TABLE IF NOT EXISTS artifacts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_key TEXT NOT NULL UNIQUE,
    relative_path TEXT NOT NULL,
    full_path TEXT NOT NULL,
    inode INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,
    mtime_epoch INTEGER NOT NULL,
    status TEXT NOT NULL,
    retry_count INTEGER NOT NULL DEFAULT 0,
    next_retry_epoch INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    discovered_at_epoch INTEGER NOT NULL,
    updated_at_epoch INTEGER NOT NULL,
    last_seen_epoch INTEGER NOT NULL,
    last_attempt_epoch INTEGER NOT NULL DEFAULT 0,
    first_shipped_epoch INTEGER NOT NULL DEFAULT 0,
    shipped_target TEXT NOT NULL DEFAULT '',
    pruned_at_epoch INTEGER NOT NULL DEFAULT 0,
    profile_at_ship TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_artifacts_status ON artifacts(status);
CREATE INDEX IF NOT EXISTS idx_artifacts_next_retry ON artifacts(next_retry_epoch);
CREATE INDEX IF NOT EXISTS idx_artifacts_first_shipped ON artifacts(first_shipped_epoch);
CREATE INDEX IF NOT EXISTS idx_artifacts_relative_path ON artifacts(relative_path);
CREATE TABLE IF NOT EXISTS artifact_targets (
    artifact_id INTEGER NOT NULL,
    target_name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING',
    attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_epoch INTEGER NOT NULL DEFAULT 0,
    last_success_epoch INTEGER NOT NULL DEFAULT 0,
    last_error TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (artifact_id, target_name),
    FOREIGN KEY (artifact_id) REFERENCES artifacts(id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS attempt_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    artifact_id INTEGER NOT NULL,
    target_name TEXT NOT NULL,
    attempt_epoch INTEGER NOT NULL,
    action TEXT NOT NULL,
    exit_code INTEGER NOT NULL DEFAULT 0,
    message TEXT NOT NULL DEFAULT '',
    FOREIGN KEY (artifact_id) REFERENCES artifacts(id) ON DELETE CASCADE
);
"
}

archive_legacy_state() {
    if [[ -f "${LEGACY_PROCESSED_FILE}" ]]; then
        mv -f "${LEGACY_PROCESSED_FILE}" "${LEGACY_PROCESSED_FILE}.legacy.$(date +%s)" || true
        log "INFO" "Archived legacy processed.txt state"
    fi
}

acquire_lock() {
    exec 9>"${LOCK_FILE}"
    if ! flock -n 9; then
        log "ERROR" "Another upload worker instance is running. Exiting."
        exit 1
    fi
    trap 'rm -f "${LOCK_FILE}"' EXIT
    echo $$ > "${LOCK_FILE}"
}

hash_text() {
    local input="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "${input}" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "${input}" | shasum -a 256 | awk '{print $1}'
    else
        printf '%s' "${input}" | cksum | awk '{print $1}'
    fi
}

make_file_identity() {
    local file="$1"
    local relative_path="$2"
    local stat_fields
    # Use inode+size (not mtime) to avoid re-queue churn from metadata-only mtime touches.
    stat_fields="$(stat -c '%i:%s' "${file}" 2>/dev/null || echo "0:0")"
    printf '%s|%s' "${relative_path}" "${stat_fields}"
}

make_file_detection_key() {
    local file="$1"
    local relative_path="$2"
    local inode
    inode="$(stat -c %i "${file}" 2>/dev/null || echo 0)"
    printf '%s|%s' "${relative_path}" "${inode}"
}
log_file_detected_once() {
    local file="$1"
    local relative_path="$2"
    local detection_key file_size
    detection_key="$(make_file_detection_key "${file}" "${relative_path}")"

    if [[ -n "${SEEN_FILE_DETECTIONS["${detection_key}"]+x}" ]]; then
        return 0
    fi

    file_size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
    log "INFO" "Queued file candidate: ${relative_path} (size=${file_size} bytes)"
    emit_upload_event "queued" "${relative_path}" "" "${file_size}" "" "file_detected" ""
    SEEN_FILE_DETECTIONS["${detection_key}"]="1"
}

is_uploadable() {
    local basename="$1"
    [[ "${basename}" =~ ^\. ]] && return 1
    [[ "${basename}" =~ ^~ ]] && return 1
    [[ "${basename}" =~ \.MOVED$ ]] && return 1
    return 0
}

path_has_config_segment() {
    local relative_path="$1"
    local lower_relative="${relative_path,,}"
    case "${lower_relative}" in
        config/*|*/config/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

path_is_diagnostics_tree() {
    local relative_path="$1"
    local lower_relative="${relative_path,,}"
    case "${lower_relative}" in
        diagnostics/*|*/diagnostics/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_log_file() {
    local basename="$1"
    local lower_basename="${basename,,}"
    case "${lower_basename}" in
        *.log|*.log.[0-9]|*.out|*.err)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_runtime_state_file() {
    local basename="$1"
    local lower_basename="${basename,,}"
    case "${lower_basename}" in
        *.env|*.pid|*.lock|*.tmp|*.temp|*.part|*.partial|*.swp|*.swo|*.db|*.db-*|*.sqlite|*.sqlite-*|*.journal|state.env|capture.log)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

log_file_excluded_once() {
    local file="$1"
    local relative_path="$2"
    local reason="$3"
    local detection_key
    detection_key="$(make_file_detection_key "${file}" "${relative_path}")|${reason}"

    if [[ -n "${SEEN_FILE_EXCLUSIONS["${detection_key}"]+x}" ]]; then
        return 0
    fi

    log "DEBUG" "Skipping excluded file: ${relative_path} reason=${reason}"
    SEEN_FILE_EXCLUSIONS["${detection_key}"]="1"
}

excluded_reason_for_path() {
    local relative_path="$1"
    local basename="$2"
    local reason=""

    if path_has_config_segment "${relative_path}"; then
        reason="config_tree_runtime_excluded"
    elif is_runtime_state_file "${basename}" && ! path_is_diagnostics_tree "${relative_path}"; then
        reason="runtime_state_excluded"
    elif is_log_file "${basename}" && ! path_is_diagnostics_tree "${relative_path}"; then
        reason="log_outside_diagnostics_excluded"
    fi

    printf '%s' "${reason}"
}

is_excluded_upload_candidate() {
    local relative_path="$1"
    local basename="$2"
    local reason=""

    reason="$(excluded_reason_for_path "${relative_path}" "${basename}")"
    if [[ -n "${reason}" ]]; then
        EXCLUSION_REASON="${reason}"
        return 0
    fi

    EXCLUSION_REASON=""
    return 1
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

is_video_file() {
    local basename="$1"
    local lower_basename="${basename,,}"
    case "${lower_basename}" in
        *.h264|*.h265|*.hevc|*.mp4|*.mov|*.mkv|*.avi|*.mts|*.m2ts|*.ts|*.webm|*.mjpeg|*.yuv)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_slow_maturity_file() {
    local basename="$1"
    local lower_basename="${basename,,}"
    case "${lower_basename}" in
        state.env|*.log)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

required_min_age_for_file() {
    local basename="$1"
    if is_slow_maturity_file "${basename}"; then
        echo "${MIN_FILE_AGE_STATE_AND_LOG}"
    elif is_still_image "${basename}"; then
        echo "${MIN_FILE_AGE_STILL_IMAGE}"
    elif is_video_file "${basename}"; then
        echo "${MIN_FILE_AGE_VIDEO}"
    else
        echo "${MIN_FILE_AGE_DEFAULT}"
    fi
}

stability_interval_for_file() {
    local basename="$1"
    if is_still_image "${basename}"; then
        echo "${FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE}"
    else
        echo "${FILE_STABILITY_CHECK_INTERVAL_DEFAULT}"
    fi
}

is_file_stable() {
    local file="$1"
    local stability_interval="$2"
    local initial_size final_size

    initial_size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
    sleep "${stability_interval}"

    if [[ ! -f "${file}" ]]; then
        return 1
    fi

    final_size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
    [[ "${initial_size}" -eq "${final_size}" ]]
}

init_open_file_check_tool() {
    if command -v lsof >/dev/null 2>&1; then
        OPEN_FILE_CHECK_TOOL="lsof"
    elif command -v fuser >/dev/null 2>&1; then
        OPEN_FILE_CHECK_TOOL="fuser"
    else
        OPEN_FILE_CHECK_TOOL="none"
        log "WARN" "No lsof/fuser found; open-file detection is disabled"
    fi
}

is_file_currently_open() {
    local file="$1"
    case "${OPEN_FILE_CHECK_TOOL}" in
        lsof)
            lsof -t -- "${file}" >/dev/null 2>&1
            ;;
        fuser)
            fuser "${file}" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

profile_targets_for_attempt() {
    local profile="$1"
    case "${profile}" in
        field)
            printf '%s\n' "local" "cloud"
            ;;
        cloud)
            printf '%s\n' "cloud"
            ;;
        local)
            printf '%s\n' "local"
            ;;
    esac
}

build_remote_target() {
    local relative_path="$1"
    if [[ -n "${CURRENT_UPLOAD_RCLONE_PATH}" ]]; then
        printf '%s:%s/%s' "${CURRENT_UPLOAD_RCLONE_REMOTE}" "${CURRENT_UPLOAD_RCLONE_PATH}" "${relative_path}"
    else
        printf '%s:%s' "${CURRENT_UPLOAD_RCLONE_REMOTE}" "${relative_path}"
    fi
}

remote_path_exists() {
    local remote_target="$1"
    local listing
    listing="$(rclone lsf --files-only --max-depth 1 "${remote_target}" 2>/dev/null || true)"
    [[ -n "${listing//[[:space:]]/}" ]]
}

resolve_remote_target() {
    local relative_path="$1"
    local selected_target
    selected_target="$(build_remote_target "${relative_path}")"
    printf '%s|%s' "${relative_path}" "${selected_target}"
}

resolve_local_target_path() {
    local relative_path="$1"
    local selected_target="${CURRENT_UPLOAD_LOCAL_TARGET%/}/${relative_path}"
    printf '%s|%s' "${relative_path}" "${selected_target}"
}

calculate_backoff() {
    local attempt="$1"
    local delay=$((RETRY_BASE_DELAY_SECONDS * (2 ** (attempt - 1))))
    if [[ "${delay}" -gt "${RETRY_MAX_DELAY_SECONDS}" ]]; then
        delay="${RETRY_MAX_DELAY_SECONDS}"
    fi
    echo "${delay}"
}

now_epoch() {
    date +%s
}

set_artifact_target_status() {
    local artifact_id="$1"
    local target_name="$2"
    local status="$3"
    local error_message="$4"
    local current_epoch="$5"
    local success_epoch="$6"

    local escaped_error
    escaped_error="$(sql_escape "${error_message}")"

    db_exec "
INSERT INTO artifact_targets (artifact_id, target_name, status, attempt_count, last_attempt_epoch, last_success_epoch, last_error)
VALUES (${artifact_id}, '$(sql_escape "${target_name}")', '$(sql_escape "${status}")', 1, ${current_epoch}, ${success_epoch}, '${escaped_error}')
ON CONFLICT(artifact_id, target_name) DO UPDATE SET
    status=excluded.status,
    attempt_count=artifact_targets.attempt_count + 1,
    last_attempt_epoch=excluded.last_attempt_epoch,
    last_success_epoch=excluded.last_success_epoch,
    last_error=excluded.last_error;
"
}

insert_attempt_log() {
    local artifact_id="$1"
    local target_name="$2"
    local action="$3"
    local exit_code="$4"
    local message="$5"
    local current_epoch="$6"

    db_exec "
INSERT INTO attempt_log (artifact_id, target_name, attempt_epoch, action, exit_code, message)
VALUES (${artifact_id}, '$(sql_escape "${target_name}")', ${current_epoch}, '$(sql_escape "${action}")', ${exit_code}, '$(sql_escape "${message}")');
"
}
register_artifact_if_needed() {
    local file="$1"
    local relative_path="$2"
    local file_key="$3"

    local inode size_bytes mtime_epoch current_epoch existing_id
    inode="$(stat -c %i "${file}" 2>/dev/null || echo 0)"
    size_bytes="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
    mtime_epoch="$(stat -c %Y "${file}" 2>/dev/null || echo 0)"
    current_epoch="$(now_epoch)"

    existing_id="$(db_query_single "SELECT id FROM artifacts WHERE file_key='$(sql_escape "${file_key}")' LIMIT 1;")"
    if [[ -z "${existing_id}" ]]; then
        existing_id="$(db_query_single "SELECT id FROM artifacts WHERE relative_path='$(sql_escape "${relative_path}")' ORDER BY id DESC LIMIT 1;")"
    fi

    if [[ -z "${existing_id}" ]]; then
        db_exec "
INSERT INTO artifacts (file_key, relative_path, full_path, inode, size_bytes, mtime_epoch, status, retry_count, next_retry_epoch, last_error, discovered_at_epoch, updated_at_epoch, last_seen_epoch)
VALUES ('$(sql_escape "${file_key}")', '$(sql_escape "${relative_path}")', '$(sql_escape "${file}")', ${inode}, ${size_bytes}, ${mtime_epoch}, 'QUEUED', 0, 0, '', ${current_epoch}, ${current_epoch}, ${current_epoch});
"
        existing_id="$(db_query_single "SELECT id FROM artifacts WHERE file_key='$(sql_escape "${file_key}")' LIMIT 1;")"
    else
        db_exec "
UPDATE artifacts
SET file_key='$(sql_escape "${file_key}")',
    relative_path='$(sql_escape "${relative_path}")',
    full_path='$(sql_escape "${file}")',
    inode=${inode},
    size_bytes=${size_bytes},
    mtime_epoch=${mtime_epoch},
    last_seen_epoch=${current_epoch},
    updated_at_epoch=${current_epoch}
WHERE id=${existing_id};
"
    fi

    printf '%s' "${existing_id}"
}

can_attempt_artifact_now() {
    local artifact_id="$1"
    local current_epoch="$2"

    local status next_retry
    status="$(db_query_single "SELECT status FROM artifacts WHERE id=${artifact_id};")"

    case "${status}" in
        SHIPPED|PRUNED|DEAD_LETTER)
            return 1
            ;;
        RETRY_WAIT)
            next_retry="$(db_query_single "SELECT next_retry_epoch FROM artifacts WHERE id=${artifact_id};")"
            if [[ -n "${next_retry}" && "${next_retry}" -gt "${current_epoch}" ]]; then
                return 1
            fi
            ;;
        *)
            ;;
    esac

    return 0
}

ship_to_cloud_target() {
    local file="$1"
    local relative_path="$2"

    if [[ -z "${CURRENT_UPLOAD_RCLONE_REMOTE}" ]]; then
        SHIP_FAILURE_REASON="cloud_remote_unset"
        return 1
    fi

    if ! command -v rclone >/dev/null 2>&1; then
        SHIP_FAILURE_REASON="rclone_not_installed"
        return 1
    fi

    local selection selected_relative remote_target file_size
    selection="$(resolve_remote_target "${relative_path}")"
    selected_relative="${selection%%|*}"
    remote_target="${selection#*|}"
    file_size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"

    if remote_path_exists "${remote_target}"; then
        SHIP_DESTINATION="${CURRENT_UPLOAD_RCLONE_REMOTE}:${CURRENT_UPLOAD_RCLONE_PATH}"
        if [[ -z "${CURRENT_UPLOAD_RCLONE_PATH}" ]]; then
            SHIP_DESTINATION="${CURRENT_UPLOAD_RCLONE_REMOTE}:"
        fi
        SHIP_DESTINATION_PATH="${remote_target}"
        SHIP_SELECTED_RELATIVE="${selected_relative}"
        SHIP_FILE_SIZE="${file_size}"
        SHIP_ALREADY_PRESENT="true"
        return 0
    fi

    if ! rclone copyto "${file}" "${remote_target}" --immutable --progress --stats=0 2>&1 | tee -a "${LOG_FILE}"; then
        SHIP_FAILURE_REASON="rclone_copy_failed"
        return 1
    fi

    SHIP_DESTINATION="${CURRENT_UPLOAD_RCLONE_REMOTE}:${CURRENT_UPLOAD_RCLONE_PATH}"
    if [[ -z "${CURRENT_UPLOAD_RCLONE_PATH}" ]]; then
        SHIP_DESTINATION="${CURRENT_UPLOAD_RCLONE_REMOTE}:"
    fi
    SHIP_DESTINATION_PATH="${remote_target}"
    SHIP_SELECTED_RELATIVE="${selected_relative}"
    SHIP_FILE_SIZE="${file_size}"
    SHIP_ALREADY_PRESENT="false"
    return 0
}

ship_to_local_target() {
    local file="$1"
    local relative_path="$2"

    if [[ -z "${CURRENT_UPLOAD_LOCAL_TARGET}" ]]; then
        SHIP_FAILURE_REASON="local_target_unset"
        return 1
    fi

    if [[ ! -d "${CURRENT_UPLOAD_LOCAL_TARGET}" ]]; then
        SHIP_FAILURE_REASON="local_target_missing"
        return 1
    fi

    if [[ ! -w "${CURRENT_UPLOAD_LOCAL_TARGET}" ]]; then
        SHIP_FAILURE_REASON="local_target_not_writable"
        return 1
    fi

    local selection selected_relative target_path target_dir tmp_path file_size
    selection="$(resolve_local_target_path "${relative_path}")"
    selected_relative="${selection%%|*}"
    target_path="${selection#*|}"
    target_dir="$(dirname "${target_path}")"
    mkdir -p "${target_dir}"

    if [[ -f "${target_path}" ]]; then
        local source_size target_size
        source_size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
        target_size="$(stat -c %s "${target_path}" 2>/dev/null || echo -1)"

        if [[ "${source_size}" -eq "${target_size}" ]]; then
            SHIP_DESTINATION="local:${CURRENT_UPLOAD_LOCAL_TARGET}"
            SHIP_DESTINATION_PATH="${target_path}"
            SHIP_SELECTED_RELATIVE="${selected_relative}"
            SHIP_FILE_SIZE="${source_size}"
            SHIP_ALREADY_PRESENT="true"
            return 0
        fi

        SHIP_FAILURE_REASON="local_destination_conflict"
        return 1
    fi

    tmp_path="${target_path}.tmp.$$.${RANDOM}"
    if ! cp -p "${file}" "${tmp_path}"; then
        rm -f "${tmp_path}" >/dev/null 2>&1 || true
        SHIP_FAILURE_REASON="local_copy_failed"
        return 1
    fi

    if ! mv -f "${tmp_path}" "${target_path}"; then
        rm -f "${tmp_path}" >/dev/null 2>&1 || true
        SHIP_FAILURE_REASON="local_move_failed"
        return 1
    fi

    file_size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
    SHIP_DESTINATION="local:${CURRENT_UPLOAD_LOCAL_TARGET}"
    SHIP_DESTINATION_PATH="${target_path}"
    SHIP_SELECTED_RELATIVE="${selected_relative}"
    SHIP_FILE_SIZE="${file_size}"
    SHIP_ALREADY_PRESENT="false"
    return 0
}

attempt_ship_artifact() {
    local artifact_id="$1"
    local file="$2"
    local relative_path="$3"
    local file_key="$4"
    local current_epoch="$5"

    local targets target
    local final_error="all_targets_failed"

    db_exec "UPDATE artifacts SET status='IN_FLIGHT', updated_at_epoch=${current_epoch}, last_attempt_epoch=${current_epoch} WHERE id=${artifact_id};"
    emit_upload_event "in_flight" "${relative_path}" "" "$(stat -c %s "${file}" 2>/dev/null || echo 0)" "" "attempt_started" ""

    mapfile -t targets < <(profile_targets_for_attempt "${CURRENT_UPLOAD_PROFILE}")

    for target in "${targets[@]}"; do
        SHIP_FAILURE_REASON=""
        SHIP_DESTINATION=""
        SHIP_DESTINATION_PATH=""
        SHIP_SELECTED_RELATIVE=""
        SHIP_FILE_SIZE="0"
        SHIP_ALREADY_PRESENT="false"

        if [[ "${target}" == "local" ]]; then
            if ship_to_local_target "${file}" "${relative_path}"; then
                local success_reason="target_local"
                if [[ "${SHIP_ALREADY_PRESENT}" == "true" ]]; then
                    success_reason="target_local_exists"
                fi
                set_artifact_target_status "${artifact_id}" "local" "SUCCESS" "" "${current_epoch}" "${current_epoch}"
                insert_attempt_log "${artifact_id}" "local" "success" 0 "${SHIP_DESTINATION_PATH}" "${current_epoch}"
                db_exec "
UPDATE artifacts
SET status='SHIPPED',
    retry_count=0,
    next_retry_epoch=0,
    last_error='',
    updated_at_epoch=${current_epoch},
    first_shipped_epoch=CASE WHEN first_shipped_epoch=0 THEN ${current_epoch} ELSE first_shipped_epoch END,
    shipped_target='local',
    profile_at_ship='$(sql_escape "${CURRENT_UPLOAD_PROFILE}")'
WHERE id=${artifact_id};
"
                emit_upload_event "shipped" "${relative_path}" "${SHIP_DESTINATION_PATH}" "${SHIP_FILE_SIZE}" "" "${success_reason}" ""
                if [[ "${SHIP_ALREADY_PRESENT}" == "true" ]]; then
                    log "INFO" "Local destination already had file; treated as shipped: ${relative_path}"
                fi
                return 0
            fi
            set_artifact_target_status "${artifact_id}" "local" "FAILED" "${SHIP_FAILURE_REASON}" "${current_epoch}" 0
            insert_attempt_log "${artifact_id}" "local" "failed" 1 "${SHIP_FAILURE_REASON}" "${current_epoch}"
            emit_upload_event "failed" "${relative_path}" "local:${CURRENT_UPLOAD_LOCAL_TARGET}" "$(stat -c %s "${file}" 2>/dev/null || echo 0)" "" "${SHIP_FAILURE_REASON}" "1"
            final_error="${SHIP_FAILURE_REASON}"
        else
            if ship_to_cloud_target "${file}" "${relative_path}"; then
                local success_reason="target_cloud"
                if [[ "${SHIP_ALREADY_PRESENT}" == "true" ]]; then
                    success_reason="target_cloud_exists"
                fi
                set_artifact_target_status "${artifact_id}" "cloud" "SUCCESS" "" "${current_epoch}" "${current_epoch}"
                insert_attempt_log "${artifact_id}" "cloud" "success" 0 "${SHIP_DESTINATION_PATH}" "${current_epoch}"
                db_exec "
UPDATE artifacts
SET status='SHIPPED',
    retry_count=0,
    next_retry_epoch=0,
    last_error='',
    updated_at_epoch=${current_epoch},
    first_shipped_epoch=CASE WHEN first_shipped_epoch=0 THEN ${current_epoch} ELSE first_shipped_epoch END,
    shipped_target='cloud',
    profile_at_ship='$(sql_escape "${CURRENT_UPLOAD_PROFILE}")'
WHERE id=${artifact_id};
"
                emit_upload_event "shipped" "${relative_path}" "${SHIP_DESTINATION_PATH}" "${SHIP_FILE_SIZE}" "" "${success_reason}" ""
                if [[ "${SHIP_ALREADY_PRESENT}" == "true" ]]; then
                    log "INFO" "Cloud destination already had file; treated as shipped: ${relative_path}"
                fi
                return 0
            fi
            set_artifact_target_status "${artifact_id}" "cloud" "FAILED" "${SHIP_FAILURE_REASON}" "${current_epoch}" 0
            insert_attempt_log "${artifact_id}" "cloud" "failed" 1 "${SHIP_FAILURE_REASON}" "${current_epoch}"
            emit_upload_event "failed" "${relative_path}" "${CURRENT_UPLOAD_RCLONE_REMOTE}:${CURRENT_UPLOAD_RCLONE_PATH}" "$(stat -c %s "${file}" 2>/dev/null || echo 0)" "" "${SHIP_FAILURE_REASON}" "1"
            final_error="${SHIP_FAILURE_REASON}"
        fi
    done

    local retry_count new_retry_count
    retry_count="$(db_query_single "SELECT retry_count FROM artifacts WHERE id=${artifact_id};")"
    [[ -n "${retry_count}" ]] || retry_count=0
    new_retry_count=$((retry_count + 1))

    if [[ "${new_retry_count}" -ge "${MAX_RETRIES}" ]]; then
        db_exec "
UPDATE artifacts
SET status='DEAD_LETTER', retry_count=${new_retry_count}, next_retry_epoch=0, last_error='$(sql_escape "${final_error}")', updated_at_epoch=${current_epoch}
WHERE id=${artifact_id};
"
        emit_upload_event "dead_letter" "${relative_path}" "" "$(stat -c %s "${file}" 2>/dev/null || echo 0)" "${new_retry_count}" "${final_error}" ""
    else
        local backoff next_retry_epoch
        backoff="$(calculate_backoff "${new_retry_count}")"
        next_retry_epoch=$((current_epoch + backoff))
        db_exec "
UPDATE artifacts
SET status='RETRY_WAIT', retry_count=${new_retry_count}, next_retry_epoch=${next_retry_epoch}, last_error='$(sql_escape "${final_error}")', updated_at_epoch=${current_epoch}
WHERE id=${artifact_id};
"
        emit_upload_event "retry" "${relative_path}" "" "$(stat -c %s "${file}" 2>/dev/null || echo 0)" "${new_retry_count}" "retry_backoff_${backoff}s" ""
    fi

    return 1
}

canonical_path_value() {
    local path_value="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "${path_value}" <<'PY' 2>/dev/null || true
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
        return 0
    fi

    if command -v realpath >/dev/null 2>&1; then
        realpath "${path_value}" 2>/dev/null || printf '%s\n' "${path_value}"
        return 0
    fi

    printf '%s\n' "${path_value}"
}

is_path_within_upload_dir() {
    local file_path="$1"
    local file_real upload_real
    file_real="$(canonical_path_value "${file_path}")"
    upload_real="$(canonical_path_value "${UPLOAD_DIR}")"

    case "${file_real}" in
        "${upload_real}"|${upload_real}/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

spool_usage_percent() {
    local usage_value
    usage_value="$(df -P "${UPLOAD_DIR}" 2>/dev/null | awk 'NR==2 {gsub("%", "", $5); print $5}' || true)"
    if [[ -z "${usage_value}" ]]; then
        echo "0"
    else
        echo "${usage_value}"
    fi
}

request_protect_stop_if_needed() {
    local current_epoch="$1"
    local last_epoch=0

    if [[ -f "${PROTECT_STOP_STAMP_FILE}" ]]; then
        last_epoch="$(cat "${PROTECT_STOP_STAMP_FILE}" 2>/dev/null || echo 0)"
    fi

    if [[ $((current_epoch - last_epoch)) -lt "${PROTECT_STOP_COOLDOWN_SECONDS}" ]]; then
        return 0
    fi

    emit_upload_event "protect_stop" "" "" "" "" "disk_threshold_reached" ""

    if eval "${UPLOAD_STOP_COMMAND}" >/dev/null 2>&1; then
        log "WARN" "Protect retention requested recording stop"
    else
        log "WARN" "Protect retention could not execute stop command: ${UPLOAD_STOP_COMMAND}"
    fi

    printf '%s\n' "${current_epoch}" > "${PROTECT_STOP_STAMP_FILE}"
}

prune_oldest_shipped_until_low_watermark() {
    local current_usage
    current_usage="$(spool_usage_percent)"

    while [[ "${current_usage}" -gt "${CURRENT_LOW_WATERMARK}" ]]; do
        local row id full_path relative_path size_bytes
        row="$(sqlite3 -separator '|' -noheader "${DB_FILE}" "SELECT id, full_path, relative_path, IFNULL(size_bytes,0) FROM artifacts WHERE status='SHIPPED' ORDER BY first_shipped_epoch ASC LIMIT 1;" 2>/dev/null || true)"

        if [[ -z "${row}" ]]; then
            log "WARN" "Rolling retention reached watermark, but no shipped files remain to prune"
            break
        fi

        IFS='|' read -r id full_path relative_path size_bytes <<< "${row}"
        if [[ -z "${full_path}" ]]; then
            db_exec "UPDATE artifacts SET status='PRUNED', pruned_at_epoch=$(now_epoch), updated_at_epoch=$(now_epoch), last_error='empty_full_path' WHERE id=${id};"
            continue
        fi

        if ! is_path_within_upload_dir "${full_path}"; then
            log "WARN" "Skipping unsafe prune candidate outside upload dir: ${full_path}"
            db_exec "UPDATE artifacts SET status='DEAD_LETTER', last_error='unsafe_prune_path', updated_at_epoch=$(now_epoch) WHERE id=${id};"
            continue
        fi

        if [[ -f "${full_path}" ]]; then
            rm -f "${full_path}"
        fi

        db_exec "UPDATE artifacts SET status='PRUNED', pruned_at_epoch=$(now_epoch), updated_at_epoch=$(now_epoch), last_error='' WHERE id=${id};"
        emit_upload_event "pruned" "${relative_path}" "" "${size_bytes}" "" "rolling_retention" ""

        current_usage="$(spool_usage_percent)"
    done
}

enforce_retention_policy() {
    local usage current_epoch
    usage="$(spool_usage_percent)"
    current_epoch="$(now_epoch)"

    if [[ "${CURRENT_UPLOAD_RETENTION}" == "protect" ]]; then
        if [[ "${usage}" -ge "${CURRENT_HIGH_WATERMARK}" ]]; then
            request_protect_stop_if_needed "${current_epoch}"
        fi
        return 0
    fi

    if [[ "${CURRENT_UPLOAD_RETENTION}" == "rolling" && "${usage}" -ge "${CURRENT_HIGH_WATERMARK}" ]]; then
        prune_oldest_shipped_until_low_watermark
    fi
}

mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${RUNTIME_DIR}" "${UPLOAD_DIR}" "${UPLOAD_CONFIG_DIR}"

acquire_lock
require_sqlite3
init_db
archive_legacy_state
refresh_runtime_settings
init_open_file_check_tool

log "INFO" "Upload worker starting"
log "INFO" "Spool dir: ${UPLOAD_DIR}"
log "INFO" "Config dir: ${UPLOAD_CONFIG_DIR}"
log "INFO" "Queue DB: ${DB_FILE}"
log "INFO" "Upload profile=${CURRENT_UPLOAD_PROFILE} retention=${CURRENT_UPLOAD_RETENTION}"

while true; do
    refresh_runtime_settings
    enforce_retention_policy

    if [[ ! -d "${UPLOAD_DIR}" ]]; then
        sleep "${SCAN_INTERVAL}"
        continue
    fi

    while IFS= read -r -d '' file; do
        relative_path="${file#${UPLOAD_DIR}/}"
        if [[ "${relative_path}" == "${file}" ]]; then
            relative_path="$(basename "${file}")"
        fi
        basename="$(basename "${file}")"

        if ! is_uploadable "${basename}"; then
            continue
        fi

        if is_excluded_upload_candidate "${relative_path}" "${basename}"; then
            log_file_excluded_once "${file}" "${relative_path}" "${EXCLUSION_REASON}"
            continue
        fi

        log_file_detected_once "${file}" "${relative_path}"

        mtime="$(stat -c %Y "${file}" 2>/dev/null || echo 0)"
        now="$(now_epoch)"
        age=$((now - mtime))

        required_min_age="$(required_min_age_for_file "${basename}")"
        if [[ "${age}" -lt "${required_min_age}" ]]; then
            continue
        fi

        if is_file_currently_open "${file}"; then
            continue
        fi

        stability_interval="$(stability_interval_for_file "${basename}")"
        if ! is_file_stable "${file}" "${stability_interval}"; then
            continue
        fi

        file_identity="$(make_file_identity "${file}" "${relative_path}")"
        file_key="$(hash_text "${file_identity}")"
        artifact_id="$(register_artifact_if_needed "${file}" "${relative_path}" "${file_key}")"

        if ! can_attempt_artifact_now "${artifact_id}" "${now}"; then
            continue
        fi

        if [[ "${CURRENT_UPLOAD_PAUSED}" == "true" ]]; then
            if [[ "${PAUSE_NOTICE_EMITTED}" != "true" ]]; then
                emit_upload_event "paused" "" "" "" "" "upload_paused" ""
                PAUSE_NOTICE_EMITTED="true"
            fi
            continue
        fi

        PAUSE_NOTICE_EMITTED="false"
        attempt_ship_artifact "${artifact_id}" "${file}" "${relative_path}" "${file_key}" "${now}" || true
    done < <(find "${UPLOAD_DIR}" -type f -print0 2>/dev/null)

    sleep "${SCAN_INTERVAL}"
done
