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
#   PREBUILT_APP=/path/to/Zerm.app scripts/release.sh
#                                        # validate + sign an existing Release app
#   RELEASE_LABEL=1.2.8.2 RELEASE_TAG=v1.2.8.2 scripts/release.sh
#                                        # GitHub label/tag independent of bundle version
#   SKIP_NOTARIZE=1 scripts/release.sh   # dry run: build + sign only

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Arcusis LTD (F9Z784RA6D)}"
TEAM_ID="${TEAM_ID:-F9Z784RA6D}"
NOTARY_PROFILE="${NOTARY_PROFILE:-zerm-notary}"
DERIVED_DATA="$REPO_ROOT/.release-build"
WORK_DIR="$DERIVED_DATA/package"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Zerm.app"

APP_BUILD_SETTINGS=$(awk '
    /buildSettings = \{/ { in_settings = 1; settings = $0 ORS; next }
    in_settings { settings = settings $0 ORS }
    in_settings && /^[[:space:]]*};/ {
        if (settings ~ /PRODUCT_BUNDLE_IDENTIFIER = com\.arcusis\.zerm;/) {
            printf "%s", settings
        }
        in_settings = 0
        settings = ""
    }
' "$REPO_ROOT/Zerm.xcodeproj/project.pbxproj")
BUNDLE_VERSION=$(printf '%s\n' "$APP_BUILD_SETTINGS" \
    | sed -n 's/.*MARKETING_VERSION = \([0-9][0-9.]*\);.*/\1/p' | sort -u)
BUILD_VERSION=$(printf '%s\n' "$APP_BUILD_SETTINGS" \
    | sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);.*/\1/p' | sort -u)
EXPECTED_BUNDLE_ID="com.arcusis.zerm"

# GitHub release labels may have four components even though Apple's user-visible bundle
# version must have exactly three. If only a tag is supplied, derive the label from it; if only
# a label is supplied, derive its canonical `v` tag. Supplying both must describe the same release
# so filenames, appcast URLs and workflow validation cannot drift apart.
if [ -n "${RELEASE_TAG:-}" ] && [ -z "${RELEASE_LABEL:-}" ]; then
    RELEASE_LABEL="${RELEASE_TAG#v}"
else
    RELEASE_LABEL="${RELEASE_LABEL:-$BUNDLE_VERSION}"
fi
RELEASE_TAG="${RELEASE_TAG:-v$RELEASE_LABEL}"

DMG_NAME="Zerm_${RELEASE_LABEL}_aarch64.dmg"
DMG_PATH="$REPO_ROOT/$DMG_NAME"
UPDATE_NAME="Zerm-${RELEASE_LABEL}-macos.zip"
EXPORTED_UPDATE_ZIP="$REPO_ROOT/$UPDATE_NAME"

validate_release_app() {
    local candidate="$1"
    local info_plist="$candidate/Contents/Info.plist"
    local executable_name
    local executable
    local actual_bundle_id
    local actual_version
    local actual_build
    local actual_archs

    [ -d "$candidate" ] || { echo "error: prebuilt app not found: $candidate"; exit 1; }
    [ -f "$info_plist" ] || { echo "error: missing Info.plist in $candidate"; exit 1; }

    executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)
    [ -n "$executable_name" ] || { echo "error: CFBundleExecutable is missing in $info_plist"; exit 1; }
    executable="$candidate/Contents/MacOS/$executable_name"
    [ -f "$executable" ] || { echo "error: app executable not found: $executable"; exit 1; }

    actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)
    actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null || true)
    actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null || true)
    actual_archs=$(lipo -archs "$executable" 2>/dev/null || true)

    [ "$actual_bundle_id" = "$EXPECTED_BUNDLE_ID" ] || {
        echo "error: prebuilt bundle id '$actual_bundle_id' does not match '$EXPECTED_BUNDLE_ID'."
        exit 1
    }
    [ "$actual_version" = "$BUNDLE_VERSION" ] || {
        echo "error: prebuilt version '$actual_version' does not match project bundle version '$BUNDLE_VERSION'."
        exit 1
    }
    [ "$actual_build" = "$BUILD_VERSION" ] || {
        echo "error: prebuilt build '$actual_build' does not match project build '$BUILD_VERSION'."
        exit 1
    }
    [ "$actual_archs" = "arm64" ] || {
        echo "error: prebuilt executable architectures '$actual_archs' are not the required arm64 release architecture."
        exit 1
    }
}

