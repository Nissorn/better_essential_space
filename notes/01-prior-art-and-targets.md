# Prior art & targets (researched 2026-10-24)

Findings from the initial desk research, before any APK analysis. Sources inline.

## TL;DR

No public reverse engineering of the Essential Space **cloud API** or **Nothing account auth flow** exists. All community projects reimplement the experience locally and never talk to Nothing's backend. This project's cloud-client path is therefore genuine RE work.

## Known packages (from buttonoo's how-it-works doc)

- `com.nothing.ntessentialspace` — the Essential Space app itself ([Google Play](https://play.google.com/store/apps/details?id=com.nothing.ntessentialspace), [APKMirror](https://www.apkmirror.com/apk/nothing-technology-limited/essential-space/))
- `com.nothing.ntessentialrecorder` — recorder companion
- `com.essentialintelligence` — likely the AI/processing package

Source: [buttonoo docs/how-it-works.md](https://github.com/bractstudio/buttonoo/blob/main/docs/how-it-works.md). That project only remaps the Essential Key hardware events (keyCode 0 / KEYCODE_UNKNOWN, scan codes 250/296 observed) and does not touch Essential Space data.

## Community projects (all local-first, none use the cloud API)

- [rKyzen/Essential_Space_Lite](https://github.com/rKyzen/Essential_Space_Lite) — Jetpack Compose reimplementation; SQLite local, OpenRouter for AI, "zero remote database synchronization"
- [mirarr-app/Gessential](https://github.com/mirarr-app/Gessential) — Essential Space for non-Nothing phones; transcription via Gemini API
- [LainsMain/CrucialSpace](https://github.com/LainsMain/CrucialSpace) — share-to-capture mimic
- [KoukeNeko/EssentialKeyTools](https://github.com/KoukeNeko/EssentialKeyTools) — Essential Key remapping

## Official API status

Nothing has published no API; community is asking for one: [nothing.community — Essential Space API thread](https://nothing.community/d/48395-essential-space-api). Ecosystem index: [spike0en/awesome_nothing](https://github.com/spike0en/awesome_nothing).

## Open questions for the RE phases

1. Does the Android app actually sync content to a Nothing cloud backend? (base URLs, endpoints)
2. What does login with a Nothing account look like on the wire (OAuth variant? token exchange? device binding?)
3. Is there request signing / attestation beyond bearer tokens?
4. What are the content models (screenshot, voice note, AI summary, collection) and sync protocol?
