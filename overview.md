# Repository Overview

This repository provides:

1. Manual camera profile CLI: `antscam`
2. Upload service: `antscihub-upload.service`

## 1. Camera Profiles (`antscam`)

Source:

- `1-capture_config/antscam`
- `1-capture_config/profiles/*.conf`

Purpose:

- Apply explicit camera boot configs on demand (`auto`, `imx708`, `owlcam`)
- Keep profile selection operator-controlled, not dynamic at boot
- Write a managed block in `/boot/firmware/config.txt` (or `/boot/config.txt`)
- Reboot only when a profile is applied (unless `--no-reboot`)
- Keep backups of previous config before writes

Install target:

- CLI: `/usr/local/bin/antscam`
- Profiles: `/etc/antscihub/camera-profiles`

## 2. Upload Service

Source:

- `4-upload/upload_worker.sh`

Purpose:

- Resolve Desktop for the service user and watch `<desktop>/5-UPLOAD`
- Upload stable files recursively with preserved relative paths
- Rename uploads with machine suffix when remote path conflicts exist
- Create `<filename>.MOVED` reference files on success
- Track processed files using file identity
- Retry failures with exponential backoff and per-file schedules

## Operational Defaults

- Remote: `gdrive_personal`
- Remote path: empty (remote root)
- Upload service user: installer chooses invoking non-root user when possible

## State Paths

Upload worker (user-scoped):

- `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/`
- `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/antscihub-upload.log`

Legacy camera state/log paths from previous dynamic service may still exist:

- `/var/lib/antscihub-capture-config/`
- `/var/log/antscihub-capture-config.log`

## Validation

Run:

```bash
bash 2-test_scripts/run_static_checks.sh
```
