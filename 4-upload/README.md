# Upload

Automated upload worker that monitors `~/Desktop/5-UPLOAD` for video files and moves them to a remote destination using `rclone`.

## Features

- **File Stability Detection** - Waits for files to finish being written before uploading
- **Atomic State Tracking** - Never re-uploads files, even if the service crashes
- **Process Lock** - Only one upload worker runs at a time
- **Exponential Backoff** - Retries failed uploads with intelligent backoff (30s → 1m → 5m → 10m)
- **File Validation** - Only uploads video files with supported extensions and minimum size
- **Comprehensive Logging** - Logs to systemd journal for easy debugging

## Files

- `upload_worker.sh` - Main upload loop script
- `upload.service` - Systemd service template (install.sh creates the actual service)

## How It Works

1. Continuously scans `~/Desktop/5-UPLOAD` for new files
2. Validates files:
   - **Accepts all file types** (videos, text files, documents, folders, etc.)
   - Skips `.MOVED` reference files (from previous successful uploads)
   - Skips hidden files (starting with `.`)
   - Skips temp files (starting with `~`)
3. Checks file stability:
   - Measures size at T=0 and T=10s
   - Only proceeds if sizes match (file not being written)
   - Minimum age: 30 seconds before upload attempted
4. Runs `rclone move <file> <remote:path>`
5. On success:
   - Creates `.MOVED` reference file
   - Marks file as processed (never re-uploads)
6. On failure:
   - Increments retry counter
   - Uses exponential backoff (max 5 retries per file)
   - Logs failure for manual investigation

## State Management

State files stored in `/var/lib/antscihub-upload/`:
- `processed.txt` - List of successfully uploaded files (atomic updates)
- `failed/<filename>.retries` - Retry count for each failed file

Process lock in `/var/run/antscihub-upload.lock` - ensures only one instance runs.

## Installation

The `install.sh` script installs the upload service with these defaults:

```bash
RCLONE_REMOTE=gdrive_personal
RCLONE_PATH=5-UPLOAD
```

Start and enable the service:

```bash
sudo systemctl start antscihub-upload.service
sudo systemctl enable antscihub-upload.service
```

### Override destination (optional)

```bash
sudo systemctl edit antscihub-upload.service
```

Add these lines in the `[Service]` section:
```ini
Environment="RCLONE_REMOTE=gdrive_personal"
Environment="RCLONE_PATH=5-UPLOAD"
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl start antscihub-upload.service
```

## Configuration

### Rclone Setup

First, configure `rclone`:

```bash
rclone config
# Follow prompts to add a remote (e.g., "gdrive" for Google Drive)
```

List available remotes:
```bash
rclone listremotes
```

### Environment Variables

- `RCLONE_REMOTE` - The rclone remote name (e.g., `gdrive_personal`, `b2`, `s3`)
- `RCLONE_PATH` - The path on the remote (e.g., `5-UPLOAD`, `backup/pi-videos`)

### Tuning Parameters

Edit `upload_worker.sh` to adjust:
- `FILE_STABILITY_CHECK_INTERVAL=10` - Seconds between size checks
- `MIN_FILE_AGE=30` - Minimum seconds before uploading
- `MAX_RETRIES=5` - Max upload attempts per file
- `SCAN_INTERVAL=10` - Check for new files every N seconds

## Usage

### Check service status

```bash
systemctl status antscihub-upload.service
```

### View logs (real-time)

```bash
sudo journalctl -u antscihub-upload.service -f
```

### View logs (last N lines)

```bash
sudo journalctl -u antscihub-upload.service -n 100
```

### Stop/start the service

```bash
sudo systemctl stop antscihub-upload.service
sudo systemctl start antscihub-upload.service
```

### Check processed files

```bash
cat /var/lib/antscihub-upload/processed.txt
```

### Check failed uploads

```bash
ls -la /var/lib/antscihub-upload/failed/
cat /var/lib/antscihub-upload/failed/myfile.mp4.retries
```

## Troubleshooting

**Service not uploading:**
```bash
# Check if service is running
systemctl is-active antscihub-upload.service

# Check logs
journalctl -u antscihub-upload.service -f

# Verify rclone config
rclone listremotes
rclone ls <remote>:<path>
```

**File not uploaded (no error visible):**
- Check if file meets validation requirements (extension, size, age)
- Run `ls -la ~/Desktop/5-UPLOAD/` to see files

**Rclone authentication failed:**
- Re-run `rclone config` to fix auth token
- Check rclone docs: https://rclone.org/docs/

**Disk space issues:**
- Check available space: `df -h ~/Desktop/5-UPLOAD`
- Uploaded files are moved (deleted locally), not copied
- If rclone fails, files stay local until successful upload

## Reference Files

After a successful upload, a `.uploaded` reference file is created:

```text
# Upload successful
# Original file: myvideo.mp4
# Moved to: gdrive_personal:5-UPLOAD/myvideo.mp4
# Date: 2026-05-09T14:30:45Z
```

This serves as proof that the file was uploaded and shows where it's stored.




