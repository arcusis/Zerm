# Building Zerm

This guide provides detailed instructions for building Zerm from source.

## Prerequisites

Before you begin, ensure you have:
- macOS 14.4 or later
- Xcode (latest version recommended)
- Swift (latest version recommended)
- Git (for cloning repositories)

## Quick Start with Makefile (Recommended)

The easiest way to build Zerm is using the included Makefile, which automates the entire build process including building and linking the whisper framework.

### Simple Build Commands

```bash
# Clone the repository
git clone https://github.com/Arcusis/Zerm.git
cd Zerm

# Build everything (recommended for first-time setup)
make all

# Or for development (build and run)
make dev
```

### Available Makefile Commands

- `make check` or `make healthcheck` - Verify all required tools are installed
- `make whisper` - Clone and build whisper.cpp XCFramework automatically
- `make setup` - Prepare the whisper framework for linking
- `make build` - Build the Zerm Xcode project
- `make local` - Build for local use (no Apple Developer certificate needed)
- `make release` - Build the Developer ID signed + notarized release DMG (maintainers only)
- `make run` - Launch the built Zerm app
- `make dev` - Build and run (ideal for development workflow)
- `make all` - Complete build process (default)
- `make clean` - Remove build artifacts and dependencies
- `make help` - Show all available commands

### How the Makefile Helps

The Makefile automatically:
1. **Manages Dependencies**: Creates a dedicated `~/Zerm-Dependencies` directory for all external frameworks
2. **Builds Whisper Framework**: Clones whisper.cpp and builds the XCFramework with the correct configuration
3. **Handles Framework Linking**: Sets up the whisper.xcframework in the proper location for Xcode to find
4. **Verifies Prerequisites**: Checks that git, xcodebuild, and swift are installed before building
5. **Streamlines Development**: Provides convenient shortcuts for common development tasks

This approach ensures consistent builds across different machines and eliminates manual framework setup errors.

---

## Building for Local Use (No Apple Developer Certificate)

If you don't have an Apple Developer certificate, use `make local`:

```bash
git clone https://github.com/Arcusis/Zerm.git
cd Zerm
make local
open ~/Downloads/Zerm.app
```

This builds Zerm with ad-hoc signing using a separate build configuration (`LocalBuild.xcconfig`) that requires no Apple Developer account.

### How It Works

The `make local` command uses:
- `LocalBuild.xcconfig` to override signing and entitlements settings
- `Zerm.local.entitlements` (stripped-down, no CloudKit/keychain groups)
- `LOCAL_BUILD` Swift compilation flag for conditional code paths

Your normal `make all` / `make build` commands are completely unaffected.

---

## Building a Release (Maintainers)

Public DMGs must be Developer ID signed **and notarized**, otherwise Gatekeeper
rejects the app on other Macs ("Zerm is damaged and can't be opened" /
"Apple could not verify Zerm is free of malware").

Requirements on the release machine:

- The `Developer ID Application: Arcusis LTD (F9Z784RA6D)` certificate in the login keychain
- One-time notarization credential setup:

```bash
xcrun notarytool store-credentials zerm-notary \
  --key ~/.appstoreconnect/private_keys/AuthKey_<KEY-ID>.p8 \
  --key-id <KEY-ID> \
  --issuer <ISSUER-UUID>
```

The issuer UUID is shown in App Store Connect under
**Users and Access → Integrations → App Store Connect API**.

Then build the release:

```bash
make release            # or: scripts/release.sh
```

This builds the Release configuration, signs the app with Developer ID and the
hardened runtime, notarizes app and DMG with Apple, staples the tickets, and
verifies the result with `spctl`. It exports both exact GitHub Release assets in
the repo root: `Zerm_<release-label>_aarch64.dmg` and the Sparkle enclosure
`Zerm-<release-label>-macos.zip`. Upload both with the command printed by the
script.

By default the release label is the Xcode project's `MARKETING_VERSION` and the
tag is `v<MARKETING_VERSION>`. If the approved GitHub release needs a distinct
three- or four-component label, set both explicitly:

