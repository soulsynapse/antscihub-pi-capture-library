#!/usr/bin/env bash
set -euo pipefail

capture_dir="${ANTCAM_CAPTURE_DIR:-${1:-$(pwd)}}"

log() {
    echo "[photo] $*" >&2
}

is_valid_lens_position_value() {
    local value="$1"
    [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_auto_focus_value() {
    local value="${1:-}"
    [[ "${value,,}" == "auto" ]]
}

is_valid_fps_value() {
    local value="$1"
    [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    awk -v v="${value}" 'BEGIN { exit (v > 0 ? 0 : 1) }'
}

normalize_duration_value() {
    local input="${1:-}"
    input="${input//[[:space:]]/}"
    input="${input,,}"
    printf '%s\n' "${input}"
}

duration_to_milliseconds() {
    local duration_value
    duration_value="$(normalize_duration_value "${1:-}")"
    [[ -n "${duration_value}" ]] || return 1

    local remaining="${duration_value}"
    local total_ms=0
    local amount=0
    local unit=""
    local rest=""

    while [[ -n "${remaining}" ]]; do
        if [[ "${remaining}" =~ ^([0-9]+)([hms])(.*)$ ]]; then
            amount="${BASH_REMATCH[1]}"
            unit="${BASH_REMATCH[2]}"
            rest="${BASH_REMATCH[3]}"
        else
            return 1
        fi

        case "${unit}" in
            h)
                total_ms=$((total_ms + (amount * 3600000)))
                ;;
            m)
                total_ms=$((total_ms + (amount * 60000)))
                ;;
            s)
                total_ms=$((total_ms + (amount * 1000)))
                ;;
            *)
                return 1
                ;;
        esac

        remaining="${rest}"
    done

    printf '%s\n' "${total_ms}"
}

fps_to_interval_milliseconds() {
    local fps_value="$1"
    awk -v fps="${fps_value}" '
        BEGIN {
            if (fps <= 0) {
                exit 1
            }
            ms = int((1000 / fps) + 0.5)
            if (ms < 1) {
                ms = 1
            }
            printf "%d\n", ms
        }
    '
}

resolve_focus_file_path() {
    if [[ -n "${ANTCAM_FOCUS_VALUE_FILE:-}" ]]; then
        printf '%s\n' "${ANTCAM_FOCUS_VALUE_FILE}"
        return 0
    fi
    printf '%s\n' "${capture_dir%/}/config/focus-lens-position.txt"
}

resolve_fps_file_path() {
    if [[ -n "${ANTCAM_FPS_VALUE_FILE:-}" ]]; then
        printf '%s\n' "${ANTCAM_FPS_VALUE_FILE}"
        return 0
    fi
    printf '%s\n' "${capture_dir%/}/config/recording-fps.txt"
}

resolve_length_file_path() {
    if [[ -n "${ANTCAM_LENGTH_VALUE_FILE:-}" ]]; then
        printf '%s\n' "${ANTCAM_LENGTH_VALUE_FILE}"
        return 0
    fi
    printf '%s\n' "${capture_dir%/}/config/recording-length.txt"
}

resolve_upload_dir_path() {
    if [[ -n "${ANTCAM_UPLOAD_DIR:-}" ]]; then
        printf '%s\n' "${ANTCAM_UPLOAD_DIR}"
        return 0
    fi

    local capture_parent
    capture_parent="$(dirname "${capture_dir%/}")"
    printf '%s\n' "${capture_parent}/5-UPLOAD"
}

resolve_session_hostname() {
    local host=""
    host="$(hostname 2>/dev/null || true)"
    host="${host//$'\r'/}"
    host="${host//$'\n'/}"
    host="${host//$'\t'/}"
    host="${host//[^[:alnum:]._-]/_}"
    host="${host//__/_}"
    host="${host##_}"
    host="${host%%_}"
    [[ -n "${host}" ]] || host="unknown-host"
    printf '%s\n' "${host}"
}

focus_value="${ANTCAM_FOCUS_LENS_POSITION:-}"
focus_file="$(resolve_focus_file_path)"
fps_value="${ANTCAM_RECORDING_FPS:-}"
fps_file="$(resolve_fps_file_path)"
length_value="${ANTCAM_RECORDING_LENGTH:-}"
length_file="$(resolve_length_file_path)"

if [[ -z "${focus_value}" ]]; then
    if [[ -f "${focus_file}" ]]; then
        focus_value="$(head -n 1 "${focus_file}" | tr -d '[:space:]' || true)"
    else
        focus_value="auto"
    fi
fi

if is_auto_focus_value "${focus_value}"; then
    focus_value="auto"
elif ! is_valid_lens_position_value "${focus_value}"; then
    log "invalid focus lens-position value: ${focus_value}"
    log "set it with: antcam set focus <lens-position|auto>"
    exit 3
fi

if [[ -z "${fps_value}" ]]; then
    if [[ -f "${fps_file}" ]]; then
        fps_value="$(head -n 1 "${fps_file}" | tr -d '[:space:]' || true)"
    else
        fps_value="1"
    fi
fi

is_valid_fps_value "${fps_value}" || {
    log "invalid recording fps value: ${fps_value}"
    log "set it with: antcam set fps <value>"
    exit 4
}

if [[ -z "${length_value}" ]]; then
    if [[ -f "${length_file}" ]]; then
        length_value="$(head -n 1 "${length_file}" | tr -d '[:space:]' || true)"
    else
        length_value="0s"
    fi
fi
length_value="$(normalize_duration_value "${length_value}")"
length_ms="$(duration_to_milliseconds "${length_value}" || true)"
if [[ -z "${length_ms}" ]]; then
    log "invalid recording length value: ${length_value}"
    log "set it with: antcam set length <duration> (example: 30h, 10m, 45s)"
    exit 5
fi

interval_ms="$(fps_to_interval_milliseconds "${fps_value}" || true)"
if [[ -z "${interval_ms}" || "${interval_ms}" -lt 1 ]]; then
    log "could not derive photo interval from fps value: ${fps_value}"
    exit 6
fi

still_cmd=()
if command -v rpicam-still >/dev/null 2>&1; then
    still_cmd=(rpicam-still)
elif command -v libcamera-still >/dev/null 2>&1; then
    still_cmd=(libcamera-still)
else
    log "rpicam-still or libcamera-still not found. Install Raspberry Pi camera apps."
    exit 1
fi

mkdir -p "${capture_dir}"

upload_dir="$(resolve_upload_dir_path)"
session_timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
session_hostname="$(resolve_session_hostname)"
session_dir="${upload_dir%/}/${session_timestamp}__${session_hostname}"
mkdir -p "${session_dir}"
output_pattern="${session_dir}/photo-%05d.jpg"

log "Using still command: ${still_cmd[0]}"
if is_auto_focus_value "${focus_value}"; then
    log "Focus mode: auto (no --lens-position override)"
else
    log "Focus lens-position: ${focus_value}"
fi
log "Recording length: ${length_value} (${length_ms} ms)"
log "Capture rate: ${fps_value} fps"
log "Capture interval: ${interval_ms} ms"
log "Session folder: ${session_dir}"
log "Output pattern: ${output_pattern}"

still_args=(
    --nopreview
    --timeout "${length_ms}"
    --timelapse "${interval_ms}"
    --encoding jpg
)

if ! is_auto_focus_value "${focus_value}"; then
    still_args+=(--lens-position "${focus_value}")
fi

still_args+=(--output "${output_pattern}")

exec "${still_cmd[@]}" \
    "${still_args[@]}"
