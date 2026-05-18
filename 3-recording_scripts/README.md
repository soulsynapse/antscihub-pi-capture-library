# Recording Trigger

Recording commands:

```bash
antcam set focus <lens-position|auto>
antcam set fps <value>
antcam set length <duration>
antcam set segment <duration>
antcam set loop <duration|none|0>
antcam report focus
antcam report fps
antcam report length
antcam report segment
antcam report loop
antcam start <recording-script-name>
antcam stop
antcam focus
```

`antcam start <recording-script-name>` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Resolve a named recording script from `/etc/antscihub/recording-scripts/` (installed) or repository `3-recording_scripts/`.
4. Read focus value from `<desktop>/4-CAPTURE/config/focus-lens-position.txt` (or `ANTCAM_FOCUS_VALUE_FILE` override, defaults to `auto` if unset).
5. Read fps value from `<desktop>/4-CAPTURE/config/recording-fps.txt` (or `ANTCAM_FPS_VALUE_FILE` override, defaults to `1` if unset).
6. Read recording length from `<desktop>/4-CAPTURE/config/recording-length.txt` (or `ANTCAM_LENGTH_VALUE_FILE` override, defaults to `0s`).
7. Read segment length from `<desktop>/4-CAPTURE/config/recording-segment.txt` (or `ANTCAM_SEGMENT_VALUE_FILE` override, defaults to `1m`) for scripts that use segments (for example, `video.sh`).
8. Read loop interval from `<desktop>/4-CAPTURE/config/recording-loop.txt` (or `ANTCAM_LOOP_VALUE_FILE` override, defaults to `1m`; accepts `none`/`0` to disable loop scheduling).
9. Run the selected script from inside `<desktop>/4-CAPTURE`.
10. Write active recording state to `<desktop>/4-CAPTURE/config/recording-active-state.env` for `antcam stop`.
11. Selected script writes outputs to `<desktop>/5-UPLOAD/YYYY-MM-DD_HH-MM-SS__hostname/` (for example, `video.sh` writes `video-%05d.h264`, `photos.sh` writes `photos-%05d.jpg`).
12. Publish encrypted Fleet report messages when recording starts and ends.
   - Topic: `fleet/report/{DEVICE_ID}` (or `FLEET_EVENT_TOPIC_TEMPLATE` override)
   - Payload includes `event=report`, `report=recording_start|recording_end`, `device_id`, `timestamp`, `severity`, `success`
13. If the recording script fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.

`antcam stop` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Read `<desktop>/4-CAPTURE/config/recording-active-state.env`.
3. If recording PID is active, send `SIGINT` for graceful stop.
   - Applies to both `video` and `photos` recording scripts.
4. If still active after a timeout, send `SIGTERM`.
5. Clear recording state file after the recording process exits.

Bundled recording scripts:

- `video.sh`
  - Runs `rpicam-vid`/`libcamera-vid` using configured fps (`antcam set fps <value>`, defaults to `1`)
  - Uses configurable length (`antcam set length <duration>`, default `0s`), segment size (`antcam set segment <duration>`, default `1m`), and loop interval (`antcam set loop <duration|none|0>`, default `1m`)
  - Starts each clip on loop-aligned schedule from script start time
  - Requires `segment <= loop` to preserve aligned start schedule
  - If loop is `none` or `0`, loop scheduling is disabled and clips run back-to-back
  - Applies `--lens-position` from the saved focus setting, or omits it when focus is `auto`
- `photos.sh`
  - Runs `rpicam-still`/`libcamera-still` still capture
  - Uses configurable length (`antcam set length <duration>`, default `0s`) and loop interval (`antcam set loop <duration|none|0>`, default `1m`)
  - Uses loop (not fps) to decide when each photo starts
  - Requires `loop >= 10s` for positive loop values
  - If loop is `none` or `0`, loop scheduling is disabled and one photo is captured per run
  - Applies `--lens-position` from the saved focus setting, or omits it when focus is `auto`
  - Writes photos to `<desktop>/5-UPLOAD/YYYY-MM-DD_HH-MM-SS__hostname/photos-%05d.jpg`

`antcam focus` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Run autofocus helper `1-capture_config/antcam_focus_autofocus.sh` (or installed copy `/etc/antscihub/antcam_focus_autofocus.sh`) from inside `<desktop>/4-CAPTURE`.
4. Final output is the `lens-position` value suitable for `rpicam-vid --lens-position <value>`.
5. Copy captured focus photo into `<desktop>/5-UPLOAD/diagnostics/recordings/` as `YYYY-MM-DD__T-HH-MM-SS__focus-result-lens-position-#.#__hostname.jpeg` for uploader pickup.
6. If the autofocus helper fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.
