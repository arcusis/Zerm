# Clipboard History

Clipboard History keeps copied items in an encrypted local store. It supports text, code, rich text, images, files, links, and other pasteboard content. Code snippets are detected from text structure and shown with syntax highlighting; pasted text stays unchanged. Image text and QR or barcode values are indexed for search and shown in item details.

An open panel receives new copies, edits, removals, and clear operations immediately. History loads in pages as you browse. Image lists use encrypted thumbnails; original clipboard data loads when needed. Items larger than the configured maximum are skipped. Default maximum is 50 MB.

The main window has **Clipboard → History**. History is a searchable library with item-kind, source-app, and date filters, sorting, multi-selection, a rich preview, and usage summaries. Select items to copy them back to the clipboard, pin or favourite them, delete them, or export them as an archive. This page copies items; use the floating panel when you want to paste into the active app.

## Open and search

Open the floating panel with **Shift-Command-V** or choose **Open Clipboard History** from the menu bar. The shortcut can be changed in Settings. Search matches item text, titles, source apps, OCR text, and QR or barcode values. Add `kind:` or `app:` tokens to filter results.

Select one or more items to paste, copy, merge, or delete them. The command palette opens with **Command-K**. It includes text transforms, editing, splitting text into lines, pinning, favourite ordering, paste-sequence controls, and history clearing. Transforms save their result as a new item. Search accepts `kind:` and `app:` tokens in both the panel and main-window library.

The floating panel has a labeled, collapsible sidebar, a history list, and a large preview. Use the sidebar to switch between all items, favourites, item kinds, and source apps. Date and sort controls sit above the list with search, pinning, and commands. The preview toolbar provides item actions and controls for details and preview visibility. Details show the source app, type, kind-specific metadata, and absolute copy time.

Use **Return** to paste the selected item, **Option-Return** to paste plain text, **Command-1–9** to paste one of the first nine visible items, and **Command-K** to open the command palette. Arrow keys move selection; Tab moves focus across panel controls. The footer names the app that was active when the panel opened. More history loads as you scroll; new copies update the open panel while preserving your selection.

Panel settings control its position, paste-on-click and double-click behavior, quick-paste badges, favourite ordering, and confirmation before clearing. The Details pane shows source app, dates, size, and recognized image text.

## Retention, storage, and privacy

Storage settings show the current encrypted store size and let you set total, per-kind, and per-item size limits. When a size limit is reached, older unpinned items are removed first; ordinary items are removed before favourites. Per-kind age retention and the maximum item count also apply during capture and scheduled cleanup.

History can be cleared on quit, restart, screen lock, sleep, or once daily at a chosen local time. Clear operations can preserve favourites. App exclusions stop future captures from those apps. Confidential and transient pasteboard types can also be ignored. Link previews can be disabled; when enabled, link titles and images are fetched from the linked site.

## Sounds

Copy, paste, delete, and selection actions each support no sound, a macOS system sound, or a chosen audio file. Each action has its own volume and preview control.

## Settings and privacy

Clipboard History can be paused from Settings or the menu bar. Settings control which apps and confidential or transient content are ignored, whether dictated text is saved, and retention by item kind. Pinned and favourited items can be protected from cleanup or clearing.

Export writes a ZIP archive of clipboard history. Version 1 archives remain importable. An optional password encrypts the archive; without one, the archive is unencrypted.
