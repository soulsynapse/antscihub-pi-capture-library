# Camera Profiles (`antcam`)

Camera config is now manual and profile-driven.

This module no longer relies on a boot-time dynamic camera detection service.  
Instead, you apply a known camera profile explicitly with `antcam`.

## Commands

```bash
sudo antcam list
sudo antcam current
sudo antcam show <profile>
sudo antcam apply <profile>
sudo antcam apply <profile> --dry-run
sudo antcam apply <profile> --no-reboot
antcam start
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
- `antcam start` creates missing `4-CAPTURE/record.sh` and `4-CAPTURE/experiment.txt` as empty files before execution
- You can add custom profiles by dropping `*.conf` files into `/etc/antscihub/camera-profiles`
- `install.sh` installs/updates the CLI and profile files
