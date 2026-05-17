#!/usr/bin/env bash
set -euo pipefail

capture_dir="${ANTCAM_CAPTURE_DIR:-${1:-$(pwd)}}"

log() {
    echo "[record-1fps-1m-focus] $*" >&2
}

is_valid_lens_position_value() {
    local value="$1"
    [[ "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

resolve_focus_file_path() {
    if [[ -n "${ANTCAM_FOCUS_VALUE_FILE:-}" ]]; then
        printf '%s\n' "${ANTCAM_FOCUS_VALUE_FILE}"
        return 0
    fi
    printf '%s\n' "${capture_dir%/}/config/focus-lens-position.txt"
}

focus_value="${ANTCAM_FOCUS_LENS_POSITION:-}"
focus_file="$(resolve_focus_file_path)"

if [[ -z "${focus_value}" ]]; then
    [[ -f "${focus_file}" ]] || {
        log "focus settings file not found: ${focus_file}"
        log "set it with: antcam set focus <lens-position>"
        exit 2
    }
    focus_value="$(head -n 1 "${focus_file}" | tr -d '[:space:]' || true)"
fi

is_valid_lens_position_value "${focus_value}" || {
    log "invalid focus lens-position value: ${focus_value}"
    log "set it with: antcam set focus <lens-position>"
    exit 3
}

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

timestamp_prefix="$(date -u +%Y-%m-%d__T-%H-%M-%S)"
output_pattern="${capture_dir%/}/${timestamp_prefix}__chunk-%05d.h264"

log "Using video command: ${video_cmd[0]}"
log "Focus lens-position: ${focus_value}"
log "Chunk length: 1 minute (60000 ms)"
log "Frame rate: 1 fps"
log "Output pattern: ${output_pattern}"

exec "${video_cmd[@]}" \
    --nopreview \
    --timeout 0 \
    --framerate 1 \
    --segment 60000 \
    --codec h264 \
    --inline \
    --lens-position "${focus_value}" \
    --output "${output_pattern}"
