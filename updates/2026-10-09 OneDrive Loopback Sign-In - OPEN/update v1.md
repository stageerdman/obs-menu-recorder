# OneDrive sign-in: device-code → loopback auth-code + PKCE

## Goal
Replace the OneDrive device-code sign-in (user has to copy a code into a separate page, and a
modal sheet blocks the rest of RecBar until it resolves — which trapped the user mid-sign-in)
with the cleaner flow the Pensieve project uses: click → the real browser opens to the
Microsoft consent screen → after approving, a one-shot loopback HTTP server catches the
redirect automatically → tokens are exchanged with PKCE. No code to type.

## Design (mirrors Pensieve's `connect.ts`/`oauth.ts`/`sync.rs`)
Authorization-code flow with **PKCE**, **public client** (no client secret — same as before),
`consumers` tenant, loopback redirect on an OS-assigned ephemeral port (RFC 8252):
1. `OneDriveAuth.signInInteractive()` makes a PKCE verifier/challenge + random `state`.
2. `LoopbackOAuthServer` binds `127.0.0.1:<ephemeral>` and returns the port.
3. Build `…/authorize?...&redirect_uri=http://localhost:<port>/callback&code_challenge=…&prompt=select_account`
   and open it with `NSWorkspace.shared.open`.
4. The server catches `?code=…&state=…` (or `?error=…`), serves a "you can close this tab" page.
5. Validate `state`, POST the code + `code_verifier` to the token endpoint → store refresh token.

`validAccessToken()` / refresh-token logic / Keychain storage are **unchanged** — only the
*initial* interactive sign-in changed. The transient-vs-definitive refresh-failure handling
(the 2026-09-27 fix) is preserved.

## Files
- **New** `Sources/RecBar/LoopbackOAuthServer.swift` — one-shot loopback catcher via
  `Network.framework` (`NWListener`, loopback-only via `requiredLocalEndpoint`). Binds an
  ephemeral port, parses the redirect's first request line, answers a close-me page, resolves a
  continuation; has a timeout and an external `cancel()`.
- `Sources/RecBar/OneDriveAuth.swift` — dropped `DeviceCodeResponse`/`requestDeviceCode`/
  `pollForToken`; added `signInInteractive`, PKCE (`CryptoKit` SHA256 + `SecRandomCopyBytes`),
  the authorize-URL builder, the code exchange, and `cancelInteractiveSignIn`.
- `Sources/RecBar/LibraryViewModel.swift` — `signInPrompt: DeviceCodeResponse?` →
  `isSigningIn: Bool`; `signIn()` now calls `signInInteractive`; added `cancelSignIn()` +
  `signInTask` tracking; user-cancel errors are swallowed, not surfaced.
- `Sources/RecBar/Views/LibraryView.swift` — the code sheet → a lightweight "finishing in your
  browser" sheet with a Cancel button.

## Azure / config (settled 2026-10-09)
**RecBar and Pensieve are different Azure apps** (initial "same clientId" claim was a misread):
RecBar = `bae96960-…`, Pensieve = `51c918c5-…`. A redirect URI must be registered on RecBar's
app (`bae96960`). RecBar's app is a **public client** — it worked with device-code (public
flow) + no secret, so PKCE-no-secret is fine. Therefore:
- Microsoft matches `redirect_uri` by exact string → the loopback server binds the exact port +
  path from `config.oneDrive.redirectUri`.
- User confirmed `http://localhost:3000/api/auth/callback` is registered on RecBar's app, then
  asked to switch to `http://localhost:8711/callback` → done. **Caveat**: 8711 only works if it
  too is registered on `bae96960`, else `AADSTS50011` (redirect mismatch) — fall back to 3000.
- `config.oneDrive.clientSecret` (new, optional) stays **empty** — safety net only, sent if
  non-empty, for a "Web"-platform registration (not our case; would otherwise be `AADSTS7000218`).

## Roadmap / status
- [x] Loopback server
- [x] PKCE + auth-code exchange in `OneDriveAuth`
- [x] VM + View rewired, build green (`./build.sh`)
- [x] Fixed-port binding + path match to the registered `:3000/api/auth/callback` URI
- [x] Optional `clientSecret` safety net wired through exchange + refresh (stays empty)
- [x] Confirmed public client (no secret) from Pensieve's live config — no config edit needed
- [ ] **End-to-end walkthrough with the user** — click Sign In, browser opens, approve, sheet
      closes on its own, quota/account populate; then an actual upload still works. No GUI
      automation here, so this must be confirmed live.
- [ ] Confirm Cancel tears the flow down cleanly (sheet closes, no stuck listener).
