# Implementation Issues & Fixes

**Status: Critical and Important issues IMPLEMENTED** ✓

## Completed Fixes

### ✓ 1. Camera Config Reboot Loop Prevention
**Fixed in:** `1-capture_config/apply_camera_config.sh`

Implemented:
- State directory `/var/lib/antscihub-capture-config/` for tracking attempts
- Attempt counter with max limit of 3 reboot attempts
- Logging to `/var/log/antscihub-capture-config.log`
- File locking to prevent concurrent runs
- Clear error messages instead of silent failures

---

### ✓ 2. Upload File Stability Detection
**Fixed in:** `4-upload/upload_worker.sh`

Implemented:
- Dual-check file stability: measure size at T=0 and T=10s
- Configurable minimum file age (30 seconds default)
- Skips files that are still being written
- Ignores temp files starting with `.` or `~`

---

### ✓ 3. Upload State File Race Condition
**Fixed in:** `4-upload/upload_worker.sh`

Implemented:
- Atomic state writes using temp file + move pattern
- State written immediately after successful rclone move
- File locking on state directory (`/var/lib/antscihub-upload/`)
- Prevents crash from losing upload state

---

### ✓ 4. Upload Process Lock
**Fixed in:** `4-upload/upload_worker.sh`

Implemented:
- PID lockfile in `/var/run/antscihub-upload.lock`
- Only one upload worker runs at a time
- Stale lock detection (removes locks older than implicit window)
- Clean exit on lock conflict

---

### ✓ 5. Upload Retry Logic
**Fixed in:** `4-upload/upload_worker.sh`

Implemented:
- Exponential backoff: 30s → 1m → 5m → 10m (max)
- Max retry count of 5 per file
- Retry count tracking in `/var/lib/antscihub-upload/failed/`
- Failed files logged separately from processed files

---

### ✓ 6. File Validation Before Upload
**Fixed in:** `4-upload/upload_worker.sh`

Implemented:
- **Accepts all file types** (videos, text files, documents, folders, etc.)
- Skips `.MOVED` reference files (from previous successful uploads)
- Skips hidden files (`.filename`)
- Skips temp files (`~filename`)
- Reference file extension changed from `.uploaded` to `.MOVED`

---

### ✓ 7. Camera Config Robustness
**Fixed in:** `1-capture_config/apply_camera_config.sh`

Implemented:
- Try `libcamera-hello` first (more stable)
- Fall back to `rpicam-hello` if needed
- Enhanced pattern matching for `ov64a40`, `owlcam`, `imx708`, `arducam`
- Detailed logging of detection attempts and output

---

### ✓ 8. Service Installation & Upgrade
**Fixed in:** `install.sh`

Implemented:
- Proper old service stop + disable before replacement
- Both capture config and upload services installed
- Correct script paths substituted (not placeholders)
- Service validation after installation
- Clear user instructions for rclone configuration
- Comprehensive logging and status messages

---

## Remaining Issues

### 9. Service Logging Configuration
**Status:** IMPLEMENTED in service files
- Both service files now have `StandardOutput=journal` and `StandardError=journal`
- Logs accessible via `journalctl -u service-name -f`

---

### 10. Monitoring & Alerting
**Status:** Future enhancement (not critical for MVP)
- Could add optional MQTT/webhook reporting
- Implement health check endpoint
- Add `/etc/antscihub/config` for centralized settings

---

### 11. Test Scripts in 2-test_scripts
**Status:** Future enhancement (not critical for MVP)
- Placeholder folder created
- Can add mock versions for local testing later

---

## Summary of Changes

| Component | Issue | Fix | Impact |
|-----------|-------|-----|--------|
| Camera Config | Infinite reboot loop | Attempt counter + guard | Prevents hardware getting stuck |
| Camera Config | Fragile detection | Robust fallback + logging | Better compatibility |
| Upload Worker | Early upload of incomplete files | Dual-size check + min age | Prevents file corruption |
| Upload Worker | Lost state on crash | Atomic writes + locking | No re-uploads |
| Upload Worker | Concurrent access | Process lock | Data integrity |
| Upload Worker | Hammer on network failure | Exponential backoff | Reduces load |
| Upload Worker | Uploads random files | Extension/size validation | Controlled uploads |
| Installer | Service replacement issues | Proper cleanup + config | Clean upgrades |

---

## Testing Checklist (for Pi deployment)

- [ ] Run `sudo bash install.sh` and verify both services enabled
- [ ] Trigger camera config with unsupported camera (should fail without reboot)
- [ ] Test camera config with real ov64a40 or imx708
- [ ] Verify `/var/log/antscihub-capture-config.log` exists
- [ ] Configure rclone and test upload with small file
- [ ] Verify `/var/lib/antscihub-upload/processed.txt` tracks files
- [ ] Test upload interruption (kill process mid-upload) and verify retry
- [ ] Test concurrent upload attempts (second instance should exit cleanly)
- [ ] Check logs via `journalctl -u antscihub-capture-config -f`
- [ ] Check logs via `journalctl -u antscihub-upload -f`




