# macOS app spec — Better Essential Space (v1)

Confirmed 2026-10-25 (grill-with-docs interview; all decisions user-approved). Status 2026-10-25: **v1 delivered** — M1 + M2 login live-verified (user login + token refresh), Records UI complete; audio playback deferred.

## Goal

A native macOS client that logs in with a Nothing Account and displays the user's Essential Space content, read-only.

## Confirmed decisions

- **Scope v1 (read-only):** list voice Records with their Transcripts; a detail view with audio playback (include playback if media URLs turn out practical, otherwise defer — not a scope change); a settings screen showing account preferences. No create/update/delete, no `process_memory`.
- **Single account, online-only, English UI.**
- **Login, two milestones:**
  - **M1 — token bootstrap (delivered, kept as fallback):** import the token set from a file (`secrets/es_token.json`, keys `access_token`/`id_token`/`refresh_token`/`device_secret`) via a file-open dialog; store in Keychain; auto-refresh via the `refresh_token` grant when the Access Token expires or a request 401s.
  - **M2 — in-app Authflow login (delivered, user-verified 2026-10-25):** email + password → OTP, all native HTTP (no browser). The Device Report claims the A059 Android profile (the profile proven to pass the security gate); a fresh EC P-256 keypair per install, stored in Keychain. `x-device-signature` = base64url-with-padding P1363 ECDSA over `"<epoch ms>." + raw body` (cracked + capture-verified, notes/02).
- **App form:** regular window app — `NavigationSplitView` (list sidebar + detail).
- **Identity:** display name "Better Essential Space", bundle id `com.nissorn.betteressentialspace`.
- **Stack:** SwiftUI + Observation, Swift 6, `URLSession` + `Codable`, zero third-party dependencies, deployment target macOS 26. Code lives in `macos/` as a Swift package (SPM executable + bundle script; also opens in Xcode).
- **Secrets policy:** tokens live in the Keychain; everything in `secrets/` (personal tokens, captures) stays out of the repo. The two shared APK-derived app keys are published in-source (`EmbeddedKeys.swift`, issue 06 decision 2026-10-25), with runtime-file overrides for rotations.
- **Distribution:** open-source on GitHub — users build from source (no notarization involved) and log in with their own accounts. Name kept as "Better Essential Space" (owner decision, issue 06).

## Open items

- ~~Where the account's synced Records actually live, the Record wire schema, and the audio-URL mechanism~~ → **resolved 2026-10-25**: Records are Cards on the legacy host behind an `auth = md5(apiKey+timestamp)` header; transcripts inline; read recipe verified (notes/03). Audio playback **deferred** (Firebase Storage 403 for non-genuine clients — allowed by the Q13 decision).
- ~~Whether reading Records needs an SSO-exchanged token~~ → **no**: the same account Access Token works on both hosts.

## Why native-HTTP login (no browser) — rationale recorded in lieu of an ADR

The captured login is 100% native HTTP (Dart client): device/report → authflow/login → state/input (OTP) → authorize → token exchange. The authorize step requires an `x-idp-session` header a real browser cannot send, and no web login UI was ever observed — `ASWebAuthenticationSession` is not viable. Full evidence: notes/02-essential-space-api.md §"Login protocol".
