# Upload Worker Logic (Exact Behavior)

This document describes the exact store-and-forward runtime logic in `upload_worker.py` as currently implemented.

## Entrypoint

- `upload_worker.sh` is a thin launcher.
- It exits with error if `upload_worker.py` is missing.
- It exits with error if `python3` is missing.
- Otherwise it executes: `python3 upload_worker.py`.

## Path Resolution

At startup, the worker resolves paths in this order:

1. `UPLOAD_DIR` environment variable, if set.
2. Otherwise `<desktop>/5-UPLOAD`, where desktop is resolved by:
3. `xdg-user-dir DESKTOP`, if available and non-empty/non-home.
4. `~/.config/user-dirs.dirs` `XDG_DESKTOP_DIR`, if available.
5. `~/Desktop` if it exists, else `~/desktop` if it exists, else `~/Desktop`.

Config directory:

1. `UPLOAD_CONFIG_DIR` environment variable, if set.
2. Otherwise sibling path `<upload_parent>/4-CAPTURE/config`.

State/log/runtime directories:

- `STATE_DIRECTORY` (first `:` segment only), fallback `~/.local/state/antscihub-upload`
- `LOGS_DIRECTORY` (first `:` segment only), fallback `~/.local/state/antscihub-upload`
- `RUNTIME_DIRECTORY` (first `:` segment only), fallback `${XDG_RUNTIME_DIR}` then `/tmp`

Files used:

- DB: `<state_dir>/queue.db`
- Log: `<log_dir>/antscihub-upload.log`
- Lock: `<state_dir>/antscihub-upload.lock`
- Legacy marker: `<state_dir>/processed.txt`
- Protect cooldown stamp: `<state_dir>/last-protect-stop.epoch`

## Startup Sequence

`setup()` performs this exact order:

1. `mkdir -p` for state/log/runtime/upload/config dirs.
2. Acquire single-instance file lock with `fcntl.flock(...LOCK_EX|LOCK_NB)`.
3. Open SQLite DB (`busy_timeout=5000`, `WAL`, `synchronous=FULL`, `foreign_keys=ON`).
4. Create schema if missing (`artifacts`, `artifact_targets`, `attempt_log` + indexes).
5. Normalize artifact `status` to uppercase for all rows.
6. Recover rows with `status='IN_FLIGHT'` by sending each through normal retry/dead-letter scheduling.
7. Archive legacy `processed.txt` to `processed.txt.legacy.<epoch>` if present.
8. Load runtime settings from config files.
9. Initialize open-file tool: `lsof`, else `fuser`, else disabled (`none`).
10. Emit startup logs.

## Runtime Settings Reload (Every Loop)

Every loop, settings are re-read from config files:

- `upload-profile.txt`: valid `field|cloud|local`; invalid -> `field`.
- `upload-retention.txt`: valid `protect|rolling`; invalid -> `protect`.
- `upload-paused.txt`: truthy `1|true|yes|on`, falsy `0|false|no|off`; invalid -> `false`.
- `upload-local-target.txt`: `"none"` -> empty.
- `upload-rclone-remote.txt`: `"none"` -> empty.
- `upload-rclone-path.txt`: `"none"` -> empty; also strips leading/trailing `/`; `"."` -> empty.
- Watermarks from `upload-high-watermark-percent.txt` and `upload-low-watermark-percent.txt`:
- Must be integer `1..99`.
- Defaults high=80 low=70 if invalid.
- If `low >= high`, force `low = max(1, high - 10)`.

## Main Loop

While running:

1. Reload runtime settings.
2. Enforce retention policy (`protect` or `rolling`).
3. Prune `attempt_log` if prune interval elapsed and row count is above cap.
4. If spool dir missing, clear scan queues, sleep `SCAN_INTERVAL`, and continue.
5. Pull up to `MAX_SCAN_FILES_PER_LOOP` file paths from a resumable directory sweep:
6. Sweep state is held in memory (`scan_dir_queue` + `scan_file_queue`).
7. Directory entries are sorted per directory (`child_dirs.sort()`, `child_files.sort()`).
8. The worker does not rebuild a full recursive list each loop.
9. For each scanned file candidate, run filter/maturity/stability/queue logic below.
10. If paused, emit one `paused` event and skip upload attempts.
11. If not paused, enforce global retry pause (when active due to rate limiting) and skip attempts until pause expires.
12. If not paused and no global retry pause, repeatedly choose the oldest pending candidate set and upload oldest-ready:
13. candidates are due `QUEUED` and due `RETRY_WAIT` (`next_retry_epoch <= now`), ordered by `mtime_epoch`, then `discovered_at_epoch`, then `id`.
14. if oldest candidate is still being written/not stable/open/not mature, skip it for now and keep checking the next oldest candidate.
15. attempt one oldest-ready artifact, then re-query and continue until no eligible progress remains for this cycle.
16. if a rate-limited failure sets global retry pause during this cycle, stop further due attempts immediately.
17. Sleep `SCAN_INTERVAL`.

