#!/usr/bin/env bash
# Archives the app and uploads it to TestFlight. One-time setup (the App Store
# Connect app record, the .p8 API key in ~/.appstoreconnect/private_keys) is
# not here.
#
#   ASC_ISSUER_ID=<uuid> ios/deploy/push.sh          # Debug -> beta
#   ASC_ISSUER_ID=<uuid> ios/deploy/push.sh Release   # prod  -> release
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID — App Store Connect > Users and Access > Integrations}"
ASC_KEY_ID="${ASC_KEY_ID:-5Q2C7V23A4}"
# ~/.appstoreconnect/private_keys is where Xcode itself keeps API keys, so a key
# added through Xcode is found with no configuration. ~/private_keys is altool's
# older location, checked second.
KEY=""
for d in "$HOME/.appstoreconnect/private_keys" "$HOME/private_keys"; do
  [ -f "$d/AuthKey_$ASC_KEY_ID.p8" ] && KEY="$d/AuthKey_$ASC_KEY_ID.p8" && break
done
[ -n "$KEY" ] || { echo "no AuthKey_$ASC_KEY_ID.p8 in ~/.appstoreconnect/private_keys or ~/private_keys" >&2; exit 1; }

# The build number has to trace back to a commit, or a TestFlight build that
# misbehaves can't be tied to the code that produced it.
[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty — commit first" >&2; exit 1; }
BUILD="$(git rev-list --count HEAD)"
SHA="$(git rev-parse --short HEAD)"

ARCHIVE="$(mktemp -d)/GarageDoor.xcarchive"
xcodegen generate

xcodebuild archive \
  -project GarageDoor.xcodeproj \
  -scheme GarageDoor \
  -configuration "$CONFIG" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$BUILD"

# -exportArchive with destination=upload does the upload itself, so a failure
# here is a failed upload, not a stale .ipa sitting around looking successful.
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist deploy/ExportOptions.plist \
  -exportPath "$(dirname "$ARCHIVE")/export" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "uploaded $CONFIG build $BUILD ($SHA) — processing takes ~5-15 min before it appears in TestFlight"
