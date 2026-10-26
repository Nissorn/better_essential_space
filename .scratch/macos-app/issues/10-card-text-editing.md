# 10 — Edit Record text: title, summary, main topics

Status: ready-for-agent
Type: feature

## Summary

Let the user edit a Record's text and push it to Nothing's cloud. `POST storage/card/v1/update` on the legacy host accepts the full `client_request_response` JSON back with edits; the write envelope is cracked and live-verified (notes/04; `tools/es-write-path-test.py` proves create→update→verify→delete end to end).

## Recipe

- Wire format (`CardUpdateRequest1`):
  ```json
  {"payload": "<AES-256-ECB-PKCS7(deviceId)>", "cipherKey": "<RSA-PKCS1v15(base64(32-random-bytes), claimKey)>",
   "clientVersion": 2,
   "cards": [{"cardId": "…", "client_request_response": "<FULL edited JSON string>",
              "files": [{"region": "…", "gcsKey": "…"}], "collectionIds": [],
              "clientUpdateTime": <ms>, "payload": "<AES(String(size))>", "cipherKey": "<same>"}]}
  ```
- The server **replaces** `client_request_response` wholesale — send the whole JSON string with `cards.title`, `cards.summary`, and/or `card_resources[]` (main topics live in `MEETING_MAIN_TOPIC` / `MEETING_KEY_TOPIC_ANALYSIS` resources) edited. Not a patch.
- Envelope primitives in Apple frameworks, no third-party deps: `CCCrypt(kCCAlgorithmAES, kCCOptionECBMode | kCCOptionPKCS7Padding)` and `SecKeyCreateEncryptedData(…, .rsaEncryptionPKCS1, …)`.
- New runtime secret: claimKey (RSA-2048 SPKI base64, currently in `secrets/es_config_dump.json`) → install as `~/.better-essential-space/claim-key` alongside the legacy apiKey; fail with a clear error if absent.
- Per-card `payload` = AES of `String.valueOf(size)`; `"0"` accepted for a card with no files — for real cards prefer the sum of RECORDING metadata `size` values.
- `memories/update` on the new host is the memory bank (`{memoryName, fact, metadata}`) — irrelevant here.
- Update response is `BaseResponse<List<CardResponse>>`; refresh the local Record from it (or re-fetch the card) so the UI reflects the server state.

## UX sketch

- Detail view: inline edit for title (also shown in the sidebar/list), summary block, and each main-topic row (title + content); save button per edit session writes once via one update call.
- Optimistic local update + background push; on failure keep the edit and surface a retry.

## Done when

- [ ] Editing title/summary/main topics round-trips: edit → `card/v1/update` → re-fetch shows the new text (verified against the live account with a scratch card, like the probe tool).
- [ ] Envelope unit tests: AES/RSA vectors matching the probe tool's output; malformed claimKey errors clearly.
- [ ] Concurrent edit safety: update carries `clientUpdateTime`; document that last-write-wins is the server behaviour.
