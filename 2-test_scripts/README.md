# Test Scripts

Run static validation:

```bash
bash run_static_checks.sh
```

Checks include:

- Bash syntax for core scripts
- `antcam` command surface (including `antcam start` and `antcam focus`)
- Recording trigger docs presence
- Presence of key upload-worker safety functions and MQTT event emitter hooks
- Install defaults for `gdrive_personal:5-UPLOAD`

Autofocus and recording runtime scripts now live in:

- `1-capture_config/antcam_focus_autofocus.sh`
- `3-recording_scripts/*.sh`
