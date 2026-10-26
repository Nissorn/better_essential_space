# Audio download & card writes — both open problems closed (2026-10-26, session 4)

Resolves the two features the macOS client was missing: **downloading Record audio from the cloud** (notes/03 declared it infeasible — that verdict was wrong) and **editing Card text** (title, summary, main topics). Both were proven live against production with curl/openssl from the Mac, outside any proxy.

## 1. Audio download — WORKING (premise of notes/03 overturned)

**The wrong premise:** notes/03 concluded "no Nothing client ever downloads audio from Firebase Storage" after auditing `FirebaseUtil`/`CloudStorageUtil`/`AmplifyUtil` (upload-only) and the Recorder app (transcription-only). The audit covered the upload utilities but missed the download pipeline.

**The missed component:** `com.nothing.ntessentialspace.data.work.sync.RemoteFileDownloader` (jadx: `notes/jadx/ntessentialspace/sources/com/nothing/ntessentialspace/data/work/sync/RemoteFileDownloader.java`), a WorkManager worker wired into `CloudSyncWorker` after every `fetchDeltaSync1`. It requests a **server-signed download URL** for each pending cloud file and fetches the bytes with plain OkHttp (Range resume included).

The chain (all three steps verified live, HTTP 200):

```
1. POST storage/card/v1/list  (existing read recipe, notes/03)
   → each Card carries files: [{region, gcsKey}]
     (mirrors card_resources[].remote_region / remote_gcsKey on RECORDING resources)

2. POST storage/card/v1/files
   headers: Authorization / timestamp / auth (same as all legacy writes+reads)
   body:    {"files":[{"region":"asia-south1","gcsKey":"audioRequest/<md5(uuid)>/<cardId>/<resId>.aac"}]}
   → 200 {"code":"00000","data":[{"region":…,"gcsKey":…,"signUrl":"https://storage.googleapis.com/essential-space-gcs-asia-south1/storage/<gcsKey>?X-Goog-Algorithm=GOOG4-RSA-SHA256&X-Goog-Expires=604800&X-Goog-Signature=…"}]}

3. GET <signUrl>   (no Authorization header — the signature is in the URL)
   → 200, the audio bytes
```

Live evidence (2026-10-26): requested the signUrl for a RECORDING resource of card `97176add-…`, downloaded **9,747,378 bytes**, `file` identifies it as `ISO Media, MP4 v2` (AAC in an MP4/M4A container despite the `.aac` extension; Content-Type `video/mp4`). No Firebase idToken, no App Check, no attestation — the legacy-host auth headers are the only gate, and we already have them. The signed URL is Google Cloud Storage V4 (`X-Goog-*` params, host `storage.googleapis.com`, bucket `essential-space-gcs-asia-south1`).

Notes for the client:
- The earlier 403s (Firebase `?alt=media`, Cognito S3 role) were the wrong doors; the server-issued signUrl is the right one and Nothing's own app uses exactly this chain.
- The emulator "playback stuck at 0:00" mystery from notes/03 is also explained: `CloudSyncWorker` never ran there (backup toggle server-gated), so `RemoteFileDownloader` never downloaded the files, and playback preferred the missing local recording.
- Extension choice: the ES app picks it from the `Content-Disposition` header of the GET (`RemoteFileDownloader.t()`); `mp4`/`m4a` is what actually comes back.
- `storage/card/v1/files` is plaintext JSON (no write-envelope) despite being a POST.

## 2. Card text editing — WORKING (write envelope cracked)

`memories/update` (new host) is the AI **memory bank** DTO (`v86` = `{memoryName, fact, metadata}`) — not record editing. Editing a Record = `POST storage/card/v1/update` on the legacy host, whose request model is `CardUpdateRequest1`. The R8-obfuscated call graph has no in-app caller in v2.2.0, but the wire format is fully determined by the model classes and the server accepted a from-scratch request.

**Write envelope** (shared by create/update/delete/restore/hard-delete; `NothingApiManager.getPayload`/`getCipherKey`/`getPublicKey`/`getAESKeyFromString`):

