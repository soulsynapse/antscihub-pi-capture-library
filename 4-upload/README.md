# Upload

Upload worker that monitors `~/Desktop/5-UPLOAD` for new video files and moves them to a remote destination using `rclone`.

## Files

- [upload_worker.sh](upload_worker.sh) - main upload loop script
- [upload.service](upload.service) - systemd service file

## How It Works

1. Monitors `~/Desktop/5-UPLOAD` for new files
2. Waits for each file to stabilize (not being written to)
3. Runs `rclone move <file> <remote:path>`
4. On success, creates a `.uploaded` reference file at the original location pointing to the remote path
5. Tracks processed files to avoid re-uploading

## Setup

1. Edit `upload.service` to set `RCLONE_REMOTE` and `RCLONE_PATH` environment variables:

```ini
Environment="RCLONE_REMOTE=gdrive"
Environment="RCLONE_PATH=Videos"
```

2. Make sure `rclone` is installed and configured on the Pi:

```bash
sudo apt-get install rclone
rclone config  # Configure your remotes
```

3. Install the service:

```bash
sudo cp upload.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable upload.service
sudo systemctl start upload.service
```

4. Check status:

```bash
sudo systemctl status upload.service
sudo journalctl -u upload.service -f
```

## File Reference

When a file is successfully uploaded, a `.uploaded` reference file is created. For example:

```
~/Desktop/5-UPLOAD/myvideo.mp4 → moved to remote
~/Desktop/5-UPLOAD/myvideo.mp4.uploaded → reference file created
```

The reference file contains:
- Original filename
- Remote path
- Upload timestamp

