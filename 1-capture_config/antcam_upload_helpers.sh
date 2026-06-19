# shellcheck shell=bash
# antcam upload/settings helper functions
read_upload_service_env_value() {
    local env_key="$1"
    local service_name="${DEFAULT_UPLOAD_SERVICE_NAME}"
    local env_blob

    command -v systemctl >/dev/null 2>&1 || return 1
    env_blob="$(systemctl show "${service_name}" -p Environment --value 2>/dev/null || true)"
    [[ -n "${env_blob}" ]] || return 1

    if command -v python3 >/dev/null 2>&1; then
        python3 - "${env_key}" "${env_blob}" <<'PY' 2>/dev/null || return 1
import shlex
import sys

key = sys.argv[1]
blob = sys.argv[2]
needle = f"{key}="

for token in shlex.split(blob):
    if token.startswith(needle):
        print(token[len(needle):])
        raise SystemExit(0)

raise SystemExit(1)
PY
        return 0
    fi

    local token
    for token in ${env_blob}; do
        case "${token}" in
            "${env_key}"=*)
                printf '%s\n' "${token#*=}"
                return 0
                ;;
        esac
    done
    return 1
}

write_antcam_diagnostic_payload_file() {
    local user_home="$1"
    local payload="$2"

    local upload_dir timestamp_utc timestamp_slug device_id
    local target_subdir primary_dir primary_file fallback_dir fallback_file
    upload_dir="$(resolve_upload_dir_for_home "${user_home}")"

    timestamp_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    timestamp_slug="$(date -u +%Y%m%dT%H%M%SZ)"
    resolve_device_id >/dev/null
    device_id="${DEVICE_ID_CACHE}"
    target_subdir="diagnostics/recordings"

    primary_dir="${upload_dir}/${target_subdir}"
    primary_file="${primary_dir}/antcam-diagnostic-${device_id}-${timestamp_slug}.json"
    fallback_dir="${upload_dir}/diagnostics"
    fallback_file="${fallback_dir}/antcam-diagnostic-write-fallback-${device_id}-${timestamp_slug}.log"

    if mkdir -p "${primary_dir}" && printf '%s\n' "${payload}" > "${primary_file}"; then
        echo "wrote antcam diagnostic payload: ${primary_file}" >&2
        printf '%s\n' "${primary_file}"
        return 0
    fi

    if mkdir -p "${fallback_dir}"; then
        {
            echo "# AntCam Diagnostic Write Fallback"
            echo "timestamp_utc=${timestamp_utc}"
            echo "device_id=${device_id}"
            echo "intended_path=${primary_file}"
            echo "reason=failed_to_write_primary_diagnostic"
            echo
            echo "## Diagnostic Payload"
            printf '%s\n' "${payload}"
        } > "${fallback_file}"
        echo "wrote fallback diagnostic payload: ${fallback_file}" >&2
        printf '%s\n' "${fallback_file}"
        return 0
    fi

    echo "antcam: warning: unable to write diagnostic payload to ${primary_dir} or fallback diagnostics folder" >&2
    return 1
}

read_transcode_video_effective_for_home() {
    local user_home="$1"
    local setting_file transcode_value fallback_value
    setting_file="$(resolve_transcode_video_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "UPLOAD_TRANSCODE_VIDEO" || true)"
    fallback_value="$(normalize_transcode_video_value "${fallback_value}")"
    if ! is_valid_transcode_video_value "${fallback_value}"; then
        fallback_value="${DEFAULT_TRANSCODE_VIDEO}"
    fi

    transcode_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    transcode_value="$(normalize_transcode_video_value "${transcode_value}")"
    is_valid_transcode_video_value "${transcode_value}" || die "invalid transcode-video in ${setting_file}: ${transcode_value} (expected off|mux|crf:N)"
    printf '%s\n' "${transcode_value}"
}

set_transcode_video_for_home() {
    local user_home="$1"
    local transcode_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_transcode_video_value "${transcode_value}")"
    is_valid_transcode_video_value "${normalized_value}" || die "invalid transcode-video: ${transcode_value} (expected off|mux|crf:N where N is 0-51)"
    setting_file="$(resolve_transcode_video_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_transcode_video_value() {
    local transcode_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for transcode settings"

    local transcode_file normalized_transcode
    transcode_file="$(set_transcode_video_for_home "${user_home}" "${transcode_value}")"
    normalized_transcode="$(read_transcode_video_for_home "${user_home}")"
    echo "transcode-video set to ${normalized_transcode}"
    echo "transcode-video settings file: ${transcode_file}"
}

report_transcode_video_value() {
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for transcode settings"

    local transcode_value transcode_file
    transcode_value="$(read_transcode_video_effective_for_home "${user_home}")"
    transcode_file="$(resolve_transcode_video_file_for_home "${user_home}")"
    echo "transcode_video=${transcode_value}"
    echo "transcode_video_settings_file=${transcode_file}"
}

read_upload_effective_profile_for_home() {
    local user_home="$1"
    local setting_file profile_value fallback_value
    setting_file="$(resolve_upload_profile_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "UPLOAD_PROFILE" || true)"
    fallback_value="$(normalize_upload_profile_value "${fallback_value}")"
    if ! is_valid_upload_profile_value "${fallback_value}"; then
        fallback_value="${DEFAULT_UPLOAD_PROFILE}"
    fi

    profile_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    profile_value="$(normalize_upload_profile_value "${profile_value}")"
    is_valid_upload_profile_value "${profile_value}" || die "invalid upload profile in ${setting_file}: ${profile_value} (expected field|cloud|local)"
    printf '%s\n' "${profile_value}"
}

read_upload_effective_retention_for_home() {
    local user_home="$1"
    local setting_file retention_value fallback_value
    setting_file="$(resolve_upload_retention_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "UPLOAD_RETENTION" || true)"
    fallback_value="$(normalize_upload_retention_value "${fallback_value}")"
    if ! is_valid_upload_retention_value "${fallback_value}"; then
        fallback_value="${DEFAULT_UPLOAD_RETENTION}"
    fi

    retention_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    retention_value="$(normalize_upload_retention_value "${retention_value}")"
    is_valid_upload_retention_value "${retention_value}" || die "invalid upload retention in ${setting_file}: ${retention_value} (expected protect|rolling)"
    printf '%s\n' "${retention_value}"
}

