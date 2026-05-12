# Test Scripts

Run static validation:

```bash
bash run_static_checks.sh
```

Checks include:

- Bash syntax for core scripts
- `antcam` command surface (including `antcam start` and `antcam test`)
- Recording trigger docs presence
- Presence of key upload-worker safety functions
- Install defaults for `gdrive_personal:5-UPLOAD`
