# Camera Profiles (`antscam`)

Camera config is now manual and profile-driven.

This module no longer relies on a boot-time dynamic camera detection service.  
Instead, you apply a known camera profile explicitly with `antscam`.

## Commands

```bash
sudo antscam list
sudo antscam current
sudo antscam show <profile>
sudo antscam apply <profile>
sudo antscam apply <profile> --dry-run
sudo antscam apply <profile> --no-reboot
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
2. Backs it up (`.antscam.bak.<timestamp>`)
3. Removes previous managed block
4. Removes known conflicting camera lines
5. Writes selected profile in the managed block:
   - `# antscihub-capture-config BEGIN`
   - `# antscihub-capture-config END`
6. Reboots (unless `--no-reboot`)

## Notes

- `antscam apply` requires `sudo` (except `--dry-run`)
- You can add custom profiles by dropping `*.conf` files into `/etc/antscihub/camera-profiles`
- `install.sh` installs/updates the CLI and profile files
