# OneDrive account strip + upload error recovery

## Goal (user request, 2026-11-13)
"OneDrive upload errors and I don't see ability to connect / reconnect, I don't see my account
and how much space is left there — I'm used to seeing my OneDrive account on top."

## Findings (library.json, 2026-11-13)
- Today's failure: `401` on the first chunk PUT to the pre-authenticated upload URL (an upload
  2026-11-13 13:20 the same day succeeded, so the sign-in was fine). The real reason was
  lost: chunk failures threw away Graph's response body.
- The library holds items from **two OneDrive drives** (`F92B…` ×96, `4995…` ×24), from an
  account switch. A failed entry from the old drive retried the old item id forever.
- ~31 GB uploaded to the current drive; quota was invisible.

## Phases
1. `OneDriveClient`: `driveInfo()` (`GET /me/drive` → owner name + quota, no new scope);
   keep + parse Graph error bodies; full-drive message; a 401/403/404 from the upload URL
   starts a fresh session (max 2 times) — **done**.
2. `LibraryViewModel`: `accountStatus` (notConfigured / signedOut(expired) / signingIn /
   loading / connected / unreachable), connect / cancel / sign out / switch account; reused
   item 403/404 → new placeholder + link — **done**.
3. `OneDriveAccountStrip` under the Library header (UX-agent spec) + Cancel on the sign-in
   sheet — **done**, built + installed.
4. Walkthrough with the user — **pending**: strip shows name + free space; retry the
   Lukas Vrabel row; if it fails again, the tooltip now shows OneDrive's actual reason.
