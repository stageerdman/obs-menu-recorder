# Wiki — Resumable OneDrive uploads

Durable decisions / lessons for this feature.

## Why resume instead of the old restart-from-0

The original design (see the superseded comment on `OneDriveClient.uploadFile`) deliberately
did NOT resume across relaunches — the stated reason was "Graph's upload-session validity
window isn't something to bet on with confidence." In practice that meant every interruption
(quit, crash, restart, or exhausting the in-session retry budget) threw away all progress, and
the manual retry started over. On a slow/flaky residential upstream, large recordings
(hundreds of MB to multi-GB) rarely finished. This is the direct cause of the user's "fails
quite often" report.

The validity-window worry is handled by making expiry a *fallback*, not a blocker: try the
persisted session; if the server says it's gone (GET → non-200, or a chunk PUT → 404/410),
recreate the session (same item id, so the share link is preserved) and restart the bytes.
Worst case = re-upload; never a permanently stuck upload.

## Source of truth for the resume offset

The **server's** `nextExpectedRanges` (queried via GET on the upload URL), not our persisted
`cloudBytesSent`. The persisted byte count is only for UI continuity at launch (show roughly
where we were before the GET lands). This is why per-chunk disk persistence of `cloudBytesSent`
is correctness-irrelevant but cheap and nice-to-have, and why a partially-received final chunk
before a drop is handled correctly (we trust the server, not our last-sent offset).

## Lifecycle gotcha: Library window StateObject persists across close/reopen

`LibraryView` owns the VM as `@StateObject`; `start()` runs on every `onAppear`. An upload's
`Task` lives in `uploadTasks` and keeps running while the window is closed. So
`resumeInterruptedUploads` must guard `uploadTasks[id] == nil` — otherwise reopening the window
mid-upload would cancel and restart a perfectly healthy live upload. Only genuinely orphaned
`.uploading` entries (from a *previous process*, where `uploadTasks` is empty) get picked up.

## Ordering

`start()` must `reconcile()` BEFORE `resumeInterruptedUploads()` — `runUpload` reads the entry
out of `self.items`, which `reconcile()` populates. (Old `recoverInterruptedUploads` read from
`LibraryStore.load()` directly and ran first; the new one reads `items`.)
