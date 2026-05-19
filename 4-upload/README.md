# Upload (Store-and-Forward)

`upload_worker.sh` implements a spool-and-ship upload model.

- Spool source: `<desktop>/5-UPLOAD`
- Queue state: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/queue.db`
- Log: `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/antscihub-upload.log`

## Core Behavior

- Source files are treated as immutable spool artifacts.
- Normal upload flow does **not** move/delete source files.
- Queue lifecycle uses durable SQLite state (`QUEUED`, `IN_FLIGHT`, `RETRY_WAIT`, `SHIPPED`, `DEAD_LETTER`, `PRUNED`).
- Upload path is copy-only:
  - Cloud: `rclone copyto`
  - Local target: local atomic copy (temp + rename)

## Profiles

`upload-profile.txt` controls destination routing:

- `field`: local target first, cloud fallback
- `cloud`: cloud only
- `local`: local only

Profile setting file:

- `<desktop>/4-CAPTURE/config/upload-profile.txt`

Related target config files:

- `upload-local-target.txt`
- `upload-rclone-remote.txt`
- `upload-rclone-path.txt`

## Retention

`upload-retention.txt` controls disk behavior:

- `protect`: if spool usage crosses high watermark, request graceful recording stop (`antcam stop`)
- `rolling`: if spool usage crosses high watermark, prune oldest shipped artifacts until low watermark

Watermark config files:

- `upload-high-watermark-percent.txt` (default `80`)
- `upload-low-watermark-percent.txt` (default `70`)

Pause file:

- `upload-paused.txt` (`true` or `false`)

## File Maturity / Stability

- Still image fast path: 3s min age + 3s stability
- Non-image default: 30s min age + 10s stability
- `state.env` and `*.log`: 5 minutes min age before upload

## Events

Worker emits:

- stdout `UPLOAD_EVENT ...` lines
- encrypted Fleet report events (`fleet/report/{DEVICE_ID}` by default)

Typical statuses:

- `queued`
- `in_flight`
- `shipped`
- `failed`
- `retry`
- `dead_letter`
- `pruned`
- `paused`
- `protect_stop`

## Service

```bash
sudo systemctl enable --now antscihub-upload.service
systemctl status antscihub-upload.service
journalctl -u antscihub-upload.service -f
```

Override service env:

```bash
sudo systemctl edit antscihub-upload.service
```

Common overrides:

```ini
[Service]
Environment="UPLOAD_PROFILE=field"
Environment="UPLOAD_RETENTION=protect"
Environment="UPLOAD_HIGH_WATERMARK_PERCENT=80"
Environment="UPLOAD_LOW_WATERMARK_PERCENT=70"
Environment="RCLONE_REMOTE=gdrive_personal"
Environment="RCLONE_PATH=antscihub"
Environment="UPLOAD_LOCAL_TARGET_PATH=/mnt/antscihub"
```

## Troubleshooting

```bash
systemctl status antscihub-upload.service
journalctl -u antscihub-upload.service -n 100
journalctl -u antscihub-upload.service -f
rclone listremotes
```
