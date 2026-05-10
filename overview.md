# Repository Overview

This repository provides two essential services for Raspberry Pi camera systems:

1. **Automatic Camera Detection & Configuration** - Detects the attached camera on boot and configures the Pi's firmware automatically
2. **Automatic Video Upload** - Monitors a folder for video files and automatically uploads them to remote storage

## Top-Level Folders

### [1-capture_config](1-capture_config) - Camera Detection Service
Boot-time service that:
- Detects `ov64a40` (Owlcam) or `imx708` (Arducam V3) cameras
- Writes correct firmware overlays to `/boot/firmware/config.txt`
- Reboots only when the config actually changes
- Prevents infinite reboot loops with attempt counter
- Logs all activity to `/var/log/antscihub-capture-config.log`

**Service:** `antscihub-capture-config.service` (systemd oneshot)

### [2-test_scripts](2-test_scripts)
Placeholder for testing and validation scripts (future development)

### [3-recording_scripts](3-recording_scripts)
Placeholder for camera recording helper scripts (future development)

### [4-upload](4-upload) - Upload Worker Service
Continuous service that:
- Monitors `~/Desktop/5-UPLOAD` for new video files
- Validates files (extension, size, not temp files)
- Waits for file stability before uploading
- Moves files to remote storage using `rclone`
- Retries failed uploads with exponential backoff
- Tracks processed files (never re-uploads)
- Creates `.uploaded` reference files after success

**Service:** `antscihub-upload.service` (systemd long-running)

## Top-Level Files

- [README.md](README.md) - Quick start guide and feature overview
- [install.sh](install.sh) - Unified installer for both services
- [antscihub.manifest](antscihub.manifest) - Deployment manifest for automated systems
- [overview.md](overview.md) - This file
- [ISSUES_AND_FIXES.md](ISSUES_AND_FIXES.md) - Detailed problem analysis and solutions

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  antscihub-capture-config.service (runs on boot)        │
│  • Detects camera (ov64a40 or imx708)                   │
│  • Updates /boot/firmware/config.txt                    │
│  • Reboots if config changed                            │
│  • Prevents reboot loops with attempt counter           │
└─────────────────────────────────────────────────────────┘
                           ↓
                    [System Ready]
                           ↓
┌─────────────────────────────────────────────────────────┐
│  [Camera Recording Process]                              │
│  Produces: ~/Desktop/5-UPLOAD/video.mp4                 │
└─────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────┐
│  antscihub-upload.service (continuous monitoring)       │
│  • Watches ~/Desktop/5-UPLOAD/                          │
│  • Validates files (ext, size, stability)               │
│  • Moves to remote: rclone move file remote:path/       │
│  • Creates .uploaded reference files                    │
│  • Retries with exponential backoff                     │
└─────────────────────────────────────────────────────────┘
                           ↓
                  [Remote Storage]
                  (Google Drive, B2, S3, etc.)
```

## Data Flow

1. **Boot:**
   - `antscihub-capture-config.service` runs
   - Detects camera, updates `/boot/firmware/config.txt` if needed
   - Reboots if config changed (one-time only per hardware change)

2. **Recording (external process):**
   - Recording scripts capture video to `~/Desktop/5-UPLOAD/`
   - File is written and grows in size

3. **Upload:**
   - `antscihub-upload.service` continuously monitors folder
   - Detects new file
   - Waits for stability (size unchanged for 30+ seconds)
   - Moves file to remote with `rclone move`
   - Creates `.uploaded` reference file on success
   - Cleans up retry state

## State Management

### Camera Config Service
```
/var/lib/antscihub-capture-config/
  ├── last-config         # Last successfully applied config block
  ├── attempt-count       # Current reboot attempt counter
  └── apply.lock          # Process lock
```

### Upload Service
```
/var/lib/antscihub-upload/
  ├── processed.txt       # List of uploaded files (atomic)
  ├── upload.lock         # Process lock
  └── failed/             # Failed upload tracking
      └── filename.retries    # Retry count per failed file
```

### Logs
```
/var/log/
  └── antscihub-capture-config.log    # Camera config logs
  └── antscihub-upload.log             # Upload worker logs
```

Also available via systemd:
```bash
journalctl -u antscihub-capture-config.service
journalctl -u antscihub-upload.service
```

## Runtime Behavior

### Camera Detection (runs once on boot)
- **Duration:** < 30 seconds typically
- **Result:** Config file updated or no-op (if already correct)
- **Reboot:** Only if config changed
- **Loop Protection:** Max 3 consecutive reboots before failing
- **Logging:** `/var/log/antscihub-capture-config.log` + systemd journal

### Upload Worker (runs continuously)
- **Scan Interval:** Every 10 seconds
- **File Stability Check:** 10-second size verification
- **Minimum Age:** 30 seconds before upload attempted
- **Minimum Size:** 10 MB
- **Retry Strategy:** 5 attempts with exponential backoff (30s → 10m)
- **Concurrency:** Only one instance runs (PID lock)
- **Atomicity:** State writes are atomic (temp file + move pattern)
- **Logging:** `/var/log/antscihub-upload.log` + systemd journal

## Implementation Quality

All critical issues identified during design have been fixed:
- ✓ Reboot loop prevention
- ✓ File stability detection before upload
- ✓ Atomic state management (no re-uploads on crash)
- ✓ Process locking (concurrent access prevention)
- ✓ Exponential backoff on failures
- ✓ File validation (extension, size, temp files)
- ✓ Robust camera detection with fallbacks
- ✓ Proper service installation and upgrades

See [ISSUES_AND_FIXES.md](ISSUES_AND_FIXES.md) for complete analysis and implementation details.

## Testing Recommendations

Before production deployment:
1. Test on spare Pi with real camera (ov64a40 or imx708)
2. Verify boot config service completes successfully
3. Test upload service with small test files
4. Verify no re-uploads on service restart
5. Test network failure and recovery
6. Check all log files are being written
7. Validate rclone remote is accessible

See testing checklist in [ISSUES_AND_FIXES.md](ISSUES_AND_FIXES.md).
