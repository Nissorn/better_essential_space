# Better Essential Space (macOS)

A native macOS client that reads a Nothing account's Essential Space content: voice Records with their Transcripts. Read-only. See the repo root `spec.md`-adjacent docs (`notes/02`, `notes/03`) for the reverse-engineered API it stands on.

## State

Working (v2): native email + password + OTP login against Nothing's Authflow (`account.nothing.tech`), automatic token refresh, and Records (title, main topics, summary, date, duration, Transcript inline) + account preferences. v2 redesigned the whole UI — scheme-dynamic light/dark tokens with a System/Light/Dark picker in Settings, gradient canvas and accent-gradient buttons, card-based detail, bundled Doto/Geist/Geist Mono (SIL OFL). The M1 token-file import remains as a fallback on the login screen. Audio playback is deferred (Firebase Storage rejects non-genuine clients for now — notes/03).

## Build & run

The app target needs the full Xcode toolchain (SwiftUI's `@State` macro plugin ships with Xcode, not Command Line Tools):

```zsh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build                 # or: open the package in Xcode and Run
swift test                  # all tests, no network (URLProtocol mocks)
scripts/build-app.sh        # -> dist/BetterEssentialSpace.app (ad-hoc signed)
```

With Command Line Tools alone only the logic library builds: `swift build --target BetterEssentialSpaceCore`.

## Runtime key files (never in the repo or binary)

The app reads two plain-text key files at launch-time use:

- `~/.better-essential-space/legacy-api-key` — the records-host key for the `auth` header (`md5(key + timestamp)`; from `ConfigUtil.getApiKey`, notes/03).
- `~/.better-essential-space/account-signing-key` — HMAC key for `x-app-signature` on every account request, login included (notes/02 §"Request signing").

Fetching Records fails with a clear error if the first file is missing; login and refresh need the second.

## Signing in

Run the app → email + password → enter the OTP Nothing emails → done. The app reports its own A059 device profile and per-install EC P-256 keypair (Keychain) exactly like the phone client (notes/02 §"Login protocol"). The token-file import (M1) stays available under "Import a token file instead (advanced)". Tokens live in the Keychain (service `com.nissorn.betteressentialspace`); "Sign out" in Settings removes them.

## Layout

- `Sources/BetterEssentialSpaceCore/` — models, `ESClient` (both hosts), `AccountSession` (Keychain + refresh), `AuthflowClient` (login), `AuthSigning` (all three header schemes), `RuntimeSecrets`, `TokenFile`
- `Sources/BetterEssentialSpace/` — SwiftUI app (`AppModel`, Records list/detail, Settings, Login screen)
- `Tests/` — decoding, signing, JWT, refresh-flow, Keychain round-trip (all mocked; the card fixture is redacted, built from the shape in `secrets/fixtures/card_list_sample.json`)
