import SwiftUI
import AVFoundation
import Cocoa
import KeyboardShortcuts
import ScreenCaptureKit

class PermissionManager: ObservableObject {
    @Published var audioPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published var isAccessibilityEnabled = false
    @Published var isScreenRecordingEnabled = false
    @Published var isKeyboardShortcutSet = false
    @Published var isGlobalHotkeyMonitoringAvailable = true
    /// Shown when Screen Recording is toggled on in Settings but the process must relaunch.
    @Published var screenRecordingNeedsRelaunch = false

    private var pollTask: Task<Void, Never>?

    init() {
        setupNotificationObservers()
        checkAllPermissions()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        pollTask?.cancel()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ZermGlobalHotkeyMonitoringChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let available = notification.userInfo?["available"] as? Bool else { return }
            self?.isGlobalHotkeyMonitoringAvailable = available
        }
    }

    @objc private func applicationDidBecomeActive() {
        // After returning from System Settings, re-check several times —
        // macOS often updates TCC a beat after the toggle flips.
        checkAllPermissions()
        pollPermissions(forSeconds: 4)
    }

    func checkAllPermissions() {
        checkAccessibilityPermissions()
        checkScreenRecordingPermission()
        checkAudioPermissionStatus()
        checkKeyboardShortcut()
    }

    /// Re-check on an interval so refresh / Settings return picks up grants without relaunch when possible.
    func pollPermissions(forSeconds seconds: TimeInterval = 3) {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            let steps = max(1, Int(seconds / 0.5))
            for _ in 0..<steps {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                self.checkAllPermissions()
                if self.isAccessibilityEnabled && self.isScreenRecordingEnabled {
                    self.screenRecordingNeedsRelaunch = false
                    return
                }
            }
        }
    }

    func checkAccessibilityPermissions() {
        // Prefer the non-prompting check; also accept plain AXIsProcessTrusted.
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let withOptions = AXIsProcessTrustedWithOptions(options)
        let plain = AXIsProcessTrusted()
        let accessibilityEnabled = withOptions || plain
        DispatchQueue.main.async {
            self.isAccessibilityEnabled = accessibilityEnabled
        }
    }

    /// Opens System Settings and optionally shows the system accessibility prompt to re-bind trust.
    func openAccessibilitySettings(promptIfNeeded: Bool = true) {
        if promptIfNeeded, !isAccessibilityEnabled {
            // This presents the system dialog that links this exact binary to TCC.
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options)
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        pollPermissions(forSeconds: 8)
    }

    func checkScreenRecordingPermission() {
        let preflight = CGPreflightScreenCaptureAccess()
        DispatchQueue.main.async {
            self.isScreenRecordingEnabled = preflight
            if preflight {
                self.screenRecordingNeedsRelaunch = false
            }
        }
        // Secondary async probe via ScreenCaptureKit — on some macOS versions
        // CGPreflight lags behind the Settings toggle until relaunch.
        if !preflight {
            Task { @MainActor in
                let kitGranted = await Self.probeScreenCaptureKitAccess()
                if kitGranted {
                    // TCC is effectively granted; process just needs a relaunch for CGPreflight.
                    self.screenRecordingNeedsRelaunch = true
                }
            }
        }
    }

    func requestScreenRecordingPermission() {
        let already = CGPreflightScreenCaptureAccess()
        if !already {
            CGRequestScreenCaptureAccess()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        pollPermissions(forSeconds: 8)
        // After the user toggles, macOS often still returns false until relaunch.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let preflight = CGPreflightScreenCaptureAccess()
            let kit = await Self.probeScreenCaptureKitAccess()
            if !preflight && kit {
                self.screenRecordingNeedsRelaunch = true
            }
        }
    }

    /// True if ScreenCaptureKit can enumerate displays (permission present for this process).
    private static func probeScreenCaptureKitAccess() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    func checkAudioPermissionStatus() {
        DispatchQueue.main.async {
            self.audioPermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    func requestAudioPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                self.audioPermissionStatus = granted ? .authorized : .denied
            }
        }
    }

    func checkKeyboardShortcut() {
        DispatchQueue.main.async {
            self.isKeyboardShortcutSet = KeyboardShortcuts.getShortcut(for: .toggleMiniRecorder) != nil
        }
    }
}

