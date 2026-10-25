# 03 — Records list, detail, transcripts, audio playback

Status: ready-for-human
Type: task
Blocked by: 01, 02

## Summary

Build the actual content experience on the real read path from issue 01 (notes/03): the sidebar list of Records, the detail view with Transcript text, and audio playback **deferred** (Firebase Storage 403s for non-genuine clients — see notes/03 "Audio files"; revisit in a later issue per spec Q13).

## Acceptance criteria

- [ ] Records fetched via the legacy card list (Bearer + timestamp + auth header per notes/03), decoded into typed models matching the observed schema
- [ ] Sidebar list shows Records (title, date); detail view shows summary + Transcript (from the TRANSCRIPTION resource), duration/size from RECORDING metadata
- [ ] Pagination handled (`page_no` / `hasNextPage`)
- [ ] Error and empty states; tests for the decoders against a redacted fixture derived from `secrets/fixtures/card_list_sample.json`
- [ ] Audio playback: NOT in this issue (deferred; hypotheses to revisit listed in notes/03)

## Comments
- 2026-10-25 — Delivered together with issue 02: Records list (title/date/duration) + detail (summary + inline Transcript, text-selectable), pagination loop over `hasNextPage`, newest-first ordering, empty/error states, decoder tests against the redacted fixture (shape from secrets/fixtures/card_list_sample.json). Audio playback deferred per spec (Firebase Storage 403s — notes/03). Launched end-to-end with the real account: token seeded into Keychain, app opened. Status: ready-for-human.
- 2026-10-25 (follow-up, user feedback): the phone app's "Main topic" section was missing. Found the data in the previously-ignored `card_analysis` payload sibling: `MEETING_MAIN_TOPIC` (77 entries across the account's cards, `metadata` = JSON `{title, content}`), plus `MEETING_EMOTIONAL_SUMMARY` (plain-string tone line) and `meeting_speakers` (speaker descriptions). Added `CardAnalysis`/`MeetingSpeaker` models, `Record.mainTopics`/`emotionalSummary`/`speakers`, and a detail section with wrapping chips + expandable topic content + Speakers section. Fixture + tests extended (all green). Relaunched.
