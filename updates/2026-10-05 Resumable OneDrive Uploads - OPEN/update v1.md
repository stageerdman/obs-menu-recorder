# Resumable OneDrive uploads (2026-10-05)

## Goal

User report: "uploading fails quite often, can't we make it so that the progress is
always saved instead of it failing, and can be recovered even after I restart a computer?"
(cloud uploads).

Make OneDrive uploads durable: persist upload progress + the Graph resumable-upload-session
so an upload interrupted by a quit, crash, or full computer restart resumes from where it
left off instead of restarting from byte 0 (the previous behaviour, which made large files
on a slow/flaky upstream rarely finish).

## Status: IMPLEMENTED, builds clean, NOT yet verified end-to-end

Branch: `resumable-onedrive-uploads`. Cannot be self-certified — no GUI automation / no real
OneDrive account in this dev environment (see CLAUDE.md "Testing notes"). Needs a user
walkthrough (see Phase 3 below).

## Roadmap

### Phase 1 — Persist the resumable session + progress ✅ (done)
- `RecordingMetadata` gained `cloudUploadUrl: String?` (migration-safe `decodeIfPresent`).
  Holds the Graph upload-session URL for an in-flight upload; nil otherwise.
- `LibraryViewModel.updateProgress` now persists `cloudBytesSent` to disk each chunk (was
  in-memory only, on the old assumption that resume restarted from scratch so it'd be wasted
  IO — no longer true). reconcile's `liveUploading` guard still prevents the stale-disk stomp.
- `persistUploadUrl` writes the session URL the moment `OneDriveClient` mints one.

### Phase 2 — Resume instead of restart ✅ (done)
- `OneDriveClient.uploadFile` signature changed:
  `uploadFile(itemId:localPath:auth:resumeUploadUrl:onSession:onProgress:)`.
  - If `resumeUploadUrl` is live on the server (GET returns `nextExpectedRanges`), resume from
    that byte; else create a fresh session via new `createUploadSession(itemId:auth:)` helper
    and report it via `onSession` so the caller persists it.
  - A session that dies mid-upload (404/410 on a chunk PUT) is now recreated on the fly and
    the upload continues, instead of failing fast. Other 4xx-non-429 still fail fast; cancel
    still propagates.
  - Chunk retry budget raised 5 → 10 consecutive failures.
- `LibraryViewModel.runUpload` passes `resumeUploadUrl: item.cloudUploadUrl`, wires `onSession`
  → `persistUploadUrl`, clears `cloudUploadUrl` on successful finish. Jumps straight to
  `.uploading` (not `.creatingLink`) when resuming an entry that already has its link.
- `recoverInterruptedUploads` (old: demote `.uploading`→`.failed` on launch) replaced by
  `resumeInterruptedUploads`: on launch (after `reconcile()` so `items` is populated),
  auto-restarts any `.uploading`/`.creatingLink` entry whose local file still exists; only a
  missing local file now falls back to `.failed`. Guards `uploadTasks[id] == nil` so reopening
  the Library window mid-upload doesn't cancel/restart a live upload (StateObject persists
  across window close/reopen).
- `cancelUpload` / `deleteCloud` also clear `cloudUploadUrl`.

### Phase 3 — Verify end-to-end with the user ⬜ (OPEN — this is where we resume)
Walk through with real OneDrive + a large recording:
1. Start a large upload; quit RecBar (or restart the Mac) partway through.
2. Reopen the Library window → confirm it auto-resumes from roughly where it stopped
   (progress bar picks up, not back to 0), and completes.
3. Confirm the share link created before the interruption is unchanged after completion.
4. Confirm mid-upload network drops recover within a session (should already, now more retries).
5. Edge: let a session go stale long enough to expire (multi-day), confirm the fallback
   restarts from byte 0 cleanly rather than erroring.

## Open questions / caveats
- Graph upload-session URLs are valid a few days — a persisted one usually survives an
  overnight restart, but if expired the resume GET 404s and we recreate (restart from 0,
  same item id so the link stays valid). Acceptable fallback, but the exact validity window
  for OneDrive *consumer* wasn't confirmed against a real account.
- Cosmetic pre-existing issue (not touched): some entries have `sizeBytes` << `cloudBytesSent`
  in library.json, so the % bar denominator is wrong for those (noted in issues.txt).
- Possible nicety deferred: a visible "Resuming…" indicator in the row UI (asked user; no
  answer yet).
