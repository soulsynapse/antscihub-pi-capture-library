# Recording Trigger

Recording commands:

```bash
antcam start
antcam test
```

`antcam start` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Ensure `<desktop>/4-CAPTURE/record.sh` exists (create empty file if missing).
4. Ensure `<desktop>/4-CAPTURE/experiment.txt` exists (create empty file if missing).
5. Run `record.sh` from inside `<desktop>/4-CAPTURE`.
6. Publish plain JSON Fleet report messages when recording starts and ends.
   - Topic: `fleet/report/{DEVICE_ID}` (or `FLEET_EVENT_TOPIC_TEMPLATE` override)
   - Payload includes `event=report`, `report=recording_start|recording_end`, `device_id`, `timestamp`, `severity`, `success`

`antcam test` behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Use existing `<desktop>/4-CAPTURE`.
3. Run `test.sh` from inside `<desktop>/4-CAPTURE`.
4. Do not create or require `<desktop>/4-CAPTURE/experiment.txt`.
5. Publish plain JSON Fleet report messages when test starts and ends.
   - Topic: `fleet/report/{DEVICE_ID}` (or `FLEET_EVENT_TOPIC_TEMPLATE` override)
   - Payload includes `event=report`, `report=test_start|test_end`, `device_id`, `timestamp`, `severity`, `success`
