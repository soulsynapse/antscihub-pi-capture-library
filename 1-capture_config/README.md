# Camera Profiles (`antcam`)

Camera config is now manual and profile-driven.

This module no longer relies on a boot-time dynamic camera detection service.  
Instead, you apply a known camera profile explicitly with `antcam`.

## Commands

```bash
sudo antcam list
sudo antcam cam report
sudo antcam show <profile>
sudo antcam apply <profile>
sudo antcam apply <profile> --dry-run
sudo antcam apply <profile> --no-reboot
antcam focus set <lens-position|auto>
antcam ev set <value|auto>
antcam saturation set <value|default>
antcam awbgains set <red,blue|auto>
antcam fps set <value>
antcam length set <duration>
antcam segment set <duration>
antcam intra set <frames|none|0>
antcam photo-every set <duration|none|0>
antcam name set <name>
antcam upload set profile <field|cloud|local>
antcam upload set retention <protect|rolling>
antcam upload set local-target <path>
antcam upload set remote <rclone-remote>
antcam upload set remote-path <path>
antcam upload set watermark-high <percent>
antcam upload set watermark-low <percent>
antcam upload report
antcam upload report queue
antcam upload report targets
antcam upload test
antcam upload pause
antcam upload resume
antcam upload reload
antcam upload prune --older-than <duration> [--dry-run]
antcam capture report
antcam focus report
antcam ev report
antcam saturation report
antcam awbgains report
antcam fps report
antcam length report
antcam segment report
antcam intra report
antcam photo-every report
antcam name report
antcam start <recording-script-name>
antcam stop
antcam recording resume-if-needed
antcam focus check
```

## Profiles

Profiles are installed to:

```text
/etc/antscihub/camera-profiles
```

Current bundled profiles:

- `auto` -> `camera_auto_detect=1`
- `imx708` -> `camera_auto_detect=0`, `dtoverlay=imx708`
- `owlcam` -> `camera_auto_detect=0`, `dtoverlay=ov64a40,...`, `dtoverlay=cma,cma-256`

## How `apply` works

1. Finds active `config.txt` (`/boot/firmware/config.txt` or `/boot/config.txt`)
2. Backs it up (`.antcam.bak.<timestamp>`)
3. Removes previous managed block
4. Removes known conflicting camera lines
5. Writes selected profile in the managed block:
   - `# antscihub-capture-config BEGIN`
   - `# antscihub-capture-config END`
6. Reboots (unless `--no-reboot`)

## Notes