read_upload_effective_paused_for_home() {
    local user_home="$1"
    local setting_file paused_value fallback_value
    setting_file="$(resolve_upload_paused_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "UPLOAD_PAUSED" || true)"
    fallback_value="$(normalize_upload_boolean_value "${fallback_value}" || true)"
    if [[ -z "${fallback_value}" ]]; then
        fallback_value="${DEFAULT_UPLOAD_PAUSED}"
    fi

    paused_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    paused_value="$(normalize_upload_boolean_value "${paused_value}" || true)"
    [[ -n "${paused_value}" ]] || die "invalid upload paused flag in ${setting_file} (expected true|false)"
    printf '%s\n' "${paused_value}"
}

read_upload_effective_local_target_for_home() {
    local user_home="$1"
    local setting_file target_value fallback_value
    setting_file="$(resolve_upload_local_target_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "UPLOAD_LOCAL_TARGET_PATH" || true)"
    fallback_value="$(normalize_upload_text_value "${fallback_value}")"
    target_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    target_value="$(normalize_upload_text_value "${target_value}")"
    if [[ "${target_value,,}" == "none" ]]; then
        target_value=""
    fi
    printf '%s\n' "${target_value}"
}

read_upload_effective_rclone_remote_for_home() {
    local user_home="$1"
    local setting_file remote_value fallback_value
    setting_file="$(resolve_upload_rclone_remote_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "RCLONE_REMOTE" || true)"
    fallback_value="$(normalize_upload_text_value "${fallback_value}")"
    remote_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    remote_value="$(normalize_upload_text_value "${remote_value}")"
    if [[ "${remote_value,,}" == "none" ]]; then
        remote_value=""
    fi
    printf '%s\n' "${remote_value}"
}

read_upload_effective_rclone_path_for_home() {
    local user_home="$1"
    local setting_file path_value fallback_value
    setting_file="$(resolve_upload_rclone_path_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "RCLONE_PATH" || true)"
    fallback_value="$(normalize_upload_text_value "${fallback_value}")"
    path_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    path_value="$(normalize_upload_text_value "${path_value}")"
    if [[ "${path_value,,}" == "none" ]]; then
        path_value=""
    fi
    path_value="${path_value#/}"
    path_value="${path_value%/}"
    if [[ "${path_value}" == "." ]]; then
        path_value=""
    fi
    printf '%s\n' "${path_value}"
}

read_upload_effective_high_watermark_for_home() {
    local user_home="$1"
    local setting_file high_value fallback_value
    setting_file="$(resolve_upload_high_watermark_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "UPLOAD_HIGH_WATERMARK_PERCENT" || true)"
    fallback_value="$(normalize_upload_watermark_value "${fallback_value}" || true)"
    if [[ -z "${fallback_value}" ]]; then
        fallback_value="${DEFAULT_UPLOAD_HIGH_WATERMARK_PERCENT}"
    fi

    high_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    high_value="$(normalize_upload_watermark_value "${high_value}" || true)"
    [[ -n "${high_value}" ]] || die "invalid upload high watermark in ${setting_file} (expected integer 1-99)"
    printf '%s\n' "${high_value}"
}

read_upload_effective_low_watermark_for_home() {
    local user_home="$1"
    local setting_file low_value fallback_value
    setting_file="$(resolve_upload_low_watermark_file_for_home "${user_home}")"

    fallback_value="$(read_upload_service_env_value "UPLOAD_LOW_WATERMARK_PERCENT" || true)"
    fallback_value="$(normalize_upload_watermark_value "${fallback_value}" || true)"
    if [[ -z "${fallback_value}" ]]; then
        fallback_value="${DEFAULT_UPLOAD_LOW_WATERMARK_PERCENT}"
    fi

    low_value="$(read_setting_value_with_default "${setting_file}" "${fallback_value}")"
    low_value="$(normalize_upload_watermark_value "${low_value}" || true)"
    [[ -n "${low_value}" ]] || die "invalid upload low watermark in ${setting_file} (expected integer 1-99)"
    printf '%s\n' "${low_value}"
}

set_upload_profile_for_home() {
    local user_home="$1"
    local profile_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_profile_value "${profile_value}")"
    is_valid_upload_profile_value "${normalized_value}" || die "invalid upload profile: ${profile_value} (expected field|cloud|local)"
    setting_file="$(resolve_upload_profile_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_upload_retention_for_home() {
    local user_home="$1"
    local retention_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_retention_value "${retention_value}")"
    is_valid_upload_retention_value "${normalized_value}" || die "invalid upload retention: ${retention_value} (expected protect|rolling)"
    setting_file="$(resolve_upload_retention_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_upload_paused_for_home() {
    local user_home="$1"
    local paused_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_boolean_value "${paused_value}" || true)"
    [[ -n "${normalized_value}" ]] || die "invalid upload paused flag: ${paused_value} (expected true|false)"
    setting_file="$(resolve_upload_paused_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_upload_local_target_for_home() {
    local user_home="$1"
    local target_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_text_value "${target_value}")"
    if [[ "${normalized_value,,}" == "none" ]]; then
        normalized_value=""
    fi
    if [[ -n "${normalized_value}" ]] && ! is_valid_upload_target_path_value "${normalized_value}"; then
        die "invalid upload local target: ${target_value}"
    fi
    setting_file="$(resolve_upload_local_target_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_upload_rclone_remote_for_home() {
    local user_home="$1"
    local remote_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_text_value "${remote_value}")"
    if [[ "${normalized_value,,}" == "none" ]]; then
        normalized_value=""
    fi
    if [[ -n "${normalized_value}" ]] && ! is_valid_upload_remote_value "${normalized_value}"; then
        die "invalid upload remote: ${remote_value}"
    fi
    setting_file="$(resolve_upload_rclone_remote_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_upload_rclone_path_for_home() {
    local user_home="$1"
    local path_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_text_value "${path_value}")"
    if [[ "${normalized_value,,}" == "none" ]]; then
        normalized_value=""
    fi
    normalized_value="${normalized_value#/}"
    normalized_value="${normalized_value%/}"
    if [[ "${normalized_value}" == "." ]]; then
        normalized_value=""
    fi
    is_valid_upload_remote_path_value "${normalized_value}" || die "invalid upload remote-path: ${path_value}"
    setting_file="$(resolve_upload_rclone_path_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_upload_high_watermark_for_home() {
    local user_home="$1"
    local high_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_watermark_value "${high_value}" || true)"
    [[ -n "${normalized_value}" ]] || die "invalid upload watermark-high: ${high_value} (expected integer 1-99)"
    setting_file="$(resolve_upload_high_watermark_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_upload_low_watermark_for_home() {
    local user_home="$1"
    local low_value="$2"
    local normalized_value setting_file
    normalized_value="$(normalize_upload_watermark_value "${low_value}" || true)"
    [[ -n "${normalized_value}" ]] || die "invalid upload watermark-low: ${low_value} (expected integer 1-99)"
    setting_file="$(resolve_upload_low_watermark_file_for_home "${user_home}")"
    write_setting_value "${setting_file}" "${normalized_value}"
}

