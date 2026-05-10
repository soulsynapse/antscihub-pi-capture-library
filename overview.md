# Repository Overview

This repository now focuses on one thing: detecting the attached Raspberry Pi camera on boot and writing the correct firmware config block.

## Top-Level Folders

- [1-capture_config](1-capture_config) - boot-time camera detection and config application
- [2-test_scripts](2-test_scripts) - testing and validation scripts
- [3-recording_scripts](3-recording_scripts) - reserved for future recording scripts
- [4-upload](4-upload) - future upload service placeholder

## Top-Level Files

- [README.md](README.md) - short summary of the trimmed-down repo
- [install.sh](install.sh) - installs and enables the boot camera config service
- [antscihub.manifest](antscihub.manifest) - deployment manifest used by the installer tooling

## Runtime Shape

- The boot service detects `ov64a40` and `imx708` for now.
- It writes a managed block into the Raspberry Pi firmware config.
- It reboots only when the block changes.

## Future Shape

- `2-test_scripts` will hold test and validation scripts for the Pi.
- `3-recording_scripts` will hold any camera recording helpers later.
- `4-upload` will hold the upload worker that moves completed videos with `rclone`.

