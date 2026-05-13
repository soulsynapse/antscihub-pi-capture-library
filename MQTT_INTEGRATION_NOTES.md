# MQTT Integration Notes

This file is the handoff reference for future sessions working on MQTT behavior in this repo.

## Scope

MQTT reporting is implemented in:

- `1-capture_config/antcam`
- `4-upload/upload_worker.sh`

Both now publish encrypted payloads only (no `--no-encrypt` usage).

## Topic Model

- Default report topic: `fleet/report/{DEVICE_ID}`
- Override template: `FLEET_EVENT_TOPIC_TEMPLATE`
  - Supports `{DEVICE_ID}` placeholder.

## Publisher Fallback Order

For both `antcam` and uploader:

1. `fleet-publish`
2. `mqtt_report.py`
3. Python `mqtt_client` fallback

### `antcam` Python fallback

- Tries `from mqtt_client import fleet` first.
- Then falls back to `FleetMQTT`.
- When encryption flag is supported, calls use `encrypt=True`.

### uploader Python fallback

- Uses `FleetMQTT`.
- When encryption flag is supported, calls use `encrypt=True`.

## Device ID Resolution

`DEVICE_ID` resolution order in both scripts:

1. `DEVICE_ID` env var
2. `FLEET_DEVICE_ID` env var
3. `fleet-publish --device-id` or `fleet-publish device-id`
4. Python `mqtt_client.DEVICE_ID`
5. Known device-id files
6. Fallback hostname-derived value

Important implementation detail: callers now invoke `resolve_device_id >/dev/null` and then read `DEVICE_ID_CACHE`, so resolution is cached within a process.

## Event Shapes

All emitted report events use `event=report` and include:

- `report`
- `device_id`
- `timestamp`
- `severity`
- `message`
- `success`

Optional context fields are included by source (for example `service`, `folder`, `script`, `file`, `remote`, `attempt`, `reason`, `exit_code`).

## `antcam` Events

### `antcam start`

- `recording_start` (`ATTENTION`, `success=true`)
- `recording_end` (`INFO` on success, `ERROR` on failure, includes `exit_code`)

### `antcam test`

- `test_start` (`ATTENTION`, `success=true`)
- `test_end` (`INFO` on success, `ERROR` on failure, includes `exit_code`)

`antcam test` runs `4-CAPTURE/test.sh` and does not require `experiment.txt`.

Failure diagnostics from `antcam` are written for uploader pickup:

- `record.sh` failures: `<desktop>/5-UPLOAD/diagnostics/recordings/`
- `test.sh` failures: `<desktop>/5-UPLOAD/diagnostics/test/`
- If the primary diagnostic path fails, a fallback timestamped file is written in `<desktop>/5-UPLOAD/diagnostics/`

## Uploader Events

Uploader report names:

- `upload_detected`
- `upload_renamed`
- `upload_start`
- `upload_success`
- `upload_failed`
- `upload_retry_scheduled`
- `upload_gave_up`

Uploader additionally logs local operational lines for:

- file detection (`Detected file: ...`)
- rename decisions on conflict (`Renaming remote upload target: ...`)
- retry scheduling and failures

MQTT payloads include context such as `file`, `folder`, `remote`, `size_bytes`, `attempt`, `reason`, and `exit_code`.
The uploader `message` field also includes key details at every stage (file path, size, remote target, attempt, and reason when present) so GUI-only message views remain informative.

Uploader path special-case:

- Any file whose relative path includes a `config` directory component is treated as a read-only local source.
- Those files are uploaded with `rclone copyto` (not `moveto`).
- No local `.MOVED` placeholder file is written for those config-path uploads.

## Validation Checks

Static checks are in `2-test_scripts/run_static_checks.sh`.

Current MQTT-related assertions include:

- `test_start` and `test_end` present in `antcam`
- `encrypt=True` present in both `antcam` and uploader python fallbacks
- `--no-encrypt` absent from both `antcam` and uploader scripts

## Quick Pi Test Commands

### 1) Direct publish sanity check

```bash
DEV="$(hostname)"
fleet-publish --topic "fleet/report/${DEV}" --json "{\"event\":\"report\",\"report\":\"manual_probe\",\"device_id\":\"${DEV}\",\"timestamp\":$(date +%s),\"severity\":\"INFO\",\"message\":\"manual probe\",\"success\":true}"
```

### 2) `antcam test` success/failure events

```bash
CAP="$HOME/Desktop/4-CAPTURE"
mkdir -p "$CAP"

cat > "$CAP/test.sh" <<'EOF'
#!/usr/bin/env bash
echo "[test.sh] success run"
exit 0
EOF
chmod +x "$CAP/test.sh"
antcam test

cat > "$CAP/test.sh" <<'EOF'
#!/usr/bin/env bash
echo "[test.sh] failure run"
exit 7
EOF
chmod +x "$CAP/test.sh"
antcam test || true
```

### 3) Tail uploader service logs

```bash
journalctl -u antscihub-upload.service -f
```

## Guardrails For Future Edits

- Do not reintroduce `--no-encrypt` in publisher paths.
- Keep `report` names stable unless orchestrator mapping is intentionally changed.
- Keep `device_id` and `timestamp` in every payload.
- If transport flags change in fleet tooling, preserve fallback compatibility by trying multiple argument shapes without weakening encryption defaults.
