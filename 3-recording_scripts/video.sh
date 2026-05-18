#!/usr/bin/env bash
set -euo pipefail

capture_dir="${ANTCAM_CAPTURE_DIR:-${1:-$(pwd)}}"

log() {
    echo "[video] $*" >&2
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

normalize_loop_setting_value() {
    local raw_value="${1:-}"
    local normalized_value loop_ms
    normalized_value="$(normalize_duration_value "${raw_value}")"
    [[ -n "${normalized_value}" ]] || return 1

    if [[ "${normalized_value}" == "none" || "${normalized_value}" == "0" ]]; then
        printf '%s\n' "none"
        return 0
    fi

    loop_ms="$(duration_to_milliseconds "${normalized_value}" || true)"
    [[ -n "${loop_ms}" ]] || return 1
    if [[ "${loop_ms}" -le 0 ]]; then
        printf '%s\n' "none"
    else
        printf '%s\n' "${normalized_value}"
    fi
}

is_loop_disabled_value() {
    local value="${1:-}"
    [[ "${value}" == "none" ]]
}

now_epoch_milliseconds() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
        return 0
    fi

    local now_seconds
    now_seconds="$(date +%s)"
    printf '%s\n' "$((now_seconds * 1000))"
}

sleep_milliseconds() {
    local sleep_ms="$1"
    if [[ "${sleep_ms}" -le 0 ]]; then
        return 0
    fi

    local sleep_seconds
    sleep_seconds="$(awk -v ms="${sleep_ms}" 'BEGIN { printf "%.3f\n", ms / 1000 }')"
    sleep "${sleep_seconds}"
}

