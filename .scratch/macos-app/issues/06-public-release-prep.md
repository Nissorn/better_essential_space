# 06 — Public release preparation (future — not v1)

Status: needs-triage
Type: task
Blocked by: 05

## Summary

The owner wants to publish the app publicly in a later version. v1 is personal-use. This issue collects the decisions that public release forces, so they are not silently assumed:

- **Signing-key distribution:** the login flow requires Nothing's app HMAC key (extracted from their APK). Embedding it in a public binary means anyone can extract it; proxying through a server means running infrastructure and the user's credentials pass through it. Needs a real decision.
- **Naming/trademark:** "Better Essential Space" vs Nothing's marks; bundle id may move to a domain the owner controls.
- **Distribution channel:** notarization, Developer ID, or Homebrew/casket-style side-load.
- **ToS/risk:** unofficial client against an unpublished API; account-ban risk for users.

## Comments