set_focus_setting_for_home() {
    local user_home="$1"
    local focus_value="$2"
    local normalized_focus_value
    normalized_focus_value="$(normalize_duration_value "${focus_value}")"
    if ! is_valid_focus_setting_value "${normalized_focus_value}"; then
        die "invalid focus value: ${focus_value} (expected numeric lens-position or 'auto')"
    fi
    if is_auto_focus_value "${normalized_focus_value}"; then
        normalized_focus_value="auto"
    fi

    local focus_file focus_dir
    focus_file="$(resolve_focus_value_file_for_home "${user_home}")"
    focus_dir="$(dirname "${focus_file}")"
    mkdir -p "${focus_dir}"
    printf '%s\n' "${normalized_focus_value}" > "${focus_file}"
    printf '%s\n' "${focus_file}"
}

set_fps_setting_for_home() {
    local user_home="$1"
    local fps_value="$2"
    is_valid_fps_value "${fps_value}" || die "invalid fps value: ${fps_value} (expected a numeric value greater than zero)"

    local fps_file fps_dir
    fps_file="$(resolve_fps_value_file_for_home "${user_home}")"
    fps_dir="$(dirname "${fps_file}")"
    mkdir -p "${fps_dir}"
    printf '%s\n' "${fps_value}" > "${fps_file}"
    printf '%s\n' "${fps_file}"
}

set_length_setting_for_home() {
    local user_home="$1"
    local length_value="$2"
    local normalized_length_value
    normalized_length_value="$(normalize_duration_value "${length_value}")"
    is_valid_duration_value "${normalized_length_value}" || die "invalid length value: ${length_value} (expected format like 30h, 10m, 45s, or 1h30m)"

    local length_file length_dir
    length_file="$(resolve_length_value_file_for_home "${user_home}")"
    length_dir="$(dirname "${length_file}")"
    mkdir -p "${length_dir}"
    printf '%s\n' "${normalized_length_value}" > "${length_file}"
    printf '%s\n' "${length_file}"
}

set_segment_setting_for_home() {
    local user_home="$1"
    local segment_value="$2"
    local normalized_segment_value segment_ms
    normalized_segment_value="$(normalize_duration_value "${segment_value}")"
    is_valid_duration_value "${normalized_segment_value}" || die "invalid segment value: ${segment_value} (expected format like 30h, 10m, 45s, or 1h30m)"
    segment_ms="$(duration_to_milliseconds "${normalized_segment_value}")"
    [[ "${segment_ms}" -gt 0 ]] || die "invalid segment value: ${segment_value} (must be greater than 0)"

    local segment_file segment_dir
    segment_file="$(resolve_segment_value_file_for_home "${user_home}")"
    segment_dir="$(dirname "${segment_file}")"
    mkdir -p "${segment_dir}"
    printf '%s\n' "${normalized_segment_value}" > "${segment_file}"
    printf '%s\n' "${segment_file}"
}

set_intra_setting_for_home() {
    local user_home="$1"
    local intra_value="$2"
    local normalized_intra_value
    normalized_intra_value="$(normalize_intra_setting_value "${intra_value}" || true)"
    [[ -n "${normalized_intra_value}" ]] || die "invalid intra value: ${intra_value} (expected positive integer frame period, none, or 0)"

    local intra_file intra_dir
    intra_file="$(resolve_intra_value_file_for_home "${user_home}")"
    intra_dir="$(dirname "${intra_file}")"
    mkdir -p "${intra_dir}"
    printf '%s\n' "${normalized_intra_value}" > "${intra_file}"
    printf '%s\n' "${intra_file}"
}

set_photo_every_setting_for_home() {
    local user_home="$1"
    local photo_every_value="$2"
    local normalized_photo_every_value
    normalized_photo_every_value="$(normalize_photo_every_setting_value "${photo_every_value}" || true)"
    [[ -n "${normalized_photo_every_value}" ]] || die "invalid photo-every value: ${photo_every_value} (expected format like 30h, 10m, 45s, 1h30m, 0, or none)"

    local photo_every_file photo_every_dir
    photo_every_file="$(resolve_photo_every_value_file_for_home "${user_home}")"
    photo_every_dir="$(dirname "${photo_every_file}")"
    mkdir -p "${photo_every_dir}"
    printf '%s\n' "${normalized_photo_every_value}" > "${photo_every_file}"
    printf '%s\n' "${photo_every_file}"
}

set_name_setting_for_home() {
    local user_home="$1"
    local name_value="$2"
    local normalized_name_value
    normalized_name_value="$(normalize_recording_name_value "${name_value}")"
    is_valid_recording_name_value "${normalized_name_value}" || die "invalid recording name: ${name_value} (expected characters [A-Za-z0-9._-])"

    local name_file name_dir
    name_file="$(resolve_name_value_file_for_home "${user_home}")"
    name_dir="$(dirname "${name_file}")"
    mkdir -p "${name_dir}"
    printf '%s\n' "${normalized_name_value}" > "${name_file}"
    printf '%s\n' "${name_file}"
}

