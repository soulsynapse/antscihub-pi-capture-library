# shellcheck shell=bash
# antcam diagnostic helper functions
truncate_text_for_payload() {
    local input="${1:-}"
    local max_chars="${2:-16000}"
    local marker=" ...<truncated>... "

    if [[ "${max_chars}" -le 0 ]]; then
        printf '%s' ""
        return 0
    fi

    if [[ "${#input}" -le "${max_chars}" ]]; then
        printf '%s' "${input}"
        return 0
    fi

    local keep_each=$(( (max_chars - ${#marker}) / 2 ))
    if [[ "${keep_each}" -lt 0 ]]; then
        keep_each=0
    fi

    if [[ "${keep_each}" -eq 0 ]]; then
        printf '%s' "${input:0:${max_chars}}"
        return 0
    fi

    printf '%s%s%s' "${input:0:${keep_each}}" "${marker}" "${input: -${keep_each}}"
}

capture_subshell_output() {
    local out_var="$1"
    local rc_var="$2"
    shift 2

    local cmd_output cmd_rc
    set +e
    cmd_output="$( ( "$@" ) 2>&1 )"
    cmd_rc=$?
    set -e

    printf -v "${out_var}" '%s' "${cmd_output}"
    printf -v "${rc_var}" '%s' "${cmd_rc}"
}

read_file_tail_for_payload() {
    local file_path="$1"
    local lines="${2:-80}"

    if [[ -f "${file_path}" ]]; then
        tail -n "${lines}" "${file_path}" 2>/dev/null || cat "${file_path}" 2>/dev/null || true
    else
        printf '%s\n' "(file missing: ${file_path})"
    fi
}

report_upload_worker_process_snapshot() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -af 'upload_worker\.sh' 2>/dev/null || true
        return 0
    fi

    if command -v ps >/dev/null 2>&1; then
        ps -eo pid,ppid,etimes,cmd 2>/dev/null | awk '/upload_worker\.sh/ { print }' || true
        return 0
    fi

    printf '%s\n' "(pgrep/ps unavailable)"
}

report_upload_worker_cgroup_snapshot() {
    if ! command -v systemctl >/dev/null 2>&1; then
        printf '%s\n' "(systemctl unavailable)"
        return 0
    fi

    local cgroup_path
    cgroup_path="$(systemctl show "${DEFAULT_UPLOAD_SERVICE_NAME}" -p ControlGroup --value 2>/dev/null || true)"
    cgroup_path="$(printf '%s' "${cgroup_path}" | tr -d '[:space:]')"
    if [[ -z "${cgroup_path}" || "${cgroup_path}" == "/" ]]; then
        printf '%s\n' "(service control group unavailable)"
        return 0
    fi

    printf '%s\n' "control_group=${cgroup_path}"

    if command -v systemd-cgls >/dev/null 2>&1; then
        systemd-cgls --no-pager "${cgroup_path}" 2>/dev/null || true
        return 0
    fi

    if command -v ps >/dev/null 2>&1; then
        ps -eo pid,ppid,etimes,cgroup,cmd 2>/dev/null | awk -v cg="${cgroup_path}" 'index($0, cg) > 0 { print }' || true
        return 0
    fi

    printf '%s\n' "(systemd-cgls and ps unavailable)"
}

report_upload_worker_lock_snapshot() {
    local user_home queue_db state_dir lock_file lock_pid
    user_home="$(resolve_effective_home)" || user_home="${HOME}"
    queue_db="$(resolve_upload_queue_db_for_home "${user_home}")"
    state_dir="$(dirname "${queue_db}")"
    lock_file="${state_dir}/antscihub-upload.lock"

    echo "lock_file=${lock_file}"

    if [[ ! -e "${lock_file}" ]]; then
        echo "lock_file_exists=false"
        return 0
    fi

    echo "lock_file_exists=true"
    lock_pid="$(tr -d '[:space:]' < "${lock_file}" 2>/dev/null || true)"
    echo "lock_file_pid=${lock_pid}"

    if [[ -n "${lock_pid}" && "${lock_pid}" =~ ^[0-9]+$ ]] && kill -0 "${lock_pid}" 2>/dev/null; then
        echo "lock_pid_alive=true"
        if command -v ps >/dev/null 2>&1; then
            ps -o pid=,ppid=,etimes=,cmd= -p "${lock_pid}" 2>/dev/null || true
        fi
    else
        echo "lock_pid_alive=false"
    fi
}

report_upload_queue_db_diagnostic_for_home() {
    local user_home="$1"
    local queue_db
    queue_db="$(resolve_upload_queue_db_for_home "${user_home}")"
    echo "queue_db=${queue_db}"

    if [[ ! -f "${queue_db}" ]]; then
        echo "queue_db_exists=false"
        return 0
    fi
    echo "queue_db_exists=true"

    if command -v stat >/dev/null 2>&1; then
        echo "queue_db_stat=$(stat -c '%i|%s|%Y|%n' "${queue_db}" 2>/dev/null || true)"
    fi

    if ! command -v sqlite3 >/dev/null 2>&1; then
        echo "sqlite3_available=false"
        return 0
    fi
    echo "sqlite3_available=true"

    local quick_check journal_mode locking_mode artifacts_total
    quick_check="$(sqlite3 -noheader "${queue_db}" "PRAGMA quick_check;" 2>/dev/null | tr '\n' ';' || true)"
    journal_mode="$(sqlite3 -noheader "${queue_db}" "PRAGMA journal_mode;" 2>/dev/null | head -n 1 || true)"
    locking_mode="$(sqlite3 -noheader "${queue_db}" "PRAGMA locking_mode;" 2>/dev/null | head -n 1 || true)"
    artifacts_total="$(sqlite3 -noheader "${queue_db}" "SELECT COUNT(*) FROM artifacts;" 2>/dev/null || true)"
    echo "sqlite_quick_check=${quick_check:-unknown}"
    echo "sqlite_journal_mode=${journal_mode:-unknown}"
    echo "sqlite_locking_mode=${locking_mode:-unknown}"
    echo "artifacts_total=${artifacts_total:-unknown}"

    echo "status_counts_begin"
    while IFS='|' read -r status_name status_count; do
        [[ -n "${status_name}" ]] || continue
        echo "status_${status_name,,}=${status_count}"
    done < <(sqlite3 -separator '|' -noheader "${queue_db}" "SELECT status, COUNT(*) FROM artifacts GROUP BY status ORDER BY status;" 2>/dev/null || true)
    echo "status_counts_end"

    echo "duplicate_relative_paths_begin"
    sqlite3 -separator '|' -noheader "${queue_db}" \
        "SELECT relative_path, COUNT(*) FROM artifacts GROUP BY relative_path HAVING COUNT(*) > 1 ORDER BY COUNT(*) DESC, relative_path ASC LIMIT 40;" \
        2>/dev/null || true
    echo "duplicate_relative_paths_end"

    echo "repeated_success_attempts_begin"
    sqlite3 -separator '|' -noheader "${queue_db}" \
        "SELECT a.relative_path, t.target_name, COUNT(*) FROM attempt_log t JOIN artifacts a ON a.id=t.artifact_id WHERE t.action='success' GROUP BY a.relative_path, t.target_name HAVING COUNT(*) > 1 ORDER BY COUNT(*) DESC, a.relative_path ASC LIMIT 40;" \
        2>/dev/null || true
    echo "repeated_success_attempts_end"

    echo "recent_pending_artifacts_begin"
    sqlite3 -separator '|' -noheader "${queue_db}" \
        "SELECT id, status, retry_count, next_retry_epoch, last_attempt_epoch, relative_path FROM artifacts WHERE status IN ('QUEUED','RETRY_WAIT','IN_FLIGHT') ORDER BY discovered_at_epoch ASC LIMIT 40;" \
        2>/dev/null || true
    echo "recent_pending_artifacts_end"
}

report_upload_worker_start_counters_for_home() {
    local user_home="$1"
    local upload_worker_log_file
    upload_worker_log_file="${user_home%/}/.local/state/antscihub-upload/antscihub-upload.log"

    local journal_starts="n/a" log_starts="n/a"
    if command -v journalctl >/dev/null 2>&1; then
        journal_starts="$(journalctl -u "${DEFAULT_UPLOAD_SERVICE_NAME}" --since '-24 hours' --no-pager 2>/dev/null | grep -c 'Upload worker starting' || true)"
    fi
    if [[ -f "${upload_worker_log_file}" ]]; then
        log_starts="$(grep -c 'Upload worker starting' "${upload_worker_log_file}" 2>/dev/null || true)"
    fi

    echo "journal_upload_worker_start_count_24h=${journal_starts}"
    echo "log_upload_worker_start_count_total=${log_starts}"
}

report_upload_worker_repeat_summary_for_home() {
    local user_home="$1"
    local upload_worker_log_file
    upload_worker_log_file="${user_home%/}/.local/state/antscihub-upload/antscihub-upload.log"

    if [[ ! -f "${upload_worker_log_file}" ]]; then
        echo "upload_worker_log_exists=false"
        return 0
    fi
    echo "upload_worker_log_exists=true"

    if ! command -v awk >/dev/null 2>&1; then
        echo "awk_available=false"
        return 0
    fi
    echo "awk_available=true"

    echo "repeat_queue_candidates_begin"
    awk '
        /Queued file candidate:/ {
            split($0, parts, "Queued file candidate: ")
            if (length(parts) >= 2) {
                split(parts[2], p2, " \\(size=")
                path=p2[1]
                q[path]++
            }
        }
        END {
            for (k in q) {
                if (q[k] > 1) {
                    printf "%s|%d\n", k, q[k]
                }
            }
        }
    ' "${upload_worker_log_file}" 2>/dev/null | sort -t '|' -k2,2nr | head -n 40 || true
    echo "repeat_queue_candidates_end"

    echo "repeat_existing_destination_hits_begin"
    awk '
        /destination already had file; treated as shipped:/ {
            split($0, parts, "treated as shipped: ")
            if (length(parts) >= 2) {
                path=parts[2]
                s[path]++
            }
        }
        END {
            for (k in s) {
                if (s[k] > 1) {
                    printf "%s|%d\n", k, s[k]
                }
            }
        }
    ' "${upload_worker_log_file}" 2>/dev/null | sort -t '|' -k2,2nr | head -n 40 || true
    echo "repeat_existing_destination_hits_end"
}

report_diagnostic_payload() {
    local user_home effective_user
    user_home="$(resolve_effective_home)" || die "could not resolve user home for diagnostic"
    effective_user="$(resolve_effective_user || true)"
    [[ -n "${effective_user}" ]] || effective_user="$(id -un)"

    local capture_dir upload_dir queue_db state_file recording_last_start_state_file upload_worker_log_file
    local focus_file fps_file length_file segment_file loop_file
    capture_dir="$(resolve_capture_dir_for_home "${user_home}")"
    upload_dir="$(resolve_upload_dir_for_home "${user_home}")"
    queue_db="$(resolve_upload_queue_db_for_home "${user_home}")"
    state_file="$(resolve_recording_state_file_for_home "${user_home}")"
    recording_last_start_state_file="$(resolve_recording_last_start_state_file_for_home "${user_home}")"
    upload_worker_log_file="${user_home%/}/.local/state/antscihub-upload/antscihub-upload.log"
    focus_file="$(resolve_focus_value_file_for_home "${user_home}")"
    fps_file="$(resolve_fps_value_file_for_home "${user_home}")"
    length_file="$(resolve_length_value_file_for_home "${user_home}")"
    segment_file="$(resolve_segment_value_file_for_home "${user_home}")"
    loop_file="$(resolve_loop_value_file_for_home "${user_home}")"

    local capture_report capture_rc
    local upload_settings_report upload_settings_rc
    local upload_targets_report upload_targets_rc
    local upload_queue_report upload_queue_rc
    local camera_report camera_rc
    capture_subshell_output capture_report capture_rc report_capture_settings
    capture_subshell_output upload_settings_report upload_settings_rc report_upload_settings
    capture_subshell_output upload_targets_report upload_targets_rc report_upload_targets
    capture_subshell_output upload_queue_report upload_queue_rc report_upload_queue
    capture_subshell_output camera_report camera_rc report_camera_make_model

    local photos_script_path photos_script_rc video_script_path video_script_rc
    capture_subshell_output photos_script_path photos_script_rc resolve_recording_script_path photos
    capture_subshell_output video_script_path video_script_rc resolve_recording_script_path video

    local service_active="" service_active_rc=127
    local service_enabled="" service_enabled_rc=127
    local service_show="" service_show_rc=127
    local service_mainpid="" service_mainpid_rc=127
    local service_journal="" service_journal_rc=127
    local service_health="" service_health_rc=127
    if command -v systemctl >/dev/null 2>&1; then
        capture_subshell_output service_active service_active_rc systemctl is-active "${DEFAULT_UPLOAD_SERVICE_NAME}"
        capture_subshell_output service_enabled service_enabled_rc systemctl is-enabled "${DEFAULT_UPLOAD_SERVICE_NAME}"
        capture_subshell_output service_mainpid service_mainpid_rc systemctl show "${DEFAULT_UPLOAD_SERVICE_NAME}" -p MainPID --value
        capture_subshell_output service_show service_show_rc systemctl show "${DEFAULT_UPLOAD_SERVICE_NAME}" -p ActiveState -p SubState -p Result -p ExecMainStatus -p MainPID -p FragmentPath -p Environment --value
        capture_subshell_output service_health service_health_rc systemctl show "${DEFAULT_UPLOAD_SERVICE_NAME}" -p NRestarts -p Restart -p RestartUSec -p ExecMainCode -p ExecMainStatus -p ExecMainStartTimestamp -p ExecMainExitTimestamp -p ActiveEnterTimestamp -p ActiveExitTimestamp -p StateChangeTimestamp -p InvocationID -p ControlGroup --value
    fi
    if command -v journalctl >/dev/null 2>&1; then
        capture_subshell_output service_journal service_journal_rc journalctl -u "${DEFAULT_UPLOAD_SERVICE_NAME}" -n 120 --no-pager
    fi

    local upload_worker_log_tail recording_state_tail recording_last_start_state_tail
    upload_worker_log_tail="$(read_file_tail_for_payload "${upload_worker_log_file}" 120)"
    recording_state_tail="$(read_file_tail_for_payload "${state_file}" 80)"
    recording_last_start_state_tail="$(read_file_tail_for_payload "${recording_last_start_state_file}" 120)"

    local upload_worker_processes upload_worker_processes_rc
    capture_subshell_output upload_worker_processes upload_worker_processes_rc report_upload_worker_process_snapshot

    local upload_worker_cgroup_snapshot upload_worker_cgroup_snapshot_rc
    capture_subshell_output upload_worker_cgroup_snapshot upload_worker_cgroup_snapshot_rc report_upload_worker_cgroup_snapshot

    local upload_worker_lock_snapshot upload_worker_lock_snapshot_rc
    capture_subshell_output upload_worker_lock_snapshot upload_worker_lock_snapshot_rc report_upload_worker_lock_snapshot

    local upload_queue_db_diagnostic upload_queue_db_diagnostic_rc
    capture_subshell_output upload_queue_db_diagnostic upload_queue_db_diagnostic_rc report_upload_queue_db_diagnostic_for_home "${user_home}"

    local upload_worker_start_counters upload_worker_start_counters_rc
    capture_subshell_output upload_worker_start_counters upload_worker_start_counters_rc report_upload_worker_start_counters_for_home "${user_home}"

    local upload_worker_repeat_summary upload_worker_repeat_summary_rc
    capture_subshell_output upload_worker_repeat_summary upload_worker_repeat_summary_rc report_upload_worker_repeat_summary_for_home "${user_home}"

    service_mainpid="$(printf '%s' "${service_mainpid}" | tr -d '[:space:]')"
    local upload_worker_pid_list upload_worker_process_count mainpid_present orphan_worker_pids
    upload_worker_pid_list="$(printf '%s\n' "${upload_worker_processes}" | awk '{print $1}' | grep -E '^[0-9]+$' | paste -sd ',' - 2>/dev/null || true)"
    upload_worker_process_count="$(printf '%s\n' "${upload_worker_processes}" | awk '{ if ($1 ~ /^[0-9]+$/) c++ } END { print c+0 }')"
    mainpid_present="false"
    orphan_worker_pids=""
    if [[ -n "${service_mainpid}" && "${service_mainpid}" != "0" ]]; then
        if printf '%s\n' "${upload_worker_processes}" | awk -v p="${service_mainpid}" '$1 == p { found=1 } END { exit(found ? 0 : 1) }'; then
            mainpid_present="true"
        fi
    fi
    orphan_worker_pids="$(printf '%s\n' "${upload_worker_processes}" | awk -v p="${service_mainpid}" '
        $1 ~ /^[0-9]+$/ {
            if (p == "" || p == "0" || $1 != p) {
                out = (out == "" ? $1 : out "," $1)
            }
        }
        END { print out }
    ')"

    local legacy_upload_unit_scan legacy_upload_unit_scan_rc
    legacy_upload_unit_scan=""
    legacy_upload_unit_scan_rc=127
    if command -v systemctl >/dev/null 2>&1; then
        capture_subshell_output legacy_upload_unit_scan legacy_upload_unit_scan_rc systemctl list-units --type=service --all
        legacy_upload_unit_scan="$(printf '%s\n' "${legacy_upload_unit_scan}" | awk '/antscihub/ && /upload/ { print }')"
    fi

    local focus_file_text fps_file_text length_file_text segment_file_text loop_file_text
    focus_file_text="$(read_file_tail_for_payload "${focus_file}" 20)"
    fps_file_text="$(read_file_tail_for_payload "${fps_file}" 20)"
    length_file_text="$(read_file_tail_for_payload "${length_file}" 20)"
    segment_file_text="$(read_file_tail_for_payload "${segment_file}" 20)"
    loop_file_text="$(read_file_tail_for_payload "${loop_file}" 20)"

    local upload_dir_df upload_dir_df_rc upload_dir_du upload_dir_du_rc
    upload_dir_df=""
    upload_dir_du=""
    upload_dir_df_rc=127
    upload_dir_du_rc=127
    if [[ -d "${upload_dir}" ]]; then
        capture_subshell_output upload_dir_df upload_dir_df_rc df -h "${upload_dir}"
        capture_subshell_output upload_dir_du upload_dir_du_rc du -sh "${upload_dir}"
    fi

    local recent_upload_files=""
    if [[ -d "${upload_dir}" ]]; then
        recent_upload_files="$(find "${upload_dir}" -maxdepth 2 -type f 2>/dev/null | tail -n 120 || true)"
    fi

    local hostname_value kernel_value date_utc now_epoch
    hostname_value="$(hostname 2>/dev/null || true)"
    kernel_value="$(uname -a 2>/dev/null || true)"
    date_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    now_epoch="$(date +%s)"

    resolve_device_id >/dev/null
    local device_id topic
    device_id="${DEVICE_ID_CACHE}"
    topic="$(build_fleet_event_topic "${device_id}")"

    capture_report="$(truncate_text_for_payload "${capture_report}" 20000)"
    upload_settings_report="$(truncate_text_for_payload "${upload_settings_report}" 20000)"
    upload_targets_report="$(truncate_text_for_payload "${upload_targets_report}" 12000)"
    upload_queue_report="$(truncate_text_for_payload "${upload_queue_report}" 20000)"
    camera_report="$(truncate_text_for_payload "${camera_report}" 4000)"
    photos_script_path="$(truncate_text_for_payload "${photos_script_path}" 4000)"
    video_script_path="$(truncate_text_for_payload "${video_script_path}" 4000)"
    service_active="$(truncate_text_for_payload "${service_active}" 4000)"
    service_enabled="$(truncate_text_for_payload "${service_enabled}" 4000)"
    service_show="$(truncate_text_for_payload "${service_show}" 20000)"
    service_health="$(truncate_text_for_payload "${service_health}" 16000)"
    service_mainpid="$(truncate_text_for_payload "${service_mainpid}" 2000)"
    service_journal="$(truncate_text_for_payload "${service_journal}" 20000)"
    upload_worker_log_tail="$(truncate_text_for_payload "${upload_worker_log_tail}" 20000)"
    upload_worker_processes="$(truncate_text_for_payload "${upload_worker_processes}" 12000)"
    upload_worker_cgroup_snapshot="$(truncate_text_for_payload "${upload_worker_cgroup_snapshot}" 16000)"
    upload_worker_lock_snapshot="$(truncate_text_for_payload "${upload_worker_lock_snapshot}" 8000)"
    upload_queue_db_diagnostic="$(truncate_text_for_payload "${upload_queue_db_diagnostic}" 20000)"
    upload_worker_start_counters="$(truncate_text_for_payload "${upload_worker_start_counters}" 8000)"
    upload_worker_repeat_summary="$(truncate_text_for_payload "${upload_worker_repeat_summary}" 20000)"
    upload_worker_pid_list="$(truncate_text_for_payload "${upload_worker_pid_list}" 2000)"
    orphan_worker_pids="$(truncate_text_for_payload "${orphan_worker_pids}" 2000)"
    legacy_upload_unit_scan="$(truncate_text_for_payload "${legacy_upload_unit_scan}" 12000)"
    recording_state_tail="$(truncate_text_for_payload "${recording_state_tail}" 12000)"
    recording_last_start_state_tail="$(truncate_text_for_payload "${recording_last_start_state_tail}" 12000)"
    focus_file_text="$(truncate_text_for_payload "${focus_file_text}" 4000)"
    fps_file_text="$(truncate_text_for_payload "${fps_file_text}" 4000)"
    length_file_text="$(truncate_text_for_payload "${length_file_text}" 4000)"
    segment_file_text="$(truncate_text_for_payload "${segment_file_text}" 4000)"
    loop_file_text="$(truncate_text_for_payload "${loop_file_text}" 4000)"
    upload_dir_df="$(truncate_text_for_payload "${upload_dir_df}" 8000)"
    upload_dir_du="$(truncate_text_for_payload "${upload_dir_du}" 4000)"
    recent_upload_files="$(truncate_text_for_payload "${recent_upload_files}" 20000)"

    local payload
    payload="{\"event\":\"report\""
    payload+=",\"report\":\"antcam_diagnostic\""
    payload+=",\"device_id\":\"$(json_escape "${device_id}")\""
    payload+=",\"timestamp\":${now_epoch}"
    payload+=",\"timestamp_utc\":\"$(json_escape "${date_utc}")\""
    payload+=",\"severity\":\"INFO\""
    payload+=",\"success\":true"
    payload+=",\"service\":\"antcam-cli\""
    payload+=",\"topic\":\"$(json_escape "${topic}")\""
    payload+=",\"message\":\"AntCam diagnostic payload\""
    payload+=",\"diagnostic_version\":\"3\""
    payload+=",\"host\":\"$(json_escape "${hostname_value}")\""
    payload+=",\"kernel\":\"$(json_escape "${kernel_value}")\""
    payload+=",\"effective_user\":\"$(json_escape "${effective_user}")\""
    payload+=",\"effective_home\":\"$(json_escape "${user_home}")\""
    payload+=",\"capture_dir\":\"$(json_escape "${capture_dir}")\""
    payload+=",\"upload_dir\":\"$(json_escape "${upload_dir}")\""
    payload+=",\"queue_db\":\"$(json_escape "${queue_db}")\""
    payload+=",\"recording_state_file\":\"$(json_escape "${state_file}")\""
    payload+=",\"recording_last_start_state_file\":\"$(json_escape "${recording_last_start_state_file}")\""
    payload+=",\"upload_worker_log_file\":\"$(json_escape "${upload_worker_log_file}")\""
    payload+=",\"capture_report_rc\":\"$(json_escape "${capture_rc}")\""
    payload+=",\"upload_settings_report_rc\":\"$(json_escape "${upload_settings_rc}")\""
    payload+=",\"upload_targets_report_rc\":\"$(json_escape "${upload_targets_rc}")\""
    payload+=",\"upload_queue_report_rc\":\"$(json_escape "${upload_queue_rc}")\""
    payload+=",\"camera_report_rc\":\"$(json_escape "${camera_rc}")\""
    payload+=",\"photos_script_resolve_rc\":\"$(json_escape "${photos_script_rc}")\""
    payload+=",\"video_script_resolve_rc\":\"$(json_escape "${video_script_rc}")\""
    payload+=",\"upload_service_active_rc\":\"$(json_escape "${service_active_rc}")\""
    payload+=",\"upload_service_enabled_rc\":\"$(json_escape "${service_enabled_rc}")\""
    payload+=",\"upload_service_show_rc\":\"$(json_escape "${service_show_rc}")\""
    payload+=",\"upload_service_health_rc\":\"$(json_escape "${service_health_rc}")\""
    payload+=",\"upload_service_mainpid_rc\":\"$(json_escape "${service_mainpid_rc}")\""
    payload+=",\"upload_service_journal_rc\":\"$(json_escape "${service_journal_rc}")\""
    payload+=",\"upload_worker_processes_rc\":\"$(json_escape "${upload_worker_processes_rc}")\""
    payload+=",\"upload_worker_cgroup_snapshot_rc\":\"$(json_escape "${upload_worker_cgroup_snapshot_rc}")\""
    payload+=",\"upload_worker_lock_snapshot_rc\":\"$(json_escape "${upload_worker_lock_snapshot_rc}")\""
    payload+=",\"upload_queue_db_diagnostic_rc\":\"$(json_escape "${upload_queue_db_diagnostic_rc}")\""
    payload+=",\"upload_worker_start_counters_rc\":\"$(json_escape "${upload_worker_start_counters_rc}")\""
    payload+=",\"upload_worker_repeat_summary_rc\":\"$(json_escape "${upload_worker_repeat_summary_rc}")\""
    payload+=",\"legacy_upload_unit_scan_rc\":\"$(json_escape "${legacy_upload_unit_scan_rc}")\""
    payload+=",\"upload_worker_process_count\":\"$(json_escape "${upload_worker_process_count}")\""
    payload+=",\"upload_worker_mainpid_present\":\"$(json_escape "${mainpid_present}")\""
    payload+=",\"upload_dir_df_rc\":\"$(json_escape "${upload_dir_df_rc}")\""
    payload+=",\"upload_dir_du_rc\":\"$(json_escape "${upload_dir_du_rc}")\""
    payload+=",\"camera_report_raw\":\"$(json_escape "${camera_report}")\""
    payload+=",\"capture_report_raw\":\"$(json_escape "${capture_report}")\""
    payload+=",\"upload_settings_report_raw\":\"$(json_escape "${upload_settings_report}")\""
    payload+=",\"upload_targets_report_raw\":\"$(json_escape "${upload_targets_report}")\""
    payload+=",\"upload_queue_report_raw\":\"$(json_escape "${upload_queue_report}")\""
    payload+=",\"photos_script_path_raw\":\"$(json_escape "${photos_script_path}")\""
    payload+=",\"video_script_path_raw\":\"$(json_escape "${video_script_path}")\""
    payload+=",\"upload_service_active_raw\":\"$(json_escape "${service_active}")\""
    payload+=",\"upload_service_enabled_raw\":\"$(json_escape "${service_enabled}")\""
    payload+=",\"upload_service_mainpid_raw\":\"$(json_escape "${service_mainpid}")\""
    payload+=",\"upload_service_show_raw\":\"$(json_escape "${service_show}")\""
    payload+=",\"upload_service_health_raw\":\"$(json_escape "${service_health}")\""
    payload+=",\"upload_service_journal_raw\":\"$(json_escape "${service_journal}")\""
    payload+=",\"upload_worker_processes_raw\":\"$(json_escape "${upload_worker_processes}")\""
    payload+=",\"upload_worker_cgroup_snapshot_raw\":\"$(json_escape "${upload_worker_cgroup_snapshot}")\""
    payload+=",\"upload_worker_lock_snapshot_raw\":\"$(json_escape "${upload_worker_lock_snapshot}")\""
    payload+=",\"upload_queue_db_diagnostic_raw\":\"$(json_escape "${upload_queue_db_diagnostic}")\""
    payload+=",\"upload_worker_start_counters_raw\":\"$(json_escape "${upload_worker_start_counters}")\""
    payload+=",\"upload_worker_repeat_summary_raw\":\"$(json_escape "${upload_worker_repeat_summary}")\""
    payload+=",\"upload_worker_pid_list_raw\":\"$(json_escape "${upload_worker_pid_list}")\""
    payload+=",\"upload_worker_orphan_pids_raw\":\"$(json_escape "${orphan_worker_pids}")\""
    payload+=",\"legacy_upload_units_raw\":\"$(json_escape "${legacy_upload_unit_scan}")\""
    payload+=",\"upload_worker_log_tail_raw\":\"$(json_escape "${upload_worker_log_tail}")\""
    payload+=",\"recording_state_tail_raw\":\"$(json_escape "${recording_state_tail}")\""
    payload+=",\"recording_last_start_state_tail_raw\":\"$(json_escape "${recording_last_start_state_tail}")\""
    payload+=",\"focus_file\":\"$(json_escape "${focus_file}")\""
    payload+=",\"focus_file_raw\":\"$(json_escape "${focus_file_text}")\""
    payload+=",\"fps_file\":\"$(json_escape "${fps_file}")\""
    payload+=",\"fps_file_raw\":\"$(json_escape "${fps_file_text}")\""
    payload+=",\"length_file\":\"$(json_escape "${length_file}")\""
    payload+=",\"length_file_raw\":\"$(json_escape "${length_file_text}")\""
    payload+=",\"segment_file\":\"$(json_escape "${segment_file}")\""
    payload+=",\"segment_file_raw\":\"$(json_escape "${segment_file_text}")\""
    payload+=",\"loop_file\":\"$(json_escape "${loop_file}")\""
    payload+=",\"loop_file_raw\":\"$(json_escape "${loop_file_text}")\""
    payload+=",\"upload_dir_df_raw\":\"$(json_escape "${upload_dir_df}")\""
    payload+=",\"upload_dir_du_raw\":\"$(json_escape "${upload_dir_du}")\""
    payload+=",\"recent_upload_files_raw\":\"$(json_escape "${recent_upload_files}")\""
    payload+="}"

    local diagnostic_file_path
    diagnostic_file_path="$(write_antcam_diagnostic_payload_file "${user_home}" "${payload}" || true)"
    if [[ -n "${diagnostic_file_path}" ]]; then
        echo "diagnostic_payload_file=${diagnostic_file_path}"
        return 0
    fi

    die "failed to write diagnostic payload file"
}
