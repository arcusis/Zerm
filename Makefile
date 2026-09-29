# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/Zerm-Dependencies
# Pinned upstream revisions of the native parsers compiled into the shipped binary.
# Bump these deliberately (and re-verify) rather than tracking a moving branch head.
WHISPER_COMMIT := 927cfce34f31707e17f2bff35c349632fb9e2c3a
SHERPA_COMMIT := 6faa8142d49d4d47d2a6c1e06350a976661fe046
LLAMA_COMMIT := d5d993a0938ddc0d2a4328632b8dcfbfa64b63e6
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework
SHERPA_DIR := $(DEPS_DIR)/sherpa-onnx
SHERPA_BUILD := $(SHERPA_DIR)/build-swift-macos
SHERPA_XCFRAMEWORK := $(SHERPA_BUILD)/sherpa-onnx.xcframework
ONNX_XCFRAMEWORK := $(SHERPA_BUILD)/onnxruntime.xcframework
LLAMA_DIR := $(DEPS_DIR)/llama
LLAMA_XCFRAMEWORK := $(LLAMA_DIR)/build-apple/llama.xcframework
# Each built framework records the upstream commit it came from, so bumping a pin rebuilds
# it instead of silently linking a stale copy left in DEPS_DIR.
PIN_STAMP := .zerm-pinned-commit
LOCAL_DERIVED_DATA := $(CURDIR)/.local-build
# Development builds use their own bundle identifier, so their UserDefaults, Application
# Support data, TCC grants and updater never touch an installed Zerm. See AppStoragePaths.
DEV_BUNDLE_SUFFIX := .dev
DEV_DERIVED_DATA := $(CURDIR)/.dev-build
DEV_APP := $(DEV_DERIVED_DATA)/Zerm Dev.app

.PHONY: all clean whisper sherpa llama setup build test dev-app local check healthcheck help dev run install reset-permissions release site

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# whisper.cpp packages seven Apple platform slices; Zerm links only macOS. Keep its
# transformed recipe checked by scripts/macos-only-xcframework.py.
WHISPER_MACOS_XCFRAMEWORK = python3 $(CURDIR)/scripts/macos-only-xcframework.py build-xcframework.sh build-xcframework-macos.sh && $(call INJECT_PREFIX_MAP,build-xcframework-macos.sh) && bash build-xcframework-macos.sh

# Shipped binaries must not embed build-machine paths (they reveal the builder's user name).
# Map every source path under the home folder to "." in the upstream build scripts, and refuse
# a framework that still contains one.
PREFIX_MAP_FLAGS := -ffile-prefix-map=$(DEPS_DIR)=. -ffile-prefix-map=$(HOME)=.
INJECT_PREFIX_MAP = sed -i '' -E 's|^(COMMON_C(XX)?_FLAGS="[^"]*)"|\1 $(PREFIX_MAP_FLAGS)"|' $(1) && grep -q -- '-ffile-prefix-map=$(HOME)=' $(1)
CHECK_NO_HOME_PATHS = if find "$(1)" -type f \( -perm -u+x -o -name '*.a' \) -exec strings -a {} + | grep -q "$(HOME)/"; then echo "error: $(1) embeds paths under $(HOME)"; exit 1; fi

# Build process
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ "$$(cat "$(FRAMEWORK_PATH)/$(PIN_STAMP)" 2>/dev/null)" != "$(WHISPER_COMMIT)" ]; then \
		echo "Building whisper.xcframework $(WHISPER_COMMIT) in $(DEPS_DIR)..."; \
		rm -rf "$(FRAMEWORK_PATH)"; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git fetch origin); \
		fi; \
		(cd $(WHISPER_CPP_DIR) && git checkout --quiet --force $(WHISPER_COMMIT)); \
		(cd $(WHISPER_CPP_DIR) && $(WHISPER_MACOS_XCFRAMEWORK)) && \
		$(call CHECK_NO_HOME_PATHS,$(FRAMEWORK_PATH)) && \
		echo "$(WHISPER_COMMIT)" > "$(FRAMEWORK_PATH)/$(PIN_STAMP)"; \
	else \
		echo "whisper.xcframework $(WHISPER_COMMIT) already built in $(DEPS_DIR), skipping build"; \
	fi

