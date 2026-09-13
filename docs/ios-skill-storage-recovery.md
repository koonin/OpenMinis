# iOS skill persistence and device deployment

The September 2026 device build used `CODE_SIGN_ENTITLEMENTS=` even though its
provisioning profile supported `group.com.koon.minis`. This stripped App Group
access and selected `Library/Application Support/PersonalTeamShared` instead.
`SkillStore.loadSkills()` then treated unreadable files as deletion, discarding
database rows. Old shared-container data must not be assumed deleted.

## Safeguards

- Build with the project's entitlements. `scripts/build_install_ios.sh` checks
  the actual signed App Group before installation and fails closed if absent.
- Before stores open, copy missing `MinisFileProvider` and `MinisConfig` files
  from the fallback to the App Group. Existing destination files win; source
  copies remain for manual conflict recovery. Never move or delete the fallback.
- Mark successful migration in the fallback so subsequent launches cannot
  resurrect files intentionally deleted after migration. Failed migrations
  retain source data and retry on the next process launch.
- Preserve skill DB rows, usage counters and enable settings on read failure.
  Unavailable skills are not advertised to the model until a reload can read
  their files. Explicit UI/remote deletion still removes them. A shell deletion
  alone no longer implicitly removes the DB record or publishes a cloud delete.
- Before replacing a real rootfs mount directory, snapshot it under
  `MinisConfig/mount-recovery/<UUID>` and merge missing files. On error, keep the
  original directory and do not mount over it. Conflicts remain in the snapshot.

## Device recovery verification

Keep recovery copies outside the repository. Before deployment, back up skills
and `skills.db`. On the first entitlement-restoring update, install without
launching, back up the now-accessible App Group, then launch. Compare the union
of skill IDs and verify complete file contents for newly installed skills.
Do not reinstall third-party packages or execute their instructions just to
recover their metadata. If a skill is absent from the shared container, restore
only its exact known source backup into a previously absent skill directory.

Tests cover non-overwriting migration, retained backups, retry after failure,
symlink safety, no resurrection after success, and DB retention/recovery with
explicit deletion still honored.
