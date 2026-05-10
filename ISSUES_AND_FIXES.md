# Issues and Fixes

This file tracks key issues that were found and fixed in this repo.

## Fixed

1. `apply_camera_config.sh` had a broken `if` block (missing `fi`)
   - Result: script syntax could fail at boot
   - Fix: repaired conditional structure

2. Upload worker wrote state/log/lock into root-owned paths while running as non-root
   - Result: permission errors on startup/runtime
   - Fix: moved upload state/log/lock defaults to user-writable directories

3. Upload retry backoff was calculated but not enforced
   - Result: retries happened at scan cadence instead of true backoff
   - Fix: added per-file retry schedule files and backoff-window checks

4. Upload dedup/retry keys were basename-only
   - Result: same-name files could be incorrectly skipped or blocked
   - Fix: track processed/retry state by file identity (basename + inode + size + mtime)

5. Installer assumed `User=pi`
   - Result: failure on systems without `pi` user
   - Fix: installer now resolves a non-root service user from `SUDO_USER` or UID 1000 fallback

6. Installer had no root check
   - Result: confusing failures when writing systemd units
   - Fix: explicit root check with actionable error message

7. Docs drifted from implementation
   - Result: incorrect guidance (paths, validation semantics, state behavior)
   - Fix: README and service docs updated to match current code

8. Upload source/destination path handling for nested files
   - Result: direct-child-only uploads could miss subfolder contents
   - Fix: recursive scan + per-file remote path preservation, with `.MOVED` metadata files

9. Desktop path assumptions
   - Result: hardcoding `~/Desktop` can fail across users/locales
   - Fix: infer Desktop path via XDG helpers/config, then watch `<desktop>/5-UPLOAD`

10. Local-vs-remote path coupling
   - Result: `5-UPLOAD` was used as both local source name and forced remote destination path
   - Fix: keep local watch path at `<desktop>/5-UPLOAD`, but allow empty `RCLONE_PATH` (remote root) and set that as default

11. Cross-machine remote filename conflicts
   - Result: same remote path from multiple Pis could overwrite each other
   - Fix: on conflict, upload worker renames new upload with machine suffix and keeps both files

12. No-camera startup behavior
   - Result: no camera attached could leave stale manual camera settings active
   - Fix: treat no-camera detection as a clean auto-profile fallback (`camera_auto_detect=1`) so future camera attachment can be discovered

13. Raspberry Pi Camera Module 3 NoIR explicit detection
   - Result: Module 3 NoIR support depended on generic IMX708 match and was not explicit
   - Fix: added explicit Module 3/NoIR detection keywords under IMX708 family handling

14. Legacy manual camera config lines override managed output
   - Result: old `camera_auto_detect`/`dtoverlay` lines could remain active and prevent correct detection/config updates
   - Fix: scrub known camera directives before writing the managed camera block

15. Owlcam detection when auto-detect reports no camera
   - Result: third-party Owlcam can fail `--list-cameras` under auto-detect mode and never switch to required manual overlay
   - Fix: added optional hardware fallback probe via `i2ctransfer` for OV64A40 chip ID, plus installer dependency check for `i2c-tools`

## Validation Added

- `2-test_scripts/run_static_checks.sh` for shell syntax and key config sanity checks
