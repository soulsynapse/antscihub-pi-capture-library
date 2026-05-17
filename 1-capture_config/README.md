# Camera Profiles (`antcam`)

Camera config is now manual and profile-driven.

This module no longer relies on a boot-time dynamic camera detection service.  
Instead, you apply a known camera profile explicitly with `antcam`.

## Commands

```bash
sudo antcam list
sudo antcam report cam
sudo antcam show <profile>
sudo antcam apply <profile>
sudo antcam apply <profile> --dry-run
sudo antcam apply <profile> --no-reboot
antcam set focus <lens-position|auto>
antcam set fps <value>
antcam set length <duration>
antcam set segment <duration>
antcam report focus
antcam report fps
antcam report length
antcam report segment
antcam start <recording-script-name>
antcam stop
antcam focus
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
- Bundled recording script names include `video` and `photo` (for example: `antcam start video`, `antcam start photo`)
- `antcam set focus <lens-position|auto>` writes the focus setting file used by recording scripts (`auto` omits `--lens-position` at record time)
- `antcam set fps <value>` writes the fps setting file used by recording scripts
- `antcam set length <duration>` writes recording length (examples: `30h`, `10m`, `45s`, `1h30m`)
- `antcam set segment <duration>` writes segment length (examples: `10m`, `30s`, `1h`)
- `antcam report focus` returns the saved focus value (or `auto` default)
- `antcam report fps` returns the saved fps value (or default)
- `antcam report length` returns the saved recording length (or default)
- `antcam report segment` returns the saved segment length (or default)
- `antcam report cam` returns camera make/model label (for example `Raspberry Pi Camera Module 3 (Sony IMX708)` when using profile `imx708`)
- `antcam start` publishes encrypted Fleet report messages when recording starts/ends (`recording_start`, `recording_end`)
- `antcam start` writes active recording state to `<desktop>/4-CAPTURE/config/recording-active-state.env` so `antcam stop` can target the live recording process
- `antcam stop` gracefully stops the active recording with `SIGINT` first, then `SIGTERM` if needed
- If the recording script fails, `antcam start` writes a timestamped diagnostic log to `<desktop>/5-UPLOAD/diagnostics/recordings/`
- `antcam focus` does not require `sudo`; if run with `sudo`, it still targets the invoking user's Desktop
- `antcam focus` runs the autofocus helper script from `1-capture_config/antcam_focus_autofocus.sh` (or `/etc/antscihub/antcam_focus_autofocus.sh` on installed systems)
- `antcam focus` final output is the `lens-position` value for `rpicam-vid --lens-position <value>`
- `antcam focus` copies the captured focus photo into `<desktop>/5-UPLOAD/diagnostics/recordings/` as `YYYY-MM-DD__T-HH-MM-SS__focus-result-lens-position-#.#__hostname.jpeg`
- If the autofocus helper fails, `antcam focus` writes a timestamped diagnostic log to `<desktop>/5-UPLOAD/diagnostics/recordings/`
- You can add custom profiles by dropping `*.conf` files into `/etc/antscihub/camera-profiles`
- `install.sh` installs/updates the CLI, profile files, focus helper, and recording scripts
