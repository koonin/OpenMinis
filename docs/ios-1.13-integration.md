# iOS 1.13 integration

Integrated on 2026-09-06, using the official increment from `09fc199`
(1.12) through `4ef2900` (1.13). Local starting point: `8d917f6`.

## Scope

1. iSH/kernel/terminal fixes (`2df21b6`), Provider/thinking/voice fixes
   (`421699d`), and the Chat/sync stability changes in `ada340b`.
2. Folder and Rclone backup/restore (`6c08b18`), including its shared Go
   sources, iOS build script, encryption, streaming ZIP writer and tests.
3. Remaining iOS UI/localization work in `ada340b`, locale helpers
   (`18bca81`), JIT regression script and build artifact ignores (`a8d6ef6`),
   and tracking iSH on master (`7414c0d`). Android source changes are excluded.

Some Provider and Chat code depends on the new localization and backup APIs,
so the integrated tree is validated together rather than treating each
upstream commit as independently buildable.

## Local compatibility decisions

- Keep team `257ZBQBLS8`, the `com.koon.minis` bundle identifiers, local
  entitlements/container identifiers, custom icons, scheduled-task setup,
  delegated workers and the hardened Apple Music implementation.
- Keep the existing iCloud backup implementation and view. The official
  re-added copies have no new executable behavior to adopt; the manager's
  official container identifier must not replace our own.
- Retain the existing audio ownership and background-expiry behavior.
  `BackupKeepAlive` acquires its own low-priority coordinator intent and
  releases only that intent. It yields when recording is already active;
  finite background time still applies in that case. Playback-start failures
  also release the intent.
- Preserve `ChatSession.source` in backup restore INSERT/UPDATE. A missing
  source in an older backup cannot clear an existing worker's identity.
- Keep the local XCTest target dependency; exclude all standalone Swift
  scripts from the synchronized XCTest sources.
- Route the new File Provider update marker through the local App Group
  helper, preserving the Personal Team guard.

## Native dependencies

The iSH pointer is `3f6384c70eefd1a370f121d3492a5f21f7767df9`, a descendant
of the previously pinned `19c690c`. Rebuild after updating submodules:

```sh
./deps/build_ish.sh release
bash deps/build_rclone_ios.sh
```

Rclone is pinned by `deps/rclone-mobile/go.mod` and `go.sum`. The local
build used `GOPROXY=https://goproxy.cn` because the default Go proxy timed
out; the mirror is a per-command override, with checksum verification kept
enabled. Both arm64 device and simulator Rclone slices built successfully.
Generated native libraries/frameworks remain ignored.

## Verification

- iPhoneOS Debug `build-for-testing` passed for the final integrated tree,
  including the app, extensions, unit tests and UI-test targets.
- All nine scripts under `src/ios/MinisTests/Standalone` passed on macOS.
- `BackupCryptoTests`: 27 passed against production crypto/format sources
  linked into a temporary macOS Swift package; only logging was stubbed.
- `BackupPackagingTests`: 15 passed against production blob/ZIP sources in
  that same host package.
- `BackupSessionSourceTests`: four passed using the production restore method
  extracted verbatim into a temporary SQLite host adapter. The checked-in
  tests also compile against the real ChatStore in the iPhoneOS test target.
- Model catalog verification: 193 providers, 7,248 entries, all 2,106
  normalized keys matched the reference resolution.

The full iPhoneOS XCTest suite was compiled, not executed on a phone.
The host checks do not replace device runtime validation. Simulator app
linking remains constrained by device-only iSH/FFmpeg artifacts. Actual
remote-server backup transfers and the recording/music/backup combinations
have not been exercised on a phone in this integration pass.
