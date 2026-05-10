# antscihub-pi-capture-library

Lightweight Raspberry Pi services for:

1. Boot-time camera detection and firmware config
2. Continuous upload of completed files from Desktop to remote storage via `rclone`

## Repository Layout

- [1-capture_config](1-capture_config) - Boot-time camera detection service
- [2-test_scripts](2-test_scripts) - Validation scripts
- [3-recording_scripts](3-recording_scripts) - Recording scripts (placeholder)
- [4-upload](4-upload) - Upload worker service

## Quick Start

### Install

```bash
sudo bash install.sh
```

This installs:

- `antscihub-capture-config.service`
- `antscihub-upload.service`
- `i2c-tools` (if missing) to enable Owlcam fallback hardware detection

The upload service is configured by default to upload to:

- `RCLONE_REMOTE=gdrive_personal`
- `RCLONE_PATH=` (empty, so uploads go to remote root)

Local source remains `<desktop>/5-UPLOAD`; that name is local-only and is not added to the remote path unless you explicitly set `RCLONE_PATH=5-UPLOAD`.

`install.sh` is standalone and safe to re-run on update pulls. It rewrites current units, removes known legacy units, clears old manager-level env overrides, and re-detects the upload user's Desktop path for `5-UPLOAD`.

### Start upload service

```bash
sudo systemctl start antscihub-upload.service
sudo systemctl enable antscihub-upload.service
```

### Check status and logs

```bash
systemctl status antscihub-capture-config.service
systemctl status antscihub-upload.service

journalctl -u antscihub-capture-config.service -f
journalctl -u antscihub-upload.service -f
```

## Upload Worker Behavior

The upload worker:

1. Resolves the service user's Desktop directory and watches `<desktop>/5-UPLOAD`
2. Skips hidden files, temp files (`~*`), and `.MOVED` reference files
3. Waits until each file is old enough and size-stable
4. Uploads files recursively with `rclone moveto`, preserving relative subfolders
5. Writes `<filename>.MOVED` next to each moved file with destination and metadata
6. Retries failures with real exponential backoff (up to max retries)
7. On remote path conflicts, renames the uploaded file with a machine suffix instead of overwriting
8. Tracks processed files by file identity (not just basename), so same-name files are handled safely

## State and Logs

### Capture config service

- Log file: `/var/log/antscihub-capture-config.log`
- State: `/var/lib/antscihub-capture-config/`

### Upload service

State is user-scoped (no root-owned writable paths required):

- State root: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload`
- Processed list: `processed.txt`
- Retry counters: `failed/*.retries`
- Retry schedule: `next-retry/*.next`
- Worker log: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/antscihub-upload.log`

## Validation Scripts

Run static checks:

```bash
bash 2-test_scripts/run_static_checks.sh
```

## Notes

- Upload requires `rclone` installed and configured for `gdrive_personal`.
- Camera detection requires `libcamera-hello` or `rpicam-hello` and supports OV64A40 plus IMX708-family sensors (including Raspberry Pi Camera Module 3 NoIR).
- For best Owlcam fallback detection when auto-detect cannot enumerate third-party sensors, install `i2c-tools` (`i2ctransfer`).