read_recording_state_field() {
    local state_file="$1"
    local field_name="$2"
    [[ -f "${state_file}" ]] || return 1
    grep -E "^${field_name}=" "${state_file}" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

read_recording_pid_from_state_file() {
    local state_file="$1"
    local pid_value
    pid_value="$(read_recording_state_field "${state_file}" "record_pid" || true)"
    if ! is_pid_value "${pid_value}"; then
        return 1
    fi
    printf '%s\n' "${pid_value}"
}

clear_recording_state_for_home() {
    local user_home="$1"
    local state_file
    state_file="$(resolve_recording_state_file_for_home "${user_home}")"
    rm -f "${state_file}" >/dev/null 2>&1 || true
}

write_recording_state_for_home() {
    local user_home="$1"
    local record_pid="$2"
    local capture_dir="$3"
    local record_script="$4"
    local requested_script_name="$5"
    is_pid_value "${record_pid}" || return 1

    local state_file state_dir state_tmp
    state_file="$(resolve_recording_state_file_for_home "${user_home}")"
    state_dir="$(dirname "${state_file}")"
    mkdir -p "${state_dir}"
    state_tmp="$(mktemp "${state_dir}/.recording-state.XXXXXX")"

    {
        echo "record_pid=${record_pid}"
        echo "capture_dir=${capture_dir}"
        echo "record_script=${record_script}"
        echo "record_script_name=${requested_script_name}"
        echo "started_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "stop_requested=false"
    } > "${state_tmp}"

    mv -f "${state_tmp}" "${state_file}"
}

mark_recording_stop_requested_for_home() {
    local user_home="$1"
    local state_file
    state_file="$(resolve_recording_state_file_for_home "${user_home}")"
    [[ -f "${state_file}" ]] || return 1

    {
        echo "stop_requested=true"
        echo "stop_requested_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >> "${state_file}"
}

set_focus_value() {
    local focus_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for focus settings"

    local focus_file
    focus_file="$(set_focus_setting_for_home "${user_home}" "${focus_value}")"
    echo "focus setting set to $(read_focus_setting_for_home "${user_home}")"
    echo "focus settings file: ${focus_file}"
}

set_fps_value() {
    local fps_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for fps settings"

    local fps_file
    fps_file="$(set_fps_setting_for_home "${user_home}" "${fps_value}")"
    echo "recording fps set to ${fps_value}"
    echo "fps settings file: ${fps_file}"
}

set_length_value() {
    local length_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for length settings"

    local length_file normalized_length
    length_file="$(set_length_setting_for_home "${user_home}" "${length_value}")"
    normalized_length="$(read_length_setting_for_home "${user_home}")"
    echo "recording length set to ${normalized_length}"
    echo "length settings file: ${length_file}"
}

set_segment_value() {
    local segment_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for segment settings"

    local segment_file normalized_segment
    segment_file="$(set_segment_setting_for_home "${user_home}" "${segment_value}")"
    normalized_segment="$(read_segment_setting_for_home "${user_home}")"
    echo "recording segment set to ${normalized_segment}"
    echo "segment settings file: ${segment_file}"
}

set_intra_value() {
    local intra_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for intra settings"

    local intra_file normalized_intra
    intra_file="$(set_intra_setting_for_home "${user_home}" "${intra_value}")"
    normalized_intra="$(read_intra_setting_for_home "${user_home}")"
    echo "recording intra set to ${normalized_intra}"
    echo "intra settings file: ${intra_file}"
}

set_photo_every_value() {
    local photo_every_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for photo-every settings"

    local photo_every_file normalized_photo_every
    photo_every_file="$(set_photo_every_setting_for_home "${user_home}" "${photo_every_value}")"
    normalized_photo_every="$(read_photo_every_setting_for_home "${user_home}")"
    echo "recording photo-every set to ${normalized_photo_every}"
    echo "photo-every settings file: ${photo_every_file}"
}

set_name_value() {
    local name_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for name settings"

    local name_file normalized_name
    name_file="$(set_name_setting_for_home "${user_home}" "${name_value}")"
    normalized_name="$(read_name_setting_for_home "${user_home}")"
    echo "recording name set to ${normalized_name}"
    echo "name settings file: ${name_file}"
}

set_upload_profile_value() {
    local profile_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload profile settings"

    local profile_file normalized_profile
    profile_file="$(set_upload_profile_for_home "${user_home}" "${profile_value}")"
    normalized_profile="$(read_upload_profile_for_home "${user_home}")"
    echo "upload profile set to ${normalized_profile}"
    echo "upload profile settings file: ${profile_file}"
}

set_upload_retention_value() {
    local retention_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload retention settings"

    local retention_file normalized_retention
    retention_file="$(set_upload_retention_for_home "${user_home}" "${retention_value}")"
    normalized_retention="$(read_upload_retention_for_home "${user_home}")"
    echo "upload retention set to ${normalized_retention}"
    echo "upload retention settings file: ${retention_file}"
}

set_upload_local_target_value() {
    local target_path="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload local target settings"

    local target_file normalized_target
    target_file="$(set_upload_local_target_for_home "${user_home}" "${target_path}")"
    normalized_target="$(read_upload_local_target_for_home "${user_home}")"
    echo "upload local target set to ${normalized_target}"
    echo "upload local target settings file: ${target_file}"
}

set_upload_remote_value() {
    local remote_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload remote settings"

    local remote_file normalized_remote
    remote_file="$(set_upload_rclone_remote_for_home "${user_home}" "${remote_value}")"
    normalized_remote="$(read_upload_rclone_remote_for_home "${user_home}")"
    echo "upload rclone remote set to ${normalized_remote}"
    echo "upload rclone remote settings file: ${remote_file}"
}

set_upload_remote_path_value() {
    local remote_path_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload remote-path settings"

    local remote_path_file normalized_path
    remote_path_file="$(set_upload_rclone_path_for_home "${user_home}" "${remote_path_value}")"
    normalized_path="$(read_upload_rclone_path_for_home "${user_home}")"
    if [[ -n "${normalized_path}" ]]; then
        echo "upload rclone path set to ${normalized_path}"
    else
        echo "upload rclone path set to (remote root)"
    fi
    echo "upload rclone path settings file: ${remote_path_file}"
}

set_upload_watermark_high_value() {
    local high_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload watermark settings"

    local high_file normalized_high low_value
    normalized_high="$(normalize_upload_watermark_value "${high_value}" || true)"
    [[ -n "${normalized_high}" ]] || die "invalid upload watermark-high: ${high_value} (expected integer 1-99)"
    low_value="$(read_upload_low_watermark_for_home "${user_home}")"
    if [[ "${normalized_high}" -le "${low_value}" ]]; then
        die "invalid watermark combination: high (${normalized_high}) must be greater than low (${low_value})"
    fi
    high_file="$(set_upload_high_watermark_for_home "${user_home}" "${normalized_high}")"
    echo "upload high watermark set to ${normalized_high}%"
    echo "upload high watermark settings file: ${high_file}"
}

set_upload_watermark_low_value() {
    local low_value_input="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload watermark settings"

    local low_file normalized_low high_value
    normalized_low="$(normalize_upload_watermark_value "${low_value_input}" || true)"
    [[ -n "${normalized_low}" ]] || die "invalid upload watermark-low: ${low_value_input} (expected integer 1-99)"
    high_value="$(read_upload_high_watermark_for_home "${user_home}")"
    if [[ "${normalized_low}" -ge "${high_value}" ]]; then
        die "invalid watermark combination: low (${normalized_low}) must be less than high (${high_value})"
    fi
    low_file="$(set_upload_low_watermark_for_home "${user_home}" "${normalized_low}")"
    echo "upload low watermark set to ${normalized_low}%"
    echo "upload low watermark settings file: ${low_file}"
}

set_upload_pause_value() {
    local pause_value="$1"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload pause settings"

    local pause_file normalized_pause
    pause_file="$(set_upload_paused_for_home "${user_home}" "${pause_value}")"
    normalized_pause="$(read_upload_paused_for_home "${user_home}")"
    if [[ "${normalized_pause}" == "true" ]]; then
        echo "upload worker is now paused"
    else
        echo "upload worker is now resumed"
    fi
    echo "upload pause settings file: ${pause_file}"
}

report_upload_settings() {
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload settings"

    local upload_dir queue_db profile retention paused local_target remote_name remote_path
    local high_watermark low_watermark transcode_value
    local profile_file retention_file paused_file
    local local_target_file remote_file remote_path_file high_file low_file transcode_file
    upload_dir="$(resolve_upload_dir_for_home "${user_home}")"
    queue_db="$(resolve_upload_queue_db_for_home "${user_home}")"
    profile="$(read_upload_effective_profile_for_home "${user_home}")"
    retention="$(read_upload_effective_retention_for_home "${user_home}")"
    paused="$(read_upload_effective_paused_for_home "${user_home}")"
    local_target="$(read_upload_effective_local_target_for_home "${user_home}")"
    remote_name="$(read_upload_effective_rclone_remote_for_home "${user_home}")"
    remote_path="$(read_upload_effective_rclone_path_for_home "${user_home}")"
    high_watermark="$(read_upload_effective_high_watermark_for_home "${user_home}")"
    low_watermark="$(read_upload_effective_low_watermark_for_home "${user_home}")"
    transcode_value="$(read_transcode_video_effective_for_home "${user_home}")"
    profile_file="$(resolve_upload_profile_file_for_home "${user_home}")"
    retention_file="$(resolve_upload_retention_file_for_home "${user_home}")"
    paused_file="$(resolve_upload_paused_file_for_home "${user_home}")"
    local_target_file="$(resolve_upload_local_target_file_for_home "${user_home}")"
    remote_file="$(resolve_upload_rclone_remote_file_for_home "${user_home}")"
    remote_path_file="$(resolve_upload_rclone_path_file_for_home "${user_home}")"
    high_file="$(resolve_upload_high_watermark_file_for_home "${user_home}")"
    low_file="$(resolve_upload_low_watermark_file_for_home "${user_home}")"
    transcode_file="$(resolve_transcode_video_file_for_home "${user_home}")"

    echo "upload_dir=${upload_dir}"
    echo "queue_db=${queue_db}"
    echo "upload_profile=${profile}"
    echo "upload_retention=${retention}"
    echo "upload_paused=${paused}"
    echo "upload_high_watermark_percent=${high_watermark}"
    echo "upload_low_watermark_percent=${low_watermark}"
    if [[ -n "${local_target}" ]]; then
        echo "upload_local_target=${local_target}"
    else
        echo "upload_local_target=(unset)"
    fi
    if [[ -n "${remote_name}" ]]; then
        if [[ -n "${remote_path}" ]]; then
            echo "upload_rclone_target=${remote_name}:${remote_path}"
        else
            echo "upload_rclone_target=${remote_name}:"
        fi
    else
        echo "upload_rclone_target=(unset)"
    fi
    echo "transcode_video=${transcode_value}"
    echo "upload_profile_settings_file=${profile_file}"
    echo "upload_retention_settings_file=${retention_file}"
    echo "upload_paused_settings_file=${paused_file}"
    echo "upload_local_target_settings_file=${local_target_file}"
    echo "upload_rclone_remote_settings_file=${remote_file}"
    echo "upload_rclone_path_settings_file=${remote_path_file}"
    echo "upload_high_watermark_settings_file=${high_file}"
    echo "upload_low_watermark_settings_file=${low_file}"
    echo "transcode_video_settings_file=${transcode_file}"
}

report_upload_targets() {
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload target report"

    local profile local_target remote_name remote_path
    profile="$(read_upload_effective_profile_for_home "${user_home}")"
    local_target="$(read_upload_effective_local_target_for_home "${user_home}")"
    remote_name="$(read_upload_effective_rclone_remote_for_home "${user_home}")"
    remote_path="$(read_upload_effective_rclone_path_for_home "${user_home}")"

    echo "upload_profile=${profile}"

    if [[ -n "${local_target}" ]]; then
        echo "local_target=${local_target}"
        if [[ -d "${local_target}" ]]; then
            if [[ -w "${local_target}" ]]; then
                echo "local_target_status=ready"
            else
                echo "local_target_status=not_writable"
            fi
        else
            echo "local_target_status=missing"
        fi
    else
        echo "local_target=(unset)"
        echo "local_target_status=unset"
    fi

    if [[ -n "${remote_name}" ]]; then
        if [[ -n "${remote_path}" ]]; then
            echo "cloud_target=${remote_name}:${remote_path}"
        else
            echo "cloud_target=${remote_name}:"
        fi
    else
        echo "cloud_target=(unset)"
    fi
}

report_upload_queue() {
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload queue report"

    local paused_flag
    paused_flag="$(read_upload_effective_paused_for_home "${user_home}" 2>/dev/null || echo "unknown")"
    echo "upload_paused=${paused_flag}"

    local queue_db
    queue_db="$(resolve_upload_queue_db_for_home "${user_home}")"
    echo "queue_db=${queue_db}"

    if [[ ! -f "${queue_db}" ]]; then
        echo "queue_status=not_initialized"
        return 0
    fi

    require_sqlite3

    local total_count
    total_count="$(sqlite3 -noheader "${queue_db}" "SELECT COUNT(*) FROM artifacts;" 2>/dev/null || echo "0")"
    echo "artifacts_total=${total_count}"

    local status_line status_name status_count
    while IFS='|' read -r status_name status_count; do
        [[ -n "${status_name}" ]] || continue
        echo "status_${status_name,,}=${status_count}"
    done < <(sqlite3 -separator '|' -noheader "${queue_db}" "SELECT status, COUNT(*) FROM artifacts GROUP BY status ORDER BY status;" 2>/dev/null || true)

    local now_epoch oldest_pending pending_age
    now_epoch="$(date +%s)"
    oldest_pending="$(sqlite3 -noheader "${queue_db}" "SELECT MIN(discovered_at_epoch) FROM artifacts WHERE status IN ('QUEUED','RETRY_WAIT','IN_FLIGHT');" 2>/dev/null || true)"
    if [[ -n "${oldest_pending}" && "${oldest_pending}" != "0" ]]; then
        pending_age=$((now_epoch - oldest_pending))
        echo "oldest_pending_age_seconds=${pending_age}"
    else
        echo "oldest_pending_age_seconds=0"
    fi

    local due_now_count
    due_now_count="$(sqlite3 -noheader "${queue_db}" "SELECT COUNT(*) FROM artifacts WHERE status='QUEUED' OR (status='RETRY_WAIT' AND next_retry_epoch <= ${now_epoch});" 2>/dev/null || echo "0")"
    echo "artifacts_due_now=${due_now_count}"

    local oldest_pending_row pending_id pending_status pending_path pending_next_retry pending_last_error pending_retry_wait
    oldest_pending_row="$(sqlite3 -separator '|' -noheader "${queue_db}" "SELECT id, status, IFNULL(relative_path,''), IFNULL(next_retry_epoch,0), IFNULL(last_error,'') FROM artifacts WHERE status IN ('QUEUED','RETRY_WAIT','IN_FLIGHT') ORDER BY discovered_at_epoch ASC, id ASC LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "${oldest_pending_row}" ]]; then
        IFS='|' read -r pending_id pending_status pending_path pending_next_retry pending_last_error <<< "${oldest_pending_row}"
        echo "oldest_pending_id=${pending_id}"
        echo "oldest_pending_status=${pending_status}"
        echo "oldest_pending_path=${pending_path}"
        echo "oldest_pending_last_error=${pending_last_error}"
        if [[ "${pending_status}" == "RETRY_WAIT" ]]; then
            pending_retry_wait=$((pending_next_retry - now_epoch))
            if [[ "${pending_retry_wait}" -lt 0 ]]; then
                pending_retry_wait=0
            fi
            echo "oldest_pending_retry_wait_seconds=${pending_retry_wait}"
        else
            echo "oldest_pending_retry_wait_seconds=0"
        fi
    fi
}