# Build sherpa-onnx + onnxruntime xcframeworks for on-device Kokoro TTS (Read Aloud feature)
sherpa:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(SHERPA_XCFRAMEWORK)" ]; then \
		echo "Building sherpa-onnx.xcframework in $(DEPS_DIR)..."; \
		if [ ! -d "$(SHERPA_DIR)" ]; then \
			git clone https://github.com/k2-fsa/sherpa-onnx.git $(SHERPA_DIR); \
		fi; \
		(cd $(SHERPA_DIR) && git fetch origin && git checkout --quiet $(SHERPA_COMMIT)); \
		cd $(SHERPA_DIR) && \
			CC="$$(xcrun --find clang)" \
			CXX="$$(xcrun --find clang++)" \
			SDKROOT="$$(xcrun --sdk macosx --show-sdk-path)" \
			./build-swift-macos.sh; \
	else \
		echo "sherpa-onnx.xcframework already built, skipping"; \
	fi
	@if [ ! -d "$(ONNX_XCFRAMEWORK)" ]; then \
		echo "Packaging onnxruntime.xcframework..."; \
		cd $(SHERPA_BUILD) && xcodebuild -create-xcframework -library install/lib/libonnxruntime.a -output onnxruntime.xcframework; \
	else \
		echo "onnxruntime.xcframework already built, skipping"; \
	fi

# Build llama.cpp at the exact revision used by Zerm's Objective-C++ bridge. Its current
# upstream script accepts a macOS slice selector and no longer matches the legacy transformer.
llama:
	@mkdir -p $(DEPS_DIR)
	@if [ "$$(cat "$(LLAMA_XCFRAMEWORK)/$(PIN_STAMP)" 2>/dev/null)" != "$(LLAMA_COMMIT)" ]; then \
		echo "Building llama.xcframework $(LLAMA_COMMIT) in $(DEPS_DIR)..."; \
		rm -rf "$(LLAMA_XCFRAMEWORK)"; \
		if [ ! -d "$(LLAMA_DIR)/.git" ]; then \
			rm -rf "$(LLAMA_DIR)" && git clone https://github.com/ggerganov/llama.cpp.git $(LLAMA_DIR); \
		else \
			(cd $(LLAMA_DIR) && git fetch origin); \
		fi; \
		(cd $(LLAMA_DIR) && git checkout --quiet --force $(LLAMA_COMMIT)); \
		(cd $(LLAMA_DIR) && $(call INJECT_PREFIX_MAP,build-xcframework.sh) && bash build-xcframework.sh macos) && \
		$(call CHECK_NO_HOME_PATHS,$(LLAMA_XCFRAMEWORK)) && \
		echo "$(LLAMA_COMMIT)" > "$(LLAMA_XCFRAMEWORK)/$(PIN_STAMP)"; \
	else \
		echo "llama.xcframework $(LLAMA_COMMIT) already built, skipping"; \
	fi

setup: whisper sherpa llama
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "sherpa-onnx framework is ready at $(SHERPA_XCFRAMEWORK)"
	@echo "llama framework is ready at $(LLAMA_XCFRAMEWORK)"
	@echo "Please ensure your Xcode project references the frameworks from these locations."

build: setup
	xcodebuild -project Zerm.xcodeproj -scheme Zerm -configuration Debug ZERM_DEPS_DIR="$(DEPS_DIR)" CODE_SIGN_IDENTITY="" build

# Build for local use without Apple Developer certificate
local: check setup
	@echo "Building Zerm for local use (no Apple Developer certificate required)..."
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	xcodebuild -project Zerm.xcodeproj -scheme Zerm -configuration Debug \
		-derivedDataPath "$(LOCAL_DERIVED_DATA)" \
		-xcconfig LocalBuild.xcconfig \
		ZERM_DEPS_DIR="$(DEPS_DIR)" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS=$(CURDIR)/Zerm/Zerm.local.entitlements \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH="$(LOCAL_DERIVED_DATA)/Build/Products/Debug/Zerm.app" && \
	if [ -d "$$APP_PATH" ]; then \
		echo "Copying Zerm.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/Zerm.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/Zerm.app"; \
		xattr -cr "$$HOME/Downloads/Zerm.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/Zerm.app"; \
		echo "Run with: open ~/Downloads/Zerm.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built Zerm.app at $$APP_PATH"; \
		exit 1; \
	fi

