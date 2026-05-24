# antscihub-pi-capture-library

Lightweight Raspberry Pi services/scripts for:

1. Manual camera profile application (`antcam`)
2. Capture commands (`antcam focus set`, `antcam fps set`, `antcam length set`, `antcam segment set`, `antcam photo-every set`, `antcam capture report`, `antcam start`, `antcam stop`, `antcam recording resume-if-needed`, `antcam focus check`)
3. Store-and-forward upload control (`antcam upload set ...`, `antcam upload report ...`, `antcam upload ...`) with profile routing and retention modes

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
- Installs/updates `antscihub-recording-resume.service` (boot-time finite-window recording resume)

`install.sh` is standalone and safe to re-run after repo updates.

### Camera Profile Commands

```bash
sudo antcam list
sudo antcam cam report
sudo antcam show imx708
sudo antcam apply imx708
```

`antcam cam report` prints a make/model camera label for the active profile (for example, `Raspberry Pi Camera Module 3 (Sony IMX708)`).

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
antcam focus set <lens-position|auto>
antcam fps set <value>
antcam length set <duration>
antcam segment set <duration>
antcam photo-every set <duration|none|0>
antcam upload set profile <field|cloud|local>
antcam upload set retention <protect|rolling>
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
antcam fps report
antcam length report
antcam segment report
antcam photo-every report
antcam start <recording-script-name>
antcam stop
antcam recording resume-if-needed
antcam focus check
```

`antcam start <recording-script-name>` resolves the active user's Desktop path and then:

- Creates `<desktop>/4-CAPTURE` if missing
- Resolves `<recording-script-name>` from `/etc/antscihub/recording-scripts/` (installed) or `3-recording_scripts/` (repo)
- Reads focus value from `<desktop>/4-CAPTURE/config/focus-lens-position.txt` (defaults to `auto` if not set)
- Reads fps value from `<desktop>/4-CAPTURE/config/recording-fps.txt` (defaults to `1` if not set)
- Reads recording length from `<desktop>/4-CAPTURE/config/recording-length.txt` (defaults to `0s`)
- Reads segment length from `<desktop>/4-CAPTURE/config/recording-segment.txt` (defaults to `1m`) for scripts that use segments (for example, `video.py`)
- Reads photo interval from `<desktop>/4-CAPTURE/config/recording-photo-every.txt` (defaults to `1m`; accepts `none`/`0` to disable interval scheduling and use one-shot)
- Writes active recording state to `<desktop>/4-CAPTURE/config/recording-active-state.env` for stop control
- Writes finite-window resume state to `<desktop>/4-CAPTURE/config/recording-resume-state.env` (`length > 0s` only)
- Runs the selected recording script from inside `<desktop>/4-CAPTURE`
- Selected recording script writes to `<desktop>/5-UPLOAD/YYYY-MM-DD_HH-MM-SS__hostname/` (`video.py` -> `video-%05d.h264`, `photos.py` -> `photos-%05d.jpg`)
- Publishes encrypted Fleet report messages at recording start/end (`report=recording_start|recording_end`)
- On recording-script failure, writes timestamped diagnostics to `<desktop>/5-UPLOAD/diagnostics/recordings/`

`antcam stop` resolves the active recording state file and gracefully stops the active recording process (`SIGINT` first, then `SIGTERM` if needed).
`antcam recording resume-if-needed` resumes pending finite recordings if the saved recording window has remaining time. `antscihub-recording-resume.service` runs this command automatically on boot.

Bundled recording scripts:

- `video.py` (with `video.sh` retained as a compatibility launcher) -> configurable fps video (`antcam fps set <value>`, default `1`), default 1080p (`1920x1080`), configurable length/segment (`antcam length set`, `antcam segment set`), and focus from saved `lens-position` or `auto`
- `photos.py` (with `photos.sh` retained as a compatibility launcher) -> interval-driven still-photo capture (`antcam photo-every set <duration|none|0>`). Positive values require minimum `10s`; `none`/`0` keeps one-shot behavior. For positive intervals, captures occur at `t=0` and then every interval while `scheduled_time <= recording_length`

`antcam focus check` resolves the active user's Desktop path and then:

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
antcam upload test
antcam upload pause
antcam upload resume
antcam upload prune --older-than 72h --dry-run
```

`antcam upload report` and `antcam upload report targets` fall back to `antscihub-upload.service` environment defaults (for example `RCLONE_REMOTE`) when Desktop upload config files are unset.
`antcam upload test` runs a one-shot upload probe using current profile routing with first-attempt jitter and no queue/retry loop.

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
6. Applies first-attempt jitter after an artifact is ready to upload (`0-30s` by default, configurable)
7. Ships by copy only (no source-file move in normal flow)
   - cloud: `rclone copyto`
   - local target: atomic local copy (temp -> final)
8. Uses upload profiles (`field`, `cloud`, `local`) for routing
9. Applies retention policy:
   - `protect`: stop active recording at high watermark
   - `rolling`: prune oldest shipped files from 80% down to 70%
10. Retries failures with exponential backoff and marks dead-letter when exhausted
11. Emits upload status events to stdout and Fleet report topics (`fleet/report/{DEVICE_ID}`, encrypted payloads)

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
