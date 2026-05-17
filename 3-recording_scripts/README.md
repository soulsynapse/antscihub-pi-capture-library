# Recording Trigger

Recording commands:

```bash
antcam set focus <lens-position>
antcam report focus
antcam start <recording-script-name>
antcam focus
```

`antcam start <recording-script-name>` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Resolve a named recording script from `/etc/antscihub/recording-scripts/` (installed) or repository `3-recording_scripts/`.
4. Read focus value from `<desktop>/4-CAPTURE/config/focus-lens-position.txt` (or `ANTCAM_FOCUS_VALUE_FILE` override).
5. Run the selected script from inside `<desktop>/4-CAPTURE`.
6. Publish encrypted Fleet report messages when recording starts and ends.
   - Topic: `fleet/report/{DEVICE_ID}` (or `FLEET_EVENT_TOPIC_TEMPLATE` override)
   - Payload includes `event=report`, `report=recording_start|recording_end`, `device_id`, `timestamp`, `severity`, `success`
7. If the recording script fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.

Bundled recording scripts:

- `record_1fps_1m_focus.sh`
  - Runs `rpicam-vid`/`libcamera-vid` at `1 fps`
  - Segments every `60000 ms` (1-minute chunks)
  - Applies `--lens-position` from the saved focus setting

`antcam focus` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Run autofocus helper `1-capture_config/antcam_focus_autofocus.sh` (or installed copy `/etc/antscihub/antcam_focus_autofocus.sh`) from inside `<desktop>/4-CAPTURE`.
4. Final output is the `lens-position` value suitable for `rpicam-vid --lens-position <value>`.
5. Copy captured focus photo into `<desktop>/5-UPLOAD/diagnostics/recordings/` as `YYYY-MM-DD__T-HH-MM-SS__focus-result-lens-position-#.#__hostname.jpeg` for uploader pickup.
6. If the autofocus helper fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.