sleep_until_epoch_milliseconds() {
    local target_ms="$1"
    local now_ms remaining_ms
    now_ms="$(now_epoch_milliseconds)"
    remaining_ms=$((target_ms - now_ms))
    sleep_milliseconds "${remaining_ms}"
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

resolve_segment_file_path() {
    if [[ -n "${ANTCAM_SEGMENT_VALUE_FILE:-}" ]]; then
        printf '%s\n' "${ANTCAM_SEGMENT_VALUE_FILE}"
        return 0
    fi
    printf '%s\n' "${capture_dir%/}/config/recording-segment.txt"
}

resolve_loop_file_path() {
    if [[ -n "${ANTCAM_LOOP_VALUE_FILE:-}" ]]; then
        printf '%s\n' "${ANTCAM_LOOP_VALUE_FILE}"
        return 0
    fi
    printf '%s\n' "${capture_dir%/}/config/recording-loop.txt"
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
segment_value="${ANTCAM_RECORDING_SEGMENT:-}"
segment_file="$(resolve_segment_file_path)"
loop_value="${ANTCAM_RECORDING_LOOP:-}"
loop_file="$(resolve_loop_file_path)"

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

if [[ -z "${segment_value}" ]]; then
    if [[ -f "${segment_file}" ]]; then
        segment_value="$(head -n 1 "${segment_file}" | tr -d '[:space:]' || true)"
    else
        segment_value="1m"
    fi
fi
segment_value="$(normalize_duration_value "${segment_value}")"
segment_ms="$(duration_to_milliseconds "${segment_value}" || true)"
if [[ -z "${segment_ms}" || "${segment_ms}" -le 0 ]]; then
    log "invalid recording segment value: ${segment_value}"
    log "set it with: antcam set segment <duration> (example: 10m, 30s, 1h)"
    exit 6
fi

if [[ -z "${loop_value}" ]]; then
    if [[ -f "${loop_file}" ]]; then
        loop_value="$(head -n 1 "${loop_file}" | tr -d '[:space:]' || true)"
    else
        loop_value="1m"
    fi
fi
loop_raw_value="${loop_value}"
loop_value="$(normalize_duration_value "${loop_value}")"
loop_value="$(normalize_loop_setting_value "${loop_value}" || true)"
if [[ -z "${loop_value}" ]]; then
    log "invalid recording loop value: ${loop_raw_value}"
    log "set it with: antcam set loop <duration|none|0> (example: 1m, 30s, 2h, none)"
    exit 7
fi

loop_enabled="true"
loop_ms=0
if is_loop_disabled_value "${loop_value}"; then
    loop_enabled="false"
else
    loop_ms="$(duration_to_milliseconds "${loop_value}" || true)"
    if [[ -z "${loop_ms}" || "${loop_ms}" -le 0 ]]; then
        log "invalid recording loop value: ${loop_raw_value}"
        log "set it with: antcam set loop <duration|none|0> (example: 1m, 30s, 2h, none)"
        exit 7
    fi
fi

if [[ "${loop_enabled}" == "true" && "${segment_ms}" -gt "${loop_ms}" ]]; then
    log "recording segment (${segment_value}) cannot exceed loop interval (${loop_value})"
    log "set segment <= loop to keep loop-aligned start times"
    exit 8
fi

video_cmd=()
if command -v rpicam-vid >/dev/null 2>&1; then
    video_cmd=(rpicam-vid)
elif command -v libcamera-vid >/dev/null 2>&1; then
    video_cmd=(libcamera-vid)
else
    log "rpicam-vid or libcamera-vid not found. Install Raspberry Pi camera apps."
    exit 1
fi

mkdir -p "${capture_dir}"

upload_dir="$(resolve_upload_dir_path)"
session_timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
session_hostname="$(resolve_session_hostname)"
session_dir="${upload_dir%/}/${session_timestamp}__${session_hostname}"
mkdir -p "${session_dir}"

log "Using video command: ${video_cmd[0]}"
if is_auto_focus_value "${focus_value}"; then
    log "Focus mode: auto (no --lens-position override)"
else
    log "Focus lens-position: ${focus_value}"
fi
log "Recording length: ${length_value} (${length_ms} ms)"
log "Chunk length: ${segment_value} (${segment_ms} ms)"
if [[ "${loop_enabled}" == "true" ]]; then
    log "Loop interval: ${loop_value} (${loop_ms} ms)"
else
    log "Loop interval: none (loop scheduling disabled; clips start immediately after each clip)"
fi
log "Frame rate: ${fps_value} fps"
log "Session folder: ${session_dir}"
log "Output pattern: ${session_dir}/video-%05d.h264"

start_epoch_ms="$(now_epoch_milliseconds)"
end_epoch_ms=0
if [[ "${length_ms}" -gt 0 ]]; then
    end_epoch_ms=$((start_epoch_ms + length_ms))
fi

clip_index=0
while true; do
    if [[ "${loop_enabled}" == "true" ]]; then
        now_ms="$(now_epoch_milliseconds)"
        expected_index=$(((now_ms - start_epoch_ms + loop_ms - 1) / loop_ms))
        if [[ "${expected_index}" -gt "${clip_index}" ]]; then
            skipped_slots=$((expected_index - clip_index))
            log "scheduler behind by ${skipped_slots} slot(s); skipping ahead to preserve start-time alignment"
            clip_index="${expected_index}"
        fi

        target_epoch_ms=$((start_epoch_ms + (clip_index * loop_ms)))
        sleep_until_epoch_milliseconds "${target_epoch_ms}"
    fi

    now_ms="$(now_epoch_milliseconds)"
    if [[ "${end_epoch_ms}" -gt 0 && "${now_ms}" -ge "${end_epoch_ms}" ]]; then
        break
    fi

    clip_timeout_ms="${segment_ms}"
    if [[ "${end_epoch_ms}" -gt 0 ]]; then
        remaining_ms=$((end_epoch_ms - now_ms))
        if [[ "${remaining_ms}" -le 0 ]]; then
            break
        fi
        if [[ "${clip_timeout_ms}" -gt "${remaining_ms}" ]]; then
            clip_timeout_ms="${remaining_ms}"
        fi
    fi

    output_file="$(printf "%s/video-%05d.h264" "${session_dir}" "${clip_index}")"
    log "Starting clip index=${clip_index} timeout=${clip_timeout_ms}ms output=${output_file}"

    video_args=(
        --nopreview
        --timeout "${clip_timeout_ms}"
        --framerate "${fps_value}"
        --codec h264
        --inline
    )

    if ! is_auto_focus_value "${focus_value}"; then
        video_args+=(--lens-position "${focus_value}")
    fi

    video_args+=(--output "${output_file}")

    "${video_cmd[@]}" "${video_args[@]}"
    clip_index=$((clip_index + 1))
done
