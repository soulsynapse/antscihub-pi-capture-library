# antscihub-pi-capture-library

This repo has been reduced to the boot-time camera configuration flow.

Top-level folders:
- [1-capture_config](1-capture_config) - detect the attached camera, write the required Raspberry Pi firmware lines, and reboot only when the config changes
- [2-test_scripts](2-test_scripts) - reserved for testing and validation scripts
- [3-recording_scripts](3-recording_scripts) - reserved for future recording scripts
- [4-upload](4-upload) - placeholder for the future upload service that will move completed video files with `rclone`

## Current behavior

The boot config service is intentionally narrow:
- Detect the attached camera model.
- Match it against a small supported list.
- Write the correct managed block into `config.txt`.
- Reboot only if the managed block changed.

Supported cameras for now:
- `ov64a40` -> Owlcam
- `imx708` -> Arducam V3

## Install

```bash
bash install.sh
```

That installs and enables `antscihub-capture-config.service`.

## Upload placeholder

The future upload service is documented in [4-upload/README.md](4-upload/README.md) as pseudocode for now.