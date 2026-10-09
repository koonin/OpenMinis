# iOS 1.14 integration

This fork incorporates the official iOS changes between `4ef2900` and
`b4c0661`, preserving the local application identity and data safeguards.
Android application changes are excluded. The pre-integration revision is
`9286b4f`, retained by `codex/backup-before-ios114-20261009`.

## Integrated changes

- Account-scoped Codex model discovery, updated provider catalogs, Copilot
  support, model search, reasoning and request compatibility fixes.
- Official subagents and in-process scheduled prompts, programmatic prompt
  handling, cancellation and model-switch fixes.
- Incremental session-list caching, context estimation and compaction
  fallback, browser timeout recovery, speech input and rendering fixes.
- Backup, skill restore, File Provider, MCP and localization improvements.
- iSH pinned to `e6521d9cfe9cd48f19917fc3b23aea622ba358b4`; rebuild using
  `bash deps/build_ish.sh release`. Generated native binaries remain ignored.

## Local compatibility decisions

- Keep team `257ZBQBLS8`, `com.koon.minis`, `group.com.koon.minis`, local
  iCloud identifiers, the crowned-skull icon and the install entitlement gate.
- Enable the upstream APNs entitlement with the refreshed Push Notifications
  provisioning profile. The Debug install gate requires the signed app to
  contain `aps-environment=development` as well as the original App Group.
  The existing CloudKit sync path and remote-notification background mode
  remain unchanged; enabling push does not turn on iCloud sync.
- Preserve skill metadata when storage is temporarily unavailable. Keep
  App Group migration and mount-recovery backups; missing files never imply
  an authorized skill deletion.
- Keep local read-only `delegate_task` workers alongside official
  `subagent_task`. Neither worker generation may recursively delegate through
  the legacy tool. Both respect the Agents switch and stay out of user-facing
  session lists. Restore persists both `source` and official parent links.
- Keep the bounded context previews, structured handoffs and auxiliary usage
  accounting. Compaction failure budgets are per view model, not shared by
  simultaneous conversations. Offloaded-file reads do not create new copies.
- Retain GPT Image 2.5 image input, request validation and image-containing
  conversation export. Image selection belongs to the image-generation tool;
  the top-level Codex request remains a text-model request.
- Adopt complete environment/MCP credential backup support, but retain
  mandatory encryption for credential-bearing packages, including MCP inline
  headers. The UI defaults to encryption and rejects unsafe combinations.
- Exclude all standalone Swift scripts from the XCTest target. ContextPolicy
  tests import the production app module rather than compiling a duplicate
  implementation with missing AgentProvider types.

## Verification

- Signed iPhoneOS `build-for-testing` passed, including the app and extensions.
- Signature validation confirmed `group.com.koon.minis` in the signed app.
- The APNs follow-up signed device build passed. Both the embedded profile
  and signed app contain `aps-environment=development`, retaining the same
  App Group and iCloud container. Live background push delivery is not yet
  verified; iCloud sync settings were not changed.
- 136 standalone Swift scripts passed after using their required working
  directories and adapting source assertions to the preserved local policies.
- Six other scripts are not green: two require UIKit, two compare Android
  code that is outside this integration, and two contain stale official
  catalog/consent-source expectations. They are not counted as passes.
- Production AgentContextSupport tests passed 41 checks; recursive compaction
  handoff regression passed. The iOS MCP suites passed 19 tests.
- The pre-install skill database passed SQLite integrity checking and contained
  54 records. Backup files remain outside the repository.
- On the paired iPhone, all 21 selected XCTest cases passed: integration
  safeguards, GPT-6 Astra, GPT Image 2.5 and session-source backup restore.
- Normal launch found the original App Group skills directory with 54 entries.
  The app was updated in place without uninstalling it.

These checks do not establish live access to every provider or validate
remote-server backup transfers. XCTest and deliberate process termination can
leave stale launch markers; a reported previous-run marker is not evidence of
a new-version crash. The observed normal launch terminated with exit code 0.
