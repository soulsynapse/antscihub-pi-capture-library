# Capture Config

Boot-time camera detection and Raspberry Pi firmware configuration service.

## Behavior

- Detects camera state on every boot
- Supports explicit profile modes through `/etc/default/antscihub-capture-config`:
  - `CAMERA_PROFILE_MODE=dynamic` (default)
  - `CAMERA_PROFILE_MODE=auto`
  - `CAMERA_PROFILE_MODE=owlcam`
- In `dynamic` mode:
  - Uses auto-detect profile for non-Owl sensors
  - Uses manual OV64A40 profile for Owlcam
  - If no camera is enumerated, tries Owlcam I2C chip probe
  - If still ambiguous, runs a single bounded Owlcam probe boot, then settles on auto if no camera is found (no endless probe loop)
- Compares against managed firmware block in `config.txt`
- Writes only when configuration actually changes
- Removes stale camera overlay lines before writing the managed block
- Reboots only on configuration changes
- Uses reboot-attempt guard to avoid loops
- Logs to `/var/log/antscihub-capture-config.log`

## Supported Cameras

- **OV64A40** (Owlcam) -> `camera_auto_detect=0`, `dtoverlay=ov64a40`, `dtoverlay=cma`
- **IMX708 family** (Arducam V3, Raspberry Pi Camera Module 3, Raspberry Pi Camera Module 3 NoIR) -> auto-detect profile (`camera_auto_detect=1`)

## Detection Strategy

1. Try `rpicam-hello --list-cameras` (primary on Bookworm/Trixie), then fall back to `libcamera-hello`, `rpicam-still`, and `libcamera-still`
2. Pattern-match Owlcam signatures (`ov64a40`, `owlsight`, `arducam_64mp`, etc.)
3. If no camera is enumerated, probe OV64A40 chip ID (`0x566441`) via `i2ctransfer` (best effort)
4. Apply profile selection rules from `CAMERA_PROFILE_MODE`
5. Write config and reboot only when needed

## Reboot Guard

The service implements a reboot attempt counter to prevent infinite loops:
- Tracks attempt count in `/var/lib/antscihub-capture-config/attempt-count`
- Max 3 reboot attempts before failing and halting
- Counter resets when no config change is needed
- Logs failures to `/var/log/antscihub-capture-config.log`

## Files

- `apply_camera_config.sh` - The main detection and config script
- `/etc/default/antscihub-capture-config` - Optional mode override (`dynamic|auto|owlcam`)
- Managed block markers in `config.txt`:
  - `# antscihub-capture-config BEGIN`
  - `# antscihub-capture-config END`

## Logs

View logs:
```bash
sudo journalctl -u antscihub-capture-config.service -f
tail -f /var/log/antscihub-capture-config.log
```

## Troubleshooting

**Service won't start:**
```bash
systemctl status antscihub-capture-config.service
journalctl -u antscihub-capture-config.service -n 50
```

**Config not being applied:**
- Check `/var/log/antscihub-capture-config.log`
- Verify camera is detected: run `libcamera-hello --list-cameras` manually
- If using Owlcam and auto-detect cannot enumerate it, install `i2c-tools` for fallback probing (`i2ctransfer`)
- Check `/var/lib/antscihub-capture-config/attempt-count` for retry state

**Stuck in reboot loop:**
- This should not happen with the reboot guard
- If it does, check logs and manually set `attempt-count` to 0 or higher
- Edit `/boot/firmware/config.txt` manually to fix the config