read_upload_test_jitter_max_seconds() {
    local explicit_value service_value

    explicit_value="$(normalize_upload_text_value "${ANTCAM_UPLOAD_TEST_JITTER_MAX_SECONDS:-}")"
    if [[ -n "${explicit_value}" ]]; then
        [[ "${explicit_value}" =~ ^[0-9]+$ ]] || die "invalid ANTCAM_UPLOAD_TEST_JITTER_MAX_SECONDS: ${explicit_value} (expected integer >= 0)"
        printf '%s\n' "${explicit_value}"
        return 0
    fi

    service_value="$(read_upload_service_env_value "INITIAL_UPLOAD_JITTER_MAX_SECONDS" || true)"
    service_value="$(normalize_upload_text_value "${service_value}")"
    if [[ -n "${service_value}" ]]; then
        [[ "${service_value}" =~ ^[0-9]+$ ]] || die "invalid INITIAL_UPLOAD_JITTER_MAX_SECONDS from service env: ${service_value} (expected integer >= 0)"
        printf '%s\n' "${service_value}"
        return 0
    fi

    printf '%s\n' "30"
}

random_upload_test_jitter_seconds() {
    local jitter_max="${1:-0}"
    if [[ ! "${jitter_max}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "0"
        return 0
    fi
    if [[ "${jitter_max}" -le 0 ]]; then
        printf '%s\n' "0"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "${jitter_max}" <<'PY' 2>/dev/null || true
import random
import sys

try:
    upper = int(sys.argv[1])
except Exception:
    upper = 0

if upper <= 0:
    print("0")
else:
    print(random.randint(0, upper))
PY
        return 0
    fi

    printf '%s\n' $((RANDOM % (jitter_max + 1)))
}

build_upload_test_remote_target() {
    local remote_name="$1"
    local remote_path="$2"
    local relative_path="$3"

    if [[ -n "${remote_path}" ]]; then
        printf '%s\n' "${remote_name}:${remote_path}/${relative_path}"
    else
        printf '%s\n' "${remote_name}:${relative_path}"
    fi
}

UPLOAD_TEST_LAST_ERROR=""

upload_test_try_local_target() {
    local source_file="$1"
    local relative_path="$2"
    local upload_dir="$3"
    local local_target="$4"
    local target_path target_dir target_tmp
    UPLOAD_TEST_LAST_ERROR=""

    if [[ -z "${local_target}" ]]; then
        UPLOAD_TEST_LAST_ERROR="local_target_unset"
        return 1
    fi
    if is_path_within_directory "${local_target}" "${upload_dir}"; then
        UPLOAD_TEST_LAST_ERROR="local_target_inside_upload_dir"
        return 1
    fi
    if [[ ! -d "${local_target}" ]]; then
        UPLOAD_TEST_LAST_ERROR="local_target_missing"
        return 1
    fi
    if [[ ! -w "${local_target}" ]]; then
        UPLOAD_TEST_LAST_ERROR="local_target_not_writable"
        return 1
    fi

    target_path="${local_target%/}/${relative_path}"
    target_dir="$(dirname "${target_path}")"
    if ! mkdir -p "${target_dir}" >/dev/null 2>&1; then
        UPLOAD_TEST_LAST_ERROR="local_target_mkdir_failed"
        return 1
    fi

    target_tmp="${target_path}.tmp.$$.$RANDOM"
    if ! cp "${source_file}" "${target_tmp}" >/dev/null 2>&1; then
        rm -f "${target_tmp}" >/dev/null 2>&1 || true
        UPLOAD_TEST_LAST_ERROR="local_copy_failed"
        return 1
    fi
    if ! mv -f "${target_tmp}" "${target_path}" >/dev/null 2>&1; then
        rm -f "${target_tmp}" >/dev/null 2>&1 || true
        UPLOAD_TEST_LAST_ERROR="local_move_failed"
        return 1
    fi

    echo "upload_test_target=local:${local_target}"
    echo "upload_test_destination=${target_path}"
    return 0
}

upload_test_try_cloud_target() {
    local source_file="$1"
    local relative_path="$2"
    local remote_name="$3"
    local remote_path="$4"
    local remote_target destination_label rclone_output rclone_exit
    UPLOAD_TEST_LAST_ERROR=""

    if [[ -z "${remote_name}" ]]; then
        UPLOAD_TEST_LAST_ERROR="cloud_remote_unset"
        return 1
    fi
    if ! command -v rclone >/dev/null 2>&1; then
        UPLOAD_TEST_LAST_ERROR="rclone_not_installed"
        return 1
    fi

    remote_target="$(build_upload_test_remote_target "${remote_name}" "${remote_path}" "${relative_path}")"

    set +e
    rclone_output="$(
        rclone copyto \
            "${source_file}" \
            "${remote_target}" \
            --stats=0 \
            --contimeout 15s \
            --timeout 120s \
            --retries 1 \
            --low-level-retries 1 \
            2>&1
    )"
    rclone_exit="$?"
    set -e

    if [[ "${rclone_exit}" -ne 0 ]]; then
        UPLOAD_TEST_LAST_ERROR="rclone_copy_failed"
        if [[ -n "${rclone_output}" ]]; then
            printf '%s\n' "${rclone_output}" >&2
        fi
        return 1
    fi

    if [[ -n "${remote_path}" ]]; then
        destination_label="${remote_name}:${remote_path}"
    else
        destination_label="${remote_name}:"
    fi

    echo "upload_test_target=${destination_label}"
    echo "upload_test_destination=${remote_target}"
    return 0
}

run_upload_test_once() {
    local user_home upload_dir profile local_target remote_name remote_path
    local jitter_max jitter_seconds timestamp_utc timestamp_slug device_id
    local test_basename relative_path source_file source_size
    local local_reason cloud_reason

    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload test"
    upload_dir="$(resolve_upload_dir_for_home "${user_home}")"
    profile="$(read_upload_effective_profile_for_home "${user_home}")"
    local_target="$(read_upload_effective_local_target_for_home "${user_home}")"
    remote_name="$(read_upload_effective_rclone_remote_for_home "${user_home}")"
    remote_path="$(read_upload_effective_rclone_path_for_home "${user_home}")"
    jitter_max="$(read_upload_test_jitter_max_seconds)"
    jitter_seconds="$(random_upload_test_jitter_seconds "${jitter_max}")"

    if [[ ! "${jitter_seconds}" =~ ^[0-9]+$ ]]; then
        jitter_seconds=0
    fi

    timestamp_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    timestamp_slug="$(date -u +%Y%m%dT%H%M%SZ)"
    resolve_device_id >/dev/null
    device_id="${DEVICE_ID_CACHE}"

    source_file="$(mktemp "${TMPDIR:-/tmp}/antcam-upload-test.XXXXXX.txt")"
    test_basename="upload-test-${device_id}-${timestamp_slug}-$$.txt"
    relative_path="diagnostics/upload-tests/${test_basename}"

    {
        echo "# AntCam Upload Test Artifact"
        echo "timestamp_utc=${timestamp_utc}"
        echo "device_id=${device_id}"
        echo "upload_profile=${profile}"
        echo "upload_dir=${upload_dir}"
        if [[ -n "${local_target}" ]]; then
            echo "upload_local_target=${local_target}"
        else
            echo "upload_local_target=(unset)"
        fi
        if [[ -n "${remote_name}" ]]; then
            if [[ -n "${remote_path}" ]]; then
                echo "upload_rclone_target=${remote_name}:${remote_path}"
            else
                echo "upload_rclone_target=${remote_name}:"
            fi
        else
            echo "upload_rclone_target=(unset)"
        fi
        echo "note=one_shot_upload_test_no_queue_retry_loop"
    } > "${source_file}"

    source_size="$(wc -c < "${source_file}" | tr -d '[:space:]')"

    echo "upload test profile=${profile}"
    echo "upload test source=${source_file}"
    echo "upload test source_size_bytes=${source_size}"
    echo "upload test destination_relative_path=${relative_path}"
    echo "upload test jitter_seconds=${jitter_seconds} (max=${jitter_max})"

    if [[ "${jitter_seconds}" -gt 0 ]]; then
        sleep "${jitter_seconds}"
    fi

    case "${profile}" in
        local)
            if upload_test_try_local_target "${source_file}" "${relative_path}" "${upload_dir}" "${local_target}"; then
                echo "upload_test_status=success"
                rm -f "${source_file}" >/dev/null 2>&1 || true
                return 0
            fi
            local_reason="${UPLOAD_TEST_LAST_ERROR:-unknown_local_error}"
            rm -f "${source_file}" >/dev/null 2>&1 || true
            echo "antcam: upload test failed (profile=local, reason=${local_reason})" >&2
            return 1
            ;;
        cloud)
            if upload_test_try_cloud_target "${source_file}" "${relative_path}" "${remote_name}" "${remote_path}"; then
                echo "upload_test_status=success"
                rm -f "${source_file}" >/dev/null 2>&1 || true
                return 0
            fi
            cloud_reason="${UPLOAD_TEST_LAST_ERROR:-unknown_cloud_error}"
            rm -f "${source_file}" >/dev/null 2>&1 || true
            echo "antcam: upload test failed (profile=cloud, reason=${cloud_reason})" >&2
            return 1
            ;;
        field)
            if upload_test_try_local_target "${source_file}" "${relative_path}" "${upload_dir}" "${local_target}"; then
                echo "upload_test_status=success"
                rm -f "${source_file}" >/dev/null 2>&1 || true
                return 0
            fi
            local_reason="${UPLOAD_TEST_LAST_ERROR:-unknown_local_error}"
            echo "upload test local attempt failed (reason=${local_reason}); trying cloud"
            if upload_test_try_cloud_target "${source_file}" "${relative_path}" "${remote_name}" "${remote_path}"; then
                echo "upload_test_status=success"
                rm -f "${source_file}" >/dev/null 2>&1 || true
                return 0
            fi
            cloud_reason="${UPLOAD_TEST_LAST_ERROR:-unknown_cloud_error}"
            rm -f "${source_file}" >/dev/null 2>&1 || true
            echo "antcam: upload test failed (profile=field, local_reason=${local_reason}, cloud_reason=${cloud_reason})" >&2
            return 1
            ;;
        *)
            rm -f "${source_file}" >/dev/null 2>&1 || true
            echo "antcam: upload test failed (unknown profile=${profile})" >&2
            return 1
            ;;
    esac
}

