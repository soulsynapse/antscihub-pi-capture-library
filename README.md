# antscihub-pi-capture-library

Lightweight Raspberry Pi services/scripts for:

1. Manual camera profile application (`antcam`)
2. Capture commands (`antcam set focus`, `antcam set fps`, `antcam set length`, `antcam set segment`, `antcam set loop`, `antcam report`, `antcam start`, `antcam stop`, `antcam focus`)
3. Store-and-forward upload control (`antcam upload ...`) with profile routing and retention modes

## Repository Layout

- [1-capture_config](1-capture_config) - Camera profile CLI + profile files
- [2-test_scripts](2-test_scripts) - Validation scripts
- [3-recording_scripts](3-recording_scripts) - Recording scripts + docs
- [4-upload](4-upload) - Upload worker service

## Quick Start

### Install

```bash
sudo bash install.sh
```

This install flow:

- Installs `antcam` to `/usr/local/bin/antcam`
- Installs camera profiles to `/etc/antscihub/camera-profiles`
- Installs recording scripts to `/etc/antscihub/recording-scripts`
- Disables/removes the old dynamic camera service (`antscihub-capture-config.service`)
- Installs/updates `antscihub-upload.service`

`install.sh` is standalone and safe to re-run after repo updates.

### Camera Profile Commands

```bash
sudo antcam list
sudo antcam report cam
sudo antcam show imx708
sudo antcam apply imx708
```

`antcam report cam` prints a make/model camera label for the active profile (for example, `Raspberry Pi Camera Module 3 (Sony IMX708)`).

Apply options:

- `--dry-run` (preview only)
- `--no-reboot` (write config but do not reboot)

Current bundled profiles:

- `auto` -> `camera_auto_detect=1`
- `imx708` -> `camera_auto_detect=0`, `dtoverlay=imx708`
- `owlcam` -> `camera_auto_detect=0`, `dtoverlay=ov64a40,...`, `dtoverlay=cma,cma-256`

### How `antcam apply` Works

1. Finds active `config.txt` (`/boot/firmware/config.txt` or `/boot/config.txt`)
2. Backs it up (`.antcam.bak.<timestamp>`)
3. Removes previous managed block
4. Removes known conflicting camera lines
5. Writes selected profile in the managed block:
   - `# antscihub-capture-config BEGIN`
   - `# antscihub-capture-config END`
6. Reboots (unless `--no-reboot`)

### Recording Commands

```bash
antcam set focus <lens-position|auto>
antcam set fps <value>
antcam set length <duration>
antcam set segment <duration>
antcam set loop <duration|none|0>
antcam upload set profile <field|cloud|local>
antcam upload set retention <protect|rolling>
antcam upload report
antcam upload report queue
antcam upload report targets
antcam upload pause
antcam upload resume
antcam upload reload
antcam upload prune --older-than <duration> [--dry-run]
antcam report focus
antcam report fps
antcam report length
antcam report segment
antcam report loop
antcam start <recording-script-name>
antcam stop
antcam focus
```

`antcam start <recording-script-name>` resolves the active user's Desktop path and then:

- Creates `<desktop>/4-CAPTURE` if missing
- Resolves `<recording-script-name>` from `/etc/antscihub/recording-scripts/` (installed) or `3-recording_scripts/` (repo)
- Reads focus value from `<desktop>/4-CAPTURE/config/focus-lens-position.txt` (defaults to `auto` if not set)
- Reads fps value from `<desktop>/4-CAPTURE/config/recording-fps.txt` (defaults to `1` if not set)
- Reads recording length from `<desktop>/4-CAPTURE/config/recording-length.txt` (defaults to `0s`)
- Reads segment length from `<desktop>/4-CAPTURE/config/recording-segment.txt` (defaults to `1m`) for scripts that use segments (for example, `video.sh`)
- Reads loop interval from `<desktop>/4-CAPTURE/config/recording-loop.txt` (defaults to `1m`; accepts `none`/`0` to disable loop scheduling)
- Writes active recording state to `<desktop>/4-CAPTURE/config/recording-active-state.env` for stop control
- Runs the selected recording script from inside `<desktop>/4-CAPTURE`
- Selected recording script writes to `<desktop>/5-UPLOAD/YYYY-MM-DD_HH-MM-SS__hostname/` (`video.sh` -> `video-%05d.h264`, `photos.sh` -> `photos-%05d.jpg`)
- Publishes encrypted Fleet report messages at recording start/end (`report=recording_start|recording_end`)
- On recording-script failure, writes timestamped diagnostics to `<desktop>/5-UPLOAD/diagnostics/recordings/`

