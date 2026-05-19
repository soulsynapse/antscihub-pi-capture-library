# UPLOAD_WORKER_REWRITE_PLAN.md (Final Draft)

## Summary
Rewrite uploader to a **store-and-forward (spool-and-ship)** model: no source-file move/delete in normal upload flow, durable queue state, and explicit retention policies (`protect` or `rolling`).

## Core Logic
1. Treat `<desktop>/5-UPLOAD` as immutable spool input.
2. Replace `.MOVED`/`processed.txt` semantics with durable queue state (`queue.db`) tracking artifact lifecycle and retry metadata.
3. Upload by **copy** only:
   - Cloud: `rclone copyto`
   - Attached drive: local copy (atomic temp -> final rename)
4. Keep existing maturity/stability safeguards (image fast path, log/state slow path).
5. Destination routing via profile:
   - `field`: local target preferred, cloud fallback
   - `cloud`: cloud only
   - `local`: local target only
6. Retention modes:
   - `protect`: at threshold, gracefully stop active recording (`antcam stop` behavior), keep uploader running.
   - `rolling`: at 80% spool usage, delete oldest eligible shipped files until 70%.
7. Deletion eligibility in `rolling`: file is eligible after profile-defined successful shipment.
8. Preserve/extend upload events (stdout + MQTT), including spool lifecycle statuses (`queued`, `in_flight`, `shipped`, `dead_letter`, `pruned`).

## Decisions / Alternatives
- Routing UX: preset profiles (`field`, `cloud`, `local`), not explicit chain commands.
- Retention UX: `protect` and `rolling`, not a single forever-keep mode.
- Rolling hysteresis: `80% -> 70%`.
- Protect action: stop active recording at threshold.

## Proposed `antcam upload` Surface (v1)
- `antcam upload set profile <field|cloud|local>`
- `antcam upload set retention <protect|rolling>`
- `antcam upload report`
- `antcam upload report queue`
- `antcam upload report targets`
- `antcam upload pause`
- `antcam upload resume`
- `antcam upload reload`
- `antcam upload prune --older-than <duration> [--dry-run]`

Useful params:
- Local target path (attached drive mount)
- rclone remote + remote path
- Optional watermark overrides (defaults remain 80/70)

## Benefits
- Eliminates destructive move/delete race risks in hot path.
- Improves offline resilience and restart recovery.
- Better observability of queue depth, retries, dead letters, shipped/pruned states.
- Cleaner edge operation with intermittent USB/cloud availability.
- Predictable disk safety via explicit retention policy.

## Industry Practice References
- AWS IoT Greengrass Stream Manager: edge local store + export  
  https://docs.aws.amazon.com/greengrass/v2/developerguide/manage-data-streams.html
- Fluent Bit filesystem buffering  
  https://docs.fluentbit.io/manual/3.0/administration/buffering-and-storage
- Logstash persistent queues  
  https://www.elastic.co/docs/reference/logstash/persistent-queues
- Apache Kafka durable append-only log  
  https://kafka.apache.org/25/implementation/log/

## Test Plan
- Unit: lifecycle transitions, retry/backoff, profile routing, rolling watermark logic.
- Integration: network outage/recovery, attached drive mount/unmount, restart during in-flight uploads, protect threshold stop behavior, rolling prune to 70%.
- Acceptance: no `.MOVED` dependency, no source deletion during normal shipment, cleanup only by explicit retention policy.

## Assumptions
- Existing capture/recording flow remains unchanged except threshold-triggered stop in `protect`.
- Single worker instance model in v1.
- MQTT event transport remains, with extended spool lifecycle report names.
