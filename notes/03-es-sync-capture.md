# ES sync capture — where records really live (2026-10-25, session 3)

Resolves the open question from notes/02 ("where do the account's actual records live?"). Everything below was observed live on the `essential36` emulator (ES v2.2.0, account logged in, device spoofed as A059) and **verified reproducible with curl from the Mac, outside the proxy**.

## TL;DR

Records are **Cards on the legacy host** (`essential-space.nothingtech.link`), NOT the `memories/*` API. The account JWT works there — but only with a third header, `auth: md5(apiKey + timestamp)`, which jadx analysis had missed (it lives in a second OkHttp interceptor, `NothingApiManager.b`, not in `ag.java`). Transcripts are **inline** in the card list response. Audio files sit in Firebase Storage (`gs://essential-space-gcs-asia-south1`) behind a token chain that currently 403s for non-genuine clients → audio playback deferred (spec allows).

## The read recipe (verified live, HTTP 200, from the Mac)

```bash
TOK=<account access_token JWT>          # secrets/es_token.json access_token
KEY=$(cat secrets/es_legacy_apikey.txt) # dumped via frida, see below
TS=$(python3 -c "import time;print(int(time.time()*1000))")
AUTH=$(python3 -c "import hashlib;print(hashlib.md5('$KEY$TS'.encode()).hexdigest())")

# Cards (the records):
curl -s "https://essential-space.nothingtech.link/essentialSpace/storage/card/v1/list" \
  -H "Authorization: Bearer $TOK" -H "timestamp: $TS" -H "auth: $AUTH" \
  -H "Content-Type: application/json; charset=UTF-8" \
  -d '{"page_no":1,"page_size":20,"sinceTime":0}'
# → 200 {"code":"00000","msg":"success","data":{"page_no":1,...,"hasNextPage":...,"page_data":[...]}}

# Categories: GET .../storage/category/v1/list  (same headers) → data:[{"categoryId":"recording","count":12}]
# Collections: POST .../storage/collection/v1/list (same headers), body {"collectionIds":[...]} or {"sinceTime":0}
```

Header rules on the legacy host (from 12 captured requests + jadx):

- `Authorization: Bearer <account access_token>` — the SAME token the new host uses (byte-identical to the one in `secrets/es_token.json`; claims `aud=account-app-native`).
- `timestamp` — epoch ms.
- `auth` — `md5(apiKey + timestamp)` hex. Algorithm: `NothingApiManager.b` interceptor (`notes/jadx/.../remote/NothingApiManager.java:1100-1109`): `ic1.e(ConfigUtil.getApiKey(context) + System.currentTimeMillis())` where `ic1.e` = hex(MD5).
- **No** `X-Nothing-Account-ID` on this host (that header belongs to the `prod.essentialsearch` host only).
- User-Agent the app sends: `okhttp/5.0.0-alpha.14`. Server did not check it in our tests (curl default UA was accepted).

The apiKey came from `ConfigUtil.getApiKey` (native, `libconfig-lib.so`) — dumped by calling it via frida on the running ES process (script pattern: `tools/frida-dump-security-config.js`). Value lives in `secrets/es_legacy_apikey.txt` (gitignored). The formula was verified against all 12 captured (auth, timestamp) pairs: **12/12 exact match**.

Earlier 401s on this host ("Auth failed. Without auth" 200001) were caused by the missing `auth` header, not a wrong token.

## Card wire schema (from a live 200 response)

Envelope (`data` of the list response):

- `page_no`, `page_size`, `hasNextPage`, `page_data: [Card]`
- `Card`: `cardId` (uuid), `client_request_response` (**JSON-encoded string**, see below), `files`, `clientCreateTime`, `clientUpdateTime`, `clientVersion` (ms epochs)

Inside `client_request_response`:

- `cards`: `{card_id, title, summary, type: "RECORDING", create_time, update_time, resource_mask}` — `title`/`summary` are AI-generated (e.g. "Optimising AI Inference Performance for Large Language Models")
- `card_resources[]`: `{card_resource_id, raw_type: "RECORDING"|"TRANSCRIPTION", data, mime_type: "audio/aac", is_primary, metadata (JSON string: size, duration ms, start_time, end_time), create_time, update_time, remote_gcsKey, remote_region}`
  - `raw_type:"TRANSCRIPTION"` → `data` holds the **full transcript text inline** (Thai/English mixed in this account). No second fetch needed for transcripts.
  - `raw_type:"RECORDING"` → `data` empty; `remote_gcsKey` = `audioRequest/<md5(account uuid)>/<cardId>/<resourceId>.aac`, `remote_region` = `"asia-south1"`. Confirmed `md5(account uuid) == 51deb102e41e2e29ac0f252f96adadcb` for this account.
- Request body variants observed: `{"page_no":1,"page_size":20,"sinceTime":0}` and `{"categoryId":"recording","page_no":1,"page_size":...}`.

Full sample card JSON for decoder fixtures: `secrets/fixtures/card_list_sample.json` (gitignored; redact before using in committed tests).

## ConfigUtil native values (frida dump, 2026-10-25)

All `static native` methods on `com.nothing.ai.service.engine.util.ConfigUtil`, dumped live (values also mirrored in `secrets/es_config_dump.json`):

