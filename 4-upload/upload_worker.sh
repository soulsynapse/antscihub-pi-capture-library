#!/usr/bin/env bash
set -euo pipefail

# Configuration
UPLOAD_DIR="${HOME}/Desktop/5-UPLOAD"
STATE_FILE="/tmp/antscihub-upload-state.txt"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"  # Must be set via environment or systemd
RCLONE_PATH="${RCLONE_PATH:-}"      # Remote path, e.g., "gdrive:Videos"
FILE_STABILITY_DELAY=5              # Seconds to wait before assuming a file is stable
SCAN_INTERVAL=10                    # Seconds between scans

if [[ -z "${RCLONE_REMOTE}" ]] || [[ -z "${RCLONE_PATH}" ]]; then
    echo "[upload-worker] Error: RCLONE_REMOTE and RCLONE_PATH must be set" >&2
    exit 1
fi

if [[ ! -d "${UPLOAD_DIR}" ]]; then
    echo "[upload-worker] Creating upload directory: ${UPLOAD_DIR}"
    mkdir -p "${UPLOAD_DIR}"
fi

# Initialize state file
touch "${STATE_FILE}"

# Load previously processed files
declare -A PROCESSED_FILES
if [[ -f "${STATE_FILE}" ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        PROCESSED_FILES["${line}"]=1
    done < "${STATE_FILE}"
fi

echo "[upload-worker] Starting upload worker"
echo "[upload-worker] Watching: ${UPLOAD_DIR}"
echo "[upload-worker] Remote: ${RCLONE_REMOTE}:${RCLONE_PATH}"

while true; do
    # Scan for new files
    if [[ ! -d "${UPLOAD_DIR}" ]]; then
        sleep "${SCAN_INTERVAL}"
        continue
    fi

    for file in "${UPLOAD_DIR}"/*; do
        # Skip if not a regular file
        [[ ! -f "${file}" ]] && continue

        basename="${file##*/}"

        # Skip if already processed
        if [[ -n "${PROCESSED_FILES["${basename}"]:-}" ]]; then
            continue
        fi

        # Check file stability: if it was modified more than FILE_STABILITY_DELAY seconds ago
        mtime=$(stat -c %Y "${file}" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - mtime))

        if [[ ${age} -lt ${FILE_STABILITY_DELAY} ]]; then
            continue
        fi

        echo "[upload-worker] Processing: ${basename}"

        # Run rclone move
        if rclone move "${file}" "${RCLONE_REMOTE}:${RCLONE_PATH}/" \
            --progress --stats=0 2>&1 | tee /tmp/rclone-move-${basename}.log; then

            # Success: create a symlink at the original location pointing to the remote
            remote_link="${UPLOAD_DIR}/${basename}.uploaded"
            remote_path="${RCLONE_REMOTE}:${RCLONE_PATH}/${basename}"
            
            # Store a plaintext shortcut/reference file instead of symlink
            # (easier to view what was uploaded)
            cat > "${remote_link}" <<EOF
# Upload successful
# Original file: ${basename}
# Moved to: ${remote_path}
# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

            echo "[upload-worker] Created reference: ${remote_link}"

            # Mark as processed
            PROCESSED_FILES["${basename}"]=1
            echo "${basename}" >> "${STATE_FILE}"

        else
            echo "[upload-worker] Failed to move ${basename}. See /tmp/rclone-move-${basename}.log" >&2
            # Do not mark as processed so we retry next time
        fi
    done

    sleep "${SCAN_INTERVAL}"
done
