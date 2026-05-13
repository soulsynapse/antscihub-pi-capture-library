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
- Special case: files under any `config/` path component are uploaded with `rclone copyto` (not moved), and no `.MOVED` placeholder is written for them

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
- `config/` paths are treated as read-only sources locally: upload succeeds without deleting local files or writing placeholders

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

## MQTT Upload Events (Orchestrator)

The uploader publishes report events to Fleet using encrypted MQTT payloads.

- Default topic: `fleet/report/{DEVICE_ID}`
- Topic override: `FLEET_EVENT_TOPIC_TEMPLATE` (supports `{DEVICE_ID}` placeholder)
- Preferred transport: `fleet-publish --topic ... --json ...`
- Also supported: `mqtt_report.py --topic ... --json ...`
- Fallback transport: `mqtt_client.FleetMQTT` (python module from fleet setup)

Each event object includes core fields before encryption:

- `event` (`report` for uploader messages)
- `report` (uploader report name, for example `upload_start`)
- `device_id`
- `timestamp` (unix seconds)

Additional context fields are included when available:

- `service` (`antscihub-upload.service` by default)
- `success`
- `severity` (`ROUTINE`, `INFO`, `WARNING`, `ERROR`)
- `message`
- `folder`
- `file`
- `remote`
- `size_bytes`
- `cmd`
- `attempt`
- `reason`
- `exit_code`

The `message` field is human-readable and includes upload context at every report stage, including file path and size (plus remote target, attempt, and failure reason when available).

Uploader `report` values:

- `upload_detected`
- `upload_renamed`
- `upload_start`
- `upload_success`
- `upload_failed`
- `upload_retry_scheduled`
- `upload_gave_up`

Device ID resolution order:

1. `DEVICE_ID` env var
2. `FLEET_DEVICE_ID` env var
3. Fleet client probes (`fleet-publish`)
4. `mqtt_client.DEVICE_ID` (python)
5. Known fleet device-id files
6. Fallback: machine suffix (hostname-derived)

Optional service overrides (if needed):

```ini
[Service]
Environment="DEVICE_ID=pi-0123"
Environment="FLEET_DEVICE_ID=pi-0123"
Environment="FLEET_EVENT_TOPIC_TEMPLATE=fleet/report/{DEVICE_ID}"
Environment="FLEET_PUBLISH_BIN=fleet-publish"
Environment="MQTT_REPORT_BIN=mqtt_report.py"
Environment="MQTT_EVENT_ENABLED=true"
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
