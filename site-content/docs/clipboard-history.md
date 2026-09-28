---
title: Clipboard history
eyebrow: Privacy
summary: How Zerm captures and protects clipboard copies on this Mac.
---

Zerm's clipboard history stores copies locally so they can be searched and pasted again.
Nothing is sent off this Mac. History capture is enabled by default; dictation capture is
off by default.

Zerm skips copies marked transient, concealed, or automatically generated. It also skips
copies from 1Password, Bitwarden, Keychain Access, and Apple Passwords by default. The
history can be paused globally, for a set time, or for the next copy. Excluded apps and
retention limits are configurable through the Clipboard History settings API.

History metadata and each clipboard payload are encrypted with AES-GCM. The encryption
key is held in this Zerm installation's Keychain, and encrypted files live under Zerm's
Application Support folder. Pinned items do not expire or count toward the item limit.
Clearing history keeps pinned items unless they are explicitly included.

Zerm's transient dictation paste and clipboard restoration are marked and skipped by
history capture. Saving dictated text to history is optional and starts turned off.

The history panel and settings controls are not part of this release yet.
