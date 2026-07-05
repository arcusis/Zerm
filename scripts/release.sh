#!/bin/bash
set -euo pipefail

# Builds the Developer ID signed + notarized DMG that gets uploaded to GitHub Releases.
#
# One-time setup — store notarization credentials in the login keychain:
#   xcrun notarytool store-credentials zerm-notary \
#     --key ~/.appstoreconnect/private_keys/AuthKey_32D372QBLD.p8 \
#     --key-id 32D372QBLD \
#     --issuer <ISSUER-UUID>
#   (Issuer UUID: App Store Connect -> Users and Access -> Integrations -> App Store Connect API)
#
# Usage:
#   scripts/release.sh                   # build + sign + notarize + staple
#   SKIP_NOTARIZE=1 scripts/release.sh   # dry run: build + sign only

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Arcusis LTD (F9Z784RA6D)}"
TEAM_ID="${TEAM_ID:-F9Z784RA6D}"
NOTARY_PROFILE="${NOTARY_PROFILE:-zerm-notary}"
DERIVED_DATA="$REPO_ROOT/.release-build"
WORK_DIR="$DERIVED_DATA/package"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Zerm.app"

VERSION=$(sed -n 's/.*MARKETING_VERSION = \([0-9][0-9.]*\);.*/\1/p' "$REPO_ROOT/Zerm.xcodeproj/project.pbxproj" | head -1)
DMG_NAME="Zerm_${VERSION}_aarch64.dmg"
DMG_PATH="$REPO_ROOT/$DMG_NAME"

echo "==> Releasing Zerm $VERSION"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "error: notarytool credentials profile '$NOTARY_PROFILE' not found or invalid."
        echo "Run the one-time setup documented at the top of this script."
        exit 1
    fi
fi

echo "==> Building Release configuration"
rm -rf "$DERIVED_DATA"
# LOCAL_BUILD keeps runtime behavior identical to previously shipped builds
# (CloudKit off, UserDefaults key store) — the entitlements it requires need no
# provisioning profile, which Developer ID signing alone cannot provide.
xcodebuild -project "$REPO_ROOT/Zerm.xcodeproj" -scheme Zerm -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64 \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_ENTITLEMENTS="$REPO_ROOT/Zerm/Zerm.local.entitlements" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
    build

[ -d "$APP_PATH" ] || { echo "error: $APP_PATH not found after build"; exit 1; }

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "==> Notarizing app"
    mkdir -p "$WORK_DIR"
    ditto -c -k --keepParent "$APP_PATH" "$WORK_DIR/Zerm.zip"
    xcrun notarytool submit "$WORK_DIR/Zerm.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
fi

echo "==> Creating DMG"
STAGING="$WORK_DIR/dmg-staging"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
ditto "$APP_PATH" "$STAGING/Zerm.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Zerm $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "==> Notarizing DMG"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "==> Gatekeeper assessment"
spctl -a -vv -t exec "$APP_PATH" || [ "${SKIP_NOTARIZE:-0}" = "1" ]
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH" || [ "${SKIP_NOTARIZE:-0}" = "1" ]

echo ""
echo "Done: $DMG_PATH"
echo "Upload with: gh release upload v$VERSION $DMG_NAME"
