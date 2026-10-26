# Better Essential Space

An unofficial macOS client for Nothing's Essential Space: sign in with your Nothing account to read, listen to, and edit your voice Records — transcripts, summaries, topics, audio — on your Mac.

> [!IMPORTANT]
> This is a hobby project, not affiliated with or endorsed by Nothing Technology Ltd. It talks to undocumented, reverse-engineered APIs (research notes in [`notes/`](notes/)). Nothing may change or block them at any time, and using an unofficial client may violate their Terms of Service. Your account, your risk. The app writes to your Essential Space only when you edit a Record's title, summary, or main topics; it never creates or deletes anything.

## What works

- **Native sign-in** — email + password + OTP, the same Authflow the phone app uses. No browser, no token files. Your tokens live in your Mac's Keychain and refresh automatically.
- **Records** — browse your Essential Space: titles, dates, durations, summaries, main topics, full transcripts.
- **Audio** — tap Play to download a Record's recording with a progress bar; it plays as soon as it lands and stays cached on your Mac.
- **Inline editing** — click a title, summary, or main topic and type; changes save automatically and sync to the phone.
- **Collections** — the Collections you made on the phone, with counts and one-click filtering in the sidebar.
- **Search** — instant, client-side, across every text field of every Record (⌘F).
- **Export** — Copy as Markdown, or export one Record / everything as `.md` (File menu, ⌘E).
- **Instant start** — the last snapshot loads immediately and refreshes in the background.
- **A quiet, readable UI** — adaptive light/dark appearance (System / Light / Dark), gradient accents, Doto + Geist typography, copy-to-clipboard everywhere.
- **No servers, no telemetry** — the app talks directly to Nothing's endpoints; nothing passes through anyone else's hands.

## Requirements

- macOS 26 or later
- Xcode 26 (the SwiftUI app target needs the full Xcode toolchain; Command Line Tools alone build only the `BetterEssentialSpaceCore` library)

## Build & run

```zsh
git clone https://github.com/Nissorn/better_essential_space.git
cd better_essential_space/macos
./scripts/build-app.sh    # -> dist/BetterEssentialSpace.app (ad-hoc signed)
```

or from source during development:

```zsh
swift run                 # needs DEVELOPER_DIR pointed at Xcode
swift test                # full suite; no network (URLProtocol mocks)
```

Because you build it yourself, Gatekeeper never gets involved — no Developer ID, no notarization.

## Keys

The two shared Nothing app keys the client needs (the records-host `auth` key and the account `x-app-signature` HMAC key) are bundled in the source ([`EmbeddedKeys.swift`](macos/Sources/BetterEssentialSpaceCore/EmbeddedKeys.swift)). They are values extracted from Nothing's public APK — identical for every user, not personal credentials — published here so a fresh clone just works.

If Nothing rotates them, the app breaks until it's updated. You can fix it locally without waiting: write the new value (one plain-text line) into

```
~/.better-essential-space/legacy-api-key
~/.better-essential-space/account-signing-key
```

A file that exists always wins over the bundled key. Your account tokens and this install's device key never leave your Mac's Keychain.

## How the login works

Short version: the app reports an A059 Android device profile with a fresh EC P-256 keypair per install, runs the 5-step Authflow (device/report → login → OTP → authorize → token exchange), and signs requests with the same three header schemes the official client uses. The full reverse-engineering story is in [`notes/`](notes/) — start with [`notes/02-essential-space-api.md`](notes/02-essential-space-api.md).

## Project layout

- `macos/` — the app (Swift 6 package: `BetterEssentialSpaceCore` logic library + SwiftUI app + tests; see [`macos/README.md`](macos/README.md))
- `notes/` — reverse-engineering research (API, auth, data formats)
- `.scratch/` — local issue tracker and spec (development history)
- `docs/`, `GLOSSARY.md` — domain terms and working agreements

## License

MIT — see [LICENSE](LICENSE). Fonts (Doto, Geist, Geist Mono) are bundled under the SIL Open Font License 1.1.

Nothing, Essential Space, and related marks belong to Nothing Technology Ltd; this project is not affiliated with them.