struct PermissionCard: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    let isGranted: Bool
    var statusTitle: LocalizedStringKey? = nil
    let buttonTitle: LocalizedStringKey
    let buttonAction: () -> Void
    var infoTipMessage: String?
    var infoTipLink: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .frame(width: 30, height: 30)
                .background((isGranted ? Color.green : Color.orange).opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if let message = infoTipMessage {
                        if let link = infoTipLink, !link.isEmpty {
                            InfoTip(message, learnMoreURL: link)
                        } else {
                            InfoTip(message)
                        }
                    }
                }
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Label(isGranted ? "Granted" : (statusTitle ?? "Blocked"), systemImage: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(isGranted ? Color.green : Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isGranted ? Color.green : Color.orange).opacity(0.1), in: Capsule())

            if !isGranted {
                Button(buttonTitle, action: buttonAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(CardBackground(isSelected: false))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var hotkeyManager: HotkeyManager
    @StateObject private var permissionManager = PermissionManager()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                CompactHeroSection(
                    icon: "shield.lefthalf.filled",
                    title: String(localized: "App Permissions"),
                    description: String(localized: "Zerm requires the following permissions to function properly")
                )
                
                // Permission Cards
                HStack {
                    Spacer()
                    Button(action: refreshPermissions) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh permission status")
                    .accessibilityLabel("Refresh permission status")
                }
                .padding(.bottom, -24)

                VStack(spacing: 8) {
                    ForEach(orderedPermissions, id: \.self) { permission in
                        permissionCard(permission)
                    }
                }
            }
            .padding(24)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear {
            hotkeyManager.refreshMonitoring()
            permissionManager.checkAllPermissions()
            permissionManager.pollPermissions(forSeconds: 2)
        }
    }

    private enum PermissionKind: CaseIterable {
        case microphone, accessibility, keyboardMonitoring, screenRecording, shortcut
    }

    private var orderedPermissions: [PermissionKind] {
        PermissionKind.allCases.sorted { !isGranted($0) && isGranted($1) }
    }

    private func isGranted(_ permission: PermissionKind) -> Bool {
        switch permission {
        case .microphone: permissionManager.audioPermissionStatus == .authorized
        case .accessibility: permissionManager.isAccessibilityEnabled
        case .keyboardMonitoring: permissionManager.isGlobalHotkeyMonitoringAvailable
        case .screenRecording: permissionManager.isScreenRecordingEnabled
        case .shortcut: hotkeyManager.selectedHotkey1 != .none
        }
    }

    @ViewBuilder
    private func permissionCard(_ permission: PermissionKind) -> some View {
        switch permission {
        case .microphone:
            PermissionCard(
                icon: "mic", title: "Microphone Access",
                description: "Allow Zerm to record your voice for transcription",
                isGranted: isGranted(permission),
                statusTitle: permissionManager.audioPermissionStatus == .notDetermined ? "Not requested" : nil,
                buttonTitle: "Open System Settings",
                buttonAction: { openPrivacySettings("Privacy_Microphone") },
                infoTipMessage: String(localized: "The one permission Zerm cannot work without — no microphone access means no audio to transcribe. macOS only asks once, so if you declined the first time you have to grant it in System Settings under Privacy & Security › Microphone."),
                infoTipLink: Links.docString(.permissions)
            )
        case .accessibility:
            PermissionCard(
                icon: "hand.raised", title: "Accessibility Access",
                description: "Allow Zerm to paste transcribed text directly at your cursor position",
                isGranted: isGranted(permission), buttonTitle: "Open System Settings",
                buttonAction: { permissionManager.openAccessibilitySettings(promptIfNeeded: true) },
                infoTipMessage: String(localized: "Zerm uses Accessibility permissions to paste the transcribed text directly into other applications at your cursor's position. This allows for a seamless dictation experience across your Mac. After enabling Zerm in System Settings, use the refresh button — if it stays red, fully quit Zerm (Cmd+Q) and reopen."),
                infoTipLink: Links.docString(.permissions)
            )
        case .keyboardMonitoring:
            PermissionCard(
                icon: "keyboard",
                title: "Global Keyboard Monitoring",
                description: permissionManager.isGlobalHotkeyMonitoringAvailable
                    ? "Receive key releases to stop push-to-talk reliably"
                    : "Global key events unavailable — enable Accessibility or Input Monitoring",
                isGranted: isGranted(permission),
                buttonTitle: "Open System Settings",
                buttonAction: { permissionManager.openAccessibilitySettings(promptIfNeeded: true) },
                infoTipMessage: String(localized: "Global keyboard monitoring lets push-to-talk receive key releases while another app is active. Zerm also checks key state locally to stop recordings if a release event is missed."),
                infoTipLink: Links.docString(.permissions)
            )
        case .screenRecording:
            PermissionCard(
                icon: "rectangle.on.rectangle", title: "Screen Recording Access",
                description: permissionManager.screenRecordingNeedsRelaunch
                    ? "Permission looks granted — fully quit Zerm (Cmd+Q) and reopen to finish enabling Screen Recording"
                    : "Allow Zerm to understand context from your screen for transcript Enhancement",
                isGranted: isGranted(permission),
                statusTitle: permissionManager.screenRecordingNeedsRelaunch ? "Relaunch required" : nil,
                buttonTitle: permissionManager.screenRecordingNeedsRelaunch ? "Quit Zerm to Finish" : "Open System Settings",
                buttonAction: {
                    if permissionManager.screenRecordingNeedsRelaunch { NSApp.terminate(nil) }
                    else { permissionManager.requestScreenRecordingPermission() }
                },
                infoTipMessage: String(localized: "Zerm can read on-screen text when Screen Context is enabled. Zerm does not save that captured text to disk, but enhancement requests can send it to your configured enhancement provider. Choose an on-device provider to keep it on your Mac. After enabling Screen Recording, fully quit and reopen Zerm if this check stays red."),
                infoTipLink: Links.docString(.contextualAwareness)
            )
        case .shortcut:
            PermissionCard(
                icon: "keyboard", title: "Keyboard Shortcut",
                description: "Set up a keyboard shortcut to use Zerm anywhere",
                isGranted: isGranted(permission), statusTitle: "Not set", buttonTitle: "Configure Shortcut",
                buttonAction: {
                    NotificationCenter.default.post(
                        name: .navigateToDestination, object: nil,
                        userInfo: ["destination": "Settings"]
                    )
                },
                infoTipMessage: String(localized: "Not a macOS permission — this is simply whether you have picked a key to start dictation with. Without one there is no way to open the recorder except from the menu bar. Configure Shortcut takes you to the Settings pane where you choose it."),
                infoTipLink: Links.docString(.shortcuts)
            )
        }
    }

    private func refreshPermissions() {
        hotkeyManager.refreshMonitoring()
        permissionManager.checkAllPermissions()
        permissionManager.pollPermissions(forSeconds: 2)
    }

    private func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview {
    PermissionsView()
} 
