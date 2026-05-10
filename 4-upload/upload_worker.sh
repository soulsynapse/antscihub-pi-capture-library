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

# Tuning
FILE_STABILITY_CHECK_INTERVAL=10  # Check size stability every 10 seconds
MIN_FILE_AGE=30                   # Wait at least 30 seconds before uploading
MAX_RETRIES=5                     # Max retry attempts per file
SCAN_INTERVAL=10                  # Scan for new files every 10 seconds

if [[ -z "${RCLONE_REMOTE}" ]]; then
    echo "[upload-worker] Error: RCLONE_REMOTE must be set" >&2
    exit 1
fi

log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
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

# Validation: file stability (size hasn't changed)
is_file_stable() {
    local file="$1"
    local initial_size
    local final_size

    initial_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    sleep "$FILE_STABILITY_CHECK_INTERVAL"

    if [[ ! -f "$file" ]]; then
        return 1  # File was deleted
    fi

    final_size=$(stat -c %s "$file" 2>/dev/null || echo 0)

    [[ "$initial_size" -eq "$final_size" ]]
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
    local remote_target
    local file_size
    local file_mtime
    basename=$(basename "$file")
    if [[ -n "${RCLONE_PATH}" ]]; then
        remote_target="${RCLONE_REMOTE}:${RCLONE_PATH}/${relative_path}"
    else
        remote_target="${RCLONE_REMOTE}:${relative_path}"
    fi
    file_size=$(stat -c %s "$file" 2>/dev/null || echo 0)
    file_mtime=$(stat -c %y "$file" 2>/dev/null || echo "unknown")

    log "INFO" "Starting upload: ${relative_path}"

    # Move this single file to its exact remote path to preserve folder structure.
    if rclone moveto "$file" "$remote_target" \
        --progress --stats=0 2>&1 | tee -a "$LOG_FILE"; then

        log "INFO" "Upload successful: ${relative_path}"

        # Create reference file (atomically)
        local remote_link="${file}.MOVED"
        local tmpref
        tmpref=$(mktemp)
        cat > "$tmpref" <<EOF
# File moved to remote storage
# Original file: ${relative_path}
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
        log "ERROR" "Upload failed: ${relative_path}"
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

        # Validation: file age (avoid uploading files still being written)
        mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
        now=$(date +%s)
        age=$((now - mtime))

        if [[ $age -lt $MIN_FILE_AGE ]]; then
            log "DEBUG" "File too new ($age < $MIN_FILE_AGE): $basename"
            continue
        fi

        # Validation: file stability
        log "DEBUG" "Checking stability: $basename"
        if ! is_file_stable "$file"; then
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
                log "WARN" "Retry $current_retries/$MAX_RETRIES for $basename (backoff: ${backoff}s)"
            fi
        fi
    done < <(find "$UPLOAD_DIR" -type f -print0 2>/dev/null)

    sleep "$SCAN_INTERVAL"
done
