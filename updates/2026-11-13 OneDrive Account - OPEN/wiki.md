# Wiki — OneDrive account

- `GET /me/drive?$select=id,owner,quota` works under `Files.ReadWrite`: gives
  `owner.user.displayName` and `quota.{used,total,state}` (state: normal/nearing/critical/
  exceeded). An email address would need `User.Read` → a forced re-consent for everyone; not
  worth it just for display.
- Chunk PUTs carry no Authorization header, so a 401/403/404 there means the *upload session*
  is dead, not the token → make a new session against the same item (keeps the share link).
- Items are drive-scoped: after switching Microsoft accounts, old item ids 403/404. Fall back to a
  fresh placeholder (new link) instead of failing forever.
- "Offline" and "sign-in expired" are different states on purpose: only `invalid_grant` /
  `interaction_required` mean re-sign-in (see cad77c1).
