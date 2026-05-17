# Recording Trigger

Recording commands:

```bash
antcam start
antcam focus
```

`antcam start` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Ensure `<desktop>/4-CAPTURE/record.sh` exists (create empty file if missing).
4. Run `record.sh` from inside `<desktop>/4-CAPTURE`.
5. Publish encrypted Fleet report messages when recording starts and ends.
   - Topic: `fleet/report/{DEVICE_ID}` (or `FLEET_EVENT_TOPIC_TEMPLATE` override)
   - Payload includes `event=report`, `report=recording_start|recording_end`, `device_id`, `timestamp`, `severity`, `success`
6. If `record.sh` fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.

`antcam focus` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Ensure `<desktop>/4-CAPTURE/focus.sh` exists (create default script if missing).
4. Run `focus.sh` from inside `<desktop>/4-CAPTURE`.
5. The default script performs an autofocus capture and reports lens-position-based approximate focus distance when available.
6. If `focus.sh` fails, write a timestamped diagnostic log into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup.
