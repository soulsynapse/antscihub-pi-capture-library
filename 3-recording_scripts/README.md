# Recording Trigger

Recording commands:

```bash
antcam focus set <lens-position|auto>
antcam fps set <value>
antcam length set <duration>
antcam segment set <duration>
antcam intra set <frames|none|0>
antcam photo-every set <duration|none|0>
antcam name set <suffix>
antcam focus report
antcam fps report
antcam length report
antcam segment report
antcam intra report
antcam photo-every report
antcam name report
antcam start <recording-script-name>
antcam stop
antcam recording resume-if-needed
antcam focus check
```

`antcam start <recording-script-name>` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Resolve a named recording script from `/etc/antscihub/recording-scripts/` (installed) or repository `3-recording_scripts/`.
4. Read focus value from `<desktop>/4-CAPTURE/config/focus-lens-position.txt` (or `ANTCAM_FOCUS_VALUE_FILE` override, defaults to `auto` if unset).
5. Read fps value from `<desktop>/4-CAPTURE/config/recording-fps.txt` (or `ANTCAM_FPS_VALUE_FILE` override, defaults to `1` if unset).
6. Read recording length from `<desktop>/4-CAPTURE/config/recording-length.txt` (or `ANTCAM_LENGTH_VALUE_FILE` override, defaults to `0s`).
7. Read segment length from `<desktop>/4-CAPTURE/config/recording-segment.txt` (or `ANTCAM_SEGMENT_VALUE_FILE` override, defaults to `1m`) for scripts that use segments (for example, `video.py`).
8. Read intra frame period from `<desktop>/4-CAPTURE/config/recording-intra.txt` (or `ANTCAM_INTRA_VALUE_FILE` override, defaults to `none`; positive integers add `--intra <frames>` for `video.py`).
9. Read photo interval from `<desktop>/4-CAPTURE/config/recording-photo-every.txt` (or `ANTCAM_PHOTO_EVERY_VALUE_FILE` override, defaults to `1m`; accepts `none`/`0` to disable interval scheduling and keep one-shot behavior).
10. Read recording name suffix from `<desktop>/4-CAPTURE/config/recording-name.txt` (or `ANTCAM_NAME_VALUE_FILE` override, defaults to `BLANK` if unset).
11. Run the selected script from inside `<desktop>/4-CAPTURE`.
12. Write active recording state to `<desktop>/4-CAPTURE/config/recording-active-state.env` for `antcam stop`.
13. For finite lengths (`length > 0s`), write resume-window state to `<desktop>/4-CAPTURE/config/recording-resume-state.env`.
14. Selected script writes outputs to `<desktop>/5-UPLOAD/YYYY-MM-DD_HH-MM-SS__hostname__suffix/` (for example, `video.py` writes `video-suffix-%05d.h264`, `photos.py` writes `photos-suffix-%05d.jpg`).
15. Publish encrypted Fleet report messages when recording starts and ends.
   - Topic: `fleet/report/{DEVICE_ID}` (or `FLEET_EVENT_TOPIC_TEMPLATE` override)
   - Payload includes `event=report`, `report=recording_start|recording_end`, `device_id`, `timestamp`, `severity`, `success`
16. If the recording script fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.

`antcam stop` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Read `<desktop>/4-CAPTURE/config/recording-active-state.env`.
3. If recording PID is active, send `SIGINT` for graceful stop.
   - Applies to both `video` and `photos` recording scripts.
4. If still active after a timeout, send `SIGTERM`.
5. Clear recording state file after the recording process exits.

Bundled recording scripts:

- `video.py` (invoked via `video.sh` launcher)
  - Runs `rpicam-vid`/`libcamera-vid` using configured fps (`antcam fps set <value>`, defaults to `1`)
  - Records at 1080p by default (`1920x1080` via `--width/--height`; override with `ANTCAM_VIDEO_WIDTH` and `ANTCAM_VIDEO_HEIGHT`)
  - Uses configurable length (`antcam length set <duration>`, default `0s`) and segment size (`antcam segment set <duration>`, default `1m`)
  - Uses configurable intra frame period (`antcam intra set <frames|none|0>`, default `none`; positive integers add `--intra <frames>`)
  - Runs a single long-lived `rpicam-vid`/`libcamera-vid` process with `--segment` to avoid per-clip startup loss
  - Segment mode writes contiguous clips for the configured recording length
  - Applies `--lens-position` from the saved focus setting, or omits it when focus is `auto`
- `photos.py` (invoked via `photos.sh` launcher)
  - Runs `rpicam-still`/`libcamera-still` still capture
  - Uses configurable length (`antcam length set <duration>`, default `0s`) and photo interval (`antcam photo-every set <duration|none|0>`, default `1m`)
  - Uses photo interval (not fps) to decide when each photo starts
  - Requires `photo-every >= 10s` for positive interval values
  - If `photo-every` is `none` or `0`, the script runs one-shot (exactly one photo)
  - If length is `0s`, the script runs one-shot even when `photo-every` is positive
  - For positive length with positive `photo-every`, captures occur at `t=0` and then every interval while `scheduled_time <= length`
  - Supports `ANTCAM_RECORDING_START_EPOCH_MS` schedule anchor override for power-loss resume alignment
  - Applies `--lens-position` from the saved focus setting, or omits it when focus is `auto`
  - Writes photos to `<desktop>/5-UPLOAD/YYYY-MM-DD_HH-MM-SS__hostname__suffix/photos-suffix-%05d.jpg`

`antcam focus check` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Run autofocus helper `1-capture_config/antcam_focus_autofocus.sh` (or installed copy `/etc/antscihub/antcam_focus_autofocus.sh`) from inside `<desktop>/4-CAPTURE`.
4. Final output is the `lens-position` value suitable for `rpicam-vid --lens-position <value>`.
5. Copy captured focus photo into `<desktop>/5-UPLOAD/diagnostics/recordings/` as `YYYY-MM-DD__T-HH-MM-SS__focus-result-lens-position-#.#__hostname.jpeg` for uploader pickup.
6. If the autofocus helper fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.
