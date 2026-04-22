#!/usr/bin/env bash
set -u

APP_PATH="${ZERM_APP_PATH:-/Applications/Zerm.app}"
STRICT_RELEASE=0
RUN_AUTOPASTE_SELF_TEST=0
PRINT_MANUAL_CHECKLIST=1
FAILURES=0
WARNINGS=0

usage() {
  cat <<'USAGE'
Usage: scripts/verify-native-writing-layer.sh [options]

Checks the native writing-layer release surface without changing system state.

Options:
  --app PATH                    App bundle to inspect. Defaults to /Applications/Zerm.app.
  --strict-release              Treat unsigned, ad-hoc, non-Developer ID, or Gatekeeper-rejected macOS bundles as failures.
  --run-autopaste-self-test     Run Zerm's interactive auto-paste self-test against the currently focused text field.
  --no-manual-checklist         Skip printing manual full-screen pill and paste checklist.
  -h, --help                    Show this help.

Safety:
  The default mode is read-only. The auto-paste self-test can paste text into the focused app and
  only runs when both --run-autopaste-self-test and ZERM_VERIFY_ALLOW_INPUT=1 are set.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --app" >&2
        exit 2
      fi
      APP_PATH="$2"
      shift 2
      ;;
    --strict-release)
      STRICT_RELEASE=1
      shift
      ;;
    --run-autopaste-self-test)
      RUN_AUTOPASTE_SELF_TEST=1
      shift
      ;;
    --no-manual-checklist)
      PRINT_MANUAL_CHECKLIST=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

section() {
  printf '\n== %s ==\n' "$1"
}

info() {
  printf 'info: %s\n' "$1"
}

pass() {
  printf 'pass: %s\n' "$1"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf 'warn: %s\n' "$1"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'fail: %s\n' "$1"
}

strict_or_warn() {
  if [[ "$STRICT_RELEASE" -eq 1 ]]; then
    fail "$1"
  else
    warn "$1"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_environment() {
  section "Environment"
  info "OS: $(uname -s)"
  info "Arch: $(uname -m)"
  info "App path: $APP_PATH"
  if [[ "$STRICT_RELEASE" -eq 1 ]]; then
    info "Strict release checks: enabled"
  else
    info "Strict release checks: disabled"
  fi
}

macos_codesign_details() {
  local details identifier signature team authorities bundle_identifier verify_output spctl_output

  if [[ ! -d "$APP_PATH" ]]; then
    fail "App bundle does not exist: $APP_PATH"
    return
  fi

  if [[ ! -x "$APP_PATH/Contents/MacOS/zerm" ]]; then
    fail "Expected executable is missing or not executable: $APP_PATH/Contents/MacOS/zerm"
  else
    pass "Executable exists: $APP_PATH/Contents/MacOS/zerm"
  fi

  if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
    fail "Info.plist is missing from app bundle"
  elif [[ -x /usr/libexec/PlistBuddy ]]; then
    bundle_identifier=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$bundle_identifier" == "com.arcusis.zerm" ]]; then
      pass "Info.plist bundle id is com.arcusis.zerm"
    else
      fail "Info.plist bundle id is '${bundle_identifier:-missing}', expected com.arcusis.zerm"
    fi
  else
    warn "PlistBuddy is unavailable; skipped Info.plist bundle id check"
  fi

  if [[ ! -x /usr/bin/codesign ]]; then
    fail "codesign is unavailable; cannot verify macOS signing"
    return
  fi

  if verify_output=$(/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1); then
    pass "codesign --verify --deep --strict passed"
  else
    fail "codesign verification failed: $(printf '%s' "$verify_output" | tr '\n' ' ')"
  fi

  details=$(/usr/bin/codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)
  identifier=$(printf '%s\n' "$details" | awk -F= '/^Identifier=/{print $2; exit}')
  signature=$(printf '%s\n' "$details" | awk -F= '/^Signature=/{print $2; exit}')
  team=$(printf '%s\n' "$details" | awk -F= '/^TeamIdentifier=/{print $2; exit}')
  authorities=$(printf '%s\n' "$details" | awk -F= '/^Authority=/{print $2}')

  if [[ "$identifier" == "com.arcusis.zerm" ]]; then
    pass "codesign identifier is com.arcusis.zerm"
  else
    fail "codesign identifier is '${identifier:-missing}', expected com.arcusis.zerm"
  fi

  if [[ "$signature" == "adhoc" ]]; then
    strict_or_warn "bundle is ad-hoc signed; macOS Accessibility may show a stale enabled row that does not apply to this binary"
  elif [[ -n "$signature" ]]; then
    info "codesign signature: $signature"
  fi

  if [[ -z "$team" || "$team" == "not set" ]]; then
    strict_or_warn "TeamIdentifier is missing; Accessibility trust is not stable across installs"
  else
    pass "TeamIdentifier is present: $team"
  fi

  if printf '%s\n' "$authorities" | grep -q '^Developer ID Application:'; then
    pass "Developer ID Application authority is present"
  else
    strict_or_warn "Developer ID Application authority is missing"
  fi

  if [[ -x /usr/sbin/spctl ]]; then
    if spctl_output=$(/usr/sbin/spctl -a -vv --type exec "$APP_PATH" 2>&1); then
      pass "Gatekeeper assessment accepted the app"
    else
      strict_or_warn "Gatekeeper assessment rejected the app: $(printf '%s' "$spctl_output" | tr '\n' ' ')"
    fi
  else
    warn "spctl is unavailable; skipped Gatekeeper assessment"
  fi
}

macos_permission_notes() {
  section "macOS Accessibility And Automation"
  info "The authoritative runtime check is AXIsProcessTrusted() from the running Zerm process."
  info "System Settings can show an enabled Zerm row while an ad-hoc or replaced local binary is still not trusted."
  info "For release builds, require Developer ID signing, a stable TeamIdentifier, and Gatekeeper acceptance."
  info "If the dashboard still shows Accessibility blocked for a local build, remove and re-add the exact installed app bundle."
  info "Automation is only needed for the System Events fallback; direct Accessibility and CoreGraphics paths do not prove Automation trust."
}

run_autopaste_self_test() {
  local executable token answer

  section "Interactive Auto-Paste Self-Test"

  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "Auto-paste self-test is currently macOS-only"
    return
  fi

  if [[ "$ZERM_VERIFY_ALLOW_INPUT:-0" != "1" ]]; then
    warn "Skipped auto-paste self-test because ZERM_VERIFY_ALLOW_INPUT=1 is not set"
    info "To run it: focus a scratch text field, then run ZERM_VERIFY_ALLOW_INPUT=1 scripts/verify-native-writing-layer.sh --run-autopaste-self-test"
    return
  fi

  executable="$APP_PATH/Contents/MacOS/zerm"
  if [[ ! -x "$executable" ]]; then
    fail "Cannot run self-test; executable is missing: $executable"
    return
  fi

  token="ZERM_AUTOPASTE_SELF_TEST_$(date +%Y%m%d_%H%M%S)"
  info "This test will paste token '$token' into the focused app."
  if [[ -t 0 ]]; then
    printf 'Focus a scratch text field now, then press Enter to continue. '
    read -r _
  else
    info "No TTY detected; waiting 5 seconds so a caller can focus a scratch text field."
    sleep 5
  fi

  "$executable" --zerm-autopaste-self-test "$token"
  local status=$?
  if [[ "$status" -eq 0 ]]; then
    pass "Zerm self-test command returned success"
  else
    fail "Zerm self-test command failed with exit code $status"
    return
  fi

  if [[ -t 0 ]]; then
    printf 'Did the token appear exactly once in the focused text field? [y/N] '
    read -r answer
    case "$answer" in
      y|Y|yes|YES)
        pass "Human-confirmed paste landed in the focused field"
        ;;
      *)
        fail "Paste was not human-confirmed; collect dashboard insertion diagnostics and target app details"
        ;;
    esac
  else
    warn "Self-test command returned success, but paste landing was not confirmed in non-interactive mode"
  fi
}