`antcam stop` resolves the active recording state file and gracefully stops the active recording process (`SIGINT` first, then `SIGTERM` if needed).

Bundled recording scripts:

- `video.sh` -> configurable fps video (`antcam set fps <value>`, default `1`), configurable length/segment/loop (`antcam set length`, `antcam set segment`, `antcam set loop`), and focus from saved `lens-position` or `auto`
- `photos.sh` -> loop-driven still-photo capture (`antcam set loop <duration|none|0>`). Positive loop values require minimum `10s`; `none`/`0` disables looping and captures one photo per run

`antcam focus` resolves the active user's Desktop path and then:

- Creates `<desktop>/4-CAPTURE` if missing
- Runs the autofocus helper script from `1-capture_config/antcam_focus_autofocus.sh` (or installed copy at `/etc/antscihub/antcam_focus_autofocus.sh`)
- Final output is the `lens-position` value for direct use with `rpicam-vid --lens-position <value>`
- Drops a focus photo into `<desktop>/5-UPLOAD/diagnostics/recordings/` named `YYYY-MM-DD__T-HH-MM-SS__focus-result-lens-position-#.#__hostname.jpeg`
- On autofocus helper failure, writes timestamped diagnostics to `<desktop>/5-UPLOAD/diagnostics/recordings/`

### Upload Service

The upload service defaults:

- `RCLONE_REMOTE=gdrive_personal`
- `RCLONE_PATH=` (remote root)
- Source directory auto-resolved to `<desktop>/5-UPLOAD`

Commands:

```bash
sudo systemctl enable --now antscihub-upload.service
systemctl status antscihub-upload.service
journalctl -u antscihub-upload.service -f
```

Upload control via `antcam`:

```bash
antcam upload set profile <field|cloud|local>
antcam upload set retention <protect|rolling>
antcam upload report
antcam upload report queue
antcam upload report targets
antcam upload pause
antcam upload resume
antcam upload prune --older-than 72h --dry-run
```

## Operational Defaults

- Remote: `gdrive_personal`
- Remote path: empty (remote root)
- Upload service user: installer chooses invoking non-root user when possible

## Upload Worker Behavior

The upload worker:

1. Resolves Desktop and watches `<desktop>/5-UPLOAD`
2. Treats `<desktop>/5-UPLOAD` as immutable spool input
3. Skips hidden files, temp files (`~*`), and legacy `.MOVED` files
4. Persists queue lifecycle in `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/queue.db`
5. Waits for minimum age + size stability
   - still images: `3s` age + `3s` stability
   - `state.env` and `*.log`: `5m` age
6. Ships by copy only (no source-file move in normal flow)
   - cloud: `rclone copyto`
   - local target: atomic local copy (temp -> final)
7. Uses upload profiles (`field`, `cloud`, `local`) for routing
8. Applies retention policy:
   - `protect`: stop active recording at high watermark
   - `rolling`: prune oldest shipped files from 80% down to 70%
9. Retries failures with exponential backoff and marks dead-letter when exhausted
10. Emits upload status events to stdout and Fleet report topics (`fleet/report/{DEVICE_ID}`, encrypted payloads)

## State Paths

Upload worker (user-scoped):

- `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/`
- `${XDG_STATE_HOME:-~/.local/state}/antscihub-upload/antscihub-upload.log`

Legacy camera state/log paths from previous dynamic service may still exist:

- `/var/lib/antscihub-capture-config/`
- `/var/log/antscihub-capture-config.log`

## Validation

Run:

```bash
bash 2-test_scripts/run_static_checks.sh
```

## Notes

- Upload requires `rclone` configured for `gdrive_personal`
- Camera profile selection is now explicit and operator-controlled via `antcam`
- `antcam apply` requires `sudo` (except `--dry-run`)
- `antcam start` does not require `sudo`; if run with `sudo`, it still targets the invoking user's Desktop
- MQTT implementation handoff notes are in `MQTT_INTEGRATION_NOTES.md`