reload_upload_worker_service() {
    local service_name="${DEFAULT_UPLOAD_SERVICE_NAME}"

    if [[ "$(id -u)" -eq 0 ]]; then
        systemctl restart "${service_name}"
        echo "upload service restarted: ${service_name}"
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo systemctl restart "${service_name}"
        echo "upload service restarted: ${service_name}"
        return 0
    fi

    die "cannot restart ${service_name} without root privileges or sudo"
}

prune_uploaded_files() {
    local older_than_value="$1"
    local dry_run="$2"
    local user_home
    user_home="$(resolve_effective_home)" || die "could not resolve user home for upload prune"

    local queue_db upload_dir
    queue_db="$(resolve_upload_queue_db_for_home "${user_home}")"
    upload_dir="$(resolve_upload_dir_for_home "${user_home}")"
    require_sqlite3

    local normalized_duration cutoff_ms cutoff_epoch now_epoch
    normalized_duration="$(normalize_duration_value "${older_than_value}")"
    is_valid_duration_value "${normalized_duration}" || die "invalid --older-than value: ${older_than_value} (expected format like 72h, 30m, 10s)"
    cutoff_ms="$(duration_to_milliseconds "${normalized_duration}")"
    [[ "${cutoff_ms}" -gt 0 ]] || die "--older-than must be greater than zero"
    now_epoch="$(date +%s)"
    cutoff_epoch=$((now_epoch - (cutoff_ms / 1000)))

    if [[ ! -f "${queue_db}" ]]; then
        echo "queue db not found: ${queue_db}"
        return 0
    fi

    local candidate_rows
    candidate_rows="$(sqlite3 -separator '|' -noheader "${queue_db}" "SELECT id, full_path, relative_path, IFNULL(size_bytes,0), IFNULL(first_shipped_epoch,0) FROM artifacts WHERE status='SHIPPED' AND IFNULL(first_shipped_epoch,0) > 0 AND first_shipped_epoch <= ${cutoff_epoch} ORDER BY first_shipped_epoch ASC;" 2>/dev/null || true)"

    local pruned_count=0
    local skipped_count=0
    local row id full_path relative_path size_bytes shipped_epoch
    while IFS= read -r row; do
        [[ -n "${row}" ]] || continue
        IFS='|' read -r id full_path relative_path size_bytes shipped_epoch <<< "${row}"

        if [[ -z "${full_path}" ]]; then
            skipped_count=$((skipped_count + 1))
            continue
        fi

        if ! is_path_within_directory "${full_path}" "${upload_dir}"; then
            echo "skipping unsafe prune path outside upload dir: ${full_path}" >&2
            skipped_count=$((skipped_count + 1))
            continue
        fi

        if [[ "${dry_run}" == "true" ]]; then
            echo "dry-run prune candidate: ${relative_path} (${size_bytes} bytes)"
            pruned_count=$((pruned_count + 1))
            continue
        fi

        if [[ -f "${full_path}" ]]; then
            rm -f "${full_path}"
        fi

        sqlite3 "${queue_db}" "UPDATE artifacts SET status='PRUNED', updated_at_epoch=${now_epoch}, pruned_at_epoch=${now_epoch}, last_error='' WHERE id=${id};" >/dev/null 2>&1 || true
        echo "pruned: ${relative_path}"
        pruned_count=$((pruned_count + 1))
    done <<< "${candidate_rows}"

    if [[ "${dry_run}" == "true" ]]; then
        echo "dry-run prune candidates=${pruned_count} skipped=${skipped_count}"
    else
        echo "prune completed pruned=${pruned_count} skipped=${skipped_count}"
    fi
}
