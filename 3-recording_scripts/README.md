# Recording Trigger

Recording starts from the CLI command:

```bash
antcam start
```

Current behavior:

1. Resolve the active Desktop directory (including `sudo` invocation support).
2. Ensure `<desktop>/4-CAPTURE` exists (create it if missing).
3. Ensure `<desktop>/4-CAPTURE/record.sh` exists (create empty file if missing).
4. Ensure `<desktop>/4-CAPTURE/experiment.txt` exists (create empty file if missing).
5. Run `record.sh` from inside `<desktop>/4-CAPTURE`.

Future recording modes can be added to this module while preserving the same `antcam start` operator flow.
