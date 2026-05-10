# Upload

`upload_worker.sh` continuously monitors the service user's `<desktop>/5-UPLOAD` directory and uploads stable files to remote storage.

## Defaults

The installed service uses:

- `RCLONE_REMOTE=gdrive_personal`
- `RCLONE_PATH=5-UPLOAD`

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

- Destination root is `RCLONE_REMOTE:RCLONE_PATH` (default: `gdrive_personal:5-UPLOAD`)
- Each file is moved to `RCLONE_PATH/<relative path from local 5-UPLOAD>`
- No extra nested `5-UPLOAD/5-UPLOAD` level is created

## Safety/Resilience

- File age + stability checks before upload
- Single-instance process lock
- Atomic processed-state updates
- Retry counters and exponential backoff scheduling
- File identity tracking (basename + inode + size + mtime), not basename-only
- `.MOVED` reference files are written beside each moved file with destination/timestamp metadata

## Service Data Locations

By default (for the service user):

- State: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload`
- Log: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/antscihub-upload.log`
- Lock: `${XDG_RUNTIME_DIR:-/tmp}/antscihub-upload.lock`

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
