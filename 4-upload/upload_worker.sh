#!/usr/bin/env bash
set -euo pipefail

# Configuration
UPLOAD_DIR="${HOME}/Desktop/5-UPLOAD"
STATE_DIR="/var/lib/antscihub-upload"
STATE_FILE="${STATE_DIR}/processed.txt"
FAILED_DIR="${STATE_DIR}/failed"
LOG_FILE="/var/log/antscihub-upload.log"
LOCK_FILE="/var/run/antscihub-upload.lock"

RCLONE_REMOTE="${RCLONE_REMOTE:-}"
RCLONE_PATH="${RCLONE_PATH:-}"

# Tuning
FILE_STABILITY_CHECK_INTERVAL=10  # Check size stability every 10 seconds
MIN_FILE_AGE=30                   # Wait at least 30 seconds before uploading
MAX_RETRIES=5                     # Max retry attempts per file
SCAN_INTERVAL=10                  # Scan for new files every 10 seconds

if [[ -z "${RCLONE_REMOTE}" ]] || [[ -z "${RCLONE_PATH}" ]]; then
    echo "[upload-worker] Error: RCLONE_REMOTE and RCLONE_PATH must be set" >&2
    exit 1
fi

# Logging function
log() {
    local level="$1"
    shift
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# Ensure directories exist
mkdir -p "$STATE_DIR"
mkdir -p "$FAILED_DIR"
mkdir -p "$(dirname "$LOG_FILE")"
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

# Atomic state write
add_processed_file() {
    local basename="$1"
    local tmpfile
    tmpfile=$(mktemp)
    {
        cat "$STATE_FILE" 2>/dev/null || true
        echo "$basename"
    } | sort -u > "$tmpfile"
    mv "$tmpfile" "$STATE_FILE"
}

# Check if file is already processed
is_processed() {
    local basename="$1"
    [[ -f "$STATE_FILE" ]] && grep -Fxq "$basename" "$STATE_FILE" && return 0
    return 1
}

# Check if file has exceeded max retries
exceeds_retry_limit() {
    local basename="$1"
    local retry_file="${FAILED_DIR}/${basename}.retries"
    if [[ ! -f "$retry_file" ]]; then
        return 1
    fi
    local count=$(cat "$retry_file" 2>/dev/null || echo 0)
    [[ $count -ge $MAX_RETRIES ]]
}

# Increment retry count
increment_retry_count() {
    local basename="$1"
    local retry_file="${FAILED_DIR}/${basename}.retries"
    local count=$(cat "$retry_file" 2>/dev/null || echo 0)
    echo $((count + 1)) > "$retry_file"
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
    # Accept everything else (videos, text files, folders, etc.)
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
    local basename
    basename=$(basename "$file")
    
    log "INFO" "Starting upload: $basename"
    
    # Run rclone move with progress
    if rclone move "$file" "${RCLONE_REMOTE}:${RCLONE_PATH}/" \
        --progress --stats=0 2>&1 | tee -a "$LOG_FILE"; then
        
        log "INFO" "Upload successful: $basename"
        
        # Create reference file (atomically)
        local remote_link="${UPLOAD_DIR}/${basename}.MOVED"
        local tmpref
        tmpref=$(mktemp)
        cat > "$tmpref" <<EOF
# File moved to remote storage
# Original file: ${basename}
# Moved to: ${RCLONE_REMOTE}:${RCLONE_PATH}/${basename}
# Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
        mv "$tmpref" "$remote_link"
        log "INFO" "Created reference: $remote_link"
        
        # Mark as processed (atomic)
        add_processed_file "$basename"
        rm -f "${FAILED_DIR}/${basename}.retries"
        
        return 0
    else
        log "ERROR" "Upload failed: $basename"
        return 1
    fi
}

acquire_lock

log "INFO" "Upload worker starting"
log "INFO" "Watching: $UPLOAD_DIR"
log "INFO" "Remote: ${RCLONE_REMOTE}:${RCLONE_PATH}"

while true; do
    # Scan for new files
    if [[ ! -d "${UPLOAD_DIR}" ]]; then
        sleep "$SCAN_INTERVAL"
        continue
    fi
    
    for file in "${UPLOAD_DIR}"/*; do
        # Skip if not a regular file
        [[ ! -f "$file" ]] && continue
        
        basename=$(basename "$file")
        
        # Skip if already processed
        if is_processed "$basename"; then
            continue
        fi
        
        # Skip if exceeds retry limit
        if exceeds_retry_limit "$basename"; then
            log "WARN" "Exceeded max retries ($MAX_RETRIES) for: $basename"
            continue
        fi
        
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
        
        # File is ready to upload
        if do_upload "$file"; then
            # Success - mark as processed (already done in do_upload)
            :
        else
            # Failure - increment retry count and maybe retry later
            increment_retry_count "$basename"
            current_retries=$(cat "${FAILED_DIR}/${basename}.retries" 2>/dev/null || echo 1)
            
            if [[ $current_retries -lt $MAX_RETRIES ]]; then
                backoff=$(calculate_backoff "$current_retries")
                log "WARN" "Retry $current_retries/$MAX_RETRIES for $basename (backoff: ${backoff}s)"
            fi
        fi
    done
    
    sleep "$SCAN_INTERVAL"
done