[ -n "$BUNDLE_VERSION" ] || { echo "error: MARKETING_VERSION is missing from the Xcode project."; exit 1; }
[ -n "$BUILD_VERSION" ] || { echo "error: CURRENT_PROJECT_VERSION is missing from the Xcode project."; exit 1; }
[[ "$BUNDLE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: project bundle version '$BUNDLE_VERSION' must use Apple's Major.Minor.Patch format."
    exit 1
}
[[ "$BUILD_VERSION" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: project build version '$BUILD_VERSION' must be a positive integer."
    exit 1
}
[[ "$RELEASE_LABEL" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]] || {
    echo "error: RELEASE_LABEL '$RELEASE_LABEL' must contain three or four numeric components."
    exit 1
}
[ "$RELEASE_TAG" = "v$RELEASE_LABEL" ] || {
    echo "error: RELEASE_TAG '$RELEASE_TAG' must equal v$RELEASE_LABEL so tag, assets and appcast stay aligned."
    exit 1
}

# Sparkle orders updates by CFBundleVersion/sparkle:version, not by the human-readable
# GitHub label. Refuse to create another release at or below the feed's current build. An
# intentional retry of already-generated output requires an explicit dry-run override.
PUBLISHED_BUILD=""
if [ -f "$REPO_ROOT/docs/appcast.xml" ]; then
    PUBLISHED_BUILD=$(sed -n 's|.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*|\1|p' \
        "$REPO_ROOT/docs/appcast.xml" | head -1)
fi
if [ -n "$PUBLISHED_BUILD" ] && [ "$BUILD_VERSION" -le "$PUBLISHED_BUILD" ] \
    && [ "${ALLOW_REBUILD_CURRENT_RELEASE:-0}" != "1" ]; then
    echo "error: project build $BUILD_VERSION is not newer than published Sparkle build $PUBLISHED_BUILD."
    echo "Increment CURRENT_PROJECT_VERSION before packaging a new release."
    echo "Set ALLOW_REBUILD_CURRENT_RELEASE=1 only to reproduce already-generated release output."
    exit 1
fi

echo "==> Releasing Zerm label $RELEASE_LABEL ($RELEASE_TAG), bundle $BUNDLE_VERSION ($BUILD_VERSION)"

PREBUILT_SOURCE=""
if [ -n "${PREBUILT_APP:-}" ]; then
    PREBUILT_SOURCE=$(cd "$PREBUILT_APP" 2>/dev/null && pwd -P) || {
        echo "error: cannot resolve PREBUILT_APP bundle: $PREBUILT_APP"
        exit 1
    }
    case "$PREBUILT_SOURCE/" in
        "$DERIVED_DATA/"*)
            echo "error: PREBUILT_APP must be outside $DERIVED_DATA because that directory is recreated during packaging."
            exit 1
            ;;
    esac
    validate_release_app "$PREBUILT_SOURCE"
fi

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        echo "error: notarytool credentials profile '$NOTARY_PROFILE' not found or invalid."
        echo "Run the one-time setup documented at the top of this script."
        exit 1
    fi
fi

rm -rf "$DERIVED_DATA"
if [ -n "$PREBUILT_SOURCE" ]; then
    echo "==> Staging validated prebuilt Release app"
    mkdir -p "$(dirname "$APP_PATH")"
    ditto "$PREBUILT_SOURCE" "$APP_PATH"
else
    echo "==> Building Release configuration"
    # LOCAL_BUILD disables CloudKit because Developer ID signing alone cannot grant its
    # restricted entitlement. Release credentials still use the system Keychain.
    # shellcheck disable=SC2016 # Xcode, not this shell, expands $(inherited).
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
fi

[ -d "$APP_PATH" ] || { echo "error: $APP_PATH not found after build"; exit 1; }
validate_release_app "$APP_PATH"

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
        echo "  !! ${ITEM#"$APP_PATH"/}: TeamIdentifier='${TEAM:-not set}' (expected $TEAM_ID)"
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

# Branded installer window. Best effort: if anything here fails the release still ships, it
# just falls back to Finder's default plain listing.
VOLUME_NAME="Zerm $RELEASE_LABEL"
BRANDED_DMG=0
mkdir -p "$STAGING/.background"
if swift "$REPO_ROOT/scripts/make-dmg-background.swift" \
        "$REPO_ROOT/assets/logo.png" \
        "$STAGING/.background/background.png" \
        "$RELEASE_LABEL"; then
    BRANDED_DMG=1
else
    echo "    background render failed; falling back to an unstyled DMG"
    rm -rf "$STAGING/.background"
fi

if [ "$BRANDED_DMG" = "1" ]; then
    # Give the volume the app's own icon.
    if [ -f "$APP_PATH/Contents/Resources/AppIcon.icns" ]; then
        cp "$APP_PATH/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
        SetFile -a C "$STAGING" 2>/dev/null || true
    fi

    RW_DMG="$WORK_DIR/zerm-rw.dmg"
    rm -f "$RW_DMG"
    # Read-write first: Finder can only record window geometry on a mounted writable volume.
    hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG"
    # Must mount at the default /Volumes path. With `-mountpoint` pointing elsewhere Finder
    # cannot address the volume by name and every styling command fails with -1728.
    hdiutil detach "/Volumes/$VOLUME_NAME" -force >/dev/null 2>&1 || true
    hdiutil attach "$RW_DMG" -noverify -noautoopen
    sleep 2

    # Written to a file and run by path rather than piped through a heredoc. A heredoc here
    # failed in the 2.8.4 release run with `line 294: tell: command not found` — the body was
    # executed as shell instead of reaching osascript, and the DMG shipped unstyled while every
    # other step reported success. A file has no such ambiguity, and can be inspected on failure.
    STYLE_SCRIPT="$WORK_DIR/style-installer-window.applescript"
    cat > "$STYLE_SCRIPT" <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        delay 1
        set theWindow to container window
        set current view of theWindow to icon view
        set toolbar visible of theWindow to false
        set statusbar visible of theWindow to false
        -- Matches the canvas in make-dmg-background.swift.
        set the bounds of theWindow to {200, 140, 860, 560}
        set theOptions to the icon view options of theWindow
        set arrangement of theOptions to not arranged
        set icon size of theOptions to 128
        -- Resolve the background against the disk, not the view options: nesting this inside a
        -- \`tell the icon view options\` block makes Finder look for the file there and fail.
        set background picture of theOptions to file ".background:background.png"
        set position of item "Zerm.app" of theWindow to {170, 218}
        set position of item "Applications" of theWindow to {490, 218}
        delay 1
        update without registering applications
        delay 2
        -- Deliberately not closed. Closing the window makes Finder rewrite .DS_Store without
        -- the background alias, and the styling then vanishes during hdiutil convert. Measured
        -- over three variants: with `close` the shipped DMG carries 0 background references,
        -- without it 5. Detaching the volume closes the window anyway.
    end tell
end tell
APPLESCRIPT

    if ! osascript "$STYLE_SCRIPT"; then
        echo "    could not style the installer window; shipping it unstyled"
    fi

    sleep 3
    sync
    hdiutil detach "/Volumes/$VOLUME_NAME" -force || true
    hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
    rm -f "$RW_DMG"

    # Verify the DMG that actually ships, not the read-write volume it was built from. An
    # earlier version checked the staging volume, reported success, and shipped an unstyled DMG
    # anyway: the reference was present there and gone after convert.
    VERIFY_MOUNT="$WORK_DIR/verify-mount"
    rm -rf "$VERIFY_MOUNT"; mkdir -p "$VERIFY_MOUNT"
    BACKGROUND_REFS=0
    if hdiutil attach "$DMG_PATH" -nobrowse -noverify -mountpoint "$VERIFY_MOUNT" >/dev/null 2>&1; then
        BACKGROUND_REFS=$(strings "$VERIFY_MOUNT/.DS_Store" 2>/dev/null | grep -c "background.png" || true)
        hdiutil detach "$VERIFY_MOUNT" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$VERIFY_MOUNT"

    if [ "${BACKGROUND_REFS:-0}" -gt 0 ]; then
        echo "    installer window styled (verified in the shipped DMG)"
    else
        echo "error: the shipped DMG has no installer background."
        echo "  Set SKIP_DMG_BRANDING=1 to ship it unstyled."
        [ "${SKIP_DMG_BRANDING:-0}" = "1" ] || exit 1
    fi
else
    hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
fi
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [ "${SKIP_NOTARIZE:-0}" != "1" ]; then
    echo "==> Notarizing DMG"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
fi

echo "==> Gatekeeper assessment"
spctl -a -vv -t exec "$APP_PATH" || [ "${SKIP_NOTARIZE:-0}" = "1" ]
spctl -a -vv -t open --context context:primary-signature "$DMG_PATH" || [ "${SKIP_NOTARIZE:-0}" = "1" ]

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

UPDATE_ZIP="$WORK_DIR/$UPDATE_NAME"
mkdir -p "$WORK_DIR"
ditto -c -k --keepParent "$APP_PATH" "$UPDATE_ZIP"
UPDATE_LEN=$(stat -f%z "$UPDATE_ZIP" 2>/dev/null || stat -c%s "$UPDATE_ZIP")
UPDATE_URL="https://github.com/arcusis/Zerm/releases/download/${RELEASE_TAG}/${UPDATE_NAME}"
ED_SIG=""
if [ -n "$SIGN_UPDATE" ] && [ -f "$SPARKLE_PRIVATE_KEY_FILE" ]; then
    SIGN_OUT=$("$SIGN_UPDATE" "$UPDATE_ZIP" -f "$SPARKLE_PRIVATE_KEY_FILE" 2>/dev/null | tr -d '\n' || true)
    # sign_update prints `sparkle:edSignature="..." length="..."` on current
    # versions and a bare base64 signature on older ones. Extract just the
    # signature: the enclosure below already emits length, and a duplicate
    # attribute makes the feed malformed XML — every client's update check then
    # fails to parse the feed, silently killing OTA for all users.
    SIG_VALUE=$(printf '%s' "$SIGN_OUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')
    [ -n "$SIG_VALUE" ] || SIG_VALUE="$SIGN_OUT"
    if [ -n "$SIG_VALUE" ]; then
        ED_SIG="sparkle:edSignature=\"$SIG_VALUE\""
    fi
fi

# Fail closed: an unsigned appcast would either be rejected by every client (dead OTA)
# or, worse, ship an unverifiable update. Never publish one by accident.
# Set SKIP_APPCAST_SIGNATURE=1 only for an intentional dry run.
if [ -z "$ED_SIG" ] && [ "${SKIP_APPCAST_SIGNATURE:-0}" != "1" ]; then
    echo "error: could not EdDSA-sign the update (sign_update or private key missing)."
    echo "  Install Sparkle's sign_update and set SPARKLE_PRIVATE_KEY_FILE=$SPARKLE_PRIVATE_KEY_FILE."
    echo "  Refusing to write an unsigned appcast. (Set SKIP_APPCAST_SIGNATURE=1 to override for a dry run.)"
    exit 1
fi

# Per-release notes for the Sparkle feed. Override per release, e.g.
#   RELEASE_NOTES_HTML='                    <li>Fixed the thing.</li>' scripts/release.sh
# Release notes shown in the in-app update dialog.
#
# There is deliberately no useful default. A silent fallback shipped 2.8.0 — a release
# with a whole new Recording tab — describing itself to every user as "maintenance and
# stability improvements". Better to stop and make the author write them.
if [ -z "${RELEASE_NOTES_HTML:-}" ]; then
    if [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "${RELEASE_NOTES_FILE}" ]; then
        RELEASE_NOTES_HTML="$(cat "${RELEASE_NOTES_FILE}")"
    else
        echo "error: no release notes supplied."
        echo "  RELEASE_NOTES_HTML='<li>...</li>' scripts/release.sh"
        echo "  RELEASE_NOTES_FILE=notes.html   scripts/release.sh"
        echo "These are what users read in the update dialog; do not ship without them."
        exit 1
    fi
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
            <title>${RELEASE_LABEL}</title>
            <description><![CDATA[
                <h3>What's New in ${RELEASE_TAG}</h3>
                <ul>
${RELEASE_NOTES_HTML}
                </ul>
            ]]></description>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${BUILD_VERSION}</sparkle:version>
            <sparkle:shortVersionString>${BUNDLE_VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>
            <enclosure url="${UPDATE_URL}" length="${UPDATE_LEN}" type="application/octet-stream" ${ED_SIG}/>
        </item>
    </channel>
</rss>
APPCAST
cp "$APPCAST_OUT" "$REPO_ROOT/appcast.xml"
cp "$UPDATE_ZIP" "$EXPORTED_UPDATE_ZIP"
echo "Appcast written to docs/appcast.xml (publish via GitHub Pages)."
echo "Update zip: $EXPORTED_UPDATE_ZIP"
echo ""
echo "Done: $DMG_PATH"
echo "Upload both required assets with:"
echo "  gh release upload $RELEASE_TAG \"$DMG_PATH\" \"$EXPORTED_UPDATE_ZIP\""