# Install built app to /Applications and reset TCC permissions
# Run this after every 'make local' to avoid stale permission grants from old builds
install: local
	@echo "Installing Zerm.app to /Applications..."
	@pkill -x Zerm 2>/dev/null || true
	@sleep 0.5
	@ditto "$$HOME/Downloads/Zerm.app" /Applications/Zerm.app
	@rm -rf "$$HOME/Downloads/Zerm.app"
	@rm -rf "$(LOCAL_DERIVED_DATA)"
	@/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
		-f /Applications/Zerm.app
	@defaults write com.apple.dock ResetLaunchPad -bool true && killall Dock
	@echo "Resetting TCC permissions (ad-hoc signature changed)..."
	@tccutil reset Accessibility com.arcusis.zerm 2>/dev/null || true
	@tccutil reset ScreenCapture com.arcusis.zerm 2>/dev/null || true
	@echo ""
	@echo "Zerm.app installed. Opening..."
	@open /Applications/Zerm.app
	@echo ""
	@echo "Re-grant Accessibility and Screen Recording in Zerm → Permissions."

# Build the Developer ID signed + notarized DMG and Sparkle ZIP (see scripts/release.sh)
release: check setup
	@scripts/release.sh

# Reset TCC permissions for Zerm (run after rebuilding with a new ad-hoc signature)
reset-permissions:
	@echo "Resetting Zerm TCC permissions..."
	@tccutil reset Accessibility com.arcusis.zerm && echo "  Accessibility reset" || echo "  Accessibility: nothing to reset"
	@tccutil reset ScreenCapture com.arcusis.zerm && echo "  ScreenCapture reset" || echo "  ScreenCapture: nothing to reset"
	@echo ""
	@echo "Done. Open Zerm → Permissions and re-grant Accessibility and Screen Recording."

# Run application
run:
	@if [ -d "$$HOME/Downloads/Zerm.app" ]; then \
		echo "Opening ~/Downloads/Zerm.app..."; \
		open "$$HOME/Downloads/Zerm.app"; \
	else \
		echo "Looking for Zerm.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "Zerm.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "Zerm.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

# Run the unit tests. The scheme has always had a TestAction wired to ZermTests, but
# nothing invoked it — no make target and no CI step — so the suite never ran.
# Debug is required, not incidental: `@testable import Zerm` needs ENABLE_TESTABILITY,
# which Release turns off, and the tests fail to compile without it.
# The test host launches the whole app, so it runs under the development bundle identifier:
# otherwise launch-time migrations would run against the installed app's data.
test: setup
	xcodebuild test -project Zerm.xcodeproj -scheme Zerm \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath "$(DEV_DERIVED_DATA)" \
		-only-testing:ZermTests \
		ZERM_DEPS_DIR="$(DEPS_DIR)" \
		ZERM_BUNDLE_ID_SUFFIX=$(DEV_BUNDLE_SUFFIX) \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Build "Zerm Dev.app" (com.arcusis.zerm.dev) for hands-on testing beside the installed app.
# Never installed to /Applications. Give it hotkeys that differ from the installed app's
# before granting it Accessibility.
dev-app: check setup
	xcodebuild -project Zerm.xcodeproj -scheme Zerm -configuration Debug \
		-derivedDataPath "$(DEV_DERIVED_DATA)" \
		ZERM_DEPS_DIR="$(DEPS_DIR)" \
		-xcconfig LocalBuild.xcconfig \
		ZERM_BUNDLE_ID_SUFFIX=$(DEV_BUNDLE_SUFFIX) \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS=$(CURDIR)/Zerm/Zerm.local.entitlements \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@rm -rf "$(DEV_APP)"
	@ditto "$(DEV_DERIVED_DATA)/Build/Products/Debug/Zerm.app" "$(DEV_APP)"
	@xattr -cr "$(DEV_APP)"
	@echo "Built $(DEV_APP) ($$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$(DEV_APP)/Contents/Info.plist"))"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to Zerm project"
	@echo "  build              Build the Zerm Xcode project"
	@echo "  test               Run the ZermTests unit suite"
	@echo "  local              Build for local use (no Apple Developer certificate needed)"
	@echo "  release            Build signed/notarized DMG and Sparkle ZIP"
	@echo "  install            Build, install to /Applications, and reset Launchpad"
	@echo "  reset-permissions  Reset Accessibility + Screen Recording TCC grants (run after rebuild)"
	@echo "  run                Launch the built Zerm app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"
# Regenerate the derived site pages: changelog, notice, license, building,
# verification, and the docs/ section from site-content/docs/*.md.
# Needs an authenticated `gh` — markdown is rendered through the GitHub API.
site:
	node scripts/build-site.mjs
