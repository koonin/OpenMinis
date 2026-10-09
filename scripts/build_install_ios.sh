#!/bin/bash
# Device build/install with mandatory App Group and push entitlement gates.
# Usage: bash scripts/build_install_ios.sh DEVICE_ID [DERIVED_DATA_PATH]
set -euo pipefail
device_id="${1:?Pass the paired iPhone device identifier}"
derived_data="${2:-/tmp/OpenMinisDerived-ios113}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
signing_check_dir="$(mktemp -d /tmp/openminis-signing-check.XXXXXX)"

# Never clear CODE_SIGN_ENTITLEMENTS to get past a provisioning error: doing
# so silently switches persistent skills/memory to the fallback container.
xcodebuild -quiet -project "$repo_dir/src/ios/Minis.xcodeproj" -scheme Minis \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" -allowProvisioningUpdates build
app_path="$derived_data/Build/Products/Debug-iphoneos/Minis.app"
codesign --verify --deep --strict "$app_path"
codesign -d --entitlements :- "$app_path" > "$signing_check_dir/entitlements.plist"
app_group=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$signing_check_dir/entitlements.plist")
if [[ "$app_group" != 'group.com.koon.minis' ]]; then
  echo 'Refusing installation: the signed app is missing the required App Group.' >&2
  exit 1
fi
push_environment=$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$signing_check_dir/entitlements.plist" 2>/dev/null || true)
if [[ "$push_environment" != 'development' ]]; then
  echo 'Refusing installation: the signed Debug app is missing development push entitlement.' >&2
  exit 1
fi
xcrun devicectl device install app --device "$device_id" "$app_path"
xcrun devicectl device process launch --device "$device_id" com.koon.minis
