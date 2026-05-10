# antscihub-pi-capture-library

Lightweight Raspberry Pi services/scripts for:

1. Manual camera profile application (`antscam`)
2. Continuous upload of completed files from Desktop to remote storage via `rclone`

## Repository Layout

- [1-capture_config](1-capture_config) - Camera profile CLI + profile files
- [2-test_scripts](2-test_scripts) - Validation scripts
- [3-recording_scripts](3-recording_scripts) - Recording scripts (placeholder)
- [4-upload](4-upload) - Upload worker service

## Quick Start

### Install

```bash
sudo bash install.sh
```

This install flow:

- Installs `antscam` to `/usr/local/bin/antscam`
- Installs camera profiles to `/etc/antscihub/camera-profiles`
- Disables/removes the old dynamic camera service (`antscihub-capture-config.service`)
- Installs/updates `antscihub-upload.service`

`install.sh` is standalone and safe to re-run after repo updates.

### Camera Profile Commands

```bash
sudo antscam list
sudo antscam current
sudo antscam show imx708
sudo antscam apply imx708
```

Apply options:

- `--dry-run` (preview only)
- `--no-reboot` (write config but do not reboot)

### Upload Service

The upload service defaults:

- `RCLONE_REMOTE=gdrive_personal`
- `RCLONE_PATH=` (remote root)
- Source directory auto-resolved to `<desktop>/5-UPLOAD`

Commands:

```bash
sudo systemctl enable --now antscihub-upload.service
systemctl status antscihub-upload.service
journalctl -u antscihub-upload.service -f
```

## Upload Worker Behavior

The upload worker:

1. Resolves Desktop and watches `<desktop>/5-UPLOAD`
2. Skips hidden files, temp files (`~*`), and `.MOVED` files
3. Waits for minimum age + size stability
4. Uploads with `rclone moveto`, preserving folder structure
5. Writes `<filename>.MOVED` with destination metadata
6. Retries failures with exponential backoff
7. Adds machine suffix on remote-name conflicts
8. Tracks processed files by file identity

## Notes

- Upload requires `rclone` configured for `gdrive_personal`
- Camera profile selection is now explicit and operator-controlled via `antscam`
