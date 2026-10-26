# 09 — Download Record audio from the cloud and play it

Status: ready-for-agent
Type: feature

## Summary

The macOS client shows transcripts only. The audio now has a proven download chain (notes/04, live-verified 2026-10-26): `storage/card/v1/files` returns a server-signed GCS V4 URL per (region, gcsKey), and a plain GET on it returns the audio bytes. supersede the old "playback not feasible" conclusion from notes/03.

## Recipe (all steps verified live, HTTP 200)

1. Cards already carry `files: [{region, gcsKey}]` (and `card_resources[].remote_region/remote_gcsKey` on RECORDING resources); no new read is needed.
2. `POST storage/card/v1/files` on the legacy host with the same three auth headers as every other legacy call, body `{"files":[{"region":"asia-south1","gcsKey":"audioRequest/…/<cardId>/<resId>.aac"}]}` → `data:[{region, gcsKey, signUrl}]`. Plaintext JSON — no write envelope.
3. `GET signUrl` with **no** Authorization header (signature is in the URL, `storage.googleapis.com/…?X-Goog-Algorithm=GOOG4-RSA-SHA256&…`). Live result: 9,747,378 bytes, `ISO Media, MP4 v2` (AAC in an MP4/M4A container despite the `.aac` name; Content-Type `video/mp4`).

## Implementation notes

- Two ESClient methods: `fetchCardFileURLs(_ files: [CardFileRef]) -> [CardFileResponse]` (signUrl per gcsKey) and `downloadAudio(from signUrl: URL) -> Data/URL`; batch a Record's files in one call; do not cache signUrls beyond their `X-Goog-Expires` (~1 h) — re-request on demand.
- Persist downloads under Application Support keyed by gcsKey, resume-free (files are ≤ tens of MB); extension from the response `Content-Disposition` like the ES app's downloader does, or just `.m4a`.
- Playback: AVPlayer on the local file. The audio is an MP4 container — verify AVAudioPlayer vs AVPlayer; AVPlayer handles ftyp/mp42.
- Secret needs: none beyond what the client already loads (legacy apiKey + token).

## Done when

- [ ] A Record with a RECORDING resource can fetch its signUrl, download the audio, and play it in the detail view.
- [ ] Missing/failed downloads surface a sensible error state (e.g. 404/403 from GCS, offline).
- [ ] Decoding test for the `storage/card/v1/files` envelope (request + response) with a fixture.