- `getApiKey()` — the legacy-host `auth` header key (see above). **In secrets only.**
- `getClaimKey()` — RSA public key (X.509 SPKI, base64) — this is the write-path encryption public key from notes/02 unknown #5.
- `getLogKey()` — 32-char key (log encryption).
- `getAPS1()` — Amplify config ap-south-1: Cognito identity pool `ap-south-1:4a694709-b90d-41ad-bf93-76c6816139b9`, S3 bucket `essential-space-india`.
- `getEUW3()` — eu-west-3: S3 bucket `essential-space-eu`.
- `getFirebaseConfig()` — `{applicationId:"1:412109873682:android:...", projectId:"ai-testing-440205", apiKey:"AIzaSy..."}` (web API key, also embedded in the public APK).

## Audio files — what works and what blocks (deferred)

Facts established:

1. Buckets from `FirebaseUtil.Location`: `AS1("asia-south1", "gs://essential-space-gcs-asia-south1")`, `EW3("europe-west3", "gs://essential-space-gcs-europe-west3")`.
2. `GET storage/v1/getFirebaseToken` (legacy host + auth headers) → **works**: a Google identity-toolkit **custom token** (RS256, issuer `firebase-adminsdk-fbsvc@ai-testing-440205...`, claims `isNtUser:true`, `uid` = account uuid, 1 h).
3. `POST identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=<web API key>` → **works**: Firebase idToken, `isNtUser` claim survives, `aud=ai-testing-440205`.
4. `GET firebasestorage.googleapis.com/v0/b/essential-space-gcs-asia-south1/o/<urlencoded gcsKey>?alt=media` with `Authorization: Bearer <idToken>` → **403 Permission denied** (metadata GET also 403; unauthenticated also 403; slash-literal URL forms are invalid = 400).
5. S3 via the Cognito identity pool unauthenticated role (GetId succeeds! `GetCredentialsForIdentity` returns creds) → `s3:GetObject` on `essential-space-india` → **403 AccessDenied** (role lacks object permissions).
6. The ES app **on the emulator also cannot play** records: player stuck at 0:00, no Firebase Storage request even attempted (no logcat errors, `StorageReference.getFile` hook never fires). One hint: the app logs `PackageManager$NameNotFoundException: com.nothing.ntessentialrecorder` — the recorder companion app is not installed on the emulator; playback may depend on it. The user's real phone (which recorded the audio locally and has the recorder app) plays fine.

Conclusion for v1: transcripts are fully served by the card list alone; **audio playback deferred** (explicitly allowed by spec Q13). Follow-up hypotheses for a later issue: Firebase Storage rules requiring Play Integrity/App Check attestation; download-token URLs; recorder-app dependency on-device; or authenticated Cognito identities for S3.

### Update (2026-10-25, later session): the cloud copy is upload-only — playback is local, audio playback is not feasible today

Decompiled `EssentialRecorder.apk` (`apks/ntessentialrecorder/` → `apks/ntessentialrecorder/jadx-out/`) and re-audited the ES app; this closes the follow-up hypotheses above:

- **ES app `FirebaseUtil` is upload-only** (`notes/jadx/.../util/FirebaseUtil.java`): `uploadFile`/`putFile` plus upload-session resume bookkeeping (`findFastestLocationWithLatency` even uploads a latency-probe file `upload_test.dat`). No `getFile`/`getDownloadUrl` call exists anywhere outside the coil3 image loader.
- **Recorder app has no download path either**: its only network call is `essentialVoice/ai/v1/transcription` (`network/NetworkApi.java`); no Firebase Storage, no cloud restore, no audio fetch. Playback = the ES app binds `com.nothing.ntessentialrecorder/.MainService2`, which plays the **local recording file** — which is exactly why the emulator (no recorder app installed, no local files) sat at 0:00 with zero network attempts, and why the user's real phone plays fine.
- Combined with the earlier finding that a valid Firebase idToken still gets 403 on `?alt=media` and metadata reads, the picture is: **no Nothing client ever downloads audio from Firebase Storage**. The rules deny client reads; there is no working request to replicate.

Verdict: audio playback in a third-party client is **not feasible today** — the blocker is not attestation we could mimic, it is that no download path exists in the ecosystem. Re-open only if Nothing ships a downloading client (a web player, restore-on-new-phone, multi-device sync) or relaxes the rules; then capture that client's request and replicate.

## What the macOS client needs (summary for issues 02-03)

- Two hosts: legacy `essential-space.nothingtech.link/essentialSpace/` (records: card/collection/category list) and `prod.essentialsearch.essential-nt.com` (preferences; memories list = AI memory bank, currently empty for this account).
- Two runtime secrets loaded from files (never in the repo/binary): the legacy `apiKey` (`secrets/es_legacy_apikey.txt` → install as `~/.better-essential-space/legacy-api-key`) and the account HMAC key for `x-app-signature` (`secrets/spoof_and_sign.py` → `~/.better-essential-space/account-signing-key`), the latter needed for token refresh/login (M2) and possibly the refresh grant.
- Records UI reads card list (+ pagination via `page_no`/`hasNextPage`); transcript from the TRANSCRIPTION resource; title/summary/date from `cards`; detail can also show duration/size from RECORDING metadata.

## Artifacts

- Capture: `captures/es-sync.flow` (28→38 flows; the 12 legacy-host list calls are the evidence)
- Dumps: `/tmp/full_dump.jsonl`, `/tmp/auth_full.jsonl` (scratch)
- Frida scripts used: `/tmp/dump_apikey.js` (ConfigUtil), `/tmp/hook_fbstorage.js` (storage hooks), agent's `/tmp/hook_es6.js`
- Secrets written: `secrets/es_legacy_apikey.txt`, `secrets/es_config_dump.json`, `secrets/fixtures/card_list_sample.json`
