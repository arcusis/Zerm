#!/bin/bash
set -euo pipefail

# Builds the Developer ID signed + notarized DMG that gets uploaded to GitHub Releases.
#
# One-time setup — store notarization credentials in the login keychain:
#   xcrun notarytool store-credentials zerm-notary \
#     --key ~/.appstoreconnect/private_keys/AuthKey_<KEY-ID>.p8 \
#     --key-id <KEY-ID> \
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

# Xcode's CodeSignOnCopy re-signs each embedded framework's *main* binary with our
# Developer ID, but NOT the executables nested inside them. Sparkle in particular
# ships its XPC services, Autoupdate helper and Updater.app ad-hoc signed via SPM.
# Notarization rejects any ad-hoc / hardened-runtime-less nested code, and at launch
# dyld's library validation aborts with "different Team IDs" on a downloaded copy.
# So re-sign every nested Mach-O bottom-up (deepest first) before sealing the app.
echo "==> Re-signing nested code inside-out (Developer ID + hardened runtime)"
# Collect nested bundles plus loose Mach-O helpers (e.g. Sparkle's Autoupdate),
# then sign deepest paths first so inner bundles are sealed before their parents.
NESTED_BUNDLES=$(find "$APP_PATH/Contents/Frameworks" \
    \( -name "*.xpc" -o -name "*.app" -o -name "*.framework" \) -print)
NESTED_MACHO=$(find "$APP_PATH/Contents/Frameworks" -type f ! -name "*.dylib" \
    -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print)
SIGN_LIST=$(printf '%s\n%s\n' "$NESTED_BUNDLES" "$NESTED_MACHO" \
    | awk 'NF { print length"\t"$0 }' | sort -rn | cut -f2- | awk '!seen[$0]++')
while IFS= read -r ITEM; do
    [ -n "$ITEM" ] || continue
    # Preserve each helper's own entitlements; only the outer app gets ours.
    codesign --force --options runtime --timestamp \
        --preserve-metadata=entitlements --sign "$SIGN_IDENTITY" "$ITEM"
done <<SIGN_EOF
$SIGN_LIST
SIGN_EOF

echo "==> Re-sealing app bundle"
codesign --force --options runtime --timestamp \
    --entitlements "$REPO_ROOT/Zerm/Zerm.local.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP_PATH"

echo "==> Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Guard against the failure that shipped in 2.1.3: an ad-hoc (or wrong-team)
# signature passes `--deep --strict` because ad-hoc is itself valid, yet dyld's
# library validation aborts at launch with "different Team IDs", and notarization
# rejects ad-hoc code. Assert every bundled executable carries our Developer ID team.
echo "==> Asserting Developer ID Team ID ($TEAM_ID) on all bundled code"
SIGN_BAD=0
while IFS= read -r -d '' ITEM; do
    TEAM=$(codesign -dvv "$ITEM" 2>&1 | sed -n 's/^TeamIdentifier=//p')
    if [ "$TEAM" != "$TEAM_ID" ]; then
        echo "  !! ${ITEM#$APP_PATH/}: TeamIdentifier='${TEAM:-not set}' (expected $TEAM_ID)"
        SIGN_BAD=1
    fi
done < <(
    find "$APP_PATH" \
        \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.dylib" \) -print0
    find "$APP_PATH/Contents/Frameworks" -type f ! -name "*.dylib" \
        -exec sh -c 'file -b "$1" | grep -q "Mach-O"' _ {} \; -print0
    printf '%s\0' "$APP_PATH/Contents/MacOS/Zerm"
)
if [ "$SIGN_BAD" != "0" ]; then
    echo "error: not all bundled code is signed with team $TEAM_ID."
    echo "This build would crash on download with a dyld 'different Team IDs' error. Aborting."
    exit 1
fi

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

# --- Sparkle appcast ----------------------------------------------------------
# Requires a Sparkle EdDSA private key at SPARKLE_PRIVATE_KEY_FILE (or
# ~/.zerm/sparkle_eddsa_private.key). Public key must match SUPublicEDKey in Info.plist.
# Generate once with:  generate_keys  (from Sparkle tools) and store privately.
echo "==> Generating Sparkle appcast entry (if sign_update available)"
SPARKLE_PRIVATE_KEY_FILE="${SPARKLE_PRIVATE_KEY_FILE:-$HOME/.zerm/sparkle_eddsa_private.key}"
SIGN_UPDATE=""
if command -v sign_update >/dev/null 2>&1; then
    SIGN_UPDATE="sign_update"
elif [ -x "$REPO_ROOT/.sparkle-bin/sign_update" ]; then
    SIGN_UPDATE="$REPO_ROOT/.sparkle-bin/sign_update"
elif [ -x "/usr/local/bin/sign_update" ]; then
    SIGN_UPDATE="/usr/local/bin/sign_update"
fi

UPDATE_ZIP="$WORK_DIR/Zerm-$VERSION-macos.zip"
mkdir -p "$WORK_DIR"
ditto -c -k --keepParent "$APP_PATH" "$UPDATE_ZIP"
UPDATE_LEN=$(stat -f%z "$UPDATE_ZIP" 2>/dev/null || stat -c%s "$UPDATE_ZIP")
UPDATE_URL="https://github.com/arcusis/Zerm/releases/download/v${VERSION}/Zerm-${VERSION}-macos.zip"
ED_SIG=""
if [ -n "$SIGN_UPDATE" ] && [ -f "$SPARKLE_PRIVATE_KEY_FILE" ]; then
    ED_SIG=$("$SIGN_UPDATE" "$UPDATE_ZIP" -f "$SPARKLE_PRIVATE_KEY_FILE" 2>/dev/null | tr -d '\n' || true)
    # sign_update often prints: sparkle:edSignature="..." length="..."
    if echo "$ED_SIG" | grep -q 'edSignature='; then
        :
    else
        # Some versions print only the signature base64
        if [ -n "$ED_SIG" ]; then
            ED_SIG="sparkle:edSignature=\"$ED_SIG\" length=\"$UPDATE_LEN\""
        fi
    fi
else
    echo "warning: sign_update or private key missing — appcast will be unsigned."
    echo "  Set SPARKLE_PRIVATE_KEY_FILE and install Sparkle's sign_update for real updates."
fi

PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")
APPCAST_OUT="$REPO_ROOT/docs/appcast.xml"
mkdir -p "$REPO_ROOT/docs"
# Also keep root appcast.xml in sync for local/dev reference.
cat > "$APPCAST_OUT" <<APPCAST
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Zerm</title>
        <item>
            <title>${VERSION}</title>
            <description><![CDATA[
                <h3>What's New in v${VERSION}</h3>
                <ul>
                    <li>Deep review fixes: privacy, accuracy, stability, and ops.</li>
                </ul>
            ]]></description>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);.*/\1/p' "$REPO_ROOT/Zerm.xcodeproj/project.pbxproj" | head -1)</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>
            <enclosure url="${UPDATE_URL}" length="${UPDATE_LEN}" type="application/octet-stream" ${ED_SIG}/>
        </item>
    </channel>
</rss>
APPCAST
cp "$APPCAST_OUT" "$REPO_ROOT/appcast.xml"
cp "$UPDATE_ZIP" "$REPO_ROOT/Zerm_${VERSION}_macos.zip" 2>/dev/null || true
echo "Appcast written to docs/appcast.xml (publish via GitHub Pages)."
echo "Update zip: $UPDATE_ZIP"
