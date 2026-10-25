# Essential Space API — static RE findings

From static analysis of `com.nothing.ntessentialspace` v2.2.0 (versionCode 543) pulled from a Nothing Phone (2a) Plus (A059, Nothing OS). Decompiled with jadx: `notes/jadx/ntessentialspace/` (only code, no resources). Evidence paths below are relative to `notes/jadx/ntessentialspace/sources/`.

## ✅ SOLVED — working read API (2026-10-25, session 2): no SSO token needed

The ES app talks to **two different backends**, and the one that actually serves the user's content in v2.2.0 is **not** the `essential-space.nothingtech.link` host documented further below:

| Backend | Used by | Auth |
|---|---|---|
| `https://prod.essentialsearch.essential-nt.com` | `MemoriesApiService` (content), `UserPreferencesService`, `ProcessMemoryService` (AI memory bank) — via `oy4`/`SecurityConfig.fetchKey1` | **Plain account access token works** |
| `https://essential-space.nothingtech.link/essentialSpace/` | `NothingApiService` (storage/card/bill/package v1 APIs) | Rejects the account JWT (`401 200001`) — likely legacy or a different consumer; SSO client_id unresolved but **not needed** for the current API |

Base-URL evidence: `defpackage/oy4.java` wraps `com.nothing.security.sdk.SecurityConfig` (JNI → `libconfig-lib.so`); decrypted live on the emulator by constructing `SecurityConfig("")` via Frida and calling `fetchKey1..5`/`fetchCustomData`:

- `fetchKey1` = `https://prod.essentialsearch.essential-nt.com` (base URL)
- `fetchKey2` / `fetchKey3` = app keys (base64 blobs — likely the Cognito/Amplify keys, see unknowns)
- `fetchCustomData` = `{"accessProviderWhitelist":"com.nothing.appservice,com.nothing.smartcenter"}`
- Script: `tools/frida-dump-security-config.js`

**Minimal end-to-end recipe (verified live, HTTP 200):**

```bash
# 1. Login (see "Login protocol" below) → 30-day access_token JWT (aud=account-app-native)
# 2. Read content — headers: Authorization + X-Nothing-Account-ID ONLY (timestamp not required)
UUID=<uuid claim from the access_token JWT>
TOK=<access_token>
curl "https://prod.essentialsearch.essential-nt.com/memories/list" \
     -H "Authorization: Bearer $TOK" -H "X-Nothing-Account-ID: $UUID"
# → 200 {"memories":[]}   (empty until the account has cloud-synced content)
curl "https://prod.essentialsearch.essential-nt.com/preferences" \
     -H "Authorization: Bearer $TOK" -H "X-Nothing-Account-ID: $UUID"
# → 200 {"userId":...,"useMemory":true,"hasAgreedToTerms":true,"updatedAt":...}
```

Verified header matrix on `memories/list`: Bearer+Account-ID → **200**; drop either → 401. The token ES itself sends is exactly this token (`User.nothingToken` == the OAuth `access_token`, confirmed by Frida hooking `i96$a.a(User)` in ES and comparing JWT claims), and `defpackage/ag.java` adds only `Authorization`, `X-Nothing-Account-ID`, `Content-Type`, `timestamp` — no signature, no device attestation on this host.

✅ **RESOLVED (2026-10-25 session 3) — records are Cards on the legacy host; the 401s were a missing `auth` header, not a wrong token.** Full findings, verified read recipe, and the `auth = md5(apiKey + timestamp)` header scheme: **notes/03-es-sync-capture.md**. (Original hypotheses (a) was correct; (b) and (c) were eliminated by the phone screenshot + JWT uuid match.)

Endpoints on the new host (from `MemoriesApiService.java`, `UserPreferencesService.java`, `ProcessMemoryService.java`; `@ou3`=POST, `@x02`=GET):

| Method | Path | Purpose |
|---|---|---|
| GET | `memories/list?page_token=` | List Essential Space memories (paginated) |
| POST | `memories/update` | Update memory (body class `v86`) |
| POST | `memories/delete` | Delete memory (body class `x41`) |
| GET | `preferences` | User preferences (verified 200) |
| POST | `process_memory` | Memory-bank AI processing (body class `t04`) |

(`version/v1/check` and the `bill/*`/`storage/*` paths are **not** served by this host — they belong to the legacy `essentialSpace/` base.)

## Why the earlier "SSO token required" conclusion was wrong

