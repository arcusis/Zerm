---
title: Clipboard history
eyebrow: Privacy
summary: How Zerm captures, protects, and retains clipboard copies on this Mac.
---

Zerm stores clipboard history locally. Capture starts enabled; saving dictated text is optional
and off by default. History can be paused, and password-manager apps are excluded by default.
Confidential and transient pasteboard markers have separate controls.

History index and payloads are encrypted at rest with AES-GCM. The key stays in this Zerm
installation's Keychain. Retention can be set by content kind, from one to 365 days, unlimited,
or never. Never prevents capture. Expired entries are cleaned hourly. Pinned entries bypass
age and item-count limits. Favorites and tagged entries follow their keep settings when history
is cleared or retention runs.

Clipboard History settings include per-kind retention, sort order, Copy & Merge on double ⌘C,
and its separator and clipboard-update options. Export creates a ZIP archive. An optional
password encrypts the archive; without one, the archive is unencrypted.

The history panel is still being built. Its open shortcut and menu entry remain connection stubs.
The Paste Next shortcuts select and paste successive non-favorite items in copy order.
