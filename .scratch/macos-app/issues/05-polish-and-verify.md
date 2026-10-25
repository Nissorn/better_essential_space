# 05 — Polish, bundle, verify

Status: ready-for-human
Type: task
Blocked by: 03, 04

## Summary

Final pass: independent review of the whole app (standards/spec/reliability per orchestrate-issues), error-state polish, app bundle verification (launch, Keychain prompts, audio playback), and a README that reflects the finished v1.

## Acceptance criteria

- [x] Independent review pass on the full tree; blocking findings fixed and re-reviewed (two rounds; final verdict SHIP — details in Comments)
- [x] The bundled `.app` launches on the orchestrator's machine and shows real Records end-to-end (user verified via in-app login 2026-10-25)
- [x] Token expiry → refresh → re-login paths exercised (live `refresh()` 200 with rotation + persistence 2026-10-25; re-login = the user's in-app Authflow login; unit tests cover 401-retry, still-401, single-flight, network failure)
- [x] README + spec updated to reflect reality

## Comments

- 2026-10-25 (round 1, independent reviewer subagent): verdict FIX-FIRST — 0 blocking, 4 major, 5 minor. Majors: (1) still-401-after-refresh wiped a valid session; (2) trusted-device re-login threw "did not ask for an OTP" forever (`authflow/login` returning `finished` unhandled); (3) no single-flight refresh — concurrent loads could double-spend the Refresh Token; (4) unknown `raw_type` strings threw during Card decoding, silently dropping Records. Minors: unbounded pagination, partial Keychain loss could mismatch keypair/registration, post-OTP failure dead-ended the login form, `macos/.build` + `dist` not gitignored, per-`AuthflowClient` URLSession never invalidated (skipped — negligible for one app-lifetime instance, reviewer concurred).
- 2026-10-25 (fixes): all 4 majors + minors 5-8 fixed (`ESError.hostUnauthorized`, `LoginStep` enum, `RefreshFlight` actor + `reload()` cancellation, lenient `.unknown` RawType decoding, 500-page cap, mint-both-halves device identity, split OTP error handling, `macos/.gitignore`). New `AppModelTests` (5 state-machine cases) with `ESClient` injectable. 57/57.
- 2026-10-25 (round 2, same reviewer, files re-read fresh): all 8 findings RESOLVED; verdict **SHIP**. One new minor introduced by the cancellation fix: a superseded load surfaced `URLError.cancelled` as a "Network request failed" alert. Fixed the same day: all three `send()`/refresh error wrappers rethrow `CancellationError` for `URLError.cancelled`; added the two noted test gaps (single-flight coalescing proves one exchange for two concurrent callers; refresh network failure keeps tokens). **59/59.**