```
aes_key_b64 = base64(32 random bytes)                      // the "key string"
payload     = base64( AES-256-ECB-PKCS7( utf8(deviceId), key = raw 32 bytes ) )
cipherKey   = base64( RSA-PKCS1v15-encrypt( aes_key_b64, claimKey ) )
```

- Java `Cipher.getInstance("AES")` = `AES/ECB/PKCS5Padding` (= PKCS7, same block padding).
- `claimKey` = `ConfigUtil.getClaimKey()` (frida dump, `secrets/es_config_dump.json`) — RSA-2048 SPKI base64 (`MIIBIjANBgkqhkiG9w0B…`). It is a **public** key, so any client can wrap its own AES key; no private key material is involved.
- The outer `payload` is the AES-encrypted **deviceId string** (parameter name confirmed by the coroutine `DebugMetadata` `n = {"accessToken","deviceId","cards",…}` of postCardCreate1/postCardUpdate1). The server accepted an arbitrary stand-in string, so it is not validated against the account.
- Despite the name, the cards' real content (`client_request_response`) travels in cleartext inside `cards[]`; only the deviceId and the per-card `size` are AES-encrypted.

**Update request** (`storage/card/v1/update`, plaintext top level except the envelope):

```json
{
  "payload": "<AES(deviceId)>", "cipherKey": "<RSA(aes_key_b64)>", "clientVersion": 2,
  "cards": [{
    "cardId": "<uuid>",
    "client_request_response": "<the FULL edited JSON string>",
    "files": [{"region": "…", "gcsKey": "…"}],
    "collectionIds": [],
    "clientUpdateTime": 1769400000000,
    "payload": "<AES(String.valueOf(size))>",
    "cipherKey": "<same cipherKey>"
  }]
}
```

- `client_request_response` must be sent **whole** (the server replaces it, not a patch): edit `cards.title`, `cards.summary`, and/or the `card_resources[]` entries (`MEETING_MAIN_TOPIC`/`MEETING_KEY_TOPIC_ANALYSIS` carry the main topics) and send the string back.
- Per-card `payload` = AES-encrypted `String.valueOf(size)`; a `"0"` was accepted for a card with no files. For real cards, the sum of file metadata sizes is the likely honest value.
- `clientVersion: 2` matches the value on the account's existing cards.

**Create** (`storage/card/v1/create`) is the same shape plus `categoryId`, `clientCreateTime`, and a client-generated `cardId`.

**Delete/restore:** `storage/card/v1/delete` takes `cards:[{cardId, clientUpdateTime}]` (no per-card payload); `storage/restore/v1/delete` takes `cardIds:[…]`; `storage/restore/v1/list` lists trash. Same envelope.

**Live proof (2026-10-26, `/tmp/es_write_test.py`, committed as `tools/es-write-path-test.py`):**

```
CREATE  http=200 code=00000 msg=success   (server echoed cardId)
UPDATE  http=200 code=00000 msg=success
VERIFY  title='BES scratch card EDITED TITLE' summary='summary edited by write-path test'
TRASH   http=200 code=00000 msg=success
HARDDEL http=200 code=00000 msg=success
```

The verification read-back came from `storage/card/v1/list`, i.e. the edit is visible to every client of the account. The scratch card was deleted afterwards; no user data was touched.

Swift implementation notes: both primitives exist in Apple frameworks without third-party deps — `CCCrypt(kCCAlgorithmAES, kCCOptionECBMode | kCCOptionPKCS7Padding)` for the payload and `SecKeyCreateEncryptedData(.rsaEncryptionPKCS1)` for the cipherKey. The claimKey joins the other runtime secrets (`~/.better-essential-space/claim-key`), never the binary.

## 3. What stays open

- The main topics come from `card_resources[]` with `raw_type` `MEETING_MAIN_TOPIC` / `MEETING_KEY_TOPIC_ANALYSIS`; editing them is the same update call, but the macOS UI needs edit affordances per resource type (issue 10).
- Recreating a Card's audio upload path (Recorder → S3/GCS) is out of scope; the client only downloads.
- Sign-URL TTL is `X-Goog-Expires=604800` (7 days, measured live 2026-10-26). The client still never persists a signUrl: it signs per download and re-signs once on a GCS 403, which covers an expired signature.