`SCAN_INTERVAL` default: `10` seconds.
`MAX_SCAN_FILES_PER_LOOP` default: `500`.
`MAX_DUE_ATTEMPTS_PER_LOOP` default: `50`.
`RETRY_BASE_DELAY_SECONDS` default: `2`.
`RETRY_MAX_DELAY_SECONDS` default: `600`.
`RETRY_JITTER_MAX_SECONDS` default: `30`.
`INITIAL_UPLOAD_JITTER_MAX_SECONDS` default: `30`.

## Candidate File Filters

A file is skipped if any of these are true:

- Not a regular file.
- Basename starts with `.`.
- Basename starts with `~`.
- Basename ends with `.MOVED`.
- File path is under current local target tree (`local_target_tree_excluded`).
- Path contains `config/` segment (`config_tree_runtime_excluded`).
- Basename matches runtime-state patterns and path is not under `diagnostics/` tree.
- Basename is a log (`*.log`, `*.log.N`, `*.out`, `*.err`) and path is not under `diagnostics/` tree.

Runtime-state glob patterns:

- `*.env`, `*.pid`, `*.lock`, `*.tmp`, `*.temp`, `*.part`, `*.partial`, `*.swp`, `*.swo`
- `*.db`, `*.db-*`, `*.sqlite`, `*.sqlite-*`, `*.journal`
- `state.env`, `capture.log`

## Maturity and Stability Gates

After filtering, candidate must pass all:

1. Min age (`now - mtime`) check:
2. `state.env` or `.log` -> `MIN_FILE_AGE_STATE_AND_LOG` (default 300s)
3. still image -> `MIN_FILE_AGE_STILL_IMAGE` (default 3s)
4. video -> `MIN_FILE_AGE_VIDEO` (default 120s)
5. everything else -> `MIN_FILE_AGE_DEFAULT` (default 30s)
6. Open-file check:
7. If `lsof` available: `lsof -t -- <file>` must return non-zero.
8. Else if `fuser` available: `fuser <file>` must return non-zero.
9. Else no open-file check.
10. Stability check:
11. Worker records the file size and first-seen epoch in an in-memory stability map.
12. File is considered stable only after size remains unchanged for at least the stability interval.
13. No per-file blocking sleep is used.

Stability interval:

- still image -> `FILE_STABILITY_CHECK_INTERVAL_STILL_IMAGE` (default 3s)
- all others -> `FILE_STABILITY_CHECK_INTERVAL_DEFAULT` (default 10s)

Still image extensions:

- `jpg jpeg png tif tiff bmp gif webp heic heif dng cr2 cr3 nef arw orf rw2 raf`

Video extensions:

- `h264 h265 hevc mp4 mov mkv avi mts m2ts ts webm mjpeg yuv`

## Artifact Identity and Registration

Identity string:

- `"<relative_path>|<st_dev>:<size_bytes>:<mtime_ns>|<sample_sha256>"`
- `sample_sha256` is computed from file bytes:
- full file when `size <= 2 * FILE_IDENTITY_SAMPLE_BYTES`
- otherwise `sha256(head_sample + 0x00 + tail_sample)`

`file_key`:

- `sha256(identity_string)`

Registration lookup order:

1. `SELECT id WHERE file_key = ?`
2. If not found, check newest pending row for the same `relative_path` (`status IN QUEUED, RETRY_WAIT`).

If file_key is found:

- Update existing row fields: `file_key`, `relative_path`, `full_path`, `inode`, `size_bytes`, `mtime_epoch`, `last_seen_epoch`, `updated_at_epoch`.
- Existing `status` is preserved.

If file_key is not found and same-path pending row exists:

- Re-arm that same pending row as a fresh queue candidate:
- set `status='QUEUED'`
- reset `retry_count=0`
- set `next_retry_epoch=0`
- clear `last_error`
- update identity/path/stat fields and timestamps
- set `discovered_at_epoch=now`
- delete prior `artifact_targets` rows for that artifact id
- mark any other pending rows for the same `relative_path` as `DEAD_LETTER` with `last_error='superseded_by_newer_file_state'` to prevent duplicate uploads
- Emit `queued` event with reason `artifact_requeued_after_write_activity`.

If neither file_key nor same-path pending row is found:

- Insert new row as `status='QUEUED'`, retry_count `0`, next_retry_epoch `0`.
- Emit `queued` event with reason `artifact_registered`.

## Due Attempt Selection

When not paused, due rows are selected with:

