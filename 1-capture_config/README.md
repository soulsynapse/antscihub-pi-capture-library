# Capture Config

Boot-time camera detection and Raspberry Pi firmware configuration service.

## Behavior

- Detects the attached camera on every boot
- If no camera is attached, exits cleanly without modifying config
- Compares with the existing managed firmware block in `config.txt`
- Writes the correct boot overlays only when the config actually differs
- Reboots **only when the config changes** (not on every boot)
- Prevents infinite reboot loops with attempt counter
- Logs all activity to `/var/log/antscihub-capture-config.log`

## Supported Cameras

- **OV64A40** (Owlcam) → `camera_auto_detect=0`, `dtoverlay=ov64a40`, `dtoverlay=cma`
- **IMX708** (Arducam V3) → `camera_auto_detect=0`, `dtoverlay=imx708`

## Detection Strategy

1. Try `libcamera-hello --list-cameras` (primary)
2. Fall back to `rpicam-hello --list-cameras` if needed
3. Pattern match on camera model names
4. Log detailed output for debugging

## Reboot Guard

The service implements a reboot attempt counter to prevent infinite loops:
- Tracks attempt count in `/var/lib/antscihub-capture-config/attempt-count`
- Max 3 reboot attempts before failing and halting
- Counter resets when a successful config is applied
- Logs failures to `/var/log/antscihub-capture-config.log`

## Files

- `apply_camera_config.sh` - The main detection and config script
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
- Check `/var/lib/antscihub-capture-config/attempt-count` for retry state

**Stuck in reboot loop:**
- This should not happen with the reboot guard
- If it does, check logs and manually set `attempt-count` to 0 or higher
- Edit `/boot/firmware/config.txt` manually to fix the config
