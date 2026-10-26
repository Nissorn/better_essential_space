# RE tooling (session artifacts, kept from /tmp)

Reusable scripts from the Essential Space reverse-engineering sessions. See `notes/02-essential-space-api.md` for the full findings.

## Frida scripts (target: emulator `emulator-5556`, frida-server already running)

Attach pattern (the CLI REPL dies on EOF in background; `-n` name lookup is flaky, prefer `-p <pid>`; spawn mode `-f` catches startup hooks):

```bash
adb -s emulator-5556 shell am start -n com.nothing.ntessentialspace/.MainActivity
PID=$(adb -s emulator-5556 shell ps -A | grep ntessentialspace | awk '{print $2}')
tail -f /dev/null | frida -D emulator-5556 -p $PID -l <script.js>
```

- `frida-dump-security-config.js` — constructs `com.nothing.security.sdk.SecurityConfig("")` in the ES (or UC) process and dumps `fetchKey1..5` + `fetchCustomData` (decrypted config from `libconfig-lib.so`): base URLs, embedded keys. This produced the `prod.essentialsearch.essential-nt.com` discovery.
- `frida-dump-es-account.js` — hooks `i96$a.a(User)` (ES's account-model factory) and the `ag` OkHttp interceptor; prints the live `nothingToken` and every authenticated request URL. Proved ES sends the raw account JWT.

Dart-level hooks for User Center (registerClientId/exchangeTokenForSso/getToken) are generated from the blutter template — see `notes/02` "Emulator state" for addresses; the generator is small enough to rebuild: copy `/tmp/uc_blutter/blutter_frida.js`, replace its `onLibappLoaded` with `Interceptor.attach(libapp.add(0xADDR), {onEnter: dump args via getTaggedObjectValue})`.

## mitmproxy capture readers

Read `.flow` captures with the bundled interpreter (system python3 has no mitmproxy):

```bash
mitmdump -nr captures/<file>.flow -s tools/mitmdump-dump-recent-flows.py --set flow_detail=0
```

- `mitmdump-dump-recent-flows.py` — one JSONL line per recent flow (method/host/path/status/truncated auth) → `/tmp/flow_recent.jsonl`.
- `mitmdump-dump-auth-bodies.py` — request/response bodies for account.nothing.tech auth endpoints → `/tmp/flow_bodies.jsonl` (contains tokens — file stays local, never commit).

## Live API probes

- `es-write-path-test.py` — proves the legacy-host card write envelope end to end against production: create → update (title/summary) → verify by list read-back → trash → hard delete one scratch card it creates itself. Needs `secrets/es_token.json`, `secrets/es_legacy_apikey.txt`, `secrets/es_config_dump.json` (claimKey). The recipe is in `notes/04-audio-download-and-card-writes.md`.

## Legacy patch-pipeline helpers

- `DexFilter.java`, `dex_filter.py` — framework.jar dex filtering used while building the `nt-services.jar` boot-classpath stub (procedure in `notes/02` §"Emulator capture stack").

## Secrets (gitignored `secrets/`)

- `secrets/spoof_and_sign.py` — mitmproxy addon that spoofs the device report to a Nothing A059 and re-signs every request with the embedded HMAC key (`x-app-signature` scheme in `notes/02`).

## Token caches (local only, never commit)

- `/tmp/es_token.json` — login result (access_token / id_token / device_secret). access_token is the only one the current ES API needs (30-day JWT).
- Refresh when `id_token`/`access_token` expires: `POST /api/v2/oauth2/token` with `grant_type=refresh_token&client_id=account-app-native&refresh_token=<from captures/*.flow>`.