- (`status='QUEUED'` AND `next_retry_epoch <= now`) OR (`status='RETRY_WAIT'` AND `next_retry_epoch <= now`)
- ordered by `mtime_epoch ASC`, then `discovered_at_epoch ASC`, then `id ASC`
- limited per fetch by `MAX_DUE_ATTEMPTS_PER_LOOP`
- worker iterates that ordered list and picks the first candidate that is actually ready to upload.
- if earlier candidates are not ready (open/still-writing/not stable yet), they are skipped for now instead of blocking newer ready artifacts.

Per due row:

1. Resolve source path:
2. Use `full_path` if it exists.
3. Else try `<upload_dir>/<relative_path>` only if it stays inside upload dir.
4. If still missing, call `schedule_retry_or_dead_letter(..., final_error='source_file_missing')`.
5. If recovered path differs, update `artifacts.full_path`.
6. If `relative_path` is empty, derive from current path and update DB.
7. Re-check `can_attempt_artifact_now()`.
8. Re-check readiness gates (maturity/open-file/stability + exclusions).
9. If `status='QUEUED'` and ready and `next_retry_epoch==0`, schedule one-time readiness jitter before first upload attempt:
10. jitter is random integer seconds in `[0, INITIAL_UPLOAD_JITTER_MAX_SECONDS]` (default `0..30`).
11. if jitter > 0, set `next_retry_epoch=now+jitter`, emit `queued` reason `ready_jitter_<N>s`, and skip immediate upload this cycle.
12. if jitter == 0, continue directly to upload attempt.
13. For due `RETRY_WAIT`, no readiness jitter is added (normal retry backoff semantics apply).
14. If ready and not delayed, call `attempt_ship_artifact(...)`; if not ready, continue scanning older->newer candidates for oldest-ready behavior.

## Attempt Eligibility

`can_attempt_artifact_now()` returns `false` when:

- status is `SHIPPED`, `PRUNED`, `DEAD_LETTER`, or `IN_FLIGHT`
- status is `QUEUED` or `RETRY_WAIT` and `next_retry_epoch > now`

Otherwise it returns `true`.

## Profile Routing Order

- `field` -> try `local`, then `cloud`
- `cloud` -> try `cloud` only
- `local` -> try `local` only

## Upload Attempt Logic

Before routing:

1. Set artifact status `IN_FLIGHT`.
2. Set `updated_at_epoch` and `last_attempt_epoch` to current epoch.
3. Emit `in_flight`.

### Local target attempt

Hard checks:

- local target must be non-empty
- local target must NOT be inside spool dir (`local_target_inside_upload_dir`)
- local target directory must exist
- local target directory must be writable
- destination directory creation must succeed

Copy behavior:

1. Destination is `<local_target>/<relative_path>`.
2. If destination file exists and size matches source, compare sampled hashes.
3. If sampled hashes match, treat as success (`target_local_exists`).
4. Otherwise fail (`local_destination_conflict`).
5. Else copy source to temp file, then `os.replace(temp, final)` (atomic finalization).
6. Copy failures map to `local_copy_failed` or `local_move_failed`.

### Cloud target attempt

Hard checks:

- remote name must be non-empty
- `rclone` binary must exist

Remote path:

- `<remote_name>:<remote_path>/<relative_path>` when `remote_path` non-empty
- `<remote_name>:<relative_path>` when `remote_path` empty

Behavior:

1. Run `rclone copyto` with `--immutable --stats=0 --contimeout <N>s --timeout <N>s --retries 1 --low-level-retries 1`.
2. If copy succeeds -> `target_cloud`.
3. If copy times out -> `rclone_timeout`.
4. If copy fails and output text matches immutable/existing hints, validate remote size with `rclone lsjson --stat --files-only`.
5. Only treat immutable/existing as success when remote size exactly matches local size (`target_cloud_exists`).
6. If size validation fails, return explicit failure reasons such as `remote_destination_conflict` or `rclone_lsjson_*`.
7. If command output indicates provider throttling/rate-limit -> `rclone_rate_limited`.
8. Else -> `rclone_copy_failed`.

## Success Commit

On first successful target (local or cloud):

1. Update `artifact_targets` for that target to `SUCCESS`.
2. Insert success row in `attempt_log`.
3. Update artifact:
4. `status='SHIPPED'`
5. `retry_count=0`
6. `next_retry_epoch=0`
7. `last_error=''`
8. `updated_at_epoch=now`
9. `first_shipped_epoch=now` only if previously `0`
10. `shipped_target='local'` or `'cloud'`
11. `profile_at_ship=current_profile`
12. Emit `shipped` event.
13. Return immediately (no further target attempts).

## Failure Commit and Retry/Dead Letter

Per-target failure:

