# 04 — M2: in-app Authflow login

Status: ready-for-human
Type: task
Blocked by: 02

## Summary

Replace the M1 token-import bootstrap with a real in-app login for fresh installs: email + password → OTP entry, native HTTP against `account.nothing.tech`, per spec.md. If issue 01 reveals that reading Records requires an SSO-exchanged token, this issue also covers obtaining that token at login (client_id from issue 01 findings).

## Scope

- Authflow sequence: `POST /api/v2/device/report` (A059 profile, fresh EC P-256 keypair from CryptoKit, public key uploaded) → `POST /api/v2/authflow/login` → `POST /api/v2/authflow/login/state/input` (OTP) → `GET /api/v2/oauth2/authorize` with `x-idp-session` (parse `code` from the 302 Location) → `POST /api/v2/oauth2/token` (PKCE).
- All requests signed: `x-app-signature` (app HMAC key) and `x-device-signature` (device keypair) per notes/02.
- Device identity + keypair persisted in Keychain; token set stored as in M1.
- Login UI: email/password form → OTP form → error states; replaces/extends the BootstrapView.

## Acceptance criteria

- [x] Full Authflow login works against the live service from the app — user-verified 2026-10-25 (email + OTP login succeeded in the shipped app)
- [x] Unit tests for each step with mocked responses, including the signing headers' construction (7 new tests, 50/50 total)
- [x] M1 import remains available as a fallback path (disclosure on the login screen)

## Comments

- 2026-10-25 (orchestrator): the `x-device-signature` scheme was not in notes/02 beyond "EC P-256". Cracked it from the User Center Dart AOT (blutter) + verified byte-for-byte against all three signed requests in `captures/nothing-login2.flow`: payload `"<epoch ms>." + <raw body>`, ECDSA P-256 SHA-256, IEEE P1363 `r||s`, base64url **with** padding. Public key upload format = SPKI DER base64 (91 bytes). Documented in notes/02 §"Request signing".
- 2026-10-25 (orchestrator): ran a live `device/report` from the Mac with the shipped code — **200 OK, `device_id` persisted** (A059 profile accepted, both signatures valid). The app's Keychain already holds this identity, so the in-app login skips straight to `authflow/login`.
- Implementation: `macos/Sources/BetterEssentialSpaceCore/Authflow.swift` (`AuthflowClient`, `DeviceIdentity`, `DeviceProfile`, PKCE), `AuthSigning.deviceSignature`, `LoginView` replacing `BootstrapView`, `AppModel.logIn/submitOTP/cancelLogin`.
- 2026-10-25 (user): completed the email + OTP login in the app successfully. Issue 04 done.