```bash
RELEASE_LABEL=A.B.C.D RELEASE_TAG=vA.B.C.D scripts/release.sh
```

This changes the GitHub tag, filenames, appcast title and enclosure URL only.
The app and `sparkle:shortVersionString` still use Apple's three-component
`MARKETING_VERSION`; `sparkle:version` uses the strictly increasing
`CURRENT_PROJECT_VERSION`, which controls update ordering. The script rejects a
noncanonical tag/label pair or a build number that is not newer than the current
published appcast.

To sign and notarize a Release app built on the Office Mac without rebuilding
on the signing Mac, copy the app outside `.release-build` and run the script
directly (not through `make release`, whose `setup` prerequisite builds native
dependencies):

```bash
PREBUILT_APP=/path/to/Zerm.app \
  RELEASE_LABEL=A.B.C.D RELEASE_TAG=vA.B.C.D \
  scripts/release.sh
```

The script fails before signing if the bundle identifier, project version,
build number or arm64 executable does not match, and validates the staged copy
again. Sparkle signing material and release notes are mandatory for a real run.

`SKIP_NOTARIZE=1 scripts/release.sh` does a signing-only dry run.

After packaging, commit the generated `docs/appcast.xml` with the release source,
push the tag, create a draft GitHub Release, and upload both exact assets. Run
the Release workflow manually against that draft tag before publishing. The
workflow cross-checks the tag and filenames against the tagged appcast, Xcode
project and ZIP bundle identity; its `released` run is a post-publication
verification, not a substitute for the draft gate.

### After publishing the GitHub Release

The site changelog is generated from the **published** GitHub Releases, so it can
only be rebuilt once the release exists:

```bash
node scripts/build-site.mjs
git add docs/ && git commit -m "Regenerate site changelog from releases"
```

Open that as a PR — Production takes changes by pull request only.

This is a manual step on purpose. The Release workflow cannot do it for you: it
can create a properly signed commit, but the organization forbids GitHub Actions
from opening pull requests, and Production requires one. The workflow therefore
checks for drift and fails loudly if the site is behind, rather than pretending
to publish.

---

## Manual Build Process (Alternative)

If you prefer to build manually or need more control over the build process, follow these steps:

### Building whisper.cpp Framework

1. Clone and build whisper.cpp:
```bash
git clone https://github.com/ggerganov/whisper.cpp.git
cd whisper.cpp
./build-xcframework.sh
```
This will create the XCFramework at `build-apple/whisper.xcframework`.

### Building Zerm

1. Clone the Zerm repository:
```bash
git clone https://github.com/Arcusis/Zerm.git
cd Zerm
```

2. Add the whisper.xcframework to your project:
   - Drag and drop `../whisper.cpp/build-apple/whisper.xcframework` into the project navigator, or
   - Add it manually in the "Frameworks, Libraries, and Embedded Content" section of project settings

3. Build and Run
   - Build the project using Cmd+B or Product > Build
   - Run the project using Cmd+R or Product > Run

## Development Setup

1. **Xcode Configuration**
   - Ensure you have the latest Xcode version
   - Install any required Xcode Command Line Tools

2. **Dependencies**
   - The project uses [whisper.cpp](https://github.com/ggerganov/whisper.cpp) for transcription
   - Ensure the whisper.xcframework is properly linked in your Xcode project
   - Test the whisper.cpp installation independently before proceeding

3. **Building for Development**
   - Use the Debug configuration for development
   - Enable relevant debugging options in Xcode

4. **Testing**
   - Run the test suite before making changes
   - Ensure all tests pass after your modifications

## Troubleshooting

If you encounter any build issues:
1. Clean the build folder (Cmd+Shift+K)
2. Clean the build cache (Cmd+Shift+K twice)
3. Check Xcode and macOS versions
4. Verify all dependencies are properly installed
5. Make sure whisper.xcframework is properly built and linked

For more help, please check the [issues](https://github.com/Arcusis/Zerm/issues) section or create a new issue.
