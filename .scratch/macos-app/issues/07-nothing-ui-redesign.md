# 07 — v2: Nothing-style UI redesign

Status: ready-for-human
Type: task
Blocked by: (none — v1 tagged)

## Summary

Redesign the app's UI around the "vibe-nothing-ui-design" language (community Nothing-inspired design system, MIT; its SPEC.md is the contract): monochrome dark-first, single signal-red accent, black↔white inversion for active states, 1px hairlines, no shadows/gradients, Doto dot-matrix numerals, Geist UI text, Geist Mono uppercase labels, dotted background field. Translated to a native SwiftUI design system — the web CSS itself is not used.

## Decisions (per SPEC.md, orchestrator-set 2026-10-25)

- Dark-first, single theme (spec: "dashboards always dark"); no light theme in v2.
- Fonts bundled in the app (Doto, Geist, Geist Mono — SIL OFL 1.1, license file included). This is a font asset, not a code dependency; the zero-third-party-dependency rule (Swift packages) still holds.
- Whole app restyled in one pass (login, records list/detail, settings) — a half-restyled app reads as two apps.

## Scope

- `DesignSystem.swift` (tokens + typography + button styles + hairlines + dot-field background), font loading at launch.
- Package resources + `build-app.sh` ship the fonts.
- All screens restyled: LoginView, ContentView (sidebar + detail), RecordRow, RecordDetail, SettingsScreen, RootView alert/loading.

## Acceptance criteria

- [x] App launches dark, monochrome, no system-tinted controls visible in the main flows (`vibrantDark` appearance + `.preferredColorScheme(.dark)` + hidden scroll backgrounds)
- [x] Numerals (dates, durations, counts) render in Doto; labels/headers in Geist Mono uppercase; body in Geist (fonts registered at launch, resolution verified via CoreText probe)
- [x] Red appears only as signal (error text / missing refresh token), never on buttons or selection
- [x] Active/selected states invert black↔white (sidebar selection, primary buttons); separators are 1px hairlines; no shadows/gradients
- [x] 59/59 tests still pass (UI-only change) and the bundled .app relaunches cleanly

## Comments

- 2026-10-25 (orchestrator): delivered in one pass — `DesignSystem.swift` (palette, Doto/Geist/Geist Mono typography, `InvertedButtonStyle`/`OutlineButtonStyle`, `NDField`, `Hairline`, `DotFieldBackground`, `NDLabel`), fonts bundled under `Resources/Fonts` with the SIL OFL license, `build-app.sh` ships the SPM resource bundle. All screens restyled: RootView (dark canvas + dot field), LoginView (underlined fields, inverted Continue, Doto OTP entry), ContentView (inverted sidebar selection, Doto numerals in rows/detail, mono uppercase section headers, outline copy buttons), SettingsScreen (mono data rows, signal-red only for the missing-token state). Terminal cannot screenshot (no screen-recording permission) — visual sign-off belongs to the user.
- 2026-10-25 (user, round 1 review): design rejected — text too small, dark-on-dark unreadable, not minimal, no gradients, no light mode. Redesigned via the hallmark skill's redesign flow: adaptive scheme-dynamic tokens (System/Light/Dark picker in Settings), gradient canvas + accent-gradient primary buttons, card-based detail, body 15pt with line spacing, Doto restricted to display-only (the small dot-matrix meta was the main legibility killer), dates forced to en_US (fixed "2569 BE").
- 2026-10-25 (user, round 2 review): overall approved. One bug found: the Settings toolbar button was dead (legacy `showSettingsWindow:` selector) — replaced with SwiftUI's `openSettings` environment action; Cmd-, had worked all along. **Issue 07 done; shipped as v2.0.0.**
