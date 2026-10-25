# 02 — Scaffold the Swift package + M1 token bootstrap

Status: ready-for-agent
Type: task
Blocked by: (none)

## Summary

Create the macOS app in `macos/` as a Swift package that builds and tests green with the Command Line Tools toolchain (Swift 6.4 — Xcode is still installing, so do not depend on it), including M1 end-to-end: token file import → Keychain → authenticated `preferences` fetch → refresh on expiry.

## Scope (from spec.md + issue 01 findings — follow both)

- `Package.swift`: name `BetterEssentialSpace`, platform macOS 26, executable + test targets, zero third-party dependencies (SwiftUI, Foundation, Security, CryptoKit only; CommonCrypto via CryptoKit's Insecure.MD5 is fine).
- SwiftUI app skeleton: `NavigationSplitView` (Record list sidebar with empty state + detail placeholder), settings screen, first-run BootstrapView with a file-open dialog for the token JSON.
- Networking — TWO hosts, one `ESClient`:
  - Records (legacy): `POST https://essential-space.nothingtech.link/essentialSpace/storage/card/v1/list` body `{"page_no":N,"page_size":N,"sinceTime":0}`; headers `Authorization: Bearer <access_token>`, `timestamp` (epoch ms), `auth` = hex(MD5(legacyApiKey + timestamp)). Also GET `storage/category/v1/list`, POST `storage/collection/v1/list` (same header scheme). Response model per notes/03: envelope `{code,msg,data:{page_no,page_size,hasNextPage,page_data:[Card]}}`; `Card` = `{cardId, client_request_response (JSON string: {cards:{card_id,title,summary,type,create_time,update_time,resource_mask}, card_resources:[{card_resource_id,raw_type,data,mime_type,is_primary,metadata(JSON string),remote_gcsKey,remote_region,...}]}), files, clientCreateTime, clientUpdateTime, clientVersion}`. Fixture with real shape: `secrets/fixtures/card_list_sample.json` (copy values into a REDACTED test fixture — never commit the real one).
  - Preferences (new host): `GET https://prod.essentialsearch.essential-nt.com/preferences` with `Authorization` + `X-Nothing-Account-ID` (uuid claim from the access_token JWT); response `{"userId","useMemory","hasAgreedToTerms","updatedAt"}`. `GET memories/list` optional, decode defensively.
- `AccountSession`: Keychain storage, JWT decode (uuid/exp), auto-refresh on 401 via `oauth2/token` `grant_type=refresh_token&client_id=account-app-native`, `sessionExpired` surfaced to the UI as a re-import prompt.
- Runtime secret files (NEVER embedded, NEVER committed; loader + tests with dummy keys):
  - `~/.better-essential-space/legacy-api-key` — the legacy host apiKey (real value: `secrets/es_legacy_apikey.txt`)
  - `~/.better-essential-space/account-signing-key` — the account HMAC key for `x-app-signature` (real value embedded in `secrets/spoof_and_sign.py`), used on refresh/login requests per notes/02 §Request signing
- `scripts/build-app.sh`: release build → `dist/BetterEssentialSpace.app` (Info.plist, ad-hoc codesign).
- Tests with `URLProtocol` mocks only — no live network calls, no use of real tokens or real keys.
- `macos/README.md`: build/test/bundle instructions, secret-file layout, current state.

## Acceptance criteria

- [ ] `swift build` and `swift test` pass with the CLT toolchain
- [ ] Token import → Keychain round-trip covered by tests; refresh flow tested with mocked 200 and 400 responses
- [ ] Card list decoding tested against a redacted fixture matching the real schema (from notes/03)
- [ ] The `auth` header signer (MD5 of legacyApiKey+timestamp) unit-tested with a dummy key and independently computed expected values
- [ ] No secrets anywhere in `macos/`
- [ ] `scripts/build-app.sh` produces a structurally valid `.app`
- [ ] Naming follows GLOSSARY.md terms

## Comments

- 2026-10-25 — started (agent, issue 02). Plan: SPM package in `macos/` (Core library + SwiftUI executable + tests), URLProtocol-mocked tests only, redacted card-list fixture derived from `secrets/fixtures/card_list_sample.json` structure. CLT toolchain Swift 6.4 confirmed; both runtime key files present at `~/.better-essential-space/` (values not read).
- 2026-10-25 — agent died at 11 min (model concurrency limit; 4th subagent death this session) after writing 23 files. Orchestrator finished inline: made Core declarations `public`, added missing imports (3 UI files), fixed `ESError.errorDescription` missing returns, bumped swift-tools-version to 6.2 (`.macOS(.v26)` needs it), corrected `CollectionSummary` to the captured wire shape (`collectionId`/`collectionName`), wrote `README.md` + `scripts/build-app.sh`. Secrets scan of `macos/`: clean.
- Toolchain finding: CLT cannot build the app target (SwiftUI `@State` macro plugin ships only with Xcode) nor run tests (no XCTest in CLT). `swift build --target BetterEssentialSpaceCore` passes with CLT. Xcode is installed but its license is not yet accepted — full `swift build` + `swift test` + bundle verification pending that. Records list/detail UI (issue 03 territory) already wired by the scaffold.
- 2026-10-25 — VERIFIED after Xcode license acceptance: `swift build` ✓, `swift test` 42/42 ✓ (after fixing 3 test bugs the agent left: fixture lookup needed `subdirectory: "Fixtures"`, a truncated base64 test vector, wrong path suffix assertions), `scripts/build-app.sh` → valid codesigned `.app` ✓. UI compile fixes along the way: `private(set)` lastError needed a dismiss method, macOS 26 SDK quirks (Optional.map vs View.map in ViewBuilder; `.dateTime.date().time()` chains misresolve — used classic forms). Pagination loop + newest-first sort added to AppModel. Status: ready-for-human.
