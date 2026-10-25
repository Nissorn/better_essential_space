# 01 — Emulator sync capture: the real record read path + Record schema

Status: ready-for-human
Type: research
Blocked by: (none)

## Question

The account's ~13 voice Records are in Nothing's cloud (phone shows Cloud storage "In sync", 192 MB of 2.15 GB, Backup ON, app v2.2.0), but `GET https://prod.essentialsearch.essential-nt.com/memories/list` with the account's OAuth Access Token returns `{"memories":[]}`, and `https://essential-space.nothingtech.link/essentialSpace/*` returns 401 with the same token. Where does the Essential Space app actually read synced Records from, with which token, and what does a Record look like on the wire?

## Why it matters

The macOS app's data layer (issue 03) cannot be written until this is known. Issue 04 may also depend on it if reading requires an SSO-exchanged token.

## Approach (agreed in interview 2026-10-25)

Boot the `essential36` emulator (account already logged in, device spoofed as a real A059), run mitmdump with the spoof/sign addon, enable the Backup toggle in the Essential Space app, let it sync the Records down, capture and analyze all traffic. Read-only toward cloud data: enabling Backup (a download) is the only allowed account mutation.

## Acceptance criteria

- [x] Full traffic capture saved under `captures/` (gitignored) — `captures/es-sync.flow`
- [x] Sync/read endpoints identified (host, method, path, headers) with the exact token in `Authorization` decoded (aud/did/scopes) — account JWT or something else? — **it IS the account JWT**; the earlier 401 was the missing `auth` header (`md5(apiKey+timestamp)`), not the token
- [x] If a different token is used: minting flow documented — N/A (same token); the apiKey dumped via frida → `secrets/es_legacy_apikey.txt`
- [x] Record JSON schema documented (field names + nesting, values redacted) — notes/03; full sample in `secrets/fixtures/card_list_sample.json`
- [x] Audio file URL mechanism documented (pattern, signed?, which storage) — Firebase Storage `gs://essential-space-gcs-asia-south1`; token chain works (getFirebaseToken → signInWithCustomToken) but object GET returns 403 for non-genuine clients; **playback deferred per spec**; follow-up hypotheses listed in notes/03
- [x] Findings written to `notes/03-es-sync-capture.md`, including a concrete read recipe — **verified reproducible with curl from the Mac (200)**
- [x] If the Backup toggle refuses to enable: blocker documented — toggle stayed grayed OFF on the emulator, yet the read path (card/collection/category list) fired anyway and works; backup not required for reading

## Comments

- 2026-10-25: Started. Plan: boot `essential36` with mitmdump (spoof_and_sign addon) on :8080, verify ES login state, attach Frida (tools/frida-dump-es-account.js), flip Settings → Cloud storage → Backup, watch the sync pull ~192 MB of Records down, then decode every Authorization JWT in the capture and document endpoints/Record schema/audio URLs.
- 2026-10-25 (agent, died at 169s from infra limit): emulator booted, mitmdump started, frida hooks (hook_es6.js) attached.
- 2026-10-25 (agent retry, died at 325s): killed the stale mitmdump, started the fresh one writing `captures/es-sync.flow`, frida spawn-mode hook attached; the app began listing from the legacy host (12 list calls, all 200).
- 2026-10-25 (orchestrator, direct): subagents kept dying to concurrency limits, so the remainder ran in the main session. Decoded the legacy token (= account JWT), found the missing `auth` header in `NothingApiManager.b`, dumped `ConfigUtil.getApiKey` via frida, verified `md5(apiKey+timestamp)` against all 12 captured pairs (12/12), then proved the whole recipe standalone with curl (card list 200 with 12 cards, transcripts inline; category list 200). Audio: Firebase Storage buckets identified + token chain verified but object GET 403s (also broken on the emulator app itself); deferred per spec Q13. Deliverables: notes/03, secrets/es_legacy_apikey.txt, secrets/es_config_dump.json, secrets/fixtures/card_list_sample.json. Status: ready-for-human.
