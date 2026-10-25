# 06 — Public release preparation

Status: ready-for-human (creating the GitHub repo and pushing is the owner's action)
Type: task

## Summary

Publish the app as an open-source GitHub repo: users build from source and log in with their own Nothing accounts.

Decisions (owner, 2026-10-25):

- **Key distribution:** publish both APK-derived app keys in-source (`EmbeddedKeys.swift`); `~/.better-essential-space/` files remain as optional overrides for rotations. Personal tokens/captures stay out of the repo (secrets policy amended in spec.md).
- **Naming:** keep "Better Essential Space" (trademark risk accepted by the owner).
- **Distribution channel:** source builds only — no Developer ID, no notarization; a locally built app never hits Gatekeeper.
- **ToS/risk:** README carries the unofficial / not affiliated / read-only / account-ban-risk disclaimer.

## Delivered

- [x] Git history rewritten to GitHub noreply email (`85168988+Nissorn@users.noreply.github.com`); tags v1.0.0/v2.0.0 re-pointed; local `user.email` set for future commits
- [x] `EmbeddedKeys.swift` + `RuntimeSecrets` fallback (absent file → bundled key; existing-but-empty override → typed error); Login/Settings copy updated
- [x] Root `README.md` (disclaimer, build steps, keys, project layout) + `LICENSE` (MIT)
- [x] `.zcode/` untracked and gitignored; app version bumped to 2.1.0 in build-app.sh
- [x] Tests updated for the fallback contract — 58/58 green; dist app rebuilt

## Comments

- 2026-10-25 — repo hygiene verified before publishing keys: `captures/`, `secrets/`, `notes/jadx/`, `apks/` were never committed in any commit; no long token-like strings in tracked files; test fixtures are synthetic.
- 2026-10-25 — remaining owner action: create the GitHub repo and `git push` (plus `git push --tags`). Optional later: GitHub Actions CI, a Homebrew tap, screenshots in the README.
