# Clipboard History

Clipboard History keeps copied items in an encrypted local store. It supports text, rich text, images, files, links, and other pasteboard content. Image text and QR or barcode values are indexed for search and shown in item details.

## Open and search

Open the floating panel with **Shift-Command-V** or choose **Open Clipboard History** from the menu bar. The shortcut can be changed in Settings. Search matches item text, titles, source apps, tags, OCR text, and QR or barcode values. Add `kind:`, `app:`, or `tag:` tokens to filter results.

Select one or more items to paste, copy, merge, or delete them. The command palette opens with **Command-K**. It includes text transforms, editing, splitting text into lines, tag actions, pinning, favourite ordering, paste-sequence controls, and history clearing. Transforms save their result as a new item.

Panel settings control its position, paste-on-click and double-click behavior, quick-paste badges, favourite ordering, and confirmation before clearing. The Details pane shows source app, dates, size, tags, and recognized image text.

## Settings and privacy

Clipboard History can be paused from Settings or the menu bar. Settings control which apps and confidential or transient content are ignored, whether dictated text is saved, and retention by item kind. Pinned, favourited, and tagged items can be protected from cleanup or clearing.

Export writes a ZIP archive. An optional password encrypts the archive; without one, the archive is unencrypted. Import merges archive entries into the current history.
