# Upload

`upload_worker.sh` continuously monitors the service user's `<desktop>/5-UPLOAD` directory and uploads stable files to remote storage.

## Defaults

The installed service uses:

- `RCLONE_REMOTE=gdrive_personal`
- `RCLONE_PATH=` (empty by default, meaning remote root)
- `UPLOAD_DIR=<detected desktop>/5-UPLOAD` (set by `install.sh` per device user)
- `MACHINE_SUFFIX=<hostname>` by default (override with service env var if needed)

Override via:

```bash
sudo systemctl edit antscihub-upload.service
```

Example override:

```ini
[Service]
Environment="RCLONE_REMOTE=myremote"
Environment="RCLONE_PATH=myfolder"
```

Then apply:

```bash
sudo systemctl daemon-reload
sudo systemctl restart antscihub-upload.service
```

## What Gets Uploaded

- Regular files in `<desktop>/5-UPLOAD` (recursively, including subfolders)
- Excludes hidden files, `~` temp files, and `.MOVED` files

Remote behavior:

- Destination root is `RCLONE_REMOTE:RCLONE_PATH` (default: `gdrive_personal:` root)
- If `RCLONE_PATH` is set, each file is moved to `RCLONE_PATH/<relative path from local 5-UPLOAD>`
- If `RCLONE_PATH` is empty, files are moved directly under remote root with preserved relative paths
- No extra nested `5-UPLOAD/5-UPLOAD` level is created

## Safety/Resilience

- File age + stability checks before upload
- Still-image fast path: common image formats (`jpg`, `jpeg`, `png`, `tif`, `tiff`, `bmp`, `gif`, `webp`, `heic`, `heif`, and common RAW formats) use 3s minimum age + 3s stability window
- Non-image files keep conservative defaults: 30s minimum age + 10s stability window
- Single-instance process lock
- Atomic processed-state updates
- Retry counters and exponential backoff scheduling
- File identity tracking (basename + inode + size + mtime), not basename-only
- Remote conflict handling: if target path already exists, upload is renamed with machine suffix
- `rclone moveto --immutable` prevents overwrite-on-conflict races
- `.MOVED` reference files are written beside each moved file with destination/timestamp metadata

## Service Data Locations

By default (for the service user):

- State: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload`
- Log: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/antscihub-upload.log`
- Lock: `${XDG_RUNTIME_DIR:-/tmp}/antscihub-upload.lock`

## Console Upload Events

For orchestrators that monitor process stdout, each upload emits explicit event lines:

```text
UPLOAD_EVENT status=start ts=<utc-iso8601> file=<shell-escaped-path> remote=<shell-escaped-remote> size_bytes=<n>
UPLOAD_EVENT status=success ts=<utc-iso8601> file=<shell-escaped-path> remote=<shell-escaped-remote> size_bytes=<n>
UPLOAD_EVENT status=failed ts=<utc-iso8601> file=<shell-escaped-path> remote=<shell-escaped-remote> size_bytes=<n>
```

## Troubleshooting

```bash
systemctl status antscihub-upload.service
journalctl -u antscihub-upload.service -n 100
journalctl -u antscihub-upload.service -f
```

Check rclone:

```bash
rclone listremotes
rclone ls gdrive_personal:
```