The 401 experiments had hit the legacy host only. The current app's request chain (`ag` interceptor → `oy4` base URL) never touches that host for content reads, and the app performs **no token exchange at all**:

- ES's bundled `IUserService` stub (`com/nothing/user/center/data/service/b.java`) only implements binder codes 3 (`registerCallback`) and 6 (`getUser`) — **it has no token method** (the UC side implements codes 1,2,4,5,7; code 5 = `getToken`).
- ES also never calls the `content://com.nothing.user.center.provider` methods `registerAppConfig`/`getToken` (the provider dispatch is `p054i5/d.java` in the UC jadx tree; ES's provider client `defpackage/q3.java` only calls `getUser`/`getCurrentState`).
- UC resolves a token request's namespace as the **calling app's package name** (`UserService.a()` → `getNameForUid(Binder.getCallingUid())`), looks up `ns → clientId` in a map filled only by `registerClientId` (Java `registerAppConfig`), and falls back to the host token for unknown namespaces (Dart string `][getToken] fallback host token ns=`). Since nobody registers ES's ns, UC hands ES the host token — which is exactly what the new backend accepts.

The RFC 8693 exchange machinery (kept below for reference) would only matter for the legacy host or for server-side per-service audiences we haven't seen; the macOS client does not need it.

## Architecture at a glance

- **Backend**: `https://essential-space.nothingtech.link/essentialSpace/` (prod) — k8s service behind Nothing's domain; test build points at `https://k8s-essentia-essentia-61cbe5a450-2117596415.ap-northeast-1.elb.amazonaws.com/essentialSpace/` (AWS ap-northeast-1). Evidence: `com/nothing/ai/service/engine/remote/NothingApiManager.java:100-101`.
- **HTTP stack**: Retrofit-style Kotlin interface over OkHttp/Ktor, coroutines.
- **Auth**: `Authorization` header = **Nothing account token** (`User.nothingToken`) obtained from Nothing's **User Center** via **Binder IPC** (`com.nothing.user.center.data.service.IUserService`), not from any login UI inside this app. Evidence: `defpackage/i96.java` (wraps `com.nothing.user.center.data.service.User`, calls `getNothingToken()`), `com/nothing/user/center/data/service/b.java` (AIDL stub).
- **File storage**: AWS Amplify — Cognito auth plugin + S3 storage plugin, with configs for two regions (ap-south-1, eu-west-3) chosen by latency test. `storage/v1/getFirebaseToken` endpoint also exists (Firebase Storage for some files). Evidence: `com/nothing/ai/service/engine/util/AmplifyUtil.java` (`init`, `uploadToS3`), region latency test `measureLatency`.
- **On-device AI**: Whisper + ggml native libs (local transcription) — explains the 159 MB base.apk.
- **Local crypto**: Tink (`tink-java`); native `libsecurityJni.so` for request encryption; `libconfig-lib.so` for hidden config.

## API endpoints (relative to the base URL)

`NothingApiService.java` — annotations are R8-obfuscated; mapping inferred: `@x02` = GET, `@ou3` = POST, `@s22` = `@Header`, `@z44` = `@Query`, `@un` = `@Body`. All wrapped in `BaseResponse<T>`.

| Method | Path | Purpose |
|---|---|---|
| GET | `storage/common/v1/list?sinceTime=` | **Delta sync** of everything since a timestamp |
| POST | `storage/card/v1/list` | Paged card list (keywords, categoryId, pageNo, pageSize, sinceTime, clientCreateTime) |
| POST | `storage/card/v1/list/nopage` | Full card list by IDs |
| POST | `storage/card/v1/create` | Create cards (body encrypted) |
| POST | `storage/card/v1/update` | Update cards (body encrypted) |
| POST | `storage/card/v1/delete` | Trash cards (body encrypted) |
| POST | `storage/card/v1/files` | Attachments metadata per card |
| POST | `storage/restore/v1/list` | Trash list |
| POST | `storage/restore/v1/restore` | Restore from trash (body encrypted) |
| POST | `storage/restore/v1/delete` | Hard delete (body encrypted) |
| POST | `storage/collection/v1/create/update/delete/list` | Collections CRUD (write bodies encrypted) |
| GET | `storage/category/v1/list` | Category list |
| GET | `storage/v1/update/switch?enabled=` | Update switch |
| GET | `storage/v1/getFirebaseToken` | Firebase storage token |
| POST | `ai/v1/audioRequest`, `ai/v2/audioRequest` | AI processing for voice notes |
| POST | `ai/v3/imageRequest` | AI processing for screenshots |
| POST | `ai/v1/embedding` | Embedding for search |
| POST | `ai/v1/getSmartCollectionName` | AI names a collection |
| GET/POST | `bill/v1..v4/account`, `bill/v1/model`, `package/v1/v3/claim` | Subscription/billing/feature-claim |
| POST | `version/v1/check` | Version check (no auth param) |

**Data model** (from `CardResponse`): `cardId`, `code`, `clientRequestResponse`, `clientUpdateTime`, `clientCreateTime`, `deleteAt`, `files: [FileItem]`, `missingFiles`, `clientVersion`. A "Card" is the essential-space item (screenshot capture, voice note, thought); Collections group cards; delta sync is timestamp-based via `storage/common/v1/list`.

**Write-path encryption**: card/collection write requests wrap the JSON body as `payload` (AES) + `cipherKey` (RSA-wrapped AES key) — see `getPayload`/`getCipherKey`/`getPublicKey`/`getAESKeyFromString` in `NothingApiManager.java`, key material from `libsecurityJni.so`. Reads are plaintext JSON.

## Nothing account auth — what we know and what we don't

Known (updated after User Center RE + emulator work, 2026-10-25):
- The app never logs in itself; it binds to the system User Center service and reads `User` (uuid, email, country, `login` flag, `nothingToken`, `thirdPartToken`).
- The API `Authorization` value is `nothingToken` (raw header — exact wire format unknown).
- **User Center = `com.nothing.user.center`** (also shipped as priv-app `/product/priv-app/NothingAccount/`), a **Flutter** app. Its Dart layer performs the account auth itself; native side reaches it via Pigeon channels (`NtAccountFlutterApi.getToken/getLocalUser`).
- **Nothing Account API = `https://account.nothing.tech/api`** (CloudFront). Two layers:
  - First-party login API: `/account/email/login`, `/account/phone/login`, `/account/create`, `/auth/2fa/*`, `/auth/mfa/*`, `/auth/logout`, `/auth/verification/*`, `/device/activate`, `/device/report` (POST — responds 403 to non-trusted devices)
  - OAuth2 layer (RFC-standard): `/v2/oauth2/authorize`, `/v2/oauth2/token`, `/v2/authflow/login|signup`, `/v2/auth/token/migrate`, token exchange via `urn:ietf:params:oauth:token-type:id_token`, PKCE (`NacPkceSession`/`NacPkceUtils`)
- OAuth client ids found: `account-app-native`, `nothing-x-native` (pattern `<app>-native`); redirect URIs: `app://oauth2/callback`, `nothingx://oauth2/callback`
- Device binding: `nac_device_key_*` key material per device (`nac_login_device_uuid_v1`, `nac_device_registered_id`) — the `/device/activate` + `/device/report` flow is what binds an install to the account.
- AWS Cognito SDKs are bundled in ES (`cognito-idp`, `cognito-identity`, OIDC) — backing S3 credentials; `storage/v1/getFirebaseToken` endpoint exists for Firebase Storage.
- Play Integrity + reCAPTCHA artifacts bundled (device-attestation risk for third-party clients).

Unknown (updated 2026-10-25 session 2):
1. ~~`Authorization` header format / TTL / refresh~~ — **answered**: `Bearer <30-day OAuth access_token JWT>`; refresh via `grant_type=refresh_token&client_id=account-app-native`; refresh_token lives in `captures/*.flow`.
2. ~~Is `nothingToken` raw OAuth or SSO-exchanged?~~ — **answered**: it is the raw OAuth access token (`aud=account-app-native`), verified by dumping it from the running ES app; no exchange happens in the ES read path.
3. `fetchKey2`/`fetchKey3` semantics (likely Cognito/Amplify or signing keys for writes) — values captured in this session, purpose unconfirmed. Cognito pool IDs / Amplify config — `ConfigUtil.getAPS1/getEUW3/getApiKey` are **native** methods whose strings in `libconfig-lib.so` are encrypted at rest.
4. Write-path requirements on the new host (`memories/update|delete`, `process_memory`): body schema (`v86`/`x41`/`t04` gson models) and whether they need `fetchKey2/3`-derived signatures — untested (read-only goal for now).
5. The RSA public key for the legacy write encryption and whether it rotates.
6. Whether the legacy `essentialSpace/` host serves consumers with an SSO token — **reopened 2026-10-25**: if the account's records live there (see the open question in the SOLVED section), the macOS client needs that token path after all.

## Request signing — CRACKED (verified against live captures, 2026-10-25)

Every request to `account.nothing.tech/api` carries `x-nonce`, `x-timestamp`/`x-request-timestamp`, `x-device-info` (base64 JSON of the device report fields) and `x-app-signature`:

```
payload  = "body=" + sha256_hex(raw_request_body)
         + "&nonce=" + <x-nonce uuid>
         + "&path=" + urlencode(request_path, safe="")
         + "&timestamp=" + <epoch ms>
         + "&apiKey=" + KEY
x-app-signature = base64url_nopad(HMAC-SHA256(payload, key=KEY))

KEY = see `secrets/spoof_and_sign.py` (gitignored; embedded Nothing account-app key, de-obfuscated from `NtDcConfig._decodeApiKey()` which decodes `"k9T6c6f+bt=JXtQMi+L+gNYWfrC7lKX3YOP7kqU4g8nG"` through the base64 alphabet)
```

(Extraction method: hooking `Hmac::Hmac`/`Hmac::convert` with Frida using blutter's symbol map, verified byte-for-byte against a live capture.)

**Per-endpoint enforcement (from capture analysis, 2026-10-25):** `x-app-signature` rides on every `/api/v2/*` request the app makes. On top of that, the device-bound POSTs (`authflow/login`, `authflow/login/state/input`, `oauth2/token`) **require** `x-device-signature` — the genuine app sent `authflow/login` without it (because `device/report` had never succeeded) and got `403 "Missing required header(s): X-Device-Signature"`. `authorize` instead carries `x-idp-session`; bare `GET /api` probes go unsigned and are still served. `x-device-signature` signs with the EC P-256 private key whose `public_key` was uploaded in `device/report` — keypair generated client-side per device, so a native client can mint its own with CryptoKit.

**`x-device-signature` scheme — CRACKED (2026-10-25, verified against all 3 signed requests in `captures/nothing-login2.flow` with the uploaded public key):**

```
signPayload = "<x-timestamp epoch ms>" + "." + <raw request body string>   // no hashing, no nonce, no path
signature   = base64UrlWithPadding( ECDSA-P256-SHA256( utf8(signPayload) ) as P1363 r||s 64 bytes )
```

Evidence: User Center Dart AOT (blutter `/tmp/uc_blutter`), `NacNetConfigInterceptor::_injectDeviceHeadersIfNeeded` builds `"$timestamp.$serializeBodyForSigning(body)"`, `NacDeviceKeyManager::sign` → `_encodeP1363` (r and s each padded to 32 bytes) → `base64Url.encode` (keeps `=` padding). The DER variant (`_signWithKey` → `_encodeDer`) is only for key-rotation payloads. The `public_key` in `device/report` is SPKI DER, base64 (91 bytes = 26-byte ASN.1 header + 65-byte `0x04||X||Y`).

Device risk gate: `POST /api/v2/device/report` is judged purely on the self-reported JSON (`is_emulator`, `device_model`, `hardware`…). With a spoofed body + re-signed payload the server returns `200 {"device_id": "...", "next_key_rotation_at": "..."}` — the "Security issue detected" login block comes from this report, and is fully bypassed. Working mitmproxy addon: `secrets/spoof_and_sign.py` (gitignored; run `mitmdump -w captures/<name>.flow -s secrets/spoof_and_sign.py`).

## Login protocol — captured live (2026-10-25, email+OTP login on the emulator)

**The entire login is native HTTP (`User-Agent: Dart/3.9 (dart:io)`) — the app never opens a browser or WebView.** Full wire order (verified against `captures/nothing-login2.flow`, 2026-10-25 capture analysis):

1. **Device report** — `POST /api/v2/device/report` with the device-field JSON (`identifier`, `platform:"ANDROID"`, `device_model`, `is_emulator`, …) plus a base64 **EC P-256 `public_key`** → `{"device_id":"<uuid>","next_key_rotation_at":"..."}`. The client signs later auth requests with the matching private key (`x-device-signature`). An honest `is_emulator:true` body → `403 "Device is an emulator"` (this was the entire emulator block).
2. **Authflow login** — `POST /api/v2/authflow/login` body `{"input":{"identification":"email","login_id":"<email>","password":"<pw>"}}` → `{"state_token":"statetoken_…","action":{"type":"verify","data":{OTP challenge, masked email, is_device_trusted:false}}}` (new device ⇒ OTP always required).
3. **OTP submit** — `POST /api/v2/authflow/login/state/input` body `{"state_token":"…","input":{"code":"<6-digit>"}}` → `action.type:"finished"` with `session_id` (`sess_…`).
4. **Authorize** — plain `GET /api/v2/oauth2/authorize?response_type=code&client_id=account-app-native&redirect_uri=nothing-account-app://oauth2/callback&scope=openid profile email offline_access&state=<43 random>&code_challenge_method=S256&code_challenge=<43 random>` with headers `x-idp-session: <session_id>` + `x-device-id` → `302` whose `Location` is `nothing-account-app://oauth2/callback?code=…&state=…`. The client just parses `code` out of `Location`; the redirect URI is never opened, so a native client needs no URL-scheme registration.
5. **Token exchange** (form-encoded):
```
POST https://account.nothing.tech/api/v2/oauth2/token
grant_type=authorization_code&client_id=account-app-native
&code=<...>&redirect_uri=nothing-account-app://oauth2/callback&code_verifier=<...>
&x_device_info=<urlencoded base64 JSON of device fields>
```
(headers include `x-device-signature`; the `x_device_info` form field is not re-validated — a captured exchange succeeded with `is_emulator:true` inside it. Server rejects only what `device/report` claimed.)
Response: `access_token` (**JWT ~650 chars, HS256, expires_in 2 592 000 s = 30 days**), `refresh_token` (~110 chars), `id_token` (RS256 JWT), `token_type=Bearer`, `scope`, **`device_secret` (ds_… — originates here, NOT from device/report)**.

Access-token JWT claims: `iss=https://account.nothing.tech/api/v2`, `aud=account-app-native`, `sub` (numeric user id), `uuid` (account uuid), `scopes`, `sid` (session), `amr:[pwd,otp]`, **`did=<device_id from device/report>`** — device binding is inside the token. Usage: `Authorization: Bearer <access_token JWT>` (verified live on `/api/auth/me_v2` → 200).

**3. SSO token exchange for other services** (RFC 8693, from the Dart AOT; parameters confirmed in `exchangeTokenForSso`):
```
POST https://account.nothing.tech/api/v2/oauth2/token
grant_type=urn:ietf:params:oauth:grant-type:token-exchange
subject_token=<id_token>&subject_token_type=urn:ietf:params:oauth:token-type:id_token
actor_token=<device_secret>&actor_token_type=urn:x-oath:params:oauth:token-type:device-secret
client_id=<per-service client>&scope=device_sso offline_access&x_device_info=<...>
```
The per-service `client_id` is **not hardcoded in the apps** — it is resolved per namespace server-side (`AccountSession::registerClientId`, `getToken(ssoNamespace)`). Trying `essential-space*`/`ntessentialspace*`/package-name variants returns `invalid_client`. **Superseded 2026-10-25 session 2:** the current ES API does not need this exchange at all (see the "SOLVED" section above); the legacy `essentialSpace/` host still rejects the account JWT with `401 {"code":"200001","msg":"Auth failed. Without auth"}`, but nothing in ES v2.2.0 reads content from it.

**4. ES backend auth headers** (`defpackage/ag.java` + `NothingApiManager`): `Authorization: Bearer <token>`, `X-Nothing-Account-ID: <account uuid>`, `timestamp: <epoch ms>` (timestamp optional — verified). Legacy host: raw account JWT → 401 200001. Current host (`prod.essentialsearch.essential-nt.com`): raw account JWT → 200.

## Emulator state (session 2026-10-25)

- Email+OTP login **succeeded** on the emulator; User Center holds the session; the ES app binds the account (`ESAccountManager: Current status:LoggedIn`, Tink-encrypted session blob) and reaches its main screen.
- Emulator: `essential36` AVD now on **emulator-5556** (port shifted after a restart), `-gpu swiftshader_indirect` (host GPU broke Flutter input — dialogs rendered as black blobs and clicks were dead; swiftshader fixed both).
- ES onboarding bypassed via datastore patch: `/data/data/com.nothing.ntessentialspace/files/datastore/essential_raw_data.preferences_pb`, keys `skip_onboarding=true`, `cloud_enable=true` (protobuf bool `08 00`→`08 01`). The "Double-Click Essential Key" tutorial gate requires a real Essential Key event (no accessibility service in ES; the key is routed by Nothing OS framework — not reproducible on stock Android).
- `Backup` toggle (Settings→Cloud storage) stayed off: cloud storage is likely server-gated (bill/claim) per device; sync worker therefore never fired → ES backend traffic not yet captured.
- Session 2 addendum: with hooks on UC's Dart `AccountService.getToken` / `registerClientId` / `exchangeTokenForSso` (blutter addresses 0x9b6e00 / 0xa02c20 / 0x9b8190) and ES restarts, **none of them ever fire** — ES never requests a namespaced token (see "Why the earlier SSO conclusion was wrong"). Android 16's cached-app freezer also freezes UC between binder calls; `device_config put activity_manager native_app_freezer false` alone does not unfreeze an already-frozen process — restart UC (force-stop + re-bind via ES) and attach Frida quickly, or attach by PID (`-n` name lookup intermittently fails; `-p <pid>` is reliable).
- Running when the session paused: mitmdump (`-w captures/nothing-login2.flow -s /tmp/spoof_and_sign.py`, port 8080), frida-server on the emulator, blutter output in `/tmp/uc_blutter/`.

## Emulator capture stack (built 2026-10-25, survives in the `essential36` AVD)

The emulator route needed four platform workarounds, all scripted and repeatable:

1. **API 36 (Android 16) google_apis image** — User Center has minSdk 36; `google_apis` (not `-playstore`) keeps `adb root` available.
2. **mitmproxy CA in the system store** — `adb root` → `avbctl disable-verification` → reboot → `adb remount` → push `~/.mitmproxy/mitmproxy-ca-cert.pem` as `c8750f0d.0` to `/system/etc/security/cacerts/`. IPv6 disabled in-guest (`/proc/sys/net/ipv6/conf/all/disable_ipv6=1`) because the Mac has no IPv6 route (mitmproxy 502 otherwise). Emulator boots with `-http-proxy http://127.0.0.1:8080`.
3. **Nothing framework class injection** — User Center calls `Class.forName("com.nothing.onlineconfig.ConfigGrabber")`, a class baked into Nothing's `framework.jar` (found on the phone at `/system/framework/framework.jar` classes5.dex). Fix: compiled a 2-class stub (`ConfigGrabber.grabConfig()→null`, `ConfigObserver.register()→no-op`) with javac+d8 against android-34 and injected `/system/framework/nt-services.jar` (named to reuse the phone's boot-jar slot) into the emulator **BOOTCLASSPATH** by appending a record to `/system/etc/classpaths/bootclasspath.pb` (protobuf record: `0a len 0a pathlen <path> 10 01`). The earlier jadx/dexlib2 and hand-byte-edit attempts failed on ART's map/section checks; a clean d8 dex was the reliable path. Also `settings put global hidden_api_policy 1` (reflection on hidden boot classes was blocked otherwise).
4. **PairIP bypass** — User Center's startup is gated by Google Play licensing (`com.pairip.licensecheck.LicenseActivity` → "Check that Google Play is enabled"). Patch: apktool-decompiled `apks/usercenter/base.apk`, changed `android:name="com.pairip.application.Application"` → `com.nothing.user.center.AccountApplication` (the wrapper only added `LicenseClient.checkLicense()`), removed `requiredSplitTypes`/stray `splitTypes` attrs, merged `lib/arm64-v8a` from the abi split, set `extractNativeLibs="true"`, rebuilt, zipaligned, signed with a debug key → `/tmp/ntjar/uc-signed.apk`. The Flutter login UI ("Welcome to Nothing", Email login) then opens. Warning shown: "Device appears to be rooted" — informational only.

Traffic is recorded by `mitmdump -w captures/essential-space-login.flow` on port 8080. `captures/`, `apks/` and `notes/jadx/` are gitignored. Patch tooling and stub sources live in `/tmp/ntjar/` (ephemeral — copy into repo if the build is needed again).

## Traffic-capture feasibility (decided from manifest)

No `networkSecurityConfig` in the manifest; default trust applies. With minSdk 34/targetSdk 37, **user-installed CAs are not trusted** — plain mitmproxy will not work. Options: Android emulator with system CA (recommended, keeps the phone untouched), or Frida/objection on the phone.

## Repo layout for RE artifacts

- `apks/` — pulled APKs (gitignored; copyrighted binaries)
- `notes/jadx/` — decompiled sources (gitignored, regenerable via jadx)
- `captures/` — mitmproxy captures (gitignored; contain tokens)
