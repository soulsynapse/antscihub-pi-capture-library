# Repository Overview

This repository provides two Raspberry Pi services:

1. `antscihub-capture-config.service`
2. `antscihub-upload.service`

## 1. Camera Config Service

Location: `1-capture_config/apply_camera_config.sh`

Purpose:

- Detect supported camera model at boot
- Treat "no camera attached" as a safe no-op (no reboot/config rewrite)
- Write a managed config block in `/boot/firmware/config.txt` (or `/boot/config.txt`)
- Reboot only when configuration changes
- Prevent reboot loops with attempt counter and lock file

## 2. Upload Service

Location: `4-upload/upload_worker.sh`

Purpose:

- Resolve Desktop for the configured service user and watch `<desktop>/5-UPLOAD`
- Upload stable files recursively with preserved relative paths
- Rename uploads with machine suffix when remote path conflicts exist
- Create `<filename>.MOVED` reference files on success
- Track processed files using file identity
- Retry failures with exponential backoff and per-file schedules

## Operational Defaults

- Remote: `gdrive_personal`
- Remote path: empty (remote root)
- Upload service user: installer chooses the invoking non-root user when possible

## State Paths

Capture config:

- `/var/lib/antscihub-capture-config/`
- `/var/log/antscihub-capture-config.log`

Upload worker (user-scoped):

- `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/`
- `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/antscihub-upload.log`

## Validation

Run:

```bash
bash 2-test_scripts/run_static_checks.sh
```