print_manual_checklist() {
  section "Manual Full-Screen Pill Test"
  cat <<'CHECKLIST'
1. Open TextEdit, Arc/Chrome, Slack/Discord, and a terminal/editor target.
2. Put each app into macOS full-screen mode one at a time.
3. Move the pointer to the active full-screen display.
4. Press the Zerm hotkey.
5. Expected: the floating pill appears immediately above the full-screen app on the active display.
6. Speak for 2-3 seconds.
7. Expected: the pill stays visible while recording, shows processing, then copied/pasted/failure state.
8. Switch Spaces or monitors and repeat.
9. Failure data to capture: app name, bundle id, display count, Space/full-screen state, whether the pill was hidden or on another display.
CHECKLIST

  section "Manual Auto-Paste Target Matrix"
  cat <<'CHECKLIST'
Use a scratch document or disposable message box. Never run paste tests in a password or production form.

- TextEdit native text field: expect direct Accessibility insertion or clipboard fallback.
- Arc/Chrome web input: expect clipboard-keystroke path; direct AX may be rejected by the browser.
- Slack/Discord/Electron: expect clipboard-keystroke path and clipboard-consumption confirmation work.
- Terminal/editor: expect clipboard-keystroke path; preserve symbols and newlines.
- Secure/password fields: expect refusal or copy-only recovery, never forced paste.
CHECKLIST
}

print_support_matrix() {
  section "Cross-Platform Paste Support Matrix"
  cat <<'MATRIX'
Platform        Current production expectation                 Required permissions / caveats
macOS          Auto-paste supported and under active hardening  Accessibility; Automation only for System Events fallback; signed builds required for stable TCC trust
Windows        Clipboard copy supported; native paste pending   Needs helper/SendInput integration, clipboard sequence tracking, and permission diagnostics before production auto-paste
Linux X11      Clipboard copy supported; native paste pending   Needs X11 clipboard + key synthesis path and clear dependency checks
Linux Wayland  Copy-only or explicit unsupported state          Needs compositor/portal-specific support; do not claim generic paste support
MATRIX
}

print_summary() {
  section "Summary"
  info "Warnings: $WARNINGS"
  info "Failures: $FAILURES"
  if [[ "$FAILURES" -gt 0 ]]; then
    exit 1
  fi
}

main() {
  print_environment

  case "$(uname -s)" in
    Darwin)
      section "macOS Signing"
      macos_codesign_details
      macos_permission_notes
      ;;
    Linux)
      section "Linux Native Layer"
      info "Check X11 vs Wayland explicitly before enabling auto-paste."
      info "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}"
      info "DISPLAY=${DISPLAY:-unset}"
      ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT)
      section "Windows Native Layer"
      info "Verify the future native helper uses SendInput, modifier masking, clipboard sequence tracking, and timeouts."
      ;;
    *)
      section "Native Layer"
      warn "Unknown OS; only documentation checks are available"
      ;;
  esac

  if [[ "$RUN_AUTOPASTE_SELF_TEST" -eq 1 ]]; then
    run_autopaste_self_test
  fi

  if [[ "$PRINT_MANUAL_CHECKLIST" -eq 1 ]]; then
    print_manual_checklist
  fi

  print_support_matrix
  print_summary
}

main
