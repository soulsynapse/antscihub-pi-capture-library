#!/usr/bin/env bash
set -euo pipefail

capture_dir="${1:-$(pwd)}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
image_file="${capture_dir}/focus-check-${timestamp}.jpg"
metadata_file="${capture_dir}/focus-check-${timestamp}.txt"
log_file="${capture_dir}/focus-check-${timestamp}.log"

log() {
    echo "[focus] $*" >&2
}

mkdir -p "${capture_dir}"

camera_cmd=()
if command -v rpicam-still >/dev/null 2>&1; then
    camera_cmd=(rpicam-still)
elif command -v libcamera-still >/dev/null 2>&1; then
    camera_cmd=(libcamera-still)
else
    log "rpicam-still or libcamera-still not found. Install Raspberry Pi camera apps."
    exit 1
fi

log "Running autofocus probe with ${camera_cmd[0]}"
log "Image output: ${image_file}"
log "Metadata output: ${metadata_file}"

set +e
"${camera_cmd[@]}" \
    --nopreview \
    --timeout 1500 \
    --autofocus-mode auto \
    --autofocus-on-capture \
    --metadata "${metadata_file}" \
    --metadata-format txt \
    --output "${image_file}" 2>&1 | tee -a "${log_file}" >&2
capture_exit="${PIPESTATUS[0]}"
set -e

if [[ "${capture_exit}" -ne 0 ]]; then
    log "autofocus capture failed (exit=${capture_exit})."
    exit "${capture_exit}"
fi

lens_position="$(grep -E '^LensPosition=' "${metadata_file}" | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"
focus_metric="$(grep -E '^(FocusFoM|Focus|focus)=' "${metadata_file}" | tail -n 1 | cut -d= -f2- | tr -d '[:space:]' || true)"

if [[ -z "${lens_position}" ]]; then
    log "LensPosition not found in metadata. Check ${metadata_file}."
    exit 2
fi

if [[ -n "${focus_metric}" ]]; then
    log "Focus metric: ${focus_metric}"
fi

log "Use with: rpicam-vid --lens-position ${lens_position}"

# Final stdout line is intentionally just the numeric lens-position value.
printf '%s\n' "${lens_position}"
