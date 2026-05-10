# antscihub-pi-capture-library

Lightweight, reliable Raspberry Pi camera detection and automatic upload service.

## What It Does

- **On Boot:** Automatically detects which camera is attached (Owlcam or Arducam V3) and configures the Raspberry Pi firmware accordingly
- **Upload:** Monitors a folder for recorded video files and automatically uploads them to a remote destination (Google Drive, B2, S3, etc.) using `rclone`

## Top-Level Folders

- [1-capture_config](1-capture_config) - Camera detection service (runs on boot)
- [2-test_scripts](2-test_scripts) - Testing and validation scripts (placeholder)
- [3-recording_scripts](3-recording_scripts) - Recording scripts (placeholder)
- [4-upload](4-upload) - Upload worker service

## Quick Start

### Install

```bash
bash install.sh
```

This installs two systemd services:
- `antscihub-capture-config.service` - Auto-detects camera and configures boot firmware
- `antscihub-upload.service` - Monitors and uploads video files

### Configure Upload Service

```bash
# Upload destination is preset to gdrive_personal:5-UPLOAD
# Start the upload service
sudo systemctl start antscihub-upload.service
```

### Check Status

```bash
systemctl status antscihub-capture-config.service
systemctl status antscihub-upload.service

# View logs
journalctl -u antscihub-capture-config.service -f
journalctl -u antscihub-upload.service -f
```

## How It Works

### Camera Config Service

1. Runs once on boot (via systemd `Type=oneshot`)
2. Detects attached camera using `libcamera-hello` or `rpicam-hello`
3. Checks `/boot/firmware/config.txt` for existing configuration
4. If config needs updating:
   - Backs up current config
   - Writes new managed block with correct overlays
   - Reboots to apply (only if config actually changed)
5. Prevents infinite reboot loops with attempt counter (max 3 reboots)

### Upload Service

1. Runs continuously, scanning `~/Desktop/5-UPLOAD` every 10 seconds
2. Validates files before upload:
   - Checks extension (`.mp4`, `.mkv`, `.avi`, `.mov`, `.flv`, `.wmv`)
   - Minimum size: 10 MB
   - Not a temp file (doesn't start with `.` or `~`)
3. Waits for file stability (size doesn't change for 30+ seconds)
4. Moves file to remote using `rclone move` (not copy, so local storage stays small)
5. Creates `.uploaded` reference file if successful
6. Retries failed uploads with exponential backoff (max 5 attempts)
7. Never re-uploads the same file

## Key Features

✓ **Reboot Loop Prevention** - Attempt counter prevents infinite boot cycles  
✓ **File Stability Detection** - Waits for files to finish being written  
✓ **Atomic State Tracking** - Never loses uploads or re-uploads files  
✓ **Process Lock** - Only one upload worker at a time  
✓ **Smart Retry** - Exponential backoff on failures (30s → 10m)  
✓ **File Validation** - Only uploads video files of sufficient size  
✓ **Comprehensive Logging** - All activity logged to systemd journal  
✓ **Secure Upgrades** - Clean service replacement without conflicts  

## Supported Cameras

- **OV64A40** (Owlcam) - Requires: `camera_auto_detect=0`, `dtoverlay=ov64a40`, `dtoverlay=cma`
- **IMX708** (Arducam V3) - Requires: `camera_auto_detect=0`, `dtoverlay=imx708`

## Known Limitations

- Requires `libcamera-hello` or `rpicam-hello` for camera detection
- Upload requires `rclone` to be installed and configured
- Only detects cameras at `/boot/firmware/config.txt` or `/boot/config.txt`

## Troubleshooting

**Check camera config logs:**
```bash
sudo journalctl -u antscihub-capture-config.service -f
tail -f /var/log/antscihub-capture-config.log
```

**Check upload logs:**
```bash
sudo journalctl -u antscihub-upload.service -f
tail -f /var/log/antscihub-upload.log
```

**Verify rclone is configured:**
```bash
rclone listremotes
rclone ls gdrive_personal:  # or your remote name
```

**Check processed files:**
```bash
cat /var/lib/antscihub-upload/processed.txt
ls -la /var/lib/antscihub-upload/failed/
```

## Implementation Notes

See [ISSUES_AND_FIXES.md](ISSUES_AND_FIXES.md) for detailed documentation of all critical and important issues that were identified and fixed during implementation.

## Service Files

- `install.sh` - Installation and service setup script
- `antscihub.manifest` - Deployment manifest
- `ISSUES_AND_FIXES.md` - Problem analysis and solutions

## Additional Resources

See individual README files:
- [1-capture_config/README.md](1-capture_config/README.md) - Camera detection details
- [4-upload/README.md](4-upload/README.md) - Upload service details

## Upload placeholder

The future upload service is documented in [4-upload/README.md](4-upload/README.md) as pseudocode for now.
