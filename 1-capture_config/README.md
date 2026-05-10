# Capture Config

This folder contains the boot-time camera detection/configuration logic.

Behavior:
- Detect the attached camera on boot.
- Compare it with the existing managed firmware block.
- Write only the needed Raspberry Pi firmware lines.
- Reboot only when the config actually changes.

Supported cameras for now:
- `ov64a40` -> Owlcam settings
- `imx708` -> Arducam V3 settings

Managed block written into `config.txt`:

```text
# antscihub-capture-config BEGIN
camera_auto_detect=0
dtoverlay=ov64a40,link-frequency=360000000
dtoverlay=cma,cma-256
# antscihub-capture-config END
```

```text
# antscihub-capture-config BEGIN
camera_auto_detect=0
dtoverlay=imx708
# antscihub-capture-config END
```
