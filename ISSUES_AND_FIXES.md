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

## Validation Added

- `2-test_scripts/run_static_checks.sh` for shell syntax and key config sanity checks
