---
title: Clipboard history
eyebrow: Privacy
summary: How Zerm captures, stores, and exports clipboard copies on this Mac.
---

Zerm keeps clipboard history on this Mac. Capture starts enabled; saving dictated text is
optional and off by default. History can be paused, and password-manager apps are excluded
by default. Confidential and transient pasteboard markers have separate controls.

History index and payloads are encrypted at rest with AES-GCM. The key stays in this Zerm
installation's Keychain. Pinned items bypass age and count retention. Clearing history can
keep pinned items, favourites, and tagged items. Optional clear-on-quit and clear-on-restart
settings remove stored entries; restart detection compares the system boot time saved at the
previous launch.

Export creates a ZIP archive with a versioned JSON index and one JSON representation blob per
item. It preserves item metadata, titles, pins, favourites, collection membership, and favourite
order. Import merges entries by content hash. An optional password encrypts the ZIP payload with
PBKDF2-HMAC-SHA256 and AES-GCM; without a password, the ZIP is unencrypted and should be stored
accordingly.

Retention choices can be set per content kind and are stored in settings. Per-kind enforcement
will connect when the history engine work lands; the current engine enforces the overall age and
count limits. The history panel is being built separately. Its open shortcut and menu entry call
a connection stub until that panel is merged. The Paste Next shortcuts likewise forward through
a marked runtime hook for the history engine integration.