- `antcam apply` requires `sudo` (except `--dry-run`)
- `antcam start` does not require `sudo`; if run with `sudo`, it still targets the invoking user's Desktop
- `antcam start` requires a recording script name and resolves it from `/etc/antscihub/recording-scripts/` (installed) or `3-recording_scripts/` (repo)
- Bundled recording script names include `video` and `photos` (for example: `antcam start video`, `antcam start photos`)
- `antcam focus set <lens-position|auto>` writes the focus setting file used by recording scripts (`auto` omits `--lens-position` at record time)
- `antcam ev set <value|auto>` writes EV exposure compensation used by recording scripts; `auto` omits `--ev`, while numeric values including `0` add `--ev <value>`
- `antcam saturation set <value|default>` writes saturation used by recording scripts and focus check; `default` omits `--saturation`, while numeric values including `0` add `--saturation <value>`
- `antcam awbgains set <red,blue|auto>` writes fixed red/blue AWB gains used by recording scripts and focus check; `auto` omits `--awbgains`, while positive `red,blue` values add `--awbgains <red,blue>`
- `antcam fps set <value>` writes the fps setting file used by recording scripts
- `antcam length set <duration>` writes recording length (examples: `30h`, `10m`, `45s`, `1h30m`)
- `antcam segment set <duration>` writes segment length (examples: `10m`, `30s`, `1h`)
- `antcam intra set <frames|none|0>` writes the video intra frame period; positive integers add `--intra <frames>`, while `none`/`0` keeps the camera default
- `antcam photo-every set <duration|none|0>` writes the still-photo interval used by `photos.py`
- `antcam name set <name>` writes the recording name component used in output folder/file stems (allowed characters: `A-Z`, `a-z`, `0-9`, `.`, `_`, `-`; default `BLANK`)
- Positive `photo-every` values keep start-time aligned scheduling (examples: `1m`, `30s`, `2h`)
- `none` or `0` disables photo interval scheduling and keeps one-shot behavior
- With positive `photo-every`, photos run at `t=0` and then every interval while `scheduled_time <= length` (for example, `length=10m` and `photo-every=10m` -> 2 photos)
- `antcam upload set profile <field|cloud|local>` selects destination routing mode for store-and-forward uploader
- `antcam upload set retention <protect|rolling>` controls threshold behavior (`protect` stops recording, `rolling` prunes shipped files)
- `antcam upload set local-target <path>` sets attached-drive/local destination path (`none` to unset)
- `antcam upload set remote <rclone-remote>` sets cloud remote (`none` to unset)
- `antcam upload set remote-path <path>` sets remote subpath (`none` or empty for remote root)
- `antcam upload set watermark-high <percent>` and `... watermark-low <percent>` set spool thresholds (defaults `80`/`70`)
- `antcam upload report`, `antcam upload report queue`, and `antcam upload report targets` expose upload config and queue state
- `antcam upload report` and `antcam upload report targets` fall back to `antscihub-upload.service` environment defaults (for example `RCLONE_REMOTE`) when Desktop config files are unset
- `antcam upload test` performs a one-shot upload probe using current profile routing with first-attempt jitter and no queue/retry loop
- `antcam upload pause` / `resume` toggles upload processing without stopping the service
- `antcam upload reload` restarts `antscihub-upload.service`
- `antcam upload prune --older-than <duration> [--dry-run]` prunes old shipped artifacts from spool
- `antcam capture report` returns a consolidated capture+recording settings report
- `antcam focus report` returns the saved focus value (or `auto` default)
- `antcam ev report` returns the saved EV exposure compensation value (or `auto` default)
- `antcam saturation report` returns the saved saturation value (or `default`)
- `antcam awbgains report` returns the saved AWB gains value (or `auto`)
- `antcam fps report` returns the saved fps value (or default)
- `antcam length report` returns the saved recording length (or default)
- `antcam segment report` returns the saved segment length (or default)
- `antcam intra report` returns the saved intra frame period (or default)
- `antcam photo-every report` returns the saved photo interval (or default)
- `antcam name report` returns the saved recording name (or default `BLANK`)
- `antcam cam report` returns camera make/model label (for example `Raspberry Pi Camera Module 3 (Sony IMX708)` when using profile `imx708`)
- `antcam start` publishes encrypted Fleet report messages when recording starts/ends (`recording_start`, `recording_end`); failures include `reason_code`, `reason_detail`, and `diagnostic_file`
- `antcam start` writes active recording state to `<desktop>/4-CAPTURE/config/recording-active-state.env` so `antcam stop` can target the live recording process
- `antcam start` writes finite-window resume state to `<desktop>/4-CAPTURE/config/recording-resume-state.env` when `length > 0s`
- `antcam stop` gracefully stops the active recording script (including `video` and `photos`) with `SIGINT` first, then `SIGTERM` if needed; the recording workers forward stop signals to active `rpicam`/`libcamera` children so the camera pipeline is released
- `antcam recording resume-if-needed` resumes pending finite recording windows (used automatically by `antscihub-recording-resume.service` at boot)
- If the recording script fails, `antcam start` writes a timestamped diagnostic log to `<desktop>/5-UPLOAD/diagnostics/recordings/` and includes the compact failure detail in MQTT
- `antcam focus check` does not require `sudo`; if run with `sudo`, it still targets the invoking user's Desktop
- `antcam focus check` runs the autofocus helper script from `1-capture_config/antcam_focus_autofocus.sh` (or `/etc/antscihub/antcam_focus_autofocus.sh` on installed systems)
- `antcam focus check` uses the saved EV setting from `antcam ev set <value|auto>`; `auto` omits `--ev`, numeric values including `0` add `--ev <value>`
- `antcam focus check` uses the saved saturation setting from `antcam saturation set <value|default>`; `default` omits `--saturation`, numeric values including `0` add `--saturation <value>`
- `antcam focus check` uses the saved AWB-gains setting from `antcam awbgains set <red,blue|auto>`; `auto` omits `--awbgains`, positive `red,blue` values add `--awbgains <red,blue>`
- `antcam focus check` reports the rpicam/libcamera metadata from the autofocus image, including exposure time, analogue gain, digital gain, colour gains, colour temperature, frame duration, and derived frame rate when `FrameDuration` is present
- `antcam focus check` final output is the `lens-position` value for `rpicam-vid --lens-position <value>`
- `antcam focus check` copies the captured focus photo and matching `.metadata.txt` into `<desktop>/5-UPLOAD/diagnostics/recordings/` for uploader pickup
- If the autofocus helper fails, `antcam focus check` writes a timestamped diagnostic log to `<desktop>/5-UPLOAD/diagnostics/recordings/`
- You can add custom profiles by dropping `*.conf` files into `/etc/antscihub/camera-profiles`
- `install.sh` installs/updates the CLI, profile files, focus helper, and recording scripts
