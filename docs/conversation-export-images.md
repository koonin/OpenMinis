# Conversation export with attachments (2026-09-09)

## Behavior

- Export remains a ZIP containing `conversation.json` or `conversation.txt`.
  TXT exports also include `conversation.md` for Markdown readers with local
  image support. Extract the entire archive before opening it.
- Local media references, tool result images/browser snapshots, inline Markdown
  image/file links, and user attachment XML paths are copied into `attachments/`.
  The transcript uses archive-relative paths; `attachments.json` records the
  mapping and `README.txt` records unbundled references.
- Each selected session resolves its own workspace/attachments. Shared file
  references use the shared root; no other sessions are searched. Symlinks and
  traversal outside these roots, directories and unreadable files are rejected.
- Repeated references share one copied file; different files with the same
  original name receive distinct archive names. Copies are filesystem-based,
  not base64 embedded in the transcript.
- Remote/data-URL images are not downloaded/materialized. Unsupported image
  references and missing local files remain visible with warnings. Reference-
  style Markdown and HTML images are not currently resolved by the inline-link
  collector. This is a user-facing conversation export, not a full backup or
  a guarantee that every original tool-result body is retained (existing text
  truncation remains).

## Crash fix

The supplied 20:45 crash reports identify `DocumentExportPicker` passing a
missing ZIP to `UIDocumentPickerViewController`. UIKit's default exporting
initializer **moves** the original file; the preview kept that now-stale URL.

The picker now uses `asCopy: true`, with readable-file checks both on action and
at controller creation. Missing files display a recovery message rather than
constructing the picker. Following the SwiftUI UI Patterns skill, share/save
use one item-driven destination rather than independent boolean sheets.

ZIP creation has a single synchronous coordinator result instead of resuming a
continuation in two separate callbacks. Archive failure no longer silently
falls back to text without attachments; it displays an error.

## Validation

Eight export helper tests run against production sources in a macOS Swift
package: byte-identical copies, deduplication, Markdown/XML rewrites, encoded
and spaced paths, session isolation, traversal/symlink rejection, missing and
remote warnings, stale-file checks, and real ZIP listing/extraction/re-export.
Together with the existing 12 model tests: 20 passed.

An iPhoneOS `build-for-testing` build validates app integration. On-device UI
verification (save twice, share after saving, missing ZIP while preview remains
open) and the user's actual conversation export still require an installed build.
