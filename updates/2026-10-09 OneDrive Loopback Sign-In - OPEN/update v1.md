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

## Azure / config (updated after the user confirmed their registration)
The user already has `http://localhost:3000/api/auth/callback` registered (the **Pensieve**
project's Web-platform redirect). Microsoft matches `redirect_uri` by exact string, so:
- The loopback server binds the **exact** port (3000) + path (`/api/auth/callback`) from
  `config.oneDrive.redirectUri` — not a dynamic port. Default matches the registered URI, so no
  config edit is required.
- That URI is a **"Web" platform** registration → confidential → a secret-less token exchange
  fails with `AADSTS7000218`. So `config.oneDrive.clientSecret` (new, optional) is sent with the
  code exchange + refresh when set. The user must put the Pensieve app's client secret there.
  (If they instead register the URI under "Mobile and desktop applications", leave it empty.)

## Roadmap / status
- [x] Loopback server
- [x] PKCE + auth-code exchange in `OneDriveAuth`
- [x] VM + View rewired, build green (`./build.sh`)
- [x] Fixed-port binding + path match to the registered `:3000/api/auth/callback` URI
- [x] Optional `clientSecret` (for the Web-platform app) wired through exchange + refresh
- [ ] User: set `oneDrive.clientSecret` in config.json to the Pensieve app's secret
- [ ] **End-to-end walkthrough with the user** — click Sign In, browser opens, approve, sheet
      closes on its own, quota/account populate; then an actual upload still works. No GUI
      automation here, so this must be confirmed live.
- [ ] Confirm Cancel tears the flow down cleanly (sheet closes, no stuck listener).
