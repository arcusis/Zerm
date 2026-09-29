# Clipboard History

Clipboard History keeps copied items in an encrypted local store. It supports text, rich text, images, files, links, and other pasteboard content. Image text and QR or barcode values are indexed for search and shown in item details.

An open panel receives new copies, edits, removals, and clear operations immediately. History loads in pages as you browse. Image lists use encrypted thumbnails; original clipboard data loads when needed. Items larger than the configured maximum are skipped. Default maximum is 50 MB.

## Open and search

Open the floating panel with **Shift-Command-V** or choose **Open Clipboard History** from the menu bar. The shortcut can be changed in Settings. Search matches item text, titles, source apps, tags, OCR text, and QR or barcode values. Add `kind:`, `app:`, or `tag:` tokens to filter results.

Select one or more items to paste, copy, merge, or delete them. The command palette opens with **Command-K**. It includes text transforms, editing, splitting text into lines, tag actions, pinning, favourite ordering, paste-sequence controls, and history clearing. Transforms save their result as a new item.

The panel shows compact rows beside a large preview of the selected item. Turn on **Details** to show source app, type, size, last copy time, copy count, and tags under the preview. Active type, app, and tag filters appear below search; clear filters while keeping your search text.

Use **Return** to paste the selected item, **Option-Return** to paste plain text, **Command-1–9** to paste one of the first nine visible items, and **Command-K** to open the command palette. Arrow keys move selection. More history loads as you scroll; new copies update the open panel while preserving your selection.

Panel settings control its position, paste-on-click and double-click behavior, quick-paste badges, favourite ordering, and confirmation before clearing. The Details pane shows source app, dates, size, tags, and recognized image text.

## Retention, storage, and privacy

Storage settings show the current encrypted store size and let you set total, per-kind, and per-item size limits. When a size limit is reached, older unpinned items are removed first; ordinary items are removed before favourites and tagged items. Per-kind age retention and the maximum item count also apply during capture and scheduled cleanup.

History can be cleared on quit, restart, screen lock, sleep, or once daily at a chosen local time. Clear operations can preserve favourites and tagged items. App exclusions stop future captures from those apps. Confidential and transient pasteboard types can also be ignored. Link previews can be disabled; when enabled, link titles and images are fetched from the linked site.

## Sounds

Copy, paste, delete, and selection actions each support no sound, a macOS system sound, or a chosen audio file. Each action has its own volume and preview control.

## Settings and privacy

Clipboard History can be paused from Settings or the menu bar. Settings control which apps and confidential or transient content are ignored, whether dictated text is saved, and retention by item kind. Pinned, favourited, and tagged items can be protected from cleanup or clearing.

Export writes a ZIP archive. An optional password encrypts the archive; without one, the archive is unencrypted. Import merges archive entries into the current history.
