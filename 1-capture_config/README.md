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
antcam fps set <value>
antcam length set <duration>
antcam segment set <duration>
antcam loop set <duration|none|0>
antcam name set <suffix>
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
antcam upload pause
antcam upload resume
antcam upload reload
antcam upload prune --older-than <duration> [--dry-run]
antcam capture report
antcam focus report
antcam fps report
antcam length report
antcam segment report
antcam loop report
antcam name report
antcam start <recording-script-name>
antcam stop
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
- `antcam fps set <value>` writes the fps setting file used by recording scripts
- `antcam length set <duration>` writes recording length (examples: `30h`, `10m`, `45s`, `1h30m`)
- `antcam segment set <duration>` writes segment length (examples: `10m`, `30s`, `1h`)
- `antcam loop set <duration|none|0>` writes the loop interval used by recording scripts
- `antcam name set <suffix>` writes recording filename/folder suffix (allowed characters: `A-Z`, `a-z`, `0-9`, `.`, `_`, `-`; default `BLANK`)
- Positive loop values keep start-time aligned scheduling (examples: `1m`, `30s`, `2h`)
- `none` or `0` disables loop scheduling
- `antcam upload set profile <field|cloud|local>` selects destination routing mode for store-and-forward uploader
- `antcam upload set retention <protect|rolling>` controls threshold behavior (`protect` stops recording, `rolling` prunes shipped files)
- `antcam upload set local-target <path>` sets attached-drive/local destination path (`none` to unset)
- `antcam upload set remote <rclone-remote>` sets cloud remote (`none` to unset)
- `antcam upload set remote-path <path>` sets remote subpath (`none` or empty for remote root)
- `antcam upload set watermark-high <percent>` and `... watermark-low <percent>` set spool thresholds (defaults `80`/`70`)
- `antcam upload report`, `antcam upload report queue`, and `antcam upload report targets` expose upload config and queue state
- `antcam upload report` and `antcam upload report targets` fall back to `antscihub-upload.service` environment defaults (for example `RCLONE_REMOTE`) when Desktop config files are unset
- `antcam upload pause` / `resume` toggles upload processing without stopping the service
- `antcam upload reload` restarts `antscihub-upload.service`
- `antcam upload prune --older-than <duration> [--dry-run]` prunes old shipped artifacts from spool
- `antcam capture report` returns a consolidated capture+recording settings report
- `antcam focus report` returns the saved focus value (or `auto` default)
- `antcam fps report` returns the saved fps value (or default)
- `antcam length report` returns the saved recording length (or default)
- `antcam segment report` returns the saved segment length (or default)
- `antcam loop report` returns the saved loop interval (or default)
- `antcam name report` returns the saved recording suffix (or default `BLANK`)
- `antcam cam report` returns camera make/model label (for example `Raspberry Pi Camera Module 3 (Sony IMX708)` when using profile `imx708`)
- `antcam start` publishes encrypted Fleet report messages when recording starts/ends (`recording_start`, `recording_end`)
- `antcam start` writes active recording state to `<desktop>/4-CAPTURE/config/recording-active-state.env` so `antcam stop` can target the live recording process
- `antcam stop` gracefully stops the active recording script (including `video` and `photos`) with `SIGINT` first, then `SIGTERM` if needed
- If the recording script fails, `antcam start` writes a timestamped diagnostic log to `<desktop>/5-UPLOAD/diagnostics/recordings/`
- `antcam focus check` does not require `sudo`; if run with `sudo`, it still targets the invoking user's Desktop
- `antcam focus check` runs the autofocus helper script from `1-capture_config/antcam_focus_autofocus.sh` (or `/etc/antscihub/antcam_focus_autofocus.sh` on installed systems)
- `antcam focus check` final output is the `lens-position` value for `rpicam-vid --lens-position <value>`
- `antcam focus check` copies the captured focus photo into `<desktop>/5-UPLOAD/diagnostics/recordings/` as `YYYY-MM-DD__T-HH-MM-SS__focus-result-lens-position-#.#__hostname.jpeg`
- If the autofocus helper fails, `antcam focus check` writes a timestamped diagnostic log to `<desktop>/5-UPLOAD/diagnostics/recordings/`
- You can add custom profiles by dropping `*.conf` files into `/etc/antscihub/camera-profiles`
- `install.sh` installs/updates the CLI, profile files, focus helper, and recording scripts
