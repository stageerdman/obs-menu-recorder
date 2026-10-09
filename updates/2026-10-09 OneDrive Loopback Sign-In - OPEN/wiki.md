# Durable decisions & lessons — OneDrive loopback sign-in

- **Why loopback over device-code**: device-code made the user copy a code into a separate
  page AND its modal sheet blocked the rest of RecBar's UI until it resolved — the user got
  stuck unable to use transport controls mid-sign-in. Loopback auth-code is one click + the
  normal browser consent, and the new sheet is non-blocking (informational + Cancel).

- **Public client + PKCE, no secret** — kept the no-client-secret stance (CLAUDE.md). PKCE
  (S256) replaces the secret as proof the token request came from the app that started sign-in.
  Pensieve's code sends a secret *if configured* (it registered a "Web" platform app); RecBar
  deliberately omits it and uses the "Mobile and desktop applications" platform instead.

- **Ephemeral loopback port (RFC 8252)** — bind `127.0.0.1:0`, read the assigned port, build
  the redirect URI from it. Azure only needs `http://localhost` registered once; Microsoft
  ignores the port when matching loopback redirects. Avoids hardcoding/colliding on a fixed port.

- **`NWListener` bound loopback-only** via `params.requiredLocalEndpoint =
  .hostPort(host: "127.0.0.1", port: .any)` — nothing on the LAN can hit the listener. Raw HTTP
  is tiny (parse the first request line, write a fixed 200 + close page). No entitlement needed
  (RecBar isn't sandboxed).

- **Cancel path**: the awaited redirect is a continuation that Task-cancellation alone won't
  unblock, so `OneDriveAuth` holds the active `LoopbackOAuthServer` and `cancelInteractiveSignIn()`
  calls its `cancel()`, which resolves the continuation with `.cancelled` → `AuthError.cancelled`,
  swallowed by the VM (not shown as an error).

- **Not yet verified live** — no GUI automation for native macOS here; the Graph token exchange
  and the browser round-trip can only be confirmed by the user. Build is green.