- Update `artifact_targets` to `FAILED`
- Insert failed row in `attempt_log`
- Emit `failed` event
- Keep last failure reason as `final_error`

After all targets fail:

- Call `schedule_retry_or_dead_letter(...)`.

`schedule_retry_or_dead_letter` logic:

1. Read current `status` and `retry_count`.
2. If status is terminal (`SHIPPED|PRUNED|DEAD_LETTER`), do nothing.
3. Compute `new_retry_count = retry_count + 1`.
4. If `new_retry_count >= MAX_RETRIES`:
5. Set `status='DEAD_LETTER'`, set `retry_count`, clear `next_retry_epoch`, set `last_error`, set `updated_at_epoch`.
6. Emit `dead_letter`.
7. Else:
8. Backoff = `RETRY_BASE_DELAY_SECONDS * 2^(attempt-1)` capped by `RETRY_MAX_DELAY_SECONDS`.
9. Compute retry jitter as random integer seconds in `[0, RETRY_JITTER_MAX_SECONDS]` (default `0..30`).
10. Set `status='RETRY_WAIT'`, set `retry_count`, set `next_retry_epoch=now+backoff+jitter`, set `last_error`, set `updated_at_epoch`.
11. If `final_error` is rate-limit (`rclone_rate_limited`), set global retry pause until `now + backoff + jitter`.
12. Emit `retry` with reason `retry_backoff_<N>s` (and `_jitter_<N>s` when jitter > 0).

Defaults:

- `MAX_RETRIES=5`
- `RETRY_BASE_DELAY_SECONDS=2`
- `RETRY_MAX_DELAY_SECONDS=600`
- `RETRY_JITTER_MAX_SECONDS=30`

## Exception Handling Around Attempts

- Any unhandled exception from `attempt_ship_artifact` during due processing is caught.
- Worker logs error and routes artifact through `schedule_retry_or_dead_letter` with reason:
- `unexpected_exception_<ExceptionType>`
- Any unhandled exception while processing a scanned file candidate is logged and that candidate is skipped for the current loop.

## Unclean Shutdown Recovery

- On startup, every row with `status='IN_FLIGHT'` is immediately passed through `schedule_retry_or_dead_letter` with reason `recovered_after_unclean_shutdown`.
- This consumes retry budget and can push directly to `DEAD_LETTER`.

## Retention Policy Logic

Disk usage:

- Uses `shutil.disk_usage(upload_dir)` and computes integer percent used.

`protect` mode:

1. If usage >= high watermark, emit `protect_stop` and run `UPLOAD_STOP_COMMAND` parsed via shell-style token splitting.
2. A cooldown stamp prevents repeated stop requests for `PROTECT_STOP_COOLDOWN_SECONDS` (default 300s).

`rolling` mode:

1. If usage >= high watermark, repeatedly prune oldest shipped artifacts until usage <= low watermark.
2. Oldest is by `first_shipped_epoch ASC`.
3. Prune safety:
4. If `full_path` empty -> mark artifact `PRUNED` with `last_error='empty_full_path'`.
5. If `full_path` outside spool dir -> mark artifact `DEAD_LETTER` with `last_error='unsafe_prune_path'`.
6. Else remove file if present, set status `PRUNED`, set prune timestamps, emit `pruned`.

## Events

For status transitions, worker prints:

- `UPLOAD_EVENT status=<status> ts=<utc_iso> file=<shlex_quoted> destination=<shlex_quoted> size_bytes=<value>`

Worker also attempts MQTT publish in this order:

1. `fleet-publish` binary variants
2. `mqtt_report.py --topic --json`
3. Python `mqtt_client.FleetMQTT` methods (`publish_json`, `publish`, `send`)

If all publish methods fail, one warning is logged once.

## SQLite Tables

`artifacts` tracks lifecycle/state:

- identity fields: `file_key`, `relative_path`, `full_path`, `inode`, `size_bytes`, `mtime_epoch`
- state fields: `status`, `retry_count`, `next_retry_epoch`, `last_error`
- timestamps: `discovered_at_epoch`, `updated_at_epoch`, `last_seen_epoch`, `last_attempt_epoch`, `first_shipped_epoch`, `pruned_at_epoch`
- shipment info: `shipped_target`, `profile_at_ship`

`artifact_targets` tracks per-target success/fail attempts.

`attempt_log` stores per-attempt action history.

`attempt_log` pruning:

- Every `ATTEMPT_LOG_PRUNE_INTERVAL_SECONDS` (default `300`, minimum `30`), worker checks row count.
- If `row_count > ATTEMPT_LOG_MAX_ROWS` (default `100000`), it deletes the oldest `row_count - cap` rows by `id ASC`.
- `ATTEMPT_LOG_MAX_ROWS <= 0` disables pruning.
